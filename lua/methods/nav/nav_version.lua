-----------------------------------------------------------------------------
-- nav_version.lua
-- Single Lua authority for the custom PokéBot NDS build identity.
-----------------------------------------------------------------------------

NAV_BUILD_VERSION = "v40.10"
NAV_BUILD_NAME = "Capability Engine + Clean Map Workflow"
NAV_BUILD_SUMMARY = "Compact mapper intelligence pack: adds tile capability engine, scan lens dashboard data, safe map archive/reset workflow, map-pack architecture status, stronger party snapshot rendering, and dynamic-blockage-safe movement classification."
NAV_BUILD_BASE = "v40.9 Lens Hotfix + Party Keepalive"
NAV_BUILD_DATE = "2026-07-03"
NAV_DASHBOARD_MIN_VERSION = "v40.10"

function nav_version()
    return NAV_BUILD_VERSION
end

function nav_build_name()
    return NAV_BUILD_NAME
end

function nav_build_label()
    return tostring(NAV_BUILD_VERSION) .. " " .. tostring(NAV_BUILD_NAME)
end

function nav_build_summary()
    return tostring(NAV_BUILD_SUMMARY)
end

function nav_build_base()
    return tostring(NAV_BUILD_BASE)
end

function nav_build_date()
    return NAV_BUILD_DATE
end

function nav_dashboard_min_version()
    return NAV_DASHBOARD_MIN_VERSION
end

function nav_storage_version()
    return NAV_BUILD_VERSION
end

function nav_log_version()
    return NAV_BUILD_VERSION
end

function nav_cleanup_version()
    return NAV_BUILD_VERSION
end

function nav_developer_debug_enabled()
    if not config then
        return false
    end

    return config.debug == true
        or config.nav_developer_mode == true
        or config.nav_show_advanced_modes == true
        or config.perf_debug == true
end
