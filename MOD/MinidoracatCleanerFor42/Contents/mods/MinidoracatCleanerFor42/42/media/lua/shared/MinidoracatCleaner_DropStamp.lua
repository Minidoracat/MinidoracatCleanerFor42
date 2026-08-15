require "MinidoracatCleaner_Core"
require "TimedActions/ISDropWorldItemAction"
require "TimedActions/ISDropVehicleItemAction"
require "TimedActions/ISTransferAction"
require "TimedActions/ISGrabItemAction"

if isClient() then
    return
end

local Cleaner = MinidoracatCleaner

local function stamp(item, character)
    -- TouchTraceEnabled 只關 stamp，不關 markDirty（dirty queue 屬功能二，不受追蹤開關影響）
    if item and character and Cleaner.getOption("TouchTraceEnabled") ~= false then
        Cleaner.stampItem(item, Cleaner.KEY_DROPPED, character:getUsername())
        -- 丟棄也是一次「操作」：兩章同步蓋，tooltip 的操作者/時間才不會停在上一手
        Cleaner.stampMove(item, character:getUsername())
    end
end

local function stampMove(item, character)
    if item and character and Cleaner.getOption("TouchTraceEnabled") ~= false then
        Cleaner.stampMove(item, character:getUsername())
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
        else
            -- 一般容器對容器轉移，isClient()==false 且真的由 Lua 執行搬移的路徑——單機必然；
            -- 伺服器端的一般轉移是純 Java（Transaction.java:294,301），只有 dropOnFloor 交易
            -- 會經過本函式。isClient()==true 的環境（MP 玩家，含開服者自己的遊戲端）
            -- perform 會跳過 transferItem（ISInventoryTransferAction.lua:501-503），
            -- 由 Client.lua 回報、Commands 蓋章——兩條路徑以 isClient() 互斥，不會重複。
            -- 「自己身上搬到自己身上」跳過：整理背包是最高頻操作，無鑑識價值且徒增 modData 寫入。
            -- getCharacter 對玩家背包與其內袋皆非 nil（isSyncableContainer 同款判定）。
            -- 用回傳的 result 而非傳入的 item：點燃的蠟燭／油燈轉移時會銷毀換新
            -- （ISTransferAction.lua:168-183）
            local sameOwner = character and srcContainer and destContainer
                and srcContainer:getCharacter() == character
                and destContainer:getCharacter() == character
            if not sameOwner then
                stampMove(result or item, character)
            end
        end
        return result
    end

    -- 撿地板有獨立實作（ISGrabItemAction.lua:121-137 直接 AddItem，不經 ISTransferAction），
    -- 單機需在此蓋章。**必須 nil-guard**：ISGrabItemAction 是 client-only 檔，dedicated server
    -- 對 client 目錄只算 checksum 不執行（GameServer.java:1450-1452），require 找不到靜默回 nil
    -- ——不 guard 的話這裡 deref nil 會讓整個 install callback 中斷，連下面的
    -- OnProcessTransaction 註冊都到不了（本檔其他三個 hook 目標都在 shared/，才一直沒事）。
    -- dedicated 的撿取本來就由 Client.lua 回報，跳過無缺口
    if ISGrabItemAction then
        local originalGrabTransfer = ISGrabItemAction.transferItem
        function ISGrabItemAction:transferItem(worldItem)
            local result = originalGrabTransfer(self, worldItem)
            if not isClient() and worldItem and worldItem.getItem then
                stampMove(worldItem:getItem(), self.character)
            end
            return result
        end
    end

    Events.OnProcessTransaction.Add(onProcessTransaction)
end

Events.OnGameStart.Add(installDropHooks)
Events.OnServerStarted.Add(installDropHooks)
