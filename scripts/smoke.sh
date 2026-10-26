#!/usr/bin/env bash
# The single-quoted node programs are literal on purpose.
# shellcheck disable=SC2016
# Named test, per platform: installs the packed tarballs into a scratch project,
# as a consumer would, and checks that binaryPath() resolves to an executable
# taplo that reports upstreamVersion, formats, queries and lints TOML (with and
# without a local JSON schema, offline), links the way the build promises
# (static on linux: ldd reports it static and readelf -d lists no NEEDED
# entries; system libraries only on darwin), ships its licences, and that no
# tarball declares an install script.
#
#   scripts/smoke.sh <tgzdir> <platform>      e.g. dist/tgz linux-x64
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tgz=$(cd "${1:?usage: smoke.sh <tgzdir> <platform>}" && pwd)
platform=${2:?usage: smoke.sh <tgzdir> <platform>}
upstream=$(jq -er .version "$root/upstream.json")
version=$(bash "$root/scripts/pkgver.sh")

launcher="$tgz/ai-swfactory-oss-taplo-$version.tgz"
native="$tgz/ai-swfactory-oss-taplo-$platform-$version.tgz"

# Read tarball contents into files first: `tar ... | grep -q` under pipefail
# fails when grep exits early and tar hits the closed pipe.
scan=$(mktemp -d)
for f in "$launcher" "$native"; do
  test -f "$f" || { echo "smoke: missing $f" >&2; exit 1; }
  tar -xzOf "$f" package/package.json >"$scan/package.json"
  if jq -e '.scripts // {} | keys | any(test("install"))' "$scan/package.json" >/dev/null; then
    echo "smoke: $f declares an install script" >&2; exit 1
  fi
  tar -xzOf "$f" package/NOTICE >"$scan/NOTICE"
  for mpl in $(jq -r '.licenses.mpl_sources[] | "\(.crate)-\(.version).crate"' "$root/upstream.json"); do
    grep -q "$mpl" "$scan/NOTICE" || { echo "smoke: $f NOTICE does not name the MPL-2.0 source $mpl" >&2; exit 1; }
  done
  grep -q "releases/tag/v$version" "$scan/NOTICE" || { echo "smoke: $f NOTICE does not point at the release" >&2; exit 1; }
done
tar -xzOf "$native" package/THIRD-PARTY-LICENSES >"$scan/THIRD-PARTY-LICENSES"
grep -q 'Mozilla Public License' "$scan/THIRD-PARTY-LICENSES" ||
  { echo "smoke: THIRD-PARTY-LICENSES lacks the MPL-2.0 text" >&2; exit 1; }

work=$(mktemp -d)
cd "$work" || exit 1
printf '{"name":"smoke","version":"1.0.0","private":true}\n' >package.json
npm install --no-audit --no-fund "$launcher" "$native"

echo "== binaryPath(), upstreamVersion and --version"
node -e '
  const { execFileSync } = require("node:child_process");
  const fs = require("node:fs");
  const taplo = require("@ai-swfactory-oss/taplo");
  const [expected] = process.argv.slice(1);
  if (taplo.upstreamVersion !== expected) throw new Error(`upstreamVersion ${taplo.upstreamVersion} != ${expected}`);
  const bin = taplo.binaryPath();
  if (!fs.statSync(bin).isFile()) throw new Error(`${bin} is not a file`);
  fs.accessSync(bin, fs.constants.X_OK);
  const printed = execFileSync(bin, ["--version"], { encoding: "utf8" }).trim();
  if (printed !== `taplo ${expected}`) throw new Error(`${bin} --version printed ${printed}, expected taplo ${expected}`);
  console.log(bin, printed);
' "$upstream"
bin=$(node -p 'require("@ai-swfactory-oss/taplo").binaryPath()')

echo "== fmt and get"
printf 'a=1\n[t]\nb  =   "x"\n' >in.toml
if "$bin" fmt --check in.toml; then
  echo "smoke: fmt --check accepted an unformatted file" >&2; exit 1
fi
"$bin" fmt in.toml
cat in.toml
"$bin" fmt --check in.toml
grep -qx 'a = 1' in.toml || { echo "smoke: a=1 was not formatted" >&2; exit 1; }
grep -qx 'b = "x"' in.toml || { echo "smoke: b was not formatted" >&2; exit 1; }
got=$("$bin" get -f in.toml t.b)
[ "$got" = x ] || { echo "smoke: taplo get t.b printed '$got', expected x" >&2; exit 1; }

echo "== lint (offline)"
"$bin" lint --no-schema in.toml
printf 'a = \n' >broken.toml
if "$bin" lint --no-schema broken.toml; then
  echo "smoke: lint accepted invalid TOML" >&2; exit 1
fi
printf '{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}\n' >schema.json
"$bin" lint --schema "file://$work/schema.json" in.toml
printf 'a = "not an integer"\n' >wrong.toml
if "$bin" lint --schema "file://$work/schema.json" wrong.toml; then
  echo "smoke: lint accepted a document that violates its schema" >&2; exit 1
fi

echo "== linkage"
case "$platform" in
  linux-*)
    # Decide from what ldd prints, not its exit status (static-PIE: "statically
    # linked", exit 0; non-PIE static: "not a dynamic executable", exit 1).
    ldd "$bin" >ldd.txt 2>&1 || true
    cat ldd.txt
    if ! grep -qE 'statically linked|not a dynamic executable' ldd.txt; then
      echo "smoke: $bin is dynamically linked (ldd lists libraries)" >&2; exit 1
    fi
    readelf -d "$bin" >readelf.txt 2>&1 || true
    if grep -q 'NEEDED' readelf.txt; then
      cat readelf.txt; echo "smoke: $bin has NEEDED entries in its dynamic section" >&2; exit 1
    fi
    echo "readelf -d: no NEEDED entries"
    ;;
  darwin-*)
    otool -L "$bin" >otool.txt
    cat otool.txt
    if tail -n +2 otool.txt | grep -vqE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
      echo "smoke: $bin loads a library outside the system" >&2; exit 1
    fi
    ;;
esac

echo "smoke: $platform OK"
