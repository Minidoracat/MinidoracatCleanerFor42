--[[
用假的 PZ 全域驅動真正的 Core.lua / WorldScanner.lua / Commands.lua，跑四條路徑並斷言結果。

    lua scripts/smoke_scanner.lua        （在 repo 根目錄執行）

情境一：自動清理的 normal／high 雙桶分流（掃描 → 警告 → 下一輪確認 → 刪除）
情境二：批次手動刪除的索引建立與安全邊界（範圍外、被牆阻隔、最愛物品都不得被刪）
情境三：提早退出（只刪背包內物品時不得掃描世界，但也不得因此略過把關）
情境四：拒絕路徑（保險屋拒絕、無所在格）與記憶體配置上限

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

local tickHandlers, clientCommandHandlers = {}, {}
Events = setmetatable({}, {
    __index = function(_, name)
        return {
            Add = function(fn)
                if name == "OnTick" then tickHandlers[#tickHandlers + 1] = fn
                elseif name == "OnClientCommand" then clientCommandHandlers[#clientCommandHandlers + 1] = fn end
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

-- 家具容器：getParent 非 nil 才通得過 isSyncableContainer 的 MP 檢查
local function makeContainer(owner)
    local c
    c = {
        _items = {},
        getItems = function(self) return javaList(self._items) end,
        getCharacter = function() return owner == "player" and true or nil end,
        getParent = function() return owner == "furniture" and true or nil end,
        getWorldItem = function() return nil end,
        DoRemoveItem = function(self, item)
            for i, it in ipairs(self._items) do
                if it == item then table.remove(self._items, i) break end
            end
        end,
        add = function(self, item) self._items[#self._items + 1] = item; item._container = c; return item end,
    }
    return c
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

local function putFurniture(x, y, z, container)
    local square = getOrMakeSquare(x, y, z)
    square._containers[#square._containers + 1] = {
        getContainerCount = function() return 1 end,
        getContainerByIndex = function() return container end,
    }
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

-- ===== 情境五：Kahlua 沒有的標準 Lua 全域（靜態掃描）=====
-- 這個 harness 跑在標準 Lua 上，next/assert/xpcall 全都存在，所以「執行測試」在架構上
-- 永遠抓不到誤用——0.2.2 的 next(index) 就是這樣溜到正式服，讓動物清理每輪拋
-- 「Object tried to call nil」而整輪中斷（正式服 server-console 累積 91 次）。
-- Kahlua 的 BaseLib 只註冊 collectgarbage/error/getfenv/getmetatable/pcall/print/
-- rawequal/rawget/rawset/select/setfenv/setmetatable/tonumber/tostring/type/unpack；
-- pairs/ipairs 另由 TableLib 註冊，可用。以下三個在整個 kahlua 樹都找不到。
print()
print("情境五：Kahlua 缺少的標準 Lua 全域（原始碼掃描）")

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

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
