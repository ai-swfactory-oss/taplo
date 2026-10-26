#!/usr/bin/env bash
# Named test: a source crate whose sha256 does not match the crates.io index
# checksum pinned in upstream.json fails scripts/fetch.sh, which the build runs
# before it unpacks, compiles or publishes anything, and leaves neither the
# crate nor unpacked source behind. A crate with the right checksum but no
# Cargo.lock is refused too (a locked build would be impossible). The good
# crate with its true checksum is accepted and unpacked, so the check is not
# vacuous. Runs offline: the "registry" is local files.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

commit=0123456789abcdef0123456789abcdef01234567
make_crate() { # <name> <with lockfile: yes|no>
  local dir="$work/build-$1/taplo-cli-9.9.9"
  mkdir -p "$dir" "$work/registry-$1/taplo-cli"
  printf '{"git":{"sha1":"%s"},"path_in_vcs":"crates/taplo-cli"}\n' "$commit" >"$dir/.cargo_vcs_info.json"
  printf '[package]\nname = "taplo-cli"\nversion = "9.9.9"\n' >"$dir/Cargo.toml"
  if [ "$2" = yes ]; then printf 'version = 3\n' >"$dir/Cargo.lock"; fi
  tar -czf "$work/registry-$1/taplo-cli/taplo-cli-9.9.9.crate" -C "$work/build-$1" taplo-cli-9.9.9
}
make_crate good yes
make_crate nolock no
printf 'MIT License\n\nCopyright (c) 2020 Ferenc Tamás\n' >"$work/LICENSE"

manifest() { # <cksum>
  jq -n --arg c "$1" '{crate: "taplo-cli", version: "9.9.9", cksum: $c, repack: 0}'
}

fetch() { # <registry> <manifest file> <outdir>
  UPSTREAM_JSON=$2 UPSTREAM_BASE_URL="file://$work/registry-$1" UPSTREAM_LICENSE_URL="file://$work/LICENSE" \
    bash "$root/scripts/fetch.sh" "$3"
}

expect_refusal() { # <case> <registry> <manifest file> <log pattern>
  set +e
  fetch "$2" "$3" "$work/out-$1" >"$work/$1.log" 2>&1
  local rc=$?
  set -e
  cat "$work/$1.log"
  [ "$rc" -ne 0 ] || { echo "digest-mismatch: $1: fetch accepted it" >&2; exit 1; }
  grep -q "$4" "$work/$1.log" || { echo "digest-mismatch: $1: the failure does not say '$4'" >&2; exit 1; }
  [ ! -e "$work/out-$1/taplo-cli-9.9.9.crate" ] || { echo "digest-mismatch: $1: the crate was left behind" >&2; exit 1; }
  [ ! -e "$work/out-$1/src/taplo-cli-9.9.9" ] || { echo "digest-mismatch: $1: unpacked source was left behind" >&2; exit 1; }
}

true_cksum=$(sha256 "$work/registry-good/taplo-cli/taplo-cli-9.9.9.crate")
nolock_cksum=$(sha256 "$work/registry-nolock/taplo-cli/taplo-cli-9.9.9.crate")

manifest "$(printf '%064d' 0)" >"$work/wrong.json"
expect_refusal wrong good "$work/wrong.json" 'sha256 mismatch for taplo-cli-9.9.9.crate'

manifest "$nolock_cksum" >"$work/nolock.json"
expect_refusal nolock nolock "$work/nolock.json" 'ships no Cargo.lock'

manifest "$true_cksum" >"$work/true.json"
fetch good "$work/true.json" "$work/out-true"
test -f "$work/out-true/src/taplo-cli-9.9.9/Cargo.lock"
cmp "$work/registry-good/taplo-cli/taplo-cli-9.9.9.crate" "$work/out-true/taplo-cli-9.9.9.crate"
grep -q 'MIT License' "$work/out-true/LICENSE"

echo "digest-mismatch: OK"
