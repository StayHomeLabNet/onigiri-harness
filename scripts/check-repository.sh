#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"
failures=0

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  failures=$((failures + 1))
}

while IFS= read -r tracked_path; do
  case "$tracked_path" in
    *.DS_Store|.env|.env.*|*.p12|*.mobileprovision|*.dmg|*.zip|Onigiri-*.json)
      [[ "$tracked_path" == ".env.example" ]] || fail "Disallowed tracked file: $tracked_path"
      ;;
  esac
done < <(git ls-files)

if git grep -I -n -E '/Users/[^/]+/|OneDrive-個人用|Downloads/RAG' -- . \
  ':(exclude)scripts/check-repository.sh'; then
  fail "Local absolute path found."
fi

if git grep -I -n -E \
  'sk-[A-Za-z0-9_-]{16,}|AIza[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY' \
  -- . ':(exclude)scripts/check-repository.sh'; then
  fail "Credential-like content found."
fi

version="$(tr -d '[:space:]' < VERSION)"
semver_pattern='^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
if [[ ! "$version" =~ $semver_pattern ]]; then
  fail "VERSION is not SemVer-compatible: $version"
fi

for required_file in LICENSE NOTICE README.md SECURITY.md CONTRIBUTING.md; do
  [[ -s "$required_file" ]] || fail "Required public file is missing or empty: $required_file"
done

if (( failures > 0 )); then
  printf 'Repository safety check failed: %s issue(s).\n' "$failures" >&2
  exit 1
fi

printf 'Repository safety check passed.\n'
