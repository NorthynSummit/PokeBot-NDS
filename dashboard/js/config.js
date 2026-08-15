const configForm = document.getElementById('config-form');
const textAreas  = [...configForm.getElementsByTagName('textarea')].map(ele => ele.id);
const fields     = [...configForm.querySelectorAll('input, select')].map(ele => ele.id);
const checkboxes = [...configForm.querySelectorAll('input[type="checkbox"]')].map(ele => ele.id);

let config;
let loadedPrimoPhrases = false;
let configDirty = false;
let ALL_MODE_OPTIONS = null;

const NAV_MODES = {
    route_record: true,
    route_replay: true,
    route_to: true,
    map_mark: true,
    map_to: true,
    map_probe: true,
    map_probe_batch: true,
    map_scan_line: true,
    map_sweep: true,
    map_graph_build: true,
    map_graph_to: true,
    map_graph_frontier: true,
    map_terrain_probe: true,
    map_explore_once: true,
    map_explore_area: true,
    map_cleanup_current_tile: true,
    nav_storage_status: true,
    map_probe_benchmark: true
};

const ADVANCED_NAV_MODES = {
    route_record: true,
    route_replay: true,
    route_to: true,
    map_mark: true,
    map_to: true,
    map_probe: true,
    map_probe_batch: true,
    map_scan_line: true,
    map_sweep: true,
    map_graph_frontier: true,
    map_terrain_probe: true,
    map_explore_once: true,
    map_probe_benchmark: true
};

const CONFIG_CATEGORY_COPY = {
    general: ['General', 'Universal behavior, startup helpers, and history limits.'],
    task: ['Task Selection', 'Choose the current bot mission and review what it requires.'],
    navigation: ['Navigation / Map Tools', 'Map learning, travel, route tools, and navigation limits.'],
    targets: ['Target Pokémon', 'Target matching, shiny safety, and export behavior.'],
    battles: ['Battle Behavior', 'Wild encounter decisions and mapping safety.'],
    autocatch: ['Auto-Catch Rules', 'Capture rules, ball priority, and target handling.'],
    files: ['Save / File Behavior', 'Notifications, file output, milestones, and save-file related overrides.'],
    utility: ['Pickup / Utility', 'Small helper automation around the main task.'],
    developer: ['Developer / Debug', 'Advanced diagnostics, full runtime logs, and navigation internals.']
};

const TASK_COPY = {
    manual: ['General', 'Idle', 'No automation', 'Log-only mode keeps the script connected without running a bot task.'],
    random_encounters: ['Standard Hunting', 'Moving encounters', 'Normal user', 'Runs the classic random encounter loop with your target and battle settings.'],
    random_encounters_small: ['Standard Hunting', 'Moving encounters', 'Normal user', 'A smaller random encounter loop variant.'],
    daycare_eggs: ['Standard Hunting', 'Egg hatching', 'Normal user', 'Runs egg hatching behavior using target and save settings.'],
    fishing: ['Standard Hunting', 'Fishing', 'Normal user', 'Runs fishing encounters.'],
    headbutt: ['Standard Hunting', 'Headbutt', 'Normal user', 'Runs headbutt-tree encounters.'],
    phenomenon_encounters: ['Standard Hunting', 'Phenomenon', 'Normal user', 'Runs moving encounters for Gen V phenomenon hunting.'],
    hidden_grottos: ['Standard Hunting', 'Hidden Grotto', 'Normal user', 'Runs the selected Hidden Grotto location.'],
    map_explore_area: ['Navigation', 'Learn area', 'Recommended mapper', 'Coverage Planner v1 maps nearby tiles, avoids repeated wall rubbing, uses safe battle handling, and writes normalized storage.'],
    map_cleanup_current_tile: ['Navigation', 'Data repair', 'Careful cleanup', 'Repairs suspicious map observations near the tile you are standing on.'],
    map_graph_to: ['Navigation', 'Graph travel', 'Known-map travel', 'Walks to a map/header coordinate using the compact learned graph.'],
    nav_storage_status: ['Navigation', 'Storage health', 'No movement', 'Prints source-of-truth backend, storage health, table counts, duplicates, warnings, and backup helper status.'],
    map_graph_build: ['Navigation', 'Cache rebuild', 'No movement', 'Rebuilds the compact graph cache from stored map observations.'],
    route_record: ['Navigation', 'Legacy route tool', 'Developer/legacy', 'Records a manually walked route file.'],
    route_replay: ['Navigation', 'Legacy route tool', 'Developer/legacy', 'Replays a saved route file.'],
    route_to: ['Navigation', 'Legacy route tool', 'Developer/legacy', 'Chains saved route files through a route index.'],
    map_mark: ['Navigation', 'Legacy map tool', 'Developer/legacy', 'Marks the current tile as a named map node.'],
    map_to: ['Navigation', 'Legacy map tool', 'Developer/legacy', 'Travels to a marked map destination.'],
    map_probe: ['Navigation', 'Probe tool', 'Developer', 'Probes one tile in one direction and stops.'],
    map_probe_batch: ['Navigation', 'Probe tool', 'Developer', 'Probes multiple steps in one direction.'],
    map_scan_line: ['Navigation', 'Scan tool', 'Developer', 'Scans a straight line until blocked or max steps.'],
    map_sweep: ['Navigation', 'Sweep tool', 'Developer', 'Runs an early lawnmower-style map sweep.'],
    map_graph_frontier: ['Navigation', 'Frontier report', 'Developer', 'Writes reachable graph frontiers without moving.'],
    map_terrain_probe: ['Navigation', 'Terrain research', 'Developer', 'Records tile fingerprints for terrain investigation.'],
    map_explore_once: ['Navigation', 'Explore step', 'Developer', 'Performs one old-style explore step and stops.'],
    map_probe_benchmark: ['Navigation', 'Benchmark', 'Developer', 'Benchmarks movement/probe/write/shutdown timing.'],
    starters: ['Soft reset', 'Starter selection', 'Normal user', 'Soft resets and chooses selected starters.'],
    gift: ['Soft reset', 'Gift Pokémon', 'Normal user', 'Soft resets gift Pokémon.'],
    static_encounters: ['Soft reset', 'Static encounter', 'Normal user', 'Soft resets static encounters.'],
    primo_gift: ['Soft reset', 'Primo eggs', 'Normal user', 'Runs Primo gift egg phrases.'],
    roamers: ['Soft reset', 'Roamers', 'Normal user', 'Soft resets roaming encounters.'],
    voltorb_flip: ['Misc', 'Voltorb Flip', 'Utility', 'Runs Voltorb Flip helper behavior.']
};

const TASK_REQUIREMENTS = {
    manual: ['Lua script loaded if you want dashboard telemetry.', 'No movement or encounter settings required.'],
    random_encounters: ['Lua connected to emulator.', 'Target rules reviewed if hunting specific Pokémon.', 'Battle Behavior and Auto-Catch settings reviewed.'],
    random_encounters_small: ['Lua connected to emulator.', 'Movement method selected.', 'Target and battle settings reviewed.'],
    daycare_eggs: ['Lua connected to emulator.', 'Target rules and save behavior reviewed.', 'Party and daycare setup prepared in game.'],
    fishing: ['Lua connected to emulator.', 'Fishing rod and in-game position ready.', 'Battle Behavior and Auto-Catch settings reviewed.'],
    hidden_grottos: ['Grotto location selected.', 'Lua connected to emulator.', 'Target and battle settings reviewed.'],
    map_explore_area: ['Lua connected and standing in a safe area.', 'Navigation storage enabled automatically.', 'Battle Behavior reviewed; leave Defeat non-targets off for safe mapping.'],
    map_cleanup_current_tile: ['Stand on the tile you want to repair.', 'Review cleanup scope and radius.', 'Backups are created before destructive cleanup.'],
    map_graph_to: ['Target map/header and X/Z coordinate set.', 'Compact graph data already learned.', 'Max path steps reviewed.'],
    nav_storage_status: ['No movement required.', 'Use after installing patches, checking map data, or validating the v39 storage foundation.'],
    map_graph_build: ['Existing map observations available.', 'No movement required. Rebuilds graph cache.'],
    starters: ['Starter checkboxes selected.', 'Soft reset flow prepared in game.'],
    gift: ['Target rules reviewed.', 'Soft reset position prepared in game.'],
    static_encounters: ['Target rules reviewed.', 'Static encounter prepared in game.']
};

function collectConfigFromForm() {
    try {
        for (let i = 0; i < textAreas.length; i++) {
            const key = textAreas[i];
            config[key] = jsyaml.load($('#' + key).val());
        }
    } catch (error) {
        return error;
    }

    for (let i = 0; i < fields.length; i++) {
        const field = fields[i];
        if (!field) continue;
        config[field] = $('#' + field).val();
    }

    for (let i = 0; i < checkboxes.length; i++) {
        const field = checkboxes[i];
        if (!field) continue;
        config[field] = $('#' + field).prop('checked');
    }

    return null;
}

function sendConfig() {
    if (!config) return;
    const error = collectConfigFromForm();
    if (error) {
        halfmoon.initStickyAlert({ content: error.toString(), title: 'Changes not saved', alertType: 'alert-danger' });
        return;
    }

    socketServerSend('config', { config: config, game: $('#editing').val() }, function (sendError, _) {
        if (sendError) {
            halfmoon.initStickyAlert({ content: sendError.toString(), title: 'Changes not saved', alertType: 'alert-danger' });
            return;
        }
        setDirtyState(false);
        halfmoon.initStickyAlert({
            content: 'Saved. You may need to restart pokebot-nds.lua for the selected task to update immediately; most other settings take effect now.',
            title: 'Configuration saved',
            alertType: 'alert-success'
        });
    });
}

function discardConfigChanges() {
    if (!config) return;
    populateConfigForm();
    setDirtyState(false);
}

function setDirtyState(isDirty) {
    configDirty = !!isDirty;
    const save = document.getElementById('post-config');
    const discard = document.getElementById('discard-config');
    const state = document.getElementById('save-state');
    if (save) save.disabled = !configDirty;
    if (discard) discard.disabled = !configDirty;
    if (state) {
        state.textContent = configDirty ? 'Unsaved changes' : 'Saved';
        state.classList.toggle('dirty', configDirty);
    }
}

function activateConfigCategory(category, updateHash) {
    const target = category || 'general';
    document.querySelectorAll('[data-config-section]').forEach(section => {
        section.classList.toggle('active', section.dataset.configSection === target);
    });
    document.querySelectorAll('[data-config-target]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.configTarget === target);
    });
    const copy = CONFIG_CATEGORY_COPY[target] || CONFIG_CATEGORY_COPY.general;
    const title = document.getElementById('current-config-title');
    const description = document.getElementById('current-config-description');
    if (title) title.textContent = copy[0];
    if (description) description.textContent = copy[1];
    if (updateHash !== false) window.history.replaceState(null, '', '#settings-' + target);
}

function initCategoryNav() {
    document.querySelectorAll('[data-config-target]').forEach(btn => {
        btn.addEventListener('click', () => activateConfigCategory(btn.dataset.configTarget, true));
    });
    document.querySelectorAll('[data-config-link]').forEach(link => {
        link.addEventListener('click', function (e) {
            e.preventDefault();
            activateConfigCategory(this.dataset.configLink, true);
        });
    });
    const hash = (window.location.hash || '').replace('#settings-', '');
    if (hash && document.querySelector(`[data-config-section="${hash}"]`)) activateConfigCategory(hash, false);
}

function updateTaskSummary() {
    const mode = $('#mode').val();
    const selected = $('#mode option:selected').text() || mode || '—';
    const copy = TASK_COPY[mode] || ['Other', selected, 'Task-specific', 'Task-specific settings will appear when relevant.'];
    const reqs = TASK_REQUIREMENTS[mode] || ['Review related settings before running.', 'Load pokebot-nds.lua in emulator for live telemetry.'];

    $('#task-summary-mode').text(selected).attr('title', selected);
    $('#task-summary-family').text(copy[0]);
    $('#task-summary-risk').text(copy[2]);
    $('#task-summary-description').text(copy[3]);
    $('#task-summary-requirements').html(reqs.map(item => `<li>${item}</li>`).join(''));

    const navRelevant = /^map_|^route_|^nav_/.test(mode || '');
    const targetRelevant = /random_encounters|daycare_eggs|fishing|headbutt|starters|gift|static_encounters|primo|roamers/i.test(mode || '');
    $('[data-config-link="navigation"]').toggleClass('is-recommended', navRelevant);
    $('[data-config-link="targets"]').toggleClass('is-recommended', targetRelevant);
    $('[data-config-link="battles"]').toggleClass('is-recommended', targetRelevant || navRelevant);
    $('[data-config-link="files"]').toggleClass('is-recommended', true);
}

function captureModeOptions() {
    const modeSelect = document.getElementById('mode');
    if (!modeSelect || ALL_MODE_OPTIONS) return;

    // Preserve the original optgroup/category structure. v39.1 correctly hid
    // advanced tools, but flattening the select removed the visual separators.
    ALL_MODE_OPTIONS = [...modeSelect.children].map(child => {
        if (child.tagName && child.tagName.toLowerCase() === 'optgroup') {
            return {
                type: 'group',
                label: child.label || '',
                options: [...child.children].map(option => ({
                    value: option.value,
                    text: option.textContent,
                    disabled: option.disabled === true
                }))
            };
        }
        return {
            type: 'option',
            value: child.value,
            text: child.textContent,
            disabled: child.disabled === true
        };
    });
}

function appendModeOption(parent, original, current, showAdvanced) {
    const isAdvanced = ADVANCED_NAV_MODES[original.value] === true;
    const keepCurrentAdvanced = isAdvanced && original.value === current;

    if (isAdvanced && !showAdvanced && !keepCurrentAdvanced) {
        return false;
    }

    const option = document.createElement('option');
    option.value = original.value;
    option.textContent = keepCurrentAdvanced && !showAdvanced
        ? `${original.text} (advanced current)`
        : original.text;
    option.disabled = original.disabled === true;
    parent.appendChild(option);
    return true;
}

function renderModeOptions() {
    const modeSelect = document.getElementById('mode');
    if (!modeSelect) return;

    captureModeOptions();

    const current = modeSelect.value || (config && config.mode) || 'manual';
    // Developer log mode should not reveal advanced navigation tasks by itself.
    // Only this explicit setting controls whether probe/sweep/legacy tools appear.
    const showAdvanced = $('#nav_show_advanced_modes').prop('checked') === true;
    const groups = ALL_MODE_OPTIONS || [];

    modeSelect.innerHTML = '';
    groups.forEach(entry => {
        if (entry.type === 'group') {
            const group = document.createElement('optgroup');
            group.label = entry.label;
            let added = 0;
            (entry.options || []).forEach(original => {
                if (appendModeOption(group, original, current, showAdvanced)) added += 1;
            });
            if (added > 0) modeSelect.appendChild(group);
            return;
        }
        appendModeOption(modeSelect, entry, current, showAdvanced);
    });

    const hasCurrent = [...modeSelect.options].some(option => option.value === current);
    modeSelect.value = hasCurrent ? current : 'manual';
}

function applyAdvancedModeVisibility() {
    renderModeOptions();
    $('body').toggleClass('developer-mode-enabled', $('#debug').prop('checked') === true);
}

function updateOptionVisibility() {
    $('#option_starters').hide();
    $('#option_moving_encounters').hide();
    $('#option_auto_catch').hide();
    $('#option_webhook').hide();
    $('#option_ping_user').hide();
    $('#option_encounter_milestones').hide();
    $('#option_primo').hide();
    $('#option_grotto').hide();
    $('#option_ot_override').hide();
    $('#option_routes').hide();

    let taskSpecificVisible = false;
    const markTaskOptions = () => { taskSpecificVisible = true; };

    const mode = $('#mode').val();

    switch (mode) {
        case 'starters':
            $('#option_starters').show();
            markTaskOptions();
            break;
        case 'random_encounters':
        case 'random_encounters_small':
        case 'phenomenon_encounters':
            $('#option_moving_encounters').show();
            markTaskOptions();
            break;
        case 'hidden_grottos':
            $('#option_moving_encounters').show();
            $('#option_grotto').show();
            markTaskOptions();
            break;
        case 'primo_gift':
            $('#option_primo').show();
            markTaskOptions();
            loadPrimoPhrases();
            break;
    }

    if (NAV_MODES[mode]) {
        $('#option_routes').show();
        $('#navigation-empty').hide();
    } else {
        $('#navigation-empty').show();
    }

    if ($('#auto_catch').prop('checked')) $('#option_auto_catch').show();
    if ($('#webhook_enabled').prop('checked')) $('#option_webhook').show();
    if ($('#ping_user').prop('checked')) $('#option_ping_user').show();
    if ($('#encounter_milestones_enable').prop('checked')) $('#option_encounter_milestones').show();
    if ($('#ot_override').prop('checked')) $('#option_ot_override').show();

    $('#task-options-empty').toggle(!taskSpecificVisible);

    updateTravelModeVisibility(mode);
    applyAdvancedModeVisibility();
    updateTaskSummary();
}

function updateTravelModeVisibility(mode) {
    $('.travel-help, .travel-field').each(function () {
        const modes = String($(this).data('modes') || '').split(/\s+/);
        const visible = modes.includes(mode);
        $(this).toggle(visible);
    });
}

function loadPrimoPhrases() {
    if (loadedPrimoPhrases) return;
    $.getJSON('assets/en_easychat_iv.json', function (json) {
        let phrases = '';
        json.forEach(word => { phrases += `<option value=${word[0]}>${word[1]}</option>`; });
        $('#primo1,#primo2,#primo3,#primo4').append(phrases);
        $('#primo1').val(config['primo1']);
        $('#primo2').val(config['primo2']);
        $('#primo3').val(config['primo3']);
        $('#primo4').val(config['primo4']);
    });
    loadedPrimoPhrases = true;
}

function setEditableGames(clients) {
    const selected = $('#editing').val();
    $('#editing').empty().append('<option value="all">All Games</option>');
    for (let i = 0; i < clients.length; i++) {
        const name = clients[i].version;
        $('#editing').append('<option value="' + i.toString() + '">' + name + ' </option>');
    }
    $('#editing').val(selected || 'all');
}

function populateConfigForm() {
    captureModeOptions();
    for (let i = 0; i < textAreas.length; i++) {
        const key = textAreas[i];
        $('#' + key).val(jsyaml.dump(config[key]));
    }

    for (let i = 0; i < fields.length; i++) {
        const field = fields[i];
        if (config[field] !== undefined) $('#' + field).val(config[field]);
    }

    for (let i = 0; i < checkboxes.length; i++) {
        const field = checkboxes[i];
        $('#' + field).prop('checked', config[field] === true);
    }

    $('#config-form').removeAttr('disabled');
    updateOptionVisibility();
    setDirtyState(false);
}

function updateClientInfo() {
    socketServerGet('clients', (error, clients) => {
        if (error) {
            console.error(error);
            return;
        }
        const clientCount = clients.length;
        if (clientCount == 0) {
            clearInterval(elapsedInterval);
            elapsedStart = null;
            $('#elapsed-time').text('0s');
            $('#encounter-rate').text('0/h');
            setBadgeClientCount(0);
            return;
        }
        if (!elapsedStart) {
            socketServerGet('elapsed_start', function (elapsedError, start) {
                if (elapsedError) {
                    console.error(elapsedError);
                    return;
                }
                elapsedStart = start;
                elapsedInterval = setInterval(updateStatBadges, 1000);
                updateStatBadges();
            });
        }
        setBadgeClientCount(clientCount);
        setEditableGames(clients);
    });
}

function testWebhook() {
    socketServerSend('test_webhook', { webhook_url: $('#webhook_url').val() }, function (e, _) { });
}

configForm.addEventListener('change', function () {
    updateOptionVisibility();
    setDirtyState(true);
});

configForm.addEventListener('input', function () {
    setDirtyState(true);
});

// Allow tab indentation in textareas.
[...document.getElementsByTagName('textarea')].forEach(area => {
    area.onkeydown = function (e) {
        if (e.key == 'Tab') {
            e.preventDefault();
            const s = this.selectionStart;
            this.value = this.value.substring(0, this.selectionStart) + '  ' + this.value.substring(this.selectionEnd);
            this.selectionEnd = s + 2;
            setDirtyState(true);
        }
    };
});

socketServerGet('config', function (error, data) {
    if (error) {
        console.error(error);
        return;
    }
    config = data;
    populateConfigForm();
});

document.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && e.key === 's') {
        e.preventDefault();
        sendConfig();
    }
});

initCategoryNav();
updateClientInfo();
setInterval(updateClientInfo, 1000);
