if isClient() then return end

require "MinidoracatCleaner_Core"

local Cleaner = MinidoracatCleaner

local lastCommandAt = {}

local function normalizeIDs(args)
    if not args or type(args.ids) ~= "table" then
        return nil
    end
    local result = {}
    local seen = {}
    local count = 0
    for _, rawID in pairs(args.ids) do
        count = count + 1
        if count > Cleaner.CONSTANTS.MANUAL_DELETE_LIMIT then
            return nil
        end
        local id = tonumber(rawID)
        if id and id >= 0 and id == math.floor(id) and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    return result
end

local function logManualDelete(playerObj, removedByType, removed)
    if removed == 0 then
        return
    end
    local details = {}
    for fullType, count in pairs(removedByType) do
        details[#details + 1] = Cleaner.sanitize(fullType) .. "=" .. count
    end
    Cleaner.sortSafe(details, function(a, b) return a < b end)
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

local function deleteItems(playerObj, args)
    if Cleaner.getOption("AllowManualDelete") == false then
        return
    end
    local ids = normalizeIDs(args)
    if not ids or #ids == 0 then
        return
    end

    -- 整批共用一份索引：舊版每個 id 都要重掃一次周遭（9 格 × 其中每個容器全走訪），
    -- 刪 90 件就是同一份掃描跑 90 遍，而且全在伺服器主執行緒同步做完
    local index = Cleaner.buildAccessibleIndex(playerObj, 1, ids)

    local removedByType = {}
    local removed = 0
    for _, id in ipairs(ids) do
        local found = index[id]
        local item = found and found.item
        if item and Cleaner.canManuallyDelete(playerObj, item) then
            local deleted = false
            if found.kind == "floor" then
                if found.worldObj:getItem() == item and found.worldObj:getSquare() == found.square then
                    deleted = Cleaner.removeFloorItem(item, found.worldObj, found.square)
                end
            elseif found.kind == "container" and item:getContainer() == found.container then
                deleted = Cleaner.removeContainerItem(item, found.container)
            end
            if deleted then
                removed = removed + 1
                local fullType = item:getFullType()
                removedByType[fullType] = (removedByType[fullType] or 0) + 1
            end
        end
    end
    logManualDelete(playerObj, removedByType, removed)
end

local function onClientCommand(module, command, playerObj, args)
    if module ~= Cleaner.COMMAND_MODULE or not playerObj then
        return
    end
    -- per-player 節流：偽造封包每次都會觸發一輪周遭掃描（server 主執行緒），<250ms 直接丟棄
    local key = playerObj:getUsername()
    local now = getTimestampMs()
    local last = lastCommandAt[key]
    if last and now - last < 250 then
        return
    end
    lastCommandAt[key] = now
    if command == "deleteItems" then
        deleteItems(playerObj, args)
    end
end

-- GameServer.java:2243-2294
Events.OnClientCommand.Add(onClientCommand)
