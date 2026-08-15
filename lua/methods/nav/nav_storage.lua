-----------------------------------------------------------------------------
-- nav_storage.lua
-- Normalized navigation storage layer.
--
-- Purpose:
--   * Keep the old raw edge TXT files for compatibility/debugging.
--   * Add stable unique keys for games/maps/nodes/edges.
--   * Write normalized TSV tables that do not duplicate coordinates.
--   * Send observations to the dashboard; Node can persist them to SQLite if
--     optional SQLite support is installed, otherwise it falls back safely.
-----------------------------------------------------------------------------

NAV_STORAGE_VERSION = (nav_storage_version and nav_storage_version()) or "v39.0"

local NAV_STORAGE_INDEX_LOADED = false
local NAV_STORAGE_CREATED_DIRS = {}
local NAV_STORAGE_NODE_KEYS = {}
local NAV_STORAGE_EDGE_KEYS = {}
local NAV_STORAGE_BLOCKED_KEYS = {}
local NAV_STORAGE_TRANSITION_KEYS = {}

function nav_storage_enabled()
    if config and config.nav_storage_enabled == false then
        return false
    end
    return true
end

function nav_storage_path_sep()
    return "\\"
end

function nav_storage_safe_text(value)
    value = tostring(value or "")
    value = string.gsub(value, "\t", " ")
    value = string.gsub(value, "\r", " ")
    value = string.gsub(value, "\n", " ")
    return value
end

function nav_storage_path_safe(value)
    value = nav_storage_safe_text(value)
    value = string.gsub(value, "[^A-Za-z0-9_%-]+", "_")
    value = string.gsub(value, "_+", "_")
    if value == "" then value = "unknown" end
    return value
end

function nav_storage_game_id()
    local version = "UNK"
    local language = "UNK"

    if _ROM then
        version = tostring(_ROM.version or version)
        language = tostring(_ROM.language or language)
    end

    return nav_storage_path_safe(version .. "_" .. language)
end

function nav_storage_base_dir()
    return "user\\nav"
end

function nav_storage_game_dir()
    return nav_storage_base_dir() .. "\\games\\" .. nav_storage_game_id()
end

function nav_storage_table_path(name)
    return nav_storage_game_dir() .. "\\" .. tostring(name) .. ".tsv"
end

function nav_storage_schema_path()
    return nav_storage_base_dir() .. "\\nav_schema.sql"
end

function nav_storage_mkdir(path)
    path = tostring(path or "")
    if path == "" or NAV_STORAGE_CREATED_DIRS[path] then
        return
    end

    -- Windows-compatible. Executed only once per directory per Lua run.
    os.execute('mkdir "' .. path .. '" 2>nul')
    NAV_STORAGE_CREATED_DIRS[path] = true
end

function nav_storage_init_dirs()
    nav_storage_mkdir("user")
    nav_storage_mkdir(nav_storage_base_dir())
    nav_storage_mkdir(nav_storage_base_dir() .. "\\games")
    nav_storage_mkdir(nav_storage_game_dir())
    nav_storage_mkdir(nav_storage_game_dir() .. "\\raw")
end

function nav_storage_write_if_missing(path, text)
    local file = io.open(path, "r")
    if file then
        file:close()
        return
    end

    file = io.open(path, "w")
    if file then
        file:write(text)
        file:close()
    end
end

NAV_STORAGE_FILES_READY = false

function nav_storage_init_files()
    if NAV_STORAGE_FILES_READY then
        return
    end

    -- Avoid running Windows shell mkdir on every Lua run once the storage
    -- tables already exist. The first storage-enabled explore run showed a
    -- one-time multi-second delay here because os.execute() is expensive in
    -- DeSmuME Lua.
    local existing_nodes = io.open(nav_storage_table_path("nodes"), "r")
    if existing_nodes then
        existing_nodes:close()
    else
        nav_storage_init_dirs()
    end

    nav_storage_write_if_missing(nav_storage_table_path("nodes"),
        "node_id\tgame_id\tmap_header\tmap_name\ttile_x\ttile_y\ttile_z\tfirst_seen_at\tlast_seen_at\tsource\n")
    nav_storage_write_if_missing(nav_storage_table_path("edges"),
        "edge_id\tgame_id\tfrom_node_id\tdirection\tto_node_id\tresult\tencounter_risk\tcost\tfirst_seen_at\tlast_seen_at\tsource\tnote\n")
    nav_storage_write_if_missing(nav_storage_table_path("blocked"),
        "blocked_id\tgame_id\tfrom_node_id\tdirection\tresult\tfirst_seen_at\tlast_seen_at\tsource\tnote\n")
    nav_storage_write_if_missing(nav_storage_table_path("transitions"),
        "transition_id\tgame_id\tfrom_node_id\tdirection\tto_node_id\tfrom_map_header\tto_map_header\tfirst_seen_at\tlast_seen_at\tsource\tnote\n")
    nav_storage_write_if_missing(nav_storage_table_path("observations"),
        "observation_time\tgame_id\tmode\tsource\tfrom_node_id\tdirection\tresult\tto_node_id\tencounter_risk\tmap_changed\tnote\n")

    nav_storage_write_if_missing(nav_storage_base_dir() .. "\\README.txt", [[Pokebot custom navigation storage

This folder is the custom navigation normalized storage layer.

v39 keeps TSV files as the safe compatibility backend while introducing storage health checks and backup helpers.
These TSV files are designed to avoid duplicate coordinate nodes and to be easy to migrate into SQLite or another source-of-truth backend later.

Key rules:
- nodes.tsv is unique by game_id + map_header + tile_x + tile_y + tile_z.
- edges.tsv is unique by from_node_id + direction + result + to_node_id.
- blocked.tsv is unique by from_node_id + direction.
- transitions.tsv is unique by from_node_id + direction + to_node_id.
- observations.tsv is append-only and keeps every probe observation.

Storage source-of-truth plan:
- v39 source of truth remains normalized TSV files, with raw route files preserved for compatibility.
- dashboard\nav_store.js records runtime observations to user\nav\node_observations.jsonl and reports storage health.
- SQLite is not required by this build; future builds can migrate from these TSV files safely.
]])

    nav_storage_write_if_missing(nav_storage_schema_path(), [[-- Pokebot custom navigation SQLite schema, v39.0 foundation.
-- Optional for Node-side storage. Lua does not require SQLite.

CREATE TABLE IF NOT EXISTS games (
    game_id TEXT PRIMARY KEY,
    rom_version TEXT,
    rom_language TEXT,
    profile TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS maps (
    map_uid TEXT PRIMARY KEY,
    game_id TEXT NOT NULL,
    map_header INTEGER NOT NULL,
    map_name TEXT,
    first_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(game_id, map_header)
);

CREATE TABLE IF NOT EXISTS nodes (
    node_id TEXT PRIMARY KEY,
    game_id TEXT NOT NULL,
    map_header INTEGER NOT NULL,
    map_name TEXT,
    tile_x INTEGER NOT NULL,
    tile_y INTEGER NOT NULL,
    tile_z INTEGER NOT NULL,
    terrain TEXT DEFAULT 'unknown',
    visit_count INTEGER DEFAULT 0,
    first_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(game_id, map_header, tile_x, tile_y, tile_z)
);

CREATE TABLE IF NOT EXISTS edges (
    edge_id TEXT PRIMARY KEY,
    game_id TEXT NOT NULL,
    from_node_id TEXT NOT NULL,
    direction TEXT NOT NULL,
    to_node_id TEXT,
    result TEXT NOT NULL,
    cost INTEGER DEFAULT 1,
    encounter_risk INTEGER DEFAULT 0,
    confidence INTEGER DEFAULT 1,
    observed_count INTEGER DEFAULT 1,
    first_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    note TEXT,
    UNIQUE(from_node_id, direction, result, to_node_id)
);

CREATE TABLE IF NOT EXISTS blocked_edges (
    blocked_id TEXT PRIMARY KEY,
    game_id TEXT NOT NULL,
    from_node_id TEXT NOT NULL,
    direction TEXT NOT NULL,
    observed_count INTEGER DEFAULT 1,
    first_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    note TEXT,
    UNIQUE(from_node_id, direction)
);

CREATE TABLE IF NOT EXISTS transitions (
    transition_id TEXT PRIMARY KEY,
    game_id TEXT NOT NULL,
    from_node_id TEXT NOT NULL,
    direction TEXT NOT NULL,
    to_node_id TEXT,
    from_map_header INTEGER,
    to_map_header INTEGER,
    transition_type TEXT DEFAULT 'map_change',
    observed_count INTEGER DEFAULT 1,
    first_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TEXT DEFAULT CURRENT_TIMESTAMP,
    note TEXT,
    UNIQUE(from_node_id, direction, to_node_id)
);

CREATE TABLE IF NOT EXISTS observations (
    observation_id INTEGER PRIMARY KEY AUTOINCREMENT,
    observed_at TEXT DEFAULT CURRENT_TIMESTAMP,
    game_id TEXT,
    mode TEXT,
    source TEXT,
    from_node_id TEXT,
    direction TEXT,
    result TEXT,
    to_node_id TEXT,
    encounter_risk INTEGER DEFAULT 0,
    map_changed INTEGER DEFAULT 0,
    note TEXT,
    raw_json TEXT
);
]])

    NAV_STORAGE_FILES_READY = true
end

function nav_storage_now()
    return os.date("%Y-%m-%d %H:%M:%S")
end

function nav_storage_tile_int(value)
    return math.floor((tonumber(value) or 0))
end

function nav_storage_point_with_y(point)
    point = point or {}
    local copy = {
        name = tostring(point.name or (game_state and game_state.map_name) or ""),
        map = tonumber(point.map or (game_state and game_state.map_header) or 0) or 0,
        x = tonumber(point.x or (game_state and game_state.trainer_x) or 0) or 0,
        y = tonumber(point.y or (game_state and game_state.trainer_y) or 0) or 0,
        z = tonumber(point.z or (game_state and game_state.trainer_z) or 0) or 0
    }
    return copy
end

function nav_storage_node_id(point)
    point = nav_storage_point_with_y(point)
    return nav_storage_game_id() .. "|" ..
           tostring(point.map) .. "|" ..
           tostring(nav_storage_tile_int(point.x)) .. "|" ..
           tostring(nav_storage_tile_int(point.y)) .. "|" ..
           tostring(nav_storage_tile_int(point.z))
end

function nav_storage_line(parts)
    local out = {}
    for i, part in ipairs(parts) do
        out[i] = nav_storage_safe_text(part)
    end
    return table.concat(out, "\t") .. "\n"
end

function nav_storage_append(path, line)
    local file = io.open(path, "a")
    if not file then
        print_warn("Navigation storage could not open " .. tostring(path) .. ".")
        return false
    end
    file:write(line)
    file:close()
    return true
end

function nav_storage_load_key_file(path, key_table, key_column)
    local file = io.open(path, "r")
    if not file then return end

    local first = true
    for line in file:lines() do
        if first then
            first = false
        else
            local cols = {}
            for part in string.gmatch(line .. "\t", "(.-)\t") do
                cols[#cols + 1] = part
            end
            local key = cols[key_column or 1]
            if key and key ~= "" then
                key_table[key] = true
            end
        end
    end

    file:close()
end

function nav_storage_load_indexes_once()
    if NAV_STORAGE_INDEX_LOADED then return end
    nav_storage_init_files()
    nav_storage_load_key_file(nav_storage_table_path("nodes"), NAV_STORAGE_NODE_KEYS, 1)
    nav_storage_load_key_file(nav_storage_table_path("edges"), NAV_STORAGE_EDGE_KEYS, 1)
    nav_storage_load_key_file(nav_storage_table_path("blocked"), NAV_STORAGE_BLOCKED_KEYS, 1)
    nav_storage_load_key_file(nav_storage_table_path("transitions"), NAV_STORAGE_TRANSITION_KEYS, 1)
    NAV_STORAGE_INDEX_LOADED = true
end

function nav_storage_upsert_node(point, source)
    point = nav_storage_point_with_y(point)
    local node_id = nav_storage_node_id(point)
    nav_storage_load_indexes_once()

    if not NAV_STORAGE_NODE_KEYS[node_id] then
        local now = nav_storage_now()
        nav_storage_append(nav_storage_table_path("nodes"), nav_storage_line({
            node_id,
            nav_storage_game_id(),
            point.map,
            point.name,
            nav_storage_tile_int(point.x),
            nav_storage_tile_int(point.y),
            nav_storage_tile_int(point.z),
            now,
            now,
            source or "unknown"
        }))
        NAV_STORAGE_NODE_KEYS[node_id] = true
    end

    return node_id
end

function nav_storage_note_has(note, pattern)
    note = tostring(note or "")
    return string.find(note, pattern, 1, true) ~= nil
end

function nav_storage_entry_encounter_risk(entry)
    if not entry then return false end
    if tostring(entry.result or "") == "battle" then return true end
    if nav_storage_note_has(entry.note, "encounter_risk=true") then return true end
    if nav_storage_note_has(entry.note, "battle_triggered=true") then return true end
    return false
end

function nav_storage_entry_map_changed(entry)
    if not entry then return false end
    if tostring(entry.result or "") == "transition" then return true end
    if nav_storage_note_has(entry.note, "map_changed") then return true end
    return false
end

function nav_storage_edge_id(from_node_id, dir, result, to_node_id)
    return tostring(from_node_id) .. "|" .. tostring(dir) .. "|" .. tostring(result) .. "|" .. tostring(to_node_id or "")
end

function nav_storage_blocked_id(from_node_id, dir)
    return tostring(from_node_id) .. "|" .. tostring(dir)
end

function nav_storage_transition_id(from_node_id, dir, to_node_id)
    return tostring(from_node_id) .. "|" .. tostring(dir) .. "|" .. tostring(to_node_id or "")
end

function nav_storage_upsert_edge(entry, source)
    local result = tostring(entry.result or "unknown")
    if result ~= "walkable" and result ~= "transition" then
        return nil
    end

    local from_node_id = nav_storage_upsert_node(entry.start_point, source)
    local to_node_id = nav_storage_upsert_node(entry.end_point, source)
    local edge_id = nav_storage_edge_id(from_node_id, entry.dir, result, to_node_id)
    nav_storage_load_indexes_once()

    if not NAV_STORAGE_EDGE_KEYS[edge_id] then
        local now = nav_storage_now()
        nav_storage_append(nav_storage_table_path("edges"), nav_storage_line({
            edge_id,
            nav_storage_game_id(),
            from_node_id,
            entry.dir,
            to_node_id,
            result,
            nav_storage_entry_encounter_risk(entry) and 1 or 0,
            result == "walkable" and 1 or 1,
            now,
            now,
            source or "unknown",
            entry.note or ""
        }))
        NAV_STORAGE_EDGE_KEYS[edge_id] = true
    end

    if result == "transition" then
        local transition_id = nav_storage_transition_id(from_node_id, entry.dir, to_node_id)
        if not NAV_STORAGE_TRANSITION_KEYS[transition_id] then
            local now = nav_storage_now()
            local start_point = nav_storage_point_with_y(entry.start_point)
            local end_point = nav_storage_point_with_y(entry.end_point)
            nav_storage_append(nav_storage_table_path("transitions"), nav_storage_line({
                transition_id,
                nav_storage_game_id(),
                from_node_id,
                entry.dir,
                to_node_id,
                start_point.map,
                end_point.map,
                now,
                now,
                source or "unknown",
                entry.note or ""
            }))
            NAV_STORAGE_TRANSITION_KEYS[transition_id] = true
        end
    end

    return edge_id
end

function nav_storage_upsert_blocked(entry, source)
    if tostring(entry.result or "") ~= "blocked" then
        return nil
    end

    local from_node_id = nav_storage_upsert_node(entry.start_point, source)
    local blocked_id = nav_storage_blocked_id(from_node_id, entry.dir)
    nav_storage_load_indexes_once()

    if not NAV_STORAGE_BLOCKED_KEYS[blocked_id] then
        local now = nav_storage_now()
        nav_storage_append(nav_storage_table_path("blocked"), nav_storage_line({
            blocked_id,
            nav_storage_game_id(),
            from_node_id,
            entry.dir,
            entry.result,
            now,
            now,
            source or "unknown",
            entry.note or ""
        }))
        NAV_STORAGE_BLOCKED_KEYS[blocked_id] = true
    end

    return blocked_id
end

function nav_storage_send_dashboard(entry, source, from_node_id, to_node_id)
    if not dashboard_send then
        return
    end

    local ok, err = pcall(function()
        dashboard_send({
            type = "nav_observation",
            data = {
                storage_version = NAV_STORAGE_VERSION,
                game_id = nav_storage_game_id(),
                mode = tostring(config and config.mode or "unknown"),
                source = tostring(source or "unknown"),
                from_node_id = from_node_id,
                to_node_id = to_node_id,
                direction = tostring(entry.dir or ""),
                result = tostring(entry.result or "unknown"),
                encounter_risk = nav_storage_entry_encounter_risk(entry),
                map_changed = nav_storage_entry_map_changed(entry),
                note = tostring(entry.note or ""),
                start_point = nav_storage_point_with_y(entry.start_point),
                end_point = nav_storage_point_with_y(entry.end_point)
            }
        })
    end)

    if not ok then
        print_debug("Navigation storage dashboard send failed: " .. tostring(err))
    end
end

function nav_storage_record_probe_entry(entry, source)
    if not nav_storage_enabled() or not entry then
        return false
    end

    nav_storage_load_indexes_once()

    local from_node_id = nav_storage_upsert_node(entry.start_point, source)
    local to_node_id = nil

    if entry.end_point then
        to_node_id = nav_storage_node_id(entry.end_point)
    end

    local result = tostring(entry.result or "unknown")
    if result == "walkable" or result == "transition" then
        nav_storage_upsert_edge(entry, source)
        to_node_id = nav_storage_node_id(entry.end_point)
    elseif result == "blocked" then
        nav_storage_upsert_blocked(entry, source)
        to_node_id = from_node_id
    elseif result == "battle" then
        -- Do not poison the graph/storage with a fake blocked edge.
        -- Battle observations are kept in observations.tsv only unless the
        -- explore layer converted a clean movement to walkable+encounter_risk.
        to_node_id = from_node_id
    end

    local now = nav_storage_now()
    nav_storage_append(nav_storage_table_path("observations"), nav_storage_line({
        now,
        nav_storage_game_id(),
        tostring(config and config.mode or "unknown"),
        source or "unknown",
        from_node_id,
        entry.dir or "",
        result,
        to_node_id or "",
        nav_storage_entry_encounter_risk(entry) and 1 or 0,
        nav_storage_entry_map_changed(entry) and 1 or 0,
        entry.note or ""
    }))

    nav_storage_send_dashboard(entry, source, from_node_id, to_node_id)
    return true
end

function nav_storage_record_probe_results(results, output_label, output_path)
    if not nav_storage_enabled() or not results then
        return 0
    end

    local source = tostring(output_label or "unknown") .. ":" .. tostring(output_path or "")
    local count = 0
    for _, entry in ipairs(results) do
        if nav_storage_record_probe_entry(entry, source) then
            count = count + 1
        end
    end

    if count > 0 and config and config.debug then
        print("Navigation storage recorded " .. tostring(count) .. " normalized observation(s).")
    end

    return count
end


function nav_storage_file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

function nav_storage_count_records(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local count = 0
    local first = true
    for _ in file:lines() do
        if first then
            first = false
        else
            count = count + 1
        end
    end
    file:close()
    return count
end

function nav_storage_count_duplicate_keys(path, key_column)
    local file = io.open(path, "r")
    if not file then return nil end

    local seen = {}
    local duplicates = 0
    local first = true
    for line in file:lines() do
        if first then
            first = false
        else
            local cols = {}
            for part in string.gmatch(line .. "\t", "(.-)\t") do
                cols[#cols + 1] = part
            end
            local key = cols[key_column or 1]
            if key and key ~= "" then
                if seen[key] then duplicates = duplicates + 1 end
                seen[key] = true
            end
        end
    end
    file:close()
    return duplicates
end

function nav_storage_health_status()
    nav_storage_init_files()

    local tables = {
        { name = "nodes", key_column = 1 },
        { name = "edges", key_column = 1 },
        { name = "blocked", key_column = 1 },
        { name = "transitions", key_column = 1 },
        { name = "observations", key_column = nil }
    }

    local result = {
        version = tostring(NAV_STORAGE_VERSION),
        backend = "tsv_compat",
        source_of_truth = "normalized_tsv_foundation",
        game_id = nav_storage_game_id(),
        folder = nav_storage_game_dir(),
        tables = {},
        warnings = {},
        records_total = 0,
        health = "ready"
    }

    for _, table_info in ipairs(tables) do
        local path = nav_storage_table_path(table_info.name)
        local exists = nav_storage_file_exists(path)
        local records = exists and nav_storage_count_records(path) or nil
        local duplicates = exists and table_info.key_column and nav_storage_count_duplicate_keys(path, table_info.key_column) or 0

        result.tables[table_info.name] = {
            path = path,
            exists = exists,
            records = records or 0,
            duplicate_keys = duplicates or 0
        }

        if not exists then
            result.health = "missing_files"
            result.warnings[#result.warnings + 1] = table_info.name .. ".tsv is missing."
        elseif duplicates and duplicates > 0 then
            if result.health == "ready" then result.health = "needs_review" end
            result.warnings[#result.warnings + 1] = table_info.name .. ".tsv has " .. tostring(duplicates) .. " duplicate key(s)."
        end

        result.records_total = result.records_total + (records or 0)
    end

    if result.records_total == 0 and result.health == "ready" then
        result.health = "initialized_empty"
    end

    return result
end

function nav_storage_backup_path(reason)
    reason = nav_storage_path_safe(reason or "manual")
    return nav_storage_base_dir() .. "\\backups\\" .. os.date("nav_backup_%Y%m%d_%H%M%S_") .. reason
end

function nav_storage_backup_current(reason)
    nav_storage_init_files()
    local backup_dir = nav_storage_backup_path(reason)
    nav_storage_mkdir(nav_storage_base_dir() .. "\\backups")
    nav_storage_mkdir(backup_dir)
    nav_storage_mkdir(backup_dir .. "\\tables")
    nav_storage_mkdir(backup_dir .. "\\routes")

    local copied = 0
    local function copy_file(src, dest)
        local input = io.open(src, "rb")
        if not input then return false end
        local data = input:read("*a")
        input:close()

        local output = io.open(dest, "wb")
        if not output then return false end
        output:write(data or "")
        output:close()
        copied = copied + 1
        return true
    end

    copy_file(nav_storage_table_path("nodes"), backup_dir .. "\\tables\\nodes.tsv")
    copy_file(nav_storage_table_path("edges"), backup_dir .. "\\tables\\edges.tsv")
    copy_file(nav_storage_table_path("blocked"), backup_dir .. "\\tables\\blocked.tsv")
    copy_file(nav_storage_table_path("transitions"), backup_dir .. "\\tables\\transitions.tsv")
    copy_file(nav_storage_table_path("observations"), backup_dir .. "\\tables\\observations.tsv")
    copy_file("user\\routes\\map_graph.txt", backup_dir .. "\\routes\\map_graph.txt")
    copy_file("user\\routes\\map_sweep_edges.txt", backup_dir .. "\\routes\\map_sweep_edges.txt")
    copy_file("user\\routes\\map_nodes.txt", backup_dir .. "\\routes\\map_nodes.txt")

    local info = io.open(backup_dir .. "\\backup_info.txt", "w")
    if info then
        info:write("Pokebot navigation storage backup\n")
        info:write("Created: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        info:write("Reason: " .. tostring(reason or "manual") .. "\n")
        info:write("Files copied: " .. tostring(copied) .. "\n")
        info:close()
    end

    return backup_dir, copied
end

function mode_nav_storage_status()
    local health = nav_storage_health_status()
    print("Navigation Storage Status")
    print("Version: " .. tostring(NAV_STORAGE_VERSION))
    if nav_build_label then print("Build: " .. tostring(nav_build_label())) end
    print("Enabled: " .. tostring(nav_storage_enabled()))
    print("Backend: " .. tostring(health.backend))
    print("Source of truth: " .. tostring(health.source_of_truth))
    print("SQLite required: false")
    print("Game ID: " .. tostring(nav_storage_game_id()))
    print("Storage folder: " .. tostring(nav_storage_game_dir()))
    print("Health: " .. tostring(health.health))
    print("Records total: " .. tostring(health.records_total))
    print("Tables:")
    local order = { "nodes", "edges", "blocked", "transitions", "observations" }
    for _, name in ipairs(order) do
        local t = health.tables[name]
        if t then
            print("  " .. tostring(t.path) .. " | exists=" .. tostring(t.exists) .. " | records=" .. tostring(t.records) .. " | duplicate_keys=" .. tostring(t.duplicate_keys))
        end
    end
    print("SQLite schema: " .. tostring(nav_storage_schema_path()))
    if #health.warnings > 0 then
        print("Warnings:")
        for _, warning in ipairs(health.warnings) do
            print("  " .. tostring(warning))
        end
    else
        print("Warnings: none")
    end
    print("Backup helper: nav_storage_backup_current(reason) is available for explicit repair/migration safety.")
    abort("Navigation Storage Status finished.")
end
