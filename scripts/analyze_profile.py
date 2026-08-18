#!/usr/bin/env python3
"""分析 PZ 內建 GameProfiler 的錄製檔（Zomboid/Recording/*.csv）。

用途：比較「裝本 MOD」與「不裝本 MOD」在同一存檔／同一操作下的 tick 成本，
回答「本 MOD 讓 OnTick 貴了多少」。

為什麼要用它而不是自己在 Lua 裡計時：Lua 端能拿到的時間只有
System.currentTimeMillis()（LuaManager.java:9271 的 getTimestampMs、:4028 的
getTimeInMillis，全檔沒有 nanoTime），而本 MOD 每 tick 是亞毫秒量級，毫秒時鐘
只會量到 0/1 的量化雜訊。GameProfiler 走的是 System.nanoTime()
（GameProfiler.java:177），CSV 裡的時間單位是 100ns，精度足夠。

已知限制：引擎給每個 Lua callback 的 span 名稱只有 "Lua - <事件名>"
（Event.java:34,55 的 profiler.profile("Lua - " + this.name)），**不含檔名**——
檔名只在單次 callback 超過 250ms 時才寫進 slow warning（:37-40）。所以單看一份
錄製檔無法分辨哪個 span 屬於哪個 MOD；歸因一律靠「有/無 MOD」兩份錄製的差分。

檔案結構（GameProfileRecording.java:135-207）：
  <stem>_header.csv          KeyNamesTable 把 span 名稱對應成數字索引
  <stem>_times.csv           每 frame 一行：frame, startTime/100, endTime/100, segmentNo
  <stem>_times_0000.csv, ... 分段的 span 檔，每 frame 一行：
                       frame, (keyIndex, depth, startOffset, length) × N（前序展開）

用法：
  python scripts/analyze_profile.py <錄製目錄或 header 檔>
  python scripts/analyze_profile.py <基準組> --compare <對照組>
"""

from __future__ import annotations

import argparse
import csv
import statistics
import sys
from pathlib import Path

TICK_SPAN = "Lua - OnTick"


def find_header(target: Path) -> Path:
    """接受 header 檔本身、或含錄製檔的目錄（取最新一組）。"""
    if target.is_file():
        return target
    headers = sorted(target.glob("*_header.csv"), key=lambda p: p.stat().st_mtime)
    if not headers:
        raise SystemExit(f"在 {target} 找不到 *_header.csv——確認 GameProfiler.Enabled 有錄到東西")
    return headers[-1]


def load_key_names(header: Path) -> dict[int, str]:
    """讀 KeyNamesTable 段落：Index,Name。"""
    names: dict[int, str] = {}
    in_table = False
    for raw in header.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line == "KeyNamesTable":
            in_table = True
            continue
        if not in_table or not line or line == "Index,Name":
            continue
        index, _, name = line.partition(",")
        if index.isdigit():
            names[int(index)] = name
    if not names:
        raise SystemExit(f"{header} 沒有 KeyNamesTable——檔案可能還沒寫完（錄製要先停止）")
    return names


def segment_files(header: Path) -> list[Path]:
    """同一組錄製的 span 分段檔：`<stem>_times_0000.csv`、`_0001.csv`……

    要跟 `<stem>_times.csv`（每 frame 一行的 frame time）區分開——兩者前綴相同，
    只差後面那四位數字。
    """
    stem = header.name[: -len("_header.csv")]
    return sorted(header.parent.glob(f"{stem}_times_[0-9][0-9][0-9][0-9].csv"))


def parse_spans(path: Path, names: dict[int, str]) -> dict[str, list[float]]:
    """回傳 span 名稱 → 該名稱每次出現的長度（毫秒）。

    一行的欄位是四個一組；同一個名稱在一行內可以出現多次——每個註冊在該事件上的
    callback 各自一個 span（Event.java 的迴圈），這正是差分能歸因的原因。
    """
    per_name: dict[str, list[float]] = {}
    with path.open(encoding="utf-8", errors="replace", newline="") as fh:
        for row in csv.reader(fh):
            if len(row) < 5:
                continue
            cells = row[1:]  # 第一欄是 frame number
            for i in range(0, len(cells) - 3, 4):
                key, _depth, _start, length = cells[i : i + 4]
                if not key.strip().isdigit() or not length.strip().lstrip("-").isdigit():
                    continue
                name = names.get(int(key), f"<未知索引 {key}>")
                # CSV 單位是 100ns（GameProfileRecording 對所有時間做 /100）
                per_name.setdefault(name, []).append(int(length) * 100 / 1_000_000)
    return per_name


def frame_times(header: Path) -> list[float]:
    """每 frame 的總長度（毫秒）。

    取自 `<stem>_times.csv`（欄位 frameNo,StartTime,EndTime,SegmentNo——header 首行
    自己列出這個格式）。注意分段的 span 檔是 `<stem>_times_0000.csv`，檔名前綴相同、
    多了四位數字，不能混在一起。
    """
    stem = header.name[: -len("_header.csv")]
    frame_file = header.parent / f"{stem}_times.csv"
    if not frame_file.exists():
        return []
    out: list[float] = []
    with frame_file.open(encoding="utf-8", errors="replace", newline="") as fh:
        for row in csv.reader(fh):
            if len(row) >= 3 and row[1].strip().lstrip("-").isdigit():
                out.append((int(row[2]) - int(row[1])) * 100 / 1_000_000)
    return out


def summarise(target: Path) -> dict:
    header = find_header(target)
    names = load_key_names(header)
    merged: dict[str, list[float]] = {}
    for segment in segment_files(header):
        for name, lengths in parse_spans(segment, names).items():
            merged.setdefault(name, []).extend(lengths)
    frames = frame_times(header)
    return {"header": header, "spans": merged, "frames": frames}


def percentile(sorted_values: list[float], q: float) -> float:
    """線性插值分位數。不用 statistics.quantiles：它要 n>=2，而 span 常有單筆樣本。"""
    if len(sorted_values) == 1:
        return sorted_values[0]
    pos = q * (len(sorted_values) - 1)
    low = int(pos)
    high = min(low + 1, len(sorted_values) - 1)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (pos - low)


def fmt(values: list[float], thresholds: tuple[float, ...] = (0.5, 1.0)) -> str:
    """中位數與 p95 是刻意放進來的：平均會被少數尖峰拉高，而「常態成本」與「尖峰成本」
    在效能判斷上是兩個不同的問題（常態決定基礎負載，尖峰決定玩家有沒有感覺到頓）。
    閾值計數則直接回答「這種頓發生得多頻繁」。"""
    if not values:
        return "無資料"
    ordered = sorted(values)
    over = "  ".join(
        f">{t:g}ms {sum(1 for v in values if v > t):>6}" for t in thresholds
    )
    return (
        f"次數 {len(values):>7}  平均 {statistics.fmean(values):>7.4f}ms  "
        f"中位 {statistics.median(ordered):>7.4f}ms  p95 {percentile(ordered, 0.95):>7.4f}ms  "
        f"最長 {max(values):>7.3f}ms  {over}"
    )


def report(label: str, data: dict, top: int = 12) -> None:
    print(f"\n===== {label} =====")
    print(f"來源：{data['header'].name}")
    frames = data["frames"]
    if frames:
        # frame 的閾值用 fps 門檻而不是 span 的 0.5/1ms：16.7ms 是掉出 60fps、
        # 33.3ms 是掉出 30fps，這兩個數字才對應玩家真的看得出來的頓
        print(f"frame 數 {len(frames)}；每 frame {fmt(frames, (16.7, 33.3))}")
    spans = data["spans"]
    tick = spans.get(TICK_SPAN, [])
    if tick and frames:
        print(f"\n{TICK_SPAN}：{fmt(tick)}")
        print(f"  每 frame 平均 {len(tick) / len(frames):.1f} 個 span"
              f"（＝註冊在 OnTick 上的 callback 數）"
              f"、合計 {sum(tick) / len(frames):.4f}ms")
    print(f"\n最耗時的 span（依總計）：")
    for name, lengths in sorted(spans.items(), key=lambda kv: -sum(kv[1]))[:top]:
        print(f"  {name:<38} {fmt(lengths)}")


def compare(base: dict, other: dict) -> None:
    print("\n===== 差分（對照組 − 基準組）=====")
    print("span 數量的差就是對照組多註冊的 callback 數；時間差就是它們的成本。")
    b_frames, o_frames = base["frames"], other["frames"]
    if b_frames and o_frames:
        b_avg, o_avg = statistics.fmean(b_frames), statistics.fmean(o_frames)
        print(f"\n每 frame 平均：{b_avg:.4f}ms → {o_avg:.4f}ms"
              f"（{o_avg - b_avg:+.4f}ms，{(o_avg / b_avg - 1) * 100:+.1f}%）")

    b_tick = base["spans"].get(TICK_SPAN, [])
    o_tick = other["spans"].get(TICK_SPAN, [])
    if b_tick and o_tick and b_frames and o_frames:
        b_per = len(b_tick) / len(b_frames)
        o_per = len(o_tick) / len(o_frames)
        b_cost = sum(b_tick) / len(b_frames)
        o_cost = sum(o_tick) / len(o_frames)
        print(f"\n{TICK_SPAN}")
        print(f"  每 frame span 數：{b_per:.1f} → {o_per:.1f}（{o_per - b_per:+.1f}）")
        print(f"  每 frame 成本  ：{b_cost:.4f}ms → {o_cost:.4f}ms（{o_cost - b_cost:+.4f}ms）")
        if o_per > b_per:
            print(f"  ⇒ 多出來的每個 callback 平均 "
                  f"{(o_cost - b_cost) / (o_per - b_per):.4f}ms/tick")
        print("\n  注意：這個差分把「對照組多裝的所有 MOD」算在一起。要單獨歸因到本 MOD，"
              "\n  兩組必須只差本 MOD 一個（本 MOD 註冊 3 個 OnTick callback：WorldScanner、"
              "\n  AnimalScanner、Client 的 flushTouch）。")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("target", type=Path, help="錄製目錄或 *_header.csv")
    parser.add_argument("--compare", type=Path, help="另一組錄製，用來做差分")
    args = parser.parse_args()

    base = summarise(args.target)
    report("基準組" if args.compare else "錄製摘要", base)
    if args.compare:
        other = summarise(args.compare)
        report("對照組", other)
        compare(base, other)
    return 0


if __name__ == "__main__":
    sys.exit(main())
