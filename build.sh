#!/bin/sh
set -eu
cd "$(dirname "$0")"
config=${1:-release}
swift_bin=$(command -v swift)
developer_dir=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}

# SwiftPM records the plugin environment in its cache. Keep provider sign-ins
# and shell variables out of the build, including when running the tests.
swiftpm() {
    /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        DEVELOPER_DIR="$developer_dir" TMPDIR=/tmp LANG=C \
        "$swift_bin" "$@"
}

case "$config" in
    test) swiftpm test --disable-automatic-resolution; exit ;;
    debug) scratch=.build ;;
    release)
        scratch=$(mktemp -d /tmp/realm-lens-build.XXXXXXXX)
        trap 'rm -rf "$scratch"' EXIT
        ;;
    *) echo "Usage: ./build.sh [release|debug|test]" >&2; exit 2 ;;
esac

swiftpm build --disable-automatic-resolution --scratch-path "$scratch" -c "$config" \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=RealmLens" \
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=RealmLens" \
    -Xcc "-ffile-prefix-map=$PWD=RealmLens"
bin="$scratch/$config"
app=dist/RealmLens.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp "$bin/RealmLens" "$app/Contents/MacOS/RealmLens"
if [ "$config" = release ]; then
    /usr/bin/strip -S -x "$app/Contents/MacOS/RealmLens"
fi
for bundle in "$bin"/*.bundle; do
    if [ -d "$bundle" ]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
done
for dependency in SwiftTerm swift-argument-parser; do
    mkdir -p "$app/Contents/Resources/Licenses/$dependency"
    license="$scratch/checkouts/$dependency/LICENSE"
    if [ ! -f "$license" ]; then license="$license.txt"; fi
    cp "$license" "$app/Contents/Resources/Licenses/$dependency/"
    if [ -f "$scratch/checkouts/$dependency/NOTICE.txt" ]; then
        cp "$scratch/checkouts/$dependency/NOTICE.txt" "$app/Contents/Resources/Licenses/$dependency/"
    fi
done
/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo "Built $app"
