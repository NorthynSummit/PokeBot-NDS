-----------------------------------------------------------------------------
-- Main Pokebot NDS script
-- Custom navigation build
-- Version authority: lua\methods\nav\nav_version.lua
--
-- Responsible for loading the files appropriate to the current state,
-- including emulator, game, language, and configuration.
-----------------------------------------------------------------------------
package.cpath = package.cpath .. ";.\\lua\\modules\\?.dll" -- Allow socket.core to be detected beyond the project root
dofile("lua\\detect_emu.lua")

-- Load the custom build identity before dashboard/config startup so root script
-- console output and later navigation/dashboard displays use the same source.
local _nav_version_ok, _nav_version_err = pcall(function()
    dofile("lua\\methods\\nav\\nav_version.lua")
end)

print("Pokebot NDS - Custom Navigation Build")
if nav_build_label then
    print("Custom build: " .. tostring(nav_build_label()))
elseif not _nav_version_ok then
    print("Custom build: unknown (nav_version.lua failed: " .. tostring(_nav_version_err) .. ")")
end
print("Running " .. _VERSION .. " on " .. _EMU)
print("")

-- Clear values that might linger after restarting the script
game_state = nil
config = nil
foe = nil
party = {}

dofile("lua\\data\\misc.lua")
pokemon = require("lua\\modules\\pokemon")
dofile("lua\\modules\\input.lua")
dofile("lua\\detect_game.lua")
dofile("lua\\modules\\dashboard.lua")
dofile("lua\\helpers.lua")

-- Get the respective global scope function for the current bot mode
local mode_function = _G["mode_" .. config.mode]

if not mode_function then
    abort("Function for mode '" .. config.mode .. "' does not exist. It may not be compatible with this game.")
end

print("---------------------------")
print("Bot mode set to " .. config.mode)

-----------------------------------------------------------------------------
-- MAIN LOOP
-----------------------------------------------------------------------------
while true do
    joypad.set(input)
    process_frame()
    clear_unheld_inputs()
    
    mode_function()
end