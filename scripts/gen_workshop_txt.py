# -*- coding: utf-8 -*-
"""由 STEAM_DESCRIPTION_EN.md 重新生成 workshop.txt 的 description 區塊。

用法：
    python scripts/gen_workshop_txt.py

規則（見 AGENTS.md 發布流程）：
- description 區塊是唯一由本腳本管理的部分，其餘欄位（version/id/title/tags/visibility）保留既有值
- 首次發布時檔案尚無 id=，由遊戲內 Workshop 工具上傳後自動寫入；本腳本不會生成或猜測 id
- EN 描述每行加 description= 前綴（空行也輸出 description=），行尾 LF、UTF-8 無 BOM
"""
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "STEAM_DESCRIPTION_EN.md")
DST = os.path.join(REPO, "MOD", "MinidoracatCleanerFor42", "workshop.txt")

TITLE = "Minidoracat Cleaner for B42"
TAGS = "Build 42;Interface;Items;Multiplayer"
VISIBILITY = "public"

FIELD_RE = re.compile(r"^(version|id|title|tags|visibility)=", re.IGNORECASE)


def read_existing_fields(path):
    """保留既有的 version/id/title/tags/visibility（遊戲回寫的 id 不可覆蓋）。"""
    fields = {}
    if not os.path.isfile(path):
        return fields
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            m = FIELD_RE.match(line)
            if m:
                key, _, value = line.partition("=")
                fields[key.strip().lower()] = value
    return fields


def build():
    with open(SRC, encoding="utf-8") as f:
        body = f.read().splitlines()

    existing = read_existing_fields(DST)
    out = []
    out.append("version=" + existing.get("version", "1"))
    # id 只在既有檔案已有時保留；首次發布時不輸出，待遊戲上傳後自動寫入
    if existing.get("id"):
        out.append("id=" + existing["id"])
    out.append("title=" + existing.get("title", TITLE))
    for line in body:
        out.append("description=" + line)
    out.append("tags=" + existing.get("tags", TAGS))
    out.append("visibility=" + existing.get("visibility", VISIBILITY))

    os.makedirs(os.path.dirname(DST), exist_ok=True)
    with open(DST, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("寫出:", DST)
    print("  description 行數:", len(body))
    print("  id:", existing.get("id") or "(尚未指派，首次上傳後由遊戲寫入)")


if __name__ == "__main__":
    build()
