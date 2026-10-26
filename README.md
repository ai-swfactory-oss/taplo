# taplo

[![update](https://github.com/ai-swfactory-oss/taplo/actions/workflows/update.yml/badge.svg)](https://github.com/ai-swfactory-oss/taplo/actions/workflows/update.yml)
[![build](https://github.com/ai-swfactory-oss/taplo/actions/workflows/build.yml/badge.svg)](https://github.com/ai-swfactory-oss/taplo/actions/workflows/build.yml)

[taplo](https://github.com/tamasfe/taplo) (tamasfe/taplo), the TOML formatter, linter and language server, as npm packages: a **native binary per platform, built here from the `taplo-cli` crate on crates.io** with its locked dependencies, updated and published automatically to GitHub Packages. No WASM, no download at install time, no install scripts. (The `@taplo/cli` package on npmjs.com is a separate, WASM-based build.)

| Package | What |
|---|---|
| `@ai-swfactory-oss/taplo` | Thin: the `taplo` bin, and `binaryPath()` / `upstreamVersion` for Node. Depends optionally on the four platform packages, pinned exactly. |
| `@ai-swfactory-oss/taplo-linux-x64` | `bin/taplo`, static (musl), built in the pinned rust Alpine image |
| `@ai-swfactory-oss/taplo-linux-arm64` | the same for arm64 |
| `@ai-swfactory-oss/taplo-darwin-x64` | `bin/taplo`, linked against the macOS system libraries only |
| `@ai-swfactory-oss/taplo-darwin-arm64` | the same for arm64 |

npm installs only the platform package whose `os`/`cpu` match. Windows is not packaged (the ruling scope is darwin and linux).

## Install

The packages live on GitHub Packages, which needs two things even for public packages.

1. The scope line, in your project's `.npmrc` (safe to commit):

   ```
   @ai-swfactory-oss:registry=https://npm.pkg.github.com
   ```

2. A token with `read:packages` (a classic personal access token), in your **user** `~/.npmrc`, never in the repository:

   ```
   //npm.pkg.github.com/:_authToken=<token>
   ```

   In GitHub Actions, use `actions/setup-node` with `registry-url: https://npm.pkg.github.com`, `scope: "@ai-swfactory-oss"` and `NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`, and grant the job `packages: read`.

Then:

```sh
npm install --save-dev @ai-swfactory-oss/taplo
npx taplo --version
npx taplo fmt --check
```

From Node, spawn the binary directly; there is no node process in between:

```js
const { spawnSync } = require('node:child_process');
const { binaryPath, upstreamVersion } = require('@ai-swfactory-oss/taplo');

const check = spawnSync(binaryPath(), ['fmt', '--check', 'Cargo.toml'], { encoding: 'utf8' });
```

- `binaryPath(platform = process.platform, arch = process.arch)` returns the absolute path of the binary.
  - It throws `UnsupportedPlatformError` (with `platform` and `arch`) when no binary is published for that os and cpu.
  - It throws `PlatformPackageMissingError` (with `platform`, `arch` and `packageName`) when one is published but its package is not installed, for example after `--omit=optional`.
- `upstreamVersion` is the taplo version the binary reports, for example `0.10.0` (`taplo --version` prints `taplo 0.10.0`).
- `supportedPlatforms` lists the `<os>-<cpu>` pairs a binary is published for.

Installing with `--omit=optional` (or `--no-optional`) leaves no binary; `taplo` then says so and exits 1.

## How the binary is made, and how to check it

1. **Source.** [`upstream.json`](upstream.json) pins the `taplo-cli` version and its **crates.io index checksum** (the `cksum` field of https://index.crates.io/ta/pl/taplo-cli). `scripts/fetch.sh` downloads `taplo-cli-<version>.crate` from crates.io and deletes and refuses it unless its sha256 equals that checksum, and refuses a crate that ships no `Cargo.lock`. The named test `test/digest-mismatch.sh` proves both refusals. taplo's MIT `LICENSE` is taken from tamasfe/taplo at the commit the crate records in `.cargo_vcs_info.json`.
2. **Dependencies.** `cargo fetch --locked` downloads every crate in that `Cargo.lock`, and cargo verifies each against the lockfile's checksum (the crates.io index checksum), so the single pinned checksum pins the whole build.
3. **Build** (`scripts/build.sh`): `cargo build --release --locked --frozen --bin taplo` with upstream's default features (`completions`, `lint`, `lsp`, `rustls-tls`, `toml-test`).
   - linux: inside the rust Alpine image pinned by digest in `upstream.json` (musl, static). It is checked to have no `NEEDED` entries and no program interpreter.
   - darwin: with the pinned `MACOSX_DEPLOYMENT_TARGET` and the pinned Rust toolchain. It is checked to load only `/usr/lib` and `/System` libraries.
4. **Licences** (`scripts/licenses.js`, named tests `test/licenses.test.js`): from `cargo metadata` for the build target it lists every crate compiled in (dev-only dependencies excluded) and writes `THIRD-PARTY-LICENSES` with each crate's own licence files, or the pinned MIT/Apache-2.0 text from [`licenses/`](licenses) when a crate ships none. The build fails on any copyleft or unknown licence, except MPL-2.0 crates listed in `upstream.json` `.licenses.mpl_sources`. Their `.crate` must match the pinned checksum and `Cargo.lock`, and is attached to the release.
5. **Provenance.** Every published tarball and binary carries a GitHub build-provenance attestation:

   ```sh
   gh attestation verify node_modules/@ai-swfactory-oss/taplo-linux-x64/bin/taplo --repo ai-swfactory-oss/taplo
   ```

## Licences and source

- taplo is **MIT** (Copyright (c) 2020 Ferenc Tamás). Every package ships its `LICENSE` and a `NOTICE`; every platform package also ships `THIRD-PARTY-LICENSES`.
- The binary includes **`webpki-roots` 0.25.4** (the Mozilla CA root store), which is **MPL-2.0**. Upstream's default `rustls-tls` feature brings it in, through `reqwest`. Its complete source, `webpki-roots-0.25.4.crate`, is attached to every GitHub release and checksum-verified against the crates.io index. The `NOTICE` names it and that location.
- Every GitHub release `v<version>` carries the npm tarballs, `taplo-cli-<version>.crate`, `LICENSE-taplo`, the MPL-2.0 crate sources, `THIRD-PARTY-LICENSES-<platform>`, `build-scripts.tar.gz` (the manifest, scripts and workflows) and `SHA256SUMS`. **Releases are never deleted while their package version is served.**

## Versions

- The package version **equals the taplo version** (`0.10.0`), for all five packages.
- A **re-pack** of the same taplo version (a build or packaging fix, rare) is published as `<version>-r.<n>`, set with `"repack": <n>` in `upstream.json`, with the dist-tag `latest`.

## Workflows

| Workflow | When | What |
|---|---|---|
| `update` | Daily; monthly keepalive | Reads the crates.io index. A newer non-yanked `taplo-cli` is pinned with its index checksum in a pull request, which `build` tests. If the new version compiles in a copyleft crate not listed in `upstream.json`, the build fails: a licence question for a maintainer. A missing release for main's version re-runs the publish. |
| `build` | Push to `main` touching the build inputs; manual; called by `update` | Named digest-mismatch and licence tests; checksum-verified fetch; build on four runners; stage; launcher tests; pack once; smoke-test the packed tarballs on four runners (`--version`, `fmt`, `get`, offline `lint` with and without a schema, linkage, licences, no install script). On push or manual publish it attests, publishes (platforms first) and creates the release. |
| `pr` | Every pull request | `build` without publishing. |
| `failures` | After `update`/`build` on `main` | Keeps one `build-failure` issue in sync. |

## License

- The scripts and workflows in this repository are **MIT** (see [`LICENSE`](LICENSE)).
- The **npm packages are MIT**, the licence of taplo, plus the third-party licences listed in `THIRD-PARTY-LICENSES`.

This project is not affiliated with the taplo project.
