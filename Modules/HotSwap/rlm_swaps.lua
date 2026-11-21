-- Existing-item-only combat equipment transactions. Every mutation uses the
-- game's normal inventory controller and is verified after replication.

local async = require("rlm_async")
local engine = require("rlm_engine")
local log = require("rlm_log")
local store = require("rlm_store")
local transaction = require("rlm_transaction")

local M = {}
local LOADOUT_LAST_SLOT, INVENTORY_SCAN_FALLBACK = 11, 120
local pending, operation_token = false, 0
local listeners = {}
local config = { DispatchIntervalMs = 70, VerifyTimeoutSeconds = 5 }

local function emit(kind, message, swap)
    log.info(("hot swap %s: %s"):format(tostring(kind), tostring(message)))
    for _, listener in ipairs(listeners) do pcall(listener, kind, message, swap) end
end

local function item_at(component, slot)
    local item = engine.call(component, "GetItemFromSlot", slot)
    return engine.is_valid(item) and item or nil
end

local function item_data(item)
    return engine.object_call(item, "BP_GetItemData") or engine.field_object(item, { "ItemData" })
end

local function short_asset_name(identity)
    local text = tostring(identity or "")
    return text:match("%.([^%.%s]+)$") or text:match("/([^/%s]+)$")
        or text:match("([^%s]+)$") or text
end

local function same_item(item, wanted)
    local data = item_data(item)
    if not data or type(wanted) ~= "table" then return false end
    local identity = engine.full_name(data)
    if identity ~= "" and tostring(wanted.identity or "") == identity then return true end
    return short_asset_name(identity):lower() == tostring(wanted.asset or ""):lower()
end

local function slot_count(runtime)
    local count = engine.number_field(runtime.inventory,
        { "MaxSlotCount", "MaxSlots", "SlotCount" }, INVENTORY_SCAN_FALLBACK)
    return count >= 1 and count <= 500 and count or INVENTORY_SCAN_FALLBACK
end

local function find_item(runtime, wanted)
    for slot = 0, slot_count(runtime) - 1 do
        local item = item_at(runtime.inventory, slot)
        if item and same_item(item, wanted) then return runtime.inventory, slot end
    end
    for slot = 0, LOADOUT_LAST_SLOT do
        local item = item_at(runtime.loadout, slot)
        if item and same_item(item, wanted) then return runtime.loadout, slot end
    end
    return nil
end

local function prepare(entries)
    if type(entries) ~= "table" or #entries == 0 then return nil, "swap has no captured equipment" end
    local result, held_assets = {}, {}
    for _, wanted in ipairs(entries) do
        local slot = type(wanted) == "table" and tonumber(wanted.slot) or nil
        local asset = type(wanted) == "table" and tostring(wanted.asset or "") or ""
        if not slot or slot < 0 or slot > LOADOUT_LAST_SLOT or asset == "" then
            return nil, "swap contains an invalid equipment entry"
        end
        local held, key = slot == 7 or slot == 8, nil
        if held then key = asset:lower() end
        if not (held and held_assets[key]) then
            if held then held_assets[key] = true end
            result[#result + 1] = wanted
        end
    end
    table.sort(result, function(left, right) return tonumber(left.slot) < tonumber(right.slot) end)
    return result
end

local function call_method(object, method, ...)
    if not engine.is_valid(object) then return false, method .. " target is unavailable" end
    local ok_method, fn = pcall(function() return object[method] end)
    if not ok_method or not fn then return false, method .. " is unavailable" end
    local args = { ... }
    local ok, result = pcall(function() return fn(object, table.unpack(args)) end)
    if not ok then return false, tostring(result) end
    if result == false then return false, "game rejected request" end
    return true
end

local function move_item(runtime, source, source_slot, wanted)
    local target_slot = tonumber(wanted.slot)
    if source == runtime.loadout and source_slot == target_slot then return true end
    if target_slot == 7 or target_slot == 8 then
        if source ~= runtime.inventory then return false, "held item is not present in the player inventory" end
        local ok, reason = call_method(runtime.inventory_controller,
            "UseItemFromInventory", source, source_slot)
        if ok then return true end
        local server_ok, server_reason = call_method(runtime.inventory_controller,
            "Server_UseItemFromInventory", source, source_slot)
        if server_ok then return true end
        return false, tostring(reason) .. "; " .. tostring(server_reason)
    end
    return call_method(runtime.inventory_controller, "MoveItemBetweenInventories",
        source, source_slot, runtime.loadout, target_slot)
end

function M.find(id)
    local document = store.get("gear_swaps")
    for _, swap in ipairs(type(document) == "table" and document.swaps or {}) do
        if tonumber(swap.id) == tonumber(id) then return swap end
    end
    return nil
end

function M.is_pending() return pending end

function M.on_status(listener)
    if type(listener) == "function" then listeners[#listeners + 1] = listener end
end

function M.apply(id)
    id = tonumber(id)
    local swap = M.find(id)
    if not swap then return false, "Swap " .. tostring(id or "?") .. " does not exist" end
    if pending then return false, "another gear swap is waiting for server confirmation" end

    local entries, prepare_error = prepare(swap.equipment)
    if not entries then return false, prepare_error end
    local runtime, runtime_error = engine.player_runtime()
    if not runtime then return false, runtime_error end
    if not runtime.inventory_controller then return false, "inventory transfer controller is unavailable" end

    local missing = {}
    for _, wanted in ipairs(entries) do
        local current = item_at(runtime.loadout, wanted.slot)
        if not (current and same_item(current, wanted)) and not find_item(runtime, wanted) then
            missing[#missing + 1] = tostring(wanted.label or wanted.asset)
        end
    end
    if #missing > 0 then return false, "missing carried gear: " .. table.concat(missing, ", ") end

    local locked, lock_error = transaction.acquire("hot swap")
    if not locked then return false, lock_error end

    pending, operation_token = true, operation_token + 1
    local token, changed, correct = operation_token, 0, 0

    local function finish(ok, message)
        if token ~= operation_token then return end
        pending = false
        transaction.release("hot swap")
        emit(ok and "complete" or "incomplete", message, swap)
    end

    local function schedule(delay, callback)
        local ok, reason = async.after(delay, function()
            if token ~= operation_token then return end
            local ran, run_error = pcall(callback)
            if not ran then finish(false, "transaction error: " .. tostring(run_error)) end
        end)
        if not ok then finish(false, reason) end
        return ok
    end

    local verify
    verify = function(deadline, stable)
        local live, reason = engine.player_runtime()
        if not live then finish(false, reason); return end
        local outstanding = {}
        for _, wanted in ipairs(entries) do
            local equipped = item_at(live.loadout, wanted.slot)
            if not (equipped and same_item(equipped, wanted)) then
                outstanding[#outstanding + 1] = tostring(wanted.label or wanted.asset)
            end
        end
        if #outstanding == 0 then
            stable = (stable or 0) + 1
            if stable >= 2 then
                finish(true, ("%s: %d changed, %d already correct; server verified")
                    :format(tostring(swap.name), changed, correct))
            else
                schedule(0.15, function() verify(deadline, stable) end)
            end
        elseif engine.real_time_seconds() >= deadline then
            finish(false, tostring(swap.name) .. " incomplete; current equipment kept: "
                .. table.concat(outstanding, ", "))
        else
            schedule(0.15, function() verify(deadline, 0) end)
        end
    end

    local dispatch
    dispatch = function(index)
        if index > #entries then
            schedule(0.15, function()
                verify(engine.real_time_seconds() + tonumber(config.VerifyTimeoutSeconds or 5), 0)
            end)
            return
        end
        local wanted = entries[index]
        local live, reason = engine.player_runtime()
        if not live then finish(false, reason); return end
        local equipped = item_at(live.loadout, wanted.slot)
        if equipped and same_item(equipped, wanted) then
            correct = correct + 1
            dispatch(index + 1)
            return
        end
        local source, source_slot = find_item(live, wanted)
        if not source then
            finish(false, tostring(wanted.label or wanted.asset) .. " disappeared during swap")
            return
        end
        local moved, move_error = move_item(live, source, source_slot, wanted)
        if not moved then
            finish(false, tostring(wanted.label or wanted.asset) .. " was rejected: " .. tostring(move_error))
            return
        end
        changed = changed + 1
        schedule((tonumber(config.DispatchIntervalMs) or 70) / 1000,
            function() dispatch(index + 1) end)
    end

    local started, start_error = async.after(0, function() dispatch(1) end)
    if not started then
        pending = false
        transaction.release("hot swap")
        return false, start_error
    end
    emit("queued", ("applying %s (%d target slots)"):format(tostring(swap.name), #entries), swap)
    return true, ("queued %s with %d target slot(s)"):format(tostring(swap.name), #entries)
end

-- Compatibility for older module runtimes. Repeated calls are intentionally
-- idempotent and no longer restore a captured return set.
function M.toggle(id)
    return M.apply(id)
end

function M.start(options)
    config = type(options) == "table" and options or config
    return true
end

function M.stop()
    operation_token = operation_token + 1
    pending, listeners = false, {}
    transaction.release("hot swap")
    return true
end

return M
