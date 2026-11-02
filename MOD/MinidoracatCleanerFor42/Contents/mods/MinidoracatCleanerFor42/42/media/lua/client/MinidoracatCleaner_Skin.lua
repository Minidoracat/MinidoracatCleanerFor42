-- MinidoracatCleaner_Skin：本 MOD 色票的唯一權威來源＋家族 UI 框架
-- （MinidoracatUIFor42）的 thin adapter。樣板抄 NoticeBoard 的 NBSkin。
--
-- 【退回紅線】框架缺席（未安裝、版本不合、載入失敗）時本 MOD 的 UI 仍要能開——
-- 一律退直角／halo，絕不 error。正式發佈以 mod.info 的 `require=MinidoracatUIFor42`
-- 保證框架先載入（引擎依賴先排 load order，ZomboidFileSystem.java:807-833）；
-- 這裡的動態檢查涵蓋測試 harness 與異常環境。
--
-- 【API 契約】框架同 major 只做 additive 變更；本 MOD 需要 API v1 rev>=1
-- （Skin.fill/border、Widgets/Toast、VirtualList），確認框另用 rev 26 不擋操作的 Dialog
-- （CAPABILITIES.dialog＋dialogModeless）。版本不合＝當框架不存在處理（走退回），不帶半套狀態運行。

if not (MinidoracatUI and MinidoracatUI.v1) then
    -- 測試環境／異常順序防禦：Kahlua require 對缺檔的行為未查證，pcall 包住
    pcall(require, "MinidoracatUI/V1")
    pcall(require, "MinidoracatUI/Widgets/Toast")
    pcall(require, "MinidoracatUI/VirtualList")
    pcall(require, "MinidoracatUI/Widgets/Window")
end
require "ISUI/ISModalDialog"

MinidoracatCleanerSkin = MinidoracatCleanerSkin or {}
local Skin = MinidoracatCleanerSkin

-- 色票（r,g,b,a 皆 0-1 浮點）。值刻意保持字面（不從框架 theme 取）：
-- 框架缺席時色票也要在。數值對齊框架 dark palette（V1.lua DARK），
-- 讓本 MOD 與家族其他視窗同席同色。
Skin.COLORS = {
    BG_PANEL      = { r = 0,    g = 0,    b = 0,    a = 0.8 },  -- surface
    TITLEBAR_FILL = { r = 1,    g = 1,    b = 1,    a = 0.10 }, -- surfaceTitle
    WELL          = { r = 0,    g = 0,    b = 0,    a = 0.5 },  -- well（清單、輸入框底）
    BORDER        = { r = 0.4,  g = 0.4,  b = 0.4,  a = 1.0 },
    TEXT          = { r = 1,    g = 1,    b = 1,    a = 1.0 },
    TEXT_MUTED    = { r = 0.62, g = 0.62, b = 0.62, a = 1.0 },
    ACCENT        = { r = 1,    g = 0.85, b = 0.4,  a = 1.0 },
    HOVER         = { r = 1,    g = 1,    b = 1,    a = 0.06 },
    SELECTED      = { r = 1,    g = 1,    b = 1,    a = 0.12 },
    ERROR_SURFACE = { r = 0.3,  g = 0.05, b = 0.05, a = 0.5 },
    ERROR_TEXT    = { r = 0.9,  g = 0.35, b = 0.3,  a = 1.0 },
}

-- 載入期綁定：mod.info require= 保證框架的 lua 已全部先執行（見檔頭）。
local FW, TOAST, VLIST, DIALOG = nil, nil, nil, nil
do
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.Skin then
        FW = ui.Skin
        if ui.CAPABILITIES and ui.CAPABILITIES.toast then
            TOAST = ui.Toast
        end
        if ui.CAPABILITIES and ui.CAPABILITIES.virtualList then
            VLIST = ui.VirtualList
        end
        -- 確認框要 rev 26 不擋操作的模式（modal = false、anchor）：舊框架的框會鋪全螢幕遮罩、吃掉滑鼠，改走原版框
        if ui.CAPABILITIES and ui.CAPABILITIES.dialog and ui.CAPABILITIES.dialogModeless then
            DIALOG = ui.Dialog
        end
    end
end

-- 遊戲內更新概要（框架 rev 24，WhatsNew）：更新後第一次進遊戲在右上角跳這版的重點。
-- 發布列車的 ready 用 regex 讀這段：四欄都寫字面字串、一欄一行；這版有寫新概要才把 since 改成本版
-- （家族 conventions.md「遊戲內更新概要」、框架 AGENTS.md「下游 consumer」第 8 條）
pcall(require, "MinidoracatUI/WhatsNew")
do
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and (ui.API_REVISION or 0) >= 24 and ui.CAPABILITIES and ui.CAPABILITIES.whatsNew
        and ui.WhatsNew then
        ui.WhatsNew.register({
            modId = "MinidoracatCleanerFor42",
            since = "0.10.0",
            name = "IGUI_MinidoracatCleaner_Name",
            text = "IGUI_MinidoracatCleaner_WhatsNew",
        })
    end
end

-- 圓角填色。shape 直通框架（nil=四角圓、true/"roundTop"=上圓、"rect"=直角）。
function Skin.fill(element, x, y, width, height, color, shape, alphaScale)
    if FW then
        FW.fill(element, x, y, width, height, color, shape, alphaScale)
        return
    end
    element:drawRect(x, y, width, height,
        (color.a or 1) * (alphaScale or 1), color.r, color.g, color.b)
end

-- 1px 圓角邊框。
function Skin.border(element, x, y, width, height, color, shape, alphaScale)
    if FW then
        FW.border(element, x, y, width, height, color, shape, alphaScale)
        return
    end
    element:drawRectBorder(x, y, width, height,
        (color.a or 1) * (alphaScale or 1), color.r, color.g, color.b)
end

-- 框架 VirtualList class；缺席為 nil（呼叫端走 ISScrollingListBox 退回）。
Skin.VirtualList = VLIST

-- 通知：框架 Toast（右上滑入堆疊，跨 MOD 共用疊放不重疊）；缺席退 halo。
-- kind："ok"（綠）/"error"（紅）/nil（一般）。playerObj 允許 nil（此時只出 Toast）。
function Skin.notify(playerObj, message, kind)
    if TOAST then
        local colors = nil
        if kind == "error" then
            colors = {
                surface = Skin.COLORS.ERROR_SURFACE,
                border = Skin.COLORS.ERROR_TEXT,
                text = Skin.COLORS.TEXT,
            }
        end
        TOAST.show({
            title = getText("IGUI_MinidoracatCleaner_ToastTitle"),
            message = message,
            colors = colors,
            maxLines = 3, -- 較長的通知（複製清單後的貼上說明、套用結果、各語言較長的譯文）換行顯示，不再截成一行
        })
        return
    end
    if playerObj then
        if kind == "error" then
            playerObj:setHaloNote(message, 255, 120, 120, 240)
        else
            playerObj:setHaloNote(message, 120, 255, 120, 240)
        end
    end
end

-- 危險動作的確認框。opts：playerNum、title、text（\n 分行）、confirmText、cancelText、onResult(ok)。
-- onResult 至多呼叫一次（按鈕、Enter／Esc、關閉鈕都算）；退回路徑被同一客戶端新開的框取代時不回呼。
-- 兩條路都不擋操作（2026-11-02 使用者裁定；玩家回報框「畫面會變暗、擋到人物、在室內很容易被偷襲」）：
-- 不鋪全螢幕遮罩，滑鼠照常給遊戲（攻擊、瞄準）；滑鼠玩家的框開在游標旁（右鍵選單的位置），不蓋住畫面中央的角色。
-- 框架 Dialog（rev 26）：確認鈕用 danger 樣式、Esc 取消、焦點框亮著時 Enter 按焦點下的鈕、高度照行數。
-- 退回原版 ISModalDialog 的情況：框架缺席或早於 rev 26，或分割畫面第 2–4 位的手把玩家——框架只接玩家 1 的
-- 手把（Window.lua:332 Focus.takeJoypad(win, 0)），原版框可以把焦點交給指定玩家。原版框本來就沒有遮罩。
local CONFIRM_WIDTH = 420
local fallbackDialog = nil

local function fallbackConfirm(opts)
    if fallbackDialog then
        fallbackDialog:destroy()
        fallbackDialog = nil
    end
    local playerNum = opts.playerNum
    local pad = JoypadState.players[playerNum + 1] ~= nil
    local text = opts.title .. "\n\n" .. opts.text
    -- CalcSize 用 Java regex split 分行（StringLib.java:1413），真換行照算高度；寬度依最長那行撐開。
    -- 位置要用撐完的尺寸算，不然長譯文的確認框整個偏掉（法文實機 598 寬）
    local width, height = ISModalDialog.CalcSize(360, 0, text)
    -- 滑鼠玩家：框的中心對準游標；手把玩家：放在他那塊畫面的中央。都夾在他那塊畫面裡
    local left, top = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum)
    local right = left + getPlayerScreenWidth(playerNum) - width
    local bottom = top + getPlayerScreenHeight(playerNum) - height
    local x, y = (left + right) / 2, (top + bottom) / 2
    if not pad then
        x, y = getMouseX() - width / 2, getMouseY() - height / 2
    end
    x = math.max(left, math.min(x, right))
    y = math.max(top, math.min(y, bottom))
    -- ISModalDialog.lua:187-210：onclick(target, button, param1, param2)
    local dialog = ISModalDialog:new(x, y, width, height, text, true, nil, function(_, button)
        fallbackDialog = nil
        opts.onResult(button.internal == "YES")
    end, playerNum)
    dialog:initialise()
    -- 夾到下緣時游標會落在按鈕列：膠囊框、重開的主框接著開在剛按過刪除的地方，雙擊就一次按掉兩個框。
    -- 這時把框放到游標上方
    if not pad and getMouseY() >= y + dialog.yes:getY() then
        y = math.max(top, math.min(getMouseY() - height - 10, bottom))
    end
    -- new 把 x 或 y 等於 0 當成「自己找位置」（ISModalDialog.lua:192-207）：夾到畫面左緣或上緣時改回算好的位置
    dialog:setX(x)
    dialog:setY(y)
    -- 原版 destroy 在遊戲中會把速度設回 1（ISModalDialog.lua:47-49），按鈕與新框取代舊框都會走到。
    -- 框不擋操作，玩家可能在框開著時暫停或快轉：只拿掉改速度那段，其餘照抄原版（:43-46、:50-51）；
    -- player 一定有值（都帶 playerNum），用不到原版的 joyfocus 分支
    function dialog:destroy()
        local inGame = MainScreen.instance and MainScreen.instance.inGame and not MainScreen.instance:getIsVisible()
        UIManager.setShowPausedMessage(inGame)
        self:setVisible(false)
        self:removeFromUIManager()
        setJoypadFocus(self.player, self.prevFocus)
    end
    -- 按鈕寫出動作；危險色放在確認、安全色放在取消（原版是「是」綠、「否」紅）。
    -- 原版按鈕固定 100 寬（ISModalDialog.lua:10-28），手把玩家的按鈕左邊還畫圖示：依文字重新量寬度再置中
    dialog.yes:setTitle(opts.confirmText)
    dialog.yes:setWidthToTitle(100, pad)
    dialog.yes:enableCancelColor()
    dialog.no:setTitle(opts.cancelText)
    dialog.no:setWidthToTitle(100, pad)
    dialog.no:enableAcceptColor()
    dialog.yes:setX((width - 10) / 2 - dialog.yes.width)
    dialog.no:setX((width + 10) / 2)
    dialog:addToUIManager()
    if pad then
        dialog.prevFocus = JoypadState.players[playerNum + 1].focus
        setJoypadFocus(playerNum, dialog)
    end
    fallbackDialog = dialog
end

function Skin.confirm(opts)
    local pad = JoypadState.players[opts.playerNum + 1] ~= nil
    if DIALOG and not (pad and opts.playerNum ~= 0) then
        DIALOG.show({
            title = opts.title,
            text = opts.text,
            width = CONFIRM_WIDTH,
            confirmText = opts.confirmText,
            cancelText = opts.cancelText,
            danger = true,
            opaque = true, -- rev 18：疊在物品欄上時底下的字不透出來（2026-11-02 裁定維持不透明）
            modal = false, -- rev 26：不鋪遮罩，滑鼠照常給遊戲
            anchor = not pad and "mouse" or nil, -- rev 26：框的中心對準游標；玩家 1 用手把時照舊放畫面中央
            onResult = function(ok)
                opts.onResult(ok == true)
            end,
        })
        return
    end
    fallbackConfirm(opts)
end

return Skin
