#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="VlessMenuBar"
APP_DIR="dist/${APP_NAME}.app"

echo "==> 清除源文件的隔离属性（一次性，之后不会再复发）"
xattr -cr . 2>/dev/null || true

echo "==> swift build（分别编译 arm64 + x86_64，再合并成通用二进制）"
swift build -c "${CONFIG}" --arch arm64
swift build -c "${CONFIG}" --arch x86_64
xattr -cr .build 2>/dev/null || true

echo "==> 定位编译产物"
ARM64_BIN=""
X86_64_BIN=""
while IFS= read -r bin; do
  arch="$(lipo -archs "$bin" 2>/dev/null || true)"
  case "$arch" in
    *arm64*) ARM64_BIN="$bin" ;;
  esac
  case "$arch" in
    *x86_64*) X86_64_BIN="$bin" ;;
  esac
done < <(find .build -type f -path "*/${CONFIG}/*" -name "${APP_NAME}" -perm -u+x 2>/dev/null)

if [ -z "$ARM64_BIN" ] || [ -z "$X86_64_BIN" ]; then
  echo "错误：没能在 .build 目录下找到两种架构的可执行文件" >&2
  echo "找到的候选文件：" >&2
  find .build -type f -name "${APP_NAME}" -perm -u+x 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
echo "  arm64  -> $ARM64_BIN"
echo "  x86_64 -> $X86_64_BIN"

RESOURCE_BUNDLE="$(find .build -type d -path "*/${CONFIG}/*" -name "${APP_NAME}_VlessMenuBar.bundle" 2>/dev/null | head -1)"
if [ -z "$RESOURCE_BUNDLE" ]; then
  echo "错误：没能在 .build 目录下找到资源包 (${APP_NAME}_VlessMenuBar.bundle)，" >&2
  echo "里面应该内含两个 vless-ws-client 二进制。没有这个资源包，App 编译" >&2
  echo "出来能正常打开，但点击「连接」时会因为找不到内嵌的可执行文件而崩溃。" >&2
  exit 1
fi
echo "  资源包 -> $RESOURCE_BUNDLE"

UNIVERSAL_BIN="$(mktemp -d)/${APP_NAME}"
lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$UNIVERSAL_BIN"
echo "==> 通用二进制包含的架构：$(lipo -archs "$UNIVERSAL_BIN")"

echo "==> 组装 .app 包结构"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$UNIVERSAL_BIN" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Info.plist "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Helpers"
cp "$RESOURCE_BUNDLE/vless-ws-client-darwin-arm64" "$APP_DIR/Contents/Helpers/"
cp "$RESOURCE_BUNDLE/vless-ws-client-darwin-amd64" "$APP_DIR/Contents/Helpers/"

echo "==> 生成 App 图标 (iconutil 是 macOS 自带工具，把 iconset 转成 icns)"
if [ -d "AppIcon.iconset" ]; then
  iconutil -c icns AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "警告：没找到 AppIcon.iconset，App 会用系统默认图标" >&2
fi

echo "==> 校验：确认资源包里两个二进制确实被打包进去了"
if [ ! -f "$APP_DIR/Contents/Helpers/vless-ws-client-darwin-arm64" ] || \
   [ ! -f "$APP_DIR/Contents/Helpers/vless-ws-client-darwin-amd64" ]; then
  echo "错误：打包完成后检查发现两个 vless-ws-client 二进制不在预期位置，App 会在" >&2
  echo "点击「连接」时崩溃。请检查上面「资源包」那一行路径是否正确。" >&2
  exit 1
fi
echo "  确认无误：两个 vless-ws-client 二进制都在资源包里"

echo "==> ad-hoc 签名（不是正式开发者签名，只是让系统能正常识别/运行这个 App）"
codesign --force --sign - "$APP_DIR/Contents/Helpers/vless-ws-client-darwin-arm64"
codesign --force --sign - "$APP_DIR/Contents/Helpers/vless-ws-client-darwin-amd64"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 完成：$APP_DIR"
echo "第一次运行需要在 Finder 里右键 -> 打开，绕过 Gatekeeper 的未知开发者拦截。"
echo "或者命令行执行： xattr -cr \"$APP_DIR\""
echo
echo "如果 Dock/访达里图标还是显示旧的（系统图标缓存问题），可以试试："
echo "  killall Dock && killall Finder"
