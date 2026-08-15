if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner

local lastCommandAt = {}

-- limit 預設沿用刪除上限；truncate=true 時超量截斷而非整批拒絕——
-- 刪除類指令要防濫用（超量＝惡意，整批拒），touch 類寧漏尾端也不讓正常大批搬運全數失效
local function normalizeIDs(args, limit, truncate)
    if not args or type(args.ids) ~= "table" then
        return nil
    end
    limit = limit or Cleaner.CONSTANTS.MANUAL_DELETE_LIMIT
    local result = {}
    local seen = {}
    local count = 0
    for _, rawID in pairs(args.ids) do
        count = count + 1
        if count > limit then
            if truncate then
                break
            end
            return nil
        end
        local id = tonumber(rawID)
        if id and id >= 0 and id == math.floor(id) and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    return result
end

local function logManualDelete(playerObj, removedByType, removed)
    if removed == 0 then
        return
    end
    local details = {}
    for fullType, count in pairs(removedByType) do
        details[#details + 1] = Cleaner.sanitize(fullType) .. "=" .. count
    end
    Cleaner.sortSafe(details, function(a, b) return a < b end)
    local square = playerObj:getCurrentSquare()
    Cleaner.log(
        "manual_delete",
        playerObj:getUsername(),
        square and square:getX() or 0,
        square and square:getY() or 0,
        square and square:getZ() or 0,
        "removed=" .. removed .. " types=" .. table.concat(details, ",")
    )
end

local function deleteItems(playerObj, args)
    if Cleaner.getOption("AllowManualDelete") == false then
        return
    end
    local ids = normalizeIDs(args)
    if not ids or #ids == 0 then
        return
    end

    -- 整批共用一份索引：舊版每個 id 都要重掃一次周遭（9 格 × 其中每個容器全走訪），
    -- 刪 90 件就是同一份掃描跑 90 遍，而且全在伺服器主執行緒同步做完
    local index = Cleaner.buildAccessibleIndex(playerObj, 1, ids)

    local removedByType = {}
    local removed = 0
    for _, id in ipairs(ids) do
        local found = index[id]
        local item = found and found.item
        if item and Cleaner.canManuallyDelete(playerObj, item) then
            local deleted = false
            if found.kind == "floor" then
                if found.worldObj:getItem() == item and found.worldObj:getSquare() == found.square then
                    deleted = Cleaner.removeFloorItem(item, found.worldObj, found.square)
                end
            elseif found.kind == "container" and item:getContainer() == found.container then
                deleted = Cleaner.removeContainerItem(item, found.container)
            end
            if deleted then
                removed = removed + 1
                local fullType = item:getFullType()
                removedByType[fullType] = (removedByType[fullType] or 0) + 1
            end
        end
    end
    logManualDelete(playerObj, removedByType, removed)

    -- 刪除封包（GameServer.sendRemoveItemFromContainer:2445-2461）只更新客戶端的容器**資料**，
    -- 不會叫物品欄面板重繪；ISInventoryPane 有自己的顯示快取，要等事件才重建。結果是玩家看著
    -- 已刪除的「幽靈物品」還留在貨架上，得丟一件東西進去再拿出來，用一次真實互動逼面板重建。
    -- 廣播給附近玩家而非只給操作者：兩人同時開著同一個貨架時，只刷新操作者會讓另一人
    -- 繼續盯著幽靈物品。以操作者位置為錨點即可涵蓋所有可能開著該容器的人（刪除範圍只有 1 格）。
    -- 走本 MOD 自己的通道而不是原版的 ui/DirtyUI：ServerCommands.OnServerCommand（:201-209）
    -- 對每一則認得的指令都 print 一行到 console.txt，而那正是我們查 MOD 錯誤的地方。
    if removed > 0 then
        Cleaner.refreshNearbyUI(playerObj:getX(), playerObj:getY(), playerObj:getZ())
    end
end

-- MP 唯一的「最後操作者」蓋章路徑：client 於轉移動作完成後回報物品 ID（見 Client.lua），
-- username 一律取自連線身分（OnClientCommand 第三參數，GameServer.java:2243-2294），
-- 不採 client 聲稱值——無法栽贓他人。但偽造封包能做到「物品一件不動就把可及範圍內
-- 他人的章覆蓋成自己的名字」（洗章）：modData 章可被覆蓋，故下方在覆蓋他人章時
-- 另寫一行聚合 log 當第二份證據——log 檔 client 動不了，洗章洪水會留下連續大量
-- overwritten 記錄、藏不住。範圍受 buildAccessibleIndex 的 1 格＋safehouse／阻隔檢查約束
local function touchItems(playerObj, args)
    if Cleaner.getOption("TouchTraceEnabled") == false then
        return
    end
    local ids = normalizeIDs(args, Cleaner.CONSTANTS.TOUCH_BATCH_LIMIT, true)
    if not ids or #ids == 0 then
        return
    end
    local username = playerObj:getUsername()
    -- 與 stampMove 寫入值同一套消毒（sanitizeName），覆蓋比對與 ack 回推才不會不一致
    local sanitizedName = Cleaner.sanitizeName(username)
    local index = Cleaner.buildAccessibleIndex(playerObj, 1, ids)
    local acknowledged = {}
    local stampedAt = nil
    local overwritten = 0
    for _, id in ipairs(ids) do
        local found = index[id]
        -- 只蓋容器內物品：地板物品的章由丟棄路徑負責（DropStamp），且撿進背包後即屬 container
        if found and found.kind == "container" and found.item then
            local previous = Cleaner.getItemModDataValue(found.item, Cleaner.KEY_MOVED)
            if previous and previous ~= sanitizedName then
                overwritten = overwritten + 1
            end
            stampedAt = Cleaner.stampMove(found.item, username) or stampedAt
            acknowledged[#acknowledged + 1] = id
        end
    end
    local square = playerObj:getCurrentSquare()
    local x = square and square:getX() or 0
    local y = square and square:getY() or 0
    local z = square and square:getZ() or 0
    if #acknowledged > 0 then
        local payload = {
            ids = acknowledged,
            name = sanitizedName,
            at = stampedAt,
        }
        -- 除操作者外也推給附近玩家回寫本地副本：交易完成當下的整件重傳早於蓋章，
        -- 正開著同一容器的旁觀者若不推送會停在舊值，直到下次整包重送。半徑同幽靈物品
        -- 刷新的理由（UI_REFRESH_RADIUS）；旁觀者端的回寫索引只有 1 格，天然只影響
        -- 真的貼著容器看的人
        for _, nearbyPlayer in ipairs(Cleaner.getActivePlayers()) do
            if Cleaner.chebyshevDistance(nearbyPlayer:getX(), nearbyPlayer:getY(), x, y)
                <= Cleaner.CONSTANTS.UI_REFRESH_RADIUS then
                sendServerCommand(nearbyPlayer, Cleaner.COMMAND_MODULE, "touchAck", payload)
            end
        end
        if overwritten > 0 then
            -- 一批一行（聚合寫入，ZLogger 10MB 截斷限制）。正常共用基地互相拿取也會出現，
            -- 但洗章洪水會爆出連續的 overwritten=數百，模式差異一目了然
            Cleaner.log("touch_overwrite", username, x, y, z,
                "overwritten=" .. overwritten .. " batch=" .. #acknowledged)
        end
    elseif Cleaner.getOption("DebugMenuEnabled") == true then
        -- 全 miss 是診斷訊號（瞬移離場、物品已銷毀、原版改動讓 client 批次假設失效），
        -- 但誠實 client 幾乎不會走到——能大量產生這行的只有偽造封包，逐包寫入等於
        -- 送攻擊者一支日誌洪水原語（ZLogger >10MB 原檔截斷，可沖掉 touch_overwrite
        -- 證據），故只在 debug 開關下產出
        Cleaner.log("touch_miss", username, x, y, z, "ids=" .. #ids)
    end
end

-- 認得的 command 才進節流表：節流 key 含 command 字串，若未知 command 也先寫入，
-- 任意偽造字串可讓 lastCommandAt 無界成長（記憶體 DoS）；table lookup 對非字串
-- command 也安全（字串串接則會拋例外）
local HANDLERS = { deleteItems = deleteItems, touch = touchItems }
-- 各 command 的最小間隔（ms）。touch 放寬到 1000：client 端以 ≥1.1 秒間隔聚合送出
-- （Client.lua flushTouch），正常玩家不會撞到；偽造洪水觸發周遭掃描的速率則被砍到 1/s
local MIN_INTERVAL = { deleteItems = 250, touch = 1000 }

local function onClientCommand(module, command, playerObj, args)
    if module ~= Cleaner.COMMAND_MODULE or not playerObj then
        return
    end
    local handler = HANDLERS[command]
    if not handler then
        return
    end
    -- per-player-per-command 節流：偽造封包每次都會觸發一輪周遭掃描（server 主執行緒），
    -- 未達最小間隔直接丟棄。分 command 計數，搬運回報的節流不會誤傷緊接著的刪除操作
    local key = command .. ":" .. playerObj:getUsername()
    local now = getTimestampMs()
    local last = lastCommandAt[key]
    if last and now - last < MIN_INTERVAL[command] then
        return
    end
    lastCommandAt[key] = now
    handler(playerObj, args)
end

-- GameServer.java:2243-2294
Events.OnClientCommand.Add(onClientCommand)
