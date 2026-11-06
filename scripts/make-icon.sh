#!/bin/bash
# アプリアイコンを作り直す。scripts/make-icon.swift で 1024px のマスターを描き、
# Sources/mirne/Assets.xcassets/AppIcon.appiconset に 16〜512px の @1x/@2x の 10 枚（8-bit）を置く。
#
#   scripts/make-icon.sh
#
# macOS 27 は icns だけ（CFBundleIconFile のみ）のアプリを 16/32px の表示で灰色の角丸の箱に入れるので、
# Asset Catalog（CFBundleIconName = AppIcon）にする。icns は作らない（ビルドが Asset Catalog から副生成する）。
# SMALL_16=1 のときだけ、16×16（1x）の 1 枚を余白の狭い絵にする（標準の余白の 16px が箱に入る絵のための逃げ道。
# 非 Retina の 16px が箱に入るのは不具合として扱わない方針なので、既定では使わない）
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MASTER="$WORK/master.png"
swift scripts/make-icon.swift "$MASTER" standard

APPICON=Sources/mirne/Assets.xcassets/AppIcon.appiconset
rm -rf "$APPICON"
mkdir -p "$APPICON"
for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER" --out "$APPICON/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$APPICON/icon_${size}x${size}@2x.png" >/dev/null
done
if [ "${SMALL_16:-0}" = 1 ]; then
    swift scripts/make-icon.swift "$WORK/master-16.png" small
    sips -z 16 16 "$WORK/master-16.png" --out "$APPICON/icon_16x16.png" >/dev/null
fi

# Contents.json はシェルで組み立てない（set -e の下で 1x の分岐が黙って止まることがある）
python3 - Sources/mirne/Assets.xcassets "$APPICON" <<'EOF'
import json, sys
catalog, appicon = sys.argv[1], sys.argv[2]
info = {"author": "xcode", "version": 1}
json.dump({"info": info}, open(f"{catalog}/Contents.json", "w"), indent=2)
images = [{"filename": f"icon_{s}x{s}{'@2x' if k == 2 else ''}.png", "idiom": "mac", "scale": f"{k}x", "size": f"{s}x{s}"}
          for s in (16, 32, 128, 256, 512) for k in (1, 2)]
json.dump({"images": images, "info": info}, open(f"{appicon}/Contents.json", "w"), indent=2)
EOF

echo "アイコンを生成: $APPICON"
