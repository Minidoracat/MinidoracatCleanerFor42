if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner

-- 家具搬移與建造的 server 端稽核紀錄。原版 ClientActionLog 只記「[ISMoveablesAction][名字][座標]」，
-- 分不出撿起／放下，也沒有物件名；建造（ISBuildIsoEntity）更只在 DebugLog 印
-- 「consume success」，沒有玩家與座標。兩者都是在路上放障礙物這類事件唯一的直接證據。
-- 只在 MP server 寫：這兩個函式在 MP 由 server 執行、character 是連線身分，client 偽造不了名字；
-- 單機沒有調查需求。原動作一律先跑，紀錄本身包 pcall，任何失敗都不影響遊戲行為。
--
-- 放置者另存一份在 server 端 global ModData（`<x,y,z>` → `{ [sprite] = "<name>,<epochHour>" }`），
-- **不寫進物件 modData**：物件 modData 會隨物件同步給附近所有玩家，這份只在玩家右鍵查詢時
-- 回給查詢者本人（Commands.lua placedQuery），平時廣播流量為零。
-- 物件被殭屍打壞、燒掉等非 moveable 路徑消失時不會清到這裡；client 端只顯示該格仍存在的
-- sprite，殘留項不會誤導玩家。
-- ponytail: 多格家具只記錨點格，查其他格顯示「沒有紀錄」；有需求再展開成每格一筆
local STORE_KEY = "MinidoracatCleanerPlaced"

local function squareKey(x, y, z)
    return math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z)
end

function Cleaner.readPlaced(x, y, z)
    return ModData.getOrCreate(STORE_KEY)[squareKey(x, y, z)]
end

local function writePlaced(x, y, z, sprite, value)
    local store = ModData.getOrCreate(STORE_KEY)
    local key = squareKey(x, y, z)
    local entries = store[key]
    if value ~= nil then
        entries = entries or {}
        entries[sprite] = value
        store[key] = entries
        return
    end
    if not entries then
        return
    end
    entries[sprite] = nil
    for _ in pairs(entries) do
        return
    end
    store[key] = nil
end

local function placedValue(username)
    return Cleaner.sanitizeName(username) .. "," .. (math.floor(getTimestamp() / 3600) * 3600)
end

local function spriteOf(action)
    local props = action.moveProps
    return (props and props.spriteName) or action.origSpriteName
end

local function recordMoveable(action)
    local square = action.square
    local character = action.character
    if not square or not character then
        return
    end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local sprite = spriteOf(action)
    local detail = "mode=" .. tostring(action.mode) .. " sprite=" .. tostring(sprite)
    if action.mode == "place" and action.item then
        detail = detail .. " item=" .. action.item:getFullType()
    end
    Cleaner.log("moveable", character:getUsername(), x, y, z, detail)
    if not sprite then
        return
    end
    if action.mode == "place" then
        writePlaced(x, y, z, sprite, placedValue(character:getUsername()))
    elseif action.mode == "pickup" or action.mode == "scrap" then
        writePlaced(x, y, z, sprite, nil)
    elseif action.mode == "rotate" and action.origMoveProps then
        -- 轉向換 sprite，放置者不變：搬到新 sprite 底下
        local entries = Cleaner.readPlaced(x, y, z)
        local oldSprite = action.origMoveProps.spriteName
        local value = entries and oldSprite and entries[oldSprite]
        if value then
            writePlaced(x, y, z, oldSprite, nil)
            writePlaced(x, y, z, sprite, value)
        end
    end
end

local function objectCount(x, y, z)
    local square = getCell():getGridSquare(x, y, z)
    return square and square:getObjects():size() or 0
end

local function recipeName(entity)
    if entity.craftRecipe then
        return entity.craftRecipe:getName()
    end
    return entity.objectInfo and entity.objectInfo:getScript():getName()
end

local function installWorldAuditHooks()
    if Cleaner._worldAuditInstalled or not isServer() then
        return
    end
    Cleaner._worldAuditInstalled = true

    local originalMoveableComplete = ISMoveablesAction.complete
    function ISMoveablesAction:complete()
        local result = originalMoveableComplete(self)
        pcall(recordMoveable, self)
        return result
    end

    if ISBuildIsoEntity then
        local originalBuildCreate = ISBuildIsoEntity.create
        function ISBuildIsoEntity:create(x, y, z, north, sprite)
            local okBefore, before = pcall(objectCount, x, y, z)
            local result = originalBuildCreate(self, x, y, z, north, sprite)
            -- create 成功與失敗都回 nil，只能看錨點格物件數有沒有增加判斷是否真的蓋出來。
            -- ponytail: 只看錨點格；多格物件的其他格不另計，錨點格一定有物件，夠判斷成敗
            pcall(function()
                if not okBefore or objectCount(x, y, z) <= before or not self.character then
                    return
                end
                local _, recipe = pcall(recipeName, self)
                Cleaner.log("build", self.character:getUsername(), x, y, z,
                    "sprite=" .. tostring(sprite) .. " recipe=" .. tostring(recipe))
                if sprite then
                    writePlaced(x, y, z, sprite, placedValue(self.character:getUsername()))
                end
            end)
            return result
        end
    end
end

Events.OnServerStarted.Add(installWorldAuditHooks)
