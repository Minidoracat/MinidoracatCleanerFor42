require "MinidoracatCleaner_Core"
require "ISUI/ISToolTipInv"

local Cleaner = MinidoracatCleaner

-- 「最後操作時間」格式化：存的是 epoch 秒（UTC、分鐘取整），這裡用 Calendar.getInstance()
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
            timeFormatter = timeFormatter or SimpleDateFormat.new("yyyy-MM-dd HH:mm", Locale.ENGLISH)
            local cal = Calendar.getInstance()
            cal:setTimeInMillis(at * 1000)
            return timeFormatter:format(cal:getTime())
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
    local modData = item:getModData()
    -- modData 是 Kahlua 原生 table：只能用全域 rawget(t,k)，方法式 t:rawget(k) 是 table 索引查找→call nil 爆錯
    local dropped = rawget(modData, Cleaner.KEY_DROPPED)
    local moved = rawget(modData, Cleaner.KEY_MOVED)
    local hasDropped = dropped ~= nil and dropped ~= ""
    local hasMoved = moved ~= nil and moved ~= ""
    if not hasDropped and not hasMoved then
        return nil
    end
    local lines = {}
    if hasDropped then
        lines[#lines + 1] = { getText("IGUI_MinidoracatCleaner_LastDropped"), tostring(dropped) }
    end
    if hasMoved then
        local value = tostring(moved)
        local at = tonumber(rawget(modData, Cleaner.KEY_MOVED_AT))
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

local function appendTraceBlock(tooltip, lines)
    local padLeft = tooltip.padLeft or 5
    local padBottom = tooltip.padBottom or 5
    local currentHeight = tooltip:getHeight()
    -- ObjectTooltip.java:252-267,307-318,328-367,411-427
    local layout = tooltip:beginLayout()
    for _, line in ipairs(lines) do
        local layoutItem = layout:addItem()
        layoutItem:setLabel(line[1] .. ":", 1, 1, 1, 1)
        layoutItem:setValue(line[2], 0.8, 0.8, 0.8, 1)
    end
    local endY = layout:render(padLeft, currentHeight - padBottom, tooltip)
    tooltip:endLayout(layout)
    tooltip:setHeight(endY + padBottom)
end

local function renderItemTooltip(tooltip, item, lines)
    item:DoTooltip(tooltip)
    appendTraceBlock(tooltip, lines)
end

local function installTooltipHook()
    if Cleaner._tooltipHookInstalled or Cleaner.getOption("TouchTraceEnabled") == false then
        return
    end
    Cleaner._tooltipHookInstalled = true
    local originalRender = ISToolTipInv.render

    function ISToolTipInv:render()
        local lines = getTraceLines(self.item)
        if not lines then
            return originalRender(self)
        end

        -- Vanilla 42.20.2 ISToolTipInv.lua:35-105, with append after both DoTooltip passes.
        if not ISContextMenu.instance or not ISContextMenu.instance.visibleCheck then
            local mx = getMouseX() + 24
            local my = getMouseY() + 24
            if not self.followMouse then
                mx = self:getX()
                my = self:getY()
                if self.anchorBottomLeft then
                    mx = self.anchorBottomLeft.x
                    my = self.anchorBottomLeft.y
                end
            end

            local PADX = 0
            self.tooltip:setX(mx + PADX)
            self.tooltip:setY(my)
            self.tooltip:setWidth(50)
            self.tooltip:setMeasureOnly(true)
            renderItemTooltip(self.tooltip, self.item, lines)
            self.tooltip:setMeasureOnly(false)

            local myCore = getCore()
            local maxX = myCore:getScreenWidth()
            local maxY = myCore:getScreenHeight()
            local tw = self.tooltip:getWidth()
            local th = self.tooltip:getHeight()

            self.tooltip:setX(math.max(0, math.min(mx + PADX, maxX - tw - 1)))
            if not self.followMouse and self.anchorBottomLeft then
                self.tooltip:setY(math.max(0, math.min(my - th, maxY - th - 1)))
            else
                self.tooltip:setY(math.max(0, math.min(my, maxY - th - 1)))
            end

            if self.contextMenu and self.contextMenu.joyfocus then
                local playerNum = self.contextMenu.player
                self.tooltip:setX(getPlayerScreenLeft(playerNum) + 60)
                self.tooltip:setY(getPlayerScreenTop(playerNum) + 60)
            elseif self.contextMenu and self.contextMenu.currentOptionRect then
                if self.contextMenu.currentOptionRect.height > 32 then
                    self:setY(my + self.contextMenu.currentOptionRect.height)
                end
                self:adjustPositionToAvoidOverlap(self.contextMenu.currentOptionRect)
            end

            self:setX(self.tooltip:getX() - PADX)
            self:setY(self.tooltip:getY())
            self:setWidth(tw + PADX)
            self:setHeight(th)

            if self.followMouse and self.contextMenu == nil then
                self:adjustPositionToAvoidOverlap({
                    x = mx - 24 * 2,
                    y = my - 24 * 2,
                    width = 24 * 2,
                    height = 24 * 2,
                })
            end

            self:drawRect(0, 0, self.width, self.height, self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
            self:drawRectBorder(0, 0, self.width, self.height, self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
            renderItemTooltip(self.tooltip, self.item, lines)
        end
    end
end

Events.OnGameStart.Add(installTooltipHook)
Events.OnCreatePlayer.Add(installTooltipHook)
