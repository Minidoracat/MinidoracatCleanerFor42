# Minidoracat Cleaner for B42

所有容器皆可刪除垃圾；自動清理範圍內過量的地板重複物品與動物

Project Zomboid Build 42 MOD。

## 功能

- **全容器刪除物品**：任何容器（背包、櫃子、車廂、地板…）右鍵單獨或批量刪除，刪除前有確認視窗。多人由伺服器端驗證後代為執行；最愛／裝備中／鑰匙圈自動排除
- **地板物品自動清理**：雙層閾值（每 8×8 區塊上限＋掃描區域總量上限），整堆整堆清除最新丟棄的堆，物品落地即進入偵測佇列
- **動物數量清理**：範圍內同物種過多時清除超額；散養與圈養分開計數、各有獨立上限並可逐物種覆寫。圈養預設永不清理，命名／牽抱／掛鉤動物絕對保護
- **警告機制**：先警告、下一輪仍超量才清理——頭上持續紅字＋聊天室訊息＋音效，清理後綠字通知並顯示剩餘數
- **接觸者追蹤**：記錄物品最後接觸者／丟棄者，顯示於物品提示資訊
- **清理紀錄檔**：警告與清理事件寫入 `Zomboid/Logs/`，含時間、物品／物種、數量、座標、丟棄者
- **清單產生器**：遊戲內右鍵開啟，關鍵字（中文名稱或英文 ID）搜尋物品／動物並複製精確值貼入沙盒選項
- **批量生成動物**：管理員測試工具，右鍵一次生成 10／25／50／100 隻
- **沙盒選項**：14 項，分為一般／物品／動物三頁
- **四語系**：EN / CH / CN / JP

## 安裝

- Steam Workshop：[Minidoracat Cleaner for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3779823349)
- 手動安裝：把 `MOD/MinidoracatCleanerFor42/Contents/mods/MinidoracatCleanerFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatCleanerFor42`

## 開發

- `link_workshop.bat`：把 repo 掛載到 `Zomboid\Workshop\` 與 `Zomboid\mods\`（符號連結，repo 改動即時生效）
- `PZ_Test.bat`：啟動測試（客戶端 / 專用伺服器 / 多客戶端組合）
- `scripts/poster/finish_poster.py`：把主視覺疊上 PZ 風標題板，輸出 `poster.png` / `preview.png`

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.20.2-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)
