-- 清單產生器：關鍵字搜尋（客戶端語言）→ 挑選 → 產生精確值 CSV → 複製到剪貼簿貼進沙盒選項
-- UI 模式抄 admin 物品清單檢視器（ISItemsListTable/ISItemsListViewer）；getAllItems: ISItemsListViewer.lua:42
require "MinidoracatCleaner_Core"
require "ISUI/ISCollapsableWindow"

local Cleaner = MinidoracatCleaner

MinidoracatCleanerPicker = ISCollapsableWindow:derive("MinidoracatCleanerPicker")
MinidoracatCleanerPicker.instance = nil

local PAD = 8
local ROW = 24

function MinidoracatCleanerPicker.open(playerObj)
    if MinidoracatCleanerPicker.instance then
        MinidoracatCleanerPicker.instance:close()
    end
    local window = MinidoracatCleanerPicker:new(120, 100, 620, 560, playerObj)
    window:initialise()
    window:addToUIManager()
    MinidoracatCleanerPicker.instance = window
end

function MinidoracatCleanerPicker:new(x, y, width, height, playerObj)
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    o.playerObj = playerObj
    o.title = getText("IGUI_MinidoracatCleaner_PickerTitle")
    o.mode = "items"
    o.selectedValues = {}
    o.selectedSet = {}
    o.itemCache = nil
    o.resizable = false
    o.lastSearchText = ""
    return o
end

function MinidoracatCleanerPicker:createChildren()
    ISCollapsableWindow.createChildren(self)
    local y = self:titleBarHeight() + PAD
    local innerWidth = self.width - PAD * 2

    -- 模式切換（ISComboBox.lua:586,435,475）
    self.modeCombo = ISComboBox:new(PAD, y, 240, ROW, self, MinidoracatCleanerPicker.onModeChange)
    self.modeCombo:initialise()
    self:addChild(self.modeCombo)
    self.modeCombo:addOptionWithData(getText("IGUI_MinidoracatCleaner_PickerModeItems"), "items")
    self.modeCombo:addOptionWithData(getText("IGUI_MinidoracatCleaner_PickerModeAnimals"), "animals")
    y = y + ROW + PAD

    -- 搜尋框：不用 onTextChange（IME 組字送出不會觸發），改由 prerender 每 frame 輪詢文字變化
    self.searchEntry = ISTextEntryBox:new("", PAD, y, innerWidth, ROW)
    self.searchEntry:initialise()
    self.searchEntry:instantiate()
    self:addChild(self.searchEntry)
    y = y + ROW + 2

    -- 操作說明（常駐）
    self.hintLabel = ISLabel:new(PAD, y, 18, getText("IGUI_MinidoracatCleaner_PickerHint"), 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.hintLabel:initialise()
    self:addChild(self.hintLabel)
    y = y + 18 + PAD

    -- 搜尋結果（雙擊加入；setOnMouseDoubleClick: ISItemsListTable.lua:96）
    local resultsHeight = 240
    self.resultsList = ISScrollingListBox:new(PAD, y, innerWidth, resultsHeight)
    self.resultsList:initialise()
    self.resultsList:instantiate()
    self.resultsList.itemheight = ROW
    self.resultsList.font = UIFont.Small
    self.resultsList.drawBorder = true
    self.resultsList:setOnMouseDoubleClick(self, MinidoracatCleanerPicker.onAddEntry)
    self:addChild(self.resultsList)
    y = y + resultsHeight + PAD

    -- 已選清單（雙擊移除）
    local selectedHeight = 96
    self.selectedList = ISScrollingListBox:new(PAD, y, innerWidth, selectedHeight)
    self.selectedList:initialise()
    self.selectedList:instantiate()
    self.selectedList.itemheight = ROW
    self.selectedList.font = UIFont.Small
    self.selectedList.drawBorder = true
    self.selectedList:setOnMouseDoubleClick(self, MinidoracatCleanerPicker.onRemoveEntry)
    self:addChild(self.selectedList)
    y = y + selectedHeight + PAD

    self.countLabel = ISLabel:new(PAD, y, ROW, "", 1, 1, 1, 1, UIFont.Small, true)
    self.countLabel:initialise()
    self:addChild(self.countLabel)

    self.copyButton = ISButton:new(self.width - PAD - 260, y, 170, ROW,
        getText("IGUI_MinidoracatCleaner_PickerCopy"), self, MinidoracatCleanerPicker.onCopy)
    self.copyButton:initialise()
    self:addChild(self.copyButton)

    self.clearButton = ISButton:new(self.width - PAD - 82, y, 82, ROW,
        getText("IGUI_MinidoracatCleaner_PickerClear"), self, MinidoracatCleanerPicker.onClear)
    self.clearButton:initialise()
    self:addChild(self.clearButton)

    self:refreshResults()
    self:refreshSelected()
end

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
            label = group .. "  \194\183  " .. (names ~= "" and names or group),
            search = entry.search,
        }
    end
    Cleaner.sortSafe(cache, function(a, b) return a.label < b.label end)
    return cache
end

function MinidoracatCleanerPicker:refreshResults()
    self.resultsList:clear()
    local text = string.lower(self.searchEntry and self.searchEntry:getText() or "")
    text = text:match("^%s*(.-)%s*$") or ""
    local entries
    local minChars
    if self.mode == "animals" then
        entries = self:getAnimalEntries()
        minChars = 0
    else
        entries = self:getItemEntries()
        minChars = 2
    end
    if #text < minChars then
        return
    end
    local shown = 0
    for _, entry in ipairs(entries) do
        if text == "" or string.find(entry.search, text, 1, true) then
            if not self.selectedSet[entry.value] then
                self.resultsList:addItem(entry.label, entry)
                shown = shown + 1
                if shown >= 200 then
                    break
                end
            end
        end
    end
end

function MinidoracatCleanerPicker:refreshSelected()
    self.selectedList:clear()
    for _, value in ipairs(self.selectedValues) do
        self.selectedList:addItem(value, value)
    end
    self.countLabel:setName(getText("IGUI_MinidoracatCleaner_PickerSelected", tostring(#self.selectedValues)))
end

-- IME（中文輸入法）組字送出不觸發 onTextChange，改每 frame 比對文字；貼上/刪除也一併涵蓋
function MinidoracatCleanerPicker:prerender()
    ISCollapsableWindow.prerender(self)
    local text = self.searchEntry and self.searchEntry:getText() or ""
    if text ~= self.lastSearchText then
        self.lastSearchText = text
        self:refreshResults()
    end
end

function MinidoracatCleanerPicker:onModeChange()
    local newMode = self.modeCombo:getOptionData(self.modeCombo.selected)
    if newMode ~= self.mode then
        self.mode = newMode
        self.selectedValues = {}
        self.selectedSet = {}
        self.searchEntry:setText("")
        self:refreshResults()
        self:refreshSelected()
    end
end

function MinidoracatCleanerPicker:onAddEntry(item)
    if item and item.value and not self.selectedSet[item.value] then
        self.selectedSet[item.value] = true
        self.selectedValues[#self.selectedValues + 1] = item.value
        self:refreshSelected()
        self:refreshResults()
    end
end

function MinidoracatCleanerPicker:onRemoveEntry(value)
    if value and self.selectedSet[value] then
        self.selectedSet[value] = nil
        for index, existing in ipairs(self.selectedValues) do
            if existing == value then
                table.remove(self.selectedValues, index)
                break
            end
        end
        self:refreshSelected()
        self:refreshResults()
    end
end

function MinidoracatCleanerPicker:onCopy()
    if #self.selectedValues == 0 then
        return
    end
    local text = table.concat(self.selectedValues, ",")
    Clipboard.setClipboard(text) -- ISSpawnPointsEditor.lua:270
    if self.playerObj then
        self.playerObj:setHaloNote(getText("IGUI_MinidoracatCleaner_PickerCopied"), 120, 255, 120, 240)
    end
end

function MinidoracatCleanerPicker:onClear()
    self.selectedValues = {}
    self.selectedSet = {}
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
    if square and playerObj then
        addBatchSpawnMenu(playerObj, context, square)
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldMenu)
