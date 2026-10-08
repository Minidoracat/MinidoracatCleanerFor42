<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3779823349/586187095760095568/ -->
<!-- 標題：📖 Cleaner Guide: Features, Settings & FAQ -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3779823349/586187095760095548/]Cleaner 完整說明：功能、設定與常見問題[/url]

[h2]🚀 Quick start[/h2]
Build 42.20.2+, singleplayer and multiplayer; UI in Traditional/Simplified Chinese, English, Japanese, Korean, Russian, Spanish, Portuguese, Turkish, French, Polish, German (please report any translation issues). Install Minidoracat UI Library on server and clients, listed before this mod in the server's Mods line.
[olist]
[*] [b]Delete[/b]: select items (multi-select works), right-click "Delete", confirm
[*] [b]Auto-cleanup[/b]: on by default; warning first, cleanup only if still over at the next check
[*] [b]Admins[/b]: sandbox settings (new game, hosting, or admin panel), pages "Minidoracat Cleaner - General / Items / Animals"
[*] [b]Lists[/b]: right-click the ground, "Cleaner: List Manager..."
[/olist]

[h2]🧰 Features in detail[/h2]
[h3]Manual deletion[/h3]
[list]
[*] Anything within reach: inventory (nested bags too), cabinets, trunks and other vehicle containers, floor items; safehouse loot permissions apply
[*] [b]Cannot be deleted[/b]: favorites and items equipped, worn or on the hotbar/belt (no option shown)
[*] Always confirmed first. If a selected container still holds items (parcel, bag, key ring with keys…), the dialog says how many are destroyed with it. Empty key rings can be deleted
[*] Up to 100 items per deletion
[*] Multiplayer: server-validated, no admin rights needed; "Allow manual deletion" can turn it off. Always on in singleplayer
[*] Every manual deletion goes to the cleanup log
[/list]
[h3]Ground pile auto-cleanup[/h3]
[list]
[*] Ground items only, counted per item type per chunk (8×8 tiles) and per player's scan area; exceeding either triggers it
[*] [b]Warning first[/b]: red overhead text, chat message and sound for nearby players; if still over at the next scan the excess goes, followed by a green notice and a panel refresh
[*] [b]Newest pile first[/b]: removed pile by pile (per tile), newest drop first; items that were already there stay
[*] [b]Junk vs. scenery[/b]: items players dropped this playthrough use the normal limits. Natural branches, logs and grass, and anything lying there before the mod was installed, have no dropper record and use separate high-tolerance limits: 100 natural logs + 150 dumped = only excess among the 150 is cleaned
[*] [b]Detected on drop[/b]: items are queued for checking as they land; periodic scans are the backstop
[*] Never auto-cleaned: favorites, containers holding items, the protected list
[/list]
[h3]Animal population control[/h3]
Runaway rats, rabbits and chickens are a known B42 performance killer; this is what it is for.
[list]
[*] [b]Three limits[/b]: near players (per group within each player's scan radius), server-wide (all loaded free-roaming animals, even far from players), per farm (one set of connected animal zones)
[*] [b]Per-species overrides[/b] for every cap, e.g. rat=20,chicken=80
[*] Default species: rats, mice, rabbits, chickens; "Cleanable animal groups" accepts * or all for every animal, including other mods'
[*] Near-player cap warns that player first and removes if still over next check, wild animals and babies first. Server-wide cap: no warning, log only
[*] [b]Farm-safe[/b]: animals in or next to an animal zone, or belonging to a hutch, are not free-roaming; farm caps default to 0 (off). Farm removal skips animals inside hutches and takes babies first
[*] [b]Gentle mode[/b]: set only the breeding cap, leave farm removal at 0 — farms stop growing, nothing dies. Over the cap the newest pregnancies end and newest fertilised eggs become ordinary eggs; those closest to birth stay
[*] [b]Protected[/b]: named, on a hook, leashed, held or in a vehicle — never counted or touched
[*] Max 3 removals per game tick, so big cleanups run in batches; the notice shows how many remain nearby
[/list]
[h3]Who dropped it, who placed it[/h3]
[list]
[*] [b]Item tooltip[/b]: last dropper and last player who moved it between containers, local time, to the hour (marked ~). Moves within your own bags aren't recorded
[*] [b]Placement record[/b] (multiplayer): right-click furniture or a built object, "Who placed this", and the placer and time appear over your head. Kept on the server, sent only on request
[/list]
[h3]Cleanup log[/h3]
[b]<start time>_MinidoracatCleanerFor42.txt[/b] in Zomboid\Logs: singleplayer %USERPROFILE%\Zomboid\Logs\; multiplayer on the server (default ~/Zomboid/Logs/, or under -cachedir).
Events: warn, auto_clean (with droppers), animal_clean, manual_delete, and on servers moveable (furniture pickup, place, scrap, repair, rotate) and build. Each line: time, player, coordinates, details.
[h3]List manager[/h3]
"Cleaner: List Manager..." on the ground menu (singleplayer always; admins and moderators in multiplayer). Seven lists: protected, high tolerance, animal groups, three removal-cap overrides, breeding-cap override.
[list]
[*] Search by name or item ID, tick and add in bulk; override lists take a value
[*] Bulk-edit values or remove entries; hand-written keywords are kept
[*] "Apply to sandbox" works instantly with sandbox permission; otherwise "Copy to clipboard" and paste
[/list]

[h2]⚙️ Settings[/h2]
Defaults: normal play almost never triggers it, malicious dumping is stopped at once. 24 options, each explained in game; default in brackets:
[b]General[/b]
[list]
[*] Allow manual deletion (on): regular players can delete in multiplayer
[*] Track who dropped and handled items (on): off = no tracking
[*] Show animal spawn debug menu (off): adds "Batch Spawn Animals", a cheat tool for testing limits
[/list]
[b]Items[/b]
[list]
[*] Enable item cleanup (on): master switch; off = no scanning
[*] Per-Chunk Floor Item Limit (Normal) (100): player drops only; 0 disables
[*] Scan Area Floor Item Limit (Normal) (400): same, per scan area
[*] Per-Chunk Limit (High Tolerance) (300): 0 = never clean
[*] Scan Area Limit (High Tolerance) (2000): same
[*] High Tolerance Item List: always use high-tolerance limits
[*] Protected item list: never auto-cleaned
[*] Item scan radius (80, 16–128): squares around each player
[*] Item scan interval (60 s, 10–3600): real seconds; also the warning→cleanup gap
[/list]
Lists take item IDs (Base.Log), English or server-language names, separated by commas or semicolons.
[b]Animals[/b]
[list]
[*] Enable animal cleanup (on): master switch
[*] Cleanable animal groups (empty = rats, mice, rabbits, chickens): caps apply only to these
[*] Removal cap: unranched (near players) (50) + override
[*] Removal cap: unranched (server-wide) (0) + override
[*] Removal cap: ranched (per farm) (0) + override
[*] Breeding cap: ranched (per farm) (0) + override: cancels pregnancies and fertilised eggs, never kills
[*] Animal scan radius (64, 16–128): only affects the near-player cap
[*] Animal scan interval (10 s, 5–600): free-roaming checks, confirmations, farm removal; breeding runs on game time, a few checks per game hour
[/list]
Cap 0 = off. Overrides like rat=20,rabbit=40; [b]override 0 = that group is exempt, not "zero allowed".[/b]

[h2]⚠️ Known limitations[/h2]
[list]
[*] Placement records: within 8 tiles; none for objects placed before the feature; gone once removed or burned; multi-tile furniture (sofas) records only the placed tile
[*] Items put into a workstation (e.g. drying rack) lose their last-mover record
[*] With 20,000+ items in one container, a deletion may need a second press
[*] The list manager always shows in singleplayer; no option to hide it yet
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]Can I turn off the debug features?[/b] "Batch Spawn Animals" is hidden unless you enable "Show animal spawn debug menu"; it always appears when launched with -debug.
[*] [b]Does scanning hurt performance?[/b] Multiplayer scanning runs only on the server (in singleplayer your game is the server). Work per tick is capped. To lower it: raise "Item scan interval" (300 s = every 5 minutes), lower "Item scan radius", raise "Animal scan interval" (matters with many animals), or turn off a category's master switch.
[*] [b]Only right-click delete, no auto-cleanup?[/b] Turn off "Enable item cleanup" and "Enable animal cleanup".
[*] [b]Players don't see "Delete"?[/b] In multiplayer check "Allow manual deletion"; favorites and equipped/worn items never show it.
[*] [b]Why were my chickens removed?[/b] Outside an animal zone they are free-roaming and use the near-player cap. Name them, keep them in a zone, or set chicken=0 in the override.
[/list]

[h2]💬 Reporting[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatCleanerFor42/issues]GitHub Issues[/url]: singleplayer or multiplayer, full mod list, sandbox screenshots, console.txt (plus server logs for multiplayer)
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]
