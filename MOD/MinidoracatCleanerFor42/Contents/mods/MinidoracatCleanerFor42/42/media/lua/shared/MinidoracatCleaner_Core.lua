MinidoracatCleaner = MinidoracatCleaner or {}

local Cleaner = MinidoracatCleaner

Cleaner.MOD_ID = "MinidoracatCleanerFor42"
Cleaner.COMMAND_MODULE = "MinidoracatCleaner"
-- 註：0.1.4 移除了「最後接觸者」追蹤（與丟棄者幾乎總是同一人、可靠度較低、且多一個 modData
-- 欄位會讓同型物品更難被壓縮合併）。舊存檔殘留的 MIC42_lastTouchedBy 不再讀取，無需清理。
Cleaner.KEY_DROPPED = "MIC42_lastDroppedBy"

Cleaner.DEFAULTS = {
    AllowManualDelete = true,
    MaxFloorItemsPerType = 100,
    MaxFloorItemsPerTypeArea = 400,
    ScanRadius = 80,
    ScanIntervalSeconds = 60,
    ProtectList = "",
    TouchTraceEnabled = true,
    MaxAnimalsPerGroup = 50,
    MaxZoneAnimalsPerGroup = 0,
    AnimalGroupList = "",
    AnimalLimitOverrides = "",
    AnimalZoneLimitOverrides = "",
    AnimalScanRadius = 64,
    AnimalScanIntervalSeconds = 10,
}

Cleaner.CONSTANTS = {
    SQUARES_PER_TICK = 48,
    ITEMS_PER_TICK = 16,
    DIRTY_DELAY_MS = 60000,
    ANIMALS_PER_ROUND = 20,
    ANIMAL_EMERGENCY_MULTIPLIER = 2,
    ZONE_BUFFER = 2,
    MANUAL_DELETE_LIMIT = 100,
    WARNING_RADIUS = 30,
    CHUNK_SIZE = 8,
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Cleaner.getOption(name)
    local section = SandboxVars and SandboxVars[Cleaner.MOD_ID]
    local value = section and section[name]
    if value == nil then
        return Cleaner.DEFAULTS[name]
    end
    return value
end

function Cleaner.parseList(value, fallback)
    local result = {}
    local text = trim(value)
    if text == "" then
        if fallback then
            for _, entry in ipairs(fallback) do
                result[#result + 1] = entry
            end
        end
        return result
    end

    text = text:gsub("，", ","):gsub(";", ",")
    for token in text:gmatch("([^,]+)") do
        token = trim(token)
        if token ~= "" then
            result[#result + 1] = token
        end
    end
    return result
end

-- 保護清單支援關鍵字：token 對「fullType／點號後段／英文 DisplayName／伺服器語言翻譯名」做
-- 不分大小寫子字串比對。翻譯名依伺服器端語言（GameServer.java:595 有 loadFiles；
-- getItemNameFromFullType＝LuaManager.java:8579）
function Cleaner.getProtectMatcher()
    local tokens = {}
    for _, token in ipairs(Cleaner.parseList(Cleaner.getOption("ProtectList"))) do
        tokens[#tokens + 1] = string.lower(token)
    end
    return { tokens = tokens, cache = {} }
end

local function itemMatchNames(fullType)
    local names = { string.lower(fullType) }
    local typePart = string.match(fullType, "%.(.+)$")
    if typePart then
        names[#names + 1] = string.lower(typePart)
    end
    local script = getScriptManager():FindItem(fullType)
    if script then
        local displayName = script:getDisplayName()
        if displayName and displayName ~= "" then
            names[#names + 1] = string.lower(displayName)
        end
    end
    local translated = getItemNameFromFullType(fullType)
    if translated and translated ~= "" then
        names[#names + 1] = string.lower(translated)
    end
    return names
end

function Cleaner.isProtectedType(matcher, fullType)
    if not matcher or #matcher.tokens == 0 or not fullType then
        return false
    end
    local cached = matcher.cache[fullType]
    if cached ~= nil then
        return cached
    end
    local result = false
    local names = itemMatchNames(fullType)
    for _, token in ipairs(matcher.tokens) do
        for _, name in ipairs(names) do
            if string.find(name, token, 1, true) then
                result = true
                break
            end
        end
        if result then
            break
        end
    end
    matcher.cache[fullType] = result
    return result
end

-- 動物群組名稱索引：group key → { 各 type key、各 type 翻譯名（IGUI_AnimalType_<type>，依端語言） }
-- 供關鍵字解析：「老鼠」→ 公老鼠/小老鼠/母老鼠（CH IG_UI.json:2063-2065）→ rat 群組
local function buildAnimalNameIndex()
    local index = {}
    local defs = AnimalDefinitions and AnimalDefinitions.animals
    if type(defs) == "table" then
        for animalType, def in pairs(defs) do
            local group = def and def.group
            if group then
                group = string.lower(tostring(group))
                local names = index[group]
                if not names then
                    names = {}
                    index[group] = names
                end
                names[#names + 1] = string.lower(tostring(animalType))
                local key = "IGUI_AnimalType_" .. tostring(animalType)
                local translated = getText(key)
                if translated and translated ~= key then
                    names[#names + 1] = string.lower(translated)
                end
            end
        end
    end
    return index
end

-- token 解析為 group key：先精確比對 group/type key（避免子字串誤擴），再對翻譯名做子字串比對
local function resolveAnimalGroups(token, index, result)
    token = string.lower(trim(token))
    if token == "" then
        return
    end
    if index[token] then
        result[token] = true
        return
    end
    local matched = false
    for group, names in pairs(index) do
        for _, name in ipairs(names) do
            if name == token or string.find(name, token, 1, true) then
                result[group] = true
                matched = true
                break
            end
        end
    end
    if not matched then
        -- 未知 token（可能是其他 MOD 動物的 group key）：原樣保留，fail-closed 語意不變
        result[token] = true
    end
end

function Cleaner.getAnimalGroupSet()
    local result = {}
    local defaults = { "rat", "mouse", "rabbit", "chicken" }
    local index = buildAnimalNameIndex()
    for _, token in ipairs(Cleaner.parseList(Cleaner.getOption("AnimalGroupList"), defaults)) do
        resolveAnimalGroups(token, index, result)
    end
    return result
end

local function parseGroupLimits(optionName)
    local result = {}
    local entries = Cleaner.parseList(Cleaner.getOption(optionName))
    local index = buildAnimalNameIndex()
    for _, entry in ipairs(entries) do
        local group, value = entry:match("^%s*([^=]+)%s*=%s*(%d+)%s*$")
        value = tonumber(value)
        if group and value and value >= 0 then
            local resolved = {}
            resolveAnimalGroups(group, index, resolved)
            for groupKey in pairs(resolved) do
                result[groupKey] = math.floor(value)
            end
        end
    end
    return result
end

-- 散養上限的逐群組覆寫
function Cleaner.getAnimalLimitOverrides()
    return parseGroupLimits("AnimalLimitOverrides")
end

-- 圈養上限的逐群組覆寫（0＝該群組圈養永不清理）
function Cleaner.getAnimalZoneLimitOverrides()
    return parseGroupLimits("AnimalZoneLimitOverrides")
end

function Cleaner.sanitize(value)
    -- 清換行/tab 防整行注入；[ ] 換成 ( ) 防偽造 log 欄位邊界（username 允許 [ ]，見 ServerWorldDatabase.java:763-779）
    return tostring(value or "unknown"):gsub("[\r\n\t]", " "):gsub("%[", "("):gsub("%]", ")")
end

function Cleaner.log(event, who, x, y, z, detail)
    local location = Cleaner.sanitize(x) .. "," .. Cleaner.sanitize(y) .. "," .. Cleaner.sanitize(z)
    local text = "[" .. Cleaner.sanitize(event) .. "]"
        .. "[" .. Cleaner.sanitize(who) .. "]"
        .. "[" .. location .. "]"
        .. "[" .. Cleaner.sanitize(detail) .. "]"
    -- LuaManager.java:9171-9177
    writeLog(Cleaner.MOD_ID, text)
end

-- 裝著東西的容器不可刪（避免連同內容物一起銷毀）；空容器可刪。
-- getInventory() 只存在於 InventoryContainer（InventoryContainer.java:49），
-- 故先用 vanilla 慣用的 instanceof 判定（ISInventoryPane.lua:967 等）再取用。
-- 註：所有鑰匙環（含 Memento 類的裝飾款，如 KeyRing_PineTree）都是 capacity 1 的容器且
-- 帶 base:keyring tag，不能用 tag 一律排除——空的裝飾鑰匙環是垃圾，玩家本來就該能刪。
function Cleaner.hasContents(item)
    if not item or not instanceof(item, "InventoryContainer") then
        return false
    end
    local inventory = item:getInventory()
    -- ItemContainer.java:2275
    return inventory ~= nil and not inventory:isEmpty()
end

function Cleaner.isEquippedOrWorn(playerObj, item)
    -- IsoGameCharacter.java:10355-10367 (isEquipped = worn+hands; isAttachedItem = hotbar/belt)
    return playerObj ~= nil and item ~= nil
        and (playerObj:isEquipped(item) or playerObj:isAttachedItem(item))
end

-- 手動刪除只擋「最愛」與「裝備／穿戴／掛載中」——都是防手滑的硬保護。
-- 有內容的容器**不擋**：帶 NeverEmpty tag 的容器（所有鑰匙環）在戰利品生成時若內容為空會被直接
-- 移除（ItemPickerJava.java:1160），意即世上不存在空鑰匙環，擋掉等於整個系列永遠不能刪。
-- vanilla 垃圾桶同樣允許銷毀裝滿的容器；改由確認視窗揭露內容物數量，讓玩家自己決定。
function Cleaner.canManuallyDelete(playerObj, item)
    return item ~= nil
        and not item:isFavorite()
        and not Cleaner.isEquippedOrWorn(playerObj, item)
end

-- 選取清單中所有容器的內容物總數（供確認視窗揭露風險）
function Cleaner.countContainedItems(items)
    local total = 0
    for _, item in ipairs(items) do
        if Cleaner.hasContents(item) then
            total = total + item:getInventory():getItems():size()
        end
    end
    return total
end

function Cleaner.isSafeFloorCandidate(item, worldObj, protectMatcher)
    if not item or not worldObj or item:isFavorite() or worldObj:isIgnoreRemoveSandbox() then
        return false
    end
    if Cleaner.isProtectedType(protectMatcher, item:getFullType()) then
        return false
    end
    if Cleaner.hasContents(item) then
        return false
    end
    return true
end

function Cleaner.getItemModDataValue(item, key)
    if not item or not item:hasModData() then
        return nil
    end
    -- 全域 rawget；方法式 :rawget 對 Kahlua 原生 table 無效（見 Tooltip 同註）
    return rawget(item:getModData(), key)
end

function Cleaner.stampItem(item, key, username)
    if item and username and username ~= "" then
        rawset(item:getModData(), key, Cleaner.sanitize(username))
    end
end

-- Kahlua 的 table.sort 是遞迴 quicksort，跑在 coroutine 堆疊上（MAX_STACK_SIZE=3000，
-- Coroutine.java:16）。輸入已接近排序時退化成 O(n) 遞迴深度，數百筆即 stack overflow。
-- 以下為迭代式 bottom-up merge sort：無遞迴、穩定、O(n log n)。
function Cleaner.sortSafe(list, comp)
    local n = #list
    if n < 2 then
        return list
    end
    local buf = {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local midEnd = i + width - 1
            if midEnd > n then midEnd = n end
            local hiEnd = i + width * 2 - 1
            if hiEnd > n then hiEnd = n end
            local a, b, k = i, midEnd + 1, i
            while a <= midEnd and b <= hiEnd do
                if comp(list[b], list[a]) then
                    buf[k] = list[b]; b = b + 1
                else
                    buf[k] = list[a]; a = a + 1
                end
                k = k + 1
            end
            while a <= midEnd do buf[k] = list[a]; a = a + 1; k = k + 1 end
            while b <= hiEnd do buf[k] = list[b]; b = b + 1; k = k + 1 end
            i = i + width * 2
        end
        for j = 1, n do
            list[j] = buf[j]
        end
        width = width * 2
    end
    return list
end

function Cleaner.chebyshevDistance(x1, y1, x2, y2)
    return math.max(math.abs(x1 - x2), math.abs(y1 - y2))
end

function Cleaner.getActivePlayers()
    local result = {}
    if isServer() then
        local players = getOnlinePlayers()
        if players then
            for index = 0, players:size() - 1 do
                local playerObj = players:get(index)
                if playerObj then
                    result[#result + 1] = playerObj
                end
            end
        end
    else
        local playerObj = getSpecificPlayer(0)
        if playerObj then
            result[1] = playerObj
        end
    end
    return result
end

local function notifyNearby(command, payload, clientHandler)
    for _, playerObj in ipairs(Cleaner.getActivePlayers()) do
        if Cleaner.chebyshevDistance(playerObj:getX(), playerObj:getY(), payload.x, payload.y) <= Cleaner.CONSTANTS.WARNING_RADIUS then
            if isServer() then
                sendServerCommand(playerObj, Cleaner.COMMAND_MODULE, command, payload)
            elseif clientHandler then
                -- SP：client 檔已載入，直接呼叫顯示函式
                clientHandler(playerObj, payload)
            end
        end
    end
end

-- scope（選填）："zone"＝圈養（圈地/雞舍）觸發，client 端據此換措辭
function Cleaner.warnNearby(kind, x, y, z, detail, scope)
    notifyNearby("warn", { kind = kind, x = x, y = y, z = z, detail = detail, scope = scope }, Cleaner.showWarning)
end

function Cleaner.notifyCleaned(kind, detail, count, x, y, z, scope, remaining)
    notifyNearby("cleaned", { kind = kind, detail = detail, count = count, x = x, y = y, z = z, scope = scope, remaining = remaining }, Cleaner.showCleaned)
end

local function findInContainer(container, id)
    if not container then
        return nil
    end
    local item = container:getItemWithID(id)
    if not item then
        -- ItemContainer.java:3065-3088
        item = container:getItemWithIDRecursiv(id)
    end
    return item
end

local function containerResult(container, id)
    local item = findInContainer(container, id)
    if item then
        return { item = item, kind = "container", container = item:getContainer() or container }
    end
    return nil
end

local function findOnSquare(square, playerObj, id, seenVehicles)
    if isServer() then
        -- 尊重保險屋 loot 權限，避免隔牆刪除他人保險屋容器物品（SafeHouse.java:262-264）
        if not SafeHouse.isSafehouseAllowLoot(square, playerObj) then
            return nil
        end
        -- 阻隔檢查：只允許同格/相鄰格（range 已限 1，isBlockedTo 對相鄰邊界可靠；range 2 的中間牆不一定被檢查）。
        -- playerSquare 缺失一律 fail closed（IsoGridSquare.java:837，ISGrabItemAction.lua:16）
        local playerSquare = playerObj:getCurrentSquare()
        if not playerSquare then
            return nil
        end
        if square ~= playerSquare and square:isBlockedTo(playerSquare) then
            return nil
        end
    end
    local worldObjects = square:getWorldObjects()
    for index = 0, worldObjects:size() - 1 do
        local worldObj = worldObjects:get(index)
        local item = worldObj and worldObj:getItem()
        if item and item:getID() == id then
            return { item = item, kind = "floor", worldObj = worldObj, square = square }
        end
        if item and instanceof(item, "InventoryContainer") then
            local found = containerResult(item:getInventory(), id)
            if found then
                return found
            end
        end
    end

    local staticObjects = square:getStaticMovingObjects()
    for index = 0, staticObjects:size() - 1 do
        local object = staticObjects:get(index)
        local found = containerResult(object:getContainer(), id)
        if found then
            return found
        end
    end

    local objects = square:getObjects()
    for index = 0, objects:size() - 1 do
        local object = objects:get(index)
        for containerIndex = 0, object:getContainerCount() - 1 do
            local found = containerResult(object:getContainerByIndex(containerIndex), id)
            if found then
                return found
            end
        end
    end

    local vehicle = square:getVehicleContainer()
    if vehicle and not seenVehicles[vehicle] then
        seenVehicles[vehicle] = true
        for partIndex = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(partIndex)
            if part:getItemContainer() and vehicle:canAccessContainer(partIndex, playerObj) then
                local found = containerResult(part:getItemContainer(), id)
                if found then
                    return found
                end
            end
        end
    end
    return nil
end

function Cleaner.findAccessibleItem(playerObj, id, range)
    if not playerObj or not id then
        return nil
    end

    local inventory = playerObj:getInventory()
    local ownItem = findInContainer(inventory, id)
    if ownItem then
        return { item = ownItem, kind = "container", container = ownItem:getContainer() or inventory, own = true }
    end

    range = range or 1
    local px = math.floor(playerObj:getX())
    local py = math.floor(playerObj:getY())
    local pz = math.floor(playerObj:getZ())
    local seenVehicles = {}
    for y = py - range, py + range do
        for x = px - range, px + range do
            if Cleaner.chebyshevDistance(px, py, x, y) <= range then
                local square = getCell():getGridSquare(x, y, pz)
                if square then
                    local found = findOnSquare(square, playerObj, id, seenVehicles)
                    if found then
                        return found
                    end
                end
            end
        end
    end
    return nil
end

function Cleaner.removeFloorItem(item, worldObj, square)
    if not item or not worldObj or not square then
        return false
    end
    -- 完整 lifecycle cleanup（ISTransferAction.lua:131-159）：清 animal zone 的 foodOnGround 引用
    -- （AnimalData.java:761 仍會用到，否則留 stale reference）
    DesignationZoneAnimal.removeItemFromGround(worldObj)
    -- Radio 在地板上另有獨立的 IsoRadio special object，需一併移除避免 orphan world object
    if instanceof(item, "Radio") then
        local objects = square:getObjects()
        for i = 0, objects:size() - 1 do
            local tObj = objects:get(i)
            if instanceof(tObj, "IsoRadio") and tObj:getModData().RadioItemID == item:getID() then
                square:transmitRemoveItemFromSquare(tObj)
                square:RecalcProperties()
                square:RecalcAllWithNeighbours(true)
                break
            end
        end
    end
    -- ISTransferAction.lua:156-159
    square:transmitRemoveItemFromSquare(worldObj)
    square:removeWorldObject(worldObj)
    item:setWorldItem(nil)
    return true
end

-- sendRemoveItemFromContainer 只同步三類容器（GameServer.java:2445-2461）：玩家背包（getCharacter
-- 遞迴涵蓋背包內袋）、家具容器（getParent）、地板袋（getWorldItem）。世界容器內的巢狀袋三者皆否，
-- server 刪了不發封包 → 所有 client 看到幽靈物品。故 MP 下對不可同步容器 fail-closed。
function Cleaner.isSyncableContainer(container)
    if not container then
        return false
    end
    return container:getCharacter() ~= nil
        or container:getParent() ~= nil
        or container:getWorldItem() ~= nil
end

function Cleaner.removeContainerItem(item, container)
    if not item or not container then
        return false
    end
    if isServer() and not Cleaner.isSyncableContainer(container) then
        return false
    end
    -- ItemContainer.java:2070-2093; ClientCommands.lua:184-186
    container:DoRemoveItem(item)
    if isServer() then
        sendRemoveItemFromContainer(container, item)
    end
    return true
end
