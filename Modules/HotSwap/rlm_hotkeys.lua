-- Dynamic, sprint-compatible hotkey polling. Saved bindings take effect
-- immediately and never consume the game's normal movement input.

local engine = require("rlm_engine")
local log = require("rlm_log")
local store = require("rlm_store")
local swaps = require("rlm_swaps")

local M = {}
local active, generation, down = false, 0, {}
local ui_open = function() return false end
local driver = rawget(_G, "__RLM_HOTKEY_DRIVER")
if type(driver) ~= "table" then
    driver = { started = false, tick = nil }
    rawset(_G, "__RLM_HOTKEY_DRIVER", driver)
end

local KEY_NAMES = {
    MOUSE4 = { "ThumbMouseButton", "MouseButton4", "XButton1" },
    MOUSE5 = { "ThumbMouseButton2", "MouseButton5", "XButton2" },
    MIDDLE_MOUSE = { "MiddleMouseButton", "MiddleMouse" },
    ["0"] = "Zero", ["1"] = "One", ["2"] = "Two", ["3"] = "Three",
    ["4"] = "Four", ["5"] = "Five", ["6"] = "Six", ["7"] = "Seven",
    ["8"] = "Eight", ["9"] = "Nine",
    CTRL = { "LeftControl", "RightControl" },
    ALT = { "LeftAlt", "RightAlt" }, SHIFT = { "LeftShift", "RightShift" },
}

local function key_down(controller, name)
    local mapped = KEY_NAMES[name]
    local names = type(mapped) == "table" and mapped or { mapped or name }
    for _, unreal_name in ipairs(names) do
        local pressed, just_pressed = false, false
        local key = { KeyName = FName(unreal_name) }
        pcall(function() pressed = controller:IsInputKeyDown(key) end)
        if pressed ~= true then
            pcall(function() just_pressed = controller:WasInputKeyJustPressed(key) end)
        end
        if pressed == true or just_pressed == true then return true end
    end
    return false
end

local function chord_down(controller, chord)
    local required, base = { CTRL = false, ALT = false, SHIFT = false }, nil
    for token in tostring(chord or ""):upper():gmatch("[^+]+") do
        if required[token] ~= nil then required[token] = true else base = token end
    end
    if not base or not key_down(controller, base) then return false end
    for modifier, needed in pairs(required) do
        if key_down(controller, modifier) ~= needed then return false end
    end
    return true
end

local function tick(my_generation)
    if not active or generation ~= my_generation then return end
    local suppressed = ui_open() or swaps.is_pending()
    local controller = engine.local_controller()
    if not controller then down = {}; return end
    local document, seen = store.get("gear_swaps"), {}
    for _, swap in ipairs(type(document) == "table" and document.swaps or {}) do
        local chord = tostring(swap.hotkey or ""):upper()
        if chord ~= "" then
            local id = tonumber(swap.id)
            local key = tostring(id) .. "|" .. chord
            seen[key] = true
            local pressed = chord_down(controller, chord)
            if pressed and not down[key] and not suppressed then
                local ok, detail = swaps.apply(id)
                if not ok then log.warn("hotkey " .. chord .. " failed: " .. tostring(detail)) end
            end
            down[key] = pressed
        end
    end
    for key in pairs(down) do if not seen[key] then down[key] = nil end end
end

function M.start(options)
    if active then return true end
    if type(LoopInGameThreadWithDelay) ~= "function" then return false, "hotkey polling is unavailable" end
    if type(options) == "table" and type(options.ui_open) == "function" then ui_open = options.ui_open end
    active, generation = true, generation + 1
    local my_generation = generation
    driver.tick = function()
        local ran, tick_error = pcall(tick, my_generation)
        if not ran then log.warn("hotkey tick failed: " .. tostring(tick_error)) end
    end
    if not driver.started then
        local ok, loop_error = pcall(LoopInGameThreadWithDelay, 16, function()
            local callback = driver.tick
            if type(callback) == "function" then callback() end
        end)
        if not ok then active = false; driver.tick = nil; return false, tostring(loop_error) end
        driver.started = true
    end
    return true
end

function M.stop()
    active, down = false, {}
    generation = generation + 1
    driver.tick = nil
    return true
end

return M
