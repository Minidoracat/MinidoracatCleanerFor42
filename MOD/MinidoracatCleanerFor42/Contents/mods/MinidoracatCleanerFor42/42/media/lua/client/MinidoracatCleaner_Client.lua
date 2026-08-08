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
    end
    return tostring(detail)
end

-- 持續警告狀態：halo 預設只顯示 128 frame（IsoGameCharacter.java:592）且會被其他 halo（經驗值等）蓋掉，
-- 故每 3 秒重掛一次（setHaloNote 五參數自訂時長，vanilla 用例 ISMoveableSpriteProps.lua:3304），
-- 直到「清理完成」通知到達或確認窗到期
local activeWarn = nil

local function warningWindowMs(kind)
    local name = kind == "animals" and "AnimalScanIntervalSeconds" or "ScanIntervalSeconds"
    local seconds = tonumber(Cleaner.getOption(name)) or 60
    return (seconds + 5) * 1000
end

local function refreshWarnHalo()
    local playerObj = getPlayer()
    if playerObj and activeWarn then
        -- 240 frame ≈ 4 秒，配 3 秒重掛間隔形成連續顯示（IsoGameCharacter.java:6958）
        playerObj:setHaloNote(activeWarn.text, 255, 70, 60, 240)
    end
end

local function onTickWarn()
    if not activeWarn then
        return
    end
    local now = getTimestampMs()
    if now >= activeWarn.expireAt then
        activeWarn = nil
        return
    end
    if now >= activeWarn.nextRefreshAt then
        activeWarn.nextRefreshAt = now + 3000
        refreshWarnHalo()
    end
end

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
        text = text .. " (" .. detail .. ")"
    end
    local now = getTimestampMs()
    activeWarn = {
        text = text,
        expireAt = now + warningWindowMs(payload.kind),
        nextRefreshAt = now + 3000,
    }
    refreshWarnHalo()
    addChatLine(text)
    -- vanilla UI 音效用法（ISButton.lua:46）
    getSoundManager():playUISound("UIActivateButton")
end

function Cleaner.showCleaned(playerObj, payload)
    if not playerObj or not payload then
        return
    end
    -- 清理已發生：停止持續警告
    activeWarn = nil
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
    playerObj:setHaloNote(text, 120, 255, 120, 240)
end

local function onServerCommand(module, command, args)
    if module ~= Cleaner.COMMAND_MODULE then
        return
    end
    if command == "warn" then
        Cleaner.showWarning(getPlayer(), args)
    elseif command == "cleaned" then
        Cleaner.showCleaned(getPlayer(), args)
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTickWarn)
