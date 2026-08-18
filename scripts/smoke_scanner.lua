--[[
用假的 PZ 全域驅動真正的 Core.lua / WorldScanner.lua / Commands.lua，跑二十個情境並斷言結果。

    lua scripts/smoke_scanner.lua        （在 repo 根目錄執行）

情境一：自動清理的 normal／high 雙桶分流（掃描 → 警告 → 下一輪確認 → 刪除）
情境二：批次手動刪除的索引建立與安全邊界（範圍外、被牆阻隔、最愛物品都不得被刪）
情境三：提早退出（只刪背包內物品時不得掃描世界，但也不得因此略過把關）
情境四：拒絕路徑（保險屋拒絕、無所在格）與記憶體配置上限
情境五：週期掃描修復被刪空的容器（三種正常狀態當對照組，確認修復不外溢）
情境六：Kahlua 缺少的標準 Lua 全域（原始碼靜態掃描）
情境七：批量生成動物的右鍵選單預設值（單人／MP／管理員／-debug 四種組合）
情境八：chunk-scope 警告記錄的生命週期——區塊卸載時不得誤判「已解決」，回到上限內要即時
        回收，未觀測超過 staleMs 也要回收（不得無界滯留）
情境九：area-scope 的同款生命週期——判定只看「這筆計數的來源區塊」有沒有本輪未觀測到的，
        而不是「區域內任一區塊未觀測」（後者恆真，掃描盒比引擎載入視窗大一圈）
情境十：area 來源清單必須合併而非覆寫——部分來源卸載時仍超標並清理後，可觀測總數會掉到
        門檻以下，清單若忘掉那個卸載來源就會誤判「已解決」（真實總數仍超標）
情境十一：掃描途中卸載——一個區塊 64 格而每 tick 預算 48 格，掃描必定跨 tick，載入狀態
          必須每個 tick 重查，否則低估的計數會帶著「已觀測」而讓記錄被誤判已解決
情境十二：area 記錄是 per-player——玩家搬家後，舊來源區塊即使還在別人的掃描盒裡（且未載入），
          也不得再算進他的來源集，否則 underCounted 恆真 ⇒ 記錄永遠不會在達標輪被回收 ⇒
          下次超標時直接沿用舊記錄清理、不再給玩家警告
情境十三：area 刪除前的 live recount——佇列跨 tick 消化時，玩家自己把數量撿回上限內，
          後續還排著的 victim 必須被取消，不能刪到低於上限
情境十四：來源集依計數降冪截到 AREA_RECOUNT_CHUNKS_PER_TICK 塊，截斷後的下界若證明不了超標
          就整批不排入（否則每輪都排入註定被取消的 victim），並留下管理員可見的診斷
情境十五：來源集只保留計數最高的 N 塊——保留錯的 N 塊會讓下界證明不了超標，明顯超標的
          熱點被永久放過（同時釘住 top-N 的插入位置與替換決策）
情境十六：單 tick 的載入探測次數受額度封頂，且跨 fullType 有效（0-cache 只在同 bucket ＋
          同 fullType 之間共用，多型別的 victim 會各自重新探測同一批卸載來源）
情境十七：單一格子的物品數超過走訪額度時，計數必須跨 tick 續算（格數封頂不等於成本封頂：
          worldObjects 沒有容量上限），且單 tick 的走訪峰值不得超過額度
情境十八：victim 落在超大同格清單尾端時仍要找得到（find 必須反向掃，因為候選依 item ID
          由大到小挑而掉落物 append 在尾端）；victim 前面隔著超過額度的物件時要觸頂放掉
情境十九：刪除前必須讀**當前**上限而不是排入當時的快照——管理員可在執行期改 sandbox，
          照舊值刪會刪掉當前政策允許保留的物品

為什麼需要它：luac -p 只驗語法，抓不到「改了函式簽章但漏改呼叫點」這類執行期錯誤——
hotspotKey 從兩參數改成三參數時漏改了 processDeleteQueue 的呼叫點，要等第一件物品真的被
刪除才會炸。情境二～四則是守住 buildAccessibleIndex 改寫後的可及性判定不出現漏洞，
以及配置量不隨「範圍內有幾件物品」放大（Kahlua 每個 table 都是獨立的 KahluaTableImpl／
LinkedHashMap，不是標準 Lua 那種輕量 table，10 萬筆 record 實測約 35 MiB）。

限制：這是標準 Lua 5.x，不是遊戲用的 Kahlua。它能抓邏輯／arity／nil 錯誤與可及性回歸，
但**不能**證明 Kahlua 專屬行為（table.sort 遞迴深度、Java field 不暴露、rawget 呼叫形式）。
那些仍然只能靠反編譯查證與實機測試。
]]

local MEDIA = "MOD/MinidoracatCleanerFor42/Contents/mods/MinidoracatCleanerFor42/42/media/lua"

-- ===== 假的 PZ 全域 =====
-- 起始時間必須大於掃描間隔：queuePeriodicScan 的條件是 now - lastPeriodicAt >= interval，
-- 而 lastPeriodicAt 初值為 0。遊戲裡 getTimestampMs() 本來就是很大的系統時間
local nowMs = 5000000
local logLines = {}
local sentCommands = {}

function getTimestampMs() return nowMs end
function isClient() return false end
function isServer() return true end
function writeLog(_, text) logLines[#logLines + 1] = text end
function getItemNameFromFullType(fullType) return fullType end
function getScriptManager() return { FindItem = function() return nil end } end
function sendServerCommand(playerObj, _, command, args)
    sentCommands[#sentCommands + 1] = { player = playerObj, command = command, args = args }
end
function sendRemoveItemFromContainer() end
function getText(key) return key end

DesignationZoneAnimal = { removeItemFromGround = function() end }

-- 這兩個開關供負面測試切換：保險屋拒絕、以及玩家沒有所在格
local safehouseAllows = true
local playerHasSquare = true
SafeHouse = { isSafehouseAllowLoot = function() return safehouseAllows end }

-- instanceof 只需分辨容器；假物件用 _isContainer 標記
function instanceof(obj, class)
    if class == "InventoryContainer" then
        return type(obj) == "table" and obj._isContainer == true
    end
    return false
end

SandboxVars = {
    MinidoracatCleanerFor42 = {
        MaxFloorItemsPerType = 10,
        MaxFloorItemsPerTypeArea = 40,
        HighToleranceMaxPerType = 100,
        HighToleranceMaxPerTypeArea = 400,
        HighToleranceList = "",
        ProtectList = "",
        TouchTraceEnabled = true,
        AllowManualDelete = true,
        ScanRadius = 16,
        ScanIntervalSeconds = 60,
    },
}

local tickHandlers, clientCommandHandlers, worldMenuHandlers = {}, {}, {}
Events = setmetatable({}, {
    __index = function(_, name)
        return {
            Add = function(fn)
                if name == "OnTick" then tickHandlers[#tickHandlers + 1] = fn
                elseif name == "OnClientCommand" then clientCommandHandlers[#clientCommandHandlers + 1] = fn
                elseif name == "OnFillWorldObjectContextMenu" then worldMenuHandlers[#worldMenuHandlers + 1] = fn end
            end,
        }
    end,
})

-- java 風格容器（size()/get(i)，0-based）
local function javaList(items)
    return {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
        _raw = items,
    }
end

-- ===== 世界模型 =====
local world = {}
local gridLookups = 0   -- 用來證明「提早退出」真的沒去碰世界
-- 卸載輪的活性檢查用：只計 probeChunk 這一個區塊的查詢次數。全域 gridLookups 會被其他
-- 區塊的查詢滿足，證明不了「目標區塊真的被走訪過」——AGENTS.md 踩坑錄記過這個坑：
-- 上限／缺席類斷言必須配活性檢查，否則掃描先在別處返回時測試會空轉假通過
local probeChunk = nil
local probeLookups = 0
-- 掃描器對 probeChunk 查了幾次「載入狀態」。未載入的區塊現在會被整塊跳過（只查一次載入
-- 狀態、不再逐格 getGridSquare），所以活性檢查改成「確實查過載入狀態」＋「確實沒逐格查」
-- 兩條——後者順帶釘住那個省掉 64 次無效查詢的效能改善
local probeChunkChecks = 0
-- 全域載入探測次數（不限特定區塊）：area recount 的單 tick 探測上限用它斷言
local chunkCheckTotal = 0
-- 模擬「區塊未載入」：getGridSquare 一律回 nil（Lua 端走 IsoCell.java:3181-3183 分派，
-- dedicated server 進 ServerMap.java:682-687，單機進 IsoCell.java:3197-3206），但 world 裡的
-- square 與其上的物品原封不動——這正是引擎的真實狀態（資料在存檔裡，只是沒載進記憶體）。
-- 不可改成把 square 從 world 移除：countFloor 是遍歷 world 數的，那樣連「東西還在」都測不到
local unloadedChunks = {}
-- 模擬「掃描途中卸載」：對指定區塊，第一次被查載入狀態時照常回報已載入，第二次起連同
-- getGridSquare 一律回 nil。用「被查幾次載入狀態」而不是「掃了幾格」當門檻，是因為單一區塊
-- 的掃描會從哪一格跨到下一個 tick，取決於前面區塊吃掉多少預算——綁格數的話門檻會跟著浮動。
-- 一個區塊 64 格而每 tick 預算只有 48 格 ⇒ 掃描必定跨 tick，這正是「只在起頭查一次載入狀態」
-- 擋不住、而「每個 tick 重查」才擋得住的情境
local partialUnload = nil
local function partialGone(cx, cy, z)
    return partialUnload ~= nil
        and partialUnload.key == (cx .. "," .. cy .. "," .. z)
        and partialUnload.checks > 1
end
local function squareKey(x, y, z) return x .. "," .. y .. "," .. z end

local function getOrMakeSquare(x, y, z)
    local key = squareKey(x, y, z)
    if world[key] then return world[key] end
    local square = {
        _objs = {}, _containers = {}, _blocked = false,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
        getWorldObjects = function(self) return javaList(self._objs) end,
        getStaticMovingObjects = function() return javaList({}) end,
        getObjects = function(self) return javaList(self._containers) end,
        getVehicleContainer = function() return nil end,
        isBlockedTo = function(self) return self._blocked end,
        transmitRemoveItemFromSquare = function() end,
        removeWorldObject = function(self, worldObj)
            for i, o in ipairs(self._objs) do
                if o == worldObj then table.remove(self._objs, i) break end
            end
        end,
    }
    world[key] = square
    return square
end

function getCell()
    return {
        getGridSquare = function(_, x, y, z)
            gridLookups = gridLookups + 1
            local cx, cy = math.floor(x / 8), math.floor(y / 8)
            if probeChunk and z == probeChunk.z and cx == probeChunk.cx and cy == probeChunk.cy then
                probeLookups = probeLookups + 1
            end
            if unloadedChunks[cx .. "," .. cy .. "," .. z] then
                return nil
            end
            if partialGone(cx, cy, z) then
                return nil
            end
            return world[squareKey(x, y, z)]
        end,
        -- IsoCell.getChunkForGridSquare（IsoCell.java:334-358）：參數是 world-square 座標，
        -- 未載入回 nil。harness 以「該 chunk 內建過任何 square」代表引擎已把這塊載入，
        -- 並讓 unloadedChunks 一律視為未載入，與 getGridSquare 的判定保持一致
        getChunkForGridSquare = function(_, x, y, z)
            local cx, cy = math.floor(x / 8), math.floor(y / 8)
            -- 全域計數：area recount 的載入探測上限用它斷言（情境十六）。探測不逐格查 square，
            -- 所以 gridLookups 抓不到這條成本
            chunkCheckTotal = chunkCheckTotal + 1
            if probeChunk and z == probeChunk.z and cx == probeChunk.cx and cy == probeChunk.cy then
                probeChunkChecks = probeChunkChecks + 1
            end
            if partialUnload and partialUnload.key == (cx .. "," .. cy .. "," .. z) then
                partialUnload.checks = partialUnload.checks + 1
            end
            if unloadedChunks[cx .. "," .. cy .. "," .. z] or partialGone(cx, cy, z) then
                return nil
            end
            for px = cx * 8, cx * 8 + 7 do
                for py = cy * 8, cy * 8 + 7 do
                    if world[squareKey(px, py, z)] then
                        return { cx = cx, cy = cy, z = z }
                    end
                end
            end
            return nil
        end,
    }
end

local nextID = 1000
local function makeItem(fullType, dropper)
    nextID = nextID + 1
    local modData = {}
    if dropper then modData.MIC42_lastDroppedBy = dropper end
    return {
        _id = nextID, _fullType = fullType, _modData = modData, _favorite = false, _container = nil,
        getID = function(self) return self._id end,
        getFullType = function(self) return self._fullType end,
        isFavorite = function(self) return self._favorite end,
        hasModData = function() return true end,
        getModData = function(self) return self._modData end,
        setWorldItem = function() end,
        getContainer = function(self) return self._container end,
    }
end

-- 哪張 overlay 屬於哪些底圖（ContainerOverlays.java:87-113 建的反查表）。
-- 沒登記在這裡的 overlay＝來路不明，修復必須放過它
local overlayOwners = {
    ["shelf_full"] = { "shelf_base" },
}

-- 家具容器：getParent 非 nil 才通得過 isSyncableContainer 的 MP 檢查。
-- getParent 回傳的是貨架本體（IsoObject），它身上掛著滿／空的 overlay 貼圖
local function makeContainer(owner)
    local c
    local parent = owner == "furniture" and {
        _sprite = "shelf_base",
        _overlay = "shelf_full",
        _inOverlayMap = true,     -- 底圖登記在容器 overlay 表裡＝真的是貨架
        _overlayUpdates = 0,
        _hotSaves = 0,
        getSprite = function(self) return { getName = function() return self._sprite end } end,
        getOverlaySprite = function(self)
            if not self._overlay then return nil end
            local name = self._overlay
            return { getName = function() return name end }
        end,
        getContainer = function(self) return self._container end,
        getContainerCount = function() return 1 end,
        getContainerByIndex = function(self) return self._container end,
        flagForHotSave = function(self) self._hotSaves = self._hotSaves + 1 end,
    } or nil
    c = {
        _items = {},
        _looted = false,
        _parent = parent,
        getItems = function(self) return javaList(self._items) end,
        isEmpty = function(self) return #self._items == 0 end,
        getCharacter = function() return owner == "player" and true or nil end,
        getParent = function(self) return self._parent end,
        getWorldItem = function() return nil end,
        setHasBeenLooted = function(self, value) self._looted = value end,
        isHasBeenLooted = function(self) return self._looted end,
        DoRemoveItem = function(self, item)
            for i, it in ipairs(self._items) do
                if it == item then table.remove(self._items, i) break end
            end
        end,
        add = function(self, item) self._items[#self._items + 1] = item; item._container = c; return item end,
    }
    if parent then
        -- 反向連結：讓 ItemPicker.updateOverlaySprite 能照 ContainerOverlays.java:147 的規則
        -- （容器空了就把 overlay 清成 nil）重算
        parent._container = c
    end
    return c
end

-- ContainerOverlays.java:139-178 的行為骨架：底圖沒登記在容器 overlay 表裡就把 overlay
-- 清成 nil（這正是誤判會抹掉工作站進度貼圖的原因），登記了則依件數重算
ItemPicker = {
    updateOverlaySprite = function(obj)
        if not obj then return end
        obj._overlayUpdates = (obj._overlayUpdates or 0) + 1
        if not obj._inOverlayMap or (obj._container and #obj._container._items == 0) then
            obj._overlay = nil
        end
    end,
}

-- ContainerOverlays.java:131-133 與 :135-137：底圖是否登記在容器 overlay 表裡，
-- 以及某張 overlay 反查得到哪些底圖（用來確認 overlay 真的出自容器系統）
function getContainerOverlays()
    return {
        hasOverlays = function(_, obj) return obj._inOverlayMap == true end,
        getUnderlyingSpriteNames = function(_, overlayName)
            local owner = overlayOwners[overlayName]
            return owner and javaList(owner) or nil
        end,
    }
end

-- 地板物件被實際讀取的次數。掃描／recount／find 都得先 getItem 才知道那是什麼，所以這個
-- 計數器就是「走訪成本」的直接量測，用來斷言單 tick 的物件走訪額度（情境十七）
local itemReads = 0

local function putOnFloor(x, y, z, item)
    local square = getOrMakeSquare(x, y, z)
    local worldObj = {
        getItem = function(self)
            itemReads = itemReads + 1
            return self._item
        end,
        isIgnoreRemoveSandbox = function() return false end,
        getSquare = function() return square end,
        _item = item,
    }
    square._objs[#square._objs + 1] = worldObj
    return item
end

-- 放進去的是家具本體（IsoObject），容器掛在它身上——`square:getObjects()` 拿到的是它，
-- 容器修復與可及性索引都從這個物件出發，與真實引擎一致
local function putFurniture(x, y, z, container)
    local square = getOrMakeSquare(x, y, z)
    square._containers[#square._containers + 1] = container:getParent()
end

local playerInv = makeContainer("player")
-- 座標用變數而非常數：情境十二要驗「area 記錄是 per-player」——玩家搬家後，舊來源區塊
-- 不再屬於他的掃描盒，就不該再被併進他的來源集。其餘情境都不動這兩個值，行為與原本相同
local playerX, playerY = 100, 100
local player = {
    getX = function() return playerX end,
    getY = function() return playerY end,
    getZ = function() return 0 end,
    getUsername = function() return "tester" end,
    getOnlineID = function() return 1 end,
    getCurrentSquare = function() return playerHasSquare and getOrMakeSquare(100, 100, 0) or nil end,
    getInventory = function() return playerInv end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
-- 線上玩家清單可換：情境十二會臨時加入第二位玩家，讓「別人的掃描盒」真的存在
local onlineRoster = nil
function getOnlinePlayers() return javaList(onlineRoster or { player }) end
function getPlayer() return player end

-- ===== 載入受測程式碼 =====
local loaded = {}
function require(name)
    if loaded[name] then return true end
    loaded[name] = true
    -- 帶斜線的是原版路徑（如 ISUI/ISCollapsableWindow），本 harness 不載入原版，直接放行
    if name:find("/", 1, true) then return true end
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then chunk() return true end
    end
    error("require 找不到: " .. name)
end

require "MinidoracatCleaner_Core"
require "MinidoracatCleaner_WorldScanner"
require "MinidoracatCleaner_Commands"

-- ===== 測試工具 =====
local failures = 0
local function check(ok, label)
    if ok then print("  PASS  " .. label)
    else failures = failures + 1; print("  FAIL  " .. label) end
end

local function runTicks(count)
    for _ = 1, count do
        for _, fn in ipairs(tickHandlers) do fn() end
    end
end

local function countFloor(fullType, stamped)
    local total = 0
    for _, square in pairs(world) do
        for _, worldObj in ipairs(square._objs) do
            local item = worldObj:getItem()
            if item:getFullType() == fullType then
                local has = rawget(item:getModData(), "MIC42_lastDroppedBy") ~= nil
                if stamped == nil or has == stamped then total = total + 1 end
            end
        end
    end
    return total
end

-- 地板上該 fullType 現存的最大 item ID。用來驗「最新的先刪」政策：ID 遞增近似落地順序，
-- 所以清理過後剩下的應該都是較舊（ID 較小）的那些
local function maxFloorId(fullType)
    local best = nil
    for _, square in pairs(world) do
        for _, worldObj in ipairs(square._objs) do
            local item = worldObj:getItem()
            if item:getFullType() == fullType and (not best or item:getID() > best) then
                best = item:getID()
            end
        end
    end
    return best
end

-- ===== 情境一：混合來源的同種地面物品 =====
-- 全部落在區塊 (12,12,0)（x/y 皆 96..103），玩家站在 (100,100) 也在該區塊內，
-- 讓「每區塊」成為唯一觸發原因：區域上限 40／400 不會被 25／20 件碰到
print("情境一：自動清理的雙桶分流")
for i = 1, 20 do putOnFloor(96 + (i % 8), 96, 0, makeItem("Base.Log", nil)) end
for i = 1, 25 do putOnFloor(96 + (i % 8), 97, 0, makeItem("Base.Log", "griefer")) end

check(countFloor("Base.Log", false) == 20, "起始：無標記 20 件")
check(countFloor("Base.Log", true) == 25, "起始：有標記 25 件")

runTicks(400)
check(countFloor("Base.Log") == 45, "第一輪只警告、不刪")

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Log", false) == 20, "高容忍桶（無標記）完全沒被動到")
check(countFloor("Base.Log", true) == 10, "一般桶（有標記）刪到剛好等於上限 10")

local cleaned = 0
for _, line in ipairs(logLines) do
    if line:find("auto_clean", 1, true) then cleaned = cleaned + 1 end
end
check(cleaned >= 1, "auto_clean 記錄有寫出（刪除後的聚合輸出路徑沒炸）")

-- ===== 情境二：批次手動刪除與安全邊界 =====
print()
print("情境二：批次手動刪除的可及性判定")

local inBag = playerInv:add(makeItem("Base.Nails"))
local favorite = playerInv:add(makeItem("Base.Hammer"))
favorite._favorite = true

local shelf = makeContainer("furniture")
putFurniture(100, 100, 0, shelf)
local inShelf = { shelf:add(makeItem("Base.Screwdriver")), shelf:add(makeItem("Base.Saw")) }

local onFloor = putOnFloor(101, 100, 0, makeItem("Base.Plank", "tester"))

-- 範圍外（距離 5 格）：不得被刪
local farShelf = makeContainer("furniture")
putFurniture(105, 100, 0, farShelf)
local farItem = farShelf:add(makeItem("Base.Axe"))

-- 相鄰但被牆阻隔：不得被刪
local blockedShelf = makeContainer("furniture")
putFurniture(99, 100, 0, blockedShelf)
getOrMakeSquare(99, 100, 0)._blocked = true
local blockedItem = blockedShelf:add(makeItem("Base.Crowbar"))

local requested = { inBag:getID(), favorite:getID(), inShelf[1]:getID(), inShelf[2]:getID(),
                    onFloor:getID(), farItem:getID(), blockedItem:getID() }
for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "deleteItems", player, { ids = requested })
end

local function inContainer(container, item)
    for _, it in ipairs(container._items) do
        if it == item then return true end
    end
    return false
end

check(not inContainer(playerInv, inBag), "背包內的物品已刪除")
check(inContainer(playerInv, favorite), "最愛物品保留（防手滑保護生效）")
check(not inContainer(shelf, inShelf[1]) and not inContainer(shelf, inShelf[2]), "相鄰家具容器內的物品已刪除")
check(countFloor("Base.Plank") == 0, "地板物品已刪除")
check(inContainer(farShelf, farItem), "範圍外的物品未被刪除（可及性把關）")
check(inContainer(blockedShelf, blockedItem), "被阻隔格上的物品未被刪除（可及性把關）")

-- 刪空貨架必須同時解除兩道「卡住」：重生旗標與外觀貼圖。少任一項，玩家就得放一件
-- 東西進去再拿出來（＝走一次原版搬運）才會恢復正常
check(shelf:isHasBeenLooted(), "刪空的容器已標記 hasBeenLooted（物資重生不被卡住）")
check(shelf:getParent():getOverlaySprite() == nil, "刪空的貨架 overlay 貼圖已清除（外觀不再顯示滿架）")
check(farShelf:getParent():getOverlaySprite() ~= nil, "沒被刪到的貨架 overlay 貼圖保持不變")
check(not farShelf:isHasBeenLooted(), "沒被刪到的容器不會被誤標 hasBeenLooted")

local manual = 0
for _, line in ipairs(logLines) do
    if line:find("manual_delete", 1, true) then manual = manual + 1 end
end
check(manual == 1, "整批只寫一行 manual_delete 記錄（聚合寫入）")

-- ===== 情境三：提早退出 =====
-- 索引化若不帶「要找哪些 id」，右鍵刪背包裡的 1 件東西也會把周遭每個容器全部建成 entry。
-- 舊版 findAccessibleItem 是先查背包、命中就回傳，這個特性必須保住
print()
print("情境三：只刪背包內物品時不應掃描世界")

local solo = playerInv:add(makeItem("Base.Rope"))
-- 每位玩家 250ms 節流：不推進時間的話後續指令會被整包丟棄
nowMs = nowMs + 1000
gridLookups = 0
for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "deleteItems", player, { ids = { solo:getID() } })
end
check(not inContainer(playerInv, solo), "背包內的單件物品已刪除")
check(gridLookups == 0, "完全沒有查詢任何地圖格（提早退出生效）")

-- 反面：要找的 id 有一個搆不到時，不得因為提早退出而略過可及性把關
local reachable = playerInv:add(makeItem("Base.Twine"))
local stillFar = farShelf:add(makeItem("Base.Sledgehammer"))
nowMs = nowMs + 1000
gridLookups = 0
for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "deleteItems", player, { ids = { reachable:getID(), stillFar:getID() } })
end
check(not inContainer(playerInv, reachable), "搆得到的那件仍被刪除")
check(inContainer(farShelf, stillFar), "搆不到的那件仍未被刪除（提早退出沒有開後門）")
check(gridLookups > 0, "有搆不到的 id 時仍會完整掃描（不會誤判為已完成）")

-- ===== 情境四：可及性的負面案例與配置上限 =====
print()
print("情境四：拒絕路徑與記憶體配置上限")

local function indexSize(index)
    local n = 0
    for _ in pairs(index) do n = n + 1 end
    return n
end

-- 保險屋拒絕：世界端全部搆不到，但玩家自己的背包不受影響
local inBagAgain = playerInv:add(makeItem("Base.Nails"))
local shelfItem = shelf:add(makeItem("Base.Hammer"))
safehouseAllows = false
local denied = MinidoracatCleaner.buildAccessibleIndex(player, 1, { inBagAgain:getID(), shelfItem:getID() })
safehouseAllows = true
check(denied[inBagAgain:getID()] ~= nil, "保險屋拒絕時，自己背包內的物品仍可及")
check(denied[shelfItem:getID()] == nil, "保險屋拒絕時，世界容器內的物品不可及")

-- playerSquare 為 nil：世界端 fail-closed，背包仍可用
playerHasSquare = false
local noSquare = MinidoracatCleaner.buildAccessibleIndex(player, 1, { inBagAgain:getID(), shelfItem:getID() })
playerHasSquare = true
check(noSquare[inBagAgain:getID()] ~= nil, "無所在格時，自己背包內的物品仍可及")
check(noSquare[shelfItem:getID()] == nil, "無所在格時，世界端 fail-closed")

-- 配置上限：範圍內塞很多件，但只點名 1 個「不存在」的 id
for i = 1, 300 do shelf:add(makeItem("Base.Screw")) end
local bogus = MinidoracatCleaner.buildAccessibleIndex(player, 1, { 999999999 })
check(indexSize(bogus) == 0, "只點名不存在的 id 時，完全不配置任何 record（300 件在範圍內）")

local oneReal = MinidoracatCleaner.buildAccessibleIndex(player, 1, { shelfItem:getID(), 999999999 })
check(indexSize(oneReal) == 1, "點名 1 實 1 虛時只配置 1 筆 record，不隨範圍內件數放大")

-- 走訪量上限：配置量封頂之外，翻找本身也要有硬天花板。少了它，一個不存在的 id 就能
-- 讓 server 主執行緒翻完範圍內每個容器（ItemNumbersLimitPerContainer 預設 0＝無件數上限）。
-- 這裡把上限暫時調小來驗機制——測的是「會不會停」，不是 20000 這個校準值
local realLimit = MinidoracatCleaner.CONSTANTS.INDEX_VISIT_LIMIT
MinidoracatCleaner.CONSTANTS.INDEX_VISIT_LIMIT = 20

-- 貨架上已有 300+ 件，遠超過調小後的上限；最後才放的這件在走訪順序上排在上限之後
local pastCap = shelf:add(makeItem("Base.Wire"))
local capped = MinidoracatCleaner.buildAccessibleIndex(player, 1, { pastCap:getID() })
check(capped[pastCap:getID()] == nil, "走訪量觸頂即停：上限之後的物品不會被找到（不再翻完整個貨架）")

-- 觸頂是「少做事」不是「亂做事」：背包在世界之前登錄，仍必須命中
local inBagStill = playerInv:add(makeItem("Base.Needle"))
local cappedBag = MinidoracatCleaner.buildAccessibleIndex(player, 1, { inBagStill:getID() })
check(cappedBag[inBagStill:getID()] ~= nil, "觸頂上限不影響背包內物品（先登錄、提早收工）")

-- nil entry 不得成為越過上限的破口。Java 的 ArrayList 可以含 null（size 照算、get 回 null），
-- 而 visited 是無條件遞增的——若停止檢查只寫在 `if item then` 內，一串 nil 就能整段翻過去。
-- 這裡的假清單就是那個形狀：size 回報 30，前 25 筆 get 回 nil，目標排在上限之後。
-- 另附 get() 次數 oracle：只斷言「目標沒被找到」擋不住這個迴歸（少了計數，實作可能是
-- 翻完全部才碰巧沒命中）
local nilProbeGets = 0
local nilProbeTarget = makeItem("Base.Saw")
local nilProbeShelf = makeContainer("furniture")
nilProbeShelf.getItems = function()
    return {
        size = function() return 30 end,
        get = function(_, i)
            nilProbeGets = nilProbeGets + 1
            if i == 25 then return nilProbeTarget end
            return nil
        end,
    }
end
-- 擺在 (100,99,0)：格子掃描順序是 y 由小到大，這格排在玩家腳下那格（100,100,0，
-- 站著 302 件的貨架）**之前**。擺在後面的話會先在貨架上觸頂返回，probe 根本走不到，
-- 兩條斷言就變成空轉的假通過（實測會如此）
putFurniture(100, 99, 0, nilProbeShelf)
-- 拿掉 overlay：這個 fixture 只為了驗走訪上限，不該同時符合情境五「被刪空待修復」的指紋
-- （空 ＋ 未搜刮 ＋ 掛著 overlay），否則會讓那邊的 repaired 計數多一個而誤報失敗
nilProbeShelf._parent._overlay = nil

local nilProbe = MinidoracatCleaner.buildAccessibleIndex(player, 1, { nilProbeTarget:getID() })
-- 活性斷言先行：沒有它，「probe 根本沒被掃到」與「上限正確擋住」在結果上無法區分
check(nilProbeGets > 0, "nil probe 確實被走訪到（活性檢查，避免下面兩條變成空轉的假通過）")
check(nilProbe[nilProbeTarget:getID()] == nil, "一串 nil entry 不能越過走訪上限（上限之後的目標仍找不到）")
check(nilProbeGets <= 20 + 2, "nil entry 確實計入走訪量（取件次數收在上限附近，非翻完 30 筆）")

MinidoracatCleaner.CONSTANTS.INDEX_VISIT_LIMIT = realLimit

-- 還原上限後，同一件搆得到的物品必須重新找得到（證明截斷是上限造成、非其他把關）
local afterRestore = MinidoracatCleaner.buildAccessibleIndex(player, 1, { pastCap:getID() })
check(afterRestore[pastCap:getID()] ~= nil, "還原上限後同一件物品重新可及（截斷確實來自走訪上限）")

-- ===== 情境五：週期掃描順手修復被刪空的容器 =====
-- 指紋＝空 ＋ hasBeenLooted 為 false ＋ 卻還掛著 overlay。三種**不該**被碰的狀態各放一個
-- 當對照組，確認修復不會外溢到原版本來就正常的容器
print()
print("情境五：週期掃描修復被刪空的容器")

-- 放**兩個**壞掉的：只有一個時，「只寫一行 log」無法區分「逐容器輸出」與「整趟聚合」
local damaged = makeContainer("furniture")            -- 預設就是壞掉的指紋
putFurniture(102, 102, 0, damaged)
local damaged2 = makeContainer("furniture")
putFurniture(102, 103, 0, damaged2)

local natural = makeContainer("furniture")            -- 天生骰空：從來沒被賦予 overlay
natural:getParent()._overlay = nil
putFurniture(103, 102, 0, natural)

local lootedClean = makeContainer("furniture")        -- 玩家正常搬空：旗標已設、貼圖已清
lootedClean:getParent()._overlay = nil
lootedClean:setHasBeenLooted(true)
putFurniture(104, 102, 0, lootedClean)

local stocked = makeContainer("furniture")            -- 架上真的有貨：不得動它
stocked:add(makeItem("Base.Apple"))
putFurniture(105, 102, 0, stocked)

-- B42 實體工作站：也有空容器、也掛著 overlay，但那是製作進度貼圖（走 SpriteOverlayConfig，
-- 底圖不在容器 overlay 表裡）。誤判的話會同時「憑空開始重生物資」與「抹掉進度貼圖」
local craftStation = makeContainer("furniture")
craftStation:getParent()._overlay = "leather_drying_50"
craftStation:getParent()._inOverlayMap = false
putFurniture(106, 102, 0, craftStation)

-- 第三方 MOD 在**真正的貨架底圖**上掛了自己的 overlay：底圖檢查會過，但反查表裡沒有
-- 這張 overlay → 來路不明，必須放過（否則等於砸掉別家 MOD 的畫面）
local moddedShelf = makeContainer("furniture")
moddedShelf:getParent()._overlay = "thirdparty_decor_01"
putFurniture(107, 102, 0, moddedShelf)

nowMs = nowMs + 61000
runTicks(600)

check(damaged:isHasBeenLooted() and damaged2:isHasBeenLooted(), "兩個壞掉的容器都補上 hasBeenLooted（重生解鎖）")
check(damaged:getParent():getOverlaySprite() == nil, "壞掉的貨架 overlay 已清除")
check(damaged:getParent()._hotSaves > 0, "修復後有 flagForHotSave（重啟不會打回原形）")
check(not natural:isHasBeenLooted(), "天生骰空的容器未被誤標（沒有無中生有的重生）")
check(not stocked:isHasBeenLooted(), "架上有貨的容器未被誤標")
check(stocked:getParent():getOverlaySprite() ~= nil, "架上有貨的容器 overlay 保持不變")
check(lootedClean:getParent()._hotSaves == 0, "已經正常的容器完全沒被寫入（修復不外溢）")
check(not craftStation:isHasBeenLooted(), "實體工作站未被誤標（不會憑空開始重生物資）")
check(craftStation:getParent():getOverlaySprite() ~= nil, "實體工作站的製作進度貼圖沒被抹掉")
check(not moddedShelf:isHasBeenLooted(), "第三方 overlay 的貨架未被誤標（來路不明就放過）")
check(moddedShelf:getParent():getOverlaySprite() ~= nil, "第三方 MOD 掛的 overlay 沒被抹掉")

local repairLogs = {}
for _, line in ipairs(logLines) do
    if line:find("container_repair", 1, true) then repairLogs[#repairLogs + 1] = line end
end
check(#repairLogs == 1, "整趟掃描只寫一行 container_repair 記錄（聚合寫入）")
check(repairLogs[1] and repairLogs[1]:find("repaired=2", 1, true) ~= nil,
    "那一行涵蓋兩個容器（repaired=2，證明是聚合而非逐容器輸出）")

-- 第二輪：世界已修完，指紋消失，不該再寫任何 container_repair
nowMs = nowMs + 61000
runTicks(600)
local repairLogsAfter = 0
for _, line in ipairs(logLines) do
    if line:find("container_repair", 1, true) then repairLogsAfter = repairLogsAfter + 1 end
end
check(repairLogsAfter == 1, "第二輪掃描零新增（修完即收斂，不會重複處理）")

-- ===== 情境六：Kahlua 沒有的標準 Lua 全域（靜態掃描）=====
-- 這個 harness 跑在標準 Lua 上，next/assert/xpcall 全都存在，所以「執行測試」在架構上
-- 永遠抓不到誤用——0.2.2 的 next(index) 就是這樣溜到正式服，讓動物清理每輪拋
-- 「Object tried to call nil」而整輪中斷（正式服 server-console 累積 91 次）。
-- Kahlua 的 BaseLib 只註冊 collectgarbage/error/getfenv/getmetatable/pcall/print/
-- rawequal/rawget/rawset/select/setfenv/setmetatable/tonumber/tostring/type/unpack；
-- pairs/ipairs 另由 TableLib 註冊，可用。以下三個在整個 kahlua 樹都找不到。
print()
print("情境六：Kahlua 缺少的標準 Lua 全域（原始碼掃描）")

local SOURCES = {
    "shared/MinidoracatCleaner_Core.lua",
    "shared/MinidoracatCleaner_DropStamp.lua",
    "server/MinidoracatCleaner_WorldScanner.lua",
    "server/MinidoracatCleaner_AnimalScanner.lua",
    "server/MinidoracatCleaner_Commands.lua",
    "client/MinidoracatCleaner_Client.lua",
    "client/MinidoracatCleaner_ContextMenu.lua",
    "client/MinidoracatCleaner_Tooltip.lua",
    "client/MinidoracatCleaner_Picker.lua",
}
local FORBIDDEN = { "next", "assert", "xpcall" }

local hits = {}
for _, rel in ipairs(SOURCES) do
    local fh = io.open(MEDIA .. "/" .. rel)
    if fh then
        local lineNo = 0
        for line in fh:lines() do
            lineNo = lineNo + 1
            local code = line:match("^(.-)%-%-") or line   -- 去掉行註解
            for _, name in ipairs(FORBIDDEN) do
                local pos = 1
                while true do
                    local s, e = code:find(name .. "%s*%(", pos)
                    if not s then break end
                    -- 前一字元若是識別字元／冒號／點，代表是方法或欄位（如 iter:next()），不算
                    local prev = s > 1 and code:sub(s - 1, s - 1) or " "
                    if not prev:match("[%w_:%.]") then
                        hits[#hits + 1] = rel .. ":" .. lineNo .. " 用了 " .. name .. "()"
                    end
                    pos = e + 1
                end
            end
        end
        fh:close()
    else
        hits[#hits + 1] = "讀不到 " .. rel
    end
end

for _, h in ipairs(hits) do print("        " .. h) end
check(#hits == 0, "沒有使用 Kahlua 不存在的全域（next／assert／xpcall）")

-- ===== 情境七：生成選單的預設值 =====
-- 上面的 SandboxVars 存根**故意**不含 DebugMenuEnabled，走的正是「新存檔／管理員沒設過」
-- 那條 DEFAULTS fallback 路徑。這條要是回歸（DEFAULTS 誤寫 true），批量生成動物又會無條件
-- 掛在單人玩家的右鍵選單上——正是 Workshop 上被回報的那個問題。
print()
print("情境七：批量生成動物預設不出現")

local sandbox = SandboxVars.MinidoracatCleanerFor42
check(sandbox.DebugMenuEnabled == nil, "前提：存根未設此選項（走 DEFAULTS）")
check(MinidoracatCleaner.getOption("DebugMenuEnabled") == false, "沒設定時預設關閉")

-- 只驗 getOption 不夠：把 Picker 那行條件式寫反，上面兩條照樣會過。以下把真正的
-- OnFillWorldObjectContextMenu handler 拉進來跑完整顯示矩陣。UI 存根只要撐得住
-- 載入期的 derive 與選單期的 addOption／addSubMenu，不需要真的畫任何東西。
local debugMode, clientMode, adminMode, accessLevel = false, false, false, "player"
function isDebugEnabled() return debugMode end
function isAdmin() return adminMode end
function getAccessLevel() return accessLevel end
function getSpecificPlayer() return player end

local function fakeMenu()
    local menu = { labels = {} }
    function menu:addOption(label)
        self.labels[#self.labels + 1] = label
        return { label = label }
    end
    function menu:addSubMenu() end
    return menu
end

ISCollapsableWindow = { derive = function() return {} end }
ISContextMenu = { getNew = function() return fakeMenu() end }

local realIsClient, realIsServer = isClient, isServer
require "MinidoracatCleaner_Picker"
check(#worldMenuHandlers == 1, "Picker 已註冊世界右鍵選單 handler")

local fakeSquare = { getX = function() return 0 end, getY = function() return 0 end,
                     getZ = function() return 0 end }
local worldObjects = { { getSquare = function() return fakeSquare end } }

-- 回傳這個情境下右鍵選單實際掛出來的項目標籤（getText 存根原樣回傳 key）
local function menuLabels(opts)
    debugMode = opts.debug or false
    clientMode = opts.mp or false
    adminMode = opts.admin or false
    accessLevel = opts.admin and "admin" or "player"
    sandbox.DebugMenuEnabled = opts.option
    isClient = function() return clientMode end
    isServer = function() return clientMode end   -- SP 兩者皆 false，MP 客戶端只看 isClient
    local menu = fakeMenu()
    worldMenuHandlers[1](1, menu, worldObjects, false)
    isClient, isServer = realIsClient, realIsServer
    local has = {}
    for _, label in ipairs(menu.labels) do has[label] = true end
    return has, #menu.labels
end

local PICKER = "IGUI_MinidoracatCleaner_PickerOpen"
local SPAWN = "IGUI_MinidoracatCleaner_BatchSpawn"

local has, n = menuLabels({})
check(has[PICKER] and not has[SPAWN] and n == 1, "單人＋選項關：只有清單產生器，沒有生成選單")

has = menuLabels({ option = true })
check(has[PICKER] and has[SPAWN], "單人＋選項開：生成選單出現")

has = menuLabels({ debug = true })
check(has[PICKER] and has[SPAWN], "單人＋-debug：選項關著也照樣出現")

has, n = menuLabels({ mp = true, option = true })
check(n == 0, "MP 一般玩家：即使選項開著也整個選單都拿不到")

has = menuLabels({ mp = true, admin = true })
check(has[PICKER] and not has[SPAWN], "MP 管理員＋選項關：清單產生器有、生成選單沒有")

has = menuLabels({ mp = true, admin = true, option = true })
check(has[PICKER] and has[SPAWN], "MP 管理員＋選項開：兩者都在")

sandbox.DebugMenuEnabled = nil

-- ===== 情境八：警告記錄不因區塊卸載而被誤判「已解決」 =====
-- 舊版 pruneChunkWarnings 把「本輪一格都沒數到」與「數過了、已回到上限內」當成同一件事，
-- 於是玩家一走遠、區塊一卸載，警告記錄就被當成已解決刪掉，下一輪重新從零計時，永遠等不到
-- ensureWarning 的「第二次仍超標」。正式服 log 的症狀是同一個 hotspot 反覆寫出「首次警告」
-- 卻從不清理。這條回歸守住 chunk.observed 判定：沒完整觀測到的區塊一律走閒置年齡回收，不當已解決。
print()
print("情境八：區塊卸載時警告記錄必須存活")

-- 專屬區塊 (14,14)（x/y 皆 112..119，仍落在 ScanRadius 16 涵蓋的 cx/cy 10..14 內）＋一個
-- 其他情境沒用過的 fullType。**世界內容**與前七個情境分離，但 warned／logLines／nowMs 是
-- 全域共用，且這裡每一輪 periodic 都會連帶重掃 cx/cy 10..14 內其他情境的 fixture——目前無
-- 實際污染（Base.Log 剩 10 件恰為上限、不再觸發），但增修斷言時要重新確認這件事
local SHEET_CX, SHEET_CY = 14, 14
for i = 1, 25 do putOnFloor(112 + (i % 8), 112, 0, makeItem("Base.Sheet", "dumper")) end
check(countFloor("Base.Sheet") == 25, "起始：25 件（每區塊上限 10）")

local function sheetWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("Base.Sheet", 1, true) then n = n + 1 end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(400)
check(countFloor("Base.Sheet") == 25, "第一輪只警告、不刪")
check(sheetWarns() == 1, "第一輪寫出一則警告")

-- 卸載整個區塊：物品一件沒少，只是查不到（見 unloadedChunks 宣告處的說明）
local SHEET_CHUNK = SHEET_CX .. "," .. SHEET_CY .. ",0"
unloadedChunks[SHEET_CHUNK] = true

probeChunk = { cx = SHEET_CX, cy = SHEET_CY, z = 0 }
probeLookups = 0
probeChunkChecks = 0
nowMs = nowMs + 61000
runTicks(400)
check(probeChunkChecks > 0, "活性：卸載輪確實查過該區塊的載入狀態（否則以下兩條是空轉）")
check(probeLookups == 0, "未載入的區塊整塊跳過，沒有逐格做必定回 nil 的查詢")
check(sheetWarns() == 1, "卸載輪沒有重新警告（記錄沒被誤判已解決而刪除）")
check(countFloor("Base.Sheet") == 25, "卸載輪查不到東西，也就沒刪")

-- 重新載入：記錄若存活，這一輪 ensureWarning 就會回 true 而直接執行清理
unloadedChunks[SHEET_CHUNK] = nil
probeChunk = nil
nowMs = nowMs + 61000
runTicks(400)
check(sheetWarns() == 1, "重載輪仍未重新警告（沿用卸載前那一筆記錄）")
check(countFloor("Base.Sheet") == 10, "沿用舊記錄直接清到上限 10（跨卸載的確認鏈沒斷）")

-- 第四輪：世界已回到上限內（10 件）且區塊可觀測 → reasons 不含該 hotspot →
-- pruneChunkWarnings 必須**即時**刪掉警告記錄（reasons 分支）。
-- 這一輪是釘住 consumeScanQueue 裡那個 chunk.observed 標記的唯一手段：少了它判斷式恆假，
-- 記錄改走閒置分支而在 20 分鐘內存活，於是下面補貨後不會重新警告、直接被清掉。
-- 不能省掉這一輪直接補貨：清理發生在 finishJob 之後的 delete queue，執行清理那一輪的
-- reasons 仍然是超標，記錄要等到這個「已達標」的完整輪次才會被回收
nowMs = nowMs + 61000
runTicks(400)
check(countFloor("Base.Sheet") == 10, "已達標輪不再多刪")

for i = 1, 15 do putOnFloor(112 + (i % 8), 113, 0, makeItem("Base.Sheet", "dumper")) end
nowMs = nowMs + 61000
runTicks(400)
check(sheetWarns() == 2, "舊記錄已即時回收，再次超標時重新警告（釘住 chunk.observed 標記）")
check(countFloor("Base.Sheet") == 25, "重新警告的那一輪只警告、不刪")

-- 閒置回收（洩漏端）：未觀測的記錄不會永遠留著——年齡超過 staleMs
-- ＝ScanIntervalSeconds × WARN_STALE_INTERVALS（60s×20＝20 分鐘）就該被丟掉。
-- 這條守住 pruneChunkWarnings 的 elseif 分支；少了它 warned 會隨探索熱點無界滯留。
-- 附帶記錄本次修正的已知限制：正式服一輪實測 8-46 分鐘，超過 20 分鐘的輪次下
-- 未觀測記錄仍會在同一次 finishJob 被回收（見 pruneChunkWarnings 的「已知限制」段）
unloadedChunks[SHEET_CHUNK] = true
nowMs = nowMs + 1300000
runTicks(400)
unloadedChunks[SHEET_CHUNK] = nil
nowMs = nowMs + 61000
runTicks(400)
check(sheetWarns() == 3, "未觀測超過 staleMs 的記錄已被回收（重載後重新警告，不是直接清理）")
check(countFloor("Base.Sheet") == 25, "回收後回到首次警告狀態，本輪不刪")

print()
print("情境九：area-scope 記錄同樣不得因區塊卸載而被誤判「已解決」")

-- 刻意**不**預建其他區塊的空 square：mock 的 getGridSquare 只回 world 裡建過的 square，
-- 所以 ScanRadius 16 涵蓋的 25 個區塊裡，除了本情境的五個之外全是 unseen——這正是正式環境
-- 的常態（掃描盒比引擎載入視窗大一圈，玩家站 z≠0 時整層都回 null，見 finishJob 的 area
-- 回收註解）。回收判定只看「這筆記錄的計數來源」是否有區塊未被觀測，所以在這種永遠不完整
-- 的區域裡照樣能正確分辨；若判定寫成「區域內任一區塊未 seen」，下面「已達標輪即時回收」
-- 那條就會因為恆真而失敗——這個配置就是那個設計錯誤的回歸網

-- 每個區塊 9 件（未達 chunk 上限 10，chunk-scope 全程不參與）、五個區塊共 45 件（超過
-- area 上限 40）。這是唯一能單獨測到 area 路徑的配置。五個區塊都在 cx=10（x 80..87），
-- 落在 ScanRadius 16 算出的 cx/cy 10..14 內，且與情境一（12,12）／情境八（14,14）不重疊
local SOCK_ROWS = { 80, 88, 96, 104, 112 }
for _, y in ipairs(SOCK_ROWS) do
    for i = 1, 9 do putOnFloor(80 + (i % 8), y, 0, makeItem("Base.Sock", "dumper")) end
end
check(countFloor("Base.Sock") == 45, "起始：45 件（每區塊 9 件未達 10，區域總量超過 40）")

-- 分 scope 過濾：情境九要證明的是 area 路徑，而補貨若讓某個區塊超過 chunk 上限就會另外
-- 寫出 scope=chunk 的警告，混進計數會讓預期值失準。同時保留 chunk 版計數當反向對照，
-- 斷言 chunk-scope 全程沒被觸發
local function sockWarnsBy(scope)
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=" .. scope, 1, true)
            and line:find("Base.Sock", 1, true) then
            n = n + 1
        end
    end
    return n
end

-- 某個區塊現有幾件 Base.Sock（補貨時要按實際剩餘補到剛好 10，不能一次全倒進同一塊）
local function sockInRow(y)
    local n = 0
    local cy = math.floor(y / 8)
    for px = 80, 87 do
        for py = cy * 8, cy * 8 + 7 do
            local sq = world[squareKey(px, py, 0)]
            if sq then
                for _, wo in ipairs(sq._objs) do
                    if wo:getItem():getFullType() == "Base.Sock" then n = n + 1 end
                end
            end
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Sock") == 45, "第一輪只警告、不刪")
check(sockWarnsBy("area") == 1, "第一輪寫出一則 area 警告")

-- 只卸載五個區塊中的一個：可觀測總數掉到 36 < 40，本輪 areaReasons 就不含這個 key。
-- 舊版據此直接刪記錄（連閒置年齡都沒有）；正確行為是「計數來源少了一塊就不能斷言已解決」
local SOCK_CHUNK = "10,10,0"
unloadedChunks[SOCK_CHUNK] = true
probeChunk = { cx = 10, cy = 10, z = 0 }
probeLookups = 0
probeChunkChecks = 0
nowMs = nowMs + 61000
runTicks(600)
check(probeChunkChecks > 0, "活性：卸載輪確實查過該區塊的載入狀態（否則以下兩條是空轉）")
check(probeLookups == 0, "未載入的區塊整塊跳過，沒有逐格做必定回 nil 的查詢")
check(sockWarnsBy("area") == 1, "來源區塊未觀測時沒有重新警告（記錄沒被誤判已解決）")
check(countFloor("Base.Sock") == 45, "卸載輪不刪")

unloadedChunks[SOCK_CHUNK] = nil
probeChunk = nil
nowMs = nowMs + 61000
runTicks(600)
check(sockWarnsBy("area") == 1, "重載輪仍未重新警告（沿用卸載前那一筆記錄）")
check(countFloor("Base.Sock") == 40, "沿用舊記錄直接清到區域上限 40（area 確認鏈沒斷）")

-- 正向對照：來源區塊全部觀測到且已達標（剛好 40，不超過上限）→ 記錄必須被**即時**刪除。
-- 這一輪釘住 underCounted == false 分支；少了它，把判定寫成「永遠不刪」也會全綠。
-- 注意此刻區域仍有 20 個區塊是 unseen（沒預建空 square），能通過正是因為判定只看來源區塊
nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Sock") == 40, "已達標輪不再多刪")

-- 每個區塊按實際剩餘補到剛好 10 件（清理是整堆整堆挑的，五塊剩餘不一定平均）。
-- 10 不大於 chunk 上限 10 ⇒ 不觸發 chunk-scope；總量回到 50 ⇒ 只有 area 超標
for _, y in ipairs(SOCK_ROWS) do
    for _ = sockInRow(y) + 1, 10 do
        putOnFloor(80 + (y % 8), y, 0, makeItem("Base.Sock", "dumper"))
    end
end
check(countFloor("Base.Sock") == 50, "補貨後每區塊剛好 10 件、總量 50")
nowMs = nowMs + 61000
runTicks(600)
check(sockWarnsBy("area") == 2, "舊記錄已即時回收，再次超標時重新警告（釘住 underCounted false 分支）")
check(countFloor("Base.Sock") == 50, "重新警告的那一輪只警告、不刪")

-- 洩漏端：來源區塊持續未觀測的記錄也不能永遠留著——年齡超過 staleMs（60s×20＝20 分鐘）
-- 就該回收。少了這條，把 area 回收的 staleMs 分支整段刪掉仍會全綠（chunk-scope 在情境八
-- 有對應覆蓋，這裡補上對稱的那一半）
unloadedChunks[SOCK_CHUNK] = true
nowMs = nowMs + 1300000
runTicks(600)
unloadedChunks[SOCK_CHUNK] = nil
nowMs = nowMs + 61000
runTicks(600)
check(sockWarnsBy("area") == 3, "來源區塊未觀測超過 staleMs 的記錄已被回收（重載後重新警告）")
check(countFloor("Base.Sock") == 50, "回收後回到首次警告狀態，本輪不刪")
check(sockWarnsBy("chunk") == 0, "全程未觸發 chunk-scope（證明這個情境只走 area 路徑）")

print()
print("情境十：area 來源清單合併——卸載來源不得在重算時被忘掉")

-- 六個區塊各 9 件（真實 54 > 區域上限 40，但每塊 9 < 區塊上限 10 ⇒ 只走 area）。
-- 五個在 cx=11（x 88..95），第六個在 cx=13（x 104..111），都落在 ScanRadius 16 的 cx/cy 10..14
-- 內，且避開情境一（12,12）、情境五（13,12）、情境八（14,14）、情境九（cx=10）的 fixture
local PAIL_ROWS = { 80, 88, 96, 104, 112 }
for _, y in ipairs(PAIL_ROWS) do
    for i = 1, 9 do putOnFloor(88 + (i % 8), y, 0, makeItem("Base.Bucket", "dumper")) end
end
for i = 1, 9 do putOnFloor(104 + (i % 8), 80, 0, makeItem("Base.Bucket", "dumper")) end
check(countFloor("Base.Bucket") == 54, "起始：六個區塊各 9 件、總量 54")

local function pailAreaWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=area", 1, true)
            and line:find("Base.Bucket", 1, true) then
            n = n + 1
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Bucket") == 54, "第一輪只警告、不刪")
check(pailAreaWarns() == 1, "第一輪寫出一則 area 警告")

-- 卸載第六塊。可觀測總數 45 仍 > 40，而讀不到的來源一律當 0 ⇒ live 是下界、下界已證明超標，
-- 所以這一輪照樣清理，把**可觀測**部分降到剛好 40（真實總數還有 49，含卸載那塊的 9 件）。
-- 刪到可觀測＝上限就停，總數＝上限＋讀不到的部分 ⇒ 永遠不會刪到低於上限。
-- 這一輪同時讓來源清單被重算一次：合併版會保留那個卸載來源，覆寫版會把它忘掉
local PAIL_CHUNK = "13,10,0"
unloadedChunks[PAIL_CHUNK] = true
nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Bucket") == 49, "可觀測部分被清到上限 40，總量 54→49（不會刪到低於上限）")
check(pailAreaWarns() == 1, "這一輪沿用舊記錄執行清理，不重新警告")

-- 關鍵一輪：可觀測總數已是 40（不超標）⇒ 不進 areaReasons。來源清單若還記得那個卸載來源，
-- 就會判定「來源沒看完整、不能算已解決」而保留記錄；若被覆寫忘掉，記錄會在這裡被誤刪
nowMs = nowMs + 61000
runTicks(600)
check(pailAreaWarns() == 1, "可觀測數達標但來源仍缺一塊時不重新警告（記錄沒被誤刪）")

-- 重載第六塊：真實 49 > 40，且來源全部讀得到 ⇒ recount 通過。記錄若還活著就直接清到 40；
-- 若已被誤刪則會重新首次警告、當輪不清
unloadedChunks[PAIL_CHUNK] = nil
nowMs = nowMs + 61000
runTicks(600)
check(pailAreaWarns() == 1, "重載輪沿用原記錄，未重新警告（釘住合併而非覆寫）")
check(countFloor("Base.Bucket") == 40, "沿用原記錄直接清到區域上限 40")

print()
print("情境十一：掃描途中卸載——載入狀態要每個 tick 重查")

-- 佈局配合 offset → 座標的換算（x = cx*8 + offset%8、y = cy*8 + floor(offset/8)）：
-- 8 件放在 y 偏移 0（offset 0..7，任何一個 tick 只要碰到這塊就會數到），4 件放在 y 偏移 6
-- （offset 48..55，要掃過前 48 格才會碰到）。目標區塊從第幾格跨到下一個 tick 取決於前面
-- 區塊吃掉多少預算，所以這裡不假設固定邊界——卸載門檻綁的是「載入狀態被查第幾次」：
-- 第二次被查時就回 nil，此時後段那 4 件必定還沒被數到。
-- 途中卸載後可觀測數變成 8（低於區塊上限 10），若載入狀態只在起頭查一次，
-- 這筆記錄就會被當成「已回到上限內」而刪除
local CORD_CX, CORD_CY = 12, 14
for i = 1, 8 do putOnFloor(96 + (i % 8), 112, 0, makeItem("Base.Cord", "dumper")) end
for i = 1, 4 do putOnFloor(96 + (i % 8), 118, 0, makeItem("Base.Cord", "dumper")) end
check(countFloor("Base.Cord") == 12, "起始：12 件（每區塊上限 10）")

local function cordChunkWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=chunk", 1, true)
            and line:find("Base.Cord", 1, true) then
            n = n + 1
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(400)
check(countFloor("Base.Cord") == 12, "第一輪只警告、不刪")
check(cordChunkWarns() == 1, "第一輪寫出一則 chunk 警告")

-- 第二輪：第一個 tick 照常掃（8 件都數得到，8 < 上限 10 ⇒ 不進 reasons），第二個 tick 一開頭
-- 重查載入狀態時就會發現這塊讀不到，於是標記為未完整觀測、整塊跳過，記錄改走閒置分支保留。
-- 只在起頭查一次的話，這筆記錄會在這裡被當成「已回到上限內」而刪除
partialUnload = { key = CORD_CX .. "," .. CORD_CY .. ",0", checks = 0 }
nowMs = nowMs + 61000
runTicks(400)
check(partialUnload.checks > 1, "活性：該區塊的載入狀態確實被重查過（否則以下兩條是空轉）")
check(cordChunkWarns() == 1, "掃描途中卸載不算已解決（記錄沒被誤刪）")
check(countFloor("Base.Cord") == 12, "這一輪不刪")

-- 恢復完整讀取：12 > 10。記錄若還活著就直接清到 10；若已被誤刪則會重新首次警告、當輪不清
partialUnload = nil
nowMs = nowMs + 61000
runTicks(400)
check(cordChunkWarns() == 1, "恢復輪沿用原記錄，未重新警告（釘住每 tick 重查載入狀態）")
check(countFloor("Base.Cord") == 10, "沿用原記錄直接清到上限 10")

print()
print("情境十二：area 來源集必須依玩家歸屬——別人的掃描盒不算")

-- 舊區域五塊各 9 件（總 45 > 區域上限 40，每塊 9 < 區塊上限 10 ⇒ 只走 area）。
-- 選的是前十一個情境沒用過的區塊：(12,10)(12,11)(12,13)(13,11)(13,13)
local RAG_OLD = { { 96, 80 }, { 96, 88 }, { 96, 104 }, { 104, 88 }, { 104, 104 } }
for _, p in ipairs(RAG_OLD) do
    for i = 1, 9 do putOnFloor(p[1] + (i % 8), p[2], 0, makeItem("Base.Rag", "dumper")) end
end
check(countFloor("Base.Rag") == 45, "起始：舊區域五塊各 9 件、總量 45")

local function ragAreaWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=area", 1, true)
            and line:find("Base.Rag", 1, true) then
            n = n + 1
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(600)
check(ragAreaWarns() == 1, "第一輪寫出一則 area 警告")

-- 卸載其中一塊，讓它成為「來源集裡未觀測到的那一塊」（可觀測 36 < 40 ⇒ 不進 areaReasons，
-- 記錄靠 underCounted 保留）。這塊接下來就是驗 owner 歸屬的探針
local RAG_UNLOADED = "12,10,0"
unloadedChunks[RAG_UNLOADED] = true
nowMs = nowMs + 61000
runTicks(600)
check(ragAreaWarns() == 1, "來源缺一塊時記錄仍保留（不重新警告）")

-- 玩家搬家到 (300,300)；第二位玩家進駐舊位置，於是那塊未載入的舊來源**仍在全域 chunkSet 內**，
-- 只是不再屬於搬家者的掃描盒。少了 chunkOwnedBy 那道檢查，它會被永久併進搬家者的來源集，
-- 讓 underCounted 恆真 ⇒ 記錄永遠不會在達標輪被回收 ⇒ 下次超標時直接沿用舊記錄清理、
-- 不再給玩家警告。（讀不到的來源本身不擋刪除，因為 recount 用的是下界；見下方 :1145 的說明）
local player2 = {
    getX = function() return 100 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
    getUsername = function() return "neighbour" end,
    getOnlineID = function() return 2 end,
    getCurrentSquare = function() return getOrMakeSquare(100, 100, 0) end,
    getInventory = function() return makeContainer("player") end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
playerX, playerY = 300, 300
onlineRoster = { player, player2 }

-- 新區域五塊各 9 件（cx/cy 35..39 ⇒ x 280..287）：搬家者在新家又堆到超標
local RAG_NEW = { 280, 288, 296, 304, 312 }
for _, y in ipairs(RAG_NEW) do
    for i = 1, 9 do putOnFloor(280 + (i % 8), y, 0, makeItem("Base.Rag", "dumper")) end
end
check(countFloor("Base.Rag") == 90, "新區域也堆了 45 件（總量 90）")

nowMs = nowMs + 61000
runTicks(600)
nowMs = nowMs + 61000
runTicks(600)
-- 改用下界語意之後，讀不到的來源一律當 0，所以「舊來源留在集合裡」不再擋住刪除——
-- 兩種版本都會把新區域清到 40。owner 檢查真正影響的是**記錄能不能收斂**：
check(countFloor("Base.Rag") == 85, "新區域清到上限 40，總量 90→85")

-- 達標輪：新區域剩 40（不超標）⇒ 不進 areaReasons。
-- 有 owner 檢查時來源集只剩新區域那五塊、全部讀得到 ⇒ underCounted 為假 ⇒ 記錄即時回收；
-- 沒有 owner 檢查時，別人掃描盒裡那塊永遠讀不到的舊來源會讓 underCounted 恆真 ⇒ 記錄永不
-- 回收，之後再超標就會沿用舊記錄直接清、不再給玩家警告
nowMs = nowMs + 61000
runTicks(600)
for i = 1, 9 do putOnFloor(280 + (i % 8), 280, 0, makeItem("Base.Rag", "dumper")) end
nowMs = nowMs + 61000
runTicks(600)
check(ragAreaWarns() == 2, "舊記錄已回收，再次超標時重新警告（釘住來源集的 owner 歸屬）")
check(countFloor("Base.Rag") == 94, "重新警告的那一輪只警告、不刪")

onlineRoster = nil
playerX, playerY = 100, 100

print()
print("情境十三：跨 tick 的刪除佇列必須依現況重數")

-- 十五個區塊各 5 件（每塊 5 < 區塊上限 10 ⇒ 只走 area），總量 75 > 區域上限 40 ⇒ 超標 35 件，
-- 遠多於 ITEMS_PER_TICK（16），佇列必然跨 tick 消化。區塊沿用前面情境的位置但換一個沒用過的
-- fullType——area 與 chunk 的計數都是 per-fullType，彼此不干擾
local TWIG_SPOTS = {
    { 80, 80 }, { 80, 88 }, { 80, 96 }, { 80, 104 }, { 80, 112 },
    { 88, 80 }, { 88, 88 }, { 88, 96 }, { 88, 104 }, { 88, 112 },
    { 112, 80 }, { 112, 88 }, { 112, 96 }, { 112, 104 }, { 104, 112 },
}
for _, p in ipairs(TWIG_SPOTS) do
    for i = 1, 5 do putOnFloor(p[1] + (i % 8), p[2], 0, makeItem("Base.Twig", "dumper")) end
end
check(countFloor("Base.Twig") == 75, "起始：十五塊各 5 件、總量 75（區域上限 40）")

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Twig") == 75, "第一輪只警告、不刪")

-- 第二輪：確認超標並排入 35 件 victim。逐個 tick 跑，停在「第一批剛被刪掉」的那一刻——
-- 佇列還有 19 件排著，這正是 recount 要保護的窗口
nowMs = nowMs + 61000
for _ = 1, 2000 do
    runTicks(1)
    if countFloor("Base.Twig") < 75 then break end
end
check(countFloor("Base.Twig") == 75 - MinidoracatCleaner.CONSTANTS.ITEMS_PER_TICK,
    "第一個 tick 刪掉 ITEMS_PER_TICK 件")

-- 玩家自己把剩下的撿到剛好 40：後續還排在佇列裡的 victim 應該全部被 recount 取消。
-- 少了 recount，它們會照排入時的舊數量繼續刪，把區域刪到遠低於上限
local twigPicked = 0
for _, p in ipairs(TWIG_SPOTS) do
    for px = p[1], p[1] + 7 do
        local sq = world[squareKey(px, p[2], 0)]
        if sq then
            for i = #sq._objs, 1, -1 do
                if countFloor("Base.Twig") <= 40 then break end
                if sq._objs[i]:getItem():getFullType() == "Base.Twig" then
                    table.remove(sq._objs, i)
                    twigPicked = twigPicked + 1
                end
            end
        end
    end
    if countFloor("Base.Twig") <= 40 then break end
end
check(countFloor("Base.Twig") == 40, "玩家自己撿到剛好等於上限 40（撿走 " .. twigPicked .. " 件）")

runTicks(600)
check(countFloor("Base.Twig") == 40, "佇列裡剩下的 victim 全被 recount 取消，沒有刪到低於上限")

print()
print("情境十四：來源數超過走訪上限且下界證明不了超標時，整批不排入並留下診斷")

-- 這條要構造「來源數 > AREA_RECOUNT_CHUNKS_PER_TICK」的稀疏鋪陳，而預設 ScanRadius=16 只涵蓋
-- 25 個區塊，構不出來 ⇒ 放寬半徑與區域上限。
-- **還原時機**：ScanRadius=32 由情境十五、十六共用（它們的佈局都依賴這個半徑），所以三個情境
-- 都跑完才在檔尾一起還原——不要在這裡還原，那會讓後面兩條的 fixture 掉出掃描盒。
-- 佈局：33 個區塊各 1 件（每塊 1 < 區塊上限 10 ⇒ 只走 area），總量 33 > 區域上限 32。
-- 來源集依計數降冪截到 32 塊 ⇒ 可證明的下界只有 32，而 32 > 32 為假 ⇒ 整批不排入。
-- 少了這一刀，每一輪都會排入註定被 recount 取消的 victim（confirmed 恆真），持續燒掃描預算。
-- 沒有截斷時：provable 會是 33 > 32 ⇒ 刪掉 1 件
local savedRadius = sandbox.ScanRadius
local savedAreaLimit = sandbox.MaxFloorItemsPerTypeArea
sandbox.ScanRadius = 32
sandbox.MaxFloorItemsPerTypeArea = 32

-- 情境十二刻意留著一個未還原的未載入區塊（那是它驗 owner 歸屬的前提），而它正好落在下面
-- 要鋪的範圍內 ⇒ 會少數到一件、讓 33 變成 32 而剛好不超標。這裡要精確控制來源數，先全部還原
for key in pairs(unloadedChunks) do
    unloadedChunks[key] = nil
end

local function pebbleUnprovableLogs()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("items_area_unprovable", 1, true) and line:find("Base.Pebble", 1, true) then
            n = n + 1
        end
    end
    return n
end

local pebbleSpots = 0
for cx = 8, 16 do
    for cy = 8, 12 do
        if pebbleSpots < 33 then
            putOnFloor(cx * 8, cy * 8, 0, makeItem("Base.Pebble", "dumper"))
            pebbleSpots = pebbleSpots + 1
        end
    end
end
check(countFloor("Base.Pebble") == 33, "起始：33 個區塊各 1 件（區域上限 32）")

nowMs = nowMs + 61000
runTicks(3000)
nowMs = nowMs + 61000
runTicks(3000)

check(countFloor("Base.Pebble") == 33,
    "可證明的下界不足以超標 ⇒ 一件都不刪（釘住來源集截斷）")
-- 活性斷言：上面那條斷言的是「什麼都沒發生」，而那正是假通過的形狀。這行證明 area 路徑
-- 真的偵測到熱點、走到了證明判定並主動放棄，不是整段程式沒被走到
check(pebbleUnprovableLogs() == 1,
    "整批不排入時寫出一則 items_area_unprovable（管理員可見，且每個熱點只記一次）")


print()
print("情境十五：來源集必須依計數降冪挑選")

-- 密度不均且來源數遠超截斷長度時，「保留哪 32 塊」決定得出的下界能不能證明超標。
-- 佈局要與 pairs 的走訪順序無關（Kahlua 是插入序、標準 Lua 是帶隨機種子的雜湊序，兩者都
-- 不可控）：若高密度塊剛好排在前面，top-32 還沒滿就無條件進榜，替換邏輯根本不會被考驗。
-- 所以讓高密度塊的數量**正好等於**截斷長度：
--   62 塊來源——32 塊各 5 件（160）＋30 塊各 1 件（30），總量 190，區域上限 150。
--   正確（保留最大的 32 個）：無論走訪順序，最終榜上就是那 32 塊 ⇒ 160 > 150 ⇒ 排入 10 件。
--   保留最小的 32 個：30 個 1 件 ＋ 2 個 5 件 = 40，遠低於 150 ⇒ 判成「證明不了」而完全不清。
--   插入位置寫錯（榜尾不再是最小值）也會讓替換決策失準、湊不到 160。
local savedChunkLimit = sandbox.MaxFloorItemsPerType
sandbox.MaxFloorItemsPerTypeArea = 150
-- 放寬區塊上限，否則 chunk scope 會搶先清掉、測不到 area 的挑選邏輯
sandbox.MaxFloorItemsPerType = 200

local nailDenseCount, nailSparseCount = 0, 0
for cy = 8, 15 do
    for cx = 8, 15 do
        if nailDenseCount < 32 then
            -- 每塊 5 件全擠同一格：玩家傾倒就是這個形狀，而佇列只存 id/x/y/z、每次刪除前
            -- 都重新 getWorldObjects() 按 ID 尋找，所以同格重複堆是真實核心路徑
            for _ = 1, 5 do
                putOnFloor(cx * 8 + 2, cy * 8 + 2, 0, makeItem("Base.Nails", "dumper"))
            end
            nailDenseCount = nailDenseCount + 1
        elseif nailSparseCount < 30 then
            putOnFloor(cx * 8 + 2, cy * 8 + 2, 0, makeItem("Base.Nails", "dumper"))
            nailSparseCount = nailSparseCount + 1
        end
    end
end
check(countFloor("Base.Nails") == 190,
    "起始：32 塊各 5 件＋30 塊各 1 件，總量 190（區域上限 150、來源 62 塊 > 截斷 32）")

nowMs = nowMs + 61000
runTicks(6000)
check(countFloor("Base.Nails") == 190, "第一輪只警告、不刪")

nowMs = nowMs + 61000
runTicks(6000)
check(countFloor("Base.Nails") == 180,
    "保留最大的 32 塊讓下界達到 160 > 150 ⇒ 排入 10 件並刪掉（釘住 top-N 的替換與排序）")


print()
print("情境十六：單 tick 的載入探測次數必須受額度封頂（跨 fullType）")

-- 0-cache 只在相同 bucket|fullType 之間共用，所以「同一 tick、多個不同 fullType 的 area
-- victim」會各自重新探測同一批卸載來源。若載入探測不計費（walked 只在真的走了 64 格時遞增），
-- 單 tick 的 Java 往返會是 victim 數 × 來源數，而不是額度本身。
--
-- 佈局要滿足三件事：① 每型只排 1 個 victim（否則 ITEMS_PER_TICK=16 會讓單一型別吃掉整個
-- tick，輪不到第二型）② 第一型的 recount 必須走滿 32 塊才耗盡額度（所以下界只能在最後一塊
-- 才超過上限）③ 上限要高於前面所有情境的 fixture，否則它們會一起超標而讓 victim 數失控。
-- 取 3 型 × 32 塊 × 10 件、上限 319：前 31 塊只有 310 ≤ 319 ⇒ 必走滿 32 塊；319 高於既有
-- fixture 的最大量（Nails 101）⇒ 零干擾。
-- 有計費：第一型走滿 32 ⇒ 後兩型 defer ⇒ 卸載後的下一 tick 只有第二型探測 32 次。
-- 無計費：第二、三型各重走整份來源集 ⇒ 64 次
local savedAreaLimit16 = sandbox.MaxFloorItemsPerTypeArea
sandbox.MaxFloorItemsPerTypeArea = 319

local TYPES_16 = { "Base.Wire", "Base.Thread", "Base.Tarp" }
local probeKeys = {}
for index = 0, 31 do
    local cx = 8 + (index % 8)
    local cy = 8 + math.floor(index / 8)
    probeKeys[#probeKeys + 1] = cx .. "," .. cy .. ",0"
    for _, fullType in ipairs(TYPES_16) do
        for _ = 1, 10 do
            putOnFloor(cx * 8 + 5, cy * 8 + 5, 0, makeItem(fullType, "dumper"))
        end
    end
end
local function total16()
    local n = 0
    for _, fullType in ipairs(TYPES_16) do n = n + countFloor(fullType) end
    return n
end
check(total16() == 960, "起始：三個 fullType 各 32 塊各 10 件（各 320 件、區域上限 319）")

nowMs = nowMs + 61000
runTicks(6000)
check(total16() == 960, "第一輪只警告、不刪")

nowMs = nowMs + 61000
-- 跑到佇列真的開始消化就停：第一型的 victim 被刪掉，後兩型因額度耗盡而留在佇列
local t16 = 0
while total16() == 960 and t16 < 6000 do
    runTicks(1)
    t16 = t16 + 1
end
check(total16() == 959, "三型中恰好一型刪掉 1 件（其餘兩型的 victim 因額度耗盡留在佇列）")

for _, ck in ipairs(probeKeys) do
    unloadedChunks[ck] = true
end
-- 活性檢查要綁**recount 專屬**的證據。chunkCheckTotal 是全域計數，consumeScanQueue 每 tick
-- 也會對正在掃的區塊查一次載入狀態，所以「> 0」可能被掃描器滿足——那樣一來 recount 完全
-- 沒跑時上限斷言也無條件成立，整條退化成空轉假通過（AGENTS.md 踩坑錄記過這個形狀）。
-- probeChunk 指向來源集裡的一塊，probeChunkChecks 只在那一塊被查載入狀態時遞增
probeChunk = { cx = 8, cy = 8, z = 0 }
probeChunkChecks = 0
chunkCheckTotal = 0
runTicks(1)
check(probeChunkChecks > 0, "活性：這個 tick 確實對來源集裡的區塊做了載入探測（否則下一條是空轉）")
-- 額度寫死 32 而不是讀常數（讀常數的話斷言會跟著放寬，改成無限大也照樣通過），而且要用
-- **等式**不是 `<=`：若載入探測被錯誤地雙倍計費，走 16 塊就會永久 defer、每個 tick 從頭再來，
-- 而 `<= 32` 對那種退化完全無感
check(chunkCheckTotal == 32,
    "本 tick 恰好用滿額度 32（實際 " .. chunkCheckTotal .. "，釘住載入探測也計費且不重複計費）")
-- 下一個 tick 應該再恰好用滿一次：額度是每 tick 重建的，前一 tick defer 的那件會用完整額度
-- 重數。這條同時排除「額度只在第一個 tick 生效」的實作
chunkCheckTotal = 0
runTicks(1)
check(chunkCheckTotal == 32,
    "下一個 tick 又恰好用滿 32（實際 " .. chunkCheckTotal .. "，釘住額度每 tick 重建）")
-- 最後要證明佇列真的排空、不是每 tick 都在重試同一批 victim（來源全卸載 ⇒ 下界 0 ⇒ 全取消）
runTicks(3000)
chunkCheckTotal = 0
probeChunkChecks = 0
runTicks(1)
check(chunkCheckTotal == 0 and probeChunkChecks == 0,
    "佇列排空後不再有任何探測（沒有殘留 victim 每 tick 空轉）")
probeChunk = nil

for _, ck in ipairs(probeKeys) do
    unloadedChunks[ck] = nil
end
-- 還原順序：情境十四～十六各自存了自己動到的值，這裡由內而外還原。
-- MaxFloorItemsPerTypeArea 被十五（100）與十六（319）都改過，savedAreaLimit 是十四之前的原值
sandbox.MaxFloorItemsPerType = savedChunkLimit
sandbox.ScanRadius = savedRadius
sandbox.MaxFloorItemsPerTypeArea = savedAreaLimit

print()
print("情境十七：單一格子的物品數超過走訪額度時，計數必須跨 tick 續算")

-- SQUARES_PER_TICK 封頂的是格數，不是每格的物件數；單格的 worldObjects 沒有容量上限
-- （IsoGridSquare.java:319），所以掃描另有 SCAN_ITEM_VISITS_PER_TICK 這道物件額度。
-- 額度用完時**不能**前進 squareIndex，否則該格剩下的物件永遠不被計數。
-- 佈局：同一格 700 件（> 額度 512）、區塊上限 100 ⇒ 正確會清到剛好 100。
-- 漏數版本只數到 512 ⇒ 排 412 件 ⇒ 剩 288
local savedChunk17 = sandbox.MaxFloorItemsPerType
local savedArea17 = sandbox.MaxFloorItemsPerTypeArea
sandbox.MaxFloorItemsPerType = 100
sandbox.MaxFloorItemsPerTypeArea = 2000  -- 讓 area 不介入，隔離出 chunk 路徑

for _ = 1, 700 do
    putOnFloor(83, 83, 0, makeItem("Base.Nail", "dumper"))
end
check(countFloor("Base.Nail") == 700, "起始：同一格 700 件（區塊上限 100、單 tick 物件額度 512）")
-- 記下起始的最大 ID，用來驗「最新的先刪」：候選是保留 ID 最大的 N 筆（min-heap），若 heap
-- 的浮上／下沉寫錯，root 就不是最舊那筆 ⇒ 會保留錯的集合、刪掉舊的而留下新的
local nailStartMaxId = maxFloorId("Base.Nail")

-- 量測前先把前面情境殘留的刪除佇列排空：itemReads 是全域計數器，而 recount 與 find 各有
-- 自己的額度也會讀地板物件，佇列沒空的話量到的峰值不是純掃描成本。
-- 不推進 nowMs，所以這裡不會觸發新的掃描
runTicks(6000)

nowMs = nowMs + 61000
-- 逐 tick 量測地板物件讀取次數的峰值：只斷言「最後有數完」的話，把 SCAN_ITEM_VISITS_PER_TICK
-- 整段拿掉照樣會清到 100（一個 tick 全走完也算數完），上限本身就沒被釘住
local maxReads = 0
for _ = 1, 3000 do
    itemReads = 0
    runTicks(1)
    if itemReads > maxReads then
        maxReads = itemReads
    end
end
check(countFloor("Base.Nail") == 700, "第一輪只警告、不刪")
-- 上限寫死 512 而不是讀 MinidoracatCleaner.CONSTANTS.SCAN_ITEM_VISITS_PER_TICK：讀常數的話
-- 斷言會跟著常數一起放寬，把額度改成無限大也照樣通過（自我參照＝沒有釘住任何東西）。
-- 這個數字要跟著 Core.lua 的 SCAN_ITEM_VISITS_PER_TICK 一起改，那正是想要的：調整成本旋鈕
-- 必須是一個有意識的動作
check(maxReads > 0 and maxReads <= 512,
    "單 tick 的地板物件走訪不超過額度 512（實測峰值 " .. maxReads .. "，釘住掃描物件額度）")

-- 候選清單是 per (chunk, fullType) 的 bounded top-N（CANDIDATES_PER_TYPE），所以單一輪最多
-- 排入那麼多件；700 件要清到 100 需要跨輪收斂。這正是記憶體上限的代價，也是設計意圖：
-- 一輪處理不完的下一輪繼續，永遠不會為了「一次清完」而配置與世界內容量成正比的 table
local rounds17 = 0
for _ = 1, 10 do
    nowMs = nowMs + 61000
    runTicks(3000)
    rounds17 = rounds17 + 1
    if countFloor("Base.Nail") == 100 then
        break
    end
end
check(countFloor("Base.Nail") == 100,
    "逐輪收斂到剛好等於上限（釘住格內 offset 跨 tick 續算，沒有漏數）")
-- 輪數本身就是「單輪配置量有上限」的證據：要刪 600 件而每輪最多排 512 件 ⇒ 至少 2 輪。
-- 少了這條，把 CANDIDATES_PER_TYPE 改成無限大也照樣通過（一輪清完也是清到 100）
check(rounds17 >= 2,
    "清理跨了 " .. rounds17 .. " 輪（≥2，釘住每組候選的 bounded top-N 上限）")
check(maxFloorId("Base.Nail") < nailStartMaxId,
    "剩下的都是較舊的（最大 ID 從 " .. nailStartMaxId .. " 降到 " .. maxFloorId("Base.Nail")
        .. "，釘住候選 min-heap 選的是最新的那些）")

print()
print("情境十八：victim 落在超大同格清單的尾端時仍要找得到")

-- 候選依 item ID 由大到小挑，而掉落物是 append 進 worldObjects 的 ⇒ victim 幾乎總在尾端。
-- findQueuedWorldItem 若從 index 0 正向掃，單格件數超過 FIND_ITEM_VISITS_PER_TICK 時每輪都在
-- 前段觸頂、永遠找不到 victim ⇒ 加了額度反而讓清理在最需要它的場景失活。
-- 佈局：同一格 2500 件（> 額度 2048）、區塊上限 100
for _ = 1, 2500 do
    putOnFloor(91, 91, 0, makeItem("Base.Tissue", "dumper"))
end
check(countFloor("Base.Tissue") == 2500, "起始：同一格 2500 件（單 tick find 額度 2048）")

-- 同樣要跨輪收斂（每輪最多排 CANDIDATES_PER_TYPE 件）
local rounds18 = 0
for _ = 1, 15 do
    nowMs = nowMs + 61000
    runTicks(20000)
    rounds18 = rounds18 + 1
    if countFloor("Base.Tissue") == 100 then
        break
    end
end
check(countFloor("Base.Tissue") == 100,
    "逐輪收斂到剛好等於上限（用了 " .. rounds18 .. " 輪；釘住 find 反向掃，尾端的 victim 找得到）")

-- 第二段：讓 find 額度真的觸發。上面那段反向掃第一筆就命中，所以額度多寡都不影響——
-- 要釘住額度本身，得讓 victim 前面隔著超過額度的其他物件。
-- 佈局：同格再堆 2500 個「不同 fullType」的 decoy（ID 全都比 target 新 ⇒ 反向掃會先走它們），
-- 然後讓 target 再次超標。正確版：find 走 2048 筆就觸頂、當成找不到而放掉 ⇒ 這一輪不刪。
-- 沒有額度的版本：一路走完 2500 筆找到 target ⇒ 會刪
for _ = 1, 2500 do
    putOnFloor(91, 91, 0, makeItem("Base.Decoy", "dumper"))
end
for _ = 1, 60 do
    putOnFloor(91, 91, 0, makeItem("Base.Tissue", "dumper"))
end
-- decoy 要比 target 新才會擋在反向掃的前面
for _ = 1, 2500 do
    putOnFloor(91, 91, 0, makeItem("Base.Decoy2", "dumper"))
end
check(countFloor("Base.Tissue") == 160, "起始：target 160 件，尾端隔著 2500 個更新的 decoy")

nowMs = nowMs + 61000
runTicks(3000)
nowMs = nowMs + 61000
runTicks(3000)
check(countFloor("Base.Tissue") == 160,
    "victim 前面隔著超過額度的物件時 find 觸頂放掉、這一輪不刪（釘住 find 物件額度）")

print()
print("情境十九：刪除前必須讀當前上限，不是排入當時的快照")

-- 管理員可在執行期改 sandbox（server 收到設定封包後 SandboxOptions.load/applySettings/toLua，
-- GameServer.java:1695-1697）。佇列跨 tick 存活時若照排入當時的舊上限刪，就會刪掉當前政策
-- 允許保留的物品。
-- 佈局：同一塊 300 件、上限 100 ⇒ 排 200 件；佇列起步後把上限提高到 400 ⇒ 剩下的 victim
-- 全部應被取消（300 已在新上限內）
for _ = 1, 300 do
    putOnFloor(99, 99, 0, makeItem("Base.Comb", "dumper"))
end
check(countFloor("Base.Comb") == 300, "起始：同一塊 300 件（區塊上限 100）")

nowMs = nowMs + 61000
runTicks(3000)
check(countFloor("Base.Comb") == 300, "第一輪只警告、不刪")

nowMs = nowMs + 61000
local t19 = 0
while countFloor("Base.Comb") == 300 and t19 < 6000 do
    runTicks(1)
    t19 = t19 + 1
end
local comb19 = countFloor("Base.Comb")
check(comb19 < 300 and comb19 > 100, "第二輪開始刪但還沒刪完（剩 " .. comb19 .. " 件）")

-- 管理員把上限提高：佇列裡剩下的 victim 應立刻全部取消
sandbox.MaxFloorItemsPerType = 400
runTicks(3000)
check(countFloor("Base.Comb") == comb19,
    "提高上限後佇列裡剩下的 victim 全被取消（釘住刪除前讀當前上限）")


print()
print("情境二十：同型多個 victim 必須共用「來源讀不到」的結論")

-- recount 對讀不到的來源會把 0 記進本 tick 的 liveCache，讓同一 fullType 的後續 victim 直接
-- 沿用、不必再付一次 Java 往返。這行拿掉不影響正確性（只是變慢），所以要專門釘住——
-- 而情境十六測不到它：那裡每型只排一件 victim，共用的路徑根本不存在。
--
-- 構造要讓「必定走完全部來源」，否則不穩定：下界一超過上限就提早退出，而來源是用 pairs
-- 走訪的（標準 Lua 是帶隨機種子的雜湊序），那塊卸載來源有時根本輪不到 ⇒ 盯它的斷言會偶發
-- 假紅。作法是讓卸載後的可觀測量**低於**上限：此時 live 永遠不超過上限 ⇒ 每件 victim 都會
-- 走完整份來源集（並全部取消），那塊卸載來源必定被碰到。
-- 佈局：4 塊各 10 件 ＋ 1 塊 30 件（總 70）、區域上限 45 ⇒ 排入 25 件（跨 2 個 tick 消化）。
-- 第一個 tick 刪掉 ITEMS_PER_TICK 件之後把那塊 30 件的卸載 ⇒ 可觀測降到 24 ≤ 45。
-- 有 0-cache：第二個 tick 剩下的 victim 共用同一個「讀不到」結論 ⇒ 那塊只被探測 1 次。
-- 沒有 0-cache：每件 victim 各探測一次。
local savedArea20 = sandbox.MaxFloorItemsPerTypeArea
local savedChunk20 = sandbox.MaxFloorItemsPerType
local savedRadius20 = sandbox.ScanRadius
sandbox.MaxFloorItemsPerTypeArea = 45
sandbox.MaxFloorItemsPerType = 200
sandbox.ScanRadius = 16

local BIG_CX, BIG_CY = 14, 10
for index = 0, 3 do
    local cx = 10 + index
    for _ = 1, 10 do
        putOnFloor(cx * 8 + 6, 10 * 8 + 6, 0, makeItem("Base.Shard", "dumper"))
    end
end
for _ = 1, 30 do
    putOnFloor(BIG_CX * 8 + 6, BIG_CY * 8 + 6, 0, makeItem("Base.Shard", "dumper"))
end
check(countFloor("Base.Shard") == 70, "起始：4 塊各 10 件＋1 塊 30 件、總量 70（區域上限 45）")

nowMs = nowMs + 61000
runTicks(3000)
check(countFloor("Base.Shard") == 70, "第一輪只警告、不刪")

nowMs = nowMs + 61000
-- 跑到佇列開始消化（排入 25 件，一個 tick 只消化 ITEMS_PER_TICK 件 ⇒ 必定跨 tick）
local t20 = 0
while countFloor("Base.Shard") == 70 and t20 < 3000 do
    runTicks(1)
    t20 = t20 + 1
end
local shardMid = countFloor("Base.Shard")
check(shardMid < 70 and shardMid > 45,
    "第二輪開始刪但還沒刪完（剩 " .. shardMid .. " 件，佇列裡還有同型的 victim）")

-- 把 30 件那塊卸載：可觀測量掉到上限以下 ⇒ 剩下的 victim 每件都會走完整份來源集後被取消
unloadedChunks[BIG_CX .. "," .. BIG_CY .. ",0"] = true
probeChunk = { cx = BIG_CX, cy = BIG_CY, z = 0 }
probeChunkChecks = 0
runTicks(1)
check(countFloor("Base.Shard") == shardMid,
    "可觀測量低於上限後，剩下的 victim 全被取消（一件都沒再刪）")
-- 上限取 5 而不是等於 1：這個 tick 若掃描器正好在掃那一塊，consumeScanQueue 的每 tick 重查
-- 會另外貢獻一次探測（掃描進度受前面情境殘留的 job 影響，不可控）。差異仍然顯著——少了
-- 0-cache 的話，剩下的每一件 victim 都會各探測一次，量級是 victim 數（這裡約 9）
check(probeChunkChecks > 0 and probeChunkChecks <= 5,
    "同一 tick 內那塊卸載來源最多被探測 " .. probeChunkChecks
        .. " 次（釘住讀不到的來源記 0 進本 tick 快取；沒有它會是 victim 件數）")

unloadedChunks[BIG_CX .. "," .. BIG_CY .. ",0"] = nil
probeChunk = nil

sandbox.MaxFloorItemsPerTypeArea = savedArea20
sandbox.MaxFloorItemsPerType = savedChunk20
sandbox.ScanRadius = savedRadius20
sandbox.MaxFloorItemsPerType = savedChunk17
sandbox.MaxFloorItemsPerTypeArea = savedArea17
print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
