# @ai-swfactory-oss/taplo

[taplo](https://github.com/tamasfe/taplo) (tamasfe/taplo), the TOML formatter, linter and language server, as an npm package that runs a **native binary** for your platform (no WASM, no download at install time, no install scripts).

Platforms: `linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`. The binary comes from the matching optional dependency `@ai-swfactory-oss/taplo-<platform>-<arch>`: taplo built in this repository's workflow from the `taplo-cli` crate on crates.io (checksum-verified against the crates.io index) with its locked dependencies and upstream's default features.

## Install

The packages are on GitHub Packages. Point the scope at it (in your project's `.npmrc`):

```
@ai-swfactory-oss:registry=https://npm.pkg.github.com
```

GitHub Packages requires a token even for public packages: a classic personal access token with `read:packages`, in your user `~/.npmrc` (never commit it):

```
//npm.pkg.github.com/:_authToken=<token>
```

In GitHub Actions, `actions/setup-node` with `registry-url: https://npm.pkg.github.com` and `NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}` does this (the workflow needs `packages: read`).

```sh
npm install --save-dev @ai-swfactory-oss/taplo
npx taplo --version
```

## Use

```sh
taplo fmt --check
```

From Node, spawn the binary directly:

```js
const { binaryPath, upstreamVersion } = require('@ai-swfactory-oss/taplo');
// binaryPath(): absolute path to the native taplo binary for this os and cpu
// upstreamVersion: the taplo version, e.g. "0.10.0"
```

`binaryPath()` throws `UnsupportedPlatformError` (with `platform` and `arch`) when no binary is published for this os and cpu, and `PlatformPackageMissingError` when one is but its package was not installed (for example with `--omit=optional`).

## Verify

Every published tarball and binary has a GitHub build-provenance attestation:

```sh
gh attestation verify node_modules/@ai-swfactory-oss/taplo-linux-x64/bin/taplo \
  --repo ai-swfactory-oss/taplo
```

The attestation names the workflow run and commit that built the binary. Its source is the `taplo-cli` crate whose crates.io index checksum is pinned in the repository's `upstream.json`; the GitHub release of each version attaches that crate. Details: https://github.com/ai-swfactory-oss/taplo#how-the-binary-is-made-and-how-to-check-it

## Versions

The package version equals the taplo version. A rare re-pack of the same taplo release (packaging fix only) is published as `<version>-r.<n>` with the `latest` dist-tag.

## License

MIT, the license of taplo. See `LICENSE` and `NOTICE`. The binary also includes third-party crates under their own licences, listed with their texts in each platform package's `THIRD-PARTY-LICENSES`. One of them, `webpki-roots` (the Mozilla CA roots), is MPL-2.0; its source is attached to the GitHub release.
