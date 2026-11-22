#!/bin/bash
# iPad 版の署名なしの IPA を作り、同じ Release に添える FFmpeg のソースを並べる。
#
#   scripts/build-ipa.sh
#
# 出力（build/ipa）:
#   mirne-mobile-<版>.ipa     署名していない IPA。使う人が LiveContainer・AltStore などで自分で署名して入れる
#   ffmpeg-<版>.tar.xz        同梱した FFmpeg のソース（ffmpeg.org のものそのまま。LGPL-2.1 のため IPA と同じ場所に置く）
#
# archive（Release・署名なし）→ Payload にまとめて zip → 中身の検査（版・最低 OS・arm64・FFmpeg のフレームワーク・
# ライセンスの全文・NOTICE・署名が無いこと・個人の情報）の順に行う
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=build/ipa
ARCHIVE="$OUT/mirne-mobile-iOS.xcarchive"
WORK="$OUT/work"
# 同梱する FFmpeg の版と sha256 は、組むスクリプトの値を使う（2 か所に書かない）
FFMPEG_VERSION="$(sed -n 's/^FFMPEG_VERSION="\(.*\)"$/\1/p' scripts/build-ffmpeg-ios.sh)"
FFMPEG_SHA256="$(sed -n 's/^FFMPEG_SHA256="\(.*\)"$/\1/p' scripts/build-ffmpeg-ios.sh)"
FFMPEG_TARBALL="build/ffmpeg/src/ffmpeg-${FFMPEG_VERSION}.tar.xz"
# 配る IPA に入っているべき対応 OS の下限（project.yml の IPHONEOS_DEPLOYMENT_TARGET と同じ）
EXPECTED_MIN_OS="18.0"

rm -rf "$OUT"
mkdir -p "$WORK/Payload"

xcodegen generate --quiet

# ── archive（署名しない。SYMROOT は付けない。archive では BuildProductsPath のエラーになることがある） ──
xcodebuild -project mirne-mobile.xcodeproj -scheme mirne-mobile-iOS -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    archive -quiet

APP_NAME="mirne mobile.app"
cp -R "$ARCHIVE/Products/Applications/$APP_NAME" "$WORK/Payload/"
APP="$WORK/Payload/$APP_NAME"
PLIST="$APP/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"

# ── 中身の検査 ──
fail() { echo "✗ $*" >&2; exit 1; }
[ "$MIN_OS" = "$EXPECTED_MIN_OS" ] || fail "最低 OS が $MIN_OS（$EXPECTED_MIN_OS のはず）"
lipo -archs "$APP/mirne mobile" | grep -qx arm64 || fail "実行ファイルが arm64 だけではない"
for name in avcodec avutil; do
    [ -f "$APP/Frameworks/$name.framework/$name" ] || fail "$name.framework が入っていない"
done
[ -f "$APP/FFmpeg-COPYING.LGPLv2.1.txt" ] || fail "LGPL-2.1 の全文が入っていない"
[ -f "$APP/NOTICE" ] || fail "NOTICE が入っていない"
[ -f "$APP/Assets.car" ] || fail "アイコン（Assets.car）が入っていない"
[ ! -e "$APP/embedded.mobileprovision" ] || fail "プロビジョニングプロファイルが入っている（署名なしのはず）"
[ ! -d "$APP/_CodeSignature" ] || fail "署名が入っている（署名なしのはず）"
scripts/check-binary.sh "$APP"

# ── IPA（Payload を zip にしたもの） ──
IPA="$OUT/mirne-mobile-${VERSION}.ipa"
(cd "$WORK" && ditto -c -k --norsrc --keepParent Payload "../$(basename "$IPA")")

# ── FFmpeg のソース（照合してから写す） ──
[ -f "$FFMPEG_TARBALL" ] || fail "FFmpeg のソースが無い（scripts/build-ffmpeg-ios.sh を流す）: $FFMPEG_TARBALL"
[ "$(shasum -a 256 "$FFMPEG_TARBALL" | cut -d' ' -f1)" = "$FFMPEG_SHA256" ] || fail "FFmpeg のソースの sha256 が合わない"
cp "$FFMPEG_TARBALL" "$OUT/"

rm -rf "$WORK"
echo "→ $IPA（$VERSION build $BUILD・最低 iPadOS $MIN_OS）"
shasum -a 256 "$IPA" "$OUT/ffmpeg-${FFMPEG_VERSION}.tar.xz"
