#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build_dir="/tmp/onigiri-harness-build"
swift build --scratch-path "$build_dir" --product OnigiriApp
swift build --scratch-path "$build_dir" --product OnigiriServer
swift build --scratch-path "$build_dir" --product onigiri-mcp
bin_dir="$(swift build --scratch-path "$build_dir" --show-bin-path)"
app_dir="$build_dir/Onigiri.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/OnigiriApp" "$app_dir/Contents/MacOS/OnigiriApp"
cp "$bin_dir/OnigiriServer" "$app_dir/Contents/MacOS/OnigiriServer"
cp "$bin_dir/onigiri-mcp" "$app_dir/Contents/MacOS/onigiri-mcp"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Onigiri Harness</string>
<key>CFBundleIdentifier</key><string>local.onigiri.harness</string>
<key>CFBundleExecutable</key><string>OnigiriApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
print "Built: $app_dir"
