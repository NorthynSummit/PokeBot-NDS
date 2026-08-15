-----------------------------------------------------------------------------
-- nav_map_nodes.lua
-- Custom navigation module split from global.lua at v21.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Map Mark
-- Saves current location as a named map node.
-----------------------------------------------------------------------------

function map_nodes_path()
    return "user\\routes\\map_nodes.txt"
end

function map_get_node_name()
    if config.map_node_name and config.map_node_name ~= "" then
        return config.map_node_name
    end

    if config.route_destination and config.route_destination ~= "" then
        return config.route_destination
    end

    return "unnamed_node"
end

function map_mark_node()
    if not game_state or not game_state.in_game then
        abort("Cannot mark map node: not in game.")
    end

    route_make_folder()

    local node_name = map_get_node_name()
    local path = map_nodes_path()
    local file = io.open(path, "a")

    if not file then
        abort("Could not open map nodes file: " .. path)
    end

    local line =
        tostring(node_name) .. "|" ..
        tostring(game_state.map_name or "") .. "|" ..
        tostring(game_state.map_header) .. "|" ..
        tostring(game_state.trainer_x) .. "|" ..
        tostring(game_state.trainer_z)

    file:write(line .. "\n")
    file:close()

    print("Marked map node:")
    print("  Name: " .. tostring(node_name))
    print("  Map: " .. tostring(game_state.map_name))
    print("  Header: " .. tostring(game_state.map_header))
    print("  X: " .. tostring(game_state.trainer_x))
    print("  Z: " .. tostring(game_state.trainer_z))

    abort("Map node marked.")
end

function mode_map_mark()
    wait_frames(30)
    map_mark_node()
end

-----------------------------------------------------------------------------
-- Map To
-- Uses the nearest marked map node as the start, then travels to map_destination.
-----------------------------------------------------------------------------

function map_trim(value)
    if not value then
        return ""
    end

    return string.gsub(value, "^%s*(.-)%s*$", "%1")
end

function map_split_node_line(line)
    local parts = {}

    for part in string.gmatch(line, "([^|]+)") do
        parts[#parts + 1] = map_trim(part)
    end

    return parts
end

function map_load_nodes()
    local path = map_nodes_path()
    local file = io.open(path, "r")

    if not file then
        abort("Could not open map nodes file: " .. path)
    end

    local nodes = {}

    for line in file:lines() do
        line = map_trim(line)

        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local parts = map_split_node_line(line)

            if #parts >= 5 then
                nodes[#nodes + 1] = {
                    name = parts[1],
                    map_name = parts[2],
                    map = tonumber(parts[3]),
                    x = tonumber(parts[4]),
                    z = tonumber(parts[5])
                }
            else
                print_warn("Bad map node line: " .. line)
            end
        end
    end

    file:close()

    if #nodes == 0 then
        abort("No usable map nodes found in " .. path)
    end

    print("Loaded " .. tostring(#nodes) .. " map nodes.")
    return nodes
end

function map_same_map(node)
    if not game_state or not game_state.in_game then
        return false
    end

    if game_state.map_header == node.map then
        return true
    end

    if node.map_name and node.map_name ~= "" and game_state.map_name then
        return tostring(game_state.map_name) == tostring(node.map_name)
    end

    return false
end

function map_distance_to_node(node)
    if not map_same_map(node) then
        return 999999
    end

    return math.abs(node.x - game_state.trainer_x) +
           math.abs(node.z - game_state.trainer_z)
end

function map_find_nearest_node(nodes)
    local best_node = nil
    local best_distance = 999999

    for _, node in ipairs(nodes) do
        local distance = map_distance_to_node(node)

        if distance < best_distance then
            best_distance = distance
            best_node = node
        end
    end

    if not best_node or best_distance >= 999999 then
        abort(
            "Could not find a nearby map node on current map: " ..
            tostring(game_state.map_name) ..
            " / " ..
            tostring(game_state.map_header)
        )
    end

    print(
        "Nearest map node is " ..
        tostring(best_node.name) ..
        " at distance " ..
        tostring(best_distance)
    )

    return best_node, best_distance
end

function map_get_destination_name()
    if config.map_destination and config.map_destination ~= "" then
        return config.map_destination
    end

    if config.route_destination and config.route_destination ~= "" then
        return config.route_destination
    end

    return ""
end

function mode_map_to()
    if not game_state or not game_state.in_game then
        wait_frames(30)
    end

    local destination_node = map_get_destination_name()

    if destination_node == "" then
        abort("map_destination is empty.")
    end

    local nodes = map_load_nodes()
    local indexed_routes = route_load_index()
    local banned_routes = {}
    local last_start_node = nil

    for attempt = 1, ROUTE_FAILOVER_MAX_ATTEMPTS do
        local nearest_node, distance = map_find_nearest_node(nodes)
        last_start_node = nearest_node.name

        if distance > 6 then
            print_warn(
                "Nearest node is " ..
                tostring(distance) ..
                " tiles away. Start closer to a marked node if routing looks weird."
            )
        end

        print(
            "Map To attempt " ..
            tostring(attempt) ..
            ": " ..
            tostring(nearest_node.name) ..
            " -> " ..
            tostring(destination_node)
        )

        local chain, total_cost = route_find_chain(indexed_routes, nearest_node.name, destination_node, banned_routes)

        if not chain then
            route_release_direction_buttons()
            abort(
                "No map route chain found from " ..
                nearest_node.name ..
                " to " ..
                destination_node ..
                ". Banned routes: " ..
                route_banned_list(banned_routes)
            )
        end

        route_print_chain(
            "Found lowest-cost map route attempt " .. tostring(attempt),
            chain,
            total_cost
        )

        local ok, failed_route, failure = route_run_chain(chain)

        if ok then
            route_release_direction_buttons()
            print("Map To complete: " .. nearest_node.name .. " -> " .. destination_node)
            abort("Map To finished.")
        end

        banned_routes[failed_route] = true

        print_warn(
            "Map route failed on " ..
            tostring(failed_route) ..
            " (" .. tostring(failure and failure.reason or "unknown") .. ")."
        )
        print_warn("Banning failed route and recalculating from nearest marked node.")
        wait_frames(15)
    end

    route_release_direction_buttons()
    abort(
        "Map To failover gave up after " ..
        tostring(ROUTE_FAILOVER_MAX_ATTEMPTS) ..
        " attempt(s) from around " ..
        tostring(last_start_node) ..
        " to " ..
        tostring(destination_node) ..
        ". Banned routes: " ..
        route_banned_list(banned_routes)
    )
end
