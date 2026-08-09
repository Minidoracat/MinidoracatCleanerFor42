if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner
local C = Cleaner.CONSTANTS

local scanQueue = {}
local activeJob = nil
local dirtyChunks = {}
local warned = {}
-- 區域(area)超標的警告狀態，與 chunk 分開：key = onlineID:username|bucket|fullType，
-- 一位玩家、一個桶、一種物品只發一則警告（不再是區域內每個含該物品的區塊各發一則）
local areaWarned = {}
local deleteQueue = {}
local deleteHead = 1
local pendingDeleteIDs = {}
local periodicQueued = false
local lastPeriodicAt = 0
local cleanNotify = {}

local function chunkKey(cx, cy, z)
    return tostring(cx) .. "," .. tostring(cy) .. "," .. tostring(z)
end

-- 兩個計數桶，各自比對各自的上限：
--   normal＝本次遊玩中被玩家丟下的（身上有丟棄者標記，且沒被列進高容忍清單）
--   high  ＝世界原生／MOD 安裝前的舊物（無標記），或管理員列進高容忍清單的
-- 分桶的意義：「100 顆世界原生的原木 ＋ 150 顆某人倒的原木」只會清那 150 顆裡超額的部分
local BUCKETS = { "normal", "high" }

local function hotspotKey(key, bucketName, fullType)
    return key .. "|" .. bucketName .. "|" .. fullType
end

local function makeJob(kind, chunks, players)
    local chunkSet = {}
    for _, chunk in ipairs(chunks) do
        chunkSet[chunkKey(chunk.cx, chunk.cy, chunk.z)] = chunk
    end
    -- regionCount 依玩家分開累計。舊版把所有線上玩家的區塊併成單一總數，於是「掃描區域上限」
    -- 實際上是全服總和：地圖另一頭的人砍樹會害你這邊跳警告；而且玩家一走動聯集就變，
    -- 總數在上限附近震盪 → 警告記錄反覆清除重建 → 永遠等不到「下一輪仍超標」那一輪，
    -- 結果是無限刷警告卻從不執行清理（正式服 log：warn 571 筆、對應 auto_clean 0 筆）。
    players = players or {}
    local buckets = {}
    for _, bucketName in ipairs(BUCKETS) do
        local regionCount = {}
        for index = 1, #players do
            regionCount[index] = {}
        end
        buckets[bucketName] = { counts = {}, candidates = {}, regionCount = regionCount }
    end
    return {
        kind = kind,
        chunks = chunks,
        chunkSet = chunkSet,
        chunkIndex = 1,
        squareIndex = 0,
        buckets = buckets,
        players = players,
        protectSet = Cleaner.getProtectMatcher(),
        highSet = Cleaner.getHighToleranceMatcher(),
        stampsEnabled = Cleaner.getOption("TouchTraceEnabled") ~= false,
    }
end

function Cleaner.markDirty(square)
    if not square then
        return
    end
    if Cleaner.isFloorCleaningDisabled() then
        return
    end
    local cx = math.floor(square:getX() / C.CHUNK_SIZE)
    local cy = math.floor(square:getY() / C.CHUNK_SIZE)
    local z = math.floor(square:getZ())
    local key = chunkKey(cx, cy, z)
    dirtyChunks[key] = {
        cx = cx,
        cy = cy,
        z = z,
        readyAt = getTimestampMs() + C.DIRTY_DELAY_MS,
    }
end

local function buildPeriodicChunks()
    local chunks = {}
    local index = {}
    local players = Cleaner.getActivePlayers()
    local radius = tonumber(Cleaner.getOption("ScanRadius")) or Cleaner.DEFAULTS.ScanRadius
    for playerIndex, playerObj in ipairs(players) do
        local minCX = math.floor((playerObj:getX() - radius) / C.CHUNK_SIZE)
        local maxCX = math.floor((playerObj:getX() + radius) / C.CHUNK_SIZE)
        local minCY = math.floor((playerObj:getY() - radius) / C.CHUNK_SIZE)
        local maxCY = math.floor((playerObj:getY() + radius) / C.CHUNK_SIZE)
        local levels = { 0 }
        local playerZ = math.floor(playerObj:getZ())
        if playerZ ~= 0 then
            levels[2] = playerZ
        end
        for _, z in ipairs(levels) do
            for cy = minCY, maxCY do
                for cx = minCX, maxCX do
                    local key = chunkKey(cx, cy, z)
                    local chunk = index[key]
                    if not chunk then
                        chunk = { cx = cx, cy = cy, z = z, owners = {} }
                        index[key] = chunk
                        chunks[#chunks + 1] = chunk
                    end
                    -- 區塊仍去重（玩家聚集時不重複掃描），但記下它屬於哪幾位玩家的區域，
                    -- 供 regionCount 分開累計。同一玩家同一 key 只會走到這裡一次（z 不重複）
                    chunk.owners[#chunk.owners + 1] = playerIndex
                end
            end
        end
    end
    -- 不排序：巢狀迴圈產生的順序本來就是空間連續且確定的；且對「已接近排序」的大陣列
    -- 呼叫 Kahlua table.sort 會退化成 O(n) 遞迴深度而 stack overflow（見 Core.sortSafe 註解）
    return chunks, players
end

local function queuePeriodicScan(now)
    if periodicQueued then
        return
    end
    local chunks, players = buildPeriodicChunks()
    if #chunks == 0 then
        -- 無人在線時不會有 periodic job，也就不會跑到 finishJob 的 area prune，
        -- 記錄會殘留到下一批玩家上線；在這裡直接清空
        areaWarned = {}
        return
    end
    scanQueue[#scanQueue + 1] = makeJob("periodic", chunks, players)
    periodicQueued = true
    lastPeriodicAt = now
end

local function promoteDirtyChunks(now)
    local ready = {}
    for key, chunk in pairs(dirtyChunks) do
        if now >= chunk.readyAt then
            ready[#ready + 1] = { key = key, chunk = chunk }
        end
    end
    Cleaner.sortSafe(ready, function(a, b) return a.key < b.key end)
    for _, entry in ipairs(ready) do
        dirtyChunks[entry.key] = nil
        scanQueue[#scanQueue + 1] = makeJob("dirty", { entry.chunk })
    end
end

local function addCandidate(bucket, key, fullType, item, square)
    local byType = bucket.candidates[key]
    if not byType then
        byType = {}
        bucket.candidates[key] = byType
    end
    local list = byType[fullType]
    if not list then
        list = {}
        byType[fullType] = list
    end
    -- 用遞增的 item ID 近似「較晚取得＝較晚落地」；worldObj.dropTime 是 instance field，Kahlua 不暴露（讀不到）
    list[#list + 1] = {
        id = item:getID(),
        fullType = fullType,
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        cx = math.floor(square:getX() / C.CHUNK_SIZE),
        cy = math.floor(square:getY() / C.CHUNK_SIZE),
    }
end

-- 修復被「非原版路徑」刪空的容器——本 MOD 0.2.6 以前的刪除正是這樣。
-- 指紋＝容器空 ＋ hasBeenLooted 為 false ＋ 物件卻還掛著 overlay 貼圖，三者同時成立。
-- 這個組合只可能是壞的：
--   · 原版搬空會設旗標並重算貼圖（ISInventoryTransferAction.lua:656,681-683）→ 旗標是 true
--   · 天生骰空、沒人動過的容器從來不會被賦予 overlay——補正只在 !isEmpty() 時才跑
--     （LoadGridsquarePerformanceWorkaround.java:73-75）→ 貼圖是 nil
-- 修好後指紋隨即消失，同一個容器不會被重複處理，世界修完成本就歸零。
--
-- 但「有 overlay」單獨不足以當指紋：B42 的實體工作站（鞣製架、晾曬架…）也用 overlay
-- 表現製作進度，走的是完全不同的通道（SpriteOverlayConfig.java:83），而且同樣可能帶著
-- 空容器。誤判的代價是雙重的——既把它標成「已搜刮」讓它憑空開始重生物資，
-- `updateOverlaySprite` 又會因為底圖不在容器 overlay 表裡而直接抹掉它的製作進度貼圖
-- （ContainerOverlays.java:147-173 查無 → setOverlaySprite(nil)）。
-- 所以再問一次 `hasOverlays`：物件的**底圖**必須登記在容器 overlay 表裡（:131-133），
-- 也就是「這本來就是一個有滿／空外觀的貨架」；工作站與被塗鴉的牆一律排除在外。
--
-- 篩選順序＝最便宜又最有鑑別力的先做：getOverlaySprite 是純欄位讀取、對絕大多數物件是
-- nil，一次就淘汰掉；通過後才做 hasOverlays 的雜湊查表，最後才碰容器。
-- `hasOverlays` 只保證「底圖是貨架」，不保證「現在掛著的這張 overlay 真的出自容器系統」。
-- 第三方 MOD 大可在同一個底圖上掛自己的 overlay，硬清掉等於砸掉別人的畫面。
-- 所以再反查一次：這張 overlay 的名稱登記在哪些底圖底下（ContainerOverlays.java:135-137），
-- 必須包含本物件的底圖才算數。查不到＝來路不明＝fail-closed 不碰。
-- 用 size()/get() 逐一比對而不是 ArrayList:contains()：清單只有一兩筆，而 Kahlua 對
-- Java 方法的暴露有過意外（見 AGENTS.md 踩坑錄），沒必要為省三行冒這個險。
local function overlayCameFromContainer(overlays, object)
    local sprite = object:getSprite()
    local overlaySprite = object:getOverlaySprite()
    if not sprite or not overlaySprite then
        return false
    end
    local underlying = overlays:getUnderlyingSpriteNames(overlaySprite:getName())
    if not underlying then
        return false
    end
    local spriteName = sprite:getName()
    for index = 0, underlying:size() - 1 do
        if underlying:get(index) == spriteName then
            return true
        end
    end
    return false
end

local function repairBrokenContainers(job, square)
    local objects = square:getObjects()
    local overlays = getContainerOverlays()
    for index = 0, objects:size() - 1 do
        local object = objects:get(index)
        if object and object:getOverlaySprite() and overlays:hasOverlays(object)
            and overlayCameFromContainer(overlays, object) then
            -- overlay 只反映**主**容器的件數（ContainerOverlays.java:146），
            -- 也就只有主容器的狀態能從貼圖反推，多容器物件的其餘容器不碰
            local container = object:getContainer()
            if container and container:isEmpty() and not container:isHasBeenLooted() then
                container:setHasBeenLooted(true)
                ItemPicker.updateOverlaySprite(object)
                -- setHasBeenLooted 與 setOverlaySprite 都不會自己標記存檔（不像 DoRemoveItem
                -- 內建 flagForHotSave，ItemContainer.java:2090-2092）；少了這行，修好的狀態
                -- 會在下次重啟被打回原形，等於每次開服都白修一遍
                object:flagForHotSave()
                job.repaired = (job.repaired or 0) + 1
                if not job.repairAt then
                    job.repairAt = { x = square:getX(), y = square:getY(), z = square:getZ() }
                end
            end
        end
    end
end

local function scanSquare(job, chunk, square)
    repairBrokenContainers(job, square)
    local key = chunkKey(chunk.cx, chunk.cy, chunk.z)
    local worldObjects = square:getWorldObjects()
    for index = 0, worldObjects:size() - 1 do
        local worldObj = worldObjects:get(index)
        local item = worldObj and worldObj:getItem()
        local fullType = item and item:getFullType()
        if fullType then
            local bucketName = Cleaner.isHighTolerance(job.highSet, item, fullType, job.stampsEnabled)
                and "high" or "normal"
            local bucket = job.buckets[bucketName]
            local counts = bucket.counts[key]
            if not counts then
                counts = {}
                bucket.counts[key] = counts
            end
            counts[fullType] = (counts[fullType] or 0) + 1
            if job.kind == "periodic" and chunk.owners then
                for _, owner in ipairs(chunk.owners) do
                    local ownerCount = bucket.regionCount[owner]
                    if ownerCount then
                        ownerCount[fullType] = (ownerCount[fullType] or 0) + 1
                    end
                end
            end
            if Cleaner.isSafeFloorCandidate(item, worldObj, job.protectSet) then
                addCandidate(bucket, key, fullType, item, square)
            end
        end
    end
end

local function warnInterval()
    return (tonumber(Cleaner.getOption("ScanIntervalSeconds")) or Cleaner.DEFAULTS.ScanIntervalSeconds) * 1000
end

local function ensureWarning(key, chunk, fullType, count, limit, now)
    local record = warned[key]
    if not record then
        record = { time = now, lastSeen = now }
        warned[key] = record
        local x = chunk.cx * C.CHUNK_SIZE + C.CHUNK_SIZE / 2
        local y = chunk.cy * C.CHUNK_SIZE + C.CHUNK_SIZE / 2
        Cleaner.warnNearby("items", x, y, chunk.z, fullType, nil, count, limit)
        Cleaner.log("warn", "system", x, y, chunk.z,
            "kind=items scope=chunk fullType=" .. Cleaner.sanitize(fullType)
                .. " count=" .. count .. " limit=" .. limit)
    end
    return now - record.time >= warnInterval()
end

-- 帶上 username：B42 的 onlineID 是可回收重用的連線槽（GameServer.java:2638,3006），
-- 只用 ID 當 key 時新玩家可能撿到前一位玩家的舊 timestamp，導致首次掃描就直接進清理而沒警告
local function areaWarnKey(playerObj, bucketName, fullType)
    return tostring(playerObj:getOnlineID()) .. ":" .. Cleaner.sanitize(playerObj:getUsername())
        .. "|" .. bucketName .. "|" .. fullType
end

-- 區域超標：整個掃描區域、每位玩家、每種物品只發**一則**警告，錨在該玩家自身位置。
-- 舊版對區域內每個含該物品的區塊各發一則（條件只是該區塊有 ≥1 件），玩家附近有幾個
-- 這種區塊就被洗幾行完全相同的訊息。
local function ensureAreaWarning(key, playerObj, fullType, count, limit, now)
    local record = areaWarned[key]
    if not record then
        record = { time = now }
        areaWarned[key] = record
        local x, y, z = playerObj:getX(), playerObj:getY(), playerObj:getZ()
        Cleaner.warnPlayerOnly(playerObj, "items", fullType, count, limit)
        Cleaner.log("warn", playerObj:getUsername(), x, y, z,
            "kind=items scope=area fullType=" .. Cleaner.sanitize(fullType)
                .. " count=" .. count .. " limit=" .. limit)
    end
    return now - record.time >= warnInterval()
end

local function queueVictim(record, scope, limit, bucketName)
    if pendingDeleteIDs[record.id] then
        return false
    end
    pendingDeleteIDs[record.id] = true
    -- 記錄觸發 scope、當時閾值與所屬桶，供 processDeleteQueue 刪除前 live recount
    -- （避免用過期數量刪到低於閾值；recount 必須只數同一個桶的物品）
    record.scope = scope
    record.limit = limit
    record.bucket = bucketName
    deleteQueue[#deleteQueue + 1] = record
    return true
end

local function selectCandidates(list, needed, selected, scope, limit, bucketName)
    if not list or needed <= 0 then
        return
    end
    -- 整堆整堆刪：以格子為單位分組，最新的堆（該格最大 item ID）先整堆刪光再換下一堆——
    -- 傾倒者看到自己的堆整堆蒸發，視覺直觀；堆內再按 ID 降冪
    local pileRank = {}
    for _, record in ipairs(list) do
        local pk = record.x .. "," .. record.y .. "," .. record.z
        record.pileKey = pk
        if not pileRank[pk] or record.id > pileRank[pk] then
            pileRank[pk] = record.id
        end
    end
    -- 傾倒攻擊產生的 item ID 多為連號＝已接近排序，必須用非遞迴排序（見 Core.sortSafe）
    Cleaner.sortSafe(list, function(a, b)
        local ra = pileRank[a.pileKey]
        local rb = pileRank[b.pileKey]
        if ra ~= rb then
            return ra > rb
        end
        if a.pileKey ~= b.pileKey then
            return a.pileKey < b.pileKey
        end
        return a.id > b.id
    end)
    local planned = 0
    local counted = {}
    for _, record in ipairs(list) do
        if not counted[record.id] and (selected[record.id] or pendingDeleteIDs[record.id]) then
            counted[record.id] = true
            selected[record.id] = true
            planned = planned + 1
        end
    end
    if planned >= needed then
        return
    end

    for _, record in ipairs(list) do
        if not selected[record.id] then
            selected[record.id] = true
            if queueVictim(record, scope, limit, bucketName) then
                planned = planned + 1
                if planned >= needed then
                    return
                end
            end
        end
    end
end

local function getChunk(job, key)
    -- O(1)：chunkSet 存 chunk 物件（避免 finishJob 對每個 count key 做 O(chunks) 線性搜尋）
    return job.chunkSet[key]
end

local function chunkOwnedBy(chunk, ownerIndex)
    if not chunk or not chunk.owners then
        return false
    end
    for _, owner in ipairs(chunk.owners) do
        if owner == ownerIndex then
            return true
        end
    end
    return false
end

-- 本次掃到的區塊依 reasons 判定去留（沒列進去＝已回到上限內）；沒掃到的區塊——玩家已離開、
-- 之後可能永遠不會再被掃到——則用閒置年齡回收，避免記錄隨探索範圍無界成長
local function pruneChunkWarnings(job, reasons, now)
    local staleMs = warnInterval() * C.WARN_STALE_INTERVALS
    local stale = {}
    for key, record in pairs(warned) do
        local separator = string.find(key, "|", 1, true)
        local keyChunk = separator and string.sub(key, 1, separator - 1) or ""
        if job.chunkSet[keyChunk] then
            if reasons[key] then
                record.lastSeen = now
            else
                stale[#stale + 1] = key
            end
        elseif now - (record.lastSeen or record.time) > staleMs then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        warned[key] = nil
    end
end

local function bucketLimits(bucketName)
    if bucketName == "high" then
        return tonumber(Cleaner.getOption("HighToleranceMaxPerType")) or Cleaner.DEFAULTS.HighToleranceMaxPerType,
            tonumber(Cleaner.getOption("HighToleranceMaxPerTypeArea")) or Cleaner.DEFAULTS.HighToleranceMaxPerTypeArea
    end
    return tonumber(Cleaner.getOption("MaxFloorItemsPerType")) or Cleaner.DEFAULTS.MaxFloorItemsPerType,
        tonumber(Cleaner.getOption("MaxFloorItemsPerTypeArea")) or Cleaner.DEFAULTS.MaxFloorItemsPerTypeArea
end

local function finishJob(job, now)
    local selected = {}
    local reasons = {}
    local areaReasons = {}

    for _, bucketName in ipairs(BUCKETS) do
        local bucket = job.buckets[bucketName]
        local maxChunk, maxArea = bucketLimits(bucketName)

        if maxChunk > 0 then
            for key, counts in pairs(bucket.counts) do
                local chunk = getChunk(job, key)
                for fullType, count in pairs(counts) do
                    if count > maxChunk then
                        local warningKey = hotspotKey(key, bucketName, fullType)
                        reasons[warningKey] = true
                        if ensureWarning(warningKey, chunk, fullType, count, maxChunk, now) then
                            local list = bucket.candidates[key] and bucket.candidates[key][fullType]
                            if list and #list > 0 then
                                selectCandidates(list, count - maxChunk, selected, "chunk", maxChunk, bucketName)
                            else
                                -- 超標但無可刪候選（全部 isIgnoreRemoveSandbox/favorite/protectlist/非空容器）：記一次診斷 log
                                local record = warned[warningKey]
                                if record and not record.loggedProtected then
                                    record.loggedProtected = true
                                    Cleaner.log("items_protected_over", "system", chunk.cx, chunk.cy, chunk.z,
                                        "bucket=" .. bucketName .. " fullType=" .. Cleaner.sanitize(fullType)
                                            .. " count=" .. count .. " limit=" .. maxChunk)
                                end
                            end
                        end
                    end
                end
            end
        end

        if job.kind == "periodic" and maxArea > 0 then
            -- 逐玩家判定：每位玩家只跟自己周邊的數量比對，別人在地圖另一頭堆的不算在內
            for ownerIndex, counts in pairs(bucket.regionCount) do
                local playerObj = job.players[ownerIndex]
                if playerObj then
                    -- 該玩家擁有的區塊清單只建一次（且延後到真的要挑候選時才建）：
                    -- 否則「每位玩家 × 每種超標物品」都得重掃整份 counts，人多時是一次性尖峰
                    local ownerKeys = nil
                    for fullType, count in pairs(counts) do
                        if count > maxArea then
                            local warningKey = areaWarnKey(playerObj, bucketName, fullType)
                            areaReasons[warningKey] = true
                            if ensureAreaWarning(warningKey, playerObj, fullType, count, maxArea, now) then
                                if not ownerKeys then
                                    ownerKeys = {}
                                    for key in pairs(bucket.counts) do
                                        if chunkOwnedBy(getChunk(job, key), ownerIndex) then
                                            ownerKeys[#ownerKeys + 1] = key
                                        end
                                    end
                                end
                                local regionCandidates = {}
                                for _, key in ipairs(ownerKeys) do
                                    local list = bucket.candidates[key] and bucket.candidates[key][fullType]
                                    if list then
                                        for _, record in ipairs(list) do
                                            regionCandidates[#regionCandidates + 1] = record
                                        end
                                    end
                                end
                                selectCandidates(regionCandidates, count - maxArea, selected, "area", maxArea, bucketName)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 每輪 periodic 都涵蓋全部線上玩家與兩個桶，因此沒出現在本輪 areaReasons 的記錄
    -- ＝已回到上限內，或該玩家已離線 → 一律清掉
    if job.kind == "periodic" then
        local staleArea = {}
        for key in pairs(areaWarned) do
            if not areaReasons[key] then
                staleArea[#staleArea + 1] = key
            end
        end
        for _, key in ipairs(staleArea) do
            areaWarned[key] = nil
        end
    end

    pruneChunkWarnings(job, reasons, now)

    -- 修復是逐格發生的，但 log 累到整份工作做完才寫一行（ZLogger 超過 10MB 是原檔截斷
    -- 非輪替，ZLogger.java:95-101）。世界修完後這行就不再出現，可當成收斂指標
    if job.repaired and job.repaired > 0 then
        local at = job.repairAt or { x = 0, y = 0, z = 0 }
        Cleaner.log("container_repair", "system", at.x, at.y, at.z, "repaired=" .. job.repaired)
    end
end

local function consumeScanQueue(now)
    local budget = C.SQUARES_PER_TICK
    while budget > 0 do
        if not activeJob then
            activeJob = table.remove(scanQueue, 1)
            if not activeJob then
                return
            end
        end

        local chunk = activeJob.chunks[activeJob.chunkIndex]
        if not chunk then
            finishJob(activeJob, now)
            if activeJob.kind == "periodic" then
                periodicQueued = false
            end
            activeJob = nil
        else
            local offset = activeJob.squareIndex
            local x = chunk.cx * C.CHUNK_SIZE + (offset % C.CHUNK_SIZE)
            local y = chunk.cy * C.CHUNK_SIZE + math.floor(offset / C.CHUNK_SIZE)
            local square = getCell():getGridSquare(x, y, chunk.z)
            if square then
                scanSquare(activeJob, chunk, square)
            end
            activeJob.squareIndex = activeJob.squareIndex + 1
            if activeJob.squareIndex >= C.CHUNK_SIZE * C.CHUNK_SIZE then
                activeJob.squareIndex = 0
                activeJob.chunkIndex = activeJob.chunkIndex + 1
            end
            budget = budget - 1
        end
    end
end

local function findQueuedWorldItem(record)
    local square = getCell():getGridSquare(record.x, record.y, record.z)
    if not square then
        return nil, nil, nil
    end
    local worldObjects = square:getWorldObjects()
    for index = 0, worldObjects:size() - 1 do
        local worldObj = worldObjects:get(index)
        local item = worldObj and worldObj:getItem()
        if item and item:getID() == record.id and item:getFullType() == record.fullType then
            return item, worldObj, square
        end
    end
    return nil, nil, square
end

-- 重數某 chunk 內某 fullType、**且屬於同一個計數桶**的現存地板物品數（帶本 tick cache）；
-- 供刪除前 recount，避免用過期快照刪到低於閾值。必須依桶過濾——否則 normal 桶的受害者
-- 會把世界原生那些一起數進來，recount 永遠過關而刪過頭
local function liveChunkCount(cx, cy, z, fullType, bucketName, ctx, cache)
    local ck = chunkKey(cx, cy, z) .. "|" .. bucketName .. "|" .. fullType
    if cache[ck] ~= nil then
        return cache[ck], ck
    end
    local count = 0
    local baseX = cx * C.CHUNK_SIZE
    local baseY = cy * C.CHUNK_SIZE
    for oy = 0, C.CHUNK_SIZE - 1 do
        for ox = 0, C.CHUNK_SIZE - 1 do
            local square = getCell():getGridSquare(baseX + ox, baseY + oy, z)
            if square then
                local wos = square:getWorldObjects()
                for i = 0, wos:size() - 1 do
                    local wo = wos:get(i)
                    local it = wo and wo:getItem()
                    if it and it:getFullType() == fullType then
                        local isHigh = Cleaner.isHighTolerance(ctx.highSet, it, fullType, ctx.stampsEnabled)
                        if isHigh == (bucketName == "high") then
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    cache[ck] = count
    return count, ck
end

local function compactDeleteQueue()
    if deleteHead <= 256 or deleteHead <= #deleteQueue / 2 then
        return
    end
    local compacted = {}
    for index = deleteHead, #deleteQueue do
        compacted[#compacted + 1] = deleteQueue[index]
    end
    deleteQueue = compacted
    deleteHead = 1
end

local function processDeleteQueue()
    -- 佇列空就直接離開：下面兩個 matcher 每次都要重新解析沙盒字串並轉小寫，
    -- 而 onTick 每幀都會呼叫本函式——絕大多數幀佇列是空的，等於白做 60 次/秒。
    -- （排空當下的 log／通知輸出在同一次呼叫的迴圈後就完成，不會被這道 early return 跳過）
    if deleteHead > #deleteQueue then
        return
    end
    local protectSet = Cleaner.getProtectMatcher()
    local ctx = {
        highSet = Cleaner.getHighToleranceMatcher(),
        stampsEnabled = Cleaner.getOption("TouchTraceEnabled") ~= false,
    }
    local liveCache = {}
    local processed = 0
    while processed < C.ITEMS_PER_TICK and deleteHead <= #deleteQueue do
        local record = deleteQueue[deleteHead]
        deleteHead = deleteHead + 1
        pendingDeleteIDs[record.id] = nil
        processed = processed + 1

        -- chunk-scope 刪除前 recount：玩家可能已自行撿走使該 chunk 回到閾值內，則取消本件（不刪到低於閾值）
        local overThreshold = true
        if record.scope == "chunk" then
            local live = liveChunkCount(record.cx, record.cy, record.z, record.fullType, record.bucket, ctx, liveCache)
            overThreshold = live > (record.limit or 0)
        end

        local item, worldObj, square = nil, nil, nil
        if overThreshold then
            item, worldObj, square = findQueuedWorldItem(record)
            -- 分桶是掃描當下依當時設定算的；排隊等待期間管理員若改了 TouchTraceEnabled 或
            -- 高容忍清單，這件物品可能已不屬於當初那個桶 → fail-closed 放掉，下一輪用新設定重判
            if item and record.bucket
                and Cleaner.isHighTolerance(ctx.highSet, item, record.fullType, ctx.stampsEnabled)
                    ~= (record.bucket == "high") then
                item = nil
            end
        end
        if item and Cleaner.isSafeFloorCandidate(item, worldObj, protectSet) then
            local dropper = Cleaner.getItemModDataValue(item, Cleaner.KEY_DROPPED) or "unknown"
            if Cleaner.removeFloorItem(item, worldObj, square) then
                -- 任何成功刪除都遞減對應 chunk cache（不分 victim scope）；否則 area victim 刪同 chunk 後，
                -- 後續 chunk record 會用到過期數量而多刪一筆（chunk→area→chunk 會 12→9，低於 limit 10）
                local ck = chunkKey(record.cx, record.cy, record.z) .. "|" .. tostring(record.bucket) .. "|" .. record.fullType
                if liveCache[ck] then
                    liveCache[ck] = liveCache[ck] - 1
                end
                -- 清理爆發跨多 tick（限速 16 件/tick）；log 與通知都累積到佇列排空時一次輸出，
                -- 避免一次爆發寫出十幾行 removed=16
                local key = hotspotKey(chunkKey(record.cx, record.cy, record.z), record.bucket, record.fullType)
                local notify = cleanNotify[key]
                if not notify then
                    notify = {
                        detail = record.fullType,
                        count = 0,
                        droppers = {},
                        x = record.cx * C.CHUNK_SIZE + C.CHUNK_SIZE / 2,
                        y = record.cy * C.CHUNK_SIZE + C.CHUNK_SIZE / 2,
                        z = record.z,
                    }
                    cleanNotify[key] = notify
                end
                notify.count = notify.count + 1
                dropper = Cleaner.sanitize(dropper)
                notify.droppers[dropper] = (notify.droppers[dropper] or 0) + 1
            end
        end
    end

    compactDeleteQueue()
    if deleteHead > #deleteQueue then
        deleteQueue = {}
        deleteHead = 1
        -- 佇列排空＝一次清理爆發結束：每熱點只寫一行 log、發一則通知
        for _, notify in pairs(cleanNotify) do
            local dropperDetails = {}
            for dropper, count in pairs(notify.droppers) do
                dropperDetails[#dropperDetails + 1] = dropper .. ":" .. count
            end
            Cleaner.sortSafe(dropperDetails, function(a, b) return a < b end)
            Cleaner.log(
                "auto_clean",
                "system",
                notify.x,
                notify.y,
                notify.z,
                "fullType=" .. Cleaner.sanitize(notify.detail)
                    .. " removed=" .. notify.count
                    .. " dropper=" .. table.concat(dropperDetails, ",")
            )
            Cleaner.notifyCleaned("items", notify.detail, notify.count, notify.x, notify.y, notify.z)
        end
        cleanNotify = {}
    end
end

local function resetDisabledState()
    scanQueue = {}
    activeJob = nil
    dirtyChunks = {}
    warned = {}
    areaWarned = {}
    deleteQueue = {}
    deleteHead = 1
    pendingDeleteIDs = {}
    periodicQueued = false
    cleanNotify = {}
end

local function onTick()
    -- LuaManager.java:9268-9273; forageServer.lua:455-471
    local now = getTimestampMs()
    if Cleaner.isFloorCleaningDisabled() then
        resetDisabledState()
        return
    end

    promoteDirtyChunks(now)
    local interval = (tonumber(Cleaner.getOption("ScanIntervalSeconds")) or Cleaner.DEFAULTS.ScanIntervalSeconds) * 1000
    if now - lastPeriodicAt >= interval then
        queuePeriodicScan(now)
    end
    consumeScanQueue(now)
    processDeleteQueue()
end

Events.OnTick.Add(onTick)
