-- Hot Swap module runtime. Combat dispatch stays isolated here and in the
-- services that live beside this file (rlm_swaps, rlm_hotkeys).

local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local module_dir = source:match("^(.*)[/\\][^/\\]+$")
if module_dir and not package.path:find(module_dir, 1, true) then
    package.path = module_dir .. "\\?.lua;" .. package.path
end

local inventory = require("rlm_inventory")
local store = require("rlm_store")
local swaps = require("rlm_swaps")
local hotkeys = require("rlm_hotkeys")

-- This module owns its saved swaps document (gear-swaps.json in user data).
local registered, register_error = store.register("gear_swaps", {
    file = "gear-swaps.json",
    base = function(document) document.swaps = {} end,
    validate = function(value)
        if type(value.swaps) ~= "table" then return false, "swaps array is missing" end
        return true
    end,
})
if not registered then error("Hot Swap storage unavailable: " .. tostring(register_error)) end

local M = {}
local pending_clear = nil
local selected_swap_id = nil

local COLORS = { "#E04F4F", "#4FA36C", "#4F8FE0", "#D39B3A", "#9A68D8", "#42A6A6" }
local COLOR_NAMES = {
    ["#E04F4F"] = "RED", ["#4FA36C"] = "GREEN", ["#4F8FE0"] = "BLUE",
    ["#D39B3A"] = "GOLD", ["#9A68D8"] = "PURPLE", ["#42A6A6"] = "TEAL",
}

local function utc_now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function swap_document()
    local document = store.get("gear_swaps")
    if type(document) ~= "table" then return nil end
    document.swaps = type(document.swaps) == "table" and document.swaps or {}
    return document
end

local function requested_id(input)
    local text = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local id = tonumber(text)
    if not id or id % 1 ~= 0 or id < 1 or id > 99 then
        return nil, "enter a swap number between 1 and 99"
    end
    return math.floor(id)
end

local function find_swap(swaps, id)
    for index, swap in ipairs(swaps) do
        if tonumber(swap.id) == id then return swap, index end
    end
    return nil
end

local function requested_slot(input)
    local id_text, slot_text = tostring(input or ""):match("^%s*(%d+)%s+(%d+)%s*$")
    local id, id_error = requested_id(id_text)
    if not id then return nil, nil, id_error .. "; example: 1 7" end
    local slot = tonumber(slot_text)
    if not slot or slot < 0 or slot > 11 then return nil, nil, "equipment slot must be 0-11" end
    return id, math.floor(slot)
end

local function edit_slot(input, remove)
    pending_clear = nil
    local id, slot, parse_error = requested_slot(input)
    if not id then return false, parse_error end
    local document = swap_document()
    if not document then return false, "hot-swap storage is not ready" end
    local swap = find_swap(document.swaps, id)
    if not swap then return false, "Swap " .. tostring(id) .. " does not exist" end
    swap.equipment = type(swap.equipment) == "table" and swap.equipment or {}

    local replacement = nil
    if not remove then
        local snapshot, snapshot_error = inventory.snapshot()
        if not snapshot then return false, snapshot_error end
        for _, entry in ipairs(snapshot.equipment) do
            if tonumber(entry.slot) == slot then replacement = entry; break end
        end
        if not replacement then return false, "nothing is currently equipped in slot " .. tostring(slot) end
    end

    local previous = {}
    for index, entry in ipairs(swap.equipment) do previous[index] = entry end
    for index = #swap.equipment, 1, -1 do
        local entry = swap.equipment[index]
        local same_slot = tonumber(entry.slot) == slot
        local duplicate_hand = replacement and (slot == 7 or slot == 8)
            and (tonumber(entry.slot) == 7 or tonumber(entry.slot) == 8)
            and tostring(entry.asset or ""):lower() == tostring(replacement.asset or ""):lower()
        if same_slot or duplicate_hand then table.remove(swap.equipment, index) end
    end
    if replacement then swap.equipment[#swap.equipment + 1] = replacement end
    table.sort(swap.equipment, function(left, right) return tonumber(left.slot) < tonumber(right.slot) end)
    swap.updatedUtc = utc_now()
    local saved, save_error = store.save("gear_swaps")
    if not saved then swap.equipment = previous; return false, "could not update the swap: " .. tostring(save_error) end
    if remove then return true, ("removed equipment slot %d from %s"):format(slot, tostring(swap.name)) end
    return true, ("set %s slot %d to %s"):format(tostring(swap.name), slot,
        tostring(replacement.label or replacement.asset))
end

local function capture(input)
    pending_clear = nil
    local id, id_error = requested_id(input)
    if not id then return false, id_error end
    local snapshot, snapshot_error = inventory.snapshot()
    if not snapshot then return false, tostring(snapshot_error or "character inventory is not ready") end
    if #snapshot.equipment == 0 then return false, "no equipped items were detected" end
    local document = swap_document()
    if not document then return false, "hot-swap storage is not ready" end

    local existing, index = find_swap(document.swaps, id)
    local now = utc_now()
    local replacement = {
        id = id,
        name = existing and existing.name or ("Swap " .. tostring(id)),
        color = existing and existing.color or COLORS[((id - 1) % #COLORS) + 1],
        hotkey = existing and existing.hotkey or nil,
        source = "ModManager",
        createdUtc = existing and existing.createdUtc or now,
        updatedUtc = now,
        equipment = snapshot.equipment,
    }
    if index then document.swaps[index] = replacement else document.swaps[#document.swaps + 1] = replacement end
    table.sort(document.swaps, function(left, right)
        return (tonumber(left.id) or 999) < (tonumber(right.id) or 999)
    end)

    local saved, save_error = store.save("gear_swaps")
    if not saved then
        if index then document.swaps[index] = existing
        else
            local _, inserted = find_swap(document.swaps, id)
            if inserted then table.remove(document.swaps, inserted) end
        end
        return false, "could not save the swap: " .. tostring(save_error)
    end
    return true, ("captured %d equipped item(s) into %s"):format(#snapshot.equipment, replacement.name)
end

local function clear(input)
    local id, id_error = requested_id(input)
    if not id then pending_clear = nil; return false, id_error end
    local document = swap_document()
    if not document then pending_clear = nil; return false, "hot-swap storage is not ready" end
    local existing, index = find_swap(document.swaps, id)
    if not existing then pending_clear = nil; return false, "Swap " .. tostring(id) .. " does not exist" end

    if pending_clear ~= id then
        pending_clear = id
        return true, "Press CLEAR SWAP again with the same number to confirm deleting " .. tostring(existing.name),
            { preserveInput = true }
    end
    pending_clear = nil
    table.remove(document.swaps, index)
    local saved, save_error = store.save("gear_swaps")
    if not saved then
        table.insert(document.swaps, index, existing)
        return false, "could not clear the swap: " .. tostring(save_error)
    end
    return true, "cleared " .. tostring(existing.name)
end

local function canonical_hotkey(value)
    local text = tostring(value or ""):upper():gsub("%s+", ""):gsub("_PLUS_", "+")
    if text == "NONE" or text == "UNBOUND" or text == "CLEAR" then return "" end
    local aliases = {
        CONTROL = "CTRL", LEFT_CTRL = "CTRL", RIGHT_CTRL = "CTRL",
        LEFT_SHIFT = "SHIFT", RIGHT_SHIFT = "SHIFT",
        LEFT_ALT = "ALT", RIGHT_ALT = "ALT",
        MOUSE_BUTTON_4 = "MOUSE4", THUMB_MOUSE_BUTTON = "MOUSE4", XBUTTON1 = "MOUSE4",
        MOUSE_BUTTON_5 = "MOUSE5", THUMB_MOUSE_BUTTON_2 = "MOUSE5", XBUTTON2 = "MOUSE5",
        MIDDLE_MOUSE_BUTTON = "MIDDLE_MOUSE", MIDDLE = "MIDDLE_MOUSE",
    }
    local modifiers, base = { CTRL = false, ALT = false, SHIFT = false }, nil
    for token in text:gmatch("[^+]+") do
        token = aliases[token] or token
        if modifiers[token] ~= nil then
            modifiers[token] = true
        elseif base then
            return nil, "a key combination can contain only one non-modifier key"
        else
            base = token
        end
    end
    local supported = base and (base:match("^F%d%d?$") or base:match("^[A-Z]$")
        or base:match("^[0-9]$") or base == "MOUSE4" or base == "MOUSE5"
        or base == "MIDDLE_MOUSE")
    if not supported then
        return nil, "supported keys are F1-F12, A-Z, 0-9, MOUSE4, MOUSE5 and MIDDLE_MOUSE"
    end
    local number = base:match("^F(%d+)$")
    if number and (tonumber(number) < 1 or tonumber(number) > 12) then return nil, "function key must be F1-F12" end
    local parts = {}
    for _, modifier in ipairs({ "CTRL", "ALT", "SHIFT" }) do
        if modifiers[modifier] then parts[#parts + 1] = modifier end
    end
    parts[#parts + 1] = base
    return table.concat(parts, "+")
end

local function set_hotkey(context, input)
    pending_clear = nil
    local text = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local id_text, key_text = text:match("^(%d+)%s+(.+)$")
    if not id_text then id_text, key_text = text:match("^(%d+)%s*([A-Za-z_].+)$") end
    if not id_text then id_text = text:match("^(%d+)$") end
    local id, id_error = nil, nil
    if id_text then
        id, id_error = requested_id(id_text)
    elseif selected_swap_id then
        id = selected_swap_id
        if text ~= tostring(selected_swap_id) then key_text = text end
    end
    if not id then
        return false, tostring(id_error or "select a swap first")
            .. "; then enter SHIFT+F1, or use 1 SHIFT+F1"
    end
    if not key_text or key_text == "" then
        return true, ("Listening for a key for Swap %d"):format(id), {
            preserveInput = true,
            captureHotkey = { prefix = tostring(id), seconds = 3 },
        }
    end
    local hotkey, hotkey_error = canonical_hotkey(key_text)
    if hotkey == nil then return false, hotkey_error end
    local base_key = hotkey:match("([^+]+)$")
    local manager_key = tostring(context and context.config and context.config.MenuKey or ""):upper()
    if hotkey ~= "" and manager_key ~= "" and base_key == manager_key then
        return false, base_key .. " is reserved for opening Mod Manager"
    end
    local document = swap_document()
    if not document then return false, "hot-swap storage is not ready" end
    local swap = find_swap(document.swaps, id)
    if not swap then return false, "Swap " .. tostring(id) .. " does not exist" end
    if hotkey ~= "" then
        for _, other in ipairs(document.swaps) do
            if tonumber(other.id) ~= id and tostring(other.hotkey or ""):upper() == hotkey then
                return false, hotkey .. " is already assigned to " .. tostring(other.name)
            end
        end
    end
    local previous = swap.hotkey
    swap.hotkey = hotkey ~= "" and hotkey or nil
    swap.updatedUtc = utc_now()
    local saved, save_error = store.save("gear_swaps")
    if not saved then
        swap.hotkey = previous
        return false, "could not save the key combination: " .. tostring(save_error)
    end
    return true, hotkey ~= "" and ("assigned " .. hotkey .. " to " .. tostring(swap.name))
        or ("removed the key binding from " .. tostring(swap.name))
end

function M.activate(context)
    local document = swap_document() or (context.documents and context.documents.gear_swaps) or nil
    local swaps = type(document) == "table" and type(document.swaps) == "table" and document.swaps or {}
    local ordered = {}
    for _, swap in ipairs(swaps) do ordered[#ordered + 1] = swap end
    table.sort(ordered, function(left, right)
        return (tonumber(left.id) or 999) < (tonumber(right.id) or 999)
    end)
    local rows = {}
    for _, swap in ipairs(ordered) do
        local count = type(swap.equipment) == "table" and #swap.equipment or 0
        local labels = {}
        for _, item in ipairs(type(swap.equipment) == "table" and swap.equipment or {}) do
            if #labels < 5 then labels[#labels + 1] = tostring(item.label or item.asset or "Unknown") end
        end
        local shown = #labels
        local remainder = math.max(0, count - shown)
        local color = tostring(swap.color or "#D0B070"):upper()
        rows[#rows + 1] = {
            title = ("%s  •  %s  •  %s  •  %d ITEM%s"):format(
                tostring(swap.name or ("Swap " .. tostring(swap.id or "?"))),
                COLOR_NAMES[color] or color, tostring(swap.hotkey or "UNBOUND"),
                count, count == 1 and "" or "S"),
            detail = #labels > 0 and ((remainder > 0
                    and ("Equipment (%d shown, +%d more): "):format(shown, remainder)
                    or "Equipment: ") .. table.concat(labels, "  •  "))
                or "No equipment captured in this swap.",
            color = color,
            value = tostring(swap.id or ""),
            inputValue = tostring(swap.id or ""),
            compact = true,
        }
    end
    return {
        status = "",
        detail = "Select a swap to preview its equipment and fill its number. Set Key listens for your next key combination for 3 seconds.",
        rows = rows,
    }
end

function M.select_row(_, value)
    local id = tonumber(value)
    if id and id % 1 == 0 and id >= 1 and id <= 99 then selected_swap_id = math.floor(id) end
    -- Returning false lets the shared shell continue filling the input and
    -- showing the row's equipment preview.
    return false
end

function M.run_action(context, action_id, input)
    if action_id == "toggle" then
        local id, id_error = requested_id(input)
        if not id then return false, id_error end
        return swaps.apply(id)
    end
    if action_id == "capture" then return capture(input) end
    if action_id == "set-slot" then return edit_slot(input, false) end
    if action_id == "remove-slot" then return edit_slot(input, true) end
    if action_id == "clear" then return clear(input) end
    if action_id == "set-hotkey" then return set_hotkey(context, input) end
    pending_clear = nil
    return false, "unknown Hot Swap action"
end

-- Called once the shell is ready and again after every Reload Mods, so it is
-- idempotent: the swap service and key poller survive module reloads.
function M.start(context)
    swaps.start(context and context.config)
    local ui = require("rlm_ui")
    if not swaps.status_wired then
        swaps.on_status(ui.report_status)
        swaps.status_wired = true
    end
    return hotkeys.start({ ui_open = ui.is_open })
end

-- A reload replaces this runtime but must leave the key poller running.
function M.stop() return true end

-- Manager unload: stop the poller and the swap service.
function M.shutdown()
    pcall(hotkeys.stop)
    pcall(swaps.stop)
    swaps.status_wired = nil
    return true
end

return M
