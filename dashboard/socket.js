const net = require('net');
const fs = require('fs');
const { AttachmentBuilder, EmbedBuilder, WebhookClient, ButtonBuilder, ButtonStyle } = require('discord.js');
const navStore = require('./nav_store');
const logStore = require('./log_store');
const port = 51055;

var clients = [];
var clientData = [];

var elapsedStart;

var lastEncounter;
var sinceLastEncounter;

const clientInactivityTimeout = 180000; // Prevent excessive pile-up of ended sessions, remove them after 3 minutes
const rateHistorySample = 20;
var rateHistory = [];
var encounterRate = 0;

// === FILE SETUP ===
// Default config
const configTemplate = {
    mode: "random_encounters",
    starter0: true,
    starter1: true,
    starter2: true,
    move_direction: "horizontal",
    route_name: "goldenrod_test",
    route_start: "goldenrod_pc",
    route_destination: "route34_grass",
    route_reverse: false,
    route_compress: true,
    map_node_name: "route34_grass",
    map_destination: "route34_grass",
    map_probe_direction: "Up",
    map_probe_benchmark_test: "move_only_abort",
    map_explore_area_actions: "5",
    map_explore_strategy: "coverage_planner",
    map_explore_battle_policy: "original_encounter_flow",
    map_explore_continue_after_battle: true,
    map_explore_flee_timeout_frames: "1800",
    nav_storage_enabled: true,
    nav_cleanup_direction: "All",
    nav_cleanup_scope: "blocked",
    nav_cleanup_radius_tiles: "0",
    nav_cleanup_rebuild_graph: true,
    target_traits: {
        ivSum: 180
    },
    pokeball_override: {
        'Repeat Ball': {
            name: [
                "Lillipup",
                "Bidoof",
                "Sentret"
            ]
        },
        'Net Ball': {
            type: [
                "Bug",
                "Water"
            ]
        }
    },
    thief_wild_items: false,
    pickup: false,
    pokeball_priority: [
        "Premier Ball",
        "Ultra Ball",
        "Great Ball",
        "Poke Ball"
    ],
    save_game_after_catch: false,
    pickup_threshold: "2",
    cycle_lead_pokemon: true,
    encounter_log_limit: "30",
    battle_non_targets: false,
    auto_catch: false,
    target_log_limit: "30",
    subdue_target: false,
    debug: false,
    nav_developer_mode: false,
    nav_show_advanced_modes: false,
    perf_debug: false,
    webhook_url: "",
    webhook_enabled: false,
    ping_user: false,
    user_id: "",
    show_status: true,
    save_pkx: true,
    always_catch_shinies: true,
    auto_open_page: true,
    primo1: "0x0499",
    primo2: "0x058E",
    primo3: "0x05CF",
    primo4: "0x05CD",
    grotto: "2",
    ot_override: false,
    tid_override: "00000",
    sid_override: "00000",
    encounter_milestones_enable: false,
    encounter_milestones_interval: 500
}

const statsTemplate = {
    total: {
        max_iv_sum: '--',
        min_iv_sum: '--',
        shiny: 0,
        seen: 0
    },
    phase: {
        lowest_sv: '--',
        seen: 0
    }
};

// Create /user and subfolders if it doesn't exist
const userDir = '../user';

if (!fs.existsSync(userDir)) {
    fs.mkdirSync(userDir);
}

if (!fs.existsSync(userDir + "/targets")) {
    fs.mkdirSync(userDir + "/targets");
}

var recents = readJSONFromFile('../user/encounters.json', []);
var targets = readJSONFromFile('../user/target_log.json', []);
var config = readJSONFromFile('../user/config.json', configTemplate);
var stats = readJSONFromFile('../user/stats.json', statsTemplate);
var lastGameSnapshot = readJSONFromFile('../user/last_party_snapshot.json', null);

// Update stats and config with values not included in previous versions
objectSubstitute(stats, statsTemplate, true)
writeJSONToFile('../user/stats.json', stats)

objectSubstitute(config, configTemplate)
writeJSONToFile('../user/config.json', config)

process.on('uncaughtException', function (err) {
    console.log(err);
});

if (config.show_status) {
    let DiscordRPC = null;

    try {
        DiscordRPC = require('discord-rich-presence')('1140996615784636446');
    } catch (err) {
        console.warn('[dashboard] Discord Rich Presence is optional and is not installed. Continuing without Discord status.');
        DiscordRPC = null;
    }

    if (DiscordRPC) {
        DiscordRPC.on('error', (reason, _promise) => {
            console.error(`Discord RPC ${reason}`);
        });

        DiscordRPC.on('connected', (_status) => {
            setInterval(() => {
                // Default status
                let status = {
                    state: 'Idle',
                    details: 'No games connected',
                    largeImageKey: 'none',
                    startTimestamp: null,
                    instance: false
                }

                if (clientData.length > 0 && clientData[0] != undefined) {
                    const version = clientData[0].version;
                    if (!version) return;

                    let icon;

                    switch (version) {
                        case 'D': icon = "diamond"; break;
                        case 'P': icon = "pearl"; break;
                        case 'PL': icon = "platinum"; break;
                        case 'HG': icon = "heartgold"; break;
                        case 'SS': icon = "soulsilver"; break;
                        case 'B': icon = "black"; break;
                        case 'W': icon = "white"; break;
                        case 'B2': icon = "black2"; break;
                        case 'W2': icon = "white2"; break;
                    }

                    const location = clientData[0].map_name;
                    const moreGames = (clients.length > 1) ? `+ ${clientData.length - 1} game(s)` : ''

                    status.largeImageKey = icon;
                    status.details = `📍${location} ${moreGames}`;
                    status.state = `${stats.total.seen} seen (${stats.total.shiny}✨) at ${encounterRate}/h`;
                    status.startTimestamp = elapsedStart;
                }

                DiscordRPC.updatePresence(status);
            }, 2500)
        }
        );
    }
}

function getTimestamp() {
    return new Date().toLocaleTimeString()
}

const server = net.createServer((socket) => {
    console.log('[%s] Session %d connected', getTimestamp(), clients.length + 1)
    clients.push(socket);
    socketSetTimeout(socket);

    socket.write(formatClientMessage(
        'apply_config',
        { 'config': config }
    ));

    let buffer = ''
    socket.on('data', (data) => {
        buffer += data.toString();
        let responses = buffer.split('\0');

        for (let i = 0; i < responses.length - 1; i++) {
            var response = responses[i].trim();

            if (response.length > 0) {
                clearTimeout(socket.inactivityTimeout);
                socketSetTimeout(socket);

                try {
                    var message = JSON.parse(response);

                    interpretClientMessage(socket, message);
                } catch (error) {
                    console.error(error);
                }
            }
        }

        buffer = responses[responses.length - 1];
    });

    socket.on('end', () => {
        const index = killSocket(socket);
        console.log('[%s] Session %d disconnected', getTimestamp(), index + 1);
    });

    socket.on('error', (_err) => {
        // console.error('Socket error:', err);
    });
});

server.listen(port, () => {
    console.log(`Socket server listening for emulators on port ${port}`);
});

function killSocket(socket) {
    clearTimeout(socket.inactivityTimeout);
    
    const index = clients.indexOf(socket);

    if (index > -1) {
        rememberGameSnapshot(clientData[index], 'socket_disconnect');
        clients.splice(index, 1);
        clientData.splice(index, 1);
    }

    socket.destroy()
    return index;
}

function socketSetTimeout(socket) {
    socket.inactivityTimeout = setTimeout(() => {
        const index = killSocket(socket);
        console.log('[%s] Session %d removed for inactivity', getTimestamp(), index + 1);
    }, clientInactivityTimeout)
}

function objectSubstitute(src, sub, recursive = false) {
    for (var key in sub) {
        if (sub.hasOwnProperty(key)) {
            if (src[key] === undefined) {
                src[key] = sub[key];
            } else if (recursive && (typeof src[key] === 'object' && typeof sub[key] === 'object')) {
                objectSubstitute(src[key], sub[key]);
            }
        }
    }
}

function writeJSONToFile(filePath, data) {
    const jsonData = JSON.stringify(data, null, '\t');
    fs.writeFileSync(filePath, jsonData, 'utf8');
}

function readJSONFromFile(filePath, defaultValue) {
    try {
        const data = fs.readFileSync(filePath, 'utf8');
        return JSON.parse(data);
    } catch (err) {
        console.error(`Error reading ${filePath}: ${err.message}`);
        writeJSONToFile(filePath, defaultValue);
        return defaultValue;
    }
}


function hasPartyData(client) {
    return !!(client && Array.isArray(client.party) && client.party.length > 0);
}

function snapshotPartyForClient(client) {
    if (hasPartyData(client)) return client.party;
    if (lastGameSnapshot && Array.isArray(lastGameSnapshot.party) && lastGameSnapshot.party.length > 0) {
        // Keep the last valid party alive across short one-action scripts and game_state-only refreshes.
        return lastGameSnapshot.party;
    }
    return null;
}

function buildGameSnapshot(client, source) {
    if (!client) return null;

    const party = snapshotPartyForClient(client);
    if (!Array.isArray(party) || party.length === 0) return null;

    const shownValues = Object.assign({}, (lastGameSnapshot && lastGameSnapshot.shownValues) || {}, client.shownValues || {});
    if (!shownValues.Name && client.trainer_name) shownValues.Name = client.trainer_name;
    if (!shownValues.Map && client.map_name) shownValues.Map = client.map_name;
    if (!shownValues.Position && client.position) shownValues.Position = client.position;

    return {
        cached: true,
        source: source || 'dashboard_socket',
        cached_at: new Date().toISOString(),
        gen: client.gen || (lastGameSnapshot && lastGameSnapshot.gen),
        version: client.version || (lastGameSnapshot && lastGameSnapshot.version) || 'Unknown',
        custom_build: client.custom_build || (lastGameSnapshot && lastGameSnapshot.custom_build),
        custom_build_label: client.custom_build_label || (lastGameSnapshot && lastGameSnapshot.custom_build_label),
        trainer_name: client.trainer_name || shownValues.Name || (lastGameSnapshot && lastGameSnapshot.trainer_name) || 'Last known party',
        trainer_id: client.trainer_id || shownValues['Trainer ID'] || (lastGameSnapshot && lastGameSnapshot.trainer_id) || '--',
        map_name: client.map_name || shownValues.Map || (lastGameSnapshot && lastGameSnapshot.map_name) || '',
        map_header: client.map_header || (lastGameSnapshot && lastGameSnapshot.map_header),
        position: client.position || shownValues.Position || (lastGameSnapshot && lastGameSnapshot.position) || '',
        x: client.x !== undefined ? client.x : (lastGameSnapshot && lastGameSnapshot.x),
        y: client.y !== undefined ? client.y : (lastGameSnapshot && lastGameSnapshot.y),
        z: client.z !== undefined ? client.z : (lastGameSnapshot && lastGameSnapshot.z),
        shownValues,
        party
    };
}

function rememberGameSnapshot(client, source) {
    const snapshot = buildGameSnapshot(client, source);
    if (!snapshot) return lastGameSnapshot;
    lastGameSnapshot = snapshot;
    try {
        writeJSONToFile('../user/last_party_snapshot.json', lastGameSnapshot);
    } catch (err) {
        console.error('Error writing last_party_snapshot.json: ' + err.message);
    }
    return lastGameSnapshot;
}

function ensureClientRecord(index) {
    if (!clientData[index]) clientData[index] = {};
    return clientData[index];
}

function updateEncounterRate() {
    var now = Date.now() / 1000
    sinceLastEncounter = now - lastEncounter

    if (!isNaN(lastEncounter) && !isNaN(sinceLastEncounter)) {
        rateHistory.push(sinceLastEncounter);

        if (rateHistory.length > rateHistorySample) rateHistory.shift();

        var sum = 0;
        for (var i = 0; i < rateHistory.length; i++) {
            sum += rateHistory[i];
        }

        encounterRate = sum / rateHistory.length; // Average out the most recent x encounters
        encounterRate = Math.floor(1 / (encounterRate / 3600)); // Convert average encounter time to encounters/h
    }

    lastEncounter = now
}

function isDuplicateRecentEncounter(mon) {
    if (!mon || !mon.pid) return false;

    // Navigation now bridges through the original encounter flow. This guard
    // prevents accidental double-counting if a future nav visibility fallback
    // sends the same encounter more than once.
    const last = recents[recents.length - 1];
    if (!last || !last.pid) return false;

    return String(last.pid) === String(mon.pid);
}

function updateEncounterLog(mon, client) {
    if (isDuplicateRecentEncounter(mon)) {
        logStore.recordLuaLog({
            level: 'info',
            category: 'encounter',
            message: `Skipped duplicate encounter log for PID ${mon.pid}.`
        }, client || {});
        return;
    }

    recents.push(mon);
    recents.splice(0, recents.length - config.encounter_log_limit);

    updateEncounterRate()

    stats.total.seen += 1;
    stats.phase.seen += 1;
  
    const encounterData = `${client.version}_${client.trainer_id}`;
    const encounter =
      typeof stats[encounterData] === "object" &&
      stats[encounterData][mon.name] > 0
        ? ++stats[encounterData][mon.name]
        : 1;
  
    stats[encounterData] = {
      ...stats[encounterData],
      ...{
        [mon.name]: encounter,
      },
    };

    stats.phase.lowest_sv = typeof (stats.phase.lowest_sv) != 'number' ? mon.shinyValue : Math.min(mon.shinyValue, stats.phase.lowest_sv);

    stats.total.max_iv_sum = typeof (stats.total.max_iv_sum) != 'number' ? mon.ivSum : Math.max(mon.ivSum, stats.total.max_iv_sum);
    stats.total.min_iv_sum = typeof (stats.total.min_iv_sum) != 'number' ? mon.ivSum : Math.min(mon.ivSum, stats.total.min_iv_sum);

    if (mon.shiny == true || mon.shinyValue < 8) {
        stats.total.shiny = stats.total.shiny + 1;
    }

    writeJSONToFile('../user/encounters.json', recents);
}

function updateTargetLog(mon, client) {
    targets.push(mon)
    targets.splice(0, targets.length - config.target_log_limit)

    // Reset target phase stats
    stats.phase.seen = 0
    stats.phase.lowest_sv = '--'
    stats[`${client.version}_${client.trainer_id}`][mon.name] = 0

    writeJSONToFile('../user/target_log.json', targets)
}

function formatClientMessage(type, data) {
    return JSON.stringify({
        'type': type,
        'data': data
    });
}

function webhookLogPokemon(mon, client) {
    let gender;
    switch (mon.gender.toLowerCase()) {
        case 'male': gender = '♂️'; break;
        case 'female': gender = '♀️'; break;
        default: gender = ''; break;
    }

    const species = mon.species.toString().padStart(3, '0');
    const iv_sum = mon.hpIV + mon.attackIV + mon.defenseIV + mon.spAttackIV + mon.spDefenseIV + mon.speedIV;
    const sparkle = (mon.shinyValue < 8 || mon.shiny) ? '✨' : '';
    const folder = (mon.shinyValue < 8 || mon.shiny) ? 'shiny/' : '';
    const file = new AttachmentBuilder(`./assets/pokemon/${folder}${species}.png`);
    const embed = new EmbedBuilder()
    if (mon.shinyValue < 8 || mon.shiny) {
        embed
          .setTitle(
            `${
              stats[`${client.version}_${client.trainer_id}`][mon.name]
            } Shiny encountered! Lv.${mon.level} ${mon.name} ${gender}`
          )
          .setThumbnail(`attachment://${species}.png`)
          .setDescription(`Found at ${client.map_name} (${client.version})`)
          .addFields(
            {
              name: "Shiny Value",
              value: `${sparkle}${mon.shinyValue.toString()}`,
              inline: true,
            },
            { name: "Nature", value: mon.nature, inline: true },
            { name: "Item", value: mon.heldItem, inline: true }
          )
          .addFields({ name: "\u200B", value: `IVs (${iv_sum} Total)` })
          .addFields(
            { name: "HP", value: mon.hpIV.toString(), inline: true },
            { name: "ATK", value: mon.attackIV.toString(), inline: true },
            { name: "DEF", value: mon.defenseIV.toString(), inline: true },
            { name: "SP.ATK", value: mon.spAttackIV.toString(), inline: true },
            { name: "SP.DEF", value: mon.spDefenseIV.toString(), inline: true },
            { name: "SPEED", value: mon.speedIV.toString(), inline: true }
          )
          .setColor("Aqua");
    } else {
        embed
          .setTitle(
            `${stats[`${client.version}_${client.trainer_id}`][mon.name]} ${
              mon.name
            } encountered!`
          )
          .setThumbnail(`attachment://${species}.png`)
          .setDescription(`Found at ${client.map_name} (${client.version})`);
    }
    const webhookClient = new WebhookClient({ url: config.webhook_url });
    let messageContents = {
        username: 'PokéBot NDS',
        avatarURL: 'https://i.imgur.com/7tJPLRX.png',
        embeds: [embed],
        files: [file],
        content:
        mon.shinyValue < 8 || mon.shiny
          ? `Encountered a shiny ✨ ${mon.name} ✨!`
          : "🎉 New milestone achieved!",
    };

    if (config.ping_user) {
        messageContents.content = `📢 <@${config.user_id}>`
    }

    webhookClient.send(messageContents);
}

function webhookTest(url) {
    const webhookClient = new WebhookClient({ url: url });
    webhookClient.send({
        username: 'PokéBot NDS',
        avatarURL: 'https://i.imgur.com/7tJPLRX.png',
        content: 'Testing...'
    });
}

function interpretClientMessage(socket, message) {
    const index = clients.indexOf(socket);
    let client = ensureClientRecord(index);
    let data = message.data;

    switch (message.type) {
        case 'seen':
            updateEncounterLog(data, client);

            writeJSONToFile("../user/stats.json", stats);

            if (
                config.webhook_enabled &&
                config.encounter_milestones_enable &&
                stats[`${client.version}_${client.trainer_id}`][data.name] %
                  config.encounter_milestones_interval ==
                  0
              ) {
                webhookLogPokemon(data, client);
            }
            break;
        case 'seen_target':
            if (config.webhook_enabled) {
                webhookLogPokemon(data, client);
            }

            updateEncounterLog(data, client);
            updateTargetLog(data, client);

            writeJSONToFile('../user/stats.json', stats);
            break;
        case 'party':
            client.party = Array.isArray(data) ? data : [];
            rememberGameSnapshot(client, 'party_update');
            break;
        case 'load_game':
            console.log('[%s] Session %d loaded %s | %s', getTimestamp(), clientData.length + 1, data.version, data.custom_build_label || 'custom build unknown');

            client.gen = data.gen;
            client.version = data.version;
            client.custom_build = data.custom_build;
            client.custom_build_label = data.custom_build_label;
            clientData[index] = client;
            rememberGameSnapshot(client, 'load_game');

            if (clients.length == 1) {
                elapsedStart = Date.now();
            }
            break;
        case 'game_state':
            const map = data.map_name || '--';

            client.map_name = map;
            client.map_header = data.map_header;
            client.x = data.trainer_x;
            client.y = data.trainer_y;
            client.z = data.trainer_z;
            client.position = `${Math.floor(data.trainer_x || 0)}, ${Math.floor(data.trainer_y || 0)}, ${Math.floor(data.trainer_z || 0)}`;
            client.trainer_name = data.trainer_name || '--'
            client.trainer_id = data.trainer_id || '--';

            // Values displayed on the game instance's tab on the dashboard
            var shownValues = {
                Name: client.trainer_name,
                "Trainer ID": client.trainer_id,
                Map: `${map} (${(data.map_header || 0).toString()})`,
                Position: client.position
            }
            
            if ('phenomenon_x' in data) {
                shownValues.Phenomenon = `${(data.phenomenon_x || '--').toString()}, --, ${(data.phenomenon_z || '--').toString()}`;
            }
            
            client.shownValues = shownValues
            rememberGameSnapshot(client, 'game_state');
            break;
        case 'save_pkx':
            const buffer = Int8Array.from(data);

            fs.writeFileSync(`../user/targets/${message.filename}`, buffer);
            break;
        case 'nav_observation':
            navStore.recordNavObservation(data, client || {});
            break;
        case 'lua_log':
            logStore.recordLuaLog(data, client || {});
            break;
    }
}

function sendConfigToClients(new_config, target) {
    writeJSONToFile('../user/config.json', new_config);
    
    // Send updated config to all clients
    if (clients.length > 0) {
        var msg = formatClientMessage(
            'apply_config',
            { 'config': new_config }
        )

        if (target == "all") {
            clients.forEach((client) => {
                client.write(msg);
            });
        } else {
            clients[target].write(msg);
        }
    }
}

module.exports = {
    clientData,
    stats,
    config,
    recents,
    targets,
    getLastGameSnapshot: () => lastGameSnapshot,
    getElapsedStart: () => {
        return elapsedStart;
    },
    getEncounterRate: () => {
        return encounterRate;
    },
    sendConfigToClients,
    setSocketConfig: (new_config) => {
        config = new_config;
    },
    webhookTest,
    navStorageStatus: () => navStore.status(),
    luaLogs: () => logStore.status({ developerMode: config && (config.debug === true || config.nav_developer_mode === true || config.nav_show_advanced_modes === true || config.perf_debug === true) }),
    clearLuaLogs: () => logStore.clearLatest(),
};