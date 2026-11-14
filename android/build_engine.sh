#!/bin/sh
# Builds the Swift rules (PortolanEngine, on PortolanCore) for Android and puts it into the app as a native
# library. Needs the swift.org 6.4.2 toolchain, its Android SDK and the NDK r30. The rules come from the vendored
# core/ folder (or PORTOLAN_CORE).
set -eu
cd "$(dirname "$0")"
CORE="${PORTOLAN_CORE:-../core}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/android-ndk-r30}"
SWIFT="${SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin/swift}"
"$SWIFT" build --package-path "$CORE" --swift-sdk aarch64-unknown-linux-android28 --product PortolanEngine --static-swift-stdlib -c release --scratch-path "$PWD/build/android-swift"
OUT=app/src/main/jniLibs/arm64-v8a
mkdir -p "$OUT"
cp build/android-swift/out/Products/Release-android-aarch64/PortolanEngine "$OUT/libportolanengine.so"
cp "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so "$OUT/"
echo "엔진을 $OUT 에 넣었습니다."
