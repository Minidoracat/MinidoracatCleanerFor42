-- 清單產生器：關鍵字搜尋（客戶端語言）→ 單擊挑選 → 直接套用到沙盒選項（或複製 CSV）。
-- UI 走家族框架 MinidoracatUIFor42（圓角深色皮膚＋VirtualList＋Toast；MinidoracatCleaner_Skin
-- 是 thin adapter，框架缺席自動退回 vanilla 直角＋ISScrollingListBox＋halo）。
-- getAllItems: ISItemsListViewer.lua:42
--
-- 【直接套用的通道】重用 vanilla 沙盒面板的封包流程（零新增 server 攻擊面）：
--   本地生效  getSandboxOptions():set(name, value)        （ISServerSandboxOptionsUI.lua:739）
--   MP 送服   SandboxOptions.new() → copyValuesFrom → sendToServer（:794-795,:773）
--   server 端 receiveSandboxOptions 落盤並廣播全 client（GameServer.java:1693-1706）；
--   封包層以 Capability.SandboxOptions 守門（PacketTypes.java:411），UI gate 鏡射
--   ISAdminPanelUI.lua:226——避免「UI 允許、封包被拒」的假成功。
--
-- 【token 級 WYSIWYG】選定寫入目標時把現值切逗號預載為原始 token（不解析關鍵字——
--   ProtectList 的關鍵字 token 無法無損反解為物品），套用＝token 以 , join 整值寫回；
--   管理員手寫的關鍵字 token 原樣保留。
require "MinidoracatCleaner_Core"
require "MinidoracatCleaner_Skin"
require "ISUI/ISCollapsableWindow"

local Cleaner = MinidoracatCleaner
local Skin = MinidoracatCleanerSkin
local COLORS = Skin.COLORS

MinidoracatCleanerPicker = ISCollapsableWindow:derive("MinidoracatCleanerPicker")
MinidoracatCleanerPicker.instance = nil

local PAD = 8
local ROW = 26
local LIST_ROW = 26
local FONT = UIFont.Medium -- 管理面板字級（Small 太小，實測回饋）
local FONT_HGT = nil -- lazy：載入期不碰 getTextManager（dedicated／harness 沒有）

-- 可寫入的沙盒清單選項（單一下拉直列六目標；label 直接重用沙盒選項的四語顯示名
-- Sandbox_*，各自帶足語境）。mode 決定搜尋資料源（items＝物品腳本、animals＝動物
-- 群組）；withValue＝覆寫類目標，加入時以數值欄組成 group=value token。
-- 「僅複製」不是目標——複製按鈕對任何目標恆可用，獨立模式徒增一步選擇。
local TARGETS = {
    { key = "ProtectList", mode = "items" },
    { key = "HighToleranceList", mode = "items" },
    { key = "AnimalGroupList", mode = "animals" },
    { key = "AnimalLimitOverrides", mode = "animals", withValue = true },
    { key = "AnimalZoneLimitOverrides", mode = "animals", withValue = true },
    { key = "AnimalGlobalLimitOverrides", mode = "animals", withValue = true },
    { key = "RanchBreedingOverrides", mode = "animals", withValue = true },
}

-- ============ VirtualList cell（checkbox／hover 高亮／主次雙色文字） ============
-- cell 不吞滑鼠事件：框架 rebuildPool 已清掉 wantMouseEvents（ISUIElement.lua:1998 預設
-- true 會讓 ISPanel:onMouseDown 回 true 把點擊吞掉，ISPanel.lua:49），單擊統一由
-- VirtualList:onMouseDown 處理。「目前清單」的勾選狀態存在 Picker（listCheckedSet），
-- cell 每幀直接查——單一資料來源，不用 revision 重綁。

local PickerCell = ISPanel:derive("MinidoracatCleanerPickerCell")

function PickerCell:render()
    local item = self.cellItem
    if not item then
        return
    end
    local hovered = self:isMouseOver()
    if hovered then
        Skin.fill(self, 0, 0, self.width, self.height, COLORS.HOVER, "rect")
    end
    FONT_HGT = FONT_HGT or getTextManager():getFontHeight(FONT)
    local textY = math.floor((self.height - FONT_HGT) / 2)
    local textX = 6
    -- 勾選框（目前清單）：勾選＝accent 實心，未勾＝框線
    if self.showCheckbox then
        local box = 16
        local boxY = math.floor((self.height - box) / 2)
        local window = self.pickerWindow
        if window and self.checkedField and window[self.checkedField][item.value] then
            local accent = COLORS.ACCENT
            self:drawRect(6, boxY, box, box, 0.95, accent.r, accent.g, accent.b)
        else
            local border = COLORS.BORDER
            self:drawRectBorder(6, boxY, box, box, 1, border.r, border.g, border.b)
        end
        textX = 6 + box + 8
    end
    local text = COLORS.TEXT
    self:drawText(item.text, textX, textY, text.r, text.g, text.b, text.a, FONT)
    if item.detail then
        if not self.textW then
            self.textW = getTextManager():MeasureStringX(FONT, item.text)
        end
        local muted = COLORS.TEXT_MUTED
        self:drawText(item.detail, textX + self.textW + 10, textY,
            muted.r, muted.g, muted.b, muted.a, FONT)
    end
    -- 右緣動作提示（結果清單＋）：hover 時 accent 高亮，指出「點了會發生什麼」
    local glyph = self.actionGlyph
    if glyph then
        if not self.glyphW then
            self.glyphW = getTextManager():MeasureStringX(FONT, glyph)
        end
        local color = hovered and COLORS.ACCENT or COLORS.TEXT_MUTED
        self:drawText(glyph, self.width - 8 - self.glyphW, textY,
            color.r, color.g, color.b, color.a, FONT)
    end
end

-- ============ 側邊欄（目標切換；六項固定，直畫） ============
-- 點側欄項直接切換寫入目標——比下拉少一次點擊且六個清單一眼可見。
-- 覆寫 onMouseDown 自行命中（回 true 吞掉：側欄自己就是點擊終點）。

local SIDEBAR_W = 224
local SIDEBAR_ROW = 36
local MAIN_W = 700 -- 主區固定寬；總寬＝側欄（動態）＋主區

local PickerSidebar = ISPanel:derive("MinidoracatCleanerPickerSidebar")

function PickerSidebar:render()
    FONT_HGT = FONT_HGT or getTextManager():getFontHeight(FONT)
    local window = self.pickerWindow
    local mouseY = self:isMouseOver() and self:getMouseY() or -1
    for index, def in ipairs(TARGETS) do
        local y = (index - 1) * SIDEBAR_ROW
        local selected = window and window.targetDef == def
        if selected then
            Skin.fill(self, 0, y, self.width, SIDEBAR_ROW, COLORS.SELECTED, "rect")
            local accent = COLORS.ACCENT
            self:drawRect(0, y, 3, SIDEBAR_ROW, 1, accent.r, accent.g, accent.b)
        elseif mouseY >= y and mouseY < y + SIDEBAR_ROW then
            Skin.fill(self, 0, y, self.width, SIDEBAR_ROW, COLORS.HOVER, "rect")
        end
        local color = selected and COLORS.TEXT or COLORS.TEXT_MUTED
        self:drawText(getText("Sandbox_MinidoracatCleanerFor42_" .. def.key), 12,
            y + math.floor((SIDEBAR_ROW - FONT_HGT) / 2),
            color.r, color.g, color.b, color.a, FONT)
    end
end

function PickerSidebar:onMouseDown(x, y)
    local def = TARGETS[math.floor(y / SIDEBAR_ROW) + 1]
    if def and self.pickerWindow then
        self.pickerWindow:selectTarget(def)
    end
    return true
end

-- ============ 視窗 ============

function MinidoracatCleanerPicker.open(playerObj)
    if MinidoracatCleanerPicker.instance then
        MinidoracatCleanerPicker.instance:close()
    end
    local window = MinidoracatCleanerPicker:new(100, 60, 1240, 720, playerObj)
    window:initialise()
    window:addToUIManager()
    MinidoracatCleanerPicker.instance = window
end

function MinidoracatCleanerPicker:new(x, y, width, height, playerObj)
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    o.playerObj = playerObj
    o.title = getText("IGUI_MinidoracatCleaner_PickerTitle")
    -- 標題字級隨面板放大：titleBarHeight = max(16, titleFontHgt+1)（ISCollapsableWindow.lua:298-299）
    -- 跟著字高走，覆蓋兩欄位即可
    o.titleBarFont = FONT
    o.titleFontHgt = getTextManager():getFontHeight(FONT)
    o.mode = TARGETS[1].mode
    o.target = TARGETS[1].key
    o.targetDef = TARGETS[1]
    o.applyAllowed = false
    o.selectedValues = {}
    o.selectedSet = {}
    o.listCheckedSet = {}
    o.listCheckedCount = 0
    o.resultCheckedSet = {}
    o.resultCheckedCount = 0
    o.itemCache = nil
    o.resizable = false
    o.lastSearchText = ""
    return o
end

-- 清單工廠：框架在走 VirtualList（物件池，UIElement 數量只隨 viewport 成長——
-- 物品清單數千筆）；缺席退 ISScrollingListBox。兩路徑都是單擊觸發 clickHandler(entry)。
-- opts.checkedField＝勾選集欄位名（"resultCheckedSet"／"listCheckedSet"；nil＝無勾選框）；
-- opts.glyph＝右緣動作符號。
function MinidoracatCleanerPicker:buildList(x, y, width, height, clickHandler, opts)
    opts = opts or {}
    local glyph, checkedField = opts.glyph, opts.checkedField
    local checkbox = checkedField ~= nil
    local VirtualList = Skin.virtualListClass()
    if VirtualList then
        local window = self
        local list = VirtualList.new({
            x = x, y = y, width = width, height = height,
            rowHeight = LIST_ROW,
            createCell = function() return ISPanel.new(PickerCell, 0, 0, 0, 0) end,
            bindCell = function(_, cell, item)
                cell.cellItem = item
                cell.actionGlyph = glyph
                cell.showCheckbox = checkbox
                cell.checkedField = checkedField
                cell.pickerWindow = window
                cell.textW = nil
            end,
            unbindCell = function(_, cell)
                cell.cellItem = nil
                cell.textW = nil
            end,
            onSelect = function(_, item)
                clickHandler(window, item)
            end,
        })
        list.isVirtual = true
        list.showCheckbox = checkbox
        list:initialise()
        self:addChild(list)
        return list
    end
    local list = ISScrollingListBox:new(x, y, width, height)
    list:initialise()
    list:instantiate()
    list.itemheight = LIST_ROW
    list.font = UIFont.Small
    list.drawBorder = false -- 邊框統一由視窗 render 的清單外框畫
    list.showCheckbox = checkbox
    list:setOnMouseDownFunction(self, clickHandler) -- ISScrollingListBox.lua:277,289
    self:addChild(list)
    return list
end

function MinidoracatCleanerPicker:setListData(list, entries)
    if list.isVirtual then
        list:setItems(entries)
    else
        -- 退回清單無 cell 繪製：勾選狀態以文字前綴呈現
        list:clear()
        for _, entry in ipairs(entries) do
            local label = entry.label or entry.text
            if list.showCheckbox then
                label = (self.listCheckedSet[entry.value] and "[x] " or "[  ] ") .. label
            end
            list:addItem(label, entry)
        end
    end
end

function MinidoracatCleanerPicker:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.applyAllowed = self:computeApplyAllowed()
    local top = self:titleBarHeight()
    -- 側欄寬動態量測（Medium 字型下「非圈養上限覆寫（玩家周邊）」等長標籤會爆出
    -- 固定寬；四語標籤長度差異大，載入期不能碰 getTextManager、這裡可以）
    local sidebarW = SIDEBAR_W
    for _, def in ipairs(TARGETS) do
        local labelW = getTextManager():MeasureStringX(FONT,
            getText("Sandbox_MinidoracatCleanerFor42_" .. def.key))
        if labelW + 28 > sidebarW then
            sidebarW = labelW + 28
        end
    end
    if sidebarW > 500 then
        sidebarW = 500
    end
    self.sidebarW = sidebarW
    -- 視窗總寬＝動態側欄＋固定主區；先定寬再排元件（右對齊元件靠 self.width）
    self:setWidth(sidebarW + PAD + MAIN_W + PAD)
    local x0 = sidebarW + PAD -- 主區左緣（側欄右側）
    local innerWidth = MAIN_W
    local y = top + PAD

    -- 側欄：六個寫入目標直接切換
    self.sidebar = ISPanel.new(PickerSidebar, 0, top, sidebarW, SIDEBAR_ROW * #TARGETS)
    self.sidebar.pickerWindow = self
    self.sidebar:initialise()
    self:addChild(self.sidebar)


    -- 搜尋框（主區全寬）
    self.searchEntry = ISTextEntryBox:new("", x0, y, innerWidth, ROW)
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self:addChild(self.searchEntry)
    y = y + ROW + PAD

    -- 搜尋結果（點選＝勾選）
    local resultsHeight = LIST_ROW * 10
    self.resultsList = self:buildList(x0, y, innerWidth, resultsHeight,
        MinidoracatCleanerPicker.onResultClick, { checkedField = "resultCheckedSet" })
    y = y + resultsHeight + 4

    -- 加入列（貼結果清單正下方）：「全選/取消」＋上限值欄（覆寫目標才顯示）＋「加入勾選」
    self.resultAllButton = ISButton:new(x0, y, 120, ROW,
        getText("IGUI_MinidoracatCleaner_PickerToggleAll"), self, MinidoracatCleanerPicker.onToggleAllResults)
    self.resultAllButton:initialise()
    self:addChild(self.resultAllButton)
    self.addButton = ISButton:new(x0 + innerWidth - 190, y, 190, ROW,
        "", self, MinidoracatCleanerPicker.onAddChecked)
    self.addButton:initialise()
    self:addChild(self.addButton)
    self.valueEntry = ISTextEntryBox:new("", self.addButton.x - PAD - 80, y, 80, ROW)
    self.valueEntry:initialise()
    self.valueEntry:instantiate()
    self.valueEntry:setOnlyNumbers(true) -- ISTextEntryBox.lua:32；貼上繞過由 buildLimitToken 再守
    self:addChild(self.valueEntry)
    self.valueLabel = ISLabel:new(0, y + 3, 20, getText("IGUI_MinidoracatCleaner_PickerValueLabel"), 0.7, 0.7, 0.7, 1, FONT, true)
    self.valueLabel:initialise()
    self:addChild(self.valueLabel)
    self.valueLabel:setX(self.valueEntry.x - PAD - self.valueLabel:getWidth())
    y = y + ROW + PAD

    -- 目前清單標題（數量隨 refreshSelected 更新）
    self.listTitleLabel = ISLabel:new(x0, y, 20, "", 1, 1, 1, 1, FONT, true)
    self.listTitleLabel:initialise()
    self:addChild(self.listTitleLabel)
    y = y + 20 + 2

    -- 目前清單（點選＝勾選；批量設值/移除走下方按鈕——點一下就刪太容易誤觸）
    local selectedHeight = LIST_ROW * 7
    self.selectedList = self:buildList(x0, y, innerWidth, selectedHeight,
        MinidoracatCleanerPicker.onSelectedClick, { checkedField = "listCheckedSet" })
    y = y + selectedHeight + 4

    -- 批量操作列（貼目前清單正下方）：「全選/取消」＋「設定數值」（覆寫目標才顯示；
    -- 數值取上方加入列的上限值欄）＋「移除勾選」
    self.listAllButton = ISButton:new(x0, y, 120, ROW,
        getText("IGUI_MinidoracatCleaner_PickerToggleAll"), self, MinidoracatCleanerPicker.onToggleAllList)
    self.listAllButton:initialise()
    self:addChild(self.listAllButton)
    self.setValueButton = ISButton:new(x0 + 120 + PAD, y, 190, ROW,
        "", self, MinidoracatCleanerPicker.onSetValueChecked)
    self.setValueButton:initialise()
    self:addChild(self.setValueButton)
    self.removeButton = ISButton:new(x0 + 120 + PAD + 190 + PAD, y, 190, ROW,
        "", self, MinidoracatCleanerPicker.onRemoveChecked)
    self.removeButton:initialise()
    self:addChild(self.removeButton)
    y = y + ROW + PAD

    -- 按鈕列：主動作「套用」accent 靠右；破壞性「清空」放最左與主動作隔開防誤觸
    self.clearButton = ISButton:new(x0, y, 96, ROW,
        getText("IGUI_MinidoracatCleaner_PickerClear"), self, MinidoracatCleanerPicker.onClear)
    self.clearButton:initialise()
    self:addChild(self.clearButton)
    self.copyButton = ISButton:new(x0 + 96 + PAD, y, 170, ROW,
        getText("IGUI_MinidoracatCleaner_PickerCopy"), self, MinidoracatCleanerPicker.onCopy)
    self.copyButton:initialise()
    self:addChild(self.copyButton)
    self.applyButton = ISButton:new(x0 + innerWidth - 190, y, 190, ROW,
        getText("IGUI_MinidoracatCleaner_PickerApply"), self, MinidoracatCleanerPicker.onApply)
    self.applyButton:initialise()
    self:addChild(self.applyButton)

    for _, button in ipairs({ self.clearButton, self.copyButton, self.addButton,
        self.setValueButton, self.removeButton, self.resultAllButton, self.listAllButton }) do
        button.font = FONT
        button.backgroundColor = { r = 0, g = 0, b = 0, a = 0.5 }
        button.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.1 }
        button.borderColor = { r = COLORS.BORDER.r, g = COLORS.BORDER.g, b = COLORS.BORDER.b, a = 1 }
    end
    -- 主按鈕：accent 填色＋深色字（ISButton.lua:252 render 讀 textColor 與 font、:492 欄位）
    self.applyButton.font = FONT
    self.applyButton.backgroundColor = { r = COLORS.ACCENT.r, g = COLORS.ACCENT.g, b = COLORS.ACCENT.b, a = 0.9 }
    self.applyButton.backgroundColorMouseOver = { r = 1, g = 0.92, b = 0.6, a = 1 }
    self.applyButton.borderColor = { r = COLORS.ACCENT.r, g = COLORS.ACCENT.g, b = COLORS.ACCENT.b, a = 1 }
    self.applyButton.textColor = { r = 0.08, g = 0.08, b = 0.08, a = 1 }
    self:updateAddButton()
    self:updateBatchButtons()
    y = y + ROW + PAD

    self:setHeight(y)
    self.sidebar:setHeight(y - top)
    -- 預設置中（螢幕尺寸執行期才知道；Toast._create 同款 getCore 用法）
    self:setX(math.floor((getCore():getScreenWidth() - self.width) / 2))
    self:setY(math.floor((getCore():getScreenHeight() - self.height) / 2))
    self:applyTargetSelection(TARGETS[1])
end

-- ============ 皮膚（NBPanel 樣板：prerender 畫底、render 畫外框） ============

function MinidoracatCleanerPicker:prerender()
    local width = self:getWidth()
    local height = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then
        height = th
    end
    Skin.fill(self, 0, 0, width, height, COLORS.BG_PANEL)
    Skin.fill(self, 0, 0, width, th, COLORS.TITLEBAR_FILL, not self.isCollapsed)
    if not self.isCollapsed then
        local border = COLORS.BORDER
        self:drawRect(0, th - 1, width, 1, border.a, border.r, border.g, border.b)
        -- 清單的 well 底（child 之前畫；圓角）
        if self.resultsList then
            Skin.fill(self, self.resultsList.x, self.resultsList.y,
                self.resultsList.width, self.resultsList.height, COLORS.WELL)
        end
        if self.selectedList then
            Skin.fill(self, self.selectedList.x, self.selectedList.y,
                self.selectedList.width, self.selectedList.height, COLORS.WELL)
            -- 空狀態：引導下一步動作（cell 是透明 child，這行字從清單底透出）
            if #self.selectedValues == 0 then
                FONT_HGT = FONT_HGT or getTextManager():getFontHeight(UIFont.Small)
                local muted = COLORS.TEXT_MUTED
                self:drawTextCentre(getText("IGUI_MinidoracatCleaner_PickerEmptyList"),
                    self.selectedList.x + self.selectedList.width / 2,
                    self.selectedList.y + math.floor((self.selectedList.height - FONT_HGT) / 2),
                    muted.r, muted.g, muted.b, muted.a, UIFont.Small)
            end
        end
    end
    if self.title then
        self:drawTextCentre(self.title, width / 2, 1, 1, 1, 1, 1, self.titleBarFont)
    end
    -- IME（中文輸入法）組字送出不觸發 onTextChange，改每 frame 比對文字；貼上/刪除也一併涵蓋
    if not self.isCollapsed then
        local text = self.searchEntry and self.searchEntry:getText() or ""
        if text ~= self.lastSearchText then
            self.lastSearchText = text
            self:refreshResults()
        end
    end
end

function MinidoracatCleanerPicker:render()
    local width = self:getWidth()
    local height = self.isCollapsed and self:titleBarHeight() or self:getHeight()
    if not self.isCollapsed then
        if self.resultsList then
            Skin.border(self, self.resultsList.x, self.resultsList.y,
                self.resultsList.width, self.resultsList.height, COLORS.BORDER)
        end
        if self.selectedList then
            Skin.border(self, self.selectedList.x, self.selectedList.y,
                self.selectedList.width, self.selectedList.height, COLORS.BORDER)
        end
    end
    if not self.isCollapsed then
        -- 側欄分隔線
        local border = COLORS.BORDER
        self:drawRect(self.sidebarW or SIDEBAR_W, self:titleBarHeight(), 1,
            height - self:titleBarHeight(), border.a, border.r, border.g, border.b)
    end
    Skin.border(self, 0, 0, width, height, COLORS.BORDER)
end

-- ============ 資料 ============

function MinidoracatCleanerPicker:getItemEntries()
    if self.itemCache then
        return self.itemCache
    end
    local cache = {}
    local all = getAllItems() -- ISItemsListViewer.lua:42
    for index = 0, all:size() - 1 do
        local script = all:get(index)
        local fullName = script:getFullName() -- Item.java:882
        -- 客戶端語言的翻譯名（LuaManager.java:8579）；缺翻譯時退回腳本英文名
        local display = getItemNameFromFullType(fullName)
        if not display or display == "" then
            display = script:getDisplayName() or fullName
        end
        cache[#cache + 1] = {
            value = fullName,
            text = display,
            detail = fullName,
            label = display .. "  \194\183  " .. fullName,
            search = string.lower(display .. " " .. fullName),
        }
    end
    -- 數千筆的大陣列用非遞迴排序（Kahlua table.sort 遞迴深度風險，見 Core.sortSafe）
    Cleaner.sortSafe(cache, function(a, b) return a.label < b.label end)
    self.itemCache = cache
    return cache
end

function MinidoracatCleanerPicker:getAnimalEntries()
    local groups = {}
    local defs = AnimalDefinitions and AnimalDefinitions.animals
    if type(defs) == "table" then
        for animalType, def in pairs(defs) do
            local group = def and def.group
            if group then
                group = tostring(group)
                local entry = groups[group]
                if not entry then
                    entry = { names = {}, search = string.lower(group) }
                    groups[group] = entry
                end
                local key = "IGUI_AnimalType_" .. tostring(animalType)
                local translated = getText(key)
                if translated and translated ~= key then
                    entry.names[#entry.names + 1] = translated
                    entry.search = entry.search .. " " .. string.lower(translated)
                end
                entry.search = entry.search .. " " .. string.lower(tostring(animalType))
            end
        end
    end
    local cache = {}
    for group, entry in pairs(groups) do
        Cleaner.sortSafe(entry.names, function(a, b) return a < b end)
        local names = table.concat(entry.names, ", ")
        cache[#cache + 1] = {
            value = group,
            text = group,
            detail = names ~= "" and names or nil,
            label = group .. "  \194\183  " .. (names ~= "" and names or group),
            search = entry.search,
        }
    end
    Cleaner.sortSafe(cache, function(a, b) return a.label < b.label end)
    return cache
end

function MinidoracatCleanerPicker:refreshResults()
    local text = string.lower(self.searchEntry and self.searchEntry:getText() or "")
    text = text:match("^%s*(.-)%s*$") or ""
    local minChars = self.mode == "animals" and 0 or 2
    local shown = {}
    -- 短於 minChars 不建 entry cache：物品清單數千筆的取得＋排序延後到第一次
    -- 真的要搜尋才付（開窗、切模式都不付）
    if #text >= minChars then
        local entries
        if self.mode == "animals" then
            entries = self:getAnimalEntries()
        else
            entries = self:getItemEntries()
        end
        for _, entry in ipairs(entries) do
            if text == "" or string.find(entry.search, text, 1, true) then
                if not self.selectedSet[Cleaner.tokenKey(entry.value)] then
                    shown[#shown + 1] = entry
                    if #shown >= 200 then
                        break
                    end
                end
            end
        end
    end
    self.shownEntries = shown
    self:setListData(self.resultsList, shown)
end

-- 「全選/取消」（結果清單）：可見結果全都勾了就整批取消，否則補勾到全滿。
-- 只動可見項——跨搜尋累積的其他勾選不受影響
function MinidoracatCleanerPicker:onToggleAllResults()
    local shown = self.shownEntries or {}
    if #shown == 0 then
        return
    end
    local allChecked = true
    for _, entry in ipairs(shown) do
        if not self.resultCheckedSet[entry.value] then
            allChecked = false
            break
        end
    end
    for _, entry in ipairs(shown) do
        local checked = self.resultCheckedSet[entry.value] == true
        if allChecked and checked then
            self.resultCheckedSet[entry.value] = nil
            self.resultCheckedCount = self.resultCheckedCount - 1
        elseif not allChecked and not checked then
            self.resultCheckedSet[entry.value] = true
            self.resultCheckedCount = self.resultCheckedCount + 1
        end
    end
    self:updateAddButton()
    if self.resultsList and not self.resultsList.isVirtual then
        self:refreshResults()
    end
end

-- 「全選/取消」（目前清單）：同一套翻轉語意
function MinidoracatCleanerPicker:onToggleAllList()
    if #self.selectedValues == 0 then
        return
    end
    local allChecked = true
    for _, token in ipairs(self.selectedValues) do
        if not self.listCheckedSet[token] then
            allChecked = false
            break
        end
    end
    for _, token in ipairs(self.selectedValues) do
        local checked = self.listCheckedSet[token] == true
        if allChecked and checked then
            self.listCheckedSet[token] = nil
            self.listCheckedCount = self.listCheckedCount - 1
        elseif not allChecked and not checked then
            self.listCheckedSet[token] = true
            self.listCheckedCount = self.listCheckedCount + 1
        end
    end
    self:updateBatchButtons()
    if self.selectedList and not self.selectedList.isVirtual then
        self:refreshSelected()
    end
end

function MinidoracatCleanerPicker:refreshSelected()
    local entries = {}
    for _, token in ipairs(self.selectedValues) do
        local key = Cleaner.tokenKey(token)
        local entry = { value = token, text = token, label = token }
        if key ~= token then
            -- 覆寫類 token：group 主色、= 值灰色
            entry.text = key
            entry.detail = "=  " .. (token:match("^[^=]*=%s*(.*)$") or "")
        end
        entries[#entries + 1] = entry
    end
    self:setListData(self.selectedList, entries)
    if self.listTitleLabel then
        self.listTitleLabel:setName(getText("IGUI_MinidoracatCleaner_PickerListTitle", tostring(#self.selectedValues)))
    end
end

-- ============ 模式／寫入目標 ============

-- 側欄點擊入口：同一目標重複點擊不重載（避免把編輯到一半的清單洗掉）
function MinidoracatCleanerPicker:selectTarget(def)
    if def and def ~= self.targetDef then
        self:applyTargetSelection(def)
    end
end

function MinidoracatCleanerPicker:applyTargetSelection(def)
    if self.mode ~= def.mode and self.searchEntry then
        -- 資料源換邊（物品↔動物）：舊搜尋詞對新資料源無意義
        self.searchEntry:setText("")
        self.lastSearchText = ""
    end
    self.targetDef = def
    self.target = def.key
    self.mode = def.mode
    self.selectedValues = {}
    self.selectedSet = {}
    self.listCheckedSet = {}
    self.listCheckedCount = 0
    self.resultCheckedSet = {}
    self.resultCheckedCount = 0
    self:updateAddButton()
    self:updateBatchButtons()
    -- 預載現值為原始 token（只切逗號，不解析關鍵字）：整值寫回時手寫 token 無損
    for _, token in ipairs(Cleaner.parseList(Cleaner.getOption(def.key))) do
        self:upsertToken(token)
    end
    local withValue = def.withValue == true
    -- 上限值欄與「設定數值」只在覆寫目標出現：membership 清單不吃數量，灰化鎖住
    -- 仍會被當成「壞掉的輸入框」（實測回饋「沒辦法輸入」），整組隱藏歧義最小——
    -- 側欄讓「切到覆寫頁」一目了然，不會找不到設定數量的地方
    if self.valueEntry then
        self.valueLabel:setVisible(withValue)
        self.valueEntry:setVisible(withValue)
        self.setValueButton:setVisible(withValue)
    end
    if self.applyButton then
        self.applyButton:setEnable(self.applyAllowed == true)
        self.applyButton.tooltip = (not self.applyAllowed)
            and getText("IGUI_MinidoracatCleaner_PickerNoPermission") or nil
    end
    self:refreshSelected()
    self:refreshResults()
end

-- ============ token 挑選 ============

-- 以 tokenKey 去重／upsert（不刷新；呼叫端統一刷新）：同 group 換值＝原位替換保序
function MinidoracatCleanerPicker:upsertToken(token)
    local key = Cleaner.tokenKey(token)
    if self.selectedSet[key] then
        for index, existing in ipairs(self.selectedValues) do
            if Cleaner.tokenKey(existing) == key then
                self.selectedValues[index] = token
                return
            end
        end
        return
    end
    self.selectedSet[key] = true
    self.selectedValues[#self.selectedValues + 1] = token
end

-- 點結果列＝勾選/取消（可跨搜尋累積），「加入勾選」批量進下方清單——
-- 逐個點擊立即加入在覆寫目標下會被值驗證連環擋（實測回饋：一個一個加很不方便）
function MinidoracatCleanerPicker:onResultClick(item)
    if not (item and item.value) then
        return
    end
    if self.resultCheckedSet[item.value] then
        self.resultCheckedSet[item.value] = nil
        self.resultCheckedCount = self.resultCheckedCount - 1
    else
        self.resultCheckedSet[item.value] = true
        self.resultCheckedCount = self.resultCheckedCount + 1
    end
    self:updateAddButton()
    -- VirtualList cell 每幀直查勾選集；退回清單的勾選是文字前綴，要重組
    if self.resultsList and not self.resultsList.isVirtual then
        self:refreshResults()
    end
end

function MinidoracatCleanerPicker:updateAddButton()
    if not self.addButton then
        return
    end
    self.addButton:setTitle(getText("IGUI_MinidoracatCleaner_PickerAddChecked", tostring(self.resultCheckedCount)))
    self.addButton:setEnable(self.resultCheckedCount > 0)
end

-- 批量加入勾選項：覆寫目標先全部驗過數值再一起加（原子性——一個非法全不加、
-- 勾選保留，改好數值再按一次即可）
function MinidoracatCleanerPicker:onAddChecked()
    if self.resultCheckedCount <= 0 then
        return
    end
    local values = {}
    for value in pairs(self.resultCheckedSet) do
        values[#values + 1] = value
    end
    Cleaner.sortSafe(values, function(a, b) return a < b end)
    local withValue = self.targetDef and self.targetDef.withValue == true
    local tokens = {}
    for _, value in ipairs(values) do
        local token = value
        if withValue then
            token = Cleaner.buildLimitToken(value, self.valueEntry and self.valueEntry:getText() or "")
            if not token then
                Skin.notify(self.playerObj, getText("IGUI_MinidoracatCleaner_PickerBadValue"), "error")
                return
            end
        end
        tokens[#tokens + 1] = token
    end
    for _, token in ipairs(tokens) do
        self:upsertToken(token)
    end
    self.resultCheckedSet = {}
    self.resultCheckedCount = 0
    self:updateAddButton()
    self:refreshSelected()
    self:refreshResults()
end


-- 點「目前清單」列＝勾選/取消（批量設值或移除的選取——點一下就刪太容易誤觸）
function MinidoracatCleanerPicker:onSelectedClick(item)
    if not (item and item.value) then
        return
    end
    if self.listCheckedSet[item.value] then
        self.listCheckedSet[item.value] = nil
        self.listCheckedCount = self.listCheckedCount - 1
    else
        self.listCheckedSet[item.value] = true
        self.listCheckedCount = self.listCheckedCount + 1
    end
    self:updateBatchButtons()
    -- VirtualList cell 每幀直查 listCheckedSet；退回清單的勾選是文字前綴，要重組
    if self.selectedList and not self.selectedList.isVirtual then
        self:refreshSelected()
    end
end

function MinidoracatCleanerPicker:updateBatchButtons()
    local n = tostring(self.listCheckedCount)
    if self.setValueButton then
        self.setValueButton:setTitle(getText("IGUI_MinidoracatCleaner_PickerSetValue", n))
        self.setValueButton:setEnable(self.listCheckedCount > 0
            and self.targetDef ~= nil and self.targetDef.withValue == true)
    end
    if self.removeButton then
        self.removeButton:setTitle(getText("IGUI_MinidoracatCleaner_PickerRemoveChecked", n))
        self.removeButton:setEnable(self.listCheckedCount > 0)
    end
end

-- 批量設值：勾選項的 group 全部改成上限值欄的數值（原子性——數值非法整批不動、
-- 勾選保留，改好數值再按一次即可）
function MinidoracatCleanerPicker:onSetValueChecked()
    if self.listCheckedCount <= 0 or not (self.targetDef and self.targetDef.withValue) then
        return
    end
    local rawValue = self.valueEntry and self.valueEntry:getText() or ""
    local keys = {}
    for token in pairs(self.listCheckedSet) do
        keys[#keys + 1] = Cleaner.tokenKey(token)
    end
    Cleaner.sortSafe(keys, function(a, b) return a < b end)
    local tokens = {}
    for _, key in ipairs(keys) do
        local token = Cleaner.buildLimitToken(key, rawValue)
        if not token then
            Skin.notify(self.playerObj, getText("IGUI_MinidoracatCleaner_PickerBadValue"), "error")
            return
        end
        tokens[#tokens + 1] = token
    end
    for _, token in ipairs(tokens) do
        self:upsertToken(token)
    end
    self.listCheckedSet = {}
    self.listCheckedCount = 0
    self:updateBatchButtons()
    self:refreshSelected()
end

-- 批量移除勾選項
function MinidoracatCleanerPicker:onRemoveChecked()
    if self.listCheckedCount <= 0 then
        return
    end
    for token in pairs(self.listCheckedSet) do
        local key = Cleaner.tokenKey(token)
        if self.selectedSet[key] then
            self.selectedSet[key] = nil
            for index, existing in ipairs(self.selectedValues) do
                if existing == token then
                    table.remove(self.selectedValues, index)
                    break
                end
            end
        end
    end
    self.listCheckedSet = {}
    self.listCheckedCount = 0
    self:updateBatchButtons()
    self:refreshSelected()
    self:refreshResults()
end

-- ============ 套用／複製 ============

-- 與封包層守門一致：SandboxOptions 封包要求 Capability.SandboxOptions
-- （PacketTypes.java:411；enum Capability.java:81），UI gate 鏡射 ISAdminPanelUI.lua:226。
-- SP 無連線守門、直接放行；此檔是 client 檔，isServer() 分支僅防禦。
function MinidoracatCleanerPicker:computeApplyAllowed()
    if not isClient() and not isServer() then
        return true
    end
    if not isClient() then
        return false
    end
    local role = self.playerObj and self.playerObj.getRole and self.playerObj:getRole()
    return role ~= nil and role:hasCapability(Capability.SandboxOptions) == true
end

function MinidoracatCleanerPicker:onApply()
    local def = self.targetDef
    if not def or not self.applyAllowed then
        return
    end
    local live = getSandboxOptions()
    local fullName = Cleaner.MOD_ID .. "." .. def.key
    -- set() 對未知選項名直接拋 IllegalArgumentException（SandboxOptions.java:572-583），
    -- 先 getOptionByName（:568）守住（例如殘留 UI 撞上未載入本 MOD 沙盒宣告的存檔）
    if not (live and live:getOptionByName(fullName)) then
        Skin.notify(self.playerObj, getText("IGUI_MinidoracatCleaner_PickerApplyFailed"), "error")
        return
    end
    local csv = table.concat(self.selectedValues, ",")
    -- 本地立即生效：vanilla 沙盒面板同款（ISServerSandboxOptionsUI.lua:739）
    live:set(fullName, csv)
    if isClient() then
        -- MP：整份現值送 server（copy→sendToServer，vanilla :794-795,:773；
        -- SandboxOptions.java:585 copyValuesFrom、:1107 sendToServer）。
        -- server 端 receiveSandboxOptions 落盤並廣播全 client（GameServer.java:1693-1706）
        local packet = SandboxOptions.new()
        packet:copyValuesFrom(live)
        packet:sendToServer()
    end
    Skin.notify(self.playerObj,
        getText("IGUI_MinidoracatCleaner_PickerApplied", tostring(#self.selectedValues)), "ok")
end

function MinidoracatCleanerPicker:onCopy()
    if #self.selectedValues == 0 then
        return
    end
    local text = table.concat(self.selectedValues, ",")
    Clipboard.setClipboard(text) -- ISSpawnPointsEditor.lua:270
    Skin.notify(self.playerObj, getText("IGUI_MinidoracatCleaner_PickerCopied"), "ok")
end

function MinidoracatCleanerPicker:onClear()
    self.selectedValues = {}
    self.selectedSet = {}
    self.listCheckedSet = {}
    self.listCheckedCount = 0
    self.resultCheckedSet = {}
    self.resultCheckedCount = 0
    self:updateAddButton()
    self:updateBatchButtons()
    self:refreshSelected()
    self:refreshResults()
end

function MinidoracatCleanerPicker:close()
    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
    if MinidoracatCleanerPicker.instance == self then
        MinidoracatCleanerPicker.instance = nil
    end
end

-- ============ 批量生成動物（測試用 admin 工具） ============

-- group 的第一個 breed 名（AnimalDefinitions.breeds["rat"].breeds["grey"]，RatDefinitions.lua:19）
local function firstBreedName(group)
    local groupBreeds = AnimalDefinitions.breeds and AnimalDefinitions.breeds[group]
    groupBreeds = groupBreeds and groupBreeds.breeds
    if type(groupBreeds) ~= "table" then
        return nil
    end
    local names = {}
    for name in pairs(groupBreeds) do
        names[#names + 1] = tostring(name)
    end
    Cleaner.sortSafe(names, function(a, b) return a < b end)
    return names[1]
end

local function buildSpawnTypeList()
    local list = {}
    local defs = AnimalDefinitions and AnimalDefinitions.animals
    if type(defs) == "table" then
        for animalType, def in pairs(defs) do
            local group = def and def.group
            local breedName = group and firstBreedName(tostring(group))
            if breedName then
                local key = "IGUI_AnimalType_" .. tostring(animalType)
                local translated = getText(key)
                local label = (translated ~= key) and translated or tostring(animalType)
                list[#list + 1] = {
                    type = tostring(animalType),
                    breedName = breedName,
                    label = label .. "  \194\183  " .. tostring(animalType),
                }
            end
        end
    end
    Cleaner.sortSafe(list, function(a, b) return a.label < b.label end)
    return list
end

-- 生成序列照抄 vanilla DebugContextMenu.AddAnimal（DebugContextMenu.lua:1454-1473）；
-- MP 由 server 端 Commands.animal.add 執行（ClientCommands.lua:723-731，AnimalCheats 權限 gate）
local function doBatchSpawn(playerObj, square, animalType, breedName, count)
    if not playerObj or not square then
        return
    end
    for _ = 1, count do
        if isClient() then
            sendClientCommandV(playerObj, "animal", "add",
                "type", animalType,
                "breed", breedName,
                "x", square:getX(),
                "y", square:getY(),
                "z", square:getZ(),
                "skeleton", false)
        else
            local breed = AnimalDefinitions.getDef(animalType):getBreedByName(breedName)
            local animal = addAnimal(getCell(), square:getX(), square:getY(), square:getZ(),
                animalType, breed, false)
            animal:addToWorld()
        end
    end
    playerObj:setHaloNote(getText("IGUI_MinidoracatCleaner_BatchSpawned", tostring(count), animalType), 120, 255, 120, 240)
end

local SPAWN_COUNTS = { 10, 25, 50, 100 }

local function addBatchSpawnMenu(playerObj, context, square)
    local option = context:addOption(getText("IGUI_MinidoracatCleaner_BatchSpawn"), nil, nil)
    local typeMenu = ISContextMenu:getNew(context)
    context:addSubMenu(option, typeMenu)
    for _, entry in ipairs(buildSpawnTypeList()) do
        local typeOption = typeMenu:addOption(entry.label, nil, nil)
        local countMenu = ISContextMenu:getNew(typeMenu)
        typeMenu:addSubMenu(typeOption, countMenu)
        for _, count in ipairs(SPAWN_COUNTS) do
            countMenu:addOption("x" .. tostring(count), playerObj, doBatchSpawn,
                square, entry.type, entry.breedName, count)
        end
    end
end

-- ============ 右鍵選單入口 ============

-- SP／debug／admin/moderator 限定（gate 模式抄 AdminContextMenu.lua:21-22）
local function onFillWorldMenu(player, context, worldobjects, test)
    if test then
        return
    end
    local isSP = not isClient() and not isServer()
    local allowed = isSP or isDebugEnabled()
        or (isClient() and (isAdmin() or getAccessLevel() == "moderator"))
    if not allowed then
        return
    end
    local playerObj = getSpecificPlayer(player)
    context:addOption(getText("IGUI_MinidoracatCleaner_PickerOpen"),
        playerObj, MinidoracatCleanerPicker.open)
    local square = nil
    for _, worldObject in ipairs(worldobjects) do
        square = worldObject:getSquare()
        if square then
            break
        end
    end
    -- 批量生成純屬作弊／測試工具，預設不掛在右鍵選單上（單人玩家嫌它礙眼且破壞體驗）。
    -- 單人開了 -debug 本來就有原版的生成選單（DebugContextMenu.lua:30 以 isDebugEnabled()
    -- 放行，:280 掛上 AddAnimal），多這一項零額外曝險故照舊顯示。MP 端原版走的是
    -- UseDebugContextMenu capability（:26-28），與這裡的判斷無關。
    if square and playerObj
        and (isDebugEnabled() or Cleaner.getOption("DebugMenuEnabled") == true) then
        addBatchSpawnMenu(playerObj, context, square)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldMenu)
