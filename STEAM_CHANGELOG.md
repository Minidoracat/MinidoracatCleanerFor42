[h1]Minidoracat Cleaner for B42 42.22.2-0.11.1[/h1]
[i]2026-11-10[/i]

[b]English summary[/b]
[list]
[*] Fixed: on Build 42.22, "Removal cap: ranched (per farm)" and "Breeding cap: ranched (per farm)" (and their overrides) did nothing, and every farm check printed an error in the console. Both caps work again. Servers that leave these caps at the default were not affected.
[*] Checked on Build 42.22.2: floor cleanup, manual delete, drop and move records, farm caps and the list manager were all tested in game. Everything else works as before, and no settings need to change.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]對應 PZ 42.22.2[/b]：已在 42.22.2 實際測過自動清理、手動刪除、丟棄與搬移紀錄、農場上限和清單管理，其他功能照常運作，設定不用改。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]42.22 上農場的清除上限與繁殖上限沒有作用[/b]：有設「清除上限：圈養（每座農場）」或「繁殖上限：圈養（每座農場）」（或它們的覆寫）、世界上又有動物圈地時（單機也一樣），每次檢查農場都會出錯：超過上限的動物不會被清除，新的懷孕也不會被取消，console 一直出現錯誤訊息。現在恢復正常。這兩個上限維持預設的伺服器不受影響。
[/list]
伺服器更新後重開生效，設定不用改。
