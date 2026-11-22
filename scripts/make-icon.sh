#!/bin/bash
# アプリアイコンを作り直す。scripts/make-icon.swift で 1024px のマスターを描き、
# Sources/App/Assets.xcassets/AppIcon.appiconset に 16〜512px の @1x/@2x の 10 枚（8-bit）を置く（macOS 版）。
# iPad 版は Sources/iOSApp/Assets.xcassets/AppIcon.appiconset に 1024px の 1 枚（透過なし・角丸なし）を置く。
#
#   scripts/make-icon.sh          両方
#   scripts/make-icon.sh macos    macOS 版だけ
#   scripts/make-icon.sh ios      iPad 版だけ
#
# macOS 27 は icns だけ（CFBundleIconFile のみ）のアプリを 16/32px の表示で灰色の角丸の箱に入れるので、
# Asset Catalog（CFBundleIconName = AppIcon）にする。icns は作らない（ビルドが Asset Catalog から副生成する）。
# 16×16（1x）の 1 枚だけは sips ではなく面積平均で縮める（scripts/area-downscale.swift）。sips で縮めると板の縁が
# ぼやけ、macOS 27 の形の検出が「角丸 0 の四角」と判定して、非 Retina の 16px の表示を灰色の箱に入れるため。
# SMALL_16=1 のときは、16×16 を余白の狭い絵にする（面積平均で原因が分かる前の逃げ道。既定では使わない）
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-all}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# iPad 版：1024px の 1 枚だけ（iOS は Asset Catalog だけが経路で、角丸は OS が切り抜く）
make_ios() {
    local catalog=Sources/iOSApp/Assets.xcassets
    local appicon="$catalog/AppIcon.appiconset"
    rm -rf "$appicon"
    mkdir -p "$appicon"
    swift scripts/make-icon.swift "$appicon/AppIcon-1024.png" ios
    python3 - "$catalog" "$appicon" <<'EOF'
import json, sys
catalog, appicon = sys.argv[1], sys.argv[2]
info = {"author": "xcode", "version": 1}
json.dump({"info": info}, open(f"{catalog}/Contents.json", "w"), indent=2)
images = [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
json.dump({"images": images, "info": info}, open(f"{appicon}/Contents.json", "w"), indent=2)
EOF
    echo "アイコンを生成: $appicon"
}

if [ "$TARGET" = ios ]; then
    make_ios
    exit 0
fi

MASTER="$WORK/master.png"
swift scripts/make-icon.swift "$MASTER" standard

APPICON=Sources/App/Assets.xcassets/AppIcon.appiconset
rm -rf "$APPICON"
mkdir -p "$APPICON"
for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER" --out "$APPICON/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$APPICON/icon_${size}x${size}@2x.png" >/dev/null
done
# 16×16（1x）だけ面積平均で作り直す（上の説明）。32px 以上は sips のままで箱に入らない
swift scripts/area-downscale.swift "$MASTER" 16 "$APPICON/icon_16x16.png"
if [ "${SMALL_16:-0}" = 1 ]; then
    swift scripts/make-icon.swift "$WORK/master-16.png" small
    sips -z 16 16 "$WORK/master-16.png" --out "$APPICON/icon_16x16.png" >/dev/null
fi

# Contents.json はシェルで組み立てない（set -e の下で 1x の分岐が黙って止まることがある）
python3 - Sources/App/Assets.xcassets "$APPICON" <<'EOF'
import json, sys
catalog, appicon = sys.argv[1], sys.argv[2]
info = {"author": "xcode", "version": 1}
json.dump({"info": info}, open(f"{catalog}/Contents.json", "w"), indent=2)
images = [{"filename": f"icon_{s}x{s}{'@2x' if k == 2 else ''}.png", "idiom": "mac", "scale": f"{k}x", "size": f"{s}x{s}"}
          for s in (16, 32, 128, 256, 512) for k in (1, 2)]
json.dump({"images": images, "info": info}, open(f"{appicon}/Contents.json", "w"), indent=2)
EOF

echo "アイコンを生成: $APPICON"

if [ "$TARGET" = all ]; then
    make_ios
fi
