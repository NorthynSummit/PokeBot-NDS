-----------------------------------------------------------------------------
-- nav_frontier.lua
-- Custom navigation module split from global.lua at v21.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Map Graph Frontier Report v0.1
-- Finds reachable graph nodes that still have untested directions. This is the
-- planning layer for auto-explore: travel to a frontier, scan/sweep there, then
-- rebuild the compact graph.
-----------------------------------------------------------------------------

function map_graph_frontier_path()
    return "user\\routes\\map_frontiers.txt"
end

function map_graph_direction_order()
    return { "Up", "Right", "Down", "Left" }
end

function map_graph_mark_known(frontier, node_key, dir, status)
    if not node_key or not dir or dir == "" then
        return
    end

    if not frontier.known[node_key] then
        frontier.known[node_key] = {}
    end

    -- Do not let a weaker observation overwrite a stronger one.
    -- walkable > transition > blocked > unknown for planning purposes.
    local current = frontier.known[node_key][dir]
    if current == "walkable" then
        return
    end
    if current == "transition" and status ~= "walkable" then
        return
    end
    if current == "blocked" and status ~= "walkable" and status ~= "transition" then
        return
    end

    frontier.known[node_key][dir] = status
end

function map_graph_load_frontier_data(allow_reverse)
    local graph = map_graph_load_for_travel(allow_reverse)
    local frontier = {
        graph = graph,
        known = {},
        blocked_count = 0,
        transition_count = 0,
        walkable_count = 0
    }

    local path = map_graph_path()
    local file = io.open(path, "r")
    if not file then
        abort("Could not open map graph file: " .. tostring(path) .. ". Run Map Graph Build first.")
    end

    for line in file:lines() do
        if string.sub(line, 1, 5) == "EDGE|" then
            local parts = map_graph_split_pipe(line)
            if #parts >= 12 then
                local from_node = map_graph_node_from_values(parts[2], parts[3], parts[4], parts[5], 0)
                local to_node = map_graph_node_from_values(parts[8], parts[9], parts[10], parts[11], 0)
                local dir = tostring(parts[6] or "")
                local result = tostring(parts[7] or "")

                if result == "walkable" then
                    map_graph_mark_known(frontier, from_node.key, dir, "walkable")
                    frontier.walkable_count = frontier.walkable_count + 1
                    if allow_reverse then
                        map_graph_mark_known(frontier, to_node.key, map_probe_opposite_direction(dir), "walkable")
                    end
                elseif result == "transition" then
                    map_graph_mark_known(frontier, from_node.key, dir, "transition")
                    frontier.transition_count = frontier.transition_count + 1
                end
            end
        elseif string.sub(line, 1, 8) == "BLOCKED|" then
            local parts = map_graph_split_pipe(line)
            if #parts >= 7 then
                local node = map_graph_node_from_values(parts[2], parts[3], parts[4], parts[5], 0)
                local dir = tostring(parts[6] or "")
                map_graph_mark_known(frontier, node.key, dir, "blocked")
                frontier.blocked_count = frontier.blocked_count + 1
            end
        end
    end

    file:close()
    return frontier
end

function map_graph_unknown_dirs_for_node(frontier, node)
    local unknown = {}
    local known = frontier.known[node.key] or {}

    for _, dir in ipairs(map_graph_direction_order()) do
        if not known[dir] then
            unknown[#unknown + 1] = dir
        end
    end

    return unknown
end

function map_graph_known_summary_for_node(frontier, node)
    local pieces = {}
    local known = frontier.known[node.key] or {}

    for _, dir in ipairs(map_graph_direction_order()) do
        local status = known[dir] or "unknown"
        pieces[#pieces + 1] = dir .. "=" .. status
    end

    return table.concat(pieces, ",")
end

function map_graph_path_preview(path, max_items)
    max_items = max_items or 10
    local pieces = {}

    for i, edge in ipairs(path or {}) do
        if i > max_items then
            pieces[#pieces + 1] = "..."
            break
        end
        pieces[#pieces + 1] = tostring(edge.dir) .. (edge.inferred_reverse and "*" or "")
    end

    if #pieces == 0 then
        return "already there"
    end

    return table.concat(pieces, " -> ")
end

function map_graph_frontier_find_candidates(frontier, start_node, max_path_steps, same_map_only)
    local candidates = {}
    local graph = frontier.graph

    for _, key in ipairs(graph.node_order or {}) do
        local node = graph.nodes[key]

        if node and (not same_map_only or tonumber(node.map) == tonumber(start_node.map)) then
            local unknown_dirs = map_graph_unknown_dirs_for_node(frontier, node)

            if #unknown_dirs > 0 then
                local path = nil
                local path_len = 0

                if key == start_node.key then
                    path = {}
                else
                    path = map_graph_find_path(graph, start_node.key, key, max_path_steps)
                end

                if path then
                    path_len = #path
                    candidates[#candidates + 1] = {
                        node = node,
                        unknown_dirs = unknown_dirs,
                        unknown_count = #unknown_dirs,
                        path = path,
                        path_len = path_len,
                        known_summary = map_graph_known_summary_for_node(frontier, node)
                    }
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.path_len ~= b.path_len then
            return a.path_len < b.path_len
        end
        if a.unknown_count ~= b.unknown_count then
            return a.unknown_count > b.unknown_count
        end
        if tonumber(a.node.z) ~= tonumber(b.node.z) then
            return tonumber(a.node.z) < tonumber(b.node.z)
        end
        return tonumber(a.node.x) < tonumber(b.node.x)
    end)

    return candidates
end

function map_graph_frontier_write_report(candidates, start_node, same_map_only)
    local path = map_graph_frontier_path()
    local file = io.open(path, "w")
    if not file then
        print("Could not write frontier report to " .. tostring(path))
        return nil, 0
    end

    local lines = {}
    lines[#lines + 1] = "# Pokebot map frontiers v0.1\n"
    lines[#lines + 1] = "# FRONTIER|rank|map_name|map|x|z|path_len|unknown_dirs|known_summary|path_preview\n"
    lines[#lines + 1] = "START|" .. map_graph_point_text(start_node) .. "\n"
    lines[#lines + 1] = "SAME_MAP_ONLY|" .. tostring(same_map_only == true) .. "\n"
    lines[#lines + 1] = "COUNT|" .. tostring(#candidates) .. "\n"

    for i, candidate in ipairs(candidates) do
        lines[#lines + 1] = "FRONTIER|" .. tostring(i) .. "|" ..
            map_graph_point_text(candidate.node) .. "|" ..
            tostring(candidate.path_len) .. "|" ..
            table.concat(candidate.unknown_dirs, ",") .. "|" ..
            tostring(candidate.known_summary) .. "|" ..
            map_graph_path_preview(candidate.path, 20) .. "\n"
    end

    local output = table.concat(lines, "")
    file:write(output)
    file:close()

    return path, #output
end

function mode_map_graph_frontier()
    perf_start("map_graph_frontier_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_graph_frontier: not in game.")
    end

    route_release_direction_buttons()

    local allow_reverse = map_graph_to_bool(config.map_graph_allow_reverse_edges, true)
    local max_path_steps = map_graph_travel_max_steps()
    local same_map_only = true

    print("Map Graph Frontier Report v0.1")
    print("Finds reachable graph nodes with untested directions. No movement is performed.")
    print("Allow inferred reverse walkable edges: " .. tostring(allow_reverse))
    print("Max path steps: " .. tostring(max_path_steps))
    print("Same-map frontiers only: " .. tostring(same_map_only))

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    perf_start("map_graph_frontier_load")
    local frontier = map_graph_load_frontier_data(allow_reverse)
    perf_stop("map_graph_frontier_load")

    local graph = frontier.graph
    print("Graph loaded: " .. tostring(#graph.node_order) .. " node(s), " .. tostring(graph.edge_count) .. " travel edge(s), " .. tostring(graph.reverse_edge_count) .. " inferred reverse edge(s).")
    print("Known observations: walkable=" .. tostring(frontier.walkable_count) .. ", transition=" .. tostring(frontier.transition_count) .. ", blocked=" .. tostring(frontier.blocked_count))

    local current_tile = map_graph_current_tile_point()
    local start_node, start_distance = map_graph_find_closest_node(graph, current_tile, 0.60)

    if not start_node then
        abort("Map Graph Frontier could not find a graph node near current tile " .. map_graph_node_label(current_tile) .. ". Run Map Sweep/Graph Build around this area first.")
    end

    print("Start node: " .. map_graph_node_label(start_node) .. " distance=" .. string.format("%.2f", start_distance or 0))

    perf_start("map_graph_frontier_find")
    local candidates = map_graph_frontier_find_candidates(frontier, start_node, max_path_steps, same_map_only)
    perf_stop("map_graph_frontier_find")

    print("Reachable frontier nodes: " .. tostring(#candidates))

    local show_count = math.min(#candidates, 10)
    for i = 1, show_count do
        local candidate = candidates[i]
        print(
            "Frontier " .. tostring(i) .. ": " .. map_graph_node_label(candidate.node) ..
            " | path=" .. tostring(candidate.path_len) ..
            " | unknown=" .. table.concat(candidate.unknown_dirs, ",") ..
            " | known={" .. tostring(candidate.known_summary) .. "}" ..
            " | path preview=" .. map_graph_path_preview(candidate.path, 10)
        )
    end

    local output_path, output_size = map_graph_frontier_write_report(candidates, start_node, same_map_only)
    if output_path then
        print("Map Graph Frontier wrote report to " .. tostring(output_path) .. " (" .. tostring(output_size) .. " bytes).")
    end

    if #candidates > 0 then
        local best = candidates[1]
        print("Closest frontier target: map " .. tostring(best.node.map) .. ", X " .. map_graph_coord_text(best.node.x) .. ", Z " .. map_graph_coord_text(best.node.z) .. ".")
        print("Use Map Graph To Destination for that tile, then run a small Map Sweep or Map Scan Line to test unknown directions there.")
    else
        print("No reachable same-map frontier nodes found inside the current graph. Scan a new area or allow cross-map transitions later.")
    end

    perf_stop("map_graph_frontier_total")
    abort("Map Graph Frontier finished.")
end
