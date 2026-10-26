#!/usr/bin/env bash
# The repository's validate command (.panoptic.json "validate": "bash scripts/validate.sh"),
# run by `claude-factory work commit` on the gate host. It runs the same path
# the PR CI runs (build.yml), for the gate host's own platform:
#
#   1. shellcheck over every shell script;
#   2. named test test/digest-mismatch.sh: a crate whose sha256 does not match
#      the pinned crates.io index checksum, or that ships no Cargo.lock, is
#      refused and deleted; the true crate is accepted;
#   3. named tests test/licenses.test.js: the licence generator refuses a
#      copyleft crate, refuses MPL-2.0 unless pinned and checksum-verified,
#      leaves out dev-only dependencies, and writes the texts;
#   4. scripts/fetch.sh from crates.io (checksum verified);
#   5. scripts/build.sh natively on the gate host with the cargo on PATH
#      (cargo fetch --locked, cargo build --release --locked --frozen, linkage
#      check, THIRD-PARTY-LICENSES, MPL sources); nothing is installed;
#   6. named tests test/launcher.test.js over a launcher staged for all four
#      platforms (the other three binaries are stand-ins: the launcher tests
#      never run them);
#   7. stage for the gate host only, npm pack every package once;
#   8. named test scripts/smoke.sh for the gate host's platform.
#
# The other three platforms' build and smoke run in CI (pr.yml, build.yml).
# Needs network, bash, jq, tar, gzip, curl, cargo and a C compiler, node, npm
# and shellcheck.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
# The gate reports only the exit status; keep the full output for diagnosis.
mkdir -p build
exec > >(tee build/validate.log) 2>&1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "validate: unsupported gate host OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) cpu=arm64 ;;
  x86_64 | amd64) cpu=x64 ;;
  *) echo "validate: unsupported gate host CPU $(uname -m)" >&2; exit 1 ;;
esac
host="$os-$cpu"
jq -e --arg p "$host" '.platforms | index($p) != null' upstream.json >/dev/null ||
  { echo "validate: no taplo package is built for the gate host ($host)" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "validate: cargo is not on PATH" >&2; exit 1; }

echo "== shellcheck"
shellcheck scripts/*.sh test/*.sh

echo "== named test: digest mismatch"
bash test/digest-mismatch.sh

echo "== named tests: licence generator"
node --test test/licenses.test.js

echo "== fetch (crates.io index checksum verified)"
bash scripts/fetch.sh "$work/upstream"

echo "== build on the gate host ($host)"
mkdir -p "$work/built"
bash scripts/build.sh "$work/upstream" "$work/built/$host"
ls -l "$work/built/$host" "$work/built/$host/mpl-sources"

echo "== named tests: launcher (staged for every platform)"
mkdir -p "$work/all"
for platform in $(jq -r '.platforms | join(" ")' upstream.json); do
  mkdir -p "$work/all/$platform"
  cp "$work/built/$host/taplo" "$work/built/$host/LICENSE" "$work/built/$host/THIRD-PARTY-LICENSES" "$work/all/$platform/"
done
bash scripts/stage.sh "$work/all" "$work/npm-all"
TAPLO_LAUNCHER_DIR="$work/npm-all/taplo" node --test test/launcher.test.js

echo "== stage for the gate host and pack"
jq --arg p "$host" '.platforms = [$p]' upstream.json >"$work/host.json"
UPSTREAM_JSON="$work/host.json" bash scripts/stage.sh "$work/built" "$work/npm"
mkdir -p "$work/tgz"
for dir in "$work"/npm/*/; do
  npm pack "$dir" --pack-destination "$work/tgz" >/dev/null
done
ls -1 "$work/tgz"

echo "== named test: smoke on the gate host ($host)"
bash scripts/smoke.sh "$work/tgz" "$host"

echo "validate: OK"
