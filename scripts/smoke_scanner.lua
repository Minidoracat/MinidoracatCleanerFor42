--[[
用假的 PZ 全域驅動真正的 Core.lua / WorldScanner.lua / Commands.lua，跑四條路徑並斷言結果。

    lua scripts/smoke_scanner.lua        （在 repo 根目錄執行）

情境一：自動清理的 normal／high 雙桶分流（掃描 → 警告 → 下一輪確認 → 刪除）
情境二：批次手動刪除的索引建立與安全邊界（範圍外、被牆阻隔、最愛物品都不得被刪）
情境三：提早退出（只刪背包內物品時不得掃描世界，但也不得因此略過把關）
情境四：拒絕路徑（保險屋拒絕、無所在格）與記憶體配置上限
情境五：週期掃描修復被刪空的容器（三種正常狀態當對照組，確認修復不外溢）
情境六：Kahlua 缺少的標準 Lua 全域（原始碼靜態掃描）

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
            return world[squareKey(x, y, z)]
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

local function putOnFloor(x, y, z, item)
    local square = getOrMakeSquare(x, y, z)
    local worldObj = {
        getItem = function(self) return self._item end,
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
local player = {
    getX = function() return 100 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
    getUsername = function() return "tester" end,
    getOnlineID = function() return 1 end,
    getCurrentSquare = function() return playerHasSquare and getOrMakeSquare(100, 100, 0) or nil end,
    getInventory = function() return playerInv end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
function getOnlinePlayers() return javaList({ player }) end
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

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
