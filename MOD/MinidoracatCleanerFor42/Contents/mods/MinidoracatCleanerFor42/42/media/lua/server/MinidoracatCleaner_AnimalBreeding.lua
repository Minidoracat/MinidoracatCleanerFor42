if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner
local C = Cleaner.CONSTANTS

-- 農場治理：以「一座農場」（一組相連的動物圈地，getAllDZones 的連通元件）為單位，
-- 管圈養動物的兩個獨立門檻。
--
--   清除門檻 MaxZoneAnimalsPerGroup（＋ AnimalZoneLimitOverrides 逐群組覆寫）：
--     現存超過就 remove 多出來的。10 真實秒一輪（AnimalScanIntervalSeconds）——
--     清除的節拍由「移除吞吐量」決定（ANIMALS_PER_ROUND=20 ⇒ 10 秒一輪＝上限 2 隻/秒），
--     且它治的現象在真實時間軸上：已載入動物每 tick 全量更新（IsoPlayer.java:3946-3949
--     硬編碼 FULL；正式服 67 人峰值實測 IsoAnimal.updateLOS 佔主執行緒 41.7%，JavaPatch
--     W18 立案證據），反應延遲要是秒級。
--   繁殖上限 MaxRanchBreedingPerGroup（可逐群組覆寫 RanchBreedingOverrides；覆寫 0＝該群組不抑制）：
--     現存＋未出生超過就取消最新的懷孕／受精蛋，一隻現有牲畜都不動。掛 EveryTenMinutes
--     遊戲事件（GameTime.java:636-650，每遊戲小時 6 次；預設 DayLength 下約 37.5 真實秒）
--     ——抑制的節拍由「生物時鐘」決定：pregnantTime/fertilizedTime 走遊戲時間，孕期最短
--     8 遊戲日、蛋孵化 ~50 遊戲小時，最緊視窗仍有 300 輪以上的餘裕；DayLength 調快時
--     遊戲事件自動跟著收緊，固定真實秒反而在最需要跟上的設定下最鬆。10 真實秒輪詢
--     實測是 99.91% 白算（設計評審 codex lane 的成本模型）。
--
-- 為什麼清除以農場為單位、集中在這裡（設計評審 A2 裁決；A1「scanner 內建 union-find」
-- 每輪約 35 倍成本且要在 Lua 複製引擎連通語意——getZone 是「全域清單第一個命中者勝」
-- （DesignationZoneAnimal.java:316-325），相鄰關係甚至不對稱，union-find 強制對稱是
-- 引擎不保證的語意）：
--   ① 農場是實體：一座可能橫跨兩位玩家的掃描半徑、也可能沒人在附近。vanilla 的受孕
--      本來就以連通圈地為範圍（findFemaleToInseminate 走 getConnectedDZone()，
--      AnimalData.java:1340）。
--   ② **同 tick 走訪＝天然 recount**：每輪對元件重新讀取成員清單（新鮮）、當場計數、
--      當場移除（≤ 共用預算），超額未清完就不推進游標、下一 tick 重走同一元件。
--      完全沒有跨 tick 候選持有——scanner 那套 removalQueue／removed 旗標／unprovable
--      機制在這裡都不需要，也沒有「圈地被玩家瞬間建拆讓佇列過期」的問題。
--   ③ 圈養歸屬來自 zone.animals（引擎維護，addAnimal/removeAnimal），不讀座標——
--      不需要 NaN 座標的 scope 重驗；NaN 只在「能不能安全 remove」時查一次。
--
-- 範圍是「已載入的圈養動物」：zone.animals 只含已載入動物（IsoAnimal.removeFromWorld
-- 在 :1226-1227 呼叫 dZone.removeAnimal）。未載入期間不繁殖（VirtualAnimal 沒有
-- pregnant/fertilized 欄位），但重新載入時 updateStatsAway(hoursAway) 會一次追趕且
-- hoursAway 無上限（AnimalManagerMain.java:103-104）、全在同一個 Java call stack 內，
-- Lua 插不進去——離線爆量只有清除門檻救得了，這是兩個門檻並存的理由。
--
-- 圈地外的雞舍不屬於任何農場（IsoHutch 建立時查 getZoneF，沒圈地就不歸任何圈地，
-- IsoHutch.java:98-101）→ 不受這裡任何門檻約束＝完整保護。那裡也不會受孕（受孕要求
-- 公獸的 connectedDZone 非空，而 checkZone 對圈地外的動物會清空它，IsoAnimal.java:616-619）。
-- 已知殘留：母雞在圈地內受精後走到圈地外雞舍產的蛋，這裡看不到（HutchManager.hutchList
-- 是 private 無 getter，Lua 無法列舉圈地外雞舍）。

-- ===== 節流常數 =====

-- 每 tick 最多走訪幾個圈地元件。走訪成本主要是 1× getAllDZones 遞迴（內部對每個邊界格
-- 做一次 getZone，線性掃全域圈地清單，DesignationZoneAnimal.java:58-110, 316-325）＋
-- 元件內動物/雞舍/地面蛋的線性讀取。這是校準旋鈕
local COMPONENTS_PER_TICK = 4
-- 抑制側：單一 tick 最多改幾個生殖狀態（setter ＋ 地面蛋的 ItemStats 封包）
local MUTATIONS_PER_TICK = 12
-- 清除側的每 tick remove 上限**不在這裡**：與 scanner 共用同一份 tick 預算
-- （C.ANIMALS_PER_TICK，由 scanner 的 OnTick 建立並在呼叫 Cleaner.ranchTick 時傳入）。
-- 三個來源（per-player 散養、全服兜底、農場清除）若各自 3/tick，實際就是 9/tick，
-- 直接推翻 2026-08-23 活鎖事故後的降壓——約束在「每 frame 的 remove 密度」。

-- ===== 狀態 =====

-- 抑制：EveryTenMinutes 設 armed，OnTick 分批消化（跨 tick 游標）
local suppressArmed = false
local suppressCursor = 0
local suppressVisited = {}
-- 清除：每 AnimalScanIntervalSeconds 開一輪，分批消化
local cullCursor = 0
local cullVisited = {}
local lastCullAt = 0
-- 清除的兩段式警告（首輪只警告、下一輪仍超標才動手；emergency 直接動手）。
-- key = "ranch:<元件最小圈地id>|<group>"——圈地 id 是引擎持久的，成員不變則 key 不變；
-- 玩家合併/拆分農場時 key 改變＝警告週期重來，語意正確
local ranchWarned = {}
-- 「超標但一隻都刪不了」的診斷只記一次（edge-triggered）
local protectedOverLogged = {}
-- nestbox 走訪失敗只記一次（getNestBox 系列在原版 Lua 零用例，Kahlua 的 number→
-- HashMap<Integer> key 轉換沒有 vanilla 背書；真的不通就整條 hutch 蛋路徑失效）
local nestboxFailLogged = false

local function getAnimalGroup(animal)
    local definition = AnimalDefinitions.getDef(animal:getAnimalType())
    local group = definition and definition:getGroup()
    if not group or group == "" then
        return nil
    end
    return string.lower(tostring(group))
end

-- 一胎的最大隻數。**必須按上限預留而不是每隻懷孕算 1**：分娩直接建立
-- Rand.Next(minBaby, maxBaby + 1) 隻並逐隻 addBaby()（AnimalData.java:191-202），
-- 而 rat 是 2-10、pig 5-10、mouse 5-9、rabbit 3-7。算 1 的話「判定當下剛好等於上限」
-- 的農場生完就直接暴衝。代價是偏保守，這個方向是對的。
local function litterSize(animal)
    local definition = AnimalDefinitions.getDef(animal:getAnimalType())
    if not definition or not definition.getMaxBaby then
        return 1
    end
    local maxBaby = tonumber(definition:getMaxBaby()) or 1
    if maxBaby < 1 then
        return 1
    end
    return maxBaby
end

-- 蛋 → 群組。用 getAnimalHatch()（Food.java:2378-2380，存的是 animalType）反查 def 的
-- group，而不是 getAnimalHatchBreed()：breed 是品種名，跨 MOD 有撞名風險
local function eggGroup(egg)
    if not egg.getAnimalHatch then
        return nil
    end
    local animalType = egg:getAnimalHatch()
    if not animalType or animalType == "" then
        return nil
    end
    local definition = AnimalDefinitions.getDef(animalType)
    local group = definition and definition:getGroup()
    if not group or group == "" then
        return nil
    end
    return string.lower(tostring(group))
end

-- 把一顆受精蛋改回未受精。
-- **兩個欄位必須成對清零**：checkEggHatch 開頭就 `if (!isFertilized()) return false`
-- （Food.java:264-265）；留著非零的 fertilizedTime 會在 tooltip 顯示殘留孵化進度
-- （Food.java:1532）。地面蛋另外要發 ItemStats：兩個 setter 都只改欄位、不發封包，
-- vanilla 自己變更孵化進度後走 syncItemFieldForWorldItem（Food.java:279）——那是
-- private，Lua 呼不到，對等的公開入口是 sendItemStats（LuaManager.java:4340-4348）。
local function unfertilizeEgg(egg, isOnGround)
    egg:setFertilized(false)
    egg:setFertilizedTime(0)
    if isOnGround and sendItemStats then
        sendItemStats(egg)
    end
end

-- 取消一隻母獸的懷孕／受精。
-- **`fertilizedTime` 一定要一起清零**，這是 Ranch Hand（workshop 3696510155）踩死的
-- 地方：canBePregnant() 對蛋生動物要求 `fertilizedTime == 0 && !fertilized`
-- （AnimalData.java:1309,1313），而 checkFertilizedTime() 只在 fertilized 為真時遞增、
-- 要等 fertilizedTime > fertilizedTimeMax 才把兩者一起清零（:621-630）。只關 boolean
-- 的話計時器永遠停在某個 ≤ max 的值、自癒分支永不觸發，母禽**永久不孕**且跨存檔
-- （IsoAnimal.save/load 會存 fertilizedTime，:1347-1348,1460-1461）。
local function cancelPregnancy(data)
    data:setPregnant(false)
    data:setPregnancyTime(0)
    data:setFertilized(false)
    data:setFertilizedTime(0)
end

-- ===== 一次走訪：整個元件所有群組的計數與候選 =====
--
-- caller 已付過唯一一次 getAllDZones（元件成員清單）；這裡**逐成員讀 per-zone getter**：
-- zone:getAnimals()/getHutchs()/getFoodOnGround()（DesignationZoneAnimal.java:395/:431/:475）。
-- 刻意不用 getAnimalsConnected()/getHutchsConnected()/getFoodOnGroundConnected()——那三個
-- 各自內部再跑一次 getAllDZones 遞迴（:437/:466/:481），一個元件就付 4 次；contains 去重
-- 還是 O(A²)（:444）。改逐成員讀＋Lua seen-set 去重＝1 次遞迴、O(A)。
--
-- **per-zone getter 回的是引擎內部清單的直接參照，只能讀、絕不能改**（getAnimalsConnected
-- 之所以安全 addAll 是因為它回新 ArrayList；這裡沒有那層複製）。
--
-- 雞舍內動物的橋接：getAnimalInside() 回 HashMap（public class，方法可呼叫），但
-- values() 回傳 package-private 的 HashMap$Values——**只能當引數、不能當 receiver**
-- （Kahlua 按 runtime class 暴露方法）。所以先建 ArrayList.new()（vanilla Lua 大量用例，
-- 如 ISItemSlot.lua:414）再 addAll(values())，receiver 都是 public 的 ArrayList。
--
-- 每個群組的 bucket：
--   live       全部現存（含 hutch 內、含保護個體）——繁殖上限的基數：農場人口壓力
--   cullCount  可治理現存（排除保護個體；含 hutch 內的未保護個體）——清除門檻的基數，
--              與散養側「protected 不計入 count」同語意
--   removable  清除候選：只有站在世界上的未保護個體。hutch **內**的不進候選——牠們已被
--              removeFromWorld（IsoAnimal.java:1226-1227），直接 remove 會留下
--              hutch.animalInside 的殘留參照
--   nanSkipped 座標 NaN：不可安全移除（活鎖事故教訓），但仍計入現存數
--   pregnancies/eggs/unborn  抑制側候選與計數（排序鍵：越小＝越晚受孕，優先取消）
local function collectComponent(component)
    local groups = {}
    local function bucketFor(group)
        local bucket = groups[group]
        if not bucket then
            bucket = {
                live = 0,
                cullCount = 0,
                unborn = 0,
                nanSkipped = 0,
                removable = {},
                pregnancies = {},
                eggs = {},
            }
            groups[group] = bucket
        end
        return bucket
    end

    -- 邊界上的圈地可能把同一個 hutch／地面物件登記進兩個成員的清單（zone.check 掃自己
    -- 範圍內的格子，DesignationZoneAnimal.java:222）；動物的 dZone 唯一（setDZone 會先從
    -- 舊圈地移除，IsoAnimal.java:2842-2850）但防禦性一起去重
    local seen = {}

    local function tallyAnimal(animal, insideHutch)
        if not animal or seen[animal] then
            return
        end
        seen[animal] = true
        -- 掛鉤（屠宰架）上的不算農場人口：與 getAnimalsConnected 的過濾一致（:444）
        if animal:isOnHook() then
            return
        end
        local group = getAnimalGroup(animal)
        if not group then
            return
        end
        local bucket = bucketFor(group)
        bucket.live = bucket.live + 1
        if not Cleaner.isProtectedAnimal(animal) then
            bucket.cullCount = bucket.cullCount + 1
            if not insideHutch then
                local ax = animal:getX()
                local ay = animal:getY()
                local az = animal:getZ()
                -- 三軸都要查：只擋 x/y 會漏掉「只有 z 壞掉」的個體
                if ax ~= ax or ay ~= ay or az ~= az then
                    bucket.nanSkipped = bucket.nanSkipped + 1
                else
                    bucket.removable[#bucket.removable + 1] = {
                        animal = animal,
                        baby = animal:isBaby() == true,
                        order = bucket.live,
                    }
                end
            end
        end
        local data = animal:getData()
        if data and data:isPregnant() then
            local size = litterSize(animal)
            bucket.unborn = bucket.unborn + size
            bucket.pregnancies[#bucket.pregnancies + 1] = {
                data = data,
                size = size,
                -- 懷孕越久＝越接近分娩，保留它、先取消剛懷上的
                order = tonumber(data:getPregnancyTime()) or 0,
            }
        end
    end

    local function tallyEgg(egg, isOnGround)
        if not egg or seen[egg] then
            return
        end
        seen[egg] = true
        -- 先問「方法存在嗎」：Kahlua 對 Java 物件缺 key 回 nil 不拋例外
        if not egg.isFertilized or not egg:isFertilized() then
            return
        end
        local group = eggGroup(egg)
        if not group then
            return
        end
        local bucket = bucketFor(group)
        bucket.unborn = bucket.unborn + 1
        bucket.eggs[#bucket.eggs + 1] = {
            egg = egg,
            ground = isOnGround,
            order = tonumber(egg:getFertilizedTime()) or 0,
        }
    end

    for m = 0, component:size() - 1 do
        local member = component:get(m)
        if member then
            local animals = member:getAnimals()
            if animals then
                for i = 0, animals:size() - 1 do
                    tallyAnimal(animals:get(i), false)
                end
            end

            local hutches = member:getHutchs()
            if hutches then
                for i = 0, hutches:size() - 1 do
                    local hutch = hutches:get(i)
                    if hutch and not seen[hutch] then
                        seen[hutch] = true
                        -- 雞舍內動物：live/cullCount 計入（是農場人口），不進 removable
                        local inside = hutch:getAnimalInside()
                        if inside and inside:size() > 0 then
                            local bridge = ArrayList.new()
                            bridge:addAll(inside:values())
                            for j = 0, bridge:size() - 1 do
                                tallyAnimal(bridge:get(j), true)
                            end
                        end
                        -- 巢箱蛋。原版 Lua 對 getNestBox/getEggsNb/getEgg 零用例
                        -- （Ranch Hand 首創），整段 pcall：不通就只少涵蓋 hutch 蛋。
                        -- 索引跑 0..getMaxNestBox() **含**上界（vanilla 初始化
                        -- maxNestBox+1 個，IsoHutch.java:117-119）
                        local ok = pcall(function()
                            local maxNest = hutch:getMaxNestBox()
                            for j = 0, maxNest do
                                local nest = hutch:getNestBox(j)
                                if nest then
                                    local eggCount = nest:getEggsNb()
                                    for k = 0, eggCount - 1 do
                                        tallyEgg(nest:getEgg(k), false)
                                    end
                                end
                            end
                        end)
                        if not ok and not nestboxFailLogged then
                            nestboxFailLogged = true
                            Cleaner.log("animal_nestbox_unreadable", "system",
                                member:getX(), member:getY(), member:getZ(),
                                "hutch_eggs_skipped")
                        end
                    end
                end
            end

            -- 圈地地面上的受精蛋。背包／容器／動物拖車裡的蛋照樣會孵化
            -- （Food.checkEggHatch，Food.java:282-300）但不屬於任何圈地——刻意不涵蓋
            local ground = member:getFoodOnGround()
            if ground then
                for i = 0, ground:size() - 1 do
                    local worldObj = ground:get(i)
                    if worldObj and not seen[worldObj] then
                        seen[worldObj] = true
                        tallyEgg(worldObj:getItem(), true)
                    end
                end
            end
        end
    end

    return groups
end

-- 元件的穩定識別：成員圈地的最小 id（引擎持久；游標序跨輪不穩定，不能當 warned key）
local function componentKey(component, fallbackZone)
    local minId = nil
    if component then
        for i = 0, component:size() - 1 do
            local member = component:get(i)
            local id = member and member:getId()
            if id ~= nil and (minId == nil or id < minId) then
                minId = id
            end
        end
    end
    if minId == nil and fallbackZone then
        minId = fallbackZone:getId()
    end
    return tostring(minId or "?")
end

-- ===== 抑制（繁殖上限）=====

local function suppressGroup(instance, group, bucket, limit, budget)
    local overage = (bucket.live + bucket.unborn) - limit
    if overage <= 0 then
        return 0
    end

    -- 一律 sortSafe（Kahlua 的 table.sort 是遞迴 quicksort，接近排序的輸入會 stack overflow）
    Cleaner.sortSafe(bucket.eggs, function(a, b) return a.order < b.order end)
    Cleaner.sortSafe(bucket.pregnancies, function(a, b) return a.order < b.order end)

    local used = 0
    local cancelledEggs = 0
    local cancelledPregnancies = 0

    -- 先取消蛋：一顆蛋只抵 1 隻，粒度比懷孕細（懷孕要整胎取消），能更精準地收到上限
    for _, entry in ipairs(bucket.eggs) do
        if overage <= 0 or used >= budget then
            break
        end
        unfertilizeEgg(entry.egg, entry.ground)
        overage = overage - 1
        cancelledEggs = cancelledEggs + 1
        used = used + 1
    end

    for _, entry in ipairs(bucket.pregnancies) do
        if overage <= 0 or used >= budget then
            break
        end
        cancelPregnancy(entry.data)
        overage = overage - entry.size
        cancelledPregnancies = cancelledPregnancies + 1
        used = used + 1
    end

    if used > 0 then
        Cleaner.log(
            "animal_breed_suppress",
            "system",
            instance:getX(),
            instance:getY(),
            instance:getZ(),
            "group=" .. Cleaner.sanitize(group)
                .. " live=" .. bucket.live
                .. " unborn=" .. bucket.unborn
                .. " limit=" .. limit
                .. " eggs=" .. cancelledEggs
                .. " pregnancies=" .. cancelledPregnancies
        )
    end
    return used
end

local function finishSuppressRound()
    suppressArmed = false
    suppressCursor = 0
    suppressVisited = {}
end

-- 抑制掃一步（一個 tick 的份）
local function stepSuppression(allowedGroups, zones, breedingLimit, breedingOverrides)
    local total = zones:size()
    local components = 0
    local budget = MUTATIONS_PER_TICK

    while suppressCursor < total and components < COMPONENTS_PER_TICK do
        local zone = zones:get(suppressCursor)
        suppressCursor = suppressCursor + 1
        local id = zone and zone:getId()
        if id and not suppressVisited[id] then
            local component = DesignationZoneAnimal.getAllDZones(nil, zone, nil)
            if component then
                for i = 0, component:size() - 1 do
                    local member = component:get(i)
                    if member then
                        suppressVisited[member:getId()] = true
                    end
                end

                components = components + 1
                -- 群組來源是元件內實際存在的動物與蛋（`*` 模式下 allowedGroups 只有
                -- sentinel、沒有群組 key）；白名單用在過濾側
                for group, bucket in pairs(collectComponent(component)) do
                    if budget <= 0 then
                        break
                    end
                    if allowedGroups._allowAll or allowedGroups[group] == true then
                        -- 逐群組覆寫優先於共用預設；覆寫 0＝該群組不抑制（與清除側
                        -- 「覆寫 0＝永不刪除」同一套 0 語意）
                        local limit = breedingOverrides[group] or breedingLimit
                        if limit > 0 then
                            budget = budget - suppressGroup(zone, group, bucket, limit, budget)
                        end
                    end
                end
            end
        end
    end

    if suppressCursor >= total then
        finishSuppressRound()
    end
end

-- ===== 清除（農場清除門檻）=====

local function cullSort(a, b)
    -- 幼體優先（損失最小），再按走訪序（穩定）
    if a.baby ~= b.baby then
        return a.baby
    end
    return a.order < b.order
end

-- 本輪實際評估過的 key。一輪走完時，不在集合裡的警告/診斷記錄一律回收——群組整組消失
-- 或上限被改成 0 時，殘留記錄會讓農場之後重新住滿時**跳過警告直接清理**
-- （「恢復同 key 不可沿用過期記錄」，scanner 的 warned 生命週期同一條規則）
local cullSeenKeys = {}

local function finishCullRound()
    cullCursor = 0
    cullVisited = {}
    local stale = {}
    for key in pairs(ranchWarned) do
        if not cullSeenKeys[key] then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        ranchWarned[key] = nil
    end
    stale = {}
    for key in pairs(protectedOverLogged) do
        if not cullSeenKeys[key] then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        protectedOverLogged[key] = nil
    end
    cullSeenKeys = {}
end

-- 兩段式警告：首輪只廣播給農場錨點附近的玩家（農場可能離所有人很遠，沒人在附近就只留
-- log），下一輪仍超標才動手；emergency（超過 2 倍）直接動手
local function warnRanch(key, instance, group, count, limit)
    if ranchWarned[key] then
        return true
    end
    ranchWarned[key] = true
    Cleaner.warnNearby("animals", instance:getX(), instance:getY(), instance:getZ(),
        group, "zone", count, limit)
    Cleaner.log(
        "warn",
        "system",
        instance:getX(),
        instance:getY(),
        instance:getZ(),
        "kind=animals group=" .. Cleaner.sanitize(group) .. " scope=zone"
            .. " count=" .. tostring(count) .. " limit=" .. tostring(limit)
    )
    return false
end

-- 清除一個群組。回傳 (本 tick 用掉的 remove 次數, 是否還有超額且還有候選)
local function cullGroup(instance, key, group, bucket, limit, budget)
    local excess = bucket.cullCount - limit
    if excess <= 0 then
        ranchWarned[key] = nil
        protectedOverLogged[key] = nil
        return 0, false
    end

    local emergency = bucket.cullCount > C.ANIMAL_EMERGENCY_MULTIPLIER * limit
    if not emergency and not warnRanch(key, instance, group, bucket.cullCount, limit) then
        return 0, false
    end

    Cleaner.sortSafe(bucket.removable, cullSort)

    local removed = 0
    local index = 1
    while excess > 0 and removed < budget and index <= #bucket.removable do
        -- IsoAnimal.java:3383-3405；server 端 remove 自動 MP 同步
        bucket.removable[index].animal:remove()
        removed = removed + 1
        excess = excess - 1
        index = index + 1
    end

    if bucket.nanSkipped > 0 then
        Cleaner.log("animal_nan", "system",
            instance:getX(), instance:getY(), instance:getZ(),
            "group=" .. Cleaner.sanitize(group) .. " skipped=" .. bucket.nanSkipped)
    end

    if removed > 0 then
        Cleaner.log(
            "animal_clean",
            "system",
            instance:getX(),
            instance:getY(),
            instance:getZ(),
            "group=" .. Cleaner.sanitize(group)
                .. " removed=" .. removed
                .. " wild=0"
                .. " zoned=" .. removed
                .. " scope=zone"
        )
        Cleaner.notifyCleaned("animals", group, removed,
            instance:getX(), instance:getY(), instance:getZ(), "zone", bucket.live - removed)
    elseif excess > 0 then
        -- 超標但一隻都刪不了（全是保護個體／NaN／hutch 內）。edge-triggered 記一次
        if not protectedOverLogged[key] then
            protectedOverLogged[key] = true
            Cleaner.log(
                "animal_protected_over",
                "system",
                instance:getX(),
                instance:getY(),
                instance:getZ(),
                "group=" .. Cleaner.sanitize(group)
                    .. " count=0 zoneCount=" .. bucket.cullCount
                    .. " protected=" .. (bucket.live - bucket.cullCount)
            )
        end
    end

    local unfinished = excess > 0 and index <= #bucket.removable
    return removed, unfinished
end

-- 清除掃一步。budget 是**跨模組共用**的 tick 移除預算（scanner 建立、先扣自己的，
-- 剩餘傳進來；見檔頭節流常數說明）
local function stepCull(allowedGroups, zones, zoneLimit, zoneOverrides, budget)
    local total = zones:size()
    local components = 0

    while cullCursor < total and components < COMPONENTS_PER_TICK do
        local zone = zones:get(cullCursor)
        local id = zone and zone:getId()
        if id == nil or cullVisited[id] then
            cullCursor = cullCursor + 1
        else
            local component = DesignationZoneAnimal.getAllDZones(nil, zone, nil)
            if not component or component:size() == 0 then
                cullVisited[id] = true
                cullCursor = cullCursor + 1
            else
                local compKey = componentKey(component, zone)
                components = components + 1

                local anyUnfinished = false
                for group, bucket in pairs(collectComponent(component)) do
                    if allowedGroups._allowAll or allowedGroups[group] == true then
                        local limit = zoneOverrides[group]
                        if limit == nil then
                            limit = zoneLimit
                        end
                        -- limit 0 ＝ 該群組農場不清除
                        if limit > 0 then
                            local key = "ranch:" .. compKey .. "|" .. group
                            cullSeenKeys[key] = true
                            local removed, unfinished =
                                cullGroup(zone, key, group, bucket, limit, budget.removals)
                            budget.removals = budget.removals - removed
                            if unfinished then
                                anyUnfinished = true
                            end
                        end
                    end
                end

                if anyUnfinished and budget.removals <= 0 then
                    -- 還有超額且是預算用盡造成的：**不推進游標、不標 visited**，下一 tick
                    -- 從同一個元件重新讀取＋計數（天然 recount，不持有任何跨 tick 候選）。
                    -- unfinished 但預算還有（＝候選用盡，全是保護個體）則照常推進，
                    -- 不能卡在這裡空轉
                    return
                end
                for i = 0, component:size() - 1 do
                    local member = component:get(i)
                    if member then
                        cullVisited[member:getId()] = true
                    end
                end
                cullCursor = cullCursor + 1
            end
        end
        if budget.removals <= 0 and cullCursor < total then
            -- 本 tick 的移除預算用完，走訪也先停（下一 tick 續走）；計數型走訪本身
            -- 不受移除預算限制，但沒有預算時繼續走只會累積「確認超標卻動不了手」
            return
        end
    end

    if cullCursor >= total then
        finishCullRound()
    end
end

-- ===== 驅動 =====

local function hasCullLimit(zoneLimit, zoneOverrides)
    if zoneLimit > 0 then
        return true
    end
    for _, value in pairs(zoneOverrides) do
        if value > 0 then return true end
    end
    return false
end

local function onEveryTenMinutes()
    if Cleaner.getOption("AnimalCleanupEnabled") == false then
        return
    end
    -- 共用預設或任一逐群組覆寫 > 0 都要武裝（hasCullLimit 的判準與上限來源無關）
    local breedingLimit = tonumber(Cleaner.getOption("MaxRanchBreedingPerGroup")) or 0
    if hasCullLimit(breedingLimit, Cleaner.getRanchBreedingOverrides()) then
        suppressArmed = true
    end
end

-- 農場治理的 tick 入口。**由 AnimalScanner 的 OnTick 呼叫**（動物子系統單一進入點），
-- budget.removals 是兩個模組共用的本 tick 移除預算。不自註 OnTick：兩個 Events.OnTick.Add
-- 的執行順序取決於檔案載入順序（字母序），共用預算不能建立在這種隱性依賴上
function Cleaner.ranchTick(budget)
    if Cleaner.getOption("AnimalCleanupEnabled") == false then
        finishSuppressRound()
        finishCullRound()
        ranchWarned = {}
        protectedOverLogged = {}
        return
    end

    local zones = DesignationZoneAnimal.getAllZones()
    if not zones or zones:size() == 0 then
        finishSuppressRound()
        finishCullRound()
        return
    end

    local allowedGroups = nil

    -- 清除時鐘：AnimalScanIntervalSeconds（預設 10 真實秒）開一輪，游標未走完則每 tick 續走
    local zoneLimit = tonumber(Cleaner.getOption("MaxZoneAnimalsPerGroup")) or 0
    local zoneOverrides = Cleaner.getAnimalZoneLimitOverrides()
    if hasCullLimit(zoneLimit, zoneOverrides) then
        local now = getTimestampMs()
        local interval = (tonumber(Cleaner.getOption("AnimalScanIntervalSeconds"))
            or Cleaner.DEFAULTS.AnimalScanIntervalSeconds) * 1000
        if cullCursor ~= 0 or now - lastCullAt >= interval then
            if cullCursor == 0 then
                lastCullAt = now
            end
            allowedGroups = Cleaner.getAnimalGroupSet()
            stepCull(allowedGroups, zones, zoneLimit, zoneOverrides, budget)
        end
    else
        finishCullRound()
        ranchWarned = {}
        protectedOverLogged = {}
    end

    -- 抑制時鐘：EveryTenMinutes 設 armed，這裡分批消化
    if suppressArmed or suppressCursor ~= 0 then
        local breedingLimit = tonumber(Cleaner.getOption("MaxRanchBreedingPerGroup")) or 0
        local breedingOverrides = Cleaner.getRanchBreedingOverrides()
        if not hasCullLimit(breedingLimit, breedingOverrides) then
            finishSuppressRound()
        else
            if suppressCursor == 0 then
                -- 開始消化：armed 落地成游標走訪
                suppressArmed = false
            end
            allowedGroups = allowedGroups or Cleaner.getAnimalGroupSet()
            stepSuppression(allowedGroups, zones, breedingLimit, breedingOverrides)
        end
    end
end

Events.EveryTenMinutes.Add(onEveryTenMinutes)
