const fs = require('fs');
const path = require('path');

// v39 keeps the dashboard storage backend TSV-only.
// No SQLite/native module and no JSONL fallback is required to start the dashboard.
const USER_DIR = path.resolve(__dirname, '../user');
const NAV_DIR = path.join(USER_DIR, 'nav');
const GAMES_DIR = path.join(NAV_DIR, 'games');
const ROUTES_DIR = path.join(USER_DIR, 'routes');
const STRESS_DIR = path.join(NAV_DIR, 'stress_snapshots');
const PROJECT_ROOT = path.resolve(__dirname, '..');
const VERSION = 'v40.10';
const SOURCE_OF_TRUTH = 'normalized_tsv_foundation';
const BACKEND = 'tsv_compat';

const TABLES = [
    { name: 'nodes', keyColumn: 0 },
    { name: 'edges', keyColumn: 0 },
    { name: 'blocked', keyColumn: 0 },
    { name: 'transitions', keyColumn: 0 },
    { name: 'observations', keyColumn: null }
];

const DIRECTIONS = ['Up', 'Down', 'Left', 'Right'];
const OPPOSITE = { Up: 'Down', Down: 'Up', Left: 'Right', Right: 'Left' };

let memory = {
    observationsRecorded: 0,
    lastObservationAt: null,
    lastObservation: null,
    lastWriteError: null
};

function ensureDir(dir) {
    fs.mkdirSync(dir, { recursive: true });
}

function safeStat(filePath) {
    try {
        return fs.statSync(filePath);
    } catch (_err) {
        return null;
    }
}

function readLines(filePath) {
    try {
        const text = fs.readFileSync(filePath, 'utf8');
        if (!text) return [];
        return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n').filter(line => line.length > 0);
    } catch (_err) {
        return [];
    }
}

function rel(filePath) {
    return path.relative(PROJECT_ROOT, filePath).replace(/\\/g, '/');
}

function findLatestGameDir() {
    const stat = safeStat(GAMES_DIR);
    if (!stat || !stat.isDirectory()) return null;

    let candidates = [];
    for (const name of fs.readdirSync(GAMES_DIR)) {
        const full = path.join(GAMES_DIR, name);
        const s = safeStat(full);
        if (s && s.isDirectory()) candidates.push({ game_id: name, dir: full, mtimeMs: s.mtimeMs });
    }

    candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
    return candidates[0] || null;
}

function analyzeTsv(filePath, keyColumn) {
    const stat = safeStat(filePath);
    const exists = !!stat && stat.isFile();
    const result = {
        path: rel(filePath),
        exists,
        bytes: exists ? stat.size : 0,
        modified_at: exists ? stat.mtime.toISOString() : null,
        records: 0,
        duplicate_keys: 0,
        header: ''
    };

    if (!exists) return result;

    const lines = readLines(filePath);
    result.header = lines[0] || '';
    const dataLines = lines.slice(1);
    result.records = dataLines.length;

    if (keyColumn !== null && keyColumn !== undefined) {
        const seen = new Set();
        let duplicates = 0;
        for (const line of dataLines) {
            const cols = line.split('\t');
            const key = cols[keyColumn] || '';
            if (!key) continue;
            if (seen.has(key)) duplicates += 1;
            seen.add(key);
        }
        result.duplicate_keys = duplicates;
    }

    return result;
}

function summarizeRawRoutes() {
    const files = ['map_graph.txt', 'map_sweep_edges.txt', 'map_nodes.txt', 'routes_index.txt'];
    const out = {};
    for (const file of files) {
        const full = path.join(ROUTES_DIR, file);
        const stat = safeStat(full);
        out[file] = {
            exists: !!stat && stat.isFile(),
            bytes: stat && stat.isFile() ? stat.size : 0,
            modified_at: stat && stat.isFile() ? stat.mtime.toISOString() : null
        };
    }
    return out;
}

function parseTsvObjects(filePath) {
    const lines = readLines(filePath);
    if (!lines.length) return { header: [], rows: [] };
    const header = lines[0].split('\t');
    const rows = lines.slice(1).map(line => {
        const cols = line.split('\t');
        const row = {};
        header.forEach((name, index) => { row[name] = cols[index] !== undefined ? cols[index] : ''; });
        return row;
    });
    return { header, rows };
}

function loadStorageRows(game) {
    if (!game) return { nodes: [], edges: [], blocked: [], transitions: [], observations: [] };
    return {
        nodes: parseTsvObjects(path.join(game.dir, 'nodes.tsv')).rows,
        edges: parseTsvObjects(path.join(game.dir, 'edges.tsv')).rows,
        blocked: parseTsvObjects(path.join(game.dir, 'blocked.tsv')).rows,
        transitions: parseTsvObjects(path.join(game.dir, 'transitions.tsv')).rows,
        observations: parseTsvObjects(path.join(game.dir, 'observations.tsv')).rows
    };
}

function numberValue(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
}

function coordKey(row) {
    if (!row) return '';
    return [row.map_header || '', row.tile_y || '', row.tile_x || '', row.tile_z || ''].join('|');
}

function scanKey(nodeId, direction) {
    return `${nodeId || ''}|${direction || ''}`;
}

function neighborCoord(row, direction) {
    const x = numberValue(row.tile_x);
    const z = numberValue(row.tile_z);
    if (x === null || z === null) return null;
    let nx = x;
    let nz = z;
    if (direction === 'Up') nz -= 1;
    else if (direction === 'Down') nz += 1;
    else if (direction === 'Left') nx -= 1;
    else if (direction === 'Right') nx += 1;
    else return null;
    return { x: nx, y: row.tile_y || '', z: nz };
}

function neighborKey(row, direction) {
    const c = neighborCoord(row, direction);
    if (!c) return '';
    return [row.map_header || '', c.y, String(c.x), String(c.z)].join('|');
}

function expectedNodeId(row, gameId) {
    return [gameId || row.game_id || '', row.map_header || '', row.tile_x || '', row.tile_y || '', row.tile_z || ''].join('|');
}

function sample(list, count) {
    return list.slice(0, count || 40);
}

function buildIndexes(rows, gameId) {
    const nodeById = new Map();
    const coordToNodes = new Map();
    const duplicateCoordinates = [];
    const nodeIdMismatches = [];
    const invalidNodes = [];

    for (const node of rows.nodes) {
        if (node.node_id) nodeById.set(node.node_id, node);
        const key = coordKey(node);
        if (key) {
            if (!coordToNodes.has(key)) coordToNodes.set(key, []);
            coordToNodes.get(key).push(node);
        }

        const x = numberValue(node.tile_x);
        const y = numberValue(node.tile_y);
        const z = numberValue(node.tile_z);
        if (!node.node_id || !node.map_header || x === null || y === null || z === null) {
            invalidNodes.push({ node_id: node.node_id || '', reason: 'missing id/map header or non-numeric coordinate' });
        } else {
            const expected = expectedNodeId(node, gameId);
            if (node.node_id !== expected) {
                nodeIdMismatches.push({ node_id: node.node_id, expected_node_id: expected, reason: 'node_id does not match stored game/map/tile coordinates' });
            }
        }
    }

    for (const [key, list] of coordToNodes.entries()) {
        if (list.length > 1) {
            duplicateCoordinates.push({ coord_key: key, node_ids: list.map(n => n.node_id).filter(Boolean), count: list.length });
        }
    }

    const scanned = new Set();
    const walkable = new Set();
    const blockedSet = new Set();
    const transitionSet = new Set();
    const edgesFrom = new Map();
    const undirectedAdj = new Map();

    const addAdj = (a, b) => {
        if (!a || !b) return;
        if (!undirectedAdj.has(a)) undirectedAdj.set(a, new Set());
        if (!undirectedAdj.has(b)) undirectedAdj.set(b, new Set());
        undirectedAdj.get(a).add(b);
        undirectedAdj.get(b).add(a);
    };

    for (const node of rows.nodes) {
        if (node.node_id && !undirectedAdj.has(node.node_id)) undirectedAdj.set(node.node_id, new Set());
    }

    for (const edge of rows.edges) {
        if (!edge.from_node_id || !edge.direction) continue;
        const key = scanKey(edge.from_node_id, edge.direction);
        scanned.add(key);
        walkable.add(key);
        if (!edgesFrom.has(edge.from_node_id)) edgesFrom.set(edge.from_node_id, []);
        edgesFrom.get(edge.from_node_id).push(edge);
        if (edge.to_node_id) addAdj(edge.from_node_id, edge.to_node_id);
    }
    for (const item of rows.blocked) {
        if (!item.from_node_id || !item.direction) continue;
        const key = scanKey(item.from_node_id, item.direction);
        scanned.add(key);
        blockedSet.add(key);
    }
    for (const item of rows.transitions) {
        if (!item.from_node_id || !item.direction) continue;
        const key = scanKey(item.from_node_id, item.direction);
        scanned.add(key);
        transitionSet.add(key);
        if (item.to_node_id) addAdj(item.from_node_id, item.to_node_id);
    }

    return {
        nodeById,
        coordToNodes,
        duplicateCoordinates,
        nodeIdMismatches,
        invalidNodes,
        scanned,
        walkable,
        blockedSet,
        transitionSet,
        edgesFrom,
        undirectedAdj
    };
}

function componentAnalysis(rows, indexes) {
    const seen = new Set();
    const components = [];
    for (const node of rows.nodes) {
        const start = node.node_id;
        if (!start || seen.has(start)) continue;
        const queue = [start];
        seen.add(start);
        const ids = [];
        while (queue.length) {
            const id = queue.shift();
            ids.push(id);
            const neighbors = indexes.undirectedAdj.get(id) || new Set();
            for (const next of neighbors) {
                if (!seen.has(next)) {
                    seen.add(next);
                    queue.push(next);
                }
            }
        }
        const coords = ids.map(id => indexes.nodeById.get(id)).filter(Boolean).map(n => ({
            x: numberValue(n.tile_x),
            z: numberValue(n.tile_z),
            map_header: n.map_header || '',
            map_name: n.map_name || ''
        })).filter(c => c.x !== null && c.z !== null);
        const xs = coords.map(c => c.x);
        const zs = coords.map(c => c.z);
        const mapNames = [...new Set(coords.map(c => c.map_name).filter(Boolean))];
        components.push({
            size: ids.length,
            node_ids: ids,
            map_headers: [...new Set(coords.map(c => c.map_header).filter(Boolean))],
            map_names: mapNames,
            bounds: xs.length ? { min_x: Math.min(...xs), max_x: Math.max(...xs), min_z: Math.min(...zs), max_z: Math.max(...zs) } : null
        });
    }
    components.sort((a, b) => b.size - a.size || String(a.node_ids[0]).localeCompare(String(b.node_ids[0])));
    const main = components[0] || null;
    return {
        total_components: components.length,
        main_component_size: main ? main.size : 0,
        disconnected_components: Math.max(0, components.length - 1),
        small_components: components.filter(c => c.size < 3).length,
        components,
        component_sample: components.slice(0, 12).map(c => ({
            size: c.size,
            map_headers: c.map_headers,
            map_names: c.map_names,
            bounds: c.bounds,
            sample_node_ids: c.node_ids.slice(0, 6)
        }))
    };
}

function detectOutlierNodes(rows, components, indexes) {
    const outliers = [];
    const main = components.components && components.components[0];
    if (!main || !main.bounds || main.size < 8) return outliers;
    const pad = 80;
    const b = main.bounds;
    const mainMapHeaders = new Set(main.map_headers || []);
    for (const node of rows.nodes) {
        const x = numberValue(node.tile_x);
        const z = numberValue(node.tile_z);
        if (x === null || z === null) continue;
        const sameMap = mainMapHeaders.has(node.map_header || '');
        const far = sameMap && (x < b.min_x - pad || x > b.max_x + pad || z < b.min_z - pad || z > b.max_z + pad);
        const obviousPlaceholder = (x === 0 && z <= 0) || /\|0\|0\|-1$/.test(node.node_id || '');
        if (far || obviousPlaceholder) {
            outliers.push({
                node_id: node.node_id,
                map_name: node.map_name || '',
                map_header: node.map_header || '',
                tile_x: node.tile_x,
                tile_y: node.tile_y,
                tile_z: node.tile_z,
                reason: obviousPlaceholder ? 'placeholder-like coordinate' : 'far outside the main connected map cluster'
            });
        }
    }
    return outliers;
}

function storageStatusBase(game, tables, counts, warnings) {
    const raw_routes = summarizeRawRoutes();
    const hasTables = game && TABLES.every(t => tables[t.name] && tables[t.name].exists);
    const hasRecords = (counts.nodes || 0) > 0 || (counts.observations || 0) > 0;

    let health = 'missing';
    if (hasTables && hasRecords && warnings.length === 0) health = 'ready';
    else if (hasTables && hasRecords) health = 'needs_review';
    else if (hasTables) health = 'initialized_empty';

    if (!game) warnings.push('No game-specific navigation folder found yet. Run Learn Current Area or Storage Status after Lua connects.');
    if (raw_routes['map_graph.txt'] && !raw_routes['map_graph.txt'].exists) warnings.push('Raw map graph cache is missing; rebuild or learn an area when needed.');

    return { raw_routes, health };
}

function status() {
    ensureDir(NAV_DIR);
    ensureDir(GAMES_DIR);

    const game = findLatestGameDir();
    const tables = {};
    const counts = {};
    const warnings = [];

    for (const table of TABLES) {
        const tablePath = game ? path.join(game.dir, table.name + '.tsv') : path.join(GAMES_DIR, '<game>', table.name + '.tsv');
        const info = game ? analyzeTsv(tablePath, table.keyColumn) : {
            path: rel(tablePath),
            exists: false,
            bytes: 0,
            modified_at: null,
            records: 0,
            duplicate_keys: 0,
            header: ''
        };
        tables[table.name] = info;
        counts[table.name] = info.records;
        if (!info.exists) warnings.push(`${table.name}.tsv is missing.`);
        if (info.duplicate_keys > 0) warnings.push(`${table.name}.tsv has ${info.duplicate_keys} duplicate key(s).`);
    }

    const base = storageStatusBase(game, tables, counts, warnings);

    return {
        version: VERSION,
        backend: BACKEND,
        source_of_truth: SOURCE_OF_TRUTH,
        sqlite: {
            enabled: false,
            required: false,
            status: 'not_used',
            note: 'SQLite is not loaded by the dashboard. v40.9 keeps TSV as the active backend while adding goal-directed Baritone-lite planning, strict movement write gates, profile-based exact tile atlas, and concise normal/Dev BLT logging.'
        },
        game_id: game ? game.game_id : null,
        nav_dir: rel(NAV_DIR),
        game_dir: game ? rel(game.dir) : null,
        health: base.health,
        counts,
        tables,
        raw_routes: base.raw_routes,
        server_observations_seen_this_run: memory.observationsRecorded,
        last_observation_at: memory.lastObservationAt || (tables.observations && tables.observations.modified_at) || null,
        last_write_error: memory.lastWriteError,
        warnings
    };
}

// Lua remains the source that writes normalized TSV observations.
// Dashboard-side observation messages are counted only; they are not written to a second backend.
function recordNavObservation(data, client) {
    try {
        memory.observationsRecorded += 1;
        memory.lastObservationAt = new Date().toISOString();
        memory.lastObservation = {
            client_version: client && client.version ? client.version : null,
            mode: data && data.mode ? data.mode : null,
            source: data && data.source ? data.source : null,
            direction: data && data.direction ? data.direction : null,
            result: data && data.result ? data.result : null
        };
        memory.lastWriteError = null;
        return true;
    } catch (err) {
        memory.lastWriteError = err && err.message ? err.message : String(err);
        return false;
    }
}

function integrityStatus() {
    const storage = status();
    const game = findLatestGameDir();
    if (!game) {
        return {
            version: VERSION,
            backend: BACKEND,
            source_of_truth: SOURCE_OF_TRUTH,
            health: 'missing',
            game_id: null,
            generated_at: new Date().toISOString(),
            audit: null,
            repair_preview: [],
            warnings: ['No game-specific navigation folder found yet.']
        };
    }

    const rows = loadStorageRows(game);
    const indexes = buildIndexes(rows, game.game_id);
    const components = componentAnalysis(rows, indexes);
    const outlierNodes = detectOutlierNodes(rows, components, indexes);

    const edgesMissingFrom = [];
    const edgesMissingTo = [];
    const transitionsMissingFrom = [];
    const observationsMissingNodes = [];
    const missingExplicitReverseEdges = [];

    for (const edge of rows.edges) {
        if (edge.from_node_id && !indexes.nodeById.has(edge.from_node_id)) edgesMissingFrom.push(edge);
        if (edge.to_node_id && !indexes.nodeById.has(edge.to_node_id)) edgesMissingTo.push(edge);
        if (edge.from_node_id && edge.to_node_id && edge.direction && indexes.nodeById.has(edge.from_node_id) && indexes.nodeById.has(edge.to_node_id)) {
            const reverseKey = scanKey(edge.to_node_id, OPPOSITE[edge.direction]);
            if (!indexes.walkable.has(reverseKey)) {
                missingExplicitReverseEdges.push({
                    from_node_id: edge.from_node_id,
                    direction: edge.direction,
                    to_node_id: edge.to_node_id,
                    reverse_direction: OPPOSITE[edge.direction],
                    note: 'Reverse walkable edge is not explicit in edges.tsv. This may be okay if inferred reverse edges are enabled, but it matters for strict storage rebuilds.'
                });
            }
        }
    }

    for (const item of rows.transitions) {
        if (item.from_node_id && !indexes.nodeById.has(item.from_node_id)) transitionsMissingFrom.push(item);
    }
    for (const obs of rows.observations) {
        if (obs.from_node_id && !indexes.nodeById.has(obs.from_node_id)) observationsMissingNodes.push({ observation_time: obs.observation_time, from_node_id: obs.from_node_id, direction: obs.direction, result: obs.result });
        if (obs.to_node_id && !indexes.nodeById.has(obs.to_node_id)) observationsMissingNodes.push({ observation_time: obs.observation_time, to_node_id: obs.to_node_id, direction: obs.direction, result: obs.result });
    }

    const issueCounts = {
        duplicate_node_keys: storage.tables.nodes ? storage.tables.nodes.duplicate_keys : 0,
        duplicate_edge_keys: storage.tables.edges ? storage.tables.edges.duplicate_keys : 0,
        duplicate_blocked_keys: storage.tables.blocked ? storage.tables.blocked.duplicate_keys : 0,
        duplicate_transition_keys: storage.tables.transitions ? storage.tables.transitions.duplicate_keys : 0,
        duplicate_coordinates: indexes.duplicateCoordinates.length,
        invalid_nodes: indexes.invalidNodes.length,
        node_id_mismatches: indexes.nodeIdMismatches.length,
        suspicious_outlier_nodes: outlierNodes.length,
        edges_missing_from_node: edgesMissingFrom.length,
        edges_missing_to_node: edgesMissingTo.length,
        transitions_missing_from_node: transitionsMissingFrom.length,
        observations_referencing_missing_nodes: observationsMissingNodes.length,
        disconnected_components: components.disconnected_components,
        small_components: components.small_components,
        missing_explicit_reverse_edges: missingExplicitReverseEdges.length
    };

    const blockingIssues = issueCounts.invalid_nodes + issueCounts.node_id_mismatches + issueCounts.edges_missing_from_node + issueCounts.edges_missing_to_node + issueCounts.transitions_missing_from_node + issueCounts.observations_referencing_missing_nodes;
    const reviewIssues = issueCounts.duplicate_coordinates + issueCounts.suspicious_outlier_nodes + issueCounts.disconnected_components + issueCounts.small_components;
    const health = blockingIssues > 0 ? 'blocked' : (reviewIssues > 0 ? 'needs_review' : 'ready');

    const warnings = [...(storage.warnings || [])];
    if (issueCounts.suspicious_outlier_nodes > 0) warnings.push(`${issueCounts.suspicious_outlier_nodes} suspicious/outlier node(s) found.`);
    if (issueCounts.disconnected_components > 0) warnings.push(`${issueCounts.disconnected_components} disconnected storage component(s) found.`);
    if (blockingIssues > 0) warnings.push(`${blockingIssues} blocking storage integrity issue(s) found.`);
    if (missingExplicitReverseEdges.length > 0) warnings.push(`${missingExplicitReverseEdges.length} explicit reverse edge(s) are missing; current mapper may infer them, but strict rebuilds should handle this intentionally.`);

    const repairPreview = [];
    if (outlierNodes.length > 0) repairPreview.push({ action: 'quarantine_suspicious_nodes', count: outlierNodes.length, safety: 'requires backup and explicit repair command' });
    if (components.disconnected_components > 0) repairPreview.push({ action: 'review_disconnected_components', count: components.disconnected_components, safety: 'read-only report for now' });
    if (missingExplicitReverseEdges.length > 0) repairPreview.push({ action: 'derive_or_materialize_reverse_edges', count: missingExplicitReverseEdges.length, safety: 'future cache rebuild should decide whether to materialize or infer' });
    if (blockingIssues > 0) repairPreview.push({ action: 'repair_invalid_references', count: blockingIssues, safety: 'do not run automatically' });

    return {
        version: VERSION,
        backend: BACKEND,
        source_of_truth: SOURCE_OF_TRUTH,
        health,
        game_id: game.game_id,
        generated_at: new Date().toISOString(),
        source_of_truth_rules: {
            normalized_tsv: 'authoritative for navigation storage',
            raw_routes: 'legacy/import/debug files',
            map_graph_txt: 'derived cache, not the source of truth',
            coverage_report: 'read-only derived analysis'
        },
        audit: {
            counts: issueCounts,
            components: {
                total_components: components.total_components,
                main_component_size: components.main_component_size,
                disconnected_components: components.disconnected_components,
                small_components: components.small_components,
                component_sample: components.component_sample
            },
            samples: {
                suspicious_outlier_nodes: sample(outlierNodes, 30),
                duplicate_coordinates: sample(indexes.duplicateCoordinates, 30),
                invalid_nodes: sample(indexes.invalidNodes, 30),
                node_id_mismatches: sample(indexes.nodeIdMismatches, 30),
                edges_missing_from_node: sample(edgesMissingFrom, 20),
                edges_missing_to_node: sample(edgesMissingTo, 20),
                observations_referencing_missing_nodes: sample(observationsMissingNodes, 20),
                missing_explicit_reverse_edges: sample(missingExplicitReverseEdges, 30)
            }
        },
        repair_preview: repairPreview,
        warnings
    };
}

function coverageStatus() {
    const storage = status();
    const game = findLatestGameDir();
    if (!game) {
        return {
            version: VERSION,
            backend: BACKEND,
            source_of_truth: SOURCE_OF_TRUTH,
            health: 'missing',
            game_id: null,
            generated_at: new Date().toISOString(),
            coverage: { nodes: 0, explicit_scanned_directions: 0, effective_scanned_directions: 0, true_frontier_directions: 0, possible_holes: 0, missing_reverse_links: 0, dead_end_candidates: 0, explicit_coverage_percent: 0, effective_coverage_percent: 0 },
            frontier_sample: [],
            possible_holes_sample: [],
            missing_reverse_sample: [],
            dead_end_sample: [],
            warnings: ['No game-specific navigation folder found yet.']
        };
    }

    const rows = loadStorageRows(game);
    const indexes = buildIndexes(rows, game.game_id);
    const components = componentAnalysis(rows, indexes);
    const outlierNodes = detectOutlierNodes(rows, components, indexes);
    const suspiciousIds = new Set(outlierNodes.map(n => n.node_id).filter(Boolean));

    const frontiers = [];
    const holes = [];
    const missingReverse = [];
    const deadEnds = [];
    let explicitScannedDirections = 0;
    let effectiveScannedDirections = 0;
    let trueFrontierDirections = 0;
    let unscannedDirections = 0;

    for (const node of rows.nodes) {
        if (!node.node_id || suspiciousIds.has(node.node_id)) continue;
        const missing = [];
        const trueMissing = [];
        let explicitLocal = 0;
        let effectiveLocal = 0;
        let exits = 0;

        for (const direction of DIRECTIONS) {
            const key = scanKey(node.node_id, direction);
            const explicit = indexes.scanned.has(key);
            let effective = explicit;
            let neighbor = null;
            let reverseKey = '';

            const nKey = neighborKey(node, direction);
            const list = nKey && indexes.coordToNodes.get(nKey);
            if (list && list.length) {
                neighbor = list[0];
                reverseKey = scanKey(neighbor.node_id, OPPOSITE[direction]);
                if (!effective && indexes.scanned.has(reverseKey)) effective = true;
            }

            if (explicit) {
                explicitScannedDirections += 1;
                explicitLocal += 1;
                if (indexes.walkable.has(key) || indexes.transitionSet.has(key)) exits += 1;
            }
            if (effective) {
                effectiveScannedDirections += 1;
                effectiveLocal += 1;
            } else {
                unscannedDirections += 1;
                missing.push(direction);
                if (neighbor) {
                    holes.push({
                        node_id: node.node_id,
                        map_name: node.map_name || '',
                        map_header: node.map_header || '',
                        tile_x: node.tile_x,
                        tile_y: node.tile_y,
                        tile_z: node.tile_z,
                        direction,
                        neighbor_node_id: neighbor.node_id,
                        neighbor_tile_x: neighbor.tile_x,
                        neighbor_tile_z: neighbor.tile_z,
                        reason: 'adjacent known tile but neither direction has an edge/block/transition record'
                    });
                } else {
                    trueFrontierDirections += 1;
                    trueMissing.push(direction);
                }
            }

            if (!explicit && neighbor && indexes.scanned.has(reverseKey)) {
                missingReverse.push({
                    node_id: node.node_id,
                    map_name: node.map_name || '',
                    map_header: node.map_header || '',
                    tile_x: node.tile_x,
                    tile_y: node.tile_y,
                    tile_z: node.tile_z,
                    direction,
                    neighbor_node_id: neighbor.node_id,
                    neighbor_tile_x: neighbor.tile_x,
                    neighbor_tile_z: neighbor.tile_z,
                    reverse_direction: OPPOSITE[direction],
                    reason: 'reverse direction is known, so this is not a true hole; it is missing explicit reverse/scan data'
                });
            }
        }

        if (trueMissing.length || holes.some(h => h.node_id === node.node_id)) {
            frontiers.push({
                node_id: node.node_id,
                map_name: node.map_name || '',
                map_header: node.map_header || '',
                tile_x: node.tile_x,
                tile_y: node.tile_y,
                tile_z: node.tile_z,
                true_frontier_directions: trueMissing,
                missing_directions: missing,
                explicit_scanned_directions: explicitLocal,
                effective_scanned_directions: effectiveLocal
            });
        }
        if (effectiveLocal >= 4 && exits <= 1) {
            deadEnds.push({
                node_id: node.node_id,
                map_name: node.map_name || '',
                map_header: node.map_header || '',
                tile_x: node.tile_x,
                tile_y: node.tile_y,
                tile_z: node.tile_z,
                walkable_exits: exits,
                reason: exits === 0 ? 'fully scanned isolated node' : 'fully scanned node with only one exit'
            });
        }
    }

    frontiers.sort((a, b) => (b.true_frontier_directions.length - a.true_frontier_directions.length) || (b.missing_directions.length - a.missing_directions.length) || String(a.node_id).localeCompare(String(b.node_id)));
    holes.sort((a, b) => String(a.node_id).localeCompare(String(b.node_id)) || String(a.direction).localeCompare(String(b.direction)));
    missingReverse.sort((a, b) => String(a.node_id).localeCompare(String(b.node_id)) || String(a.direction).localeCompare(String(b.direction)));

    const totalDirections = (rows.nodes.length - suspiciousIds.size) * DIRECTIONS.length;
    const explicitCoveragePercent = totalDirections > 0 ? Math.round((explicitScannedDirections / totalDirections) * 1000) / 10 : 0;
    const effectiveCoveragePercent = totalDirections > 0 ? Math.round((effectiveScannedDirections / totalDirections) * 1000) / 10 : 0;
    const warnings = [...(storage.warnings || [])];
    if (holes.length > 0) warnings.push(`${holes.length} true possible hole(s) found after reverse-link classification.`);
    if (frontiers.length > 0) warnings.push(`${frontiers.length} frontier node(s) still have true unscanned directions or possible holes.`);
    if (outlierNodes.length > 0) warnings.push(`${outlierNodes.length} suspicious node(s) excluded from effective coverage math. Review /api/nav_integrity.`);

    return {
        version: VERSION,
        backend: BACKEND,
        source_of_truth: SOURCE_OF_TRUTH,
        health: storage.health || 'unknown',
        game_id: game.game_id,
        generated_at: new Date().toISOString(),
        coverage: {
            nodes: rows.nodes.length,
            suspicious_nodes_excluded: suspiciousIds.size,
            walkable_edges: rows.edges.length,
            blocked_directions: rows.blocked.length,
            transitions: rows.transitions.length,
            observations: rows.observations.length,
            total_node_directions: totalDirections,
            explicit_scanned_directions: explicitScannedDirections,
            effective_scanned_directions: effectiveScannedDirections,
            unscanned_directions: unscannedDirections,
            true_frontier_directions: trueFrontierDirections,
            frontier_nodes: frontiers.length,
            possible_holes: holes.length,
            missing_reverse_links: missingReverse.length,
            dead_end_candidates: deadEnds.length,
            explicit_coverage_percent: explicitCoveragePercent,
            effective_coverage_percent: effectiveCoveragePercent,
            coverage_percent: effectiveCoveragePercent
        },
        classification: {
            true_frontier: 'no adjacent known tile and no scan record yet',
            possible_hole: 'adjacent known tile exists, but neither direction has a scan/edge/block/transition record',
            missing_reverse_link: 'reverse direction is known, so the missing direction is probably derived/inferred rather than a real hole',
            suspicious_node: 'excluded from effective coverage math until reviewed'
        },
        component_summary: {
            total_components: components.total_components,
            main_component_size: components.main_component_size,
            disconnected_components: components.disconnected_components,
            small_components: components.small_components
        },
        frontier_sample: sample(frontiers, 40),
        possible_holes_sample: sample(holes, 40),
        missing_reverse_sample: sample(missingReverse, 40),
        dead_end_sample: sample(deadEnds, 20),
        warnings
    };
}

function makeBackup(reason) {
    ensureDir(NAV_DIR);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const backupDir = path.join(NAV_DIR, 'backups', `nav-backup-${stamp}`);
    ensureDir(backupDir);

    const game = findLatestGameDir();
    const copied = [];
    const copyFile = (src, relName) => {
        const stat = safeStat(src);
        if (!stat || !stat.isFile()) return;
        const dest = path.join(backupDir, relName);
        ensureDir(path.dirname(dest));
        fs.copyFileSync(src, dest);
        copied.push(relName.replace(/\\/g, '/'));
    };

    if (game) {
        for (const table of TABLES) copyFile(path.join(game.dir, table.name + '.tsv'), path.join('games', game.game_id, table.name + '.tsv'));
    }
    for (const name of ['map_graph.txt', 'map_sweep_edges.txt', 'map_nodes.txt', 'routes_index.txt']) {
        copyFile(path.join(ROUTES_DIR, name), path.join('routes', name));
    }

    fs.writeFileSync(path.join(backupDir, 'backup_info.json'), JSON.stringify({
        created_at: new Date().toISOString(),
        reason: reason || 'manual',
        storage_backend: BACKEND,
        source_of_truth: SOURCE_OF_TRUTH,
        copied
    }, null, 2), 'utf8');

    return { backup_dir: rel(backupDir), copied };
}


function backupRoot() {
    const root = path.join(NAV_DIR, 'backups');
    ensureDir(root);
    return root;
}

function quarantineRoot(gameId) {
    const root = path.join(NAV_DIR, 'games', gameId || 'unknown', 'quarantine');
    ensureDir(root);
    return root;
}

function safeResolveUnder(root, maybePath) {
    const resolvedRoot = path.resolve(root);
    const resolved = path.resolve(PROJECT_ROOT, maybePath || '');
    if (resolved === resolvedRoot || resolved.startsWith(resolvedRoot + path.sep)) return resolved;

    const direct = path.resolve(maybePath || '');
    if (direct === resolvedRoot || direct.startsWith(resolvedRoot + path.sep)) return direct;
    return null;
}

function listBackups() {
    const root = backupRoot();
    const out = [];
    for (const name of fs.readdirSync(root)) {
        const full = path.join(root, name);
        const stat = safeStat(full);
        if (!stat || !stat.isDirectory()) continue;
        let info = null;
        try {
            info = JSON.parse(fs.readFileSync(path.join(full, 'backup_info.json'), 'utf8'));
        } catch (_err) {
            info = null;
        }
        out.push({
            name,
            path: rel(full),
            created_at: info && info.created_at ? info.created_at : stat.mtime.toISOString(),
            reason: info && info.reason ? info.reason : 'unknown',
            copied: info && Array.isArray(info.copied) ? info.copied.length : 0,
            storage_backend: info && info.storage_backend ? info.storage_backend : BACKEND,
            source_of_truth: info && info.source_of_truth ? info.source_of_truth : SOURCE_OF_TRUTH
        });
    }
    out.sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    return {
        version: VERSION,
        backup_root: rel(root),
        count: out.length,
        backups: out
    };
}

function readTsvWithHeader(filePath) {
    const parsed = parseTsvObjects(filePath);
    return { header: parsed.header, rows: parsed.rows };
}

function writeTsvObjects(filePath, header, rows) {
    ensureDir(path.dirname(filePath));
    const cols = header && header.length ? header : [];
    const lines = [cols.join('\t')];
    for (const row of rows) {
        lines.push(cols.map(name => row[name] !== undefined && row[name] !== null ? String(row[name]) : '').join('\t'));
    }

    // v40.9 inherited: write through a temporary file first so repair/restore operations do
    // not leave a half-written TSV if the process is interrupted mid-write.
    const tmpPath = filePath + `.tmp-${process.pid}-${Date.now()}`;
    fs.writeFileSync(tmpPath, lines.join('\n') + '\n', 'utf8');
    fs.renameSync(tmpPath, filePath);
}

function writeTsvQuarantine(filePath, header, rows) {
    if (!rows.length) return false;
    writeTsvObjects(filePath, header, rows);
    return true;
}

function createRepairPreview() {
    const integrity = integrityStatus();
    const backups = listBackups();
    const actions = [];
    const counts = integrity.audit && integrity.audit.counts ? integrity.audit.counts : {};

    if ((counts.suspicious_outlier_nodes || 0) > 0) {
        actions.push({
            id: 'quarantine_suspicious_nodes',
            label: 'Quarantine suspicious/outlier nodes',
            count: counts.suspicious_outlier_nodes,
            destructive: true,
            requires_backup: true,
            requires_confirm: true,
            endpoint: '/api/nav_repair_quarantine_suspicious',
            method: 'POST',
            description: 'Moves placeholder/outlier node records and dependent records into quarantine files, then rewrites TSV tables without those records.'
        });
    }

    if ((counts.disconnected_components || 0) > 0) {
        actions.push({
            id: 'review_disconnected_components',
            label: 'Review disconnected components',
            count: counts.disconnected_components,
            destructive: false,
            requires_backup: false,
            requires_confirm: false,
            endpoint: '/api/nav_integrity',
            method: 'GET',
            description: 'Read-only for now. Disconnected components may be real explored islands or areas that are not linked yet.'
        });
    }

    if ((counts.missing_explicit_reverse_edges || 0) > 0) {
        actions.push({
            id: 'reverse_edge_policy_review',
            label: 'Review reverse edge policy',
            count: counts.missing_explicit_reverse_edges,
            destructive: false,
            requires_backup: false,
            requires_confirm: false,
            endpoint: '/api/nav_integrity',
            method: 'GET',
            description: 'Current mapper can infer reverse movement. Future cache rebuilds should decide whether to infer or materialize reverse edges.'
        });
    }

    return {
        version: VERSION,
        backend: BACKEND,
        source_of_truth: SOURCE_OF_TRUTH,
        health: integrity.health,
        game_id: integrity.game_id,
        generated_at: new Date().toISOString(),
        backup_available: backups.count > 0,
        latest_backup: backups.backups[0] || null,
        actions,
        repair_preview: integrity.repair_preview || [],
        warnings: integrity.warnings || []
    };
}

function quarantineSuspiciousNodes(options) {
    options = options || {};
    const confirm = options.confirm === true || options.confirm === 'true';
    const dryRun = !confirm || options.dry_run === true || options.dry_run === 'true';
    const integrity = integrityStatus();
    const game = findLatestGameDir();
    const suspicious = integrity.audit && integrity.audit.samples && integrity.audit.samples.suspicious_outlier_nodes ? integrity.audit.samples.suspicious_outlier_nodes : [];
    const suspiciousIds = new Set(suspicious.map(n => n.node_id).filter(Boolean));

    if (!game) {
        return { version: VERSION, ok: false, dry_run: dryRun, error: 'No game-specific navigation folder found.' };
    }
    if (suspiciousIds.size === 0) {
        return { version: VERSION, ok: true, dry_run: dryRun, action: 'quarantine_suspicious_nodes', changed: false, message: 'No suspicious nodes found.' };
    }

    const affected = {
        nodes: [],
        edges: [],
        blocked: [],
        transitions: [],
        observations: []
    };
    const kept = {};
    const loaded = {};

    for (const table of TABLES) {
        const filePath = path.join(game.dir, table.name + '.tsv');
        loaded[table.name] = readTsvWithHeader(filePath);
    }

    const touchesSuspicious = (row) => {
        return suspiciousIds.has(row.node_id) || suspiciousIds.has(row.from_node_id) || suspiciousIds.has(row.to_node_id);
    };

    for (const table of TABLES) {
        const rows = loaded[table.name].rows;
        affected[table.name] = rows.filter(touchesSuspicious);
        kept[table.name] = rows.filter(row => !touchesSuspicious(row));
    }

    const changedCount = Object.values(affected).reduce((sum, list) => sum + list.length, 0);
    const preview = {
        nodes: affected.nodes.length,
        edges: affected.edges.length,
        blocked: affected.blocked.length,
        transitions: affected.transitions.length,
        observations: affected.observations.length,
        total_records: changedCount
    };

    if (dryRun) {
        return {
            version: VERSION,
            ok: true,
            dry_run: true,
            action: 'quarantine_suspicious_nodes',
            game_id: game.game_id,
            suspicious_node_ids: [...suspiciousIds],
            would_quarantine: preview,
            note: 'No files changed. POST with data={"confirm":true} to run after reviewing the preview.'
        };
    }

    const backup = makeBackup(options.reason || 'before_quarantine_suspicious_nodes');
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const qDir = path.join(quarantineRoot(game.game_id), `quarantine-${stamp}`);
    ensureDir(qDir);

    for (const table of TABLES) {
        writeTsvQuarantine(path.join(qDir, table.name + '.tsv'), loaded[table.name].header, affected[table.name]);
        writeTsvObjects(path.join(game.dir, table.name + '.tsv'), loaded[table.name].header, kept[table.name]);
    }

    fs.writeFileSync(path.join(qDir, 'quarantine_info.json'), JSON.stringify({
        created_at: new Date().toISOString(),
        action: 'quarantine_suspicious_nodes',
        reason: options.reason || 'explicit repair action',
        backup_dir: backup.backup_dir,
        suspicious_node_ids: [...suspiciousIds],
        affected_records: preview,
        safety: 'Records were moved to quarantine files, not permanently deleted.'
    }, null, 2), 'utf8');

    return {
        version: VERSION,
        ok: true,
        dry_run: false,
        action: 'quarantine_suspicious_nodes',
        game_id: game.game_id,
        backup,
        quarantine_dir: rel(qDir),
        suspicious_node_ids: [...suspiciousIds],
        quarantined: preview,
        storage_after: status(),
        integrity_after: integrityStatus()
    };
}

function restoreBackup(backupPath, options) {
    options = options || {};
    const confirm = options.confirm === true || options.confirm === 'true';
    if (!confirm) {
        return {
            version: VERSION,
            ok: false,
            dry_run: true,
            error: 'Restore requires confirm=true.',
            note: 'POST /api/nav_restore_backup with data={"backup_path":"user/nav/backups/...","confirm":true}'
        };
    }

    const root = backupRoot();
    const resolved = safeResolveUnder(root, backupPath);
    if (!resolved) {
        return { version: VERSION, ok: false, error: 'Invalid backup path. Backup must be inside user/nav/backups.' };
    }
    const stat = safeStat(resolved);
    if (!stat || !stat.isDirectory()) {
        return { version: VERSION, ok: false, error: 'Backup folder not found.' };
    }

    const beforeRestoreBackup = makeBackup('before_restore_backup');
    const restored = [];
    const gamesDir = path.join(resolved, 'games');
    const routesDir = path.join(resolved, 'routes');

    if (safeStat(gamesDir) && safeStat(gamesDir).isDirectory()) {
        for (const gameId of fs.readdirSync(gamesDir)) {
            const srcGame = path.join(gamesDir, gameId);
            const srcStat = safeStat(srcGame);
            if (!srcStat || !srcStat.isDirectory()) continue;
            const destGame = path.join(GAMES_DIR, gameId);
            ensureDir(destGame);
            for (const table of TABLES) {
                const src = path.join(srcGame, table.name + '.tsv');
                const srcFile = safeStat(src);
                if (srcFile && srcFile.isFile()) {
                    const dest = path.join(destGame, table.name + '.tsv');
                    fs.copyFileSync(src, dest);
                    restored.push(rel(dest));
                }
            }
        }
    }

    if (safeStat(routesDir) && safeStat(routesDir).isDirectory()) {
        ensureDir(ROUTES_DIR);
        for (const name of fs.readdirSync(routesDir)) {
            const src = path.join(routesDir, name);
            const srcFile = safeStat(src);
            if (srcFile && srcFile.isFile()) {
                const dest = path.join(ROUTES_DIR, name);
                fs.copyFileSync(src, dest);
                restored.push(rel(dest));
            }
        }
    }

    return {
        version: VERSION,
        ok: true,
        action: 'restore_backup',
        restored_from: rel(resolved),
        safety_backup_before_restore: beforeRestoreBackup,
        restored_files: restored,
        storage_after: status(),
        integrity_after: integrityStatus()
    };
}


function listQuarantines() {
    const game = findLatestGameDir();
    if (!game) {
        return {
            version: VERSION,
            game_id: null,
            quarantine_root: null,
            count: 0,
            quarantines: [],
            warnings: ['No game-specific navigation folder found yet.']
        };
    }

    const root = quarantineRoot(game.game_id);
    const out = [];
    for (const name of fs.readdirSync(root)) {
        const full = path.join(root, name);
        const stat = safeStat(full);
        if (!stat || !stat.isDirectory()) continue;
        let info = null;
        try {
            info = JSON.parse(fs.readFileSync(path.join(full, 'quarantine_info.json'), 'utf8'));
        } catch (_err) {
            info = null;
        }
        const table_counts = {};
        for (const table of TABLES) {
            table_counts[table.name] = analyzeTsv(path.join(full, table.name + '.tsv'), table.keyColumn).records;
        }
        out.push({
            name,
            path: rel(full),
            created_at: info && info.created_at ? info.created_at : stat.mtime.toISOString(),
            action: info && info.action ? info.action : 'unknown',
            reason: info && info.reason ? info.reason : 'unknown',
            backup_dir: info && info.backup_dir ? info.backup_dir : null,
            suspicious_node_ids: info && Array.isArray(info.suspicious_node_ids) ? info.suspicious_node_ids : [],
            affected_records: info && info.affected_records ? info.affected_records : table_counts,
            table_counts,
            safety: info && info.safety ? info.safety : 'Quarantine files are retained for review.'
        });
    }
    out.sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    return {
        version: VERSION,
        game_id: game.game_id,
        quarantine_root: rel(root),
        count: out.length,
        quarantines: out
    };
}

function derivedCacheRebuildPreview(options) {
    options = options || {};
    const game = findLatestGameDir();
    if (!game) {
        return {
            version: VERSION,
            ok: false,
            dry_run: true,
            action: 'derived_cache_rebuild_preview',
            error: 'No game-specific navigation folder found yet.'
        };
    }

    const rows = loadStorageRows(game);
    const storage = status();
    const integrity = integrityStatus();
    const coverage = coverageStatus();
    const counts = integrity.audit && integrity.audit.counts ? integrity.audit.counts : {};
    const suspiciousCount = counts.suspicious_outlier_nodes || 0;
    const missingReverseCount = counts.missing_explicit_reverse_edges || 0;
    const blockingIssues = (counts.invalid_nodes || 0)
        + (counts.node_id_mismatches || 0)
        + (counts.edges_missing_from_node || 0)
        + (counts.edges_missing_to_node || 0)
        + (counts.transitions_missing_from_node || 0)
        + (counts.observations_referencing_missing_nodes || 0);

    const rawGraph = storage.raw_routes && storage.raw_routes['map_graph.txt'] ? storage.raw_routes['map_graph.txt'] : null;
    const policy = (options.reverse_edge_policy || 'infer_in_derived_cache');
    const wouldInferReverse = policy !== 'explicit_only';
    const effectiveTravelEdges = rows.edges.length + (wouldInferReverse ? missingReverseCount : 0);

    const warnings = [];
    if (blockingIssues > 0) warnings.push(`${blockingIssues} blocking integrity issue(s) should be fixed before rebuilding derived cache.`);
    if (suspiciousCount > 0) warnings.push(`${suspiciousCount} suspicious node(s) still active. Quarantine them before trusting a rebuilt cache.`);
    if (counts.disconnected_components > 0) warnings.push(`${counts.disconnected_components} disconnected component(s) will remain disconnected in a derived rebuild unless future learning connects them.`);
    if (missingReverseCount > 0 && wouldInferReverse) warnings.push(`${missingReverseCount} reverse edge(s) would be inferred in the derived cache, not materialized in normalized TSV.`);

    return {
        version: VERSION,
        ok: blockingIssues === 0,
        dry_run: true,
        action: 'derived_cache_rebuild_preview',
        game_id: game.game_id,
        source_of_truth: SOURCE_OF_TRUTH,
        target_cache: 'user/routes/map_graph.txt',
        source_tables: {
            nodes: 'user/nav/games/' + game.game_id + '/nodes.tsv',
            edges: 'user/nav/games/' + game.game_id + '/edges.tsv',
            blocked: 'user/nav/games/' + game.game_id + '/blocked.tsv',
            transitions: 'user/nav/games/' + game.game_id + '/transitions.tsv'
        },
        current_cache: rawGraph,
        policy: {
            normalized_tsv_is_authority: true,
            raw_routes_are_legacy_debug: true,
            reverse_edge_policy: policy,
            inferred_reverse_edges_written_to_tsv: false,
            suspicious_nodes: suspiciousCount > 0 ? 'warn_and_require_review' : 'none_detected'
        },
        would_build: {
            nodes: rows.nodes.length,
            suspicious_nodes_active: suspiciousCount,
            observed_walkable_edges: rows.edges.length,
            inferred_reverse_edges: wouldInferReverse ? missingReverseCount : 0,
            effective_travel_edges: effectiveTravelEdges,
            blocked_directions: rows.blocked.length,
            transitions: rows.transitions.length,
            disconnected_components: counts.disconnected_components || 0,
            possible_holes: coverage.coverage ? coverage.coverage.possible_holes : 0,
            frontier_nodes: coverage.coverage ? coverage.coverage.frontier_nodes : 0
        },
        safety: {
            files_changed: false,
            backup_required_before_real_rebuild: true,
            rebuild_is_preview_only_in_v39_7: true,
            next_step: 'After the v40 storage gate stays clean, keep cache rebuild execution behind developer tools until archive/reset is safe.'
        },
        warnings
    };
}

function stressTestPlan() {
    return {
        version: VERSION,
        name: 'Navigation Storage + Learn Current Area Stress Test Plan',
        purpose: 'Try to break storage, coverage, repair safety, and Learn Current Area before full map builds.',
        rules: [
            'Start every destructive/repair test with a backup.',
            'Use small action counts first, then increase only after logs look clean.',
            'After every run, check /api/nav_integrity, /api/nav_coverage, and /api/nav_stress_snapshot.',
            'Treat current Route 34 data as disposable test data until the Baritone-lite learner is ready.',
            'Do not judge map quality only by coverage percent; inspect holes, frontiers, components, and bad records.'
        ],
        phases: [
            {
                id: 'storage_safety_preflight',
                label: 'Storage safety preflight',
                steps: [
                    'GET /api/version and confirm v40.9.',
                    'GET /api/nav_storage and confirm backend=tsv_compat and sqlite.required=false.',
                    'GET /api/nav_backups and confirm at least one backup exists.',
                    'GET /api/nav_selftest and record status.'
                ],
                pass: 'No blocking integrity failures, dashboard does not crash, and selftest returns pass or needs_review.'
            },
            {
                id: 'repair_body_post_test',
                label: 'POST body repair test',
                steps: [
                    'Run quarantine suspicious repair with a JSON POST body, not a query string.',
                    'Confirm the response is not dry_run when confirm=true is posted.',
                    'GET /api/nav_quarantine and confirm the quarantined records are visible.',
                    'GET /api/nav_integrity and confirm suspicious_outlier_nodes drops to 0 if repair ran.'
                ],
                pass: 'JSON POST body is honored and repair remains backup-protected.'
            },
            {
                id: 'learn_current_area_small',
                label: 'Learn Current Area small run',
                steps: [
                    'Run Learn Current Area / Map Explore Area with 3 actions.',
                    'Do not manually correct movement during the run.',
                    'After it ends, check logs for battles, stuck movement, repeated same probe, bad node writes, or PERF spikes.',
                    'GET /api/nav_stress_snapshot and compare counts before/after.'
                ],
                pass: 'No crash, no bad placeholder node, observations increase only when real probes happen.'
            },
            {
                id: 'boundary_wall_rub',
                label: 'Boundary and wall-rub test',
                steps: [
                    'Place player beside walls, fences, corners, grass boundaries, and narrow paths.',
                    'Run 3-10 actions.',
                    'Watch for repeated blocked direction spam, soft-boundary wall-rubbing, or fake walkable edges.',
                    'Check possible_holes and blocked_directions after the run.'
                ],
                pass: 'Blocked directions are recorded cleanly and the bot does not repeatedly grind the same wall.'
            },
            {
                id: 'battle_interruption',
                label: 'Battle interruption test',
                steps: [
                    'Run mapping in grass until a wild battle triggers.',
                    'Confirm original Random Encounters flow handles the battle.',
                    'Confirm mapping resumes or stops cleanly according to the task settings.',
                    'Check latest.log for unresolved_battles, battle bridge errors, or duplicate observation writes.'
                ],
                pass: 'Battle handling stays bridged into original PokéBot flow and storage is not corrupted by the interruption.'
            },
            {
                id: 'transition_and_disconnected',
                label: 'Transition and disconnected component test',
                steps: [
                    'Approach gates, doors, route borders, or map transitions only after normal route walking is stable.',
                    'Use low action counts.',
                    'Check transitions.tsv and component_summary after the run.',
                    'Do not auto-delete disconnected components; classify first.'
                ],
                pass: 'Transitions are detected intentionally or left unmodified; no fake connection is created.'
            }
        ],
        break_conditions: [
            'New placeholder/outlier nodes appear.',
            'edges_missing_from_node or edges_missing_to_node becomes nonzero.',
            'observations_referencing_missing_nodes becomes nonzero.',
            'The bot repeats the same useless move without learning or blocking it.',
            'A battle leaves the bot stuck or causes duplicate/corrupt storage writes.',
            'Dashboard and Lua disagree on version/backend/storage counts.'
        ],
        endpoints_to_collect_after_each_run: [
            '/api/nav_storage',
            '/api/nav_integrity',
            '/api/nav_coverage',
            '/api/nav_repair_preview',
            '/api/nav_stress_snapshot'
        ]
    };
}


function sanitizeLabel(label) {
    return String(label || 'manual').replace(/[^a-z0-9_-]+/gi, '_').replace(/^_+|_+$/g, '').slice(0, 48) || 'manual';
}

function stressRoot() {
    ensureDir(STRESS_DIR);
    return STRESS_DIR;
}

function compactStressSnapshot(label) {
    const storage = status();
    const integrity = integrityStatus();
    const coverage = coverageStatus();
    const backups = listBackups();
    const quarantines = listQuarantines();
    const rebuild = derivedCacheRebuildPreview();
    const drift = driftReport();
    const componentClasses = componentClassification();
    const counts = integrity.audit && integrity.audit.counts ? integrity.audit.counts : {};
    const coverageCounts = coverage.coverage || {};
    const tableSummary = {};

    for (const table of TABLES) {
        const info = storage.tables && storage.tables[table.name] ? storage.tables[table.name] : null;
        tableSummary[table.name] = info ? {
            records: info.records,
            duplicate_keys: info.duplicate_keys,
            bytes: info.bytes,
            modified_at: info.modified_at
        } : null;
    }

    return {
        version: VERSION,
        label: label || 'snapshot',
        created_at: new Date().toISOString(),
        game_id: storage.game_id,
        backend: storage.backend,
        source_of_truth: storage.source_of_truth,
        storage_health: storage.health,
        integrity_health: integrity.health,
        coverage_health: coverage.health,
        counts: Object.assign({}, storage.counts || {}),
        integrity_counts: Object.assign({}, counts),
        coverage_counts: Object.assign({}, coverageCounts),
        tables: tableSummary,
        raw_routes: storage.raw_routes || {},
        backups: backups.count,
        latest_backup: backups.backups && backups.backups[0] ? backups.backups[0] : null,
        quarantines: quarantines.count,
        latest_quarantine: quarantines.quarantines && quarantines.quarantines[0] ? quarantines.quarantines[0] : null,
        derived_cache_preview: rebuild && rebuild.would_build ? rebuild.would_build : null,
        last_observation_at: storage.last_observation_at || null,
        warnings: {
            storage: storage.warnings || [],
            integrity: integrity.warnings || [],
            coverage: coverage.warnings || []
        }
    };
}

function createStressBaseline(options) {
    options = options || {};
    const label = sanitizeLabel(options.label || options.name || 'baseline');
    const root = stressRoot();
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const filePath = path.join(root, `stress-${stamp}-${label}.json`);
    const snap = compactStressSnapshot(label);
    snap.kind = 'stress_baseline';
    snap.note = 'Use this as the before snapshot. After the in-game run, call /api/nav_stress_compare to compare current storage against this baseline.';
    fs.writeFileSync(filePath, JSON.stringify(snap, null, 2), 'utf8');
    return {
        version: VERSION,
        ok: true,
        action: 'create_stress_baseline',
        path: rel(filePath),
        baseline: snap,
        next_steps: [
            'Run the in-game Learn Current Area stress scenario.',
            'Do not manually correct movement during the run unless the bot is hard-stuck.',
            'Then call /api/nav_stress_compare and /api/nav_selftest.'
        ]
    };
}

function listStressBaselines() {
    const root = stressRoot();
    const out = [];
    for (const name of fs.readdirSync(root)) {
        if (!/\.json$/i.test(name)) continue;
        const full = path.join(root, name);
        const stat = safeStat(full);
        if (!stat || !stat.isFile()) continue;
        let data = null;
        try {
            data = JSON.parse(fs.readFileSync(full, 'utf8'));
        } catch (_err) {
            data = null;
        }
        out.push({
            name,
            path: rel(full),
            created_at: data && data.created_at ? data.created_at : stat.mtime.toISOString(),
            label: data && data.label ? data.label : 'unknown',
            game_id: data && data.game_id ? data.game_id : null,
            backend: data && data.backend ? data.backend : null,
            nodes: data && data.counts ? data.counts.nodes : null,
            edges: data && data.counts ? data.counts.edges : null,
            observations: data && data.counts ? data.counts.observations : null,
            suspicious_outlier_nodes: data && data.integrity_counts ? data.integrity_counts.suspicious_outlier_nodes : null,
            disconnected_components: data && data.integrity_counts ? data.integrity_counts.disconnected_components : null,
            coverage_percent: data && data.coverage_counts ? data.coverage_counts.coverage_percent : null
        });
    }
    out.sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    return {
        version: VERSION,
        root: rel(root),
        count: out.length,
        baselines: out
    };
}

function latestStressBaseline() {
    const list = listStressBaselines();
    if (!list.baselines.length) return null;
    const full = path.resolve(PROJECT_ROOT, list.baselines[0].path);
    try {
        return JSON.parse(fs.readFileSync(full, 'utf8'));
    } catch (_err) {
        return null;
    }
}

function numericDelta(beforeObj, afterObj) {
    const out = {};
    const keys = new Set(Object.keys(beforeObj || {}).concat(Object.keys(afterObj || {})));
    for (const key of keys) {
        const before = Number((beforeObj || {})[key]);
        const after = Number((afterObj || {})[key]);
        if (!Number.isFinite(before) && !Number.isFinite(after)) continue;
        out[key] = {
            before: Number.isFinite(before) ? before : null,
            after: Number.isFinite(after) ? after : null,
            delta: (Number.isFinite(after) ? after : 0) - (Number.isFinite(before) ? before : 0)
        };
    }
    return out;
}

function stressCompare() {
    const before = latestStressBaseline();
    const after = compactStressSnapshot('after_current_state');
    if (!before) {
        return {
            version: VERSION,
            ok: false,
            status: 'missing_baseline',
            error: 'No stress baseline found.',
            next_step: 'POST /api/nav_stress_baseline_create with optional data={"label":"before_wall_test"}, then run the in-game scenario and call /api/nav_stress_compare.'
        };
    }

    const countDelta = numericDelta(before.counts, after.counts);
    const integrityDelta = numericDelta(before.integrity_counts, after.integrity_counts);
    const coverageDelta = numericDelta(before.coverage_counts, after.coverage_counts);
    const tableDelta = {};
    for (const table of TABLES) {
        const b = before.tables && before.tables[table.name] ? before.tables[table.name] : {};
        const a = after.tables && after.tables[table.name] ? after.tables[table.name] : {};
        tableDelta[table.name] = numericDelta({ records: b.records, duplicate_keys: b.duplicate_keys, bytes: b.bytes }, { records: a.records, duplicate_keys: a.duplicate_keys, bytes: a.bytes });
    }

    const checks = [];
    const add = (id, label, severity, pass, detail) => checks.push({ id, label, severity, pass: !!pass, detail });
    const afterIntegrity = after.integrity_counts || {};
    const afterTables = after.tables || {};

    add('backend_stable', 'Backend stayed TSV-only', 'required', before.backend === BACKEND && after.backend === BACKEND, { before: before.backend, after: after.backend });
    add('game_stable', 'Game folder stayed stable', 'required', before.game_id === after.game_id, { before: before.game_id, after: after.game_id });
    add('no_suspicious_nodes', 'No new suspicious/outlier nodes appeared', 'required', (afterIntegrity.suspicious_outlier_nodes || 0) === 0, { before: before.integrity_counts ? before.integrity_counts.suspicious_outlier_nodes : null, after: afterIntegrity.suspicious_outlier_nodes || 0 });
    add('no_bad_references', 'No missing node references appeared', 'required', ((afterIntegrity.edges_missing_from_node || 0) + (afterIntegrity.edges_missing_to_node || 0) + (afterIntegrity.transitions_missing_from_node || 0) + (afterIntegrity.observations_referencing_missing_nodes || 0)) === 0, afterIntegrity);
    add('no_invalid_nodes', 'No invalid nodes or node_id mismatches appeared', 'required', ((afterIntegrity.invalid_nodes || 0) + (afterIntegrity.node_id_mismatches || 0)) === 0, afterIntegrity);
    add('no_duplicate_keys', 'No duplicate TSV keys appeared', 'required', TABLES.every(t => !afterTables[t.name] || (afterTables[t.name].duplicate_keys || 0) === 0), Object.fromEntries(TABLES.map(t => [t.name, afterTables[t.name] ? afterTables[t.name].duplicate_keys : null])));
    add('counts_not_negative', 'Core record counts did not unexpectedly drop', 'warning', ['nodes', 'edges', 'blocked', 'observations'].every(k => !countDelta[k] || countDelta[k].delta >= 0), countDelta);
    add('observations_moved', 'Observation count changed during the test run', 'info', !!countDelta.observations && countDelta.observations.delta !== 0, countDelta.observations || null);
    add('coverage_available', 'Coverage report remained available', 'required', typeof after.coverage_counts.coverage_percent === 'number', after.coverage_counts);
    add('components_tracked', 'Disconnected components are tracked, not auto-deleted', 'info', true, { before: before.integrity_counts ? before.integrity_counts.disconnected_components : null, after: afterIntegrity.disconnected_components || 0 });
    add('reverse_policy_stable', 'Reverse-edge policy remains infer-in-derived-cache', 'info', true, { before: before.integrity_counts ? before.integrity_counts.missing_explicit_reverse_edges : null, after: afterIntegrity.missing_explicit_reverse_edges || 0 });

    const requiredFailed = checks.filter(c => c.severity === 'required' && !c.pass);
    const warningFailed = checks.filter(c => c.severity === 'warning' && !c.pass);
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: requiredFailed.length ? 'fail' : (warningFailed.length ? 'needs_review' : 'pass'),
        required_failed: requiredFailed.length,
        warnings_failed: warningFailed.length,
        baseline: {
            label: before.label,
            created_at: before.created_at,
            game_id: before.game_id,
            nodes: before.counts ? before.counts.nodes : null,
            edges: before.counts ? before.counts.edges : null,
            observations: before.counts ? before.counts.observations : null
        },
        current: {
            created_at: after.created_at,
            game_id: after.game_id,
            nodes: after.counts ? after.counts.nodes : null,
            edges: after.counts ? after.counts.edges : null,
            observations: after.counts ? after.counts.observations : null
        },
        checks,
        deltas: {
            counts: countDelta,
            integrity_counts: integrityDelta,
            coverage_counts: coverageDelta,
            tables: tableDelta
        },
        interpretation: [
            'pass means the storage layer survived this run without corruption signals.',
            'needs_review means the run may still be useful, but inspect the warning checks and logs.',
            'fail means stop testing and inspect latest.log, previous.log, nav_integrity, and nav_stress_snapshot before continuing.'
        ],
        endpoints_to_collect: [
            '/api/nav_storage',
            '/api/nav_integrity',
            '/api/nav_coverage',
            '/api/nav_selftest',
            '/api/nav_stress_snapshot'
        ]
    };
}

function stressRunbook() {
    return {
        version: VERSION,
        name: 'v40.9 Developer Stress Runbook',
        purpose: 'Run repeatable before/after tests that try to break Learn Current Area and prove storage stays clean.',
        exact_order: [
            'GET /api/version and confirm v40.9.',
            'GET /api/nav_selftest and confirm required_failed=0.',
            'POST /api/nav_stress_baseline_create with data={"label":"before_<scenario>"}.',
            'Run one in-game scenario using Learn Current Area.',
            'Do not manually correct the player unless the bot is truly hard-stuck.',
            'GET /api/nav_stress_compare.',
            'GET /api/nav_stress_snapshot.',
            'Copy latest.log if nav_stress_compare fails or needs review.'
        ],
        scenarios: [
            {
                id: 'open_route_3_actions',
                max_actions: 3,
                setup: 'Stand on normal walkable route tiles with no immediate wall pressure.',
                goal: 'Basic sanity: observations/edges can increase without corruption.'
            },
            {
                id: 'wall_corner_3_to_10_actions',
                max_actions: '3 then 10',
                setup: 'Stand beside fences, corners, trees, and narrow path edges.',
                goal: 'Prove blocked movement is recorded and the bot does not grind the same wall forever.'
            },
            {
                id: 'grass_battle_interrupt',
                max_actions: 'until battle or 10 actions',
                setup: 'Stand in grass where wild encounters can interrupt movement.',
                goal: 'Prove original Random Encounters battle bridge still handles battle flow and storage is not corrupted.'
            },
            {
                id: 'restart_resume',
                max_actions: 3,
                setup: 'Create a baseline, run a few actions, stop Lua/dashboard, restart, then compare.',
                goal: 'Prove TSV source-of-truth survives restarts and dashboard snapshots remain consistent.'
            },
            {
                id: 'frontier_probe',
                max_actions: 10,
                setup: 'Start near known frontier tiles from /api/nav_coverage frontier_sample.',
                goal: 'Prove frontier probing changes coverage logically without suspicious nodes or missing references.'
            }
        ],
        hard_fail_conditions: [
            'suspicious_outlier_nodes becomes greater than 0.',
            'edges_missing_from_node or edges_missing_to_node becomes greater than 0.',
            'observations_referencing_missing_nodes becomes greater than 0.',
            'duplicate_keys becomes greater than 0 in any core TSV table.',
            'latest.log shows unresolved battle handling or repeated stuck movement without recording a block.',
            'Dashboard /api/version and Lua Storage Status disagree on build/backend.'
        ],
        pass_after_each_scenario: 'GET /api/nav_stress_compare returns status pass or only a clearly understood needs_review with required_failed=0.'
    };
}


function countBy(rows, key) {
    const out = {};
    for (const row of rows || []) {
        const value = (row && row[key] !== undefined && row[key] !== '') ? String(row[key]) : '<blank>';
        out[value] = (out[value] || 0) + 1;
    }
    return out;
}

function battleObservationSummary(rows) {
    rows = rows || loadStorageRows(findLatestGameDir());
    const observations = rows.observations || [];
    const byResult = countBy(observations, 'result');
    const battleRows = observations.filter(row => String(row.result || '').toLowerCase() === 'battle' || /battle/i.test(String(row.note || '')));
    const unresolvedBattleRows = battleRows.filter(row => /unresolved|failed|timeout/i.test(String(row.note || '')));
    const battleSavedAsBlocked = (rows.blocked || []).filter(row => /battle/i.test(String(row.note || row.result || '')));

    return {
        total_observations: observations.length,
        by_result: byResult,
        clean_walkable_observations: byResult.walkable || 0,
        blocked_observations: byResult.blocked || 0,
        transition_observations: byResult.transition || 0,
        battle_observations: battleRows.length,
        unresolved_battle_observations: unresolvedBattleRows.length,
        battle_saved_as_blocked_candidates: battleSavedAsBlocked.length,
        map_changed_observations: observations.filter(row => String(row.map_changed || '').toLowerCase() === 'true').length,
        sample_battle_observations: sample(battleRows.map(row => ({
            observation_time: row.observation_time,
            from_node_id: row.from_node_id,
            direction: row.direction,
            result: row.result,
            to_node_id: row.to_node_id,
            note: row.note || ''
        })), 12),
        policy: {
            battle_is_not_blocked: true,
            battle_observations_do_not_prove_clean_edges: true,
            compact_graph_rebuild_should_wait_for_clean_walkable_or_blocked_result: true
        }
    };
}

function rawRouteEstimate(fileName) {
    const full = path.join(ROUTES_DIR, fileName);
    const stat = safeStat(full);
    const info = {
        path: rel(full),
        exists: !!stat && stat.isFile(),
        bytes: stat && stat.isFile() ? stat.size : 0,
        modified_at: stat && stat.isFile() ? stat.mtime.toISOString() : null,
        line_count: 0,
        comment_lines: 0,
        non_comment_lines: 0,
        candidate_node_ids: 0,
        candidate_result_counts: {},
        confidence: 'best_effort_text_scan'
    };
    if (!info.exists) return info;

    const text = fs.readFileSync(full, 'utf8');
    const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n').filter(line => line.length > 0);
    info.line_count = lines.length;
    info.comment_lines = lines.filter(line => /^\s*#/.test(line)).length;
    info.non_comment_lines = info.line_count - info.comment_lines;

    const nodeIds = new Set();
    const nodeRe = /[A-Z0-9_]+\|\d+\|-?\d+\|-?\d+\|-?\d+/g;
    let m;
    while ((m = nodeRe.exec(text)) !== null) nodeIds.add(m[0]);
    info.candidate_node_ids = nodeIds.size;

    const resultCounts = {};
    for (const token of ['walkable', 'blocked', 'transition', 'battle', 'wall', 'no_movement']) {
        const re = new RegExp('\\b' + token + '\\b', 'gi');
        const matches = text.match(re);
        resultCounts[token] = matches ? matches.length : 0;
    }
    info.candidate_result_counts = resultCounts;
    return info;
}

function latestTsvModifiedAt(storage) {
    let latest = null;
    for (const table of TABLES) {
        const item = storage.tables && storage.tables[table.name] ? storage.tables[table.name] : null;
        if (!item || !item.modified_at) continue;
        const t = new Date(item.modified_at).getTime();
        if (Number.isFinite(t) && (latest === null || t > latest)) latest = t;
    }
    return latest ? new Date(latest).toISOString() : null;
}

function componentClassification() {
    const integrity = integrityStatus();
    const comp = integrity.audit && integrity.audit.components ? integrity.audit.components : null;
    const samples = comp && Array.isArray(comp.component_sample) ? comp.component_sample : [];
    const classes = [];
    samples.forEach((item, index) => {
        let cls = index === 0 ? 'main_component' : 'valid_disconnected_test_component';
        let needsAction = false;
        if ((item.size || 0) < 3) {
            cls = 'small_or_isolated_component';
            needsAction = true;
        }
        const b = item.bounds || {};
        if (b.min_x === 0 && b.max_x === 0 && b.min_z <= 0) {
            cls = 'suspicious_placeholder_component';
            needsAction = true;
        }
        classes.push({
            classification: cls,
            needs_action: needsAction,
            accepted_for_v39_test_data: !needsAction,
            size: item.size,
            map_headers: item.map_headers || [],
            map_names: item.map_names || [],
            bounds: item.bounds || null,
            sample_node_ids: item.sample_node_ids || []
        });
    });

    return {
        version: VERSION,
        health: classes.some(c => c.needs_action) ? 'needs_review' : 'reviewed_test_data',
        total_components: comp ? comp.total_components : 0,
        disconnected_components: comp ? comp.disconnected_components : 0,
        small_components: comp ? comp.small_components : 0,
        classifications: classes,
        note: 'v40.9 treats non-suspicious disconnected components as reviewed test data inherited from the v39 storage phase. They should not block wrapping storage, but future Baritone-lite learning should connect or reset them cleanly.'
    };
}

function driftReport() {
    const storage = status();
    const game = findLatestGameDir();
    const rows = game ? loadStorageRows(game) : { nodes: [], edges: [], blocked: [], transitions: [], observations: [] };
    const integrity = integrityStatus();
    const coverage = coverageStatus();
    const rawGraph = rawRouteEstimate('map_graph.txt');
    const rawSweep = rawRouteEstimate('map_sweep_edges.txt');
    const rawNodes = rawRouteEstimate('map_nodes.txt');
    const routesIndex = rawRouteEstimate('routes_index.txt');
    const latestTsv = latestTsvModifiedAt(storage);
    const graphTime = rawGraph.modified_at ? new Date(rawGraph.modified_at).getTime() : null;
    const tsvTime = latestTsv ? new Date(latestTsv).getTime() : null;
    const graphStale = Number.isFinite(graphTime) && Number.isFinite(tsvTime) ? graphTime < tsvTime : false;
    const obs = battleObservationSummary(rows);

    const rawGraphCandidateNodes = rawGraph.candidate_node_ids || 0;
    const tsvNodeCount = rows.nodes.length;
    const warnings = [];
    const notes = [];
    if (graphStale) warnings.push('map_graph.txt is older than the newest normalized TSV table. This is not corruption, but the derived cache may be stale.');
    if (rawGraph.exists && rawGraphCandidateNodes && Math.abs(rawGraphCandidateNodes - tsvNodeCount) > 0) {
        notes.push('Raw graph candidate-node count differs from normalized TSV node count. This can be expected because raw route files are legacy/derived/debug, while normalized TSV is authoritative.');
    }
    if ((integrity.audit && integrity.audit.counts && integrity.audit.counts.suspicious_outlier_nodes) > 0) warnings.push('Suspicious nodes are still active; quarantine before trusting storage.');

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        backend: BACKEND,
        source_of_truth: SOURCE_OF_TRUTH,
        health: warnings.length ? 'needs_review' : 'ready',
        game_id: game ? game.game_id : null,
        source_of_truth_rules: {
            normalized_tsv: 'authoritative for navigation storage',
            raw_routes: 'legacy/import/debug files and derived caches',
            map_graph_txt: 'derived cache/export, not the source of truth',
            coverage_report: 'read-only derived analysis'
        },
        normalized_tsv: {
            counts: storage.counts,
            latest_modified_at: latestTsv,
            tables: storage.tables
        },
        raw_routes: {
            map_graph_txt: rawGraph,
            map_sweep_edges_txt: rawSweep,
            map_nodes_txt: rawNodes,
            routes_index_txt: routesIndex
        },
        drift: {
            tsv_nodes: tsvNodeCount,
            raw_graph_candidate_nodes: rawGraphCandidateNodes,
            tsv_edges: rows.edges.length,
            raw_graph_candidate_walkable_mentions: rawGraph.candidate_result_counts.walkable || 0,
            tsv_blocked: rows.blocked.length,
            raw_graph_candidate_blocked_mentions: rawGraph.candidate_result_counts.blocked || 0,
            tsv_observations: rows.observations.length,
            raw_sweep_non_comment_lines: rawSweep.non_comment_lines,
            map_graph_stale_vs_tsv: graphStale,
            confidence: 'raw route parsing is best-effort; normalized TSV counts are authoritative'
        },
        battle_observations: obs,
        integrity_counts: integrity.audit && integrity.audit.counts ? integrity.audit.counts : null,
        coverage_counts: coverage.coverage || null,
        warnings,
        notes
    };
}

function finalStorageGate() {
    const storage = status();
    const integrity = integrityStatus();
    const coverage = coverageStatus();
    const backups = listBackups();
    const quarantines = listQuarantines();
    const rebuild = derivedCacheRebuildPreview();
    const drift = driftReport();
    const components = componentClassification();
    const counts = integrity.audit && integrity.audit.counts ? integrity.audit.counts : {};
    const checks = [];
    const add = (id, label, severity, pass, detail) => checks.push({ id, label, severity, pass: !!pass, detail });

    add('version', 'Version is v40.9', 'required', storage.version === VERSION && integrity.version === VERSION && coverage.version === VERSION, { storage: storage.version, integrity: integrity.version, coverage: coverage.version });
    add('backend_tsv_only', 'Backend is TSV-only', 'required', storage.backend === BACKEND && storage.sqlite && storage.sqlite.required === false, { backend: storage.backend, sqlite: storage.sqlite });
    add('core_tables', 'Core TSV tables exist', 'required', TABLES.every(t => storage.tables[t.name] && storage.tables[t.name].exists), storage.counts);
    add('no_duplicate_keys', 'No duplicate TSV primary keys', 'required', TABLES.every(t => !storage.tables[t.name] || storage.tables[t.name].duplicate_keys === 0), Object.fromEntries(TABLES.map(t => [t.name, storage.tables[t.name] ? storage.tables[t.name].duplicate_keys : null])));
    add('no_bad_references', 'No missing node references', 'required', ((counts.edges_missing_from_node || 0) + (counts.edges_missing_to_node || 0) + (counts.transitions_missing_from_node || 0) + (counts.observations_referencing_missing_nodes || 0)) === 0, counts);
    add('no_invalid_nodes', 'No invalid nodes or node ID mismatches', 'required', ((counts.invalid_nodes || 0) + (counts.node_id_mismatches || 0)) === 0, counts);
    add('no_suspicious_nodes', 'No suspicious/outlier nodes active', 'required', (counts.suspicious_outlier_nodes || 0) === 0, { suspicious_outlier_nodes: counts.suspicious_outlier_nodes || 0 });
    add('coverage_available', 'Coverage report is available', 'required', !!coverage.coverage && typeof coverage.coverage.coverage_percent === 'number', coverage.coverage || null);
    add('backup_available', 'Backup exists before future rebuild/reset work', 'required', backups.count > 0, { backup_count: backups.count, latest_backup: backups.backups[0] || null });
    add('quarantine_reviewed', 'Quarantine review is available', 'info', true, { quarantine_count: quarantines.count, latest_quarantine: quarantines.quarantines[0] || null });
    add('components_classified', 'Disconnected components are classified as test data, not corruption', 'info', components.health === 'reviewed_test_data', components);
    add('reverse_policy_defined', 'Reverse edge policy is defined', 'info', true, { missing_explicit_reverse_edges: counts.missing_explicit_reverse_edges || 0, policy: 'observed edges stay in TSV; reverse movement is inferred in derived cache unless a future strict rebuild materializes it' });
    add('battle_observations_visible', 'Battle observations are visible and not treated as blocked edges', 'info', drift.battle_observations ? drift.battle_observations.policy : null, drift.battle_observations || null);
    add('drift_report_available', 'Raw/TSV drift report is available', 'info', true, { health: drift.health, drift: drift.drift, warnings: drift.warnings });
    add('derived_cache_preview', 'Derived cache rebuild preview is available', 'info', !!rebuild && rebuild.dry_run === true, rebuild.would_build || rebuild.error || null);

    const requiredFailed = checks.filter(c => c.severity === 'required' && !c.pass);
    const blocking = requiredFailed.length;
    const readyForTesting = blocking === 0;
    const readyForBaritoneLite = readyForTesting && (counts.suspicious_outlier_nodes || 0) === 0 && backups.count > 0;

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: blocking ? 'fail' : 'ready_with_known_test_data',
        required_failed: blocking,
        checks,
        readiness: {
            safe_to_continue_testing: readyForTesting,
            ready_to_wrap_v39_storage: readyForTesting,
            ready_for_baritone_lite_planning: readyForBaritoneLite,
            ready_for_full_map_reset: readyForTesting,
            ready_for_cache_rebuild_preview: !!rebuild && rebuild.dry_run === true,
            ready_for_cache_rebuild_execute: false,
            cache_rebuild_execute_note: 'Not implemented in v40.9. Keep rebuild execution behind developer tools until archive/reset workflow is safe.'
        },
        summary: {
            backend: storage.backend,
            game_id: storage.game_id,
            nodes: storage.counts.nodes,
            edges: storage.counts.edges,
            blocked: storage.counts.blocked,
            observations: storage.counts.observations,
            suspicious_outlier_nodes: counts.suspicious_outlier_nodes || 0,
            disconnected_components: counts.disconnected_components || 0,
            missing_explicit_reverse_edges: counts.missing_explicit_reverse_edges || 0,
            backups: backups.count,
            quarantines: quarantines.count,
            coverage_percent: coverage.coverage ? coverage.coverage.coverage_percent : null,
            frontier_nodes: coverage.coverage ? coverage.coverage.frontier_nodes : null,
            possible_holes: coverage.coverage ? coverage.coverage.possible_holes : null,
            battle_observations: drift.battle_observations ? drift.battle_observations.battle_observations : null
        },
        v40_cleanup_note: 'v40.9 keeps legacy stress/debug endpoints available as developer tools. Normal testing should use the Lua log plus /api/nav_test_summary; terrain truth must come from a game-profile exact behavior provider or exact seen-tile DB, never manual labels, map names, or battle history.'
    };
}

function futureActionItems() {
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        purpose: 'Track what v40 cleaned up and what still belongs to later Baritone-lite/dashboard work.',
        items: [
            {
                id: 'party_panel_persistence',
                target: 'dashboard',
                priority: 'implemented_v40_0',
                summary: 'Keep the last known party visible after short navigation tasks end.',
                notes: [
                    'Dashboard caches the last valid party snapshot in the browser.',
                    'A new valid Lua/emulator update refreshes the cache.',
                    'No extra idle polling is required just to keep sprites visible.'
                ]
            },
            {
                id: 'battle_viewer_assist',
                target: 'dashboard',
                priority: 'later_careful_design',
                summary: 'Add a view-only battle/fight helper without turning the game into autopilot.',
                notes: [
                    'Possible displays: current foe, party matchup notes, known IV/EV panels when available, status, HP, and safe general guidance.',
                    'Avoid making the bot auto-select complex fights unless the user explicitly turns on a future battle policy.',
                    'Keep it as an assistive viewer first, not a take-the-game-away battle bot.'
                ]
            },
            {
                id: 'v40_cleanup_sweep',
                target: 'build_cleanup',
                priority: 'implemented_v40_0_policy',
                summary: 'Move v39 stress-testing bloat out of the normal testing workflow.',
                notes: [
                    'Keep core storage status, integrity, coverage, drift, and final gate.',
                    'Normal testing should use Lua logs and /api/nav_test_summary instead of several debug pages.',
                    'Do not remove backup/restore safety.'
                ]
            },
            {
                id: 'baritone_lite_reset_workflow',
                target: 'navigation_storage',
                priority: 'before_full_relearn',
                summary: 'Archive current test data, reset active map data, and relearn with the stronger Baritone-lite learner.',
                notes: [
                    'Do not manually delete random TSV files.',
                    'Build an archive/reset/restore workflow first.',
                    'Treat current Route 34 data as test data, not the final clean map.'
                ]
            }
        ]
    };
}

function selfTest() {
    const storage = status();
    const integrity = integrityStatus();
    const coverage = coverageStatus();
    const backups = listBackups();
    const quarantines = listQuarantines();
    const rebuild = derivedCacheRebuildPreview();
    const drift = driftReport();
    const componentClasses = componentClassification();
    const counts = integrity.audit && integrity.audit.counts ? integrity.audit.counts : {};
    const checks = [];
    const add = (id, label, severity, pass, detail) => {
        checks.push({ id, label, severity, pass: !!pass, detail });
    };

    add('version', 'Version is v40.9', 'required', storage.version === VERSION && integrity.version === VERSION && coverage.version === VERSION, { storage: storage.version, integrity: integrity.version, coverage: coverage.version });
    add('backend', 'Storage backend is TSV-only', 'required', storage.backend === BACKEND && storage.sqlite && storage.sqlite.required === false, { backend: storage.backend, sqlite: storage.sqlite });
    add('tables', 'Core TSV tables exist', 'required', TABLES.every(t => storage.tables[t.name] && storage.tables[t.name].exists), storage.counts);
    add('duplicate_keys', 'No duplicate TSV primary keys', 'required', TABLES.every(t => !storage.tables[t.name] || storage.tables[t.name].duplicate_keys === 0), Object.fromEntries(TABLES.map(t => [t.name, storage.tables[t.name] ? storage.tables[t.name].duplicate_keys : null])));
    add('bad_references', 'No missing node references', 'required', ((counts.edges_missing_from_node || 0) + (counts.edges_missing_to_node || 0) + (counts.transitions_missing_from_node || 0) + (counts.observations_referencing_missing_nodes || 0)) === 0, counts);
    add('backup_available', 'At least one backup exists before repair/rebuild', 'warning', backups.count > 0, { backup_count: backups.count, latest_backup: backups.backups[0] || null });
    add('suspicious_nodes', 'No suspicious/outlier nodes active', 'warning', (counts.suspicious_outlier_nodes || 0) === 0, { suspicious_outlier_nodes: counts.suspicious_outlier_nodes || 0 });
    add('disconnected_components', 'Disconnected components classified', 'info', componentClasses.health === 'reviewed_test_data', componentClasses);
    add('reverse_policy', 'Reverse edge policy is intentionally handled', 'info', true, { missing_explicit_reverse_edges: counts.missing_explicit_reverse_edges || 0, policy: 'infer reverse movement in derived cache unless future strict storage decides to materialize' });
    add('coverage_available', 'Coverage report is available', 'required', !!coverage.coverage && typeof coverage.coverage.coverage_percent === 'number', coverage.coverage || null);
    add('quarantine_visible', 'Quarantine review endpoint is available', 'info', true, { quarantine_count: quarantines.count });
    add('rebuild_preview', 'Derived cache rebuild preview is available', 'info', !!rebuild && rebuild.dry_run === true, rebuild.would_build || rebuild.error || null);
    add('drift_report', 'Raw/TSV drift report is available', 'info', !!drift && !!drift.drift, drift ? { health: drift.health, drift: drift.drift, warnings: drift.warnings } : null);

    const requiredFailed = checks.filter(c => c.severity === 'required' && !c.pass);
    const warningsFailed = checks.filter(c => c.severity === 'warning' && !c.pass);
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: requiredFailed.length ? 'fail' : (warningsFailed.length ? 'needs_review' : 'pass'),
        required_failed: requiredFailed.length,
        warnings_failed: warningsFailed.length,
        checks,
        summary: {
            backend: storage.backend,
            health: integrity.health,
            backups: backups.count,
            quarantines: quarantines.count,
            suspicious_outlier_nodes: counts.suspicious_outlier_nodes || 0,
            disconnected_components: counts.disconnected_components || 0,
            missing_explicit_reverse_edges: counts.missing_explicit_reverse_edges || 0,
            coverage_percent: coverage.coverage ? coverage.coverage.coverage_percent : null,
            frontier_nodes: coverage.coverage ? coverage.coverage.frontier_nodes : null,
            possible_holes: coverage.coverage ? coverage.coverage.possible_holes : null,
            component_classification: componentClasses.health,
            drift_health: drift.health
        }
    };
}

function stressSnapshot() {
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        storage: status(),
        integrity: integrityStatus(),
        coverage: coverageStatus(),
        repair_preview: createRepairPreview(),
        backups: listBackups(),
        quarantine: listQuarantines(),
        stress_baselines: listStressBaselines(),
        stress_compare: stressCompare(),
        derived_cache_rebuild_preview: derivedCacheRebuildPreview(),
        drift_report: driftReport(),
        final_storage_gate: finalStorageGate(),
        future_action_items: futureActionItems(),
        selftest: selfTest(),
        stress_plan_endpoint: '/api/nav_stress_test_plan',
        stress_runbook_endpoint: '/api/nav_stress_runbook',
        stress_baseline_create_endpoint: '/api/nav_stress_baseline_create',
        stress_compare_endpoint: '/api/nav_stress_compare',
        drift_report_endpoint: '/api/nav_drift_report',
        final_gate_endpoint: '/api/nav_storage_final_gate'
    };
}


function afterActionSummary() {
    const storage = status();
    const integrity = integrityStatus();
    const coverage = coverageStatus();
    const finalGate = finalStorageGate();
    const battle = battleObservationSummary();
    const drift = driftReport();
    const counts = storage.counts || {};
    const integrityCounts = integrity.audit && integrity.audit.counts ? integrity.audit.counts : {};
    const coverageCounts = coverage.coverage || {};
    const requiredFailed = finalGate.required_failed || 0;

    const checks = [
        {
            id: 'storage_safe',
            label: 'Storage safe for continued testing',
            pass: requiredFailed === 0 && storage.backend === BACKEND,
            detail: {
                final_gate_status: finalGate.status,
                required_failed: requiredFailed,
                backend: storage.backend,
                health: storage.health
            }
        },
        {
            id: 'no_corruption_signals',
            label: 'No corruption signals active',
            pass: (integrityCounts.duplicate_node_keys || 0) === 0
                && (integrityCounts.duplicate_edge_keys || 0) === 0
                && (integrityCounts.duplicate_blocked_keys || 0) === 0
                && (integrityCounts.invalid_nodes || 0) === 0
                && (integrityCounts.node_id_mismatches || 0) === 0
                && (integrityCounts.suspicious_outlier_nodes || 0) === 0
                && (integrityCounts.edges_missing_from_node || 0) === 0
                && (integrityCounts.edges_missing_to_node || 0) === 0
                && (integrityCounts.observations_referencing_missing_nodes || 0) === 0,
            detail: {
                duplicate_node_keys: integrityCounts.duplicate_node_keys || 0,
                duplicate_edge_keys: integrityCounts.duplicate_edge_keys || 0,
                invalid_nodes: integrityCounts.invalid_nodes || 0,
                node_id_mismatches: integrityCounts.node_id_mismatches || 0,
                suspicious_outlier_nodes: integrityCounts.suspicious_outlier_nodes || 0,
                missing_references: {
                    edges_from: integrityCounts.edges_missing_from_node || 0,
                    edges_to: integrityCounts.edges_missing_to_node || 0,
                    observations: integrityCounts.observations_referencing_missing_nodes || 0
                }
            }
        },
        {
            id: 'lua_log_primary',
            label: 'Use Lua log as primary test view',
            pass: true,
            detail: 'For v40 gameplay testing, read latest.log/full log first. Use this summary only as a quick storage gate.'
        }
    ];

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: checks.some(c => c.pass === false) ? 'needs_review' : 'pass',
        purpose: 'One-page v40 testing summary. Use this instead of opening several storage/debug endpoints after every short Learn Current Area run.',
        testing_workflow: [
            'Read the Lua log first. It is the source of truth for what happened in-game.',
            'Open this endpoint only when you want a quick storage safety check after a run.',
            'Use the older stress/debug endpoints only when this summary or the Lua log shows a problem.'
        ],
        counts: {
            nodes: counts.nodes || 0,
            edges: counts.edges || 0,
            blocked: counts.blocked || 0,
            transitions: counts.transitions || 0,
            observations: counts.observations || 0,
            battle_observations: battle.battle_observations || 0
        },
        storage_gate: {
            safe_to_continue_testing: finalGate.readiness ? finalGate.readiness.safe_to_continue_testing : requiredFailed === 0,
            ready_to_wrap_v39_storage: finalGate.readiness ? finalGate.readiness.ready_to_wrap_v39_storage : true,
            ready_for_baritone_lite_planning: finalGate.readiness ? finalGate.readiness.ready_for_baritone_lite_planning : true,
            required_failed: requiredFailed
        },
        integrity: {
            duplicate_keys: {
                nodes: storage.tables && storage.tables.nodes ? storage.tables.nodes.duplicate_keys : 0,
                edges: storage.tables && storage.tables.edges ? storage.tables.edges.duplicate_keys : 0,
                blocked: storage.tables && storage.tables.blocked ? storage.tables.blocked.duplicate_keys : 0,
                transitions: storage.tables && storage.tables.transitions ? storage.tables.transitions.duplicate_keys : 0,
                observations: storage.tables && storage.tables.observations ? storage.tables.observations.duplicate_keys : 0
            },
            suspicious_outlier_nodes: integrityCounts.suspicious_outlier_nodes || 0,
            missing_node_references: {
                edges_from: integrityCounts.edges_missing_from_node || 0,
                edges_to: integrityCounts.edges_missing_to_node || 0,
                transitions_from: integrityCounts.transitions_missing_from_node || 0,
                observations: integrityCounts.observations_referencing_missing_nodes || 0
            },
            disconnected_components: integrityCounts.disconnected_components || 0,
            component_policy: 'Reviewed v39 test components are accepted for testing. Future Baritone-lite reset/relearn should cleanly connect or archive/reset them.'
        },
        coverage: {
            percent: coverageCounts.coverage_percent || 0,
            frontier_nodes: coverageCounts.frontier_nodes || 0,
            possible_holes: coverageCounts.possible_holes || 0,
            missing_reverse_links: coverageCounts.missing_reverse_links || 0,
            policy: 'Observed TSV edges remain one-way; derived cache may infer reverse movement.'
        },
        battles: {
            total_battle_observations: battle.battle_observations || 0,
            unresolved_battle_observations: battle.unresolved_battle_observations || 0,
            battle_saved_as_blocked_candidates: battle.battle_saved_as_blocked_candidates || 0,
            policy: battle.policy || {
                battle_is_not_blocked: true,
                battle_observations_do_not_prove_clean_edges: true
            }
        },
        drift: drift.drift || null,
        baritone_lite: {
            brain_pack: 'active_v40_6_exact_tile_atlas',
            primary_view: 'Lua log',
            expected_lua_markers: [
                '[BLT] Runtime',
                '[BLT] Action N observe/load_graph/plan_frontier/travel/probe/save_or_recover',
                '[BLT] Action N classified',
                'baritone-lite summary lines'
            ],
            one_page_endpoints: [
                '/api/nav_test_summary',
                '/api/nav_baritone_lite_status',
                '/api/nav_baritone_lite_gate'
            ],
            note: 'v40.9 keeps the goal-directed planner and uses a profile-based exact tile atlas plus an exact seen-tile DB. Unknown future tiles remain unknown; manual labels, old samples, map names, and battle history are not terrain truth.'
        },
        checks,
        developer_endpoints_only_when_needed: [
            '/api/nav_integrity',
            '/api/nav_coverage',
            '/api/nav_drift_report',
            '/api/nav_stress_compare',
            '/api/nav_stress_snapshot',
            '/api/nav_storage_final_gate'
        ],
        v40_cleanup: {
            stress_tools_hidden_by_policy: true,
            backup_restore_kept: true,
            storage_safety_kept: true,
            party_snapshot_cache: 'dashboard client cache; refreshes when Lua sends a new valid party snapshot',
            battle_viewer: 'not implemented yet; kept for later careful design'
        }
    };
}

function baritoneLitePlan() {
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: 'brain_pack_active',
        purpose: 'Define the complete v40 Baritone-lite target while keeping cleanup secondary.',
        perfect_outcome: 'Learn Current Area becomes a trustworthy local mapper: it observes, plans, travels, probes, classifies, writes only trusted results, recovers from interruptions, and explains every action in the Lua log.',
        non_goals: [
            'not a full-game autopilot',
            'not a complex battle bot',
            'not a SQLite migration',
            'not a UI/debug endpoint project',
            'not a promise that one build completes the entire game map'
        ],
        learner_loop: [
            'observe_current_tile',
            'load_known_map',
            'classify_current_situation',
            'pick_frontier_or_probe',
            'travel_to_target',
            'probe_direction',
            'classify_result',
            'write_trusted_observation_or_recover',
            'summarize_run'
        ],
        result_classes: {
            trusted_writes: ['walkable', 'blocked', 'transition'],
            handled_interruptions: ['battle_resolved_no_edge', 'battle_no_longer_active_no_edge'],
            untrusted_or_stop: ['battle_unresolved', 'wrong_tile', 'partial', 'unsafe_jump', 'no_probe_entry'],
            no_write: ['no_frontiers', 'no_unknown_direction', 'seed_no_unknown_direction']
        },
        expected_by_end_v40: [
            { id: 'lua_log_primary', required: true, target: 'Lua log explains each action clearly without requiring several API pages.' },
            { id: 'state_machine', required: true, target: 'Observe/load/plan/travel/probe/classify/save-or-recover loop is explicit in logs.' },
            { id: 'movement_verification', required: true, target: 'Clean movement, blocked, battle, transition, wrong-tile, partial, and untrusted movement are separated.' },
            { id: 'frontier_priority', required: true, target: 'Planner prefers useful current/nearby/frontier/hole/lane work and avoids repeated bad probes.' },
            { id: 'wall_corner_recovery', required: true, target: 'Walls/corners/dead ends become confirmed blocked directions without endless wall rubbing.' },
            { id: 'battle_recovery', required: true, target: 'Battles never become fake blocked edges; position is reconfirmed after handling.' },
            { id: 'transition_handling', required: true, target: 'Map changes are recorded as transitions and do not become fake same-map walkable edges.' },
            { id: 'trusted_storage_only', required: true, target: 'Only clean classified results are written as map facts.' },
            { id: 'run_summary', required: true, target: 'Each run summarizes actions, trusted writes, battles, transitions, untrusted results, stop reason, and current tile.' },
            { id: 'party_persistence', required: false, target: 'Dashboard keeps last known party visible without constant idle polling.' },
            { id: 'battle_viewer_assist', required: false, target: 'Optional view-only fight helper, not a take-the-game-away autopilot.' },
            { id: 'archive_reset_relearn', required: true, target: 'Current test map data can be archived/reset/restored before clean full relearn.' }
        ],
        v40_build_plan: [
            { build: 'v40.1', name: 'Baritone-lite Core Scaffold', expected: 'state machine logs, result classification, run summary, acceptance endpoints' },
            { build: 'v40.2', name: 'Baritone-lite Brain Pack', expected: 'goal-directed frontier targeting, local saturation detection, repeated-probe suppression, and stricter movement write gates' },
            { build: 'v40.3', name: 'Travel Recovery', expected: 'interrupted known-path travel replans instead of ending the whole task' },
            { build: 'v40.9', name: 'Party Snapshot Restore + Exact Tile Atlas', expected: 'game-profile exact tile atlas, exact seen-tile behavior atlas, no manual-label/map-name/battle terrain truth' },
            { build: 'next', name: 'Transition + Stuck Recovery Pack', expected: 'map-header transitions, loop/stuck detection, alternate frontier recovery, and post-battle retry/skip policy' },
            { build: 'later', name: 'Archive Reset Relearn + Clean Map Gate', expected: 'safe archive/reset/restore and clean relearn workflow' },
            { build: 'v40.final', name: 'Baritone-lite Acceptance Gate', expected: '3/10/25/50 action tests pass without storage corruption or stupid loops' }
        ]
    };
}

function baritoneLiteStatus() {
    const summary = afterActionSummary ? afterActionSummary() : null;
    const finalGate = finalStorageGate ? finalStorageGate() : null;
    const battle = battleObservationSummary ? battleObservationSummary() : null;

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: 'scaffold_ready_for_in_game_testing',
        current_runtime: {
            lua_log_primary: true,
            one_page_summary: '/api/nav_test_summary',
            baritone_plan: '/api/nav_baritone_lite_plan',
            acceptance_gate: '/api/nav_baritone_lite_gate'
        },
        current_counts: summary ? summary.counts : null,
        storage_gate: summary ? summary.storage_gate : null,
        battle_policy: battle ? battle.policy : null,
        final_gate_status: finalGate ? finalGate.status : 'unknown',
        v40_2_lua_expectations: [
            '[BLT] Runtime Brain Pack line at task start',
            '[BLT] observe/load_graph/plan_frontier/planner_brain/travel/probe/movement_gate/save_or_recover phase lines',
            '[BLT] Action N classified line after each action',
            'baritone-lite summary lines at task end'
        ],
        next_in_game_tests: [
            'Learn Current Area 3 actions on open route',
            'Learn Current Area 10 actions on current Route 34 test area',
            'wall/corner test with 3 actions',
            'grass/battle interruption test with 5 to 10 actions',
            'then check only Lua log plus /api/nav_test_summary unless something looks wrong'
        ]
    };
}

function baritoneLiteAcceptanceGate() {
    const summary = afterActionSummary ? afterActionSummary() : { checks: [], counts: {}, storage_gate: {} };
    const finalGate = finalStorageGate ? finalStorageGate() : null;
    const battle = battleObservationSummary ? battleObservationSummary() : null;
    const coverage = coverageStatus ? coverageStatus() : null;

    const checks = [];
    const add = (id, label, pass, detail) => checks.push({ id, label, pass: !!pass, detail });

    const storageGate = summary.storage_gate || {};
    const integrity = summary.integrity || {};
    const missing = integrity.missing_node_references || {};
    const dup = integrity.duplicate_keys || {};

    add('storage_safe', 'Storage safe for continued Baritone-lite testing', storageGate.safe_to_continue_testing === true && storageGate.required_failed === 0, storageGate);
    add('no_duplicate_keys', 'No duplicate TSV keys active', !dup.nodes && !dup.edges && !dup.blocked && !dup.transitions && !dup.observations, dup);
    add('no_missing_references', 'No missing node references active', !missing.edges_from && !missing.edges_to && !missing.transitions_from && !missing.observations, missing);
    add('battle_policy_safe', 'Battle observations are not treated as blocked edges', battle && battle.policy && battle.policy.battle_is_not_blocked === true && battle.battle_saved_as_blocked_candidates === 0, battle ? { battle_observations: battle.battle_observations, battle_saved_as_blocked_candidates: battle.battle_saved_as_blocked_candidates, policy: battle.policy } : null);
    add('coverage_available', 'Coverage report is available', coverage && coverage.health === 'ready' && coverage.coverage, coverage ? coverage.coverage : null);
    add('lua_log_primary', 'Lua log is the primary test view', true, 'v40.9 adds goal-directed planner-brain, movement-gate, exact surface lines, and concise normal/Dev log discipline to the Lua task log.');
    add('brain_pack_active', 'Goal-directed Baritone-lite brain pack is active', true, 'v40.9 adds the profile-based exact tile atlas and keeps compacted movement/frontier/repeat-risk behavior. Transition/reset/combat/multi-game work still follows.');

    const requiredFailed = checks.filter(c => ['storage_safe','no_duplicate_keys','no_missing_references','battle_policy_safe','coverage_available'].includes(c.id) && !c.pass).length;

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: requiredFailed === 0 ? 'ready_for_v40_6_mass_testing' : 'blocked',
        required_failed: requiredFailed,
        ready_for_baritone_lite_testing: requiredFailed === 0,
        perfect_outcome_done: false,
        perfect_outcome_note: 'The end-v40 target is defined and v40.9 now contains the profile-based exact tile atlas and compacted planner/movement brain pack, but final acceptance still needs mass testing plus transition/reset/combat/multi-game profiles.',
        checks,
        acceptance_test_target: {
            final_run: 'fresh or archived-reset area, Learn Current Area 50 actions',
            must_pass: [
                '0 duplicate keys',
                '0 missing references',
                '0 suspicious nodes',
                '0 fake blocked-from-battle records',
                'no endless wall/corner loop',
                'walkable saved only when clean movement is proven',
                'transition saved separately from same-map edge',
                'Lua log explains every action',
                '/api/nav_test_summary remains pass'
            ]
        }
    };
}

function v40CleanupStatus() {
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: 'clean_runtime_ready',
        normal_testing: {
            primary: 'Lua log',
            quick_summary: '/api/nav_test_summary',
            avoid_opening_every_run: [
                '/api/nav_integrity',
                '/api/nav_coverage',
                '/api/nav_stress_snapshot',
                '/api/nav_storage_final_gate'
            ]
        },
        kept_safety_tools: [
            'backup listing and creation',
            'quarantine review',
            'final storage gate',
            'drift report',
            'selftest'
        ],
        developer_only_bloat: [
            'stress baselines',
            'stress runbook',
            'stress snapshot',
            'raw repair preview pages'
        ],
        future_work: [
            'Baritone-lite learner design',
            'archive/reset/relearn workflow',
            'optional battle viewer assist, not autopilot',
            'full UI cleanup after the learner plan is locked'
        ]
    };
}



function storageNodeById(rows) {
    const out = new Map();
    for (const node of rows.nodes || []) {
        if (node && node.node_id) out.set(node.node_id, node);
    }
    return out;
}

function tileCodeKeyForMap(mapHeader, x, z) {
    const nx = Number(x);
    const nz = Number(z);
    if (!mapHeader || !Number.isFinite(nx) || !Number.isFinite(nz)) return '';
    return [String(mapHeader), String(Math.floor(nx)), String(Math.floor(nz))].join('|');
}

function buildTileCodeLookup(tileRows) {
    const lookup = new Map();
    for (const row of tileRows || []) {
        const key = tileCodeKeyForMap(row.map_header || '', row.tile_x, row.tile_z);
        if (key && !lookup.has(key)) lookup.set(key, row);
    }
    return lookup;
}

function attachTileCodeEvidence(codes, tileRows) {
    const game = findLatestGameDir();
    const rows = game ? loadStorageRows(game) : { nodes: [], edges: [], blocked: [], transitions: [], observations: [] };
    const nodeById = storageNodeById(rows);
    const tileLookup = buildTileCodeLookup(tileRows);
    const byCode = new Map();

    function ensure(code) {
        const key = code || 'NA';
        if (!byCode.has(key)) {
            byCode.set(key, {
                nodes_with_code: 0,
                entered_by_walkable_edges: 0,
                outgoing_walkable_edges: 0,
                blocked_from_tiles: 0,
                transition_from_tiles: 0,
                battle_observations_from_tiles: 0,
                observed_results: {},
                auto_semantics: {
                    walkability: 'unknown',
                    encounter: 'unknown',
                    transition: 'unknown',
                    confidence: 'evidence_only_not_friendly_truth'
                },
                notes: []
            });
        }
        return byCode.get(key);
    }

    function codeForNode(node) {
        if (!node) return '';
        const key = tileCodeKeyForMap(node.map_header || '', node.tile_x, node.tile_z);
        const row = key ? tileLookup.get(key) : null;
        return row ? String(row.behavior_code || row.code || '') : '';
    }

    for (const node of rows.nodes || []) {
        const code = codeForNode(node);
        if (code) ensure(code).nodes_with_code += 1;
    }

    for (const edge of rows.edges || []) {
        const fromCode = codeForNode(nodeById.get(edge.from_node_id));
        const toCode = codeForNode(nodeById.get(edge.to_node_id));
        if (fromCode) ensure(fromCode).outgoing_walkable_edges += 1;
        if (toCode) ensure(toCode).entered_by_walkable_edges += 1;
    }

    for (const block of rows.blocked || []) {
        const code = codeForNode(nodeById.get(block.from_node_id));
        if (code) ensure(code).blocked_from_tiles += 1;
    }

    for (const trans of rows.transitions || []) {
        const code = codeForNode(nodeById.get(trans.from_node_id));
        if (code) ensure(code).transition_from_tiles += 1;
    }

    for (const obs of rows.observations || []) {
        const node = nodeById.get(obs.from_node_id || obs.node_id || obs.start_node_id || obs.from || '');
        const code = codeForNode(node);
        if (!code) continue;
        const ev = ensure(code);
        const result = String(obs.result || obs.status || obs.kind || '').toLowerCase() || 'unknown';
        ev.observed_results[result] = (ev.observed_results[result] || 0) + 1;
        if (result.indexOf('battle') >= 0) ev.battle_observations_from_tiles += 1;
    }

    for (const ev of byCode.values()) {
        if (ev.entered_by_walkable_edges > 0 || ev.outgoing_walkable_edges > 0 || ev.nodes_with_code > 0) {
            ev.auto_semantics.walkability = (ev.entered_by_walkable_edges > 0 || ev.outgoing_walkable_edges > 0) ? 'walkable_observed' : 'stood_on_seen';
        }
        if (ev.blocked_from_tiles > 0 && ev.entered_by_walkable_edges === 0 && ev.outgoing_walkable_edges === 0) {
            ev.auto_semantics.walkability = 'blocked_or_boundary_observed_from_this_code';
        }
        if (ev.battle_observations_from_tiles > 0) {
            ev.auto_semantics.encounter = 'encounter_observed_near_code';
        } else {
            ev.auto_semantics.encounter = 'no_battle_observed_yet_not_proof_of_safe';
        }
        if (ev.transition_from_tiles > 0) ev.auto_semantics.transition = 'transition_observed_from_code';
        ev.notes.push('Raw behavior code is exact; semantic evidence is based on observed movement/transition/battle outcomes and is not a friendly surface label by itself.');
        ev.notes.push('A code can only become a named surface after a game profile maps it or controlled validation confirms the behavior.');
    }

    for (const code of codes) {
        code.semantic_evidence = byCode.get(String(code.behavior_code || '')) || ensure(String(code.behavior_code || ''));
    }
}

function tileCodeAtlas() {
    const atlasPath = path.join(ROUTES_DIR, 'map_terrain_exact_tiles.tsv');
    const parsed = parseTsvObjects(atlasPath);
    const stat = safeStat(atlasPath);
    const byCode = new Map();

    for (const row of parsed.rows || []) {
        const code = row.behavior_code || row.code || '';
        const surface = row.surface || 'unknown';
        const key = code || 'NA';
        const item = byCode.get(key) || {
            behavior_code: key,
            behavior_hex: code && code.startsWith('0x') ? code : (code === '' ? 'NA' : ('0x' + Number(code).toString(16).toUpperCase().padStart(4, '0'))),
            surface,
            category: row.category || 'unknown',
            walkability: row.walkability || 'unknown',
            tile_class: row.tile_class || 'unknown',
            surface_bucket: row.surface_bucket || 'unknown',
            confidence: row.confidence || 'unknown',
            provider_key: row.provider_key || 'unknown',
            exact_tiles_seen: 0,
            total_seen_count: 0,
            maps: {},
            sample_tiles: []
        };

        item.exact_tiles_seen += 1;
        item.total_seen_count += Number(row.seen_count || 1) || 1;
        if (row.map_name || row.map_header) {
            const mapKey = `${row.map_name || 'unknown'}:${row.map_header || ''}`;
            item.maps[mapKey] = (item.maps[mapKey] || 0) + 1;
        }
        if (item.sample_tiles.length < 12) {
            item.sample_tiles.push({
                map_name: row.map_name || '',
                map_header: row.map_header || '',
                tile_x: row.tile_x || '',
                tile_z: row.tile_z || '',
                surface: row.surface || 'unknown',
                confidence: row.confidence || 'unknown',
                source: row.source || '',
                last_frame: row.last_frame || ''
            });
        }
        byCode.set(key, item);
    }

    const codes = Array.from(byCode.values()).map(item => {
        item.maps = Object.keys(item.maps).sort().map(name => ({ name, tiles: item.maps[name] }));
        item.mapped = !String(item.surface || '').startsWith('unknown_behavior_') && item.confidence !== 'exact_code_unmapped';
        item.status = item.mapped ? 'mapped_exact_code' : 'unmapped_exact_code_needs_classification';
        return item;
    }).sort((a, b) => String(a.behavior_code).localeCompare(String(b.behavior_code)));

    attachTileCodeEvidence(codes, parsed.rows || []);

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: codes.length ? 'ready' : 'empty',
        purpose: 'Exact tile-code discovery report. Raw behavior codes are exact; friendly surface names are only used after a game-profile mapping exists.',
        db_path: rel(atlasPath),
        db_exists: !!stat && stat.isFile(),
        total_exact_tile_records: parsed.rows.length,
        unique_behavior_codes: codes.length,
        mapped_codes: codes.filter(c => c.mapped).length,
        unmapped_codes: codes.filter(c => !c.mapped).length,
        policy: {
            raw_code_accuracy: 'Exact when produced by a live game-profile provider.',
            friendly_label_accuracy: 'Only exact after the behavior code is mapped in the game profile. Unknown codes must stay unknown.',
            not_truth: ['manual labels', 'map names', 'battle history', 'old sample labels', 'random probe labels']
        },
        known_hgss_codes: {
            '0x0000': 'path / safe walkable ground',
            '0x0002': 'tall_grass / encounter walkable ground'
        },
        controlled_discovery: {
            note: 'The bot can auto-discover exact raw behavior codes and collect movement/battle/transition evidence. It cannot honestly invent friendly labels with 100% accuracy without a profile mapping or controlled validation.',
            next_for_unmapped_codes: [
                'stand on an obvious tile and run 1 action to record current code',
                'attempt movement into/out of the tile to prove walkability',
                'observe whether battles can trigger on that code over time',
                'test doors/warps/ledges/water with controlled 1-action probes',
                'only then map the code in the game profile'
            ]
        },
        codes
    };
}

function scanLens(options) {
    try {
        return scanLensImpl(options || {});
    } catch (err) {
        return {
            version: VERSION,
            generated_at: new Date().toISOString(),
            status: 'error',
            error: err && err.message ? err.message : String(err),
            message: 'Scan lens failed safely instead of hanging the browser. Check dashboard console/server output if this repeats.',
            legend: {
                walkable_scanned: 'explicit clean movement edge exists',
                blocked_scanned: 'explicit blocked direction exists',
                transition_scanned: 'explicit transition exists',
                reverse_known_inferred: 'neighbor reverse direction is known; not a true hole',
                possible_hole: 'adjacent known tile exists but neither direction has a scan record',
                unscanned_frontier: 'no adjacent known tile and no scan record yet'
            }
        };
    }
}

function scanLensImpl(options) {
    const game = findLatestGameDir();
    if (!game) {
        return {
            version: VERSION,
            generated_at: new Date().toISOString(),
            status: 'missing',
            message: 'No navigation game folder found yet.',
            legend: {}
        };
    }

    const detail = String(options.detail || options.mode || 'compact').toLowerCase();
    const maxNodes = Math.max(0, Math.min(1000, Number(options.max_nodes || (detail === 'full' ? 300 : 80)) || 80));
    const maxFrontiers = Math.max(0, Math.min(1000, Number(options.max_frontiers || (detail === 'full' ? 120 : 60)) || 60));

    const rows = loadStorageRows(game);
    const indexes = buildIndexes(rows, game.game_id);
    const components = componentAnalysis(rows, indexes);
    const outlierNodes = detectOutlierNodes(rows, components, indexes);
    const suspiciousIds = new Set(outlierNodes.map(n => n.node_id).filter(Boolean));
    const tileAtlas = tileCodeAtlas();

    let explicit = 0, effective = 0, unscanned = 0, trueFrontier = 0, holes = 0, reverseKnown = 0;
    const nodes = [];
    const frontierNodes = [];

    for (const node of rows.nodes) {
        if (!node.node_id || suspiciousIds.has(node.node_id)) continue;
        const dirStatus = {};
        const missing = [];
        let localExplicit = 0;
        let localEffective = 0;

        for (const direction of DIRECTIONS) {
            const key = scanKey(node.node_id, direction);
            const isExplicit = indexes.scanned.has(key);
            let status = 'unscanned_frontier';
            let neighbor = null;
            let reverseKey = '';
            const nKey = neighborKey(node, direction);
            const list = nKey && indexes.coordToNodes.get(nKey);
            if (list && list.length) {
                neighbor = list[0];
                reverseKey = scanKey(neighbor.node_id, OPPOSITE[direction]);
            }

            if (indexes.walkable.has(key)) status = 'walkable_scanned';
            else if (indexes.blockedSet.has(key)) status = 'blocked_scanned';
            else if (indexes.transitionSet.has(key)) status = 'transition_scanned';
            else if (isExplicit) status = 'explicit_scanned_other';
            else if (neighbor && indexes.scanned.has(reverseKey)) status = 'reverse_known_inferred';
            else if (neighbor) status = 'possible_hole';

            if (isExplicit) { explicit += 1; localExplicit += 1; }
            if (isExplicit || status === 'reverse_known_inferred') { effective += 1; localEffective += 1; }
            else {
                unscanned += 1;
                missing.push(direction);
                if (status === 'possible_hole') holes += 1;
                else trueFrontier += 1;
            }
            if (status === 'reverse_known_inferred') reverseKnown += 1;

            dirStatus[direction] = {
                status,
                explicit: isExplicit,
                effective: isExplicit || status === 'reverse_known_inferred',
                neighbor_node_id: neighbor ? neighbor.node_id : null
            };
        }

        const item = {
            node_id: node.node_id,
            map_name: node.map_name || '',
            map_header: node.map_header || '',
            tile_x: node.tile_x,
            tile_y: node.tile_y,
            tile_z: node.tile_z,
            explicit_scanned: localExplicit,
            effective_scanned: localEffective,
            missing_directions: missing,
            directions: dirStatus
        };
        nodes.push(item);
        if (missing.length) frontierNodes.push(item);
    }

    const total = nodes.length * DIRECTIONS.length;
    nodes.sort((a, b) => (b.missing_directions.length - a.missing_directions.length) || String(a.node_id).localeCompare(String(b.node_id)));

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: 'ready',
        purpose: 'Scan lens: what directions are scanned, inferred, blocked, walkable, possible holes, or still unscanned.',
        game_id: game.game_id,
        detail,
        legend: {
            walkable_scanned: 'explicit clean movement edge exists',
            blocked_scanned: 'explicit blocked direction exists',
            transition_scanned: 'explicit transition exists',
            reverse_known_inferred: 'neighbor reverse direction is known; not a true hole',
            possible_hole: 'adjacent known tile exists but neither direction has a scan record',
            unscanned_frontier: 'no adjacent known tile and no scan record yet'
        },
        summary: {
            nodes: nodes.length,
            total_directions: total,
            explicit_scanned: explicit,
            effective_scanned: effective,
            unscanned,
            true_frontier_directions: trueFrontier,
            possible_holes: holes,
            reverse_known_inferred: reverseKnown,
            effective_coverage_percent: total ? Math.round((effective / total) * 1000) / 10 : 0,
            returned_frontier_nodes: Math.min(frontierNodes.length, maxFrontiers),
            returned_nodes: Math.min(nodes.length, maxNodes)
        },
        tile_codes: {
            unique_behavior_codes: tileAtlas.unique_behavior_codes,
            unmapped_codes: tileAtlas.unmapped_codes,
            mapped_codes: tileAtlas.mapped_codes
        },
        frontier_nodes: sample(frontierNodes, maxFrontiers),
        nodes: sample(nodes, maxNodes)
    };
}


function tileCapabilityEngine(options) {
    options = options || {};
    const atlas = tileCodeAtlas();
    const capabilities = (atlas.codes || []).map(code => {
        const ev = code.semantic_evidence || {};
        const auto = ev.auto_semantics || {};
        const mapped = !!code.mapped;
        const observedResults = ev.observed_results || {};
        let movement = auto.walkability || code.walkability || 'unknown';
        let encounter = auto.encounter || 'unknown';
        let transition = auto.transition || 'unknown';
        let blockage = (ev.blocked_from_tiles || 0) > 0 ? 'blocked_seen_from_code_or_nearby' : 'none_observed';
        let plannerPolicy = 'unknown_exact_use_caution';
        let avoidCost = mapped && code.surface_bucket === 'encounter' ? 120 : 0;

        if (mapped && code.surface_bucket === 'safe') {
            plannerPolicy = 'prefer_for_travel';
            avoidCost = 0;
        } else if (mapped && code.surface_bucket === 'encounter') {
            plannerPolicy = 'avoid_when_equivalent_safe_route_exists';
            avoidCost = 120;
        } else if (!mapped && (ev.battle_observations_from_tiles || 0) > 0) {
            plannerPolicy = 'unmapped_encounter_possible_use_when_learning_or_needed';
            avoidCost = 60;
        } else if (!mapped && (ev.entered_by_walkable_edges || 0) > 0) {
            plannerPolicy = 'unmapped_walkable_observed_learning_value';
            avoidCost = 12;
        }

        const canName = mapped;
        const namingStatus = mapped ? 'profile_mapped' : 'raw_exact_code_only_needs_profile_or_controlled_validation';
        return {
            behavior_code: code.behavior_code,
            behavior_hex: code.behavior_hex,
            surface: code.surface,
            mapped,
            naming_status: namingStatus,
            friendly_label_allowed: canName,
            facts: {
                raw_code_exact: true,
                exact_tiles_seen: code.exact_tiles_seen || 0,
                total_seen_count: code.total_seen_count || 0,
                maps_seen: code.maps || []
            },
            capabilities: {
                movement,
                encounter,
                transition,
                blockage,
                walkability_profile: code.walkability || 'unknown',
                tile_class: code.tile_class || 'unknown',
                surface_bucket: code.surface_bucket || 'unknown'
            },
            evidence: {
                nodes_with_code: ev.nodes_with_code || 0,
                entered_by_walkable_edges: ev.entered_by_walkable_edges || 0,
                outgoing_walkable_edges: ev.outgoing_walkable_edges || 0,
                blocked_from_tiles: ev.blocked_from_tiles || 0,
                transition_from_tiles: ev.transition_from_tiles || 0,
                battle_observations_from_tiles: ev.battle_observations_from_tiles || 0,
                observed_results: observedResults
            },
            planner_policy: {
                policy: plannerPolicy,
                avoid_cost: avoidCost,
                use_for_learning: !mapped || code.surface_bucket !== 'blocked',
                notes: mapped
                    ? ['Friendly label comes from the game profile.']
                    : ['Do not invent a friendly tile name from evidence alone.', 'Planner may use capability evidence, but UI should still show the code as unmapped.']
            },
            sample_tiles: code.sample_tiles || []
        };
    });

    const unmapped = capabilities.filter(c => !c.mapped);
    const mapped = capabilities.filter(c => c.mapped);
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: 'ready',
        purpose: 'Tile capability engine: exact raw codes plus observed capabilities. Capabilities can guide planning; friendly names require a profile mapping or controlled validation.',
        policy: {
            exact_truth: 'Raw behavior codes from live providers and exact seen-tile records.',
            capability_truth: 'Observed movement/battle/transition evidence, tracked separately from friendly names.',
            friendly_name_truth: 'Only game-profile mapping, controlled validation, or imported official map/collision/permission data.',
            dynamic_blockage_policy: 'A failed move onto a known walkable tile is not permanent wall truth; treat it as dynamic/conditional until proven otherwise.'
        },
        summary: {
            unique_behavior_codes: capabilities.length,
            mapped_codes: mapped.length,
            unmapped_codes: unmapped.length,
            encounter_capable_or_possible: capabilities.filter(c => String(c.capabilities.encounter).includes('encounter')).length,
            walkable_observed: capabilities.filter(c => String(c.capabilities.movement).includes('walkable')).length
        },
        capabilities,
        next_engineering: [
            'Import or derive HGSS map/collision/permission data into a reusable map pack instead of requiring each user to relearn maps.',
            'Keep local learned TSV as overlays/deltas, not the only source of truth for every map.',
            'Store central map packs under user/nav/map_packs or downloadable release assets; store user observations separately.'
        ]
    };
}

function scanLensUiData(options) {
    options = options || {};
    const lens = scanLens(Object.assign({ max_frontiers: 24, max_nodes: 0 }, options));
    const frontierNodes = lens.frontier_nodes || [];
    const workItems = frontierNodes.map(node => {
        const dirs = node.directions || {};
        const trueDirs = [];
        const holeDirs = [];
        const blockedDirs = [];
        const walkableDirs = [];
        for (const dir of DIRECTIONS) {
            const st = dirs[dir] && dirs[dir].status;
            if (st === 'unscanned_frontier') trueDirs.push(dir);
            else if (st === 'possible_hole') holeDirs.push(dir);
            else if (st === 'blocked_scanned') blockedDirs.push(dir);
            else if (st === 'walkable_scanned') walkableDirs.push(dir);
        }
        const score = trueDirs.length * 5 + holeDirs.length * 3 - blockedDirs.length;
        return {
            node_id: node.node_id,
            map_name: node.map_name,
            map_header: node.map_header,
            tile_x: node.tile_x,
            tile_y: node.tile_y,
            tile_z: node.tile_z,
            score,
            missing_directions: node.missing_directions || [],
            true_frontier_directions: trueDirs,
            possible_hole_directions: holeDirs,
            already_walkable_directions: walkableDirs,
            blocked_directions: blockedDirs,
            action_hint: trueDirs.length
                ? `scan true frontier: ${trueDirs.join(', ')}`
                : (holeDirs.length ? `resolve possible hole: ${holeDirs.join(', ')}` : 'review node'),
            compact: `${node.map_name || 'Map'} X ${node.tile_x} Z ${node.tile_z}: ${(node.missing_directions || []).join(', ')}`
        };
    }).sort((a, b) => (b.score - a.score) || String(a.node_id).localeCompare(String(b.node_id)));

    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: lens.status || 'ready',
        purpose: 'Dashboard-ready scan lens data. This is the readable layer over /api/nav_scan_lens.',
        summary: lens.summary || {},
        legend: lens.legend || {},
        tile_codes: lens.tile_codes || {},
        work_items: workItems.slice(0, Number(options.max_items || 12) || 12),
        interpretation: [
            'true frontier = direction with no known neighbor and no scan record',
            'possible hole = adjacent known tile exists, but no explicit scan record connects it',
            'reverse inferred = not a true hole; the opposite direction is known and can be inferred for travel'
        ]
    };
}

function mapPackStatus() {
    const root = path.join(NAV_DIR, 'map_packs');
    ensureDir(root);
    const packs = [];
    for (const name of fs.readdirSync(root)) {
        const full = path.join(root, name);
        const stat = safeStat(full);
        if (!stat || !stat.isDirectory()) continue;
        let manifest = null;
        try { manifest = JSON.parse(fs.readFileSync(path.join(full, 'manifest.json'), 'utf8')); } catch (_err) { manifest = null; }
        packs.push({
            id: name,
            path: rel(full),
            modified_at: stat.mtime.toISOString(),
            manifest: manifest || null,
            status: manifest ? 'available' : 'folder_without_manifest'
        });
    }
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: 'ready',
        purpose: 'Reusable map-pack architecture status. Local learned data should eventually become a small overlay on top of shared per-game map packs, not a giant per-user rediscovery requirement.',
        root: rel(root),
        packs,
        desired_architecture: {
            shared_pack: 'Canonical per-game map/collision/permission/terrain facts shipped or downloaded once.',
            local_overlay: 'User discoveries, dynamic blockers, changed flags, and run observations.',
            planner_view: 'merged shared_pack + local_overlay + live exact reads.',
            storage_policy: 'Do not force every user to relearn every map; do not store all maps as one giant route file.'
        },
        profile_status: {
            HGSS: 'live behavior provider working; map-pack import still needed',
            B2W2: 'profile planned; provider/map-pack importer not implemented yet'
        }
    };
}

function mapArchiveRoot(gameId) {
    const root = path.join(NAV_DIR, 'map_archives', gameId || 'unknown');
    ensureDir(root);
    return root;
}

function mapDataArchivePreview(options) {
    options = options || {};
    const game = findLatestGameDir();
    if (!game) return { version: VERSION, ok: false, error: 'No game navigation folder found.' };
    const rows = loadStorageRows(game);
    const mapHeader = String(options.map_header || options.map || (rows.nodes[0] && rows.nodes[0].map_header) || '');
    const selectedNodes = new Set(rows.nodes.filter(n => !mapHeader || String(n.map_header) === mapHeader).map(n => n.node_id).filter(Boolean));
    const touches = row => selectedNodes.has(row.node_id) || selectedNodes.has(row.from_node_id) || selectedNodes.has(row.to_node_id);
    const counts = {
        nodes: rows.nodes.filter(touches).length,
        edges: rows.edges.filter(touches).length,
        blocked: rows.blocked.filter(touches).length,
        transitions: rows.transitions.filter(touches).length,
        observations: rows.observations.filter(touches).length
    };
    const routeFiles = ['map_graph.txt', 'map_sweep_edges.txt', 'map_nodes.txt', 'routes_index.txt'].map(name => {
        const stat = safeStat(path.join(ROUTES_DIR, name));
        return { name, exists: !!stat && stat.isFile(), bytes: stat && stat.isFile() ? stat.size : 0 };
    });
    return {
        version: VERSION,
        ok: true,
        dry_run: true,
        action: 'archive_reset_map_data_preview',
        game_id: game.game_id,
        map_header: mapHeader,
        would_archive_records: counts,
        route_files,
        safety: [
            'Preview only. Nothing changed.',
            'Confirmed reset creates a full backup first, archives removed TSV rows, then clears derived raw route cache files if clear_raw=true.',
            'Use this to get a clean test area without manually deleting random TSV files.'
        ],
        confirm_example: '/api/nav_map_archive_reset with POST data={"confirm":true,"map_header":"' + mapHeader + '","clear_raw":true}'
    };
}

function mapDataArchiveReset(options) {
    options = options || {};
    const confirm = options.confirm === true || options.confirm === 'true';
    if (!confirm) return mapDataArchivePreview(options);
    const game = findLatestGameDir();
    if (!game) return { version: VERSION, ok: false, error: 'No game navigation folder found.' };

    const loaded = {};
    for (const table of TABLES) loaded[table.name] = readTsvWithHeader(path.join(game.dir, table.name + '.tsv'));
    const rows = loadStorageRows(game);
    const mapHeader = String(options.map_header || options.map || (rows.nodes[0] && rows.nodes[0].map_header) || '');
    const selectedNodes = new Set(rows.nodes.filter(n => !mapHeader || String(n.map_header) === mapHeader).map(n => n.node_id).filter(Boolean));
    const touches = row => selectedNodes.has(row.node_id) || selectedNodes.has(row.from_node_id) || selectedNodes.has(row.to_node_id);
    const archive = {};
    const kept = {};
    for (const table of TABLES) {
        archive[table.name] = loaded[table.name].rows.filter(touches);
        kept[table.name] = loaded[table.name].rows.filter(row => !touches(row));
    }

    const backup = makeBackup('before_v40_10_map_archive_reset');
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const archiveDir = path.join(mapArchiveRoot(game.game_id), `map-${mapHeader || 'all'}-${stamp}`);
    ensureDir(archiveDir);
    for (const table of TABLES) {
        writeTsvObjects(path.join(archiveDir, table.name + '.tsv'), loaded[table.name].header, archive[table.name]);
        writeTsvObjects(path.join(game.dir, table.name + '.tsv'), loaded[table.name].header, kept[table.name]);
    }
    const rawCopied = [];
    for (const name of ['map_graph.txt', 'map_sweep_edges.txt', 'map_nodes.txt', 'routes_index.txt']) {
        const src = path.join(ROUTES_DIR, name);
        const stat = safeStat(src);
        if (stat && stat.isFile()) {
            const dest = path.join(archiveDir, 'routes', name);
            ensureDir(path.dirname(dest));
            fs.copyFileSync(src, dest);
            rawCopied.push(rel(dest));
            if (options.clear_raw === true || options.clear_raw === 'true') fs.writeFileSync(src, '', 'utf8');
        }
    }
    const info = {
        created_at: new Date().toISOString(),
        action: 'v40_10_map_archive_reset',
        game_id: game.game_id,
        map_header: mapHeader,
        backup_before_reset: backup,
        archived_counts: Object.fromEntries(TABLES.map(t => [t.name, archive[t.name].length])),
        raw_route_files_archived: rawCopied,
        raw_route_files_cleared: options.clear_raw === true || options.clear_raw === 'true'
    };
    fs.writeFileSync(path.join(archiveDir, 'archive_info.json'), JSON.stringify(info, null, 2), 'utf8');
    return {
        version: VERSION,
        ok: true,
        dry_run: false,
        action: 'archive_reset_map_data',
        archive_dir: rel(archiveDir),
        safety_backup: backup,
        archived: info.archived_counts,
        raw_route_files_archived: rawCopied,
        raw_route_files_cleared: info.raw_route_files_cleared,
        storage_after: status(),
        integrity_after: integrityStatus()
    };
}

function blockageReport(options) {
    options = options || {};
    const game = findLatestGameDir();
    if (!game) return { version: VERSION, status: 'missing', blockages: [] };
    const rows = loadStorageRows(game);
    const indexes = buildIndexes(rows, game.game_id);
    const items = [];
    let staticLikely = 0, dynamicCandidates = 0, conflicts = 0;
    for (const b of rows.blocked) {
        const from = indexes.nodeById.get(b.from_node_id || b.node_id || '');
        const dir = b.direction || b.dir || '';
        const key = scanKey(b.from_node_id || b.node_id || '', dir);
        let expectedNeighbor = null;
        if (from && dir) {
            const nk = neighborKey(from, dir);
            const list = nk && indexes.coordToNodes.get(nk);
            expectedNeighbor = list && list.length ? list[0] : null;
        }
        const hasWalkableConflict = indexes.walkable.has(key) || (expectedNeighbor && indexes.scanned.has(scanKey(expectedNeighbor.node_id, OPPOSITE[dir])));
        let classification = 'static_or_obstacle_candidate';
        let reason = 'blocked direction has no known walkable neighbor evidence';
        if (hasWalkableConflict) {
            classification = 'dynamic_or_stale_blockage_candidate';
            reason = 'same direction or expected neighbor has walkable/reverse evidence; do not treat as permanent wall without review';
            dynamicCandidates += 1;
            conflicts += 1;
        } else {
            staticLikely += 1;
        }
        if (items.length < (Number(options.limit || 80) || 80)) {
            items.push({
                from_node_id: b.from_node_id || b.node_id || '',
                direction: dir,
                map_name: from ? from.map_name : '',
                map_header: from ? from.map_header : '',
                tile_x: from ? from.tile_x : '',
                tile_z: from ? from.tile_z : '',
                expected_neighbor_node_id: expectedNeighbor ? expectedNeighbor.node_id : null,
                classification,
                reason
            });
        }
    }
    return {
        version: VERSION,
        generated_at: new Date().toISOString(),
        status: 'ready',
        purpose: 'Blockage report. This separates permanent wall candidates from dynamic/stale blockage candidates using graph evidence; it does not pretend to see NPCs/Cut trees directly yet.',
        policy: {
            permanent_blocked: 'Only safe when repeated no-movement has no conflicting walkable/reverse evidence and no battle/menu/position issue.',
            dynamic_candidate: 'If a tile/direction is otherwise known walkable, a block should be treated as NPC/object/state/conditional until a stronger object detector exists.',
            future_needed: 'Real object/NPC/Cut-tree discrimination should come from map object/script data or live object memory, not guessing from one blocked movement.'
        },
        summary: { total_blocked: rows.blocked.length, static_or_obstacle_candidates: staticLikely, dynamic_or_stale_candidates: dynamicCandidates, conflicts },
        blockages: items
    };
}

module.exports = {
    status,
    coverageStatus,
    integrityStatus,
    createRepairPreview,
    listBackups,
    listQuarantines,
    derivedCacheRebuildPreview,
    stressTestPlan,
    stressRunbook,
    createStressBaseline,
    listStressBaselines,
    stressCompare,
    selfTest,
    stressSnapshot,
    driftReport,
    finalStorageGate,
    battleObservationSummary,
    componentClassification,
    futureActionItems,
    afterActionSummary,
    baritoneLitePlan,
    baritoneLiteStatus,
    baritoneLiteAcceptanceGate,
    v40CleanupStatus,
    scanLens,
    tileCodeAtlas,
    tileCapabilityEngine,
    scanLensUiData,
    mapPackStatus,
    mapDataArchivePreview,
    mapDataArchiveReset,
    blockageReport,
    recordNavObservation,
    makeBackup,
    quarantineSuspiciousNodes,
    restoreBackup
};
