#!/usr/bin/env bash
# Downloads the taplo-cli source crate named in upstream.json from crates.io and
# verifies it against the sha256 checksum pinned in upstream.json, which is the
# crates.io index checksum for that version (https://index.crates.io/ta/pl/taplo-cli,
# field "cksum"). A crate whose checksum does not match is deleted and the
# script exits 1, before anything is unpacked, compiled or published. The crate
# must ship its Cargo.lock: every dependency is then fetched by cargo against
# the checksums in that lockfile (cargo fetch --locked), so the whole build is
# pinned by this one checksum.
#
# taplo's MIT LICENSE is not in the crate. It is taken from tamasfe/taplo at
# the exact commit the crate records in .cargo_vcs_info.json (inside the
# verified crate), and must be the expected MIT text.
#
#   scripts/fetch.sh <outdir>
#
# UPSTREAM_JSON overrides the manifest; UPSTREAM_BASE_URL overrides the crate
# download base (default https://static.crates.io/crates); UPSTREAM_LICENSE_URL
# overrides the LICENSE URL (the tests point them at local files).
#
# Result: <outdir>/<crate>-<version>.crate   the verified crate
#         <outdir>/src/<crate>-<version>/    the unpacked source, with Cargo.lock
#         <outdir>/LICENSE                   taplo's MIT licence
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${UPSTREAM_JSON:-$root/upstream.json}
out=${1:?usage: fetch.sh <outdir>}
base=${UPSTREAM_BASE_URL:-https://static.crates.io/crates}

crate=$(jq -er .crate "$manifest")
version=$(jq -er .version "$manifest")
cksum=$(jq -er .cksum "$manifest")
[[ "$cksum" =~ ^[0-9a-f]{64}$ ]] || { echo "fetch: cksum '$cksum' is not a sha256 hex digest" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

mkdir -p "$out"
file="$out/$crate-$version.crate"
echo "fetch: <- $base/$crate/$crate-$version.crate"
curl -fsSL --retry 3 --retry-delay 5 -o "$file" "$base/$crate/$crate-$version.crate"
got=$(sha256 "$file")
if [ "$got" != "$cksum" ]; then
  echo "fetch: sha256 mismatch for $crate-$version.crate: got $got, crates.io index says $cksum" >&2
  rm -f "$file"
  exit 1
fi
echo "fetch: $crate-$version.crate sha256 $got (crates.io index checksum)"

rm -rf "$out/src"
mkdir -p "$out/src"
tar -xzf "$file" -C "$out/src"
src="$out/src/$crate-$version"
[ -f "$src/Cargo.lock" ] || { echo "fetch: $crate-$version.crate ships no Cargo.lock; a locked build is impossible" >&2; rm -rf "$out/src" "$file"; exit 1; }

commit=$(jq -er .git.sha1 "$src/.cargo_vcs_info.json")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "fetch: .cargo_vcs_info.json names no commit" >&2; exit 1; }
license_url=${UPSTREAM_LICENSE_URL:-https://raw.githubusercontent.com/tamasfe/taplo/$commit/LICENSE}
echo "fetch: <- $license_url"
curl -fsSL --retry 3 --retry-delay 5 -o "$out/LICENSE" "$license_url"
if ! grep -q 'MIT License' "$out/LICENSE" || ! grep -q 'Ferenc Tam' "$out/LICENSE"; then
  echo "fetch: the LICENSE at tamasfe/taplo $commit is not the expected MIT licence" >&2
  rm -f "$out/LICENSE"
  exit 1
fi
echo "fetch: $src (commit $commit)"
