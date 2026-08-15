const http = require('http');
const fs = require('fs');
const path = require('path');
const socket = require('./socket');
const mime = require('mime');
const { readBuildInfo, buildLabel } = require('./version_authority');
const navStore = require('./nav_store');

const port = 3000;
const baseDir = path.resolve(__dirname, '.');

function noCacheHeaders() {
    return {
        'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
        'Surrogate-Control': 'no-store'
    };
}

function safeStaticPath(reqUrl) {
    const urlObject = new URL(reqUrl, 'http://localhost:' + port);
    let pathname = decodeURIComponent(urlObject.pathname || '/dashboard.html');

    if (pathname === '/' || pathname === '') {
        pathname = '/dashboard.html';
    }

    const normalized = path.normalize(pathname).replace(/^([/\\])+/, '');
    const filePath = path.join(baseDir, normalized);

    if (!filePath.startsWith(baseDir)) {
        return null;
    }

    return filePath;
}

function endpointFromPathname(pathname) {
    pathname = pathname || '';
    pathname = pathname.replace(/\/+$/, '');

    if (pathname === '/version') return 'version';
    if (pathname === '/api') return '';
    if (pathname.startsWith('/api/')) return pathname.substring('/api/'.length);

    return null;
}

console.clear(); // Clear node package upgrade text

const server = http.createServer(function (req, res) {
    const urlObject = new URL(req.url, 'http://localhost:' + port);
    const endpoint = endpointFromPathname(urlObject.pathname);

    if (endpoint !== null) {
        const sendJson = function (jsonData) {
            if (jsonData !== null) {
                res.writeHead(200, Object.assign({ 'Content-Type': 'application/json' }, noCacheHeaders()));
                res.end(JSON.stringify(jsonData, null, 2));
            } else {
                res.writeHead(404, Object.assign({ 'Content-Type': 'text/plain' }, noCacheHeaders()));
                res.end('Not Found');
            }
        };

        if (req.method === 'POST') {
            let body = '';
            req.on('data', function (chunk) {
                body += chunk.toString();
                if (body.length > 1024 * 1024) {
                    req.destroy();
                }
            });
            req.on('end', function () {
                sendJson(handleAPIRequest(endpoint, req.url, req.method, body));
            });
            return;
        }

        sendJson(handleAPIRequest(endpoint, req.url, req.method, ''));
        return;
    }

    const filePath = safeStaticPath(req.url);
    if (!filePath) {
        res.writeHead(403, Object.assign({ 'Content-Type': 'text/plain' }, noCacheHeaders()));
        res.end('Forbidden');
        return;
    }

    const extname = path.extname(filePath);
    const contentType = mime.getType(extname) || 'text/html';

    fs.readFile(filePath, function (error, data) {
        if (error) {
            if (error.code === 'ENOENT') {
                res.writeHead(404, Object.assign({ 'Content-Type': 'text/plain' }, noCacheHeaders()));
                res.end('Error: File not found');
            } else {
                res.writeHead(500, Object.assign({ 'Content-Type': 'text/plain' }, noCacheHeaders()));
                res.write('Error: Internal Server Error');
                res.end('\n\nPlease open the dashboard at http://localhost:3000/dashboard.html instead!');
            }
        } else {
            const extraHeaders = /\.(html|js|css|json)$/i.test(filePath) ? noCacheHeaders() : {};
            res.writeHead(200, Object.assign({ 'Content-Type': contentType }, extraHeaders));
            res.end(data);
        }
    });
});

server.listen(port, function (error) {
    if (error) {
        console.log('An error occurred while starting the dashboard server: ', error);
    } else {
        var url = 'http://localhost:' + port + '/dashboard.html';
        var config = require('../user/config.json');

        if (config.auto_open_page) {
            var start = (process.platform == 'darwin' ? 'open' : process.platform == 'win32' ? 'start' : 'xdg-open');
            require('child_process').exec(start + ' ' + url);
        }

        const dashVersion = readBuildInfo();
        console.log('\nDashboard started successfully. Access it at ' + url);
        console.log('Build authority: ' + (dashVersion.source || 'unknown'));
        console.log('Dashboard build: ' + buildLabel(dashVersion));
        console.log('Requires Lua build: ' + (dashVersion.requiresLua || dashVersion.build || 'unknown'));
        console.log('Version check: http://localhost:' + port + '/api/version\n');
    }
});

function parseApiData(url, body) {
    try {
        const searchParams = new URLSearchParams((url.split('?')[1]) || '');
        const dataParam = searchParams.get('data');
        if (dataParam) return JSON.parse(decodeURIComponent(dataParam));

        const trimmed = (body || '').trim();
        if (!trimmed) return {};
        if (trimmed[0] === '{' || trimmed[0] === '[') return JSON.parse(trimmed);

        const form = new URLSearchParams(trimmed);
        const formData = form.get('data');
        if (formData) return JSON.parse(decodeURIComponent(formData));
        const obj = {};
        for (const [key, value] of form.entries()) obj[key] = value;
        return obj;
    } catch (err) {
        return { __parse_error: err && err.message ? err.message : String(err) };
    }
}


function safeApiResult(name, fn) {
    try {
        return fn();
    } catch (err) {
        return {
            error: name + ' failed',
            status: 'error',
            detail: err && err.message ? err.message : String(err),
            generated_at: new Date().toISOString()
        };
    }
}

function handleAPIRequest(endpoint, url, method, body) {
    let data = parseApiData(url, body || '');
    endpoint = (endpoint || '').replace(/^\/+|\/+$/g, '');

    if (data && data.__parse_error) {
        return { error: 'Invalid API data', detail: data.__parse_error };
    }

    switch (endpoint) {
        case 'test_webhook':
            socket.webhookTest(data.webhook_url);
            break;
        case 'version':
            return readBuildInfo();
        case 'clients':
            return socket.clientData;
        case 'last_party_snapshot':
        case 'last_game_snapshot':
            return socket.getLastGameSnapshot ? socket.getLastGameSnapshot() : null;
        case 'stats':
            return socket.stats;
        case 'recents':
            return socket.recents;
        case 'targets':
            return socket.targets;
        case 'elapsed_start':
            return socket.getElapsedStart();
        case 'config':
            if (method == "GET") {
                return socket.config;
            } else if (method == "POST") {
                socket.sendConfigToClients(data.config, data.game);
                socket.config = data.config;
                socket.setSocketConfig(data.config);
                return socket.config;
            }
            return null;
        case 'encounter_rate':
            return socket.getEncounterRate();
        case 'nav_storage':
        case 'nav_storage_health':
            if (socket.navStorageStatus) return socket.navStorageStatus();
            return navStore.status ? navStore.status() : { backend: 'unavailable', health: 'unavailable' };
        case 'nav_coverage':
        case 'nav_storage_coverage':
            return navStore.coverageStatus ? navStore.coverageStatus() : { backend: 'unavailable', health: 'unavailable', coverage: null };
        case 'nav_integrity':
        case 'nav_storage_integrity':
            return navStore.integrityStatus ? navStore.integrityStatus() : { backend: 'unavailable', health: 'unavailable', audit: null };
        case 'nav_repair_preview':
        case 'nav_storage_repair_preview':
            return navStore.createRepairPreview ? navStore.createRepairPreview() : { backend: 'unavailable', actions: [] };
        case 'nav_backups':
        case 'nav_storage_backups':
            return navStore.listBackups ? navStore.listBackups() : { backups: [] };
        case 'nav_quarantine':
        case 'nav_storage_quarantine':
            return navStore.listQuarantines ? navStore.listQuarantines() : { quarantines: [] };
        case 'nav_rebuild_cache_preview':
        case 'nav_derived_cache_rebuild_preview':
        case 'nav_storage_rebuild_cache_preview':
            return navStore.derivedCacheRebuildPreview ? navStore.derivedCacheRebuildPreview(data || {}) : { error: 'derived cache rebuild preview unavailable' };
        case 'nav_drift_report':
        case 'nav_storage_drift_report':
        case 'nav_raw_tsv_drift_report':
            return navStore.driftReport ? navStore.driftReport() : { error: 'drift report unavailable' };
        case 'nav_battle_observations':
        case 'nav_storage_battle_observations':
            return navStore.battleObservationSummary ? navStore.battleObservationSummary() : { error: 'battle observation summary unavailable' };
        case 'nav_component_classification':
        case 'nav_storage_component_classification':
            return navStore.componentClassification ? navStore.componentClassification() : { error: 'component classification unavailable' };
        case 'nav_storage_final_gate':
        case 'nav_final_gate':
        case 'nav_v39_final_gate':
            return navStore.finalStorageGate ? navStore.finalStorageGate() : { error: 'final storage gate unavailable' };
        case 'nav_future_action_items':
        case 'nav_v40_action_items':
        case 'nav_cleanup_plan':
            return navStore.futureActionItems ? navStore.futureActionItems() : { error: 'future action items unavailable' };
        case 'nav_test_summary':
        case 'nav_after_action_summary':
        case 'nav_after_action':
        case 'nav_quick_check':
            return navStore.afterActionSummary ? navStore.afterActionSummary(data || {}) : { error: 'after action summary unavailable' };
        case 'nav_scan_lens':
        case 'nav_lens':
        case 'nav_coverage_lens':
        case 'nav_scanned_unscanned':
            return safeApiResult('scan lens', () => navStore.scanLens ? navStore.scanLens(data || {}) : { error: 'scan lens unavailable' });
        case 'nav_tile_codes':
        case 'nav_tile_atlas':
        case 'nav_exact_tile_codes':
        case 'nav_surface_codes':
            return safeApiResult('tile-code atlas', () => navStore.tileCodeAtlas ? navStore.tileCodeAtlas(data || {}) : { error: 'tile-code atlas unavailable' });
        case 'nav_tile_capabilities':
        case 'nav_capability_engine':
        case 'nav_tile_capability_engine':
            return safeApiResult('tile capability engine', () => navStore.tileCapabilityEngine ? navStore.tileCapabilityEngine(data || {}) : { error: 'tile capability engine unavailable' });
        case 'nav_scan_lens_ui':
        case 'nav_lens_ui':
        case 'nav_scan_dashboard':
            return safeApiResult('scan lens ui', () => navStore.scanLensUiData ? navStore.scanLensUiData(data || {}) : { error: 'scan lens ui unavailable' });
        case 'nav_map_pack_status':
        case 'nav_map_packs':
        case 'nav_shared_map_status':
            return safeApiResult('map pack status', () => navStore.mapPackStatus ? navStore.mapPackStatus(data || {}) : { error: 'map pack status unavailable' });
        case 'nav_map_archive_preview':
        case 'nav_map_reset_preview':
        case 'nav_clean_map_preview':
            return safeApiResult('map archive preview', () => navStore.mapDataArchivePreview ? navStore.mapDataArchivePreview(data || {}) : { error: 'map archive preview unavailable' });
        case 'nav_map_archive_reset':
        case 'nav_map_reset':
        case 'nav_clean_map_reset':
            if (method !== 'POST') return safeApiResult('map archive preview', () => navStore.mapDataArchivePreview ? navStore.mapDataArchivePreview(data || {}) : { error: 'map archive preview unavailable' });
            return safeApiResult('map archive reset', () => navStore.mapDataArchiveReset ? navStore.mapDataArchiveReset(data || {}) : { error: 'map archive reset unavailable' });
        case 'nav_blockage_report':
        case 'nav_dynamic_blockages':
        case 'nav_obstacle_report':
            return safeApiResult('blockage report', () => navStore.blockageReport ? navStore.blockageReport(data || {}) : { error: 'blockage report unavailable' });
        case 'nav_baritone_lite_plan':
        case 'nav_blt_plan':
        case 'nav_v40_plan':
        case 'nav_perfect_outcome':
            return navStore.baritoneLitePlan ? navStore.baritoneLitePlan() : { error: 'baritone-lite plan unavailable' };
        case 'nav_baritone_lite_status':
        case 'nav_learner_status':
        case 'nav_blt_status':
            return navStore.baritoneLiteStatus ? navStore.baritoneLiteStatus() : { error: 'baritone-lite status unavailable' };
        case 'nav_baritone_lite_gate':
        case 'nav_v40_acceptance':
        case 'nav_blt_gate':
            return navStore.baritoneLiteAcceptanceGate ? navStore.baritoneLiteAcceptanceGate() : { error: 'baritone-lite acceptance gate unavailable' };
        case 'nav_v40_cleanup_status':
        case 'nav_clean_runtime_status':
            return navStore.v40CleanupStatus ? navStore.v40CleanupStatus() : { error: 'v40 cleanup status unavailable' };
        case 'nav_selftest':
        case 'nav_storage_selftest':
            return navStore.selfTest ? navStore.selfTest() : { error: 'selftest unavailable' };
        case 'nav_stress_test_plan':
            return navStore.stressTestPlan ? navStore.stressTestPlan() : { error: 'stress test plan unavailable' };
        case 'nav_stress_snapshot':
        case 'nav_storage_stress_snapshot':
            return navStore.stressSnapshot ? navStore.stressSnapshot() : { error: 'stress snapshot unavailable' };
        case 'nav_stress_runbook':
        case 'nav_storage_stress_runbook':
            return navStore.stressRunbook ? navStore.stressRunbook() : { error: 'stress runbook unavailable' };
        case 'nav_stress_baselines':
        case 'nav_storage_stress_baselines':
            return navStore.listStressBaselines ? navStore.listStressBaselines() : { error: 'stress baselines unavailable' };
        case 'nav_stress_baseline_create':
        case 'nav_storage_stress_baseline_create':
            if (method !== 'POST') {
                return { error: 'Stress baseline creation requires POST. Use data={"label":"before_test"} if needed.' };
            }
            return navStore.createStressBaseline ? navStore.createStressBaseline(data || {}) : { error: 'stress baseline create unavailable' };
        case 'nav_stress_compare':
        case 'nav_storage_stress_compare':
        case 'nav_stress_after_action':
            return navStore.stressCompare ? navStore.stressCompare(data || {}) : { error: 'stress compare unavailable' };
        case 'nav_backup_create':
        case 'nav_storage_backup_create':
            return navStore.makeBackup ? navStore.makeBackup((data && data.reason) || 'manual_dashboard_api') : { error: 'backup unavailable' };
        case 'nav_repair_quarantine_suspicious':
            if (method !== 'POST') {
                return navStore.quarantineSuspiciousNodes ? navStore.quarantineSuspiciousNodes({ dry_run: true }) : { error: 'repair unavailable' };
            }
            return navStore.quarantineSuspiciousNodes ? navStore.quarantineSuspiciousNodes(data || {}) : { error: 'repair unavailable' };
        case 'nav_restore_backup':
            if (method !== 'POST') {
                return { error: 'Restore requires POST with data={"backup_path":"user/nav/backups/...","confirm":true}' };
            }
            return navStore.restoreBackup ? navStore.restoreBackup(data && (data.backup_path || data.backup_dir || data.path), data || {}) : { error: 'restore unavailable' };
        case 'lua_logs':
            return socket.luaLogs ? socket.luaLogs() : { entries: [], latest_text: '', previous_text: '' };
        case 'clear_lua_logs':
            if (socket.clearLuaLogs) {
                socket.clearLuaLogs();
            }
            return socket.luaLogs ? socket.luaLogs() : { entries: [], latest_text: '', previous_text: '' };
        default:
            return null;
    }
}
