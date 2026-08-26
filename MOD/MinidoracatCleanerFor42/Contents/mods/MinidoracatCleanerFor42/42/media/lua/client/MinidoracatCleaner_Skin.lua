-- MinidoracatCleaner_Skin：本 MOD 色票的唯一權威來源＋家族 UI 框架
-- （MinidoracatUIFor42）的 thin adapter。樣板抄 NoticeBoard 的 NBSkin。
--
-- 【退回紅線】框架缺席（未安裝、版本不合、載入失敗）時本 MOD 的 UI 仍要能開——
-- 一律退直角／halo，絕不 error。正式發佈以 mod.info 的 `require=MinidoracatUIFor42`
-- 保證框架先載入（引擎依賴先排 load order，ZomboidFileSystem.java:807-833）；
-- 這裡的動態檢查涵蓋測試 harness 與異常環境。
--
-- 【API 契約】框架同 major 只做 additive 變更；本 MOD 需要 API v1 rev>=1
-- （Skin.fill/border/fits、Widgets/Toast、VirtualList）。版本不合＝當框架不存在
-- 處理（走退回），不帶半套狀態運行。

if not (MinidoracatUI and MinidoracatUI.v1) then
    -- 測試環境／異常順序防禦：Kahlua require 對缺檔的行為未查證，pcall 包住
    pcall(require, "MinidoracatUI/V1")
    pcall(require, "MinidoracatUI/Widgets/Toast")
    pcall(require, "MinidoracatUI/VirtualList")
end

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
    OK_TEXT       = { r = 0.47, g = 1,    b = 0.47, a = 1.0 }, -- halo 綠（120,255,120）同值
}

-- 載入期綁定：mod.info require= 保證框架的 lua 已全部先執行（見檔頭）。
local FW, TOAST, VLIST = nil, nil, nil
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
    end
end

-- 矩形夠不夠大到能走 9-slice。框架缺席一律 false（fill/border 直接退直角）。
function Skin.fits(width, height, shape)
    if FW then
        return FW.fits(width, height, shape)
    end
    return false
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

-- 框架 VirtualList class；缺席回 nil（呼叫端走 ISScrollingListBox 退回）。
function Skin.virtualListClass()
    return VLIST
end

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

return Skin
