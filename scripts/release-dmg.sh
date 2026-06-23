#!/usr/bin/env bash
# 把 App 打成可拖拽安装的 DMG，并可选地发布到 GitHub Release。
#
# 用法:
#   scripts/release-dmg.sh <version>            # 仅构建 + 生成 DMG 到 dist/
#   PUBLISH=1 scripts/release-dmg.sh <version>  # 额外用 gh 创建 GitHub Release 并上传 DMG
#
# 例: scripts/release-dmg.sh 1.0.0
set -euo pipefail

VERSION="${1:?usage: $0 <version>  (例: $0 1.0.0)}"
SCHEME="FinderRightClickMenu"
APP_NAME="FinderRightClickMenu.app"
BUILD_DIR="build/release"
DIST_DIR="dist"
DMG="$DIST_DIR/FinderRightClickMenu-$VERSION.dmg"
VOLNAME="FinderRightClickMenu"

cd "$(dirname "$0")/.."

# 工程由 XcodeGen 从 project.yml 生成（不入库），先确保最新
command -v xcodegen >/dev/null 2>&1 && xcodegen generate

echo "==> Building Release ($VERSION)…"
rm -rf "$BUILD_DIR"
xcodebuild -project FinderRightClickMenu.xcodeproj \
  -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" \
  build

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"
[ -d "$APP" ] || { echo "error: 未找到 $APP" >&2; exit 1; }

echo "==> Creating DMG…"
mkdir -p "$DIST_DIR"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/frcm-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"   # 让用户把图标拖进 Applications 安装
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "    -> $DMG"

if [ "${PUBLISH:-0}" = "1" ]; then
  echo "==> Publishing GitHub Release v$VERSION…"
  gh release create "v$VERSION" "$DMG" --title "v$VERSION" --generate-notes
fi

echo "Done."
