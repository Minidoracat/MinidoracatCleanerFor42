--[[
用假的 PZ 全域驅動真正的 Core.lua / WorldScanner.lua / Commands.lua / AnimalScanner.lua /
DropStamp.lua / Client.lua / Tooltip.lua / AnimalBreeding.lua / Picker.lua，跑四十一個情境並斷言結果。

    lua scripts/smoke_scanner.lua        （在 repo 根目錄執行）

情境一：自動清理的 normal／high 雙桶分流（掃描 → 警告 → 下一輪確認 → 刪除）
情境二：批次手動刪除的索引建立與安全邊界（範圍外、被牆阻隔、最愛物品都不得被刪）
情境三：提早退出（只刪背包內物品時不得掃描世界，但也不得因此略過把關）
情境四：拒絕路徑（保險屋拒絕、無所在格）與記憶體配置上限
情境五：週期掃描修復被刪空的容器（三種正常狀態當對照組，確認修復不外溢）
情境六：Kahlua 缺少的標準 Lua 全域（原始碼靜態掃描）
情境七：批量生成動物的右鍵選單預設值（單人／MP／管理員／-debug 四種組合）
情境八：chunk-scope 警告記錄的生命週期——區塊卸載時不得誤判「已解決」，回到上限內要即時
        回收，未觀測超過 staleMs 也要回收（不得無界滯留）
情境九：area-scope 的同款生命週期——判定只看「這筆計數的來源區塊」有沒有本輪未觀測到的，
        而不是「區域內任一區塊未觀測」（後者恆真，掃描盒比引擎載入視窗大一圈）
情境十：area 來源清單必須合併而非覆寫——部分來源卸載時仍超標並清理後，可觀測總數會掉到
        門檻以下，清單若忘掉那個卸載來源就會誤判「已解決」（真實總數仍超標）
情境十一：掃描途中卸載——一個區塊 64 格而每 tick 預算 48 格，掃描必定跨 tick，載入狀態
          必須每個 tick 重查，否則低估的計數會帶著「已觀測」而讓記錄被誤判已解決
情境十二：area 記錄是 per-player——玩家搬家後，舊來源區塊即使還在別人的掃描盒裡（且未載入），
          也不得再算進他的來源集，否則 underCounted 恆真 ⇒ 記錄永遠不會在達標輪被回收 ⇒
          下次超標時直接沿用舊記錄清理、不再給玩家警告
情境十三：area 刪除前的 live recount——佇列跨 tick 消化時，玩家自己把數量撿回上限內，
          後續還排著的 victim 必須被取消，不能刪到低於上限
情境十四：來源集依計數降冪截到 AREA_RECOUNT_CHUNKS_PER_TICK 塊，截斷後的下界若證明不了超標
          就整批不排入（否則每輪都排入註定被取消的 victim），並留下管理員可見的診斷
情境十五：來源集只保留計數最高的 N 塊——保留錯的 N 塊會讓下界證明不了超標，明顯超標的
          熱點被永久放過（同時釘住 top-N 的插入位置與替換決策）
情境十六：單 tick 的載入探測次數受額度封頂，且跨 fullType 有效（0-cache 只在同 bucket ＋
          同 fullType 之間共用，多型別的 victim 會各自重新探測同一批卸載來源）
情境十七：單一格子的物品數超過走訪額度時，計數必須跨 tick 續算（格數封頂不等於成本封頂：
          worldObjects 沒有容量上限），且單 tick 的走訪峰值不得超過額度
情境十八：victim 落在超大同格清單尾端時仍要找得到（find 必須反向掃，因為候選依 item ID
          由大到小挑而掉落物 append 在尾端）；victim 前面隔著超過額度的物件時要觸頂放掉
情境十九：刪除前必須讀**當前**上限而不是排入當時的快照——管理員可在執行期改 sandbox，
          照舊值刪會刪掉當前政策允許保留的物品
情境二十：同型的多個 victim 必須共用「來源讀不到」的結論（0-cache 以 bucket＋fullType 為界，
          否則每個 victim 各自重探同一批卸載來源）
情境二十一：多位玩家的掃描盒重疊時，重疊區塊只能掃一次——去重表必須跨 tick 存活，且
            fixture 要挑到讓「第二次命中」真的落在第二個 tick
情境二十二：玩家站在 z≠0 時，z=0 與當前層都要掃（少了這條，二樓玩家看不到樓下的堆積）
情境二十三：區塊清單的漸進建構——建構期間不掃描，且必須每 tick 前進到完成
情境二十四：物品清理的分類總開關（關閉時連超標也不動，重新開啟後要恢復）
情境二十五：單一熱點落盤失敗不得牽連其他熱點，例外仍要可見，且已寫出的熱點不得被重放
情境二十六：刪除爆發中途被停用時，已刪除的部分仍要落盤（落盤的第二個出口）
情境二十七：章的欄位精簡與舊格式遷移——同一小時同一人的章必須逐 byte 相同（容器封包的
            CompressIdenticalItems 命中前提）、寫新 key 要就地刪舊 key、舊存檔的章仍讀得到，
            且名字裡的欄位分隔符不得用來偽造時間
情境二十八：分桶判定必須讀新 MIC42_d 與舊 lastDroppedBy；少任一路徑就會把玩家丟棄物誤分
            到高容忍桶，而原 fixture 全用舊 key 時這個迴歸會靜默穿過
情境二十九：touch 指令的完整 server 呼叫鏈——首次蓋章、覆蓋偵測、touch_overwrite 聚合 log、
            touchAck 的 server 整點值；釘住 Commands.lua 的 readTouch 呼叫點
情境三十：不同操作歷史最後必須以同一順序插入 MIC42_d→MIC42_t；順序是
          CompressIdenticalItems 逐 byte 比對的一部分
情境三十一：AnimalGroupList 的 `*`／`all` 解析語意（Core 層純函式）
情境三十二：AnimalScanner 的真實掃描——`*` 讓未列群組進清理（釘住 sentinel 消費點）、
            remove 跨 tick 攤平且單 tick 不超過 ANIMALS_PER_TICK、總量仍等於
            ANIMALS_PER_ROUND、NaN 座標跳過並留診斷、清理中關掉開關要停手且已刪部分落盤
情境三十三：server 端 drop 路徑（OnProcessTransaction）真的寫新章格式且不留舊 key；
            釘住 DropStamp 的 stampDrop／stampMove 呼叫點（改名漏改只有實機才炸）
情境三十四：多個 bucket ＝ 多個 job——佇列要逐個推進（Kahlua 上 `#` 會因就地設 nil 而回 0
            的最小反例形態）、每輪額度跨 job 分配、每個 job 各一行 animal_clean，
            以及「額度用盡而根本沒被嘗試的 job」不得寫 animal_protected_over
情境三十五：client 端 touchAck 走 Core 的 writeTouch，寫新章格式且不留舊 key
            （第 1 輪點出的 client 半邊覆蓋缺口）
情境三十六：recount 邊界——原候選走出原玩家半徑後不再計入舊 bucket；單一 plan
            超過 visit budget 時 fail-closed 不刪並寫 animal_recount_unprovable；
            stray／zone 兩份 plan 各有 NaN 時 animal_nan 的 skipped 要加總
情境三十七：Tooltip client 消費端真的讀新章——有章物品走自訂 render、無章物品退回原 render，
            小時章會進 Calendar/SimpleDateFormat 格式化路徑
情境三十八：全域散養上限——離所有玩家超過 AnimalScanRadius 的已載入動物在 per-player
            分桶裡根本不存在，只有全域桶看得到；全域上限只管散養（圈養是玩家資產）、
            不對任何玩家發通知；兩個維度同時超標時同一隻不得被兩個 job 各刪一次
            （remove 之後 getSquare() 仍回原格、isDead() 仍是 false，判定只能靠
            candidate.removed 旗標）
情境三十九：農場繁殖上限——達上限時取消還沒出生的（懷孕、受精蛋）而不刪現有牲畜；
            由 EveryTenMinutes 武裝（遊戲時鐘）、OnTick 分批消化；懷孕按該物種一胎
            最大隻數預留額度；取消時兩個欄位必須成對清零（只關 fertilized 而留著
            fertilizedTime 會讓母禽永久不孕）；地面蛋要發 ItemStats；一整組相連圈地
            與其中所有群組每個 pass 合計只付一次 getAllDZones；逐群組覆寫
            （RanchBreedingOverrides）蓋過共用預設、覆寫 0＝該群組不抑制、
            共用預設 0 時覆寫仍獨自武裝
情境四十：農場清除——以「每座農場」（連通圈地）計數，兩段式警告（emergency 直清）；
            同 tick 走訪＝天然 recount（不持跨 tick 候選）；與 scanner 共用 3/tick 移除
            預算（各自 3/tick 會推翻活鎖降壓）；保護個體計入現存數但不可刪；NaN 計數
            不刪；雞舍內計數不進候選；幼體優先；警告記錄隨群組消失回收
情境四十一：清單產生器直通沙盒——token 級 WYSIWYG（預載原始 token 原樣保留、同 group
            upsert 原位替換、整值寫回）、權限 gate 鏡射封包層 Capability 守門、
            getOptionByName 先擋未宣告選項（set 對未知名拋 Java 例外）、SP 不送封包、
            MP 走 copy→sendToServer 的 vanilla 封包鏈

為什麼需要它：luac -p 只驗語法，抓不到「改了函式簽章但漏改呼叫點」這類執行期錯誤——
hotspotKey 從兩參數改成三參數時漏改了 processDeleteQueue 的呼叫點，要等第一件物品真的被
刪除才會炸。情境二～四則是守住 buildAccessibleIndex 改寫後的可及性判定不出現漏洞，
以及配置量不隨「範圍內有幾件物品」放大（Kahlua 每個 table 都是獨立的 KahluaTableImpl／
LinkedHashMap，不是標準 Lua 那種輕量 table，10 萬筆 record 實測約 35 MiB）。

限制：這是標準 Lua 5.x，不是遊戲用的 Kahlua。它能抓邏輯／arity／nil 錯誤與可及性回歸，
但**不能**證明 Kahlua 專屬行為（table.sort 遞迴深度、Java field 不暴露、rawget 呼叫形式）。
那些仍然只能靠反編譯查證與實機測試。
]]

local MEDIA = "MOD/MinidoracatCleanerFor42/Contents/mods/MinidoracatCleanerFor42/42/media/lua"

-- ===== 假的 PZ 全域 =====
-- 起始時間必須大於掃描間隔：queuePeriodicScan 的條件是 now - lastPeriodicAt >= interval，
-- 而 lastPeriodicAt 初值為 0。遊戲裡 getTimestampMs() 本來就是很大的系統時間
local nowMs = 5000000
-- epoch 秒（getTimestamp()，LuaManager.java:9259-9264）。刻意與 nowMs 分開：
-- 遊戲裡本來就是不同時鐘。STAMP_HOUR 是測試常數（刻意不用 local：main chunk 已逼近
-- Lua/Kahlua 的 200 locals 上限），情境 27-30 用來驗證小時取整。
STAMP_HOUR = 1787479200
local nowSec = STAMP_HOUR
local logLines = {}
local sentCommands = {}

function getTimestampMs() return nowMs end
function getTimestamp() return nowSec end
function isClient() return false end
function isServer() return true end
function writeLog(_, text) logLines[#logLines + 1] = text end
function getItemNameFromFullType(fullType) return fullType end
function getScriptManager() return { FindItem = function() return nil end } end
function sendServerCommand(playerObj, _, command, args)
    sentCommands[#sentCommands + 1] = { player = playerObj, command = command, args = args }
end
function sendRemoveItemFromContainer() end
function getText(key) return key end

-- getAllZones 供 AnimalScanner 的 buildZoneCache 用。刻意不透過 javaList（它在下面才宣告，
-- 這裡的 closure 抓不到），自己回 java 風格容器。預設無圈地，動物情境自行填 ANIMAL_ZONES
ANIMAL_ZONES = {}
DesignationZoneAnimal = {
    removeItemFromGround = function() end,
    getAllZones = function()
        local items = ANIMAL_ZONES
        return {
            size = function() return #items end,
            get = function(_, i) return items[i + 1] end,
        }
    end,
}

-- 這兩個開關供負面測試切換：保險屋拒絕、以及玩家沒有所在格
local safehouseAllows = true
local playerHasSquare = true
SafeHouse = { isSafehouseAllowLoot = function() return safehouseAllows end }

-- instanceof 只需分辨容器；假物件用 _isContainer 標記
function instanceof(obj, class)
    if class == "InventoryContainer" then
        return type(obj) == "table" and obj._isContainer == true
    end
    return false
end

SandboxVars = {
    MinidoracatCleanerFor42 = {
        MaxFloorItemsPerType = 10,
        MaxFloorItemsPerTypeArea = 40,
        HighToleranceMaxPerType = 100,
        HighToleranceMaxPerTypeArea = 400,
        HighToleranceList = "",
        ProtectList = "",
        TouchTraceEnabled = true,
        AllowManualDelete = true,
        ScanRadius = 16,
        ScanIntervalSeconds = 60,
    },
}

local tickHandlers, clientCommandHandlers, worldMenuHandlers = {}, {}, {}
-- OnGameStart／OnProcessTransaction 供 DropStamp 的 server 端 drop 路徑用；
-- OnServerCommand／OnCreatePlayer 供 Client／Tooltip 的 client 消費端用。
-- 全域而非 local：main chunk 的 200 locals 額度已滿（見檔頭 STAMP_HOUR 同註）
GAME_START_HANDLERS, TRANSACTION_HANDLERS, SERVER_COMMAND_HANDLERS, CREATE_PLAYER_HANDLERS = {}, {}, {}, {}
-- EveryTenMinutes 供 AnimalBreeding 的抑制 arming 用（GameTime.java:636-650 的遊戲分鐘事件）
TEN_MINUTE_HANDLERS = {}
Events = setmetatable({}, {
    __index = function(_, name)
        return {
            Add = function(fn)
                if name == "OnTick" then tickHandlers[#tickHandlers + 1] = fn
                elseif name == "OnClientCommand" then clientCommandHandlers[#clientCommandHandlers + 1] = fn
                elseif name == "OnFillWorldObjectContextMenu" then worldMenuHandlers[#worldMenuHandlers + 1] = fn
                elseif name == "OnGameStart" then GAME_START_HANDLERS[#GAME_START_HANDLERS + 1] = fn
                elseif name == "OnProcessTransaction" then TRANSACTION_HANDLERS[#TRANSACTION_HANDLERS + 1] = fn
                elseif name == "OnServerCommand" then SERVER_COMMAND_HANDLERS[#SERVER_COMMAND_HANDLERS + 1] = fn
                elseif name == "OnCreatePlayer" then CREATE_PLAYER_HANDLERS[#CREATE_PLAYER_HANDLERS + 1] = fn
                elseif name == "EveryTenMinutes" then TEN_MINUTE_HANDLERS[#TEN_MINUTE_HANDLERS + 1] = fn end
            end,
        }
    end,
})

-- java 風格容器（size()/get(i)，0-based）
local function javaList(items)
    local list
    list = {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
        -- ArrayList.addAll：抑制路徑要把 hutch 內的動物併進 getAnimalsConnected 的結果
        -- （照抄 vanilla ISDesignationAnimalZoneUI.lua:373）。真實的 getAnimalsConnected
        -- 回的是**新** ArrayList（DesignationZoneAnimal.java:436），所以 addAll 不會污染
        -- 引擎狀態——mock 的 zone 也必須每次回新 list 才忠於這一點
        addAll = function(_, other)
            local src = other and other._raw
            if src then
                for _, value in ipairs(src) do
                    items[#items + 1] = value
                end
            end
            return true
        end,
        -- HashMap.values()：Lua 端只會拿它去 addAll 或走 iterator
        values = function() return list end,
        iterator = function()
            local index = 0
            return {
                hasNext = function() return index < #items end,
                next = function()
                    index = index + 1
                    return items[index]
                end,
            }
        end,
        _raw = items,
    }
    return list
end

-- java.util.ArrayList 的最小暴露：AnimalBreeding 用 ArrayList.new() 當橋接容器
-- （getAnimalInside():values() 回 package-private 的 HashMap$Values，只能當引數不能當
-- receiver）。vanilla Lua 大量用例（ISItemSlot.lua:414 等）
ArrayList = { new = function() return javaList({}) end }

-- ===== 世界模型 =====
local world = {}
local gridLookups = 0   -- 用來證明「提早退出」真的沒去碰世界
-- 卸載輪的活性檢查用：只計 probeChunk 這一個區塊的查詢次數。全域 gridLookups 會被其他
-- 區塊的查詢滿足，證明不了「目標區塊真的被走訪過」——AGENTS.md 踩坑錄記過這個坑：
-- 上限／缺席類斷言必須配活性檢查，否則掃描先在別處返回時測試會空轉假通過
local probeChunk = nil
local probeLookups = 0
-- 掃描器對 probeChunk 查了幾次「載入狀態」。未載入的區塊現在會被整塊跳過（只查一次載入
-- 狀態、不再逐格 getGridSquare），所以活性檢查改成「確實查過載入狀態」＋「確實沒逐格查」
-- 兩條——後者順帶釘住那個省掉 64 次無效查詢的效能改善
local probeChunkChecks = 0
-- 全域載入探測次數（不限特定區塊）：area recount 的單 tick 探測上限用它斷言
local chunkCheckTotal = 0
-- 模擬「區塊未載入」：getGridSquare 一律回 nil（Lua 端走 IsoCell.java:3181-3183 分派，
-- dedicated server 進 ServerMap.java:682-687，單機進 IsoCell.java:3197-3206），但 world 裡的
-- square 與其上的物品原封不動——這正是引擎的真實狀態（資料在存檔裡，只是沒載進記憶體）。
-- 不可改成把 square 從 world 移除：countFloor 是遍歷 world 數的，那樣連「東西還在」都測不到
local unloadedChunks = {}
-- 模擬「掃描途中卸載」：對指定區塊，第一次被查載入狀態時照常回報已載入，第二次起連同
-- getGridSquare 一律回 nil。用「被查幾次載入狀態」而不是「掃了幾格」當門檻，是因為單一區塊
-- 的掃描會從哪一格跨到下一個 tick，取決於前面區塊吃掉多少預算——綁格數的話門檻會跟著浮動。
-- 一個區塊 64 格而每 tick 預算只有 48 格 ⇒ 掃描必定跨 tick，這正是「只在起頭查一次載入狀態」
-- 擋不住、而「每個 tick 重查」才擋得住的情境
local partialUnload = nil
local function partialGone(cx, cy, z)
    return partialUnload ~= nil
        and partialUnload.key == (cx .. "," .. cy .. "," .. z)
        and partialUnload.checks > 1
end
local function squareKey(x, y, z) return x .. "," .. y .. "," .. z end

local function getOrMakeSquare(x, y, z)
    local key = squareKey(x, y, z)
    if world[key] then return world[key] end
    local square = {
        _objs = {}, _containers = {}, _blocked = false,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
        getWorldObjects = function(self) return javaList(self._objs) end,
        getStaticMovingObjects = function() return javaList({}) end,
        getObjects = function(self) return javaList(self._containers) end,
        getVehicleContainer = function() return nil end,
        isBlockedTo = function(self) return self._blocked end,
        transmitRemoveItemFromSquare = function() end,
        removeWorldObject = function(self, worldObj)
            for i, o in ipairs(self._objs) do
                if o == worldObj then table.remove(self._objs, i) break end
            end
        end,
    }
    world[key] = square
    return square
end

function getCell()
    return {
        -- IsoCell.getAnimals()。預設 nil（＝世界沒有動物清單），既有情境因此完全不受
        -- AnimalScanner 的 onTick 影響；動物情境自行填 ANIMAL_ROSTER
        -- IsoCell.getAnimals() 走 cell 的 objectList（IsoCell.java:4573-4582），而
        -- `animal:remove()` → `delete()` → `removeFromWorld()` 會把自己從那份清單移除。
        -- 所以已移除的動物**下一輪掃描就看不到了**——這裡必須跟著過濾，否則已刪動物會
        -- 一直回到新一輪的計數裡（而它們的 getSquare() 仍回原格，見 makeTestAnimal 的
        -- 忠於引擎說明），把「刪到上限」變成永不收斂。
        -- 注意這只涵蓋「跨輪」：同一輪的 plan.list 直接持有 candidate 參照，不經這裡，
        -- 那條由生產程式碼的 candidate.removed 旗標負責。
        getAnimals = function()
            if not ANIMAL_ROSTER then
                return nil
            end
            local alive = {}
            for _, animal in ipairs(ANIMAL_ROSTER) do
                if not animal.isGone() then
                    alive[#alive + 1] = animal
                end
            end
            return javaList(alive)
        end,
        getGridSquare = function(_, x, y, z)
            gridLookups = gridLookups + 1
            local cx, cy = math.floor(x / 8), math.floor(y / 8)
            if probeChunk and z == probeChunk.z and cx == probeChunk.cx and cy == probeChunk.cy then
                probeLookups = probeLookups + 1
            end
            if unloadedChunks[cx .. "," .. cy .. "," .. z] then
                return nil
            end
            if partialGone(cx, cy, z) then
                return nil
            end
            return world[squareKey(x, y, z)]
        end,
        -- IsoCell.getChunkForGridSquare（IsoCell.java:334-358）：參數是 world-square 座標，
        -- 未載入回 nil。harness 以「該 chunk 內建過任何 square」代表引擎已把這塊載入，
        -- 並讓 unloadedChunks 一律視為未載入，與 getGridSquare 的判定保持一致
        getChunkForGridSquare = function(_, x, y, z)
            local cx, cy = math.floor(x / 8), math.floor(y / 8)
            -- 全域計數：area recount 的載入探測上限用它斷言（情境十六）。探測不逐格查 square，
            -- 所以 gridLookups 抓不到這條成本
            chunkCheckTotal = chunkCheckTotal + 1
            if probeChunk and z == probeChunk.z and cx == probeChunk.cx and cy == probeChunk.cy then
                probeChunkChecks = probeChunkChecks + 1
            end
            if partialUnload and partialUnload.key == (cx .. "," .. cy .. "," .. z) then
                partialUnload.checks = partialUnload.checks + 1
            end
            if unloadedChunks[cx .. "," .. cy .. "," .. z] or partialGone(cx, cy, z) then
                return nil
            end
            for px = cx * 8, cx * 8 + 7 do
                for py = cy * 8, cy * 8 + 7 do
                    if world[squareKey(px, py, z)] then
                        return { cx = cx, cy = cy, z = z }
                    end
                end
            end
            return nil
        end,
    }
end

local nextID = 1000
-- dropper 章一律以新格式（MIC42_d）建立。情境一到二十六必須跑真實寫入形狀，
-- 否則只練到 readDrop 的 legacy fallback（review：改回只讀舊 key 時 27 情境全綠）。
-- 舊格式相容讀取由 makeLegacyItem 與情境二十七⑥⑦、二十八覆蓋。
local function makeItemWith(fullType, dropKey, dropper)
    nextID = nextID + 1
    local modData = {}
    if dropper then modData[dropKey] = dropper end
    return {
        _id = nextID, _fullType = fullType, _modData = modData, _favorite = false, _container = nil,
        getID = function(self) return self._id end,
        getFullType = function(self) return self._fullType end,
        isFavorite = function(self) return self._favorite end,
        hasModData = function() return true end,
        getModData = function(self) return self._modData end,
        setWorldItem = function() end,
        getContainer = function(self) return self._container end,
    }
end

local function makeItem(fullType, dropper)
    return makeItemWith(fullType, "MIC42_d", dropper)
end

-- 0.3.0 舊格式 fixture：釘住「沒再被碰過的舊物品」的相容讀取（分桶與顯示）
local function makeLegacyItem(fullType, dropper)
    return makeItemWith(fullType, "MIC42_lastDroppedBy", dropper)
end

-- 哪張 overlay 屬於哪些底圖（ContainerOverlays.java:87-113 建的反查表）。
-- 沒登記在這裡的 overlay＝來路不明，修復必須放過它
local overlayOwners = {
    ["shelf_full"] = { "shelf_base" },
}

-- 家具容器：getParent 非 nil 才通得過 isSyncableContainer 的 MP 檢查。
-- getParent 回傳的是貨架本體（IsoObject），它身上掛著滿／空的 overlay 貼圖
local function makeContainer(owner)
    local c
    local parent = owner == "furniture" and {
        _sprite = "shelf_base",
        _overlay = "shelf_full",
        _inOverlayMap = true,     -- 底圖登記在容器 overlay 表裡＝真的是貨架
        _overlayUpdates = 0,
        _hotSaves = 0,
        getSprite = function(self) return { getName = function() return self._sprite end } end,
        getOverlaySprite = function(self)
            if not self._overlay then return nil end
            local name = self._overlay
            return { getName = function() return name end }
        end,
        getContainer = function(self) return self._container end,
        getContainerCount = function() return 1 end,
        getContainerByIndex = function(self) return self._container end,
        flagForHotSave = function(self) self._hotSaves = self._hotSaves + 1 end,
    } or nil
    c = {
        _items = {},
        _looted = false,
        _parent = parent,
        getItems = function(self) return javaList(self._items) end,
        isEmpty = function(self) return #self._items == 0 end,
        getCharacter = function() return owner == "player" and true or nil end,
        getParent = function(self) return self._parent end,
        getWorldItem = function() return nil end,
        setHasBeenLooted = function(self, value) self._looted = value end,
        isHasBeenLooted = function(self) return self._looted end,
        DoRemoveItem = function(self, item)
            for i, it in ipairs(self._items) do
                if it == item then table.remove(self._items, i) break end
            end
        end,
        add = function(self, item) self._items[#self._items + 1] = item; item._container = c; return item end,
    }
    if parent then
        -- 反向連結：讓 ItemPicker.updateOverlaySprite 能照 ContainerOverlays.java:147 的規則
        -- （容器空了就把 overlay 清成 nil）重算
        parent._container = c
    end
    return c
end

-- ContainerOverlays.java:139-178 的行為骨架：底圖沒登記在容器 overlay 表裡就把 overlay
-- 清成 nil（這正是誤判會抹掉工作站進度貼圖的原因），登記了則依件數重算
ItemPicker = {
    updateOverlaySprite = function(obj)
        if not obj then return end
        obj._overlayUpdates = (obj._overlayUpdates or 0) + 1
        if not obj._inOverlayMap or (obj._container and #obj._container._items == 0) then
            obj._overlay = nil
        end
    end,
}

-- ContainerOverlays.java:131-133 與 :135-137：底圖是否登記在容器 overlay 表裡，
-- 以及某張 overlay 反查得到哪些底圖（用來確認 overlay 真的出自容器系統）
--
-- overlayFetches 數的是「取得 overlay 表」本身的次數。它是引擎單例
-- （LuaManager.java:11976-11982 回 ContainerOverlays.instance），所以整份掃描工作只該取
-- 一次；放進 per-square 的修復函式就會變成每 tick SQUARES_PER_TICK 次 Kahlua→Java 往返。
-- 沒有這個計數器的話，把取得處搬回每格呼叫不會讓任何斷言轉紅（實測過），那條效能契約
-- 就等於沒被釘住
overlayFetches = 0
function getContainerOverlays()
    overlayFetches = overlayFetches + 1
    return {
        hasOverlays = function(_, obj) return obj._inOverlayMap == true end,
        getUnderlyingSpriteNames = function(_, overlayName)
            local owner = overlayOwners[overlayName]
            return owner and javaList(owner) or nil
        end,
    }
end

-- 地板物件被實際讀取的次數。掃描／recount／find 都得先 getItem 才知道那是什麼，所以這個
-- 計數器就是「走訪成本」的直接量測，用來斷言單 tick 的物件走訪額度（情境十七）
local itemReads = 0

local function putOnFloor(x, y, z, item)
    local square = getOrMakeSquare(x, y, z)
    local worldObj = {
        getItem = function(self)
            itemReads = itemReads + 1
            return self._item
        end,
        isIgnoreRemoveSandbox = function() return false end,
        getSquare = function() return square end,
        _item = item,
    }
    square._objs[#square._objs + 1] = worldObj
    return item
end

-- 放進去的是家具本體（IsoObject），容器掛在它身上——`square:getObjects()` 拿到的是它，
-- 容器修復與可及性索引都從這個物件出發，與真實引擎一致
local function putFurniture(x, y, z, container)
    local square = getOrMakeSquare(x, y, z)
    square._containers[#square._containers + 1] = container:getParent()
end

local playerInv = makeContainer("player")
-- 座標用變數而非常數：情境十二要驗「area 記錄是 per-player」——玩家搬家後，舊來源區塊
-- 不再屬於他的掃描盒，就不該再被併進他的來源集。z 也要可變：站在 z≠0 時掃描會同時排入
-- z=0 與當前層（見 newPeriodicBuild），那條分支需要專門的情境。其餘情境都不動這些值
local playerX, playerY, playerZ = 100, 100, 0
local player = {
    getX = function() return playerX end,
    getY = function() return playerY end,
    getZ = function() return playerZ end,
    getUsername = function() return "tester" end,
    getOnlineID = function() return 1 end,
    getCurrentSquare = function() return playerHasSquare and getOrMakeSquare(100, 100, 0) or nil end,
    getInventory = function() return playerInv end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
-- 線上玩家清單可換：情境十二會臨時加入第二位玩家，讓「別人的掃描盒」真的存在
local onlineRoster = nil
function getOnlinePlayers() return javaList(onlineRoster or { player }) end
function getPlayer() return player end
-- Client.lua 的 applyTouchAck 走 getSpecificPlayer(0..3) 找「名字對上的本機子玩家」
-- （分割畫面）。單一玩家的 harness 只要 index 0 回 player 即可
function getSpecificPlayer(index) return index == 0 and player or nil end

-- ===== 載入受測程式碼 =====
local loaded = {}
function require(name)
    if loaded[name] then return true end
    loaded[name] = true
    -- 帶斜線的是原版路徑（如 ISUI/ISCollapsableWindow），本 harness 不載入原版，直接放行
    if name:find("/", 1, true) then return true end
    for _, dir in ipairs({ "shared", "server", "client" }) do
        local chunk = loadfile(MEDIA .. "/" .. dir .. "/" .. name .. ".lua")
        if chunk then chunk() return true end
    end
    error("require 找不到: " .. name)
end

-- ===== 動物 mock（必須在 require AnimalScanner 之前就位）=====
-- 全域而非 local：main chunk 已逼近 Lua/Kahlua 的 200 locals 上限（見 STAMP_HOUR 同註）
ANIMAL_ROSTER = nil
-- Core 的 buildAnimalNameIndex 讀 `.animals` 的 `group` 欄位；AnimalScanner 的
-- getAnimalGroup 走 getDef():getGroup()。兩種形式都要有，否則只練到其中一條
ANIMAL_GROUPS = { rattus = "rat", hen = "chicken", doe = "deer", sow = "pig" }
AnimalDefinitions = { animals = {} }
for atype, group in pairs(ANIMAL_GROUPS) do
    AnimalDefinitions.animals[atype] = { group = group }
end
-- 一胎最大隻數：抑制路徑按它預留額度（AnimalData.java:191-202 的分娩直接建立
-- Rand.Next(minBaby, maxBaby+1) 隻）。取真實 vanilla 值的量級：rat 2-10、pig 5-10、
-- 雞是蛋生（一顆蛋一隻）
ANIMAL_MAX_BABY = { rattus = 10, hen = 1, doe = 1, sow = 10 }
function AnimalDefinitions.getDef(atype)
    local group = ANIMAL_GROUPS[atype]
    if not group then
        return nil
    end
    return {
        getGroup = function() return group end,
        getMaxBaby = function() return ANIMAL_MAX_BABY[atype] or 1 end,
    }
end

-- 地面蛋改完受精狀態後要發的 ItemStats（LuaManager.java:4340-4348）。計數而非只是 stub：
-- 「有沒有同步」是可斷言的行為，漏發會讓附近 client 繼續顯示舊的受精狀態
ITEM_STATS_SENT = {}
function sendItemStats(item)
    ITEM_STATS_SENT[#ITEM_STATS_SENT + 1] = item
end

-- opts：hatch（animalType，nil＝不是蛋）/ fertilized / fertilizedTime
function makeTestEgg(opts)
    return {
        _opts = opts,
        getAnimalHatch = function() return opts.hatch end,
        isFertilized = function() return opts.fertilized == true end,
        setFertilized = function(_, value) opts.fertilized = value end,
        getFertilizedTime = function() return opts.fertilizedTime or 0 end,
        setFertilizedTime = function(_, value) opts.fertilizedTime = value end,
    }
end

-- opts：nests（每個巢箱一份蛋陣列）/ inside（hutch 內的動物）
-- 巢箱以 0-based index 存取，且索引跑到 getMaxNestBox()**含**上界——vanilla 自己
-- 初始化 maxNestBox + 1 個（IsoHutch.java:117-119）
function makeTestHutch(opts)
    local nests = opts.nests or {}
    return {
        _opts = opts,
        getMaxNestBox = function() return #nests - 1 end,
        getNestBox = function(_, index)
            local eggs = nests[index + 1]
            if not eggs then
                return nil
            end
            return {
                getEggsNb = function() return #eggs end,
                getEgg = function(_, i) return eggs[i + 1] end,
            }
        end,
        getAnimalInside = function() return javaList(opts.inside or {}) end,
    }
end

-- opts：id / x / y / z / animals / hutches / ground / component
-- component 省略時就是自己一個元件。
-- **per-zone getter 忠於引擎**：getAnimals/getHutchs/getFoodOnGround 回引擎內部清單的
-- 直接參照（DesignationZoneAnimal.java:395/:431/:475，無複製）——mock 回包在 javaList
-- 裡的同一份 opts 表，生產程式碼若誤 addAll 就會污染 fixture 而被斷言抓到。
-- getAnimals 過濾已移除的動物：animal:remove() → removeFromWorld → dZone.removeAnimal
-- （IsoAnimal.java:1226-1228），移除後就不在 zone.animals 裡
function makeTestZone(opts)
    local zone
    zone = {
        _opts = opts,
        getId = function() return opts.id end,
        getX = function() return opts.x or 100 end,
        getY = function() return opts.y or 100 end,
        getZ = function() return opts.z or 0 end,
        getW = function() return opts.w or 10 end,
        getH = function() return opts.h or 10 end,
        getAnimals = function()
            local alive = {}
            for _, animal in ipairs(opts.animals or {}) do
                if not animal.isGone or not animal.isGone() then
                    alive[#alive + 1] = animal
                end
            end
            return javaList(alive)
        end,
        getHutchs = function() return javaList(opts.hutches or {}) end,
        getFoodOnGround = function()
            local objs = {}
            for _, egg in ipairs(opts.ground or {}) do
                objs[#objs + 1] = { getItem = function() return egg end }
            end
            return javaList(objs)
        end,
        _component = function() return opts.component or { zone } end,
    }
    return zone
end

-- getAllDZones(nil, zone, nil)：回整個連通元件（DesignationZoneAnimal.java:58-110）。
-- 計數器是效能契約的量尺：農場治理每個元件每個 pass 只准付一次（設計評審 codex lane
-- 的成本模型——它的遞迴內部對每個邊界格線性掃全域圈地清單，是最貴的原語）
GETALLDZONES_CALLS = 0
DesignationZoneAnimal.getAllDZones = function(_, zone, _)
    GETALLDZONES_CALLS = GETALLDZONES_CALLS + 1
    if not zone or not zone._component then
        return javaList({})
    end
    return javaList(zone._component())
end

-- vanilla 動作類的最小 stub：installDropHooks 會 deref 它們的方法再包一層，
-- 缺任一個就會在安裝階段 nil-deref 而讓整個 hook 註冊中斷（DropStamp 自己的註解已提過
-- ISGrabItemAction 那條，這裡把 shared/ 的三個補上）
ISDropWorldItemAction = { complete = function() return true end }
ISDropVehicleItemAction = { complete = function() return true end }
ISTransferAction = { transferItem = function() return nil end }

ANIMAL_REMOVED = {}
-- opts：id / atype / x / y / wild / baby / hutch / dzone / named
function makeTestAnimal(opts)
    local gone = false
    local animal
    animal = {
        _opts = opts,
        isGone = function() return gone end,
        getAnimalID = function() return opts.id end,
        getOnlineID = function() return opts.id end,
        getAnimalType = function() return opts.atype end,
        -- 座標刻意每次現算：NaN 情境要能在掃描之後才讓座標壞掉
        getX = function() return opts.x end,
        getY = function() return opts.y end,
        -- z 也要可變：NaN 防護必須三軸都查（vanilla 的比較器把 x/y/z 都送進距離計算），
        -- 寫死 0 的話「只有 z 壞掉」那個變異不會被任何斷言抓到
        getZ = function() return opts.z or 0 end,
        isWild = function() return opts.wild == true end,
        isBaby = function() return opts.baby == true end,
        -- **忠於引擎**：`IsoAnimal.remove()` → `delete()` → `removeFromSquare()`，而
        -- IsoMovingObject 只清 current/last（IsoMovingObject.java:705）、IsoObject 只把自己
        -- 從該格的清單移除（IsoObject.java:4539-4544）——**兩者都不清 this.square 欄位**，
        -- remove() 也不設 dead。所以移除後 getSquare() 仍回原格、isDead() 仍是 false。
        -- 讓 mock 說謊（移除後回 nil／true）會讓「同一隻被兩個 job 各刪一次」這類迴歸
        -- 靜默穿過：生產程式碼判定已刪除只能靠自己蓋的 candidate.removed 旗標，
        -- 測試必須逼它真的用那個旗標，而不是靠一個引擎不會給的訊號。
        -- isGone 是 harness 自己的統計用（liveAnimals），與引擎 API 無關。
        isDead = function() return opts.dead == true end,
        getSquare = function() return opts.noSquare and nil or getOrMakeSquare(100, 100, 0) end,
        getCustomName = function() return opts.named end,
        isOnHook = function() return false end,
        -- AnimalData。**不能回 nil**：抑制路徑要問 isPregnant／改 setPregnant，而
        -- classifyAnimal 也會問 getAttachedPlayer。欄位都寫回 opts，讓測試能在斷言時
        -- 直接讀 animal._opts 檢查「有沒有真的被取消」
        getData = function()
            return {
                getAttachedPlayer = function() return opts.attachedPlayer end,
                isPregnant = function() return opts.pregnant == true end,
                setPregnant = function(_, value) opts.pregnant = value end,
                getPregnancyTime = function() return opts.pregnancyTime or 0 end,
                setPregnancyTime = function(_, value) opts.pregnancyTime = value end,
                isFertilized = function() return opts.fertilized == true end,
                setFertilized = function(_, value) opts.fertilized = value end,
                getFertilizedTime = function() return opts.fertilizedTime or 0 end,
                setFertilizedTime = function(_, value) opts.fertilizedTime = value end,
            }
        end,
        isHeld = function() return false end,
        getVehicle = function() return nil end,
        getHutch = function() return opts.hutch end,
        getDZone = function() return opts.dzone end,
        remove = function()
            gone = true
            ANIMAL_REMOVED[#ANIMAL_REMOVED + 1] = opts.id
        end,
    }
    return animal
end

require "MinidoracatCleaner_Core"
require "MinidoracatCleaner_WorldScanner"
require "MinidoracatCleaner_Commands"
-- AnimalScanner：本次新增的 `*`／`all` sentinel 消費點與 remove 分幀都在它的 onTick 裡，
-- 不載入就只能靠測試自己複製判定式（review 抓到的空轉假通過）。ANIMAL_ROSTER 預設 nil，
-- 所以它掛進 tickHandlers 後對既有情境是 no-op。
require "MinidoracatCleaner_AnimalScanner"
-- AnimalBreeding：圈養抑制繁殖。預設 ANIMAL_ZONES 為空 ⇒ getAllZones():size() == 0 ⇒
-- 它的 onTick 立刻 return，對既有情境是 no-op
require "MinidoracatCleaner_AnimalBreeding"
-- DropStamp：server 端 drop 路徑的 stampDrop／stampMove 呼叫點（改名漏改只有實機才炸）
require "MinidoracatCleaner_DropStamp"

-- ===== 測試工具 =====
local failures = 0
local function check(ok, label)
    if ok then print("  PASS  " .. label)
    else failures = failures + 1; print("  FAIL  " .. label) end
end

local function runTicks(count)
    for _ = 1, count do
        for _, fn in ipairs(tickHandlers) do fn() end
    end
end

-- 觸發 EveryTenMinutes（AnimalBreeding 的抑制 arming 入口）。全域函式：main chunk 的
-- 200 locals 額度已滿
function fireTenMinutes()
    for _, fn in ipairs(TEN_MINUTE_HANDLERS) do fn() end
end

-- ===== 動物情境共用 helper =====
-- 全域函式而非 local：main chunk 已達 Lua 的 200 locals 硬上限（見 STAMP_HOUR 同註），
-- 而情境三十二、三十四都要用同一組工具。定義位置在 runTicks 之後才捕獲得到它
function countLogEvent(name)
    local total = 0
    for _, line in ipairs(logLines) do
        if line:find("[" .. name .. "]", 1, true) then
            total = total + 1
        end
    end
    return total
end

-- 只數動物警告，避免 WorldScanner 的 `[warn] kind=items` 讓生命週期斷言假紅／假綠
function countAnimalWarn()
    local total = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("kind=animals", 1, true) then
            total = total + 1
        end
    end
    return total
end

-- specs：{ { atype = "sow", count = 15, hutch = true, x = 500, y = 500 }, ... }
-- hutch 為真 ⇒ getHutch() 非 nil ⇒ classifyAnimal 回 "zone"（圈養路徑，不必建圈地）
-- x／y 省略時是 (100,100)＝主 player 腳邊。**指定遠座標是全域上限情境的必要條件**：
-- per-player 分桶要先通過 nearestPlayer(radius)，離所有玩家超過 AnimalScanRadius 的動物
-- 在那個維度裡根本不存在，只有全域桶看得到它們。
-- 刻意不動 makeTestAnimal 的 getSquare（仍固定回 100,100 那格）：classifyAnimal 只用它
-- 判「有沒有格子」，stray／zone 的實際判定走 getX/getY，而把座標接進 getSquare 會讓
-- NaN 情境（掃描後才把座標改壞）去建出 key 為 nan 的假格子
function seedAnimals(specs)
    ANIMAL_ROSTER = {}
    ANIMAL_REMOVED = {}
    local nextId = 9000
    for _, spec in ipairs(specs) do
        for _ = 1, spec.count do
            nextId = nextId + 1
            ANIMAL_ROSTER[#ANIMAL_ROSTER + 1] = makeTestAnimal({
                id = nextId,
                atype = spec.atype,
                x = spec.x or 100,
                y = spec.y or 100,
                hutch = spec.hutch and {} or nil,
            })
        end
    end
end

-- 存活隻數；帶 atype 只數該類型
function liveAnimals(atype)
    local total = 0
    for _, animal in ipairs(ANIMAL_ROSTER or {}) do
        if not animal.isGone() and (atype == nil or animal._opts.atype == atype) then
            total = total + 1
        end
    end
    return total
end

-- 清掉 warned：暫時把動物清單抽空跑一 tick，buckets 全空 ⇒ runAnimalScan 尾端的 stale
-- 回收會清掉所有警告記錄。不動 sandbox 上限，所以不會與情境自己的設定打架。
-- 少了這步，後一個子情境會沿用前一個的 warned 而在第一輪就直接確認（前提會漂）
function resetAnimalWarned()
    local saved = ANIMAL_ROSTER
    ANIMAL_ROSTER = {}
    runTicks(1)
    ANIMAL_ROSTER = saved
end

local function countFloor(fullType, stamped)
    local total = 0
    for _, square in pairs(world) do
        for _, worldObj in ipairs(square._objs) do
            local item = worldObj:getItem()
            if item:getFullType() == fullType then
                -- 走生產用的 readDrop（新舊 key 皆認），fixture 換格式時這裡不用跟著改
                local has = MinidoracatCleaner.readDrop(item) ~= nil
                if stamped == nil or has == stamped then total = total + 1 end
            end
        end
    end
    return total
end

-- 地板上該 fullType 現存的最大 item ID。用來驗「最新的先刪」政策：ID 遞增近似落地順序，
-- 所以清理過後剩下的應該都是較舊（ID 較小）的那些
local function maxFloorId(fullType)
    local best = nil
    for _, square in pairs(world) do
        for _, worldObj in ipairs(square._objs) do
            local item = worldObj:getItem()
            if item:getFullType() == fullType and (not best or item:getID() > best) then
                best = item:getID()
            end
        end
    end
    return best
end
-- 只數某一層的地板物品。情境二十二要驗「站在 z≠0 時 z=0 與當前層都會被掃」，而全域的
-- countFloor 把兩層加在一起、看不出哪層被清；分層數才能區分「兩層都清」與「只清一層」
local function countFloorAtZ(fullType, z)
    local n = 0
    for _, square in pairs(world) do
        if square:getZ() == z then
            for _, worldObj in ipairs(square._objs) do
                if worldObj:getItem():getFullType() == fullType then
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- ===== 情境一：混合來源的同種地面物品 =====
-- 全部落在區塊 (12,12,0)（x/y 皆 96..103），玩家站在 (100,100) 也在該區塊內，
-- 讓「每區塊」成為唯一觸發原因：區域上限 40／400 不會被 25／20 件碰到
print("情境一：自動清理的雙桶分流")
for i = 1, 20 do putOnFloor(96 + (i % 8), 96, 0, makeItem("Base.Log", nil)) end
for i = 1, 25 do putOnFloor(96 + (i % 8), 97, 0, makeItem("Base.Log", "griefer")) end

check(countFloor("Base.Log", false) == 20, "起始：無標記 20 件")
check(countFloor("Base.Log", true) == 25, "起始：有標記 25 件")

runTicks(400)
check(countFloor("Base.Log") == 45, "第一輪只警告、不刪")

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Log", false) == 20, "高容忍桶（無標記）完全沒被動到")
check(countFloor("Base.Log", true) == 10, "一般桶（有標記）刪到剛好等於上限 10")

local cleaned = 0
for _, line in ipairs(logLines) do
    if line:find("auto_clean", 1, true) then cleaned = cleaned + 1 end
end
check(cleaned >= 1, "auto_clean 記錄有寫出（刪除後的聚合輸出路徑沒炸）")

-- ===== 情境二：批次手動刪除與安全邊界 =====
print()
print("情境二：批次手動刪除的可及性判定")

local inBag = playerInv:add(makeItem("Base.Nails"))
local favorite = playerInv:add(makeItem("Base.Hammer"))
favorite._favorite = true

local shelf = makeContainer("furniture")
putFurniture(100, 100, 0, shelf)
local inShelf = { shelf:add(makeItem("Base.Screwdriver")), shelf:add(makeItem("Base.Saw")) }

local onFloor = putOnFloor(101, 100, 0, makeItem("Base.Plank", "tester"))

-- 範圍外（距離 5 格）：不得被刪
local farShelf = makeContainer("furniture")
putFurniture(105, 100, 0, farShelf)
local farItem = farShelf:add(makeItem("Base.Axe"))

-- 相鄰但被牆阻隔：不得被刪
local blockedShelf = makeContainer("furniture")
putFurniture(99, 100, 0, blockedShelf)
getOrMakeSquare(99, 100, 0)._blocked = true
local blockedItem = blockedShelf:add(makeItem("Base.Crowbar"))

local requested = { inBag:getID(), favorite:getID(), inShelf[1]:getID(), inShelf[2]:getID(),
                    onFloor:getID(), farItem:getID(), blockedItem:getID() }
for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "deleteItems", player, { ids = requested })
end

local function inContainer(container, item)
    for _, it in ipairs(container._items) do
        if it == item then return true end
    end
    return false
end

check(not inContainer(playerInv, inBag), "背包內的物品已刪除")
check(inContainer(playerInv, favorite), "最愛物品保留（防手滑保護生效）")
check(not inContainer(shelf, inShelf[1]) and not inContainer(shelf, inShelf[2]), "相鄰家具容器內的物品已刪除")
check(countFloor("Base.Plank") == 0, "地板物品已刪除")
check(inContainer(farShelf, farItem), "範圍外的物品未被刪除（可及性把關）")
check(inContainer(blockedShelf, blockedItem), "被阻隔格上的物品未被刪除（可及性把關）")

-- 刪空貨架必須同時解除兩道「卡住」：重生旗標與外觀貼圖。少任一項，玩家就得放一件
-- 東西進去再拿出來（＝走一次原版搬運）才會恢復正常
check(shelf:isHasBeenLooted(), "刪空的容器已標記 hasBeenLooted（物資重生不被卡住）")
check(shelf:getParent():getOverlaySprite() == nil, "刪空的貨架 overlay 貼圖已清除（外觀不再顯示滿架）")
check(farShelf:getParent():getOverlaySprite() ~= nil, "沒被刪到的貨架 overlay 貼圖保持不變")
check(not farShelf:isHasBeenLooted(), "沒被刪到的容器不會被誤標 hasBeenLooted")

local manual = 0
for _, line in ipairs(logLines) do
    if line:find("manual_delete", 1, true) then manual = manual + 1 end
end
check(manual == 1, "整批只寫一行 manual_delete 記錄（聚合寫入）")

-- ===== 情境三：提早退出 =====
-- 索引化若不帶「要找哪些 id」，右鍵刪背包裡的 1 件東西也會把周遭每個容器全部建成 entry。
-- 舊版 findAccessibleItem 是先查背包、命中就回傳，這個特性必須保住
print()
print("情境三：只刪背包內物品時不應掃描世界")

local solo = playerInv:add(makeItem("Base.Rope"))
-- 每位玩家 250ms 節流：不推進時間的話後續指令會被整包丟棄
nowMs = nowMs + 1000
gridLookups = 0
for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "deleteItems", player, { ids = { solo:getID() } })
end
check(not inContainer(playerInv, solo), "背包內的單件物品已刪除")
check(gridLookups == 0, "完全沒有查詢任何地圖格（提早退出生效）")

-- 反面：要找的 id 有一個搆不到時，不得因為提早退出而略過可及性把關
local reachable = playerInv:add(makeItem("Base.Twine"))
local stillFar = farShelf:add(makeItem("Base.Sledgehammer"))
nowMs = nowMs + 1000
gridLookups = 0
for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "deleteItems", player, { ids = { reachable:getID(), stillFar:getID() } })
end
check(not inContainer(playerInv, reachable), "搆得到的那件仍被刪除")
check(inContainer(farShelf, stillFar), "搆不到的那件仍未被刪除（提早退出沒有開後門）")
check(gridLookups > 0, "有搆不到的 id 時仍會完整掃描（不會誤判為已完成）")

-- ===== 情境四：可及性的負面案例與配置上限 =====
print()
print("情境四：拒絕路徑與記憶體配置上限")

local function indexSize(index)
    local n = 0
    for _ in pairs(index) do n = n + 1 end
    return n
end

-- 保險屋拒絕：世界端全部搆不到，但玩家自己的背包不受影響
local inBagAgain = playerInv:add(makeItem("Base.Nails"))
local shelfItem = shelf:add(makeItem("Base.Hammer"))
safehouseAllows = false
local denied = MinidoracatCleaner.buildAccessibleIndex(player, 1, { inBagAgain:getID(), shelfItem:getID() })
safehouseAllows = true
check(denied[inBagAgain:getID()] ~= nil, "保險屋拒絕時，自己背包內的物品仍可及")
check(denied[shelfItem:getID()] == nil, "保險屋拒絕時，世界容器內的物品不可及")

-- playerSquare 為 nil：世界端 fail-closed，背包仍可用
playerHasSquare = false
local noSquare = MinidoracatCleaner.buildAccessibleIndex(player, 1, { inBagAgain:getID(), shelfItem:getID() })
playerHasSquare = true
check(noSquare[inBagAgain:getID()] ~= nil, "無所在格時，自己背包內的物品仍可及")
check(noSquare[shelfItem:getID()] == nil, "無所在格時，世界端 fail-closed")

-- 配置上限：範圍內塞很多件，但只點名 1 個「不存在」的 id
for i = 1, 300 do shelf:add(makeItem("Base.Screw")) end
local bogus = MinidoracatCleaner.buildAccessibleIndex(player, 1, { 999999999 })
check(indexSize(bogus) == 0, "只點名不存在的 id 時，完全不配置任何 record（300 件在範圍內）")

local oneReal = MinidoracatCleaner.buildAccessibleIndex(player, 1, { shelfItem:getID(), 999999999 })
check(indexSize(oneReal) == 1, "點名 1 實 1 虛時只配置 1 筆 record，不隨範圍內件數放大")

-- 走訪量上限：配置量封頂之外，翻找本身也要有硬天花板。少了它，一個不存在的 id 就能
-- 讓 server 主執行緒翻完範圍內每個容器（ItemNumbersLimitPerContainer 預設 0＝無件數上限）。
-- 這裡把上限暫時調小來驗機制——測的是「會不會停」，不是 20000 這個校準值
local realLimit = MinidoracatCleaner.CONSTANTS.INDEX_VISIT_LIMIT
MinidoracatCleaner.CONSTANTS.INDEX_VISIT_LIMIT = 20

-- 貨架上已有 300+ 件，遠超過調小後的上限；最後才放的這件在走訪順序上排在上限之後
local pastCap = shelf:add(makeItem("Base.Wire"))
local capped = MinidoracatCleaner.buildAccessibleIndex(player, 1, { pastCap:getID() })
check(capped[pastCap:getID()] == nil, "走訪量觸頂即停：上限之後的物品不會被找到（不再翻完整個貨架）")

-- 觸頂是「少做事」不是「亂做事」：背包在世界之前登錄，仍必須命中
local inBagStill = playerInv:add(makeItem("Base.Needle"))
local cappedBag = MinidoracatCleaner.buildAccessibleIndex(player, 1, { inBagStill:getID() })
check(cappedBag[inBagStill:getID()] ~= nil, "觸頂上限不影響背包內物品（先登錄、提早收工）")

-- nil entry 不得成為越過上限的破口。Java 的 ArrayList 可以含 null（size 照算、get 回 null），
-- 而 visited 是無條件遞增的——若停止檢查只寫在 `if item then` 內，一串 nil 就能整段翻過去。
-- 這裡的假清單就是那個形狀：size 回報 30，前 25 筆 get 回 nil，目標排在上限之後。
-- 另附 get() 次數 oracle：只斷言「目標沒被找到」擋不住這個迴歸（少了計數，實作可能是
-- 翻完全部才碰巧沒命中）
local nilProbeGets = 0
local nilProbeTarget = makeItem("Base.Saw")
local nilProbeShelf = makeContainer("furniture")
nilProbeShelf.getItems = function()
    return {
        size = function() return 30 end,
        get = function(_, i)
            nilProbeGets = nilProbeGets + 1
            if i == 25 then return nilProbeTarget end
            return nil
        end,
    }
end
-- 擺在 (100,99,0)：格子掃描順序是 y 由小到大，這格排在玩家腳下那格（100,100,0，
-- 站著 302 件的貨架）**之前**。擺在後面的話會先在貨架上觸頂返回，probe 根本走不到，
-- 兩條斷言就變成空轉的假通過（實測會如此）
putFurniture(100, 99, 0, nilProbeShelf)
-- 拿掉 overlay：這個 fixture 只為了驗走訪上限，不該同時符合情境五「被刪空待修復」的指紋
-- （空 ＋ 未搜刮 ＋ 掛著 overlay），否則會讓那邊的 repaired 計數多一個而誤報失敗
nilProbeShelf._parent._overlay = nil

local nilProbe = MinidoracatCleaner.buildAccessibleIndex(player, 1, { nilProbeTarget:getID() })
-- 活性斷言先行：沒有它，「probe 根本沒被掃到」與「上限正確擋住」在結果上無法區分
check(nilProbeGets > 0, "nil probe 確實被走訪到（活性檢查，避免下面兩條變成空轉的假通過）")
check(nilProbe[nilProbeTarget:getID()] == nil, "一串 nil entry 不能越過走訪上限（上限之後的目標仍找不到）")
check(nilProbeGets <= 20 + 2, "nil entry 確實計入走訪量（取件次數收在上限附近，非翻完 30 筆）")

MinidoracatCleaner.CONSTANTS.INDEX_VISIT_LIMIT = realLimit

-- 還原上限後，同一件搆得到的物品必須重新找得到（證明截斷是上限造成、非其他把關）
local afterRestore = MinidoracatCleaner.buildAccessibleIndex(player, 1, { pastCap:getID() })
check(afterRestore[pastCap:getID()] ~= nil, "還原上限後同一件物品重新可及（截斷確實來自走訪上限）")

-- ===== 情境五：週期掃描順手修復被刪空的容器 =====
-- 指紋＝空 ＋ hasBeenLooted 為 false ＋ 卻還掛著 overlay。三種**不該**被碰的狀態各放一個
-- 當對照組，確認修復不會外溢到原版本來就正常的容器
print()
print("情境五：週期掃描修復被刪空的容器")

-- 放**兩個**壞掉的：只有一個時，「只寫一行 log」無法區分「逐容器輸出」與「整趟聚合」
local damaged = makeContainer("furniture")            -- 預設就是壞掉的指紋
putFurniture(102, 102, 0, damaged)
local damaged2 = makeContainer("furniture")
putFurniture(102, 103, 0, damaged2)

local natural = makeContainer("furniture")            -- 天生骰空：從來沒被賦予 overlay
natural:getParent()._overlay = nil
putFurniture(103, 102, 0, natural)

local lootedClean = makeContainer("furniture")        -- 玩家正常搬空：旗標已設、貼圖已清
lootedClean:getParent()._overlay = nil
lootedClean:setHasBeenLooted(true)
putFurniture(104, 102, 0, lootedClean)

local stocked = makeContainer("furniture")            -- 架上真的有貨：不得動它
stocked:add(makeItem("Base.Apple"))
putFurniture(105, 102, 0, stocked)

-- B42 實體工作站：也有空容器、也掛著 overlay，但那是製作進度貼圖（走 SpriteOverlayConfig，
-- 底圖不在容器 overlay 表裡）。誤判的話會同時「憑空開始重生物資」與「抹掉進度貼圖」
local craftStation = makeContainer("furniture")
craftStation:getParent()._overlay = "leather_drying_50"
craftStation:getParent()._inOverlayMap = false
putFurniture(106, 102, 0, craftStation)

-- 第三方 MOD 在**真正的貨架底圖**上掛了自己的 overlay：底圖檢查會過，但反查表裡沒有
-- 這張 overlay → 來路不明，必須放過（否則等於砸掉別家 MOD 的畫面）
local moddedShelf = makeContainer("furniture")
moddedShelf:getParent()._overlay = "thirdparty_decor_01"
putFurniture(107, 102, 0, moddedShelf)

nowMs = nowMs + 61000
runTicks(600)

check(damaged:isHasBeenLooted() and damaged2:isHasBeenLooted(), "兩個壞掉的容器都補上 hasBeenLooted（重生解鎖）")
check(damaged:getParent():getOverlaySprite() == nil, "壞掉的貨架 overlay 已清除")
check(damaged:getParent()._hotSaves > 0, "修復後有 flagForHotSave（重啟不會打回原形）")
check(not natural:isHasBeenLooted(), "天生骰空的容器未被誤標（沒有無中生有的重生）")
check(not stocked:isHasBeenLooted(), "架上有貨的容器未被誤標")
check(stocked:getParent():getOverlaySprite() ~= nil, "架上有貨的容器 overlay 保持不變")
check(lootedClean:getParent()._hotSaves == 0, "已經正常的容器完全沒被寫入（修復不外溢）")
check(not craftStation:isHasBeenLooted(), "實體工作站未被誤標（不會憑空開始重生物資）")
check(craftStation:getParent():getOverlaySprite() ~= nil, "實體工作站的製作進度貼圖沒被抹掉")
check(not moddedShelf:isHasBeenLooted(), "第三方 overlay 的貨架未被誤標（來路不明就放過）")
check(moddedShelf:getParent():getOverlaySprite() ~= nil, "第三方 MOD 掛的 overlay 沒被抹掉")

local repairLogs = {}
for _, line in ipairs(logLines) do
    if line:find("container_repair", 1, true) then repairLogs[#repairLogs + 1] = line end
end
check(#repairLogs == 1, "整趟掃描只寫一行 container_repair 記錄（聚合寫入）")
check(repairLogs[1] and repairLogs[1]:find("repaired=2", 1, true) ~= nil,
    "那一行涵蓋兩個容器（repaired=2，證明是聚合而非逐容器輸出）")

-- 第二輪：世界已修完，指紋消失，不該再寫任何 container_repair。
-- 同時量 overlay 表的提取次數：它是引擎單例，每份掃描工作只該取一次。
nowMs = nowMs + 61000
local fetchBefore = overlayFetches
gridLookups = 0
runTicks(600)
local fetchDelta = overlayFetches - fetchBefore
local repairLogsAfter = 0
for _, line in ipairs(logLines) do
    if line:find("container_repair", 1, true) then repairLogsAfter = repairLogsAfter + 1 end
end
check(repairLogsAfter == 1, "第二輪掃描零新增（修完即收斂，不會重複處理）")

-- 活性先行：沒有這條，「提取次數很少」也可能只是因為這一輪根本沒有工作跑
check(gridLookups > 0,
    "這一輪真的有掃描（查格 " .. gridLookups .. " 次；沒有這條，下面的少量提取可能只是空轉）")
-- 上限寫死成 4：一輪裡最多一個 periodic 加少數 dirty job，每個 job 取一次。
-- 刻意不寫成「等於 job 數」或去讀常數——自我參照的斷言釘不住任何東西。
-- 若把 getContainerOverlays() 搬回 repairBrokenContainers 內（每格一次），這個數字會
-- 直接變成上面那個查格數的同一量級（上千），斷言立刻轉紅
check(fetchDelta >= 1 and fetchDelta <= 4,
    "overlay 表每份工作只取一次（實際 " .. fetchDelta .. " 次，上限 4）")
check(fetchDelta * 50 < gridLookups,
    "提取次數與走訪格數不同量級（" .. fetchDelta .. " vs 查格 " .. gridLookups
        .. "；釘住『不是 per-square 取得』）")

-- ===== 情境六：Kahlua 沒有的標準 Lua 全域（靜態掃描）=====
-- 這個 harness 跑在標準 Lua 上，next/assert/xpcall 全都存在，所以「執行測試」在架構上
-- 永遠抓不到誤用——0.2.2 的 next(index) 就是這樣溜到正式服，讓動物清理每輪拋
-- 「Object tried to call nil」而整輪中斷（正式服 server-console 累積 91 次）。
-- Kahlua 的 BaseLib 只註冊 collectgarbage/error/getfenv/getmetatable/pcall/print/
-- rawequal/rawget/rawset/select/setfenv/setmetatable/tonumber/tostring/type/unpack；
-- pairs/ipairs 另由 TableLib 註冊，可用。以下三個在整個 kahlua 樹都找不到。
print()
print("情境六：Kahlua 缺少的標準 Lua 全域（原始碼掃描）")

local SOURCES = {
    "shared/MinidoracatCleaner_Core.lua",
    "shared/MinidoracatCleaner_DropStamp.lua",
    "server/MinidoracatCleaner_WorldScanner.lua",
    "server/MinidoracatCleaner_AnimalScanner.lua",
    "server/MinidoracatCleaner_Commands.lua",
    "client/MinidoracatCleaner_Client.lua",
    "client/MinidoracatCleaner_ContextMenu.lua",
    "client/MinidoracatCleaner_Tooltip.lua",
    "client/MinidoracatCleaner_Picker.lua",
    "client/MinidoracatCleaner_Skin.lua",
}
local FORBIDDEN = { "next", "assert", "xpcall" }

local hits = {}
for _, rel in ipairs(SOURCES) do
    local fh = io.open(MEDIA .. "/" .. rel)
    if fh then
        local lineNo = 0
        for line in fh:lines() do
            lineNo = lineNo + 1
            local code = line:match("^(.-)%-%-") or line   -- 去掉行註解
            for _, name in ipairs(FORBIDDEN) do
                local pos = 1
                while true do
                    local s, e = code:find(name .. "%s*%(", pos)
                    if not s then break end
                    -- 前一字元若是識別字元／冒號／點，代表是方法或欄位（如 iter:next()），不算
                    local prev = s > 1 and code:sub(s - 1, s - 1) or " "
                    if not prev:match("[%w_:%.]") then
                        hits[#hits + 1] = rel .. ":" .. lineNo .. " 用了 " .. name .. "()"
                    end
                    pos = e + 1
                end
            end
        end
        fh:close()
    else
        hits[#hits + 1] = "讀不到 " .. rel
    end
end

for _, h in ipairs(hits) do print("        " .. h) end
check(#hits == 0, "沒有使用 Kahlua 不存在的全域（next／assert／xpcall）")

-- 同一類「harness 跑標準 Lua 所以永遠測不到」的 Kahlua 差異：**佇列不得就地設 nil**。
-- Kahlua 的 rawset(k, nil) 會從底層 LinkedHashMap 刪掉該 key（KahluaTableImpl.java:59-62），
-- 而 `#` 走 KahluaUtil.len 的二分搜尋、上界只有 2*size（:147-148 → KahluaUtil.java:436-457）
-- ——t[1] 一旦不存在就回 0。標準 Lua 的 luaH_getn 看 t[#array] 非 nil 即回長度，所以
-- 「跑得過測試」完全不代表在遊戲裡正確。實際踩過：移除佇列消化完第一個 job 後把該槽設 nil，
-- 於是 `#removalQueue` 變 0、第二個以後的 job 被整表丟棄且從未落盤。
-- 正解是只推進 head、排空時整表重置（WorldScanner 的 deleteQueue 同款）。
local queueHits = {}
for _, rel in ipairs(SOURCES) do
    local fh = io.open(MEDIA .. "/" .. rel)
    if fh then
        local lineNo = 0
        for line in fh:lines() do
            lineNo = lineNo + 1
            local code = line:match("^(.-)%-%-") or line
            -- `<某某>Queue[ ... ] = nil`
            if code:find("[%w_]+[Qq]ueue%s*%[[^%]]*%]%s*=%s*nil") then
                queueHits[#queueHits + 1] = rel .. ":" .. lineNo
            end
        end
        fh:close()
    end
end
for _, h in ipairs(queueHits) do print("        " .. h) end
check(#queueHits == 0,
    "沒有對佇列就地設 nil（Kahlua 的 # 會因此回 0，把後續項目靜默丟棄）")

-- ===== 情境七：生成選單的預設值 =====
-- 上面的 SandboxVars 存根**故意**不含 DebugMenuEnabled，走的正是「新存檔／管理員沒設過」
-- 那條 DEFAULTS fallback 路徑。這條要是回歸（DEFAULTS 誤寫 true），批量生成動物又會無條件
-- 掛在單人玩家的右鍵選單上——正是 Workshop 上被回報的那個問題。
print()
print("情境七：批量生成動物預設不出現")

local sandbox = SandboxVars.MinidoracatCleanerFor42
check(sandbox.DebugMenuEnabled == nil, "前提：存根未設此選項（走 DEFAULTS）")
check(MinidoracatCleaner.getOption("DebugMenuEnabled") == false, "沒設定時預設關閉")

-- 只驗 getOption 不夠：把 Picker 那行條件式寫反，上面兩條照樣會過。以下把真正的
-- OnFillWorldObjectContextMenu handler 拉進來跑完整顯示矩陣。UI 存根只要撐得住
-- 載入期的 derive 與選單期的 addOption／addSubMenu，不需要真的畫任何東西。
local debugMode, clientMode, adminMode, accessLevel = false, false, false, "player"
function isDebugEnabled() return debugMode end
function isAdmin() return adminMode end
function getAccessLevel() return accessLevel end
function getSpecificPlayer() return player end

local function fakeMenu()
    local menu = { labels = {} }
    function menu:addOption(label)
        self.labels[#self.labels + 1] = label
        return { label = label }
    end
    function menu:addSubMenu() end
    return menu
end

ISCollapsableWindow = { derive = function() return {} end }
-- Picker 的 VirtualList cell 在載入期 derive（實機由 ISCollapsableWindow 的 require 鏈
-- 保證 ISPanel 存在，ISCollapsableWindow.lua:1）；harness 給同款極簡 stub
ISPanel = { derive = function() return {} end }
-- Picker 檔頭在載入期取 UIFont.Medium 當字級常數（實機 client 環境恆有此全域）
UIFont = UIFont or { Small = "Small", Medium = "Medium" }
ISContextMenu = { getNew = function() return fakeMenu() end }

local realIsClient, realIsServer = isClient, isServer
require "MinidoracatCleaner_Picker"
check(#worldMenuHandlers == 1, "Picker 已註冊世界右鍵選單 handler")

local fakeSquare = { getX = function() return 0 end, getY = function() return 0 end,
                     getZ = function() return 0 end }
local worldObjects = { { getSquare = function() return fakeSquare end } }

-- 回傳這個情境下右鍵選單實際掛出來的項目標籤（getText 存根原樣回傳 key）
local function menuLabels(opts)
    debugMode = opts.debug or false
    clientMode = opts.mp or false
    adminMode = opts.admin or false
    accessLevel = opts.admin and "admin" or "player"
    sandbox.DebugMenuEnabled = opts.option
    isClient = function() return clientMode end
    isServer = function() return clientMode end   -- SP 兩者皆 false，MP 客戶端只看 isClient
    local menu = fakeMenu()
    worldMenuHandlers[1](1, menu, worldObjects, false)
    isClient, isServer = realIsClient, realIsServer
    local has = {}
    for _, label in ipairs(menu.labels) do has[label] = true end
    return has, #menu.labels
end

local PICKER = "IGUI_MinidoracatCleaner_PickerOpen"
local SPAWN = "IGUI_MinidoracatCleaner_BatchSpawn"

local has, n = menuLabels({})
check(has[PICKER] and not has[SPAWN] and n == 1, "單人＋選項關：只有清單產生器，沒有生成選單")

has = menuLabels({ option = true })
check(has[PICKER] and has[SPAWN], "單人＋選項開：生成選單出現")

has = menuLabels({ debug = true })
check(has[PICKER] and has[SPAWN], "單人＋-debug：選項關著也照樣出現")

has, n = menuLabels({ mp = true, option = true })
check(n == 0, "MP 一般玩家：即使選項開著也整個選單都拿不到")

has = menuLabels({ mp = true, admin = true })
check(has[PICKER] and not has[SPAWN], "MP 管理員＋選項關：清單產生器有、生成選單沒有")

has = menuLabels({ mp = true, admin = true, option = true })
check(has[PICKER] and has[SPAWN], "MP 管理員＋選項開：兩者都在")

sandbox.DebugMenuEnabled = nil

-- ===== 情境八：警告記錄不因區塊卸載而被誤判「已解決」 =====
-- 舊版 pruneChunkWarnings 把「本輪一格都沒數到」與「數過了、已回到上限內」當成同一件事，
-- 於是玩家一走遠、區塊一卸載，警告記錄就被當成已解決刪掉，下一輪重新從零計時，永遠等不到
-- ensureWarning 的「第二次仍超標」。正式服 log 的症狀是同一個 hotspot 反覆寫出「首次警告」
-- 卻從不清理。這條回歸守住 chunk.observed 判定：沒完整觀測到的區塊一律走閒置年齡回收，不當已解決。
print()
print("情境八：區塊卸載時警告記錄必須存活")

-- 專屬區塊 (14,14)（x/y 皆 112..119，仍落在 ScanRadius 16 涵蓋的 cx/cy 10..14 內）＋一個
-- 其他情境沒用過的 fullType。**世界內容**與前七個情境分離，但 warned／logLines／nowMs 是
-- 全域共用，且這裡每一輪 periodic 都會連帶重掃 cx/cy 10..14 內其他情境的 fixture——目前無
-- 實際污染（Base.Log 剩 10 件恰為上限、不再觸發），但增修斷言時要重新確認這件事
local SHEET_CX, SHEET_CY = 14, 14
for i = 1, 25 do putOnFloor(112 + (i % 8), 112, 0, makeItem("Base.Sheet", "dumper")) end
check(countFloor("Base.Sheet") == 25, "起始：25 件（每區塊上限 10）")

local function sheetWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("Base.Sheet", 1, true) then n = n + 1 end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(400)
check(countFloor("Base.Sheet") == 25, "第一輪只警告、不刪")
check(sheetWarns() == 1, "第一輪寫出一則警告")

-- 卸載整個區塊：物品一件沒少，只是查不到（見 unloadedChunks 宣告處的說明）
local SHEET_CHUNK = SHEET_CX .. "," .. SHEET_CY .. ",0"
unloadedChunks[SHEET_CHUNK] = true

probeChunk = { cx = SHEET_CX, cy = SHEET_CY, z = 0 }
probeLookups = 0
probeChunkChecks = 0
nowMs = nowMs + 61000
runTicks(400)
check(probeChunkChecks > 0, "活性：卸載輪確實查過該區塊的載入狀態（否則以下兩條是空轉）")
check(probeLookups == 0, "未載入的區塊整塊跳過，沒有逐格做必定回 nil 的查詢")
check(sheetWarns() == 1, "卸載輪沒有重新警告（記錄沒被誤判已解決而刪除）")
check(countFloor("Base.Sheet") == 25, "卸載輪查不到東西，也就沒刪")

-- 重新載入：記錄若存活，這一輪 ensureWarning 就會回 true 而直接執行清理
unloadedChunks[SHEET_CHUNK] = nil
probeChunk = nil
nowMs = nowMs + 61000
runTicks(400)
check(sheetWarns() == 1, "重載輪仍未重新警告（沿用卸載前那一筆記錄）")
check(countFloor("Base.Sheet") == 10, "沿用舊記錄直接清到上限 10（跨卸載的確認鏈沒斷）")

-- 第四輪：世界已回到上限內（10 件）且區塊可觀測 → reasons 不含該 hotspot →
-- pruneChunkWarnings 必須**即時**刪掉警告記錄（reasons 分支）。
-- 這一輪是釘住 consumeScanQueue 裡那個 chunk.observed 標記的唯一手段：少了它判斷式恆假，
-- 記錄改走閒置分支而在 20 分鐘內存活，於是下面補貨後不會重新警告、直接被清掉。
-- 不能省掉這一輪直接補貨：清理發生在 finishJob 之後的 delete queue，執行清理那一輪的
-- reasons 仍然是超標，記錄要等到這個「已達標」的完整輪次才會被回收
nowMs = nowMs + 61000
runTicks(400)
check(countFloor("Base.Sheet") == 10, "已達標輪不再多刪")

for i = 1, 15 do putOnFloor(112 + (i % 8), 113, 0, makeItem("Base.Sheet", "dumper")) end
nowMs = nowMs + 61000
runTicks(400)
check(sheetWarns() == 2, "舊記錄已即時回收，再次超標時重新警告（釘住 chunk.observed 標記）")
check(countFloor("Base.Sheet") == 25, "重新警告的那一輪只警告、不刪")

-- 閒置回收（洩漏端）：未觀測的記錄不會永遠留著——年齡超過 staleMs
-- ＝ScanIntervalSeconds × WARN_STALE_INTERVALS（60s×20＝20 分鐘）就該被丟掉。
-- 這條守住 pruneChunkWarnings 的 elseif 分支；少了它 warned 會隨探索熱點無界滯留。
-- 附帶記錄本次修正的已知限制：正式服一輪實測 8-46 分鐘，超過 20 分鐘的輪次下
-- 未觀測記錄仍會在同一次 finishJob 被回收（見 pruneChunkWarnings 的「已知限制」段）
unloadedChunks[SHEET_CHUNK] = true
nowMs = nowMs + 1300000
runTicks(400)
unloadedChunks[SHEET_CHUNK] = nil
nowMs = nowMs + 61000
runTicks(400)
check(sheetWarns() == 3, "未觀測超過 staleMs 的記錄已被回收（重載後重新警告，不是直接清理）")
check(countFloor("Base.Sheet") == 25, "回收後回到首次警告狀態，本輪不刪")

print()
print("情境九：area-scope 記錄同樣不得因區塊卸載而被誤判「已解決」")

-- 刻意**不**預建其他區塊的空 square：mock 的 getGridSquare 只回 world 裡建過的 square，
-- 所以 ScanRadius 16 涵蓋的 25 個區塊裡，除了本情境的五個之外全是 unseen——這正是正式環境
-- 的常態（掃描盒比引擎載入視窗大一圈，玩家站 z≠0 時整層都回 null，見 finishJob 的 area
-- 回收註解）。回收判定只看「這筆記錄的計數來源」是否有區塊未被觀測，所以在這種永遠不完整
-- 的區域裡照樣能正確分辨；若判定寫成「區域內任一區塊未 seen」，下面「已達標輪即時回收」
-- 那條就會因為恆真而失敗——這個配置就是那個設計錯誤的回歸網

-- 每個區塊 9 件（未達 chunk 上限 10，chunk-scope 全程不參與）、五個區塊共 45 件（超過
-- area 上限 40）。這是唯一能單獨測到 area 路徑的配置。五個區塊都在 cx=10（x 80..87），
-- 落在 ScanRadius 16 算出的 cx/cy 10..14 內，且與情境一（12,12）／情境八（14,14）不重疊
local SOCK_ROWS = { 80, 88, 96, 104, 112 }
for _, y in ipairs(SOCK_ROWS) do
    for i = 1, 9 do putOnFloor(80 + (i % 8), y, 0, makeItem("Base.Sock", "dumper")) end
end
check(countFloor("Base.Sock") == 45, "起始：45 件（每區塊 9 件未達 10，區域總量超過 40）")

-- 分 scope 過濾：情境九要證明的是 area 路徑，而補貨若讓某個區塊超過 chunk 上限就會另外
-- 寫出 scope=chunk 的警告，混進計數會讓預期值失準。同時保留 chunk 版計數當反向對照，
-- 斷言 chunk-scope 全程沒被觸發
local function sockWarnsBy(scope)
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=" .. scope, 1, true)
            and line:find("Base.Sock", 1, true) then
            n = n + 1
        end
    end
    return n
end

-- 某個區塊現有幾件 Base.Sock（補貨時要按實際剩餘補到剛好 10，不能一次全倒進同一塊）
local function sockInRow(y)
    local n = 0
    local cy = math.floor(y / 8)
    for px = 80, 87 do
        for py = cy * 8, cy * 8 + 7 do
            local sq = world[squareKey(px, py, 0)]
            if sq then
                for _, wo in ipairs(sq._objs) do
                    if wo:getItem():getFullType() == "Base.Sock" then n = n + 1 end
                end
            end
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Sock") == 45, "第一輪只警告、不刪")
check(sockWarnsBy("area") == 1, "第一輪寫出一則 area 警告")

-- 只卸載五個區塊中的一個：可觀測總數掉到 36 < 40，本輪 areaReasons 就不含這個 key。
-- 舊版據此直接刪記錄（連閒置年齡都沒有）；正確行為是「計數來源少了一塊就不能斷言已解決」
local SOCK_CHUNK = "10,10,0"
unloadedChunks[SOCK_CHUNK] = true
probeChunk = { cx = 10, cy = 10, z = 0 }
probeLookups = 0
probeChunkChecks = 0
nowMs = nowMs + 61000
runTicks(600)
check(probeChunkChecks > 0, "活性：卸載輪確實查過該區塊的載入狀態（否則以下兩條是空轉）")
check(probeLookups == 0, "未載入的區塊整塊跳過，沒有逐格做必定回 nil 的查詢")
check(sockWarnsBy("area") == 1, "來源區塊未觀測時沒有重新警告（記錄沒被誤判已解決）")
check(countFloor("Base.Sock") == 45, "卸載輪不刪")

unloadedChunks[SOCK_CHUNK] = nil
probeChunk = nil
nowMs = nowMs + 61000
runTicks(600)
check(sockWarnsBy("area") == 1, "重載輪仍未重新警告（沿用卸載前那一筆記錄）")
check(countFloor("Base.Sock") == 40, "沿用舊記錄直接清到區域上限 40（area 確認鏈沒斷）")

-- 正向對照：來源區塊全部觀測到且已達標（剛好 40，不超過上限）→ 記錄必須被**即時**刪除。
-- 這一輪釘住 underCounted == false 分支；少了它，把判定寫成「永遠不刪」也會全綠。
-- 注意此刻區域仍有 20 個區塊是 unseen（沒預建空 square），能通過正是因為判定只看來源區塊
nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Sock") == 40, "已達標輪不再多刪")

-- 每個區塊按實際剩餘補到剛好 10 件（清理是整堆整堆挑的，五塊剩餘不一定平均）。
-- 10 不大於 chunk 上限 10 ⇒ 不觸發 chunk-scope；總量回到 50 ⇒ 只有 area 超標
for _, y in ipairs(SOCK_ROWS) do
    for _ = sockInRow(y) + 1, 10 do
        putOnFloor(80 + (y % 8), y, 0, makeItem("Base.Sock", "dumper"))
    end
end
check(countFloor("Base.Sock") == 50, "補貨後每區塊剛好 10 件、總量 50")
nowMs = nowMs + 61000
runTicks(600)
check(sockWarnsBy("area") == 2, "舊記錄已即時回收，再次超標時重新警告（釘住 underCounted false 分支）")
check(countFloor("Base.Sock") == 50, "重新警告的那一輪只警告、不刪")

-- 洩漏端：來源區塊持續未觀測的記錄也不能永遠留著——年齡超過 staleMs（60s×20＝20 分鐘）
-- 就該回收。少了這條，把 area 回收的 staleMs 分支整段刪掉仍會全綠（chunk-scope 在情境八
-- 有對應覆蓋，這裡補上對稱的那一半）
unloadedChunks[SOCK_CHUNK] = true
nowMs = nowMs + 1300000
runTicks(600)
unloadedChunks[SOCK_CHUNK] = nil
nowMs = nowMs + 61000
runTicks(600)
check(sockWarnsBy("area") == 3, "來源區塊未觀測超過 staleMs 的記錄已被回收（重載後重新警告）")
check(countFloor("Base.Sock") == 50, "回收後回到首次警告狀態，本輪不刪")
check(sockWarnsBy("chunk") == 0, "全程未觸發 chunk-scope（證明這個情境只走 area 路徑）")

print()
print("情境十：area 來源清單合併——卸載來源不得在重算時被忘掉")

-- 六個區塊各 9 件（真實 54 > 區域上限 40，但每塊 9 < 區塊上限 10 ⇒ 只走 area）。
-- 五個在 cx=11（x 88..95），第六個在 cx=13（x 104..111），都落在 ScanRadius 16 的 cx/cy 10..14
-- 內，且避開情境一（12,12）、情境五（13,12）、情境八（14,14）、情境九（cx=10）的 fixture
local PAIL_ROWS = { 80, 88, 96, 104, 112 }
for _, y in ipairs(PAIL_ROWS) do
    for i = 1, 9 do putOnFloor(88 + (i % 8), y, 0, makeItem("Base.Bucket", "dumper")) end
end
for i = 1, 9 do putOnFloor(104 + (i % 8), 80, 0, makeItem("Base.Bucket", "dumper")) end
check(countFloor("Base.Bucket") == 54, "起始：六個區塊各 9 件、總量 54")

local function pailAreaWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=area", 1, true)
            and line:find("Base.Bucket", 1, true) then
            n = n + 1
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Bucket") == 54, "第一輪只警告、不刪")
check(pailAreaWarns() == 1, "第一輪寫出一則 area 警告")

-- 卸載第六塊。可觀測總數 45 仍 > 40，而讀不到的來源一律當 0 ⇒ live 是下界、下界已證明超標，
-- 所以這一輪照樣清理，把**可觀測**部分降到剛好 40（真實總數還有 49，含卸載那塊的 9 件）。
-- 刪到可觀測＝上限就停，總數＝上限＋讀不到的部分 ⇒ 永遠不會刪到低於上限。
-- 這一輪同時讓來源清單被重算一次：合併版會保留那個卸載來源，覆寫版會把它忘掉
local PAIL_CHUNK = "13,10,0"
unloadedChunks[PAIL_CHUNK] = true
nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Bucket") == 49, "可觀測部分被清到上限 40，總量 54→49（不會刪到低於上限）")
check(pailAreaWarns() == 1, "這一輪沿用舊記錄執行清理，不重新警告")

-- 關鍵一輪：可觀測總數已是 40（不超標）⇒ 不進 areaReasons。來源清單若還記得那個卸載來源，
-- 就會判定「來源沒看完整、不能算已解決」而保留記錄；若被覆寫忘掉，記錄會在這裡被誤刪
nowMs = nowMs + 61000
runTicks(600)
check(pailAreaWarns() == 1, "可觀測數達標但來源仍缺一塊時不重新警告（記錄沒被誤刪）")

-- 重載第六塊：真實 49 > 40，且來源全部讀得到 ⇒ recount 通過。記錄若還活著就直接清到 40；
-- 若已被誤刪則會重新首次警告、當輪不清
unloadedChunks[PAIL_CHUNK] = nil
nowMs = nowMs + 61000
runTicks(600)
check(pailAreaWarns() == 1, "重載輪沿用原記錄，未重新警告（釘住合併而非覆寫）")
check(countFloor("Base.Bucket") == 40, "沿用原記錄直接清到區域上限 40")

print()
print("情境十一：掃描途中卸載——載入狀態要每個 tick 重查")

-- 佈局配合 offset → 座標的換算（x = cx*8 + offset%8、y = cy*8 + floor(offset/8)）：
-- 8 件放在 y 偏移 0（offset 0..7，任何一個 tick 只要碰到這塊就會數到），4 件放在 y 偏移 6
-- （offset 48..55，要掃過前 48 格才會碰到）。目標區塊從第幾格跨到下一個 tick 取決於前面
-- 區塊吃掉多少預算，所以這裡不假設固定邊界——卸載門檻綁的是「載入狀態被查第幾次」：
-- 第二次被查時就回 nil，此時後段那 4 件必定還沒被數到。
-- 途中卸載後可觀測數變成 8（低於區塊上限 10），若載入狀態只在起頭查一次，
-- 這筆記錄就會被當成「已回到上限內」而刪除
local CORD_CX, CORD_CY = 12, 14
for i = 1, 8 do putOnFloor(96 + (i % 8), 112, 0, makeItem("Base.Cord", "dumper")) end
for i = 1, 4 do putOnFloor(96 + (i % 8), 118, 0, makeItem("Base.Cord", "dumper")) end
check(countFloor("Base.Cord") == 12, "起始：12 件（每區塊上限 10）")

local function cordChunkWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=chunk", 1, true)
            and line:find("Base.Cord", 1, true) then
            n = n + 1
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(400)
check(countFloor("Base.Cord") == 12, "第一輪只警告、不刪")
check(cordChunkWarns() == 1, "第一輪寫出一則 chunk 警告")

-- 第二輪：第一個 tick 照常掃（8 件都數得到，8 < 上限 10 ⇒ 不進 reasons），第二個 tick 一開頭
-- 重查載入狀態時就會發現這塊讀不到，於是標記為未完整觀測、整塊跳過，記錄改走閒置分支保留。
-- 只在起頭查一次的話，這筆記錄會在這裡被當成「已回到上限內」而刪除
partialUnload = { key = CORD_CX .. "," .. CORD_CY .. ",0", checks = 0 }
nowMs = nowMs + 61000
runTicks(400)
check(partialUnload.checks > 1, "活性：該區塊的載入狀態確實被重查過（否則以下兩條是空轉）")
check(cordChunkWarns() == 1, "掃描途中卸載不算已解決（記錄沒被誤刪）")
check(countFloor("Base.Cord") == 12, "這一輪不刪")

-- 恢復完整讀取：12 > 10。記錄若還活著就直接清到 10；若已被誤刪則會重新首次警告、當輪不清
partialUnload = nil
nowMs = nowMs + 61000
runTicks(400)
check(cordChunkWarns() == 1, "恢復輪沿用原記錄，未重新警告（釘住每 tick 重查載入狀態）")
check(countFloor("Base.Cord") == 10, "沿用原記錄直接清到上限 10")

print()
print("情境十二：area 來源集必須依玩家歸屬——別人的掃描盒不算")

-- 舊區域五塊各 9 件（總 45 > 區域上限 40，每塊 9 < 區塊上限 10 ⇒ 只走 area）。
-- 選的是前十一個情境沒用過的區塊：(12,10)(12,11)(12,13)(13,11)(13,13)
local RAG_OLD = { { 96, 80 }, { 96, 88 }, { 96, 104 }, { 104, 88 }, { 104, 104 } }
for _, p in ipairs(RAG_OLD) do
    for i = 1, 9 do putOnFloor(p[1] + (i % 8), p[2], 0, makeItem("Base.Rag", "dumper")) end
end
check(countFloor("Base.Rag") == 45, "起始：舊區域五塊各 9 件、總量 45")

local function ragAreaWarns()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("[warn]", 1, true) and line:find("scope=area", 1, true)
            and line:find("Base.Rag", 1, true) then
            n = n + 1
        end
    end
    return n
end

nowMs = nowMs + 61000
runTicks(600)
check(ragAreaWarns() == 1, "第一輪寫出一則 area 警告")

-- 卸載其中一塊，讓它成為「來源集裡未觀測到的那一塊」（可觀測 36 < 40 ⇒ 不進 areaReasons，
-- 記錄靠 underCounted 保留）。這塊接下來就是驗 owner 歸屬的探針
local RAG_UNLOADED = "12,10,0"
unloadedChunks[RAG_UNLOADED] = true
nowMs = nowMs + 61000
runTicks(600)
check(ragAreaWarns() == 1, "來源缺一塊時記錄仍保留（不重新警告）")

-- 玩家搬家到 (300,300)；第二位玩家進駐舊位置，於是那塊未載入的舊來源**仍在全域 chunkSet 內**，
-- 只是不再屬於搬家者的掃描盒。少了 chunkOwnedBy 那道檢查，它會被永久併進搬家者的來源集，
-- 讓 underCounted 恆真 ⇒ 記錄永遠不會在達標輪被回收 ⇒ 下次超標時直接沿用舊記錄清理、
-- 不再給玩家警告。（讀不到的來源本身不擋刪除，因為 recount 用的是下界；見下方 :1145 的說明）
local player2 = {
    getX = function() return 100 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
    getUsername = function() return "neighbour" end,
    getOnlineID = function() return 2 end,
    getCurrentSquare = function() return getOrMakeSquare(100, 100, 0) end,
    getInventory = function() return makeContainer("player") end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
playerX, playerY = 300, 300
onlineRoster = { player, player2 }

-- 新區域五塊各 9 件（cx/cy 35..39 ⇒ x 280..287）：搬家者在新家又堆到超標
local RAG_NEW = { 280, 288, 296, 304, 312 }
for _, y in ipairs(RAG_NEW) do
    for i = 1, 9 do putOnFloor(280 + (i % 8), y, 0, makeItem("Base.Rag", "dumper")) end
end
check(countFloor("Base.Rag") == 90, "新區域也堆了 45 件（總量 90）")

nowMs = nowMs + 61000
runTicks(600)
nowMs = nowMs + 61000
runTicks(600)
-- 改用下界語意之後，讀不到的來源一律當 0，所以「舊來源留在集合裡」不再擋住刪除——
-- 兩種版本都會把新區域清到 40。owner 檢查真正影響的是**記錄能不能收斂**：
check(countFloor("Base.Rag") == 85, "新區域清到上限 40，總量 90→85")

-- 達標輪：新區域剩 40（不超標）⇒ 不進 areaReasons。
-- 有 owner 檢查時來源集只剩新區域那五塊、全部讀得到 ⇒ underCounted 為假 ⇒ 記錄即時回收；
-- 沒有 owner 檢查時，別人掃描盒裡那塊永遠讀不到的舊來源會讓 underCounted 恆真 ⇒ 記錄永不
-- 回收，之後再超標就會沿用舊記錄直接清、不再給玩家警告
nowMs = nowMs + 61000
runTicks(600)
for i = 1, 9 do putOnFloor(280 + (i % 8), 280, 0, makeItem("Base.Rag", "dumper")) end
nowMs = nowMs + 61000
runTicks(600)
check(ragAreaWarns() == 2, "舊記錄已回收，再次超標時重新警告（釘住來源集的 owner 歸屬）")
check(countFloor("Base.Rag") == 94, "重新警告的那一輪只警告、不刪")

onlineRoster = nil
playerX, playerY = 100, 100

print()
print("情境十三：跨 tick 的刪除佇列必須依現況重數")

-- 十五個區塊各 5 件（每塊 5 < 區塊上限 10 ⇒ 只走 area），總量 75 > 區域上限 40 ⇒ 超標 35 件，
-- 遠多於 ITEMS_PER_TICK（16），佇列必然跨 tick 消化。區塊沿用前面情境的位置但換一個沒用過的
-- fullType——area 與 chunk 的計數都是 per-fullType，彼此不干擾
local TWIG_SPOTS = {
    { 80, 80 }, { 80, 88 }, { 80, 96 }, { 80, 104 }, { 80, 112 },
    { 88, 80 }, { 88, 88 }, { 88, 96 }, { 88, 104 }, { 88, 112 },
    { 112, 80 }, { 112, 88 }, { 112, 96 }, { 112, 104 }, { 104, 112 },
}
for _, p in ipairs(TWIG_SPOTS) do
    for i = 1, 5 do putOnFloor(p[1] + (i % 8), p[2], 0, makeItem("Base.Twig", "dumper")) end
end
check(countFloor("Base.Twig") == 75, "起始：十五塊各 5 件、總量 75（區域上限 40）")

nowMs = nowMs + 61000
runTicks(600)
check(countFloor("Base.Twig") == 75, "第一輪只警告、不刪")

-- 第二輪：確認超標並排入 35 件 victim。逐個 tick 跑，停在「第一批剛被刪掉」的那一刻——
-- 佇列還有 19 件排著，這正是 recount 要保護的窗口
nowMs = nowMs + 61000
for _ = 1, 2000 do
    runTicks(1)
    if countFloor("Base.Twig") < 75 then break end
end
check(countFloor("Base.Twig") == 75 - MinidoracatCleaner.CONSTANTS.ITEMS_PER_TICK,
    "第一個 tick 刪掉 ITEMS_PER_TICK 件")

-- 玩家自己把剩下的撿到剛好 40：後續還排在佇列裡的 victim 應該全部被 recount 取消。
-- 少了 recount，它們會照排入時的舊數量繼續刪，把區域刪到遠低於上限
local twigPicked = 0
for _, p in ipairs(TWIG_SPOTS) do
    for px = p[1], p[1] + 7 do
        local sq = world[squareKey(px, p[2], 0)]
        if sq then
            for i = #sq._objs, 1, -1 do
                if countFloor("Base.Twig") <= 40 then break end
                if sq._objs[i]:getItem():getFullType() == "Base.Twig" then
                    table.remove(sq._objs, i)
                    twigPicked = twigPicked + 1
                end
            end
        end
    end
    if countFloor("Base.Twig") <= 40 then break end
end
check(countFloor("Base.Twig") == 40, "玩家自己撿到剛好等於上限 40（撿走 " .. twigPicked .. " 件）")

runTicks(600)
check(countFloor("Base.Twig") == 40, "佇列裡剩下的 victim 全被 recount 取消，沒有刪到低於上限")

print()
print("情境十四：來源數超過走訪上限且下界證明不了超標時，整批不排入並留下診斷")

-- 這條要構造「來源數 > AREA_RECOUNT_CHUNKS_PER_TICK」的稀疏鋪陳，而預設 ScanRadius=16 只涵蓋
-- 25 個區塊，構不出來 ⇒ 放寬半徑與區域上限。
-- **還原時機**：ScanRadius=32 由情境十五、十六共用（它們的佈局都依賴這個半徑），所以三個情境
-- 都跑完才在檔尾一起還原——不要在這裡還原，那會讓後面兩條的 fixture 掉出掃描盒。
-- 佈局：33 個區塊各 1 件（每塊 1 < 區塊上限 10 ⇒ 只走 area），總量 33 > 區域上限 32。
-- 來源集依計數降冪截到 32 塊 ⇒ 可證明的下界只有 32，而 32 > 32 為假 ⇒ 整批不排入。
-- 少了這一刀，每一輪都會排入註定被 recount 取消的 victim（confirmed 恆真），持續燒掃描預算。
-- 沒有截斷時：provable 會是 33 > 32 ⇒ 刪掉 1 件
local savedRadius = sandbox.ScanRadius
local savedAreaLimit = sandbox.MaxFloorItemsPerTypeArea
sandbox.ScanRadius = 32
sandbox.MaxFloorItemsPerTypeArea = 32

-- 情境十二刻意留著一個未還原的未載入區塊（那是它驗 owner 歸屬的前提），而它正好落在下面
-- 要鋪的範圍內 ⇒ 會少數到一件、讓 33 變成 32 而剛好不超標。這裡要精確控制來源數，先全部還原
for key in pairs(unloadedChunks) do
    unloadedChunks[key] = nil
end

local function pebbleUnprovableLogs()
    local n = 0
    for _, line in ipairs(logLines) do
        if line:find("items_area_unprovable", 1, true) and line:find("Base.Pebble", 1, true) then
            n = n + 1
        end
    end
    return n
end

local pebbleSpots = 0
for cx = 8, 16 do
    for cy = 8, 12 do
        if pebbleSpots < 33 then
            putOnFloor(cx * 8, cy * 8, 0, makeItem("Base.Pebble", "dumper"))
            pebbleSpots = pebbleSpots + 1
        end
    end
end
check(countFloor("Base.Pebble") == 33, "起始：33 個區塊各 1 件（區域上限 32）")

nowMs = nowMs + 61000
runTicks(3000)
nowMs = nowMs + 61000
runTicks(3000)

check(countFloor("Base.Pebble") == 33,
    "可證明的下界不足以超標 ⇒ 一件都不刪（釘住來源集截斷）")
-- 活性斷言：上面那條斷言的是「什麼都沒發生」，而那正是假通過的形狀。這行證明 area 路徑
-- 真的偵測到熱點、走到了證明判定並主動放棄，不是整段程式沒被走到
check(pebbleUnprovableLogs() == 1,
    "整批不排入時寫出一則 items_area_unprovable（管理員可見，且每個熱點只記一次）")


print()
print("情境十五：來源集必須依計數降冪挑選")

-- 密度不均且來源數遠超截斷長度時，「保留哪 32 塊」決定得出的下界能不能證明超標。
-- 佈局要與 pairs 的走訪順序無關（Kahlua 是插入序、標準 Lua 是帶隨機種子的雜湊序，兩者都
-- 不可控）：若高密度塊剛好排在前面，top-32 還沒滿就無條件進榜，替換邏輯根本不會被考驗。
-- 所以讓高密度塊的數量**正好等於**截斷長度：
--   62 塊來源——32 塊各 5 件（160）＋30 塊各 1 件（30），總量 190，區域上限 150。
--   正確（保留最大的 32 個）：無論走訪順序，最終榜上就是那 32 塊 ⇒ 160 > 150 ⇒ 排入 10 件。
--   保留最小的 32 個：30 個 1 件 ＋ 2 個 5 件 = 40，遠低於 150 ⇒ 判成「證明不了」而完全不清。
--   插入位置寫錯（榜尾不再是最小值）也會讓替換決策失準、湊不到 160。
local savedChunkLimit = sandbox.MaxFloorItemsPerType
sandbox.MaxFloorItemsPerTypeArea = 150
-- 放寬區塊上限，否則 chunk scope 會搶先清掉、測不到 area 的挑選邏輯
sandbox.MaxFloorItemsPerType = 200

local nailDenseCount, nailSparseCount = 0, 0
for cy = 8, 15 do
    for cx = 8, 15 do
        if nailDenseCount < 32 then
            -- 每塊 5 件全擠同一格：玩家傾倒就是這個形狀，而佇列只存 id/x/y/z、每次刪除前
            -- 都重新 getWorldObjects() 按 ID 尋找，所以同格重複堆是真實核心路徑
            for _ = 1, 5 do
                putOnFloor(cx * 8 + 2, cy * 8 + 2, 0, makeItem("Base.Nails", "dumper"))
            end
            nailDenseCount = nailDenseCount + 1
        elseif nailSparseCount < 30 then
            putOnFloor(cx * 8 + 2, cy * 8 + 2, 0, makeItem("Base.Nails", "dumper"))
            nailSparseCount = nailSparseCount + 1
        end
    end
end
check(countFloor("Base.Nails") == 190,
    "起始：32 塊各 5 件＋30 塊各 1 件，總量 190（區域上限 150、來源 62 塊 > 截斷 32）")

nowMs = nowMs + 61000
runTicks(6000)
check(countFloor("Base.Nails") == 190, "第一輪只警告、不刪")

nowMs = nowMs + 61000
runTicks(6000)
check(countFloor("Base.Nails") == 180,
    "保留最大的 32 塊讓下界達到 160 > 150 ⇒ 排入 10 件並刪掉（釘住 top-N 的替換與排序）")


print()
print("情境十六：單 tick 的載入探測次數必須受額度封頂（跨 fullType）")

-- 0-cache 只在相同 bucket|fullType 之間共用，所以「同一 tick、多個不同 fullType 的 area
-- victim」會各自重新探測同一批卸載來源。若載入探測不計費（walked 只在真的走了 64 格時遞增），
-- 單 tick 的 Java 往返會是 victim 數 × 來源數，而不是額度本身。
--
-- 佈局要滿足三件事：① 每型只排 1 個 victim（否則 ITEMS_PER_TICK=16 會讓單一型別吃掉整個
-- tick，輪不到第二型）② 第一型的 recount 必須走滿 32 塊才耗盡額度（所以下界只能在最後一塊
-- 才超過上限）③ 上限要高於前面所有情境的 fixture，否則它們會一起超標而讓 victim 數失控。
-- 取 3 型 × 32 塊 × 10 件、上限 319：前 31 塊只有 310 ≤ 319 ⇒ 必走滿 32 塊；319 高於既有
-- fixture 的最大量（Nails 101）⇒ 零干擾。
-- 有計費：第一型走滿 32 ⇒ 後兩型 defer ⇒ 卸載後的下一 tick 只有第二型探測 32 次。
-- 無計費：第二、三型各重走整份來源集 ⇒ 64 次
local savedAreaLimit16 = sandbox.MaxFloorItemsPerTypeArea
sandbox.MaxFloorItemsPerTypeArea = 319

local TYPES_16 = { "Base.Wire", "Base.Thread", "Base.Tarp" }
local probeKeys = {}
for index = 0, 31 do
    local cx = 8 + (index % 8)
    local cy = 8 + math.floor(index / 8)
    probeKeys[#probeKeys + 1] = cx .. "," .. cy .. ",0"
    for _, fullType in ipairs(TYPES_16) do
        for _ = 1, 10 do
            putOnFloor(cx * 8 + 5, cy * 8 + 5, 0, makeItem(fullType, "dumper"))
        end
    end
end
local function total16()
    local n = 0
    for _, fullType in ipairs(TYPES_16) do n = n + countFloor(fullType) end
    return n
end
check(total16() == 960, "起始：三個 fullType 各 32 塊各 10 件（各 320 件、區域上限 319）")

nowMs = nowMs + 61000
runTicks(6000)
check(total16() == 960, "第一輪只警告、不刪")

nowMs = nowMs + 61000
-- 跑到佇列真的開始消化就停：第一型的 victim 被刪掉，後兩型因額度耗盡而留在佇列
local t16 = 0
while total16() == 960 and t16 < 6000 do
    runTicks(1)
    t16 = t16 + 1
end
check(total16() == 959, "三型中恰好一型刪掉 1 件（其餘兩型的 victim 因額度耗盡留在佇列）")

for _, ck in ipairs(probeKeys) do
    unloadedChunks[ck] = true
end
-- 活性檢查要綁**recount 專屬**的證據。chunkCheckTotal 是全域計數，consumeScanQueue 每 tick
-- 也會對正在掃的區塊查一次載入狀態，所以「> 0」可能被掃描器滿足——那樣一來 recount 完全
-- 沒跑時上限斷言也無條件成立，整條退化成空轉假通過（AGENTS.md 踩坑錄記過這個形狀）。
-- probeChunk 指向來源集裡的一塊，probeChunkChecks 只在那一塊被查載入狀態時遞增
probeChunk = { cx = 8, cy = 8, z = 0 }
probeChunkChecks = 0
chunkCheckTotal = 0
runTicks(1)
check(probeChunkChecks > 0, "活性：這個 tick 確實對來源集裡的區塊做了載入探測（否則下一條是空轉）")
-- 額度寫死 32 而不是讀常數（讀常數的話斷言會跟著放寬，改成無限大也照樣通過），而且要用
-- **等式**不是 `<=`：若載入探測被錯誤地雙倍計費，走 16 塊就會永久 defer、每個 tick 從頭再來，
-- 而 `<= 32` 對那種退化完全無感
check(chunkCheckTotal == 32,
    "本 tick 恰好用滿額度 32（實際 " .. chunkCheckTotal .. "，釘住載入探測也計費且不重複計費）")
-- 下一個 tick 應該再恰好用滿一次：額度是每 tick 重建的，前一 tick defer 的那件會用完整額度
-- 重數。這條同時排除「額度只在第一個 tick 生效」的實作
chunkCheckTotal = 0
runTicks(1)
check(chunkCheckTotal == 32,
    "下一個 tick 又恰好用滿 32（實際 " .. chunkCheckTotal .. "，釘住額度每 tick 重建）")
-- 最後要證明佇列真的排空、不是每 tick 都在重試同一批 victim（來源全卸載 ⇒ 下界 0 ⇒ 全取消）
runTicks(3000)
chunkCheckTotal = 0
probeChunkChecks = 0
runTicks(1)
check(chunkCheckTotal == 0 and probeChunkChecks == 0,
    "佇列排空後不再有任何探測（沒有殘留 victim 每 tick 空轉）")
probeChunk = nil

for _, ck in ipairs(probeKeys) do
    unloadedChunks[ck] = nil
end
-- 還原順序：情境十四～十六各自存了自己動到的值，這裡由內而外還原。
-- MaxFloorItemsPerTypeArea 被十五（100）與十六（319）都改過，savedAreaLimit 是十四之前的原值
sandbox.MaxFloorItemsPerType = savedChunkLimit
sandbox.ScanRadius = savedRadius
sandbox.MaxFloorItemsPerTypeArea = savedAreaLimit

print()
print("情境十七：單一格子的物品數超過走訪額度時，計數必須跨 tick 續算")

-- SQUARES_PER_TICK 封頂的是格數，不是每格的物件數；單格的 worldObjects 沒有容量上限
-- （IsoGridSquare.java:319），所以掃描另有 SCAN_ITEM_VISITS_PER_TICK 這道物件額度。
-- 額度用完時**不能**前進 squareIndex，否則該格剩下的物件永遠不被計數。
-- 佈局：同一格 700 件（> 額度 512）、區塊上限 100 ⇒ 正確會清到剛好 100。
-- 漏數版本只數到 512 ⇒ 排 412 件 ⇒ 剩 288
local savedChunk17 = sandbox.MaxFloorItemsPerType
local savedArea17 = sandbox.MaxFloorItemsPerTypeArea
sandbox.MaxFloorItemsPerType = 100
sandbox.MaxFloorItemsPerTypeArea = 2000  -- 讓 area 不介入，隔離出 chunk 路徑

for _ = 1, 700 do
    putOnFloor(83, 83, 0, makeItem("Base.Nail", "dumper"))
end
check(countFloor("Base.Nail") == 700, "起始：同一格 700 件（區塊上限 100、單 tick 物件額度 512）")
-- 記下起始的最大 ID，用來驗「最新的先刪」：候選是保留 ID 最大的 N 筆（min-heap），若 heap
-- 的浮上／下沉寫錯，root 就不是最舊那筆 ⇒ 會保留錯的集合、刪掉舊的而留下新的
local nailStartMaxId = maxFloorId("Base.Nail")

-- 量測前先把前面情境殘留的刪除佇列排空：itemReads 是全域計數器，而 recount 與 find 各有
-- 自己的額度也會讀地板物件，佇列沒空的話量到的峰值不是純掃描成本。
-- 不推進 nowMs，所以這裡不會觸發新的掃描
runTicks(6000)

nowMs = nowMs + 61000
-- 逐 tick 量測地板物件讀取次數的峰值：只斷言「最後有數完」的話，把 SCAN_ITEM_VISITS_PER_TICK
-- 整段拿掉照樣會清到 100（一個 tick 全走完也算數完），上限本身就沒被釘住
local maxReads = 0
for _ = 1, 3000 do
    itemReads = 0
    runTicks(1)
    if itemReads > maxReads then
        maxReads = itemReads
    end
end
check(countFloor("Base.Nail") == 700, "第一輪只警告、不刪")
-- 上限寫死 512 而不是讀 MinidoracatCleaner.CONSTANTS.SCAN_ITEM_VISITS_PER_TICK：讀常數的話
-- 斷言會跟著常數一起放寬，把額度改成無限大也照樣通過（自我參照＝沒有釘住任何東西）。
-- 這個數字要跟著 Core.lua 的 SCAN_ITEM_VISITS_PER_TICK 一起改，那正是想要的：調整成本旋鈕
-- 必須是一個有意識的動作
check(maxReads > 0 and maxReads <= 512,
    "單 tick 的地板物件走訪不超過額度 512（實測峰值 " .. maxReads .. "，釘住掃描物件額度）")

-- 候選清單是 per (chunk, fullType) 的 bounded top-N（CANDIDATES_PER_TYPE），所以單一輪最多
-- 排入那麼多件；700 件要清到 100 需要跨輪收斂。這正是記憶體上限的代價，也是設計意圖：
-- 一輪處理不完的下一輪繼續，永遠不會為了「一次清完」而配置與世界內容量成正比的 table
local rounds17 = 0
for _ = 1, 10 do
    nowMs = nowMs + 61000
    runTicks(3000)
    rounds17 = rounds17 + 1
    if countFloor("Base.Nail") == 100 then
        break
    end
end
check(countFloor("Base.Nail") == 100,
    "逐輪收斂到剛好等於上限（釘住格內 offset 跨 tick 續算，沒有漏數）")
-- 輪數本身就是「單輪配置量有上限」的證據：要刪 600 件而每輪最多排 512 件 ⇒ 至少 2 輪。
-- 少了這條，把 CANDIDATES_PER_TYPE 改成無限大也照樣通過（一輪清完也是清到 100）
check(rounds17 >= 2,
    "清理跨了 " .. rounds17 .. " 輪（≥2，釘住每組候選的 bounded top-N 上限）")
check(maxFloorId("Base.Nail") < nailStartMaxId,
    "剩下的都是較舊的（最大 ID 從 " .. nailStartMaxId .. " 降到 " .. maxFloorId("Base.Nail")
        .. "，釘住候選 min-heap 選的是最新的那些）")

print()
print("情境十八：victim 落在超大同格清單的尾端時仍要找得到")

-- 候選依 item ID 由大到小挑，而掉落物是 append 進 worldObjects 的 ⇒ victim 幾乎總在尾端。
-- findQueuedWorldItem 若從 index 0 正向掃，單格件數超過 FIND_ITEM_VISITS_PER_TICK 時每輪都在
-- 前段觸頂、永遠找不到 victim ⇒ 加了額度反而讓清理在最需要它的場景失活。
-- 佈局：同一格 2500 件（> 額度 2048）、區塊上限 100
for _ = 1, 2500 do
    putOnFloor(91, 91, 0, makeItem("Base.Tissue", "dumper"))
end
check(countFloor("Base.Tissue") == 2500, "起始：同一格 2500 件（單 tick find 額度 2048）")

-- 同樣要跨輪收斂（每輪最多排 CANDIDATES_PER_TYPE 件）
local rounds18 = 0
for _ = 1, 15 do
    nowMs = nowMs + 61000
    runTicks(20000)
    rounds18 = rounds18 + 1
    if countFloor("Base.Tissue") == 100 then
        break
    end
end
check(countFloor("Base.Tissue") == 100,
    "逐輪收斂到剛好等於上限（用了 " .. rounds18 .. " 輪；釘住 find 反向掃，尾端的 victim 找得到）")

-- 第二段：讓 find 額度真的觸發。上面那段反向掃第一筆就命中，所以額度多寡都不影響——
-- 要釘住額度本身，得讓 victim 前面隔著超過額度的其他物件。
-- 佈局：同格再堆 2500 個「不同 fullType」的 decoy（ID 全都比 target 新 ⇒ 反向掃會先走它們），
-- 然後讓 target 再次超標。正確版：find 走 2048 筆就觸頂、當成找不到而放掉 ⇒ 這一輪不刪。
-- 沒有額度的版本：一路走完 2500 筆找到 target ⇒ 會刪
for _ = 1, 2500 do
    putOnFloor(91, 91, 0, makeItem("Base.Decoy", "dumper"))
end
for _ = 1, 60 do
    putOnFloor(91, 91, 0, makeItem("Base.Tissue", "dumper"))
end
-- decoy 要比 target 新才會擋在反向掃的前面
for _ = 1, 2500 do
    putOnFloor(91, 91, 0, makeItem("Base.Decoy2", "dumper"))
end
check(countFloor("Base.Tissue") == 160, "起始：target 160 件，尾端隔著 2500 個更新的 decoy")

nowMs = nowMs + 61000
runTicks(3000)
nowMs = nowMs + 61000
runTicks(3000)
check(countFloor("Base.Tissue") == 160,
    "victim 前面隔著超過額度的物件時 find 觸頂放掉、這一輪不刪（釘住 find 物件額度）")

-- 收尾：把這個情境堆的東西從世界移掉。decoy 各 2500 件而區塊上限是 100，它們會**永遠**超標
-- ⇒ 每一輪掃描都排入約 4800 個 victim 佔住全域刪除佇列，讓後面情境的清理時序完全不可控
-- （實測讓情境二十的活性檢查與情境二十二的分層斷言各有一成機率偶發假紅）。
-- 情境之間共用 world／deleteQueue，製造大量永久超標的 fixture 就要自己收乾淨
for _, sq in pairs(world) do
    for i = #sq._objs, 1, -1 do
        local ft = sq._objs[i]:getItem():getFullType()
        if ft == "Base.Decoy" or ft == "Base.Decoy2" or ft == "Base.Tissue" then
            table.remove(sq._objs, i)
        end
    end
end
check(countFloor("Base.Decoy") == 0 and countFloor("Base.Tissue") == 0,
    "收尾：本情境的 fixture 已從世界移除（避免污染後續情境的刪除佇列）")

print()
print("情境十九：刪除前必須讀當前上限，不是排入當時的快照")

-- 管理員可在執行期改 sandbox（server 收到設定封包後 SandboxOptions.load/applySettings/toLua，
-- GameServer.java:1695-1697）。佇列跨 tick 存活時若照排入當時的舊上限刪，就會刪掉當前政策
-- 允許保留的物品。
-- 佈局：同一塊 300 件、上限 100 ⇒ 排 200 件；佇列起步後把上限提高到 400 ⇒ 剩下的 victim
-- 全部應被取消（300 已在新上限內）
for _ = 1, 300 do
    putOnFloor(99, 99, 0, makeItem("Base.Comb", "dumper"))
end
check(countFloor("Base.Comb") == 300, "起始：同一塊 300 件（區塊上限 100）")

nowMs = nowMs + 61000
runTicks(3000)
check(countFloor("Base.Comb") == 300, "第一輪只警告、不刪")

nowMs = nowMs + 61000
local t19 = 0
while countFloor("Base.Comb") == 300 and t19 < 6000 do
    runTicks(1)
    t19 = t19 + 1
end
local comb19 = countFloor("Base.Comb")
check(comb19 < 300 and comb19 > 100, "第二輪開始刪但還沒刪完（剩 " .. comb19 .. " 件）")

-- 管理員把上限提高：佇列裡剩下的 victim 應立刻全部取消
sandbox.MaxFloorItemsPerType = 400
runTicks(3000)
check(countFloor("Base.Comb") == comb19,
    "提高上限後佇列裡剩下的 victim 全被取消（釘住刪除前讀當前上限）")


print()
print("情境二十：同型多個 victim 必須共用「來源讀不到」的結論")

-- recount 對讀不到的來源會把 0 記進本 tick 的 liveCache，讓同一 fullType 的後續 victim 直接
-- 沿用、不必再付一次 Java 往返。這行拿掉不影響正確性（只是變慢），所以要專門釘住——
-- 而情境十六測不到它：那裡每型只排一件 victim，共用的路徑根本不存在。
--
-- 構造要讓「必定走完全部來源」，否則不穩定：下界一超過上限就提早退出，而來源是用 pairs
-- 走訪的（標準 Lua 是帶隨機種子的雜湊序），那塊卸載來源有時根本輪不到 ⇒ 盯它的斷言會偶發
-- 假紅。作法是讓卸載後的可觀測量**低於**上限：此時 live 永遠不超過上限 ⇒ 每件 victim 都會
-- 走完整份來源集（並全部取消），那塊卸載來源必定被碰到。
-- 佈局：4 塊各 10 件 ＋ 1 塊 30 件（總 70）、區域上限 45 ⇒ 排入 25 件（跨 2 個 tick 消化）。
-- 第一個 tick 刪掉 ITEMS_PER_TICK 件之後把那塊 30 件的卸載 ⇒ 可觀測降到 24 ≤ 45。
-- 有 0-cache：第二個 tick 剩下的 victim 共用同一個「讀不到」結論 ⇒ 那塊只被探測 1 次。
-- 沒有 0-cache：每件 victim 各探測一次。
local savedArea20 = sandbox.MaxFloorItemsPerTypeArea
local savedChunk20 = sandbox.MaxFloorItemsPerType
local savedRadius20 = sandbox.ScanRadius
sandbox.MaxFloorItemsPerTypeArea = 45
sandbox.MaxFloorItemsPerType = 200
sandbox.ScanRadius = 16

local BIG_CX, BIG_CY = 14, 10
for index = 0, 3 do
    local cx = 10 + index
    for _ = 1, 10 do
        putOnFloor(cx * 8 + 6, 10 * 8 + 6, 0, makeItem("Base.Shard", "dumper"))
    end
end
for _ = 1, 30 do
    putOnFloor(BIG_CX * 8 + 6, BIG_CY * 8 + 6, 0, makeItem("Base.Shard", "dumper"))
end
check(countFloor("Base.Shard") == 70, "起始：4 塊各 10 件＋1 塊 30 件、總量 70（區域上限 45）")

nowMs = nowMs + 61000
runTicks(3000)
check(countFloor("Base.Shard") == 70, "第一輪只警告、不刪")

nowMs = nowMs + 61000
-- 跑到佇列開始消化（排入 25 件，一個 tick 只消化 ITEMS_PER_TICK 件 ⇒ 必定跨 tick）
local t20 = 0
while countFloor("Base.Shard") == 70 and t20 < 3000 do
    runTicks(1)
    t20 = t20 + 1
end
local shardMid = countFloor("Base.Shard")
check(shardMid < 70 and shardMid > 45,
    "第二輪開始刪但還沒刪完（剩 " .. shardMid .. " 件，佇列裡還有同型的 victim）")

-- 把 30 件那塊卸載：可觀測量掉到上限以下 ⇒ 剩下的 victim 每件都會走完整份來源集後被取消
unloadedChunks[BIG_CX .. "," .. BIG_CY .. ",0"] = true
probeChunk = { cx = BIG_CX, cy = BIG_CY, z = 0 }
probeChunkChecks = 0
runTicks(1)
check(countFloor("Base.Shard") == shardMid,
    "可觀測量低於上限後，剩下的 victim 全被取消（一件都沒再刪）")
-- 上限取 5 而不是等於 1：這個 tick 若掃描器正好在掃那一塊，consumeScanQueue 的每 tick 重查
-- 會另外貢獻一次探測（掃描進度受前面情境殘留的 job 影響，不可控）。差異仍然顯著——少了
-- 0-cache 的話，剩下的每一件 victim 都會各探測一次，量級是 victim 數（這裡約 9）
check(probeChunkChecks > 0 and probeChunkChecks <= 5,
    "同一 tick 內那塊卸載來源最多被探測 " .. probeChunkChecks
        .. " 次（釘住讀不到的來源記 0 進本 tick 快取；沒有它會是 victim 件數）")

unloadedChunks[BIG_CX .. "," .. BIG_CY .. ",0"] = nil
probeChunk = nil

sandbox.MaxFloorItemsPerTypeArea = savedArea20
sandbox.MaxFloorItemsPerType = savedChunk20
sandbox.ScanRadius = savedRadius20
sandbox.MaxFloorItemsPerType = savedChunk17
sandbox.MaxFloorItemsPerTypeArea = savedArea17

print()
print("情境二十一：多位玩家的掃描盒重疊時，重疊區塊只能掃一次")

-- 區塊清單是漸進建構的（每 tick 一批），去重必須跨 tick 存活，否則同一個區塊會被建進
-- chunks 兩次、掃描時計數翻倍。這條之前完全沒被涵蓋——其他情境的玩家都相距很遠
-- （情境十二是 (100,100) 與 (300,300)），去重分支從來沒被走到。
--
-- 半徑要選到讓建構**真的跨 tick**：建構步數是 #玩家 ×(2r/8+1)²×樓層，r=16 只有
-- 2×5×5＝50 步 < CHUNKS_PER_TICK（128），一個 tick 就建完 ⇒ 「跨 tick 存活」這個性質
-- 根本沒被執行（把去重表改成每次呼叫都重建也不會轉紅）。r=32 是 2×9×9＝162 步 > 128，
-- 至少兩個 tick。下面用 gridLookups 當活性證據，證明第一個 tick 真的還在建構而非已在掃描
-- 佈局：兩位玩家相距 8 格（掃描盒大量重疊），重疊區某塊放 6 件、區塊上限 10。
-- 去重正常 ⇒ 數到 6，不清理；去重失效 ⇒ 數到 12 > 10 ⇒ 會清掉 2 件
local savedRadius21 = sandbox.ScanRadius
local savedChunk21 = sandbox.MaxFloorItemsPerType
local savedArea21 = sandbox.MaxFloorItemsPerTypeArea
sandbox.ScanRadius = 32
sandbox.MaxFloorItemsPerType = 10
sandbox.MaxFloorItemsPerTypeArea = 2000  -- 讓 area 不介入，隔離出 chunk 路徑

local neighbour = {
    getX = function() return 108 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
    getUsername = function() return "overlap" end,
    getOnlineID = function() return 3 end,
    getCurrentSquare = function() return getOrMakeSquare(108, 100, 0) end,
    getInventory = function() return makeContainer("player") end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
onlineRoster = { player, neighbour }

-- 座標要挑到讓「同一個 key 被第二次遇到」發生在**另一個 tick**，否則去重命中仍在單一
-- tick 內完成，跨 tick 存活這個性質還是沒被測到。建構順序是 range1（player）整段 81 步、
-- 接著 range2（neighbour）——第一個 tick 的 128 步只吃到 range2 的 offset 0..46。
-- 區塊 (13,13) 在 range1 的 offset 是 50（第一個 tick 建立），在 range2 是 49
-- ⇒ 全域第 130 步 ⇒ 第二個 tick 才碰到它、去重命中因此橫跨 tick 邊界。
-- 兩人的掃描盒（各 ±32 格）都涵蓋這一格：區塊 13 是 x 104..111、y 104..111
for _ = 1, 6 do
    putOnFloor(105, 108, 0, makeItem("Base.Twig2", "dumper"))
end

-- fixture 前提的健全性檢查。下面的主斷言是**缺席型**（沒有警告），它的意義完全建立在
-- 「第二次命中落在第二個 tick」這個算式結果上：全域第 130 步。若 CHUNKS_PER_TICK 日後被
-- 調到 130 以上，建構仍然跨 tick（上面的 gridLookups 活性斷言照樣綠），但去重命中會退回
-- 單一 tick 內完成，被測性質就靜默消失而測試維持全綠。130 是從 offset 算式寫死推導的，
-- 只拿常數來比較，不是拿常數當期望值
local SECOND_HIT_GLOBAL_STEP = 130
check(MinidoracatCleaner.CONSTANTS.CHUNKS_PER_TICK < SECOND_HIT_GLOBAL_STEP,
    "fixture 前提成立：第二次命中在全域第 130 步，而 CHUNKS_PER_TICK＝"
        .. MinidoracatCleaner.CONSTANTS.CHUNKS_PER_TICK .. " 更小，命中確實跨 tick")
check(countFloor("Base.Twig2") == 6, "起始：重疊區某塊 6 件（區塊上限 10）")

-- 先把前面殘留的掃描工作跑完，否則 periodicQueued 還卡著、下面不會排入新工作
runTicks(40000)

-- sentCommands 是全域累積的，只數本情境新發的
local sentBefore21 = #sentCommands
nowMs = nowMs + 61000
gridLookups = 0
runTicks(1)
check(gridLookups == 0,
    "第一個 tick 仍在建構、尚未掃描（162 步 > 128 ⇒ 建構必定跨 tick，實際查格 "
        .. gridLookups .. " 次）")

runTicks(3000)
nowMs = nowMs + 61000
runTicks(3000)

-- 斷言看的是**警告**，不是物品數。去重失效時掃描快照會把這塊數成 12（>上限 10）並發出
-- 超標警告，但物品不會被誤刪——刪除前的 recount 以實體世界重數（liveChunkCount，見
-- WorldScanner 的 processDeleteQueue：live=6 ≤ 10 ⇒ victim 取消）。所以「還剩 6 件」
-- 在去重失效時同樣成立，用它當斷言等於什麼都沒釘住（實測變異不轉紅）。
-- 真正的可觀測後果是玩家收到假警告，加上掃描量從 90 塊變成 162 塊
local twigWarns = 0
for index = sentBefore21 + 1, #sentCommands do
    local sent = sentCommands[index]
    -- Core.warnNearby 送的 command 就是 "warn"，payload.detail 是 fullType
    -- （MinidoracatCleaner_Core.lua:541-542）
    if sent.command == "warn" and sent.args and sent.args.detail == "Base.Twig2" then
        twigWarns = twigWarns + 1
    end
end
check(twigWarns == 0,
    "重疊區塊只被計一次 ⇒ 6 ≤ 10 不發超標警告（實際發了 " .. twigWarns
        .. " 則；釘住跨 tick 的建構去重）")
check(countFloor("Base.Twig2") == 6,
    "且物品一件未動（刪除前 recount 是第二道保險）")

print()
print("情境二十二：玩家站在 z≠0 時，z=0 與當前層都要掃")

-- newPeriodicBuild 對 z≠0 的玩家會把 z=0 與當前層都排進來（levels[2] = playerZ）。
-- 少了這條，站在二樓時樓下的堆積永遠不會被清——而且不會有任何錯誤，只是靜默失效。
-- 佈局：玩家在 z=1，z=0 與 z=1 各堆 15 件（區塊上限 10）⇒ 兩層都該被清到 10
onlineRoster = nil
-- 換 z 之前必須把前一個情境的週期掃描跑完：periodicQueued 在 finishJob 之後才清，若還卡著
-- 未完成的 job，下面 nowMs 推進時 queuePeriodicScan 會直接 return（不排新工作），於是
-- 這一輪用的仍是舊 job 的範圍——那份是 playerZ 還等於 0 時建的，z=1 的 fixture 不在裡面。
-- 實測會讓這條有一半機率量到 25~30 而非 20（不推進 nowMs，所以只消化不新排）。
-- tick 數要給足：情境十八在世界裡留了 5000 個 decoy，它們每輪都會被排進刪除佇列，
-- 而佇列是全域共用的——沒排空就進下一個情境，新的 victim 會卡在後面等，
-- 於是 warn 有寫、auto_clean 卻一直沒發生
runTicks(40000)
playerZ = 1
for _ = 1, 15 do
    putOnFloor(101, 101, 0, makeItem("Base.Twig3", "dumper"))
    putOnFloor(101, 101, 1, makeItem("Base.Twig3", "dumper"))
end
check(countFloor("Base.Twig3") == 30, "起始：z=0 與 z=1 各 15 件（區塊上限 10）")

-- 斷言用「兩層各自都有被清」而不是「總量恰好 20」：dirty job 會插隊（前面情境刪了數千件、
-- 每次刪除都會 markDirty），週期掃描被延後的輪數不可控，寫死總量會有一半機率偶發假紅。
-- 分層檢查已足以抓住要守的迴歸——少了 levels[2] 那行，z=1 會一件都不掉
local rounds22 = 0
for _ = 1, 12 do
    nowMs = nowMs + 61000
    runTicks(3000)
    rounds22 = rounds22 + 1
    if countFloorAtZ("Base.Twig3", 0) < 15 and countFloorAtZ("Base.Twig3", 1) < 15 then
        break
    end
end
check(countFloorAtZ("Base.Twig3", 0) < 15,
    "z=0 那層被清（剩 " .. countFloorAtZ("Base.Twig3", 0) .. " 件）")
check(countFloorAtZ("Base.Twig3", 1) < 15,
    "z=1 那層也被清（剩 " .. countFloorAtZ("Base.Twig3", 1)
        .. " 件，用了 " .. rounds22 .. " 輪；釘住 z≠0 時的雙層掃描）")

playerZ = 0
sandbox.ScanRadius = savedRadius21
sandbox.MaxFloorItemsPerType = savedChunk21
sandbox.MaxFloorItemsPerTypeArea = savedArea21

print()
print("情境二十三：區塊清單必須跨 tick 建構，不可一次建完")

-- 這是本次效能修正的核心，而它需要「區塊數 > CHUNKS_PER_TICK」才會走到——前面所有情境的
-- ScanRadius 都是 16（每位玩家 5×5＝25 個區塊 < 128），stepPeriodicBuild 一個 tick 就建完，
-- 「還沒建完就 return」那條路徑從來沒被執行過。
-- 佈局：ScanRadius 80 ⇒ 21×21＝441 個區塊，在 CHUNKS_PER_TICK=128 之下需要 4 個 tick。
-- 活性證據用 gridLookups：建構期間完全不呼叫 getGridSquare，所以前幾個 tick 必須是 0，
-- 之後才會開始逐格掃描。
-- 放在最後一條：ScanRadius 80 的掃描盒會涵蓋前面情境的 fixture，跑完整輪會干擾它們
local savedRadius23 = sandbox.ScanRadius

-- 先把前面殘留的掃描工作跑完，否則 periodicQueued 還卡著、下面不會排入新工作
runTicks(40000)
sandbox.ScanRadius = 80

nowMs = nowMs + 61000
gridLookups = 0
runTicks(3)
check(gridLookups == 0,
    "建構期間一格都沒查（前 3 個 tick 只在建 441 個區塊的清單，實際 " .. gridLookups .. " 次）")

runTicks(5)
check(gridLookups > 0,
    "建構完成後才開始逐格掃描（實際 " .. gridLookups .. " 次，釘住跨 tick 建構）")

sandbox.ScanRadius = savedRadius23

print()
print("情境二十四：物品清理的分類總開關")

-- 總開關的用途是「不必把四個上限逐一改成 0 就能停用整套物品清理」。
-- 要守兩個方向：關閉時連超標也不動、重新開啟後恢復正常清理（不能因為關過就永久失效）。
-- 動物那個開關走的是同一套判定（AnimalScanner.runAnimalScan 開頭），但 harness 沒有動物的
-- mock（全檔零個動物情境），所以那邊只能靠實機驗證——這裡誠實留下缺口說明，不假裝有覆蓋
local savedChunk24 = sandbox.MaxFloorItemsPerType
local savedArea24 = sandbox.MaxFloorItemsPerTypeArea
sandbox.MaxFloorItemsPerType = 10
sandbox.MaxFloorItemsPerTypeArea = 2000
sandbox.ItemCleanupEnabled = false

for _ = 1, 30 do
    putOnFloor(99, 103, 0, makeItem("Base.Nut", "dumper"))
end
check(countFloor("Base.Nut") == 30, "起始：同一塊 30 件（區塊上限 10、總開關關閉）")

for _ = 1, 3 do
    nowMs = nowMs + 61000
    runTicks(3000)
end
check(countFloor("Base.Nut") == 30,
    "總開關關閉時，超標也完全不清（釘住總開關優先於上限）")

sandbox.ItemCleanupEnabled = true
local rounds24 = 0
for _ = 1, 10 do
    nowMs = nowMs + 61000
    runTicks(3000)
    rounds24 = rounds24 + 1
    if countFloor("Base.Nut") == 10 then
        break
    end
end
check(countFloor("Base.Nut") == 10,
    "重新開啟後恢復清理、清到上限 10（用了 " .. rounds24 .. " 輪；關過不會永久失效）")
sandbox.MaxFloorItemsPerType = savedChunk24
sandbox.MaxFloorItemsPerTypeArea = savedArea24

print()
print("情境二十五：單一熱點落盤失敗，不得牽連其他熱點，也不得重複寫出")

-- 落盤（auto_clean log ＋ 玩家通知）刻意**不重試**：真正該重試的寫檔失敗根本傳不到 Lua
-- （ZLogger.write 把 Exception 全 catch 掉只印 DebugLog，ZLogger.java:48-54），而對 Lua 層
-- 例外重放整張表會每 tick 拋一份堆疊（Event.trigger 逐次 catch 後照常註冊，
-- Event.java:52-59）並重複寫 log／重複通知玩家。設計改成「先從表移除、每個熱點各自 pcall、
-- 首個錯誤最後重拋」，要守的是三件事：
--   ① 壞掉的那一個熱點不會把其他熱點的稽核一起帶走
--   ② 例外仍然可見（不是靜默吞掉）
--   ③ 已寫出的熱點不會被重放（下一個 tick 不再出現第二行）
local savedChunk25 = sandbox.MaxFloorItemsPerType
local savedArea25 = sandbox.MaxFloorItemsPerTypeArea
sandbox.MaxFloorItemsPerType = 10
sandbox.MaxFloorItemsPerTypeArea = 2000
sandbox.ItemCleanupEnabled = true

-- 只讓「指定 fullType 的 auto_clean 那一行」拋錯，其餘 log 照常寫
local failFullType = nil
local realWriteLog = writeLog
function writeLog(logger, text)
    if failFullType and string.find(text, "auto_clean", 1, true)
        and string.find(text, failFullType, 1, true) then
        error("模擬落盤路徑的 Lua 例外")
    end
    return realWriteLog(logger, text)
end

local function countAutoClean(fullType)
    local n = 0
    for _, line in ipairs(logLines) do
        if string.find(line, "auto_clean", 1, true)
            and string.find(line, fullType, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function countCleanedNotices(fullType, fromIndex)
    local n = 0
    for index = fromIndex + 1, #sentCommands do
        local sent = sentCommands[index]
        if sent.command == "cleaned" and sent.args and sent.args.detail == fullType then
            n = n + 1
        end
    end
    return n
end

-- 兩個熱點放在**不同區塊**才會是兩筆 cleanNotify（key 含區塊座標）。
-- 座標要落在玩家 (100,100) 於 ScanRadius 16 之下的區塊範圍（cx/cy 10..14，即格 80..119）：
-- 區塊 (10,14) 與 (12,14)。各 25 件、上限 10 ⇒ 各要刪 15 件。
-- 兩塊合計刪 30 件 > ITEMS_PER_TICK（16）⇒ 跨 tick，排空時一次落盤兩筆
for _ = 1, 25 do
    putOnFloor(81, 113, 0, makeItem("Base.ProbeBad", "dumper"))
    putOnFloor(97, 114, 0, makeItem("Base.ProbeGood", "dumper"))
end
check(countFloor("Base.ProbeBad") == 25 and countFloor("Base.ProbeGood") == 25,
    "起始：兩個不同區塊各 25 件（上限 10，各要刪 15 件）")

local sentBefore25 = #sentCommands
failFullType = "Base.ProbeBad"
nowMs = nowMs + 61000
runTicks(3000)   -- 警告輪
nowMs = nowMs + 61000
runTicks(3000)   -- 清理輪 → 排空 → 落盤（壞熱點拋錯，被逐項 pcall 攔下）

check(countFloor("Base.ProbeBad") == 10 and countFloor("Base.ProbeGood") == 10,
    "兩塊都已刪到上限（刪除在落盤之前，不可逆）")
check(countAutoClean("Base.ProbeBad") == 0,
    "壞掉的那個熱點沒有稽核行（它的 log 寫不出去）")
-- emitCleanEntry 內是「先寫稽核、後發通知」，讓部分成功落在最少害的位置：
-- 稽核優先於通知。順序若被對調，壞熱點會變成「玩家收到清理通知、稽核檔案卻沒有那一行」
check(countCleanedNotices("Base.ProbeBad", sentBefore25) == 0,
    "壞熱點也沒有發出玩家通知（釘住 emitCleanEntry 內先 log 後通知的順序；實際 "
        .. countCleanedNotices("Base.ProbeBad", sentBefore25) .. " 則）")
check(countAutoClean("Base.ProbeGood") == 1,
    "另一個熱點的稽核**照樣寫出**（釘住個別 pcall：少了它這行會一起消失，實際 "
        .. countAutoClean("Base.ProbeGood") .. " 行）")
check(countCleanedNotices("Base.ProbeGood", sentBefore25) == 1,
    "另一個熱點的玩家通知也照樣發出（實際 "
        .. countCleanedNotices("Base.ProbeGood", sentBefore25) .. " 則）")

-- 已寫出的熱點不得被重放。這需要**第二次落盤**才觀察得到：flush 只在刪除佇列排空那一刻
-- 被呼叫，光是空轉幾十輪並不會再進去（佇列空 ⇒ processDeleteQueue 開頭就 return），
-- 所以要另外製造一次爆發。第三個區塊 (13,14)、另一個 fullType：
-- 它排空時會再呼叫一次 flush，屆時若舊熱點還留在 cleanNotify 裡就會被重寫一行
failFullType = nil
for _ = 1, 25 do
    putOnFloor(105, 116, 0, makeItem("Base.ProbeTrigger", "dumper"))
end
local rounds25 = 0
for _ = 1, 20 do
    nowMs = nowMs + 61000
    runTicks(3000)
    rounds25 = rounds25 + 1
    if countAutoClean("Base.ProbeTrigger") > 0 then
        break
    end
end
check(countAutoClean("Base.ProbeTrigger") == 1,
    "第二次爆發確實落盤了（活性：沒有這條，下面的『沒重複』可能只是 flush 從未再被呼叫；"
        .. "用了 " .. rounds25 .. " 輪）")
check(countAutoClean("Base.ProbeGood") == 1,
    "第二次落盤沒有重寫第一批的熱點（釘住處理後即從表移除；實際 "
        .. countAutoClean("Base.ProbeGood") .. " 行）")
check(countCleanedNotices("Base.ProbeGood", sentBefore25) == 1,
    "玩家也沒有收到重複通知（實際 "
        .. countCleanedNotices("Base.ProbeGood", sentBefore25) .. " 則）")
-- **本輪最核心的設計決定就是這一條**：失敗的熱點也在處理前就被移除，所以它不會被重放。
-- 少了這條斷言，把 flushCleanNotify 改成「成功才移除、失敗留回表裡」（＝把重試語意從後門
-- 加回來）不會讓任何斷言轉紅：ProbeGood 成功後照樣被移除，而 ProbeBad 會在這次
-- ProbeTrigger 的 flush 被重放、且此時注入已關閉所以會成功寫出一行——沒有人在看它。
-- 這是移除重試後與舊設計唯一的行為差異，必須有斷言
check(countAutoClean("Base.ProbeBad") == 0,
    "失敗的熱點也沒有被重放（釘住「失敗項同樣不留回表裡」；實際 "
        .. countAutoClean("Base.ProbeBad") .. " 行）")
check(countCleanedNotices("Base.ProbeBad", sentBefore25) == 0,
    "失敗的熱點也沒有補發通知（實際 "
        .. countCleanedNotices("Base.ProbeBad", sentBefore25) .. " 則）")

writeLog = realWriteLog
sandbox.ItemCleanupEnabled = true
sandbox.MaxFloorItemsPerType = savedChunk25
sandbox.MaxFloorItemsPerTypeArea = savedArea25

print()
print("情境二十六：刪除爆發中途被停用，已刪除的部分仍要落盤")

-- 這是落盤的**第二個出口**（resetDisabledState），也是最初促成 flushCleanNotify 存在的
-- 那個問題：刪除在 removeFloorItem 回 true 那刻就不可逆，但稽核要等佇列排空才寫。管理員
-- 若在爆發進行中關掉 ItemCleanupEnabled，舊版會在 reset 裡直接丟掉 cleanNotify ⇒ 已經
-- 刪掉的物品完全沒有 auto_clean 紀錄。
-- 情境二十四測的是「關閉時不動手」（那時還沒有任何刪除），情境二十五走的是正常 queue-drain
-- 出口——兩者都不涵蓋這條路徑：把 resetDisabledState 裡的 flushCleanNotify() 刪掉，
-- 前面 174 條斷言全部照樣綠（實測過）。
local savedChunk26 = sandbox.MaxFloorItemsPerType
local savedArea26 = sandbox.MaxFloorItemsPerTypeArea
sandbox.MaxFloorItemsPerType = 10
sandbox.MaxFloorItemsPerTypeArea = 2000
sandbox.ItemCleanupEnabled = true

-- 區塊 (14,13)（x 112..119、y 104..111），在 ScanRadius 16 的 cx/cy 10..14 內。
-- 這一塊情境十五的 Base.Nails 也用過（它鋪 cx/cy 8..15 全部），但計數是 per-fullType，
-- 兩者不會交叉觸發——隔離靠的是專屬 fullType，不是區塊獨佔。130 件、上限 10 ⇒ 要刪 120 件，
-- 每 tick 只刪 ITEMS_PER_TICK（16）⇒ 必定跨 tick，中途才有窗口可以關開關
for _ = 1, 130 do
    putOnFloor(113, 105, 0, makeItem("Base.ProbeDisable", "dumper"))
end
check(countFloor("Base.ProbeDisable") == 130, "起始：同一塊 130 件（上限 10，要刪 120 件）")

nowMs = nowMs + 61000
runTicks(3000)   -- 警告輪
nowMs = nowMs + 61000
local mid26 = 130
for _ = 1, 3000 do
    runTicks(1)
    mid26 = countFloor("Base.ProbeDisable")
    if mid26 < 130 then
        break
    end
end
check(mid26 > 10 and mid26 < 130,
    "爆發進行中就停手（剩 " .. mid26 .. " 件，介於 130 與上限 10 之間）")
-- 活性：這一條證明後面的 auto_clean 是**停用轉場**寫的，不是正常排空寫的
check(countAutoClean("Base.ProbeDisable") == 0,
    "此刻還沒有任何稽核行（聚合要等佇列排空才寫，所以下面那行只能來自停用轉場）")

sandbox.ItemCleanupEnabled = false
runTicks(1)
check(countAutoClean("Base.ProbeDisable") == 1,
    "中途停用時把已刪除的部分落盤了（釘住 resetDisabledState 裡的 flushCleanNotify；實際 "
        .. countAutoClean("Base.ProbeDisable") .. " 行）")

-- 停用後不得再刪，也不得再寫第二行
for _ = 1, 3 do
    nowMs = nowMs + 61000
    runTicks(1000)
end
check(countFloor("Base.ProbeDisable") == mid26, "停用後一件都沒再刪")
check(countAutoClean("Base.ProbeDisable") == 1,
    "也沒有重複寫出（實際 " .. countAutoClean("Base.ProbeDisable") .. " 行）")

sandbox.ItemCleanupEnabled = true
sandbox.MaxFloorItemsPerType = savedChunk26
sandbox.MaxFloorItemsPerTypeArea = savedArea26

print()
do
print("情境二十七：章的欄位精簡與舊格式遷移")
-- 核心性質：同一小時同一人的章必須逐 byte 相同（CompressIdenticalItems 命中前提）。
local Stamp = MinidoracatCleaner
local savedSec27 = nowSec

-- ① 核心性質：同一小時內的兩次蓋章必須產生完全相同的值。
--    刻意讓兩次相差 61 秒——若時間取整退回分鐘精度，值就會不同、本條轉紅。
--    這是唯一真正防止迴歸的斷言，不可改成同一秒（同一秒下分鐘與小時精度都會通過）
nowSec = STAMP_HOUR
local itemA27 = makeItem("Base.StampProbe")
Stamp.stampMove(itemA27, "ryan")
local valA27 = rawget(itemA27:getModData(), Stamp.KEY_TOUCH)
nowSec = STAMP_HOUR + 61
local itemB27 = makeItem("Base.StampProbe")
Stamp.stampMove(itemB27, "ryan")
check(valA27 ~= nil and valA27 == rawget(itemB27:getModData(), Stamp.KEY_TOUCH),
    "同一小時內同一人的章逐 byte 相同（相差 61 秒；分鐘精度會轉紅）")

-- ② 活性：跨小時必須不同。少了這條，①有可能只是因為時間根本沒被寫進值裡
nowSec = STAMP_HOUR + 3601
local itemC27 = makeItem("Base.StampProbe")
Stamp.stampMove(itemC27, "ryan")
check(rawget(itemC27:getModData(), Stamp.KEY_TOUCH) ~= valA27,
    "跨小時的章不同（活性：證明時間真的寫進值裡，不是常數）")

-- ③ 活性：不同操作者必須不同
nowSec = STAMP_HOUR
local itemD27 = makeItem("Base.StampProbe")
Stamp.stampMove(itemD27, "dandankk")
check(rawget(itemD27:getModData(), Stamp.KEY_TOUCH) ~= valA27,
    "不同操作者的章不同（活性：證明名字真的寫進值裡）")

-- ④ 任一次操作要一次遷移**三個**舊 key。容器搬動本來只改 mover，但舊 dropper 若留著，
--    就會與已完整遷移的同型物品永久分裂；CHANGELOG「下次搬動自動換格式」也會變假話
local itemE27 = makeItem("Base.StampProbe")
itemE27._modData[Stamp.LEGACY_DROPPED] = "legacydropper"
itemE27._modData[Stamp.LEGACY_MOVED] = "olduser"
itemE27._modData[Stamp.LEGACY_MOVED_AT] = 1787400000
Stamp.stampMove(itemE27, "ryan")
check(rawget(itemE27:getModData(), Stamp.LEGACY_DROPPED) == nil
        and rawget(itemE27:getModData(), Stamp.LEGACY_MOVED) == nil
        and rawget(itemE27:getModData(), Stamp.LEGACY_MOVED_AT) == nil
        and rawget(itemE27:getModData(), Stamp.KEY_DROP) == "legacydropper",
    "搬動一次即遷移丟棄者＋操作者＋時間三個舊 key（dropper 已轉 MIC42_d）")

-- ⑤ round-trip：解析回來要拿得到名字與小時整點
local nameE27, atE27 = Stamp.readTouch(itemE27)
check(nameE27 == "ryan" and atE27 == STAMP_HOUR,
    "新格式 round-trip（實際 " .. tostring(nameE27) .. " / " .. tostring(atE27) .. "）")

-- ⑥ 舊存檔的章仍讀得到——換格式不能讓既有紀錄消失
local itemF27 = makeItem("Base.StampProbe")
itemF27._modData[Stamp.LEGACY_MOVED] = "olduser"
itemF27._modData[Stamp.LEGACY_MOVED_AT] = 1787400060
local nameF27, atF27 = Stamp.readTouch(itemF27)
check(nameF27 == "olduser" and atF27 == 1787400060,
    "0.3.0 舊 key 仍讀得到（沒再被碰過的物品不會憑空失去章）")

-- ⑦ 丟棄者章：舊 key 讀得到，蓋新章後改讀新 key 且舊 key 已刪
local itemG27 = makeLegacyItem("Base.StampProbe", "legacydropper")
check(Stamp.readDrop(itemG27) == "legacydropper", "丟棄者舊 key 仍讀得到")
Stamp.stampDrop(itemG27, "newdropper")
check(Stamp.readDrop(itemG27) == "newdropper"
        and rawget(itemG27:getModData(), Stamp.LEGACY_DROPPED) == nil,
    "蓋新丟棄者章後改讀新 key、舊 key 已刪")

-- ⑧ 名字裡的欄位分隔符必須在寫入點就被清掉，否則能偽造時間欄位、或讓解析取到錯的名字。
--    分隔符是 `,`：PZ 引擎層本來就拒收含它的 username（ServerWorldDatabase.java:769），
--    sanitizeName 是第二層，把它換成空白，於是 decode 找到的仍是真正的時間戳
local itemH27 = makeItem("Base.StampProbe")
Stamp.stampMove(itemH27, "evil,9999999999")
local nameH27, atH27 = Stamp.readTouch(itemH27)
check(nameH27 ~= nil and nameH27:find(",", 1, true) == nil and atH27 == STAMP_HOUR,
    "名字裡的 , 被清掉，無法偽造時間欄位（解析出 " .. tostring(nameH27) .. " / " .. tostring(atH27) .. "）")
nowSec = savedSec27
end

do
local Stamp = MinidoracatCleaner
local savedSec27Edges = nowSec
nowSec = STAMP_HOUR

-- ⑨ 新 key 壞值不能遮蔽仍有效的舊 key（readDropFrom / touchValueFrom 的 fail-soft）
local itemI27 = makeLegacyItem("Base.StampProbe", "legacydropper")
itemI27._modData[Stamp.KEY_DROP] = ""
check(Stamp.readDrop(itemI27) == "legacydropper", "空 MIC42_d 不遮蔽仍有效的 legacy dropper")
local itemJ27 = makeItem("Base.StampProbe")
itemJ27._modData[Stamp.KEY_TOUCH] = ",123"
itemJ27._modData[Stamp.LEGACY_MOVED] = "oldmover"
itemJ27._modData[Stamp.LEGACY_MOVED_AT] = STAMP_HOUR + 60
Stamp.stampDrop(itemJ27, "dropper")
local nameJ27, atJ27 = Stamp.readTouch(itemJ27)
check(nameJ27 == "oldmover" and atJ27 == STAMP_HOUR
        and rawget(itemJ27._modData, Stamp.LEGACY_MOVED) == nil,
    "壞 MIC42_t 不遮蔽 legacy mover；下一次操作保留舊章、取整並完成遷移")

-- ⑩ writeTouch 缺 at 必須 fail-closed，不得用 client 本端時鐘鑄造與 server 不同的章
local itemK27 = makeItem("Base.StampProbe")
Stamp.stampMove(itemK27, "server")
local beforeK27 = rawget(itemK27._modData, Stamp.KEY_TOUCH)
check(Stamp.writeTouch(itemK27, "client", nil) == nil
        and rawget(itemK27._modData, Stamp.KEY_TOUCH) == beforeK27,
    "writeTouch 缺 at 直接不寫，保留 server 原章（不從 client 時鐘補值）")

-- ⑪ 遷移路徑也必須消毒 legacy 名字。0.3.0 寫入的章沒有本版的分隔符保證（手改存檔、
--    異版 client 都可能留下含 `,` 的名字）；touchValueFrom 若直接串接，decode 會在
--    第一個分隔符切斷 → 名字截成 `a`、tonumber("b,<hour>") 得 nil 而時間永久掉失。
--    這條在 touchValueFrom 少掉 sanitizeName 時轉紅。
local itemL27 = makeItem("Base.StampProbe")
itemL27._modData[Stamp.LEGACY_MOVED] = "a,b"
itemL27._modData[Stamp.LEGACY_MOVED_AT] = STAMP_HOUR
Stamp.stampDrop(itemL27, "dropper")
local nameL27, atL27 = Stamp.readTouch(itemL27)
check(nameL27 == "a b" and atL27 == STAMP_HOUR,
    "遷移時 legacy 名字也過 sanitizeName（實際 " .. tostring(nameL27) .. " / " .. tostring(atL27) .. "）")

nowSec = savedSec27Edges
end

print()
do
local Stamp = MinidoracatCleaner
print("情境二十八：分桶呼叫點讀新 key（isHighTolerance）")
-- review 抓到的覆蓋空白（實測確認）：把 isHighTolerance 改回只讀 LEGACY_DROPPED，
-- 原本 27 個情境全綠——因為 fixture 全寫舊 key。fixture 已改寫新 key（情境一的整合
-- 路徑現在跑新格式），這裡再對呼叫點語意做直接斷言：四種輸入各釘一條。
local hiSet28 = Stamp.getHighToleranceMatcher()
check(Stamp.isHighTolerance(hiSet28, makeItem("Base.BucketProbe", "ryan"), "Base.BucketProbe", true) == false,
    "新 key（MIC42_d）有章 → 一般桶（變異「改回只讀舊 key」時本條轉紅）")
check(Stamp.isHighTolerance(hiSet28, makeLegacyItem("Base.BucketProbe", "ryan"), "Base.BucketProbe", true) == false,
    "舊 key（lastDroppedBy）有章 → 一般桶（0.3.0 存檔相容）")
check(Stamp.isHighTolerance(hiSet28, makeItem("Base.BucketProbe", nil), "Base.BucketProbe", true) == true,
    "無章 → 高容忍桶")
check(Stamp.isHighTolerance(hiSet28, makeItem("Base.BucketProbe", "ryan"), "Base.BucketProbe", false) == false,
    "追蹤關閉 → fail-closed：不看章一律一般桶")
end

print()
do
local Stamp = MinidoracatCleaner
local savedSec29 = nowSec
print("情境二十九：touch 指令的覆蓋偵測與 ack（Commands 呼叫點）")
-- Commands.lua touchItems 的 readTouch 呼叫點先前零覆蓋（review Important 1）。
-- 流程：tester 先蓋 → rival 覆蓋 → 斷言 touch_overwrite log 與 touchAck payload。
-- 節流 key 是 command:username（Commands.lua:190），兩位玩家不互擋。
local rivalInv29 = makeContainer("player")
local rival29 = {
    getX = function() return playerX end,
    getY = function() return playerY end,
    getZ = function() return playerZ end,
    getUsername = function() return "rival" end,
    getOnlineID = function() return 2 end,
    getCurrentSquare = function() return getOrMakeSquare(100, 100, 0) end,
    getInventory = function() return rivalInv29 end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
local shelf29 = makeContainer("furniture")
putFurniture(100, 100, 0, shelf29)
local probe29 = shelf29:add(makeItem("Base.TouchProbe"))
nowSec = STAMP_HOUR
local logBase29 = #logLines
local sentBase29 = #sentCommands

for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "touch", player, { ids = { probe29:getID() } })
end
local n29, at29 = Stamp.readTouch(probe29)
check(n29 == "tester" and at29 == STAMP_HOUR, "tester 蓋章成功且時間為整點（實際 "
    .. tostring(n29) .. " / " .. tostring(at29) .. "）")
local function countOverwriteSince29(base)
    local n = 0
    for i = base + 1, #logLines do
        if logLines[i]:find("touch_overwrite", 1, true) then n = n + 1 end
    end
    return n
end
check(countOverwriteSince29(logBase29) == 0, "首次蓋章（無前手）不寫 touch_overwrite")

nowMs = nowMs + 1100   -- 過 touch:rival 自己的節流窗（不同 key 本不互擋，保險起見仍推進）
for _, fn in ipairs(clientCommandHandlers) do
    fn("MinidoracatCleaner", "touch", rival29, { ids = { probe29:getID() } })
end
local n29b = Stamp.readTouch(probe29)
check(n29b == "rival", "rival 覆蓋成功（變異「readTouch 回 nil」或「改讀舊 key」時本條或下一條轉紅）")
check(countOverwriteSince29(logBase29) == 1, "覆蓋他人章寫出一行 touch_overwrite（洗章偵測的第二份證據）")
local sawOverwriteDetail29 = false
for i = logBase29 + 1, #logLines do
    if logLines[i]:find("overwritten=1", 1, true) and logLines[i]:find("batch=1", 1, true) then
        sawOverwriteDetail29 = true
    end
end
check(sawOverwriteDetail29, "touch_overwrite 的 detail 帶 overwritten=1 batch=1")
local ack29 = 0
local ackAtOk29 = true
for i = sentBase29 + 1, #sentCommands do
    local c = sentCommands[i]
    if c.command == "touchAck" then
        ack29 = ack29 + 1
        if c.args.at ~= STAMP_HOUR then ackAtOk29 = false end
    end
end
check(ack29 >= 2 and ackAtOk29, "兩次 touch 各推送 touchAck 且 at 是 server 的整點值（實際 "
    .. ack29 .. " 則）")
nowSec = savedSec29
end

print()
do
local Stamp = MinidoracatCleaner
local savedSec30 = nowSec
print("情境三十：章的 key 插入順序一致性（壓縮命中前提）")
-- modData 序列化直接迭代 KahluaTableImpl 的 LinkedHashMap（KahluaTableImpl.java:205-231），
-- 插入順序決定 byte 序列；CompressIdenticalItems 逐 byte 比對。rewriteStamps 的契約是
-- 「先全刪、再按 drop→touch 固定順序重插」，於是**不論操作歷史**最終順序一致。
-- harness 的 modData 是標準 Lua table、看不到順序，但 LinkedHashMap 的最終順序由
-- rawset 呼叫序完全決定（rawset(k,nil)=remove、rawset(k,v)=put）——所以攔截全域 rawset
-- 記錄呼叫序，斷言呼叫序即斷言 LinkedHashMap 的最終插入序。
nowSec = STAMP_HOUR
local itemA30 = makeItem("Base.OrderProbe")   -- 歷史 A：先被搬（touch）、後被丟（drop）
local itemB30 = makeItem("Base.OrderProbe")   -- 歷史 B：先被丟（drop）、後被搬（touch）
local logA30, logB30 = {}, {}
local realRawset30 = rawset
rawset = function(t, k, v)
    local entry = (v == nil and "-" or "+") .. tostring(k)
    if t == itemA30._modData then logA30[#logA30 + 1] = entry
    elseif t == itemB30._modData then logB30[#logB30 + 1] = entry end
    return realRawset30(t, k, v)
end
Stamp.stampMove(itemA30, "ryan")
Stamp.stampDrop(itemA30, "ryan")
Stamp.stampDrop(itemB30, "ryan")
Stamp.stampMove(itemB30, "ryan")
rawset = realRawset30
local function finalRewrite30(log)
    -- 每次 rewriteStamps 的完整操作序固定為 5 次 remove＋最多 2 次 put。只看 `+` 不夠：
    -- LinkedHashMap 對既有 key 的 put **不改插入序**，所以「不先刪、只照 d→t put」時
    -- +rawset 記錄照樣是 d,t，但物品 A 的真實順序仍是 t,d（R2 review 抓到的假綠）。
    if #log < 7 then return table.concat(log, ",") end
    local out = {}
    for i = #log - 6, #log do out[#out + 1] = log[i] end
    return table.concat(out, ",")
end
local expected30 = "-MIC42_d,-MIC42_t,-MIC42_lastDroppedBy,-MIC42_lastMovedBy,"
    .. "-MIC42_lastMovedAt,+MIC42_d,+MIC42_t"
check(#logA30 > 0 and #logB30 > 0, "活性：兩件物品的 rawset 都有被攔截記錄")
check(finalRewrite30(logA30) == finalRewrite30(logB30),
    "兩種操作歷史的最終 rewrite 序相同（實際 A=" .. finalRewrite30(logA30)
    .. " B=" .. finalRewrite30(logB30) .. "）")
check(finalRewrite30(logA30) == expected30,
    "每次都先刪新舊五 key，再固定 drop→touch 重插（反序／不先刪任一變異皆轉紅）")
check(rawget(itemA30._modData, "MIC42_t") == rawget(itemB30._modData, "MIC42_t")
        and rawget(itemA30._modData, "MIC42_d") == rawget(itemB30._modData, "MIC42_d"),
    "兩種歷史的最終 key 值也完全相同（同人同小時 → 可與彼此壓縮）")
nowSec = savedSec30
end

print()
print("情境三十一：AnimalGroupList 的 * / all 語意")
do
    -- 動物定義用檔頭的全域 mock（ANIMAL_GROUPS：rattus→rat、hen→chicken、doe→deer、sow→pig）。
    -- 刻意不在這裡重設 AnimalDefinitions：那會蓋掉 AnimalScanner 也在用的同一份表，
    -- 而情境三十二要靠它把 sow 認成 pig
    local savedList = sandbox.AnimalGroupList

    sandbox.AnimalGroupList = ""
    local defSet = MinidoracatCleaner.getAnimalGroupSet()
    check(defSet.rat == true and defSet.mouse == true and defSet.rabbit == true and defSet.chicken == true,
        "留空 → 預設四害獸都在 set 裡")
    check(defSet.deer == nil and defSet.pig == nil and defSet._allowAll == nil,
        "留空 → 不是 all，也不含鹿／豬")

    sandbox.AnimalGroupList = "all"
    local allSet = MinidoracatCleaner.getAnimalGroupSet()
    check(allSet._allowAll == true, "all → _allowAll sentinel")
    check(allSet.rat == nil and allSet.deer == nil,
        "all 模式不逐一列 group key（scanner 看 sentinel）")

    sandbox.AnimalGroupList = "*"
    check(MinidoracatCleaner.getAnimalGroupSet()._allowAll == true, "* 等同 all")

    sandbox.AnimalGroupList = "ALL"
    check(MinidoracatCleaner.getAnimalGroupSet()._allowAll == true, "ALL 不分大小寫")

    sandbox.AnimalGroupList = "all,rat"
    check(MinidoracatCleaner.getAnimalGroupSet()._allowAll == true,
        "清單裡只要出現 all／* 就整份當全部（不必手列其餘）")

    sandbox.AnimalGroupList = "deer,rat"
    local mix = MinidoracatCleaner.getAnimalGroupSet()
    check(mix.deer == true and mix.rat == true, "明示清單解析 deer+rat")
    check(mix._allowAll == nil and mix.chicken == nil and mix.pig == nil,
        "明示清單不是 all，也不帶預設雞／豬")

    -- scanner 端的判定不在這裡驗——測試自己複製一份 `set._allowAll or set[group]` 是套套
    -- 邏輯，把 AnimalScanner 那行變異回舊版也不會轉紅（review 實測）。真實消費端由
    -- 情境三十二驅動 runAnimalScan 覆蓋。

    sandbox.AnimalGroupList = savedList
end
print()
print("情境三十二：AnimalScanner 的真實掃描（* 生效、remove 分幀、NaN 跳過）")
do
local C = MinidoracatCleaner.CONSTANTS
-- 不宣告 savedXxx local（main chunk 的 200 locals 額度已滿）：檔頭的 SandboxVars 存根
-- 本來就沒有任何動物選項（走 DEFAULTS），所以收尾直接設回 nil 就是還原

-- seedPigs／countEvent／livePigs／resetWarned 已提升為共用全域（見 runTicks 之後那一段）：
-- 情境三十四需要同一組工具，而 main chunk 的 local 額度已滿

sandbox.AnimalCleanupEnabled = true
sandbox.MaxAnimalsPerGroup = 10
sandbox.MaxZoneAnimalsPerGroup = 0
-- 掃描間隔 0：本情境的標的是「清除怎麼攤平」，不是「多久掃一次」
sandbox.AnimalScanIntervalSeconds = 0

-- ① 明示清單沒有 pig ⇒ 一隻都不該碰。這條同時是 ② 的對照組：證明 ② 的清理確實來自 `*`
sandbox.AnimalGroupList = "rat"
seedAnimals({ { atype = "sow", count = 30 } })
runTicks(12)
check(#ANIMAL_REMOVED == 0,
    "明示清單未列 pig ⇒ 30 隻豬一隻都沒被清（實際 " .. #ANIMAL_REMOVED .. "）")

-- ② `*` ⇒ pig 進入清理。**這條釘住 AnimalScanner 的 sentinel 消費點**：all 模式下
--    allowedGroups 只有 _allowAll、不含 pig key，所以把判定變異回舊版 allowedGroups[group]
--    會讓清理數變 0 而轉紅——正是情境三十一的複製品斷言擋不住的那個回歸
sandbox.AnimalGroupList = "*"
resetAnimalWarned()
seedAnimals({ { atype = "sow", count = 30 } })
local cleanBefore32 = countLogEvent("animal_clean")
local perTick32 = {}
for _ = 1, 14 do
    local before = #ANIMAL_REMOVED
    runTicks(1)
    perTick32[#perTick32 + 1] = #ANIMAL_REMOVED - before
end
check(#ANIMAL_REMOVED == C.ANIMALS_PER_ROUND,
    "* 讓 pig 進清理，總量等於每輪額度 " .. C.ANIMALS_PER_ROUND
        .. "（實際 " .. #ANIMAL_REMOVED .. "）")
check(liveAnimals() == 30 - C.ANIMALS_PER_ROUND,
    "剩餘等於散養上限 10（實際 " .. liveAnimals() .. "）")
local peak32 = 0
for _, n in ipairs(perTick32) do
    if n > peak32 then
        peak32 = n
    end
end
check(peak32 > 0, "活性：真的有刪（沒有這條，下面的上限斷言可能只是空轉）")
check(peak32 <= C.ANIMALS_PER_TICK,
    "單 tick remove 峰值 " .. peak32 .. " ≤ 上限 " .. C.ANIMALS_PER_TICK
        .. "（舊版是單 tick 直接刪滿 " .. C.ANIMALS_PER_ROUND .. "）")
check(countLogEvent("animal_clean") - cleanBefore32 == 1,
    "跨多個 tick 仍只寫一行 animal_clean（分幀沒有破壞逐 bucket 聚合）")

-- ③ 座標 NaN 的動物必須跳過並留診斷。掃描當時座標仍正常——NaN 會讓 chebyshevDistance
--    回 NaN 而根本進不了 bucket，所以只有「計畫排入後才壞掉」這個形態測得到，而它正是
--    實機的形態（動物狀態在幀之間變壞）。
--    數量刻意用 20 而非 30：30 隻對上限 10 會觸發 ANIMAL_EMERGENCY_MULTIPLIER（>2 倍）
--    的緊急加速而跳過警告確認，第一輪就排入，下面「第二輪才排入」的前提就不成立了
sandbox.AnimalGroupList = "*"
resetAnimalWarned()
seedAnimals({ { atype = "sow", count = 20 } })
local excess32 = 20 - 10
local nanBefore32 = countLogEvent("animal_nan")
runTicks(1)
check(#ANIMAL_REMOVED == 0, "前提：第一輪只警告、不刪")
runTicks(1)
check(#ANIMAL_REMOVED == 0,
    "前提：計畫已排入，但本 tick 還沒開始刪（onTick 先消化再掃描，排入落在尾端）")
ANIMAL_ROSTER[1]._opts.x = 0 / 0
-- 第二隻只讓 z 壞掉：這條釘住「三軸都要查」——只擋 x／y 的版本會照樣把它 remove
ANIMAL_ROSTER[2]._opts.z = 0 / 0
runTicks(14)
check(ANIMAL_ROSTER[1].isGone() == false, "x 座標 NaN 的動物沒有被 remove")
check(ANIMAL_ROSTER[2].isGone() == false, "只有 z 座標 NaN 的動物也沒有被 remove")
check(countLogEvent("animal_nan") - nanBefore32 == 1,
    "兩隻都記在同一行 animal_nan（聚合，不是逐隻寫）")
ANIMAL_NAN_LINE = nil
for i = #logLines, 1, -1 do
    if logLines[i]:find("[animal_nan]", 1, true) then
        ANIMAL_NAN_LINE = logLines[i]
        break
    end
end
check(ANIMAL_NAN_LINE ~= nil and ANIMAL_NAN_LINE:find("skipped=2", 1, true) ~= nil,
    "同兩隻 NaN 跨多個 recount tick 仍各只計一次（nanSeen 去重，實際 skipped=2）")
check(#ANIMAL_REMOVED == excess32,
    "NaN 跳過不佔額度，照樣刪滿超額的 " .. excess32 .. " 隻（實際 " .. #ANIMAL_REMOVED .. "）")
check(liveAnimals() == 20 - excess32,
    "正常座標的動物沒被誤殺、且剛好收在上限 10（x == x 恆真；剩餘 " .. liveAnimals() .. "）")

-- ④ 清理進行中關掉總開關：立刻停手，且已刪除的部分仍要落盤（物品側 0.3.0 修過同型問題）
sandbox.AnimalGroupList = "*"
resetAnimalWarned()
seedAnimals({ { atype = "sow", count = 30 } })
local cleanBefore32d = countLogEvent("animal_clean")
runTicks(3)
local partial32 = #ANIMAL_REMOVED
check(partial32 > 0 and partial32 < C.ANIMALS_PER_ROUND,
    "前提：刪了一部分但還沒刪完（實際 " .. partial32 .. "）")
check(countLogEvent("animal_clean") - cleanBefore32d == 0,
    "前提：此刻還沒落盤（聚合要等計畫做完，所以下面那行只能來自停用轉場）")
sandbox.AnimalCleanupEnabled = false
runTicks(5)
check(#ANIMAL_REMOVED == partial32,
    "關掉開關後一隻都沒再刪（實際 " .. #ANIMAL_REMOVED .. "）")
check(countLogEvent("animal_clean") - cleanBefore32d == 1,
    "已刪除的部分仍落盤，且沒有重複寫出")

-- ⑤ scanner 只治理散養：zone 類（這裡用「屬於雞舍」觸發）動物完全不進 per-player
--    候選，即使散養側超標也一隻不動。圈養的清除已搬到 AnimalBreeding 的農場治理
--    （設計評審 A2），這裡沒有圈地 fixture ⇒ 農場治理也不會動它們。
-- ④ 刻意把總開關關掉了，這裡要先開回來——否則 onTick 直接 return，連 resetWarned 都不會
-- 清到任何東西，下面的斷言會全部因為「一隻都沒清」而紅
sandbox.AnimalCleanupEnabled = true
sandbox.AnimalGroupList = "*"
sandbox.MaxZoneAnimalsPerGroup = 10
resetAnimalWarned()
ANIMAL_ROSTER = {}
for i = 1, 15 do
    ANIMAL_ROSTER[i] = makeTestAnimal({ id = 6000 + i, atype = "sow", x = 100, y = 100 })
end
for i = 16, 30 do
    -- getHutch 非 nil ⇒ classifyAnimal 回 "zone"（圈地外雞舍：不歸 scanner、也沒有農場）
    ANIMAL_ROSTER[i] = makeTestAnimal({ id = 6000 + i, atype = "sow", x = 100, y = 100, hutch = {} })
end
ANIMAL_REMOVED = {}
runTicks(14)
-- 全域而非 local：main chunk 已達 Lua 的 200 locals 硬上限（檔頭 STAMP_HOUR 同註）
ANIMAL_CLEAN_LINE = nil
for i = #logLines, 1, -1 do
    if logLines[i]:find("[animal_clean]", 1, true) then
        ANIMAL_CLEAN_LINE = logLines[i]
        break
    end
end
check(#ANIMAL_REMOVED == 5,
    "散養超 5 ＋ 雞舍 15 隻 ⇒ 只刪散養超額的 5 隻（實際 " .. #ANIMAL_REMOVED .. "）")
HUTCH_ALIVE_32 = 0
for i = 16, 30 do
    if not ANIMAL_ROSTER[i].isGone() then
        HUTCH_ALIVE_32 = HUTCH_ALIVE_32 + 1
    end
end
check(HUTCH_ALIVE_32 == 15,
    "雞舍動物一隻不動（scanner 跳過 zone 類；實際存活 " .. HUTCH_ALIVE_32 .. "）")
check(ANIMAL_CLEAN_LINE ~= nil and ANIMAL_CLEAN_LINE:find("scope=stray", 1, true) ~= nil
        and ANIMAL_CLEAN_LINE:find("zoned=0", 1, true) ~= nil,
    "log 的 scope=stray、zoned=0（scanner 不再有圈養維度）")

ANIMAL_ROSTER = nil
sandbox.AnimalGroupList = nil
sandbox.MaxAnimalsPerGroup = nil
sandbox.MaxZoneAnimalsPerGroup = nil
sandbox.AnimalScanIntervalSeconds = nil
sandbox.AnimalCleanupEnabled = nil
end

print()
print("情境三十三：server 端 drop 路徑真的寫新章格式")
do
-- installDropHooks 掛在 OnGameStart，而它才註冊 OnProcessTransaction——兩段都要驅動
for _, fn in ipairs(GAME_START_HANDLERS) do
    fn()
end
check(#TRANSACTION_HANDLERS > 0,
    "前提：drop hook 已安裝並註冊 OnProcessTransaction（安裝階段 nil-deref 會讓這條轉紅）")
local savedSec33 = nowSec
-- 刻意用非整點：驗證寫入端有取整，而不是原樣落地
nowSec = STAMP_HOUR + 1234
local item33 = makeItem("Base.StampProbe")
for _, fn in ipairs(TRANSACTION_HANDLERS) do
    fn("dropOnFloor", player, item33, nil, nil, { square = getOrMakeSquare(100, 100, 0) })
end
check(MinidoracatCleaner.readDrop(item33) == "tester",
    "drop 路徑蓋上丟棄者章（釘住 DropStamp 的 stampDrop 呼叫點）")
local mover33, at33 = MinidoracatCleaner.readTouch(item33)
check(mover33 == "tester" and at33 == STAMP_HOUR,
    "同一次 drop 也蓋操作者章、且取整到小時（實際 " .. tostring(mover33)
        .. " / " .. tostring(at33) .. "）")
check(rawget(item33._modData, MinidoracatCleaner.LEGACY_DROPPED) == nil
        and rawget(item33._modData, MinidoracatCleaner.LEGACY_MOVED) == nil
        and rawget(item33._modData, MinidoracatCleaner.LEGACY_MOVED_AT) == nil,
    "drop 路徑寫的是新 key，沒留任何 0.3.0 舊 key")
nowSec = savedSec33
end

print()
print("情境三十四：多個 bucket ＝ 多個 job")
do
sandbox.AnimalCleanupEnabled = true
sandbox.AnimalGroupList = "*"
sandbox.MaxAnimalsPerGroup = 10
sandbox.MaxZoneAnimalsPerGroup = 0
sandbox.AnimalScanIntervalSeconds = 0

-- ① 兩個群組各超標 ⇒ 兩個 bucket ⇒ 兩個 job。
--    這是 Kahlua 上「就地把消化完的槽設 nil ⇒ #removalQueue 回 0 ⇒ 第二個以後的 job
--    整表被丟棄」的最小反例形態，也是「額度跨 job 分配」與「每個 job 各一行 log」的
--    唯一可執行覆蓋——情境三十二全部只有一個 job（單玩家＋單群組），碰不到這條路徑。
seedAnimals({ { atype = "sow", count = 15 }, { atype = "hen", count = 15 } })
resetAnimalWarned()
ANIMAL_REMOVED = {}
CLEAN_BEFORE = countLogEvent("animal_clean")
runTicks(24)
check(#ANIMAL_REMOVED == 10,
    "兩群各超 5 ⇒ 共刪 10 隻（實際 " .. #ANIMAL_REMOVED .. "）")
check(liveAnimals("sow") == 10 and liveAnimals("hen") == 10,
    "兩群都收在上限 10（實際 sow=" .. liveAnimals("sow") .. " hen=" .. liveAnimals("hen") .. "）")
check(countLogEvent("animal_clean") - CLEAN_BEFORE == 2,
    "兩個 job 各寫一行 animal_clean（只寫一行＝第二個 job 被丟掉了）")

-- ② 總超額大於每輪額度：先排序的 job 吃光額度，後面的 job 根本沒被嘗試。
--    那些 job 不得寫 animal_protected_over——該事件的語意是「候選重驗全數失效」，
--    把「額度用完」記成那樣會讓正式服排障往保護判定的方向找。
--    **必須鎖成單輪掃描**：掃描間隔 0 的話佇列一排空就會立刻重掃、重設額度再刪一輪，
--    「每輪 20」的斷言會變成「20 × 輪數」。這裡把間隔拉長，並靠 30 隻對上限 10
--    （> ANIMAL_EMERGENCY_MULTIPLIER × 10）的緊急加速在第一次掃描就直接確認。
sandbox.AnimalScanIntervalSeconds = 3600
seedAnimals({ { atype = "sow", count = 30 }, { atype = "hen", count = 30 } })
resetAnimalWarned()
-- resetAnimalWarned 那一 tick 也會掃描並更新 lastScanAt，所以要把時鐘推過間隔
nowMs = nowMs + 3600 * 1000 + 1
ANIMAL_REMOVED = {}
CLEAN_BEFORE = countLogEvent("animal_clean")
PROT_BEFORE = countLogEvent("animal_protected_over")
runTicks(30)
check(#ANIMAL_REMOVED == MinidoracatCleaner.CONSTANTS.ANIMALS_PER_ROUND,
    "總量收在每輪額度 " .. MinidoracatCleaner.CONSTANTS.ANIMALS_PER_ROUND
        .. "（實際 " .. #ANIMAL_REMOVED .. "）")
-- 失敗時把整段動物 log 印出來：這條斷言的價值在於「哪個 job、什麼順序」，光看數字查不出
if countLogEvent("animal_protected_over") - PROT_BEFORE ~= 0 then
    for i = 1, #logLines do
        if logLines[i]:find("[animal_", 1, true) then
            print("        LOG " .. i .. ": " .. logLines[i])
        end
    end
end
check(countLogEvent("animal_protected_over") - PROT_BEFORE == 0,
    "額度用盡而未被嘗試的 job 不寫 animal_protected_over（實際多了 "
        .. (countLogEvent("animal_protected_over") - PROT_BEFORE) .. " 行）")
check(countLogEvent("animal_clean") - CLEAN_BEFORE == 1,
    "只有真的刪了東西的那個 job 寫 animal_clean")

ANIMAL_ROSTER = nil
sandbox.AnimalGroupList = nil
sandbox.MaxAnimalsPerGroup = nil
sandbox.MaxZoneAnimalsPerGroup = nil
sandbox.AnimalScanIntervalSeconds = nil
sandbox.AnimalCleanupEnabled = nil
end

print()
print("情境三十五：client 端 touchAck 走同一套章格式")
do
-- 延後 require：Client.lua 也註冊 OnGameStart（installTouchReporters），而情境三十三
-- 已經把 GAME_START_HANDLERS 跑完了，所以它不會被觸發——那條路徑要 client-only 的
-- vanilla class（ISInventoryTransferAction／ISGrabItemAction），不是本情境的標的。
-- 本情境釘的是持久化契約的 client 半邊：ack 進來時寫的是不是新章格式。
require "MinidoracatCleaner_Client"
check(#SERVER_COMMAND_HANDLERS > 0,
    "前提：client 的 OnServerCommand handler 已註冊（載入失敗會讓這條轉紅）")
-- 全域而非 local：main chunk 已達 Lua 的 200 locals 硬上限（檔頭 STAMP_HOUR 同註）
ACK_SAVED_SEC = nowSec
nowSec = STAMP_HOUR + 777
ACK_SHELF = makeContainer("furniture")

putFurniture(100, 100, 0, ACK_SHELF)
ACK_ITEM = ACK_SHELF:add(makeItem("Base.AckProbe"))
for _, fn in ipairs(SERVER_COMMAND_HANDLERS) do
    fn("MinidoracatCleaner", "touchAck", { ids = { ACK_ITEM:getID() }, name = "tester", at = STAMP_HOUR })
end
ACK_MOVER, ACK_AT = MinidoracatCleaner.readTouch(ACK_ITEM)
check(ACK_MOVER == "tester" and ACK_AT == STAMP_HOUR,
    "client 收到 ack 後寫入新章格式（實際 " .. tostring(ACK_MOVER) .. " / " .. tostring(ACK_AT) .. "）")
check(rawget(ACK_ITEM._modData, MinidoracatCleaner.LEGACY_MOVED) == nil
        and rawget(ACK_ITEM._modData, MinidoracatCleaner.LEGACY_MOVED_AT) == nil,
    "client 端沒留任何 0.3.0 舊 key（釘住 applyTouchAck 走 Core.writeTouch）")
-- ack 缺 at 時不得用 client 本端時鐘鑄造（server 權威）
for _, fn in ipairs(SERVER_COMMAND_HANDLERS) do
    fn("MinidoracatCleaner", "touchAck", { ids = { ACK_ITEM:getID() }, name = "other", at = nil })
end
check(MinidoracatCleaner.readTouch(ACK_ITEM) == "tester",
    "缺 at 的畸形 ack 不覆蓋既有章（不從 client 時鐘補值）")
nowSec = ACK_SAVED_SEC
end
print()
print("情境三十六：recount 的 scope／budget／跨 plan NaN 邊界")
do
sandbox.AnimalCleanupEnabled = true
sandbox.AnimalGroupList = "*"
sandbox.MaxAnimalsPerGroup = 10
sandbox.MaxZoneAnimalsPerGroup = 0
sandbox.AnimalScanIntervalSeconds = 0

-- ① 原候選走出原玩家半徑後，不得繼續算在舊 bucket。11 隻對上限 10：第一輪警告，
--    第二輪排入；刪除前把 1 隻移到 1000,1000，原 bucket 當下只剩 10 → 不該再刪。
--    少了 nearestPlayer/radius 重驗時會 walkAlive=11、再刪 1 隻而轉紅。
seedAnimals({ { atype = "sow", count = 11 } })
resetAnimalWarned()
ANIMAL_REMOVED = {}
runTicks(1)
runTicks(1)
ANIMAL_ROSTER[1]._opts.x = 1000
ANIMAL_ROSTER[1]._opts.y = 1000
runTicks(8)
check(#ANIMAL_REMOVED == 0,
    "原候選移出玩家半徑後，舊 bucket 已回上限 10，不再補刪（實際 " .. #ANIMAL_REMOVED .. "）")

-- ①b 不能只驗「nearest 不存在」；還要驗「仍有 nearest、但已改歸另一位玩家」。
-- 初始：舊玩家在 100、新玩家在 160，動物在 100 ⇒ 舊玩家最近。排入後把第一隻移到 160，
-- 它仍在舊玩家 64 格半徑內（距離 60），但 nearest 已是新玩家。若 production 只檢查
-- nearest ~= nil、不比對 job.playerObj，仍會把它算進舊 bucket 而補刪 1 隻。
REASSIGN_PLAYER = {
    getX = function() return 160 end,
    getY = function() return 100 end,
    getZ = function() return 0 end,
    getUsername = function() return "reassigned" end,
    getOnlineID = function() return 77 end,
    getCurrentSquare = function() return getOrMakeSquare(160, 100, 0) end,
    getInventory = function() return makeContainer("player") end,
    isEquipped = function() return false end,
    isAttachedItem = function() return false end,
}
onlineRoster = { player, REASSIGN_PLAYER }
seedAnimals({ { atype = "sow", count = 11 } })
resetAnimalWarned()
ANIMAL_REMOVED = {}
runTicks(1)
runTicks(1)
ANIMAL_ROSTER[1]._opts.x = 160
runTicks(8)
check(#ANIMAL_REMOVED == 0,
    "候選仍在舊半徑內但改歸另一 nearest player，也不再算進舊 bucket")
onlineRoster = nil

-- ② 單一 plan 超過 visit budget：無法在同一 tick 完整 recount，跨 tick 攢 walkValid 又會
--    讓前半段驗證過期。正確是本輪 fail-closed 不刪＋專用診斷，不是硬走 513 筆也不是
--    animal_protected_over。間隔拉長避免佇列排空後第二輪又重掃。
sandbox.AnimalScanIntervalSeconds = 3600
seedAnimals({ { atype = "sow", count = MinidoracatCleaner.CONSTANTS.ANIMAL_VISITS_PER_TICK + 1 } })
nowMs = nowMs + 3600 * 1000 + 1
UNPROV_BEFORE = countLogEvent("animal_recount_unprovable")
PROT_BEFORE = countLogEvent("animal_protected_over")
ANIMAL_REMOVED = {}
runTicks(6)
check(#ANIMAL_REMOVED == 0,
    "plan 候選數超過 visit budget 時 fail-closed，一隻不刪")
check(countLogEvent("animal_recount_unprovable") - UNPROV_BEFORE == 1,
    "留一行 animal_recount_unprovable（不是靜默跳過）")
check(countLogEvent("animal_protected_over") - PROT_BEFORE == 0,
    "無法同 tick 重數不冒充『候選重驗全數失效』")

-- 持續同一個 unprovable 狀態不應每輪重寫：共用 ZLogger >10MB 會截斷原檔。
UNPROV_REPEAT = countLogEvent("animal_recount_unprovable")
nowMs = nowMs + 3600 * 1000 + 1
runTicks(6)
check(countLogEvent("animal_recount_unprovable") - UNPROV_REPEAT == 0,
    "持續 > visit budget 的同一 bucket 不重複寫 unprovable（首次診斷已足夠）")

-- partial multi-plan：marker 已存在；下一輪同一 pig bucket 的 stray plan 先刪滿 round budget，
-- 後置 zone plan（513）完全未嘗試。只有**所有 plans 完成**才能解除 marker；job-wide
-- attempted 會因前 plan 成功就誤解除，下一輪 zone 仍 513 時又重寫「首次」診斷。
sandbox.MaxZoneAnimalsPerGroup = 10
seedAnimals({
    { atype = "sow", count = 30 },
    { atype = "sow", count = MinidoracatCleaner.CONSTANTS.ANIMAL_VISITS_PER_TICK + 1, hutch = true },
})
nowMs = nowMs + 3600 * 1000 + 1
runTicks(16)
seedAnimals({
    { atype = "sow", count = MinidoracatCleaner.CONSTANTS.ANIMAL_VISITS_PER_TICK + 1, hutch = true },
})
nowMs = nowMs + 3600 * 1000 + 1
UNPROV_PARTIAL = countLogEvent("animal_recount_unprovable")
runTicks(6)
check(countLogEvent("animal_recount_unprovable") - UNPROV_PARTIAL == 0,
    "前 plan 吃光額度、後置 unprovable plan 未嘗試，不會誤解除 marker")
sandbox.MaxZoneAnimalsPerGroup = 0

-- 恢復可證明且**所有 plans 完成**後才解除狀態；下次再超過應重新記一行。
-- 不能用 512 隻當「恢復」：它雖可同 tick recount，但每輪只刪 20、plan 未完成，marker
-- 正確不該解除。11 隻對上限10只刪1並完成整個 job，才是真正的恢復。
seedAnimals({ { atype = "sow", count = 11 } })
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)  -- 首輪警告
nowMs = nowMs + 3600 * 1000 + 1
runTicks(8)  -- 次輪確認、刪1、plan完成
seedAnimals({ { atype = "sow", count = MinidoracatCleaner.CONSTANTS.ANIMAL_VISITS_PER_TICK + 1 } })
nowMs = nowMs + 3600 * 1000 + 1
UNPROV_REARM = countLogEvent("animal_recount_unprovable")
runTicks(6)
check(countLogEvent("animal_recount_unprovable") - UNPROV_REARM == 1,
    "恢復可證明後再超過，unprovable 首次診斷會重新啟用")

-- 所有上限設 0 代表 bucket 生命週期中斷：兩張狀態表都要清。恢復同 key、仍 513 時，
-- 應重新留一行首次診斷；若 early return 只清 warned，舊 marker 會永久壓掉這行。
sandbox.MaxAnimalsPerGroup = 0
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)
sandbox.MaxAnimalsPerGroup = 10
seedAnimals({ { atype = "sow", count = MinidoracatCleaner.CONSTANTS.ANIMAL_VISITS_PER_TICK + 1 } })
nowMs = nowMs + 3600 * 1000 + 1
UNPROV_LIMITS = countLogEvent("animal_recount_unprovable")
runTicks(6)
check(countLogEvent("animal_recount_unprovable") - UNPROV_LIMITS == 1,
    "所有上限 0 → 恢復後，unprovable 首次診斷重新啟用")

-- 無玩家同樣等同所有 bucket 消失；warned 也要清，避免同 key 玩家重連後沿用舊確認直接清。
onlineRoster = {}
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)
onlineRoster = nil
nowMs = nowMs + 3600 * 1000 + 1
UNPROV_NOPLAYER = countLogEvent("animal_recount_unprovable")
runTicks(6)
check(countLogEvent("animal_recount_unprovable") - UNPROV_NOPLAYER == 1,
    "無玩家 → 同 key 恢復後，unprovable 首次診斷重新啟用")

-- warned 的 no-player 生命週期要用**非 emergency**數量獨立釘住。513 會被 emergency 短路，
-- 完全不讀 warned，無法證明重連後「重新警告、不得沿用舊確認直接清」。
-- 先以 limits=0 清乾淨，再用 11 隻建立一筆首次警告；玩家全離線後同 key 重連，
-- 第一輪必須再寫一筆 warn 且零 remove。少掉 no-player 分支的 warned={} 時，會沿用舊時間戳
-- 直接確認：warn 不新增（這條轉紅），下一 tick 開始清。
sandbox.MaxAnimalsPerGroup = 0
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)
sandbox.MaxAnimalsPerGroup = 10
seedAnimals({ { atype = "sow", count = 11 } })
WARN_SETUP = countAnimalWarn()
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)  -- 建立首次警告
check(countAnimalWarn() - WARN_SETUP == 1,
    "活性：離線前確實已建立一筆動物警告（不是空白 warned 的假通過）")
onlineRoster = {}
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)  -- no-player early return：清兩表
onlineRoster = nil
WARN_REJOIN = countAnimalWarn()
ANIMAL_REMOVED = {}
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)
check(countAnimalWarn() - WARN_REJOIN == 1 and #ANIMAL_REMOVED == 0,
    "玩家全離線後同 key 重連：重新警告且第一輪不清（animal warn +"
        .. (countAnimalWarn() - WARN_REJOIN) .. " removed=" .. #ANIMAL_REMOVED .. "）")

-- limits=0 同型：暫停所有上限後恢復，不能沿用暫停前的確認鏈。
sandbox.MaxAnimalsPerGroup = 0
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)
sandbox.MaxAnimalsPerGroup = 10
WARN_LIMITS = countAnimalWarn()
ANIMAL_REMOVED = {}
nowMs = nowMs + 3600 * 1000 + 1
runTicks(1)
check(countAnimalWarn() - WARN_LIMITS == 1 and #ANIMAL_REMOVED == 0,
    "所有上限 0 後恢復：重新寫動物警告且第一輪不清")

-- ②b 兩個 plan 合計超過 visit budget，但各自都 ≤512：第一個 chicken plan 用掉 200 visits，
-- 剩 312 不夠走 pig 的 400 → 原封不動留到下一 tick；不是誤判成 >512、也不會永久餓死。
sandbox.AnimalScanIntervalSeconds = 0
sandbox.AnimalLimitOverrides = "pig=399,chicken=199"
seedAnimals({ { atype = "sow", count = 400 }, { atype = "hen", count = 200 } })
resetAnimalWarned()
ANIMAL_REMOVED = {}
runTicks(1)
runTicks(1)
runTicks(1)
check(#ANIMAL_REMOVED == 1,
    "第一個 200-candidate job 用掉部分 visit budget；第二個 400-candidate job 延到下 tick")
runTicks(1)
check(#ANIMAL_REMOVED == 2,
    "延後的 400-candidate job 下 tick 取得完整 budget 並前進（沒有餓死）")
sandbox.AnimalLimitOverrides = nil

-- ③ 散養 plan 的 NaN：候選重驗時座標壞掉 ⇒ 不刪但計入現存數（blocked），且同一 job
--    跨多個 tick 重數也只在 animal_nan 記一次（nanSeen 去重）。圈養側已無 scanner plan
--    （農場治理有自己的 NaN 防護，見情境四十），這裡只驗散養半邊
sandbox.AnimalScanIntervalSeconds = 0
sandbox.MaxZoneAnimalsPerGroup = 0
seedAnimals({ { atype = "sow", count = 12 } })
resetAnimalWarned()
ANIMAL_REMOVED = {}
NAN_BEFORE = countLogEvent("animal_nan")
runTicks(1)
runTicks(1)
ANIMAL_ROSTER[1]._opts.x = 0 / 0
ANIMAL_ROSTER[2]._opts.z = 0 / 0
runTicks(10)
ANIMAL_NAN_LINE = nil
for i = #logLines, 1, -1 do
    if logLines[i]:find("[animal_nan]", 1, true) then
        ANIMAL_NAN_LINE = logLines[i]
        break
    end
end
check(#ANIMAL_REMOVED == 2,
    "散養超 2、其中 2 隻 NaN ⇒ 刪掉 2 隻正常候選收到上限（實際 " .. #ANIMAL_REMOVED .. "）")
check(countLogEvent("animal_nan") - NAN_BEFORE == 1,
    "NaN 聚合成一行（跨 tick 重數不重複寫）")
check(ANIMAL_NAN_LINE ~= nil and ANIMAL_NAN_LINE:find("skipped=2", 1, true) ~= nil,
    "兩隻 NaN 都被計入 skipped（x 壞與 z 壞各一，實際行：" .. tostring(ANIMAL_NAN_LINE) .. "）")

ANIMAL_ROSTER = nil
sandbox.AnimalGroupList = nil
sandbox.MaxAnimalsPerGroup = nil
sandbox.MaxZoneAnimalsPerGroup = nil
sandbox.AnimalScanIntervalSeconds = nil
sandbox.AnimalCleanupEnabled = nil
end

print()
print("情境三十七：Tooltip client 消費端讀新章")
do
-- 延後 require 並補最小 vanilla stub。OnCreatePlayer 會同時執行 Client 的
-- installTouchReporters，因此它需要兩個 client-only action class；Tooltip 本身只要
-- ISToolTipInv.render 與 ISContextMenu.visibleCheck。visibleCheck=true 讓 render 在
-- getTraceLines 之後直接收工，不必 mock 整套 UI layout，但仍真的跑了 readTouch＋時間格式化。
ISInventoryTransferAction = { perform = function() end }
ISGrabItemAction = { perform = function() end }
TOOLTIP_ORIGINAL_CALLS = 0
FORMAT_CALLS = 0
CALENDAR_MS = nil
ISToolTipInv = {
    render = function(self)
        TOOLTIP_ORIGINAL_CALLS = TOOLTIP_ORIGINAL_CALLS + 1
        return "original"
    end,
}
ISContextMenu = { instance = { visibleCheck = true } }
Locale = { ENGLISH = {} }
SimpleDateFormat = {
    new = function()
        return {
            format = function()
                FORMAT_CALLS = FORMAT_CALLS + 1
                return "2026-08-23 12:00"
            end,
        }
    end,
}
Calendar = {
    getInstance = function()
        return {
            setTimeInMillis = function(_, value) CALENDAR_MS = value end,
            getTime = function() return {} end,
        }
    end,
}
require "MinidoracatCleaner_Tooltip"
for _, fn in ipairs(CREATE_PLAYER_HANDLERS) do
    fn()
end
check(MinidoracatCleaner._tooltipHookInstalled == true,
    "前提：Tooltip hook 已安裝（require／vanilla stub 形狀錯時轉紅）")

-- 無章物品：getTraceLines 回 nil，必須退回原 render
TOOLTIP_ORIGINAL_CALLS = 0
ISToolTipInv.render({ item = makeItem("Base.NoTrace") })
check(TOOLTIP_ORIGINAL_CALLS == 1,
    "無章物品退回 vanilla render")

-- ACK_ITEM 來自情境三十五，已由 client touchAck 寫入新格式小時章。
-- 有章時 getTraceLines 非 nil，且 visibleCheck=true 讓 hook 不進完整 UI layout；
-- 若 Tooltip 還在讀舊 key，會誤判無章而呼叫 original。
TOOLTIP_ORIGINAL_CALLS = 0
FORMAT_CALLS = 0
CALENDAR_MS = nil
ISToolTipInv.render({ item = ACK_ITEM })
check(TOOLTIP_ORIGINAL_CALLS == 0,
    "有新章的物品走自訂 Tooltip 路徑（不是退回 vanilla）")
check(FORMAT_CALLS == 1 and CALENDAR_MS == STAMP_HOUR * 1000,
    "小時章進 Calendar/SimpleDateFormat 格式化（實際 calls=" .. FORMAT_CALLS
        .. " ms=" .. tostring(CALENDAR_MS) .. "）")
end
print()
print("情境三十八：全域散養上限（跨玩家半徑的兜底維度）")
do
local C = MinidoracatCleaner.CONSTANTS
onlineRoster = { player }
sandbox.AnimalCleanupEnabled = true
sandbox.AnimalGroupList = "*"
sandbox.AnimalScanIntervalSeconds = 0
sandbox.AnimalGlobalLimitOverrides = ""

-- fixture：5 隻在主 player 腳邊 (100,100)、30 隻在 (500,500)。後者離玩家 400 格，
-- 遠超 AnimalScanRadius 預設 64 ⇒ nearestPlayer 回 nil ⇒ **per-player 分桶完全看不到**。
local function seed38()
    seedAnimals({
        { atype = "sow", count = 5 },
        { atype = "sow", count = 30, x = 500, y = 500 },
    })
end

-- ① 對照組：全域上限關閉時，遠處那 30 隻不受任何約束。
--    per-player 上限 10 只看得到腳邊 5 隻（未超標），所以整輪零刪除。
--    這條同時證明「遠處動物確實在 per-player 維度之外」——② 的清理只可能來自全域桶
sandbox.MaxAnimalsPerGroup = 10
sandbox.MaxZoneAnimalsPerGroup = 0
sandbox.MaxGlobalAnimalsPerGroup = 0
seed38()
resetAnimalWarned()
runTicks(12)
check(liveAnimals() == 35, "前提：fixture 的 35 隻都在（實際 " .. liveAnimals() .. "）")
check(#ANIMAL_REMOVED == 0,
    "全域上限關閉 ⇒ 離玩家 400 格的 30 隻完全不受管（實際刪 " .. #ANIMAL_REMOVED .. "）")

-- ② 全域上限 20：全服 35 隻超標 15。刻意讓 35 不到 2×20，否則會走 emergency 直接跳過
--    第一輪警告，「第一輪只警告」那條前提就驗不到了
sandbox.MaxGlobalAnimalsPerGroup = 20
seed38()
resetAnimalWarned()
SENT38 = #sentCommands
runTicks(1)
check(#ANIMAL_REMOVED == 0, "前提：全域桶第一輪也只警告、不刪")
runTicks(12)
check(#ANIMAL_REMOVED == 15,
    "全域上限 20 ⇒ 35 隻刪到剩 20（實際刪 " .. #ANIMAL_REMOVED .. "）")
check(liveAnimals() == 20, "剩餘等於全域上限 20（實際 " .. liveAnimals() .. "）")
check(countLogEvent("animal_clean") > 0, "活性：確實寫了 animal_clean")
-- 全域桶的 playerObj 是 nil ⇒ notifyPlayer 直接 return（Core:749-751）。把 playerObj
-- 改成某個玩家的變異會在這裡轉紅
ZONE38 = 0
for index = SENT38 + 1, #sentCommands do
    local sent = sentCommands[index]
    if sent.args and (sent.args.kind == "animals") then
        ZONE38 = ZONE38 + 1
    end
end
check(ZONE38 == 0,
    "全域桶不對任何玩家發警告／清理通知（超額動物可能離所有人都很遠，實際 "
        .. ZONE38 .. " 則）")

-- ③ 全域上限只管散養：圈養上限刻意設 100（遠高於 30）——這樣 classifyAnimal 仍回 "zone"
--    但 per-player 圈養桶不超標。
--    全域上限取 20 而非 10 是必要的：下面用「有沒有寫超標警告」當可觀測輸出，而
--    `confirmed = emergency or warnBucket(...)` 是短路求值——count 超過 2×limit 時
--    emergency 為真，warnBucket 根本不會執行、一則警告都不會寫，斷言就變成永遠全綠。
--    30 < 2×20 保證走的是正常的「先警告」路徑
sandbox.MaxAnimalsPerGroup = 0
sandbox.MaxZoneAnimalsPerGroup = 100
sandbox.MaxGlobalAnimalsPerGroup = 20
seedAnimals({ { atype = "sow", count = 30, hutch = true, x = 500, y = 500 } })
resetAnimalWarned()
WARN38 = countAnimalWarn()
runTicks(12)
check(#ANIMAL_REMOVED == 0,
    "全域上限只管散養 ⇒ 30 隻圈養一隻不動（實際刪 " .. #ANIMAL_REMOVED .. "）")
-- **斷言要打在安全網之前。** inspectCandidate 最後一道 class 比對（plan.zone 為 false
-- 時只認 "stray"）是第二層防護，會把誤收的圈養候選全部剔成 gone——所以「沒刪」這條
-- 對「掃描階段有沒有誤收」完全不敏感：把分流變異成「全域桶也收 zone 候選」時，上面
-- 那條照樣全綠（實測）。第一手可觀測輸出是超標警告：誤把 30 隻圈養算進全域 count
-- 就會寫出一則假的 scope=global 警告，即使最終一隻都沒刪
check(countAnimalWarn() == WARN38,
    "全域桶不把圈養算進 count（否則會寫出假的超標警告，實際新增 "
        .. (countAnimalWarn() - WARN38) .. " 則）")
-- 活性對照組：**唯一變數是 hutch**。同座標、同數量、同設定，只是不再是圈養——
-- 全域上限就會清它們。這才證明 ③ 的零刪除來自「全域只管散養」，而不是 fixture
-- 根本沒進掃描。
-- 刻意不用「把圈養上限調小」當活性：遠處動物的 nearestPlayer 是 nil ⇒ per-player
-- 圈養桶根本不會建立，那條斷言永遠是 0，只會變成第二個假通過
seedAnimals({ { atype = "sow", count = 30, x = 500, y = 500 } })
resetAnimalWarned()
runTicks(12)
check(#ANIMAL_REMOVED > 0,
    "活性：同批遠處 fixture 若不是圈養，全域上限確實會清（實際刪 "
        .. #ANIMAL_REMOVED .. "）")

-- ④ 兩個維度同時超標時，同一隻動物不得被兩個 job 各刪一次。
--    20 隻全在腳邊 ⇒ per-player 桶與全域桶看到的是**同一批** candidate（刻意共用同一張
--    table 以免配置翻倍）。20 不到 2×12，所以不走 emergency。
sandbox.MaxAnimalsPerGroup = 12
sandbox.MaxZoneAnimalsPerGroup = 0
sandbox.MaxGlobalAnimalsPerGroup = 12
seedAnimals({ { atype = "sow", count = 20 } })
resetAnimalWarned()
runTicks(12)
check(#ANIMAL_REMOVED > 0,
    "活性：兩個維度同時超標時確實有刪除發生（實際 " .. #ANIMAL_REMOVED .. "）")
DUP38 = 0
SEEN38 = {}
for _, id in ipairs(ANIMAL_REMOVED) do
    if SEEN38[id] then
        DUP38 = DUP38 + 1
    end
    SEEN38[id] = true
end
-- 這條釘住 candidate.removed 旗標。**不能靠引擎狀態代替**：remove() 之後 getSquare()
-- 仍回原格、isDead() 仍是 false（見 makeTestAnimal 的忠於引擎說明），所以第二個 job
-- 的 inspectCandidate 會把已刪的判成 removable 並再刪一次。把那行旗標拿掉，這裡與
-- 下面的剩餘數都會轉紅
check(DUP38 == 0,
    "同一隻動物不被兩個 job 各刪一次（實際重複 " .. DUP38 .. " 次）")
check(liveAnimals() == 12,
    "刪到兩個維度的共同上限 12，不會被第二個 job 追刪到更低（實際 "
        .. liveAnimals() .. "）")

-- ⑤ 覆寫是獨立維度：共用預設 0，只靠 AnimalGlobalLimitOverrides 也必須生效。
--    hasAnyAnimalLimit 少查 globalOverrides 就會整套 early-return ⇒ 零刪除而轉紅
sandbox.MaxAnimalsPerGroup = 0
sandbox.MaxZoneAnimalsPerGroup = 0
sandbox.MaxGlobalAnimalsPerGroup = 0
sandbox.AnimalGlobalLimitOverrides = "pig=10"
seedAnimals({ { atype = "sow", count = 30, x = 500, y = 500 } })
resetAnimalWarned()
runTicks(12)
check(#ANIMAL_REMOVED == C.ANIMALS_PER_ROUND,
    "三個共用上限都是 0，只靠全域逐群組覆寫仍會清（實際刪 " .. #ANIMAL_REMOVED .. "）")

sandbox.AnimalCleanupEnabled = nil
sandbox.AnimalGroupList = nil
sandbox.AnimalScanIntervalSeconds = nil
sandbox.MaxAnimalsPerGroup = nil
sandbox.MaxZoneAnimalsPerGroup = nil
sandbox.MaxGlobalAnimalsPerGroup = nil
sandbox.AnimalGlobalLimitOverrides = nil
end
print()
print("情境三十九：圈養抑制繁殖（取消未出生的，不動現有牲畜）")
do
onlineRoster = { player }
sandbox.AnimalCleanupEnabled = true
sandbox.AnimalGroupList = "*"
sandbox.AnimalScanIntervalSeconds = 0
-- AnimalScanner 與抑制路徑刻意用不同的動物來源：前者走 getCell():getAnimals()
-- （＝ANIMAL_ROSTER），後者走 zone:getAnimalsConnected()。把 ROSTER 清空就能讓移除路徑
-- 完全不參與，斷言「一隻都沒被刪」才是在測抑制、不是在測移除剛好沒觸發
ANIMAL_ROSTER = {}

-- 建一隻 fixture 動物：pregnant/pregnancyTime 直接寫進 opts，斷言時讀 animal._opts
local function breeder(id, atype, pregnant, pregnancyTime)
    return makeTestAnimal({
        id = id,
        atype = atype,
        x = 100,
        y = 100,
        pregnant = pregnant,
        pregnancyTime = pregnancyTime,
    })
end

-- ① 懷孕被取消、成對清零，而且一隻動物都沒被刪。
--    5 隻 pig（maxBaby 10）其中 2 隻懷孕，上限 10 ⇒ live 5 ＋ unborn 20 = 25，超額 15。
--    取消第一隻剩 5、取消第二隻歸零 ⇒ 兩隻都取消
PIG_A = breeder(1, "sow", true, 3)
PIG_B = breeder(2, "sow", true, 90)
ANIMAL_ZONES = { makeTestZone({ id = 1, animals = {
    PIG_A, PIG_B, breeder(3, "sow"), breeder(4, "sow"), breeder(5, "sow"),
} }) }
sandbox.MaxRanchBreedingPerGroup = 10
ANIMAL_REMOVED = {}
-- 抑制由 EveryTenMinutes 武裝（遊戲分鐘事件；10 真實秒輪詢是 99.91% 白算，
-- 設計評審 codex lane 的成本模型），OnTick 只消化已武裝的掃描
fireTenMinutes()
runTicks(2)
check(PIG_A._opts.pregnant == false and PIG_B._opts.pregnant == false,
    "兩隻懷孕都被取消（超額 15 > 兩胎共 20）")
check(PIG_A._opts.pregnancyTime == 0 and PIG_B._opts.pregnancyTime == 0,
    "pregnancyTime 一起清零（只關旗標會在 tooltip 留下殘留進度）")
check(#ANIMAL_REMOVED == 0,
    "抑制不刪動物（實際刪 " .. #ANIMAL_REMOVED .. "）")
check(countLogEvent("animal_breed_suppress") > 0, "活性：寫了 animal_breed_suppress")

-- ② 懷孕必須按該物種一胎最大隻數預留額度。
--    5 隻 pig 其中 1 隻懷孕、上限 12：按 maxBaby 算是 5 + 10 = 15 > 12 ⇒ 要抑制；
--    若每隻懷孕只算 1，就是 5 + 1 = 6 <= 12 ⇒ 不抑制。把 litterSize 變異成回 1 會轉紅
PIG_C = breeder(11, "sow", true, 5)
ANIMAL_ZONES = { makeTestZone({ id = 2, animals = {
    PIG_C, breeder(12, "sow"), breeder(13, "sow"), breeder(14, "sow"), breeder(15, "sow"),
} }) }
sandbox.MaxRanchBreedingPerGroup = 12
fireTenMinutes()
runTicks(2)
check(PIG_C._opts.pregnant == false,
    "一胎按 maxBaby=10 預留 ⇒ 5 隻現存也會超過上限 12 而抑制")

-- ③ 蛋：取消受精、成對清零，地面蛋要發 ItemStats、巢箱蛋不必。
--    3 隻雞 ＋ 巢箱 2 顆 ＋ 地面 1 顆受精蛋，上限 4 ⇒ 6 - 4 = 2 顆要取消。
--    地面蛋的 fertilizedTime 設成最小值，保證它一定在被取消的那批裡
EGG_GROUND = makeTestEgg({ hatch = "hen", fertilized = true, fertilizedTime = 1 })
EGG_NEST_A = makeTestEgg({ hatch = "hen", fertilized = true, fertilizedTime = 50 })
EGG_NEST_B = makeTestEgg({ hatch = "hen", fertilized = true, fertilizedTime = 90 })
ANIMAL_ZONES = { makeTestZone({
    id = 3,
    animals = { breeder(21, "hen"), breeder(22, "hen"), breeder(23, "hen") },
    hutches = { makeTestHutch({ nests = { { EGG_NEST_A, EGG_NEST_B } } }) },
    ground = { EGG_GROUND },
}) }
sandbox.MaxRanchBreedingPerGroup = 4
ITEM_STATS_SENT = {}
fireTenMinutes()
runTicks(2)
check(EGG_GROUND._opts.fertilized == false and EGG_NEST_A._opts.fertilized == false,
    "受精時間最短的兩顆蛋被取消受精")
check(EGG_NEST_B._opts.fertilized == true,
    "最接近孵化的那顆保留（只取消到剛好回到上限）")
check(EGG_GROUND._opts.fertilizedTime == 0,
    "取消受精時 fertilizedTime 一起清零")
check(#ITEM_STATS_SENT == 1 and ITEM_STATS_SENT[1] == EGG_GROUND,
    "只有地面蛋發 ItemStats（巢箱蛋走 hutch 自己的同步，實際 "
        .. #ITEM_STATS_SENT .. " 件）")

-- ④ 共用預設 0 且無覆寫 ＝ 整套不處理（沒有布林總開關）。
--    釘的是 onEveryTenMinutes 的 arming 守衛與 ranchTick 的上限守衛
PIG_D = breeder(31, "sow", true, 5)
ANIMAL_ZONES = { makeTestZone({ id = 4, animals = { PIG_D } }) }
sandbox.MaxRanchBreedingPerGroup = 0
fireTenMinutes()
runTicks(2)
check(PIG_D._opts.pregnant == true, "繁殖上限 0 ⇒ 一個懷孕都不取消（連 arming 都不發生）")

-- ⑤ 動物分類總開關優先於繁殖上限：關掉就完全不動作（釘 onEveryTenMinutes 與 ranchTick
--    兩道 AnimalCleanupEnabled 守衛）
PIG_E = breeder(41, "sow", true, 5)
ANIMAL_ZONES = { makeTestZone({ id = 5, animals = { PIG_E } }) }
sandbox.MaxRanchBreedingPerGroup = 1
sandbox.AnimalCleanupEnabled = false
fireTenMinutes()
runTicks(2)
check(PIG_E._opts.pregnant == true, "總開關關閉 ⇒ 懷孕保留（繁殖上限已設也不動）")
sandbox.AnimalCleanupEnabled = true
fireTenMinutes()
runTicks(2)
check(PIG_E._opts.pregnant == false, "活性：總開關打開後同一個 fixture 立刻被抑制")

-- ⑥ 相連圈地是一個元件，整組每個 pass 只付一次 getAllDZones；多個群組共用同一趟走訪。
--    getAllDZones 的遞迴內部對每個邊界格線性掃全域圈地清單（DesignationZoneAnimal.java
--    :58-110,316-325），是農場治理最貴的原語——「呼叫幾次」本身就是效能契約，
--    純重構型性質只能用 mock 呼叫計數釘住
PIG_F = breeder(51, "sow", true, 5)
HEN_F = makeTestEgg({ hatch = "hen", fertilized = true, fertilizedTime = 2 })
ZONE_F1 = makeTestZone({ id = 61, animals = { PIG_F, breeder(52, "hen"), breeder(53, "hen") },
    ground = { HEN_F } })
ZONE_F2 = makeTestZone({ id = 62 })
ZONE_F1._opts.component = { ZONE_F1, ZONE_F2 }
ZONE_F2._opts.component = { ZONE_F1, ZONE_F2 }
ANIMAL_ZONES = { ZONE_F1, ZONE_F2 }
sandbox.MaxRanchBreedingPerGroup = 1
-- 只跑**一個** tick，且抑制只武裝一次：一個元件、mutation 需求 2，都在單 tick 的
-- COMPONENTS_PER_TICK／MUTATIONS_PER_TICK 額度內，一個 tick 就走得完
fireTenMinutes()
GETALLDZONES_CALLS = 0
runTicks(1)
check(PIG_F._opts.pregnant == false and HEN_F._opts.fertilized == false,
    "活性：同一個元件內 pig 與 chicken 兩個群組都被抑制")
check(GETALLDZONES_CALLS == 1,
    "相連圈地與多個群組合計只付一次 getAllDZones（實際 " .. GETALLDZONES_CALLS .. " 次）")

-- ⑦ 逐群組覆寫：共用預設 0 時覆寫獨自武裝並抑制（arming 不可只看共用預設值）
PIG_G = breeder(71, "sow", true, 5)
ANIMAL_ZONES = { makeTestZone({ id = 71, animals = {
    PIG_G, breeder(72, "sow"), breeder(73, "sow"), breeder(74, "sow"), breeder(75, "sow"),
} }) }
sandbox.MaxRanchBreedingPerGroup = 0
sandbox.RanchBreedingOverrides = "pig=12"
fireTenMinutes()
runTicks(2)
check(PIG_G._opts.pregnant == false,
    "共用預設 0 時逐群組覆寫仍武裝並抑制（pig=12：5 現存＋10 預留超過）")

-- ⑧ 覆寫 0＝該群組不抑制（與清除側「覆寫 0＝永不刪除」同一套 0 語意）
PIG_H = breeder(81, "sow", true, 5)
ANIMAL_ZONES = { makeTestZone({ id = 81, animals = {
    PIG_H, breeder(82, "sow"), breeder(83, "sow"), breeder(84, "sow"), breeder(85, "sow"),
} }) }
sandbox.MaxRanchBreedingPerGroup = 10
sandbox.RanchBreedingOverrides = "pig=0"
fireTenMinutes()
runTicks(2)
check(PIG_H._opts.pregnant == true,
    "覆寫 0 ⇒ 該群組不做繁殖抑制（共用預設 10 本來會抑制）")
sandbox.RanchBreedingOverrides = nil
ANIMAL_ZONES = {}
ANIMAL_ROSTER = nil
sandbox.AnimalCleanupEnabled = nil
sandbox.AnimalGroupList = nil
sandbox.AnimalScanIntervalSeconds = nil
sandbox.MaxRanchBreedingPerGroup = nil
end
print()
print("情境四十：農場清除（每座農場計數、同 tick 重數、共用移除預算）")
do
onlineRoster = { player }
sandbox.AnimalCleanupEnabled = true
sandbox.AnimalGroupList = "*"
sandbox.AnimalScanIntervalSeconds = 0
ANIMAL_ROSTER = {}

local function sow(id, extra)
    extra = extra or {}
    return makeTestAnimal({
        id = id,
        atype = "sow",
        x = extra.x or 100,
        y = extra.y or 100,
        z = extra.z,
        baby = extra.baby,
        named = extra.named,
    })
end

local function aliveIn(zoneOpts)
    local total = 0
    for _, animal in ipairs(zoneOpts.animals or {}) do
        if not animal.isGone() then
            total = total + 1
        end
    end
    return total
end

-- ① 兩段式：首輪只警告（廣播 scope=zone），下一輪仍超標才清；每 tick 清除 ≤ 3
--    （共用預算），總量收到上限即停。15 隻、上限 10、15 < 2×10 ⇒ 不走 emergency
ZONE_R1 = makeTestZone({ id = 101, animals = {} })
for i = 1, 15 do
    ZONE_R1._opts.animals[i] = sow(7000 + i)
end
ANIMAL_ZONES = { ZONE_R1 }
sandbox.MaxZoneAnimalsPerGroup = 10
ANIMAL_REMOVED = {}
WARN40 = countAnimalWarn()
SENT40 = #sentCommands
runTicks(1)
check(#ANIMAL_REMOVED == 0 and countAnimalWarn() - WARN40 == 1,
    "首輪只警告不清（warn +1、removed 0，實際 " .. #ANIMAL_REMOVED .. "）")
ZONEWARN40 = 0
for index = SENT40 + 1, #sentCommands do
    local sent = sentCommands[index]
    if sent.args and sent.args.kind == "animals" and sent.args.scope == "zone" then
        ZONEWARN40 = ZONEWARN40 + 1
    end
end
check(ZONEWARN40 == 1,
    "農場警告廣播給錨點附近玩家（scope=zone，實際 " .. ZONEWARN40 .. " 則）")
PEAK40 = 0
for _ = 1, 6 do
    local before = #ANIMAL_REMOVED
    runTicks(1)
    local delta = #ANIMAL_REMOVED - before
    if delta > PEAK40 then
        PEAK40 = delta
    end
end
check(#ANIMAL_REMOVED == 5 and aliveIn(ZONE_R1._opts) == 10,
    "確認輪清到上限即停（刪 5 剩 10，實際刪 " .. #ANIMAL_REMOVED
        .. " 剩 " .. aliveIn(ZONE_R1._opts) .. "）")
check(PEAK40 <= MinidoracatCleaner.CONSTANTS.ANIMALS_PER_TICK,
    "單 tick 清除不超過共用預算 " .. MinidoracatCleaner.CONSTANTS.ANIMALS_PER_TICK
        .. "（實際峰值 " .. PEAK40 .. "）")

-- ② 散養與農場同 tick 各自超標：**共用同一份 3/tick 預算**，單 tick 合計 ≤ 3。
--    各自 3/tick（合計 6）會推翻活鎖事故的降壓——這條釘住跨模組共用預算。
--    農場放 25 隻（> 2×10 走 emergency、超額 15＝5 個 tick 的量）**刻意讓農場清除
--    還沒收完時散養佇列就開動**：兩來源必然撞同 tick，序列化的 fixture（各 15 隻）
--    會讓兩邊自然錯開、共用預算的斷言空轉（變異驗證實測 0 FAIL）
ZONE_R2 = makeTestZone({ id = 111, animals = {} })
for i = 1, 25 do
    ZONE_R2._opts.animals[i] = sow(7100 + i)
end
-- 散養上限必須顯式設 10：不設會吃 DEFAULTS 的 50，15 隻散養永不超標，
-- 「共用預算」就只剩農場一個來源在測（假通過）
sandbox.MaxAnimalsPerGroup = 10
-- **先 reset 再掛 fixture**：resetAnimalWarned 會跑一個 tick，若 ZONE_R2 已掛上，
-- emergency（25 > 2×10）會在那個 tick 就開始清、吃掉 3 隻，迴圈內的總量斷言就差 3
-- （實際踩到：期望 20 實際 17）
resetAnimalWarned()
ANIMAL_ZONES = { ZONE_R2 }
-- 散養群放 (130,100)：在玩家半徑 64 內、但在 ZONE_R2 矩形（100..110 ±buffer 2）外——
-- 站進圈地矩形會被 classifyAnimal 判成 zone 而讓 scanner 跳過（那正是 ① 的語意）
seedAnimals({ { atype = "sow", count = 15, x = 130 } })
ANIMAL_REMOVED = {}
PEAK40B = 0
for _ = 1, 16 do
    local before = #ANIMAL_REMOVED
    runTicks(1)
    local delta = #ANIMAL_REMOVED - before
    if delta > PEAK40B then
        PEAK40B = delta
    end
end
check(#ANIMAL_REMOVED == 20,
    "散養超 5 ＋ 農場超 15 都清完（實際 " .. #ANIMAL_REMOVED .. "）")
check(PEAK40B <= MinidoracatCleaner.CONSTANTS.ANIMALS_PER_TICK,
    "兩個來源同 tick 合計仍 ≤ 3（各自 3/tick 時會是 6 而轉紅，實際峰值 "
        .. PEAK40B .. "）")
-- 隔離：清掉散養 fixture 與上限，避免後續子情境的 ANIMAL_REMOVED 被殘餘散養清除污染
ANIMAL_ROSTER = {}
sandbox.MaxAnimalsPerGroup = nil
resetAnimalWarned()

-- ③ 保護個體計入現存數但絕不清除：12 隻全命名、上限 10 ⇒ 超標但一隻都刪不了，
--    animal_protected_over 只記一次（edge-triggered，第二輪不重寫）
ZONE_R3 = makeTestZone({ id = 121, animals = {} })
for i = 1, 12 do
    ZONE_R3._opts.animals[i] = sow(7200 + i, { named = "pet" .. i })
end
ANIMAL_ZONES = { ZONE_R3 }
ANIMAL_REMOVED = {}
PROT40 = countLogEvent("animal_protected_over")
runTicks(4)
check(#ANIMAL_REMOVED == 0, "全命名 ⇒ 一隻都不清（實際 " .. #ANIMAL_REMOVED .. "）")
check(countLogEvent("animal_protected_over") - PROT40 == 0,
    "cullCount 排除保護個體 ⇒ 未超標、無診斷（命名不計入可治理數）")

-- ③b 混合：10 命名 ＋ 4 未命名、上限 10 ⇒ cullCount 4 未超標，一隻不清。
--     把 isProtectedAnimal 從計數裡拿掉（live 全算進 cullCount）會變成 14 > 10 而誤刪
ZONE_R3B = makeTestZone({ id = 122, animals = {} })
for i = 1, 10 do
    ZONE_R3B._opts.animals[i] = sow(7250 + i, { named = "keep" .. i })
end
for i = 11, 14 do
    ZONE_R3B._opts.animals[i] = sow(7250 + i)
end
ANIMAL_ZONES = { ZONE_R3B }
ANIMAL_REMOVED = {}
runTicks(4)
check(#ANIMAL_REMOVED == 0,
    "命名不佔可治理額度：4 隻未命名 < 上限 10 ⇒ 不清（實際 " .. #ANIMAL_REMOVED .. "）")

-- ④ NaN 座標：計入現存數但不清除（活鎖事故教訓），刪正常個體收到上限，
--    animal_nan 記 skipped=2。12 隻超 2、其中 2 隻 NaN ⇒ 刪 2 隻正常的
ZONE_R4 = makeTestZone({ id = 131, animals = {} })
for i = 1, 12 do
    ZONE_R4._opts.animals[i] = sow(7300 + i)
end
ZONE_R4._opts.animals[1]._opts.x = 0 / 0
ZONE_R4._opts.animals[2]._opts.z = 0 / 0
ANIMAL_ZONES = { ZONE_R4 }
ANIMAL_REMOVED = {}
NAN40 = countLogEvent("animal_nan")
runTicks(4)
check(#ANIMAL_REMOVED == 2 and not ZONE_R4._opts.animals[1].isGone()
        and not ZONE_R4._opts.animals[2].isGone(),
    "NaN 個體不清、刪 2 隻正常的收到上限（實際刪 " .. #ANIMAL_REMOVED .. "）")
check(countLogEvent("animal_nan") - NAN40 >= 1,
    "NaN 有診斷 log（skipped 計數）")

-- ⑤ 雞舍內動物計入現存數但不進清除候選（已被 removeFromWorld，直接 remove 會留
--    hutch.animalInside 殘留參照）。外 8 ＋ 內 4、上限 10 ⇒ 超 2、只刪外面的
HUTCH_IN_40 = {}
for i = 1, 4 do
    HUTCH_IN_40[i] = sow(7400 + i)
end
ZONE_R5 = makeTestZone({ id = 141, animals = {},
    hutches = { makeTestHutch({ inside = HUTCH_IN_40 }) } })
for i = 1, 8 do
    ZONE_R5._opts.animals[i] = sow(7410 + i)
end
ANIMAL_ZONES = { ZONE_R5 }
ANIMAL_REMOVED = {}
runTicks(4)
HUTCH_ALIVE_40 = 0
for i = 1, 4 do
    if not HUTCH_IN_40[i].isGone() then
        HUTCH_ALIVE_40 = HUTCH_ALIVE_40 + 1
    end
end
check(#ANIMAL_REMOVED == 2 and HUTCH_ALIVE_40 == 4,
    "外 8 ＋ 雞舍內 4 超 2 ⇒ 只刪外面的 2 隻、雞舍內不動（實際刪 "
        .. #ANIMAL_REMOVED .. "、內存活 " .. HUTCH_ALIVE_40 .. "）")

-- ⑤b 純雞舍內超額：外圈 0、內 12、上限 10 ⇒ 超 2 但候選為空，一隻都不能刪
--    （animal_protected_over 記帳）。⑤ 只釘得住「內圈有計數」——外圈候選排序在前，
--    就算內圈被誤收進候選也輪不到刪，變異不會轉紅（實測 0 FAIL）。這裡外圈歸零，
--    誤收的內圈個體就是唯一候選，變異必轉紅
HUTCH_IN_40B = {}
for i = 1, 12 do
    HUTCH_IN_40B[i] = sow(7450 + i)
end
ZONE_R5B = makeTestZone({ id = 142, animals = {},
    hutches = { makeTestHutch({ inside = HUTCH_IN_40B }) } })
ANIMAL_ZONES = { ZONE_R5B }
ANIMAL_REMOVED = {}
runTicks(4)
HUTCH_ALIVE_40B = 0
for i = 1, 12 do
    if not HUTCH_IN_40B[i].isGone() then
        HUTCH_ALIVE_40B = HUTCH_ALIVE_40B + 1
    end
end
check(#ANIMAL_REMOVED == 0 and HUTCH_ALIVE_40B == 12,
    "純雞舍內 12 超 2 ⇒ 一隻都不刪（實際刪 " .. #ANIMAL_REMOVED
        .. "、內存活 " .. HUTCH_ALIVE_40B .. "）")

-- ⑥ 幼體優先（損失最小）：13 隻含 3 幼體、上限 10 ⇒ 刪的 3 隻全是幼體
ZONE_R6 = makeTestZone({ id = 151, animals = {} })
for i = 1, 10 do
    ZONE_R6._opts.animals[i] = sow(7500 + i)
end
for i = 11, 13 do
    ZONE_R6._opts.animals[i] = sow(7500 + i, { baby = true })
end
ANIMAL_ZONES = { ZONE_R6 }
ANIMAL_REMOVED = {}
runTicks(4)
BABY_GONE_40 = 0
for i = 11, 13 do
    if ZONE_R6._opts.animals[i].isGone() then
        BABY_GONE_40 = BABY_GONE_40 + 1
    end
end
check(#ANIMAL_REMOVED == 3 and BABY_GONE_40 == 3,
    "超 3 且有 3 幼體 ⇒ 刪的全是幼體（實際刪 " .. #ANIMAL_REMOVED
        .. "、幼體 " .. BABY_GONE_40 .. "）")

-- ⑦ 天然 recount：警告輪之後、清除輪之前玩家自己處理掉超額 ⇒ 確認輪重新計數、
--    一隻不清（每輪重新讀取成員清單，沒有跨 tick 候選快照可過期）
ZONE_R7 = makeTestZone({ id = 161, animals = {} })
for i = 1, 15 do
    ZONE_R7._opts.animals[i] = sow(7600 + i)
end
ANIMAL_ZONES = { ZONE_R7 }
ANIMAL_REMOVED = {}
runTicks(1)
check(#ANIMAL_REMOVED == 0, "前提：首輪只警告")
for i = 1, 5 do
    ZONE_R7._opts.animals[i].remove()
end
ANIMAL_REMOVED = {}
runTicks(4)
check(#ANIMAL_REMOVED == 0,
    "警告後玩家自己減到上限 ⇒ 確認輪重數後一隻不清（實際 " .. #ANIMAL_REMOVED .. "）")

-- ⑧ 警告記錄的生命週期：群組整組消失後 key 被回收，重新住滿要**重新走警告輪**，
--    不可沿用過期記錄直接清理
ZONE_R8 = makeTestZone({ id = 171, animals = {} })
for i = 1, 15 do
    ZONE_R8._opts.animals[i] = sow(7700 + i)
end
ANIMAL_ZONES = { ZONE_R8 }
runTicks(1)
for i = 1, 15 do
    ZONE_R8._opts.animals[i].remove()
end
runTicks(2)
for i = 16, 30 do
    ZONE_R8._opts.animals[i] = sow(7700 + i)
end
ANIMAL_REMOVED = {}
runTicks(1)
check(#ANIMAL_REMOVED == 0,
    "群組消失讓警告記錄回收 ⇒ 重新住滿的第一輪只警告、不沿用過期記錄清理（實際刪 "
        .. #ANIMAL_REMOVED .. "）")

ANIMAL_ZONES = {}
ANIMAL_ROSTER = nil
sandbox.AnimalCleanupEnabled = nil
sandbox.AnimalGroupList = nil
sandbox.AnimalScanIntervalSeconds = nil
sandbox.MaxZoneAnimalsPerGroup = nil
end

-- ===== 情境四十一：清單產生器直通沙盒 =====
-- 重用 vanilla 沙盒面板封包鏈（本地 getSandboxOptions():set，MP 另建 copy →
-- sendToServer；封包層以 Capability.SandboxOptions 守門，PacketTypes.java:411）。
-- 不開 UI（createChildren 不跑），以 minimal instance 直測邏輯方法。
print()
print("情境四十一：清單產生器直通沙盒（token WYSIWYG、權限 gate、vanilla 封包鏈）")
do
check(MinidoracatCleaner.tokenKey("rat=5") == "rat", "tokenKey：覆寫 token 取 = 前段")
check(MinidoracatCleaner.tokenKey("rat =5") == "rat", "tokenKey：= 前空白剝除")
check(MinidoracatCleaner.tokenKey("Base.Log") == "Base.Log", "tokenKey：membership token 原樣")
check(MinidoracatCleaner.tokenKey("=5") == "", "tokenKey：畸形 token 取空 key 不炸")
check(MinidoracatCleaner.buildLimitToken("rat", "20") == "rat=20", "buildLimitToken：合法整數")
check(MinidoracatCleaner.buildLimitToken("rat", " 7 ") == "rat=7", "buildLimitToken：容忍前後空白")
check(MinidoracatCleaner.buildLimitToken("rat", "-1") == nil, "buildLimitToken：負數拒絕")
check(MinidoracatCleaner.buildLimitToken("rat", "abc") == nil, "buildLimitToken：非數字拒絕")
check(MinidoracatCleaner.buildLimitToken("rat", "2.5") == nil, "buildLimitToken：小數拒絕")
check(MinidoracatCleaner.buildLimitToken("rat", "9999999") == nil, "buildLimitToken：超出 1000000 拒絕")
check(MinidoracatCleaner.buildLimitToken("rat", "") == nil, "buildLimitToken：空字串拒絕")

-- 環境 stub：SP 起步；apply 鏈全部可觀測
local realIsClient41, realIsServer41 = isClient, isServer
local realGetSandboxOptions41 = getSandboxOptions
local realSandboxOptions41, realCapability41 = SandboxOptions, Capability
PICKER_SET_CALLS = {}
PICKER_SENT = 0
PICKER_COPIED = 0
PICKER_HALO = {}
PICKER_HAS_CAP = false
PICKER_VALUE_TEXT = ""
PICKER_KNOWN_OPTIONS = {
    ["MinidoracatCleanerFor42.AnimalLimitOverrides"] = true,
    ["MinidoracatCleanerFor42.ProtectList"] = true,
}
function getSandboxOptions()
    return {
        getOptionByName = function(_, name)
            return PICKER_KNOWN_OPTIONS[name] and {} or nil
        end,
        set = function(_, name, value)
            PICKER_SET_CALLS[#PICKER_SET_CALLS + 1] = { name = name, value = value }
        end,
    }
end
SandboxOptions = {
    new = function()
        return {
            copyValuesFrom = function() PICKER_COPIED = PICKER_COPIED + 1 end,
            sendToServer = function() PICKER_SENT = PICKER_SENT + 1 end,
        }
    end,
}
Capability = { SandboxOptions = "SandboxOptions" }
isClient = function() return false end
isServer = function() return false end

local pickerPlayer = {
    getRole = function()
        return { hasCapability = function(_, cap)
            return PICKER_HAS_CAP == true and cap == Capability.SandboxOptions
        end }
    end,
    setHaloNote = function(_, message) PICKER_HALO[#PICKER_HALO + 1] = tostring(message) end,
}

local function makePicker(mode)
    local p = setmetatable({
        playerObj = pickerPlayer,
        mode = mode,
        target = "",
        targetDef = nil,
        applyAllowed = false,
        selectedValues = {},
        selectedSet = {},
        listCheckedSet = {},
        listCheckedCount = 0,
        resultCheckedSet = {},
        resultCheckedCount = 0,
        lastSearchText = "",
        width = 1240,
    }, { __index = MinidoracatCleanerPicker })
    p.searchEntry = { getText = function() return "" end, setText = function() end }
    p.valueEntry = { getText = function() return PICKER_VALUE_TEXT end, setVisible = function() end,
        setEditable = function() end }
    p.valueLabel = { setVisible = function() end }
    p.applyButton = { setEnable = function() end }
    p.setValueButton = { setTitle = function() end, setEnable = function() end, setVisible = function() end }
    p.removeButton = { setTitle = function() end, setEnable = function() end }
    p.addButton = { setTitle = function() end, setEnable = function() end }
    p.listTitleLabel = { setName = function() end }
    p.resultsList = { isVirtual = true, setItems = function() end }
    p.selectedList = { isVirtual = true, setItems = function() end }
    return p
end

-- ① 預載：現值切逗號成原始 token，原樣保留（不解析關鍵字、不 canonical 化——
--    ProtectList 的關鍵字 token 無法無損反解，整值寫回時必須原樣通過）
sandbox.AnimalLimitOverrides = "rat=5, 手寫token ,cow=2"
local picker = makePicker("animals")
picker.applyAllowed = picker:computeApplyAllowed()
check(picker.applyAllowed == true, "SP 直接允許套用（無連線守門）")
picker:applyTargetSelection({ key = "AnimalLimitOverrides", mode = "animals", withValue = true })
check(#picker.selectedValues == 3
    and picker.selectedValues[1] == "rat=5"
    and picker.selectedValues[2] == "手寫token"
    and picker.selectedValues[3] == "cow=2",
    "預載現值為原始 token（手寫 token 原樣保留）")

-- ② 上方勾選→批量加入：覆寫目標用上限值欄現值組 token，同 group 原位替換；
--    加入後勾選清空
PICKER_VALUE_TEXT = "9"
picker:onResultClick({ value = "rat" })
check(picker.resultCheckedCount == 1, "點結果列＝勾選")
picker:onResultClick({ value = "rat" })
check(picker.resultCheckedCount == 0, "再點一次＝取消勾選（結果清單）")
picker:onResultClick({ value = "rat" })
picker:onAddChecked()
check(#picker.selectedValues == 3 and picker.selectedValues[1] == "rat=9",
    "批量加入：同 group 原位替換保序（rat=5 → rat=9）")
check(picker.resultCheckedCount == 0 and picker.resultCheckedSet["rat"] == nil,
    "批量加入後勾選清空")

-- ③ 非法上限值：整批不加入＋錯誤提示＋勾選保留（改好數值再按一次；
--    多選原子性——一個非法全不加）
PICKER_VALUE_TEXT = "abc"
picker:onResultClick({ value = "pig" })
picker:onResultClick({ value = "chicken" })
check(picker.resultCheckedCount == 2, "結果清單多選累積")
local haloBase = #PICKER_HALO
picker:onAddChecked()
check(#picker.selectedValues == 3, "非法上限值整批不加入")
check(#PICKER_HALO == haloBase + 1
    and PICKER_HALO[#PICKER_HALO]:find("BadValue", 1, true) ~= nil,
    "非法上限值有錯誤提示")
check(picker.resultCheckedCount == 2, "非法值不清勾選（修正數值後不必重勾）")
PICKER_VALUE_TEXT = "4"
picker:onAddChecked()
check(#picker.selectedValues == 5
    and picker.selectedValues[4] == "chicken=4"
    and picker.selectedValues[5] == "pig=4",
    "修正數值後批量加入成功（字母序 deterministic）")

-- ④ 下方清單勾選＋批量設值：點列＝勾選/取消；「設定數值」把勾選項的 group
--    全部改成值欄數值（原子性：非法整批不動、勾選保留）
picker:onSelectedClick({ value = "rat=9" })
check(picker.listCheckedCount == 1, "點目前清單列＝勾選")
picker:onSelectedClick({ value = "rat=9" })
check(picker.listCheckedCount == 0, "再點一次＝取消勾選")
picker:onSelectedClick({ value = "rat=9" })
picker:onSelectedClick({ value = "手寫token" })
check(picker.listCheckedCount == 2, "多選勾選累積")
PICKER_VALUE_TEXT = "abc"
haloBase = #PICKER_HALO
picker:onSetValueChecked()
check(picker.selectedValues[1] == "rat=9" and #PICKER_HALO == haloBase + 1,
    "批量設值遇非法數值：整批不動＋錯誤提示")
check(picker.listCheckedCount == 2, "非法設值不清勾選（改好數值再按一次）")
PICKER_VALUE_TEXT = "7"
picker:onSetValueChecked()
check(picker.selectedValues[1] == "rat=7"
    and picker.selectedValues[2] == "手寫token=7"
    and picker.selectedValues[3] == "cow=2",
    "批量設值：勾選項全部改值且原位保序")
check(picker.listCheckedCount == 0, "設值後勾選清空")

-- ⑤ 批量移除勾選項（一次移掉三項）
picker:onSelectedClick({ value = "cow=2" })
picker:onSelectedClick({ value = "chicken=4" })
picker:onSelectedClick({ value = "pig=4" })
picker:onRemoveChecked()
check(#picker.selectedValues == 2 and picker.selectedSet["cow"] == nil,
    "批量移除勾選項（selectedSet 的 key 一起清）")

-- ⑥ SP 套用：本地 set 整值寫回，不送封包
picker:onApply()
check(#PICKER_SET_CALLS == 1
    and PICKER_SET_CALLS[1].name == "MinidoracatCleanerFor42.AnimalLimitOverrides"
    and PICKER_SET_CALLS[1].value == "rat=7,手寫token=7",
    "SP 套用：token join 整值寫回沙盒選項")
check(PICKER_SENT == 0 and PICKER_COPIED == 0, "SP 不建封包、不送 server")

-- ⑦ MP 無權限：UI gate 擋住（鏡射封包層 Capability 守門，避免「UI 成功、封包被拒」）
isClient = function() return true end
PICKER_HAS_CAP = false
picker.applyAllowed = picker:computeApplyAllowed()
check(picker.applyAllowed == false, "MP 無 Capability.SandboxOptions ⇒ 不允許")
picker:onApply()
check(#PICKER_SET_CALLS == 1, "無權限時 set 不被呼叫")

-- ⑧ MP 有權限：本地 set ＋ copy → sendToServer（vanilla 封包鏈）
PICKER_HAS_CAP = true
picker.applyAllowed = picker:computeApplyAllowed()
check(picker.applyAllowed == true, "MP 有 capability ⇒ 允許")
picker:onApply()
check(#PICKER_SET_CALLS == 2, "有權限時本地 set 生效")
check(PICKER_COPIED == 1 and PICKER_SENT == 1,
    "MP 套用走 copyValuesFrom → sendToServer")

-- ⑨ 未宣告的沙盒選項：getOptionByName 先擋（set 對未知名拋 IllegalArgumentException，
--    SandboxOptions.java:572-583——殘留 UI 撞上未載入本 MOD 宣告的存檔不可炸）
picker:applyTargetSelection({ key = "NotDeclared", mode = "animals" })
haloBase = #PICKER_HALO
picker:onApply()
check(#PICKER_SET_CALLS == 2, "未宣告選項：set 不被呼叫")
check(#PICKER_HALO == haloBase + 1
    and PICKER_HALO[#PICKER_HALO]:find("ApplyFailed", 1, true) ~= nil,
    "未宣告選項有失敗提示")

-- ⑩ membership 目標：預載＋批量勾選加入＋去重＋整值寫回（手寫關鍵字 token 無損）
sandbox.ProtectList = "Base.Log, 關鍵字log"
local picker2 = makePicker("items")
picker2.applyAllowed = picker2:computeApplyAllowed()
picker2:applyTargetSelection({ key = "ProtectList", mode = "items" })
check(#picker2.selectedValues == 2, "membership 目標預載現值")
picker2:onResultClick({ value = "Base.Axe" })
picker2:onResultClick({ value = "Base.Hammer" })
picker2:onAddChecked()
check(#picker2.selectedValues == 4, "membership 批量勾選加入")
picker2:onResultClick({ value = "Base.Axe" })
picker2:onAddChecked()
check(#picker2.selectedValues == 4, "membership 重複加入去重（upsert）")
picker2:onApply()
check(PICKER_SET_CALLS[#PICKER_SET_CALLS].value == "Base.Log,關鍵字log,Base.Axe,Base.Hammer",
    "membership 整值寫回保序（手寫關鍵字 token 無損）")

-- ⑪ 全選/取消：結果清單只動「可見項」且翻轉語意（全勾→全取消、否則補滿）；
--    目前清單同一套
picker2.shownEntries = { { value = "Base.Saw" }, { value = "Base.Screwdriver" } }
picker2:onToggleAllResults()
check(picker2.resultCheckedCount == 2, "全選：可見結果全勾")
picker2:onResultClick({ value = "Base.Saw" })
picker2:onToggleAllResults()
check(picker2.resultCheckedCount == 2, "部分勾選時全選＝補到全滿")
picker2:onToggleAllResults()
check(picker2.resultCheckedCount == 0, "已全勾時再按＝全取消")
picker2:onToggleAllList()
check(picker2.listCheckedCount == #picker2.selectedValues and picker2.listCheckedCount > 0,
    "目前清單全選（" .. tostring(picker2.listCheckedCount) .. " 項）")
picker2:onToggleAllList()
check(picker2.listCheckedCount == 0, "目前清單再按＝全取消")

-- ⑩ 目標缺席（防禦分支）：Apply 不動作
picker2.targetDef = nil
local setBase = #PICKER_SET_CALLS
picker2:onApply()
check(#PICKER_SET_CALLS == setBase, "無目標時不寫沙盒")

isClient = realIsClient41
isServer = realIsServer41
getSandboxOptions = realGetSandboxOptions41
SandboxOptions = realSandboxOptions41
Capability = realCapability41
sandbox.AnimalLimitOverrides = nil
sandbox.ProtectList = nil
end
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
