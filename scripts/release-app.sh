#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
cd "$root_dir"

version="${ONIGIRI_VERSION:-$(tr -d '[:space:]' < "$root_dir/VERSION")}"
build_number="${ONIGIRI_BUILD_NUMBER:-1}"
architecture="${ONIGIRI_ARCHITECTURE:-$(uname -m)}"
build_dir="${ONIGIRI_BUILD_DIR:-/tmp/onigiri-harness-signed-build}"
output_dir="${ONIGIRI_ARTIFACT_OUTPUT_DIR:-$root_dir/release}"
sign_identity="${ONIGIRI_SIGN_IDENTITY:-}"
notary_profile="${ONIGIRI_NOTARY_PROFILE:-}"
notary_key_path="${ONIGIRI_NOTARY_KEY_PATH:-}"
notary_key_id="${ONIGIRI_NOTARY_KEY_ID:-}"
notary_issuer_id="${ONIGIRI_NOTARY_ISSUER_ID:-}"

if [[ -z "$sign_identity" || "$sign_identity" != "Developer ID Application:"* ]]; then
  print -u2 "ONIGIRI_SIGN_IDENTITY must be a Developer ID Application identity."
  exit 2
fi
if ! security find-identity -v -p codesigning | grep -Fq \"$sign_identity\"; then
  print -u2 "Signing identity is not available in the current keychain: $sign_identity"
  exit 2
fi
if [[ ! "$architecture" =~ '^[0-9A-Za-z_-]+$' ]]; then
  print -u2 "Invalid artifact architecture: $architecture"
  exit 2
fi

notary_args=()
if [[ -n "$notary_profile" ]]; then
  notary_args+=(--keychain-profile "$notary_profile")
elif [[ -n "$notary_key_path" && -n "$notary_key_id" && -n "$notary_issuer_id" ]]; then
  if [[ ! -f "$notary_key_path" ]]; then
    print -u2 "Notarization API key not found: $notary_key_path"
    exit 2
  fi
  notary_args+=(--key "$notary_key_path" --key-id "$notary_key_id" --issuer "$notary_issuer_id")
else
  print -u2 "Set ONIGIRI_NOTARY_PROFILE, or all of ONIGIRI_NOTARY_KEY_PATH, ONIGIRI_NOTARY_KEY_ID, and ONIGIRI_NOTARY_ISSUER_ID."
  exit 2
fi

ONIGIRI_BUILD_DIR="$build_dir" \
ONIGIRI_BUILD_CONFIGURATION=release \
ONIGIRI_VERSION="$version" \
ONIGIRI_BUILD_NUMBER="$build_number" \
ONIGIRI_SIGN_IDENTITY="$sign_identity" \
  zsh "$root_dir/scripts/build-app.sh"

app_dir="$build_dir/Onigiri.app"
submission_zip="$build_dir/Onigiri-Harness-${version}-notarization-submission.zip"
artifact_base="Onigiri-Harness-${version}-macOS-${architecture}-notarized"
archive_path="$output_dir/$artifact_base.zip"
checksum_path="$archive_path.sha256"
notary_result_path="$output_dir/$artifact_base.notarization.json"

codesign --verify --deep --strict --verbose=2 "$app_dir"
if ! codesign --display --verbose=4 "$app_dir" 2>&1 | grep -q 'runtime'; then
  print -u2 "Hardened Runtime is not enabled on the signed app."
  exit 1
fi

rm -f "$submission_zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$submission_zip"
mkdir -p "$output_dir"
rm -f "$archive_path" "$checksum_path" "$notary_result_path"

xcrun notarytool submit "$submission_zip" \
  --wait \
  --output-format json \
  "${notary_args[@]}" | tee "$notary_result_path"

notary_status="$(plutil -extract status raw -o - "$notary_result_path")"
if [[ "$notary_status" != "Accepted" ]]; then
  print -u2 "Notarization was not accepted (status: $notary_status)."
  exit 1
fi

xcrun stapler staple "$app_dir"
xcrun stapler validate "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
spctl --assess --type execute --verbose=4 "$app_dir"

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"
(
  cd "$output_dir"
  shasum -a 256 "${artifact_base}.zip" > "${artifact_base}.zip.sha256"
)
shasum -a 256 -c "$checksum_path"

print "Notarized artifact: $archive_path"
print "Checksum: $checksum_path"
print "Notarization result: $notary_result_path"
