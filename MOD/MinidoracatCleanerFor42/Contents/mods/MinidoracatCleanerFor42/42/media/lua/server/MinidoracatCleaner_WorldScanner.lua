if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner
local C = Cleaner.CONSTANTS

local scanQueue = {}
local activeJob = nil
local dirtyChunks = {}
local warned = {}
local deleteQueue = {}
local deleteHead = 1
local pendingDeleteIDs = {}
local periodicQueued = false
local lastPeriodicAt = 0
local cleanNotify = {}

local function chunkKey(cx, cy, z)
    return tostring(cx) .. "," .. tostring(cy) .. "," .. tostring(z)
end

local function hotspotKey(key, fullType)
    return key .. "|" .. fullType
end

local function makeJob(kind, chunks)
    local chunkSet = {}
    for _, chunk in ipairs(chunks) do
        chunkSet[chunkKey(chunk.cx, chunk.cy, chunk.z)] = chunk
    end
    return {
        kind = kind,
        chunks = chunks,
        chunkSet = chunkSet,
        chunkIndex = 1,
        squareIndex = 0,
        counts = {},
        regionCount = {},
        candidates = {},
        protectSet = Cleaner.getProtectMatcher(),
    }
end

function Cleaner.markDirty(square)
    if not square then
        return
    end
    if tonumber(Cleaner.getOption("MaxFloorItemsPerType")) == 0
        and tonumber(Cleaner.getOption("MaxFloorItemsPerTypeArea")) == 0 then
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
    local seen = {}
    local radius = tonumber(Cleaner.getOption("ScanRadius")) or Cleaner.DEFAULTS.ScanRadius
    for _, playerObj in ipairs(Cleaner.getActivePlayers()) do
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
                    if not seen[key] then
                        seen[key] = true
                        chunks[#chunks + 1] = { cx = cx, cy = cy, z = z }
                    end
                end
            end
        end
    end
    -- 不排序：巢狀迴圈產生的順序本來就是空間連續且確定的；且對「已接近排序」的大陣列
    -- 呼叫 Kahlua table.sort 會退化成 O(n) 遞迴深度而 stack overflow（見 Core.sortSafe 註解）
    return chunks
end

local function queuePeriodicScan(now)
    if periodicQueued then
        return
    end
    local chunks = buildPeriodicChunks()
    if #chunks == 0 then
        return
    end
    scanQueue[#scanQueue + 1] = makeJob("periodic", chunks)
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
    table.sort(ready, function(a, b) return a.key < b.key end)
    for _, entry in ipairs(ready) do
        dirtyChunks[entry.key] = nil
        scanQueue[#scanQueue + 1] = makeJob("dirty", { entry.chunk })
    end
end

local function addCandidate(job, key, fullType, item, square)
    local byType = job.candidates[key]
    if not byType then
        byType = {}
        job.candidates[key] = byType
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

local function scanSquare(job, chunk, square)
    local key = chunkKey(chunk.cx, chunk.cy, chunk.z)
    local counts = job.counts[key]
    if not counts then
        counts = {}
        job.counts[key] = counts
    end

    local worldObjects = square:getWorldObjects()
    for index = 0, worldObjects:size() - 1 do
        local worldObj = worldObjects:get(index)
        local item = worldObj and worldObj:getItem()
        local fullType = item and item:getFullType()
        if fullType then
            counts[fullType] = (counts[fullType] or 0) + 1
            if job.kind == "periodic" then
                job.regionCount[fullType] = (job.regionCount[fullType] or 0) + 1
            end
            if Cleaner.isSafeFloorCandidate(item, worldObj, job.protectSet) then
                addCandidate(job, key, fullType, item, square)
            end
        end
    end
end

local function ensureWarning(key, chunk, fullType, now)
    local record = warned[key]
    if not record then
        record = { time = now, chunk = false, area = false }
        warned[key] = record
        local x = chunk.cx * C.CHUNK_SIZE + C.CHUNK_SIZE / 2
        local y = chunk.cy * C.CHUNK_SIZE + C.CHUNK_SIZE / 2
        Cleaner.warnNearby("items", x, y, chunk.z, fullType)
        Cleaner.log("warn", "system", x, y, chunk.z, "kind=items fullType=" .. Cleaner.sanitize(fullType))
    end
    local interval = (tonumber(Cleaner.getOption("ScanIntervalSeconds")) or Cleaner.DEFAULTS.ScanIntervalSeconds) * 1000
    return now - record.time >= interval
end

local function queueVictim(record, scope, limit)
    if pendingDeleteIDs[record.id] then
        return false
    end
    pendingDeleteIDs[record.id] = true
    -- 記錄觸發 scope 與當時閾值，供 processDeleteQueue 刪除前 live recount（避免用過期數量刪到低於閾值）
    record.scope = scope
    record.limit = limit
    deleteQueue[#deleteQueue + 1] = record
    return true
end

local function selectCandidates(list, needed, selected, scope, limit)
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
            if queueVictim(record, scope, limit) then
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

local function updateWarningScopes(job, reasons)
    local stale = {}
    for key, record in pairs(warned) do
        local separator = string.find(key, "|", 1, true)
        local keyChunk = separator and string.sub(key, 1, separator - 1) or ""
        if job.chunkSet[keyChunk] then
            local reason = reasons[key]
            record.chunk = reason and reason.chunk or false
            if job.kind == "periodic" then
                record.area = reason and reason.area or false
            end
            if not record.chunk and not record.area then
                stale[#stale + 1] = key
            end
        end
    end
    for _, key in ipairs(stale) do
        warned[key] = nil
    end
end

local function finishJob(job, now)
    local maxChunk = tonumber(Cleaner.getOption("MaxFloorItemsPerType")) or Cleaner.DEFAULTS.MaxFloorItemsPerType
    local maxArea = tonumber(Cleaner.getOption("MaxFloorItemsPerTypeArea")) or Cleaner.DEFAULTS.MaxFloorItemsPerTypeArea
    local selected = {}
    local reasons = {}

    if maxChunk > 0 then
        for key, counts in pairs(job.counts) do
            local chunk = getChunk(job, key)
            for fullType, count in pairs(counts) do
                if count > maxChunk then
                    local warningKey = hotspotKey(key, fullType)
                    reasons[warningKey] = reasons[warningKey] or {}
                    reasons[warningKey].chunk = true
                    if ensureWarning(warningKey, chunk, fullType, now) then
                        local list = job.candidates[key] and job.candidates[key][fullType]
                        if list and #list > 0 then
                            selectCandidates(list, count - maxChunk, selected, "chunk", maxChunk)
                        else
                            -- 超標但無可刪候選（全部 isIgnoreRemoveSandbox/favorite/protectlist/非空容器）：記一次診斷 log
                            local record = warned[warningKey]
                            if record and not record.loggedProtected then
                                record.loggedProtected = true
                                Cleaner.log("items_protected_over", "system", chunk.cx, chunk.cy, chunk.z,
                                    "fullType=" .. Cleaner.sanitize(fullType) .. " count=" .. count .. " limit=" .. maxChunk)
                            end
                        end
                    end
                end
            end
        end
    end

    if job.kind == "periodic" and maxArea > 0 then
        for fullType, count in pairs(job.regionCount) do
            if count > maxArea then
                local regionCandidates = {}
                for key, chunkCounts in pairs(job.counts) do
                    if (chunkCounts[fullType] or 0) > 0 then
                        local chunk = getChunk(job, key)
                        local warningKey = hotspotKey(key, fullType)
                        reasons[warningKey] = reasons[warningKey] or {}
                        reasons[warningKey].area = true
                        if ensureWarning(warningKey, chunk, fullType, now) then
                            local list = job.candidates[key] and job.candidates[key][fullType]
                            if list then
                                for _, record in ipairs(list) do
                                    regionCandidates[#regionCandidates + 1] = record
                                end
                            end
                        end
                    end
                end
                selectCandidates(regionCandidates, count - maxArea, selected, "area", maxArea)
            end
        end
    end

    updateWarningScopes(job, reasons)
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

-- 重數某 chunk 內某 fullType 的現存地板物品數（帶本 tick cache）；供刪除前 recount，避免用過期快照刪到低於閾值
local function liveChunkCount(cx, cy, z, fullType, cache)
    local ck = chunkKey(cx, cy, z) .. "|" .. fullType
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
                        count = count + 1
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
    local protectSet = Cleaner.getProtectMatcher()
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
            local live = liveChunkCount(record.cx, record.cy, record.z, record.fullType, liveCache)
            overThreshold = live > (record.limit or 0)
        end

        local item, worldObj, square = nil, nil, nil
        if overThreshold then
            item, worldObj, square = findQueuedWorldItem(record)
        end
        if item and Cleaner.isSafeFloorCandidate(item, worldObj, protectSet) then
            local dropper = Cleaner.getItemModDataValue(item, Cleaner.KEY_DROPPED) or "unknown"
            if Cleaner.removeFloorItem(item, worldObj, square) then
                -- 任何成功刪除都遞減對應 chunk cache（不分 victim scope）；否則 area victim 刪同 chunk 後，
                -- 後續 chunk record 會用到過期數量而多刪一筆（chunk→area→chunk 會 12→9，低於 limit 10）
                local ck = chunkKey(record.cx, record.cy, record.z) .. "|" .. record.fullType
                if liveCache[ck] then
                    liveCache[ck] = liveCache[ck] - 1
                end
                -- 清理爆發跨多 tick（限速 16 件/tick）；log 與通知都累積到佇列排空時一次輸出，
                -- 避免一次爆發寫出十幾行 removed=16
                local key = hotspotKey(chunkKey(record.cx, record.cy, record.z), record.fullType)
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
            table.sort(dropperDetails)
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
    deleteQueue = {}
    deleteHead = 1
    pendingDeleteIDs = {}
    periodicQueued = false
    cleanNotify = {}
end

local function onTick()
    -- LuaManager.java:9268-9273; forageServer.lua:455-471
    local now = getTimestampMs()
    local maxChunk = tonumber(Cleaner.getOption("MaxFloorItemsPerType")) or 0
    local maxArea = tonumber(Cleaner.getOption("MaxFloorItemsPerTypeArea")) or 0
    if maxChunk == 0 and maxArea == 0 then
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
