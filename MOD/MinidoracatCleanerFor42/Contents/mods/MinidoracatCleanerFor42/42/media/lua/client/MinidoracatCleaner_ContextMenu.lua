require "MinidoracatCleaner_Core"
require "MinidoracatCleaner_Skin"
require "ISUI/ISInventoryPane"

local Cleaner = MinidoracatCleaner
local Skin = MinidoracatCleanerSkin
-- 確認框最多列幾種、膠囊框最多列幾顆；其餘併成一列「還有 N 種／顆」
local CONFIRM_ROWS = 8
local CAPSULE_ROWS = 8

local function deleteLocally(playerObj, items)
    local removedByType = {}
    local removed = 0
    local contained = 0
    for _, item in ipairs(items) do
        if Cleaner.canManuallyDelete(playerObj, item) then
            local inside = Cleaner.containedCount(item)
            local deleted = false
            local worldObj = item:getWorldItem()
            if worldObj and worldObj:getSquare() then
                deleted = Cleaner.removeFloorItem(item, worldObj, worldObj:getSquare())
            else
                deleted = Cleaner.removeContainerItem(item, item:getContainer())
            end
            if deleted then
                removed = removed + 1
                contained = contained + inside
                local fullType = item:getFullType()
                removedByType[fullType] = (removedByType[fullType] or 0) + 1
            end
        end
    end
    Cleaner.logManualDelete(playerObj, removedByType, removed, contained)
end

local function sendDelete(playerNum, items)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then
        return
    end
    if isClient() then
        local ids = {}
        for _, item in ipairs(items) do
            ids[#ids + 1] = item:getID()
        end
        sendClientCommand(playerObj, Cleaner.COMMAND_MODULE, "deleteItems", { ids = ids })
    else
        deleteLocally(playerObj, items)
    end
end

-- 主框的內文：逐項列出（Core.deleteSummary），有已收膠囊（或沒看完的袋子）時預告下一步，
-- 最後寫超過一次上限而不刪的件數、被略過的件數
local function summaryText(items, skipped, over, found, unchecked)
    local rows = Cleaner.deleteSummary(items)
    local lines = {}
    for i = 1, math.min(#rows, CONFIRM_ROWS) do
        local row = rows[i]
        if row.contained > 0 then
            lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmRowContains", row.name, tostring(row.count),
                tostring(row.contained))
        else
            lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmRow", row.name, tostring(row.count))
        end
    end
    if #rows > CONFIRM_ROWS then
        local rest, inside = 0, 0
        for i = CONFIRM_ROWS + 1, #rows do
            rest = rest + rows[i].count
            inside = inside + rows[i].contained
        end
        local kinds = tostring(#rows - CONFIRM_ROWS)
        if inside > 0 then
            lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmMoreContains", kinds, tostring(rest),
                tostring(inside))
        else
            lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmMore", kinds, tostring(rest))
        end
    end
    lines[#lines + 1] = ""
    if #found > 0 then
        lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmCapsuleNext")
    elseif unchecked then
        lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmUncheckedNext")
    end
    if over > 0 then
        lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmOverLimit",
            tostring(Cleaner.CONSTANTS.MANUAL_DELETE_LIMIT), tostring(over))
    end
    if skipped > 0 then
        lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmSkipped", tostring(skipped))
    end
    lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_ConfirmUndo")
    return table.concat(lines, "\n")
end

-- 膠囊框的內文：每顆點名（PackThrow 客戶端已把名字改成「膠囊：車名／動物名」，client/Info.lua），
-- 袋子裡的寫出在哪個袋子；走訪額度用完時加一句「沒檢查完」
local function capsuleText(found, unchecked)
    local lines = {}
    for i = 1, math.min(#found, CAPSULE_ROWS) do
        local entry = found[i]
        local name = entry.item:getDisplayName()
        if entry.holder then
            name = getText("IGUI_MinidoracatCleaner_CapsuleInBag", name, entry.holder:getDisplayName())
        end
        if entry.kind == "animal" then
            lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_CapsuleAnimal", name)
        else
            lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_CapsuleVehicle", name)
        end
    end
    if #found > CAPSULE_ROWS then
        lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_CapsuleMore", tostring(#found - CAPSULE_ROWS))
    end
    if unchecked then
        lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_CapsuleUnchecked")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_CapsuleWarn")
    return table.concat(lines, "\n")
end

-- 選取（頂層）裡有沒有裝著東西的容器：刪它會連物品欄看不到的內容一起刪，要確認
local function anyHasContents(items)
    for _, item in ipairs(items) do
        if Cleaner.hasContents(item) then
            return true
        end
    end
    return false
end

-- 不跳框直接刪時，主框原本寫的「不會刪除」改成右上角提示（同兩條譯文）
local function notifyLeftOut(playerNum, skipped, over)
    local playerObj = getSpecificPlayer(playerNum)
    if over > 0 then
        Skin.notify(playerObj, getText("IGUI_MinidoracatCleaner_ConfirmOverLimit",
            tostring(Cleaner.CONSTANTS.MANUAL_DELETE_LIMIT), tostring(over)))
    end
    if skipped > 0 then
        Skin.notify(playerObj, getText("IGUI_MinidoracatCleaner_ConfirmSkipped", tostring(skipped)))
    end
end

-- 只有選取裡（含袋子裡）有 PackThrow 的已收膠囊、袋子沒檢查完，或有裝著東西的容器時才確認；
-- 一般物品直接刪（2026-11-02 使用者裁定：手動刪除很頻繁，每次都跳框只會被直接按掉）。
-- 確認分兩段：主框逐項列出；有膠囊時主框按刪除後再跳膠囊框，點名整台車或動物，兩個都按刪除才送出。
-- 膠囊框按取消＝這一批都不刪。伺服器不擋膠囊（2026-11-02 使用者裁定：照舊能刪、另跳確認框、按鈕確認不打字）。
-- 框不擋操作，開著時玩家照常能搬東西（例如把膠囊放進要刪的袋子）：每個框按刪除時重算一次，
-- 和框上寫的不一樣就從頭重新確認，不照開框時的內容送出
local function showDeleteDialog(items, playerNum, skipped, over)
    if #items == 0 or not getSpecificPlayer(playerNum) then
        return
    end
    skipped, over = skipped or 0, over or 0
    local found, unchecked = Cleaner.findLoadedCapsules(items)
    if #found == 0 and not unchecked and not anyHasContents(items) then
        sendDelete(playerNum, items)
        notifyLeftOut(playerNum, skipped, over)
        return
    end
    local text = summaryText(items, skipped, over, found, unchecked)
    -- 回傳現在的膠囊清單；主框（與 capText，膠囊框的內文）和看到的不一樣時從頭重新確認，回傳 nil
    local function recheck(capText)
        local nowFound, nowUnchecked = Cleaner.findLoadedCapsules(items)
        if summaryText(items, skipped, over, nowFound, nowUnchecked) ~= text
            or (capText and capsuleText(nowFound, nowUnchecked) ~= capText) then
            showDeleteDialog(items, playerNum, skipped, over)
            return nil
        end
        return nowFound, nowUnchecked
    end
    Skin.confirm({
        playerNum = playerNum,
        title = getText("IGUI_MinidoracatCleaner_ConfirmTitle", tostring(#items)),
        text = text,
        confirmText = getText("IGUI_MinidoracatCleaner_ConfirmButton", tostring(#items)),
        cancelText = getText("UI_Cancel"),
        onResult = function(ok)
            if not ok then
                return
            end
            local nowFound, nowUnchecked = recheck(nil)
            if not nowFound then
                return
            end
            if #nowFound == 0 and not nowUnchecked then
                sendDelete(playerNum, items)
                return
            end
            local capText = capsuleText(nowFound, nowUnchecked)
            Skin.confirm({
                playerNum = playerNum,
                title = getText(#nowFound > 0 and "IGUI_MinidoracatCleaner_CapsuleTitle"
                    or "IGUI_MinidoracatCleaner_CapsuleUncheckedTitle"),
                text = capText,
                confirmText = getText("IGUI_MinidoracatCleaner_CapsuleButton"),
                cancelText = getText("UI_Cancel"),
                onResult = function(sure)
                    if sure and recheck(capText) then
                        sendDelete(playerNum, items)
                    end
                end,
            })
        end,
    })
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    if isClient() and Cleaner.getOption("AllowManualDelete") == false then
        return
    end

    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then
        return
    end

    -- ISInventoryPane.lua:908-930
    local actualItems = ISInventoryPane.getActualItems(items)
    local deletable = {}
    local skipped = 0 -- 最愛、裝備中：主框或通知寫出「不會刪除 N 件」。可刪的滿上限後照樣數完
    local over = 0 -- 可刪但超過一次上限 MANUAL_DELETE_LIMIT：這次不帶進去，主框或通知寫出件數
    for _, item in ipairs(actualItems) do
        if not Cleaner.canManuallyDelete(playerObj, item) then
            skipped = skipped + 1
        elseif #deletable < Cleaner.CONSTANTS.MANUAL_DELETE_LIMIT then
            deletable[#deletable + 1] = item
        else
            over = over + 1
        end
    end

    if #deletable == 0 then
        return
    end

    local label
    if #deletable == 1 then
        label = getText("IGUI_MinidoracatCleaner_Delete", deletable[1]:getDisplayName())
    else
        label = getText("IGUI_MinidoracatCleaner_DeleteMulti", #deletable)
    end
    local option = context:addOption(label, deletable, showDeleteDialog, playerNum, skipped, over)
    -- 一般物品不跳確認框，用原版垃圾袋圖示和其他選項區隔（寫法同原版 ISFarmingMenu.lua:123）；
    -- 不用紅字：原版選單的紅字是「不能用」（ISContextMenu.lua:441-472）
    option.iconTexture = getTexture("Item_Garbagebag")
end

-- ===== 家具放置紀錄（MP）=====
-- 資料在 server（WorldAudit.lua），右鍵才查、只回給自己。只列出該格目前仍存在的 sprite：
-- 非搬移路徑（打壞、燒掉）消失的物件不會清掉 server 那筆，靠這裡過濾
local function spritesOn(square)
    local present = {}
    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local sprite = object:getSprite()
        if sprite and sprite:getName() and not object:isFloor() then
            present[sprite:getName()] = true
        end
    end
    return present
end

function Cleaner.showPlacedInfo(args)
    local playerObj = getPlayer()
    if not playerObj or type(args) ~= "table" then
        return
    end
    local square = getCell():getGridSquare(args.x, args.y, args.z)
    local present = square and spritesOn(square) or {}
    local lines = {}
    for sprite, value in pairs(type(args.entries) == "table" and args.entries or {}) do
        local name, at = tostring(value):match("^(.*),(%d*)$")
        if present[sprite] and name then
            local timeText = tonumber(at) and Cleaner.formatStampTime and Cleaner.formatStampTime(tonumber(at))
            lines[#lines + 1] = getText("IGUI_MinidoracatCleaner_PlacedBy", name, timeText or "?")
        end
    end
    if #lines == 0 then
        lines[1] = getText("IGUI_MinidoracatCleaner_PlacedNone")
    end
    playerObj:setHaloNote(table.concat(lines, " / "), 220, 220, 120, 300)
end

local function onPlacedQuery(playerNum, square)
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj then
        sendClientCommand(playerObj, Cleaner.COMMAND_MODULE, "placedQuery",
            { x = square:getX(), y = square:getY(), z = square:getZ() })
    end
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test or not isClient() then
        return
    end
    for _, object in ipairs(worldobjects) do
        local square = object.getSquare and object:getSquare()
        if square then
            for _ in pairs(spritesOn(square)) do
                context:addOption(getText("IGUI_MinidoracatCleaner_PlacedQuery"), playerNum, onPlacedQuery, square)
                return
            end
            return
        end
    end
end

-- ISWorldObjectContextMenu.lua createMenu 觸發
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- LuaEventManager.java:617
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
