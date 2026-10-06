#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
version="${ONIGIRI_VERSION:-$(tr -d '[:space:]' < "$root_dir/VERSION")}"
architecture="${ONIGIRI_ARCHITECTURE:-$(uname -m)}"
qualifier="${ONIGIRI_ARTIFACT_QUALIFIER:-unsigned}"
build_dir="${ONIGIRI_BUILD_DIR:-/tmp/onigiri-harness-release-build}"
output_dir="${ONIGIRI_ARTIFACT_OUTPUT_DIR:-$root_dir/release}"
configuration="${ONIGIRI_BUILD_CONFIGURATION:-release}"

if [[ ! "$architecture" =~ '^[0-9A-Za-z_-]+$' || ! "$qualifier" =~ '^[0-9A-Za-z.-]+$' ]]; then
  print -u2 "Invalid artifact architecture or qualifier."
  exit 2
fi

ONIGIRI_BUILD_DIR="$build_dir" \
ONIGIRI_BUILD_CONFIGURATION="$configuration" \
ONIGIRI_VERSION="$version" \
  zsh "$root_dir/scripts/build-app.sh"

app_dir="$build_dir/Onigiri.app"
artifact_base="Onigiri-Harness-${version}-macOS-${architecture}-${qualifier}"
archive_path="$output_dir/$artifact_base.zip"
checksum_path="$archive_path.sha256"

mkdir -p "$output_dir"
rm -f "$archive_path" "$checksum_path"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"
(
  cd "$output_dir"
  shasum -a 256 "${artifact_base}.zip" > "${artifact_base}.zip.sha256"
)

expected_version="$(plutil -extract CFBundleShortVersionString raw "$app_dir/Contents/Info.plist")"
if [[ "$expected_version" != "$version" ]]; then
  print -u2 "Packaged version mismatch: expected $version, got $expected_version"
  exit 1
fi

print "Artifact: $archive_path"
print "Checksum: $checksum_path"
