-----------------------------------------------------------------------------
-- nav_planner.lua
-- Baritone-lite Goal-Directed Frontier Planner + exact tile capability integration.
--
-- This is still intentionally bounded to local/same-map learning, but it is no
-- longer just "pick a nearby frontier." It scores reachable frontier clusters,
-- detects when the current patch is saturated, suppresses repeated targets, and
-- adds goal-directed frontier scoring, repeated-target suppression, battle-risk memory,
-- and game-profile exact tile/surface/capability costs. Unknown future tiles remain unknown; no manual label/map-name/battle terrain inference.
-----------------------------------------------------------------------------

_MAP_EXPLORE_PLANNER_STATE = _MAP_EXPLORE_PLANNER_STATE or {}
_MAP_EXPLORE_PLANNER_STATE.last_dir = _MAP_EXPLORE_PLANNER_STATE.last_dir or nil
_MAP_EXPLORE_PLANNER_STATE.last_status = _MAP_EXPLORE_PLANNER_STATE.last_status or nil
_MAP_EXPLORE_PLANNER_STATE.last_point = _MAP_EXPLORE_PLANNER_STATE.last_point or nil
_MAP_EXPLORE_PLANNER_STATE.blocked_history = _MAP_EXPLORE_PLANNER_STATE.blocked_history or {}
_MAP_EXPLORE_PLANNER_STATE.target_history = _MAP_EXPLORE_PLANNER_STATE.target_history or {}
_MAP_EXPLORE_PLANNER_STATE.battle_history = _MAP_EXPLORE_PLANNER_STATE.battle_history or {}
_MAP_EXPLORE_PLANNER_STATE.action_count = _MAP_EXPLORE_PLANNER_STATE.action_count or 0
_MAP_EXPLORE_PLANNER_STATE.last_plan = _MAP_EXPLORE_PLANNER_STATE.last_plan or nil
_MAP_EXPLORE_PLANNER_STATE.local_saturation = _MAP_EXPLORE_PLANNER_STATE.local_saturation or nil

function map_explore_strategy()
    local value = tostring((config and config.map_explore_strategy) or "coverage_planner")
    if value == "simple_frontier" or value == "nearest_frontier" then
        return "simple_frontier"
    end
    return "goal_directed_frontier"
end

function map_explore_planner_enabled()
    return map_explore_strategy() ~= "simple_frontier"
end

function map_planner_axis_for_dir(dir)
    if dir == "Up" or dir == "Down" then
        return "z"
    elseif dir == "Left" or dir == "Right" then
        return "x"
    end
    return "none"
end

function map_planner_cross_axis_for_dir(dir)
    if dir == "Up" or dir == "Down" then
        return "x"
    elseif dir == "Left" or dir == "Right" then
        return "z"
    end
    return "none"
end

function map_planner_expected_block_line(point, dir)
    if not point then return 0 end
    local x = tonumber(point.x) or 0
    local z = tonumber(point.z) or 0
    if dir == "Up" then return z - 1
    elseif dir == "Down" then return z + 1
    elseif dir == "Left" then return x - 1
    elseif dir == "Right" then return x + 1 end
    return 0
end

function map_planner_cross_value(point, dir)
    if not point then return 0 end
    if dir == "Up" or dir == "Down" then return tonumber(point.x) or 0
    elseif dir == "Left" or dir == "Right" then return tonumber(point.z) or 0 end
    return 0
end

function map_planner_same_map(a, b)
    if not a or not b then return false end
    return tonumber(a.map) == tonumber(b.map)
end

function map_planner_point_key(point)
    if not point then return "unknown" end
    return tostring(tonumber(point.map) or 0) .. "|" .. tostring(math.floor((tonumber(point.x) or 0) + 0.5)) .. "|" .. tostring(math.floor((tonumber(point.z) or 0) + 0.5))
end

function map_planner_target_key(point, dir)
    return map_planner_point_key(point) .. "|" .. tostring(dir or "?")
end

function map_planner_region_key(point, size)
    size = tonumber(size) or 4
    if not point then return "unknown" end
    local x = math.floor((tonumber(point.x) or 0) / size) * size
    local z = math.floor((tonumber(point.z) or 0) / size) * size
    return tostring(tonumber(point.map) or 0) .. "|" .. tostring(x) .. "|" .. tostring(z)
end

function map_planner_manhattan(a, b)
    if not a or not b then return 9999 end
    if not map_planner_same_map(a, b) then return 9999 end
    return math.abs((tonumber(a.x) or 0) - (tonumber(b.x) or 0)) + math.abs((tonumber(a.z) or 0) - (tonumber(b.z) or 0))
end

function map_planner_exact_surface_penalty(candidate, dir)
    local node = candidate and candidate.node or nil
    local stand = map_terrain_lookup_exact and map_terrain_lookup_exact(node) or nil
    local probe_point = map_terrain_neighbor_point and map_terrain_neighbor_point(node, dir) or nil
    local probe = map_terrain_lookup_exact and map_terrain_lookup_exact(probe_point) or nil

    local stand_penalty, stand_reason, stand_debug = 0, "stand_surface_unknown", nil
    local probe_penalty, probe_reason, probe_debug = 0, "probe_surface_unknown", nil

    if map_terrain_plan_surface_cost then
        stand_penalty, stand_reason, stand_debug = map_terrain_plan_surface_cost(stand, "stand")
        probe_penalty, probe_reason, probe_debug = map_terrain_plan_surface_cost(probe, "probe")
    else
        if stand and stand.exact and (stand.encounter_risk == true or tostring(stand.surface) == "tall_grass") then
            stand_penalty, stand_reason = 80, "exact_stand_encounter_surface"
        elseif stand and stand.exact then
            stand_reason = "exact_stand_surface"
        end
        if probe and probe.exact and (probe.encounter_risk == true or tostring(probe.surface) == "tall_grass") then
            probe_penalty, probe_reason = 120, "exact_probe_encounter_surface"
        elseif probe and probe.exact then
            probe_reason = "exact_probe_surface"
        end
        stand_debug = { surface = stand and stand.surface or "unknown", code = stand and stand.behavior_hex or "NA", exact = stand and stand.exact == true, source = stand and stand.source or "none", provider = stand and stand.provider_key or "none", category = stand and stand.category or "unknown", confidence = stand and stand.confidence or "unknown", surface_bucket = stand and stand.surface_bucket or "unknown" }
        probe_debug = { surface = probe and probe.surface or "unknown", code = probe and probe.behavior_hex or "NA", exact = probe and probe.exact == true, source = probe and probe.source or "none", provider = probe and probe.provider_key or "none", category = probe and probe.category or "unknown", confidence = probe and probe.confidence or "unknown", surface_bucket = probe and probe.surface_bucket or "unknown" }
    end

    local penalty = (tonumber(stand_penalty) or 0) + (tonumber(probe_penalty) or 0)
    local reasons = {}
    if stand_reason and stand_reason ~= "" then reasons[#reasons + 1] = stand_reason end
    if probe_reason and probe_reason ~= "" then reasons[#reasons + 1] = probe_reason end

    local stand_exact = (stand_debug and stand_debug.exact) and "exact" or "unknown"
    local probe_exact = (probe_debug and probe_debug.exact) and "exact" or "unknown"
    local surface_text = "stand=" .. tostring(stand_debug and stand_debug.surface or "unknown") ..
        ":" .. tostring(stand_debug and stand_debug.code or "NA") .. ":" .. stand_exact ..
        "/probe=" .. tostring(probe_debug and probe_debug.surface or "unknown") ..
        ":" .. tostring(probe_debug and probe_debug.code or "NA") .. ":" .. probe_exact

    return penalty, table.concat(reasons, ";"), {
        surface_hint = surface_text,
        stand_surface = stand_debug and stand_debug.surface or "unknown",
        stand_surface_source = stand_debug and stand_debug.source or "none",
        stand_surface_exact = stand_debug and stand_debug.exact == true,
        stand_surface_code = stand_debug and stand_debug.code or "NA",
        stand_surface_provider = stand_debug and stand_debug.provider or "none",
        stand_surface_confidence = stand_debug and stand_debug.confidence or "unknown",
        probe_surface = probe_debug and probe_debug.surface or "unknown",
        probe_surface_source = probe_debug and probe_debug.source or "none",
        probe_surface_exact = probe_debug and probe_debug.exact == true,
        probe_surface_code = probe_debug and probe_debug.code or "NA",
        probe_surface_provider = probe_debug and probe_debug.provider or "none",
        probe_surface_confidence = probe_debug and probe_debug.confidence or "unknown",
        surface_penalty = penalty
    }
end

function map_planner_candidate_unknown_count(candidate)
    if not candidate then return 0 end
    if candidate.unknown_count then return tonumber(candidate.unknown_count) or 0 end
    return #(candidate.unknown_dirs or {})
end

function map_planner_record_block(point, dir)
    if not point or not dir then return end
    local history = _MAP_EXPLORE_PLANNER_STATE.blocked_history
    history[#history + 1] = {
        map = tonumber(point.map) or 0,
        name = tostring(point.name or ""),
        x = tonumber(point.x) or 0,
        z = tonumber(point.z) or 0,
        dir = tostring(dir),
        line = map_planner_expected_block_line(point, dir),
        cross = map_planner_cross_value(point, dir),
        action = _MAP_EXPLORE_PLANNER_STATE.action_count or 0
    }
    while #history > 64 do table.remove(history, 1) end
end

function map_planner_record_battle(point, dir)
    if not point or not dir then return end
    local history = _MAP_EXPLORE_PLANNER_STATE.battle_history
    history[#history + 1] = {
        map = tonumber(point.map) or 0,
        x = tonumber(point.x) or 0,
        z = tonumber(point.z) or 0,
        dir = tostring(dir),
        action = _MAP_EXPLORE_PLANNER_STATE.action_count or 0,
        key = map_planner_target_key(point, dir),
        region = map_planner_region_key(point, 5)
    }
    while #history > 48 do table.remove(history, 1) end
end

function map_planner_boundary_cluster(point, dir)
    if not point or not dir then return 0, 0 end
    local line = map_planner_expected_block_line(point, dir)
    local cross = map_planner_cross_value(point, dir)
    local count = 0
    local closest = 999
    for _, item in ipairs(_MAP_EXPLORE_PLANNER_STATE.blocked_history or {}) do
        if tostring(item.dir) == tostring(dir) and tonumber(item.map) == tonumber(point.map) then
            local line_delta = math.abs((tonumber(item.line) or 0) - line)
            local cross_delta = math.abs((tonumber(item.cross) or 0) - cross)
            if line_delta <= 0.45 and cross_delta <= 4.25 then
                count = count + 1
                if cross_delta < closest then closest = cross_delta end
            end
        end
    end
    return count, closest
end

function map_planner_gap_recheck(point, dir, cycle_index)
    local cross = math.floor(math.abs(map_planner_cross_value(point, dir)) + 0.5)
    local line = math.floor(math.abs(map_planner_expected_block_line(point, dir)) + 0.5)
    local action = tonumber(cycle_index or _MAP_EXPLORE_PLANNER_STATE.action_count or 0) or 0
    return ((cross + line + action) % 4) == 0
end

function map_planner_boundary_penalty(point, dir, cycle_index)
    local count, closest = map_planner_boundary_cluster(point, dir)
    if count < 2 then return 0, "none" end
    if map_planner_gap_recheck(point, dir, cycle_index) then
        if closest and closest >= 2.20 then return -8 + math.min(count, 4), "gap_recheck_due" end
        return 8 + math.min(count * 2, 10), "gap_recheck_close"
    end
    return 110 + math.min(count * 12, 55), "soft_boundary"
end

function map_planner_direction_bias(dir)
    local state = _MAP_EXPLORE_PLANNER_STATE
    local score = 0
    local reasons = {}
    if state.last_status == "walkable" and state.last_dir == dir then
        score = score - 8
        reasons[#reasons + 1] = "continue_lane_light"
    elseif state.last_status == "blocked" and state.last_dir == dir then
        score = score + 70
        reasons[#reasons + 1] = "avoid_repeat_block"
    elseif state.last_status == "battle" and state.last_dir == dir then
        score = score + 45
        reasons[#reasons + 1] = "avoid_repeat_battle_dir"
    end
    if state.last_dir and map_probe_opposite_direction and map_probe_opposite_direction(state.last_dir) == dir then
        score = score + 10
        reasons[#reasons + 1] = "avoid_immediate_backtrack"
    end
    if dir == "Right" or dir == "Left" then
        score = score - 1
        reasons[#reasons + 1] = "lane_bias"
    end
    return score, table.concat(reasons, ",")
end

function map_planner_recent_target_penalty(candidate, dir, cycle_index)
    local point = candidate and candidate.node
    if not point or not dir then return 0, "" end
    local now = tonumber(cycle_index or _MAP_EXPLORE_PLANNER_STATE.action_count or 0) or 0
    local key = map_planner_target_key(point, dir)
    local node_key = map_planner_point_key(point)
    local region = map_planner_region_key(point, 4)
    local penalty = 0
    local reasons = {}

    for _, item in ipairs(_MAP_EXPLORE_PLANNER_STATE.target_history or {}) do
        local age = now - (tonumber(item.action) or 0)
        if age >= 0 and age <= 18 then
            if item.key == key then
                penalty = penalty + 220
                reasons[#reasons + 1] = "suppress_recent_same_probe"
            elseif item.node_key == node_key then
                penalty = penalty + 85
                reasons[#reasons + 1] = "suppress_recent_same_tile"
            elseif item.region == region and age <= 10 then
                penalty = penalty + 22
                reasons[#reasons + 1] = "suppress_recent_region"
            end
        end
    end

    return penalty, table.concat(reasons, ",")
end

function map_planner_battle_risk_penalty(candidate, dir, cycle_index)
    local point = candidate and candidate.node
    if not point or not dir then return 0, "" end
    local now = tonumber(cycle_index or _MAP_EXPLORE_PLANNER_STATE.action_count or 0) or 0
    local key = map_planner_target_key(point, dir)
    local region = map_planner_region_key(point, 5)
    local penalty = 0
    local reasons = {}

    for _, item in ipairs(_MAP_EXPLORE_PLANNER_STATE.battle_history or {}) do
        local age = now - (tonumber(item.action) or 0)
        if age >= 0 and age <= 60 then
            if item.key == key then
                penalty = penalty + 90
                reasons[#reasons + 1] = "encounter_risk_same_probe"
            elseif item.region == region then
                penalty = penalty + 25
                reasons[#reasons + 1] = "encounter_risk_region"
            else
                local d = map_planner_manhattan(point, item)
                if d <= 2 then
                    penalty = penalty + 20
                    reasons[#reasons + 1] = "encounter_risk_nearby"
                end
            end
        end
    end

    return penalty, table.concat(reasons, ",")
end

function map_planner_cluster_value(candidate, candidates)
    if not candidate or not candidate.node then return 0, 0 end
    local value = 0
    local members = 0
    for _, other in ipairs(candidates or {}) do
        if other and other.node and map_planner_same_map(candidate.node, other.node) then
            local d = map_planner_manhattan(candidate.node, other.node)
            if d <= 4 then
                members = members + 1
                value = value + map_planner_candidate_unknown_count(other)
            end
        end
    end
    return value, members
end

function map_planner_analyze_local_saturation(candidates, start_node)
    local local_nodes = 0
    local local_unknowns = 0
    local current_unknowns = 0
    local far_nodes = 0
    local far_unknowns = 0
    local max_cluster_value = 0
    local recent_local_nibbles = 0
    local now = tonumber(_MAP_EXPLORE_PLANNER_STATE.action_count or 0) or 0

    for _, item in ipairs(_MAP_EXPLORE_PLANNER_STATE.target_history or {}) do
        local age = now - (tonumber(item.action) or 0)
        if age >= 0 and age <= 10 and tonumber(item.path_len or 999) <= 3 and tostring(item.mode or "") == "local_probe" then
            recent_local_nibbles = recent_local_nibbles + 1
        end
    end

    for _, c in ipairs(candidates or {}) do
        local path_len = tonumber(c.path_len) or 0
        local unknowns = map_planner_candidate_unknown_count(c)
        if path_len == 0 then current_unknowns = current_unknowns + unknowns end
        if path_len <= 4 then
            local_nodes = local_nodes + 1
            local_unknowns = local_unknowns + unknowns
        else
            far_nodes = far_nodes + 1
            far_unknowns = far_unknowns + unknowns
        end
    end

    for _, c in ipairs(candidates or {}) do
        local cluster_value = map_planner_cluster_value(c, candidates)
        if cluster_value > max_cluster_value then max_cluster_value = cluster_value end
    end

    local local_density = 0
    if local_nodes > 0 then local_density = local_unknowns / local_nodes end

    local saturated = false
    local mode = "local_probe"
    local reason = "local work still useful"

    -- This is the critical v40.2 behavior: if the current patch is mostly old
    -- work and there are reachable frontier clusters farther away, leave the
    -- starting patch instead of repeatedly nibbling the same few holes.
    if far_nodes > 0 and recent_local_nibbles >= 4 and far_unknowns >= math.max(local_unknowns, 1) then
        saturated = true
        mode = "global_frontier_travel"
        reason = "recent local probes are nibbling the same patch; go learn a higher-value reachable frontier"
    elseif far_nodes > 0 and current_unknowns <= 1 and local_unknowns <= 18 and far_unknowns >= math.max(local_unknowns + 8, 20) then
        saturated = true
        mode = "global_frontier_travel"
        reason = "local patch has low remaining value compared with farther reachable work"
    elseif far_nodes > 0 and current_unknowns == 0 and (local_unknowns <= 10 or max_cluster_value >= 10) then
        saturated = true
        mode = "global_frontier_travel"
        reason = "current patch is saturated; prefer a higher-value reachable frontier cluster"
    elseif far_nodes > 0 and local_nodes > 12 and local_density <= 1.35 and far_unknowns > local_unknowns then
        saturated = true
        mode = "global_frontier_travel"
        reason = "nearby frontier density is low compared with farther reachable work"
    end

    return {
        saturated = saturated,
        mode = mode,
        reason = reason,
        local_nodes = local_nodes,
        local_unknowns = local_unknowns,
        current_unknowns = current_unknowns,
        far_nodes = far_nodes,
        far_unknowns = far_unknowns,
        max_cluster_value = max_cluster_value,
        local_density = local_density,
        recent_local_nibbles = recent_local_nibbles
    }
end

function map_planner_score_candidate(candidate, dir, cycle_index, start_node, candidates, saturation)
    local score = 0
    local reasons = {}
    local path_len = tonumber(candidate.path_len) or 0
    local unknown_count = map_planner_candidate_unknown_count(candidate)
    local cluster_value, cluster_members = map_planner_cluster_value(candidate, candidates)

    -- Distance matters, but it should not dominate the whole brain. Old v1 made
    -- nearby holes too sticky. v40.2 makes high-value reachable frontiers win.
    score = score + math.min(path_len * 2.4, 95)

    -- Unknown directions and frontier clusters are real learning value.
    score = score - (unknown_count * 8)
    score = score - math.min(cluster_value * 2.5, 70)
    if cluster_members >= 5 then
        score = score - 18
        reasons[#reasons + 1] = "frontier_cluster"
    end

    if path_len == 0 then
        if saturation and saturation.saturated then
            score = score + 35
            reasons[#reasons + 1] = "local_saturated_no_current_probe"
        else
            score = score - 8
            reasons[#reasons + 1] = "current_tile"
        end
    elseif path_len <= 3 then
        if saturation and saturation.saturated then
            score = score + 55
            reasons[#reasons + 1] = "leave_saturated_patch"
        else
            score = score - 3
            reasons[#reasons + 1] = "nearby"
        end
    elseif path_len >= 5 then
        if saturation and saturation.saturated then
            score = score - math.min(path_len * 1.8, 55)
            reasons[#reasons + 1] = "go_learn_somewhere_new"
        else
            reasons[#reasons + 1] = "reachable_farther_frontier"
        end
    end

    local direction_score, direction_reason = map_planner_direction_bias(dir)
    score = score + direction_score
    if direction_reason and direction_reason ~= "" then reasons[#reasons + 1] = direction_reason end

    local boundary_score, boundary_reason = map_planner_boundary_penalty(candidate.node, dir, cycle_index)
    score = score + boundary_score
    if boundary_reason and boundary_reason ~= "none" then reasons[#reasons + 1] = boundary_reason end

    local repeat_score, repeat_reason = map_planner_recent_target_penalty(candidate, dir, cycle_index)
    score = score + repeat_score
    if repeat_reason and repeat_reason ~= "" then reasons[#reasons + 1] = repeat_reason end

    local risk_score, risk_reason = map_planner_battle_risk_penalty(candidate, dir, cycle_index)
    score = score + risk_score
    if risk_reason and risk_reason ~= "" then reasons[#reasons + 1] = risk_reason end

    local surface_score, surface_reason, surface_debug = map_planner_exact_surface_penalty(candidate, dir)
    score = score + surface_score
    if surface_reason and surface_reason ~= "" then reasons[#reasons + 1] = surface_reason end

    -- Stable tie-breaker. Prefer north/south expansion only when score is close;
    -- this keeps tests repeatable without forcing old scan-lane behavior.
    score = score + ((tonumber(candidate.node.z) or 0) * 0.0007) + ((tonumber(candidate.node.x) or 0) * 0.00007)

    return score, table.concat(reasons, ";"), {
        path_len = path_len,
        unknown_count = unknown_count,
        cluster_value = cluster_value,
        cluster_members = cluster_members,
        repeat_penalty = repeat_score,
        encounter_risk_penalty = risk_score,
        boundary_penalty = boundary_score,
        surface_penalty = surface_score,
        surface_hint = surface_debug and surface_debug.surface_hint or "unknown",
        stand_surface = surface_debug and surface_debug.stand_surface or "unknown",
        stand_surface_source = surface_debug and surface_debug.stand_surface_source or "none",
        stand_surface_exact = surface_debug and surface_debug.stand_surface_exact or false,
        stand_surface_code = surface_debug and surface_debug.stand_surface_code or "NA",
        probe_surface = surface_debug and surface_debug.probe_surface or "unknown",
        probe_surface_source = surface_debug and surface_debug.probe_surface_source or "none",
        probe_surface_exact = surface_debug and surface_debug.probe_surface_exact or false,
        probe_surface_code = surface_debug and surface_debug.probe_surface_code or "NA"
    }
end

function map_explore_planner_select(candidates, start_node, cycle_index)
    if not candidates or #candidates == 0 then return nil, nil, nil end

    if not map_explore_planner_enabled() then
        local simple = candidates[1]
        return simple, map_explore_once_pick_direction(simple), { strategy = "simple_frontier", score = 0, reason = "legacy_nearest_frontier" }
    end

    local saturation = map_planner_analyze_local_saturation(candidates, start_node)
    _MAP_EXPLORE_PLANNER_STATE.local_saturation = saturation

    local best = nil
    local best_dir = nil
    local best_score = nil
    local best_reason = ""
    local best_debug = nil
    local evaluated = 0

    for _, candidate in ipairs(candidates) do
        for _, dir in ipairs(candidate.unknown_dirs or {}) do
            evaluated = evaluated + 1
            local score, reason, debug = map_planner_score_candidate(candidate, dir, cycle_index, start_node, candidates, saturation)
            if not best or score < best_score then
                best = candidate
                best_dir = dir
                best_score = score
                best_reason = reason or ""
                best_debug = debug
            end
        end
    end

    if not best then return nil, nil, nil end

    local plan = {
        strategy = "goal_directed_frontier_v10",
        score = best_score,
        reason = best_reason,
        mode = saturation.mode,
        local_saturated = saturation.saturated,
        local_reason = saturation.reason,
        local_nodes = saturation.local_nodes,
        local_unknowns = saturation.local_unknowns,
        current_unknowns = saturation.current_unknowns,
        far_nodes = saturation.far_nodes,
        far_unknowns = saturation.far_unknowns,
        max_cluster_value = saturation.max_cluster_value,
        recent_local_nibbles = saturation.recent_local_nibbles,
        evaluated_candidates = #candidates,
        evaluated_probes = evaluated,
        debug = best_debug or {}
    }

    -- Record the selected target immediately so repeated actions in the same
    -- short run do not keep choosing the same tile/probe if it produced little
    -- value or an interruption.
    local hist = _MAP_EXPLORE_PLANNER_STATE.target_history
    hist[#hist + 1] = {
        key = map_planner_target_key(best.node, best_dir),
        node_key = map_planner_point_key(best.node),
        region = map_planner_region_key(best.node, 4),
        dir = tostring(best_dir),
        action = tonumber(cycle_index or _MAP_EXPLORE_PLANNER_STATE.action_count or 0) or 0,
        mode = plan.mode,
        score = best_score,
        path_len = tonumber(best.path_len) or 0
    }
    while #hist > 72 do table.remove(hist, 1) end
    _MAP_EXPLORE_PLANNER_STATE.last_plan = plan

    return best, best_dir, plan
end

function map_explore_planner_record_result(result)
    if not result then return end
    local entry = result.entry
    local dir = entry and entry.dir or result.probed_dir
    local status = result.entry_status or result.status
    local point = entry and entry.start_point or result.from_node or nil

    _MAP_EXPLORE_PLANNER_STATE.action_count = (_MAP_EXPLORE_PLANNER_STATE.action_count or 0) + 1
    _MAP_EXPLORE_PLANNER_STATE.last_dir = dir
    _MAP_EXPLORE_PLANNER_STATE.last_status = status
    _MAP_EXPLORE_PLANNER_STATE.last_point = point

    if status == "blocked" and point and dir then
        map_planner_record_block(point, dir)
    end

    local note = tostring(entry and entry.note or "")
    if point and dir and (tostring(status):find("battle", 1, true) or note:find("encounter_risk", 1, true)) then
        map_planner_record_battle(point, dir)
    end
end

function map_explore_planner_summary()
    local state = _MAP_EXPLORE_PLANNER_STATE or {}
    local sat = state.local_saturation or {}
    local plan = state.last_plan or {}
    return "strategy=" .. tostring(map_explore_strategy()) ..
        ", mode=" .. tostring(plan.mode or sat.mode or "unknown") ..
        ", local_saturated=" .. tostring(sat.saturated or false) ..
        ", local_unknowns=" .. tostring(sat.local_unknowns or 0) ..
        ", far_unknowns=" .. tostring(sat.far_unknowns or 0) ..
        ", local_nibbles=" .. tostring(sat.recent_local_nibbles or 0) ..
        ", recent_blocks=" .. tostring(#(state.blocked_history or {})) ..
        ", battle_risk_marks=" .. tostring(#(state.battle_history or {})) ..
        ", surface_model=exact_tile_atlas_profile_provider" ..
        ", last_dir=" .. tostring(state.last_dir or "none") ..
        ", last_status=" .. tostring(state.last_status or "none")
end
