-----------------------------------------------------------------------------
-- nav_probe.lua
-- Custom navigation module split from global.lua at v21.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Map Probe Lite Precise No-Write
-- Performance-safe first step toward generated map data.
-- Probes ONE direction, stops after roughly one tile, prints ONE result, then stops.
-- No file writes here: benchmark showed Lua file writes freeze DeSmuME.
-----------------------------------------------------------------------------

local MAP_PROBE_MAX_FRAMES = 18
local MAP_PROBE_HOLD_FRAMES = 18
local MAP_PROBE_TARGET_MOVE = 0.85
local MAP_PROBE_SETTLE_FRAMES = 2
local MAP_PROBE_MIN_MOVE = 0.35
MAP_PROBE_UNSAFE_JUMP = 8.0

function map_probe_edges_path()
    return "user\\routes\\map_probe_edges.txt"
end

function map_probe_get_direction()
    local dir = config.map_probe_direction or "Up"

    if dir == "Up" or dir == "Right" or dir == "Down" or dir == "Left" then
        return dir
    end

    print_warn("Bad map_probe_direction: " .. tostring(dir) .. ". Defaulting to Up.")
    return "Up"
end

function map_probe_current_point()
    return {
        name = tostring(game_state.map_name or ""),
        map = tonumber(game_state.map_header) or 0,
        x = tonumber(game_state.trainer_x) or 0,
        y = tonumber(game_state.trainer_y) or 0,
        z = tonumber(game_state.trainer_z) or 0
    }
end

function map_probe_same_map(a, b)
    if not a or not b then
        return false
    end

    if a.map == b.map then
        return true
    end

    if a.name and b.name and a.name ~= "" and b.name ~= "" then
        return a.name == b.name
    end

    return false
end

function map_probe_distance(a, b)
    if not a or not b then
        return 999999
    end

    return math.abs((a.x or 0) - (b.x or 0)) + math.abs((a.z or 0) - (b.z or 0))
end

function map_probe_point_text(point)
    return tostring(point.name or "") .. "|" ..
           tostring(point.map or "") .. "|" ..
           tostring(point.x or "") .. "|" ..
           tostring(point.z or "")
end

function map_probe_write_result(start_point, dir, result, end_point, note)
    -- Intentionally unused by mode_map_probe right now.
    -- Keep this helper for later batch-save/export mode.
    route_make_folder()

    local path = map_probe_edges_path()
    local file = io.open(path, "a")

    if not file then
        abort("Could not open map probe output file: " .. path)
    end

    file:write(
        map_probe_point_text(start_point) .. "|" ..
        tostring(dir) .. "|" ..
        tostring(result) .. "|" ..
        map_probe_point_text(end_point) .. "|" ..
        tostring(note or "") .. "\n"
    )

    file:close()
end

function map_probe_hold_direction(start_point, dir)
    -- Precise no-write probe:
    -- Check position each frame, but do NOT write files and do NOT use route/recovery logic.
    -- Stop after about one tile of movement or a short timeout.
    route_release_direction_buttons()
    wait_frames(1)

    hold_button(dir)

    for frame = 1, MAP_PROBE_MAX_FRAMES do
        process_frame()

        if game_state.in_battle then
            route_release_direction_buttons()
            return "battle"
        end

        local current = map_probe_current_point()

        if not map_probe_same_map(start_point, current) then
            route_release_direction_buttons()
            return "transition"
        end

        if map_probe_distance(start_point, current) >= MAP_PROBE_TARGET_MOVE then
            route_release_direction_buttons()
            return "target_reached"
        end
    end

    route_release_direction_buttons()
    return "timeout"
end

function mode_map_probe()
    if not game_state or not game_state.in_game then
        abort("Cannot run map_probe: not in game.")
    end

    local dir = map_probe_get_direction()
    local start_point = map_probe_current_point()

    print("Map Probe Lite Precise No-Write")
    print("Direction: " .. tostring(dir))
    print(
        "Start: " .. tostring(start_point.name) ..
        " | map " .. tostring(start_point.map) ..
        " | X " .. tostring(start_point.x) ..
        " | Z " .. tostring(start_point.z)
    )

    local stop_reason = map_probe_hold_direction(start_point, dir)
    wait_frames(MAP_PROBE_SETTLE_FRAMES)

    local end_point = map_probe_current_point()
    local moved = map_probe_distance(start_point, end_point)
    local result = "blocked"
    local note = "moved=" .. tostring(moved) .. ";stop=" .. tostring(stop_reason)

    if moved > MAP_PROBE_UNSAFE_JUMP then
        result = "unsafe_jump"
        note = note .. ";large_coordinate_jump"
    elseif not map_probe_same_map(start_point, end_point) then
        result = "transition"
        note = note .. ";map_changed"
    elseif moved >= MAP_PROBE_MIN_MOVE then
        result = "walkable"
    else
        result = "blocked"
    end

    print(
        "Result: " .. tostring(result) ..
        " | moved=" .. tostring(moved) ..
        " | stop=" .. tostring(stop_reason)
    )
    print(
        "End: " .. tostring(end_point.name) ..
        " | map " .. tostring(end_point.map) ..
        " | X " .. tostring(end_point.x) ..
        " | Z " .. tostring(end_point.z)
    )
    print("No file write was performed. Probe data will need batch saving later.")

    route_release_direction_buttons()
    abort("Map Probe finished without file write.")
end

-----------------------------------------------------------------------------
-- Map Probe Benchmark
-- Isolates probe slowdown: movement, reads, file writes, abort/shutdown.
-----------------------------------------------------------------------------

function map_probe_benchmark_path()
    return "user\\routes\\map_probe_benchmark.txt"
end

function map_probe_benchmark_get_test()
    local test = config.map_probe_benchmark_test or "move_only_abort"

    local valid = {
        shutdown_only = true,
        file_write_only = true,
        move_only_abort = true,
        move_read_abort = true,
        move_write_abort = true,
        move_idle_no_abort = true
    }

    if valid[test] then
        return test
    end

    print_warn("Bad map_probe_benchmark_test: " .. tostring(test) .. ". Defaulting to move_only_abort.")
    return "move_only_abort"
end

function map_probe_benchmark_write_line(label, start_point, end_point)
    route_make_folder()

    local path = map_probe_benchmark_path()
    local file = io.open(path, "a")

    if not file then
        abort("Could not open benchmark file: " .. path)
    end

    file:write(
        tostring(label) .. "|" ..
        map_probe_point_text(start_point or map_probe_current_point()) .. "|" ..
        map_probe_point_text(end_point or map_probe_current_point()) .. "\n"
    )

    file:close()
end

function map_probe_benchmark_move(dir)
    route_release_direction_buttons()
    wait_frames(2)

    hold_button(dir)
    wait_frames(MAP_PROBE_HOLD_FRAMES)
    route_release_direction_buttons()
    wait_frames(MAP_PROBE_SETTLE_FRAMES)
end

function mode_map_probe_benchmark()
    local test = map_probe_benchmark_get_test()
    local dir = map_probe_get_direction()

    print("Map Probe Benchmark")
    print("Test: " .. tostring(test))
    print("Direction: " .. tostring(dir))

    if test == "shutdown_only" then
        wait_frames(30)
        abort("Benchmark shutdown_only finished.")
    end

    if test == "file_write_only" then
        local point = map_probe_current_point()
        map_probe_benchmark_write_line("file_write_only", point, point)
        abort("Benchmark file_write_only finished.")
    end

    if not game_state or not game_state.in_game then
        abort("Cannot run movement benchmark: not in game.")
    end

    local start_point = map_probe_current_point()

    if test == "move_only_abort" then
        map_probe_benchmark_move(dir)
        abort("Benchmark move_only_abort finished.")
    end

    if test == "move_read_abort" then
        map_probe_benchmark_move(dir)
        local end_point = map_probe_current_point()
        print(
            "End: " .. tostring(end_point.name) ..
            " | map " .. tostring(end_point.map) ..
            " | X " .. tostring(end_point.x) ..
            " | Z " .. tostring(end_point.z)
        )
        abort("Benchmark move_read_abort finished.")
    end

    if test == "move_write_abort" then
        map_probe_benchmark_move(dir)
        local end_point = map_probe_current_point()
        map_probe_benchmark_write_line("move_write_abort", start_point, end_point)
        abort("Benchmark move_write_abort finished.")
    end

    if test == "move_idle_no_abort" then
        map_probe_benchmark_move(dir)
        print("Movement finished. Idling without abort. Stop the Lua script manually after checking for freeze.")
        while true do
            route_release_direction_buttons()
            process_frame()
        end
    end

    abort("Benchmark test not handled: " .. tostring(test))
end



-----------------------------------------------------------------------------
-- Lightweight performance timers
-- Enabled when config.debug is true, or when config.perf_debug is true.
-- Uses os.clock(), which is useful for Lua-side timing. If DeSmuME visually
-- stalls but os.clock() shows a tiny value, the delay is outside normal Lua CPU
-- time, usually emulator/file I/O blocking.
-----------------------------------------------------------------------------

local PERF_TIMERS = {}

function perf_enabled()
    if nav_developer_debug_enabled then
        return nav_developer_debug_enabled()
    end
    return config and config.perf_debug == true
end

function perf_now()
    return os.clock()
end

function perf_start(label)
    if not perf_enabled() then
        return
    end

    PERF_TIMERS[label] = perf_now()
end

function perf_stop(label)
    if not perf_enabled() then
        return 0
    end

    local start_time = PERF_TIMERS[label]

    if not start_time then
        print("[PERF] " .. tostring(label) .. " had no start time.")
        return 0
    end

    local elapsed = perf_now() - start_time
    PERF_TIMERS[label] = nil

    print("[PERF] " .. tostring(label) .. " took " .. string.format("%.3f", elapsed) .. "s")

    return elapsed
end

function perf_mark(label, start_time)
    if not perf_enabled() then
        return 0
    end

    local elapsed = perf_now() - start_time
    print("[PERF] " .. tostring(label) .. " at +" .. string.format("%.3f", elapsed) .. "s")
    return elapsed
end

-----------------------------------------------------------------------------
-- Map Probe Smooth Line Batch v0.8 Clean Save + Perf
-- Holds ONE selected direction continuously for smooth movement.
-- Records exact one-tile edges in memory.
-- Optional save writes the whole batch with one file:write() at the end.
-- No per-probe file writes and no per-frame logging.
-----------------------------------------------------------------------------

local MAP_PROBE_BATCH_STUCK_FRAMES = 30
local MAP_PROBE_BATCH_MOVE_EPSILON = 0.025
local MAP_PROBE_BATCH_TILE_SIZE = 1.0
local MAP_PROBE_BATCH_AXIS_TOLERANCE = 0.08
local MAP_PROBE_BATCH_MAX_FRAMES_PER_STEP = 75
local MAP_PROBE_BATCH_LOG_LIMIT = 12

-- Stable-turn tuning. These constants are intentionally conservative because
-- DeSmuME/HGSS can keep finishing the previous walking animation even after
-- input is released. Without this, the sweep tries to turn while the previous
-- Down/Up step is still resolving and the sidestep becomes a wrong-axis step.
local MAP_PROBE_FINAL_RELEASE_PROGRESS = 0.82
local MAP_PROBE_STABLE_MOVE_EPSILON = 0.012
local MAP_PROBE_STABLE_FRAMES = 8
local MAP_PROBE_STABLE_TIMEOUT = 90
local MAP_PROBE_TURN_SETTLE_FRAMES = 8

-- Strict sidestep tuning. The sidestep controller measures progress on the
-- requested sidestep axis, not just total distance. This prevents a leftover
-- Down/Up animation from being counted as a Left/Right sidestep.
local MAP_SWEEP_SIDESTEP_TARGET_PROGRESS = 0.62
local MAP_SWEEP_SIDESTEP_OVERSHOOT_PROGRESS = 1.35
local MAP_SWEEP_SIDESTEP_CROSS_DRIFT_LIMIT = 0.35
local MAP_SWEEP_SIDESTEP_TIMEOUT = 70

-- v15 sweep design: scan lines use the smooth cruise scanner again, but final
-- release overshoot is split into real one-tile edges instead of treated as a
-- fatal error. Sidesteps remain strict/verified because turns must be precise.
MAP_SWEEP_VERIFIED_STEP_RELEASE_PROGRESS = 0.62
MAP_SWEEP_VERIFIED_STEP_OVERSHOOT_PROGRESS = 1.35
MAP_SWEEP_VERIFIED_STEP_CROSS_DRIFT_LIMIT = 0.45
MAP_SWEEP_VERIFIED_STEP_TIMEOUT = 75
MAP_SWEEP_VERIFIED_STEP_SETTLE_FRAMES = 2

function map_probe_batch_get_steps()
    local steps = tonumber(config.map_probe_batch_steps) or 8

    if steps < 1 then
        steps = 1
    elseif steps > 50 then
        print_warn("map_probe_batch_steps capped at 50 for emulator responsiveness.")
        steps = 50
    end

    return steps
end

function map_probe_classify_result(start_point, end_point, stop_reason)
    local moved = map_probe_distance(start_point, end_point)
    local result = "blocked"
    local note = "moved=" .. tostring(moved) .. ";stop=" .. tostring(stop_reason)

    -- v33/v32 classification order: when battle is active, position values can
    -- briefly become invalid (for example X 0.5 / Z -0.5 in HGSS). Treat battle
    -- as battle first, not unsafe_jump or blocked. Transition still applies
    -- when there is no battle and the map actually changed.
    if stop_reason == "battle" or (game_state and game_state.in_battle) then
        result = "battle"
        note = note .. ";battle_detected=true;not_blocked;position_may_be_untrusted"
    elseif moved > MAP_PROBE_UNSAFE_JUMP then
        result = "unsafe_jump"
        note = note .. ";large_coordinate_jump"
    elseif not map_probe_same_map(start_point, end_point) then
        result = "transition"
        note = note .. ";map_changed"
    elseif moved >= MAP_PROBE_MIN_MOVE then
        result = "walkable"
    else
        result = "blocked"
    end

    return result, moved, note
end

function map_probe_batch_path()
    return "user\\routes\\map_probe_batch_edges.txt"
end

function map_scan_line_path()
    return "user\\routes\\map_scan_line_edges.txt"
end

function map_probe_write_results(results, output_path, output_label)
    perf_start("batch_save_total")

    -- Do not call route_make_folder() here. Benchmarking showed the Windows
    -- shell folder check was the 5-second freeze. These outputs live in
    -- user\routes, which should already exist once Map v1 is in use.
    local path = output_path or map_probe_batch_path()
    local label = output_label or "Batch"

    perf_start("batch_save_open_file")
    local file = io.open(path, "a")
    perf_stop("batch_save_open_file")

    if not file then
        abort("Could not open map probe output file: " .. path)
    end

    -- Important performance detail:
    -- Build one string and call file:write() once. Multiple Lua file writes caused
    -- noticeable DeSmuME pauses during benchmarking.
    perf_start("batch_save_build_string")
    local lines = {}

    for _, entry in ipairs(results) do
        lines[#lines + 1] =
            tostring(entry.step) .. "|" ..
            map_probe_point_text(entry.start_point) .. "|" ..
            tostring(entry.dir) .. "|" ..
            tostring(entry.result) .. "|" ..
            map_probe_point_text(entry.end_point) .. "|" ..
            tostring(entry.note or "") .. "\n"
    end

    local output = table.concat(lines, "")
    perf_stop("batch_save_build_string")

    if #output > 0 then
        perf_start("batch_save_file_write")
        file:write(output)
        perf_stop("batch_save_file_write")
    end

    perf_start("batch_save_file_close")
    file:close()
    perf_stop("batch_save_file_close")

    print(label .. " wrote " .. tostring(#results) .. " probe result(s) to " .. path .. " using one file write.")

    -- v31 normalized storage: keep the legacy TXT output, but also write
    -- deduped node/edge tables and send observations to the dashboard.
    if nav_storage_record_probe_results then
        local ok, err = pcall(nav_storage_record_probe_results, results, label, path)
        if not ok then
            print_warn("Navigation storage write failed but legacy TXT was saved: " .. tostring(err))
        end
    end

    perf_stop("batch_save_total")
end

-- Backwards-compatible wrapper for existing batch code.
function map_probe_batch_write_results(results)
    map_probe_write_results(results, map_probe_batch_path(), "Batch")
end

function map_probe_snap_value_to_tile_center(value)
    value = tonumber(value) or 0
    return math.floor(value) + 0.5
end

function map_probe_snap_to_tile_center(point)
    return {
        name = point.name,
        map = point.map,
        x = map_probe_snap_value_to_tile_center(point.x),
        y = tonumber(point.y or (game_state and game_state.trainer_y) or 0) or 0,
        z = map_probe_snap_value_to_tile_center(point.z)
    }
end

function map_probe_offset_tile(point, dir, amount)
    amount = amount or MAP_PROBE_BATCH_TILE_SIZE

    local next_point = {
        name = point.name,
        map = point.map,
        x = point.x,
        y = point.y,
        z = point.z
    }

    if dir == "Up" then
        next_point.z = next_point.z - amount
    elseif dir == "Down" then
        next_point.z = next_point.z + amount
    elseif dir == "Left" then
        next_point.x = next_point.x - amount
    elseif dir == "Right" then
        next_point.x = next_point.x + amount
    end

    return next_point
end

function map_probe_axis_reached(current, target, dir)
    if dir == "Up" then
        return current.z <= target.z + MAP_PROBE_BATCH_AXIS_TOLERANCE
    elseif dir == "Down" then
        return current.z >= target.z - MAP_PROBE_BATCH_AXIS_TOLERANCE
    elseif dir == "Left" then
        return current.x <= target.x + MAP_PROBE_BATCH_AXIS_TOLERANCE
    elseif dir == "Right" then
        return current.x >= target.x - MAP_PROBE_BATCH_AXIS_TOLERANCE
    end

    return false
end


-- Shared by nav_scan_sweep.lua and graph travel helpers. Do not keep this local.
-- Modular split note: scan/sweep creates probe edge entries too.

function map_probe_axis_progress(start_point, current_point, dir)
    if dir == "Up" then
        return (start_point.z or 0) - (current_point.z or 0)
    elseif dir == "Down" then
        return (current_point.z or 0) - (start_point.z or 0)
    elseif dir == "Left" then
        return (start_point.x or 0) - (current_point.x or 0)
    elseif dir == "Right" then
        return (current_point.x or 0) - (start_point.x or 0)
    end

    return 0
end

function map_probe_cross_drift(start_point, current_point, dir)
    if dir == "Up" or dir == "Down" then
        return math.abs((current_point.x or 0) - (start_point.x or 0))
    elseif dir == "Left" or dir == "Right" then
        return math.abs((current_point.z or 0) - (start_point.z or 0))
    end

    return 0
end

function map_probe_wait_until_position_stable(label)
    route_release_direction_buttons()

    local last = map_probe_current_point()
    local stable_frames = 0

    for frame = 1, MAP_PROBE_STABLE_TIMEOUT do
        process_frame()

        if game_state.in_battle then
            -- Do not sample a fresh overworld coordinate while the battle
            -- transition is active. HGSS can report temporary invalid coords.
            return last, "battle", frame
        end

        local current = map_probe_current_point()

        if map_probe_same_map(last, current) and map_probe_distance(last, current) <= MAP_PROBE_STABLE_MOVE_EPSILON then
            stable_frames = stable_frames + 1

            if stable_frames >= MAP_PROBE_STABLE_FRAMES then
                return current, "stable", frame
            end
        else
            stable_frames = 0
        end

        last = current
    end

    return map_probe_current_point(), "timeout", MAP_PROBE_STABLE_TIMEOUT
end

function map_probe_record_precise_final_step(results, step, dir, current_tile, stop_label)
    -- For the final tile before a turn/stop, do not keep holding until the exact
    -- center. Releasing slightly early lets the game finish the current tile.
    -- v15 improvement: if HGSS/DeSmuME still finishes one extra tile anyway,
    -- do not throw away the scan. Split the actual movement into clean one-tile
    -- edges, then let the turn/sidestep start from the true stable tile.
    route_release_direction_buttons()

    local stable_point, stable_reason, stable_frames = map_probe_wait_until_position_stable(stop_label or "final_line_stop")
    local stable_tile = map_probe_snap_to_tile_center(stable_point)
    local target_tile = map_probe_offset_tile(current_tile, dir, MAP_PROBE_BATCH_TILE_SIZE)

    local result = "partial"
    local moved = map_probe_distance(current_tile, stable_point)
    local note = "moved=" .. tostring(moved) ..
        ";stop=final_precise_release" ..
        ";stable=" .. tostring(stable_reason) ..
        ";stable_frames=" .. tostring(stable_frames) ..
        ";expected=" .. tostring(target_tile.x) .. "," .. tostring(target_tile.z) ..
        ";actual=" .. tostring(stable_tile.x) .. "," .. tostring(stable_tile.z)

    if stable_reason == "battle" then
        result = "battle"
    elseif not map_probe_same_map(current_tile, stable_point) then
        result = "transition"
        note = note .. ";map_changed"
    else
        local forward_delta = map_probe_axis_progress(current_tile, stable_tile, dir)
        local cross_delta = map_probe_cross_drift(current_tile, stable_tile, dir)

        note = note ..
            ";forward_delta=" .. string.format("%.2f", forward_delta) ..
            ";cross_delta=" .. string.format("%.2f", cross_delta)

        if forward_delta >= 1.35 and cross_delta <= 0.35 then
            local clean_steps = math.floor(forward_delta + 0.25)

            if clean_steps >= 2 and clean_steps <= 3 then
                for i = 1, clean_steps do
                    local from_tile = map_probe_offset_tile(current_tile, dir, i - 1)
                    local to_tile = map_probe_offset_tile(current_tile, dir, i)
                    local split_note = "moved=1;stop=final_release_split;stable=" .. tostring(stable_reason) ..
                        ";stable_frames=" .. tostring(stable_frames) ..
                        ";split=" .. tostring(i) .. "/" .. tostring(clean_steps) ..
                        ";actual_final=" .. tostring(stable_tile.x) .. "," .. tostring(stable_tile.z) ..
                        ";recorded_extra_tile_instead_of_failing_overshoot"
                    results[#results + 1] = map_probe_make_entry((step or 1) + i - 1, dir, from_tile, to_tile, "walkable", 1, split_note)
                end

                stable_tile = map_probe_offset_tile(current_tile, dir, clean_steps)
                return "walkable", stable_tile, stable_point, stable_reason
            else
                result = "overshoot"
                note = note .. ";queued_too_many_tiles"
            end
        elseif forward_delta >= 0.75 and forward_delta <= 1.25 and cross_delta <= 0.35 then
            result = "walkable"
            moved = 1
            stable_tile = target_tile
            note = note .. ";verified_final_tile"
        elseif forward_delta < 0.35 then
            result = "blocked"
            note = note .. ";did_not_complete_final_tile"
        else
            result = "partial"
            note = note .. ";final_tile_not_clean"
        end
    end

    results[#results + 1] = map_probe_make_entry(step, dir, current_tile, stable_tile, result, moved, note)

    return result, stable_tile, stable_point, stable_reason
end

map_probe_make_entry = function(step, dir, start_point, end_point, result, moved, note)
    return {
        step = step,
        dir = dir,
        start_point = start_point,
        end_point = end_point,
        result = result,
        moved = moved,
        note = note
    }
end

function map_probe_smooth_line_batch(dir, steps)
    local results = {}
    local step = 1
    local current_tile = map_probe_snap_to_tile_center(map_probe_current_point())
    local last_motion_point = map_probe_current_point()
    local stuck_frames = 0
    local segment_frames = 0
    local stop_reason = "finished"

    route_release_direction_buttons()
    wait_frames(1)

    while step <= steps do
        -- Important for DeSmuME: refresh the held direction every frame.
        -- Holding once can look like it works for the first tile, then silently stop.
        -- This is why v0.3 could move one tile and then report the clear path as blocked.
        hold_button(dir)

        if game_state.in_battle then
            stop_reason = "battle"
            break
        end

        local current = map_probe_current_point()

        if not map_probe_same_map(current_tile, current) then
            local result, moved, note = map_probe_classify_result(current_tile, current, "transition")
            results[#results + 1] = map_probe_make_entry(step, dir, current_tile, current, result, moved, note)
            stop_reason = "transition"
            break
        end

        if map_probe_distance(current_tile, current) > MAP_PROBE_UNSAFE_JUMP then
            local result, moved, note = map_probe_classify_result(current_tile, current, "unsafe_jump")
            results[#results + 1] = map_probe_make_entry(step, dir, current_tile, current, result, moved, note)
            stop_reason = "unsafe_jump"
            break
        end

        local moved_since_motion = map_probe_distance(last_motion_point, current)

        if moved_since_motion > MAP_PROBE_BATCH_MOVE_EPSILON then
            stuck_frames = 0
            last_motion_point = current
        else
            stuck_frames = stuck_frames + 1
        end

        segment_frames = segment_frames + 1

        local target_tile = map_probe_offset_tile(current_tile, dir, MAP_PROBE_BATCH_TILE_SIZE)

        if step == steps and map_probe_axis_progress(current_tile, current, dir) >= MAP_PROBE_FINAL_RELEASE_PROGRESS then
            local result, stable_tile, stable_point, stable_reason = map_probe_record_precise_final_step(results, step, dir, current_tile, "smooth_line_final_stop")

            if result == "walkable" then
                current_tile = stable_tile
                step = step + 1
                stop_reason = "finished"
            else
                stop_reason = result
            end

            break
        elseif map_probe_axis_reached(current, target_tile, dir) then
            -- Record a clean one-tile edge, not the fractional animation position.
            local result, moved, note = map_probe_classify_result(current_tile, target_tile, "tile_reached")
            results[#results + 1] = map_probe_make_entry(step, dir, current_tile, target_tile, result, moved, note)

            if result ~= "walkable" then
                stop_reason = result
                break
            end

            current_tile = target_tile
            last_motion_point = current
            stuck_frames = 0
            segment_frames = 0
            step = step + 1
        elseif stuck_frames >= MAP_PROBE_BATCH_STUCK_FRAMES or segment_frames >= MAP_PROBE_BATCH_MAX_FRAMES_PER_STEP then
            local reason = "blocked"

            if segment_frames >= MAP_PROBE_BATCH_MAX_FRAMES_PER_STEP then
                reason = "timeout"
            end

            local result, moved, note = map_probe_classify_result(current_tile, current, reason)

            -- If we did not reach the next tile, do not pretend a partial drift is
            -- a confirmed walkable edge.
            if result == "walkable" then
                result = "partial"
                note = note .. ";did_not_reach_next_tile"
            end

            results[#results + 1] = map_probe_make_entry(step, dir, current_tile, current, result, moved, note)
            stop_reason = reason
            break
        end
    end

    map_probe_wait_until_position_stable("smooth_line_return_settle")

    return results, stop_reason
end

function map_probe_print_batch_results(results, steps)
    if #results == 0 then
        print("No probe results were recorded.")
        return
    end

    local should_print_all = config.debug or #results <= MAP_PROBE_BATCH_LOG_LIMIT

    if should_print_all then
        for _, entry in ipairs(results) do
            print(
                "Step " .. tostring(entry.step) .. "/" .. tostring(steps) ..
                " | " .. tostring(entry.dir) ..
                " | " .. tostring(entry.result) ..
                " | moved=" .. tostring(entry.moved)
            )
        end
    else
        local first = results[1]
        local last = results[#results]

        print(
            "Recorded " .. tostring(#results) .. " probe edge(s). " ..
            "First=" .. tostring(first.result) ..
            ", Last=" .. tostring(last.result) ..
            ", Last moved=" .. tostring(last.moved) ..
            ". Enable debug to print every edge."
        )
    end
end

function mode_map_probe_batch()
    perf_start("map_probe_batch_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_probe_batch: not in game.")
    end

    perf_start("map_probe_batch_setup")
    local steps = map_probe_batch_get_steps()
    local dir = map_probe_get_direction()
    local save_batch = config.map_probe_batch_save == true
    perf_stop("map_probe_batch_setup")

    print("Map Probe Smooth Line Batch v0.8 Clean Save + Perf")
    print("Steps: " .. tostring(steps))
    print("Direction: " .. tostring(dir))
    print("Save batch: " .. tostring(save_batch))
    print("Holding one direction continuously and refreshing input every frame. No per-probe file writes. Edges are tile-centered in memory.")

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    perf_start("map_probe_batch_movement")
    local results, stop_reason = map_probe_smooth_line_batch(dir, steps)
    perf_stop("map_probe_batch_movement")

    perf_start("map_probe_batch_print_results")
    map_probe_print_batch_results(results, steps)
    print("Smooth line batch stop reason: " .. tostring(stop_reason))
    perf_stop("map_probe_batch_print_results")

    if save_batch then
        print("Saving batch results once at the end.")
        map_probe_batch_write_results(results)
    else
        print("Batch results were kept in memory only. Enable batch save later when you want to write them.")
    end

    perf_stop("map_probe_batch_total")

    abort("Map Probe Smooth Line Batch finished.")
end
