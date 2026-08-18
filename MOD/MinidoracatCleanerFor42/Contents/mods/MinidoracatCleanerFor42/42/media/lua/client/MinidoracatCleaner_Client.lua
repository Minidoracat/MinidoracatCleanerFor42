require "MinidoracatCleaner_Core"
require "TimedActions/ISInventoryTransferAction"
require "TimedActions/ISGrabItemAction"

local Cleaner = MinidoracatCleaner

-- 本地插入一行紅色系統訊息到聊天室預設頻道（僅 MP 有聊天面板；SP 自動跳過）
-- ISChat.addLineInChat 是 vanilla OnAddMessage 官方入口（ISChat.lua:707,1176）。
--
-- 這個 message 是 duck-typing 出來的，不是真的 ChatMessage。vanilla 的 chatMessages 只會呼叫
-- getTextWithPrefix，但 **addLineInChat 是常被第三方 MOD 包起來的入口**，包裝者會對 message
-- 呼叫任何 ChatMessage 方法來判斷訊息類型。實機實測：漢化包的 wrapper 用
-- `pcall(function() return message:getRadioChannel() end)` 判斷是否電台訊息
-- （AEBSWeather_Flx.lua:287-290），缺這個方法時 Kahlua 會記一筆「Tried to call nil」＋完整
-- 堆疊——功能不受影響（對方有 pcall、且失敗就當非電台訊息），但每則警告與每則清理通知各洗
-- 一次 log（單場測試 37 次），開 -debug 且啟用 Break On Error 時還會彈出除錯器暫停遊戲。
-- 通則：對外交出的 duck-typed vanilla 物件，要補齊「合理的包裝者會先問的那些 getter」，
-- 不能只滿足 vanilla 自己的呼叫路徑
local function addChatLine(text)
    local chat = ISChat and ISChat.instance
    if not chat or not chat.defaultTab or chat.defaultTab.tabID == nil or not ISChat.addLineInChat then
        return
    end
    local line = "<RGB:1,0.3,0.2>" .. text
    ISChat.addLineInChat({
        getTextWithPrefix = function() return line end,
        getText = function() return text end,
        -- vanilla ChatMessage.radioChannel 預設 -1＝非電台訊息（ChatMessage.java:23，
        -- getter 在 :65；只有 ChatManager.showRadioMessage 與 RadioChat 會設成正值）
        getRadioChannel = function() return -1 end,
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

-- 伺服器端刪除只會同步容器**資料**，物品欄面板有自己的顯示快取、不會自動重建，
-- 於是架上還掛著已消失的「幽靈物品」——玩家得丟一件東西進去再拿出來，用一次真實互動
-- 逼面板重建。dirtyUI 會一併刷新 playerInventory 與 lootInventory（ISInventoryPage.lua:1330）
function Cleaner.refreshUI()
    if ISInventoryPage and ISInventoryPage.dirtyUI then
        ISInventoryPage.dirtyUI()
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
    -- 地板物品也顯示在戰利品面板裡，自動清理同樣會留下幽靈物品。這則通知本來就會送給
    -- 附近玩家，順手刷新即可，不必為此多送一則封包。動物不在面板裡，故只對物品做
    if payload.kind ~= "animals" then
        Cleaner.refreshUI()
    end
end

-- ===== MP client 端「最後操作者」回報 =====
-- B42 的一般容器對容器轉移在 MP 是 client 發起交易、server 純 Java 執行
-- （createItemTransaction，ISInventoryTransferAction.lua:313；Transaction.java:294,301），
-- server 端 Lua 全程收不到事件（Transaction.java:231-343 無 triggerEvent）——原版連 item log
-- 都記不到這種轉移。唯一補法：client 在動作完成時回報物品 ID，server 以**連線身分**權威
-- 蓋章（username 不採 client 聲稱值），再 touchAck 回推本地副本供 tooltip 立即顯示。
-- perform 在 server 核准並執行完交易後才會走到（update 輪詢 isItemTransactionDone，
-- ISInventoryTransferAction.lua:161-177），故不會回報被拒絕的操作。

-- 待回報緩衝：原版把混合類型的批量搬運切成逐類型批次、每批一次 perform
-- （checkQueueList，ISInventoryTransferAction.lua:712-744），輕物品批間隔遠小於
-- server 節流窗口——若每次 perform 都直接發封包，第二批之後會被 server 靜默丟棄。
-- 改為進緩衝、由 OnTick 以 ≥TOUCH_FLUSH_MS 間隔合併送出：一個搬運 burst 一個封包，
-- 誠實 client 永遠不會撞上 server 端節流（MIN_INTERVAL.touch=1000ms，見 Commands.lua）
-- server 端 touch 節流 1000ms（Commands.lua MIN_INTERVAL），餘裕留 500ms：
-- 只留 100ms 的話網路抖動讓兩批在 server 端相隔 <1000ms 到達時，第二批會被
-- 靜默丟棄且不留任何痕跡
local TOUCH_FLUSH_MS = 1500
-- 緩衝上限：正常遊玩不可能在一個 flush 窗口內累積到（搬運是有時長的 timed action），
-- 純粹是記憶體保險
local TOUCH_PENDING_CAP = 2000
-- 分割畫面：每位本機玩家各自一份緩衝。flush 必須以正確的玩家物件送出——
-- sendClientCommand 的封包帶 playerIndex，server 據此解析出對的子玩家與 username；
-- 全部走 player 0 會把 player 1-3 的搬運記到 player 0 名下
local touchStates = {}

local function getTouchState(playerNum)
    local state = touchStates[playerNum]
    if not state then
        state = { set = {}, list = {}, lastSentAt = 0 }
        touchStates[playerNum] = state
    end
    return state
end

local function queueTouchBatch(action, isGrabAction)
    if not action.character then
        return
    end
    -- 「自己身上搬到自己身上」不回報：與 server 端 DropStamp 的 sameOwner 過濾一致
    -- （getCharacter 對玩家背包與其內袋皆非 nil）。撿地板（grab）必然跨界，不需判
    if not isGrabAction and action.srcContainer and action.destContainer
        and action.srcContainer:getCharacter() == action.character
        and action.destContainer:getCharacter() == action.character then
        return
    end
    -- 丟到地板不回報：server 端 touchItems 對 floor 物品刻意不蓋章（章由丟棄路徑負責），
    -- 回報只是白跑一輪掃描
    if not isGrabAction and action.destContainer and action.destContainer:getType() == "floor" then
        return
    end
    local queued = action.queueList and action.queueList[1]
    if not queued or not queued.items then
        return
    end
    -- getPlayerNum：vanilla 用例 ISGrabItemAction.lua:139
    local state = getTouchState(action.character:getPlayerNum())
    for _, queuedItem in ipairs(queued.items) do
        if #state.list >= TOUCH_PENDING_CAP then
            break
        end
        local item = isGrabAction and queuedItem:getItem() or queuedItem
        if item then
            local id = item:getID()
            if not state.set[id] then
                state.set[id] = true
                state.list[#state.list + 1] = id
            end
        end
    end
end

local function flushTouch()
    -- OnTick 快路徑：touchStates 至多 4 個 key（本機玩家槽），空清單立即跳過
    local now = nil
    for playerNum, state in pairs(touchStates) do
        if #state.list > 0 then
            now = now or getTimestampMs()
            if now - state.lastSentAt >= TOUCH_FLUSH_MS then
                local playerObj = getSpecificPlayer(playerNum)
                if not playerObj then
                    -- 該分割畫面玩家已離開：緩衝作廢。清內容、不移除 key——
                    -- Kahlua table 底層是 LinkedHashMap，迭代中移除 key 有 CME 風險
                    state.set = {}
                    state.list = {}
                else
                    local batch = {}
                    local count = math.min(#state.list, Cleaner.CONSTANTS.TOUCH_BATCH_LIMIT)
                    for i = 1, count do
                        batch[i] = state.list[i]
                        state.set[batch[i]] = nil
                    end
                    if count == #state.list then
                        state.list = {}
                    else
                        -- 超量的尾端留待下一個窗口（不丟棄）
                        local rest = {}
                        for i = count + 1, #state.list do
                            rest[#rest + 1] = state.list[i]
                        end
                        state.list = rest
                    end
                    state.lastSentAt = now
                    sendClientCommand(playerObj, Cleaner.COMMAND_MODULE, "touch", { ids = batch })
                end
            end
        end
    end
end

local function installTouchReporters()
    if Cleaner._touchReportersInstalled then
        return
    end
    if not isClient() or Cleaner.getOption("TouchTraceEnabled") == false then
        return
    end
    Cleaner._touchReportersInstalled = true
    -- 只在 isClient()==true 的環境安裝（MP 玩家，含自架主機者的遊戲端——host 的遊戲
    -- 是子伺服器行程的 client）；isClient()==false（單機）由 DropStamp 的 shared hook
    -- 直接蓋章，兩條路徑以 isClient() 互斥

    local originalInventoryPerform = ISInventoryTransferAction.perform
    function ISInventoryTransferAction:perform()
        -- perform 內會消化 queueList，先抄進緩衝再呼叫原函式
        queueTouchBatch(self, false)
        return originalInventoryPerform(self)
    end

    local originalGrabPerform = ISGrabItemAction.perform
    function ISGrabItemAction:perform()
        queueTouchBatch(self, true)
        return originalGrabPerform(self)
    end

    Events.OnTick.Add(flushTouch)
end

local function applyTouchAck(args)
    local playerObj = getPlayer()
    if not playerObj or not args or type(args.ids) ~= "table" then
        return
    end
    -- 缺 name 的畸形 ack 直接忽略：sanitize(nil) 會補成 "unknown"，把缺失「補值落地」
    -- 成假操作者比不寫更糟
    if not args.name or args.name == "" then
        return
    end
    local username = Cleaner.sanitizeName(args.name)
    local at = tonumber(args.at)
    local ids = {}
    for _, id in ipairs(args.ids) do
        local numericID = tonumber(id)
        if numericID then
            ids[#ids + 1] = numericID
        end
    end
    -- 分割畫面：ack 屬於「動作者」——本機哪個子玩家的名字對上就以誰為錨建索引
    -- （server 也會把 ack 廣播給附近玩家，旁觀者 client 對不上名字→退回 player 0
    -- 盡力回寫；索引範圍 1 格，天然只影響真的貼著容器看的人）
    for i = 0, 3 do
        local candidate = getSpecificPlayer(i)
        if candidate and Cleaner.sanitizeName(candidate:getUsername()) == username then
            playerObj = candidate
            break
        end
    end
    -- server 已權威蓋章；這裡只把同樣的值寫進**本地副本**讓 tooltip 立即可見——
    -- 交易完成當下的整件重傳（AddInventoryItemToContainerPacket）早於蓋章，
    -- 不回寫的話要等該容器下次整包重送才看得到
    local index = Cleaner.buildAccessibleIndex(playerObj, 1, ids)
    for _, id in ipairs(ids) do
        local found = index[id]
        if found and found.item then
            local modData = found.item:getModData()
            rawset(modData, Cleaner.KEY_MOVED, username)
            if at then
                rawset(modData, Cleaner.KEY_MOVED_AT, at)
            end
        end
    end
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
        Cleaner.refreshUI()
    elseif command == "touchAck" then
        applyTouchAck(args)
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnGameStart.Add(installTouchReporters)
Events.OnCreatePlayer.Add(installTouchReporters)
