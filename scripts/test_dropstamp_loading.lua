-- lua scripts/test_dropstamp_loading.lua [原版 media/lua 路徑]
-- 真正載入原版動作與 Core/DropStamp；只替 Java 物件提供本情境會用到的方法。
-- 搜尋路徑依 LuaManager.java:1133-1137,1204-1206,1243-1246,5675-5690 分階段加入。
-- dedicated 的 client 階段只登錄路徑、不執行（GameServer.java:1454-1456）。
local vanilla = arg[1] or os.getenv("PZ_LUA_PATH")
    or "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua"
local media = "MOD/MinidoracatCleanerFor42/Contents/mods/MinidoracatCleanerFor42/42/media/lua"
local failures = 0
local function check(ok, label)
    if not ok then failures = failures + 1 end
    print((ok and "PASS " or "FAIL ") .. label)
end

for _, mode in ipairs({ "SP", "MP client", "dedicated" }) do
    local paths, loaded, warnings, handlers = { "shared" }, {}, {}, {}
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.isClient = function() return mode == "MP client" end
    env.isServer = function() return mode == "dedicated" end
    env.getTimestamp = function() return 7201 end
    env.SandboxVars = { MinidoracatCleanerFor42 = {} }
    env.Events = setmetatable({}, { __index = function(_, name)
        handlers[name] = handlers[name] or {}
        return { Add = function(fn) table.insert(handlers[name], fn) end }
    end })
    local function run(path)
        if loaded[path] then return end
        local chunk = assert(loadfile(path, "t", env))
        loaded[path] = true
        chunk()
    end
    env.require = function(name)
        for _, dir in ipairs(paths) do
            for _, root in ipairs({ vanilla, media }) do
                local path = root .. "/" .. dir .. "/" .. name .. ".lua"
                local file = io.open(path, "rb")
                if file then
                    file:close()
                    return run(path)
                end
            end
        end
        -- 與引擎一樣：找不到會記警告並回 nil，不拋錯，也不假裝成功。
        warnings[#warnings + 1] = name
        return nil
    end
    local function fire(name, ...)
        for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    end
    -- 同一目錄的原版檔先於 MOD；client-only 類別此時確實尚未存在。
    for _, name in ipairs({ "ISDropWorldItemAction", "ISDropVehicleItemAction", "ISTransferAction" }) do
        run(vanilla .. "/shared/TimedActions/" .. name .. ".lua")
    end
    check(env.ISGrabItemAction == nil, mode .. ": shared 階段沒有撿取類別")
    run(media .. "/shared/MinidoracatCleaner_DropStamp.lua")
    check(#warnings == 0, mode .. ": shared 載入零失敗 require [" .. table.concat(warnings, ", ") .. "]")
    paths[#paths + 1] = "client"
    if mode ~= "dedicated" then
        run(vanilla .. "/client/TimedActions/ISGrabItemAction.lua")
    end
    paths[#paths + 1] = "server"
    fire(mode == "dedicated" and "OnServerStarted" or "OnGameStart")
    -- 兩個啟動事件重複到達也不能重複掛交易 callback。
    fire("OnGameStart")
    fire("OnServerStarted")
    if mode == "MP client" then
        check(#(handlers.OnProcessTransaction or {}) == 0 and not env.MinidoracatCleaner._dropHooksInstalled,
            mode .. ": 不安裝權威蓋章 hook，保留 Client 回報路徑")
    else
        check(#(handlers.OnProcessTransaction or {}) == 1, mode .. ": 交易 hook 恰好註冊一次")
        if mode == "dedicated" then
            check(env.ISGrabItemAction == nil, mode .. ": 不因啟動事件載入 client-only 類別")
        end
        local cleaner = env.MinidoracatCleaner
        local dirty = 0
        local square = {}
        cleaner.markDirty = function(sq)
            assert(sq == square, "wrong dirty square")
            dirty = dirty + 1
        end
        local inventory = {
            getType = function() return "inventory" end,
            getParent = function() return nil end,
            setDrawDirty = function() end,
            AddItem = function(self, item) self.item = item end,
            Remove = function(self, item) assert(self.item == item); self.item = nil end,
        }
        inventory.DoRemoveItem = inventory.Remove
        local character = {
            getUsername = function() return "tester" end,
            getPlayerNum = function() return 0 end,
            getInventory = function() return inventory end,
        }
        inventory.getCharacter = function() return character end
        local function item()
            local md = {}
            return {
                getModData = function() return md end,
                hasModData = function() return true end,
                getType = function() return "Stone" end,
                getWorldItem = function(self) return self.world end,
                setWorldItem = function(self, world) self.world = world end,
                setJobDelta = function() end,
                setWorldZRotation = function() end,
            }
        end
        square.AddWorldInventoryItem = function(_, obj)
            obj.world = {
                getItem = function() return obj end,
                getSquare = function() return square end,
                setIgnoreRemoveSandbox = function() end,
                setExtendedPlacement = function() end,
                transmitCompleteItemToClients = function() end,
                removeFromWorld = function() end,
                removeFromSquare = function() end,
                setSquare = function() end,
            }
            return obj
        end
        square.transmitRemoveItemFromSquare = function() end
        env.instanceof = function() return false end -- fixture 是 Stone，非 Radio。
        env.sendRemoveItemFromContainer = function() end
        env.removeItemTransaction = function() end
        env.getPlayerData = function() return nil end
        local function stamped(obj)
            local who, when = cleaner.readTouch(obj)
            return cleaner.readDrop(obj) == "tester" and who == "tester" and when == 7200
        end
        for _, name in ipairs({ "ISDropWorldItemAction", "ISDropVehicleItemAction" }) do
            local obj = item()
            inventory.item = obj
            local before = dirty
            local result = env[name].complete({ item = obj, character = character, sq = square, dropSquare = square })
            check(result == true and inventory.item == nil and obj.world and stamped(obj) and dirty == before + 1,
                mode .. ": 原版 " .. name .. " 移出物品、雙章與 dirty 均保留")
        end
        local obj = item()
        local before = dirty
        fire("OnProcessTransaction", "dropOnFloor", character, obj, nil, nil, { square = square })
        check(stamped(obj) and dirty == before + 1, mode .. ": dropOnFloor 事件雙章與 dirty 保留")
        env.SandboxVars.MinidoracatCleanerFor42.TouchTraceEnabled = false
        obj = item()
        before = dirty
        fire("OnProcessTransaction", "dropOnFloor", character, obj, nil, nil, { square = square })
        check(cleaner.readTouch(obj) == nil and cleaner.readDrop(obj) == nil and dirty == before + 1,
            mode .. ": 關追蹤仍標 dirty、不蓋章")
        env.SandboxVars.MinidoracatCleanerFor42.TouchTraceEnabled = true
        if mode == "SP" then
            obj = item()
            local source = {
                getType = function() return "counter" end,
                getCharacter = function() return nil end,
                getParent = function() return nil end,
                DoRemoveItem = function(self, value) assert(self.item == value); self.item = nil end,
                item = obj,
            }
            local result = env.ISTransferAction:transferItem(character, obj, source, inventory)
            check(result == obj and source.item == nil and inventory.item == obj and cleaner.readTouch(obj) == "tester",
                "SP: 原版容器搬移仍蓋操作者章")
            obj = item()
            square:AddWorldInventoryItem(obj)
            env.ISGrabItemAction.transferItem({ item = obj.world, character = character, destContainer = inventory }, obj.world)
            check(obj.world == nil and inventory.item == obj and cleaner.readTouch(obj) == "tester",
                "SP: client 階段載入後，原版撿取與操作者章均生效")
        end
    end
end
assert(failures == 0, failures .. " 個載入／蓋章回歸失敗")
print("DropStamp 載入回歸全部通過")
