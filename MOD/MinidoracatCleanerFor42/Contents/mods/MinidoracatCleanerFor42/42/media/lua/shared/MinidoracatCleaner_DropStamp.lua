require "MinidoracatCleaner_Core"
require "TimedActions/ISDropWorldItemAction"
require "TimedActions/ISDropVehicleItemAction"
require "TimedActions/ISTransferAction"

if isClient() then
    return
end

local Cleaner = MinidoracatCleaner

local function stamp(item, character)
    -- TouchTraceEnabled 只關 stamp，不關 markDirty（dirty queue 屬功能二，不受追蹤開關影響）
    if item and character and Cleaner.getOption("TouchTraceEnabled") ~= false then
        Cleaner.stampItem(item, Cleaner.KEY_DROPPED, character:getUsername())
    end
end

local function markDirty(square)
    if square and Cleaner.markDirty then
        Cleaner.markDirty(square)
    end
end

local function onProcessTransaction(action, character, item, source, destination, args)
    if action ~= "dropOnFloor" then
        return
    end
    -- TransactionProcessor.lua:53-68
    stamp(item, character)
    local square = args and args.square
    if not square and item and item:getWorldItem() then
        square = item:getWorldItem():getSquare()
    end
    markDirty(square)
end

local function installDropHooks()
    if Cleaner._dropHooksInstalled then
        return
    end
    Cleaner._dropHooksInstalled = true

    local originalWorldComplete = ISDropWorldItemAction.complete
    function ISDropWorldItemAction:complete()
        stamp(self.item, self.character)
        local result = originalWorldComplete(self)
        stamp(self.item, self.character)
        local square = self.item and self.item:getWorldItem() and self.item:getWorldItem():getSquare() or self.sq
        markDirty(square)
        return result
    end

    local originalVehicleComplete = ISDropVehicleItemAction.complete
    function ISDropVehicleItemAction:complete()
        stamp(self.item, self.character)
        local result = originalVehicleComplete(self)
        stamp(self.item, self.character)
        local square = self.item and self.item:getWorldItem() and self.item:getWorldItem():getSquare() or self.dropSquare
        markDirty(square)
        return result
    end

    local originalTransfer = ISTransferAction.transferItem
    function ISTransferAction:transferItem(character, item, srcContainer, destContainer, dropSquare)
        local dropsOnFloor = destContainer and destContainer:getType() == "floor"
        if dropsOnFloor then
            stamp(item, character)
        end
        local result = originalTransfer(self, character, item, srcContainer, destContainer, dropSquare)
        if dropsOnFloor then
            stamp(result or item, character)
            local square = result and result:getWorldItem() and result:getWorldItem():getSquare() or dropSquare
            markDirty(square)
        end
        return result
    end

    Events.OnProcessTransaction.Add(onProcessTransaction)
end

Events.OnGameStart.Add(installDropHooks)
Events.OnServerStarted.Add(installDropHooks)
