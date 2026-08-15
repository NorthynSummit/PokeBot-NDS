-----------------------------------------------------------------------------
-- nav_log.lua
-- Dashboard-backed Lua log bridge for navigation/community builds.
-- Keeps the normal DeSmuME console output, but also mirrors lines to the
-- dashboard so users can copy/download logs without scraping the emulator.
-----------------------------------------------------------------------------

_NAV_LOG_VERSION = (nav_log_version and nav_log_version()) or "v38.2"
_NAV_LOG_RAW_PRINT = _NAV_LOG_RAW_PRINT or print
_NAV_LOG_INSTALLED = _NAV_LOG_INSTALLED or false
_NAV_LOG_SEQ = _NAV_LOG_SEQ or 0

local function nav_log_tostring(value)
    if value == nil then
        return "nil"
    end
    return tostring(value)
end

local function nav_log_join_args(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = nav_log_tostring(select(i, ...))
    end
    return table.concat(parts, "\t")
end

function nav_log_current_context()
    local context = {}

    if _ROM then
        context.game = tostring(_ROM.version or "")
        context.gen = tostring(_ROM.gen or "")
    end

    if game_state then
        context.map_name = tostring(game_state.map_name or "")
        context.map_header = tostring(game_state.map_header or "")
        context.x = tostring(game_state.trainer_x or "")
        context.y = tostring(game_state.trainer_y or "")
        context.z = tostring(game_state.trainer_z or "")
        context.in_battle = game_state.in_battle and true or false
    end

    return context
end

function nav_log_send(level, category, message)
    if not dashboard_send then
        return
    end

    _NAV_LOG_SEQ = (_NAV_LOG_SEQ or 0) + 1

    local ok, _ = pcall(function()
        dashboard_send({
            type = "lua_log",
            data = {
                seq = _NAV_LOG_SEQ,
                frame = emu and emu.framecount and emu.framecount() or 0,
                level = tostring(level or "info"),
                category = tostring(category or "lua"),
                message = tostring(message or ""),
                context = nav_log_current_context()
            }
        })
    end)

    if not ok then
        -- Do not allow dashboard/logging failures to break gameplay scripts.
    end
end

function nav_log(level, category, message)
    local text = tostring(message or "")
    _NAV_LOG_RAW_PRINT(text)
    nav_log_send(level or "info", category or "nav", text)
end

function nav_status(message)
    nav_log("status", "navigation", message)
end

function nav_warn(message)
    nav_log("warn", "navigation", message)
end

function nav_error_log(message)
    nav_log("error", "navigation", message)
end

function nav_battle_log(message)
    nav_log("battle", "battle", message)
end

function nav_storage_log(message)
    nav_log("storage", "storage", message)
end

function nav_install_print_bridge()
    if _NAV_LOG_INSTALLED then
        return
    end

    _NAV_LOG_INSTALLED = true
    _NAV_LOG_RAW_PRINT = _NAV_LOG_RAW_PRINT or print

    print = function(...)
        local text = nav_log_join_args(...)
        _NAV_LOG_RAW_PRINT(text)
        nav_log_send("info", "lua", text)
    end

    print("Lua dashboard log bridge installed (" .. tostring(_NAV_LOG_VERSION) .. ").")
end

nav_install_print_bridge()
