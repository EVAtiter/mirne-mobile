#!/bin/bash
# iPad 版のビルドの後の段：scripts/build-ffmpeg-ios.sh が組んだ FFmpeg のフレームワーク（avutil・avcodec）を、
# アプリ（試験ならその束）の Frameworks に写して署名する。Xcode のビルドの段から呼ぶ（Xcode の環境変数を使う）。
#
# xcframework として登録すると、ビルドを始める前に Xcode がその在りかを確かめるので、FFmpeg を組む前の状態から
# ビルドできない。そのため、つなぐのは設定（FRAMEWORK_SEARCH_PATHS と -framework）で、同梱はこの段で行う
set -euo pipefail

SOURCE="$SRCROOT/build/ffmpeg/frameworks/$PLATFORM_NAME"
DESTINATION="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DESTINATION"

for name in avutil avcodec; do
  if [[ ! -d "$SOURCE/$name.framework" ]]; then
    echo "error: FFmpeg の $name.framework が無い（scripts/build-ffmpeg-ios.sh を流す）: $SOURCE" >&2
    exit 1
  fi
  rm -rf "$DESTINATION/$name.framework"
  cp -R "$SOURCE/$name.framework" "$DESTINATION/"
  # 署名しないビルド（CODE_SIGNING_ALLOWED が NO）では署名しない。シミュレータは「-」（その場の署名）になる
  if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$DESTINATION/$name.framework"
  fi
done
