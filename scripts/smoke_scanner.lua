--[[
地面物品掃描器的煙霧測試：用假的 PZ 全域驅動真正的 Core.lua / WorldScanner.lua，
跑完整條「掃描 → 警告 → 下一輪確認 → 刪除」流程並斷言結果。

    lua scripts/smoke_scanner.lua        （在 repo 根目錄執行）

為什麼需要它：luac -p 只驗語法，抓不到「改了函式簽章但漏改呼叫點」這類執行期錯誤——
hotspotKey 從兩參數改成三參數時，processDeleteQueue 的呼叫點漏改，要等到第一件物品
真的被刪除才會炸。這個 harness 會在該路徑上失敗。

限制：這是標準 Lua 5.x，不是遊戲用的 Kahlua。它能抓邏輯／arity／nil 錯誤，但**不能**
證明 Kahlua 專屬的行為（table.sort 遞迴深度、Java field 不暴露、rawget 呼叫形式等）。
那些仍然只能靠反編譯查證與實機測試。
]]

local MEDIA = "MOD/MinidoracatCleanerFor42/Contents/mods/MinidoracatCleanerFor42/42/media/lua"

-- ===== 假的 PZ 全域 =====
-- 起始時間必須大於掃描間隔：queuePeriodicScan 的條件是 now - lastPeriodicAt >= interval，
-- 而 lastPeriodicAt 初值為 0。遊戲裡 getTimestampMs() 本來就是很大的系統時間，從 0 起跳
-- 只是 harness 的假象
local nowMs = 5000000
local logLines = {}
local sentCommands = {}

function getTimestampMs() return nowMs end
function isClient() return false end
function isServer() return true end
function instanceof() return false end
function writeLog(_, text) logLines[#logLines + 1] = text end
function getItemNameFromFullType(fullType) return fullType end
function getScriptManager() return { FindItem = function() return nil end } end
function sendServerCommand(playerObj, _, command, args)
    sentCommands[#sentCommands + 1] = { player = playerObj, command = command, args = args }
end

DesignationZoneAnimal = { removeItemFromGround = function() end }

SandboxVars = {
    MinidoracatCleanerFor42 = {
        MaxFloorItemsPerType = 10,
        MaxFloorItemsPerTypeArea = 40,
        HighToleranceMaxPerType = 100,
        HighToleranceMaxPerTypeArea = 400,
        HighToleranceList = "",
        ProtectList = "",
        TouchTraceEnabled = true,
        ScanRadius = 16,
        ScanIntervalSeconds = 60,
    },
}

local tickHandlers = {}
Events = setmetatable({}, {
    __index = function(_, name)
        return {
            Add = function(fn) if name == "OnTick" then tickHandlers[#tickHandlers + 1] = fn end end,
        }
    end,
})

-- java 風格的容器（size()/get(i)，0-based）
local function javaList(items)
    return {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
        _raw = items,
    }
end

-- ===== 世界模型 =====
local world = {}       -- ["x,y,z"] = square

local function squareKey(x, y, z) return x .. "," .. y .. "," .. z end

local function getOrMakeSquare(x, y, z)
    local key = squareKey(x, y, z)
    local square = world[key]
    if square then return square end
    square = {
        _objs = {},
        getX = function(self) return x end,
        getY = function(self) return y end,
        getZ = function(self) return z end,
        getWorldObjects = function(self) return javaList(self._objs) end,
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

local nextID = 1000
local function dropItem(x, y, z, fullType, dropper)
    nextID = nextID + 1
    local modData = {}
    if dropper then modData.MIC42_lastDroppedBy = dropper end
    local item = {
        getID = function(self) return self._id end,
        getFullType = function(self) return self._fullType end,
        isFavorite = function() return false end,
        hasModData = function() return true end,
        getModData = function(self) return self._modData end,
        setWorldItem = function() end,
        _id = nextID, _fullType = fullType, _modData = modData,
    }
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

function getCell()
    return { getGridSquare = function(_, x, y, z) return world[squareKey(x, y, z)] end }
end

local player = {
    getX = function() return 100 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
    getUsername = function() return "tester" end,
    getOnlineID = function() return 1 end,
    getCurrentSquare = function() return getOrMakeSquare(100, 100, 0) end,
}
function getOnlinePlayers() return javaList({ player }) end

-- ===== 載入受測程式碼 =====
local loaded = {}
function require(name)
    if loaded[name] then return loaded[name] end
    loaded[name] = true
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local path = MEDIA .. "/" .. dir .. "/" .. name .. ".lua"
        local chunk = loadfile(path)
        if chunk then chunk() return true end
    end
    error("require 找不到: " .. name)
end

require "MinidoracatCleaner_Core"
require "MinidoracatCleaner_WorldScanner"

-- ===== 測試工具 =====
local failures = 0
local function check(ok, label)
    if ok then
        print("  PASS  " .. label)
    else
        failures = failures + 1
        print("  FAIL  " .. label)
    end
end

local function runTicks(count)
    for _ = 1, count do
        for _, fn in ipairs(tickHandlers) do fn() end
    end
end

local function countLive(fullType, dropper)
    local total = 0
    for _, square in pairs(world) do
        for _, worldObj in ipairs(square._objs) do
            local item = worldObj:getItem()
            if item:getFullType() == fullType then
                local stamped = rawget(item:getModData(), "MIC42_lastDroppedBy") ~= nil
                if dropper == nil or stamped == dropper then total = total + 1 end
            end
        end
    end
    return total
end

local function warnCount()
    local n = 0
    for _, entry in ipairs(sentCommands) do
        if entry.command == "warn" then n = n + 1 end
    end
    return n
end

-- ===== 情境：同一區塊內混著「世界原生」與「玩家傾倒」的同種物品 =====
-- 全部落在區塊 (12,12,0)（x/y 皆 96..103），玩家站在 (100,100) 也在該區塊內，
-- 讓「每區塊」成為唯一觸發原因：區域上限 40／400 都不會被 25／20 件碰到
-- 20 件無標記（高容忍桶，20 <= 100 → 不該動）
-- 25 件有標記（一般桶，25 > 10 → 該刪 15 件）
print("情境：混合來源的同種地面物品")
for i = 1, 20 do dropItem(96 + (i % 8), 96, 0, "Base.Log", nil) end
for i = 1, 25 do dropItem(96 + (i % 8), 97, 0, "Base.Log", "griefer") end

check(countLive("Base.Log", false) == 20, "起始：無標記 20 件")
check(countLive("Base.Log", true) == 25, "起始：有標記 25 件")

-- 第一輪掃描：只警告，不刪
runTicks(400)
check(warnCount() >= 1, "第一輪發出警告")
check(countLive("Base.Log") == 45, "第一輪不刪任何東西（警告後才刪）")

-- 時間推進超過掃描間隔，第二輪確認後執行刪除
nowMs = nowMs + 61000
runTicks(600)

check(countLive("Base.Log", false) == 20, "高容忍桶（無標記）完全沒被動到")
check(countLive("Base.Log", true) == 10, "一般桶（有標記）被刪到剛好等於上限 10")

local cleaned = 0
for _, line in ipairs(logLines) do
    if line:find("auto_clean", 1, true) then cleaned = cleaned + 1 end
end
check(cleaned >= 1, "有寫出 auto_clean 記錄（刪除後的聚合輸出路徑沒有炸）")

print()
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
