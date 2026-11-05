#!/usr/bin/env bash
# 重新生成 Resources/AppIcon.icns（改图标设计后跑一次即可，日常 build.sh 不需要它）。
# 依赖：xcrun swiftc + 系统自带 iconutil / sips，没有第三方库。
#
# 出图默认是"满幅不透明"版：macOS 26 起系统会按自己的圆角裁切，留透明边反而会被
# 垫一层灰底板（详见 Tools/make-icon.swift 顶部注释）。要给 macOS 15 及更早用，
# 可以 `ICON_STYLE=squircle ./Tools/make-icon.sh`，那边需要 824 见方的圆角留白。
ICON_STYLE="${ICON_STYLE:-square}"
export ICON_STYLE

set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
echo "▸ 编译并渲染 1024 主图（${ICON_STYLE}）"
xcrun swiftc -O Tools/make-icon.swift -o build/make-icon
./build/make-icon build/AppIcon-1024.png

echo "▸ 生成 iconset"
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s               build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
    sips -z $((s*2)) $((s*2))   build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png"   >/dev/null
done

echo "▸ 打包 .icns"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp build/AppIcon-1024.png Resources/AppIcon-1024.png
ls -lh Resources/AppIcon.icns | awk '{print "✓ "$9"  "$5}'
