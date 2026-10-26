#!/usr/bin/env bash
# The repository's validate command (.panoptic.json "validate": "bash scripts/validate.sh"),
# run by `claude-factory work commit` on the gate host. It runs the same path
# the PR CI runs (build.yml), for the gate host's own platform:
#
#   1. shellcheck over every shell script, and a YAML syntax check of every
#      workflow in .github/workflows with the packaged yamllint
#      (@ai-swfactory-oss/yamllint, installed into a scratch prefix, never
#      globally). A known-bad fixture must fail it first, so the check is not
#      vacuous. A workflow GitHub cannot parse never runs, so the merge would
#      publish nothing. Then no script, test or workflow may pipe into a
#      reader that can exit before its input ends (head, grep -q, a quitting
#      sed, tar): under pipefail the writer then fails on the closed pipe, at
#      random. A fixture holding each form must be flagged first;
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

echo "== workflow YAML syntax (packaged yamllint)"
yamllint_version=1.38.0
mkdir -p "$work/yamllint"
printf '{"name":"validate-yamllint","version":"1.0.0","private":true}\n' >"$work/yamllint/package.json"
# The scope's registry line comes from this repository's .npmrc; the token,
# if any, stays in the user's own ~/.npmrc. Never installed globally.
cp .npmrc "$work/yamllint/.npmrc"
npm install --prefix "$work/yamllint" --no-save --no-audit --no-fund \
  "@ai-swfactory-oss/yamllint@$yamllint_version" >"$work/yamllint-install.log" 2>&1 ||
  { cat "$work/yamllint-install.log"; echo "validate: could not install @ai-swfactory-oss/yamllint@$yamllint_version" >&2; exit 1; }
yamllint="$work/yamllint/node_modules/.bin/yamllint"
[ -x "$yamllint" ] || { echo "validate: $yamllint is missing after install" >&2; exit 1; }
# Syntax only: no style rules, so only a document YAML cannot parse fails.
syntax_only='{rules: {}}'
printf 'jobs:\n  a:\n    steps:\n      - name: bad (linux: colon)\n' >"$work/bad-workflow.yml"
if "$yamllint" -d "$syntax_only" "$work/bad-workflow.yml" >"$work/bad-workflow.txt" 2>&1; then
  cat "$work/bad-workflow.txt"; echo "validate: yamllint accepted a workflow YAML cannot parse" >&2; exit 1
fi
cat "$work/bad-workflow.txt"
"$yamllint" -d "$syntax_only" .github/workflows/*.yml
echo "workflows: YAML syntax OK"

echo "== no pipe into an early-exiting reader"
# Write the producer's output to a file first, then read the file.
# A single bar (not ||), then the reader.
early_exit='(^|[^|])\|[[:space:]]*(head|tar|grep[[:space:]]+(-[A-Za-z]*q|--quiet)|sed[[:space:]][^|]*[0-9$/]q)([[:space:]]|$)'
# The fixture spells the bar through a variable so this file does not match.
bar='|'
printf '%s\n' "a $bar head -n1" "b $bar grep -q x" "c $bar grep -Eq x" "d $bar sed 1q" "e $bar tar -xf - m" >"$work/pipes-bad.sh"
grep -cE "$early_exit" "$work/pipes-bad.sh" >"$work/pipes-bad.count" || true
[ "$(cat "$work/pipes-bad.count")" = 5 ] || { echo "validate: the pipe check missed a fixture form" >&2; exit 1; }
# Comment lines are prose, not commands.
if grep -nE "$early_exit" scripts/*.sh test/*.sh .github/workflows/*.yml | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >"$work/pipes.txt"; then
  cat "$work/pipes.txt"; echo "validate: a pipe ends in a reader that can exit early; write to a file first" >&2; exit 1
fi
echo "pipes: no early-exiting reader"

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
