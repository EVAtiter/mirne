#!/bin/bash
# Xcode のビルドフェーズから呼ばれ、coaxd・coax を .app の Contents/Helpers に入れて署名する。
#
# 入れ子の実行ファイルはアプリ本体と同じ証明書・Hardened Runtime で署名する。
# 公証では入れ子のコードにも安全なタイムスタンプが要るので、archive（ACTION=install。scripts/notarize.sh）で
# 証明書を使うときだけ付ける。ふだんのビルドは速さのため付けない（Xcode の build も本体を --timestamp=none で署名する）
set -euo pipefail

SOURCE_DIR="$SRCROOT/build/coax"
HELPERS_DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"

for name in coaxd coax; do
    if [ ! -x "$SOURCE_DIR/$name" ]; then
        echo "error: $SOURCE_DIR/$name がありません。先に scripts/fetch-coax.sh を実行してください" >&2
        exit 1
    fi
done

TIMESTAMP=--timestamp=none
if [ "${ACTION:-}" = install ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != - ]; then
    TIMESTAMP=--timestamp
fi

mkdir -p "$HELPERS_DIR"
for name in coaxd coax; do
    install -m 0755 "$SOURCE_DIR/$name" "$HELPERS_DIR/$name"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$TIMESTAMP" \
        "$HELPERS_DIR/$name"
done
