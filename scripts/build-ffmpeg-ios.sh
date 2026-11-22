#!/bin/bash
# iPad 版に同梱する FFmpeg（libavcodec の mpeg2video の復号器だけ）を組む。
#
# iOS / iPadOS の VideoToolbox には MPEG-2 の映像の復号器が無いので、地上デジタル放送の MPEG-2 は FFmpeg で復号する。
# - 版と sha256 を固定して ffmpeg.org から取り、照合してから組む
# - LGPL-2.1 のまま組む（--enable-gpl・--enable-nonfree を付けない）。動的なフレームワークにして、アプリとは別のファイルで同梱する
# - 実機（iphoneos）とシミュレータ（iphonesimulator）の arm64 を組み、SDK ごとに avcodec.framework・avutil.framework を作る
#   （build/ffmpeg/frameworks/<SDK>。アプリへの同梱はビルドの後の段で scripts/embed-ffmpeg-ios.sh が行う）
# - 出力は build/ffmpeg（git には入れない）
#
# 使い方：
#   scripts/build-ffmpeg-ios.sh              組み直す
#   scripts/build-ffmpeg-ios.sh --if-missing 組んだ物が今の設定と合っていれば何もしない（ビルドの前に呼ぶ）
set -euo pipefail

# 組む FFmpeg（版を替えたら sha256 も替える。sha256 は配布元のファイルから自分で計って確かめる）
FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
# iPad 版の対応 OS の下限（project.yml の IPHONEOS_DEPLOYMENT_TARGET と揃える）
MIN_IOS="18.0"
# フレームワークの Bundle ID の頭
BUNDLE_PREFIX="com.slack-kingdom.mirne-mobile.ffmpeg"
# configure の --prefix。FFmpeg は configure の引数をライブラリの中に書き込む（avcodec_configuration）ので、
# 手元のパス（ホームの下）を入れないよう決まった仮の場所にし、実際の置き場は make install の DESTDIR で渡す
INSTALL_PREFIX="/ffmpeg"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ffmpeg"
SRC_DIR="$OUT/src"
SRC="$SRC_DIR/ffmpeg-${FFMPEG_VERSION}"
TARBALL="$SRC_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
STAMP="$OUT/stamp"

# configure の引数（mpeg2video の復号器と MPEG の映像のパーサーだけ。ほかは全部外す）
CONFIGURE_FLAGS=(
  --enable-cross-compile --target-os=darwin --arch=aarch64
  --enable-pic --enable-shared --disable-static
  --disable-everything --disable-autodetect
  --disable-programs --disable-doc --disable-network
  --disable-avdevice --disable-avformat --disable-avfilter
  --disable-swscale --disable-swresample
  --enable-decoder=mpeg2video --enable-parser=mpegvideo
)

# 組んだ物が、いまの版・設定・このスクリプトと合っているかの印
expected_stamp() {
  { echo "$FFMPEG_VERSION $FFMPEG_SHA256 $MIN_IOS"; printf '%s\n' "${CONFIGURE_FLAGS[@]}"; shasum -a 256 "$0" | cut -d' ' -f1; } | shasum -a 256 | cut -d' ' -f1
}

if [[ "${1:-}" == "--if-missing" ]]; then
  if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$(expected_stamp)" \
        && -d "$OUT/frameworks/iphoneos/avcodec.framework" && -d "$OUT/frameworks/iphonesimulator/avcodec.framework" ]]; then
    exit 0
  fi
  echo "FFmpeg を組む（初めて、または版・設定が変わった）"
fi

# ソースを取り、照合して展開する
mkdir -p "$SRC_DIR"
if [[ ! -f "$TARBALL" ]] || ! echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - > /dev/null 2>&1; then
  rm -f "$TARBALL"
  curl -sSfL -o "$TARBALL" "$FFMPEG_URL"
fi
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c - > /dev/null || { echo "sha256 が合わない: $TARBALL" >&2; exit 1; }
if [[ ! -d "$SRC" ]]; then
  tar -xf "$TARBALL" -C "$SRC_DIR"
fi

# 1 つの SDK 向けに組んで、libavcodec と libavutil をフレームワークにする
build_platform() {
  local sdk=$1 target=$2 platform_name=$3
  local work="$OUT/work/$sdk" destdir="$OUT/install/$sdk" frameworks="$OUT/frameworks/$sdk"
  local prefix="$destdir$INSTALL_PREFIX"
  rm -rf "$work" "$destdir" "$frameworks"
  mkdir -p "$work" "$destdir" "$frameworks"
  local sysroot cc
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  (
    cd "$work"
    # configure と make は、まっさらな環境変数で流す。configure は環境変数を ffbuild/config.log に書き写すので、
    # 呼んだ側（端末・Xcode）の環境変数を持ち込むと、作業用の値がファイルに残る。Xcode の SDKROOT・ARCHS などが
    # 組み方に混ざるのも防ぐ
    clean_env=(env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}")
    if [[ -n "${DEVELOPER_DIR:-}" ]]; then clean_env+=(DEVELOPER_DIR="$DEVELOPER_DIR"); fi
    "${clean_env[@]}" "$SRC/configure" --prefix="$INSTALL_PREFIX" --cc="$cc" --sysroot="$sysroot" \
      --extra-cflags="-target $target" \
      --extra-ldflags="-target $target -Wl,-headerpad_max_install_names" \
      "${CONFIGURE_FLAGS[@]}" > "$work/configure.log" 2>&1 || { tail -30 "$work/configure.log" >&2; exit 1; }
    # LGPL のまま組めていることを確かめる（GPL・nonfree が入っていたら止める）
    grep -q "^#define CONFIG_GPL 0" config.h && grep -q "^#define CONFIG_NONFREE 0" config.h \
      || { echo "GPL か nonfree が有効になっている" >&2; exit 1; }
    "${clean_env[@]}" make -j"$(sysctl -n hw.ncpu)" > "$work/make.log" 2>&1 || { tail -30 "$work/make.log" >&2; exit 1; }
    "${clean_env[@]}" make install DESTDIR="$destdir" > "$work/install.log" 2>&1
  )

  local avutil_id
  avutil_id="$(otool -D "$prefix/lib/libavutil.dylib" | tail -1)"
  for name in avutil avcodec; do
    local framework="$frameworks/$name.framework"
    mkdir -p "$framework"
    cp -L "$prefix/lib/lib$name.dylib" "$framework/$name"
    install_name_tool -id "@rpath/$name.framework/$name" "$framework/$name"
    if [[ "$name" == "avcodec" ]]; then
      install_name_tool -change "$avutil_id" "@rpath/avutil.framework/avutil" "$framework/$name"
    fi
    /usr/libexec/PlistBuddy -c "Clear dict" \
      -c "Add :CFBundleDevelopmentRegion string en" \
      -c "Add :CFBundleExecutable string $name" \
      -c "Add :CFBundleIdentifier string $BUNDLE_PREFIX.$name" \
      -c "Add :CFBundleInfoDictionaryVersion string 6.0" \
      -c "Add :CFBundleName string $name" \
      -c "Add :CFBundlePackageType string FMWK" \
      -c "Add :CFBundleShortVersionString string $FFMPEG_VERSION" \
      -c "Add :CFBundleVersion string $FFMPEG_VERSION" \
      -c "Add :CFBundleSupportedPlatforms array" \
      -c "Add :CFBundleSupportedPlatforms:0 string $platform_name" \
      -c "Add :MinimumOSVersion string $MIN_IOS" \
      "$framework/Info.plist" > /dev/null 2>&1 || true
  done
}

build_platform iphoneos "arm64-apple-ios$MIN_IOS" iPhoneOS
build_platform iphonesimulator "arm64-apple-ios$MIN_IOS-simulator" iPhoneSimulator

# 見出し（どちらの SDK でも同じ）
rm -rf "$OUT/include"
cp -R "$OUT/install/iphoneos$INSTALL_PREFIX/include" "$OUT/include"

# 中間物を消す（展開したソース・configure と make の作業フォルダー・install 先）。残すのは、取ったソースの
# 圧縮ファイル・見出し・フレームワークだけ。漏れ検査（gitleaks dir）が FFmpeg のソースの中の鍵に似た文字列を拾わないように
rm -rf "$OUT/work" "$OUT/install" "$SRC"

expected_stamp > "$STAMP"
echo "FFmpeg $FFMPEG_VERSION（mpeg2video だけ・LGPL-2.1）を組んだ: $OUT"
