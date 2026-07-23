#!/usr/bin/env bash
# 把 SwiftPM 编译出来的可执行文件，组装成一个正经的 macOS .app 包。
#
# 为什么需要这一步而不是直接运行 `swift build` 出来的二进制：
#   1. 开机自启动（SMAppService）要求 Bundle.main 是标准 .app 结构。
#   2. 菜单栏应用如果不是 .app，Finder/启动台不好管理，双击体验也不对。
#
# 用法：
#   ./build-app.sh            # Release 构建（默认）
#   ./build-app.sh debug      # Debug 构建，编译快，方便调试

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="VlessMenuBar"
APP_DIR="dist/${APP_NAME}.app"

# 关键一步：清掉源码目录里（尤其是 Sources/VlessMenuBar/Resources/ 下内嵌的
# 两个 vless-ws-client 二进制）的隔离属性。这几个文件从你最初下载解压项目
# 压缩包开始就带着这个属性，SwiftPM 编译时只是原样拷贝文件（不会自动清掉
# 属性），所以就算之前对编译出来的 .app 用 xattr 清过，只要重新跑一次这个
# 脚本又会用带着隔离属性的源文件重新生成一份新的，等于每次重新打包都"复发"。
# 从源头清一次，之后每次编译出来的东西就都是干净的。
echo "==> 清除源文件的隔离属性（一次性，之后不会再复发）"
xattr -cr . 2>/dev/null || true

echo "==> swift build (-c ${CONFIG})"
swift build -c "${CONFIG}"
xattr -cr .build 2>/dev/null || true  # 防止用到编译缓存里遗留的隔离属性

BIN_PATH=".build/${CONFIG}/${APP_NAME}"
if [ ! -f "$BIN_PATH" ]; then
  echo "找不到编译产物: $BIN_PATH" >&2
  exit 1
fi

echo "==> 组装 .app 包结构"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> 生成 App 图标 (iconutil 是 macOS 自带工具，把 iconset 转成 icns)"
if [ -d "AppIcon.iconset" ]; then
  iconutil -c icns AppIcon.iconset -o "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "警告：没找到 AppIcon.iconset，App 会用系统默认图标" >&2
fi

# SwiftPM 的资源包（内含两个 vless-ws-client 二进制）跟主执行文件放在一起，
# Bundle.module 在运行时会在可执行文件同目录找 xxx_VlessMenuBar.bundle。
RESOURCE_BUNDLE=".build/${CONFIG}/${APP_NAME}_VlessMenuBar.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/MacOS/"
else
  echo "警告：没找到资源 bundle ($RESOURCE_BUNDLE)，两个 vless-ws-client 二进制可能没打包进去" >&2
fi

echo "==> ad-hoc 签名（不是正式开发者签名，只是让系统能正常识别/运行这个 App）"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 完成：$APP_DIR"
echo "第一次运行需要在 Finder 里右键 -> 打开，绕过 Gatekeeper 的未知开发者拦截。"
echo "或者命令行执行： xattr -cr \"$APP_DIR\""
echo
echo "如果 Dock/访达里图标还是显示旧的（系统图标缓存问题），可以试试："
echo "  killall Dock && killall Finder"
