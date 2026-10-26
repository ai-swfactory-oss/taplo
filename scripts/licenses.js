#!/usr/bin/env node
'use strict';

// Writes THIRD-PARTY-LICENSES for every crate compiled into the binary, from `cargo metadata` (run with
// --filter-platform for the build target, after `cargo fetch --locked`), and copies the source of every MPL-2.0 crate
// that is compiled in.
//
//   node scripts/licenses.js <metadata.json> <manifest> <out THIRD-PARTY-LICENSES> <mpl outdir> <cargo home>
//
// Policy (fails, naming the crate, otherwise):
// - A crate's licence expression must be satisfiable by permissive licences (MIT, Apache-2.0, BSD, ISC, Zlib,
//   Unicode, ...). For an OR, the first permissive alternative is used.
// - MPL-2.0 is accepted only for a crate and version listed in upstream.json .licenses.mpl_sources; its .crate must
//   be in cargo's cache and match both the checksum in that list and Cargo.lock's (the crates.io index checksum).
//   It is copied to <mpl outdir> for the release. Any other copyleft or unknown licence is a licence question.
// - A crate with no licence expression is accepted only if it is listed in .licenses.license_file_only and ships
//   its licence file.
// - Licence texts come from the crate's own LICENSE*/COPYING*/NOTICE* files. A crate that ships none gets the
//   pinned MIT or Apache-2.0 text from licenses/ (with its authors as the copyright line); any other licence
//   without a text in the crate fails.
// Dependencies only reachable as dev-dependencies are not compiled in and are left out; build dependencies are
// kept (conservative).

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const PERMISSIVE = new Set([
  '0BSD', 'Apache-2.0', 'Apache-2.0 WITH LLVM-exception', 'BSD-2-Clause', 'BSD-3-Clause', 'BSL-1.0',
  'CC0-1.0', 'CDLA-Permissive-2.0', 'ISC', 'MIT', 'MIT-0', 'Unicode-3.0', 'Unicode-DFS-2016', 'Unlicense', 'Zlib',
]);
const COPYLEFT = /(^|[^A-Za-z])(A?GPL|LGPL|MPL|EPL|CDDL|EUPL|OSL|CPAL|SSPL)-/;

function fail(message) {
  process.stderr.write(`licenses: ${message}\n`);
  process.exit(1);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function stripParens(s) {
  let t = s.trim();
  while (t.startsWith('(') && t.endsWith(')')) {
    let depth = 0;
    let wraps = true;
    for (let i = 0; i < t.length; i++) {
      if (t[i] === '(') depth++;
      if (t[i] === ')') depth--;
      if (depth === 0 && i < t.length - 1) { wraps = false; break; }
    }
    if (!wraps) break;
    t = t.slice(1, -1).trim();
  }
  return t;
}

function splitTop(s, op) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '(') depth++;
    else if (s[i] === ')') depth--;
    else if (depth === 0 && s.startsWith(op, i)) {
      parts.push(s.slice(start, i));
      start = i + op.length;
      i += op.length - 1;
    }
  }
  parts.push(s.slice(start));
  return parts.map(stripParens);
}

// Returns the licence ids used for this expression, or throws a message.
function choose(expression, mplAllowed) {
  const expr = stripParens(expression.replace(/\s*\/\s*/g, ' OR '));
  const used = [];
  for (const conjunct of splitTop(expr, ' AND ')) {
    const alternatives = splitTop(conjunct, ' OR ');
    if (alternatives.some((a) => a.includes(' AND ') || a.includes(' OR '))) {
      // Nested expression inside an alternative: accept the first alternative that resolves.
      let picked = null;
      for (const a of alternatives) {
        try { picked = choose(a, mplAllowed); break; } catch { /* try the next */ }
      }
      if (!picked) throw `no acceptable alternative in "${conjunct}"`;
      used.push(...picked);
      continue;
    }
    const permissive = alternatives.find((a) => PERMISSIVE.has(a));
    if (permissive) { used.push(permissive); continue; }
    if (alternatives.includes('MPL-2.0') && mplAllowed) { used.push('MPL-2.0'); continue; }
    const copyleft = alternatives.find((a) => COPYLEFT.test(a));
    if (copyleft) throw `copyleft licence ${copyleft} with no permissive alternative ("${conjunct}")`;
    throw `licence "${conjunct}" is not on the permissive list`;
  }
  return used;
}

function licenceFiles(dir) {
  return fs.readdirSync(dir)
    .filter((f) => /^(licen[cs]e|copying|notice|unlicense)([-._].*)?$/i.test(f))
    .filter((f) => fs.statSync(path.join(dir, f)).isFile())
    .sort();
}

function main() {
  const [metadataFile, manifestFile, outFile, mplOut, cargoHome] = process.argv.slice(2);
  if (!cargoHome) fail('usage: licenses.js <metadata.json> <manifest> <out> <mpl outdir> <cargo home>');
  const root = path.resolve(__dirname, '..');
  const meta = JSON.parse(fs.readFileSync(metadataFile, 'utf8'));
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  const mplPinned = new Map((manifest.licenses?.mpl_sources ?? []).map((m) => [`${m.crate}@${m.version}`, m.cksum]));
  const fileOnly = new Set(manifest.licenses?.license_file_only ?? []);
  const lock = fs.readFileSync(path.join(meta.workspace_root, 'Cargo.lock'), 'utf8');

  const packages = new Map(meta.packages.map((p) => [p.id, p]));
  const nodes = new Map(meta.resolve.nodes.map((n) => [n.id, n]));
  const rootId = meta.resolve.root;
  const seen = new Set([rootId]);
  const queue = [rootId];
  while (queue.length) {
    const node = nodes.get(queue.shift());
    for (const dep of node.deps) {
      const kinds = (dep.dep_kinds ?? []).map((k) => k.kind);
      if (kinds.length && kinds.every((k) => k === 'dev')) continue;
      if (!seen.has(dep.pkg)) { seen.add(dep.pkg); queue.push(dep.pkg); }
    }
  }
  seen.delete(rootId);

  const groups = new Map(); // text -> [crate labels]
  const mplUsed = [];
  const crates = [...seen].map((id) => packages.get(id)).sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));
  for (const p of crates) {
    const label = `${p.name} ${p.version}`;
    const dir = path.dirname(p.manifest_path);
    const files = licenceFiles(dir);
    let used;
    if (p.license) {
      try { used = choose(p.license, mplPinned.has(`${p.name}@${p.version}`)); } catch (message) {
        fail(`${label}: ${message}. This is a licence question; nothing is built until it is ruled on.`);
      }
    } else if (p.license_file && fileOnly.has(p.name)) {
      if (!files.length) fail(`${label}: declares license-file ${p.license_file} but ships no licence file`);
      used = ['LicenseRef-file'];
    } else {
      fail(`${label}: no licence expression${p.license_file ? ' (license-file only, not listed in .licenses.license_file_only)' : ''}`);
    }

    let text = '';
    if (files.length) {
      text = files.map((f) => `--- ${f} ---\n${fs.readFileSync(path.join(dir, f), 'utf8').trimEnd()}\n`).join('\n');
    } else {
      for (const id of new Set(used)) {
        if (id === 'MIT') {
          text += `--- MIT ---\nCopyright (c) ${(p.authors ?? []).join(', ') || `the ${p.name} authors`}\n\n${fs.readFileSync(path.join(root, 'licenses/MIT.txt'), 'utf8')}`;
        } else if (id === 'Apache-2.0') {
          text += `--- Apache-2.0 ---\n${fs.readFileSync(path.join(root, 'licenses/Apache-2.0.txt'), 'utf8')}`;
        } else {
          fail(`${label}: licensed ${id} but ships no licence text, and no pinned text exists for ${id}`);
        }
      }
    }
    if (!groups.has(text)) groups.set(text, []);
    groups.get(text).push(`${label} (${p.license ?? `license-file ${p.license_file}`}; used: ${used.join(', ')})`);

    if (used.includes('MPL-2.0')) {
      const pinned = mplPinned.get(`${p.name}@${p.version}`);
      const re = new RegExp(`name = "${p.name}"\\nversion = "${p.version.replace(/\./g, '\\.')}"\\nsource = "[^"]+"\\nchecksum = "([0-9a-f]{64})"`);
      const locked = re.exec(lock)?.[1];
      if (locked !== pinned) fail(`${label}: Cargo.lock checksum ${locked} != pinned ${pinned}`);
      const cacheRoot = path.join(cargoHome, 'registry', 'cache');
      const crate = fs.readdirSync(cacheRoot).map((d) => path.join(cacheRoot, d, `${p.name}-${p.version}.crate`)).find((f) => fs.existsSync(f));
      if (!crate) fail(`${label}: ${p.name}-${p.version}.crate is not in ${cacheRoot}`);
      const got = sha256(crate);
      if (got !== pinned) fail(`${label}: cached crate sha256 ${got} != pinned ${pinned}`);
      fs.mkdirSync(mplOut, { recursive: true });
      fs.copyFileSync(crate, path.join(mplOut, path.basename(crate)));
      mplUsed.push(`${p.name}-${p.version}.crate`);
    }
  }
  for (const key of mplPinned.keys()) {
    const [name, version] = key.split('@');
    if (!mplUsed.includes(`${name}-${version}.crate`)) fail(`${key} is pinned in .licenses.mpl_sources but is not compiled in; update upstream.json`);
  }

  let out = 'Third-party licences for the crates compiled into this taplo binary.\n';
  out += `Generated from cargo metadata for ${crates.length} crates (dev-only dependencies excluded).\n`;
  if (mplUsed.length) {
    out += `\nMPL-2.0 crates compiled in: ${mplUsed.join(', ')}. Their complete source (the .crate,\n`;
    out += 'checksum-verified against the crates.io index) is attached to the GitHub release that\n';
    out += 'published this package, and is available from https://crates.io.\n';
  }
  for (const [text, labels] of groups) {
    out += `\n${'='.repeat(78)}\n${labels.join('\n')}\n${'-'.repeat(78)}\n${text}`;
  }
  fs.writeFileSync(outFile, out);
  process.stdout.write(`licenses: ${crates.length} crates, ${groups.size} distinct licence texts, MPL sources: ${mplUsed.join(', ') || 'none'}\n`);
}

main();
