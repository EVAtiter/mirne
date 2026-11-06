#!/bin/bash
# 自分用の公証済みの mirne.app を作る。
#
#   scripts/notarize.sh
#
# archive → Developer ID で書き出し → 署名の確認 → 公証（notarytool）→ staple → Gatekeeper の確認、の順に行い、
# build/notarized/mirne.app に置く。バイナリは配布しないので、配布用の zip は作らない。
#
# 要るもの（どれもリポジトリに書かない）:
#   Config/Local.xcconfig の DEVELOPMENT_TEAM・CODE_SIGN_IDENTITY（Developer ID Application）・
#   NOTARY_KEYCHAIN_PROFILE（xcrun notarytool store-credentials で登録したプロファイル名）
#   build/coax/coaxd・coax（scripts/fetch-coax.sh）
#
# 書き出し先を build/release にしないのは、build.sh の SYMROOT が build/symroot でも、構成名（Release）と
# 大文字小文字だけ違う名前は取り違えやすいため（Mac の既定のファイルシステムでは同じ場所になる）
set -euo pipefail
cd "$(dirname "$0")/.."

LOCAL=Config/Local.xcconfig
ARCHIVE=build/mirne.xcarchive
EXPORT=build/notarized
APP="$EXPORT/mirne.app"

# xcconfig から値を読む（「キー = 値」の形。// の行は飛ばす）
setting() {
    [ -f "$LOCAL" ] || return 0
    sed -nE "s|^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$|\1|p" "$LOCAL" | tail -1
}

# ── 長いビルドの前に、要るものが揃っているかを確かめる ──
TEAM=$(setting DEVELOPMENT_TEAM)
IDENTITY=$(setting CODE_SIGN_IDENTITY)
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-$(setting NOTARY_KEYCHAIN_PROFILE)}"
fail() { echo "error: $*" >&2; exit 1; }
[ -n "$TEAM" ] || fail "$LOCAL に DEVELOPMENT_TEAM がありません（雛形は Config/Local.xcconfig.example）"
case "$IDENTITY" in "Developer ID Application"*) ;; *) fail "$LOCAL の CODE_SIGN_IDENTITY が Developer ID Application ではありません" ;; esac
[ -n "$PROFILE" ] || fail "$LOCAL に NOTARY_KEYCHAIN_PROFILE がありません"
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || fail "キーチェーンに証明書がありません"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "notarytool のプロファイルが使えません"
for name in coaxd coax; do
    [ -x "build/coax/$name" ] || fail "build/coax/$name がありません。先に scripts/fetch-coax.sh を実行してください"
done

# ── archive（SYMROOT は付けない。archive では BuildProductsPath のエラーになることがある） ──
xcodegen generate --quiet
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project mirne.xcodeproj -scheme mirne -configuration Release \
    -derivedDataPath build/DerivedData -archivePath "$ARCHIVE" archive -quiet

# ── Developer ID で書き出す（ExportOptions はチームを含むので build/ に作る。コミットしない） ──
OPTIONS=build/ExportOptions-developer-id.plist
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OPTIONS" -quiet

# ── 署名の確認：本体と同梱物が Developer ID・Hardened Runtime・タイムスタンプ付きで、get-task-allow が無い ──
codesign --verify --deep --strict "$APP"
for code in "$APP" "$APP/Contents/Helpers/coaxd" "$APP/Contents/Helpers/coax"; do
    info=$(codesign -dvv "$code" 2>&1)
    echo "$info" | grep -q "^Authority=Developer ID Application" || fail "$code が Developer ID で署名されていません"
    echo "$info" | grep -q "flags=.*runtime" || fail "$code に Hardened Runtime がありません"
    echo "$info" | grep -q "^Timestamp=" || fail "$code にタイムスタンプがありません"
done
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    fail "$APP に get-task-allow が残っています"
fi
scripts/check-binary.sh "$APP"

# ── 公証（送る zip は staple の前に作り、送ったら捨てる） ──
SUBMIT=$(mktemp -d)/mirne-submit.zip
ditto -c -k --keepParent "$APP" "$SUBMIT"
RESULT=$(xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format plist)
rm -f "$SUBMIT"
STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" /dev/stdin <<<"$RESULT")
ID=$(/usr/libexec/PlistBuddy -c "Print :id" /dev/stdin <<<"$RESULT")
if [ "$STATUS" != Accepted ]; then
    echo "公証が通りませんでした（$STATUS）。理由:" >&2
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    exit 1
fi

# ── staple と Gatekeeper の確認 ──
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
echo "→ $APP（$VERSION build $BUILD・公証済み）"
