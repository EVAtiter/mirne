#!/bin/bash
# ビルドした .app の実行ファイルに、個人の情報が残っていないかを調べる。
#
#   scripts/check-binary.sh build/symroot/Release/mirne.app
#
# .app の中の Mach-O をすべて調べ、ホームのパスと、.leakcheck.local があればそのパターンを探す。
# コード署名の中（証明書の名義・Team ID）は署名の仕組み上必ず入るので、
# 「本体」と「署名」を分けて数え、本体に 1 つでもあれば失敗にする。
#
# strings は __LINKEDIT（シンボル情報）を読まずに見落とすので使わない。
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:?使い方: $0 <path/to/mirne.app>}"

python3 -I - "$APP" "$HOME" .leakcheck.local <<'PYTHON'
import os, re, subprocess, sys

app, home, pattern_file = sys.argv[1], sys.argv[2], sys.argv[3]

patterns = [re.escape(home.encode())]
if os.path.exists(pattern_file):
    for line in open(pattern_file, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            patterns.append(line.encode())
else:
    print(f"⚠️ {pattern_file} が無いので、ホームのパスだけを調べる", file=sys.stderr)
expression = re.compile(b"|".join(b"(?:%s)" % p for p in patterns), re.IGNORECASE)

def signature_offset(path):
    """LC_CODE_SIGNATURE の開始位置（署名が無ければ末尾）"""
    listing = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    found = re.search(r"LC_CODE_SIGNATURE\n\s+cmdsize \d+\n\s+dataoff (\d+)", listing)
    return int(found.group(1)) if found else os.path.getsize(path)

def is_macho(path):
    with open(path, "rb") as handle:
        magic = handle.read(4)
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca")

failed = False
for root, _, files in os.walk(app):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path) or not is_macho(path):
            continue
        data = open(path, "rb").read()
        boundary = signature_offset(path)
        body = sum(1 for m in expression.finditer(data) if m.start() < boundary)
        signature = sum(1 for m in expression.finditer(data) if m.start() >= boundary)
        mark = "✗" if body else "✓"
        print(f"{mark} {os.path.relpath(path, app)}: 本体 {body} 箇所・署名 {signature} 箇所")
        failed = failed or body > 0

if failed:
    print("✗ 実行ファイルの本体に個人の情報が残っている", file=sys.stderr)
    sys.exit(1)
print("✓ 本体に個人の情報は無い（署名の中の名義は、Developer ID で署名する限り必ず入る）")
PYTHON
