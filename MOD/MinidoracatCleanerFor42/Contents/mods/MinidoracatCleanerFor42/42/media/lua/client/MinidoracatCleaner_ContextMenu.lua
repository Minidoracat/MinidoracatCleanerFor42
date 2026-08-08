require "MinidoracatCleaner_Core"
require "ISUI/ISInventoryPane"
require "ISUI/ISModalDialog"

local Cleaner = MinidoracatCleaner
local deleteDialog = nil

local function deleteLocally(playerObj, items)
    local removedByType = {}
    local removed = 0
    for _, item in ipairs(items) do
        if Cleaner.canManuallyDelete(playerObj, item) then
            local deleted = false
            local worldObj = item:getWorldItem()
            if worldObj and worldObj:getSquare() then
                deleted = Cleaner.removeFloorItem(item, worldObj, worldObj:getSquare())
            else
                deleted = Cleaner.removeContainerItem(item, item:getContainer())
            end
            if deleted then
                removed = removed + 1
                local fullType = item:getFullType()
                removedByType[fullType] = (removedByType[fullType] or 0) + 1
            end
        end
    end

    if removed > 0 then
        local details = {}
        for fullType, count in pairs(removedByType) do
            details[#details + 1] = Cleaner.sanitize(fullType) .. "=" .. count
        end
        table.sort(details)
        local square = playerObj:getCurrentSquare()
        Cleaner.log(
            "manual_delete",
            playerObj:getUsername(),
            square and square:getX() or 0,
            square and square:getY() or 0,
            square and square:getZ() or 0,
            "removed=" .. removed .. " types=" .. table.concat(details, ",")
        )
    end
end

local function onConfirmDelete(_, button, playerNum, items)
    deleteDialog = nil
    if button.internal ~= "YES" then
        return
    end

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

local function showDeleteDialog(items, playerNum)
    if deleteDialog then
        deleteDialog:destroy()
        deleteDialog = nil
    end

    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or #items == 0 then
        return
    end

    local width = 350
    local height = 120
    local x = getPlayerScreenLeft(playerNum) + (getPlayerScreenWidth(playerNum) - width) / 2
    local y = getPlayerScreenTop(playerNum) + (getPlayerScreenHeight(playerNum) - height) / 2
    local itemName = items[1]:getDisplayName()
    local text = getText("IGUI_MinidoracatCleaner_ConfirmDelete", itemName, #items)
    -- ISModalDialog.lua:187-210; ISInventoryPane.lua:656-671
    deleteDialog = ISModalDialog:new(
        x,
        y,
        width,
        height,
        text,
        true,
        nil,
        onConfirmDelete,
        playerNum,
        playerNum,
        items
    )
    deleteDialog:initialise()
    deleteDialog:addToUIManager()
    if JoypadState.players[playerNum + 1] then
        deleteDialog.prevFocus = JoypadState.players[playerNum + 1].focus
        setJoypadFocus(playerNum, deleteDialog)
    end
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
    for _, item in ipairs(actualItems) do
        if Cleaner.canManuallyDelete(playerObj, item) then
            deletable[#deletable + 1] = item
            if #deletable >= Cleaner.CONSTANTS.MANUAL_DELETE_LIMIT then
                break
            end
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
    context:addOption(label, deletable, showDeleteDialog, playerNum)
end

-- LuaEventManager.java:617
Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
