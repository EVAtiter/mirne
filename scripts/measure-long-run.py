#!/usr/bin/env python3
"""長時間の計測：mirne のプロセス（と子の coaxd・coax pcsc）の CPU とメモリを記録する。

  scripts/measure-long-run.py <出力フォルダー> <時間（秒）> [--lab-pid N]

スリープさせないように caffeinate の下で動かす（例: caffeinate -dis scripts/measure-long-run.py build/long-run 32400）

- 視聴の mirne（--lab-pid 以外の mirne）は、起動し直されても探し直して続ける
- 外部フィルタのプロセスは記録しない（mirne のプロセスと coaxd・coax pcsc だけ）
- CPU は ps の累計 CPU 時間の差から求める（1 コア = 100%）
"""
import csv
import os
import subprocess
import sys
import time
from datetime import datetime

# 記録の間隔
PS_INTERVAL = 30          # CPU と RSS
FOOTPRINT_INTERVAL = 300  # footprint（5 分）
HEAP_FIRST = 600          # 最初の heap（立ち上がりが落ち着いてから。10 分）
HEAP_INTERVAL = 14400     # 以後の heap（4 時間。heap は数え終わるまでプロセスを止めるので回数を絞る）

APP_SUFFIX = "mirne.app/Contents/MacOS/mirne"
CHILD_NAMES = ("coaxd", "coax")


def run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=120).stdout
    except Exception as error:  # noqa: BLE001
        return f"(失敗: {error})"


def processes():
    """pid → (ppid, 累計 CPU 秒, RSS KB, コマンド)"""
    out = run(["ps", "-axo", "pid=,ppid=,time=,rss=,comm="])
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, ppid, cputime, rss, comm = parts
        table[int(pid)] = (int(ppid), parse_cputime(cputime), int(rss), comm)
    return table


def parse_cputime(text):
    # 例: 0:01.23 / 125:03.21 / 1-02:03:04（日付き）
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return days * 86400 + seconds


def footprint_mb(pid):
    out = run(["footprint", "-p", str(pid)])
    for line in out.splitlines():
        if "Footprint:" in line:
            value = line.split("Footprint:")[1].split("(")[0].strip()  # 「154 MB」
            number, unit = value.split()
            scale = {"KB": 1 / 1024, "MB": 1, "GB": 1024}.get(unit, 1)
            return float(number) * scale
    return None


def main():
    folder, duration = sys.argv[1], float(sys.argv[2])
    lab_pid = int(sys.argv[sys.argv.index("--lab-pid") + 1]) if "--lab-pid" in sys.argv else None
    os.makedirs(folder, exist_ok=True)
    samples = open(os.path.join(folder, "samples.csv"), "a", newline="")
    writer = csv.writer(samples)
    if samples.tell() == 0:
        writer.writerow(["時刻", "経過秒", "役割", "pid", "コマンド", "CPU%", "RSS_MB", "footprint_MB"])
    events = open(os.path.join(folder, "events.log"), "a")

    def event(text):
        events.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {text}\n")
        events.flush()

    started = time.time()
    previous = {}          # pid → (時刻, 累計 CPU 秒)
    last_footprint = {}    # pid → 時刻
    next_heap = {}         # 役割 → 時刻（mirne の起動から数える）
    known = {}             # 役割 → pid
    event(f"記録を始める（{duration / 3600:.1f} 時間・ラボ pid {lab_pid}）")

    while time.time() - started < duration:
        now = time.time()
        table = processes()
        mirnes = [pid for pid, (_, _, _, comm) in table.items() if comm.endswith(APP_SUFFIX)]
        roles = {}
        if lab_pid in mirnes:
            roles["lab"] = lab_pid
        viewers = [pid for pid in mirnes if pid != lab_pid]
        if viewers:
            roles["viewer"] = max(viewers)
        for role, pid in list(roles.items()):
            if known.get(role) != pid:
                event(f"{role} の mirne を見つけた: pid {pid}")
                known[role] = pid
                next_heap[role] = now + HEAP_FIRST
            for child, (ppid, _, _, comm) in table.items():
                if ppid == pid and os.path.basename(comm) in CHILD_NAMES:
                    roles[f"{role}/{os.path.basename(comm)}"] = child
        for role in [r for r in known if r not in roles]:
            event(f"{role} の mirne（pid {known.pop(role)}）が終わった")
        for role, pid in roles.items():
            _, cpu, rss, comm = table[pid]
            percent = ""
            if pid in previous:
                t0, c0 = previous[pid]
                if now > t0:
                    percent = f"{(cpu - c0) / (now - t0) * 100:.1f}"
            previous[pid] = (now, cpu)
            fp = ""
            if now - last_footprint.get(pid, 0) >= FOOTPRINT_INTERVAL:
                value = footprint_mb(pid)
                fp = f"{value:.1f}" if value is not None else ""
                last_footprint[pid] = now
            writer.writerow([f"{datetime.now():%H:%M:%S}", int(now - started), role, pid, os.path.basename(comm),
                             percent, f"{rss / 1024:.1f}", fp])
            if role in next_heap and now >= next_heap[role]:
                stamp = f"{datetime.now():%H%M}"
                with open(os.path.join(folder, f"heap-{role}-{stamp}.txt"), "w") as f:
                    f.write(run(["heap", "-s", str(pid)]))
                with open(os.path.join(folder, f"vmmap-{role}-{stamp}.txt"), "w") as f:
                    f.write(run(["vmmap", "--summary", str(pid)]))
                event(f"{role} の heap と vmmap を取った（{stamp}）")
                next_heap[role] = now + HEAP_INTERVAL
        samples.flush()
        time.sleep(PS_INTERVAL)
    # 終わりの heap（最初の heap と比べる）
    for role, pid in known.items():
        with open(os.path.join(folder, f"heap-{role}-end.txt"), "w") as f:
            f.write(run(["heap", "-s", str(pid)]))
        with open(os.path.join(folder, f"vmmap-{role}-end.txt"), "w") as f:
            f.write(run(["vmmap", "--summary", str(pid)]))
    event("記録を終える")


if __name__ == "__main__":
    main()
