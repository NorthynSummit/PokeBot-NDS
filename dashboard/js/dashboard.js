let gameTab = 0;
let gameCount = 0;

let recentEncounters;
let recentTargets;

function updateBnp() {
    const binomialDistribution = function (b, a) {
        c = Math.pow(1 - a, b);
        return 100 * (c * Math.pow(- (1 / (a - 1)), b) - c);
    }

    const rate = $('#shiny-rate').val();
    const seen = document.getElementById('phase-seen').innerHTML;
    const chance = binomialDistribution(seen, 1 / rate);
    const cumulativeOdds = Math.floor(chance * 100) / 100;

    if (cumulativeOdds == 100 || isNaN(cumulativeOdds)) cumulativeOdds = '99.99'
    document.getElementById('bnp').innerHTML = cumulativeOdds.toString() + '%';
}

const partyContainer = $('#game-party')
const partyMonTemplate = $('#party-mon-template');
const partyTemplate = $('#party-template');
const PARTY_SNAPSHOT_KEY = 'pokebot_last_party_snapshot_v40';
let lastPartySnapshot = loadPartySnapshot();
let lastLiveClientCount = 0;
let partySnapshotRefreshInFlight = false;
let partySnapshotCallbacks = [];
let partySnapshotLastAttempt = 0;

function cloneData(value) {
    try {
        return JSON.parse(JSON.stringify(value));
    } catch (_err) {
        return value;
    }
}

function pbEscape(value) {
    return String(value === undefined || value === null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function loadPartySnapshot() {
    try {
        const raw = localStorage.getItem(PARTY_SNAPSHOT_KEY);
        return raw ? JSON.parse(raw) : null;
    } catch (_err) {
        return null;
    }
}

function savePartySnapshot(client, tabIndex) {
    if (!client || !Array.isArray(client.party) || client.party.length === 0) return false;
    const shownValues = cloneData(client.shownValues || {}) || {};
    const trainerName = client.trainer_name || shownValues.Name || 'Last known party';
    const version = client.version || shownValues.Version || 'Unknown';
    const snapshot = {
        cached: true,
        cached_at: client.cached_at || new Date().toISOString(),
        source: client.source || 'dashboard_client',
        tabIndex: tabIndex || client.tabIndex || 0,
        trainer_name: trainerName,
        trainer_id: client.trainer_id || shownValues['Trainer ID'] || '--',
        version,
        custom_build_label: client.custom_build_label,
        party: cloneData(client.party),
        shownValues,
        map_name: client.map_name || shownValues.Map || shownValues.Area || '',
        position: cloneData(client.position || shownValues.Position || {}),
        x: client.x,
        y: client.y,
        z: client.z
    };
    lastPartySnapshot = snapshot;
    try { localStorage.setItem(PARTY_SNAPSHOT_KEY, JSON.stringify(snapshot)); } catch (_err) {}
    return true;
}

function getCachedGameSnapshot() {
    if (lastPartySnapshot && Array.isArray(lastPartySnapshot.party) && lastPartySnapshot.party.length) return lastPartySnapshot;
    lastPartySnapshot = loadPartySnapshot();
    return lastPartySnapshot && Array.isArray(lastPartySnapshot.party) && lastPartySnapshot.party.length ? lastPartySnapshot : null;
}

function cachedSnapshotAsClient(snapshot) {
    if (!snapshot) return null;
    const shownValues = Object.assign({}, snapshot.shownValues || {});
    if (!shownValues.Name && snapshot.trainer_name) shownValues.Name = snapshot.trainer_name;
    if (!shownValues.Map && snapshot.map_name) shownValues.Map = snapshot.map_name;
    return {
        version: snapshot.version || 'Last known',
        trainer_name: snapshot.trainer_name || 'Last known party',
        party: cloneData(snapshot.party || []),
        shownValues,
        map_name: snapshot.map_name || shownValues.Map || '',
        position: cloneData(snapshot.position || {}),
        x: snapshot.x,
        y: snapshot.y,
        z: snapshot.z,
        cached: true,
        cached_at: snapshot.cached_at
    };
}


function renderLastKnownPartyFallback(snapshot) {
    snapshot = snapshot || getCachedGameSnapshot();
    const panel = document.getElementById('game-panel');
    if (!panel || !snapshot || !Array.isArray(snapshot.party) || !snapshot.party.length) return false;
    let card = document.getElementById('last-known-party-card');
    if (!card) {
        card = document.createElement('div');
        card.id = 'last-known-party-card';
        card.className = 'pb50-panel pb-last-known-party-card';
        card.style.marginTop = '12px';
        card.style.padding = '12px';
        const content = panel.querySelector('.pb-game-content') || panel;
        content.appendChild(card);
    }
    const mons = snapshot.party.slice(0, 6).map(mon => {
        const species = mon.species || '';
        const name = mon.nickname || mon.name || ('Species ' + species);
        const level = mon.level ? ('Lv ' + mon.level) : '';
        const hp = (mon.currentHP !== undefined && mon.maxHP !== undefined) ? `${mon.currentHP}/${mon.maxHP}` : '';
        return `<div style="display:flex;align-items:center;gap:8px;min-width:150px;margin:4px 8px 4px 0;">
            ${species ? `<img src="assets/pokemon-icon/${pbEscape(species)}.png" style="width:32px;height:32px;image-rendering:pixelated;" onerror="this.style.display='none'">` : ''}
            <div><strong>${pbEscape(name)}</strong><br><small>${pbEscape(level)} ${pbEscape(hp)}</small></div>
        </div>`;
    }).join('');
    card.innerHTML = `<div style="display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:8px;">
        <div><span class="pb-eyebrow">Last known party</span><h3 style="margin:2px 0 0 0;">${pbEscape(snapshot.trainer_name || 'Trainer')} · ${pbEscape(snapshot.map_name || '')}</h3></div>
        <small>${pbEscape(snapshot.cached_at || '')}</small>
    </div><div style="display:flex;flex-wrap:wrap;gap:4px;">${mons}</div>`;
    return true;
}

function displayCachedPartySnapshot() {
    const snapshot = getCachedGameSnapshot();
    if (!snapshot) return false;
    const client = cachedSnapshotAsClient(snapshot);
    displayClientParty(0, client.party);
    displayClientGameInfo(0, client);
    renderLastKnownPartyFallback(snapshot);
    const gamePanel = document.getElementById('game-panel');
    if (gamePanel) gamePanel.classList.add('is-cached-party');
    return true;
}

function fetchServerPartySnapshot(callback) {
    if (callback) partySnapshotCallbacks.push(callback);
    if (partySnapshotRefreshInFlight) return;

    partySnapshotRefreshInFlight = true;
    partySnapshotLastAttempt = Date.now();

    socketServerGet('last_party_snapshot', function (error, snapshot) {
        partySnapshotRefreshInFlight = false;
        const callbacks = partySnapshotCallbacks.splice(0, partySnapshotCallbacks.length);
        const ok = !(error || !snapshot || !Array.isArray(snapshot.party) || snapshot.party.length === 0);
        if (ok) savePartySnapshot(snapshot, snapshot.tabIndex || 0);
        callbacks.forEach(function (cb) {
            try { cb(ok); } catch (_err) {}
        });
    });
}

function keepPartySnapshotWarm() {
    fetchServerPartySnapshot(function (ok) {
        if (!ok) return;
        // When Lua is not currently connected, keep the last party visible instead of blanking the panel.
        if (lastLiveClientCount === 0) {
            displayCachedPartySnapshot();
            updateTabVisibility();
        }
    });
}

function displayBestAvailablePartySnapshot(callback) {
    if (displayCachedPartySnapshot()) {
        if (callback) callback(true);
        return true;
    }
    fetchServerPartySnapshot(function (ok) {
        if (ok) displayCachedPartySnapshot();
        if (callback) callback(ok);
    });
    return false;
}

function displayClientParty(tabIndex, party) {
    const getPokerusStrain = function (value) {
        const x = value << 8;
        const y = value & 0xF;

        if (x > 0) {
            if (y == 0) {
                return 'cured';
            } else {
                return 'infected';
            }
        } else {
            return 'none';
        }
    }

    // Update existing party element, otherwise create a new template
    const eleName = 'party-template-' + tabIndex.toString();
    const existing = $('#' + eleName);
    const ele = existing.length ? existing.detach() : partyTemplate.tmpl();

    if (existing.length) {
        ele.empty()
    } else {
        ele.attr('id', eleName);
    }

    if (!party) return
    if (!Array.isArray(party)) party = [];

    for (var i = 0; i < 6; i++) {
        let mon = party[i]

        if (!mon) break

        // Format Pokemon data for readability
        mon = enrichFurther(cloneData(mon));
        
        mon.currentHP = mon.currentHP === undefined ? 1 : mon.currentHP;
        mon.pokerus = mon.pokerus || 0;
        mon.fainted = mon.currentHP == 0 ? 'opacity: 0.5' : '';
        mon.gender = mon.gender == 'Genderless' ? 'none' : mon.gender.toString().toLowerCase();
        mon.pokerus = getPokerusStrain(mon.pokerus);
        
        // Hide species of unhatched eggs
        if (mon.isEgg) {
            mon.folder = '';
            mon.name = `~${mon.friendship << 8} Steps Remaining`;
        }

        const shiny = mon.shinyValue < 8;

        mon.folder = shiny ? 'shiny/' : '';
        mon.shiny = shiny ? '✨' : '';

        ele.append(partyMonTemplate.tmpl(mon))
    }

    partyContainer.append(ele);
}

const gameContainer = $('#game-info');
const gameTemplate = $('#game-template');

function displayClientGameInfo(tabIndex, clientData) {
    // Update existing game element, otherwise create a new template
    const eleName = 'game-template-' + tabIndex.toString();
    const existing = $('#' + eleName);
    const ele = existing.length ? existing : gameTemplate.tmpl();

    if (!existing.length) {
        ele.attr('id', eleName);
        gameContainer.append(ele);
    }

    // Game-specific display values the bot decides to send
    const fieldTable = $('#shown-values', ele).detach();
    fieldTable.empty();

    for (const key in clientData.shownValues) {
        fieldTable.append(`
            <div class="d-flex w-full p-10">
                <div class="w-half"><b>${key}</b></div>
                <div class="w-half">
                ${clientData.shownValues[key]}
                </div>
            </div>`
        );
    }

    ele.append(fieldTable)
}

const tabContainer = $('#game-buttons');
const buttonTemplate = $('#button-template');


function renderNoLuaPlaceholder() {
    if (partyContainer.children().length || gameContainer.children().length) return;
    const button = buttonTemplate.tmpl({ 'game': 'Load pokebot-nds.lua in an emulator to begin!' });
    button.attr('class', 'btn btn-primary w-full text-truncate');
    tabContainer.append(button);
    displayClientParty(0, []);
    displayClientGameInfo(0, { shownValues: {} });
}

function renderCachedPartyButton(cached) {
    const label = `Last known: ${cached.trainer_name || 'Party'} (${cached.version || 'cached'})`;
    const button = buttonTemplate.tmpl({ 'game': label });
    button.attr('id', 'button-template-0');
    button.attr('class', 'btn btn-primary w-full text-truncate');
    button.attr('title', `Cached party snapshot from ${cached.cached_at || 'previous Lua update'}. It refreshes when Lua sends party data again.`);
    tabContainer.append(button);
    displayCachedPartySnapshot();
}

function updateClientTabs(clients) {
    // Refresh display
    if (tabContainer.children().length != gameCount) {
        tabContainer.empty()
        partyContainer.empty()
        gameContainer.empty()
    }

    for (let i = 0; i < clients.length; i++) {
        const client = clients[i];

        if (!client.version || !client.trainer_name) continue; // Client still hasn't sent necessary values

        const buttonName = 'button-template-' + i.toString(); 
        const existing = $('#' + buttonName);

        if (!existing.length) {
            const button = existing.length ? existing.detach() : buttonTemplate.tmpl({ 'game': `${client.trainer_name} (${client.version})` });
            button.attr('id', buttonName);
            tabContainer.append(button)
        }
    }

    const tabCount = tabContainer.children().length;

    if (tabCount == 0) {
        tabContainer.empty();
        const cached = getCachedGameSnapshot();
        if (cached) {
            renderCachedPartyButton(cached);
        } else {
            // Do not blank a recently rendered party while the server snapshot request is pending.
            fetchServerPartySnapshot(function (ok) {
                if (ok) {
                    updateClientTabs([]);
                    updateTabVisibility();
                } else if (!getCachedGameSnapshot()) {
                    renderNoLuaPlaceholder();
                    updateTabVisibility();
                }
            });
            renderNoLuaPlaceholder();
        }
    }

    // Set selected tab to first valid client
    if (!clients[gameTab] || !clients[gameTab].version || !clients[gameTab].trainer_name) {
        for (let i = 0; i < gameCount; i++) {
            const client = clients[i];
            
            if (client && client.version && client.trainer_name) {
                gameTab = i;
                updateTabVisibility()
                break;
            } 
        }
    }
}

function updateTabVisibility() {
    const gameCount = gameContainer.children().length

    for (var i = 0; i <= gameCount; i++) {
        const idx = i.toString()

        if (i == gameTab) {
            $('#game-template-' + idx).show()
            $('#party-template-' + idx).show()
            $('#button-template-' + idx).attr('class', 'btn btn-primary col text-truncate')
            $('#button-template-' + idx).attr('style', 'display: inline-block')
        } else {
            $('#game-template-' + idx).hide()
            $('#party-template-' + idx).hide()
            $('#button-template-' + idx).attr('class', 'btn col text-truncate')
            $('#button-template-' + idx).attr('style', 'display: inline-block')
        }
    }
}

function selectTab(ele) {
    gameTab = ele.id.replace('button-template-', '');

    updateTabVisibility()
}

const rowTemplate = $('#row-template');

function refreshPokemonList(log, targetEle, targetsLength) {
    const entries = log.length;

    targetEle.empty();

    for (var i = entries; i >= entries - targetsLength; i --) {
        let mon = log[i]
        
        if (!mon) continue;

        mon = enrichFurther(mon);

        const row = rowTemplate.tmpl(mon);

        if (mon.shiny == true || mon.shinyValue < 8) {
            row.attr('id', 'shiny');
        }

        targetEle.append(row)
    }
}

function enrichFurther(mon) {
    mon = mon || {};
    // Fix filenames for display. Be defensive because cached/server snapshots can be partial if Lua disconnects quickly.
    const gender = (mon.gender || 'Genderless').toString().toLowerCase();
    mon.gender = gender == 'genderless' ? 'none' : gender;
    const shinyValue = Number(mon.shinyValue);
    mon.shinyValue = Number.isFinite(shinyValue) ? shinyValue : 65535;
    mon.shiny = (mon.shinyValue < 8 || mon.shiny === true ? '✨ ' : '➖ ');
    mon.species = (mon.species === undefined || mon.species === null ? '000' : mon.species.toString().padStart(3, '0'));

    if (mon.altForm > 0) {
        mon.species = mon.species + '-' + mon.altForm.toString()
    }

    if (mon.isEgg) {
        mon.species = 'egg';
        mon.folder = '';
        
        if (mon.name == 'Manaphy') {
            mon.species = 'manaphy-egg';
            mon.nickname = 'Manaphy Egg';
        }
    }

    // Display raised/lowered stat modifiers in colour
    mon.attackMod    = ['Lonely', 'Adamant', 'Naughty', 'Brave'].includes(mon.nature) ? 'up' : ['Bold', 'Modest', 'Calm', 'Timid'].includes(mon.nature) ? ' down' : '';
    mon.defenseMod   = ['Bold', 'Impish', 'Lax', 'Relaxed'].includes(mon.nature) ? 'up'      : ['Lonely', 'Mild', 'Gentle', 'Hasty'].includes(mon.nature) ? ' down' : '';
    mon.spAttackMod  = ['Modest', 'Mild', 'Rash', 'Quiet'].includes(mon.nature) ? 'up'       : ['Adamant', 'Impish', 'Careful', 'Jolly'].includes(mon.nature) ? ' down' : '';
    mon.spDefenseMod = ['Calm', 'Gentle', 'Careful', 'Sassy',].includes(mon.nature) ? 'up'   : ['Naughty', 'Lax', 'Rash', 'Naive'].includes(mon.nature) ? ' down' : '';
    mon.speedMod     = ['Timid', 'Hasty', 'Jolly', 'Naive',].includes(mon.nature) ? 'up'     : ['Brave', 'Relaxed', 'Quiet', 'Sassy'].includes(mon.nature) ? ' down' : '';

    return mon;
}

const recentsEle = $('#recents');
const recentsLimit = $('#recents-limit');

function updateRecentlySeen(force = false) {
    socketServerGet('recents', function (error, encounters) {
        if (error) {
            console.error(error);
            return;
        }

        if (encounters.length == 0) return;

        const updated = !recentEncounters || recentEncounters.slice(-1)[0].pid != encounters.slice(-1)[0].pid
        recentEncounters = encounters;

        if (updated || force) {
            refreshPokemonList(
                encounters,
                recentsEle,
                recentsLimit.val() || 7
            )
        }

        let uniquePIDS = [];
        recentEncounters.forEach(mon => {
            if (!uniquePIDS.includes(mon.pid)) {
                uniquePIDS.push(mon.pid);
            }
        });
        
        if (uniquePIDS.length < recentEncounters.length) {
            $('#warn-duplicate').css('visibility', 'visible')
        } else {
            $('#warn-duplicate').css('visibility', 'hidden')
        }
    });
}

const targetsEle = $('#targets');
const targetsLimit = $('#targets-limit');

function updateRecentTargets(force = false) {
    socketServerGet('targets', function (error, encounters) {
        if (error) {
            console.error(error);
            return;
        }

        if (encounters.length == 0) return;

        const updated = !recentTargets || recentTargets.slice(-1)[0].pid != encounters.slice(-1)[0].pid
        recentTargets = encounters;
        
        if (updated || force) {
            refreshPokemonList(
                encounters,
                targetsEle,
                targetsLimit.val() || 7
            )
        }
    });
}

let statsHash;

function updateStats() {
    const hashObject = function(obj) {
        const jsonString = JSON.stringify(obj);
        
        if (!jsonString) return null
        
        var hash = 0;
        for (var i = 0; i < jsonString.length; i++) {
            var code = jsonString.charCodeAt(i);
            hash = ((hash << 5) - hash) + code;
            hash = hash & hash;
        }
        
        return hash;
    }

    socketServerGet('stats', function (error, stats) {
        if (error) {
            console.error(error);
            return;
        }

        const hash = hashObject(stats);
        if (statsHash == hash) return;

        statsHash = hash;

        document.getElementById('total-seen').innerHTML      = stats.total.seen;
        document.getElementById('total-shiny').innerHTML     = stats.total.shiny;
        document.getElementById('total-max-iv').innerHTML    = stats.total.max_iv_sum;
        document.getElementById('total-min-iv').innerHTML    = stats.total.min_iv_sum;

        document.getElementById('phase-seen').innerHTML      = stats.phase.seen;
        document.getElementById('phase-lowest-sv').innerHTML = stats.phase.lowest_sv;

        updateBnp();
    });
};

function setClients() {
    socketServerGet('clients', function (error, clients) {
        if (error) {
            console.error(error);
            return;
        }

        gameCount = clients.length;
        lastLiveClientCount = gameCount;

        setBadgeClientCount(gameCount);
        updateClientTabs(clients);

        // Refresh displays. Do not blank the cached party when short Lua scripts disconnect.
        const cachedBeforeClear = getCachedGameSnapshot();
        if (gameCount < gameContainer.children().length && !(gameCount === 0 && cachedBeforeClear)) gameContainer.empty();
        if (gameCount < partyContainer.children().length && !(gameCount === 0 && cachedBeforeClear)) partyContainer.empty();

        if (gameCount == 0) {
            clearInterval(elapsedInterval);
            elapsedStart = null;

            $('#elapsed-time').text('0s');
            $('#encounter-rate').text('0/h');
            displayBestAvailablePartySnapshot(function (ok) {
                if (ok) {
                    renderLastKnownPartyFallback(getCachedGameSnapshot());
                    updateClientTabs([]);
                    updateTabVisibility();
                    renderLastKnownPartyFallback(getCachedGameSnapshot());
                }
            });
            updateTabVisibility();
            return;
        }

        for (var i = 0; i < gameCount; i++) {
            const client = clients[i];

            if (!client || !client.version || !client.trainer_name) continue; // Client still hasn't sent important values

            savePartySnapshot(client, i);
            const cached = getCachedGameSnapshot();
            const party = Array.isArray(client.party) && client.party.length ? client.party : (cached && cached.trainer_name === client.trainer_name ? cached.party : client.party);
            displayClientParty(i, party);        
            displayClientGameInfo(i, client);
        }

        updateTabVisibility()

        // Start elapsed timer if a game is connected
        if (!elapsedStart) {
            socketServerGet('elapsed_start', function (error, start) {
                if (error) {
                    console.error(error);
                    return;
                }

                elapsedStart = start;
                elapsedInterval = setInterval(updateStatBadges, 1000);

                updateStatBadges();
            });
        }
    })
};


let luaLogLatestText = '';
let luaLogPreviousText = '';
let luaFullLogText = '';
let luaPreviewText = '';
let luaDisplayedLogText = '';
let luaModalDisplayedText = '';
let luaDisplayedLogFilename = 'pokebot-lua-latest.log';
let luaLogHash = null;
let luaLogMeta = { source: 'latest.log', mode: 'User Log', build: 'v40.0', session: 'Waiting' };
let fullLogSource = 'full';
let fullLogSearch = '';
let fullLogAutoScroll = true;
let fullLogWrap = false;
let navStorageHealth = null;


const DASH_TASK_COPY = {
    manual: { title: 'Log only', objective: 'Keep Lua connected without running automation.', next: 'Choose a task in Config when you are ready to run the bot.', type: 'Idle' },
    map_explore_area: { title: 'Navigation: Learn Current Area', objective: 'Learn nearby tiles, avoid repeated wall rubbing, handle encounters safely, and save normalized map data.', next: 'Load Lua, stand in a safe test area, then start with 3–10 explore actions.', type: 'Navigation' },
    map_cleanup_current_tile: { title: 'Navigation: Fix Current Tile Data', objective: 'Remove bad blocked/battle observations near the current tile and rebuild the map cache.', next: 'Confirm the cleanup scope in Navigation / Map Tools before running.', type: 'Repair' },
    map_graph_to: { title: 'Navigation: Travel to Coordinate', objective: 'Use the compact graph to move to a learned coordinate.', next: 'Check target map/X/Z under Navigation / Map Tools.', type: 'Travel' },
    nav_storage_status: { title: 'Navigation: Storage Status', objective: 'Print source-of-truth backend, storage health, table counts, duplicates, warnings, and backup helper status without moving.', next: 'Run this after installing a patch or validating map data.', type: 'Status' },
    random_encounters: { title: 'Random Encounters', objective: 'Run the classic encounter loop using target, battle, and auto-catch rules.', next: 'Review Target Pokémon, Battle Behavior, and Auto-Catch Rules.', type: 'Hunting' },
    random_encounters_small: { title: 'Random Encounters (Small)', objective: 'Run a smaller random-encounter loop variant.', next: 'Review movement direction and target rules.', type: 'Hunting' },
    daycare_eggs: { title: 'Egg Hatching', objective: 'Run egg hatching behavior using target and save settings.', next: 'Confirm target rules and save behavior before long runs.', type: 'Hunting' },
    fishing: { title: 'Fishing', objective: 'Run fishing encounters with target and catch rules.', next: 'Confirm battle and auto-catch settings.', type: 'Hunting' },
    starters: { title: 'Starters', objective: 'Soft reset for selected starter targets.', next: 'Choose starter targets in Task Selection.', type: 'Soft Reset' },
    gift: { title: 'Gifts', objective: 'Soft reset gift Pokémon.', next: 'Confirm target rules and save behavior.', type: 'Soft Reset' },
    static_encounters: { title: 'Static Encounters', objective: 'Soft reset static encounters.', next: 'Confirm target rules and battle behavior.', type: 'Soft Reset' }
};

const DASH_TASK_SHORT = {
    map_explore_area: ['Learn Current Area', 'Navigation'],
    map_cleanup_current_tile: ['Fix Current Tile Data', 'Navigation'],
    map_graph_to: ['Travel to Coordinate', 'Navigation'],
    nav_storage_status: ['Storage Status', 'Navigation'],
    map_graph_build: ['Rebuild Map Cache', 'Navigation'],
    random_encounters: ['Random Encounters', 'Hunting'],
    random_encounters_small: ['Random Encounters Small', 'Hunting'],
    daycare_eggs: ['Egg Hatching', 'Hunting'],
    fishing: ['Fishing', 'Hunting'],
    starters: ['Starters', 'Soft Reset'],
    gift: ['Gifts', 'Soft Reset'],
    static_encounters: ['Static Encounters', 'Soft Reset'],
    manual: ['Log only', 'Idle']
};

function prettyTaskName(mode) {
    const known = DASH_TASK_COPY[mode];
    if (known) return known.title;
    return (mode || 'Not loaded').replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
}

function renderChecklist(validClients, config) {
    const list = document.getElementById('mission-checklist');
    if (!list) return;
    const taskReady = !!(config && config.mode);
    const items = [
        ['Dashboard server running', true],
        ['Lua script loaded', validClients.length > 0],
        ['Game data received', validClients.some(c => c && c.version && c.trainer_name)],
        ['Task configuration ready', taskReady]
    ];
    list.innerHTML = items.map(([label, ok]) => `<div class="${ok ? 'ready' : 'pending'}"><i class="fa ${ok ? 'fa-check-circle' : 'fa-circle'}"></i><span>${label}</span></div>`).join('');
}

function renderTargetSummary(config) {
    const ele = document.getElementById('target-summary-list');
    if (!ele || !config) return;
    const traits = config.target_traits || {};
    let targetText = 'No specific target rules loaded';
    if (traits && typeof traits === 'object') {
        const keys = Object.keys(traits);
        if (keys.length) targetText = keys.map(k => `${k}: ${Array.isArray(traits[k]) ? traits[k].join(', ') : traits[k]}`).join(' · ');
    }
    ele.innerHTML = `
        <div><span>Targets</span><strong>${targetText}</strong></div>
        <div><span>Shiny safety</span><strong>${config.always_catch_shinies ? 'Protect shinies' : 'Standard target rules'}</strong></div>
        <div><span>Auto-catch</span><strong>${config.auto_catch ? 'Enabled for targets' : 'Disabled'}</strong></div>
        <div><span>Battle policy</span><strong>${config.battle_non_targets ? 'Defeat non-targets' : 'Flee non-targets'}</strong></div>`;
}


function isNavigationTask(mode) {
    return /^map_|^route_|^nav_/.test(mode || '');
}

function renderStorageSummary(status) {
    navStorageHealth = status || null;
    const storage = document.getElementById('map-status-storage');
    if (!storage) return;

    if (!status) {
        storage.textContent = 'Unknown';
        storage.title = 'Storage health endpoint did not return data.';
        return;
    }

    const counts = status.counts || {};
    const nodeCount = counts.nodes || 0;
    const edgeCount = counts.edges || 0;
    const obsCount = counts.observations || 0;
    const health = status.health || 'unknown';
    let label = 'Checking…';

    if (health === 'ready') label = `Ready · ${nodeCount} nodes / ${obsCount} obs`;
    else if (health === 'initialized_empty') label = 'Initialized · no records yet';
    else if (health === 'needs_review') label = `Needs review · ${nodeCount} nodes`;
    else if (health === 'missing') label = 'Not initialized yet';
    else label = `${health.replace(/_/g, ' ')} · ${nodeCount} nodes`;

    storage.textContent = label;
    storage.title = [
        `Backend: ${status.backend || 'unknown'}`,
        `Source of truth: ${status.source_of_truth || 'unknown'}`,
        `Game: ${status.game_id || 'none yet'}`,
        `Edges: ${edgeCount}`,
        `Blocked: ${counts.blocked || 0}`,
        `Transitions: ${counts.transitions || 0}`,
        `Warnings: ${(status.warnings || []).length}`
    ].join('\n');
}


function renderCoverageSummary(report) {
    const ele = document.getElementById('map-status-coverage');
    if (!ele) return;

    if (!report || !report.coverage) {
        ele.textContent = 'Not checked';
        ele.title = 'Map coverage endpoint did not return data.';
        return;
    }

    const c = report.coverage || {};
    const pct = c.coverage_percent !== undefined ? c.coverage_percent : 0;
    const frontiers = c.frontier_nodes || 0;
    const unscanned = c.unscanned_directions || 0;
    const holes = c.possible_holes || 0;

    if ((c.nodes || 0) === 0) {
        ele.textContent = 'No map data yet';
    } else {
        ele.textContent = `${pct}% · ${frontiers} frontier${frontiers === 1 ? '' : 's'}`;
    }

    ele.title = [
        `Known nodes: ${c.nodes || 0}`,
        `Scanned directions: ${c.scanned_directions || 0}`,
        `Unscanned directions: ${unscanned}`,
        `Frontier nodes: ${frontiers}`,
        `Possible holes: ${holes}`,
        `Dead-end candidates: ${c.dead_end_candidates || 0}`,
        'Open /api/nav_coverage for the developer coverage/frontier report.'
    ].join('\n');
}

function taskNeedsLua(mode) {
    return !!mode && mode !== 'manual';
}

function renderAttention(validClients, config, storageStatus) {
    const ele = document.getElementById('attention-list');
    if (!ele) return;
    const items = [];
    const mode = config && config.mode ? config.mode : 'manual';
    const luaMissingBlocksTask = validClients.length === 0 && taskNeedsLua(mode);

    if (luaMissingBlocksTask) {
        const taskTitle = prettyTaskName(mode);
        items.push(['warning', `${taskTitle} cannot start until Lua is connected. Load pokebot-nds.lua in DeSmuME, then run or monitor the task.`]);
    }

    if (config && isNavigationTask(config.mode) && config.battle_non_targets) {
        items.push(['warning', 'Mapping is set to defeat non-targets. Safe mapping usually expects fleeing.']);
    }

    if (config && isNavigationTask(mode) && !luaMissingBlocksTask && storageStatus && ['missing', 'missing_files'].includes(storageStatus.health)) {
        items.push(['warning', `${prettyTaskName(mode)} needs navigation storage initialized. Run Navigation: Storage Status or Learn Current Area after Lua connects.`]);
    }

    if (config && isNavigationTask(mode) && !luaMissingBlocksTask && storageStatus && storageStatus.health === 'needs_review') {
        items.push(['warning', 'Navigation storage has duplicate or suspicious records. Run Storage Status and review before large mapping sessions.']);
    }

    const targetTask = /random_encounters|daycare_eggs|fishing|headbutt|starters|gift|static_encounters/.test(mode);
    const traits = config && config.target_traits && typeof config.target_traits === 'object' ? Object.keys(config.target_traits) : [];
    if (targetTask && traits.length === 0 && mode !== 'manual') {
        items.push(['warning', `${prettyTaskName(mode)} has no target rules configured. Review Target Pokémon before hunting a specific target.`]);
    }

    if (!items.length) items.push(['ok', 'No action needed right now.']);
    ele.innerHTML = items.map(([kind, text]) => `<div class="${kind}">${text}</div>`).join('');
}

function renderActivityTimeline(displayText) {
    const ele = document.getElementById('activity-timeline');
    const section = document.getElementById('activity-section');
    if (!ele) return;
    const raw = (displayText || '').split(/\r?\n/).filter(Boolean);
    const interesting = raw.filter(line => /Bot mode set|Map Explore Area action|selected frontier|probe result|battle|Got away|target|ERROR|WARN|##### BOT TASK ENDED/i.test(line)).slice(-8);
    if (!interesting.length) {
        ele.innerHTML = '<div class="muted">Waiting for runtime activity…</div>';
        if (section) section.classList.add('is-empty');
        return;
    }
    if (section) section.classList.remove('is-empty');
    ele.innerHTML = interesting.map(line => {
        const clean = line.replace(/^\[[^\]]+\]\s*\[[^\]]+\]\s*\[[^\]]+\]\s*/, '').replace(/@ [^-]+ - /, '');
        return `<div><span></span><p>${clean}</p></div>`;
    }).join('');
}

function downloadTextFile(filename, text) {
    const blob = new Blob([text || ''], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}




function ensureNavIntelligencePanel() {
    let panel = document.getElementById('nav-intelligence-panel');
    if (panel) return panel;
    const setup = document.querySelector('.pb50-setup-panel');
    if (!setup || !setup.parentNode) return null;
    panel = document.createElement('article');
    panel.className = 'pb50-panel pb50-nav-intel-panel';
    panel.id = 'nav-intelligence-panel';
    panel.innerHTML = `<header class="pb50-panel-head"><div><span class="pb-eyebrow">Scan Lens</span><h2>Map intelligence</h2></div><a class="pb50-link" href="/api/nav_scan_lens_ui" target="_blank">Open JSON</a></header>
        <div id="nav-intel-body" class="pb50-summary-list"><div><span>Status</span><strong>Loading scan lens…</strong></div></div>`;
    setup.parentNode.insertBefore(panel, setup.nextSibling);
    return panel;
}

function renderNavIntelligencePanel() {
    const panel = ensureNavIntelligencePanel();
    if (!panel) return;
    const body = document.getElementById('nav-intel-body');
    if (!body) return;
    socketServerGet('nav_scan_lens_ui', function (lensError, lens) {
        socketServerGet('nav_tile_capabilities', function (capError, caps) {
            if (lensError || !lens || !lens.summary) {
                body.innerHTML = `<div><span>Status</span><strong>Scan lens unavailable</strong></div>`;
                return;
            }
            const s = lens.summary || {};
            const work = (lens.work_items || []).slice(0, 5);
            const capSummary = caps && caps.summary ? caps.summary : {};
            const workHtml = work.length ? work.map(item => `<li><strong>${pbEscape(item.map_name || 'Map')} X ${pbEscape(item.tile_x)} Z ${pbEscape(item.tile_z)}</strong> — ${pbEscape(item.action_hint || '')}</li>`).join('') : '<li>No scan-lens work items returned.</li>';
            body.innerHTML = `
                <div><span>Coverage</span><strong>${pbEscape(s.effective_coverage_percent || 0)}% effective</strong></div>
                <div><span>Scanned</span><strong>${pbEscape(s.explicit_scanned || 0)} explicit / ${pbEscape(s.effective_scanned || 0)} effective</strong></div>
                <div><span>Still unknown</span><strong>${pbEscape(s.unscanned || 0)} dirs · ${pbEscape(s.true_frontier_directions || 0)} frontiers · ${pbEscape(s.possible_holes || 0)} holes</strong></div>
                <div><span>Tile codes</span><strong>${pbEscape(capSummary.unique_behavior_codes || 0)} codes · ${pbEscape(capSummary.unmapped_codes || 0)} unmapped</strong></div>
                <div style="grid-column:1/-1;"><span>Nearest useful scan work</span><ol style="margin:6px 0 0 18px;">${workHtml}</ol></div>`;
        });
    });
}

function setText(id, value) {
    const ele = document.getElementById(id);
    if (ele) ele.textContent = value;
}

function renderHomeSummary() {
    let loadedVersion = null;
    socketServerGet('version', function (error, version) {
        if (!error && version) {
            loadedVersion = version;
            setText('home-build', version.build || 'unknown');
            setText('home-build-name', version.name || '');
        }
    });

    socketServerGet('config', function (configError, config) {
        if (!configError && config) {
            const mode = config.mode || 'manual';
            const task = DASH_TASK_COPY[mode] || { title: prettyTaskName(mode), objective: 'Task-specific automation selected.', next: 'Review the related configuration categories before running.', type: 'Task' };
            const shortTask = DASH_TASK_SHORT[mode] || [task.title, task.type || 'Task'];
            setText('home-task', shortTask[0]);
            setText('home-task-detail', shortTask[1]);
            const taskEle = document.getElementById('home-task');
            if (taskEle) taskEle.title = task.title;
            setText('home-debug-mode', config.debug ? 'Developer log mode' : 'Clean user log');
            setText('mission-task-title', task.title);
            setText('mission-objective', task.objective);
            setText('mission-next-step', task.next);
            const state = document.getElementById('mission-state');
            if (state) state.textContent = task.type || 'Ready';
            renderTargetSummary(config);
        }

        socketServerGet('clients', function (error, clients) {
            if (error || !clients) return;
            const valid = clients.filter(c => c && c.version && c.trainer_name);
            const cachedSnapshot = getCachedGameSnapshot();
            const cachedClient = !valid.length && cachedSnapshot ? cachedSnapshotAsClient(cachedSnapshot) : null;
            setText('home-connection', valid.length ? 'Connected' : (cachedClient ? 'Waiting for Lua' : 'Waiting for Lua'));
            setText('home-client-count', valid.length ? `${valid.length} client${valid.length === 1 ? '' : 's'} connected` : (cachedClient ? '0 clients connected · showing last party' : '0 clients connected'));

            const empty = document.getElementById('connection-empty-state');
            const livePanel = document.getElementById('game-panel');
            const hasPartyDisplay = valid.length > 0 || !!cachedClient;
            if (empty) empty.style.display = hasPartyDisplay ? 'none' : 'grid';
            if (livePanel) {
                livePanel.classList.toggle('is-connected', valid.length > 0);
                livePanel.classList.toggle('is-cached-party', !valid.length && !!cachedClient);
            }

            const client = valid[gameTab] || valid[0] || cachedClient;
            if (client) {
                const area = client.map_name || client.shownValues && (client.shownValues['Map'] || client.shownValues['Area']) || 'Connected';
                const pos = client.position || {};
                const x = pos.x !== undefined ? pos.x : (client.x !== undefined ? client.x : '?');
                const y = pos.y !== undefined ? pos.y : (client.y !== undefined ? client.y : '?');
                const z = pos.z !== undefined ? pos.z : (client.z !== undefined ? client.z : '?');
                setText('home-area', area);
                setText('home-position', `Tile ${x}, ${y}, ${z}`);
                setText('map-status-area', area);
                setText('map-status-position', `Tile ${x}, ${y}, ${z}`);
            } else {
                setText('home-area', 'Unknown');
                setText('home-position', 'Load pokebot-nds.lua');
                setText('map-status-area', 'Unknown');
                setText('map-status-position', 'No tile data');
            }
            renderChecklist(valid, config || {});
            socketServerGet('nav_storage', function (storageError, storageStatus) {
                if (!storageError && storageStatus) {
                    renderStorageSummary(storageStatus);
                    renderAttention(valid, config || {}, storageStatus);
                } else {
                    renderStorageSummary(null);
                    renderAttention(valid, config || {}, null);
                }
            });
            socketServerGet('nav_coverage', function (coverageError, coverageStatus) {
                renderCoverageSummary(!coverageError ? coverageStatus : null);
            });
        });
    });
}

function renderDashboardVersion() {
    socketServerGet('version', function (error, version) {
        if (error || !version) return;
        const badge = document.getElementById('lua-build-version');
        if (badge) {
            badge.textContent = `Build ${version.build || 'unknown'}`;
            badge.title = `${version.build || ''} ${version.name || ''}`.trim();
        }
        if (version.build) {
            document.title = `PokéBot NDS — ${version.build}`;
        }
    });
}

function getLogTextForSource(source) {
    if (source === 'latest') return luaLogLatestText || '';
    if (source === 'previous') return luaLogPreviousText || '';
    return luaFullLogText || luaLogLatestText || '';
}

function deriveLogSession(text) {
    const match = String(text || '').match(/# Session[^:]*:\s*([^\r\n]+)/i);
    return match ? match[1].trim() : 'Current dashboard session';
}

function applyFullLogFilter(text) {
    const raw = String(text || '');
    const query = String(fullLogSearch || '').trim().toLowerCase();
    if (!query) return { text: raw, total: raw ? raw.split(/\r?\n/).length : 0, shown: raw ? raw.split(/\r?\n/).length : 0, filtered: false };
    const lines = raw.split(/\r?\n/);
    const shownLines = lines.filter(line => line.toLowerCase().includes(query));
    return { text: shownLines.join('\n'), total: lines.length, shown: shownLines.length, filtered: true };
}

function updateFullLogView() {
    const output = document.getElementById('full-log-output');
    const sourceSelect = document.getElementById('full-log-source');
    if (sourceSelect && sourceSelect.value !== fullLogSource) sourceSelect.value = fullLogSource;

    const sourceText = getLogTextForSource(fullLogSource);
    const filtered = applyFullLogFilter(sourceText);
    luaModalDisplayedText = filtered.text || '';

    if (output) {
        output.textContent = luaModalDisplayedText || 'Waiting for Lua log messages...';
        output.classList.toggle('wrap', fullLogWrap);
        if (fullLogAutoScroll) output.scrollTop = output.scrollHeight;
    }

    const sourceLabel = document.getElementById('full-log-source-label');
    if (sourceLabel) sourceLabel.textContent = fullLogSource === 'previous' ? 'previous.log' : fullLogSource === 'latest' ? 'latest.log' : 'full displayed log';
    const modeLabel = document.getElementById('full-log-mode-label');
    if (modeLabel) modeLabel.textContent = luaLogMeta.mode;
    const buildLabel = document.getElementById('full-log-build-label');
    if (buildLabel) buildLabel.textContent = luaLogMeta.build;
    const sessionLabel = document.getElementById('full-log-session-label');
    if (sessionLabel) sessionLabel.textContent = luaLogMeta.session;

    const lineCount = document.getElementById('full-log-line-count');
    if (lineCount) lineCount.textContent = filtered.filtered ? `${filtered.shown} of ${filtered.total} lines shown` : `${filtered.total} lines`;
    const filterState = document.getElementById('full-log-filter-state');
    if (filterState) filterState.textContent = filtered.filtered ? `Filter: ${fullLogSearch}` : 'No filter';

    const wrapButton = document.getElementById('toggle-wrap-log');
    if (wrapButton) wrapButton.textContent = fullLogWrap ? 'Wrap: On' : 'Wrap: Off';
    const autoButton = document.getElementById('toggle-autoscroll-log');
    if (autoButton) autoButton.textContent = fullLogAutoScroll ? 'Auto-scroll: On' : 'Auto-scroll: Off';
}

function renderLuaLogs() {
    socketServerGet('lua_logs', function (error, data) {
        if (error) {
            console.error(error);
            return;
        }

        data = data || {};
        const latest = data.latest_text || '';
        const display = data.display_text || data.full_text || latest;
        const build = data.build || {};
        const developerMode = data.developer_mode === true;
        const hash = (build.build || '') + ':' + display.length.toString() + ':' + latest.length.toString() + ':' + (data.previous_text || '').length.toString() + ':' + (data.all_entry_count || data.entry_count || 0).toString() + ':' + (developerMode ? 'dev' : 'user') + ':' + fullLogSource + ':' + fullLogSearch + ':' + (fullLogWrap ? 'wrap' : 'nowrap');

        luaLogLatestText = latest;
        luaLogPreviousText = data.previous_text || '';
        luaFullLogText = display;
        luaDisplayedLogText = display;
        luaDisplayedLogFilename = developerMode ? 'pokebot-lua-full-developer.log' : 'pokebot-lua-latest.log';
        luaLogMeta = {
            source: developerMode ? 'full displayed log' : 'latest.log',
            mode: developerMode ? 'Developer Full Log' : 'User Log',
            build: build.build || 'unknown',
            session: deriveLogSession(display || latest)
        };

        if (luaLogHash === hash) return;
        luaLogHash = hash;

        const output = document.getElementById('lua-log-output');
        renderActivityTimeline(display);

        if (output) {
            const lines = display.trim().split(/\r?\n/).filter(Boolean);
            const visible = lines.slice(-28).join('\n');
            luaPreviewText = visible || '';
            output.textContent = luaPreviewText || 'Waiting for Lua log messages...';
            output.scrollTop = output.scrollHeight;
        }

        updateFullLogView();

        const fullSubtitle = document.getElementById('full-log-subtitle');
        if (fullSubtitle) {
            fullSubtitle.textContent = developerMode
                ? 'Developer Mode is enabled. Filter, copy, download, or clear the full runtime log from here.'
                : 'Normal user log view. Enable Developer Mode in Config to include debug-only and [PERF] timing lines.';
        }

        const modeBadge = document.getElementById('lua-log-mode');
        if (modeBadge) {
            modeBadge.textContent = developerMode ? 'Developer' : 'User';
            modeBadge.className = developerMode ? 'badge badge-warning' : 'badge text-bg-secondary';
        }

        const modeHelp = document.getElementById('lua-log-mode-help');
        if (modeHelp) {
            modeHelp.textContent = developerMode ? 'Developer preview. Open the full log for filters and tools.' : 'Clean preview. Open the full log for filters and tools.';
        }

        const count = document.getElementById('lua-log-count');
        if (count) {
            if (developerMode) {
                const devCount = data.developer_entry_count ? ` · ${data.developer_entry_count} debug/PERF` : '';
                count.textContent = `${data.all_entry_count || 0} lines${devCount}`;
            } else {
                count.textContent = `${data.entry_count || 0} lines`;
            }
        }

        const buildBadge = document.getElementById('lua-build-version');
        if (buildBadge) {
            buildBadge.textContent = `Build ${build.build || 'unknown'}`;
            if (build.name) buildBadge.title = build.name;
        }

        const retention = document.getElementById('lua-log-retention');
        if (retention) retention.textContent = data.retention || 'latest + previous only';

        const path = document.getElementById('lua-log-path');
        if (path) path.textContent = developerMode ? 'dashboard full runtime view' : (data.latest_path || 'user\\logs\\latest.log');
    });
}

function clearLuaLogAndRefresh() {
    socketServerSend('clear_lua_logs', {}, function (error) {
        if (error) {
            console.error(error);
            return;
        }
        luaLogHash = null;
        renderLuaLogs();
    });
}

function setupLuaLogButtons() {
    const copyButton = document.getElementById('copy-lua-log');
    if (copyButton) {
        copyButton.addEventListener('click', () => {
            navigator.clipboard.writeText(luaPreviewText || luaDisplayedLogText || luaLogLatestText || '').then(() => {
                halfmoon.initStickyAlert({
                    content: 'Copied visible log preview to clipboard.',
                    title: 'Log copied',
                    alertType: 'alert-success',
                    timeShown: 3000
                });
            }).catch(() => {
                const output = document.getElementById('lua-log-output');
                if (output) {
                    output.focus();
                    document.execCommand('selectAll');
                }
            });
        });
    }

    const downloadButton = document.getElementById('download-lua-log');
    if (downloadButton) {
        downloadButton.addEventListener('click', () => downloadTextFile(luaDisplayedLogFilename || 'pokebot-lua-latest.log', luaDisplayedLogText || luaLogLatestText));
    }

    const previousButton = document.getElementById('download-previous-lua-log');
    if (previousButton) {
        previousButton.addEventListener('click', () => downloadTextFile('pokebot-lua-previous.log', luaLogPreviousText));
    }

    const clearButton = document.getElementById('clear-lua-log');
    if (clearButton) clearButton.addEventListener('click', clearLuaLogAndRefresh);
}

function updatePage() {
    updateStats()
    setClients()
    updateRecentTargets()
    updateRecentlySeen()
    renderDashboardVersion()
    renderLuaLogs()
    renderHomeSummary()
}

const recentEncountersEle = document.getElementById('recents-limit');
recentEncountersEle.addEventListener('change', () => {
    updateRecentlySeen(true)
})

const recentTargetsEle = document.getElementById('targets-limit');
recentTargetsEle.addEventListener('change', () => {
    updateRecentTargets(true)
})

const rateEle = document.getElementById('shiny-rate');
rateEle.addEventListener('change', () => {
    updateBnp()
})


function setupFullLogDrawer() {
    const drawer = document.getElementById('log-drawer');
    const openers = [document.getElementById('open-full-log'), document.getElementById('open-full-log-secondary')].filter(Boolean);
    const close = document.getElementById('close-full-log');
    const copy = document.getElementById('copy-full-log');
    const download = document.getElementById('download-full-log');
    const wrap = document.getElementById('toggle-wrap-log');
    const auto = document.getElementById('toggle-autoscroll-log');
    const clear = document.getElementById('clear-full-log');
    const source = document.getElementById('full-log-source');
    const search = document.getElementById('full-log-search');

    openers.forEach(btn => btn.addEventListener('click', () => {
        if (drawer) {
            drawer.classList.add('open');
            drawer.setAttribute('aria-hidden', 'false');
            updateFullLogView();
            if (search) search.focus();
        }
    }));
    if (close) close.addEventListener('click', () => {
        if (drawer) {
            drawer.classList.remove('open');
            drawer.setAttribute('aria-hidden', 'true');
        }
    });
    if (drawer) drawer.addEventListener('click', (event) => {
        if (event.target === drawer) {
            drawer.classList.remove('open');
            drawer.setAttribute('aria-hidden', 'true');
        }
    });
    if (source) source.addEventListener('change', () => {
        fullLogSource = source.value || 'full';
        updateFullLogView();
    });
    if (search) search.addEventListener('input', () => {
        fullLogSearch = search.value || '';
        updateFullLogView();
    });
    if (copy) copy.addEventListener('click', () => navigator.clipboard.writeText(luaModalDisplayedText || '').then(() => {
        halfmoon.initStickyAlert({ content: 'Copied displayed log view.', title: 'Log copied', alertType: 'alert-success', timeShown: 2500 });
    }));
    if (download) download.addEventListener('click', () => {
        const suffix = fullLogSource === 'previous' ? 'previous' : fullLogSource === 'latest' ? 'latest' : 'displayed';
        downloadTextFile(`pokebot-lua-${suffix}.log`, luaModalDisplayedText || getLogTextForSource(fullLogSource));
    });
    if (wrap) wrap.addEventListener('click', () => {
        fullLogWrap = !fullLogWrap;
        updateFullLogView();
    });
    if (auto) auto.addEventListener('click', () => {
        fullLogAutoScroll = !fullLogAutoScroll;
        updateFullLogView();
    });
    if (clear) clear.addEventListener('click', () => {
        if (confirm('Clear the current Lua log view? latest.log will be reset by the dashboard.')) {
            clearLuaLogAndRefresh();
        }
    });
    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && drawer && drawer.classList.contains('open')) {
            drawer.classList.remove('open');
            drawer.setAttribute('aria-hidden', 'true');
        }
    });
}

setupLuaLogButtons();
setupFullLogDrawer();

setInterval(function () {
    // Low-cost refresh: keeps the last known party/live-game card available while Lua is idle.
    if (lastLiveClientCount === 0) keepPartySnapshotWarm();
}, 2500);

setInterval(function () {
    renderNavIntelligencePanel();
}, 5000);
renderNavIntelligencePanel();


// Prime the idle party cache as soon as the dashboard opens.
displayBestAvailablePartySnapshot(function () {
    updateClientTabs([]);
    updateTabVisibility();
});

socketServerGet('config', function (error, config) {
    if (error) {
        console.error(error);
        return;
    }
    
    updatePage();
    
    setInterval(() => {
        updatePage();
    }, 1000);
})