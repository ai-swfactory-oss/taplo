'use strict';

const path = require('node:path');

const pkg = require('./package.json');

const SCOPE = '@ai-swfactory-oss';
const PREFIX = `${SCOPE}/taplo-`;

/** The taplo version this package runs: the upstream version, without any -r.N re-pack suffix. */
const upstreamVersion = pkg.version.replace(/-r\.\d+$/, '');

/** The `<os>-<cpu>` platforms a binary is published for, from the exactly pinned optional dependencies. */
const supportedPlatforms = Object.freeze(
  Object.keys(pkg.optionalDependencies || {})
    .filter((name) => name.startsWith(PREFIX))
    .map((name) => name.slice(PREFIX.length))
);

/** No taplo binary is published for this os and cpu. */
class UnsupportedPlatformError extends Error {
  constructor(platform, arch) {
    super(
      `@ai-swfactory-oss/taplo: no taplo binary is published for os ${platform} and cpu ${arch}; ` +
        `supported: ${supportedPlatforms.join(', ')}`
    );
    this.name = 'UnsupportedPlatformError';
    this.platform = platform;
    this.arch = arch;
  }
}

/** A binary is published for this os and cpu, but its platform package is not installed. */
class PlatformPackageMissingError extends Error {
  constructor(platform, arch, packageName) {
    super(
      `@ai-swfactory-oss/taplo: ${packageName} is not installed for os ${platform} and cpu ${arch}; ` +
        'reinstall without --omit=optional / --no-optional, or from a lockfile made on this platform'
    );
    this.name = 'PlatformPackageMissingError';
    this.platform = platform;
    this.arch = arch;
    this.packageName = packageName;
  }
}

/** Name of the platform package that carries the binary for this os and cpu. */
function platformPackage(platform = process.platform, arch = process.arch) {
  return `${PREFIX}${platform}-${arch}`;
}

/**
 * Absolute path of the native taplo binary for this os and cpu. Spawn it directly: there is no node process in
 * between. Throws UnsupportedPlatformError when no binary is published for them, and PlatformPackageMissingError
 * when one is but its package is not installed.
 */
function binaryPath(platform = process.platform, arch = process.arch) {
  if (!supportedPlatforms.includes(`${platform}-${arch}`)) throw new UnsupportedPlatformError(platform, arch);
  const name = platformPackage(platform, arch);
  let dir;
  try {
    dir = path.dirname(require.resolve(`${name}/package.json`));
  } catch {
    throw new PlatformPackageMissingError(platform, arch, name);
  }
  return path.join(dir, 'bin', 'taplo');
}

module.exports = {
  binaryPath,
  platformPackage,
  PlatformPackageMissingError,
  supportedPlatforms,
  UnsupportedPlatformError,
  upstreamVersion,
};
