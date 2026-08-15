-----------------------------------------------------------------------------
-- nav_route.lua
-- Custom navigation module split from global.lua at v21.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Route Recorder / Route Replay
-- Optimized v1:
-- Records raw map + x + z positions.
-- Loads only clean tile centers.
-- Compresses routes into corners/transitions/endpoints.
-- Replays from the closest known point and handles simple map borders.
-----------------------------------------------------------------------------

local ROUTE_CENTER_TOLERANCE = 0.03
local ROUTE_POINT_TOLERANCE = 0.14
local ROUTE_CORNER_TOLERANCE = 0.45
local ROUTE_TRANSITION_TOLERANCE = 0.35
local ROUTE_WALK_TIMEOUT = 1500
local ROUTE_TRANSITION_TIMEOUT = 360
local ROUTE_STUCK_FRAMES = 30
local ROUTE_STUCK_MOVE_EPSILON = 0.025
local ROUTE_STUCK_GRACE_FRAMES = 8
local ROUTE_AXIS_ALIGNMENT_TOLERANCE = 0.65
local ROUTE_RECOVERY_MAX_ATTEMPTS_PER_POINT = 2
-- Keep recovery nudges extremely small. Recovery is for tile alignment only,
-- not for free-roaming around obstacles or doors.
local ROUTE_RECOVERY_NUDGE_FRAMES = 5
local ROUTE_RECOVERY_MIN_MOVE = 0.08
local ROUTE_RECOVERY_TARGET_MOVE = 0.45
local ROUTE_RECOVERY_MAX_SAFE_MOVE = 0.95
local ROUTE_RECOVERY_RETURN_TIMEOUT = 45
local ROUTE_RECOVERY_AXIS_ERROR_MIN = 0.55
ROUTE_FAILOVER_MAX_ATTEMPTS = 5

local route_last_failure = nil

function route_clear_failure()
    route_last_failure = nil
end

function route_set_failure(reason, route_name, details)
    route_last_failure = {
        reason = reason or "unknown",
        route_name = route_name,
        details = details
    }
end

function route_log(message)
    if config.debug then
        print(message)
    end
end

function route_release_direction_buttons()
    release_button("Up")
    release_button("Down")
    release_button("Left")
    release_button("Right")
end

function route_get_name()
    if config.route_name and config.route_name ~= "" then
        return config.route_name
    end

    return "test_route"
end

function route_get_path()
    return "user\\routes\\" .. route_get_name() .. ".txt"
end

local ROUTE_FOLDER_READY = false

function route_known_file_exists(path)
    local file = io.open(path, "r")

    if file then
        file:close()
        return true
    end

    return false
end

function route_folder_likely_exists()
    -- Avoid calling os.execute every time. In DeSmuME Lua, even a harmless
    -- Windows shell check can pause the emulator for several seconds.
    return route_known_file_exists("user\\routes\\routes_index.txt") or
           route_known_file_exists("user\\routes\\map_nodes.txt") or
           route_known_file_exists("user\\routes\\map_probe_batch_edges.txt")
end

function route_make_folder()
    if ROUTE_FOLDER_READY then
        return
    end

    if route_folder_likely_exists() then
        ROUTE_FOLDER_READY = true
        return
    end

    -- Last resort for a fresh install where user\routes does not exist yet.
    -- This is intentionally cached because os.execute is slow in DeSmuME Lua.
    os.execute('if not exist "user\\routes" mkdir "user\\routes"')
    ROUTE_FOLDER_READY = true
end

function route_map_key_from_values(map, name)
    -- Map names are more stable for this route system than HGSS map_header.
    -- map_header can differ at borders while the visible/usable map name is what we care about.
    if name and name ~= "" then
        return tostring(name)
    end

    return tostring(map)
end

function route_map_key(point)
    return route_map_key_from_values(point.map, point.name)
end

function route_position_key()
    if not game_state or not game_state.in_game then
        return nil
    end

    return tostring(game_state.map_header) .. "," ..
           tostring(game_state.trainer_x) .. "," ..
           tostring(game_state.trainer_z) .. "," ..
           tostring(game_state.map_name or "")
end

function route_write_position(file)
    file:write(
        tostring(game_state.map_header) .. "," ..
        tostring(game_state.trainer_x) .. "," ..
        tostring(game_state.trainer_z) .. "," ..
        tostring(game_state.map_name or "") .. "\n"
    )

    file:flush()

    route_log(
        "Recorded: " ..
        tostring(game_state.map_name) ..
        " | X " .. tostring(game_state.trainer_x) ..
        " | Z " .. tostring(game_state.trainer_z)
    )
end

function mode_route_record()
    route_make_folder()

    local path = route_get_path()
    local file = io.open(path, "w")

    if not file then
        abort("Could not open route file for writing: " .. path)
    end

    print("Recording route to " .. path)
    print("Walk manually. Stop the Lua script when finished.")
    print("Tip: enable debug if you want every recorded coordinate printed.")

    local last_key = nil

    while true do
        process_frame()

        if game_state.in_battle then
            route_release_direction_buttons()
            process_wild_encounter()
            wait_frames(90)
        end

        local key = route_position_key()

        if key and key ~= last_key then
            route_write_position(file)
            last_key = key
        end
    end
end

function route_coord_is_center(value)
    local frac = value - math.floor(value)

    -- HGSS overworld tile centers are usually .5 values, like 358.5.
    return math.abs(frac - 0.5) < ROUTE_CENTER_TOLERANCE
end

function route_point_key(point)
    -- Remove duplicate standing positions while preserving map transitions.
    return route_map_key(point) .. "," ..
           tostring(math.floor(point.x + 0.5)) .. "," ..
           tostring(math.floor(point.z + 0.5))
end

function route_load()
    local path = route_get_path()
    local file = io.open(path, "r")

    if not file then
        abort("Could not open route file for reading: " .. path)
    end

    local route = {}
    local last_key = nil
    local raw_count = 0

    for line in file:lines() do
        raw_count = raw_count + 1

        local map, x, z, name = string.match(line, "([^,]+),([^,]+),([^,]+),?(.*)")

        if map and x and z then
            local point = {
                map = tonumber(map),
                x = tonumber(x),
                z = tonumber(z),
                name = name
            }

            -- Only keep clean tile-center points, not animation-frame positions.
            if point.map and point.x and point.z and route_coord_is_center(point.x) and route_coord_is_center(point.z) then
                local key = route_point_key(point)

                if key ~= last_key then
                    table.insert(route, point)
                    last_key = key
                end
            end
        end
    end

    file:close()

    if #route == 0 then
        abort("Route file had no usable tile-center points: " .. path)
    end

    print(
        "Loaded route " .. path ..
        " with " .. tostring(#route) ..
        " usable points from " .. tostring(raw_count) .. " raw points."
    )

    return route
end

function route_handle_battle()
    if game_state.in_battle then
        route_release_direction_buttons()
        process_wild_encounter()
        wait_frames(90)
    end
end

function route_same_map(point)
    if not game_state or not game_state.in_game then
        return false
    end

    if game_state.map_header == point.map then
        return true
    end

    if point.name and point.name ~= "" and game_state.map_name then
        return tostring(game_state.map_name) == tostring(point.name)
    end

    return false
end

function route_close_to_point(point, tolerance)
    return math.abs(game_state.trainer_x - point.x) < tolerance and
           math.abs(game_state.trainer_z - point.z) < tolerance
end

function route_at_point(point)
    return game_state and
           game_state.in_game and
           route_same_map(point) and
           route_close_to_point(point, ROUTE_POINT_TOLERANCE)
end

function route_close_to_corner(point)
    return game_state and
           game_state.in_game and
           route_same_map(point) and
           route_close_to_point(point, ROUTE_CORNER_TOLERANCE)
end

function route_distance_to_point(point)
    if not game_state or not game_state.in_game then
        return 999999
    end

    if not route_same_map(point) then
        return 999999
    end

    local dx = point.x - game_state.trainer_x
    local dz = point.z - game_state.trainer_z

    return math.abs(dx) + math.abs(dz)
end

function route_find_closest_index(route)
    local best_index = 1
    local best_distance = 999999

    for i = 1, #route do
        local distance = route_distance_to_point(route[i])

        if distance < best_distance then
            best_distance = distance
            best_index = i
        end
    end

    print(
        "Closest route point is " ..
        tostring(best_index) .. "/" .. tostring(#route) ..
        " at distance " .. tostring(best_distance)
    )

    return best_index
end

function route_get_direction_to(point)
    local dx = point.x - game_state.trainer_x
    local dz = point.z - game_state.trainer_z

    if math.abs(dx) >= math.abs(dz) and math.abs(dx) > ROUTE_POINT_TOLERANCE then
        return dx > 0 and "Right" or "Left"
    elseif math.abs(dz) > ROUTE_POINT_TOLERANCE then
        return dz > 0 and "Down" or "Up"
    end

    return nil
end

function route_axis_aligned_for_direction(point, dir)
    -- Do not consume a compressed corner just because we crossed one axis.
    -- If we are moving horizontally, Z must also be close enough.
    -- If we are moving vertically, X must also be close enough.
    if dir == "Right" or dir == "Left" then
        return math.abs(game_state.trainer_z - point.z) < ROUTE_AXIS_ALIGNMENT_TOLERANCE
    elseif dir == "Down" or dir == "Up" then
        return math.abs(game_state.trainer_x - point.x) < ROUTE_AXIS_ALIGNMENT_TOLERANCE
    end

    return false
end

function route_reached_or_passed_axis(point, dir)
    if not route_axis_aligned_for_direction(point, dir) then
        return false
    end

    if dir == "Right" then
        return game_state.trainer_x >= point.x - ROUTE_POINT_TOLERANCE
    elseif dir == "Left" then
        return game_state.trainer_x <= point.x + ROUTE_POINT_TOLERANCE
    elseif dir == "Down" then
        return game_state.trainer_z >= point.z - ROUTE_POINT_TOLERANCE
    elseif dir == "Up" then
        return game_state.trainer_z <= point.z + ROUTE_POINT_TOLERANCE
    end

    return false
end

function route_opposite_direction(dir)
    if dir == "Up" then
        return "Down"
    elseif dir == "Down" then
        return "Up"
    elseif dir == "Left" then
        return "Right"
    elseif dir == "Right" then
        return "Left"
    end

    return nil
end

function route_recovery_directions(point, stuck_dir)
    local primary = nil

    -- Local recovery is only allowed when we are visibly off the route line.
    -- If the blocked direction is horizontal, only nudge vertically when Z is
    -- off by more than the safety threshold. If the blocked direction is
    -- vertical, only nudge horizontally when X is off by more than the threshold.
    -- This prevents dangerous "try anything" nudges beside doors/NPCs.
    if stuck_dir == "Left" or stuck_dir == "Right" then
        local z_error = point.z - game_state.trainer_z

        if math.abs(z_error) < ROUTE_RECOVERY_AXIS_ERROR_MIN then
            print_warn("Local recovery skipped: already aligned on Z; nudge would be risky.")
            return {}
        end

        primary = z_error > 0 and "Down" or "Up"
    elseif stuck_dir == "Up" or stuck_dir == "Down" then
        local x_error = point.x - game_state.trainer_x

        if math.abs(x_error) < ROUTE_RECOVERY_AXIS_ERROR_MIN then
            print_warn("Local recovery skipped: already aligned on X; nudge would be risky.")
            return {}
        end

        primary = x_error > 0 and "Right" or "Left"
    end

    if not primary then
        return {}
    end

    -- Conservative v2: try only the direction that moves us toward the target
    -- line. Do not try the opposite direction or a last-resort escape step.
    return {primary}
end

function route_recovery_same_context(map_header, map_name)
    if not game_state or not game_state.in_game then
        return false
    end

    return game_state.map_header == map_header and
           tostring(game_state.map_name or "") == tostring(map_name or "")
end

function route_try_return_to_recovery_context(map_header, map_name, entry_dir)
    local tried = {}
    local directions = {
        route_opposite_direction(entry_dir),
        entry_dir,
        "Down",
        "Up",
        "Left",
        "Right"
    }

    route_release_direction_buttons()

    for _, dir in ipairs(directions) do
        if dir and not tried[dir] then
            tried[dir] = true

            for i = 1, ROUTE_RECOVERY_RETURN_TIMEOUT do
                if route_recovery_same_context(map_header, map_name) then
                    route_release_direction_buttons()
                    wait_frames(4)
                    return true
                end

                if game_state.in_battle then
                    route_release_direction_buttons()
                    route_handle_battle()
                    wait_frames(10)
                    return route_recovery_same_context(map_header, map_name)
                end

                hold_button(dir)
                process_frame()
            end

            route_release_direction_buttons()
            wait_frames(4)
        end
    end

    return route_recovery_same_context(map_header, map_name)
end

function route_try_nudge(dir, frames)
    if not dir then
        return false
    end

    local start_x = game_state.trainer_x
    local start_z = game_state.trainer_z
    local start_map = game_state.map_header
    local start_name = game_state.map_name
    local moved = 0

    route_release_direction_buttons()

    for i = 1, frames do
        if game_state.in_battle then
            route_release_direction_buttons()
            route_handle_battle()
            wait_frames(10)
            return true
        end

        hold_button(dir)
        process_frame()

        moved = math.abs(game_state.trainer_x - start_x) +
                math.abs(game_state.trainer_z - start_z)

        if not route_recovery_same_context(start_map, start_name) then
            route_release_direction_buttons()
            print_warn("Recovery nudge changed maps. Stopping immediately; recovery is not allowed to enter doors/warps.")
            route_set_failure(
                "unsafe_recovery_map_change",
                nil,
                "recovery nudge " .. tostring(dir) .. " changed maps from " ..
                tostring(start_name) .. " to " .. tostring(game_state.map_name)
            )
            return "unsafe"
        end

        if moved > ROUTE_RECOVERY_MAX_SAFE_MOVE then
            route_release_direction_buttons()
            print_warn(
                "Recovery nudge rejected after a large movement jump: " ..
                tostring(moved) ..
                ". Possible door, ledge, warp, or bad recovery direction."
            )
            return false
        end

        -- Stop the nudge as soon as it has moved enough to break collision.
        -- This avoids walking several tiles and accidentally entering buildings.
        if moved >= ROUTE_RECOVERY_TARGET_MOVE then
            break
        end
    end

    route_release_direction_buttons()
    wait_frames(2)

    moved = math.abs(game_state.trainer_x - start_x) +
            math.abs(game_state.trainer_z - start_z)

    return moved >= ROUTE_RECOVERY_MIN_MOVE
end

function route_try_local_recovery(point, stuck_dir, attempt)
    local dirs = route_recovery_directions(point, stuck_dir)

    if #dirs == 0 then
        return false
    end

    print_warn(
        "Local recovery attempt " .. tostring(attempt) ..
        ": stuck holding " .. tostring(stuck_dir) ..
        ", trying a small nudge."
    )

    for _, recovery_dir in ipairs(dirs) do
        if recovery_dir then
            print("  Nudging " .. tostring(recovery_dir) .. "...")

            local nudge_result = route_try_nudge(recovery_dir, ROUTE_RECOVERY_NUDGE_FRAMES)

            if nudge_result == "unsafe" then
                print_warn("Local recovery aborted because the nudge was unsafe.")
                return "unsafe"
            elseif nudge_result then
                print(
                    "  Recovery nudge moved player to X " ..
                    tostring(game_state.trainer_x) ..
                    " Z " .. tostring(game_state.trainer_z)
                )

                return true
            end
        end
    end

    print_warn("Local recovery attempt " .. tostring(attempt) .. " did not move the player.")
    return false
end

function route_abort_stuck(dir, point, stuck_frames)
    route_release_direction_buttons()

    print_warn("Route stuck while holding " .. tostring(dir) .. ".")
    print_warn(
        "Current position: " ..
        tostring(game_state.map_name) ..
        " | map " .. tostring(game_state.map_header) ..
        " | X " .. tostring(game_state.trainer_x) ..
        " | Z " .. tostring(game_state.trainer_z)
    )
    print_warn(
        "Target point: " ..
        tostring(point.name) ..
        " | map " .. tostring(point.map) ..
        " | X " .. tostring(point.x) ..
        " | Z " .. tostring(point.z)
    )
    print_warn(
        "No meaningful movement for " ..
        tostring(stuck_frames) ..
        " frames. Possible wall, NPC, bad route point, or one-way path."
    )

    route_set_failure(
        "stuck",
        nil,
        "stuck while holding " .. tostring(dir) ..
        " at X " .. tostring(game_state.trainer_x) ..
        " Z " .. tostring(game_state.trainer_z)
    )

    return false
end

function route_walk_to_point(point)
    if not game_state or not game_state.in_game then
        process_frame()
        return false
    end

    if route_at_point(point) then
        return true
    end

    if not route_same_map(point) then
        print(
            "Cannot walk: map mismatch. Target " ..
            tostring(point.name) ..
            " map " .. tostring(point.map) ..
            ", current " ..
            tostring(game_state.map_name) ..
            " map " .. tostring(game_state.map_header)
        )

        wait_frames(10)
        return false
    end

    local timeout = 0
    local stuck_frames = 0
    local last_x = game_state.trainer_x
    local last_z = game_state.trainer_z
    local last_dir = nil
    local recovery_attempts = 0

    while timeout < ROUTE_WALK_TIMEOUT do
        if game_state.in_battle then
            route_release_direction_buttons()
            route_handle_battle()
            return false
        end

        if not route_same_map(point) then
            route_release_direction_buttons()
            wait_frames(20)
            return false
        end

        if route_at_point(point) or route_close_to_corner(point) then
            route_release_direction_buttons()
            wait_frames(2)
            return true
        end

        local dir = route_get_direction_to(point)

        if not dir then
            route_release_direction_buttons()
            return true
        end

        if dir ~= last_dir then
            route_release_direction_buttons()

            print(
                "Holding " .. dir ..
                " until X " .. tostring(point.x) ..
                " Z " .. tostring(point.z)
            )

            -- Give movement a fresh grace window after changing direction.
            stuck_frames = 0
            last_x = game_state.trainer_x
            last_z = game_state.trainer_z
            last_dir = dir
        end

        if route_reached_or_passed_axis(point, dir) then
            route_release_direction_buttons()
            wait_frames(4)

            route_log(
                "Stopped near corner | Current X " ..
                tostring(game_state.trainer_x) ..
                " Z " ..
                tostring(game_state.trainer_z)
            )

            -- Compressed routes use corners. Only consume the corner after the main
            -- axis is reached AND the other axis is reasonably aligned. This prevents
            -- starting off-route from skipping a corner one tile too early.
            return true
        end

        -- Refresh held input every frame. This is much smoother than tapping once.
        hold_button(dir)
        process_frame()

        timeout = timeout + 1

        local movement_delta = math.abs(game_state.trainer_x - last_x) +
                               math.abs(game_state.trainer_z - last_z)

        if movement_delta > ROUTE_STUCK_MOVE_EPSILON then
            stuck_frames = 0
            last_x = game_state.trainer_x
            last_z = game_state.trainer_z
        elseif timeout > ROUTE_STUCK_GRACE_FRAMES then
            stuck_frames = stuck_frames + 1
        end

        if stuck_frames >= ROUTE_STUCK_FRAMES then
            if recovery_attempts < ROUTE_RECOVERY_MAX_ATTEMPTS_PER_POINT then
                recovery_attempts = recovery_attempts + 1

                local recovered = route_try_local_recovery(point, dir, recovery_attempts)

                -- Whether the nudge succeeded or not, reset the stuck window so
                -- we do not spam logs every frame. Normal movement will either
                -- recover or fail again cleanly after another short check.
                stuck_frames = 0
                last_x = game_state.trainer_x
                last_z = game_state.trainer_z
                last_dir = nil

                if recovered == "unsafe" then
                    return false
                elseif recovered then
                    wait_frames(2)
                end
            else
                -- IMPORTANT: return immediately. If we only set route_last_failure
                -- and keep looping, this logs every frame and never hands control
                -- back to route failover.
                return route_abort_stuck(dir, point, stuck_frames)
            end
        end
    end

    route_release_direction_buttons()

    print_warn(
        "Timed out walking to point. Current X " .. tostring(game_state.trainer_x) ..
        " Z " .. tostring(game_state.trainer_z)
    )

    route_set_failure(
        "walk_timeout",
        nil,
        "timed out walking to X " .. tostring(point.x) .. " Z " .. tostring(point.z)
    )

    wait_frames(2)
    return false
end

function route_transition_direction(route, index)
    local current = route[index]
    local next_point = route[index + 1]

    if not current or not next_point then
        return nil
    end

    local dx = next_point.x - game_state.trainer_x
    local dz = next_point.z - game_state.trainer_z

    if math.abs(dx) >= math.abs(dz) and math.abs(dx) > ROUTE_POINT_TOLERANCE then
        return dx > 0 and "Right" or "Left"
    elseif math.abs(dz) > ROUTE_POINT_TOLERANCE then
        return dz > 0 and "Down" or "Up"
    end

    return nil
end

function route_try_map_transition(route, index)
    local point = route[index]

    if not point or route_same_map(point) then
        return false
    end

    -- Only try this if we are standing at/near the transition coordinate.
    local near_x = math.abs(game_state.trainer_x - point.x) < ROUTE_TRANSITION_TOLERANCE
    local near_z = math.abs(game_state.trainer_z - point.z) < ROUTE_TRANSITION_TOLERANCE

    if not near_x or not near_z then
        return false
    end

    local dir = route_transition_direction(route, index)

    if not dir then
        print("Map transition needed, but could not infer direction.")
        return false
    end

    print(
        "Transition " .. dir ..
        " from " ..
        tostring(game_state.map_name) ..
        " to " ..
        tostring(point.name)
    )

    local timeout = 0

    while timeout < ROUTE_TRANSITION_TIMEOUT do
        if game_state.in_battle then
            route_release_direction_buttons()
            route_handle_battle()
            return false
        end

        if route_same_map(point) then
            route_release_direction_buttons()
            wait_frames(8)
            print("Map transition complete.")
            return true
        end

        hold_button(dir)
        process_frame()

        timeout = timeout + 1
    end

    route_release_direction_buttons()
    print_warn("Map transition timed out.")
    route_set_failure(
        "transition_timeout",
        nil,
        "could not transition to " .. tostring(point.name)
    )
    return false
end

function route_segment_direction(a, b)
    if not a or not b then
        return nil
    end

    if route_map_key(a) ~= route_map_key(b) then
        return "MAP"
    end

    local dx = b.x - a.x
    local dz = b.z - a.z

    if math.abs(dx) > math.abs(dz) and math.abs(dx) > ROUTE_POINT_TOLERANCE then
        return dx > 0 and "Right" or "Left"
    elseif math.abs(dz) > ROUTE_POINT_TOLERANCE then
        return dz > 0 and "Down" or "Up"
    end

    return nil
end

function route_compress(route)
    if config.route_compress == false or #route <= 2 then
        print("Route compression disabled or unnecessary.")
        return route
    end

    local compressed = {}

    table.insert(compressed, route[1])

    for i = 2, #route - 1 do
        local prev = route[i - 1]
        local curr = route[i]
        local next_point = route[i + 1]

        local dir_before = route_segment_direction(prev, curr)
        local dir_after = route_segment_direction(curr, next_point)

        local map_changed_before = route_map_key(prev) ~= route_map_key(curr)
        local map_changed_after = route_map_key(curr) ~= route_map_key(next_point)

        -- Keep map transitions and corners.
        if map_changed_before or map_changed_after or dir_before ~= dir_after then
            table.insert(compressed, curr)
        end
    end

    table.insert(compressed, route[#route])

    print(
        "Compressed route from " ..
        tostring(#route) ..
        " points to " ..
        tostring(#compressed) ..
        " points."
    )

    return compressed
end

function route_reverse(route)
    local reversed = {}

    for i = #route, 1, -1 do
        table.insert(reversed, route[i])
    end

    return reversed
end

function mode_route_replay()
    local route = route_load()

    if config.route_reverse then
        route = route_reverse(route)
        print("Reversing route before replay.")
    end

    route = route_compress(route)

    print("Replaying route: " .. route_get_name())

    -- Start from the closest route point, not always point 1.
    local i = route_find_closest_index(route)

    while i <= #route do
        -- Skip points we are already standing on.
        while i <= #route and route_at_point(route[i]) do
            route_log(
                "Skipping reached point " .. tostring(i) .. "/" .. tostring(#route) ..
                " | " .. tostring(route[i].name) ..
                " | X " .. tostring(route[i].x) ..
                " | Z " .. tostring(route[i].z)
            )

            i = i + 1
        end

        if i > #route then
            break
        end

        local point = route[i]

        -- Handle border transitions like Goldenrod City -> Route 34.
        if not route_same_map(point) then
            local transitioned = route_try_map_transition(route, i)

            if transitioned then
                route_log(
                    "Consumed transition point " .. tostring(i) .. "/" .. tostring(#route) ..
                    " | " .. tostring(point.name) ..
                    " | X " .. tostring(point.x) ..
                    " | Z " .. tostring(point.z)
                )

                -- Do not try to walk back to the border coordinate after transitioning.
                -- Move on to the next route point.
                i = i + 1
                wait_frames(6)
            else
                print(
                    "Cannot transition to " ..
                    tostring(point.name) ..
                    " from " ..
                    tostring(game_state.map_name)
                )
                wait_frames(10)
            end
        else
            local reached = route_walk_to_point(point)

            if reached then
                route_log(
                    "Reached point " .. tostring(i) .. "/" .. tostring(#route) ..
                    " | " .. tostring(point.name) ..
                    " | X " .. tostring(point.x) ..
                    " | Z " .. tostring(point.z)
                )

                i = i + 1
            else
                wait_frames(2)
            end
        end
    end

    route_release_direction_buttons()
    print("Route complete.")
    abort("Route replay finished.")
end

-----------------------------------------------------------------------------
-- Route Library / Route To Destination
-- Reads user\routes\routes_index.txt and chains saved routes together.
-- Supports weighted route costs.
-----------------------------------------------------------------------------

function route_index_path()
    return "user\\routes\\routes_index.txt"
end

function route_trim(value)
    if not value then
        return ""
    end

    return string.gsub(value, "^%s*(.-)%s*$", "%1")
end

function route_split_index_line(line)
    local parts = {}

    for part in string.gmatch(line, "([^|]+)") do
        parts[#parts + 1] = route_trim(part)
    end

    return parts
end

function route_load_index()
    local path = route_index_path()
    local file = io.open(path, "r")

    if not file then
        abort("Could not open route index: " .. path)
    end

    local routes = {}

    for line in file:lines() do
        line = route_trim(line)

        -- Ignore blank lines and comment lines.
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local parts = route_split_index_line(line)

            if #parts >= 3 then
                local route_name = parts[1]
                local start_node = parts[2]
                local end_node = parts[3]
                local cost = tonumber(parts[4]) or 1

                routes[#routes + 1] = {
                    name = route_name,
                    start_node = start_node,
                    end_node = end_node,
                    cost = cost
                }
            else
                print_warn("Bad route index line: " .. line)
            end
        end
    end

    file:close()

    if #routes == 0 then
        abort("No usable routes found in " .. path)
    end

    print("Loaded " .. tostring(#routes) .. " indexed routes.")
    return routes
end

function route_find_chain(routes, start_node, destination_node, banned_routes)
    start_node = route_trim(start_node)
    destination_node = route_trim(destination_node)

    local INF = 999999999

    local dist = {}
    local previous_node = {}
    local previous_route = {}
    local unvisited = {}

    dist[start_node] = 0
    unvisited[start_node] = true

    while true do
        local current_node = nil
        local current_best = INF

        for node, _ in pairs(unvisited) do
            if dist[node] and dist[node] < current_best then
                current_best = dist[node]
                current_node = node
            end
        end

        if not current_node then
            return nil, nil
        end

        if current_node == destination_node then
            break
        end

        unvisited[current_node] = nil

        for _, route in ipairs(routes) do
            if route.start_node == current_node and not (banned_routes and banned_routes[route.name]) then
                local new_cost = dist[current_node] + route.cost

                if not dist[route.end_node] or new_cost < dist[route.end_node] then
                    dist[route.end_node] = new_cost
                    previous_node[route.end_node] = current_node
                    previous_route[route.end_node] = route.name
                    unvisited[route.end_node] = true
                end
            end
        end
    end

    -- Build path backward first, then reverse it.
    local reversed_path = {}
    local node = destination_node

    while node ~= start_node do
        local route_name = previous_route[node]

        if not route_name then
            return nil, nil
        end

        reversed_path[#reversed_path + 1] = route_name
        node = previous_node[node]
    end

    local path = {}

    for i = #reversed_path, 1, -1 do
        path[#path + 1] = reversed_path[i]
    end

    return path, dist[destination_node]
end

function route_replay_loaded_route(route, route_name)
    route_clear_failure()

    if config.route_compress ~= false then
        route = route_compress(route)
    end

    print("Replaying indexed route: " .. route_name)

    local i = route_find_closest_index(route)

    while i <= #route do
        while i <= #route and route_at_point(route[i]) do
            route_log(
                "Skipping reached point " .. tostring(i) .. "/" .. tostring(#route) ..
                " | " .. tostring(route[i].name) ..
                " | X " .. tostring(route[i].x) ..
                " | Z " .. tostring(route[i].z)
            )

            i = i + 1
        end

        if i > #route then
            break
        end

        local point = route[i]

        if not route_same_map(point) then
            local transitioned = route_try_map_transition(route, i)

            if transitioned then
                print(
                    "Consumed transition point " .. tostring(i) .. "/" .. tostring(#route) ..
                    " | " .. tostring(point.name)
                )

                i = i + 1
                wait_frames(10)
            else
                print_warn(
                    "Route failed during map transition to " ..
                    tostring(point.name) ..
                    " from " ..
                    tostring(game_state.map_name)
                )

                if not route_last_failure then
                    route_set_failure(
                        "transition_failed",
                        route_name,
                        "could not transition to " .. tostring(point.name)
                    )
                end

                route_last_failure.route_name = route_name
                return false, route_last_failure
            end
        else
            local reached = route_walk_to_point(point)

            if route_last_failure then
                route_last_failure.route_name = route_name
                print_warn("Indexed route failed: " .. tostring(route_name))
                return false, route_last_failure
            end

            if reached then
                route_log(
                    "Reached point " .. tostring(i) .. "/" .. tostring(#route) ..
                    " | " .. tostring(route[i].name) ..
                    " | X " .. tostring(route[i].x) ..
                    " | Z " .. tostring(route[i].z)
                )

                i = i + 1
            else
                wait_frames(2)
            end
        end
    end

    route_release_direction_buttons()
    print("Finished indexed route: " .. route_name)
    return true, nil
end

function route_banned_list(banned_routes)
    local names = {}

    for route_name, _ in pairs(banned_routes or {}) do
        names[#names + 1] = route_name
    end

    if #names == 0 then
        return "none"
    end

    table.sort(names)
    return table.concat(names, ", ")
end

function route_print_chain(label, chain, total_cost)
    print(
        label ..
        " with " ..
        tostring(#chain) ..
        " route(s), total cost " ..
        tostring(total_cost) ..
        ":"
    )

    for i, route_name in ipairs(chain) do
        print("  " .. tostring(i) .. ". " .. route_name)
    end
end

function route_run_chain(chain)
    local original_route_name = config.route_name

    for _, route_name in ipairs(chain) do
        config.route_name = route_name

        local route = route_load()
        local ok, failure = route_replay_loaded_route(route, route_name)

        if not ok then
            config.route_name = original_route_name
            return false, route_name, failure
        end
    end

    config.route_name = original_route_name
    return true, nil, nil
end

function mode_route_to()
    local start_node = config.route_start or ""
    local destination_node = config.route_destination or ""

    if start_node == "" then
        abort("route_start is empty.")
    end

    if destination_node == "" then
        abort("route_destination is empty.")
    end

    print("Route To: " .. start_node .. " -> " .. destination_node)

    local indexed_routes = route_load_index()
    local banned_routes = {}

    for attempt = 1, ROUTE_FAILOVER_MAX_ATTEMPTS do
        local chain, total_cost = route_find_chain(indexed_routes, start_node, destination_node, banned_routes)

        if not chain then
            abort(
                "No route chain found from " ..
                start_node ..
                " to " ..
                destination_node ..
                ". Banned routes: " ..
                route_banned_list(banned_routes)
            )
        end

        route_print_chain(
            "Found lowest-cost route chain attempt " .. tostring(attempt),
            chain,
            total_cost
        )

        local ok, failed_route, failure = route_run_chain(chain)

        if ok then
            print("Route To complete: " .. start_node .. " -> " .. destination_node)
            abort("Route To finished.")
        end

        banned_routes[failed_route] = true

        print_warn(
            "Route To failed on " ..
            tostring(failed_route) ..
            " (" .. tostring(failure and failure.reason or "unknown") .. ")."
        )
        print_warn("Banning failed route and trying another chain if one exists.")
    end

    abort(
        "Route To failover gave up after " ..
        tostring(ROUTE_FAILOVER_MAX_ATTEMPTS) ..
        " attempt(s). Banned routes: " ..
        route_banned_list(banned_routes)
    )
end
