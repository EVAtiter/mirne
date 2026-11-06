#!/bin/bash
# mirne をビルドする。
#
#   ./build.sh            Debug でビルド
#   ./build.sh release    Release でビルド
#   ./build.sh test       単体試験（Tests/mirneTests）を流す
#   SCHEME=mirne-probe ./build.sh   計測用のコマンドをビルド
#
# 成果物は build/symroot/<構成>/mirne.app、中間ファイルは build/DerivedData に置く。
# SYMROOT を build 直下にしない理由は、build/Release が将来の公証版の書き出し先
# build/release と同じ場所になる（大文字小文字を区別しない）ため。
set -euo pipefail

cd "$(dirname "$0")"

ACTION=build
case "${1:-debug}" in
    debug)   CONFIGURATION=Debug ;;
    release) CONFIGURATION=Release ;;
    test)    CONFIGURATION=Debug; ACTION=test ;;
    *) echo "使い方: $0 [debug|release|test]" >&2; exit 64 ;;
esac

xcodegen generate --quiet

xcodebuild \
    -project mirne.xcodeproj \
    -scheme "${SCHEME:-mirne}" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath build/DerivedData \
    SYMROOT="$PWD/build/symroot" \
    "$ACTION"

echo "→ build/symroot/$CONFIGURATION/"
