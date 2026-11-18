#!/usr/bin/env bash
# 墨阅 Inkwell —— macOS 一键出 IPA
#
# 用法：
#   ./scripts/build_ipa.sh                 # 出未签名 IPA
#   ./scripts/build_ipa.sh --sign          # 用本机开发者证书签名
#   ./scripts/build_ipa.sh --sign --team ABCD123456
#
# 产物：dist/Inkwell-<version>-<timestamp>.ipa

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN=false
TEAM=""
IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN=true; shift ;;
    --team) TEAM="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖: $1"; exit 1; }; }
need xcodebuild
need xcodegen
need zip
need plutil

VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*"\(.*\)".*/\1/' || echo 1.0.0)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="$ROOT/build"
DIST="$ROOT/dist"
ARCHIVE="$BUILD_DIR/Inkwell.xcarchive"
mkdir -p "$BUILD_DIR" "$DIST"

echo "==> 1/5 生成 Xcode 工程"
xcodegen generate --spec project.yml

echo "==> 2/5 解析依赖"
xcodebuild -resolvePackageDependencies -project Inkwell.xcodeproj -scheme Inkwell

echo "==> 3/5 归档（Release / arm64）"
rm -rf "$ARCHIVE"
if [[ "$SIGN" == true && -n "$IDENTITY" ]]; then
  xcodebuild archive \
    -project Inkwell.xcodeproj -scheme Inkwell \
    -configuration Release -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM"
else
  xcodebuild archive \
    -project Inkwell.xcodeproj -scheme Inkwell \
    -configuration Release -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_OPTIMIZATION_LEVEL="-Osize"
fi

APP="$ARCHIVE/Products/Applications/Inkwell.app"
[[ -d "$APP" ]] || { echo "归档里没有 Inkwell.app"; exit 1; }

echo "==> 4/5 打包 Payload"
STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

if [[ "$SIGN" == true && -n "$IDENTITY" ]]; then
  echo "    重签：$IDENTITY"
  codesign --force --deep --sign "$IDENTITY" \
    --entitlements "$ROOT/entitlements.plist" \
    "$STAGE/Payload/Inkwell.app"
  codesign --verify --deep --strict "$STAGE/Payload/Inkwell.app" && echo "    签名校验通过"
else
  # 未签名包：把归档阶段可能残留的签名去掉，交给侧载工具重新签
  codesign --remove-signature "$STAGE/Payload/Inkwell.app/Inkwell" 2>/dev/null || true
fi

OUT="$DIST/Inkwell-${VERSION}-${STAMP}$([[ "$SIGN" == true ]] && echo '-signed' || echo '-unsigned').ipa"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" Payload )

echo "==> 5/5 完成"
ls -lh "$OUT"
echo
echo "产物：$OUT"
if [[ "$SIGN" == false ]]; then
  echo "下一步：用 Sideloadly / SideStore / AltStore 侧载这个未签名 IPA。"
fi
