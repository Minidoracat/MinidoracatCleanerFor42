require "MinidoracatCleaner_Core"
require "ISUI/ISToolTipInv"

local Cleaner = MinidoracatCleaner

-- 「最後操作時間」：存的是 epoch 秒（UTC）。新章是小時整點，0.3.0 舊章可能是分鐘取整，
-- 兩種都要能顯示（讀取路徑不改舊值，見 Core readTouchFrom）。用 Calendar.getInstance()
-- 落在**客戶端本地時區**——不能用 os.date，Kahlua 的 OsLib 把時區寫死成 UTC（OsLib.java:331）。
-- Calendar 是 PZCalendar 薄包裝的暴露別名（LuaManager.java:1548-1567,2430），SimpleDateFormat
-- 於 LuaManager.java:1699 暴露；vanilla 同款用法：MapSpawnSelect.lua:542-543（SimpleDateFormat.new
-- + format(Calendar:getTime())）、ISRunningDebugUI.lua:93-97（setTimeInMillis）。
-- tooltip 每 frame 量測＋實繪兩個 pass 都會走到，SDF 只建一次、格式化結果依時間戳快取，
-- 避免每 frame 配置 Java 物件
local timeFormatter = nil
local timeCacheAt, timeCacheText = nil, nil
local timeFormatWarned = false
local function formatMovedAt(at)
    if timeCacheAt ~= at then
        -- 失敗不值得賠掉整個 tooltip（render 覆寫一炸＝所有物品無提示，正式服踩過同型坑）：
        -- pcall 包住，退化成只顯示名字不顯示時間
        local ok, text = pcall(function()
            timeFormatter = timeFormatter
                or SimpleDateFormat.new("yyyy-MM-dd HH:mm", Locale.ENGLISH)
            local cal = Calendar.getInstance()
            cal:setTimeInMillis(at * 1000)
            local formatted = timeFormatter:format(cal:getTime())
            if at % 3600 == 0 then
                -- 合併格式的新章是 UTC epoch hour bucket，不是「本地整點」。UTC+5:30 等時區下
                -- UTC 整點會落在本地 :30；硬寫 HH:00 會真的顯示錯時間。保留 Calendar 算出的
                -- 真實本地分鐘，前綴 `~` 明示「這是約略的小時區間，不是分鐘精確值」。
                return "~" .. formatted
            end
            return formatted
        end)
        timeCacheAt = at
        timeCacheText = ok and text or nil
        -- 靜默退化會讓「時間永遠不顯示」無從診斷：首次失敗留一行 console（只印一次）
        if not ok and not timeFormatWarned then
            timeFormatWarned = true
            print("[" .. Cleaner.MOD_ID .. "] tooltip time format failed: " .. tostring(text))
        end
    end
    return timeCacheText
end

local function getTraceLines(item)
    -- self.item 不保證是 InventoryItem：ISToolTipInv 不只用於物品欄，原版另有兩處把別的
    -- 東西塞進同一個 tooltip——ISEnergyBar.lua:90 傳電力資源、ISFluidBar.lua:220 傳流體容器，
    -- 而 ISToolTipInv.lua:187 是 `o.item = item` 原樣存入、不檢查型別。
    -- 對這些物件呼叫 hasModData 會得到「Object tried to call nil」而整個 tooltip 繪製中斷。
    -- 用「方法存在嗎」而非 instanceof 判定：Kahlua 索引不存在的方法回傳 nil 不拋例外
    -- （這正是上述錯誤的成因），對 Java 物件與 Lua table 都成立。
    if not item or not item.hasModData or not item:hasModData() then
        return nil
    end
    local dropped = Cleaner.readDrop(item)
    local moved, at = Cleaner.readTouch(item)
    if dropped == nil and moved == nil then
        return nil
    end
    local lines = {}
    if dropped then
        lines[#lines + 1] = { getText("IGUI_MinidoracatCleaner_LastDropped"), dropped }
    end
    if moved then
        local value = moved
        if at then
            local timeText = formatMovedAt(at)
            if timeText then
                value = value .. " (" .. timeText .. ")"
            end
        end
        lines[#lines + 1] = { getText("IGUI_MinidoracatCleaner_LastMoved"), value }
    end
    return lines
end

-- 疊法：本 MOD 在事件內安裝 hook，恆為最外層（OnGameStart 晚於所有 MOD 的 top-level）。
-- 舊版有章時整個重畫 vanilla、不呼叫下游，於是任何在 ISToolTipInv:render 加料的 MOD 都被吃掉
-- ——Skill Recovery Journal 的日記一經容器轉移就「變空白」（2026-09-06 Sixya 案）。
-- 現在改成：先讓下游（vanilla／SRJ／其他 override）畫完，量它實際畫到哪，再把章貼在最底下。
--
-- 為什麼要「量」：SRJ 把技能列畫在 tooltip 框外、不回寫任何高度（SRJ Tooltip.lua:260-270），
-- self:getHeight() 量不到它。攔 self **實例**上的 drawRect/drawRectBorder 記 max(y+h) 是唯一不認
-- MOD 的量法（ISUIElement 走標準 metatable，ISUIElement.lua:1965-1968，實例欄位優先於 class 方法）。
-- 攔不到的：下游直接呼叫 self.javaObject:DrawTextureScaledColor——沒有已知 MOD 這樣做；
-- ObjectTooltip 自己的 Java 繪圖高度已含在 self:getHeight()（ISToolTipInv.lua:97）。
local PAD = 5

-- rawget 在 own key 不存在時會查 metatable（KahluaTableImpl.java:98），辨識不了「實例自己
-- 有沒有這個欄位」；只能走 pairs（iterator 只走 own keys，:152-180）。否則還原用 nil 會把
-- 別的 MOD 放在實例上的覆寫砍掉。
local function ownSlots(self)
    local rect, border
    for k, v in pairs(self) do
        if k == "drawRect" then
            rect = v
        elseif k == "drawRectBorder" then
            border = v
        end
    end
    return rect, border
end

-- 回傳下游本 frame 畫到的最底 y（相對 self）；本 frame 沒收到任何矩形回 nil
local function renderDownstreamMeasured(self, originalRender)
    local ownRect, ownBorder = ownSlots(self)
    local fwdRect, fwdBorder = self.drawRect, self.drawRectBorder -- 安裝前的有效方法（含別人的覆寫）
    local bottom
    local function track(y, w, h)
        if w > 0 and h > 0 and (not bottom or y + h > bottom) then
            bottom = y + h
        end
    end
    rawset(self, "drawRect", function(ui, x, y, w, h, a, r, g, b)
        track(y, w, h)
        return fwdRect(ui, x, y, w, h, a, r, g, b)
    end)
    rawset(self, "drawRectBorder", function(ui, x, y, w, h, a, r, g, b)
        track(y, w, h)
        return fwdBorder(ui, x, y, w, h, a, r, g, b)
    end)
    local ok, err, trace = pcall(originalRender, self)
    rawset(self, "drawRect", ownRect) -- 沒 own slot 時 ownRect 為 nil ⇒ 刪掉 recorder
    rawset(self, "drawRectBorder", ownBorder)
    if not ok then
        -- Kahlua 的 error(msg, stacktrace)：第二參數是 stacktrace，不是 Lua 的 level
        -- （BaseLib.java:250-256；pcall 回 ok, msg, trace, throwable，KahluaThread.java:1457-1463）
        error(err, trace)
    end
    -- 沒收到矩形＝下游整段沒畫（context menu 開著時 vanilla ISToolTipInv.lua:45 直接跳過）；
    -- 不能拿殘留的 self:getHeight() 畫一個孤立框
    return bottom
end

-- 框寬用 self.width：vanilla 與 SRJ 都把自己最寬的框設成 self.width（ISToolTipInv.lua:96；
-- SRJ Tooltip.lua:162,258,268 的 hardSetWidth），不必追蹤下游畫了什麼矩形
local function appendTraceBox(self, lines, bottom)
    local tm = getTextManager()
    local font = self.tooltip:getFont() -- ObjectTooltip.java:67
    local lineH = tm:getFontHeight(font)
    local h = PAD * 2 + lineH * #lines
    local w = self.width
    local texts = {}
    for i, line in ipairs(lines) do
        texts[i] = line[1] .. ": " .. line[2]
        w = math.max(w, PAD * 2 + tm:MeasureStringX(font, texts[i]))
    end
    -- 貼底框不參與 vanilla 的螢幕 clamp（ISToolTipInv.lua:76-81）：背包在右下時 vanilla 框已被推到
    -- 貼底，往下貼必被裁 ⇒ 改貼上方；上方也不夠就省略。這是相對舊版唯一的退步（舊版章在框內）。
    -- ponytail: 上方框沒做「與游標避讓矩形／context menu currentOptionRect 交集」檢查，會壓到游標旁
    -- 的格子；有人抱怨再加（vanilla :99-101、:87-92 的兩個矩形都拿得到）。
    local y = bottom - 1
    if self.y + y + h > getCore():getScreenHeight() then
        if self.y - h < 0 then
            return
        end
        y = -h + 1
    end
    local bg, bd = self.backgroundColor, self.borderColor
    self:drawRect(0, y, w, h, math.min(1, bg.a + 0.4), bg.r, bg.g, bg.b)
    self:drawRectBorder(0, y, w, h, bd.a, bd.r, bd.g, bd.b)
    for i, text in ipairs(texts) do
        self:drawText(text, PAD, y + PAD + (i - 1) * lineH, 0.8, 0.8, 0.8, 1, font)
    end
end

local function installTooltipHook()
    if Cleaner._tooltipHookInstalled or Cleaner.getOption("TouchTraceEnabled") == false then
        return
    end
    Cleaner._tooltipHookInstalled = true
    local originalRender = ISToolTipInv.render -- OnGameStart 時已是 SRJ（或任何 top-level 包過者）

    function ISToolTipInv:render()
        local lines = getTraceLines(self.item)
        if not lines then
            return originalRender(self)
        end
        -- bottom 非 nil＝下游本 frame 真的畫了（也就已定位）；不另抄 SRJ:263 的 x>1/y>1 守衛，
        -- 那會讓 tooltip 被 clamp 到 y=0（vanilla :80）時整段不畫
        local bottom = renderDownstreamMeasured(self, originalRender)
        if bottom then
            appendTraceBox(self, lines, bottom)
        end
    end
end

Events.OnGameStart.Add(installTooltipHook)
Events.OnCreatePlayer.Add(installTooltipHook)
