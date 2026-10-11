<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817857742 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Cleaner Mod Guide: Features, Settings & FAQ -->
<!-- 摘要：Illustrated guide to the Minidoracat Cleaner mod: right-click deletion, automatic cleanup of ground piles and animal numbers, who dropped or placed what, the cleanup log, the list manager, sandbox options and FAQ. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817857645]清潔隊 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3779823349
[list]
[*] [b]Game version[/b]: Build 42.20.2+, singleplayer and multiplayer.
[*] [b]UI languages[/b]: Traditional/Simplified Chinese, English, Japanese, Korean, Russian, Spanish, Portuguese, Turkish, French, Polish, German (please report any translation issues).
[*] [b]Required mod[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url] on server and clients, listed before this mod in the server's Mods line.
[/list]
[olist]
[*] [b]Delete[/b]: select items (multi-select works), right-click "Delete", confirm.
[*] [b]Auto-cleanup[/b]: on by default; warning first, cleanup only if still over at the next check.
[*] [b]Admins[/b]: sandbox settings (new game, hosting, or admin panel), pages "Minidoracat Cleaner - General / Items / Animals".
[*] [b]Lists[/b]: right-click the ground, "Cleaner: List Manager...".
[/olist]
=== 🧰 Manual deletion
{{img:01-ctx-delete.jpg}}
[list]
[*] [b]Where[/b]: anything within reach — inventory (nested bags too), cabinets, trunks and other vehicle containers, floor items.
[*] [b]Safehouses[/b]: safehouse loot permissions apply in multiplayer.
[*] [b]Cannot be deleted[/b]: favorites and items equipped, worn or on the hotbar/belt (no option shown).
[*] [b]Limit[/b]: up to 100 items per deletion.
[/list]
[h3]Confirmation[/h3]
{{img:02-confirm-contains.jpg}}
[list]
[*] [b]Always confirmed first[/b]: every deletion asks before it happens.
[*] [b]Containers with items[/b]: if a selected container still holds items (parcel, bag, key ring with keys…), the dialog says how many are destroyed with it.
[*] [b]Empty key rings[/b]: can be deleted.
[/list]
[h3]Multiplayer and logging[/h3]
[list]
[*] [b]Multiplayer[/b]: server-validated, no admin rights needed; "Allow manual deletion" can turn it off.
[*] [b]Singleplayer[/b]: always on.
[*] [b]Log[/b]: every manual deletion goes to the cleanup log.
[/list]
=== 🧰 Ground pile auto-cleanup
[list]
[*] [b]Scope[/b]: ground items only, counted per item type.
[*] [b]Two limits[/b]: per chunk (8×8 tiles) and per player's scan area; exceeding either triggers it.
[*] [b]Detected on drop[/b]: items are queued for checking as they land; periodic scans are the backstop.
[*] [b]Never auto-cleaned[/b]: favorites, containers holding items, the protected list.
[/list]
[h3]Warning first[/h3]
{{img:03-warn.jpg}}
[list]
[*] [b]Warning[/b]: red overhead text, chat message and sound for nearby players.
[*] [b]Cleanup[/b]: only if still over at the next scan.
[*] [b]Done[/b]: a green notice and an inventory panel refresh.
[/list]
{{img:04-cleaned.jpg}}
[h3]Newest pile first[/h3]
[list]
[*] Removed pile by pile (per tile), newest drop first.
[*] Items that were already there stay.
[/list]
[h3]Junk vs. scenery[/h3]
[list]
[*] [b]Player drops[/b]: items players dropped this playthrough use the normal limits.
[*] [b]Natural and old items[/b]: natural branches, logs and grass, and anything lying there before the mod was installed, have no dropper record and use separate high-tolerance limits.
[*] [b]Counted separately[/b]: 100 natural logs + 150 dumped = only excess among the 150 is cleaned.
[/list]
=== 🧰 Animal population control
Runaway rats, rabbits and chickens are a known B42 performance killer; this is what it is for.
[h3]Three limits[/h3]
[table]
[tr][th]Limit[/th][th]Counts[/th][/tr]
[tr][td]Near players[/td][td]Per group within each player's scan radius[/td][/tr]
[tr][td]Server-wide[/td][td]All loaded free-roaming animals, even far from players[/td][/tr]
[tr][td]Per farm[/td][td]One set of connected animal zones[/td][/tr]
[/table]
[list]
[*] [b]Per-species overrides[/b]: for every cap, e.g. rat=20,chicken=80.
[*] [b]Which animals[/b]: default rats, mice, rabbits, chickens; "Cleanable animal groups" accepts * or all for every animal, including other mods'.
[/list]
[h3]Warnings and removal[/h3]
[list]
[*] [b]Near-player cap[/b]: warns that player first and removes if still over next check, wild animals and babies first.
[*] [b]Server-wide cap[/b]: no warning, log only.
[*] [b]Batches[/b]: max 3 removals per game tick, so big cleanups run in batches; the notice shows how many remain nearby.
[/list]
[h3]Farm-safe[/h3]
[list]
[*] [b]Not free-roaming[/b]: animals in or next to an animal zone, or belonging to a hutch.
[*] [b]Farms off by default[/b]: farm caps default to 0.
[*] [b]Farm removal[/b]: skips animals inside hutches and takes geriatric animals first, then babies.
[*] [b]Protected[/b]: named, on a hook, leashed, held or in a vehicle — never counted or touched.
[/list]
[h3]Gentle mode[/h3]
[list]
[*] [b]How[/b]: set only the breeding cap, leave farm removal at 0.
[*] [b]Result[/b]: farms stop growing, nothing dies.
[*] [b]Over the cap[/b]: the newest pregnancies end and newest fertilised eggs become ordinary eggs; those closest to birth stay.
[*] [b]Geriatric animals don't count[/b]: they can't breed and will soon die of old age; leaving them out lets the farm raise young to replace them, so it may briefly hold a few extra old animals.
[/list]
=== 🧰 Who dropped it, who placed it
{{img:05-tooltip.jpg}}
[h3]Item tooltip[/h3]
[list]
[*] [b]What it shows[/b]: the last dropper and the last player who moved it between containers.
[*] [b]Time[/b]: your local time, to the hour (marked ~).
[*] [b]Not recorded[/b]: moves within your own bags.
[/list]
[h3]Placement record (multiplayer)[/h3]
[list]
[*] [b]How[/b]: right-click furniture or a built object, "Who placed this", and the placer and time appear over your head.
[*] [b]Traffic[/b]: kept on the server, sent only on request.
[/list]
=== 🧰 Cleanup log
[list]
[*] [b]File[/b]: <start time>_MinidoracatCleanerFor42.txt in Zomboid\Logs.
[*] [b]Singleplayer[/b]: %USERPROFILE%\Zomboid\Logs\
[*] [b]Multiplayer[/b]: on the server (default ~/Zomboid/Logs/, or under -cachedir).
[*] [b]Each line[/b]: time, player, coordinates, details.
[/list]
[h3]Events[/h3]
[table]
[tr][th]Event[/th][th]What[/th][/tr]
[tr][td]warn[/td][td]Warning[/td][/tr]
[tr][td]auto_clean[/td][td]Item cleanup, with droppers[/td][/tr]
[tr][td]animal_clean[/td][td]Animal cleanup[/td][/tr]
[tr][td]manual_delete[/td][td]Manual deletion[/td][/tr]
[tr][td]moveable[/td][td]Servers: furniture pickup, place, scrap, repair, rotate[/td][/tr]
[tr][td]build[/td][td]Servers: build[/td][/tr]
[/table]
=== 🧰 List manager
{{img:06-picker-items.jpg}}
[list]
[*] [b]Open[/b]: "Cleaner: List Manager..." on the ground menu.
[*] [b]Who[/b]: singleplayer always; admins and moderators in multiplayer.
[*] [b]Seven lists[/b]: switch on the left — protected, high tolerance, animal groups, three removal-cap overrides, breeding-cap override.
[/list]
[h3]Using it[/h3]
{{img:07-picker-override.jpg}}
[list]
[*] [b]Search[/b]: by name or item ID, tick and add in bulk; override lists take a value.
[*] [b]Bulk edit[/b]: bulk-edit values or remove entries in the current list.
[*] [b]Hand-written keywords[/b]: kept as they are.
[*] [b]Apply[/b]: "Apply to sandbox" works instantly with sandbox permission; otherwise "Copy to clipboard" and paste.
[/list]
=== ⚙️ Sandbox options and defaults
Defaults: normal play almost never triggers it, malicious dumping is stopped at once. 24 options, each explained in game.
[h3]General[/h3]
[table]
[tr][th]Option[/th][th]Default[/th][th]Notes[/th][/tr]
[tr][td]Allow manual deletion[/td][td]On[/td][td]Regular players can delete in multiplayer[/td][/tr]
[tr][td]Track who dropped and handled items[/td][td]On[/td][td]Off = no tracking[/td][/tr]
[tr][td]Show animal spawn debug menu[/td][td]Off[/td][td]Adds "Batch Spawn Animals", a cheat tool for testing limits[/td][/tr]
[/table]
[h3]Items[/h3]
[table]
[tr][th]Option[/th][th]Default[/th][th]Notes[/th][/tr]
[tr][td]Enable item cleanup[/td][td]On[/td][td]Master switch; off = no scanning[/td][/tr]
[tr][td]Per-Chunk Floor Item Limit (Normal)[/td][td]100[/td][td]Player drops only; 0 disables[/td][/tr]
[tr][td]Scan Area Floor Item Limit (Normal)[/td][td]400[/td][td]Same, per scan area[/td][/tr]
[tr][td]Per-Chunk Limit (High Tolerance)[/td][td]300[/td][td]0 = never clean[/td][/tr]
[tr][td]Scan Area Limit (High Tolerance)[/td][td]2000[/td][td]Same[/td][/tr]
[tr][td]High Tolerance Item List[/td][td]Empty[/td][td]Always use high-tolerance limits[/td][/tr]
[tr][td]Protected item list[/td][td]Empty[/td][td]Never auto-cleaned[/td][/tr]
[tr][td]Item scan radius[/td][td]80 (16–128)[/td][td]Squares around each player[/td][/tr]
[tr][td]Item scan interval[/td][td]60 s (10–3600)[/td][td]Real seconds; also the warning→cleanup gap[/td][/tr]
[/table]
Lists take item IDs (Base.Log), English or server-language names, separated by commas or semicolons.
[h3]Animals[/h3]
[table]
[tr][th]Option[/th][th]Default[/th][th]Notes[/th][/tr]
[tr][td]Enable animal cleanup[/td][td]On[/td][td]Master switch[/td][/tr]
[tr][td]Cleanable animal groups (allowlist)[/td][td]Empty = rats, mice, rabbits, chickens[/td][td]Caps apply only to these; * or all = every animal[/td][/tr]
[tr][td]Removal cap: unranched (near players)[/td][td]50[/td][td]Has an override[/td][/tr]
[tr][td]Removal cap: unranched (server-wide)[/td][td]0[/td][td]Has an override[/td][/tr]
[tr][td]Removal cap: ranched (per farm)[/td][td]0[/td][td]Has an override[/td][/tr]
[tr][td]Breeding cap: ranched (per farm)[/td][td]0[/td][td]Has an override; cancels pregnancies and fertilised eggs, never kills; geriatric animals don't count[/td][/tr]
[tr][td]Animal scan radius[/td][td]64 (16–128)[/td][td]Only affects the near-player cap[/td][/tr]
[tr][td]Animal scan interval[/td][td]10 s (5–600)[/td][td]Free-roaming checks, confirmations, farm removal; breeding runs on game time, a few checks per game hour[/td][/tr]
[/table]
[list]
[*] [b]Cap 0[/b]: off.
[*] [b]Override format[/b]: like rat=20,rabbit=40.
[*] [b]Override 0[/b]: that group is exempt, [b]not "zero allowed"[/b].
[/list]
=== ⚠️ Known limitations
[list]
[*] [b]Placement records[/b]:
[list]
[*] Within 8 tiles only
[*] None for objects placed before the feature
[*] Gone once removed or burned
[*] Multi-tile furniture (sofas) records only the placed tile
[/list]
[*] [b]Workstations[/b]: items put into a workstation (e.g. drying rack) lose their last-mover record.
[*] [b]Huge containers[/b]: with 20,000+ items in one container, a deletion may need a second press.
[*] [b]List manager entry[/b]: always shows in singleplayer; no option to hide it yet.
[/list]
=== ❓ FAQ
[h3]Can I turn off the debug features?[/h3]
[list]
[*] "Batch Spawn Animals" is hidden unless you enable "Show animal spawn debug menu".
[*] It always appears when launched with -debug.
[/list]
[h3]Does scanning hurt performance?[/h3]
[list]
[*] Multiplayer scanning runs only on the server (in singleplayer your game is the server).
[*] Work per tick is capped.
[*] To lower it:
[list]
[*] Raise "Item scan interval" (300 s = every 5 minutes)
[*] Lower "Item scan radius"
[*] Raise "Animal scan interval" (matters with many animals)
[*] Turn off a category's master switch
[/list]
[/list]
[h3]Only right-click delete, no auto-cleanup?[/h3]
[list]
[*] Turn off "Enable item cleanup" and "Enable animal cleanup".
[/list]
[h3]Players don't see "Delete"?[/h3]
[list]
[*] In multiplayer check "Allow manual deletion".
[*] Favorites and equipped/worn items never show it.
[/list]
[h3]Why were my chickens removed?[/h3]
[list]
[*] Outside an animal zone they are free-roaming and use the near-player cap.
[*] Name them, keep them in a zone, or set chicken=0 in the override.
[/list]
[h3]Why does my farm have more animals than the breeding cap?[/h3]
[list]
[*] Geriatric animals don't count toward it: they can't breed and will soon die of old age, and counting them would leave a full farm with no young to replace them until it dies out.
[*] For a hard ceiling, also set the farm removal cap; it removes geriatric animals first.
[/list]
=== 💬 Reporting
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatCleanerFor42/issues]GitHub Issues[/url][/b]: please include
[list]
[*] Singleplayer or multiplayer
[*] Full mod list
[*] Sandbox screenshots
[*] console.txt (plus server logs for multiplayer)
[/list]
[*] [b][url=https://discord.gg/Gur2V67]Discord community[/url][/b]
[/list]
