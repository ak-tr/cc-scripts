-- chest_auto_route.lua (parallelised)
-- Routes items from parent chest into other chests that already contain the same item ID.
-- If no match is found, moves the item to a fallback chest.
-- Logs to terminal + bottom monitor; success/fail tones via left speaker.

-- === Config ===
local PARENT_NAME    = "minecraft:chest_3"
local FIRST_IDX      = 4
local LAST_IDX       = 140
local LOOP_DELAY     = 0
local FALLBACK_NAME  = "charm:variant_chest_2"
local BATCH_SIZE     = 200                   -- stay under ~255 events
local _unpack        = table.unpack or unpack

-- === Peripherals ===
local parentChest    = peripheral.wrap(PARENT_NAME)
if not parentChest then error(("Parent chest '%s' not found."):format(PARENT_NAME)) end

local fallbackChest  = peripheral.wrap(FALLBACK_NAME)
local monitor        = peripheral.wrap("monitor_0")
local speaker        = peripheral.wrap("left")

-- Build fixed list of destination chests (exclude parent; exclude fallback from matching)
local destChests = {}
for i = FIRST_IDX, LAST_IDX do
    local name = ("minecraft:chest_%d"):format(i)
    local wrapped = peripheral.wrap(name)
    if wrapped then table.insert(destChests, wrapped) end
end

-- === Monitor setup ===
if monitor then
    pcall(function()
        monitor.setTextScale(0.5)
        if monitor.setTextColor then
            monitor.setTextColor(colors.white)
            monitor.setBackgroundColor(colors.black)
        end
        monitor.clear()
        monitor.setCursorPos(1, 1)
    end)
end

-- === Logging + Sounds ===
local function monitorWriteLine(msg)
    if not monitor then return end
    local ok, w, h = pcall(monitor.getSize); if not ok then return end
    local _, y = monitor.getCursorPos()
    local i, len = 1, #msg
    while i <= len do
        local line = string.sub(msg, i, i + w - 1)
        if y > h then monitor.scroll(1); y = h end
        monitor.setCursorPos(1, y); monitor.write(line); y = y + 1
        i = i + w
    end
    monitor.setCursorPos(1, y)
end

local function log(fmt, ...)
    local msg = (select('#', ...) > 0) and string.format(fmt, ...) or fmt
    print(msg); monitorWriteLine(msg)
end

local function successTone() if speaker then pcall(function() speaker.playNote("bell", 2, 21) end) end end
local function failTone()    if speaker then pcall(function() speaker.playNote("basedrum", 2, 6) end) end end

-- === Helpers ===
local function moveToChest(srcPeriph, fromSlot, dstPeriph)
    return peripheral.call(peripheral.getName(srcPeriph), "pushItems", peripheral.getName(dstPeriph), fromSlot)
end

-- Pretty display name for logs
local function prettyName(inv, slot, listed)
    local id = listed and listed.name or nil
    local detail = inv.getItemDetail and inv.getItemDetail(slot) or nil
    local disp = detail and (detail.displayName or detail.name) or id
    return disp or "Unknown item"
end

-- Build an index of which item IDs exist in which chest, in parallel once per tick
-- Returns: index[chestName] = { [itemId] = true, ... }
local function buildChestIndex(chests)
    local index = {}
    local funcs = {}

    for _, chest in ipairs(chests) do
        local chestLocal = chest
        table.insert(funcs, function()
            local name = peripheral.getName(chestLocal)
            local list = chestLocal.list() or {}
            local set = {}
            for _, it in pairs(list) do
                if it.name then set[it.name] = true end
            end
            index[name] = set
        end)
    end

    for i = 1, #funcs, BATCH_SIZE do
        parallel.waitForAll(_unpack(funcs, i, math.min(i + BATCH_SIZE - 1, #funcs)))
    end
    return index
end

-- === Init logs ===
if #destChests == 0 then
    log("[INIT] No destination chests found between indices.")
else
    log("[INIT] Dest chests: %d", #destChests)
end
if fallbackChest then
    log("[INIT] Fallback chest available: %s", FALLBACK_NAME)
else
    log("[WARN] Fallback chest not found: %s", FALLBACK_NAME)
end

-- === Main loop ===
while true do
    -- Snapshot all destination chests in parallel
    local chestIndex = buildChestIndex(destChests)

    -- Route items from parent
    local listed = parentChest.list()
    if listed then
        for slot, item in pairs(listed) do
            local idName = item and item.name or nil
            if not idName then
                log("[WARN] Could not read name for slot %d", slot)
            else
                local display = prettyName(parentChest, slot, item)

                -- Find first chest containing this item ID
                local target = nil
                for _, chest in ipairs(destChests) do
                    local cname = peripheral.getName(chest)
                    local set = chestIndex[cname]
                    if set and set[idName] then target = chest; break end
                end

                if target then
                    local moved = moveToChest(parentChest, slot, target)
                    if moved and moved > 0 then
                        log("[OK] Moved %d x %s (slot %d) -> %s", moved, display, slot, peripheral.getName(target))
                    else
                        log("[FULL] No room in %s for %s (slot %d).", peripheral.getName(target), display, slot)
                    end
                else
                    log("[SKIP] No match for %s (slot %d).", display, slot)
                    if fallbackChest then
                        local moved = moveToChest(parentChest, slot, fallbackChest)
                        if moved and moved > 0 then
                            log("[FALLBACK] Moved %d x %s (slot %d) -> %s", moved, display, slot, FALLBACK_NAME)
                            failTone()
                        else
                            log("[FULL] No room in fallback %s for %s (slot %d).", FALLBACK_NAME, display, slot)
                            failTone()
                        end
                    else
                        log("[WARN] Fallback chest '%s' unavailable; leaving %s in parent.", FALLBACK_NAME, display)
                        failTone()
                    end
                end
            end
        end
    end

    if LOOP_DELAY > 0 then sleep(LOOP_DELAY) end
end
