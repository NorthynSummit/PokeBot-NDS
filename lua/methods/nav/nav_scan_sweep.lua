-----------------------------------------------------------------------------
-- nav_scan_sweep.lua
-- Custom navigation module split from global.lua at v21.
-----------------------------------------------------------------------------


-- Safety defaults for shared sweep constants. These are normally defined in nav_probe.lua,
-- but keeping fallbacks here prevents Lua nil constants from reaching wait_frames()
-- if load order or a partial install is wrong.
MAP_PROBE_UNSAFE_JUMP = MAP_PROBE_UNSAFE_JUMP or 5.0
MAP_SWEEP_VERIFIED_STEP_RELEASE_PROGRESS = MAP_SWEEP_VERIFIED_STEP_RELEASE_PROGRESS or 0.62
MAP_SWEEP_VERIFIED_STEP_OVERSHOOT_PROGRESS = MAP_SWEEP_VERIFIED_STEP_OVERSHOOT_PROGRESS or 1.35
MAP_SWEEP_VERIFIED_STEP_CROSS_DRIFT_LIMIT = MAP_SWEEP_VERIFIED_STEP_CROSS_DRIFT_LIMIT or 0.45
MAP_SWEEP_VERIFIED_STEP_TIMEOUT = MAP_SWEEP_VERIFIED_STEP_TIMEOUT or 75
MAP_SWEEP_VERIFIED_STEP_SETTLE_FRAMES = MAP_SWEEP_VERIFIED_STEP_SETTLE_FRAMES or 2

-----------------------------------------------------------------------------
-- Map Scan Line
-- Uses the same optimized smooth-line probe engine, but treats steps as a max
-- distance and scans in one direction until blocked, transition, battle, or max.
-----------------------------------------------------------------------------

function mode_map_scan_line()
    perf_start("map_scan_line_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_scan_line: not in game.")
    end

    perf_start("map_scan_line_setup")
    local max_steps = map_probe_batch_get_steps()
    local dir = map_probe_get_direction()
    local save_batch = config.map_probe_batch_save == true
    perf_stop("map_scan_line_setup")

    print("Map Scan Line v0.2 Clean Save")
    print("Max steps: " .. tostring(max_steps))
    print("Direction: " .. tostring(dir))
    print("Save results: " .. tostring(save_batch))
    print("Scanning one continuous line until blocked or max steps reached. No per-tile file writes.")

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    perf_start("map_scan_line_movement")
    local results, stop_reason = map_probe_smooth_line_batch(dir, max_steps)
    perf_stop("map_scan_line_movement")

    perf_start("map_scan_line_print_results")
    map_probe_print_batch_results(results, max_steps)
    print("Map scan line stop reason: " .. tostring(stop_reason))
    perf_stop("map_scan_line_print_results")

    if save_batch then
        print("Saving line scan results once at the end.")
        map_probe_write_results(results, map_scan_line_path(), "Map Scan Line")
    else
        print("Line scan results were kept in memory only. Enable batch save later when you want to write them.")
    end

    perf_stop("map_scan_line_total")

    abort("Map Scan Line finished.")
end

-----------------------------------------------------------------------------
-- Map Sweep v0.6
-- Early Baritone-light "lawnmower" mapper.
-- Design change from v0.1/v0.2:
--   * Long scan lines use smooth continuous movement.
--   * Sidesteps use a separate strict one-tile controller.
--
-- Why this matters:
-- A sweep turn/sidestep is a precision move. Reusing the smooth line scanner can
-- visually queue an extra tile even if only one edge is recorded. The final bot
-- needs movement primitives that match the job:
--   * fast continuous scan for long open lines
--   * strict verified one-tile step for turns, sidesteps, graph travel, doors
-- Saves all results once at the end.
-----------------------------------------------------------------------------

function map_sweep_path()
    return "user\\routes\\map_sweep_edges.txt"
end

function map_probe_opposite_direction(dir)
    if dir == "Up" then
        return "Down"
    elseif dir == "Down" then
        return "Up"
    elseif dir == "Left" then
        return "Right"
    elseif dir == "Right" then
        return "Left"
    end

    return "Down"
end

function map_probe_turn_right(dir)
    if dir == "Up" then
        return "Right"
    elseif dir == "Right" then
        return "Down"
    elseif dir == "Down" then
        return "Left"
    elseif dir == "Left" then
        return "Up"
    end

    return "Right"
end

function map_probe_turn_left(dir)
    if dir == "Up" then
        return "Left"
    elseif dir == "Left" then
        return "Down"
    elseif dir == "Down" then
        return "Right"
    elseif dir == "Right" then
        return "Up"
    end

    return "Left"
end

function map_probe_valid_direction(dir)
    return dir == "Up" or dir == "Down" or dir == "Left" or dir == "Right"
end

function map_sweep_get_lines()
    local lines = tonumber(config.map_sweep_lines) or 3

    if lines < 1 then
        lines = 1
    elseif lines > 10 then
        print_warn("map_sweep_lines capped at 10 for safety while sweep is early.")
        lines = 10
    end

    return lines
end

function map_sweep_get_side_setting()
    local side = tostring(config.map_sweep_side_direction or "Right")

    if side == "" or side == "nil" then
        side = "Right"
    end

    return side
end

function map_sweep_get_side_direction(primary_dir)
    local side = map_sweep_get_side_setting()

    -- Auto modes are relative to the scan direction. This can look backwards on screen:
    -- if scanning Down, the right-hand turn is absolute Left.
    if side == "auto_left" then
        return map_probe_turn_left(primary_dir)
    elseif side == "auto_right" then
        return map_probe_turn_right(primary_dir)
    elseif map_probe_valid_direction(side) then
        return side
    end

    -- Absolute Right is the clearest default for early testing.
    return "Right"
end

function map_sweep_axis_delta(start_point, end_point, dir)
    if dir == "Up" then
        return (start_point.z or 0) - (end_point.z or 0)
    elseif dir == "Down" then
        return (end_point.z or 0) - (start_point.z or 0)
    elseif dir == "Left" then
        return (start_point.x or 0) - (end_point.x or 0)
    elseif dir == "Right" then
        return (end_point.x or 0) - (start_point.x or 0)
    end

    return 0
end

function map_sweep_cross_axis_delta(start_point, end_point, dir)
    if dir == "Up" or dir == "Down" then
        return math.abs((end_point.x or 0) - (start_point.x or 0))
    elseif dir == "Left" or dir == "Right" then
        return math.abs((end_point.z or 0) - (start_point.z or 0))
    end

    return 0
end

function map_sweep_format_point(point)
    if not point then
        return "nil"
    end

    return "X " .. tostring(point.x) .. " Z " .. tostring(point.z) ..
           " | " .. tostring(point.name) .. " map " .. tostring(point.map)
end

function map_sweep_verified_tile_step(dir, step_number, phase_label)
    -- The final bot should use different movement primitives for different jobs:
    --   * smooth cruise movement for long scan lines and known route/path travel
    --   * verified one-tile movement for turns, graph travel, doors, and sidesteps
    -- v15 keeps this strict stepper for sidesteps while sweep scan lines use
    -- the smoother map_probe_smooth_line_batch() scanner.
    phase_label = phase_label or "verified_step"

    route_release_direction_buttons()
    wait_frames(MAP_SWEEP_VERIFIED_STEP_SETTLE_FRAMES)

    local start_raw, pre_stable_reason, pre_stable_frames = map_probe_wait_until_position_stable("before_" .. tostring(phase_label))

    route_release_direction_buttons()
    wait_frames(MAP_SWEEP_VERIFIED_STEP_SETTLE_FRAMES)

    -- Re-read after settling. This is the exact origin we will verify against.
    start_raw = map_probe_current_point()
    local start_tile = map_probe_snap_to_tile_center(start_raw)
    local expected_tile = map_probe_offset_tile(start_tile, dir, 1.0)

    local stop_reason = "timeout"
    local last_forward_delta = 0
    local last_cross_delta = 0
    local frames_used = 0

    for frame = 1, MAP_SWEEP_VERIFIED_STEP_TIMEOUT do
        frames_used = frame

        hold_button(dir)

        if game_state.in_battle then
            stop_reason = "battle"
            break
        end

        local current = map_probe_current_point()

        if not map_probe_same_map(start_tile, current) then
            stop_reason = "transition"
            break
        end

        if map_probe_distance(start_tile, current) > MAP_PROBE_UNSAFE_JUMP then
            stop_reason = "unsafe_jump"
            break
        end

        local forward_delta = map_probe_axis_progress(start_tile, current, dir)
        local cross_delta = map_probe_cross_drift(start_tile, current, dir)

        last_forward_delta = forward_delta
        last_cross_delta = cross_delta

        -- If the previous movement is still finishing on the wrong axis, do not
        -- count that as a valid step. This catches the exact bug where a Down
        -- scan kept moving Down when the sweep tried to sidestep Left/Right.
        if cross_delta >= MAP_SWEEP_VERIFIED_STEP_CROSS_DRIFT_LIMIT and forward_delta < 0.25 then
            stop_reason = "wrong_axis_drift"
            break
        end

        -- Release before the live coordinate reaches the next center. The game
        -- should finish the current tile naturally. Waiting until 1.0 live progress
        -- can queue an extra step in HGSS/DeSmuME.
        if forward_delta >= MAP_SWEEP_VERIFIED_STEP_RELEASE_PROGRESS then
            stop_reason = "release_progress"
            break
        end
    end

    route_release_direction_buttons()

    local end_raw, post_stable_reason, post_stable_frames = map_probe_wait_until_position_stable("after_" .. tostring(phase_label))
    local end_tile = map_probe_snap_to_tile_center(end_raw)
    local result, moved, note = map_probe_classify_result(start_tile, end_raw, stop_reason)

    local forward_delta = map_sweep_axis_delta(start_tile, end_tile, dir)
    local cross_delta = map_sweep_cross_axis_delta(start_tile, end_tile, dir)

    note = tostring(note or "") ..
        ";verified_tile_step" ..
        ";phase=" .. tostring(phase_label) ..
        ";pre_stable=" .. tostring(pre_stable_reason) ..
        ";pre_stable_frames=" .. tostring(pre_stable_frames) ..
        ";post_stable=" .. tostring(post_stable_reason) ..
        ";post_stable_frames=" .. tostring(post_stable_frames) ..
        ";frames_used=" .. tostring(frames_used) ..
        ";expected=" .. tostring(expected_tile.x) .. "," .. tostring(expected_tile.z) ..
        ";actual=" .. tostring(end_tile.x) .. "," .. tostring(end_tile.z) ..
        ";live_forward_delta=" .. string.format("%.2f", last_forward_delta or 0) ..
        ";live_cross_delta=" .. string.format("%.2f", last_cross_delta or 0) ..
        ";forward_delta=" .. string.format("%.2f", forward_delta) ..
        ";cross_delta=" .. string.format("%.2f", cross_delta)

    local battle_detected = stop_reason == "battle" or
                            pre_stable_reason == "battle" or
                            post_stable_reason == "battle" or
                            (game_state and game_state.in_battle)

    if battle_detected then
        result = "battle"
        note = note .. ";battle_detected=true;not_blocked"
    elseif not map_probe_same_map(start_tile, end_raw) then
        result = "transition"
        note = note .. ";map_changed"
    elseif stop_reason == "wrong_axis_drift" then
        result = "wrong_axis"
        note = note .. ";wrong_axis_before_requested_tile"
    elseif forward_delta >= MAP_SWEEP_VERIFIED_STEP_OVERSHOOT_PROGRESS then
        result = "overshoot"
        note = note .. ";overshot_verified_step"
    elseif cross_delta >= 0.60 and forward_delta < 0.60 then
        result = "wrong_axis"
        note = note .. ";ended_on_wrong_axis"
    elseif forward_delta >= 0.75 and forward_delta <= 1.25 and cross_delta <= 0.35 then
        result = "walkable"
        moved = 1
        end_tile = expected_tile
        note = note .. ";verified_one_tile"
    elseif forward_delta < 0.35 and cross_delta < 0.35 then
        result = "blocked"
        moved = 0
        end_tile = start_tile
        note = note .. ";no_clean_tile_movement"
    else
        result = "partial"
        note = note .. ";movement_not_one_clean_tile"
    end

    local entry = map_probe_make_entry(step_number or 1, dir, start_tile, end_tile, result, moved, note)
    entry.verified_start_raw = start_raw
    entry.verified_end_raw = end_raw
    entry.verified_expected_tile = expected_tile
    entry.verified_forward_delta = forward_delta
    entry.verified_cross_delta = cross_delta
    entry.verified_live_forward_delta = last_forward_delta
    entry.verified_live_cross_delta = last_cross_delta
    entry.verified_pre_stable_reason = pre_stable_reason
    entry.verified_post_stable_reason = post_stable_reason
    entry.verified_frames_used = frames_used

    -- Backwards-compatible field names for the sidestep log printer.
    entry.sidestep_start_raw = start_raw
    entry.sidestep_end_raw = end_raw
    entry.sidestep_expected_tile = expected_tile
    entry.sidestep_forward_delta = forward_delta
    entry.sidestep_cross_delta = cross_delta
    entry.sidestep_live_forward_delta = last_forward_delta
    entry.sidestep_live_cross_delta = last_cross_delta
    entry.sidestep_pre_stable_reason = pre_stable_reason
    entry.sidestep_post_stable_reason = post_stable_reason
    entry.sidestep_frames_used = frames_used

    local strict_stop = "finished"

    if result ~= "walkable" then
        strict_stop = result
    end

    return { entry }, strict_stop, entry
end

function map_sweep_strict_sidestep(dir, step_number)
    return map_sweep_verified_tile_step(dir, step_number or 1, "strict_sidestep")
end

function map_sweep_verified_line(dir, max_steps)
    local results = {}
    local stop_reason = "finished"

    for step = 1, max_steps do
        local step_results, step_stop_reason, entry = map_sweep_verified_tile_step(dir, step, "scan_tile")

        if step_results then
            for _, result_entry in ipairs(step_results) do
                results[#results + 1] = result_entry
            end
        end

        if not entry then
            stop_reason = tostring(step_stop_reason or "no_entry")
            break
        end

        if entry.result ~= "walkable" then
            stop_reason = tostring(entry.result or step_stop_reason or "stopped")
            break
        end
    end

    return results, stop_reason
end

function map_sweep_tag_results(results, all_results, phase, line_number)
    for _, entry in ipairs(results) do
        local original_step = entry.step
        entry.step = #all_results + 1
        entry.note = tostring(entry.note or "") .. ";phase=" .. tostring(phase) .. ";sweep_line=" .. tostring(line_number) .. ";line_step=" .. tostring(original_step)
        all_results[#all_results + 1] = entry
    end
end

function map_sweep_last_result(results)
    if not results or #results == 0 then
        return nil
    end

    return results[#results]
end

function map_sweep_stop_is_hard(stop_reason)
    return stop_reason == "transition" or
           stop_reason == "battle" or
           stop_reason == "unsafe_jump" or
           stop_reason == "overshoot" or
           stop_reason == "wrong_axis" or
           stop_reason == "partial" or
           stop_reason == "blocked"
end

function mode_map_sweep()
    perf_start("map_sweep_total")

    if not game_state or not game_state.in_game then
        abort("Cannot run map_sweep: not in game.")
    end

    perf_start("map_sweep_setup")
    local max_steps = map_probe_batch_get_steps()
    local sweep_lines = map_sweep_get_lines()
    local primary_dir = map_probe_get_direction()
    local side_setting = map_sweep_get_side_setting()
    local side_dir = map_sweep_get_side_direction(primary_dir)
    local save_batch = config.map_probe_batch_save == true
    perf_stop("map_sweep_setup")

    print("Map Sweep v0.7 Hybrid Cruise Lines + Strict Sidestep")
    print("Primary direction: " .. tostring(primary_dir))
    print("Side step setting: " .. tostring(side_setting))
    print("Resolved side step direction: " .. tostring(side_dir))
    print("Side step distance: strict 1 tile, verified after release")
    print("Lines: " .. tostring(sweep_lines))
    print("Max steps per line: " .. tostring(max_steps))
    print("Save results: " .. tostring(save_batch))
    print("Sweep scan lines are smooth again. Final line overshoot is recorded as real edges. Sidesteps stay strict one-tile verified moves.")

    if perf_enabled() then
        print("[PERF] Timing enabled. Disable Show debug log to hide timing output.")
    end

    local all_results = {}
    local current_dir = primary_dir
    local stop_reason = "finished"
    local completed_lines = 0

    perf_start("map_sweep_movement")

    for line_number = 1, sweep_lines do
        print("Sweep line " .. tostring(line_number) .. "/" .. tostring(sweep_lines) .. " | dir=" .. tostring(current_dir))

        local line_results, line_stop_reason = map_probe_smooth_line_batch(current_dir, max_steps)
        map_sweep_tag_results(line_results, all_results, "scan", line_number)
        completed_lines = line_number

        local last_line_result = map_sweep_last_result(line_results)
        if last_line_result then
            print(
                "  line result: edges=" .. tostring(#line_results) ..
                " last=" .. tostring(last_line_result.result) ..
                " stop=" .. tostring(line_stop_reason)
            )
        else
            print("  line result: no edges recorded; stop=" .. tostring(line_stop_reason))
        end

        if map_sweep_stop_is_hard(line_stop_reason) then
            stop_reason = line_stop_reason
            break
        end

        if line_number >= sweep_lines then
            stop_reason = "finished"
            break
        end

        print("  strict sidestep " .. tostring(side_dir) .. " for exactly 1 tile")
        local side_results, side_stop_reason, side_entry = map_sweep_strict_sidestep(side_dir, 1)
        map_sweep_tag_results(side_results, all_results, "strict_sidestep", line_number)

        if side_entry then
            print(
                "  sidestep result: " .. tostring(side_entry.result) ..
                " stop=" .. tostring(side_stop_reason) ..
                " from " .. map_sweep_format_point(side_entry.start_point) ..
                " to " .. map_sweep_format_point(side_entry.end_point) ..
                " expected X " .. tostring(side_entry.sidestep_expected_tile.x) .. " Z " .. tostring(side_entry.sidestep_expected_tile.z) ..
                " pre_stable=" .. tostring(side_entry.sidestep_pre_stable_reason) ..
                " post_stable=" .. tostring(side_entry.sidestep_post_stable_reason) ..
                " frames=" .. tostring(side_entry.sidestep_frames_used) ..
                " live_forward=" .. string.format("%.2f", side_entry.sidestep_live_forward_delta or 0) ..
                " live_cross=" .. string.format("%.2f", side_entry.sidestep_live_cross_delta or 0) ..
                " forward_delta=" .. string.format("%.2f", side_entry.sidestep_forward_delta or 0) ..
                " cross_delta=" .. string.format("%.2f", side_entry.sidestep_cross_delta or 0)
            )
        else
            print("  sidestep result: no edge recorded; stop=" .. tostring(side_stop_reason))
        end

        if side_stop_reason ~= "finished" then
            stop_reason = "sidestep_" .. tostring(side_stop_reason)
            break
        end

        if side_entry and side_entry.result ~= "walkable" then
            stop_reason = "sidestep_" .. tostring(side_entry.result)
            break
        end

        current_dir = map_probe_opposite_direction(current_dir)
    end

    perf_stop("map_sweep_movement")

    perf_start("map_sweep_print_results")
    print("Map sweep recorded " .. tostring(#all_results) .. " total probe edge(s) across " .. tostring(completed_lines) .. " attempted line(s).")
    print("Map sweep stop reason: " .. tostring(stop_reason))

    if config.debug and #all_results > 0 then
        map_probe_print_batch_results(all_results, #all_results)
    end

    perf_stop("map_sweep_print_results")

    if save_batch then
        print("Saving map sweep results once at the end.")
        map_probe_write_results(all_results, map_sweep_path(), "Map Sweep")
    else
        print("Map sweep results were kept in memory only. Enable batch save later when you want to write them.")
    end

    perf_stop("map_sweep_total")

    abort("Map Sweep finished.")
end
