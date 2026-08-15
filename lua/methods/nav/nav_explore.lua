-----------------------------------------------------------------------------
-- nav_explore.lua
-- Auto-map loop: find reachable frontiers, travel through the compact graph,
-- probe unknown directions, save once per probe, rebuild the compact graph,
-- and stop safely at configured limits.
-----------------------------------------------------------------------------

function map_explore_once_pick_direction(candidate)
    if not candidate or not candidate.unknown_dirs or #candidate.unknown_dirs == 0 then
        return nil
    end

    -- Keep deterministic for now. Later this becomes cost/terrain-aware.
    return candidate.unknown_dirs[1]
end

function map_explore_area_action_limit()
    local value = tonumber(config.map_explore_area_actions) or tonumber(config.map_explore_max_actions) or 5

    if value < 1 then
        value = 1
    elseif value > 50 then
        value = 50
    end

    return math.floor(value)
end

function map_explore_effective_max_path_steps()
    local base = tonumber(map_graph_travel_max_steps and map_graph_travel_max_steps() or 50) or 50
    local global = tonumber(config and config.map_explore_global_max_path_steps) or 120

    if global < base then
        global = base
    end

    if global > 160 then
        global = 160
    end

    return math.floor(global)
end

function map_explore_continue_after_battle()
    if config and config.map_explore_continue_after_battle == false then
        return false
    end
    return true
end

function map_explore_battle_policy()
    local policy = tostring((config and config.map_explore_battle_policy) or "flee_then_fight")
    if policy == "stop" or policy == "flee_then_fight" or policy == "fight" then
        return policy
    end
    return "flee_then_fight"
end

function map_explore_battle_flee_timeout_frames()
    local value = tonumber(config.map_explore_flee_timeout_frames) or 1800

    if value < 300 then
        value = 300
    elseif value > 7200 then
        value = 7200
    end

    return math.floor(value)
end

-----------------------------------------------------------------------------
-- Baritone-lite Exact Tile Atlas v6
-- This does not replace the proven probe/storage primitives. It wraps them in
-- an explicit learner state machine, adds stricter movement write gates, and
-- supports goal-directed frontier selection so known local patches stop
-- absorbing every short test run.
-----------------------------------------------------------------------------

_BARITONE_LITE_RUN = _BARITONE_LITE_RUN or nil

function baritone_lite_dev_logging_enabled()
    if not config then return false end
    return config.debug == true
        or config.show_debug_log == true
        or config.developer_mode == true
        or tostring(config.log_mode or "") == "dev"
        or tostring(config.log_level or "") == "debug"
end

function baritone_lite_dev_phase(label, detail)
    if baritone_lite_dev_logging_enabled() then
        baritone_lite_phase(label, detail)
    end
end

function baritone_lite_phase(label, detail)
    local text = "[BLT] " .. tostring(label or "phase")
    if detail and tostring(detail) ~= "" then
        text = text .. ": " .. tostring(detail)
    end
    print(text)
end

function baritone_lite_surface_text(info)
    if map_terrain_surface_compact then
        return map_terrain_surface_compact(info)
    end
    if map_terrain_surface_summary then
        return map_terrain_surface_summary(info)
    end
    return "surface=unknown"
end

function baritone_lite_plan_reason_short(reason)
    reason = tostring(reason or "")
    if reason == "" then return "none" end
    local first = string.match(reason, "([^;]+)")
    return first or reason
end

function baritone_lite_status_is_terminal(status)
    status = tostring(status or "unknown")
    return status == "transition"
        or status == "battle_unresolved"
        or status == "battle"
        or status == "no_frontiers"
        or status == "wrong_tile"
        or status == "no_probe_entry"
        or status == "seed_no_unknown_direction"
        or status == "no_unknown_direction"
end

function baritone_lite_result_classification(result)
    local status = tostring((result and result.status) or "unknown")
    local entry_status = tostring((result and result.entry_status) or status)
    local original_status = tostring((result and result.original_status) or entry_status)
    local trust = "needs_review"
    local storage_intent = "none"
    local continue_recommendation = "review"
    local reason = "unclassified"

    if status == "walkable" then
        trust = "trusted"
        storage_intent = "save_clean_walkable_edge"
        continue_recommendation = "continue"
        reason = "clean movement edge was proven"
    elseif status == "blocked" then
        trust = "trusted"
        storage_intent = "save_blocked_direction"
        continue_recommendation = "continue"
        reason = "blocked/no-movement result passed confirmation policy"
    elseif status == "transition" then
        trust = "trusted_transition"
        storage_intent = "save_transition_and_stop"
        continue_recommendation = "stop_same_map"
        reason = "map changed; do not fake a same-map edge"
    elseif status == "battle_resolved_no_edge" or status == "battle_no_longer_active_no_edge" then
        trust = "handled_interruption"
        storage_intent = "save_battle_observation_only"
        continue_recommendation = "continue_from_confirmed_tile"
        reason = "battle was handled but no clean edge was proven"
    elseif status == "battle_unresolved" or status == "battle" then
        trust = "unresolved_interruption"
        storage_intent = "save_no_blocked_edge"
        continue_recommendation = "stop"
        reason = "battle could not be resolved safely"
    elseif status == "dynamic_blocked" then
        trust = "temporary_or_conditional"
        storage_intent = "save_diagnostic_only_no_permanent_block"
        continue_recommendation = "route_around_and_retry_later"
        reason = "blocked result conflicts with known walkable tile evidence"
    elseif status == "travel_interrupted_replan" then
        trust = "recoverable_travel_interruption"
        storage_intent = "save_nothing"
        continue_recommendation = "continue_from_current_tile"
        reason = "known-path travel was interrupted; replan from confirmed current tile"
    elseif status == "wrong_tile" then
        trust = "untrusted_position"
        storage_intent = "save_nothing"
        continue_recommendation = "stop_and_recover"
        reason = "travel ended on an unexpected tile before probing"
    elseif status == "partial" or status == "unsafe_jump" then
        trust = "untrusted_movement"
        storage_intent = "save_diagnostic_only"
        continue_recommendation = "stop_or_recover"
        reason = "movement did not prove a clean one-tile result"
    elseif status == "no_frontiers" then
        trust = "complete_or_disconnected"
        storage_intent = "save_nothing"
        continue_recommendation = "stop"
        reason = "no reachable same-map frontier exists"
    elseif status == "no_probe_entry" or status == "no_unknown_direction" or status == "seed_no_unknown_direction" then
        trust = "no_write"
        storage_intent = "save_nothing"
        continue_recommendation = "stop"
        reason = "planner/probe did not produce a safe observation"
    end

    return {
        status = status,
        entry_status = entry_status,
        original_status = original_status,
        trust = trust,
        storage_intent = storage_intent,
        continue_recommendation = continue_recommendation,
        reason = reason
    }
end

function baritone_lite_run_start(task_label, max_actions)
    _MAP_TERRAIN_RUN_SURFACE_COUNTS = {}

    _BARITONE_LITE_RUN = {
        task_label = tostring(task_label or "Learn Current Area"),
        max_actions = tonumber(max_actions) or 0,
        actions_attempted = 0,
        actions_completed = 0,
        trusted_walkable = 0,
        trusted_blocked = 0,
        trusted_transitions = 0,
        battle_observations = 0,
        unresolved_battles = 0,
        untrusted_results = 0,
        wrong_tile_events = 0,
        no_write_results = 0,
        storage_writes = 0,
        terminal_status = "none",
        last_classification = nil,
        last_tile = nil
    }

    baritone_lite_phase("Runtime", "Baritone-lite Capability Engine v10 active; normal log is concise, Dev mode shows scoring/details")
    baritone_lite_phase("Loop", "observe -> load_graph -> plan_frontier -> travel -> probe -> classify -> save_or_recover")
    baritone_lite_phase("Safety", "goal-directed planning; scan lens coverage; exact tile capabilities; dynamic blockage caution; recover/replan on interrupted travel; never mark battle as blocked")
end

function baritone_lite_record_action(action_index, result)
    if not _BARITONE_LITE_RUN then
        return
    end

    local cls = baritone_lite_result_classification(result)
    local run = _BARITONE_LITE_RUN
    run.actions_attempted = math.max(run.actions_attempted or 0, tonumber(action_index) or 0)
    run.actions_completed = (run.actions_completed or 0) + 1
    run.last_classification = cls
    run.last_tile = result and result.current_after or (map_graph_current_tile_point and map_graph_current_tile_point() or nil)

    if cls.status == "walkable" then
        run.trusted_walkable = (run.trusted_walkable or 0) + 1
        run.storage_writes = (run.storage_writes or 0) + 1
    elseif cls.status == "blocked" then
        run.trusted_blocked = (run.trusted_blocked or 0) + 1
        run.storage_writes = (run.storage_writes or 0) + 1
    elseif cls.status == "transition" then
        run.trusted_transitions = (run.trusted_transitions or 0) + 1
        run.storage_writes = (run.storage_writes or 0) + 1
    elseif cls.status == "battle_resolved_no_edge" or cls.status == "battle_no_longer_active_no_edge" then
        run.battle_observations = (run.battle_observations or 0) + 1
        run.storage_writes = (run.storage_writes or 0) + 1
    elseif cls.status == "battle_unresolved" or cls.status == "battle" then
        run.unresolved_battles = (run.unresolved_battles or 0) + 1
        run.untrusted_results = (run.untrusted_results or 0) + 1
    elseif cls.status == "travel_interrupted_replan" then
        run.no_write_results = (run.no_write_results or 0) + 1
    elseif cls.status == "wrong_tile" then
        run.wrong_tile_events = (run.wrong_tile_events or 0) + 1
        run.untrusted_results = (run.untrusted_results or 0) + 1
    elseif cls.storage_intent == "save_nothing" then
        run.no_write_results = (run.no_write_results or 0) + 1
    elseif cls.trust and string.find(cls.trust, "untrusted", 1, true) then
        run.untrusted_results = (run.untrusted_results or 0) + 1
    end

    if baritone_lite_status_is_terminal(cls.status) then
        run.terminal_status = cls.status
    end

    baritone_lite_phase(
        "Action " .. tostring(action_index) .. " classified",
        "status=" .. tostring(cls.status) ..
        " | trust=" .. tostring(cls.trust) ..
        " | storage=" .. tostring(cls.storage_intent) ..
        " | next=" .. tostring(cls.continue_recommendation) ..
        " | reason=" .. tostring(cls.reason)
    )
end

function baritone_lite_run_summary(stopped_reason)
    if not _BARITONE_LITE_RUN then
        return
    end

    local run = _BARITONE_LITE_RUN
    local terminal = tostring((run.terminal_status and run.terminal_status ~= "none") and run.terminal_status or stopped_reason or "none")
    local surface_summary = (map_terrain_run_surface_summary and map_terrain_run_surface_summary()) or "none"

    print("  baritone-lite summary: actions=" .. tostring(run.actions_attempted or 0) .. "/" .. tostring(run.max_actions or 0) ..
        " | walkable=" .. tostring(run.trusted_walkable or 0) ..
        " | blocked=" .. tostring(run.trusted_blocked or 0) ..
        " | transitions=" .. tostring(run.trusted_transitions or 0) ..
        " | battles=" .. tostring(run.battle_observations or 0) ..
        " | untrusted=" .. tostring(run.untrusted_results or 0) ..
        " | writes=" .. tostring(run.storage_writes or 0) ..
        " | terminal=" .. terminal)
    print("  exact surfaces seen: " .. tostring(surface_summary))
    if map_terrain_run_unmapped_summary then
        local unmapped_summary = map_terrain_run_unmapped_summary()
        if tostring(unmapped_summary) ~= "none" then
            print("  unmapped exact tile codes: " .. tostring(unmapped_summary) .. " | raw code exact; friendly label pending profile mapping")
        end
    end

    if baritone_lite_dev_logging_enabled() then
        print("  [dev] baritone-lite wrong-tile events: " .. tostring(run.wrong_tile_events or 0))
        print("  [dev] baritone-lite no-write results: " .. tostring(run.no_write_results or 0))
        print("  [dev] baritone-lite unresolved battles: " .. tostring(run.unresolved_battles or 0))
        if run.last_classification then
            print("  [dev] last classification: status=" .. tostring(run.last_classification.status) ..
                ", trust=" .. tostring(run.last_classification.trust) ..
                ", storage=" .. tostring(run.last_classification.storage_intent))
        end
    end
end



function baritone_lite_mark_final_battle_cleanup_handled()
    if not _BARITONE_LITE_RUN then
        return
    end

    local run = _BARITONE_LITE_RUN
    if run.terminal_status == "battle" or run.terminal_status == "battle_unresolved" then
        run.terminal_status = "max_actions_reached_after_final_battle_cleanup"
    end
    if (run.unresolved_battles or 0) > 0 then
        run.unresolved_battles = (run.unresolved_battles or 0) - 1
    end
    if (run.untrusted_results or 0) > 0 then
        run.untrusted_results = (run.untrusted_results or 0) - 1
    end
end

function map_explore_overworld_preflight(label)
    label = label or "preflight"

    if game_state and game_state.in_battle then
        return { status = "battle" }
    end

    route_release_direction_buttons()

    -- Safety guard for accidental open menus/dialogue boxes. Pressing B in the
    -- overworld is harmless, but if the bag/party/Pokegear/menu is open it exits
    -- back to the overworld. Without this, the bot can hold a direction while a
    -- menu is open, see no coordinate change, and falsely save a blocked edge.
    for i = 1, 5 do
        if game_state and game_state.in_battle then
            return { status = "battle", pressed_b = i - 1 }
        end
        press_button("B")
        wait_frames(8)
    end

    route_release_direction_buttons()
    local stable_point, stable_reason, stable_frames = map_probe_wait_until_position_stable("overworld_preflight_" .. tostring(label))

    return {
        status = tostring(stable_reason or "unknown"),
        pressed_b = 5,
        stable_frames = stable_frames or 0,
        point = stable_point
    }
end

function map_explore_block_retry_enabled()
    if config and config.map_explore_confirm_blocked == false then
        return false
    end
    return true
end

function map_explore_run_verified_probe_with_block_confirm(cycle_label, dir, phase_label)
    local probe_results, probe_stop_reason, entry = map_sweep_verified_tile_step(dir, 1, phase_label or "explore_area")

    if not entry or tostring(entry.result or "") ~= "blocked" or not map_explore_block_retry_enabled() then
        return probe_results, probe_stop_reason, entry, false
    end

    local original_entry = entry
    print(cycle_label .. " blocked probe needs confirmation. Clearing possible menu/dialogue state and retrying once before saving a blocked edge.")

    local preflight = map_explore_overworld_preflight(tostring(cycle_label) .. "_blocked_confirm")

    if preflight.status == "battle" or (game_state and game_state.in_battle) then
        original_entry.result = "battle"
        original_entry.moved = 0
        original_entry.end_point = original_entry.start_point
        original_entry.note = tostring(original_entry.note or "") ..
            ";blocked_confirmation_interrupted_by_battle;converted_to_battle;not_recorded_as_blocked"
        return { original_entry }, "battle", original_entry, true
    end

    local retry_start = map_graph_current_tile_point()
    if original_entry.start_point and not map_graph_points_match(retry_start, original_entry.start_point, 0.45) then
        original_entry.result = "partial"
        original_entry.moved = 0
        original_entry.end_point = original_entry.start_point
        original_entry.note = tostring(original_entry.note or "") ..
            ";blocked_confirmation_position_changed;not_recorded_as_blocked" ..
            ";retry_start=" .. tostring(retry_start.x) .. "," .. tostring(retry_start.z)
        print(cycle_label .. " blocked confirmation cancelled because the player position changed while clearing UI. Saving as partial, not blocked.")
        return { original_entry }, "partial", original_entry, true
    end

    local retry_results, retry_stop_reason, retry_entry = map_sweep_verified_tile_step(dir, 1, (phase_label or "explore_area") .. "_blocked_confirm")

    if not retry_entry then
        original_entry.result = "partial"
        original_entry.moved = 0
        original_entry.end_point = original_entry.start_point
        original_entry.note = tostring(original_entry.note or "") ..
            ";blocked_confirmation_retry_no_entry;not_recorded_as_blocked"
        print(cycle_label .. " blocked confirmation did not produce a retry entry. Saving as partial, not blocked.")
        return { original_entry }, "partial", original_entry, true
    end

    retry_entry.note = tostring(retry_entry.note or "") ..
        ";blocked_confirmation_retry=true" ..
        ";original_result=blocked" ..
        ";original_stop=" .. tostring(probe_stop_reason or "")

    if tostring(retry_entry.result or "") == "blocked" then
        retry_entry.note = retry_entry.note .. ";blocked_confirmed=true"
        print(cycle_label .. " blocked confirmation retry also blocked. Saving confirmed blocked direction.")
    else
        retry_entry.note = retry_entry.note .. ";first_block_was_not_confirmed=true;not_recorded_as_blocked"
        print(cycle_label .. " blocked confirmation changed result to " .. tostring(retry_entry.result) .. ". Using retry result instead of the first blocked result.")
    end

    return retry_results, retry_stop_reason, retry_entry, true
end

function map_explore_handle_post_action_battle(cycle_label, context_label)
    if not (game_state and game_state.in_battle) then
        return nil
    end

    print(cycle_label .. " battle is active after the movement/probe action. Handling before the task stops or continues.")

    if not map_explore_continue_after_battle() then
        print(cycle_label .. " Continue After Battle is OFF, so leaving battle active and stopping safely.")
        return { status = "continue_disabled" }
    end

    return map_explore_battle_safe_continue(context_label or "Map Explore")
end

function map_explore_wait_for_battle_data(max_frames)
    max_frames = max_frames or 180

    for frame = 1, max_frames do
        process_frame()

        if not game_state or not game_state.in_battle then
            return false
        end

        if foe and #foe > 0 then
            return true
        end
    end

    return foe and #foe > 0
end

function map_explore_wait_for_battle_menu(max_frames)
    max_frames = max_frames or 900

    for frame = 1, max_frames do
        process_frame()

        if not game_state or not game_state.in_battle then
            return false, frame, "battle_ended"
        end

        -- HGSS menu-ready value used elsewhere in the original bot.
        if pointers and pointers.battle_menu_state and mbyte(pointers.battle_menu_state) == 1 then
            return true, frame, "menu_ready"
        end

        -- Gentle text progression only. Do not tap RUN while the battle intro
        -- or white flash transition is active; that caused messy screen flashes.
        if frame % 30 == 0 then
            press_button("B")
        end
    end

    return false, max_frames, "timeout"
end

function map_explore_attempt_flee_with_timeout(max_frames)
    max_frames = max_frames or map_explore_battle_flee_timeout_frames()

    local frames = 0
    local attempts = 0

    while game_state and game_state.in_battle and frames < max_frames do
        local ready, waited, ready_reason = map_explore_wait_for_battle_menu(math.min(900, max_frames - frames))
        frames = frames + (waited or 0)

        if not (game_state and game_state.in_battle) then
            return true, frames, attempts
        end

        if ready then
            attempts = attempts + 1
            -- RUN button. Tap once, then wait for the battle/menu state to settle.
            touch_screen_at(125, 175)
            wait_frames(45)
            frames = frames + 45

            -- If flee failed, the game usually returns through text/menu states.
            -- Progress dialogue, then loop until the menu is ready again.
            for i = 1, 30 do
                if not (game_state and game_state.in_battle) then
                    return true, frames, attempts
                end
                if i % 10 == 0 then
                    press_button("B")
                end
                process_frame()
                frames = frames + 1
            end
        else
            print_debug("Battle flee wait did not reach menu: " .. tostring(ready_reason))
            break
        end
    end

    return not (game_state and game_state.in_battle), frames, attempts
end


function map_explore_battle_safe_continue(context_label)
    context_label = context_label or "Map Explore"

    if not game_state or not game_state.in_battle then
        return { status = "no_battle" }
    end

    nav_battle_log(context_label .. " battle bridge: battle detected. Handing control to the original PokéBot encounter logic.")

    local has_foe_data = map_explore_wait_for_battle_data(240)

    if not has_foe_data or not foe or #foe == 0 then
        nav_warn(context_label .. " battle bridge: foe data was not ready, so no movement edge will be recorded.")
        return { status = "unresolved", foe_name = "unknown", target = false, foe_item = false }
    end

    local foe_name = foe[1] and foe[1].name or "wild Pokemon"

    -- IMPORTANT: Do not duplicate or replace Random Encounters behavior here.
    -- process_wild_encounter() is the original shared flow. It logs the foe,
    -- catches targets when configured, flees non-targets when battle_non_targets
    -- is false, fights non-targets only when the user enabled that original
    -- setting, and runs pickup afterward.
    local ok, err = pcall(function()
        process_wild_encounter()
    end)

    if not ok then
        nav_error_log(context_label .. " battle bridge: original encounter logic stopped the task: " .. tostring(err))
        error(err)
    end

    nav_battle_log(context_label .. " battle bridge: encounter was passed through the original dashboard Recently Seen/target logging path.")

    if game_state and game_state.in_battle then
        nav_warn(context_label .. " battle bridge: battle is still active after original encounter logic.")
        return { status = "unresolved", foe_name = foe_name, target = false, foe_item = false }
    end

    check_party_status()
    route_release_direction_buttons()
    map_probe_wait_until_position_stable("after_original_encounter_bridge")

    nav_battle_log(context_label .. " battle bridge: original encounter logic resolved the wild " .. tostring(foe_name) .. ".")

    return { status = "handled", foe_name = foe_name, target = false, foe_item = false, source = "process_wild_encounter" }
end

function map_explore_convert_battle_probe_if_clean(entry, probe_results, after_battle_point)
    if not entry or entry.result ~= "battle" then
        return false
    end

    local expected_tile = entry.verified_expected_tile
    local start_tile = entry.start_point
    local after_tile = nil

    if after_battle_point then
        after_tile = map_probe_snap_to_tile_center(after_battle_point)
    end

    local live_forward_delta = tonumber(entry.verified_live_forward_delta) or 0
    local live_cross_delta = tonumber(entry.verified_live_cross_delta) or 999

    local clean = false
    local clean_source = "none"

    -- Best proof: after the battle, the player is exactly on the expected
    -- neighboring tile. This avoids trusting temporary battle-transition coords.
    if expected_tile and after_tile and map_graph_points_match(after_tile, expected_tile, 0.45) then
        clean = true
        clean_source = "after_battle_position"
    -- Secondary proof: the live pre-battle movement had already crossed enough
    -- of the requested tile with low cross-axis drift.
    elseif live_forward_delta >= 0.75 and live_forward_delta <= 1.25 and live_cross_delta <= 0.35 then
        clean = true
        clean_source = "live_pre_battle_delta"
    end

    if clean then
        entry.result = "walkable"
        entry.moved = 1
        entry.end_point = expected_tile or after_tile
        entry.note = tostring(entry.note or "") ..
            ";battle_triggered=true;recorded_as_walkable_after_clean_movement;encounter_risk=true;clean_source=" ..
            tostring(clean_source)

        if probe_results and probe_results[1] then
            probe_results[1] = entry
        end

        return true
    end

    -- No clean edge was proven. Keep this as a battle observation and clamp the
    -- endpoint to the start node so raw battle-transition coordinates do not
    -- create impossible nodes such as X 0.5 / Z -0.5 or huge moved distances.
    entry.result = "battle"
    entry.moved = 0
    entry.end_point = start_tile
    entry.note = tostring(entry.note or "") ..
        ";battle_probe_not_clean;endpoint_clamped_to_start;not_recorded_as_blocked"

    if after_tile then
        entry.note = entry.note .. ";after_battle_tile=" .. tostring(after_tile.x) .. "," .. tostring(after_tile.z)
    end

    if probe_results and probe_results[1] then
        probe_results[1] = entry
    end

    return false
end


function map_explore_once_walk_path(path)
    if not path or #path == 0 then
        return { ok = true, requested_edges = 0, completed_edges = 0, stop_reason = "already_there" }
    end

    local runs = map_graph_compress_path_runs(path)
    baritone_lite_dev_phase("travel_path", tostring(#path) .. " edge(s), " .. tostring(#runs) .. " run(s); preview=" .. map_graph_run_preview(runs))

    local result = {
        ok = true,
        requested_edges = #path,
        completed_edges = 0,
        stop_reason = "finished",
        interrupted = false,
        detail = nil,
        current_after = nil
    }

    perf_start("map_explore_travel")
    for run_index, run in ipairs(runs) do
        local before = map_graph_current_tile_point()
        local ok, run_result = pcall(function()
            return map_graph_walk_compressed_run(path, run)
        end)
        local after = map_graph_current_tile_point()
        result.current_after = after
        if map_terrain_observe_current_exact then
            map_terrain_observe_current_exact(false, "travel_run")
        end

        if not ok then
            route_release_direction_buttons()
            result.ok = false
            result.interrupted = true
            result.stop_reason = "compressed_travel_interrupted"
            result.detail = tostring(run_result or "unknown")
            baritone_lite_phase("travel_recovery",
                "compressed run " .. tostring(run_index) .. "/" .. tostring(#runs) ..
                " stopped early; current=" .. map_graph_node_label(after) ..
                " | next=replan_from_current_tile | detail=" .. tostring(result.detail))
            break
        end

        if type(run_result) == "table" then
            local stop = tostring(run_result.stop or run_result.stop_reason or run_result.status or "finished")
            if stop ~= "finished" and stop ~= "ok" and stop ~= "walkable" then
                route_release_direction_buttons()
                result.ok = false
                result.interrupted = true
                result.stop_reason = stop
                result.detail = tostring(run_result.detail or run_result.message or "travel run returned non-finished status")
                baritone_lite_phase("travel_recovery",
                    "compressed run " .. tostring(run_index) .. "/" .. tostring(#runs) ..
                    " returned " .. tostring(stop) .. "; current=" .. map_graph_node_label(after) ..
                    " | next=replan_from_current_tile")
                break
            end
        elseif type(run_result) == "string" and run_result ~= "" and run_result ~= "finished" and run_result ~= "ok" and run_result ~= "walkable" then
            route_release_direction_buttons()
            result.ok = false
            result.interrupted = true
            result.stop_reason = tostring(run_result)
            result.detail = "travel run returned non-finished status"
            baritone_lite_phase("travel_recovery",
                "compressed run " .. tostring(run_index) .. "/" .. tostring(#runs) ..
                " returned " .. tostring(run_result) .. "; current=" .. map_graph_node_label(after) ..
                " | next=replan_from_current_tile")
            break
        end

        -- We do not trust old compressed-travel assumptions blindly anymore.
        -- Count completed progress by current position rather than pretending the
        -- full path succeeded. The frontier check after this decides whether to
        -- probe or replan.
        local moved = map_probe_distance and map_probe_distance(before, after) or 0
        if moved and moved > 0 then
            result.completed_edges = math.min(result.requested_edges, result.completed_edges + math.floor(moved + 0.25))
        end
    end
    perf_stop("map_explore_travel")

    if not result.current_after then
        result.current_after = map_graph_current_tile_point()
    end

    return result
end

function map_explore_once_rebuild_graph(context_label)
    context_label = context_label or "Map Explore"

    perf_start("map_explore_rebuild_graph")
    local nodes, edges, blocked, stats = map_graph_build_from_raw()
    local output_path, output_size = map_graph_write(nodes, edges, blocked, stats)
    perf_stop("map_explore_rebuild_graph")

    local rebuilt = {
        nodes = #map_graph_sorted_keys(nodes),
        edges = #map_graph_sorted_keys(edges),
        blocked = #map_graph_sorted_keys(blocked),
        duplicate_raw_edges = stats.duplicate_edges or 0,
        output_path = output_path,
        output_size = output_size or 0
    }

    print(
        "Rebuilt compact graph: nodes=" .. tostring(rebuilt.nodes) ..
        ", edges=" .. tostring(rebuilt.edges) ..
        ", blocked=" .. tostring(rebuilt.blocked) ..
        ", duplicate_raw_edges=" .. tostring(rebuilt.duplicate_raw_edges) ..
        "."
    )

    if output_path then
        print(tostring(context_label) .. " updated " .. tostring(output_path) .. " (" .. tostring(output_size or 0) .. " bytes).")
    end

    return rebuilt
end


function map_explore_graph_file_exists()
    local file = io.open(map_graph_path(), "r")
    if file then
        file:close()
        return true
    end
    return false
end

function map_explore_empty_frontier()
    return {
        graph = {
            nodes = {},
            node_order = {},
            adj = {},
            edge_seen = {},
            edge_count = 0,
            raw_edge_count = 0,
            reverse_edge_count = 0
        },
        known = {},
        blocked_count = 0,
        transition_count = 0,
        walkable_count = 0
    }
end

function map_explore_load_frontier_or_empty(allow_reverse)
    if not map_explore_graph_file_exists() then
        return map_explore_empty_frontier(), "empty_no_graph"
    end

    return map_graph_load_frontier_data(allow_reverse), "loaded"
end

function map_explore_known_direction(frontier, point, dir)
    if not frontier or not frontier.known or not point or not dir then
        return nil
    end

    local key = map_graph_point_key(point)
    if frontier.known[key] then
        return frontier.known[key][dir]
    end

    return nil
end

function map_explore_pick_unprobed_direction(frontier, point)
    for _, dir in ipairs(map_graph_direction_order()) do
        if not map_explore_known_direction(frontier, point, dir) then
            return dir
        end
    end

    return nil
end


function map_explore_point_axis_delta(a, b)
    if not a or not b then
        return nil, nil, nil
    end
    local dx = math.abs((tonumber(b.x) or 0) - (tonumber(a.x) or 0))
    local dz = math.abs((tonumber(b.z) or 0) - (tonumber(a.z) or 0))
    local same_map = tonumber(a.map) == tonumber(b.map)
    return dx, dz, same_map
end

function map_explore_clean_one_tile_delta(start_point, end_point)
    local dx, dz, same_map = map_explore_point_axis_delta(start_point, end_point)
    if dx == nil or dz == nil then
        return false, "missing_start_or_end_point"
    end
    if not same_map then
        return false, "map_changed_not_same_map_walkable"
    end

    local one_x = dx >= 0.75 and dx <= 1.30 and dz <= 0.35
    local one_z = dz >= 0.75 and dz <= 1.30 and dx <= 0.35

    if one_x or one_z then
        return true, "clean_one_tile_delta"
    end

    return false, "dx=" .. string.format("%.2f", dx) .. ";dz=" .. string.format("%.2f", dz)
end

function map_explore_blocked_delta_is_clean(start_point, end_point, moved)
    local dx, dz, same_map = map_explore_point_axis_delta(start_point, end_point)
    if dx == nil or dz == nil then
        return false, "missing_start_or_end_point"
    end
    if not same_map then
        return false, "map_changed_during_blocked_result"
    end

    local moved_num = tonumber(moved) or 0
    if dx <= 0.35 and dz <= 0.35 and moved_num <= 0.45 then
        return true, "confirmed_no_movement"
    end

    return false, "blocked_result_moved;dx=" .. string.format("%.2f", dx) .. ";dz=" .. string.format("%.2f", dz) .. ";moved=" .. string.format("%.2f", moved_num)
end


function map_explore_expected_neighbor_surface_for_entry(entry)
    if not entry or not entry.start_point then return nil end
    local dir = entry.probed_dir or entry.direction or entry.dir
    if not dir or not map_terrain_neighbor_point or not map_terrain_lookup_exact then return nil end
    local expected = map_terrain_neighbor_point(entry.start_point, tostring(dir))
    if not expected then return nil end
    return map_terrain_lookup_exact(expected)
end

function map_explore_surface_is_known_walkable(info)
    if not info or info.exact ~= true then return false end
    local walk = tostring(info.walkability or '')
    local cat = tostring(info.category or '')
    local bucket = tostring(info.surface_bucket or '')
    return walk == 'walkable' or string.find(cat, 'walkable', 1, true) ~= nil or bucket == 'safe' or bucket == 'encounter'
end

function map_explore_validate_probe_entry_for_storage(cycle_label, entry)
    if not entry then
        return { changed = false, status = "missing" }
    end

    local status = tostring(entry.result or "unknown")

    if status == "walkable" then
        local ok, reason = map_explore_clean_one_tile_delta(entry.start_point, entry.end_point)
        if ok then
            entry.note = tostring(entry.note or "") .. ";blt_clean_walkable_verified=true"
            return { changed = false, status = "walkable", trust = "trusted", reason = reason }
        end

        entry.result = "partial"
        entry.moved = 0
        entry.end_point = entry.start_point
        entry.note = tostring(entry.note or "") .. ";blt_downgraded_walkable_to_partial=true;reason=" .. tostring(reason) .. ";not_recorded_as_clean_edge"
        print(cycle_label .. " BLT movement gate downgraded walkable to partial: " .. tostring(reason) .. ". No clean edge will be recorded.")
        return { changed = true, status = "partial", trust = "untrusted_movement", reason = reason }
    elseif status == "blocked" then
        local ok, reason = map_explore_blocked_delta_is_clean(entry.start_point, entry.end_point, entry.moved)
        if ok then
            local expected_surface = map_explore_expected_neighbor_surface_for_entry(entry)
            if map_explore_surface_is_known_walkable(expected_surface) then
                entry.result = "dynamic_blocked"
                entry.moved = 0
                entry.end_point = entry.start_point
                entry.note = tostring(entry.note or "") ..
                    ";blt_dynamic_blockage_candidate=true;expected_tile_known_walkable=true;expected_surface=" ..
                    tostring(map_terrain_surface_compact and map_terrain_surface_compact(expected_surface) or "known_walkable") ..
                    ";not_recorded_as_permanent_blocked"
                print(cycle_label .. " BLT blockage gate: blocked movement targets a known walkable exact tile. Treating as dynamic/conditional blockage, not permanent wall.")
                return { changed = true, status = "dynamic_blocked", trust = "temporary_or_conditional", reason = "known_walkable_target_blocked;likely dynamic/state/conditional obstacle" }
            end
            entry.note = tostring(entry.note or "") .. ";blt_confirmed_blocked_no_movement=true"
            return { changed = false, status = "blocked", trust = "trusted", reason = reason }
        end

        entry.result = "partial"
        entry.moved = 0
        entry.end_point = entry.start_point
        entry.note = tostring(entry.note or "") .. ";blt_downgraded_blocked_to_partial=true;reason=" .. tostring(reason) .. ";not_recorded_as_blocked"
        print(cycle_label .. " BLT movement gate downgraded blocked to partial: " .. tostring(reason) .. ". No blocked direction will be recorded.")
        return { changed = true, status = "partial", trust = "untrusted_movement", reason = reason }
    elseif status == "transition" then
        entry.note = tostring(entry.note or "") .. ";blt_transition_separate_from_same_map_edge=true"
        return { changed = false, status = "transition", trust = "trusted_transition", reason = "map change recorded separately" }
    end

    return { changed = false, status = status, trust = "not_a_map_fact", reason = "no clean movement fact expected" }
end

function map_explore_probe_save_rebuild(cycle_label, context_label, unknown_dir, from_node, options)
    options = options or {}

    print(cycle_label .. " probing unknown direction " .. tostring(unknown_dir) .. " from " .. map_graph_node_label(from_node) .. ".")

    perf_start("map_explore_probe")
    local probe_results, probe_stop_reason, entry, block_confirm_retry = map_explore_run_verified_probe_with_block_confirm(cycle_label, unknown_dir, "explore_area")
    perf_stop("map_explore_probe")

    if not probe_results or #probe_results == 0 or not entry then
        return { status = "no_probe_entry", message = "Probe did not produce a result entry." }
    end

    local original_probe_result = tostring(entry.result or "unknown")
    local battle_edge_recorded = false
    local battle_handler_result = nil
    local current_after_battle = nil

    if original_probe_result == "battle" then
        print(cycle_label .. " battle detected during probe. Holding raw battle observation until battle is handled and position is valid again.")

        if options.battle_safe then
            if map_explore_continue_after_battle() then
                battle_handler_result = map_explore_battle_safe_continue(context_label)
                if battle_handler_result and battle_handler_result.status == "handled" then
                    current_after_battle = map_graph_current_tile_point()
                end
            else
                print(cycle_label .. " battle detected, but Continue After Battle is OFF.")
                battle_handler_result = { status = "continue_disabled" }
            end
        end

        battle_edge_recorded = map_explore_convert_battle_probe_if_clean(entry, probe_results, current_after_battle)

        if battle_edge_recorded then
            print(cycle_label .. " battle was handled and a clean tile move was proven. Recording walkable edge with encounter_risk=true.")
        else
            entry.note = tostring(entry.note or "") .. ";battle_interrupted_probe=true;not_recorded_as_blocked"
            print(cycle_label .. " battle did not prove a clean edge. Saving battle observation only, NOT blocked.")
        end
    elseif game_state and game_state.in_battle then
        -- This catches the case where the one-tile move was already proven, but
        -- the wild battle opened immediately after. v32 could finish the final
        -- action and leave the user sitting on FIGHT/RUN. v33 handles it before
        -- continuing or aborting.
        entry.note = tostring(entry.note or "") .. ";post_probe_battle_active=true;encounter_risk=true"
        if options.battle_safe then
            battle_handler_result = map_explore_handle_post_action_battle(cycle_label, context_label)
        end
    end

    if entry then entry.probed_dir = unknown_dir end
    local movement_validation = map_explore_validate_probe_entry_for_storage(cycle_label, entry)
    if movement_validation and movement_validation.reason then
        baritone_lite_phase(cycle_label .. " movement_gate",
            "status=" .. tostring(entry.result) ..
            " | trust=" .. tostring(movement_validation.trust) ..
            " | reason=" .. tostring(movement_validation.reason))
    end

    print(
        cycle_label .. " probe result: " .. tostring(entry.result) ..
        (original_probe_result ~= tostring(entry.result) and (" (original=" .. tostring(original_probe_result) .. ")") or "") ..
        " | moved=" .. tostring(entry.moved) ..
        " | stop=" .. tostring(probe_stop_reason) ..
        " | from " .. map_graph_node_label(entry.start_point) ..
        " | to " .. map_graph_node_label(entry.end_point)
    )

    if battle_handler_result then
        print(cycle_label .. " battle handler result: " .. tostring(battle_handler_result.status) ..
            (battle_handler_result.foe_name and (" | foe=" .. tostring(battle_handler_result.foe_name)) or ""))
    end

    local entry_status = tostring(entry.result or "unknown")

    print(cycle_label .. " saving probe result to raw sweep edges once.")
    map_probe_write_results(probe_results, map_sweep_path(), context_label)

    local rebuilt = nil
    if entry_status == "walkable" or entry_status == "blocked" or entry_status == "transition" then
        rebuilt = map_explore_once_rebuild_graph(context_label)
    elseif entry_status == "battle" then
        print(cycle_label .. " battle observation saved. Compact graph was not rebuilt because no clean edge was proven.")
    else
        print(cycle_label .. " diagnostic/untrusted observation saved as " .. tostring(entry_status) .. ". Compact graph was not rebuilt because no trusted map fact was proven.")
    end

    local current_after = map_graph_current_tile_point()
    print(cycle_label .. " current tile after probe: " .. map_graph_node_label(current_after) .. ".")

    local final_status = entry_status
    if original_probe_result == "battle" then
        if entry_status == "walkable" then
            final_status = "walkable"
        elseif battle_handler_result and battle_handler_result.status == "handled" then
            final_status = "battle_resolved_no_edge"
        elseif battle_handler_result and battle_handler_result.status == "no_battle" then
            final_status = "battle_no_longer_active_no_edge"
        else
            final_status = "battle_unresolved"
        end
    end

    local classification_preview = baritone_lite_result_classification({
        status = final_status,
        entry_status = entry_status,
        original_status = original_probe_result,
        entry = entry
    })
    baritone_lite_dev_phase(cycle_label .. " save_or_recover",
        "storage=" .. tostring(classification_preview.storage_intent) ..
        " | trust=" .. tostring(classification_preview.trust) ..
        " | next=" .. tostring(classification_preview.continue_recommendation))

    return {
        status = final_status,
        entry_status = entry_status,
        original_status = original_probe_result,
        battle_handler_status = battle_handler_result and battle_handler_result.status or nil,
        battle_edge_recorded = battle_edge_recorded,
        block_confirm_retry = block_confirm_retry,
        stop_reason = probe_stop_reason,
        probed_dir = unknown_dir,
        entry = entry,
        rebuilt = rebuilt,
        current_after = current_after
    }
end


function map_explore_seed_from_current_tile(cycle_index, options, frontier, graph_state)
    options = options or {}
    local cycle_label = "Action " .. tostring(cycle_index or 1)
    local context_label = options.context_label or "Map Explore"
    local current_tile = map_graph_current_tile_point()
    local unknown_dir = map_explore_pick_unprobed_direction(frontier, current_tile)

    print(cycle_label .. " auto-seed: current tile is not in the compact graph yet.")
    print(cycle_label .. " auto-seed current tile: " .. map_graph_node_label(current_tile) .. ".")

    if graph_state == "empty_no_graph" then
        print(cycle_label .. " auto-seed: no map_graph.txt was loaded, so this starts a new local model from the current tile.")
    else
        print(cycle_label .. " auto-seed: graph exists, but this exact tile is new. If the probe reaches an existing node, graph build will connect to it without duplicating that coordinate.")
    end

    if not unknown_dir then
        return {
            status = "seed_no_unknown_direction",
            message = "Current unknown seed tile has no unprobed directions left according to the graph."
        }
    end

    print(cycle_label .. " auto-seed selected direction: " .. tostring(unknown_dir) .. ".")
    return map_explore_probe_save_rebuild(cycle_label, context_label, unknown_dir, current_tile, options)
end

function map_explore_cycle(cycle_index, options)
    options = options or {}
    local allow_reverse = options.allow_reverse
    local max_path_steps = options.max_path_steps or map_explore_effective_max_path_steps()
    local same_map_only = options.same_map_only ~= false
    local context_label = options.context_label or "Map Explore"
    local cycle_label = "Action " .. tostring(cycle_index or 1)

    if game_state and game_state.in_battle then
        return { status = "battle", message = "Already in battle before exploring." }
    end

    local preflight = map_explore_overworld_preflight(tostring(cycle_label) .. "_start")
    if preflight.status == "battle" or (game_state and game_state.in_battle) then
        return { status = "battle", message = "Battle started during overworld preflight." }
    end
    print(cycle_label .. " overworld preflight: B-clear complete; stable=" .. tostring(preflight.status) .. "; frames=" .. tostring(preflight.stable_frames or 0) .. ".")

    local current_surface = nil
    if map_terrain_observe_current_exact then
        current_surface = map_terrain_observe_current_exact(false, "action_start")
        baritone_lite_phase(cycle_label, "surface=" .. baritone_lite_surface_text(current_surface))
        baritone_lite_dev_phase(cycle_label .. " surface_debug", map_terrain_surface_summary and map_terrain_surface_summary(current_surface) or "surface provider loaded")
    else
        baritone_lite_phase(cycle_label, "surface=unknown(provider_not_loaded)")
    end

    baritone_lite_dev_phase(cycle_label .. " load_graph", "loading compact graph/frontier model")
    perf_start("map_explore_load_frontiers")
    local frontier, graph_state = map_explore_load_frontier_or_empty(allow_reverse)
    perf_stop("map_explore_load_frontiers")

    local graph = frontier.graph
    baritone_lite_dev_phase(cycle_label .. " graph",
        tostring(#graph.node_order) .. " node(s), " ..
        tostring(graph.edge_count) .. " travel edge(s), " ..
        tostring(graph.reverse_edge_count) .. " inferred reverse edge(s)" ..
        (graph_state == "empty_no_graph" and " [new local model]" or ""))
    baritone_lite_dev_phase(cycle_label .. " observations", "walkable=" .. tostring(frontier.walkable_count) .. ", transition=" .. tostring(frontier.transition_count) .. ", blocked=" .. tostring(frontier.blocked_count))

    local current_tile = map_graph_current_tile_point()
    local start_node, start_distance = map_graph_find_closest_node(graph, current_tile, 0.60)

    if not start_node then
        return map_explore_seed_from_current_tile(cycle_index, options, frontier, graph_state)
    end

    baritone_lite_dev_phase(cycle_label .. " start_node", map_graph_node_label(start_node) .. " distance=" .. string.format("%.2f", start_distance or 0))

    baritone_lite_dev_phase(cycle_label .. " plan_frontier", "finding reachable same-map frontier candidates")
    perf_start("map_explore_find_frontier")
    local candidates = map_graph_frontier_find_candidates(frontier, start_node, max_path_steps, same_map_only)
    perf_stop("map_explore_find_frontier")

    baritone_lite_dev_phase(cycle_label .. " frontiers", "reachable=" .. tostring(#candidates))

    if #candidates == 0 then
        return { status = "no_frontiers", message = "No reachable same-map frontier nodes were found." }
    end

    local target = nil
    local unknown_dir = nil
    local plan_info = nil

    if map_explore_planner_select then
        target, unknown_dir, plan_info = map_explore_planner_select(candidates, start_node, cycle_index)
    else
        target = candidates[1]
        unknown_dir = map_explore_once_pick_direction(target)
        plan_info = { strategy = "legacy_nearest_frontier", score = 0, reason = "planner_not_loaded" }
    end

    if not target or not unknown_dir then
        return { status = "no_unknown_direction", message = "Selected frontier had no unknown direction to probe." }
    end

    if plan_info and plan_info.mode then
        baritone_lite_phase(cycle_label .. " planner_brain",
            "mode=" .. tostring(plan_info.mode) ..
            " | local_saturated=" .. tostring(plan_info.local_saturated) ..
            " | current_unknowns=" .. tostring(plan_info.current_unknowns or 0) ..
            " | local_unknowns=" .. tostring(plan_info.local_unknowns or 0) ..
            " | far_unknowns=" .. tostring(plan_info.far_unknowns or 0) ..
            " | local_nibbles=" .. tostring(plan_info.recent_local_nibbles or 0) ..
            " | evaluated=" .. tostring(plan_info.evaluated_probes or plan_info.evaluated_candidates or 0) ..
            " | why=" .. tostring(plan_info.local_reason or ""))
    end

    local plan_surface = (plan_info and plan_info.debug and plan_info.debug.surface_hint) or "surface=unknown"
    baritone_lite_phase(cycle_label .. " plan",
        "mode=" .. tostring(plan_info and plan_info.mode or "unknown") ..
        " | target=" .. map_graph_node_label(target.node) ..
        " | path=" .. tostring(target.path_len) ..
        " | probe=" .. tostring(unknown_dir) ..
        " | surface=" .. tostring(plan_surface) ..
        " | reason=" .. baritone_lite_plan_reason_short(plan_info and plan_info.reason or ""))
    baritone_lite_dev_phase(cycle_label .. " planner_debug",
        "unknown=" .. table.concat(target.unknown_dirs, ",") ..
        " | planner=" .. tostring(plan_info and plan_info.strategy or "unknown") ..
        " | score=" .. tostring(plan_info and string.format("%.2f", tonumber(plan_info.score) or 0) or "0") ..
        ((plan_info and plan_info.reason and plan_info.reason ~= "") and (" | reason=" .. tostring(plan_info.reason)) or "") ..
        ((plan_info and plan_info.debug) and (" | value=u" .. tostring(plan_info.debug.unknown_count or 0) .. "/cluster" .. tostring(plan_info.debug.cluster_value or 0) .. "/risk" .. tostring(plan_info.debug.encounter_risk_penalty or 0) .. "/terrain" .. tostring(plan_info.debug.surface_penalty or 0) .. "/surface=" .. tostring(plan_info.debug.surface_hint or "unknown")) or "") ..
        " | path preview=" .. map_graph_path_preview(target.path, 10))

    baritone_lite_phase(cycle_label .. " travel", "path=" .. tostring(target.path_len) .. " edge(s)")
    local travel_result = map_explore_once_walk_path(target.path)

    local at_frontier = map_graph_current_tile_point()
    local frontier_surface = nil
    if map_terrain_observe_current_exact then
        frontier_surface = map_terrain_observe_current_exact(false, "frontier")
        baritone_lite_dev_phase(cycle_label .. " frontier_surface", baritone_lite_surface_text(frontier_surface))
    end
    if not travel_result or travel_result.ok == false then
        return {
            status = "travel_interrupted_replan",
            message = "Travel path was interrupted before the selected frontier. Replanning from current tile instead of ending the task.",
            from_node = start_node,
            target_node = target.node,
            current_after = at_frontier,
            travel_stop_reason = travel_result and travel_result.stop_reason or "unknown",
            travel_detail = travel_result and travel_result.detail or nil
        }
    end

    if not map_graph_points_match(at_frontier, target.node, 0.45) then
        baritone_lite_phase(cycle_label .. " travel_recovery",
            "not at selected frontier after travel; expected=" .. map_graph_node_label(target.node) ..
            " | actual=" .. map_graph_node_label(at_frontier) ..
            " | next=replan_from_current_tile")
        return {
            status = "travel_interrupted_replan",
            message = "Known-path travel ended before the selected frontier. Replanning from current tile instead of ending the task.",
            from_node = start_node,
            target_node = target.node,
            current_after = at_frontier,
            travel_stop_reason = "not_at_frontier_after_travel"
        }
    end

    baritone_lite_phase(cycle_label .. " probe", tostring(unknown_dir) .. " from selected frontier")
    local probe_result = map_explore_probe_save_rebuild(cycle_label, context_label, unknown_dir, target.node, options)
    if map_terrain_observe_current_exact then
        local after_surface = map_terrain_observe_current_exact(false, "after_probe")
        if probe_result and type(probe_result) == "table" then probe_result.current_surface = after_surface end
        baritone_lite_dev_phase(cycle_label .. " after_probe_surface", baritone_lite_surface_text(after_surface))
    end
    return probe_result
end

function map_explore_print_result_hint(result, once_mode)
    local status = result and result.status or "unknown"

    if status == "walkable" then
        print("Explore learned a new walkable edge." .. (once_mode and " Run Map Explore Once again to keep expanding from the new graph." or ""))
    elseif status == "blocked" then
        print("Explore learned a blocked direction." .. (once_mode and " Run Map Explore Once again to test another frontier direction." or ""))
    elseif status == "transition" then
        print("Explore detected a map transition. Cross-map exploration/profile handling can be improved later; graph data was still saved.")
    elseif status == "dynamic_blocked" then
        print("Explore found a dynamic/conditional blockage candidate. It was NOT saved as a permanent wall; the planner should route around and retry later.")
    elseif status == "battle_resolved_no_edge" or status == "battle_no_longer_active_no_edge" then
        print("Explore handled a wild battle, but no clean movement edge was proven. This was saved as a battle observation, not a blocked edge.")
    elseif status == "travel_interrupted_replan" then
        print("Explore travel was interrupted before the selected frontier. No map fact was written; continuing from current tile on the next action.")
    elseif status == "battle_unresolved" or status == "battle" then
        print("Explore hit a wild battle and could not safely continue. No blocked edge was recorded for the battle.")
    elseif result and result.message then
        print("Explore stopped: " .. tostring(result.message))
    else
        print("Explore stopped with status " .. tostring(status) .. ". Review the log before continuing.")
    end
end

function mode_map_explore_once()
    perf_start("map_explore_once_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_explore_once: not in game.")
    end

    route_release_direction_buttons()

    local allow_reverse = map_graph_to_bool(config.map_graph_allow_reverse_edges, true)
    local max_path_steps = map_explore_effective_max_path_steps()
    local same_map_only = true

    baritone_lite_run_start("Map Explore Once", 1)
    print("Map Explore Once " .. tostring(nav_build_label and nav_build_label() or "v38.2 Settings Workbench UI Overhaul"))
    print("Uses Baritone-lite Exact Tile Atlas v6 to use exact game-profile tile behavior for seen tiles, target frontier clusters, avoid repeated probes, and keep the original Random Encounters battle flow.")
    print("Allow inferred reverse walkable edges: " .. tostring(allow_reverse))
    print("Max path steps: " .. tostring(max_path_steps))
    print("Same-map frontiers only: " .. tostring(same_map_only))
    if map_explore_strategy then print("Explore strategy: " .. tostring(map_explore_strategy())) end

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    local result = map_explore_cycle(1, {
        allow_reverse = allow_reverse,
        max_path_steps = max_path_steps,
        same_map_only = same_map_only,
        context_label = "Map Explore Once",
        battle_safe = true
    })

    if map_explore_planner_record_result then map_explore_planner_record_result(result) end
    baritone_lite_record_action(1, result)
    map_explore_print_result_hint(result, true)
    print("Map Explore Once Baritone-lite summary:")
    baritone_lite_run_summary(result and result.status or "finished")

    perf_stop("map_explore_once_total")
    abort("Map Explore Once finished.")
end

function mode_map_explore_area()
    perf_start("map_explore_area_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_explore_area: not in game.")
    end

    route_release_direction_buttons()

    local allow_reverse = map_graph_to_bool(config.map_graph_allow_reverse_edges, true)
    local max_path_steps = map_explore_effective_max_path_steps()
    local same_map_only = true
    local max_actions = map_explore_area_action_limit()
    baritone_lite_run_start("Map Explore Area", max_actions)

    print("Map Explore Area " .. tostring(nav_build_label and nav_build_label() or "v38.2 Settings Workbench UI Overhaul"))
    print("Repeats Explore Once with Baritone-lite Exact Tile Atlas v6: goal-directed frontier travel, exact game-profile terrain for seen tiles, interrupted-travel recovery, strict movement gates, normalized storage, original encounter handling, and concise normal logs.")
    if nav_build_summary then print("Build notes: " .. tostring(nav_build_summary())) end
    print("Allow inferred reverse walkable edges: " .. tostring(allow_reverse))
    print("Max path steps: " .. tostring(max_path_steps))
    print("Same-map frontiers only: " .. tostring(same_map_only))
    if map_explore_strategy then print("Explore strategy: " .. tostring(map_explore_strategy())) end
    print("Max explore actions: " .. tostring(max_actions))
    print("Battle handling: original PokéBot Random Encounters flow; battle_non_targets controls whether non-targets are fought or fled." )
    print("Continue after battle: " .. tostring(map_explore_continue_after_battle()))
    print("Normalized storage: " .. tostring(nav_storage_enabled and nav_storage_enabled() or false))

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    local learned_walkable = 0
    local learned_blocked = 0
    local learned_transition = 0
    local handled_battles = 0
    local unresolved_battles = 0
    local stopped_reason = "max_actions_reached"

    for action = 1, max_actions do
        print("---------------------------")
        print("Map Explore Area action " .. tostring(action) .. "/" .. tostring(max_actions))

        if game_state and game_state.in_battle then
            print("Already in battle before action " .. tostring(action) .. ". Handling battle before continuing explore.")
            map_explore_battle_safe_continue("Map Explore Area")

            if game_state and game_state.in_battle then
                stopped_reason = "battle_before_action_unresolved"
                print("Battle was still active after the handler, so exploration is stopping safely.")
                break
            end
        end

        local result = map_explore_cycle(action, {
            allow_reverse = allow_reverse,
            max_path_steps = max_path_steps,
            same_map_only = same_map_only,
            context_label = "Map Explore Area",
            battle_safe = true
        })

        if map_explore_planner_record_result then map_explore_planner_record_result(result) end
        baritone_lite_record_action(action, result)
        map_explore_print_result_hint(result, false)

        local status = result and result.status or "unknown"

        if status == "walkable" then
            learned_walkable = learned_walkable + 1
        elseif status == "blocked" then
            learned_blocked = learned_blocked + 1
        elseif status == "transition" then
            learned_transition = learned_transition + 1
            stopped_reason = "transition"
            print("Stopping after transition for map-safety. Cross-map explore will come later.")
            break
        elseif status == "battle_resolved_no_edge" or status == "battle_no_longer_active_no_edge" then
            handled_battles = handled_battles + 1
            print("Battle was handled, but no clean movement edge was proven. Continuing because it was not recorded as blocked.")
        elseif status == "battle_unresolved" or status == "battle" then
            unresolved_battles = unresolved_battles + 1
            stopped_reason = "battle_unresolved"
            print("Stopping after battle because the handler could not safely resolve it. No blocked edge was recorded.")
            break
        elseif status == "travel_interrupted_replan" then
            print("Travel interruption recovered. Continuing next action from current confirmed tile instead of ending the task.")
        elseif status == "no_frontiers" then
            stopped_reason = "no_frontiers"
            break
        elseif status ~= "walkable" and status ~= "blocked" then
            stopped_reason = status
            break
        end
    end

    if game_state and game_state.in_battle then
        print("---------------------------")
        print("Map Explore Area final cleanup: battle is active at the end of the action limit. Handling before stopping the Lua task.")
        local final_battle = map_explore_handle_post_action_battle("Final cleanup", "Map Explore Area")
        if final_battle and final_battle.status == "handled" then
            handled_battles = handled_battles + 1
            if unresolved_battles > 0 and stopped_reason == "battle_unresolved" then
                unresolved_battles = unresolved_battles - 1
                stopped_reason = "max_actions_reached_after_final_battle_cleanup"
            end
            if baritone_lite_mark_final_battle_cleanup_handled then
                baritone_lite_mark_final_battle_cleanup_handled()
            end
            print("Map Explore Area final cleanup: battle handled successfully before script stop. Marking final battle as handled, not unresolved.")
        else
            unresolved_battles = unresolved_battles + 1
            stopped_reason = "final_battle_unresolved"
            print("Map Explore Area final cleanup: battle was not fully resolved; no map edge was changed.")
        end
    end

    print("---------------------------")
    print("Map Explore Area summary:")
    print("  learned walkable edges: " .. tostring(learned_walkable))
    print("  learned blocked directions: " .. tostring(learned_blocked))
    print("  learned transitions: " .. tostring(learned_transition))
    print("  handled battles: " .. tostring(handled_battles))
    print("  unresolved battles: " .. tostring(unresolved_battles))
    print("  stopped reason: " .. tostring(stopped_reason))
    print("  current tile: " .. map_graph_node_label(map_graph_current_tile_point()))
    if map_explore_planner_summary then print("  planner: " .. map_explore_planner_summary()) end
    baritone_lite_run_summary(stopped_reason)

    perf_stop("map_explore_area_total")
    abort("Map Explore Area finished.")
end
