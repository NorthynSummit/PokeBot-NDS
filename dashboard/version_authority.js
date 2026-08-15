const fs = require('fs');
const path = require('path');

const FALLBACK_BUILD = {
    build: 'v39.0',
    name: 'Navigation Storage Source-of-Truth Foundation',
    base: 'v38.8 Task Selection Stabilization + Log Polish',
    date: '2026-06-28',
    requiresLua: 'v39.0',
    authority: 'lua/methods/nav/nav_version.lua',
    notes: 'Fallback build identity used only if nav_version.lua and dashboard/version.json cannot be read.'
};

function readJsonVersion() {
    try {
        const versionPath = path.resolve(__dirname, 'version.json');
        if (!fs.existsSync(versionPath)) return {};
        return JSON.parse(fs.readFileSync(versionPath, 'utf8')) || {};
    } catch (err) {
        console.warn('Unable to read dashboard/version.json:', err && err.message ? err.message : err);
        return {};
    }
}

function parseLuaVersionFile() {
    try {
        const luaPath = path.resolve(__dirname, '../lua/methods/nav/nav_version.lua');
        if (!fs.existsSync(luaPath)) return {};

        const text = fs.readFileSync(luaPath, 'utf8');
        const getString = (name) => {
            const re = new RegExp(name + "\\s*=\\s*['\"]([^'\"]+)['\"]");
            const match = text.match(re);
            return match ? match[1] : undefined;
        };

        const build = getString('NAV_BUILD_VERSION');
        const name = getString('NAV_BUILD_NAME');
        const base = getString('NAV_BUILD_BASE');
        const date = getString('NAV_BUILD_DATE');
        const notes = getString('NAV_BUILD_SUMMARY');
        const requiresLua = getString('NAV_DASHBOARD_MIN_VERSION') || build;

        if (!build && !name) return {};

        return {
            build,
            name,
            base,
            date,
            requiresLua,
            authority: 'lua/methods/nav/nav_version.lua',
            notes
        };
    } catch (err) {
        console.warn('Unable to read lua/methods/nav/nav_version.lua:', err && err.message ? err.message : err);
        return {};
    }
}

function compact(obj) {
    const out = {};
    Object.keys(obj || {}).forEach((key) => {
        if (obj[key] !== undefined && obj[key] !== null && obj[key] !== '') {
            out[key] = obj[key];
        }
    });
    return out;
}

function readBuildInfo() {
    const jsonInfo = compact(readJsonVersion());
    const luaInfo = compact(parseLuaVersionFile());

    // Priority: fallback < dashboard/version.json mirror < nav_version.lua authority.
    return Object.assign({}, FALLBACK_BUILD, jsonInfo, luaInfo, {
        fallback_build: FALLBACK_BUILD.build,
        dashboard_version_json: jsonInfo.build || null,
        source: luaInfo.build ? 'lua/methods/nav/nav_version.lua' : (jsonInfo.build ? 'dashboard/version.json' : 'fallback')
    });
}

function buildLabel(info) {
    info = info || readBuildInfo();
    return `${info.build || 'unknown'} ${info.name || ''}`.trim();
}

module.exports = {
    FALLBACK_BUILD,
    readBuildInfo,
    buildLabel
};
