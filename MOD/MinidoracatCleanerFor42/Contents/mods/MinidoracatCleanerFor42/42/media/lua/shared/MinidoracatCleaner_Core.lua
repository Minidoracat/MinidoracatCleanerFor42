MinidoracatCleaner = MinidoracatCleaner or {}

local Cleaner = MinidoracatCleaner

Cleaner.MOD_ID = "MinidoracatCleanerFor42"
Cleaner.COMMAND_MODULE = "MinidoracatCleaner"
-- 章的 key 與值格式（合併格式；由 0.3.0 的三 key 精簡而來）
--
-- 章搭 vanilla 物品同步便車傳出（InventoryItem.save 寫整個 modData，:1693-1697）。
-- 本 MOD 自己的 touch / touchAck 只帶 ID。正式服實測（2026-08-23，77 人）章佔
-- 對外上傳 13.1%，其中 86% 在容器路徑——容器走 CompressIdenticalItems
-- （ItemContainer.java:2421、AddInventoryItemToContainerPacket.java:58），
-- 同 fullType 相鄰且逐 byte 相同才壓成每件 4 bytes（CompressIdenticalItems.java:166-179）。
-- 真正成本是「阻止壓縮」，故兩個 mover key 合併、時間改小時取整。
--
-- 值格式：`<sanitizedName>,<epochHour>`。分隔符選 `,` 而不是別的可見字元，是因為它有**兩層**
-- 保證不會出現在名字裡：① PZ 引擎層就拒絕含 `,` 的 username（ServerWorldDatabase.java:769，
-- 禁用集 `; @ $ , \ / . ' ? "`）；② sanitizeName 本來就清 `,`。若改用 PZ 未禁的字元
-- （`|` 試過、`=`、空白同理），則 `a|b` 與 `a b` 兩個合法且不同的帳號會消毒成同一個章值，
-- 而 Commands 的覆蓋偵測正是比對這個值——碰撞時連 touch_overwrite 稽核都不會產生。
Cleaner.KEY_TOUCH = "MIC42_t"
-- 丟棄者單獨一個 key：同時是高容忍分桶依據（isHighTolerance），熱路徑只問「有沒有」。
-- 值只有名字、不帶時間（與 0.3.0 的 KEY_DROPPED 語意相同）。
Cleaner.KEY_DROP = "MIC42_d"

-- 0.3.0 及更早的 key。**只讀不寫**：任一次蓋章都會一次刪掉這三個並改寫成上面兩個新 key。
-- 沒再被碰過的舊物品仍讀得到章。0.1.3 的 MIC42_lastTouchedBy 依舊不讀。
Cleaner.LEGACY_DROPPED = "MIC42_lastDroppedBy"
-- 「最後操作者＋時間」：0.1.3 曾移除「最後接觸者」（當時假設接觸者≈丟棄者），玩家實證
-- 背包對背包轉移完全不落地、不觸發任何丟棄章——而 B42 的一般容器轉移在 server 端純 Java
-- 執行、無 Lua 事件也無 item log（Transaction.java:231-343 無 triggerEvent / LoggerManager），
-- 本 MOD 不記就無跡可循，故以獨立 key 重建。
Cleaner.LEGACY_MOVED = "MIC42_lastMovedBy"
Cleaner.LEGACY_MOVED_AT = "MIC42_lastMovedAt"

Cleaner.DEFAULTS = {
    AllowManualDelete = true,
    -- 兩個分類各自的總開關（預設開）。有了它們，要停用整套清理不必把上限一個個改成 0
    ItemCleanupEnabled = true,
    AnimalCleanupEnabled = true,
    MaxFloorItemsPerType = 100,
    MaxFloorItemsPerTypeArea = 400,
    HighToleranceMaxPerType = 300,
    HighToleranceMaxPerTypeArea = 2000,
    HighToleranceList = "",
    ScanRadius = 80,
    ScanIntervalSeconds = 60,
    ProtectList = "",
    TouchTraceEnabled = true,
    DebugMenuEnabled = false,
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
    -- 週期掃描建立區塊清單時，每個 tick 建幾個。每位玩家 ScanRadius 80 就是 21×21＝441 個
    -- 區塊、站在 z≠0 時兩層共 882 個（半徑拉到最大 128 時是 2178 個），而每個區塊都要配一張
    -- table——Kahlua 的每張表都是獨立的 KahluaTableImpl／LinkedHashMap。分批建構把這筆固定
    -- 數量的配置攤到多個 tick，封頂的是「單一 tick 的配置速率」。
    -- **這是理論風險的封頂，不是實測到的熱點**：GameProfiler 只能量到整個 WorldScanner
    -- callback（Event.java:34,55 的 span 名稱只有 "Lua - OnTick"，不含檔名或函式），
    -- 無法隔離建構本身的耗時；改前後的對照也沒量到可證明的差異（尖峰成因至今未定位）。
    -- 留著它的理由是配置量由沙盒半徑與在線人數決定（#玩家 ×(2×ScanRadius/8+1)²×樓層數，
    -- 與地圖大小無關），而單一 tick 要配多少應該由我們決定、不是由設定值決定
    CHUNKS_PER_TICK = 128,
    -- area victim 刪除前重數「來源區塊」時的區塊額度，同時是**排入時**來源集的截斷長度。
    -- 每塊要走 64 格，取 32 即 2048 格/tick 的上限（掃描器本身是 SQUARES_PER_TICK＝48
    -- 格/tick，但 recount 是突發而非持續，正式服 10 天只觸發過 7 次 area 清理）。
    -- 需要上限的理由：同型物品每塊放 1 件、鋪滿 401 塊就超過 MaxFloorItemsPerTypeArea 預設
    -- 400，而每塊都遠低於區塊上限 ⇒ 不封頂的話這一批的第一個 victim 一個 tick 就要走
    -- 401×64≈25,664 格。
    -- 排入時就把來源集依計數降冪截到這個長度（見 WorldScanner.finishJob），所以單件走訪量
    -- 天生有界，recount 不必另設單件上限；截斷後的下界若證明不了超標就整批不排入，避免每輪
    -- 都排入註定被取消的 victim。同一 tick 內已數過的來源不計費（liveCache 命中），所以同一
    -- 個熱點的多個 victim 能在一個 tick 內處理完。這是校準旋鈕
    AREA_RECOUNT_CHUNKS_PER_TICK = 32,
    -- 以下三個是**地板物件走訪**的單 tick 硬額度。格數／區塊數封頂不等於成本封頂：
    -- IsoGridSquare 的 worldObjects 是沒有應用層容量限制的 ArrayList（IsoGridSquare.java:319，
    -- 掉落時直接 append、getter 原樣回傳 :9947-9949），單一格子堆到數萬件做得到，於是「每格
    -- 完整走一遍」的迴圈成本由世界內容量決定而非我們決定——AGENTS.md 的通則是成本硬上限不可
    -- 綁世界內容量。三者各自獨立計數，不共用一份額度：共用的話 recount 恰好用完就會讓
    -- findQueuedWorldItem 永遠拿不到額度。
    -- 觸頂語意各自不同（都是「少做」而非「多做」）：
    --   掃描：把格內位置記在 job.itemOffset，下一個 tick 從那裡續走（不前進 squareIndex）。
    --         所以計數仍精確、只是攤到多個 tick——換成「略過該格剩下的」會讓那些物品永遠不被
    --         計數（每輪都在同一處觸頂），清理對單格大量堆積完全失效
    --   recount：回傳已數到的部分計數。判定用下界，少數到只會少刪
    --   find：當成找不到而放掉這件（fail-closed），下一輪重新排。**反向掃**（尾端往前）是必要
    --         的：候選依 item ID 由大到小挑而掉落物 append 在尾端，正向掃會永遠在前段觸頂
    SCAN_ITEM_VISITS_PER_TICK = 512,
    RECOUNT_ITEM_VISITS_PER_TICK = 4096,
    FIND_ITEM_VISITS_PER_TICK = 2048,
    -- items_area_unprovable 的 per-player 節流間隔。這條診斷只有在「超標但下界證明不了」時
    -- 才寫，誠實玩家很少碰到，能穩定量產的是刻意鋪成稀疏形狀的人——所以要有玩家層的間隔，
    -- 不能只靠「每筆記錄一次」（多型別與記錄回收循環都能繞過）
    UNPROVABLE_LOG_INTERVAL_MS = 600000,
    -- 每個 (chunk, fullType) 保留的候選上限（依 item ID 降冪的 top-N）。這是「一輪最多從單一
    -- 熱點刪多少」的天花板：更多的話下一輪繼續，所以仍會收斂，只是攤得慢
    CANDIDATES_PER_TYPE = 512,
    -- 單一掃描工作的候選配置兜底上限。per-type 額度已擋掉「單點爆炸」，但總量仍隨超標組合數
    -- （區塊數 × 物品種類）成長，這道是純粹的記憶體 DoS 防線，設寬鬆值即可
    CANDIDATES_PER_JOB = 20000,
    -- 待刪佇列的總量上限。掃描每 tick 最多產生 SCAN_ITEM_VISITS_PER_TICK 個候選，而刪除只
    -- 消化 ITEMS_PER_TICK 個——生產可以比消化快 32 倍，佇列必須自己有天花板
    MAX_PENDING_DELETES = 20000,
    DIRTY_DELAY_MS = 60000,
    -- 每輪掃描的移除總額度（語意不變），但移除本身跨 tick 攤平：見 ANIMALS_PER_TICK
    ANIMALS_PER_ROUND = 20,
    -- 單一 tick 最多 remove 幾隻動物。不是改每輪總量，只把 remove 副作用跨 tick 攤平，
    -- 避免同幀批次移除與動物聲音／碰撞路徑疊加；事故與 NaN 根因見 AGENTS.md 踩坑錄。
    ANIMALS_PER_TICK = 3,
    -- 單一 tick 最多重驗幾個候選。AGENTS.md 的硬規則要求「刪除前重數該範圍現存數，
    -- 達標即取消」；動物側沒有便宜的範圍查詢，重數就是完整走訪該 plan 的候選清單。
    -- remove 與 visit 因此各有預算：remove 封頂副作用，visit 封頂主執行緒成本。
    -- 單一 plan 超過此值時無法在同 tick 得到一致 recount；本輪 fail-closed 不刪並寫
    -- animal_recount_unprovable（不可跨 tick 攢 walkValid，前半段驗證會在 remove 前過期）。
    ANIMAL_VISITS_PER_TICK = 512,
    ANIMAL_EMERGENCY_MULTIPLIER = 2,
    ZONE_BUFFER = 2,
    MANUAL_DELETE_LIMIT = 100,
    WARNING_RADIUS = 30,
    -- 刷新物品欄面板的廣播半徑。容器互動需要貼身（刪除範圍本身只有 1 格，站在容器另一側
    -- 的人再隔 2 格），8 格已有充裕餘裕；取小是因為 dirtyUI 會刷新對方**所有**開啟中的面板，
    -- 不該去打擾遠處正在整理自己背包的玩家
    UI_REFRESH_RADIUS = 8,
    CHUNK_SIZE = 8,
    -- 警告記錄的閒置回收門檻（幾個掃描間隔沒再被掃到就丟棄）
    WARN_STALE_INTERVALS = 20,
    -- touch 回報單批上限。與 MANUAL_DELETE_LIMIT 不同採「截斷」不採「整批拒絕」：
    -- 蓋章漏尾端好過全批失效；成本由 buildAccessibleIndex 的 wantedIds 過濾封頂
    TOUCH_BATCH_LIMIT = 400,
    -- 單次可及性掃描的走訪件數硬上限（見 indexShouldStop）。取值原則：要遠高於任何
    -- 正常請求走得到的量（正常請求在找齊時就提早收工，根本走不到這裡），又要讓單次
    -- 最壞情況有個確定的天花板。**這是校準旋鈕不是實測值**：20000 尚未在 Kahlua＋
    -- dedicated server 上量過耗時，且節流只限制「每秒幾次請求」不限制「每次多重」，
    -- 故理論上仍有每秒約 10 萬件走訪的上界。真的量到會卡、或有基地大到正常操作被
    -- 截斷（單一容器逾兩萬件；ItemNumbersLimitPerContainer 預設 0＝無件數上限），
    -- 就往下／往上調這個值
    INDEX_VISIT_LIMIT = 20000,
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
    -- AnimalDefinitions 若還沒載入就會得到空索引，此時不要快取，下次再試。
    -- 不可用 next(index)：Kahlua 的 BaseLib 沒有註冊 next（只有 collectgarbage/error/
    -- getfenv/getmetatable/pcall/print/rawequal/rawget/rawset/select/setfenv/setmetatable/
    -- tonumber/tostring/type/unpack），呼叫會拋「Object tried to call nil」並中斷整輪掃描。
    local hasAny = false
    for _ in pairs(index) do
        hasAny = true
        break
    end
    if hasAny then
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
    local tokens = Cleaner.parseList(Cleaner.getOption("AnimalGroupList"), defaults)
    -- 特殊 token：* 或 all（不分大小寫）＝允許 AnimalDefinitions 裡每一個 group。
    -- 用 _allowAll sentinel，而不是把 index 的 key 抄進 set：
    --   ① 掃描端對未知／未來 MOD group 仍放行（group 字串來自 getDef，不必預先列舉）
    --   ② 建 set 的成本固定 O(tokens)，不隨物種數成長
    -- 與一般關鍵字並存時，all 優先（例如 "all,rat" 仍是全部）
    for _, token in ipairs(tokens) do
        local lower = string.lower(trim(token))
        if lower == "*" or lower == "all" then
            result._allowAll = true
            return result
        end
    end
    local index = buildAnimalNameIndex()
    for _, token in ipairs(tokens) do
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
    -- 清換行/tab 防整行注入；[ ] 換成 ( ) 防偽造 log 欄位邊界（username 允許 [ ]，見 ServerWorldDatabase.java:763-779）。
    -- 注意：不可在這裡清 , 與 =——log 的 detail 欄位以它們當合法分隔符（repaired=2、type=count,...），
    -- 一律清掉會破壞既有格式（煙霧測試情境四實際擋下過）。username 專用的加嚴版見 sanitizeName
    return tostring(value or "unknown"):gsub("[\r\n\t]", " "):gsub("%[", "("):gsub("%]", ")")
end

-- username 專用：在 sanitize 之上多清 `,` 與 `=`。兩者都是分隔符，各有用途：
--   `=`：log detail 欄位內的鍵值分隔符（type=count），名字一旦被未來程式寫進 detail，
--     就能偽造假的型別/數量對。
--   `,`：log detail 的項目分隔符，**同時**是 KEY_TOUCH 值的欄位分隔符
--     （`<name>,<epochHour>`）。PZ 引擎層已拒絕含 `,` 的 username
--     （ServerWorldDatabase.java:769），這裡是第二層——手改存檔或異版 client 送來的
--     名字不受引擎檢查保護。
-- 在「寫入點」（蓋章）用這個版本，之後所有讀取路徑自動繼承保護
function Cleaner.sanitizeName(value)
    return (Cleaner.sanitize(value):gsub("[,=]", " "))
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
    return Cleaner.readDrop(item) == nil
end

-- 章值的欄位分隔符。PZ 拒絕含它的 username，sanitizeName 又清一次，故一個值裡至多一個。
local TOUCH_SEP = ","

local function toTouchHour(value)
    local n = tonumber(value)
    return n and math.floor(n / 3600) * 3600 or nil
end

-- 取 modData。**讀寫要用不同的取法**：`hasModData()` 是
-- `table != null && !table.isEmpty()`（InventoryItem.java:429-431），對「從未有過 modData」
-- 的物品回 false；讀取時據此早退可省掉無謂的 table 配置，但寫入時必須走 `getModData()`
-- 讓它 lazy 建表（:433-439），否則新物品永遠蓋不上章。
-- 兩者都先問「方法存在嗎」：ISToolTipInv 等 vanilla 入口會塞非 InventoryItem 進來，
-- 對它呼叫 hasModData 就是 call nil 並中斷整個 tooltip 繪製（AGENTS.md 踩坑錄）。
local function modDataForRead(item)
    if not item or not item.hasModData or not item:hasModData() then
        return nil
    end
    return item:getModData()
end

local function modDataForWrite(item)
    if not item or not item.getModData then
        return nil
    end
    return item:getModData()
end

-- 解析 KEY_TOUCH 值 → name, epochSeconds。
-- plain find（第四參數 true）已註冊（StringLib.java:1495-1502），走 String.indexOf
-- （:900-911），不進 pattern 引擎。
local function decodeTouch(value)
    if type(value) ~= "string" or value == "" then
        return nil, nil
    end
    local sep = string.find(value, TOUCH_SEP, 1, true)
    if not sep then
        -- 沒有分隔符＝只有名字。不該發生，但別因為格式意外就讓整條章消失
        return value, nil
    end
    return string.sub(value, 1, sep - 1), tonumber(string.sub(value, sep + 1))
end

-- 讀丟棄者的原始值（新 key 優先；空值／錯型不能遮蔽仍有效的舊 key）
local function readDropFrom(modData)
    local value = rawget(modData, Cleaner.KEY_DROP)
    if type(value) ~= "string" or value == "" then
        value = rawget(modData, Cleaner.LEGACY_DROPPED)
    end
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

-- 讀操作者章 → name, epochSeconds
local function readTouchFrom(modData)
    local name, at = decodeTouch(rawget(modData, Cleaner.KEY_TOUCH))
    if name ~= nil and name ~= "" then
        return name, at
    end
    -- 條件是「解不出名字」而**不是**「新 key 不存在」：後者會讓任何寫出空值/壞值的路徑
    -- 靜默遮蔽舊章，正是本次改動最想避免的失效模式
    local legacy = rawget(modData, Cleaner.LEGACY_MOVED)
    if legacy == nil or legacy == "" then
        return nil, nil
    end
    -- 舊章的 at 原樣回傳、不在讀取路徑取整：未遷移物品的顯示不該因為換格式而失真
    -- （取整只發生在寫入／遷移時，見 touchValueFrom 與 writeTouch）
    return tostring(legacy), tonumber(rawget(modData, Cleaner.LEGACY_MOVED_AT))
end

-- 把現有的操作者章（新格式，或由舊 key 升級而來）組成可直接寫入的字串。
-- **不能直接回傳非空 KEY_TOUCH 原值**：`",123"` 這種壞值（分隔符在最前面、名字為空）雖非
-- 空字串，但 readTouchFrom 會正確退回 legacy；直接回原值會在 rewriteStamps 清掉三個舊 key
-- 後永久毀掉仍有效的舊章。
local function touchValueFrom(modData)
    local name, at = readTouchFrom(modData)
    if name == nil or name == "" then
        return nil
    end
    -- 舊章的分鐘取整值在**遷移寫入時**升級成小時，之後才與新章同域、能參與壓縮
    local hour = toTouchHour(at)
    return Cleaner.sanitizeName(name) .. TOUCH_SEP .. (hour and tostring(hour) or "")
end

-- 本 MOD 的兩個 key 一律「先全刪、再按固定順序重插」（drop 先、touch 後）。
--
-- 順序是正確性的一部分：modData 序列化直接迭代 KahluaTableImpl 的 LinkedHashMap
-- （KahluaTableImpl.java:205-231），插入順序決定 byte 序列；CompressIdenticalItems
-- 逐 byte 比對。若不統一，「先搬再丟」是 touch,drop，「一開始就被丟」是 drop,touch，
-- 兩群永久分裂。先刪再插也一次清掉三個舊 key，任一次操作即完成整包遷移。
-- vanilla 其他 key 相對順序不變；本 MOD 的兩個 key 永遠落在尾端、順序固定。
local function rewriteStamps(modData, dropValue, touchValue)
    rawset(modData, Cleaner.KEY_DROP, nil)
    rawset(modData, Cleaner.KEY_TOUCH, nil)
    rawset(modData, Cleaner.LEGACY_DROPPED, nil)
    rawset(modData, Cleaner.LEGACY_MOVED, nil)
    rawset(modData, Cleaner.LEGACY_MOVED_AT, nil)
    if dropValue then
        rawset(modData, Cleaner.KEY_DROP, dropValue)
    end
    if touchValue then
        rawset(modData, Cleaner.KEY_TOUCH, touchValue)
    end
end

-- 讀「最後操作者」章 → name, epochSeconds（at 可能為 nil）。
-- 新 key 優先；解不出名字才退回舊 key，讓沒再被碰過的舊物品仍看得到章。
function Cleaner.readTouch(item)
    local modData = modDataForRead(item)
    if not modData then
        return nil, nil
    end
    return readTouchFrom(modData)
end

-- 讀「最後丟棄者」章 → name（新 key 優先，退回舊 key）
function Cleaner.readDrop(item)
    local modData = modDataForRead(item)
    if not modData then
        return nil
    end
    return readDropFrom(modData)
end

-- 寫入「最後操作者＋時間」章。server 蓋章與 client 收到 touchAck 後的本地寫入共用同一個
-- 函式，兩端的值格式才不會分岔（0.2.8 的兩端各自取時間就吃過顯示不一致）。
-- **at 一律在此重新取整**：不變量封在唯一的寫入點，呼叫者傳進未取整的值（異版 client、
-- 未來新呼叫者）不會靜默讓同批物品再度逐 byte 不同而壓縮失效。
-- **at 缺失時不鑄造時間**、直接回 nil：要當前時間的是 stampMove，它自己會給。先前用
-- 本端時鐘補值，等於把 0.2.8 那個「兩端各自取時間」的不一致從後門放回來。
function Cleaner.writeTouch(item, username, at)
    local stampAt = toTouchHour(at)
    if not stampAt or not username or username == "" then
        return nil
    end
    local modData = modDataForWrite(item)
    if not modData then
        return nil
    end
    rewriteStamps(modData, readDropFrom(modData),
        Cleaner.sanitizeName(username) .. TOUCH_SEP .. tostring(stampAt))
    return stampAt
end

-- 蓋「最後丟棄者」章。與 writeTouch 共用 rewriteStamps，故插入順序與整包遷移行為一致。
function Cleaner.stampDrop(item, username)
    if not username or username == "" then
        return
    end
    local modData = modDataForWrite(item)
    if not modData then
        return
    end
    rewriteStamps(modData, Cleaner.sanitizeName(username), touchValueFrom(modData))
end

-- 蓋「最後操作者＋時間」章。時間取自 getTimestamp()（LuaManager.java:9259-9264），
-- 由 writeTouch 取整到小時。回傳寫入的時間戳，供 touchAck 把同一個值回推 client。
function Cleaner.stampMove(item, username)
    return Cleaner.writeTouch(item, username, getTimestamp())
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

local function notifyNearby(command, payload, clientHandler, radius)
    radius = radius or Cleaner.CONSTANTS.WARNING_RADIUS
    for _, playerObj in ipairs(Cleaner.getActivePlayers()) do
        if Cleaner.chebyshevDistance(playerObj:getX(), playerObj:getY(), payload.x, payload.y) <= radius then
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

-- 通知「可能正開著同一個容器」的玩家刷新物品欄面板。判準是「誰開著」而不是「誰按了刪除」——
-- 兩人同時開著同一個貨架時，只刷新操作者會讓另一人繼續盯著幽靈物品
function Cleaner.refreshNearbyUI(x, y, z)
    notifyNearby("refreshUI", { x = x, y = y, z = z }, Cleaner.refreshUI, Cleaner.CONSTANTS.UI_REFRESH_RADIUS)
end

function Cleaner.notifyCleanedPlayerOnly(playerObj, kind, detail, count, scope, remaining)
    notifyPlayer(playerObj, "cleaned",
        { kind = kind, detail = detail, count = count, scope = scope, remaining = remaining },
        Cleaner.showCleaned)
end

-- normal 與 high 是各自獨立的兩組上限，任一為正就仍需掃描；四個全為 0 才是「完全關閉」。
-- （只看 normal 兩項會讓「normal=0、high>0」的設定意外整個停擺）
--
-- ItemCleanupEnabled 是這個分類的總開關，優先於所有上限：關掉它就不必再把四個上限逐一改成 0。
-- 寫 `== false` 只是把「唯有明確關閉才停用」寫清楚，與本檔既有的 `~= false` 同一風格；
-- getOption 對沙盒缺值會回 DEFAULTS（見上方定義），所以這裡拿不到 nil，`not` 也會等價
function Cleaner.isFloorCleaningDisabled()
    if Cleaner.getOption("ItemCleanupEnabled") == false then
        return true
    end
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

-- 停止掃描的兩個理由：
-- ① 要找的 id 全數到齊（提早收工，正常請求的常態出口）
-- ② 走訪件數觸頂——**硬上限**。上面的 wantedIds 過濾只封頂「配置量」，不封頂「走訪量」：
--    偽造封包夾帶不存在的 id 時 remaining 永不歸零，於是 9 格內每個容器、每個巢狀袋、
--    每輛載具的每個 part 都會被翻完（ItemNumbersLimitPerContainer 預設 0＝單一容器件數
--    無上限，ServerOptions.java:164，故「翻完」沒有自然天花板），而 OnClientCommand 是
--    在 server 主執行緒同步跑的。這正是 AGENTS.md「上限要綁請求量、不綁世界內容量」
--    的殘留違反。
-- 觸頂＝提早收工回傳部分索引，不是錯誤：三個呼叫點（deleteItems／touchItems／
-- applyTouchAck）都是「索引裡找不到就不處理」，截斷只會少做事，不會誤刪或誤蓋章。
local function indexShouldStop(ctx)
    -- 先判「找齊了」再判觸頂：兩者在同一次呼叫同時成立時屬正常收工，
    -- 反過來寫會誤標 truncated 並印出誤導的診斷行
    if ctx.wanted ~= nil and ctx.remaining <= 0 then
        return true
    end
    if ctx.visited >= Cleaner.CONSTANTS.INDEX_VISIT_LIMIT then
        ctx.truncated = true
        return true
    end
    return false
end

-- 觸頂只可能由偽造封包穩定量產（正常請求早在提早收工時就結束），逐次寫 log 等於送
-- 攻擊者一支日誌洪水原語（ZLogger >10MB 原檔截斷會沖掉真證據）→ 綁 debug 開關。
-- 但也不能全靜默：正常玩家若真的大到被截斷，症狀是「有幾件就是刪不掉」，沒有這行
-- 完全無從診斷（此時管理員開 debug 就看得到，並可調高 INDEX_VISIT_LIMIT）
local function finishIndex(ctx)
    if ctx.truncated and Cleaner.getOption("DebugMenuEnabled") == true then
        print("[" .. Cleaner.MOD_ID .. "] accessible index truncated at "
            .. Cleaner.CONSTANTS.INDEX_VISIT_LIMIT .. " visited items")
    end
    return ctx.index
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
        -- 計在取件處而不是命中處：走訪成本本身就發生在這裡，被 wantedIds 濾掉的件數
        -- 才是偽造請求真正燒掉的 CPU。迴圈尾端既有的 shouldStop 檢查會接住觸頂
        ctx.visited = ctx.visited + 1
        if item then
            local id = item:getID()
            if indexWanted(ctx, id) and ctx.index[id] == nil then
                ctx.index[id] = { item = item, kind = "container", container = item:getContainer() or container }
                indexNote(ctx, id)
            end
            -- 先判完成再遞迴：要找的都到齊時連這件容器的內容都不必展開
            if indexShouldStop(ctx) then
                return
            end
            -- 巢狀袋。遞迴深度等同 vanilla 的 getItemWithIDRecursiv（ItemContainer.java:3065），
            -- 容器不可能自我包含，故無循環風險
            if instanceof(item, "InventoryContainer") then
                indexContainer(ctx, item:getInventory())
            end
        end
        -- 收尾檢查放在 `if item` **之外**：visited 是無條件遞增的，若只在 item 非 nil 時
        -- 才檢查，一串 nil entry 就能整段越過硬上限（外部審查以 probe 實證：limit=20、
        -- 前置 25 個 nil，仍會走完 26 件並找到上限之後的目標）。vanilla 幾乎產不出 nil
        -- entry，但「硬上限」不能靠資料剛好乾淨才成立。此處同時涵蓋遞迴返回後的複檢
        if indexShouldStop(ctx) then
            return
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
        ctx.visited = ctx.visited + 1
        local item = worldObj and worldObj:getItem()
        if item then
            local id = item:getID()
            if indexWanted(ctx, id) and ctx.index[id] == nil then
                ctx.index[id] = { item = item, kind = "floor", worldObj = worldObj, square = square }
                indexNote(ctx, id)
            end
            -- 同上：先判完成再展開地板袋的內容
            if indexShouldStop(ctx) then
                return
            end
            if instanceof(item, "InventoryContainer") then
                indexContainer(ctx, item:getInventory())
            end
        end
        -- 同 indexContainer：檢查放在 `if item` 之外，nil entry 才不會越過硬上限
        -- （worldObj:getItem() 為 nil 是真實可能的，IsoWorldInventoryObject 有無 item 的建構子）
        if indexShouldStop(ctx) then
            return
        end
    end

    local staticObjects = square:getStaticMovingObjects()
    for i = 0, staticObjects:size() - 1 do
        local object = staticObjects:get(i)
        indexContainer(ctx, object:getContainer())
        if indexShouldStop(ctx) then
            return
        end
    end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        for containerIndex = 0, object:getContainerCount() - 1 do
            indexContainer(ctx, object:getContainerByIndex(containerIndex))
            if indexShouldStop(ctx) then
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
                if indexShouldStop(ctx) then
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
-- wantedIds（選填）：只需要這些 id 時，全部到齊即可停止掃描，其餘容器連碰都不碰。
-- 走訪件數另有硬上限（INDEX_VISIT_LIMIT，見 indexShouldStop）：找不齊時也不會無限翻下去，
-- 觸頂即回傳當下的部分索引
function Cleaner.buildAccessibleIndex(playerObj, range, wantedIds)
    local ctx = { index = {}, found = {}, wanted = nil, remaining = 0, visited = 0 }
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
    if indexShouldStop(ctx) then
        return finishIndex(ctx)
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
                    if indexShouldStop(ctx) then
                        return finishIndex(ctx)
                    end
                end
            end
        end
    end
    return finishIndex(ctx)
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

    -- DoRemoveItem 只動 items 清單，原版每條「把東西拿出容器」的路徑都另外補這兩件事：

    -- ① hasBeenLooted：物資重生的條件是 explored **且** hasBeenLooted（LootRespawn.java:138），
    -- 而這面旗只由玩家搬運（ISInventoryTransferAction.lua:656）與客戶端刪除封包
    -- （RemoveInventoryItemFromContainerPacket.java:115）設起。少了它，被本 MOD 刪空的貨架
    -- 永遠等不到重生——玩家得放一件進去再拿出來，用一次真實搬運才解鎖。
    container:setHasBeenLooted(true)

    -- ② overlay sprite：貨架「滿的／空的」外觀是 IsoObject 的 overlay 貼圖，只有
    -- ItemPicker.updateOverlaySprite 會依容器件數重算（ContainerOverlays.java:139-178）。
    -- 不補這一刀會**永久固化**成「架上滿滿、打開全空」：chunk 重載時空容器被跳過不重算
    -- （LoadGridsquarePerformanceWorkaround.java:73-75），且 overlay 名稱會寫進存檔
    -- （IsoObject.java:1489-1496）。條件與原版一致（只在本來就有 overlay 時重算），
    -- server 端呼叫會自動廣播給附近客戶端（IsoObject.java:4916-4919），無須自建封包。
    local parent = container:getParent()
    if parent and parent:getOverlaySprite() then
        ItemPicker.updateOverlaySprite(parent)
    end
    return true
end
