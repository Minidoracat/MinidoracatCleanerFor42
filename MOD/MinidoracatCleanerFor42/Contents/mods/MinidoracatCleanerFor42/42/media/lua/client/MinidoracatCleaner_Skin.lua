-- MinidoracatCleaner_Skin：本 MOD 色票的唯一權威來源＋家族 UI 框架
-- （MinidoracatUIFor42）的 thin adapter。樣板抄 NoticeBoard 的 NBSkin。
--
-- 【退回紅線】框架缺席（未安裝、版本不合、載入失敗）時本 MOD 的 UI 仍要能開——
-- 一律退直角／halo，絕不 error。正式發佈以 mod.info 的 `require=MinidoracatUIFor42`
-- 保證框架先載入（引擎依賴先排 load order，ZomboidFileSystem.java:807-833）；
-- 這裡的動態檢查涵蓋測試 harness 與異常環境。
--
-- 【API 契約】框架同 major 只做 additive 變更；本 MOD 需要 API v1 rev>=1
-- （Skin.fill/border、Widgets/Toast、VirtualList），確認框另用 rev 7 的 Dialog（CAPABILITIES.dialog）。
-- 版本不合＝當框架不存在處理（走退回），不帶半套狀態運行。

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
        if ui.CAPABILITIES and ui.CAPABILITIES.dialog then
            DIALOG = ui.Dialog
        end
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
-- 框架 Dialog：確認鈕用 danger 樣式、Enter 確認／Esc 取消、高度照行數（Window.lua:556-657）。
-- 退回原版 ISModalDialog 的情況：框架缺席，或分割畫面第 2–4 位的手把玩家——框架只接玩家 1 的
-- 手把（Window.lua:332 Focus.takeJoypad(win, 0)），原版框可以把焦點交給指定玩家。
local CONFIRM_WIDTH = 420
local fallbackDialog = nil

local function fallbackConfirm(opts)
    if fallbackDialog then
        fallbackDialog:destroy()
        fallbackDialog = nil
    end
    local playerNum = opts.playerNum
    local text = opts.title .. "\n\n" .. opts.text
    -- CalcSize 用 Java regex split 分行（StringLib.java:1413），真換行照算高度；寬度依最長那行撐開。
    -- 置中要用撐完的尺寸，不然長譯文的確認框整個偏右（法文實機 598 寬、偏右約 124px）
    local width, height = ISModalDialog.CalcSize(360, 0, text)
    local x = getPlayerScreenLeft(playerNum) + (getPlayerScreenWidth(playerNum) - width) / 2
    local y = getPlayerScreenTop(playerNum) + (getPlayerScreenHeight(playerNum) - height) / 2
    -- ISModalDialog.lua:187-210：onclick(target, button, param1, param2)
    local dialog = ISModalDialog:new(x, y, width, height, text, true, nil, function(_, button)
        fallbackDialog = nil
        opts.onResult(button.internal == "YES")
    end, playerNum)
    dialog:initialise()
    -- 按鈕寫出動作；危險色放在確認、安全色放在取消（原版是「是」綠、「否」紅）。
    -- 原版按鈕固定 100 寬（ISModalDialog.lua:10-28），手把玩家的按鈕左邊還畫圖示：依文字重新量寬度再置中
    local pad = JoypadState.players[playerNum + 1] ~= nil
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
    local otherPad = opts.playerNum ~= 0 and JoypadState.players[opts.playerNum + 1] ~= nil
    if DIALOG and not otherPad then
        DIALOG.show({
            title = opts.title,
            text = opts.text,
            width = CONFIRM_WIDTH,
            confirmText = opts.confirmText,
            cancelText = opts.cancelText,
            danger = true,
            opaque = true, -- rev 18：疊在物品欄上時底下的字不透出來；舊框架忽略這個欄位
            onResult = function(ok)
                opts.onResult(ok == true)
            end,
        })
        return
    end
    fallbackConfirm(opts)
end

return Skin
