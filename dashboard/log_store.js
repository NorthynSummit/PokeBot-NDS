const fs = require('fs');
const path = require('path');
const { readBuildInfo, buildLabel } = require('./version_authority');

const logsDir = path.resolve(__dirname, '../user/logs');
const latestPath = path.join(logsDir, 'latest.log');
const previousPath = path.join(logsDir, 'previous.log');
const maxEntries = 1500;

let entries = [];          // clean user-visible entries only
let developerEntries = []; // debug/PERF-only entries
let allEntries = [];       // full ordered runtime log for Developer Mode display
let sessionStartedAt = new Date().toISOString();
let initialized = false;
let initializedBuildLabel = '';

function ensureDir() {
    if (!fs.existsSync(logsDir)) {
        fs.mkdirSync(logsDir, { recursive: true });
    }
}

function logHeader(label, fullMode) {
    const buildInfo = readBuildInfo();
    initializedBuildLabel = buildLabel(buildInfo);

    const modeLine = fullMode
        ? '# Developer view includes debug-only and [PERF] timing lines.'
        : '# Normal log hides performance/debug-only [PERF] lines. Enable Developer Mode / Full Debug Log in Config to view the full runtime log.';

    return [
        '# PokéBot NDS Lua Log',
        `# Build: ${initializedBuildLabel}`,
        `# Session ${label}: ${new Date().toISOString()}`,
        '# Only latest.log and previous.log are kept to prevent log buildup.',
        modeLine,
        '',
        ''
    ].join('\n');
}

function rotateLogsOnce() {
    if (initialized) return;
    initialized = true;
    ensureDir();

    try {
        if (fs.existsSync(latestPath) && fs.statSync(latestPath).size > 0) {
            if (fs.existsSync(previousPath)) {
                fs.rmSync(previousPath, { force: true });
            }
            fs.renameSync(latestPath, previousPath);
        }
        fs.writeFileSync(latestPath, logHeader('started', false), 'utf8');
    } catch (err) {
        console.error('Failed to rotate Lua logs:', err);
    }
}

function safeText(value) {
    if (value === undefined || value === null) return '';
    return String(value).replace(/\r?\n/g, '\\n');
}

function formatEntry(entry) {
    const time = entry.time || new Date().toLocaleTimeString();
    const level = safeText(entry.level || 'info').toUpperCase();
    const category = safeText(entry.category || 'lua');
    const message = safeText(entry.message || '');
    const frame = entry.frame !== undefined ? ` f=${entry.frame}` : '';
    const map = entry.context && entry.context.map_name ? ` @ ${entry.context.map_name}` : '';
    const pos = entry.context && entry.context.x !== undefined && entry.context.z !== undefined ? ` (${entry.context.x},${entry.context.y || ''},${entry.context.z})` : '';

    return `[${time}] [${level}] [${category}]${frame}${map}${pos} ${message}`;
}

function isDeveloperOnly(entry) {
    const message = safeText(entry.message || '');
    const level = safeText(entry.level || '').toLowerCase();
    const category = safeText(entry.category || '').toLowerCase();

    if (message.indexOf('[PERF]') !== -1) return true;
    if (/timing enabled/i.test(message)) return true;
    if (level === 'debug' || category === 'debug' || category === 'perf' || category === 'performance') return true;

    return false;
}

function trimList(list) {
    if (list.length > maxEntries) {
        list.splice(0, list.length - maxEntries);
    }
}

function recordLuaLog(data, client) {
    rotateLogsOnce();

    const entry = {
        time: new Date().toLocaleTimeString(),
        iso: new Date().toISOString(),
        level: data && data.level ? data.level : 'info',
        category: data && data.category ? data.category : 'lua',
        message: data && data.message ? data.message : '',
        frame: data && data.frame !== undefined ? data.frame : undefined,
        seq: data && data.seq !== undefined ? data.seq : undefined,
        context: data && data.context ? data.context : {},
        client: client ? {
            version: client.version,
            trainer_name: client.trainer_name,
            map_name: client.map_name,
            position: client.position
        } : {}
    };

    const developerOnly = isDeveloperOnly(entry);

    allEntries.push(entry);
    trimList(allEntries);

    if (developerOnly) {
        developerEntries.push(entry);
        trimList(developerEntries);
        return;
    }

    entries.push(entry);
    trimList(entries);

    try {
        fs.appendFileSync(latestPath, formatEntry(entry) + '\n', 'utf8');
    } catch (err) {
        console.error('Failed to append Lua log:', err);
    }
}

function readFileText(filePath) {
    try {
        if (!fs.existsSync(filePath)) return '';
        return fs.readFileSync(filePath, 'utf8');
    } catch (_err) {
        return '';
    }
}

function formatEntryList(list) {
    return (list || []).map(formatEntry).join('\n');
}

function fullLogText() {
    const body = formatEntryList(allEntries.slice(-500));
    return logHeader('developer-view', true) + body + (body ? '\n' : '');
}

function clearLatest() {
    rotateLogsOnce();
    entries = [];
    developerEntries = [];
    allEntries = [];
    sessionStartedAt = new Date().toISOString();
    fs.writeFileSync(latestPath, logHeader('cleared', false), 'utf8');
}

function status(options) {
    rotateLogsOnce();
    options = options || {};
    const developerMode = options.developerMode === true;
    const buildInfo = readBuildInfo();
    const latestText = readFileText(latestPath);
    const developerText = formatEntryList(developerEntries.slice(-500));
    const fullText = fullLogText();

    return {
        build: buildInfo,
        dashboard_runtime: buildLabel(buildInfo),
        session_started_at: sessionStartedAt,
        logs_dir: logsDir,
        latest_path: latestPath,
        previous_path: previousPath,
        entry_count: entries.length,
        developer_entry_count: developerEntries.length,
        all_entry_count: allEntries.length,
        developer_mode: developerMode,
        retention: 'latest.log plus previous.log only',
        log_header_build: initializedBuildLabel || buildLabel(buildInfo),
        latest_text: latestText,
        previous_text: readFileText(previousPath),
        developer_text: developerText,
        full_text: developerMode ? fullText : latestText,
        display_text: developerMode ? fullText : latestText,
        entries: entries.slice(-500),
        developer_entries: developerEntries.slice(-500),
        all_entries: developerMode ? allEntries.slice(-500) : []
    };
}

rotateLogsOnce();

module.exports = {
    recordLuaLog,
    clearLatest,
    status,
    latestPath,
    previousPath
};
