#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build_dir="${ONIGIRI_BUILD_DIR:-/tmp/onigiri-harness-build}"
configuration="${ONIGIRI_BUILD_CONFIGURATION:-debug}"
version="${ONIGIRI_VERSION:-$(tr -d '[:space:]' < "$root_dir/VERSION")}"
build_number="${ONIGIRI_BUILD_NUMBER:-1}"
sign_identity="${ONIGIRI_SIGN_IDENTITY:--}"
semver_pattern='^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$build_dir/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$build_dir/module-cache}"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  print -u2 "ONIGIRI_BUILD_CONFIGURATION must be debug or release."
  exit 2
fi
if [[ ! "$version" =~ $semver_pattern ]]; then
  print -u2 "Invalid version: $version"
  exit 2
fi
if [[ ! "$build_number" =~ '^[0-9]+$' ]]; then
  print -u2 "ONIGIRI_BUILD_NUMBER must be numeric."
  exit 2
fi

mkdir -p "$build_dir/module-cache"

swift build --disable-sandbox -c "$configuration" --scratch-path "$build_dir" --product OnigiriApp
swift build --disable-sandbox -c "$configuration" --scratch-path "$build_dir" --product OnigiriServer
swift build --disable-sandbox -c "$configuration" --scratch-path "$build_dir" --product onigiri-mcp
bin_dir="$(swift build --disable-sandbox -c "$configuration" --scratch-path "$build_dir" --show-bin-path)"
app_dir="$build_dir/Onigiri.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/OnigiriApp" "$app_dir/Contents/MacOS/OnigiriApp"
cp "$bin_dir/OnigiriServer" "$app_dir/Contents/MacOS/OnigiriServer"
cp "$bin_dir/onigiri-mcp" "$app_dir/Contents/MacOS/onigiri-mcp"
cp "$root_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$root_dir/NOTICE" "$app_dir/Contents/Resources/NOTICE"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Onigiri Harness</string>
<key>CFBundleIdentifier</key><string>local.onigiri.harness</string>
<key>CFBundleExecutable</key><string>OnigiriApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app_dir/Contents/Info.plist" >/dev/null
codesign --force --sign "$sign_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
print "Built: $app_dir ($configuration, version $version, build $build_number)"
