[h1]🧹 Minidoracat Cleaner for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ What is this?[/h2]
Sanitation service for the apocalypse. This MOD does three things:
[list]
[*] Lets you delete junk from [b]any container[/b] — no longer limited to garbage cans
[*] [b]Automatically cleans up[/b] excessive duplicate items piling up on the ground — the answer to "someone dumped 500 bullets and tanked the server"
[*] [b]Automatically removes[/b] overbred animals — runaway rats, rabbits and chickens are a known B42 performance killer
[/list]
Every cleanup is [b]warned first[/b] and only executed if the area is still over the limit on the next scan, so normal players get time to tidy up themselves.

[h2]🧰 Features[/h2]
[list]
[*] [b]Delete items in every container[/b]: backpacks, cabinets, trunks, the floor… right-click to delete one item or a whole selection, with a confirmation dialog. In multiplayer the server validates and performs the deletion, so regular players need no admin rights
[*] [b]Deletion safeguards[/b]: favorite items, equipped/worn gear and keyrings are always excluded — no accidents
[*] [b]Automatic floor item cleanup[/b]: two independent thresholds — a [u]per-chunk[/u] (8×8 tiles) limit for concentrated dumping and a [u]total area[/u] limit for spread-out piles. The area total is counted [b]separately for each player[/b], so what someone piles up across the map never counts against you
[*] [b]Tells litter from scenery[/b]: forest floor branches, wood and grass are not dropped by anyone, yet they are the easiest thing to mistake for dumping. This mod splits floor items into two groups by [u]whether they carry a dropper stamp[/u] and applies a separate limit to each — a generous allowance for world-generated clutter, normal control for what players drop. You can also nominate items to use the high tolerance limits yourself
[*] [b]Whole piles at a time[/b]: cleanup starts from the most recently dropped piles and clears them entirely, keeping older legitimate items
[*] [b]Instant reaction[/b]: dropped items enter the detection queue immediately — no waiting for the next periodic scan
[*] [b]Animal population control[/b]: removes the excess when one species gets too dense. [u]Stray[/u] and [u]ranched[/u] animals are counted separately with independent limits, both overridable per species (e.g. "rat=20, chicken=80")
[*] [b]Ranches are safe[/b]: ranched animals are [u]never cleaned[/u] by default; named, held/leashed and hooked animals are absolutely protected under any configuration. Set a number only if you want a ceiling on your ranch
[*] [b]Triple warning[/b]: a red warning above your character + a chat system message + an alert sound. The chat line stays in your log so you can scroll back to it; a green notice with the remaining count follows the cleanup
[*] [b]Dropper tracking[/b]: records who last dropped each item, shown right in the item tooltip — no more guessing who littered
[*] [b]Cleanup log file[/b]: every warning and cleanup is written to its own log with timestamp, item/species, count, coordinates and the dropper — ready for server admin audits (path below)
[*] [b]List builder[/b]: an in-game search tool — look up items and animal groups by keyword ([u]localized name or English ID both work[/u]), pick them, copy the exact values and paste them into the sandbox options. No more transcribing item IDs by hand
[*] [b]Batch animal spawner[/b]: admin testing tool, right-click to spawn 10/25/50/100 of a chosen animal at once
[*] [b]Sandbox options[/b]: 17 settings split across three pages (General / Items / Animals), each with an explanation
[*] [b]Singleplayer & multiplayer[/b]: in MP every deletion and cleanup is validated and executed server-side, so modified clients can't abuse it
[*] [b]Languages[/b]: English / 繁體中文 / 简体中文 / 日本語
[/list]

[h2]⚙️ Defaults[/h2]
Works out of the box; defaults are tuned so normal play virtually never triggers it while malicious dumping is stopped immediately:
[list]
[*] Player-dropped: 100 same-type items per chunk, 400 across each player's scan area
[*] World-generated / high tolerance: 300 per chunk, 2000 across the scan area
[*] 50 stray animals per group; ranched animals are [b]not cleaned[/b] (limit 0)
[*] Default cleanup species: rat, mouse, rabbit, chicken
[/list]
Too strict or too loose? Every value is configurable in the sandbox settings, and you can disable the automatic parts entirely and keep only manual deletion.

[h2]📂 Where to find the cleanup log[/h2]
File name: [b]<server start time>_MinidoracatCleanerFor42.txt[/b] (e.g. 2026-08-08_19-10_MinidoracatCleanerFor42.txt) — a new file per startup.
[list]
[*] [b]Singleplayer / client[/b]: [b]%USERPROFILE%\Zomboid\Logs\[/b]
[*] [b]Dedicated server[/b]: [b]<cachedir>/Logs/[/b] (defaults to ~/Zomboid/Logs/; if the server was launched with -cachedir=, use that path)
[/list]
Entry types (bracket-delimited fields, grep-friendly):
[list]
[*] [b][warn][/b] — over the limit, warning issued
[*] [b][auto_clean][/b] — items removed, with fullType / removed count / dropper
[*] [b][animal_clean][/b] — animals removed, with group / removed / wild / zoned / scope
[*] [b][manual_delete][/b] — player deletion, with the acting player and item breakdown
[/list]

[h2]🔗 MOD series[/h2]
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url] — image-based world map & minimap
[/list]

[h2]📋 MOD information[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatCleanerFor42
[*] [b]Supported version:[/b] Build 42.20.2+
[*] [b]Singleplayer / Multiplayer:[/b] both supported
[/list]

[h2]💬 Support & community[/h2]
[list]
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]

[h2]📺 Follow the author[/h2]
[list]
[*] [url=https://www.twitch.tv/minidoracat]Twitch streams[/url]
[/list]

[b]#cleaner #trash #performance #server #animals #Minidoracat[/b]

Workshop ID: 3779823349
Mod ID: MinidoracatCleanerFor42
