if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner
local C = Cleaner.CONSTANTS
local warned = {}
-- 「同一 bucket 的 recount 無法在單 tick 證明」只記首次；持續 > visit budget 時每輪重寫
-- 會形成無界診斷洪水，而同一 ZLogger 超過 10MB 會截斷原檔。bucket 恢復可證明或消失後解除，
-- 下次再超過才重新記
local unprovableWarned = {}
local lastScanAt = 0
-- 待移除佇列（**只涵蓋散養**：per-player 熱點與全服兜底。圈養的清除與繁殖由
-- AnimalBreeding 以每座農場為單位治理）。runAnimalScan 只產生「每個 bucket 的完整
-- 移除計畫」，實際 remove 由 processRemovals 跨 tick 消化，每 tick 的 remove 上限是
-- **與農場治理共用**的 budget.removals（C.ANIMALS_PER_TICK；見 onTick）。佇列未排空前
-- 不開新一輪掃描，所以每輪總額度仍是 ANIMALS_PER_ROUND。
local removalQueue = {}
local removalHead = 1
local removalBudget = 0

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

-- 三態分類：protected＝絕對保護（Cleaner.isProtectedAnimal，與農場治理共用同一份判定）；
-- zone＝圈養（圈地±2格或屬雞舍）；stray＝散養。
-- **本模組只治理 stray**：zone 動物的清除與繁殖上限由 AnimalBreeding 以「每座農場」
-- 為單位治理（設計評審 A2 裁決），這裡看到 zone 一律跳過、只留診斷計數。
-- 分類仍保留 ±2 buffer 與雞舍判定：站在農場圍欄邊緣（buffer 內）或屬於圈地外雞舍的
-- 動物，農場治理算不到牠們（不在 getAnimalsConnected 裡），但也**不可**因此掉進散養桶
-- 被 MaxAnimalsPerGroup 清掉——寬鬆的 zone 判定就是牠們的保護
local function classifyAnimal(animal, zoneCache)
    if Cleaner.isProtectedAnimal(animal) then
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

-- 兩個維度各自獨立：per-player 散養、全服散養。任一為正就仍需掃描。
-- （圈養門檻屬於 AnimalBreeding 的農場治理，不在本模組的停擺判定裡）
local function hasAnyAnimalLimit(defaultLimit, globalLimit, overrides, globalOverrides)
    if defaultLimit > 0 or globalLimit > 0 then
        return true
    end
    for _, value in pairs(overrides) do
        if value > 0 then return true end
    end
    for _, value in pairs(globalOverrides) do
        if value > 0 then return true end
    end
    return false
end

-- bucket 所屬玩家可能在佇列消化期間斷線。job 跨 tick 持有 playerObj，flush 時先確認他
-- 還在線，否則定向通知是對已離線的 IsoPlayer 呼叫
local function isStillOnline(playerObj)
    if not playerObj then
        return false
    end
    for _, candidate in ipairs(Cleaner.getActivePlayers()) do
        if candidate == playerObj then
            return true
        end
    end
    return false
end

-- 一個計畫做完時把統計落盤。log 行數與舊版逐 bucket 聚合一致：跨 tick 消化只改變
-- 「什麼時候刪」，不改變輸出形狀。
-- `untried` ＝這個 job 根本沒被嘗試（本輪總額度用盡，或停用轉場時還沒輪到）。舊版的
-- 額度守門在 bucket 進入點，那些 bucket 不寫任何 log；新版改成先排入佇列，所以要在這裡
-- 還原同樣的語意——否則會寫出假的 animal_protected_over（該事件的語意是「候選重驗全數
-- 失效」，把「額度用完」記成那樣會讓排障往保護判定的方向找）
local function flushRemoval(job, untried)
    if job.nanSkipped > 0 then
        -- 座標 NaN 的動物本輪不清，留一行給 server 端 Java patch 的
        -- [MinidoracatJavaPatch][AnimalSort] nanAnimals 診斷對照。座標欄位用 bucket
        -- （＝玩家附近）而不是動物自己的 NaN，否則這行連定位都做不到
        Cleaner.log(
            "animal_nan",
            "system",
            job.x,
            job.y,
            job.z,
            "group=" .. Cleaner.sanitize(job.group) .. " skipped=" .. job.nanSkipped
        )
    end
    if job.unprovable > 0 then
        -- 單一 plan 的候選數超過每 tick 走訪額度，無法在同一個 tick 得到一致 recount。
        -- 只記「進入 unprovable 狀態」的首次；持續同狀態不每輪重寫，避免截斷共用稽核 log
        if not unprovableWarned[job.key] then
            unprovableWarned[job.key] = true
            Cleaner.log(
                "animal_recount_unprovable",
                "system",
                job.x,
                job.y,
                job.z,
                "group=" .. Cleaner.sanitize(job.group)
                    .. " plans=" .. job.unprovable
                    .. " candidates=" .. job.unprovableMax
                    .. " visitBudget=" .. C.ANIMAL_VISITS_PER_TICK
            )
        end
    elseif job.planIndex > #job.plans then
        -- 只有**所有 plans 都完成**才算恢復可證明。job-wide attempted 不夠：雙 plan job
        -- 的第一個 plan 可能完整 recount 後吃光 round budget，第二個 plan 完全未嘗試；
        -- 此時清 marker 會讓持續 unprovable 的後 plan 下一輪又重寫「首次」診斷
        unprovableWarned[job.key] = nil
    end
    if job.removed > 0 then
        -- scanner 只治理散養：scope 只剩 global（全服兜底）與 stray（per-player 熱點）。
        -- 圈養的 animal_clean（scope=zone）由 AnimalBreeding 的農場治理寫
        local cleanedScope = job.isGlobal and "global" or "stray"
        Cleaner.log(
            "animal_clean",
            "system",
            job.x,
            job.y,
            job.z,
            "group=" .. Cleaner.sanitize(job.group)
                .. " removed=" .. job.removed
                .. " wild=" .. job.wildRemoved
                .. " zoned=" .. job.zonedRemoved
                .. " scope=" .. cleanedScope
        )
        local remaining = job.count - job.removed
        -- 與警告同理：定向送給 bucket 所屬玩家，而不是以動物群位置為圓心廣播
        if isStillOnline(job.playerObj) then
            Cleaner.notifyCleanedPlayerOnly(job.playerObj, "animals", job.group, job.removed, cleanedScope, remaining)
        end
    elseif job.nanSkipped == 0 and job.unprovable == 0 and not untried then
        -- 真的嘗試過卻一隻都沒刪：候選在重驗時全數失效，或重數後已回到上限內
        -- （極少見的競態）。NaN／無法同 tick 重數各有專用診斷，不在這裡重複記
        Cleaner.log(
            "animal_protected_over",
            "system",
            job.x,
            job.y,
            job.z,
            "group=" .. Cleaner.sanitize(job.group)
                .. " count=" .. job.count
                .. " zoneCount=" .. job.zoneCount
                .. " protected=" .. job.protected
        )
    end
end

-- 候選的三態。**「還在不在原 bucket」與「這輪能不能刪」是兩件事**：
--   "removable" 仍在原玩家半徑內、仍歸原玩家、同 group/scope，可刪並計入現存數
--   "blocked"   同 group，但座標 NaN 無法安全重驗 scope → 不刪，保守計入原 bucket 現存數
--   "gone"      已死亡／換群組／變保護／走出原半徑／改歸其他玩家 → 不計入原 bucket
--
-- scope 重驗不能只看 group 與 stray/zone：動物走出半徑後，原 bucket 真正現存數已下降，
-- 若仍算進 walkAlive，會從其餘動物補刪到低於上限（AGENTS.md:131 的 recount 硬規則）。
-- 掃描後新生／移入但不在 plan.list 的動物會讓 alive 成為安全的下界，只會少刪、不會多刪。
local function inspectCandidate(job, plan, candidate, zoneCache, players, radius)
    local animal = candidate.animal
    if not animal then
        return "gone"
    end
    -- 已經被別的 job 刪掉了。**不能靠引擎狀態判斷**：`animal:remove()` 走
    -- delete() → removeFromSquare()，而 IsoMovingObject 只清 current/last
    -- （IsoMovingObject.java:705）、IsoObject 只把自己從 square 的清單移除
    -- （IsoObject.java:4539-4544）——**兩者都不清 this.square 欄位**，所以
    -- getSquare() 在移除後仍回原 square，isDead() 也不會變 true。
    -- 判準只能是我們自己蓋的旗標。它天然共享：全域桶與 per-player 桶刻意持有
    -- 同一張 candidate table，第一個 job 標記完第二個就立刻看得到
    if candidate.removed then
        return "gone"
    end
    -- 群組先查：不依賴座標，壞座標的動物也要能判斷「還算不算這一群」
    if getAnimalGroup(animal) ~= job.group then
        return "gone"
    end
    local ax = animal:getX()
    local ay = animal:getY()
    local az = animal:getZ()
    if ax ~= ax or ay ~= ay or az ~= az then
        return "blocked"
    end
    -- 全域 plan 沒有玩家歸屬可言：它的桶就是「全服已載入的這一群」，動物走到哪裡都還在桶裡。
    -- 這道重驗只對 per-player plan 成立——對全域 plan 套用的話，凡是站在任何玩家半徑內的
    -- 候選都會因 nearestPlayer ~= nil 而全數判成 gone，全域上限就只剩「清遠處」的效果
    if not plan.global then
        -- 重新套用**目前**在線玩家與**目前**掃描半徑。nearest 改變或已超出半徑，就不再
        -- 屬於掃描時那個 player|group bucket
        if nearestPlayer(animal, players, radius) ~= job.playerObj then
            return "gone"
        end
    end
    -- 分類同樣用本 tick 重建的圈地快照：新建／調整圈地後立即生效。
    -- 本模組只有散養 plan（圈養歸農場治理），候選變成 zone/protected 一律視為離開
    if classifyAnimal(animal, zoneCache) ~= "stray" then
        return "gone"
    end
    return "removable"
end

local function removeCandidate(job, plan, candidate, budget)
    local animal = candidate.animal
    local wasWild = animal:isWild() == true
    -- IsoAnimal.java:3383-3405
    animal:remove()
    -- 同一隻動物可能同時落在 per-player 與全域兩個 job 的 plan 裡（兩個桶共用 candidate）。
    -- 沒有這個旗標，第二個 job 會二次呼叫 remove()：不會崩，但 job.removed 虛高、
    -- 預算被重複扣、AnimalSynchronizationManager 再發一次刪除封包
    candidate.removed = true
    job.removed = job.removed + 1
    removalBudget = removalBudget - 1
    budget.removals = budget.removals - 1
    if wasWild then
        job.wildRemoved = job.wildRemoved + 1
    end
end

-- 換到下一個 plan（散養 → 圈養），回傳「整個 job 是否做完」
local function advancePlan(job)
    job.planIndex = job.planIndex + 1
    return job.planIndex > #job.plans
end

-- 每 tick 消化移除佇列。兩個獨立預算：
--   budget.removals        跨模組共用的本 tick remove 上限（事故降壓的標的；scanner
--                          先扣、農場治理拿剩餘——三個來源各自 3/tick 等於 9/tick，
--                          會推翻 2026-08-23 活鎖事故後的降壓）
--   ANIMAL_VISITS_PER_TICK 封頂重驗走訪量（主執行緒成本）
--
-- recount 必須在**同一個 tick**完整走完才可刪：跨 tick 累積 walkValid 會讓先驗的候選
-- 在真正 remove 前變成過期快照，重現本次要修的誤刪。單一 plan 大於 visit budget 時
-- 無法同 tick 證明現存數 → fail-closed，本輪跳過並記 animal_recount_unprovable。
local function processRemovals(budget)
    local visitBudget = C.ANIMAL_VISITS_PER_TICK
    local zoneCache = nil
    local players = Cleaner.getActivePlayers()
    local radius = tonumber(Cleaner.getOption("AnimalScanRadius")) or Cleaner.DEFAULTS.AnimalScanRadius
    while removalHead <= #removalQueue do
        local job = removalQueue[removalHead]
        local done = false
        if removalBudget <= 0 then
            -- 舊版額度用盡後的 bucket 完全不進處理、不寫 log；只標記，統一由下面出口 flush
            job.untried = job.removed == 0
            done = true
        else
            local plan = job.plans[job.planIndex]
            if not plan then
                done = true
            elseif #plan.list > C.ANIMAL_VISITS_PER_TICK then
                -- 即使本 tick 還有部分 visit budget，也無法完整走完；不能跨 tick 攢驗證結果
                job.unprovable = job.unprovable + 1
                if #plan.list > job.unprovableMax then
                    job.unprovableMax = #plan.list
                end
                done = advancePlan(job)
            elseif #plan.list > visitBudget then
                -- 這個 plan 自己可在一個 tick 走完，只是前面的 job 已用掉本 tick 額度。
                -- 原封不動留到下一 tick，屆時拿完整 visit budget；不會永久餓死
                return
            else
                zoneCache = zoneCache or buildZoneCache()
                local alive = 0
                local valid = {}
                for _, candidate in ipairs(plan.list) do
                    visitBudget = visitBudget - 1
                    local state = inspectCandidate(job, plan, candidate, zoneCache, players, radius)
                    if state == "removable" then
                        alive = alive + 1
                        valid[#valid + 1] = candidate
                    elseif state == "blocked" then
                        alive = alive + 1
                        -- 同一候選可能在多個 tick 被重數；用 key set 去重。stray/zone plan
                        -- 互斥，但同一 job 兩側都有 NaN 時要**加總**，不能取 max
                        if not job.nanSeen[candidate.key] then
                            job.nanSeen[candidate.key] = true
                            job.nanSkipped = job.nanSkipped + 1
                        end
                    end
                end
                local pending = alive - plan.limit
                if pending <= 0 then
                    -- 目前已回到上限內：本 plan 收工，一隻都不刪
                    done = advancePlan(job)
                else
                    local index = 1
                    while pending > 0 and budget.removals > 0 and removalBudget > 0
                        and index <= #valid do
                        removeCandidate(job, plan, valid[index], budget)
                        index = index + 1
                        pending = pending - 1
                    end
                    if pending <= 0 or index > #valid then
                        -- 已刪到目前上限，或所有可刪候選都用完（剩下的都是 blocked）
                        done = advancePlan(job)
                    else
                        -- remove 額度用盡但還沒刪完：不保留 valid。下一 tick 從頭完整 recount，
                        -- 確保每批 remove 前的驗證都是當下狀態
                        return
                    end
                end
            end
        end
        if done then
            if not job.flushed then
                flushRemoval(job, job.untried)
                job.flushed = true
            end
            -- 不可就地設 nil；只推進 head，排空時整表重置（見下方 Kahlua 註解）
            removalHead = removalHead + 1
        end
    end
    removalQueue = {}
    removalHead = 1
end

-- 佇列是否還有沒做完的計畫
local function hasPendingRemovals()
    return removalHead <= #removalQueue
end

-- 停用轉場：已刪除的部分仍要落盤，未做完的計畫整批丟棄。對齊物品側 0.3.0 的修正
-- （清理進行中關掉開關，已刪除的物品不能沒有紀錄）。還沒輪到的 job 帶 untried，
-- 不寫假的 animal_protected_over
local function discardRemovals()
    while removalHead <= #removalQueue do
        local job = removalQueue[removalHead]
        if not job.flushed then
            flushRemoval(job, job.removed == 0)
            job.flushed = true
        end
        removalHead = removalHead + 1
    end
    removalQueue = {}
    removalHead = 1
    removalBudget = 0
end

local function runAnimalScan(now)
    -- 分類總開關，優先於所有上限：關掉就不必把散養／圈養／逐群組覆寫逐一改成 0。
    -- 放在這裡而不是 onTick 開頭，是為了沿用下面同一條「清掉警告記錄再返回」的收尾——
    -- 關閉時舊記錄不該留著，否則之後重新開啟會沿用過期記錄直接清理、不再給玩家警告
    if Cleaner.getOption("AnimalCleanupEnabled") == false then
        warned = {}
        return
    end
    local defaultLimit = tonumber(Cleaner.getOption("MaxAnimalsPerGroup")) or Cleaner.DEFAULTS.MaxAnimalsPerGroup
    -- 全服已載入散養總量上限：0＝停用（預設）。與 defaultLimit 是獨立維度，見 Core 的
    -- MaxGlobalAnimalsPerGroup 說明——per-player 分桶必須先通過 nearestPlayer 過濾，
    -- 離所有玩家超過 AnimalScanRadius 的已載入動物在那個維度裡根本不存在。
    -- （圈養門檻不在這裡：圈養的清除與繁殖由 AnimalBreeding 以每座農場為單位治理）
    local globalLimit = tonumber(Cleaner.getOption("MaxGlobalAnimalsPerGroup")) or 0
    local overrides = Cleaner.getAnimalLimitOverrides()
    local globalOverrides = Cleaner.getAnimalGlobalLimitOverrides()
    -- 散養、全域與各自的逐群組覆寫都是獨立上限；只檢查其中一項會讓
    -- 「散養 0 ＋ 全域 rat=20」這類設定意外整個停擺
    if not hasAnyAnimalLimit(defaultLimit, globalLimit, overrides, globalOverrides) then
        -- 所有上限為 0 代表 bucket 生命週期中斷；兩種狀態都要清。否則恢復相同設定後，
        -- 舊 unprovable marker 會永久壓掉新的首次診斷
        warned = {}
        unprovableWarned = {}
        return
    end

    local players = Cleaner.getActivePlayers()
    if #players == 0 then
        -- 無玩家也等同所有 bucket 消失；同 key 玩家重連時不可沿用舊警告直接清理，亦不可
        -- 沿用舊 unprovable marker 永久沉默
        warned = {}
        unprovableWarned = {}
        return
    end

    local radius = tonumber(Cleaner.getOption("AnimalScanRadius")) or Cleaner.DEFAULTS.AnimalScanRadius
    local allowedGroups = Cleaner.getAnimalGroupSet()
    local zoneCache = buildZoneCache()
    -- 玩家周邊維度是否真的有上限（共用預設或任一覆寫 > 0）：只開全服清除時，
    -- nearestPlayer 是每輪 O(動物×玩家) 的白算——per-player 桶建了也永不超標。
    -- 全域桶刻意不做半徑過濾，跳過距離計算不影響它
    local wantPerPlayer = hasAnyAnimalLimit(defaultLimit, 0, overrides, {})
    local buckets = {}

    -- IsoCell.java:4565-4575；每輪讀一次，snapshot 成 Lua array 避免 LinkedList get(i) 的 O(n²)
    local animals = snapshotAnimals(getCell():getAnimals())
    for index = 1, #animals do
        local animal = animals[index]
        if animal then
            -- The single source list already assigns each animal once to its nearest player.
            local onlineID = animal:getOnlineID()
            local keyID = tostring(onlineID) .. ":" .. tostring(animal:getAnimalID()) .. ":" .. tostring(index)
            local group = getAnimalGroup(animal)
            if group and (allowedGroups._allowAll or allowedGroups[group]) then
                local nearest = wantPerPlayer and nearestPlayer(animal, players, radius) or nil
                -- 全域桶刻意**不**做半徑過濾：離所有玩家超過 radius 的動物在 per-player
                -- 分桶裡根本不存在（nearest 為 nil 就整隻跳過），但它們仍在
                -- IsoCell.objectList 裡、每 tick 全量更新。只在該群組真的設了全域上限時
                -- 才建桶，沒設的群組維持原本的零額外配置
                local effGlobalLimit = globalOverrides[group]
                if effGlobalLimit == nil then
                    effGlobalLimit = globalLimit
                end
                local globalBucket = nil
                if effGlobalLimit > 0 then
                    local globalKey = "*|" .. group
                    globalBucket = buckets[globalKey]
                    if not globalBucket then
                        globalBucket = {
                            key = globalKey,
                            group = group,
                            isGlobal = true,
                            -- 全域桶沒有歸屬玩家：notifyPlayer 對 nil 直接 return
                            -- （Core:749-751），所以警告與清理完成通知都不發、只留 log。
                            -- 這是刻意的——全域上限是管理員的兜底工具，超額的動物可能
                            -- 離所有玩家很遠（那正是它要處理的），沒有合理的通知對象
                            playerObj = nil,
                            count = 0,
                            zoneCount = 0,
                            protected = 0,
                            candidates = {},
                            x = animal:getX(),
                            y = animal:getY(),
                            z = animal:getZ(),
                        }
                        buckets[globalKey] = globalBucket
                    end
                end
                if nearest or globalBucket then
                    local playerBucket = nil
                    if nearest then
                        local key = playerKey(nearest) .. "|" .. group
                        playerBucket = buckets[key]
                        if not playerBucket then
                            playerBucket = {
                                key = key,
                                group = group,
                                playerObj = nearest,
                                count = 0,
                                zoneCount = 0,
                                protected = 0,
                                candidates = {},
                                x = animal:getX(),
                                y = animal:getY(),
                                z = animal:getZ(),
                            }
                            buckets[key] = playerBucket
                        end
                    end
                    local class = classifyAnimal(animal, zoneCache)
                    if class == "protected" then
                        if playerBucket then
                            playerBucket.protected = playerBucket.protected + 1
                        end
                        if globalBucket then
                            globalBucket.protected = globalBucket.protected + 1
                        end
                    elseif class == "zone" then
                        -- 圈養不歸本模組：清除與繁殖由 AnimalBreeding 以每座農場為單位
                        -- 治理。zoneCount 只是診斷計數——animal_protected_over 的 log
                        -- 靠它區分「沒有候選」與「候選全在圈地裡」
                        if playerBucket then
                            playerBucket.zoneCount = playerBucket.zoneCount + 1
                        end
                        if globalBucket then
                            globalBucket.zoneCount = globalBucket.zoneCount + 1
                        end
                    else
                        -- candidate table 由兩個桶**共用同一張表**：Kahlua 的每個 Lua table
                        -- 都是獨立的 KahluaTableImpl（底層 LinkedHashMap），各建一份會讓
                        -- 配置量直接翻倍。共用是安全的——candidate 從建立到 flush 全程唯讀
                        local candidate = {
                            key = keyID,
                            -- 直接持有動物參照。計畫壽命只有幾個 tick（20 隻 ÷ 3 每 tick），
                            -- 且每次移除前都重驗 group 與 class；比跨 tick 重新全掃
                            -- getAnimals() 便宜得多，也不必維護一份會過期的 keyID→animal 表。
                            animal = animal,
                            onlineID = onlineID,
                            animalID = animal:getAnimalID(),
                            order = index,
                            x = animal:getX(),
                            y = animal:getY(),
                            z = animal:getZ(),
                            wild = animal:isWild() == true,
                            baby = animal:isBaby() == true,
                        }
                        if playerBucket then
                            playerBucket.count = playerBucket.count + 1
                            playerBucket.candidates[#playerBucket.candidates + 1] = candidate
                        end
                        if globalBucket then
                            globalBucket.count = globalBucket.count + 1
                            globalBucket.candidates[#globalBucket.candidates + 1] = candidate
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

    -- 本輪總額度。刻意是模組級而非 local：移除跨 tick 進行，額度必須跟著佇列一起活過
    -- 這次呼叫（語意與舊版的 remainingBudget 相同——每輪最多 ANIMALS_PER_ROUND 隻）
    removalBudget = C.ANIMALS_PER_ROUND
    for _, bucket in ipairs(orderedBuckets) do
        -- plans 為空＝這個桶沒有任何維度超標。用 #plans 當統一判準，而不是各維度的
        -- over 旗標——加維度時只要在對應分支裡 push plan，收尾的警告記錄回收不必跟著改
        local plans = {}
        local scope, warnCount, warnLimit
        local emergency = false
        if bucket.isGlobal then
            -- 全域桶只有散養一個維度（圈養刻意不納入，見掃描迴圈的說明）
            local bucketGlobalLimit = globalOverrides[bucket.group]
            if bucketGlobalLimit == nil then
                bucketGlobalLimit = globalLimit
            end
            if bucketGlobalLimit > 0 and bucket.count > bucketGlobalLimit then
                scope = "global"
                warnCount = bucket.count
                warnLimit = bucketGlobalLimit
                emergency = bucket.count > C.ANIMAL_EMERGENCY_MULTIPLIER * bucketGlobalLimit
                -- global=true 讓 inspectCandidate 跳過玩家歸屬重驗（見該函式說明）
                plans[1] = { list = bucket.candidates, limit = bucketGlobalLimit, zone = false, global = true }
            end
        else
            local limit = overrides[bucket.group]
            if limit == nil then
                limit = defaultLimit
            end
            -- limit 為 0 ＝ 該群組散養不清理。少了這道 > 0 檢查，「散養 0 ＋ 全域 rat=20」
            -- 這類設定會變成 count > 0 恆為真，把散養全數清光
            if limit > 0 and bucket.count > limit then
                emergency = bucket.count > C.ANIMAL_EMERGENCY_MULTIPLIER * limit
                scope = "stray"
                warnCount = bucket.count
                warnLimit = limit
                -- **帶 limit 而不是 excess**：excess 是掃描當時的差額，跨 tick 就過期了；
                -- processRemovals 每個 tick 重數現存數再減 limit，才不會把已回到上限內的
                -- 群組繼續刪（AGENTS.md 對跨 tick 刪除佇列的硬規則）
                plans[1] = { list = bucket.candidates, limit = limit }
            end
        end
        if #plans == 0 then
            warned[bucket.key] = nil
            unprovableWarned[bucket.key] = nil
        else
            local confirmed = emergency or warnBucket(bucket, now, scope, warnCount, warnLimit)
            if confirmed then
                -- 排序在這裡做完，每個計畫只排一次；移除本身交給 processRemovals 跨 tick 攤平。
                -- 一律 sortSafe，全庫零 table.sort（Kahlua 的 table.sort 是遞迴 quicksort，
                -- 對已接近排序的輸入會退化成 O(n) 遞迴深度而 stack overflow，見 Core.sortSafe）
                for _, plan in ipairs(plans) do
                    Cleaner.sortSafe(plan.list, candidateSort)
                end
                -- 一個 bucket ＝ 一個 job ＝ 最終一行 animal_clean log。跨 tick 消化但統計
                -- 累加在 job 上，log 行數與舊版逐 bucket 聚合完全一致。
                -- 圈地快照刻意**不**存進 job：processRemovals 每個 tick 重建，否則新建圈地
                -- 內的牲畜會被舊快照當成散養而誤刪
                removalQueue[#removalQueue + 1] = {
                    key = bucket.key,
                    group = bucket.group,
                    playerObj = bucket.playerObj,
                    -- flushRemoval 的 animal_clean scope 靠這個欄位區分「全域兜底」與
                    -- 「per-player 熱點」（圈養的 scope=zone 由 AnimalBreeding 自己寫）
                    isGlobal = bucket.isGlobal == true,
                    x = bucket.x,
                    y = bucket.y,
                    z = bucket.z,
                    count = bucket.count,
                    zoneCount = bucket.zoneCount,
                    protected = bucket.protected,
                    plans = plans,
                    planIndex = 1,
                    removed = 0,
                    wildRemoved = 0,
                    zonedRemoved = 0,
                    -- NaN 用候選 key set 去重：同一 plan 跨多 tick 重數不能重複加
                    nanSeen = {},
                    nanSkipped = 0,
                    -- plan 候選數超過同 tick visit budget 時 fail-closed，專用診斷聚合在 job
                    unprovable = 0,
                    unprovableMax = 0,
                    untried = false,
                    flushed = false,
                }
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
    -- unprovable 狀態也按 bucket 生命週期回收；不可在 pairs 內直接刪，沿用上面的兩階段形狀
    stale = {}
    for key in pairs(unprovableWarned) do
        if not buckets[key] then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        unprovableWarned[key] = nil
    end
end

-- 動物子系統的**單一 OnTick 進入點**：scanner（散養）先走，農場治理（AnimalBreeding
-- 的 Cleaner.ranchTick）拿剩餘預算。兩個 Events.OnTick.Add 的執行順序取決於檔案載入
-- 順序（字母序），跨模組共用預算不能建立在那種隱性依賴上——所以由這裡統一驅動。
-- budget.removals 是本 tick 全子系統的 remove 上限（C.ANIMALS_PER_TICK；活鎖事故的
-- 降壓標的是「每 frame 的 remove 密度」，三個來源各自 3/tick 等於 9/tick 會推翻它）
local function onTick()
    local budget = { removals = C.ANIMALS_PER_TICK }
    -- 總開關的檢查必須在這裡，不能只留在 runAnimalScan：佇列未排空時根本不會呼叫它，
    -- 於是「清理進行中關掉開關」會變成照樣刪完整批（物品側 0.3.0 修過同型問題）
    if Cleaner.getOption("AnimalCleanupEnabled") == false then
        if hasPendingRemovals() then
            discardRemovals()
        end
        warned = {}
        unprovableWarned = {}
        -- 農場治理自己的停用收尾（清游標與警告記錄）也要跑
        if Cleaner.ranchTick then
            Cleaner.ranchTick(budget)
        end
        return
    end
    -- 先消化上一輪的移除佇列，把同一份總額度攤平——降壓理由見 Core 的 ANIMALS_PER_TICK
    -- （2026-08-23 全服活鎖事故）
    processRemovals(budget)
    -- 農場治理（圈養清除＋繁殖抑制）拿本 tick 剩餘的移除預算。call-time 解析：
    -- AnimalBreeding 載入順序在前（字母序 B < S），函式已就緒；防禦性判空讓兩個檔案
    -- 在任一載入順序下都不炸
    if Cleaner.ranchTick then
        Cleaner.ranchTick(budget)
    end
    -- 佇列沒排空就不開新一輪掃描：否則計畫疊加，每輪 ANIMALS_PER_ROUND 的總額度失去意義
    if hasPendingRemovals() then
        return
    end
    local now = getTimestampMs()
    local interval = (tonumber(Cleaner.getOption("AnimalScanIntervalSeconds")) or Cleaner.DEFAULTS.AnimalScanIntervalSeconds) * 1000
    if now - lastScanAt < interval then
        return
    end
    lastScanAt = now
    runAnimalScan(now)
end

Events.OnTick.Add(onTick)
