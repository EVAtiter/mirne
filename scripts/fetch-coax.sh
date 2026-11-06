#!/bin/bash
# coax を取得して coaxd と coax をビルドし、build/coax/ に置く。
#
#   scripts/fetch-coax.sh
#
# 取得するコミットは scripts/coax.lock で固定する。
# 手元のクローンを使うときは COAX_SOURCE にそのディレクトリを渡す
# （そのクローンの作業ツリーは変更しない。指定コミットを一時的に取り出してビルドする）。
#
# coaxd は GPL-2.0-only なので、mirne のリポジトリには含めない。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# shellcheck source=coax.lock
source scripts/coax.lock

WORK="$ROOT/build/coax-src"
OUT="$ROOT/build/coax"

if [ -n "${COAX_SOURCE:-}" ]; then
    # 手元のクローンから指定コミットだけを取り出す（作業ツリーには触れない）
    rm -rf "$WORK"
    git -C "$COAX_SOURCE" archive --format=tar --prefix=coax-src/ "$COAX_COMMIT" \
        | tar -x -C "$ROOT/build"
else
    if [ ! -d "$WORK/.git" ]; then
        rm -rf "$WORK"
        git clone --quiet --filter=blob:none "$COAX_REPOSITORY" "$WORK"
    fi
    git -C "$WORK" fetch --quiet origin
    git -C "$WORK" checkout --quiet --detach "$COAX_COMMIT"
fi

mkdir -p "$OUT"

# -trimpath: 手元のパス（ユーザー名を含む）をバイナリに残さない
# CGO_ENABLED=0: coax の想定どおり外部ライブラリに依存しない静的バイナリにする
# -buildvcs=false: COAX_SOURCE（git archive）には .git が無く、版の情報を埋め込めないため
(
    cd "$WORK"
    export CGO_ENABLED=0 GOOS=darwin GOARCH=arm64
    BUILDVCS=true
    [ -d .git ] || BUILDVCS=false
    go build -trimpath -buildvcs="$BUILDVCS" -o "$OUT/coaxd" ./cmd/coaxd
    go build -trimpath -buildvcs="$BUILDVCS" -o "$OUT/coax" ./cmd/coax
)

# 手元のパスが残っていないことを確かめる。
# strings は __LINKEDIT などを読まず見落とすので、バイト列をそのまま探す
for binary in "$OUT/coaxd" "$OUT/coax"; do
    if LC_ALL=C /usr/bin/grep -a -F -q "$HOME" "$binary"; then
        echo "⚠️ $binary に手元のパスが残っている" >&2
        exit 1
    fi
done

echo "→ $(basename "$OUT")/coaxd・coax（coax ${COAX_COMMIT:0:7}）"
