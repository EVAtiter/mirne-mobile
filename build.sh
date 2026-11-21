#!/bin/bash
# mirne mobile をビルドする。
#
#   ./build.sh            Debug でビルド
#   ./build.sh release    Release でビルド
#   ./build.sh test       単体試験（Tests/mirneMobileTests）を流す
#   SCHEME=mirne-mobile-probe ./build.sh   計測用のコマンドをビルド
#
# 成果物は build/symroot/<構成>/mirne mobile.app、中間ファイルは build/DerivedData に置く。
# SYMROOT を build 直下にしない理由は、build/Release が公証版の書き出し先と取り違えやすい
# （大文字小文字を区別しないファイルシステムでは build/release と同じ場所になる）ため。
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
    -project mirne-mobile.xcodeproj \
    -scheme "${SCHEME:-mirne-mobile}" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath build/DerivedData \
    SYMROOT="$PWD/build/symroot" \
    "$ACTION"

echo "→ build/symroot/$CONFIGURATION/"
