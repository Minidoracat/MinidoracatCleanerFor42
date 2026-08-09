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
    HighToleranceMaxPerType = 300,
    HighToleranceMaxPerTypeArea = 2000,
    HighToleranceList = "",
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
    -- 警告記錄的閒置回收門檻（幾個掃描間隔沒再被掃到就丟棄）
    WARN_STALE_INTERVALS = 20,
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

-- 關鍵字清單：token 對「fullType／點號後段／英文 DisplayName／伺服器語言翻譯名」做
-- 不分大小寫子字串比對。翻譯名依伺服器端語言（GameServer.java:595 有 loadFiles；
-- getItemNameFromFullType＝LuaManager.java:8579）
function Cleaner.getKeywordMatcher(optionName)
    local tokens = {}
    for _, token in ipairs(Cleaner.parseList(Cleaner.getOption(optionName))) do
        tokens[#tokens + 1] = string.lower(token)
    end
    return { tokens = tokens, cache = {} }
end

function Cleaner.getProtectMatcher()
    return Cleaner.getKeywordMatcher("ProtectList")
end

function Cleaner.getHighToleranceMatcher()
    return Cleaner.getKeywordMatcher("HighToleranceList")
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

function Cleaner.matchesType(matcher, fullType)
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
--
-- 只建一次就快取：AnimalDefinitions 與端語言在執行期都不會變。舊版由三個 getter 各自建一份，
-- 每輪動物掃描等於重建三遍（走訪全部物種＋每個物種一次 getText），其中兩遍還是為了
-- 內容為空的覆寫選項而白做
local animalNameIndex = nil

local function buildAnimalNameIndex()
    if animalNameIndex then
        return animalNameIndex
    end
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
    -- AnimalDefinitions 若還沒載入就會得到空索引，此時不要快取，下次再試
    if next(index) ~= nil then
        animalNameIndex = index
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
    -- 覆寫選項留空是常態，此時完全不必碰名稱索引
    if #entries == 0 then
        return result
    end
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
    if Cleaner.matchesType(protectMatcher, item:getFullType()) then
        return false
    end
    if Cleaner.hasContents(item) then
        return false
    end
    return true
end

-- 高容忍桶的歸屬。兩個管道共用同一組高閾值：
--   ① 身上沒有丟棄者標記 → 世界原生，或 MOD 安裝前就躺在地上的舊物
--   ② 命中高容忍清單 → 管理員明確指定要放寬的物品
-- 為什麼用「有沒有標記」而不是判斷物種：引擎其實有完美的判別式
-- IsoWorldInventoryObject.dropTime（預設 -1.0，只在被丟到地上時賦值；:65,101），原版
-- 自己就是靠 dropTime > -1 決定要不要自動移除地上物品（IsoGridSquare.java:3284）。
-- 但它是沒有 getter 的 public instance field，Kahlua 不暴露 → Lua 讀出來是 nil 且不報錯。
-- 我們自己在伺服器端蓋的丟棄者章，就是同一語意在 Lua 端唯一能取得的近似。
function Cleaner.isHighTolerance(matcher, item, fullType, stampsEnabled)
    if Cleaner.matchesType(matcher, fullType) then
        return true
    end
    -- 標記追蹤關閉時沒有任何物品有章，照章判定會讓全部物品落進高容忍桶＝清理形同關閉，
    -- 故此時只認清單（fail-closed）
    if not stampsEnabled then
        return false
    end
    return Cleaner.getItemModDataValue(item, Cleaner.KEY_DROPPED) == nil
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
-- count/limit（選填）：實際偵測數與當前上限，client 端顯示於警告文字讓玩家知道差多少
function Cleaner.warnNearby(kind, x, y, z, detail, scope, count, limit)
    notifyNearby("warn", { kind = kind, x = x, y = y, z = z, detail = detail, scope = scope, count = count, limit = limit }, Cleaner.showWarning)
end

-- 只送給指定玩家。「某位玩家周邊超量」這類訊息本來就是對他個人講的：
-- 用 notifyNearby 廣播的話，相鄰的兩位玩家各自超標時會互相收到對方那則（重複洗版），
-- 更糟的是錨點若離該玩家超過 WARNING_RADIUS，當事人反而收不到自己的通知
local function notifyPlayer(playerObj, command, payload, clientHandler)
    if not playerObj then
        return
    end
    payload.x = playerObj:getX()
    payload.y = playerObj:getY()
    payload.z = playerObj:getZ()
    if isServer() then
        sendServerCommand(playerObj, Cleaner.COMMAND_MODULE, command, payload)
    elseif clientHandler then
        clientHandler(playerObj, payload)
    end
end

function Cleaner.warnPlayerOnly(playerObj, kind, detail, count, limit, scope)
    notifyPlayer(playerObj, "warn",
        { kind = kind, detail = detail, count = count, limit = limit, scope = scope },
        Cleaner.showWarning)
end

function Cleaner.notifyCleanedPlayerOnly(playerObj, kind, detail, count, scope, remaining)
    notifyPlayer(playerObj, "cleaned",
        { kind = kind, detail = detail, count = count, scope = scope, remaining = remaining },
        Cleaner.showCleaned)
end

-- normal 與 high 是各自獨立的兩組上限，任一為正就仍需掃描；四個全為 0 才是「完全關閉」。
-- （只看 normal 兩項會讓「normal=0、high>0」的設定意外整個停擺）
function Cleaner.isFloorCleaningDisabled()
    local names = {
        "MaxFloorItemsPerType",
        "MaxFloorItemsPerTypeArea",
        "HighToleranceMaxPerType",
        "HighToleranceMaxPerTypeArea",
    }
    for _, name in ipairs(names) do
        if (tonumber(Cleaner.getOption(name)) or 0) > 0 then
            return false
        end
    end
    return true
end

function Cleaner.notifyCleaned(kind, detail, count, x, y, z, scope, remaining)
    notifyNearby("cleaned", { kind = kind, detail = detail, count = count, x = x, y = y, z = z, scope = scope, remaining = remaining }, Cleaner.showCleaned)
end

-- 建索引時的共用狀態。ctx.wanted 非 nil 時，一旦要找的 id 全數到齊就可以提早收工——
-- 這保住了舊版「東西就在玩家背包裡就命中、完全不碰世界」的提早退出特性。
-- 少了它，右鍵刪背包裡的 1 件東西也會把周遭每個箱子的每一件都建成 entry，
-- 在囤積型基地是上萬筆小 table 的配置與 GC 壓力。
-- 只替被點名的 id 配置 record。少了這道過濾，光是一個不存在的 id 就會替範圍內每一件
-- 可及物品各配一個 record——而 Kahlua 的每個 table 都是獨立的 KahluaTableImpl（底層
-- LinkedHashMap，J2SEPlatform.java:35、KahluaTableImpl.java:18），不是標準 Lua 那種輕量 table。
-- 以 42.20.2 實測 10 萬筆三欄 record 約佔 35 MiB；配上 250ms 節流仍允許每秒約四次，
-- 且全發生在同步的 server callback 上。過濾後配置量由 MANUAL_DELETE_LIMIT 封頂。
local function indexWanted(ctx, id)
    return ctx.wanted == nil or ctx.wanted[id] == true
end

local function indexNote(ctx, id)
    local wanted = ctx.wanted
    if wanted and wanted[id] and not ctx.found[id] then
        ctx.found[id] = true
        ctx.remaining = ctx.remaining - 1
    end
end

local function indexComplete(ctx)
    return ctx.wanted ~= nil and ctx.remaining <= 0
end

-- 把一個容器（含巢狀袋）裡的物品登錄進索引。先登錄者優先，因此呼叫順序決定優先權
local function indexContainer(ctx, container)
    if not container then
        return
    end
    local items = container:getItems()
    if not items then
        return
    end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local id = item:getID()
            if indexWanted(ctx, id) and ctx.index[id] == nil then
                ctx.index[id] = { item = item, kind = "container", container = item:getContainer() or container }
                indexNote(ctx, id)
            end
            -- 先判完成再遞迴：要找的都到齊時連這件容器的內容都不必展開
            if indexComplete(ctx) then
                return
            end
            -- 巢狀袋。遞迴深度等同 vanilla 的 getItemWithIDRecursiv（ItemContainer.java:3065），
            -- 容器不可能自我包含，故無循環風險
            if instanceof(item, "InventoryContainer") then
                indexContainer(ctx, item:getInventory())
                if indexComplete(ctx) then
                    return
                end
            end
        end
    end
end

local function squareAccessible(square, playerObj, playerSquare)
    if not isServer() then
        return true
    end
    -- 尊重保險屋 loot 權限，避免隔牆刪除他人保險屋容器物品（SafeHouse.java:262-264）
    if not SafeHouse.isSafehouseAllowLoot(square, playerObj) then
        return false
    end
    -- 阻隔檢查：只允許同格/相鄰格（range 已限 1，isBlockedTo 對相鄰邊界可靠；range 2 的中間牆不一定被檢查）。
    -- playerSquare 缺失一律 fail closed（IsoGridSquare.java:837，ISGrabItemAction.lua:16）
    if not playerSquare then
        return false
    end
    if square ~= playerSquare and square:isBlockedTo(playerSquare) then
        return false
    end
    return true
end

local function indexSquare(ctx, square, playerObj, seenVehicles)
    local worldObjects = square:getWorldObjects()
    for i = 0, worldObjects:size() - 1 do
        local worldObj = worldObjects:get(i)
        local item = worldObj and worldObj:getItem()
        if item then
            local id = item:getID()
            if indexWanted(ctx, id) and ctx.index[id] == nil then
                ctx.index[id] = { item = item, kind = "floor", worldObj = worldObj, square = square }
                indexNote(ctx, id)
            end
            -- 同上：先判完成再展開地板袋的內容
            if indexComplete(ctx) then
                return
            end
            if instanceof(item, "InventoryContainer") then
                indexContainer(ctx, item:getInventory())
                if indexComplete(ctx) then
                    return
                end
            end
        end
    end

    local staticObjects = square:getStaticMovingObjects()
    for i = 0, staticObjects:size() - 1 do
        local object = staticObjects:get(i)
        indexContainer(ctx, object:getContainer())
        if indexComplete(ctx) then
            return
        end
    end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for containerIndex = 0, object:getContainerCount() - 1 do
            indexContainer(ctx, object:getContainerByIndex(containerIndex))
            if indexComplete(ctx) then
                return
            end
        end
    end

    local vehicle = square:getVehicleContainer()
    if vehicle and not seenVehicles[vehicle] then
        seenVehicles[vehicle] = true
        for partIndex = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(partIndex)
            if part:getItemContainer() and vehicle:canAccessContainer(partIndex, playerObj) then
                indexContainer(ctx, part:getItemContainer())
                if indexComplete(ctx) then
                    return
                end
            end
        end
    end
end

-- 一次掃描建出「玩家此刻搆得到的所有物品」索引：id → { item, kind, container／worldObj+square }。
-- 舊版是逐一 id 呼叫 findAccessibleItem，每次都重掃 9 格與其中每個容器（且每個容器要走訪兩次，
-- 因為先呼叫 getItemWithID 再呼叫涵蓋它的 getItemWithIDRecursiv）——批量刪 90 件就等於把同一份
-- 掃描做 90 遍，全部擠在 OnClientCommand 的同一次同步回呼裡。改成建一次索引後成本是 O(掃描 + N)。
-- 安全檢查（保險屋／阻隔／載具可存取）改為每格做一次，語意不變。
-- wantedIds（選填）：只需要這些 id 時，全部到齊即可停止掃描，其餘容器連碰都不碰
function Cleaner.buildAccessibleIndex(playerObj, range, wantedIds)
    local ctx = { index = {}, found = {}, wanted = nil, remaining = 0 }
    if not playerObj then
        return ctx.index
    end
    if wantedIds then
        local wanted = {}
        local count = 0
        for _, id in ipairs(wantedIds) do
            if not wanted[id] then
                wanted[id] = true
                count = count + 1
            end
        end
        ctx.wanted = wanted
        ctx.remaining = count
    end

    -- 玩家自己的背包最先登錄：優先權與舊版「先查自己身上」一致，也讓「刪自己背包裡的東西」
    -- 這個最常見的情形在這裡就收工，完全不必碰世界
    indexContainer(ctx, playerObj:getInventory())
    if indexComplete(ctx) then
        return ctx.index
    end

    range = range or 1
    local px = math.floor(playerObj:getX())
    local py = math.floor(playerObj:getY())
    local pz = math.floor(playerObj:getZ())
    local playerSquare = playerObj:getCurrentSquare()
    local seenVehicles = {}
    for y = py - range, py + range do
        for x = px - range, px + range do
            if Cleaner.chebyshevDistance(px, py, x, y) <= range then
                local square = getCell():getGridSquare(x, y, pz)
                if square and squareAccessible(square, playerObj, playerSquare) then
                    indexSquare(ctx, square, playerObj, seenVehicles)
                    if indexComplete(ctx) then
                        return ctx.index
                    end
                end
            end
        end
    end
    return ctx.index
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
