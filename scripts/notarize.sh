#!/bin/bash
# 公証済みの mirne mobile.app と配布用の zip を作る（mirne の同名のスクリプトから、同梱物の扱いを除いたもの）。
#
#   scripts/notarize.sh
#
# archive → Developer ID で書き出し → 署名の確認 → バイナリの検査 → 公証（notarytool）→ staple →
# Gatekeeper の確認、の順に行い、build/notarized/mirne mobile.app に置く。
# 配布用の zip（build/notarized/mirne-mobile-<版>.zip）は staple の後に作る（チケットを含めるため）。
#
# 要るもの（どれもリポジトリに書かない）:
#   Config/Local.xcconfig の DEVELOPMENT_TEAM・CODE_SIGN_IDENTITY（Developer ID Application）・
#   NOTARY_KEYCHAIN_PROFILE（xcrun notarytool store-credentials で登録したプロファイル名）
#
# 書き出し先を build/release にしないのは、構成名（Release）と大文字小文字だけ違う名前は取り違えやすいため
# （Mac の既定のファイルシステムでは同じ場所になる）
set -euo pipefail
cd "$(dirname "$0")/.."

LOCAL=Config/Local.xcconfig
ARCHIVE=build/mirne-mobile.xcarchive
EXPORT=build/notarized
APP="$EXPORT/mirne mobile.app"

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

# ── archive（SYMROOT は付けない。archive では BuildProductsPath のエラーになることがある） ──
xcodegen generate --quiet
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project mirne-mobile.xcodeproj -scheme mirne-mobile -configuration Release \
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

# ── 署名の確認：Developer ID・Hardened Runtime・タイムスタンプ付きで、get-task-allow が無い ──
codesign --verify --deep --strict "$APP"
info=$(codesign -dvv "$APP" 2>&1)
echo "$info" | grep -q "^Authority=Developer ID Application" || fail "$APP が Developer ID で署名されていません"
echo "$info" | grep -q "flags=.*runtime" || fail "$APP に Hardened Runtime がありません"
echo "$info" | grep -q "^Timestamp=" || fail "$APP にタイムスタンプがありません"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    fail "$APP に get-task-allow が残っています"
fi
scripts/check-binary.sh "$APP"

# ── 公証（送る zip は staple の前に作り、送ったら捨てる） ──
SUBMIT=$(mktemp -d)/mirne-mobile-submit.zip
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

# ── 配布用の zip（展開すると mirne mobile.app が出る形） ──
ZIP="$EXPORT/mirne-mobile-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "→ $APP（$VERSION build $BUILD・公証済み）"
echo "→ $ZIP（SHA-256 $(shasum -a 256 "$ZIP" | awk '{print $1}')）"
