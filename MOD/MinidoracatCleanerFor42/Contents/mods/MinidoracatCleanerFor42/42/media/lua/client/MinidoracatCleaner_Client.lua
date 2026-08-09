require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner

-- 本地插入一行紅色系統訊息到聊天室預設頻道（僅 MP 有聊天面板；SP 自動跳過）
-- ISChat.addLineInChat 是 vanilla OnAddMessage 官方入口（ISChat.lua:707,1176），
-- message 僅需 getTextWithPrefix/getAuthor/setText（duck-typing，chatMessages 後續只呼叫 getTextWithPrefix）
local function addChatLine(text)
    local chat = ISChat and ISChat.instance
    if not chat or not chat.defaultTab or chat.defaultTab.tabID == nil or not ISChat.addLineInChat then
        return
    end
    local line = "<RGB:1,0.3,0.2>" .. text
    ISChat.addLineInChat({
        getTextWithPrefix = function() return line end,
        getAuthor = function() return nil end,
        setText = function() end,
    }, chat.defaultTab.tabID)
end

local function describeDetail(kind, detail)
    if not detail then
        return nil
    end
    if kind == "items" then
        -- fullType → 顯示名稱（ISInventoryPaneContextMenu.lua:1861 同款）
        local script = getScriptManager():FindItem(detail)
        if script then
            return script:getDisplayName()
        end
    elseif kind == "animals" then
        -- 動物「群組」沒有原版翻譯鍵可用：vanilla 只有分性別年齡的 IGUI_AnimalType_*
        -- （rat→公老鼠、ratfemale→母老鼠…），對應不到群組這個概念，故用本 MOD 自己的鍵。
        -- getText 查不到時會原樣回傳 key，就 fallback 成群組原名——別的 MOD 新增的群組
        -- 因此仍能正常顯示，不會變成空字串
        local key = "IGUI_MinidoracatCleaner_AnimalGroup_" .. tostring(detail)
        local translated = getText(key)
        if translated and translated ~= key then
            return translated
        end
    end
    return tostring(detail)
end

-- 頭上的 halo 只顯示一次就讓它自然消失（240 frame ≈ 4 秒，setHaloNote 五參數自訂時長，
-- vanilla 用例 ISMoveableSpriteProps.lua:3304）。原本會每 3 秒重掛一次撐到下一輪掃描，
-- 因為 halo 預設只有 128 frame（IsoGameCharacter.java:592）且會被經驗值等其他 halo 蓋掉；
-- 但聊天室那條紅字本來就是不會被蓋掉、可回頭翻閱的可靠通道，頭上長掛只是干擾視線。
local HALO_FRAMES = 240

function Cleaner.showWarning(playerObj, payload)
    if not playerObj then
        return
    end
    payload = payload or {}
    local key
    if payload.kind == "animals" then
        key = payload.scope == "zone"
            and "IGUI_MinidoracatCleaner_WarnAnimalsZone"
            or "IGUI_MinidoracatCleaner_WarnAnimals"
    else
        key = "IGUI_MinidoracatCleaner_WarnItems"
    end
    local text = getText(key)
    local detail = describeDetail(payload.kind, payload.detail)
    if detail then
        -- 帶上實際偵測數與當前上限，玩家才知道超出多少、要清掉多少才會停
        if payload.count and payload.limit then
            text = text .. " " .. getText(
                "IGUI_MinidoracatCleaner_WarnDetail",
                detail,
                tostring(payload.count),
                tostring(payload.limit)
            )
        else
            text = text .. " (" .. detail .. ")"
        end
    end
    playerObj:setHaloNote(text, 255, 70, 60, HALO_FRAMES)
    addChatLine(text)
    -- vanilla UI 音效用法（ISButton.lua:46）
    getSoundManager():playUISound("UIActivateButton")
end

function Cleaner.showCleaned(playerObj, payload)
    if not playerObj or not payload then
        return
    end
    local key
    if payload.kind == "animals" then
        key = payload.scope == "zone"
            and "IGUI_MinidoracatCleaner_CleanedAnimalsZone"
            or "IGUI_MinidoracatCleaner_CleanedAnimals"
    else
        key = "IGUI_MinidoracatCleaner_CleanedItems"
    end
    local detail = describeDetail(payload.kind, payload.detail) or "?"
    local text = getText(key, detail, tostring(payload.count or 0))
    -- 動物清理為「玩家附近動態集合」分波執行，附上剩餘數避免誤會只清了本波數量
    if payload.remaining ~= nil then
        text = text .. " " .. getText("IGUI_MinidoracatCleaner_CleanedRemaining", tostring(payload.remaining))
    end
    addChatLine(text)
    playerObj:setHaloNote(text, 120, 255, 120, HALO_FRAMES)
end

local function onServerCommand(module, command, args)
    if module ~= Cleaner.COMMAND_MODULE then
        return
    end
    if command == "warn" then
        Cleaner.showWarning(getPlayer(), args)
    elseif command == "cleaned" then
        Cleaner.showCleaned(getPlayer(), args)
    elseif command == "refreshUI" then
        -- 伺服器端刪除容器物品後，客戶端的容器資料會被封包更新，但物品欄面板有自己的顯示
        -- 快取、不會自動重建 → 玩家看到已刪除的「幽靈物品」還留在架上，得丟一件東西進去
        -- 再拿出來才會刷新。dirtyUI 會一併刷新 playerInventory 與 lootInventory
        ISInventoryPage.dirtyUI()
    end
end

Events.OnServerCommand.Add(onServerCommand)
