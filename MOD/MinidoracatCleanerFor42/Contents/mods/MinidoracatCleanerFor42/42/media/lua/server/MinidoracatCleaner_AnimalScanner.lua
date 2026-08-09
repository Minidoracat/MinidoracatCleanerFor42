if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner
local C = Cleaner.CONSTANTS
local warned = {}
local lastScanAt = 0

local function hasCustomName(animal)
    local name = animal:getCustomName()
    return name ~= nil and tostring(name):match("^%s*(.-)%s*$") ~= ""
end

local function snapshotAnimals(list)
    local result = {}
    if not list then
        return result
    end
    -- IsoCell.getAnimals 每輪建新 LinkedList（IsoCell.java:4565），get(i) 為 O(n) 線性尋址→整輪 O(n²)；
    -- 改用 iterator 單趟 O(n)；若 Kahlua 不支援 Java Iterator 方法則退回索引法（不比原本更差）
    local ok = pcall(function()
        local iter = list:iterator()
        while iter:hasNext() do
            result[#result + 1] = iter:next()
        end
    end)
    if not ok then
        result = {}
        for i = 0, list:size() - 1 do
            result[#result + 1] = list:get(i)
        end
    end
    return result
end

local function buildZoneCache()
    local zones = {}
    -- 精確矩形邊界（DesignationZoneAnimal.getAllZones:312；DesignationZone.getX/Y/Z/W/H:243-259）
    local all = DesignationZoneAnimal.getAllZones()
    if all then
        for i = 0, all:size() - 1 do
            local zone = all:get(i)
            zones[#zones + 1] = {
                x = zone:getX(),
                y = zone:getY(),
                z = zone:getZ(),
                w = zone:getW(),
                h = zone:getH(),
            }
        end
    end
    return zones
end

local function isNearAnimalZone(animal, zoneCache)
    if animal:getDZone() ~= nil then
        return true
    end
    local ax = animal:getX()
    local ay = animal:getY()
    local az = math.floor(animal:getZ())
    local buf = C.ZONE_BUFFER
    -- 對每個 zone 擴張 buf 格的矩形做精確判定；九點抽樣（-2,0,2）會漏掉如相對 (1,1) 的對角格
    for _, zone in ipairs(zoneCache) do
        if zone.z == az
            and ax >= zone.x - buf and ax < zone.x + zone.w + buf
            and ay >= zone.y - buf and ay < zone.y + zone.h + buf then
            return true
        end
    end
    return false
end

-- 三態分類：protected＝絕對保護（命名/掛鉤/牽抱/持有/載具/死亡）；zone＝圈養（圈地±2格或屬雞舍）；stray＝散養
local function classifyAnimal(animal, zoneCache)
    if not animal or animal:isDead() or animal:getSquare() == nil then
        return "protected"
    end
    if hasCustomName(animal) or animal:isOnHook() then
        return "protected"
    end
    local data = animal:getData()
    if data and data:getAttachedPlayer() ~= nil then
        return "protected"
    end
    -- IsoAnimal.java:2884-2886; IsoGameCharacter.java:11139-11141
    if animal:isHeld() or animal:getVehicle() ~= nil then
        return "protected"
    end
    if isNearAnimalZone(animal, zoneCache) or animal:getHutch() ~= nil then
        return "zone"
    end
    return "stray"
end

local function nearestPlayer(animal, players, radius)
    local nearest = nil
    local nearestDistance = nil
    for _, playerObj in ipairs(players) do
        local distance = Cleaner.chebyshevDistance(animal:getX(), animal:getY(), playerObj:getX(), playerObj:getY())
        if distance <= radius and (nearestDistance == nil or distance < nearestDistance) then
            nearest = playerObj
            nearestDistance = distance
        end
    end
    return nearest
end

local function playerKey(playerObj)
    return tostring(playerObj:getOnlineID()) .. ":" .. Cleaner.sanitize(playerObj:getUsername())
end

local function getAnimalGroup(animal)
    local definition = AnimalDefinitions.getDef(animal:getAnimalType())
    local group = definition and definition:getGroup()
    if not group or group == "" then
        return nil
    end
    return string.lower(tostring(group))
end

local function warnBucket(bucket, now, scope, count, limit)
    local first = warned[bucket.key]
    if not first then
        warned[bucket.key] = now
        -- 定向送給這個 bucket 所屬的玩家。bucket.x/y/z 是「該群第一隻動物」的位置，可能離
        -- 該玩家最遠到 AnimalScanRadius（預設 64）——遠超警告廣播半徑 30，
        -- 用廣播的話當事人反而收不到自己那則，動物卻照樣被清
        Cleaner.warnPlayerOnly(bucket.playerObj, "animals", bucket.group, count, limit, scope)
        Cleaner.log(
            "warn",
            "system",
            bucket.x,
            bucket.y,
            bucket.z,
            "kind=animals group=" .. Cleaner.sanitize(bucket.group) .. " scope=" .. Cleaner.sanitize(scope)
                .. " count=" .. tostring(count) .. " limit=" .. tostring(limit)
        )
        return false
    end
    local interval = (tonumber(Cleaner.getOption("AnimalScanIntervalSeconds")) or Cleaner.DEFAULTS.AnimalScanIntervalSeconds) * 1000
    return now - first >= interval
end

local function candidateSort(a, b)
    if a.wild ~= b.wild then
        return a.wild
    end
    if a.baby ~= b.baby then
        return a.baby
    end
    return a.order < b.order
end

local function hasAnyAnimalLimit(defaultLimit, zoneLimit, overrides, zoneOverrides)
    if defaultLimit > 0 or zoneLimit > 0 then
        return true
    end
    for _, value in pairs(overrides) do
        if value > 0 then return true end
    end
    for _, value in pairs(zoneOverrides) do
        if value > 0 then return true end
    end
    return false
end

local function runAnimalScan(now)
    local defaultLimit = tonumber(Cleaner.getOption("MaxAnimalsPerGroup")) or Cleaner.DEFAULTS.MaxAnimalsPerGroup
    -- 圈養獨立上限：0＝不清理圈養（完整保護，預設）
    local zoneLimit = tonumber(Cleaner.getOption("MaxZoneAnimalsPerGroup")) or 0
    local overrides = Cleaner.getAnimalLimitOverrides()
    local zoneOverrides = Cleaner.getAnimalZoneLimitOverrides()
    -- 散養、圈養與逐群組覆寫是各自獨立的上限；只檢查 MaxAnimalsPerGroup 會讓
    -- 「散養 0 ＋ 圈養 80」或「散養 0 ＋ rat=20 覆寫」這類設定意外整個停擺
    if not hasAnyAnimalLimit(defaultLimit, zoneLimit, overrides, zoneOverrides) then
        warned = {}
        return
    end

    local players = Cleaner.getActivePlayers()
    if #players == 0 then
        return
    end

    local radius = tonumber(Cleaner.getOption("AnimalScanRadius")) or Cleaner.DEFAULTS.AnimalScanRadius
    local allowedGroups = Cleaner.getAnimalGroupSet()
    local zoneCache = buildZoneCache()
    local buckets = {}
    local animalsByKey = {}

    -- IsoCell.java:4565-4575；每輪讀一次，snapshot 成 Lua array 避免 LinkedList get(i) 的 O(n²)
    local animals = snapshotAnimals(getCell():getAnimals())
    for index = 1, #animals do
        local animal = animals[index]
        if animal then
            -- The single source list already assigns each animal once to its nearest player.
            local onlineID = animal:getOnlineID()
            local keyID = tostring(onlineID) .. ":" .. tostring(animal:getAnimalID()) .. ":" .. tostring(index)
            animalsByKey[keyID] = animal
            local group = getAnimalGroup(animal)
            if group and allowedGroups[group] then
                local nearest = nearestPlayer(animal, players, radius)
                if nearest then
                    local key = playerKey(nearest) .. "|" .. group
                    local bucket = buckets[key]
                    if not bucket then
                        bucket = {
                            key = key,
                            group = group,
                            playerObj = nearest,
                            count = 0,
                            zoneCount = 0,
                            protected = 0,
                            candidates = {},
                            zoneCandidates = {},
                            x = animal:getX(),
                            y = animal:getY(),
                            z = animal:getZ(),
                        }
                        buckets[key] = bucket
                    end
                    -- 散養與圈養分開計數、各有上限；圈養上限支援逐群組覆寫，0 時該群組圈養視同絕對保護
                    local class = classifyAnimal(animal, zoneCache)
                    if class == "zone" then
                        local effZoneLimit = zoneOverrides[group]
                        if effZoneLimit == nil then
                            effZoneLimit = zoneLimit
                        end
                        if effZoneLimit == 0 then
                            class = "protected"
                        end
                    end
                    if class == "protected" then
                        bucket.protected = bucket.protected + 1
                    else
                        local candidate = {
                            key = keyID,
                            onlineID = onlineID,
                            animalID = animal:getAnimalID(),
                            order = index,
                            x = animal:getX(),
                            y = animal:getY(),
                            z = animal:getZ(),
                            wild = animal:isWild() == true,
                            baby = animal:isBaby() == true,
                        }
                        if class == "zone" then
                            bucket.zoneCount = bucket.zoneCount + 1
                            bucket.zoneCandidates[#bucket.zoneCandidates + 1] = candidate
                        else
                            bucket.count = bucket.count + 1
                            bucket.candidates[#bucket.candidates + 1] = candidate
                        end
                    end
                end
            end
        end
    end

    local orderedBuckets = {}
    for _, bucket in pairs(buckets) do
        orderedBuckets[#orderedBuckets + 1] = bucket
    end
    -- 一律用 sortSafe，全庫零 table.sort（Kahlua 的 table.sort 是遞迴 quicksort，
    -- 對已接近排序的輸入會退化成 O(n) 遞迴深度而 stack overflow，見 Core.sortSafe）
    Cleaner.sortSafe(orderedBuckets, function(a, b) return a.key < b.key end)

    local remainingBudget = C.ANIMALS_PER_ROUND
    for _, bucket in ipairs(orderedBuckets) do
        local limit = overrides[bucket.group]
        if limit == nil then
            limit = defaultLimit
        end
        local bucketZoneLimit = zoneOverrides[bucket.group]
        if bucketZoneLimit == nil then
            bucketZoneLimit = zoneLimit
        end
        -- limit 為 0 ＝ 該群組散養不清理（與圈養同語意）。少了這道 > 0 檢查，
        -- 「散養 0 ＋ 圈養 80」的設定會變成 count > 0 恆為真，把散養全數清光
        local strayOver = limit > 0 and bucket.count > limit
        local zoneOver = bucketZoneLimit > 0 and bucket.zoneCount > bucketZoneLimit
        if not strayOver and not zoneOver then
            warned[bucket.key] = nil
        else
            -- 緊急加速只對「真的超標的那一側」成立，否則 limit=0 時會恆為真
            local emergency = (strayOver and bucket.count > C.ANIMAL_EMERGENCY_MULTIPLIER * limit)
                or (zoneOver and bucket.zoneCount > C.ANIMAL_EMERGENCY_MULTIPLIER * bucketZoneLimit)
            -- 觸發來源：stray（散養）／zone（圈養：圈地/雞舍）／both（同時）——警告措辭與 log 據此區分
            local scope = (strayOver and zoneOver) and "both" or (zoneOver and "zone" or "stray")
            -- 顯示觸發那一側的數字：純圈養超標就報圈養數，其餘（含 both）報散養數
            local warnCount = (scope == "zone") and bucket.zoneCount or bucket.count
            local warnLimit = (scope == "zone") and bucketZoneLimit or limit
            local confirmed = emergency or warnBucket(bucket, now, scope, warnCount, warnLimit)
            if confirmed and remainingBudget > 0 then
                -- 散養超額先清，圈養超額其次；兩邊各自刪到剩各自的上限
                local plans = {}
                if strayOver then
                    plans[#plans + 1] = { list = bucket.candidates, excess = bucket.count - limit, zone = false }
                end
                if zoneOver then
                    plans[#plans + 1] = { list = bucket.zoneCandidates, excess = bucket.zoneCount - bucketZoneLimit, zone = true }
                end
                local removed = 0
                local wildRemoved = 0
                local zonedRemoved = 0
                for _, plan in ipairs(plans) do
                    Cleaner.sortSafe(plan.list, candidateSort)
                    local planRemoved = 0
                    for _, candidate in ipairs(plan.list) do
                        if planRemoved >= plan.excess or remainingBudget <= 0 then
                            break
                        end
                        local animal = animalsByKey[candidate.key]
                        -- 刪除前重驗：仍存在、同群組、分類未變（散養/圈養各自對應，中途變保護即跳過）
                        if animal and getAnimalGroup(animal) == bucket.group then
                            local class = classifyAnimal(animal, zoneCache)
                            local expected = plan.zone and "zone" or "stray"
                            if class == expected then
                                local wasWild = animal:isWild() == true
                                -- IsoAnimal.java:3383-3405
                                animal:remove()
                                removed = removed + 1
                                planRemoved = planRemoved + 1
                                remainingBudget = remainingBudget - 1
                                if wasWild then
                                    wildRemoved = wildRemoved + 1
                                end
                                if plan.zone then
                                    zonedRemoved = zonedRemoved + 1
                                end
                            end
                        end
                    end
                end
                if removed > 0 then
                    local cleanedScope = (zonedRemoved == removed) and "zone"
                        or (zonedRemoved == 0 and "stray" or "both")
                    Cleaner.log(
                        "animal_clean",
                        "system",
                        bucket.x,
                        bucket.y,
                        bucket.z,
                        "group=" .. Cleaner.sanitize(bucket.group)
                            .. " removed=" .. removed
                            .. " wild=" .. wildRemoved
                            .. " zoned=" .. zonedRemoved
                            .. " scope=" .. cleanedScope
                    )
                    local remaining = (bucket.count - (removed - zonedRemoved)) + (bucket.zoneCount - zonedRemoved)
                    -- 與警告同理：定向送給 bucket 所屬玩家，而不是以動物群位置為圓心廣播
                    Cleaner.notifyCleanedPlayerOnly(bucket.playerObj, "animals", bucket.group, removed, cleanedScope, remaining)
                else
                    -- 候選在重驗時全數失效（極少見的競態）：留一行診斷
                    Cleaner.log(
                        "animal_protected_over",
                        "system",
                        bucket.x,
                        bucket.y,
                        bucket.z,
                        "group=" .. Cleaner.sanitize(bucket.group)
                            .. " count=" .. bucket.count
                            .. " zoneCount=" .. bucket.zoneCount
                            .. " protected=" .. bucket.protected
                    )
                end
            end
        end
    end

    local stale = {}
    for key in pairs(warned) do
        if not buckets[key] then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        warned[key] = nil
    end
end

local function onTick()
    local now = getTimestampMs()
    local interval = (tonumber(Cleaner.getOption("AnimalScanIntervalSeconds")) or Cleaner.DEFAULTS.AnimalScanIntervalSeconds) * 1000
    if now - lastScanAt < interval then
        return
    end
    lastScanAt = now
    runAnimalScan(now)
end

Events.OnTick.Add(onTick)
