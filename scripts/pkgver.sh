#!/usr/bin/env bash
# Prints the npm package version for upstream.json: the upstream version, or
# <version>-r.<repack> when this repository re-packs the same upstream release.
set -euo pipefail
manifest=${UPSTREAM_JSON:-$(cd "$(dirname "$0")/.." && pwd)/upstream.json}
jq -er 'if (.repack // 0) > 0 then "\(.version)-r.\(.repack)" else .version end' "$manifest"
