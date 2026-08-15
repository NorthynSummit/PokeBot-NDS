-----------------------------------------------------------------------------
-- nav_terrain.lua
-- v27 Terrain Probe Failsafe Investigation
--
-- Goal: collect deterministic memory/tile fingerprints while standing on
-- known tile types (road, tall grass, cave floor, building floor, water edge,
-- ledge, etc.). This does NOT guess terrain from encounters.
--
-- The mode writes samples that can be compared across known labels so we can
-- find the real HGSS/Storm Silver tile behavior source later.
-----------------------------------------------------------------------------

function map_terrain_samples_path()
    return "user\\routes\\map_terrain_samples.txt"
end

function map_terrain_last_path()
    return "user\\routes\\map_terrain_last.txt"
end

function map_terrain_diff_path()
    return "user\\routes\\map_terrain_diff.txt"
end

function map_terrain_hex(value, width)
    if value == nil then
        return "NA"
    end

    local number_value = tonumber(value)
    if not number_value then
        return tostring(value)
    end

    if number_value < 0 then
        number_value = number_value + 4294967296
    end

    width = tonumber(width) or 0
    if width > 0 then
        return string.format("0x%0" .. tostring(width) .. "X", number_value)
    end

    return string.format("0x%X", number_value)
end

function map_terrain_safe_read_u8(addr)
    addr = tonumber(addr)
    if not addr then return nil end

    local ok, value = pcall(mbyte, addr)
    if ok then return value end
    return nil
end

function map_terrain_safe_read_u16(addr)
    addr = tonumber(addr)
    if not addr then return nil end

    local ok, value = pcall(mword, addr)
    if ok then return value end
    return nil
end

function map_terrain_safe_read_u32(addr)
    addr = tonumber(addr)
    if not addr then return nil end

    local ok, value = pcall(mdword, addr)
    if ok then return value end
    return nil
end

function map_terrain_safe_tostring(value)
    if value == nil then return "" end
    return tostring(value)
end

function map_terrain_clean_label(label)
    label = tostring(label or "unknown")
    label = string.gsub(label, "|", "_")
    label = string.gsub(label, "\r", " ")
    label = string.gsub(label, "\n", " ")
    if label == "" then label = "unknown" end
    return label
end

function map_terrain_current_tile()
    local point = map_probe_current_point()

    point.tile_x = math.floor((tonumber(point.x) or 0) + 0.0001)
    point.tile_z = math.floor((tonumber(point.z) or 0) + 0.0001)
    point.y = tonumber(game_state.trainer_y) or 0
    point.facing = nil

    if pointers and pointers.facing then
        point.facing = map_terrain_safe_read_u8(pointers.facing)
    end

    return point
end

function map_terrain_new_sample(label)
    local tile = map_terrain_current_tile()
    local sample = {
        label = map_terrain_clean_label(label),
        time = os.date and os.date("%Y-%m-%d %H:%M:%S") or tostring(emu.framecount()),
        frame = emu.framecount and emu.framecount() or 0,
        tile = tile,
        values = {},
        order = {}
    }

    return sample
end

function map_terrain_add_value(sample, key, value, addr, kind)
    key = tostring(key or "")
    if key == "" then return end

    local text_value = map_terrain_safe_tostring(value)

    if not sample.values[key] then
        sample.order[#sample.order + 1] = key
    end

    sample.values[key] = {
        value = text_value,
        addr = addr and map_terrain_hex(addr, 8) or "",
        kind = tostring(kind or "")
    }
end

function map_terrain_add_hex_value(sample, key, value, addr, kind, width)
    map_terrain_add_value(sample, key, map_terrain_hex(value, width), addr, kind)
end

function map_terrain_add_pointer_value(sample, key, addr)
    if not addr then
        map_terrain_add_value(sample, key .. ".addr", "NA", nil, "addr")
        return
    end

    map_terrain_add_hex_value(sample, key .. ".addr", addr, nil, "addr", 8)
    map_terrain_add_hex_value(sample, key .. ".u8",  map_terrain_safe_read_u8(addr),  addr, "u8", 2)
    map_terrain_add_hex_value(sample, key .. ".u16", map_terrain_safe_read_u16(addr), addr, "u16", 4)
    map_terrain_add_hex_value(sample, key .. ".u32", map_terrain_safe_read_u32(addr), addr, "u32", 8)
end

function map_terrain_add_byte_window(sample, group_name, center_addr, before, after)
    center_addr = tonumber(center_addr)
    if not center_addr then return end

    before = tonumber(before) or 0
    after = tonumber(after) or 0

    for offset = -before, after do
        local addr = center_addr + offset
        local key = tostring(group_name) .. ".b" .. string.format("%+d", offset)
        map_terrain_add_hex_value(sample, key, map_terrain_safe_read_u8(addr), addr, "u8", 2)
    end
end

function map_terrain_add_word_window(sample, group_name, center_addr, before, after)
    center_addr = tonumber(center_addr)
    if not center_addr then return end

    before = tonumber(before) or 0
    after = tonumber(after) or 0

    local start_offset = -before
    if start_offset % 2 ~= 0 then start_offset = start_offset - 1 end

    for offset = start_offset, after, 2 do
        local addr = center_addr + offset
        local key = tostring(group_name) .. ".w" .. string.format("%+d", offset)
        map_terrain_add_hex_value(sample, key, map_terrain_safe_read_u16(addr), addr, "u16", 4)
    end
end

function map_terrain_add_dword_window(sample, group_name, center_addr, before, after)
    center_addr = tonumber(center_addr)
    if not center_addr then return end

    before = tonumber(before) or 0
    after = tonumber(after) or 0

    local start_offset = -before
    local rem = start_offset % 4
    if rem ~= 0 then start_offset = start_offset - rem end

    for offset = start_offset, after, 4 do
        local addr = center_addr + offset
        local key = tostring(group_name) .. ".dw" .. string.format("%+d", offset)
        map_terrain_add_hex_value(sample, key, map_terrain_safe_read_u32(addr), addr, "u32", 8)
    end
end

function map_terrain_hgss_anchor_addr()
    local version = _ROM and _ROM.version or ""
    if version ~= "HG" and version ~= "SS" then
        return nil
    end

    return 0x21D4158 + (tonumber(_ROM.offset) or 0)
end

function map_terrain_collect_sample(label)
    local sample = map_terrain_new_sample(label)
    local tile = sample.tile

    map_terrain_add_value(sample, "meta.label", sample.label, nil, "text")
    map_terrain_add_value(sample, "meta.time", sample.time, nil, "text")
    map_terrain_add_value(sample, "meta.frame", sample.frame, nil, "number")
    map_terrain_add_value(sample, "meta.rom_version", (_ROM and _ROM.version) or "", nil, "text")
    map_terrain_add_value(sample, "meta.rom_language", (_ROM and _ROM.language) or "", nil, "text")
    map_terrain_add_hex_value(sample, "meta.rom_offset", (_ROM and _ROM.offset) or 0, nil, "number", 8)

    map_terrain_add_value(sample, "tile.map_name", tile.name, nil, "text")
    map_terrain_add_value(sample, "tile.map_header", tile.map, nil, "number")
    map_terrain_add_value(sample, "tile.x", tile.x, nil, "number")
    map_terrain_add_value(sample, "tile.y", tile.y, nil, "number")
    map_terrain_add_value(sample, "tile.z", tile.z, nil, "number")
    map_terrain_add_value(sample, "tile.tile_x", tile.tile_x, nil, "number")
    map_terrain_add_value(sample, "tile.tile_z", tile.tile_z, nil, "number")
    map_terrain_add_value(sample, "tile.facing", tile.facing or "", nil, "number")

    if pointers then
        map_terrain_add_pointer_value(sample, "ptr.map_header", pointers.map_header)
        map_terrain_add_pointer_value(sample, "ptr.trainer_x", pointers.trainer_x)
        map_terrain_add_pointer_value(sample, "ptr.trainer_y", pointers.trainer_y)
        map_terrain_add_pointer_value(sample, "ptr.trainer_z", pointers.trainer_z)
        map_terrain_add_pointer_value(sample, "ptr.facing", pointers.facing)
        map_terrain_add_pointer_value(sample, "ptr.bike", pointers.bike)
        map_terrain_add_pointer_value(sample, "ptr.battle_indicator", pointers.battle_indicator)
        map_terrain_add_pointer_value(sample, "ptr.fishing_bite_indicator", pointers.fishing_bite_indicator)
    end

    local anchor_addr = map_terrain_hgss_anchor_addr()
    local anchor = anchor_addr and map_terrain_safe_read_u32(anchor_addr) or nil
    if anchor_addr then
        map_terrain_add_hex_value(sample, "hgss.anchor_pointer_addr", anchor_addr, nil, "addr", 8)
        map_terrain_add_hex_value(sample, "hgss.anchor", anchor, anchor_addr, "u32", 8)
    end

    -- Small focused windows. These are intentionally bounded: enough to compare
    -- labels without doing a slow full-RAM scan inside DeSmuME.
    if pointers then
        -- Failsafe v27: tiny windows only. v26 used larger windows and an HGSS anchor window,
        -- which could freeze DeSmuME on some maps if a candidate pointer was bad.
        print("  Terrain probe phase: reading tiny known-pointer windows...")
        map_terrain_add_byte_window(sample, "win.facing", pointers.facing, 16, 16)
        map_terrain_add_word_window(sample, "win.facing", pointers.facing, 16, 16)

        map_terrain_add_byte_window(sample, "win.trainer_x", pointers.trainer_x, 16, 16)
        map_terrain_add_word_window(sample, "win.trainer_x", pointers.trainer_x, 16, 16)

        map_terrain_add_byte_window(sample, "win.trainer_z", pointers.trainer_z, 16, 16)
        map_terrain_add_word_window(sample, "win.trainer_z", pointers.trainer_z, 16, 16)

        map_terrain_add_byte_window(sample, "win.map_header", pointers.map_header, 16, 16)
        map_terrain_add_word_window(sample, "win.map_header", pointers.map_header, 16, 16)
    end

    if anchor then
        -- Failsafe v27: record the anchor value only. Do not scan anchor-relative memory here.
        -- The proper universal solution needs a game-profile terrain reader, not broad live-memory probing.
        map_terrain_add_hex_value(sample, "hgss.anchor_plus_1dc4.addr_only", anchor + 0x1DC4, nil, "addr", 8)
    end

    return sample
end

function map_terrain_serialize_sample(sample)
    local lines = {}
    local tile = sample.tile or {}

    lines[#lines + 1] = "SAMPLE|" ..
        tostring(sample.label or "unknown") .. "|" ..
        tostring(sample.time or "") .. "|" ..
        tostring(sample.frame or "") .. "|" ..
        tostring(tile.name or "") .. "|" ..
        tostring(tile.map or "") .. "|" ..
        tostring(tile.x or "") .. "|" ..
        tostring(tile.y or "") .. "|" ..
        tostring(tile.z or "")

    for _, key in ipairs(sample.order) do
        local item = sample.values[key]
        lines[#lines + 1] = "V|" .. tostring(key) .. "|" .. tostring(item.value or "") .. "|" .. tostring(item.addr or "") .. "|" .. tostring(item.kind or "")
    end

    lines[#lines + 1] = "END"
    return table.concat(lines, "\n") .. "\n"
end

function map_terrain_read_last_sample()
    local file = io.open(map_terrain_last_path(), "r")
    if not file then return nil end

    local previous = { values = {}, order = {}, header = "" }

    for line in file:lines() do
        if string.sub(line, 1, 7) == "SAMPLE|" then
            previous.header = line
        elseif string.sub(line, 1, 2) == "V|" then
            local parts = map_graph_split_pipe(line)
            local key = parts[2]
            local value = parts[3]
            if key then
                previous.values[key] = value or ""
                previous.order[#previous.order + 1] = key
            end
        end
    end

    file:close()
    return previous
end

function map_terrain_compare_samples(previous, current)
    local diffs = {}
    if not previous or not previous.values then return diffs end

    for _, key in ipairs(current.order) do
        local old_value = previous.values[key]
        local item = current.values[key]
        local new_value = item and item.value or nil

        if old_value ~= nil and new_value ~= nil and old_value ~= new_value then
            diffs[#diffs + 1] = {
                key = key,
                old_value = old_value,
                new_value = new_value,
                addr = item.addr or "",
                kind = item.kind or ""
            }
        end
    end

    return diffs
end

function map_terrain_write_text(path, text, mode)
    local file = io.open(path, mode or "w")
    if not file then
        abort("Could not open terrain probe file: " .. tostring(path))
    end

    file:write(text)
    file:close()
end

function map_terrain_write_sample(sample, diffs, previous)
    route_make_folder()

    local serialized = map_terrain_serialize_sample(sample)
    map_terrain_write_text(map_terrain_samples_path(), serialized, "a")
    map_terrain_write_text(map_terrain_last_path(), serialized, "w")

    local lines = {}
    lines[#lines + 1] = "# Terrain Probe diff"
    lines[#lines + 1] = "# Current: " .. tostring(sample.label or "unknown") .. " | " .. tostring(sample.time or "")
    if previous and previous.header then
        lines[#lines + 1] = "# Previous: " .. tostring(previous.header)
    else
        lines[#lines + 1] = "# Previous: none"
    end
    lines[#lines + 1] = "# Changed candidate values: " .. tostring(#diffs)

    for i, diff in ipairs(diffs) do
        lines[#lines + 1] = "D|" .. tostring(diff.key) .. "|" .. tostring(diff.old_value) .. "|" .. tostring(diff.new_value) .. "|" .. tostring(diff.addr) .. "|" .. tostring(diff.kind)
    end

    map_terrain_write_text(map_terrain_diff_path(), table.concat(lines, "\n") .. "\n", "w")
end

function map_terrain_print_diff_preview(diffs, max_lines)
    max_lines = tonumber(max_lines) or 20

    if #diffs == 0 then
        print("Compared with previous terrain sample: no candidate values changed.")
        return
    end

    print("Compared with previous terrain sample: " .. tostring(#diffs) .. " candidate value(s) changed.")
    print("Showing first " .. tostring(math.min(max_lines, #diffs)) .. " diff(s):")

    for i = 1, math.min(max_lines, #diffs) do
        local diff = diffs[i]
        print(
            "  " .. tostring(i) .. ". " .. tostring(diff.key) ..
            " | " .. tostring(diff.old_value) .. " -> " .. tostring(diff.new_value) ..
            " | " .. tostring(diff.addr) ..
            " | " .. tostring(diff.kind)
        )
    end
end

function mode_map_terrain_probe()
    perf_start("map_terrain_probe_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_terrain_probe: not in game.")
    end

    route_release_direction_buttons()

    local label = map_terrain_clean_label(config.map_terrain_label or "unknown")
    local tile = map_terrain_current_tile()

    print("Map Terrain Probe Investigation v0.2 Failsafe")
    print("This does not move. Failsafe mode avoids wide/unsafe memory scans so the emulator should not freeze.")
    print("Sample label: " .. tostring(label))
    print(
        "Current tile: " .. tostring(tile.name or "") ..
        " map " .. tostring(tile.map or "") ..
        " X " .. tostring(tile.x or "") ..
        " Y " .. tostring(tile.y or "") ..
        " Z " .. tostring(tile.z or "") ..
        " | tile_x=" .. tostring(tile.tile_x or "") ..
        " tile_z=" .. tostring(tile.tile_z or "") ..
        " facing=" .. tostring(tile.facing or "")
    )

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    perf_start("map_terrain_probe_collect")
    local sample = map_terrain_collect_sample(label)
    perf_stop("map_terrain_probe_collect")

    local previous = map_terrain_read_last_sample()
    local diffs = map_terrain_compare_samples(previous, sample)

    perf_start("map_terrain_probe_write")
    map_terrain_write_sample(sample, diffs, previous)
    perf_stop("map_terrain_probe_write")

    print("Terrain sample values captured: " .. tostring(#sample.order))
    map_terrain_print_diff_preview(diffs, 20)
    print("Saved sample append: " .. map_terrain_samples_path())
    print("Saved latest sample: " .. map_terrain_last_path())
    print("Saved latest diff: " .. map_terrain_diff_path())

    local exact_info = map_terrain_observe_current_exact(false)
    print("Exact terrain provider: " .. map_terrain_surface_summary(exact_info))
    if exact_info and exact_info.exact then
        print("Recorded exact seen-tile terrain: " .. map_terrain_exact_db_path())
    end

    print("Next step: use exact HGSS behavior codes / exact seen-tile DB for planning. Manual labels are only seed labels for known sampled tiles.")
    print("Recommended labels: road, tall_grass, cave_floor, building_floor, water_edge, ledge_top, ledge_bottom, door_warp.")

    perf_stop("map_terrain_probe_total")
    abort("Map Terrain Probe finished.")
end


-----------------------------------------------------------------------------
-- v40.6 Exact Tile Atlas + Log Discipline
--
-- Terrain is now handled as a small game-profile provider system:
--   1) read the exact live tile behavior code for the current tile, if the
--      active game profile supports it;
--   2) map the raw behavior code through a per-game behavior table;
--   3) decode codes through a clean per-game surface taxonomy;
--   4) store only exact observed tile facts in an exact seen-tile atlas;
--   5) use the seen-tile atlas for planning already-visited tiles;
--   6) leave unknown future tiles unknown instead of guessing from map name,
--      manual labels, old samples, or battle history.
--
-- Current exact profile:
--   HGSS / Storm Silver: pointers.map_header + 0x10, u16 behavior code.
--   Proven samples: 0x0000 = path, 0x0002 = tall_grass.
--
-- Cross-game policy:
--   Other games must add a profile with an exact current-tile behavior reader.
--   The architecture is ready for more games; it will not fake exact terrain on
--   unsupported games.
-----------------------------------------------------------------------------

_MAP_TERRAIN_EXACT_CACHE = _MAP_TERRAIN_EXACT_CACHE or nil
_MAP_TERRAIN_EXACT_CACHE_LOADED = _MAP_TERRAIN_EXACT_CACHE_LOADED or false
_MAP_TERRAIN_PROFILES = _MAP_TERRAIN_PROFILES or {}
_MAP_TERRAIN_PROFILE_INIT_DONE = _MAP_TERRAIN_PROFILE_INIT_DONE or false
_MAP_TERRAIN_RUN_SURFACE_COUNTS = _MAP_TERRAIN_RUN_SURFACE_COUNTS or {}
_MAP_TERRAIN_LEGACY_SAMPLE_IMPORT_ENABLED = false

function map_terrain_exact_db_path()
    return "user\\routes\\map_terrain_exact_tiles.tsv"
end

function map_terrain_game_id()
    local version = (_ROM and _ROM.version) or "UNK"
    local language = (_ROM and _ROM.language) or "UNK"
    return tostring(version) .. "_" .. tostring(language)
end

function map_terrain_floor_tile(value)
    local n = tonumber(value) or 0
    return math.floor(n + 0.0001)
end

function map_terrain_tile_key(point)
    if not point then return "" end
    return table.concat({
        map_terrain_game_id(),
        tostring(tonumber(point.map) or 0),
        tostring(map_terrain_floor_tile(point.x)),
        tostring(map_terrain_floor_tile(point.z))
    }, "|")
end

function map_terrain_behavior_hex(code)
    if code == nil then return "NA" end
    return map_terrain_hex(tonumber(code) or 0, 4)
end

function map_terrain_tags_text(tags)
    if type(tags) ~= "table" then return "" end
    local out = {}
    for _, tag in ipairs(tags) do
        if tag and tostring(tag) ~= "" then out[#out + 1] = tostring(tag) end
    end
    return table.concat(out, ",")
end

function map_terrain_surface_bucket(entry)
    if not entry then return "unknown" end
    if entry.encounter_risk == true then return "encounter" end
    local category = tostring(entry.category or "")
    if category == "walkable_safe" then return "safe" end
    if category == "warp" or category == "door" or category == "transition" then return "transition" end
    if category == "water" then return "water" end
    if category == "ledge" then return "ledge" end
    if category == "obstacle" or category == "blocked" then return "blocked" end
    return "unknown"
end

function map_terrain_register_profile(key, profile)
    key = tostring(key or "")
    if key == "" or type(profile) ~= "table" then return false end
    profile.key = key
    _MAP_TERRAIN_PROFILES[key] = profile
    return true
end

function map_terrain_init_profiles()
    if _MAP_TERRAIN_PROFILE_INIT_DONE then return end
    _MAP_TERRAIN_PROFILE_INIT_DONE = true

    map_terrain_register_profile("HGSS", {
        label = "HeartGold/SoulSilver / Storm Silver",
        provider = "hgss_live_tile_behavior_v2",
        exact_current_only = true,
        versions = { HG = true, SS = true },
        behavior_addr = function()
            if not pointers or not pointers.map_header then return nil end
            return pointers.map_header + 0x10
        end,
        read_behavior = function()
            if not pointers or not pointers.map_header then return nil, nil, "pointers_missing" end
            local addr = pointers.map_header + 0x10
            local code = map_terrain_safe_read_u16(addr)
            if code == nil then return nil, addr, "read_failed" end
            return code, addr, "ok"
        end,
        behavior_map = {
            -- Proven exact HGSS/Storm Silver behavior codes from live provider.
            -- Add future codes here only after exact behavior-code evidence, never from
            -- map names, encounter guesses, or manual screenshot labels.
            [0x0000] = {
                surface = "path",
                family = "safe_path",
                category = "walkable_safe",
                walkability = "walkable",
                tile_class = "ground",
                movement_cost = 0,
                encounter_risk = false,
                avoid_cost = 0,
                tags = { "ground", "safe", "walkable" }
            },
            [0x0002] = {
                surface = "tall_grass",
                family = "encounter_grass",
                category = "walkable_encounter",
                walkability = "walkable",
                tile_class = "grass",
                movement_cost = 120,
                encounter_risk = true,
                avoid_cost = 120,
                tags = { "ground", "encounter", "grass", "walkable" }
            }
        }
    })
end

function map_terrain_profile_for_current_game()
    map_terrain_init_profiles()
    local version = (_ROM and _ROM.version) or ""
    for _, profile in pairs(_MAP_TERRAIN_PROFILES or {}) do
        if profile.versions and profile.versions[version] then
            return profile
        end
    end
    return nil
end

function map_terrain_profile_list_text()
    map_terrain_init_profiles()
    local names = {}
    for key, _ in pairs(_MAP_TERRAIN_PROFILES or {}) do names[#names + 1] = tostring(key) end
    table.sort(names)
    return table.concat(names, ",")
end

function map_terrain_decode_behavior(code, profile)
    code = tonumber(code)
    profile = profile or map_terrain_profile_for_current_game()
    if code == nil then
        return { surface = "unknown", family = "unknown", category = "unknown", movement_cost = 0, encounter_risk = false, avoid_cost = 0, mapped = false }
    end

    local entry = profile and profile.behavior_map and profile.behavior_map[code] or nil
    if entry then
        return {
            surface = tostring(entry.surface or "unknown"),
            family = tostring(entry.family or entry.category or "unknown"),
            category = tostring(entry.category or entry.family or "unknown"),
            movement_cost = tonumber(entry.movement_cost or entry.avoid_cost or 0) or 0,
            encounter_risk = entry.encounter_risk == true,
            avoid_cost = tonumber(entry.avoid_cost or entry.movement_cost or 0) or 0,
            walkability = tostring(entry.walkability or "unknown"),
            tile_class = tostring(entry.tile_class or entry.family or "unknown"),
            tags = entry.tags or {},
            bucket = map_terrain_surface_bucket(entry),
            mapped = true
        }
    end

    return {
        surface = "unknown_behavior_" .. map_terrain_behavior_hex(code),
        family = "unknown_exact_behavior",
        category = "unknown_exact_behavior",
        movement_cost = 0,
        encounter_risk = false,
        avoid_cost = 0,
        walkability = "unknown",
        tile_class = "unknown",
        tags = { "exact", "unmapped" },
        bucket = "unknown",
        mapped = false
    }
end

function map_terrain_build_surface_info(point, code, source, exact, addr, provider_key, provider_state)
    point = point or {}
    local profile = provider_key and _MAP_TERRAIN_PROFILES and _MAP_TERRAIN_PROFILES[provider_key] or map_terrain_profile_for_current_game()
    local decoded = map_terrain_decode_behavior(code, profile)
    local confidence = "unknown"
    if exact == true and code ~= nil and decoded.mapped then
        confidence = "exact_code_mapped"
    elseif exact == true and code ~= nil and not decoded.mapped then
        confidence = "exact_code_unmapped"
    elseif source == "provider_unavailable" or source == "no_exact_profile" then
        confidence = "no_exact_provider"
    elseif source == "exact_db_miss" then
        confidence = "not_seen_yet"
    end

    return {
        exact = exact == true,
        source = tostring(source or "unknown"),
        provider_key = tostring(provider_key or (profile and profile.key) or "none"),
        provider = tostring((profile and profile.provider) or "none"),
        provider_state = tostring(provider_state or ""),
        game_id = map_terrain_game_id(),
        map = tonumber(point.map) or 0,
        map_name = tostring(point.name or ""),
        x = tonumber(point.x) or 0,
        y = tonumber(point.y) or 0,
        z = tonumber(point.z) or 0,
        tile_x = map_terrain_floor_tile(point.x),
        tile_z = map_terrain_floor_tile(point.z),
        behavior_code = tonumber(code),
        behavior_hex = map_terrain_behavior_hex(code),
        behavior_addr = addr and map_terrain_hex(addr, 8) or "",
        surface = decoded.surface,
        family = decoded.family,
        category = decoded.category,
        movement_cost = decoded.movement_cost,
        encounter_risk = decoded.encounter_risk == true,
        avoid_cost = decoded.avoid_cost,
        walkability = tostring(decoded.walkability or "unknown"),
        tile_class = tostring(decoded.tile_class or decoded.family or "unknown"),
        surface_bucket = tostring(decoded.bucket or "unknown"),
        tags = decoded.tags or {},
        tags_text = map_terrain_tags_text(decoded.tags or {}),
        code_mapped = decoded.mapped == true,
        confidence = confidence,
        key = map_terrain_tile_key(point)
    }
end

function map_terrain_current_exact_surface()
    local point = map_terrain_current_tile and map_terrain_current_tile() or (map_probe_current_point and map_probe_current_point() or nil)
    if not point then
        return map_terrain_build_surface_info({}, nil, "provider_unavailable", false, nil, "none", "no_position")
    end

    local profile = map_terrain_profile_for_current_game()
    if not profile or not profile.read_behavior then
        return map_terrain_build_surface_info(point, nil, "no_exact_profile", false, nil, "none", "unsupported_game:" .. tostring((_ROM and _ROM.version) or "UNK"))
    end

    local code, addr, state = profile.read_behavior()
    if code == nil then
        return map_terrain_build_surface_info(point, nil, "provider_unavailable", false, addr, profile.key, state or "read_failed")
    end

    return map_terrain_build_surface_info(point, code, "live_exact_behavior", true, addr, profile.key, state or "ok")
end

function map_terrain_split_tsv(line)
    local out = {}
    line = tostring(line or "")
    for part in string.gmatch(line .. "\t", "(.-)\t") do
        out[#out + 1] = part
    end
    return out
end

function map_terrain_cache_put(info)
    if not info or not info.key or info.key == "" then return end
    _MAP_TERRAIN_EXACT_CACHE = _MAP_TERRAIN_EXACT_CACHE or {}
    _MAP_TERRAIN_EXACT_CACHE[info.key] = info
end

function map_terrain_load_exact_db_file()
    local path = map_terrain_exact_db_path()
    local file = io.open(path, "r")
    if not file then return end

    for line in file:lines() do
        if line ~= "" and not string.find(line, "^game_id\t") then
            local p = map_terrain_split_tsv(line)
            local point = { name = p[3] or "", map = tonumber(p[2]) or 0, x = tonumber(p[4]) or 0, y = 0, z = tonumber(p[5]) or 0 }
            local code = tonumber(p[6])
            local info = map_terrain_build_surface_info(point, code, p[8] or "exact_db", true, nil, p[11] or nil, "loaded_db")
            info.seen_count = tonumber(p[10]) or 1
            map_terrain_cache_put(info)
        end
    end

    file:close()
end

function map_terrain_load_samples_as_exact_db()
    -- v40.6: legacy terrain samples are no longer imported into the active
    -- exact-tile atlas. They remain available only as developer evidence for
    -- discovering new behavior codes. Active terrain truth must come from a
    -- live exact provider or the exact seen-tile atlas written by that provider.
    return 0
end

function map_terrain_ensure_exact_cache()
    if _MAP_TERRAIN_EXACT_CACHE_LOADED then return end
    _MAP_TERRAIN_EXACT_CACHE = {}
    map_terrain_init_profiles()
    map_terrain_load_samples_as_exact_db()
    map_terrain_load_exact_db_file()
    _MAP_TERRAIN_EXACT_CACHE_LOADED = true
end

function map_terrain_lookup_exact(point)
    map_terrain_ensure_exact_cache()
    if not point then return map_terrain_build_surface_info({}, nil, "no_point", false, nil, "none", "no_point") end

    if game_state and game_state.in_game then
        local cp = map_probe_current_point and map_probe_current_point() or nil
        if cp and tonumber(cp.map) == tonumber(point.map)
            and map_terrain_floor_tile(cp.x) == map_terrain_floor_tile(point.x)
            and map_terrain_floor_tile(cp.z) == map_terrain_floor_tile(point.z) then
            local current = map_terrain_current_exact_surface()
            if current and current.exact then
                map_terrain_cache_put(current)
                return current
            end
        end
    end

    local key = map_terrain_tile_key(point)
    local cached = _MAP_TERRAIN_EXACT_CACHE and _MAP_TERRAIN_EXACT_CACHE[key]
    if cached then return cached end
    return map_terrain_build_surface_info(point, nil, "exact_seen_db_miss", false, nil, "none", "not_seen")
end

function map_terrain_db_line(info)
    return table.concat({
        tostring(info.game_id or map_terrain_game_id()),
        tostring(info.map or 0),
        tostring(info.map_name or ""),
        tostring(info.tile_x or map_terrain_floor_tile(info.x)),
        tostring(info.tile_z or map_terrain_floor_tile(info.z)),
        tostring(info.behavior_code or ""),
        tostring(info.surface or "unknown"),
        tostring(info.source or "unknown"),
        tostring(info.last_frame or (emu.framecount and emu.framecount() or 0)),
        tostring(info.seen_count or 1),
        tostring(info.provider_key or "none"),
        tostring(info.confidence or "unknown"),
        tostring(info.category or "unknown"),
        tostring(info.avoid_cost or 0),
        tostring(info.walkability or "unknown"),
        tostring(info.tile_class or "unknown"),
        tostring(info.surface_bucket or "unknown"),
        tostring(info.tags_text or "")
    }, "\t") .. "\n"
end

function map_terrain_count_surface_seen(info, reason)
    if not info or not info.exact then return end
    _MAP_TERRAIN_RUN_SURFACE_COUNTS = _MAP_TERRAIN_RUN_SURFACE_COUNTS or {}
    local key = tostring(info.surface or "unknown") .. ":" .. tostring(info.behavior_hex or "NA")
    local bucket = _MAP_TERRAIN_RUN_SURFACE_COUNTS[key] or { surface = tostring(info.surface or "unknown"), code = tostring(info.behavior_hex or "NA"), count = 0, reasons = {} }
    bucket.count = (tonumber(bucket.count) or 0) + 1
    if reason and tostring(reason) ~= "" then bucket.reasons[tostring(reason)] = true end
    _MAP_TERRAIN_RUN_SURFACE_COUNTS[key] = bucket
end

function map_terrain_record_exact_surface(info, reason)
    if not info or not info.exact then return false end
    map_terrain_count_surface_seen(info, reason)
    route_make_folder()
    map_terrain_ensure_exact_cache()

    local prior = _MAP_TERRAIN_EXACT_CACHE and _MAP_TERRAIN_EXACT_CACHE[info.key]
    if prior and tonumber(prior.behavior_code) == tonumber(info.behavior_code) and tostring(prior.surface) == tostring(info.surface) then
        prior.seen_count = (tonumber(prior.seen_count) or 1) + 1
        return false
    end

    info.last_frame = emu.framecount and emu.framecount() or 0
    info.seen_count = prior and ((tonumber(prior.seen_count) or 1) + 1) or 1
    local path = map_terrain_exact_db_path()
    local exists = io.open(path, "r")
    if exists then exists:close() end
    local file = io.open(path, "a")
    if not file then return false end
    if not exists then
        file:write("game_id\tmap_header\tmap_name\ttile_x\ttile_z\tbehavior_code\tsurface\tsource\tlast_frame\tseen_count\tprovider_key\tconfidence\tcategory\tavoid_cost\twalkability\ttile_class\tsurface_bucket\ttags\n")
    end
    file:write(map_terrain_db_line(info))
    file:close()
    map_terrain_cache_put(info)
    return true
end

function map_terrain_observe_current_exact(log_line, reason)
    local info = map_terrain_current_exact_surface()
    if info and info.exact then
        map_terrain_record_exact_surface(info, reason or "observe")
    end
    if log_line then
        print("Surface: " .. map_terrain_surface_summary(info))
    end
    return info
end

function map_terrain_neighbor_point(point, dir)
    if not point then return nil end
    local out = { name = point.name, map = point.map, x = tonumber(point.x) or 0, y = tonumber(point.y) or 0, z = tonumber(point.z) or 0 }
    if dir == "Up" then out.z = out.z - 1
    elseif dir == "Down" then out.z = out.z + 1
    elseif dir == "Left" then out.x = out.x - 1
    elseif dir == "Right" then out.x = out.x + 1 end
    return out
end

function map_terrain_surface_summary(info)
    if not info then return "unknown source=none" end
    local exact = info.exact and "exact" or "unknown"
    return tostring(info.surface or "unknown") ..
        " | " .. exact ..
        " | source=" .. tostring(info.source or "unknown") ..
        " | provider=" .. tostring(info.provider_key or "none") ..
        " | code=" .. tostring(info.behavior_hex or "NA") ..
        " | class=" .. tostring(info.tile_class or "unknown") ..
        " | bucket=" .. tostring(info.surface_bucket or "unknown") ..
        " | confidence=" .. tostring(info.confidence or "unknown") ..
        ((info.behavior_addr and info.behavior_addr ~= "") and (" | addr=" .. tostring(info.behavior_addr)) or "")
end

function map_terrain_surface_compact(info)
    if not info then return "unknown(unknown,NA,none)" end
    local exact = info.exact and "exact" or "unknown"
    return tostring(info.surface or "unknown") ..
        "(" .. exact .. "," .. tostring(info.behavior_hex or "NA") .. "," .. tostring(info.provider_key or "none") .. ")"
end

function map_terrain_surface_plan_text(info)
    if not info then return "unknown:NA" end
    local exact = info.exact and "exact" or "unknown"
    return tostring(info.surface or "unknown") .. ":" .. tostring(info.behavior_hex or "NA") .. ":" .. exact
end

function map_terrain_run_surface_summary()
    local counts = _MAP_TERRAIN_RUN_SURFACE_COUNTS or {}
    local parts = {}
    for _, item in pairs(counts) do
        parts[#parts + 1] = tostring(item.surface) .. "(" .. tostring(item.code) .. ")x" .. tostring(item.count or 0)
    end
    table.sort(parts)
    if #parts == 0 then return "none" end
    return table.concat(parts, ", ")
end

function map_terrain_run_unmapped_summary()
    local counts = _MAP_TERRAIN_RUN_SURFACE_COUNTS or {}
    local parts = {}
    for _, item in pairs(counts) do
        local surface = tostring(item.surface or "")
        if string.find(surface, "unknown_behavior_", 1, true) then
            parts[#parts + 1] = tostring(item.code or "NA") .. "x" .. tostring(item.count or 0)
        end
    end
    table.sort(parts)
    if #parts == 0 then return "none" end
    return table.concat(parts, ", ")
end

function map_terrain_plan_surface_cost(info, role)
    if not info then return 0, "surface_unknown", { surface = "unknown", code = "NA", exact = false, source = "none", category = "unknown" } end
    role = tostring(role or "stand")
    local penalty = 0
    local reason = ""

    if info.exact then
        if info.encounter_risk == true or tostring(info.category) == "walkable_encounter" then
            penalty = penalty + (role == "probe" and 120 or 80)
            reason = "exact_" .. role .. "_encounter_surface"
        elseif tostring(info.category) == "walkable_safe" or tostring(info.family) == "safe_path" then
            penalty = penalty - (role == "probe" and 6 or 3)
            reason = "exact_" .. role .. "_safe_surface"
        elseif tostring(info.confidence) == "exact_code_unmapped" then
            penalty = penalty + 8
            reason = "exact_" .. role .. "_unmapped_behavior"
        else
            reason = "exact_" .. role .. "_neutral_surface"
        end
    else
        reason = role .. "_surface_not_seen"
    end

    return penalty, reason, {
        surface = tostring(info.surface or "unknown"),
        code = tostring(info.behavior_hex or "NA"),
        exact = info.exact == true,
        source = tostring(info.source or "unknown"),
        provider = tostring(info.provider_key or "none"),
        category = tostring(info.category or "unknown"),
        confidence = tostring(info.confidence or "unknown"),
        walkability = tostring(info.walkability or "unknown"),
        tile_class = tostring(info.tile_class or "unknown"),
        surface_bucket = tostring(info.surface_bucket or "unknown"),
        tags = tostring(info.tags_text or ""),
        avoid_cost = tonumber(info.avoid_cost or 0) or 0
    }
end

function map_terrain_provider_status()
    local info = map_terrain_current_exact_surface()
    map_terrain_ensure_exact_cache()
    local count = 0
    for _ in pairs(_MAP_TERRAIN_EXACT_CACHE or {}) do count = count + 1 end
    local profile = map_terrain_profile_for_current_game()
    return {
        version = nav_version and nav_version() or "unknown",
        provider = profile and profile.provider or "none",
        provider_key = profile and profile.key or "none",
        supported_profiles = map_terrain_profile_list_text(),
        live_available = info and info.exact == true,
        current = info,
        exact_seen_tiles = count,
        db_path = map_terrain_exact_db_path(),
        samples_path = map_terrain_samples_path(),
        policy = "Current tile terrain is exact only when a game profile provides a raw behavior code. Seen tiles are cached as exact facts in the active atlas. Unknown future tiles remain unknown. Manual labels, old samples, map names, and battle history are not terrain truth."
    }
end
