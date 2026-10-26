'use strict';

// Named tests for scripts/licenses.js, the third-party licence generator, over synthetic cargo metadata: a copyleft
// crate compiled in fails as a licence question; MPL-2.0 passes only when pinned in upstream.json and its cached
// .crate matches the pin and Cargo.lock, and that source is copied out; a dev-only dependency is left out; a crate
// with no licence text gets the pinned MIT text; a license-file-only crate must be allowlisted.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const script = path.resolve(__dirname, '../scripts/licenses.js');

function fixture({ crates, mpl = [], fileOnly = [] }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'licenses-'));
  const ws = path.join(dir, 'ws');
  fs.mkdirSync(ws);
  const cache = path.join(dir, 'cargo', 'registry', 'cache', 'index.crates.io-test');
  fs.mkdirSync(cache, { recursive: true });
  const rootId = 'root 1.0.0';
  const packages = [{ id: rootId, name: 'root', version: '1.0.0', license: 'MIT', manifest_path: path.join(ws, 'Cargo.toml') }];
  const deps = [];
  let lock = 'version = 3\n';
  const pins = [];
  for (const c of crates) {
    const id = `${c.name} ${c.version}`;
    const cdir = path.join(dir, 'src', `${c.name}-${c.version}`);
    fs.mkdirSync(cdir, { recursive: true });
    for (const [f, text] of Object.entries(c.files ?? {})) fs.writeFileSync(path.join(cdir, f), text);
    packages.push({ id, name: c.name, version: c.version, license: c.license ?? null, license_file: c.licenseFile ?? null,
      authors: ['A. Author'], manifest_path: path.join(cdir, 'Cargo.toml') });
    deps.push({ pkg: id, dep_kinds: [{ kind: c.dev ? 'dev' : null }] });
    const crateFile = path.join(cache, `${c.name}-${c.version}.crate`);
    fs.writeFileSync(crateFile, `crate ${c.name}`);
    const sum = crypto.createHash('sha256').update(fs.readFileSync(crateFile)).digest('hex');
    lock += `\n[[package]]\nname = "${c.name}"\nversion = "${c.version}"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "${sum}"\n`;
    if (mpl.includes(c.name)) pins.push({ crate: c.name, version: c.version, cksum: c.badPin ? '0'.repeat(64) : sum });
  }
  fs.writeFileSync(path.join(ws, 'Cargo.lock'), lock);
  const meta = { workspace_root: ws, packages, resolve: { root: rootId, nodes: [{ id: rootId, deps }, ...crates.map((c) => ({ id: `${c.name} ${c.version}`, deps: [] }))] } };
  fs.writeFileSync(path.join(dir, 'metadata.json'), JSON.stringify(meta));
  fs.writeFileSync(path.join(dir, 'upstream.json'), JSON.stringify({ licenses: { mpl_sources: pins, license_file_only: fileOnly } }));
  return dir;
}

function run(dir) {
  return spawnSync(process.execPath, [script, path.join(dir, 'metadata.json'), path.join(dir, 'upstream.json'),
    path.join(dir, 'THIRD-PARTY-LICENSES'), path.join(dir, 'mpl'), path.join(dir, 'cargo')], { encoding: 'utf8' });
}

test('a GPL-only crate compiled in fails as a licence question', () => {
  const r = run(fixture({ crates: [{ name: 'gplcrate', version: '1.0.0', license: 'GPL-3.0-only', files: { LICENSE: 'GPL' } }] }));
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /gplcrate 1\.0\.0: copyleft licence GPL-3\.0-only.*licence question/);
});

test('an MPL-2.0 crate not pinned in upstream.json fails', () => {
  const r = run(fixture({ crates: [{ name: 'roots', version: '0.1.0', license: 'MPL-2.0', files: { LICENSE: 'MPL' } }] }));
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /roots 0\.1\.0: copyleft licence MPL-2\.0/);
});

test('a pinned MPL-2.0 crate whose cached .crate does not match the pin fails', () => {
  const r = run(fixture({ crates: [{ name: 'roots', version: '0.1.0', license: 'MPL-2.0', files: { LICENSE: 'MPL' }, badPin: true }], mpl: ['roots'] }));
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /Cargo\.lock checksum .* != pinned/);
});

test('a pinned MPL-2.0 crate passes and its source is copied out; texts are written', () => {
  const dir = fixture({ crates: [
    { name: 'roots', version: '0.1.0', license: 'MPL-2.0', files: { LICENSE: 'Mozilla Public License Version 2.0' } },
    { name: 'dual', version: '2.0.0', license: 'MIT OR Apache-2.0' },
    { name: 'devonly', version: '1.0.0', license: 'GPL-3.0-only', dev: true },
  ], mpl: ['roots'] });
  const r = run(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(fs.existsSync(path.join(dir, 'mpl', 'roots-0.1.0.crate')));
  const out = fs.readFileSync(path.join(dir, 'THIRD-PARTY-LICENSES'), 'utf8');
  assert.match(out, /Mozilla Public License Version 2\.0/);
  assert.match(out, /dual 2\.0\.0 \(MIT OR Apache-2\.0; used: MIT\)/);
  assert.match(out, /Copyright \(c\) A\. Author/);
  assert.doesNotMatch(out, /devonly/);
});

test('a license-file-only crate must be allowlisted and ship its file', () => {
  const crates = [{ name: 'ring', version: '0.17.7', licenseFile: 'LICENSE', files: { LICENSE: 'ring licence' } }];
  assert.notEqual(run(fixture({ crates })).status, 0);
  const dir = fixture({ crates, fileOnly: ['ring'] });
  const r = run(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(fs.readFileSync(path.join(dir, 'THIRD-PARTY-LICENSES'), 'utf8'), /ring licence/);
});

test('(MIT OR Apache-2.0) AND Unicode-DFS-2016 resolves to permissive licences', () => {
  const dir = fixture({ crates: [{ name: 'uid', version: '1.0.12', license: '(MIT OR Apache-2.0) AND Unicode-DFS-2016', files: { 'LICENSE-UNICODE': 'unicode' } }] });
  const r = run(dir);
  assert.equal(r.status, 0, r.stderr);
  assert.match(fs.readFileSync(path.join(dir, 'THIRD-PARTY-LICENSES'), 'utf8'), /used: MIT, Unicode-DFS-2016/);
});
