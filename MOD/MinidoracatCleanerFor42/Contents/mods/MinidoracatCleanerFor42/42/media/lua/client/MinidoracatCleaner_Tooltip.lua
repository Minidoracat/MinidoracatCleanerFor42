require "MinidoracatCleaner_Core"
require "ISUI/ISToolTipInv"

local Cleaner = MinidoracatCleaner

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
    if not dropped or dropped == "" then
        return nil
    end
    return { { getText("IGUI_MinidoracatCleaner_LastDropped"), tostring(dropped) } }
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
