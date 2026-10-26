#!/usr/bin/env bash
# Single-quoted jq programs and Markdown backticks are literal on purpose.
# shellcheck disable=SC2016
# Renders the npm packages from the per-platform builds.
#
#   scripts/stage.sh <builddir> <outdir>
#
# <builddir>/<platform>/{taplo,LICENSE,THIRD-PARTY-LICENSES} are the outputs of
# scripts/build.sh, one per platform in upstream.json.
# Result: <outdir>/taplo            the launcher (bin, binaryPath(), upstreamVersion)
#         <outdir>/taplo-<platform> one package per platform binary
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${UPSTREAM_JSON:-$root/upstream.json}
built=${1:?usage: stage.sh <builddir> <outdir>}
out=${2:?usage: stage.sh <builddir> <outdir>}

scope=@ai-swfactory-oss
repo_url=https://github.com/ai-swfactory-oss/taplo.git
crate=$(jq -er .crate "$manifest")
upstream=$(jq -er .version "$manifest")
cksum=$(jq -er .cksum "$manifest")
version=$(bash "$root/scripts/pkgver.sh")
read -r -a platforms <<<"$(jq -r '.platforms | join(" ")' "$manifest")"
release="https://github.com/ai-swfactory-oss/taplo/releases/tag/v$version"

common='{
  license: "MIT",
  author: "ai-swfactory",
  homepage: "https://github.com/ai-swfactory-oss/taplo#readme",
  bugs: { url: "https://github.com/ai-swfactory-oss/taplo/issues" },
  repository: { type: "git", url: $repo },
  publishConfig: { registry: "https://npm.pkg.github.com" }
}'

notice() { # <package name> <binary line>
  cat "$root/packages/NOTICE.in"
  printf '\nThis package: %s %s, built from the crates.io source %s-%s.crate\n' "$1" "$version" "$crate" "$upstream"
  printf '(sha256 %s, the crates.io index checksum) with its Cargo.lock.\n' "$cksum"
  printf '%s\n\n' "$2"
  printf 'MPL-2.0: the binary includes these crates under the Mozilla Public License 2.0.\n'
  printf 'Their complete source code form is attached to the GitHub release\n  %s\n' "$release"
  printf 'as the .crate files named below (each checksum-verified against the crates.io\n'
  printf 'index), and is also available from https://crates.io:\n'
  jq -r '.licenses.mpl_sources[] | "  \(.crate)-\(.version).crate (sha256 \(.cksum))"' "$manifest"
  printf '\nThe MPL-2.0 text and every other third-party licence are in THIRD-PARTY-LICENSES\n'
  printf '(platform packages) and in the release assets THIRD-PARTY-LICENSES-<platform>.\n'
}

rm -rf "$out"
mkdir -p "$out"

optional='{}'
for platform in "${platforms[@]}"; do
  os=${platform%%-*}
  cpu=${platform#*-}
  name="$scope/taplo-$platform"
  dir="$out/taplo-$platform"
  case "$os" in
    linux) linkage="statically linked (musl), built in $(jq -r .builder.rust_alpine "$manifest")" ;;
    darwin) linkage="linked against the macOS system libraries only, deployment target $(jq -r .builder.macos_deployment_target "$manifest")" ;;
  esac

  mkdir -p "$dir/bin"
  cp "$built/$platform/taplo" "$dir/bin/taplo"
  chmod 755 "$dir/bin/taplo"
  cp "$built/$platform/LICENSE" "$dir/LICENSE"
  cp "$built/$platform/THIRD-PARTY-LICENSES" "$dir/THIRD-PARTY-LICENSES"
  notice "$name" "Binary: bin/taplo, $linkage." >"$dir/NOTICE"
  {
    printf '# %s\n\n' "$name"
    printf 'taplo %s for `%s` / `%s`, built from the [taplo-cli](https://crates.io/crates/taplo-cli) crate on crates.io with its locked dependencies.\n\n' "$upstream" "$os" "$cpu"
    printf 'Do not install this package directly: install [`%s/taplo`](https://github.com/ai-swfactory-oss/taplo), which depends on it optionally and runs it.\n\n' "$scope"
    printf 'The binary is %s.\n\n' "$linkage"
    printf 'Provenance: `gh attestation verify bin/taplo --repo ai-swfactory-oss/taplo` (run in this package directory).\n\n'
    printf 'License: MIT (see `LICENSE`); third-party crates as listed in `THIRD-PARTY-LICENSES` and `NOTICE`.\n'
  } >"$dir/README.md"

  jq -n --arg name "$name" --arg version "$version" --arg upstream "$upstream" \
    --arg os "$os" --arg cpu "$cpu" --arg repo "$repo_url" \
    "{
      name: \$name,
      version: \$version,
      description: \"taplo \(\$upstream) for \(\$os)-\(\$cpu) (used by @ai-swfactory-oss/taplo)\",
      keywords: [\"taplo\", \"toml\", \"formatter\"],
      os: [\$os],
      cpu: [\$cpu],
      files: [\"bin/taplo\", \"LICENSE\", \"NOTICE\", \"THIRD-PARTY-LICENSES\", \"README.md\"],
      preferUnplugged: true
    } + $common" >"$dir/package.json"

  optional=$(jq -c --arg n "$name" --arg v "$version" '. + {($n): $v}' <<<"$optional")
done

launcher="$out/taplo"
mkdir -p "$launcher"
cp -R "$root/packages/taplo/." "$launcher/"
cp "$built/${platforms[0]}/LICENSE" "$launcher/LICENSE"
notice "$scope/taplo" "This package holds no binary: it runs the one from $scope/taplo-<platform>-<arch>." >"$launcher/NOTICE"
jq --arg version "$version" --arg repo "$repo_url" --argjson optional "$optional" \
  ". + {version: \$version, optionalDependencies: \$optional} + $common" \
  "$root/packages/taplo/package.json" >"$launcher/package.json"
chmod 755 "$launcher/bin/taplo.js"

echo "stage: $version ($upstream) -> $out"
ls -1 "$out"
