# -*- coding: utf-8 -*-
"""ItemCleaner 專屬的靜態檢查：scripts/verify_mod.py 第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。
從換成家族模板前的 verify_mod.py 原樣搬來（模板沒有）：
  - 翻譯值無 Markdown 標記 — PZ 純文字顯示，** 與 ` 會原樣露出給玩家
  - DEFAULTS 對等宣告      — Core 的 Cleaner.DEFAULTS 鍵與 sandbox-options.txt 宣告要一一對應
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed = [], []

# 豁免清單與 verify_mod.py 共用：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
IGNORE_PATTERNS = []
_ign = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_ignore.txt")
if os.path.isfile(_ign):
    with open(_ign, encoding="utf-8") as _fh:
        for _line in _fh:
            _line = _line.strip()
            if _line and not _line.startswith("#"):
                IGNORE_PATTERNS.append(_line)


def ok(label):
    passed.append(label)
    print(f"  PASS  {label}")


def fail(label, details=None):
    if not details:  # 說失敗卻沒附細節（例：子程序結束碼非零但沒輸出）也是失敗；空清單走下面會記成 PASS
        failed.append(label)
        print(f"  FAIL  {label}")
        return
    kept = [d for d in details if not any(p in d for p in IGNORE_PATTERNS)]
    waived = [d for d in details if any(p in d for p in IGNORE_PATTERNS)]
    for d in waived:
        print(f"  WAIVE {label}: {d}（verify_ignore.txt 豁免）")
    if not kept:
        if waived:
            ok(f"{label}（{len(waived)} 筆豁免）")
        else:
            ok(label)
        return
    failed.append(label)
    print(f"  FAIL  {label}")
    for d in kept:
        print(f"        {d}")


def find_media():
    hits = []
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            p = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(p):
                continue
            for inner in os.listdir(p):
                media = os.path.join(p, inner, "42", "media")
                if os.path.isdir(media):
                    hits.append(media)
    return hits


def iter_files(root, exts):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git",)]
        for name in files:
            if os.path.splitext(name)[1] in exts:
                yield os.path.join(base, name)


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

# ---- 翻譯值無 Markdown 標記 ----
# 缺檔與 JSON 解析失敗由 verify_mod.py 的「翻譯鍵集一致」「翻譯 JSON 可解析」回報。
for m in MEDIA_DIRS:
    troot = os.path.join(m, "lua", "shared", "Translate")
    if not os.path.isdir(troot):
        continue
    langs = sorted(d for d in os.listdir(troot) if os.path.isdir(os.path.join(troot, d)))
    names = sorted({n for l in langs for n in os.listdir(os.path.join(troot, l)) if n.endswith(".json")})
    badmd = []
    for n in names:
        for l in langs:
            p = os.path.join(troot, l, n)
            if not os.path.isfile(p):
                continue
            try:
                with open(p, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception:
                continue
            for k, v in data.items():
                # PZ 的沙盒 tooltip 與 UI 字串都是純文字，不解析 Markdown：寫 **粗體**
                # 會把四個星號原樣顯示給玩家。強調只能靠措辭（「注意：」）或全大寫
                if "**" in v or "`" in v:
                    badmd.append(f"{l}/{n} 的 {k}")
    md_label = "翻譯值無 Markdown 標記（PZ 純文字顯示，** 與 ` 會原樣露出）"
    fail(md_label, sorted(set(badmd))) if badmd else ok(md_label)

# ---- 10b. DEFAULTS 鍵 ↔ sandbox-options 宣告對等 ----
# 抓「Core 加了 DEFAULTS、程式讀 getOption，卻忘了在 sandbox-options.txt 宣告」這整類 bug：
# getOption 讀 SandboxVars[MOD_ID][name]，未宣告的鍵恆為 nil → 永遠回退 DEFAULTS →
# 功能在遊戲內完全不可達，而煙霧測試直接塞 sandbox 表、全綠（設計評審 codex lane 實際抓到
# MaxRanchBreedingPerGroup 一度是死碼）。反向（宣告了卻沒有 DEFAULTS）會讓 getOption 在
# 沙盒缺值時回 nil，呼叫端的 `or DEFAULTS.X` 兜底也拿不到值。
for m in MEDIA_DIRS:
    sb = os.path.join(m, "sandbox-options.txt")
    core = os.path.join(m, "lua", "shared", "MinidoracatCleaner_Core.lua")
    if not (os.path.isfile(sb) and os.path.isfile(core)):
        continue
    with open(sb, encoding="utf-8") as fh:
        declared = set(re.findall(r"option\s+MinidoracatCleanerFor42\.(\w+)", fh.read()))
    with open(core, encoding="utf-8") as fh:
        core_txt = fh.read()
    dm = re.search(r"Cleaner\.DEFAULTS\s*=\s*\{(.*?)\n\}", core_txt, re.DOTALL)
    if not dm:
        fail("DEFAULTS 對等宣告", ["Core.lua 找不到 Cleaner.DEFAULTS 區塊"])
        continue
    defaults = set(re.findall(r"^\s*(\w+)\s*=", dm.group(1), re.MULTILINE))
    probs = [f"DEFAULTS 有、sandbox-options 未宣告（遊戲內死碼）: {k}"
             for k in sorted(defaults - declared)]
    probs += [f"sandbox-options 宣告、DEFAULTS 缺（缺值時 getOption 回 nil）: {k}"
              for k in sorted(declared - defaults)]
    fail("DEFAULTS 對等宣告", probs) if probs else ok(f"DEFAULTS 對等宣告（{len(defaults)} 鍵）")

sys.exit(1 if failed else 0)
