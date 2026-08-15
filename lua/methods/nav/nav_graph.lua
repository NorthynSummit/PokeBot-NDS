-----------------------------------------------------------------------------
-- nav_graph.lua
-- Custom navigation module split from global.lua at v21.
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- Map Graph Build v0.1
-- Compacts raw probe/scan/sweep edge logs into one deduped graph file.
-- This is the scalable layer: raw logs are temporary/debug data; map_graph.txt
-- becomes the compact source for future pathfinding.
-----------------------------------------------------------------------------

function map_graph_path()
    return "user\\routes\\map_graph.txt"
end

function map_graph_raw_paths()
    return {
        map_sweep_path(),
        map_scan_line_path(),
        map_probe_batch_path()
    }
end

function map_graph_split_pipe(line)
    local parts = {}

    for part in string.gmatch(tostring(line or "") .. "|", "(.-)|") do
        parts[#parts + 1] = part
    end

    return parts
end

function map_graph_coord_text(value)
    local number_value = tonumber(value) or 0
    return string.format("%.1f", number_value)
end

function map_graph_point_key(point)
    return tostring(point.name or "") .. "|" ..
           tostring(point.map or "") .. "|" ..
           map_graph_coord_text(point.x) .. "|" ..
           map_graph_coord_text(point.z)
end

function map_graph_point_text(point)
    return tostring(point.name or "") .. "|" ..
           tostring(point.map or "") .. "|" ..
           map_graph_coord_text(point.x) .. "|" ..
           map_graph_coord_text(point.z)
end

function map_graph_parse_edge_line(line, source_path, line_number)
    if not line or line == "" then
        return nil, "blank"
    end

    if string.sub(line, 1, 1) == "#" then
        return nil, "comment"
    end

    local parts = map_graph_split_pipe(line)

    if #parts < 12 then
        return nil, "bad_field_count"
    end

    local note_parts = {}
    for i = 12, #parts do
        note_parts[#note_parts + 1] = parts[i]
    end

    return {
        source_path = source_path,
        line_number = line_number,
        step = tonumber(parts[1]) or 0,
        start_point = {
            name = tostring(parts[2] or ""),
            map = tonumber(parts[3]) or 0,
            x = tonumber(parts[4]) or 0,
            z = tonumber(parts[5]) or 0
        },
        dir = tostring(parts[6] or ""),
        result = tostring(parts[7] or ""),
        end_point = {
            name = tostring(parts[8] or ""),
            map = tonumber(parts[9]) or 0,
            x = tonumber(parts[10]) or 0,
            z = tonumber(parts[11]) or 0
        },
        note = table.concat(note_parts, "|")
    }, nil
end

function map_graph_sorted_keys(table_value)
    local keys = {}

    for key, _ in pairs(table_value) do
        keys[#keys + 1] = key
    end

    table.sort(keys)
    return keys
end

function map_graph_add_node(nodes, point)
    local key = map_graph_point_key(point)

    if not nodes[key] then
        nodes[key] = {
            key = key,
            name = tostring(point.name or ""),
            map = tonumber(point.map) or 0,
            x = tonumber(point.x) or 0,
            z = tonumber(point.z) or 0,
            count = 0
        }
    end

    nodes[key].count = nodes[key].count + 1
    return key
end

function map_graph_add_edge(edges, start_key, dir, result, end_key, source_path)
    local key = start_key .. "|" .. tostring(dir) .. "|" .. tostring(result) .. "|" .. end_key

    if not edges[key] then
        edges[key] = {
            key = key,
            start_key = start_key,
            dir = tostring(dir),
            result = tostring(result),
            end_key = end_key,
            count = 0,
            sources = {}
        }
    end

    edges[key].count = edges[key].count + 1
    edges[key].sources[tostring(source_path or "unknown")] = true
end

function map_graph_add_blocked(blocked, start_key, dir, source_path)
    local key = start_key .. "|" .. tostring(dir)

    if not blocked[key] then
        blocked[key] = {
            key = key,
            start_key = start_key,
            dir = tostring(dir),
            count = 0,
            sources = {}
        }
    end

    blocked[key].count = blocked[key].count + 1
    blocked[key].sources[tostring(source_path or "unknown")] = true
end

function map_graph_source_text(source_table)
    local sources = {}

    for source, _ in pairs(source_table or {}) do
        sources[#sources + 1] = source
    end

    table.sort(sources)
    return table.concat(sources, ",")
end

function map_graph_build_from_raw()
    local nodes = {}
    local edges = {}
    local blocked = {}
    local stats = {
        raw_lines = 0,
        parsed_lines = 0,
        walkable_edges = 0,
        transition_edges = 0,
        blocked_edges = 0,
        duplicate_edges = 0,
        ignored_lines = 0,
        missing_files = 0
    }

    local raw_paths = map_graph_raw_paths()

    for _, path in ipairs(raw_paths) do
        local file = io.open(path, "r")

        if not file then
            stats.missing_files = stats.missing_files + 1
        else
            local line_number = 0

            for line in file:lines() do
                line_number = line_number + 1
                stats.raw_lines = stats.raw_lines + 1

                local entry, parse_error = map_graph_parse_edge_line(line, path, line_number)

                if not entry then
                    if parse_error ~= "blank" and parse_error ~= "comment" then
                        stats.ignored_lines = stats.ignored_lines + 1
                    end
                else
                    stats.parsed_lines = stats.parsed_lines + 1

                    local start_key = map_graph_add_node(nodes, entry.start_point)

                    if entry.result == "walkable" or entry.result == "transition" then
                        local end_key = map_graph_add_node(nodes, entry.end_point)
                        local before_count = edges[start_key .. "|" .. tostring(entry.dir) .. "|" .. tostring(entry.result) .. "|" .. end_key]

                        map_graph_add_edge(edges, start_key, entry.dir, entry.result, end_key, path)

                        if before_count then
                            stats.duplicate_edges = stats.duplicate_edges + 1
                        elseif entry.result == "transition" then
                            stats.transition_edges = stats.transition_edges + 1
                        else
                            stats.walkable_edges = stats.walkable_edges + 1
                        end
                    elseif entry.result == "blocked" then
                        map_graph_add_blocked(blocked, start_key, entry.dir, path)
                        stats.blocked_edges = stats.blocked_edges + 1
                    else
                        stats.ignored_lines = stats.ignored_lines + 1
                    end
                end
            end

            file:close()
        end
    end

    return nodes, edges, blocked, stats
end

function map_graph_write(nodes, edges, blocked, stats)
    perf_start("map_graph_write_total")

    local path = map_graph_path()

    perf_start("map_graph_open_file")
    local file = io.open(path, "w")
    perf_stop("map_graph_open_file")

    if not file then
        abort("Could not open map graph output file: " .. path)
    end

    perf_start("map_graph_build_string")
    local lines = {}

    lines[#lines + 1] = "# Pokebot map graph v0.1\n"
    lines[#lines + 1] = "# Compact generated graph. Raw probe/sweep logs can be treated as temporary/debug data.\n"
    lines[#lines + 1] = "STATS|raw_lines|" .. tostring(stats.raw_lines) .. "\n"
    lines[#lines + 1] = "STATS|parsed_lines|" .. tostring(stats.parsed_lines) .. "\n"
    lines[#lines + 1] = "STATS|nodes|" .. tostring(#map_graph_sorted_keys(nodes)) .. "\n"
    lines[#lines + 1] = "STATS|edges|" .. tostring(#map_graph_sorted_keys(edges)) .. "\n"
    lines[#lines + 1] = "STATS|blocked|" .. tostring(#map_graph_sorted_keys(blocked)) .. "\n"
    lines[#lines + 1] = "STATS|walkable_edges|" .. tostring(stats.walkable_edges) .. "\n"
    lines[#lines + 1] = "STATS|transition_edges|" .. tostring(stats.transition_edges) .. "\n"
    lines[#lines + 1] = "STATS|duplicate_edges|" .. tostring(stats.duplicate_edges) .. "\n"
    lines[#lines + 1] = "STATS|ignored_lines|" .. tostring(stats.ignored_lines) .. "\n"
    lines[#lines + 1] = "STATS|missing_files|" .. tostring(stats.missing_files) .. "\n"

    lines[#lines + 1] = "# NODE|name|map|x|z|seen_count\n"
    for _, key in ipairs(map_graph_sorted_keys(nodes)) do
        local node = nodes[key]
        lines[#lines + 1] = "NODE|" ..
            tostring(node.name) .. "|" ..
            tostring(node.map) .. "|" ..
            map_graph_coord_text(node.x) .. "|" ..
            map_graph_coord_text(node.z) .. "|" ..
            tostring(node.count) .. "\n"
    end

    lines[#lines + 1] = "# EDGE|start_name|start_map|start_x|start_z|dir|result|end_name|end_map|end_x|end_z|seen_count|sources\n"
    for _, key in ipairs(map_graph_sorted_keys(edges)) do
        local edge = edges[key]
        local start_node = nodes[edge.start_key]
        local end_node = nodes[edge.end_key]

        lines[#lines + 1] = "EDGE|" ..
            map_graph_point_text(start_node) .. "|" ..
            tostring(edge.dir) .. "|" ..
            tostring(edge.result) .. "|" ..
            map_graph_point_text(end_node) .. "|" ..
            tostring(edge.count) .. "|" ..
            map_graph_source_text(edge.sources) .. "\n"
    end

    lines[#lines + 1] = "# BLOCKED|start_name|start_map|start_x|start_z|dir|seen_count|sources\n"
    for _, key in ipairs(map_graph_sorted_keys(blocked)) do
        local blocked_edge = blocked[key]
        local start_node = nodes[blocked_edge.start_key]

        lines[#lines + 1] = "BLOCKED|" ..
            map_graph_point_text(start_node) .. "|" ..
            tostring(blocked_edge.dir) .. "|" ..
            tostring(blocked_edge.count) .. "|" ..
            map_graph_source_text(blocked_edge.sources) .. "\n"
    end

    local output = table.concat(lines, "")
    perf_stop("map_graph_build_string")

    perf_start("map_graph_file_write")
    file:write(output)
    perf_stop("map_graph_file_write")

    perf_start("map_graph_file_close")
    file:close()
    perf_stop("map_graph_file_close")

    perf_stop("map_graph_write_total")

    return path, #output
end

function mode_map_graph_build()
    perf_start("map_graph_build_total")

    print("Map Graph Build v0.1")
    print("Reading raw edge files, deduplicating walkable/transition edges, and writing one compact graph file.")

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    perf_start("map_graph_read_raw")
    local nodes, edges, blocked, stats = map_graph_build_from_raw()
    perf_stop("map_graph_read_raw")

    local node_count = #map_graph_sorted_keys(nodes)
    local edge_count = #map_graph_sorted_keys(edges)
    local blocked_count = #map_graph_sorted_keys(blocked)

    print("Raw lines read: " .. tostring(stats.raw_lines))
    print("Parsed lines: " .. tostring(stats.parsed_lines))
    print("Graph nodes: " .. tostring(node_count))
    print("Graph edges: " .. tostring(edge_count) .. " directed edge(s)")
    print("Blocked attempts: " .. tostring(blocked_count))
    print("Duplicate raw edges compacted: " .. tostring(stats.duplicate_edges))
    print("Ignored lines: " .. tostring(stats.ignored_lines))

    local output_path, output_size = map_graph_write(nodes, edges, blocked, stats)

    print("Map Graph wrote compact graph to " .. tostring(output_path) .. " (" .. tostring(output_size) .. " bytes).")
    print("This graph is the file future graph travel/pathfinding should use instead of raw sweep logs.")

    perf_stop("map_graph_build_total")

    abort("Map Graph Build finished.")
end


-----------------------------------------------------------------------------
-- Map Graph Travel v0.1
-- Pathfinds over user\routes\map_graph.txt and walks graph edges with the
-- verified one-tile engine. This is intentionally strict for v0 so we prove
-- graph correctness before adding compressed cruise movement.
-----------------------------------------------------------------------------

function map_graph_to_bool(value, default_value)
    if value == nil then
        return default_value
    end

    return value == true or value == "true" or value == 1 or value == "1" or value == "on"
end

function map_graph_node_from_values(name, map, x, z, count)
    local node = {
        name = tostring(name or ""),
        map = tonumber(map) or 0,
        x = tonumber(x) or 0,
        z = tonumber(z) or 0,
        count = tonumber(count) or 0
    }

    node.key = map_graph_point_key(node)
    return node
end

function map_graph_node_label(node)
    if not node then
        return "nil"
    end

    return tostring(node.name) .. " map " .. tostring(node.map) ..
        " X " .. map_graph_coord_text(node.x) ..
        " Z " .. map_graph_coord_text(node.z)
end

function map_graph_points_match(a, b, tolerance)
    tolerance = tolerance or 0.35

    if not a or not b then
        return false
    end

    if tonumber(a.map) ~= tonumber(b.map) then
        return false
    end

    return math.abs((tonumber(a.x) or 0) - (tonumber(b.x) or 0)) <= tolerance and
           math.abs((tonumber(a.z) or 0) - (tonumber(b.z) or 0)) <= tolerance
end

function map_graph_distance(a, b)
    if not a or not b then
        return 999999
    end

    if tonumber(a.map) ~= tonumber(b.map) then
        return 999999
    end

    local dx = (tonumber(a.x) or 0) - (tonumber(b.x) or 0)
    local dz = (tonumber(a.z) or 0) - (tonumber(b.z) or 0)
    return math.sqrt(dx * dx + dz * dz)
end

function map_graph_add_loaded_node(graph, node)
    if not node or not node.key then
        return nil
    end

    if not graph.nodes[node.key] then
        graph.nodes[node.key] = node
        graph.node_order[#graph.node_order + 1] = node.key
    else
        graph.nodes[node.key].count = math.max(tonumber(graph.nodes[node.key].count) or 0, tonumber(node.count) or 0)
    end

    return graph.nodes[node.key]
end

function map_graph_add_loaded_edge(graph, from_node, to_node, dir, result, seen_count, inferred_reverse)
    if not from_node or not to_node then
        return
    end

    if result ~= "walkable" and result ~= "transition" then
        return
    end

    local edge = {
        from_key = from_node.key,
        to_key = to_node.key,
        from_node = from_node,
        to_node = to_node,
        dir = tostring(dir or ""),
        result = tostring(result or ""),
        count = tonumber(seen_count) or 0,
        inferred_reverse = inferred_reverse == true
    }

    if not graph.adj[edge.from_key] then
        graph.adj[edge.from_key] = {}
    end

    -- Dedupe in memory so a directed edge plus an inferred edge do not explode the path graph.
    local edge_key = edge.from_key .. "|" .. edge.dir .. "|" .. edge.result .. "|" .. edge.to_key
    if graph.edge_seen[edge_key] then
        return
    end

    graph.edge_seen[edge_key] = true
    graph.adj[edge.from_key][#graph.adj[edge.from_key] + 1] = edge
    graph.edge_count = graph.edge_count + 1
end

function map_graph_load_for_travel(allow_reverse)
    local path = map_graph_path()
    local file = io.open(path, "r")

    if not file then
        abort("Could not open map graph file: " .. tostring(path) .. ". Run Map Graph Build first.")
    end

    local graph = {
        nodes = {},
        node_order = {},
        adj = {},
        edge_seen = {},
        edge_count = 0,
        raw_edge_count = 0,
        reverse_edge_count = 0
    }

    local line_number = 0
    for line in file:lines() do
        line_number = line_number + 1

        if string.sub(line, 1, 5) == "NODE|" then
            local parts = map_graph_split_pipe(line)
            -- NODE|name|map|x|z|seen_count
            if #parts >= 6 then
                map_graph_add_loaded_node(graph, map_graph_node_from_values(parts[2], parts[3], parts[4], parts[5], parts[6]))
            end
        elseif string.sub(line, 1, 5) == "EDGE|" then
            local parts = map_graph_split_pipe(line)
            -- EDGE|start_name|start_map|start_x|start_z|dir|result|end_name|end_map|end_x|end_z|seen_count|sources
            if #parts >= 12 then
                local from_node = map_graph_add_loaded_node(graph, map_graph_node_from_values(parts[2], parts[3], parts[4], parts[5], 0))
                local to_node = map_graph_add_loaded_node(graph, map_graph_node_from_values(parts[8], parts[9], parts[10], parts[11], 0))
                local dir = tostring(parts[6] or "")
                local result = tostring(parts[7] or "")
                local seen_count = tonumber(parts[12]) or 0

                if result == "walkable" then
                    map_graph_add_loaded_edge(graph, from_node, to_node, dir, result, seen_count, false)
                    graph.raw_edge_count = graph.raw_edge_count + 1

                    if allow_reverse then
                        map_graph_add_loaded_edge(graph, to_node, from_node, map_probe_opposite_direction(dir), result, seen_count, true)
                        graph.reverse_edge_count = graph.reverse_edge_count + 1
                    end
                elseif result == "transition" then
                    -- Keep transition edges in the loaded graph for awareness, but v0 travel will not path through them.
                    -- Transition execution needs map-specific handling and should be tested separately.
                end
            end
        end
    end

    file:close()
    return graph
end

function map_graph_find_closest_node(graph, point, max_distance)
    local best_node = nil
    local best_distance = 999999

    for _, key in ipairs(graph.node_order or {}) do
        local node = graph.nodes[key]
        local distance = map_graph_distance(node, point)

        if distance < best_distance then
            best_node = node
            best_distance = distance
        end
    end

    if best_node and (not max_distance or best_distance <= max_distance) then
        return best_node, best_distance
    end

    return nil, best_distance
end

function map_graph_current_tile_point()
    local raw = map_probe_current_point()
    return map_probe_snap_to_tile_center(raw)
end

function map_graph_get_target_point(current_tile)
    local target_map = tonumber(config.map_graph_target_map)
    local target_x = tonumber(config.map_graph_target_x)
    local target_z = tonumber(config.map_graph_target_z)

    if not target_map or target_map == 0 then
        target_map = tonumber(current_tile.map) or 0
    end

    if not target_x or not target_z then
        abort("Map Graph To needs target X and target Z. Example for this graph: X 359.5, Z 384.5.")
    end

    return {
        name = tostring(config.map_graph_target_name or current_tile.name or ""),
        map = target_map,
        x = target_x,
        z = target_z
    }
end

function map_graph_find_path(graph, start_key, target_key, max_steps)
    max_steps = max_steps or 100

    local queue = { start_key }
    local head = 1
    local visited = {}
    local previous_key = {}
    local previous_edge = {}
    visited[start_key] = true

    while head <= #queue do
        local current_key = queue[head]
        head = head + 1

        if current_key == target_key then
            break
        end

        local current_depth = 0
        local walk_key = current_key
        while previous_key[walk_key] do
            current_depth = current_depth + 1
            walk_key = previous_key[walk_key]
        end

        if current_depth < max_steps then
            for _, edge in ipairs(graph.adj[current_key] or {}) do
                if edge.result == "walkable" and not visited[edge.to_key] then
                    visited[edge.to_key] = true
                    previous_key[edge.to_key] = current_key
                    previous_edge[edge.to_key] = edge
                    queue[#queue + 1] = edge.to_key
                end
            end
        end
    end

    if not visited[target_key] then
        return nil
    end

    local path = {}
    local key = target_key

    while key ~= start_key do
        local edge = previous_edge[key]
        if not edge then
            return nil
        end

        table.insert(path, 1, edge)
        key = previous_key[key]
    end

    return path
end

function map_graph_travel_max_steps()
    local value = tonumber(config.map_graph_max_path_steps) or 50

    if value < 1 then
        value = 1
    elseif value > 200 then
        value = 200
    end

    return value
end

function map_graph_verify_current_node(expected_node, label)
    local current_tile = map_graph_current_tile_point()

    if not map_graph_points_match(current_tile, expected_node, 0.40) then
        abort(
            "Map Graph To stopped: current tile mismatch before " .. tostring(label or "step") ..
            ". Expected " .. map_graph_node_label(expected_node) ..
            ", actual " .. map_graph_node_label(current_tile) .. "."
        )
    end

    return current_tile
end


function map_graph_compress_path_runs(path)
    local runs = {}

    if not path or #path == 0 then
        return runs
    end

    local current = nil

    for i, edge in ipairs(path) do
        local can_extend = false

        if current and
           current.dir == edge.dir and
           current.result == edge.result and
           current.end_index + 1 == i then
            -- Only compress physically continuous same-direction walkable edges.
            -- Do not compress transitions or anything cross-map.
            local previous_edge = path[i - 1]
            if previous_edge and
               previous_edge.to_key == edge.from_key and
               tonumber(previous_edge.to_node.map) == tonumber(edge.to_node.map) and
               edge.result == "walkable" then
                can_extend = true
            end
        end

        if can_extend then
            current.end_index = i
            current.count = current.count + 1
        else
            current = {
                start_index = i,
                end_index = i,
                dir = edge.dir,
                result = edge.result,
                count = 1
            }
            runs[#runs + 1] = current
        end
    end

    return runs
end

function map_graph_run_preview(runs)
    local pieces = {}

    for i, run in ipairs(runs or {}) do
        if i > 8 then
            pieces[#pieces + 1] = "..."
            break
        end

        pieces[#pieces + 1] = tostring(run.dir) .. " x" .. tostring(run.count)
    end

    return table.concat(pieces, " -> ")
end

function map_graph_count_walkable_results(results)
    local count = 0
    local first_bad = nil

    for _, entry in ipairs(results or {}) do
        if entry.result == "walkable" then
            count = count + 1
        else
            first_bad = entry
            break
        end
    end

    return count, first_bad
end

function map_graph_walk_single_edge(edge, step_label)
    print(
        tostring(step_label or "Graph step") ..
        " | " .. tostring(edge.dir) .. (edge.inferred_reverse and " inferred_reverse" or "") ..
        " | to " .. map_graph_node_label(edge.to_node)
    )

    local step_results, step_stop_reason, entry = map_sweep_verified_tile_step(edge.dir, 1, "graph_travel")

    if not entry then
        abort("Map Graph To failed: no movement entry for " .. tostring(step_label or "graph step") .. ".")
    end

    if entry.result ~= "walkable" then
        abort("Map Graph To failed at " .. tostring(step_label or "graph step") .. ": result=" .. tostring(entry.result) .. ", stop=" .. tostring(step_stop_reason) .. ", note=" .. tostring(entry.note or ""))
    end

    local actual_tile = map_graph_current_tile_point()
    if not map_graph_points_match(actual_tile, edge.to_node, 0.45) then
        abort(
            "Map Graph To failed after " .. tostring(step_label or "graph step") ..
            ": expected " .. map_graph_node_label(edge.to_node) ..
            ", actual " .. map_graph_node_label(actual_tile) .. "."
        )
    end
end

function map_graph_walk_compressed_run(path, run)
    local start_edge = path[run.start_index]
    local end_edge = path[run.end_index]

    map_graph_verify_current_node(start_edge.from_node, "compressed run " .. tostring(run.start_index) .. " start")

    print(
        "Graph run " .. tostring(run.start_index) .. "-" .. tostring(run.end_index) ..
        " | " .. tostring(run.dir) .. " x" .. tostring(run.count) ..
        " | from " .. map_graph_node_label(start_edge.from_node) ..
        " | to " .. map_graph_node_label(end_edge.to_node)
    )

    -- Small runs are not worth cruising. Verified one-tile stepping is more exact.
    if run.count <= 2 then
        for i = run.start_index, run.end_index do
            map_graph_verify_current_node(path[i].from_node, "graph step " .. tostring(i))
            map_graph_walk_single_edge(path[i], "Graph step " .. tostring(i) .. "/" .. tostring(#path))
        end
        return
    end

    -- Cruise most of the run, but intentionally request one fewer step.
    -- HGSS often finishes one extra tile after release. If it does, that lands
    -- exactly on the graph run target. If it does not, verified steps finish the rest.
    local cruise_target = run.count - 1
    local moved_by_cruise = 0

    if cruise_target > 0 then
        print("  cruise " .. tostring(run.dir) .. " target=" .. tostring(cruise_target) .. " tile(s), then verify remainder")
        local cruise_results, cruise_stop_reason = map_probe_smooth_line_batch(run.dir, cruise_target)
        moved_by_cruise = map_graph_count_walkable_results(cruise_results)
        local _, first_bad = map_graph_count_walkable_results(cruise_results)

        print("  cruise result: edges=" .. tostring(#cruise_results) .. ", walkable=" .. tostring(moved_by_cruise) .. ", stop=" .. tostring(cruise_stop_reason))

        if first_bad then
            abort("Map Graph To cruise failed in run " .. tostring(run.start_index) .. "-" .. tostring(run.end_index) .. ": result=" .. tostring(first_bad.result) .. ", note=" .. tostring(first_bad.note or ""))
        end

        if moved_by_cruise > run.count then
            abort("Map Graph To cruise overshot run " .. tostring(run.start_index) .. "-" .. tostring(run.end_index) .. ": moved " .. tostring(moved_by_cruise) .. " but run has " .. tostring(run.count) .. " edge(s).")
        end

        if moved_by_cruise > 0 then
            local expected_after_cruise = path[run.start_index + moved_by_cruise - 1].to_node
            local actual_after_cruise = map_graph_current_tile_point()

            if not map_graph_points_match(actual_after_cruise, expected_after_cruise, 0.45) then
                abort(
                    "Map Graph To cruise mismatch in run " .. tostring(run.start_index) .. "-" .. tostring(run.end_index) ..
                    ": expected " .. map_graph_node_label(expected_after_cruise) ..
                    ", actual " .. map_graph_node_label(actual_after_cruise) .. "."
                )
            end
        end
    end

    local next_index = run.start_index + moved_by_cruise

    if next_index <= run.end_index then
        print("  verified remainder: " .. tostring(run.end_index - next_index + 1) .. " tile(s)")
    end

    for i = next_index, run.end_index do
        map_graph_verify_current_node(path[i].from_node, "graph step " .. tostring(i))
        map_graph_walk_single_edge(path[i], "Graph step " .. tostring(i) .. "/" .. tostring(#path))
    end
end

function mode_map_graph_to()
    perf_start("map_graph_to_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_graph_to: not in game.")
    end

    route_release_direction_buttons()

    local allow_reverse = map_graph_to_bool(config.map_graph_allow_reverse_edges, true)
    local max_path_steps = map_graph_travel_max_steps()

    print("Map Graph To v0.2 Compressed Cruise Travel")
    print("Loads user\\routes\\map_graph.txt, finds a path, compresses same-direction runs, and walks with cruise + verified remainder.")
    print("Allow inferred reverse walkable edges: " .. tostring(allow_reverse))
    print("Max path steps: " .. tostring(max_path_steps))

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    perf_start("map_graph_to_load_graph")
    local graph = map_graph_load_for_travel(allow_reverse)
    perf_stop("map_graph_to_load_graph")

    print("Graph loaded: " .. tostring(#graph.node_order) .. " node(s), " .. tostring(graph.edge_count) .. " travel edge(s), " .. tostring(graph.reverse_edge_count) .. " inferred reverse edge(s).")

    local current_tile = map_graph_current_tile_point()
    local target_point = map_graph_get_target_point(current_tile)

    local start_node, start_distance = map_graph_find_closest_node(graph, current_tile, 0.60)
    local target_node, target_distance = map_graph_find_closest_node(graph, target_point, 0.60)

    if not start_node then
        abort("Map Graph To could not find a graph node near current tile " .. map_graph_node_label(current_tile) .. ". Run Map Sweep/Graph Build around this area first.")
    end

    if not target_node then
        abort("Map Graph To could not find a graph node near target " .. map_graph_node_label(target_point) .. ". Use coordinates from map_graph.txt or scan/build that area first.")
    end

    print("Start node: " .. map_graph_node_label(start_node) .. " distance=" .. string.format("%.2f", start_distance or 0))
    print("Target node: " .. map_graph_node_label(target_node) .. " distance=" .. string.format("%.2f", target_distance or 0))

    if start_node.key == target_node.key then
        print("Already at the target graph node.")
        perf_stop("map_graph_to_total")
        abort("Map Graph To finished.")
    end

    perf_start("map_graph_to_pathfind")
    local path = map_graph_find_path(graph, start_node.key, target_node.key, max_path_steps)
    perf_stop("map_graph_to_pathfind")

    if not path then
        abort("Map Graph To could not find a path from start to target inside the current compact graph.")
    end

    local runs = map_graph_compress_path_runs(path)

    print("Graph path found: " .. tostring(#path) .. " edge(s), compressed into " .. tostring(#runs) .. " run(s).")

    if #path > 0 then
        local preview = {}
        for i, edge in ipairs(path) do
            if i > 12 then
                preview[#preview + 1] = "..."
                break
            end
            preview[#preview + 1] = tostring(edge.dir) .. (edge.inferred_reverse and "*" or "")
        end
        print("Path preview: " .. table.concat(preview, " -> ") .. "  (* = inferred reverse edge)")
        print("Run preview: " .. map_graph_run_preview(runs))
    end

    perf_start("map_graph_to_walk")
    for _, run in ipairs(runs) do
        map_graph_walk_compressed_run(path, run)
    end
    perf_stop("map_graph_to_walk")

    local final_tile = map_graph_current_tile_point()
    if not map_graph_points_match(final_tile, target_node, 0.45) then
        abort(
            "Map Graph To finished walking but final tile did not match target. Expected " ..
            map_graph_node_label(target_node) .. ", actual " .. map_graph_node_label(final_tile) .. "."
        )
    end

    perf_stop("map_graph_to_total")

    print("Map Graph To reached target node: " .. map_graph_node_label(target_node))
    abort("Map Graph To finished.")
end
