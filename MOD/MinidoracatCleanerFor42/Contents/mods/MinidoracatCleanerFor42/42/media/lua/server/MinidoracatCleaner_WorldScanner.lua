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
-- items_area_unprovable 的節流：key = username（基數有上限＝玩家數，ServerOptions.java:30 的
-- MAX_PLAYERS 是 254，但那只限制**同時在線**）。只綁在 areaWarned 記錄上不夠——玩家可以同時製造多種稀疏超標型別，
-- 也可以走到空區讓記錄被回收、再回來重建，兩條路都能繞過「每筆記錄一次」而洪水寫檔。
-- 表本身在寫入時會清掉過了節流間隔的 key（username 基數不由在線人數封頂）
-- （ZLogger 超過 10MB 是原檔截斷而非輪替，會沖掉同一份 log 裡的真證據）
local unprovableLogAt = {}
local deleteQueue = {}
local deleteHead = 1
local pendingDeleteIDs = {}
local periodicQueued = false
local lastPeriodicAt = 0
local cleanNotify = {}
-- 單調遞增的 tick 序號：用來讓「正在掃的 chunk 每個 tick 重查一次載入狀態」只做一次
local tickSeq = 0
-- 上一個 tick 是否處於「清理已停用」：只用來讓 resetDisabledState 在 啟用→停用 的那一個
-- tick 跑一次。它重建好幾張表，而 Kahlua 的每張表都是獨立的 KahluaTableImpl／LinkedHashMap
-- （J2SEPlatform.java:35、KahluaTableImpl.java:18），每個 tick 重建等於讓「已經關掉的功能」
-- 持續製造短命配置。新增的 ItemCleanupEnabled 讓這條路徑從「手改四個整數上限」變成一次點擊
local cleaningDisabled = false

local function chunkKey(cx, cy, z)
    return tostring(cx) .. "," .. tostring(cy) .. "," .. tostring(z)
end

-- chunkKey 的反解析，供 processDeleteQueue 重數 area 範圍時取回座標（那時 job 已結束、
-- 拿不到 chunk 物件）。存 key 字串而不是每個來源各配一個座標 table，是為了不讓
-- areaChunks 的配置量隨來源區塊數放大（AGENTS.md：小 table 要有上限）
local function parseChunkKey(key)
    local cx, cy, cz = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
    if not cx then
        return nil
    end
    return tonumber(cx), tonumber(cy), tonumber(cz)
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
        -- 候選配置的兜底額度（per-type 上限見 addCandidate）。掛在 job 上是刻意的：它要涵蓋
        -- 整份掃描工作，而不是每個 tick 重置——重置的話「每 tick 都能再配 20000 筆」等於沒有上限
        candidateBudget = C.CANDIDATES_PER_JOB,
        buckets = buckets,
        players = players,
        protectSet = Cleaner.getProtectMatcher(),
        -- 容器 overlay 表是引擎單例，整輪掃描期間都是同一個物件：Lua 全域 getContainerOverlays()
        -- 固定回 ContainerOverlays.instance（LuaManager.java:11976-11982），而那是
        -- public static final（ContainerOverlays.java:20）。所以在 job 上存這個參照
        -- 8-46 分鐘是安全的，不會拿到過期副本。
        -- 提上來的收益：repairBrokenContainers 每格都要用它，原本每格取一次＝每 tick 多
        -- SQUARES_PER_TICK（48）次 Kahlua→Java 往返，現在整份工作只取一次。
        -- （省下的僅此一項；該函式仍要走完 square:getObjects() 回傳的全部 IsoObject，
        -- 那是該格的地板／牆／家具全體，IsoGridSquare.java:9635-9637）
        overlays = getContainerOverlays(),
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

-- 週期掃描的區塊清單**漸進建構**，不一次建完。
--
-- 為什麼：每位玩家 ScanRadius 80 就是 21×21＝441 個區塊，站在 z≠0 時兩層共 882 個（半徑拉到
-- 最大 128 時是 2178 個），而每個區塊都要配一張 table。這筆配置量是
-- #玩家 ×(2×ScanRadius/8+1)²×樓層數——由在線人數與沙盒半徑決定，與地圖大小或已載入
-- 區塊數無關。一次做完就是把「單一 tick 要配多少」交給沙盒設定決定，所以分批、
-- 由我們封頂配置速率。注意封的是**速率**：總量仍是上面那個式子，本次沒有改動它
--
-- **這是理論風險的封頂，不是實測到的熱點。** GameProfiler 只能量到整個 WorldScanner
-- callback（Event.java:34,55 的 span 名稱只有 "Lua - OnTick"，不含檔名或函式），無法隔離
-- 建構本身；改前後的 server 對照也沒量到可證明的差異，尖峰成因至今未定位。
--
-- 這裡只記下每位玩家的**範圍描述**，實際的 table 由 stepPeriodicBuild 每 tick 建一批。
-- 建構期間不掃描：掃描要靠完整的 chunkSet 判斷區塊歸屬（chunkOwnedBy），半成品會讓
-- 歸屬判定看到不完整的 owners 而誤判。
local function newPeriodicBuild(players)
    local radius = tonumber(Cleaner.getOption("ScanRadius")) or Cleaner.DEFAULTS.ScanRadius
    local ranges = {}
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
        ranges[#ranges + 1] = {
            owner = playerIndex,
            minCX = minCX,
            minCY = minCY,
            width = maxCX - minCX + 1,
            height = maxCY - minCY + 1,
            levels = levels,
        }
    end
    -- linear 是「當前玩家範圍內的第幾格」，用單一整數就能跨 tick 續傳——Kahlua 沒有 next()，
    -- pairs 的迭代狀態帶不過 tick 邊界。
    -- 去重不另建表：job.chunkSet 本來就是 key→chunk 映射（makeJob 以空 chunks 初始化，
    -- 故建構開始時是空的），拿它當去重表語意完全相同，省下一張與區塊數同階的表
    return { ranges = ranges, rangePos = 1, linear = 0 }
end

-- 建一批區塊；回傳是否已全部建完。
-- 區塊仍去重（玩家聚集時不重複掃描），但記下它屬於哪幾位玩家的區域，供 regionCount 分開累計。
-- 同一玩家同一 key 只會被走到一次（線性展開對每個 (玩家, z, cy, cx) 各一次，z 不重複）
local function stepPeriodicBuild(job, budget)
    local build = job.build
    local built = 0
    while built < budget do
        local range = build.ranges[build.rangePos]
        if not range then
            job.build = nil
            return true
        end
        local perLevel = range.width * range.height
        local total = perLevel * #range.levels
        if build.linear >= total then
            build.rangePos = build.rangePos + 1
            build.linear = 0
        else
            local offset = build.linear
            local levelIndex = math.floor(offset / perLevel) + 1
            local withinLevel = offset % perLevel
            local cx = range.minCX + (withinLevel % range.width)
            local cy = range.minCY + math.floor(withinLevel / range.width)
            local z = range.levels[levelIndex]
            local key = chunkKey(cx, cy, z)
            local chunk = job.chunkSet[key]
            if not chunk then
                chunk = { cx = cx, cy = cy, z = z, owners = {} }
                job.chunks[#job.chunks + 1] = chunk
                job.chunkSet[key] = chunk
            end
            chunk.owners[#chunk.owners + 1] = range.owner
            build.linear = build.linear + 1
            built = built + 1
        end
    end
    return false
end

local function queuePeriodicScan(now)
    if periodicQueued then
        return
    end
    local players = Cleaner.getActivePlayers()
    if #players == 0 then
        -- 無人在線時不會有 periodic job，也就不會跑到 finishJob 的 area prune，
        -- 記錄會殘留到下一批玩家上線；在這裡直接清空
        areaWarned = {}
        return
    end
    -- chunks 先給空表，由 stepPeriodicBuild 每 tick 填一批（見那裡的說明）
    local job = makeJob("periodic", {}, players)
    job.build = newPeriodicBuild(players)
    scanQueue[#scanQueue + 1] = job
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

-- 每個 (chunk, fullType) 的候選清單是**依 item ID 降冪的 bounded top-N**，不是無界 list：
-- 每個安全物品都要配一筆 7 欄 table，而 Kahlua 的每張表都是獨立的 KahluaTableImpl／
-- LinkedHashMap（本專案實測 10 萬筆三欄 record 約 35 MiB），所以「每物件一張表」必須有上限，
-- 且上限要綁我們自己的處理量、不能綁世界內容量（AGENTS.md 明文）。走訪額度封頂的是 CPU，
-- 沒有這道的話單格堆十萬件仍會在記憶體上炸開。
--
-- 為什麼是 per (chunk, fullType) 而不是單一個全域額度：addCandidate 對**每一件**安全地板物品
-- 都會呼叫，不管那一塊有沒有超標。共用一份額度的話，沿路的零星垃圾會先把它吃光，而掃描順序
-- 是固定的 chunkIndex/squareIndex 遞增 ⇒ 每一輪都在同一個位置耗盡 ⇒ 掃描盒後段的熱點永遠
-- 拿不到候選（還會被記成 items_protected_over 而誤導管理員說「全部受保護」）。
--
-- 為什麼是 top-N by item ID 而不是先到先得：先到先得留下的是**最舊**的那些，跟「最新的堆先刪」
-- 政策正好相反（遞增的 item ID 近似落地順序；worldObj.dropTime 是 instance field，Kahlua 不暴露）。
-- 清單維持降冪，所以尾端就是目前最舊的一筆，滿了之後只有更新的才值得換掉它——換的時候覆寫
-- 欄位、不配新 table
local function addCandidate(job, bucket, key, fullType, item, square)
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
    -- 這份清單是「保留 item ID 最大的 N 筆」的 **min-heap**（root 是目前最舊的一筆），不是
    -- 有序陣列：掉落 ID 幾乎總是遞增，維持降冪的話每來一件都要從榜尾搬到榜首，單筆成本
    -- O(N)；單 tick 最多走訪 SCAN_ITEM_VISITS_PER_TICK 件，於是 512×512≈26 萬次 table 指派，
    -- CPU 額度就不再代表真實成本了。heap 的插入／替換是 O(log N)≈9。
    -- 不需要維持完整順序，因為 selectCandidates 之後會依「整堆整堆刪」政策重新排一次
    local id = item:getID()
    local n = #list
    local slot
    if n >= C.CANDIDATES_PER_TYPE then
        -- 滿了：只有比目前最舊的那筆更新才值得留下
        if id <= list[1].id then
            return
        end
        slot = list[1]
    elseif job.candidateBudget <= 0 then
        -- job 層的兜底上限：每組各有自己的額度，總量仍會隨「超標組合數」成長，這道是純 DoS 防線
        return
    else
        job.candidateBudget = job.candidateBudget - 1
        slot = {}
        n = n + 1
        list[n] = slot
    end
    slot.id = id
    slot.fullType = fullType
    slot.x = square:getX()
    slot.y = square:getY()
    slot.z = square:getZ()
    slot.cx = math.floor(square:getX() / C.CHUNK_SIZE)
    slot.cy = math.floor(square:getY() / C.CHUNK_SIZE)
    if slot == list[1] and n > 1 then
        -- 覆寫了 root：往下沉到正確位置
        local i = 1
        while true do
            local left, right = i * 2, i * 2 + 1
            local small = i
            if left <= n and list[left].id < list[small].id then
                small = left
            end
            if right <= n and list[right].id < list[small].id then
                small = right
            end
            if small == i then
                break
            end
            list[i], list[small] = list[small], list[i]
            i = small
        end
    else
        -- 新加在尾端：往上浮到正確位置。
        -- 注意這段在實務上幾乎是 no-op：item ID 由引擎遞增發放，同一格的掉落順序就是 ID 順序，
        -- 新元素本來就該落在葉節點。停用它在煙霧測試裡也不會有任何斷言變紅（fixture 的 ID
        -- 必定遞增），所以這不是「缺測試」而是「該分支在遞增輸入下不可觸發」。
        -- 留著是因為 heap 的正確性不該依賴輸入順序——candidates 的來源若哪天不只掃描一條路，
        -- 沒有它 root 就不再是最舊的那筆，替換決策會失準
        local i = n
        while i > 1 do
            local parent = math.floor(i / 2)
            if list[parent].id <= list[i].id then
                break
            end
            list[parent], list[i] = list[i], list[parent]
            i = parent
        end
    end
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
    local overlays = job.overlays
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

-- visits 是**單 tick** 的地板物件走訪額度（`{ left = n }`，由 consumeScanQueue 每 tick 重建），
-- 不是每格的上限。回傳這一格是否已走完：沒走完時把格內位置記在 job.itemOffset，下一個 tick
-- 從那裡接著走（呼叫端不前進 squareIndex），所以計數仍然精確、只是攤到多個 tick。
-- 為什麼不能只靠 SQUARES_PER_TICK：那只封頂格數，單一格子的 worldObjects 沒有容量上限
-- （IsoGridSquare.java:319，掉落時直接 append、getter 原樣回傳 :9947-9949），十萬件堆在一格
-- 時「每格完整走一遍」還是一個 tick 全走完。
-- 為什麼不改成「觸頂就略過該格剩下的」：那會讓那些物品永遠不被計數（每輪都在同一處觸頂），
-- 清理對單格大量堆積完全失效——而那正是最需要清理的形狀
local function scanSquare(job, chunk, square, visits)
    repairBrokenContainers(job, square)
    local key = chunkKey(chunk.cx, chunk.cy, chunk.z)
    local worldObjects = square:getWorldObjects()
    local total = worldObjects:size()
    local start = job.itemOffset or 0
    local limit = total - start
    if limit > visits.left then
        limit = visits.left
    end
    if limit < 0 then
        limit = 0
    end
    visits.left = visits.left - limit
    for index = start, start + limit - 1 do
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
                addCandidate(job, bucket, key, fullType, item, square)
            end
        end
    end
    if start + limit < total then
        job.itemOffset = start + limit
        return false
    end
    job.itemOffset = nil
    return true
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
        record = { time = now, lastSeen = now }
        areaWarned[key] = record
        local x, y, z = playerObj:getX(), playerObj:getY(), playerObj:getZ()
        Cleaner.warnPlayerOnly(playerObj, "items", fullType, count, limit)
        Cleaner.log("warn", playerObj:getUsername(), x, y, z,
            "kind=items scope=area fullType=" .. Cleaner.sanitize(fullType)
                .. " count=" .. count .. " limit=" .. limit)
    end
    return now - record.time >= warnInterval()
end

local function queueVictim(record, scope, bucketName, areaChunks)
    if pendingDeleteIDs[record.id] then
        return false
    end
    -- 佇列自己要有天花板：掃描每 tick 最多產生 SCAN_ITEM_VISITS_PER_TICK 個候選，而
    -- processDeleteQueue 每 tick 只消化 ITEMS_PER_TICK 個——生產可以比消化快 32 倍
    -- （多個 dirty job 連續進來時更明顯），沒有上限的話 deleteQueue 與 pendingDeleteIDs 會
    -- 一起無界成長。觸頂就停止排入，沒排到的下一輪重新掃到時再排
    if #deleteQueue - deleteHead + 1 >= C.MAX_PENDING_DELETES then
        return false
    end
    pendingDeleteIDs[record.id] = true
    -- 記錄觸發 scope 與所屬桶，供 processDeleteQueue 刪除前 live recount（避免用過期數量刪到
    -- 低於閾值；recount 必須只數同一個桶的物品）。**不記當時的閾值**：管理員可在執行期改
    -- sandbox，刪除前要讀當前值，記下來的舊值只會讓我們照過期政策刪東西
    record.scope = scope
    record.bucket = bucketName
    -- area victim 另外帶上 recount 要重數的來源區塊集：area 的閾值是跨區塊的總數，只重數
    -- victim 自己那一塊不等於同一個 scope。這個集合在排入時已依計數降冪截到
    -- AREA_RECOUNT_CHUNKS_PER_TICK 塊，所以單件走訪量天生有界。
    -- chunk victim 用不到（liveChunkCount 就是數自己那塊），維持 nil
    record.areaChunks = areaChunks
    deleteQueue[#deleteQueue + 1] = record
    return true
end

local function selectCandidates(list, needed, selected, scope, bucketName, areaChunks)
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
            if queueVictim(record, scope, bucketName, areaChunks) then
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

-- 本次**確實完整觀測到**的區塊依 reasons 判定去留（沒列進去＝已回到上限內）；沒觀測到的
-- 區塊——玩家已離開、區塊已卸載、之後可能永遠不會再被掃到——則用閒置年齡回收，避免記錄
-- 隨探索範圍無界成長。
--
-- 「在 chunkSet 內」不等於「數過了」：job.chunks 是建立當下依玩家位置算出的快照，而一輪要
-- 8-46 分鐘（正式服實測）才輪到其中某個 chunk，掃到時玩家可能早已走遠使區塊卸載，
-- getGridSquare 全數回 nil（Lua 端走 IsoCell.java:3181-3183 分派：dedicated server 進
-- ServerMap.java:682-687，單機進 IsoCell.java:3197-3206）→ 該 chunk 的 counts 為空 → 不進
-- reasons。舊版把這種「一格都沒看到」當成「已回到上限內」直接刪掉記錄，使確認計時歸零；
-- 每輪都恰好在確認前卸載的區塊，就永遠等不到 ensureWarning 的「第二次仍超標」。
--
-- observed 的判準是 consumeScanQueue 每個 tick 對 active chunk 重查一次
-- getChunkForGridSquare（見那裡的說明），不是「至少數到一格」——後者在「掃描跨 tick、
-- 中途卸載」時會讓低估的 counts 帶著「已觀測」溜過去。
--
-- **已知限制**：導向閒置分支並沒有讓記錄免於老化——lastSeen 只在「完整觀測且仍超標」時
-- 刷新（見下方 reasons 分支），故未觀測記錄的年齡是「自上次超標觀測的那一次 finishJob 到
-- 本次 finishJob 的經過時間」，其中除了掃描本身，還含排隊等待（dirty job 插在前面）與
-- 週期間隔。staleMs＝ScanIntervalSeconds × WARN_STALE_INTERVALS（預設 60s×20＝20 分鐘）
-- 小於實測輪次上界 46 分鐘，因此長輪次的伺服器上記錄仍會在同一次 finishJob 被當成閒置
-- 回收、計時仍然歸零。（未載入區塊改為整塊跳過後一輪約省 18% 的格數走訪，輪次會縮短，
-- 但人多時仍以小時計。）要把兩端都封住，門檻得綁「連續未觀測的輪數」而不是壁鐘時間，
-- 或至少大於最大的 finishJob 間隔（不只是最長掃描耗時）；那是獨立的設計取捨，不在本次
-- 改動範圍內。
local function pruneChunkWarnings(job, reasons, now)
    local staleMs = warnInterval() * C.WARN_STALE_INTERVALS
    local stale = {}
    for key, record in pairs(warned) do
        local separator = string.find(key, "|", 1, true)
        local keyChunk = separator and string.sub(key, 1, separator - 1) or ""
        local chunk = job.chunkSet[keyChunk]
        if chunk and chunk.observed == true then
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
                                selectCandidates(list, count - maxChunk, selected, "chunk", bucketName)
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
                    -- 該玩家擁有的區塊清單只建一次：否則「每位玩家 × 每種超標物品」都得重掃
                    -- 整份 counts，人多時是一次性尖峰。本輪只要有 fullType 超標就會用到它
                    -- （下面的貢獻清單需要），故不再延後到挑候選時才建
                    local ownerKeys = nil
                    for fullType, count in pairs(counts) do
                        if count > maxArea then
                            local warningKey = areaWarnKey(playerObj, bucketName, fullType)
                            areaReasons[warningKey] = true
                            local confirmed =
                                ensureAreaWarning(warningKey, playerObj, fullType, count, maxArea, now)
                            if not ownerKeys then
                                ownerKeys = {}
                                for key in pairs(bucket.counts) do
                                    if chunkOwnedBy(getChunk(job, key), ownerIndex) then
                                        ownerKeys[#ownerKeys + 1] = key
                                    end
                                end
                            end
                            -- 記下這筆 area 計數是由哪些區塊貢獻的，供下面的回收判定分辨
                            -- 「總數掉到門檻以下」是真的被清掉、還是有來源區塊本輪沒被觀測到。
                            --
                            -- 是**合併**不是覆寫：本輪沒觀測到的來源不會出現在 bucket.counts 裡，
                            -- 直接覆寫就會把它忘掉。忘掉的後果可重現——六個區塊各 9 件（真實 54）、
                            -- 其中一個卸載後仍觀測到 45 > 40 而觸發清理，清完可見的 5 件之後下一輪
                            -- 觀測到 40 不再超標，若清單已丟掉那個卸載來源就會判成「已解決」而刪除
                            -- 記錄，可是真實總數還有 49。
                            -- 只有「本輪完整觀測到、卻沒有這個 fullType 的計數」才是真的清空可移除；
                            -- 已經離開本輪掃描盒的來源（玩家走遠）也移除，避免清單無界成長
                            local record = areaWarned[warningKey]
                            local contributing = {}
                            if record.chunks then
                                for ck in pairs(record.chunks) do
                                    local prev = job.chunkSet[ck]
                                    -- 必須同時仍屬於**這位玩家**的區域：area 記錄是 per-player 的。
                                    -- 少了 chunkOwnedBy 這道，玩家搬家後舊來源只要落在別人掃描盒的
                                    -- 外圈（在 chunkSet 內但永遠載不到），就會被永久併進他的來源集，
                                    -- 讓 underCounted 恆真 ⇒ 記錄永遠不會在達標輪被回收 ⇒ 下次超標時
                                    -- 直接沿用舊記錄清理、不再給玩家警告。（讀不到的來源本身不擋刪除，
                                    -- 因為 recount 用的是下界；這道 guard 守的是記錄能不能收斂）
                                    if prev and chunkOwnedBy(prev, ownerIndex) and prev.observed ~= true then
                                        contributing[ck] = true
                                    end
                                end
                            end
                            for _, key in ipairs(ownerKeys) do
                                if bucket.counts[key][fullType] then
                                    contributing[key] = true
                                end
                            end
                            record.chunks = contributing
                            if confirmed then
                                -- victim 帶的來源集要**依計數降冪取前 N 塊**，不是整份 contributing：
                                -- ① recount 用下界，取計數最高的幾塊能讓「下界超過上限」最快成立，
                                --    提早退出的命中率最大化；
                                -- ② 走訪量因此天生就 ≤ N，不必在 recount 裡另設單件上限；
                                -- ③ 結果不再取決於 pairs 的走訪順序（Kahlua 是插入序、標準 Lua 是
                                --    帶隨機種子的雜湊序），同一個熱區不會「有時清得掉有時清不掉」。
                                -- 若前 N 塊的計數和已經 ≤ 上限，就代表無論怎麼取都湊不出足以證明超標的
                                -- 下界 ⇒ **整批不排入**。少了這一刀，每一輪都會排入註定全部被 recount
                                -- 取消的 victim（record.time 建立後不更新 ⇒ confirmed 恆真），形成
                                -- 淨產出為零卻持續佔用掃描預算的永久負載——正好和本 MOD 的目的相反。
                                --
                                -- 選 top-N 用「插入進兩個固定長度 ≤ N 的平行陣列」，**不是**先為每塊
                                -- 配一個 {key,n} 再排序整份：ScanRadius 最大 128 ⇒ 單一玩家單層 33×33
                                -- ＝1089 塊、站在 z≠0 時兩層共 2178 塊，而這段是 per player × bucket ×
                                -- 超標 fullType 的。引擎玩家上限是 254（ServerOptions.java:30,73），
                                -- 「每塊一個小 table」在最壞情況要配上百萬個 KahluaTableImpl／
                                -- LinkedHashMap（本專案實測 10 萬筆三欄 record 約 35 MiB）。
                                -- 這裡的配置量固定是兩個 ≤N 的陣列，與世界內容量無關
                                local topKeys, topCounts, topLen = {}, {}, 0
                                local provable = 0
                                local sourceCount = 0
                                for ck in pairs(contributing) do
                                    sourceCount = sourceCount + 1
                                    local byType = bucket.counts[ck]
                                    local n = (byType and byType[fullType]) or 0
                                    local dropped = nil
                                    if topLen < C.AREA_RECOUNT_CHUNKS_PER_TICK then
                                        topLen = topLen + 1
                                    elseif n > topCounts[topLen] then
                                        dropped = topCounts[topLen]
                                    else
                                        n = nil
                                    end
                                    if n then
                                        -- 線性插入：N 是 32，比配置整份再排序便宜，且不配任何新 table
                                        local pos = topLen
                                        while pos > 1 and topCounts[pos - 1] < n do
                                            topKeys[pos] = topKeys[pos - 1]
                                            topCounts[pos] = topCounts[pos - 1]
                                            pos = pos - 1
                                        end
                                        topKeys[pos] = ck
                                        topCounts[pos] = n
                                        provable = provable + n - (dropped or 0)
                                    end
                                end
                                local recountSources = {}
                                for index = 1, topLen do
                                    recountSources[topKeys[index]] = true
                                end
                                if provable > maxArea then
                                    -- 候選仍取**全區**：安全性由 recount 的前綴下界保證（見下方
                                    -- 論證），與 victim 落在哪一塊無關。曾經把候選限制在 recountSources
                                    -- 內，那會讓 selectCandidates 的「最新堆先刪」政策失效——依 item ID
                                    -- 降序挑選的前提是候選涵蓋全區，先被密度 top-32 過濾掉就不是同一個政策
                                    local regionCandidates = {}
                                    for _, key in ipairs(ownerKeys) do
                                        local list = bucket.candidates[key] and bucket.candidates[key][fullType]
                                        if list then
                                            for _, candidate in ipairs(list) do
                                                regionCandidates[#regionCandidates + 1] = candidate
                                            end
                                        end
                                    end
                                    -- 額度用 provable 而不是全區 count。這**不是**安全性所需——刪到低於
                                    -- 上限由 recount 的前綴下界擋住（實測把它換回 count 沒有任何斷言變紅）。
                                    -- 換口徑的價值是效率：用全區 count 會多排 count - provable 件註定被
                                    -- 否決的 victim，每件都要先付一次 recount 走訪才被丟掉
                                    selectCandidates(regionCandidates, provable - maxArea, selected, "area", bucketName, recountSources)
                                    -- 旗標要能翻回來：清理會把分佈攤平（候選取全區、依最新 ID 排序，
                                    -- 不保證優先清最密的塊），所以熱點可能在下一輪變成「證明不了」。
                                    -- 只設不清會讓那次靜默無日誌，管理員看到的仍是「上限失效」。
                                    -- 翻轉需要跨輪的分佈變化，不會洗檔
                                    record.loggedUnprovable = nil
                                elseif not record.loggedUnprovable then
                                    -- 超標但「證明不了」：管理員需要知道這件事，否則 area 上限看起來
                                    -- 就是靜默失效（chunk scope 有 items_protected_over，這是 area 的
                                    -- 對應診斷）。
                                    -- 兩層節流：記錄層（同一個 episode 只記一次）＋ 玩家層（同一位
                                    -- 玩家至少間隔 UNPROVABLE_LOG_INTERVAL_MS）。只有記錄層的話，
                                    -- 同時製造多種稀疏超標型別、或走遠讓記錄被回收再回來重建，
                                    -- 都能繞過而洪水寫檔
                                    record.loggedUnprovable = true
                                    local who = playerObj:getUsername()
                                    local lastAt = unprovableLogAt[who]
                                    if not lastAt or now - lastAt >= C.UNPROVABLE_LOG_INTERVAL_MS then
                                        -- 順手清掉過了節流間隔的舊 key。username 的基數**不是**
                                        -- 由同時在線人數封頂的（MAX_PLAYERS 254 只限制同時在線），
                                        -- 伺服器長期運行會先後出現無限多個名字 ⇒ 不清就是一張無界表。
                                        -- 過期的 key 對節流判定已無作用，刪掉不影響行為。
                                        -- 先收集再刪：Kahlua 的 table 底層是 LinkedHashMap，
                                        -- 邊迭代邊改不保證安全
                                        local expired = nil
                                        for name, at in pairs(unprovableLogAt) do
                                            if now - at >= C.UNPROVABLE_LOG_INTERVAL_MS then
                                                expired = expired or {}
                                                expired[#expired + 1] = name
                                            end
                                        end
                                        if expired then
                                            for _, name in ipairs(expired) do
                                                unprovableLogAt[name] = nil
                                            end
                                        end
                                        unprovableLogAt[who] = now
                                        local px, py, pz = playerObj:getX(), playerObj:getY(), playerObj:getZ()
                                        Cleaner.log("items_area_unprovable", who, px, py, pz,
                                            "bucket=" .. bucketName .. " fullType=" .. Cleaner.sanitize(fullType)
                                                .. " count=" .. count .. " limit=" .. maxArea
                                                .. " sources=" .. sourceCount .. " top" .. C.AREA_RECOUNT_CHUNKS_PER_TICK
                                                .. "=" .. provable)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 沒出現在本輪 areaReasons 的記錄有三種成因：① 真的回到上限內 ② 該玩家已離線
    -- ③ 計數來源裡有區塊本輪沒被觀測到（區塊卸載）使總數低估。第三種不能當已解決——
    -- 舊版把三者一律刪除，於是玩家一走遠讓部分區塊卸載，area 警告就被清掉、確認計時歸零。
    --
    -- 判定只看**這筆記錄的計數來源**（record.chunks），不是「區域內所有區塊」：後者幾乎恆為
    -- 真，因為區域通常含載不到的區塊——掃描盒（ScanRadius 80 → 21×21 區塊，168 格寬）大於
    -- 單機／自架主機的載入視窗（chunkGridWidth 13~19 → 104~152 格，IsoChunkMap.java:60,107-120；
    -- dedicated server 則按 64×64 的 ServerCell 整塊載入，ServerMap.java:225,260-269，覆蓋範圍
    -- 未必小於掃描盒），而玩家站在 z≠0 時 newPeriodicBuild 會把整層都排進來，露天區塊的
    -- min/maxLevel 是 int 預設 0（IsoChunk.java:146-147）且只在真的放進該層 square 時才擴展
    -- （:3084），故整層一律回 null（:3155-3159）。從未貢獻過計數的區塊不會進 record.chunks，
    -- 判定因此只對真正的「來源消失」成立。
    -- 未觀測的記錄改用與 chunk-scope 相同的閒置年齡上限收尾（上面那條 staleMs 已知限制在此
    -- 一併適用）：既不誤判已解決，也不會無界滯留
    if job.kind == "periodic" then
        local staleMs = warnInterval() * C.WARN_STALE_INTERVALS
        local staleArea = {}
        for key, record in pairs(areaWarned) do
            if areaReasons[key] then
                record.lastSeen = now
            else
                local underCounted = false
                if record.chunks then
                    for ck in pairs(record.chunks) do
                        local chunk = job.chunkSet[ck]
                        if chunk and chunk.observed ~= true then
                            underCounted = true
                            break
                        end
                    end
                end
                if not underCounted or now - (record.lastSeen or record.time) > staleMs then
                    staleArea[#staleArea + 1] = key
                end
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
    -- 地板物件走訪的單 tick 額度。用區域 table 而不是掛在 job 上：這個函式**每個 tick 呼叫一次**，
    -- 所以額度隨函式進入自然重建；同一個 tick 內切換到下一個掃描工作時仍共用同一份，
    -- 因為要封頂的是「這一個 tick 做了多少事」，不是「每個工作各自能做多少事」
    local visits = { left = C.SCAN_ITEM_VISITS_PER_TICK }
    while budget > 0 do
        if not activeJob then
            activeJob = table.remove(scanQueue, 1)
            if not activeJob then
                return
            end
        end

        -- 週期掃描的區塊清單還沒建完：這個 tick 只建一批就收工。建構期間不掃描，因為
        -- chunkOwnedBy 要看完整的 owners（半成品會誤判歸屬）；441~882 個區塊在
        -- CHUNKS_PER_TICK=128 之下是 4~7 個 tick
        if activeJob.build then
            if not stepPeriodicBuild(activeJob, C.CHUNKS_PER_TICK) then
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
            -- 每個 tick 對正在掃的 chunk 重查一次載入狀態。一個 chunk 有 64 格而每 tick 預算
            -- 只有 SQUARES_PER_TICK（48），單一 chunk 的掃描必定跨 tick，只在起頭查一次擋不住
            -- 中途卸載（前段有值、後段全 nil，counts 就是低估值）。
            -- getChunkForGridSquare 是 IsoCell 的 public instance method（IsoCell.java:332-356）：
            -- Kahlua 對 Java 物件暴露所有 public 非 static method，@LuaMethod 只用於註冊**全域**
            -- 函式，所以不必在那裡找它（本檔既有的 getCell():getGridSquare 也是同一條路）。
            -- 參數是 world-square 座標；dedicated server 分派 ServerMap.instance.getChunk（:334
            -- → ServerMap.java:669，cell 未載入或該 IsoChunk 為 null 時回 null），單機走每位
            -- 玩家的 chunkMap 視窗、全部落空才回 null（:336-354）。
            -- observed 一旦判為 false 就不再翻回 true——中途漏掉的那幾格補不回來
            if chunk.checkedTick ~= tickSeq then
                chunk.checkedTick = tickSeq
                local loaded = getCell():getChunkForGridSquare(
                    chunk.cx * C.CHUNK_SIZE, chunk.cy * C.CHUNK_SIZE, chunk.z) ~= nil
                if not loaded then
                    chunk.observed = false
                elseif chunk.observed == nil then
                    chunk.observed = true
                end
            end
            if chunk.observed == false then
                -- 本輪這塊沒有全程載入：整塊跳過，省掉 64 次必定回 nil 的 getGridSquare。
                -- 掃描盒（ScanRadius 80 → 168 格寬）比引擎載入視窗大一圈，外圈區塊每輪都會走到
                -- 這裡，所以這條同時是效能改善。仍扣一格預算，避免單一 tick 把整個 job 的
                -- 未載入區塊一次走完
                activeJob.squareIndex = 0
                activeJob.itemOffset = nil
                activeJob.chunkIndex = activeJob.chunkIndex + 1
                budget = budget - 1
            else
                local offset = activeJob.squareIndex
                local x = chunk.cx * C.CHUNK_SIZE + (offset % C.CHUNK_SIZE)
                local y = chunk.cy * C.CHUNK_SIZE + math.floor(offset / C.CHUNK_SIZE)
                local square = getCell():getGridSquare(x, y, chunk.z)
                local finished = true
                if square then
                    finished = scanSquare(activeJob, chunk, square, visits)
                else
                    activeJob.itemOffset = nil
                end
                if not finished then
                    -- 這一格還沒走完（物件額度用完）：**不前進** squareIndex，下一個 tick 從
                    -- job.itemOffset 記住的位置接著走。前進的話該格剩下的物件永遠不會被計數
                    return
                end
                activeJob.squareIndex = activeJob.squareIndex + 1
                if activeJob.squareIndex >= C.CHUNK_SIZE * C.CHUNK_SIZE then
                    activeJob.squareIndex = 0
                    activeJob.chunkIndex = activeJob.chunkIndex + 1
                end
                budget = budget - 1
                if visits.left <= 0 then
                    -- 物件額度用完：本 tick 收工。這一格是完整走完的，所以 itemOffset 已清
                    return
                end
            end
        end
    end
end

-- visits 是 find 專屬的單 tick 走訪額度，與 recount 的分開：共用一份的話 recount 恰好用完
-- 就會讓這裡永遠拿不到額度、victim 全被放掉。觸頂當成找不到（下一輪會重新排）。
--
-- **反向掃**不是風格選擇：候選依 item ID 由大到小挑（見 selectCandidates），而掉落物是 append
-- 進 worldObjects 的（IsoGridSquare.java:319），所以 victim 幾乎總在尾端。正向掃在「單格堆了
-- 數萬件」時每輪都在前段觸頂、永遠找不到 victim ⇒ 加額度反而讓清理在最需要它的場景失活
local function findQueuedWorldItem(record, visits)
    local square = getCell():getGridSquare(record.x, record.y, record.z)
    if not square then
        return nil, nil, nil
    end
    local worldObjects = square:getWorldObjects()
    local index = worldObjects:size() - 1
    while index >= 0 and visits.left > 0 do
        visits.left = visits.left - 1
        local worldObj = worldObjects:get(index)
        local item = worldObj and worldObj:getItem()
        if item and item:getID() == record.id and item:getFullType() == record.fullType then
            return item, worldObj, square
        end
        index = index - 1
    end
    return nil, nil, square
end

-- 重數某 chunk 內某 fullType、**且屬於同一個計數桶**的現存地板物品數（帶本 tick cache）；
-- 供刪除前 recount，避免用過期快照刪到低於閾值。必須依桶過濾——否則 normal 桶的受害者
-- 會把世界原生那些一起數進來，recount 永遠過關而刪過頭。
--
-- visits 是 recount 專屬的單 tick 走訪額度（與 find 的分開）。額度用盡就把**已數到的部分**
-- 當結果並回報 partial：判定用的是下界（見 processDeleteQueue 的論證），數得比實際少只會少刪。
-- needed 是「再數到幾件就足以證明超標」，達到就立刻停——單格堆了一萬件而上限只有一百時，
-- 走前一百零一件就夠了，不必白走完整個額度。
-- 為什麼需要額度：AREA_RECOUNT_CHUNKS_PER_TICK 封頂的是區塊數與格數，而單一格子的
-- worldObjects 沒有容量上限（IsoGridSquare.java:319），2048 格裡塞多少物件不是我們決定的。
-- 觸頂時**必須先數已負擔得起的那些**，不能整格跳過：跳過會讓「全堆在一格」的傾倒永遠得到
-- 下界 0、永遠證明不了超標，清理對最該處理的形狀失活。
-- 部分結果**不寫進 cache**：cache 的契約是「這個 tick 內這一塊的完整計數」，寫進去會讓同 tick
-- 的其他 victim 沿用偏低值，而它們本來可能有額度數完
local function liveChunkCount(cx, cy, z, fullType, bucketName, ctx, cache, visits, needed)
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
                local total = wos:size()
                for i = 0, total - 1 do
                    -- 逐筆扣額度而不是整格預扣：預扣的話「數到第 101 件就證明超標」仍會把整格
                    -- 的額度燒掉，同 tick 後面的 victim 就被誤判成觸頂而取消
                    if visits.left <= 0 then
                        return count, ck, true
                    end
                    visits.left = visits.left - 1
                    local wo = wos:get(i)
                    local it = wo and wo:getItem()
                    if it and it:getFullType() == fullType then
                        local isHigh = Cleaner.isHighTolerance(ctx.highSet, it, fullType, ctx.stampsEnabled)
                        if isHigh == (bucketName == "high") then
                            count = count + 1
                            if needed and count >= needed then
                                return count, ck, true
                            end
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

-- 把累積的清理聚合落盤：每熱點寫一行 auto_clean、發一則通知。
--
-- 抽成函式是因為有兩個出口：正常出口是刪除佇列排空（processDeleteQueue 尾端），
-- 另一個是清理進行中被停用（resetDisabledState）。刪除在 removeFloorItem 回 true 那刻
-- 就已不可逆，聚合卻要等佇列排空才輸出（限速 16 件/tick，超過就跨 tick）；少了這裡
-- 統一落盤，管理員在爆發中途關掉 ItemCleanupEnabled 就會讓已刪除的物品完全沒有
-- auto_clean 紀錄也沒有通知——而新增的布林總開關讓那個時機從「手改四個整數」變成一次點擊。
--
-- **每個熱點先從表裡移除、再各自用 pcall 處理**，理由是這裡不做重試：
-- ① 寫檔失敗根本傳不到 Lua——writeLog 走 ZLogger.write，它把所有 Exception catch 起來
--    只印 DebugLog 就正常返回（ZLogger.java:48-54；建檔失敗也在 constructor 內吞掉）。
--    所以「磁碟滿／權限不足」這類真正該重試的情況，這裡連知道都不會知道。
-- ② 會傳到這裡的只剩 Lua 層例外（例如通知路徑上的 nil deref）。對那種情況重放整張表是
--    有害的：Event.trigger 對每個 callback 逐次 catch 後照常註冊（Event.java:52-59），
--    下一個 tick 還是會進來，於是「每 tick 重試」＝每 tick 拋一份堆疊；而已經寫成功的
--    熱點會重複寫一行 log、重複發一則玩家通知，若失敗與重試之間又累加了新的刪除，
--    重放那行的 removed 還會比前一行大，同一熱點的數字因此不可相加。
-- 個別 pcall 是必要的：少了它，第一個熱點拋錯就會帶著**其餘熱點的稽核一起消失**
-- （它們還留在表裡，但佇列已重設、下一個 tick 走不到這裡）。
-- pcall 攔下之後**不重拋**：Kahlua 在拋出點就已經記錄了完整的 Lua 位置與堆疊
-- （KahluaThread.java:894-897 的 luaMainloop catch：ExceptionLogger.logException ＋
-- debugException ＋ doStacktraceProper），所以錯誤本來就看得到，不是靜默吞掉。
-- 再 `error()` 一次只會多印一份指向這裡、而非指向真正拋錯點的堆疊：`error(msg)` 建的是
-- 單參數 KahluaException（source=nil、lineNumber=-1，KahluaException.java:12-16），
-- 原始位置反而遺失；而 pcall 其實回傳四個值（false、訊息、traceback、Throwable，
-- KahluaThread.java:1458-1464），只接前兩個就把 traceback 丟掉了。
-- 另外別把「外層還有 Event.trigger 的 try/catch」當成理由：那條路徑走
-- LuaCaller.pcallvoid → KahluaThread.pcallvoid → pcall(int)，而 pcall(int) 對
-- KahluaException 一律 catch 後回傳四個值、不重拋，所以 Event.java:56-58 的
-- logException 對 Lua 層 error 永遠不會被執行
local function emitCleanEntry(notify)
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

local function flushCleanNotify()
    -- 先蒐 key 再逐個處理：不在 pairs 迭代中改動同一張表（Kahlua 的 table 底層是
    -- LinkedHashMap，J2SEPlatform.java:35、KahluaTableImpl.java:18）
    local keys = {}
    for key in pairs(cleanNotify) do
        keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
        local notify = cleanNotify[key]
        if notify then
            -- 先移除再處理：失敗的熱點也不留回表裡。留回去就是把上面否決掉的重試語意
            -- 從後門加回來——下一次 flush 會把它重放，而它上一次可能已經寫成功了一半
            cleanNotify[key] = nil
            pcall(emitCleanEntry, notify)
        end
    end
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
    -- area recount 的單 tick 區塊額度。liveChunkCount 每塊要走 64 格，而掃描器本身刻意限成
    -- SQUARES_PER_TICK（48）格/tick，所以 recount 也必須有天花板：同型物品每塊放 1 件、鋪滿
    -- 401 塊就超過 MaxFloorItemsPerTypeArea 預設 400 而每塊遠低於區塊上限，不封頂的話這一批的
    -- 第一個 victim 一個 tick 就要走 401×64≈25,664 格。
    -- 額度只對「真的要新數」的來源計費（liveCache 命中不計）：同一個 area 熱點的多個 victim
    -- 共用同一份來源結果，第二件之後是零格成本，不該被算進額度而被推遲
    local recountSpent = 0
    -- 地板物件走訪的單 tick 額度，recount 與 find **各一份**（不共用）：共用的話 recount 恰好
    -- 用完就會讓 findQueuedWorldItem 永遠拿不到額度、victim 全被當成找不到而放掉。
    -- 隨函式進入重建，所以是「每 tick」而不是「每件」
    local recountVisits = { left = C.RECOUNT_ITEM_VISITS_PER_TICK }
    local findVisits = { left = C.FIND_ITEM_VISITS_PER_TICK }
    -- 上限**不能**用排入當時的快照：管理員可以在執行期改 sandbox（server 收到設定封包後
    -- SandboxOptions.load/applySettings/toLua，GameServer.java:1695-1697），把上限調高或設 0
    -- 停用。照舊值刪就會刪掉當前政策允許保留的物品，而那是不可逆的。
    -- 每個 tick 各桶只解析一次（bucketLimits 要讀沙盒字串並 tonumber，而這裡每 tick 最多
    -- 跑 ITEMS_PER_TICK 件）
    local limitCache = {}
    local function currentLimit(bucketName, scope)
        local name = bucketName or "normal"
        local entry = limitCache[name]
        if not entry then
            local maxChunk, maxArea = bucketLimits(name)
            entry = { chunk = maxChunk, area = maxArea }
            limitCache[name] = entry
        end
        return scope == "area" and entry.area or entry.chunk
    end
    while processed < C.ITEMS_PER_TICK and deleteHead <= #deleteQueue do
        local record = deleteQueue[deleteHead]

        -- 刪除前 recount：排隊期間玩家可能已自行撿走，使該範圍回到閾值內 → 取消本件（不刪到
        -- 低於閾值）。AGENTS.md 明文要求跨 tick 消化的刪除佇列要依**同 scope + limit** 重數
        local overThreshold = true
        local defer = false
        local limit = currentLimit(record.bucket, record.scope)
        if limit <= 0 then
            -- 管理員已把這個 scope 的上限設成 0（停用）⇒ 取消本件
            overThreshold = false
        elseif record.scope == "chunk" then
            -- needed 傳 limit + 1：數到這個數就已證明超標，不必把整塊走完
            local live = liveChunkCount(record.cx, record.cy, record.z, record.fullType, record.bucket,
                ctx, liveCache, recountVisits, limit + 1)
            overThreshold = live > limit
        elseif record.scope == "area" then
            -- area 的閾值是跨區塊的總數，只重數 victim 自己那一塊不是同一個 scope，所以要把
            -- victim 帶的來源集重數一遍。那個集合在排入時已依計數降冪截到
            -- AREA_RECOUNT_CHUNKS_PER_TICK 塊（見 finishJob），所以單件走訪量天生有界，
            -- 這裡不必再設單件上限。
            --
            -- 讀不到的來源一律**當 0**，於是 live 是「該範圍現存總數的下界」。這個不對稱正是
            -- 安全性的來源：`live > limit` 成立時真實總數必然也 > limit，刪到可觀測部分等於
            -- limit 之後，總數＝limit ＋（讀不到的那些，≥0）⇒ 永遠不會刪到低於閾值。
            -- 反之 `live <= limit` 時無從判斷真實總數，就不刪。
            --
            -- 為什麼不用「該來源最後一次觀測到的計數」補那些讀不到的區塊：那是過期快照。
            -- 區塊可能在兩輪之間載入過又卸載，期間 vanilla 的 HoursForWorldItemRemoval（chunk
            -- 載入時的 TTL 過濾）、其他 MOD 或玩家短暫互動都可能改變內容，舊值偏高就會把
            -- 刪除放行到低於閾值。
            -- 為什麼不改成「任一來源讀不到就整件取消」：那會讓 area 清理在**預設常態**下永久
            -- 失活——掃描盒（ScanRadius 80 → 168 格寬）比引擎載入視窗（104~152 格）大一圈，
            -- 外圈環帶恆存在，玩家傾倒後走開幾個區塊就會讓某個來源永遠讀不到，而只要仍超標
            -- 每輪都會刷新 lastSeen，staleMs 也等不到收斂。
            --
            -- 已知的保守偏差：排隊期間若有人把物品搬到範圍內**其他**區塊（不在來源集裡），
            -- 重數會低估而少刪。方向仍是少刪、不會多刪
            if not record.areaChunks then
                overThreshold = false
            else
                local live = 0
                local walked = 0
                local remaining = C.AREA_RECOUNT_CHUNKS_PER_TICK - recountSpent
                local deferred = false
                for ck in pairs(record.areaChunks) do
                    local cached = liveCache[ck .. "|" .. tostring(record.bucket) .. "|" .. record.fullType]
                    if cached ~= nil then
                        -- 本 tick 已經數過這一塊：零成本，不計費也不受額度限制。同一個 area 熱點的
                        -- 多個 victim 因此能在同一個 tick 內全部處理完，不會被前一件用掉的額度推遲
                        live = live + cached
                    elseif walked >= remaining then
                        -- 本 tick 額度用完 ⇒ 這件留在佇列原位（deleteHead 不前進），下一個 tick 用
                        -- 完整額度從頭重數（不累加不同時點的部分和）。額度歸零後第一件必定走得完，
                        -- 因為來源集本身就 ≤ 上限，所以佇列不會卡死
                        deferred = true
                        break
                    else
                        local cx, cy, cz = parseChunkKey(ck)
                        if cx and getCell():getChunkForGridSquare(
                            cx * C.CHUNK_SIZE, cy * C.CHUNK_SIZE, cz) ~= nil then
                            -- needed 是「這一塊再數到幾件就足以證明整個範圍超標」：下界已累積
                            -- live，所以還差 limit + 1 - live 件。單格堆了上萬件時這讓走訪停在
                            -- 剛好夠用的地方，而不是把額度燒完
                            local got = liveChunkCount(cx, cy, cz, record.fullType, record.bucket,
                                ctx, liveCache, recountVisits, limit + 1 - live)
                            live = live + got
                        else
                            -- 讀不到的來源以 0 記進本 tick 的快取：同一個 tick 內載入狀態不會變，
                            -- 後續 victim 共用這個結論就不必再付一次 Java 往返。快取只活一個 tick，
                            -- 所以區塊之後載入回來也不會被這個 0 卡住
                            liveCache[ck .. "|" .. tostring(record.bucket) .. "|" .. record.fullType] = 0
                        end
                        -- 載入探測本身也計費：來源全部卸載時，若只對「真的走了 64 格」計費，
                        -- 這裡就會變成不受約束的 Java 往返
                        walked = walked + 1
                    end
                    -- 下界一旦超過閾值就已證明超標，不必再數下去。來源集按計數降冪排過，
                    -- 所以密集熱點通常只走前幾塊。
                    --
                    -- 為什麼提早退出（於是 live 只是「前綴和」）不會讓刪除跑到上限以下——
                    -- 逐步不變式：記真實總數為 T、前綴和為 P、上限為 L。
                    --   ① 每次放行前都成立 T ≥ P（P 只累加真的數到的物品，讀不到的當 0），且 P > L；
                    --   ② 每次刪除至多讓 T 與 P 同減一：刪前綴內的物品時兩者都減一（成功刪除會
                    --      遞減 liveCache），刪前綴外的只有 T 減一而 P 不變；
                    --   ⇒ T ≥ L 恆成立。
                    -- **這個論證的載重前提是 liveCache 只活一個 tick**（就在本函式內宣告）。
                    -- 一旦把它提升成跨 tick 的長生命週期快取，遞減後的舊值就不再是當下的下界
                    -- （中間玩家會補貨／撿走、其他 MOD 會動、chunk 重載時 vanilla 還有 TTL 過濾），
                    -- ①、② 同時失效——而且不會有任何斷言變紅。要改快取生命週期就得重做這個證明
                    if live > limit then
                        break
                    end
                end
                if deferred then
                    defer = true
                else
                    recountSpent = recountSpent + walked
                    overThreshold = live > limit
                end
            end
        end

        if defer then
            break
        end

        deleteHead = deleteHead + 1
        pendingDeleteIDs[record.id] = nil
        processed = processed + 1

        local item, worldObj, square = nil, nil, nil
        if overThreshold then
            item, worldObj, square = findQueuedWorldItem(record, findVisits)
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
        flushCleanNotify()
    end
end

local function resetDisabledState()
    -- 落盤放最前面，是為了讓「已刪除但還沒寫稽核」的那批資料在世界狀態被清掉之前先輸出。
    -- 它現在**不會**把例外往外傳（每個熱點各自 pcall，見 flushCleanNotify），所以下面的
    -- 狀態重設一定會執行、這個函式一個 tick 就做完。
    -- 注意落盤是 at-most-once：flushCleanNotify 在處理前就把每個熱點從 cleanNotify 移除，
    -- 失敗的那一個不會重試也不會重放，所以「下一個 tick 重做」只適用於下面的狀態重設，
    -- 不適用於稽核。這是刻意的取捨，理由在 flushCleanNotify 的註解
    flushCleanNotify()
    scanQueue = {}
    activeJob = nil
    dirtyChunks = {}
    warned = {}
    areaWarned = {}
    unprovableLogAt = {}
    deleteQueue = {}
    deleteHead = 1
    pendingDeleteIDs = {}
    periodicQueued = false
end

local function onTick()
    -- LuaManager.java:9268-9273; forageServer.lua:455-471
    local now = getTimestampMs()
    -- 無條件每 tick 遞增：consumeScanQueue 靠它判斷「這個 tick 是否已重查過 active chunk 的
    -- 載入狀態」。曾經誤放進下面的 disabled 分支內部，結果只有「清理被停用」時才遞增、
    -- 正常運作時恆為 0，於是每個 chunk 只在第一次被碰到時查一次載入狀態，跨 tick 重查整條失效
    tickSeq = tickSeq + 1
    if Cleaner.isFloorCleaningDisabled() then
        -- 只在 啟用→停用 那一個 tick 清理狀態（理由見 cleaningDisabled 宣告處）。
        -- 旗標在 reset 返回之後才設。目前的 resetDisabledState 已經不會拋錯（落盤逐項
        -- pcall），所以這個順序在現況下沒有可觀測差異——留著是因為它是唯一安全的順序：
        -- 一旦日後有人在 reset 裡加了會拋錯的步驟，先設旗標就會讓那次失敗永久鎖住重做
        -- （旗標已設、狀態留半套、沒有任何後續 tick 會回來補），而「每 tick 無條件重做」
        -- 這個原本的自癒性正是加旗標時被換掉的東西
        if not cleaningDisabled then
            resetDisabledState()
            cleaningDisabled = true
        end
        return
    end
    cleaningDisabled = false

    promoteDirtyChunks(now)
    local interval = (tonumber(Cleaner.getOption("ScanIntervalSeconds")) or Cleaner.DEFAULTS.ScanIntervalSeconds) * 1000
    if now - lastPeriodicAt >= interval then
        queuePeriodicScan(now)
    end
    consumeScanQueue(now)
    processDeleteQueue()
end

Events.OnTick.Add(onTick)
