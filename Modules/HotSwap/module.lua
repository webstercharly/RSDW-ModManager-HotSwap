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
local editing_swap_id, selected_slot = nil, nil
local picker
local swap_page, slot_page = 1, 1
local SWAPS_PER_PAGE = 10
local SLOTS_PER_PAGE = 6
local LAST_SLOT = 11
local BROWSER_ACTIONS = { "toggle", "edit", "capture", "set-hotkey", "clear" }
local EDITOR_ACTIONS = { "open-backpack", "set-slot", "remove-slot" }
local PICKER_ACTIONS = { "save-backpack-item" }
local BACKPACK_PAGE_SIZE = 8
local ARMOUR_PARTS = { [0] = "head", [1] = "body", [2] = "legs" }
local TWO_HANDED_FAMILIES = {
    longbow = true, shortbow = true, crossbow = true, staff = true,
    greatsword = true, greataxe = true, hammer = true, pickaxe = true,
}

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
    if text == "" and selected_swap_id then return selected_swap_id end
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
    if tostring(input or ""):match("^%s*$") and editing_swap_id then
        if selected_slot == nil then return nil, nil, "select an equipment slot first" end
        return editing_swap_id, selected_slot
    end
    local id_text, slot_text = tostring(input or ""):match("^%s*(%d+)%s+(%d+)%s*$")
    if not id_text then return nil, nil, "select an equipment slot or enter a swap and slot (example: 1 7)" end
    local id, id_error = requested_id(id_text)
    if not id then return nil, nil, id_error .. "; example: 1 7" end
    local slot = tonumber(slot_text)
    if not slot or slot < 0 or slot > LAST_SLOT then return nil, nil, "equipment slot must be 0-11" end
    return id, math.floor(slot)
end

local function slot_name(slot)
    return inventory.equipment_slot_name(slot)
end

local function item_name(item)
    return item and tostring(item.label or item.asset or "Unknown item") or "Empty"
end

local function by_slot(equipment)
    local result = {}
    for _, entry in ipairs(type(equipment) == "table" and equipment or {}) do
        local slot = type(entry) == "table" and tonumber(entry.slot)
        if slot and slot % 1 == 0 and slot >= 0 and slot <= LAST_SLOT then result[slot] = entry end
    end
    return result
end

local function get_swap(id)
    local document = swap_document()
    if not document then return nil, "hot-swap storage is not ready" end
    local swap = find_swap(document.swaps, id)
    if not swap then return nil, "Swap " .. tostring(id) .. " does not exist" end
    return swap
end

local function is_two_handed(asset)
    asset = tostring(asset or ""):lower():gsub("^item_masterworks?_", "item_")
    local kind = asset:match("^item_([^_]+)_")
    return TWO_HANDED_FAMILIES[kind] == true or asset:find("^item_logging_axe_") ~= nil
end

local function fits_slot(slot, asset)
    asset = asset:lower()
    local kind = asset:match("^item_([^_]+)_")
    if ARMOUR_PARTS[slot] then
        return asset:find("^item_armour_t%d+_" .. ARMOUR_PARTS[slot] .. "_") ~= nil
    end
    if slot == 3 then return kind == "cape" end
    if slot == 4 then return asset:match("^item_jewellery_ring_") ~= nil
            or (kind == "trinket" and asset:match("_ring%f[^%a]") ~= nil) end
    if slot == 5 or slot == 9 then return asset:match("^item_ammo_arrows?_") ~= nil
            or asset:match("^item_ammo_bolts?_") ~= nil end
    if slot == 6 or slot == 10 then return kind == "rune" end
    if slot == 7 then return kind == "club" or kind == "sword" or kind == "scimitar" or is_two_handed(asset) end
    if slot == 8 then return kind == "shield" or asset:match("^item_masterworks?_shield_") ~= nil end
    return slot == 11 and (kind == "trinket" or kind == "jewellery") and asset:match("_amulet%f[^%a]") ~= nil
end

local function save_slot(swap, slot, replacement, clear_offhand)
    local previous, previous_updated = swap.equipment, swap.updatedUtc
    local updated = {}
    local replaced = false
    for _, entry in ipairs(type(previous) == "table" and previous or {}) do
        local entry_slot = type(entry) == "table" and tonumber(entry.slot)
        local duplicate_hand = replacement and (slot == 7 or slot == 8)
            and (entry_slot == 7 or entry_slot == 8) and inventory.same_item(entry, replacement)
        if entry_slot == slot or duplicate_hand or (clear_offhand and entry_slot == 8) then
            replaced = true
        else
            updated[#updated + 1] = entry
        end
    end
    if not replacement and not replaced then return false, slot_name(slot) .. " is already empty in this swap" end
    if replacement then updated[#updated + 1] = replacement end
    -- The combat service sorts its own targets. Keep other saved entries in
    -- their original order, including fields from newer document versions.
    swap.equipment, swap.updatedUtc = updated, utc_now()
    local saved, save_error = store.save("gear_swaps")
    if not saved then
        swap.equipment, swap.updatedUtc = previous, previous_updated
        return false, "could not update the swap: " .. tostring(save_error)
    end
    if not replacement then return true, ("Removed %s from %s"):format(slot_name(slot), tostring(swap.name)) end
    return true, ("%s now uses %s for %s"):format(tostring(swap.name), item_name(replacement), slot_name(slot))
end

local function edit_slot(input, remove)
    pending_clear = nil
    local id, slot, parse_error = requested_slot(input)
    if not id then return false, parse_error end
    local swap, err = get_swap(id)
    if not swap then return false, err end
    if remove then return save_slot(swap, slot) end
    local snapshot, snapshot_error = inventory.snapshot()
    if not snapshot then return false, snapshot_error end
    local replacement = by_slot(snapshot.equipment)[slot]
    if not replacement then return false, slot_name(slot) .. " has no equipped item to use" end
    return save_slot(swap, slot, replacement)
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
    local replacement = {}
    for key, value in pairs(existing or {}) do replacement[key] = value end
    replacement.id = id
    replacement.name = replacement.name or ("Swap " .. tostring(id))
    replacement.color = replacement.color or COLORS[((id - 1) % #COLORS) + 1]
    replacement.source = "ModManager"
    replacement.createdUtc = replacement.createdUtc or now
    replacement.updatedUtc, replacement.equipment = now, snapshot.equipment
    local previous, updated = document.swaps, {}
    for position, swap in ipairs(previous) do updated[position] = swap end
    updated[index or (#updated + 1)] = replacement
    table.sort(updated, function(left, right)
        return (tonumber(left.id) or 999) < (tonumber(right.id) or 999)
    end)
    document.swaps = updated

    local saved, save_error = store.save("gear_swaps")
    if not saved then
        document.swaps = previous
        return false, "could not save the swap: " .. tostring(save_error)
    end
    local _, saved_index = find_swap(document.swaps, id)
    selected_swap_id, swap_page = id, math.ceil(saved_index / SWAPS_PER_PAGE)
    return true, ("captured %d equipped item(s) into %s"):format(#snapshot.equipment, replacement.name),
        { preserveInput = true }
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
            { preserveInput = true, preserveView = true }
    end
    pending_clear = nil
    table.remove(document.swaps, index)
    local saved, save_error = store.save("gear_swaps")
    if not saved then
        table.insert(document.swaps, index, existing)
        return false, "could not clear the swap: " .. tostring(save_error)
    end
    if selected_swap_id == id then selected_swap_id = nil end
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
    local document = swap_document()
    if not document then return false, "hot-swap storage is not ready" end
    local swap = find_swap(document.swaps, id)
    if not swap then return false, "Swap " .. tostring(id) .. " does not exist" end
    if not key_text or key_text == "" then
        selected_swap_id = id
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
    if hotkey ~= "" then
        for _, other in ipairs(document.swaps) do
            if tonumber(other.id) ~= id and tostring(other.hotkey or ""):upper() == hotkey then
                return false, hotkey .. " is already assigned to " .. tostring(other.name)
            end
        end
    end
    local previous, previous_updated = swap.hotkey, swap.updatedUtc
    swap.hotkey = hotkey ~= "" and hotkey or nil
    swap.updatedUtc = utc_now()
    local saved, save_error = store.save("gear_swaps")
    if not saved then
        swap.hotkey, swap.updatedUtc = previous, previous_updated
        return false, "could not save the key combination: " .. tostring(save_error)
    end
    selected_swap_id = id
    return true, hotkey ~= "" and ("assigned " .. hotkey .. " to " .. tostring(swap.name))
        or ("removed the key binding from " .. tostring(swap.name)), { preserveInput = true }
end

local function editor_view(swap)
    local snapshot = inventory.snapshot()
    local equipped, saved = by_slot(snapshot and snapshot.equipment), by_slot(swap.equipment)
    local rows = {
        { title = "<  ALL SWAPS", value = "editor:back", compact = true },
        { title = slot_page == 1 and "MORE SLOTS  >" or "<  FIRST SLOTS", value = "editor:page" },
    }
    local detail = snapshot and "Select a slot to compare saved and equipped gear."
        or "Current equipment is unavailable. Saved slots can still be removed."
    local first = (slot_page - 1) * SLOTS_PER_PAGE
    for slot = first, math.min(first + SLOTS_PER_PAGE - 1, LAST_SLOT) do
        local current = snapshot and item_name(equipped[slot]) or "Unavailable"
        if snapshot and not equipped[slot] and (slot == 7 or slot == 8) then current = "No separate item" end
        local slot_detail = ("%s\nSaved · %s\nEquipped · %s"):format(slot_name(slot), item_name(saved[slot]),
            current)
        rows[#rows + 1] = {
            title = ("%s  •  %s"):format(slot_name(slot), item_name(saved[slot])),
            value = "slot:" .. slot, detail = slot_detail, compact = true,
        }
        if selected_slot == slot then detail = slot_detail end
    end
    return { status = tostring(swap.name or ("Swap " .. swap.id)) .. ("  •  Slots %d/2"):format(slot_page),
        detail = detail, rows = rows,
        poolRows = true, actionIds = EDITOR_ACTIONS }
end

local function picker_view(swap)
    local saved = by_slot(swap.equipment)
    local slot = picker.slot
    local pages = math.max(1, math.ceil(#picker.items / BACKPACK_PAGE_SIZE))
    local rows = { { title = "<  BACK TO GEAR", value = "backpack:back", compact = true } }
    if picker.page > 1 then rows[#rows + 1] = { title = "<  PREVIOUS ITEMS", value = "backpack:prev" } end
    if picker.page < pages then rows[#rows + 1] = { title = "NEXT ITEMS  >", value = "backpack:next" } end
    local status = ("%s  •  %s"):format(tostring(swap.name or ("Swap " .. swap.id)), slot_name(slot))
    if pages > 1 then status = status .. ("  •  %d/%d"):format(picker.page, pages) end
    local detail = "Saved · " .. item_name(saved[slot]) .. "\nChoose an item, then Save to Slot."
    if #picker.items == 0 then
        detail = "No supported backpack items for this slot. Use Equipped can capture an item you’re wearing."
    end
    for index = (picker.page - 1) * BACKPACK_PAGE_SIZE + 1, math.min(picker.page * BACKPACK_PAGE_SIZE, #picker.items) do
        local item = picker.items[index]
        local comparison = ("Saved · %s\nSelected · %s"):format(item_name(saved[slot]), item_name(item))
        if slot == 7 and saved[8] and is_two_handed(item.asset) then
            comparison = comparison .. "\nSaving this two-handed item will clear the preset's left hand."
        end
        rows[#rows + 1] = { title = item_name(item), value = "backpack:item:" .. index, detail = comparison }
        if picker.selected == index then detail = comparison end
    end
    return { status = status, detail = detail, rows = rows, poolRows = true,
        actionIds = #picker.items > 0 and PICKER_ACTIONS or {} }
end

local function open_backpack()
    if not editing_swap_id or selected_slot == nil then return false, "select an equipment slot first" end
    if type(inventory.backpack_gear) ~= "function" then
        return false, "restart Dragonwilds once to load the backpack picker"
    end
    local swap, err = get_swap(editing_swap_id)
    if not swap then return false, err end
    local slot = selected_slot
    local right = by_slot(swap.equipment)[7]
    if slot == 8 and right and is_two_handed(right.asset) then
        return false, "the preset uses a two-handed weapon. Change its right hand before adding a shield"
    end
    local items, reason, character = inventory.backpack_gear(slot, function(asset) return fits_slot(slot, asset) end)
    if not items then return false, reason end
    picker = { slot = slot, items = items, character = character, page = 1 }
    return true, picker_view(swap).detail
end

local function save_backpack_item()
    local wanted = picker and picker.items[picker.selected]
    if not wanted then return false, "select a backpack item first" end
    local swap, err = get_swap(editing_swap_id)
    if not swap then return false, err end
    local slot = picker.slot
    local saved = by_slot(swap.equipment)
    if slot == 8 and saved[7] and is_two_handed(saved[7].asset) then
        return false, "the preset uses a two-handed weapon. Change its right hand before adding a shield"
    end
    local item, reason = inventory.backpack_gear(slot, function(asset) return fits_slot(slot, asset) end,
        picker.character, wanted)
    if not item then return false, reason end
    local clear_offhand = slot == 7 and saved[8] ~= nil and is_two_handed(item.asset)
    local ok, message = save_slot(swap, slot, item, clear_offhand)
    if not ok then return false, message end
    picker = nil
    if clear_offhand then message = message .. ". Left hand cleared in this preset" end
    return true, message .. "."
end

function M.activate(context)
    local document = swap_document() or (context.documents and context.documents.gear_swaps) or nil
    local saved_swaps = type(document) == "table" and type(document.swaps) == "table" and document.swaps or {}
    if editing_swap_id then
        local swap = find_swap(saved_swaps, editing_swap_id)
        if swap then
            if picker then return picker_view(swap) end
            return editor_view(swap)
        end
        editing_swap_id, selected_slot, picker = nil, nil, nil
    end
    local ordered = {}
    for _, swap in ipairs(saved_swaps) do ordered[#ordered + 1] = swap end
    table.sort(ordered, function(left, right)
        return (tonumber(left.id) or 999) < (tonumber(right.id) or 999)
    end)
    local rows = {}
    local pages = math.max(1, math.ceil(#ordered / SWAPS_PER_PAGE))
    swap_page = math.max(1, math.min(swap_page, pages))
    if swap_page > 1 then rows[#rows + 1] = { title = "<  PREVIOUS SWAPS", value = "swaps:prev" } end
    for index = (swap_page - 1) * SWAPS_PER_PAGE + 1, math.min(swap_page * SWAPS_PER_PAGE, #ordered) do
        local swap = ordered[index]
        local count = type(swap.equipment) == "table" and #swap.equipment or 0
        local color = tostring(swap.color or "#D0B070"):upper()
        rows[#rows + 1] = {
            title = ("%s  •  %s  •  %s  •  %d ITEM%s"):format(
                tostring(swap.name or ("Swap " .. tostring(swap.id or "?"))),
                COLOR_NAMES[color] or color, tostring(swap.hotkey or "UNBOUND"),
                count, count == 1 and "" or "S"),
            detail = "Open Edit Gear to see every slot.",
            value = tostring(swap.id or ""),
            inputValue = tostring(swap.id or ""),
            compact = true,
        }
    end
    if swap_page < pages then rows[#rows + 1] = { title = "NEXT SWAPS  >", value = "swaps:next", compact = true } end
    if rows[1] then rows[1].compact = true end
    return {
        status = pages > 1 and ("Swaps %d/%d"):format(swap_page, pages) or "",
        detail = #ordered == 0 and "Enter a swap number and select Capture Current to save your equipped gear."
            or "Select a swap to apply it, edit its gear, or set its shortcut.",
        rows = rows, poolRows = true, actionIds = BROWSER_ACTIONS,
        inputValue = selected_swap_id or "",
    }
end

function M.select_row(_, value)
    pending_clear = nil
    if picker then
        if value == "backpack:back" then picker = nil; return true end
        if value == "backpack:prev" or value == "backpack:next" then
            picker.page = picker.page + (value == "backpack:prev" and -1 or 1)
            picker.selected = nil
            return true
        end
        local index = tonumber(tostring(value):match("^backpack:item:(%d+)$"))
        if index and picker.items[index] then picker.selected = index end
        return false
    end
    if value == "editor:back" then editing_swap_id, selected_slot = nil, nil; return true end
    if value == "editor:page" and editing_swap_id then
        slot_page, selected_slot = 3 - slot_page, nil
        return true
    end
    if value == "swaps:prev" then swap_page = swap_page - 1; return true end
    if value == "swaps:next" then swap_page = swap_page + 1; return true end
    local slot = tostring(value):match("^slot:(%d+)$")
    if editing_swap_id and slot then
        selected_slot = tonumber(slot)
        return false
    end
    local id = tonumber(value)
    if id and id % 1 == 0 and id >= 1 and id <= 99 then selected_swap_id = math.floor(id) end
    return false
end

function M.run_action(context, action_id, input)
    if action_id == "open-backpack" then return open_backpack() end
    if action_id == "save-backpack-item" then return save_backpack_item() end
    if action_id == "toggle" then
        pending_clear = nil
        local id, id_error = requested_id(input)
        if not id then return false, id_error end
        local ok, message = swaps.apply(id)
        return ok, message, { preserveInput = true, preserveView = true }
    end
    if action_id == "edit" then
        pending_clear = nil
        if not context.uiActionViews or type(inventory.equipment_slot_name) ~= "function" then
            return false, "restart Dragonwilds once to load the gear editor"
        end
        local id, id_error = requested_id(input)
        if not id then return false, id_error end
        local document = swap_document()
        local swap = document and find_swap(document.swaps, id)
        if not swap then return false, ("Swap %d does not exist"):format(id) end
        selected_swap_id, editing_swap_id, selected_slot = id, id, nil
        slot_page = 1
        return true, "Select a slot to compare saved and equipped gear."
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
