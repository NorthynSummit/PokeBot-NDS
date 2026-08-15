-----------------------------------------------------------------------------
-- nav_cleanup.lua
-- Map maintenance / cleanup tools.
--
-- Purpose:
--   * Remove bad raw observations around the current tile, especially false
--     blocked edges caused by accidental menus/dialogue or battle UI timing.
--   * Back up files before touching them.
--   * Rebuild the compact map_graph.txt after cleanup.
--   * Keep this separate from exploration so normal players get a simple
--     "fix nearby map data" mode instead of editing TXT files by hand.
-----------------------------------------------------------------------------

NAV_CLEANUP_VERSION = (nav_cleanup_version and nav_cleanup_version()) or "v38.2"

function nav_cleanup_timestamp()
    return os.date("%Y%m%d_%H%M%S")
end

function nav_cleanup_abs(value)
    value = tonumber(value) or 0
    if value < 0 then return -value end
    return value
end

function nav_cleanup_tile_int(value)
    return math.floor((tonumber(value) or 0))
end

function nav_cleanup_radius()
    local radius = tonumber(config and config.nav_cleanup_radius_tiles or 0) or 0
    if radius < 0 then radius = 0 end
    if radius > 10 then radius = 10 end
    return radius
end

function nav_cleanup_direction()
    local dir = tostring(config and config.nav_cleanup_direction or "All")
    if dir == "" then dir = "All" end
    return dir
end

function nav_cleanup_scope()
    local scope = tostring(config and config.nav_cleanup_scope or "blocked")
    if scope == "" then scope = "blocked" end
    return scope
end

function nav_cleanup_should_rebuild_graph()
    if not config then return true end
    return config.nav_cleanup_rebuild_graph ~= false
end

function nav_cleanup_matches_direction(entry_dir, wanted_dir)
    wanted_dir = tostring(wanted_dir or "All")
    if wanted_dir == "All" or wanted_dir == "Any" or wanted_dir == "" then
        return true
    end
    return tostring(entry_dir or "") == wanted_dir
end

function nav_cleanup_matches_scope(result, scope)
    result = tostring(result or "")
    scope = tostring(scope or "blocked")

    if scope == "blocked" then
        return result == "blocked"
    elseif scope == "battle" then
        return result == "battle"
    elseif scope == "blocked_battle" then
        return result == "blocked" or result == "battle"
    elseif scope == "all_non_walkable" then
        return result ~= "walkable" and result ~= "transition"
    elseif scope == "all_current" then
        return true
    elseif scope == "walkable_transition" then
        return result == "walkable" or result == "transition"
    end

    return result == "blocked"
end

function nav_cleanup_current_point()
    if map_probe_current_point then
        return map_probe_current_point()
    end

    return {
        name = tostring(game_state and game_state.map_name or ""),
        map = tonumber(game_state and game_state.map_header or 0) or 0,
        x = tonumber(game_state and game_state.trainer_x or 0) or 0,
        y = tonumber(game_state and game_state.trainer_y or 0) or 0,
        z = tonumber(game_state and game_state.trainer_z or 0) or 0
    }
end

function nav_cleanup_point_label(point)
    point = point or {}
    return tostring(point.name or "") .. " map " .. tostring(point.map or "") ..
           " X " .. string.format("%.1f", tonumber(point.x) or 0) ..
           " Z " .. string.format("%.1f", tonumber(point.z) or 0)
end

function nav_cleanup_point_matches(point, current, radius)
    if not point or not current then return false end

    local entry_map = tonumber(point.map) or 0
    local current_map = tonumber(current.map) or 0
    if entry_map ~= current_map then
        return false
    end

    local dx = nav_cleanup_abs(nav_cleanup_tile_int(point.x) - nav_cleanup_tile_int(current.x))
    local dz = nav_cleanup_abs(nav_cleanup_tile_int(point.z) - nav_cleanup_tile_int(current.z))
    return dx <= radius and dz <= radius
end

function nav_cleanup_split_tab(line)
    local parts = {}
    for part in string.gmatch(tostring(line or "") .. "\t", "(.-)\t") do
        parts[#parts + 1] = part
    end
    return parts
end

function nav_cleanup_split_pipe(line)
    if map_graph_split_pipe then
        return map_graph_split_pipe(line)
    end

    local parts = {}
    for part in string.gmatch(tostring(line or "") .. "|", "(.-)|") do
        parts[#parts + 1] = part
    end
    return parts
end

function nav_cleanup_parse_node_id(node_id)
    local parts = nav_cleanup_split_pipe(node_id)
    if #parts < 5 then return nil end

    return {
        game_id = tostring(parts[1] or ""),
        map = tonumber(parts[2]) or 0,
        x = tonumber(parts[3]) or 0,
        y = tonumber(parts[4]) or 0,
        z = tonumber(parts[5]) or 0
    }
end

function nav_cleanup_node_id_matches(node_id, current, radius)
    local node = nav_cleanup_parse_node_id(node_id)
    if not node then return false end

    if tonumber(node.map) ~= (tonumber(current.map) or 0) then
        return false
    end

    local dx = nav_cleanup_abs((tonumber(node.x) or 0) - nav_cleanup_tile_int(current.x))
    local dz = nav_cleanup_abs((tonumber(node.z) or 0) - nav_cleanup_tile_int(current.z))
    return dx <= radius and dz <= radius
end

function nav_cleanup_backup_file(path)
    local input = io.open(path, "r")
    if not input then
        return nil, 0
    end

    local text = input:read("*a") or ""
    input:close()

    local backup_path = tostring(path) .. ".bak_" .. nav_cleanup_timestamp()
    local backup = io.open(backup_path, "w")
    if backup then
        backup:write(text)
        backup:close()
    else
        print_warn("Could not write backup for " .. tostring(path) .. ". Cleanup will skip this file.")
        return nil, 0
    end

    return backup_path, #text
end

function nav_cleanup_filter_raw_file(path, current, radius, direction, scope)
    local backup_path = nav_cleanup_backup_file(path)
    if not backup_path then
        return { path = path, existed = false, removed = 0, kept = 0 }
    end

    local input = io.open(backup_path, "r")
    if not input then
        return { path = path, existed = true, removed = 0, kept = 0, error = "backup_read_failed" }
    end

    local lines = {}
    local removed = 0
    local kept = 0
    local line_number = 0

    for line in input:lines() do
        line_number = line_number + 1
        local remove = false

        local entry = nil
        if map_graph_parse_edge_line then
            entry = map_graph_parse_edge_line(line, path, line_number)
        end

        if entry then
            local matches_tile = nav_cleanup_point_matches(entry.start_point, current, radius)
            local matches_dir = nav_cleanup_matches_direction(entry.dir, direction)
            local matches_scope = nav_cleanup_matches_scope(entry.result, scope)

            if matches_tile and matches_dir and matches_scope then
                remove = true
            end
        end

        if remove then
            removed = removed + 1
        else
            kept = kept + 1
            lines[#lines + 1] = line .. "\n"
        end
    end
    input:close()

    local output = io.open(path, "w")
    if not output then
        return { path = path, existed = true, removed = removed, kept = kept, error = "write_failed" }
    end

    output:write(table.concat(lines, ""))
    output:close()

    return { path = path, existed = true, removed = removed, kept = kept, backup = backup_path }
end

function nav_cleanup_tsv_should_remove(table_name, cols, current, radius, direction, scope)
    table_name = tostring(table_name or "")

    if table_name == "nodes" then
        return false
    end

    local from_node_id = nil
    local entry_dir = ""
    local result = ""

    if table_name == "edges" then
        from_node_id = cols[3]
        entry_dir = cols[4]
        result = cols[6]
    elseif table_name == "blocked" then
        from_node_id = cols[3]
        entry_dir = cols[4]
        result = cols[5] or "blocked"
    elseif table_name == "transitions" then
        from_node_id = cols[3]
        entry_dir = cols[4]
        result = "transition"
    elseif table_name == "observations" then
        from_node_id = cols[5]
        entry_dir = cols[6]
        result = cols[7]
    else
        return false
    end

    if not nav_cleanup_node_id_matches(from_node_id, current, radius) then
        return false
    end

    if not nav_cleanup_matches_direction(entry_dir, direction) then
        return false
    end

    return nav_cleanup_matches_scope(result, scope)
end

function nav_cleanup_filter_tsv_file(table_name, current, radius, direction, scope)
    if not nav_storage_table_path then
        return { table_name = table_name, existed = false, removed = 0, kept = 0, skipped = "nav_storage_unavailable" }
    end

    local path = nav_storage_table_path(table_name)
    local backup_path = nav_cleanup_backup_file(path)
    if not backup_path then
        return { path = path, table_name = table_name, existed = false, removed = 0, kept = 0 }
    end

    local input = io.open(backup_path, "r")
    if not input then
        return { path = path, table_name = table_name, existed = true, removed = 0, kept = 0, error = "backup_read_failed" }
    end

    local lines = {}
    local removed = 0
    local kept = 0
    local line_number = 0

    for line in input:lines() do
        line_number = line_number + 1
        local remove = false

        if line_number > 1 and line ~= "" then
            local cols = nav_cleanup_split_tab(line)
            remove = nav_cleanup_tsv_should_remove(table_name, cols, current, radius, direction, scope)
        end

        if remove then
            removed = removed + 1
        else
            kept = kept + 1
            lines[#lines + 1] = line .. "\n"
        end
    end
    input:close()

    local output = io.open(path, "w")
    if not output then
        return { path = path, table_name = table_name, existed = true, removed = removed, kept = kept, error = "write_failed" }
    end

    output:write(table.concat(lines, ""))
    output:close()

    return { path = path, table_name = table_name, existed = true, removed = removed, kept = kept, backup = backup_path }
end

function nav_cleanup_print_result(result)
    if not result then return end
    if result.existed == false then
        print("  skipped missing: " .. tostring(result.path or result.table_name or "unknown"))
    elseif result.error then
        print_warn("  " .. tostring(result.path or result.table_name or "unknown") .. " cleanup error: " .. tostring(result.error))
    else
        print("  " .. tostring(result.path or result.table_name or "unknown") .. ": removed=" .. tostring(result.removed or 0) .. ", kept=" .. tostring(result.kept or 0))
        if result.backup then
            print("    backup: " .. tostring(result.backup))
        end
    end
end

function nav_cleanup_rebuild_graph_after_cleanup()
    if not map_graph_build_from_raw or not map_graph_write then
        print_warn("Map graph rebuild functions are unavailable. Run Map Graph Build manually.")
        return
    end

    print("Rebuilding compact map graph after cleanup...")
    local nodes, edges, blocked, stats = map_graph_build_from_raw()
    local output_path, output_size = map_graph_write(nodes, edges, blocked, stats)
    print("Rebuilt " .. tostring(output_path) .. " (" .. tostring(output_size) .. " bytes).")
    print("Graph now has nodes=" .. tostring(#map_graph_sorted_keys(nodes)) ..
          ", edges=" .. tostring(#map_graph_sorted_keys(edges)) ..
          ", blocked=" .. tostring(#map_graph_sorted_keys(blocked)) .. ".")
end

function mode_map_cleanup_current_tile()
    print("Navigation Cleanup Current Tile " .. tostring(NAV_CLEANUP_VERSION))
    print("Removes bad observations near your current tile, backs up files first, and rebuilds the compact graph.")

    local current = nav_cleanup_current_point()
    local radius = nav_cleanup_radius()
    local direction = nav_cleanup_direction()
    local scope = nav_cleanup_scope()

    print("Current tile: " .. nav_cleanup_point_label(current))
    print("Cleanup radius: " .. tostring(radius) .. " tile(s)")
    print("Cleanup direction: " .. tostring(direction))
    print("Cleanup scope: " .. tostring(scope))

    print("Raw observation cleanup:")
    local raw_paths = {}
    if map_graph_raw_paths then
        raw_paths = map_graph_raw_paths()
    else
        if map_sweep_path then raw_paths[#raw_paths + 1] = map_sweep_path() end
        if map_scan_line_path then raw_paths[#raw_paths + 1] = map_scan_line_path() end
        if map_probe_batch_path then raw_paths[#raw_paths + 1] = map_probe_batch_path() end
    end

    local raw_removed = 0
    for _, path in ipairs(raw_paths) do
        local result = nav_cleanup_filter_raw_file(path, current, radius, direction, scope)
        raw_removed = raw_removed + (tonumber(result.removed) or 0)
        nav_cleanup_print_result(result)
    end

    print("Normalized storage cleanup:")
    local tsv_removed = 0
    if nav_storage_init_files then
        nav_storage_init_files()
    end
    for _, table_name in ipairs({ "blocked", "edges", "transitions", "observations" }) do
        local result = nav_cleanup_filter_tsv_file(table_name, current, radius, direction, scope)
        tsv_removed = tsv_removed + (tonumber(result.removed) or 0)
        nav_cleanup_print_result(result)
    end

    if nav_cleanup_should_rebuild_graph() then
        nav_cleanup_rebuild_graph_after_cleanup()
    else
        print("Skipping map graph rebuild because nav_cleanup_rebuild_graph is OFF.")
    end

    print("Cleanup summary: raw_removed=" .. tostring(raw_removed) .. ", storage_rows_removed=" .. tostring(tsv_removed) .. ".")
    print("If the removed data was wrong, run Map Explore Area again and the bot will relearn that direction cleanly.")

    abort("Navigation Cleanup Current Tile finished.")
end
