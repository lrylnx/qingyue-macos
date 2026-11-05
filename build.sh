#!/usr/bin/env bash
# 构建 轻阅.app —— 单文件 swiftc 编译，无 Xcode 工程、无外部依赖。
set -euo pipefail
cd "$(dirname "$0")"

APP="$(pwd)/轻阅.app"

# SDK 选择（可用 SDK=... 覆盖）
#
# 1) 有 Xcode 就用它自带的 macOS 15 SDK：CLT 的 `xcrun --show-sdk-path` 指向的 SDK 比
#    Xcode 自带的新，里面的 .swiftinterface 用了 Swift 6.4 语法（Swift::Comparable），
#    Xcode 16 带的 Swift 6.0 读它直接报一堆 `expected declaration`。
# 2) 没装 Xcode（只剩 CommandLineTools）时不能直接用 CLT 最新的 SDK：从 macOS 26 SDK 起
#    SwiftUI 的 `@State` 变成了宏（SwiftUIMacros），而宏插件 libSwiftUIMacros.dylib 只有
#    Xcode 才带 —— 报错是 `plugin for module 'SwiftUIMacros' not found`，接着一堆
#    `cannot find '$xxx' in scope` 把真正的原因淹掉。这种情况退到 CLT 里 <26 的旧 SDK
#    （那边的 @State 还是普通 property wrapper），一样能编出 macOS 14+ 的产物。
SDK="${SDK:-}"
if [ -z "$SDK" ]; then
    XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    if [ -d "$XCODE_SDK" ]; then
        SDK="$XCODE_SDK"
    else
        LOWER=""
        for d in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
            [ -d "$d" ] || continue
            v="$(basename "$d" .sdk)"; v="${v#MacOSX}"
            [ "${v%%.*}" -lt 26 ] 2>/dev/null || continue
            if [ -z "$LOWER" ] || [ "$(printf '%s\n%s\n' "$LOWERV" "$v" | sort -V | tail -1)" = "$v" ]; then
                LOWER="$d"; LOWERV="$v"
            fi
        done
        if [ -n "$LOWER" ]; then
            SDK="$LOWER"
            echo "▸ 没有 Xcode，改用 CLT 旧 SDK（新 SDK 需要 Xcode 才带的 SwiftUI 宏插件）"
        else
            SDK="$(xcrun --sdk macosx --show-sdk-path)"
            echo "▸ 警告：只剩 >=26 的 SDK，@State 宏插件缺失，编译很可能失败"
        fi
    fi
fi
if [ ! -d "$SDK" ]; then
    echo "✗ SDK 不存在: $SDK" >&2
    exit 1
fi
echo "▸ SDK: $SDK"

OPT="${OPT:--O}"
BUNDLE_ID="local.qingyue.lightread"

mkdir -p build

# 不用 rm -rf（安全钩子会拦，且 ditto 会"合并"进旧 bundle 导致脏产物）
if [ -d "$APP" ]; then
    mv "$APP" "build/old-$(date +%s).app"
fi
if [ -d build/obj ]; then
    mv build/obj "build/old-obj-$(date +%s)"
fi
mkdir -p build/obj

SOURCES=$(find Sources -name '*.swift' | sort)
ARCHS="${ARCHS:-arm64}"
BINS=()

for arch in $ARCHS; do
    # C 桥接也必须按架构各编一份：单份 arm64 的 .o 在链接 x86_64 时会
    # 只报 "found architecture 'arm64'" 警告，然后 _lr_inflate 之类全成 undefined symbols。
    echo "「编译 zlib 桥接 ($arch)」"
    xcrun clang -O2 -c Sources/Core/zipshim.c \
        -isysroot "$SDK" \
        -target "${arch}-apple-macos14.0" \
        -o "build/obj/zipshim_${arch}.o"

    echo "「编译 Swift ($arch)」"
    xcrun swiftc \
        "$OPT" \
        -parse-as-library \
        -sdk "$SDK" \
        -target "${arch}-apple-macos14.0" \
        -framework AppKit \
        -framework SwiftUI \
        -framework WebKit \
        -framework UniformTypeIdentifiers \
        -lz \
        "build/obj/zipshim_${arch}.o" \
        $SOURCES \
        -o "build/obj/LightRead_${arch}"
    BINS+=("build/obj/LightRead_${arch}")
done

if [ ${#BINS[@]} -gt 1 ]; then
    xcrun lipo -create -output build/obj/LightRead "${BINS[@]}"
else
    cp "${BINS[0]}" build/obj/LightRead
fi

# 命令行导出工具（Tools/main.swift，用法 dump <in> <out.html> [sheet]）。
# 必须跟 App 一起重编：否则改了 Core 里的 CSS/解析，验证用的 dump 还是旧产物，
# 会得出"改完没效果"的错误结论。顶层代码文件不能加 -parse-as-library。
echo "▸ 编译 CLI (dump)"
# 只编 Core：UI 层里有 @main，和 Tools/main.swift 的顶层代码会冲突。
xcrun swiftc -O -sdk "$SDK" -target arm64-apple-macos14.0 -lz \
    "build/obj/zipshim_arm64.o" \
    Sources/Core/*.swift Tools/main.swift \
    -o build/dump 2>/dev/null || echo "  (CLI 编译失败，不影响 App)"

echo "▸ 组装 bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/obj/LightRead "$APP/Contents/MacOS/LightRead"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" 2>/dev/null || true

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (签名失败，App 仍可本机运行)"

echo "✓ 完成: $APP"
du -sh "$APP" | awk '{print "  体积: "$1}'

# 重新登记 LaunchServices：不然刚重新打包的 App 在 Finder 里双击文件时，
# 系统可能还拿着旧的 UTI 认领记录，表现成"双击没反应、只把 App 打开"。走两遍
# 是因为 -f 只刷新这个 bundle，要再落一次才稳定生效。
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [ -x "$LSREG" ]; then
    "$LSREG" -f "$APP" >/dev/null 2>&1 || true
    "$LSREG" -f "$APP" >/dev/null 2>&1 || true
fi
