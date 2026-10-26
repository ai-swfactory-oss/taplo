#!/usr/bin/env bash
# Builds taplo from the verified crate (the output of scripts/fetch.sh) on the
# machine it runs on, with upstream's default features, and writes the
# third-party licences for exactly what was compiled in.
#
#   scripts/build.sh <fetchdir> <outdir>
#
# - Dependencies: `cargo fetch --locked` downloads every crate in the crate's
#   own Cargo.lock into a fresh CARGO_HOME, and cargo verifies each against the
#   lockfile's checksum (the crates.io index checksum). The build then runs
#   `cargo build --release --locked --frozen` (offline).
# - linux: run inside the pinned rust Alpine (musl) image (build.yml does that);
#   musl targets link statically. The result must have no NEEDED entries.
# - darwin: links against the system only; the result may load nothing outside
#   /usr/lib and /System. MACOSX_DEPLOYMENT_TARGET comes from upstream.json.
# - scripts/licenses.js writes THIRD-PARTY-LICENSES from cargo metadata for the
#   build target, and copies the source of every MPL-2.0 crate compiled in
#   (upstream.json .licenses.mpl_sources) to <outdir>/mpl-sources/.
#
# Result: <outdir>/taplo, <outdir>/LICENSE, <outdir>/THIRD-PARTY-LICENSES,
#         <outdir>/mpl-sources/*.crate
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${UPSTREAM_JSON:-$root/upstream.json}
fetched=$(cd "${1:?usage: build.sh <fetchdir> <outdir>}" && pwd)
mkdir -p "${2:?usage: build.sh <fetchdir> <outdir>}"
out=$(cd "$2" && pwd)

crate=$(jq -er .crate "$manifest")
version=$(jq -er .version "$manifest")
src="$fetched/src/$crate-$version"
[ -f "$src/Cargo.lock" ] || { echo "build: $src has no Cargo.lock (run scripts/fetch.sh first)" >&2; exit 1; }

work=$(mktemp -d)
CARGO_HOME="$work/cargo-home"
CARGO_TARGET_DIR="$work/target"
export CARGO_HOME CARGO_TARGET_DIR
case "$(uname -s)" in
  Darwin)
    MACOSX_DEPLOYMENT_TARGET=$(jq -er .builder.macos_deployment_target "$manifest")
    export MACOSX_DEPLOYMENT_TARGET
    # Link the macOS system libraries (libiconv, libSystem) from the Apple SDK,
    # never a toolchain's own copies: the SDK comes from the system xcrun with
    # any toolchain override cleared, so a nix shell (whose linker otherwise
    # finds its own libiconv) and a GitHub macOS runner resolve the same SDK.
    [ -x /usr/bin/xcrun ] || { echo "build: /usr/bin/xcrun is missing (install the Xcode command line tools)" >&2; exit 1; }
    sdk=$(env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk macosx --show-sdk-path) ||
      { echo "build: xcrun --sdk macosx --show-sdk-path failed" >&2; exit 1; }
    [ -e "$sdk/usr/lib/libiconv.tbd" ] || { echo "build: the macOS SDK $sdk has no usr/lib/libiconv.tbd" >&2; exit 1; }
    RUSTFLAGS="-L native=$sdk/usr/lib ${RUSTFLAGS:-}"
    export RUSTFLAGS
    echo "build: system libraries from $sdk"
    ;;
  Linux) ;;
  *) echo "build: unsupported build OS $(uname -s)" >&2; exit 1 ;;
esac

cargo --version
host=$(rustc -vV | sed -n 's/^host: //p')
echo "build: target $host"

cd "$src"
cargo fetch --locked
cargo build --release --locked --frozen --bin taplo
bin="$CARGO_TARGET_DIR/release/taplo"

# Outputs go to files before they are searched: an early-exiting reader in a
# pipe fails the writer under pipefail.
case "$(uname -s)" in
  Linux)
    readelf -d "$bin" >"$work/linkage.txt" 2>&1 || true
    if grep -q 'NEEDED' "$work/linkage.txt"; then
      cat "$work/linkage.txt" >&2
      echo "build: taplo is dynamically linked" >&2; exit 1
    fi
    readelf -l "$bin" >"$work/program-headers.txt" 2>&1 || true
    if grep -q 'INTERP' "$work/program-headers.txt"; then
      echo "build: taplo requests a program interpreter (not static)" >&2; exit 1
    fi
    echo "build: static (no NEEDED, no INTERP)"
    ;;
  Darwin)
    otool -L "$bin" >"$work/linkage.txt"
    cat "$work/linkage.txt"
    if tail -n +2 "$work/linkage.txt" | grep -vqE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
      echo "build: taplo loads a library outside the system" >&2; exit 1
    fi
    ;;
esac

"$bin" --version >"$work/version.txt"
first=$(sed -n 1p "$work/version.txt")
echo "$first"
[ "$first" = "taplo $version" ] || { echo "build: taplo --version printed '$first', expected 'taplo $version'" >&2; exit 1; }

cargo metadata --format-version 1 --locked --offline --filter-platform "$host" >"$work/metadata.json"
rm -rf "$out/mpl-sources"
node "$root/scripts/licenses.js" "$work/metadata.json" "$manifest" "$out/THIRD-PARTY-LICENSES" "$out/mpl-sources" "$CARGO_HOME"

cp "$bin" "$out/taplo"
chmod 755 "$out/taplo"
cp "$fetched/LICENSE" "$out/LICENSE"
echo "build: $out/taplo OK"
