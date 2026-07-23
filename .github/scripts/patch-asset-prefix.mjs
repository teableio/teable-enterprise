#!/usr/bin/env node
/**
 * patch-asset-prefix.mjs — release-time CDN prefix patch for teable-cloud images.
 *
 * Rewrites the Turbopack browser-runtime chunk base constant so dynamically
 * imported chunks load from the CDN instead of the app origin:
 *
 *   minified:   TURBOPACK))return;let t="/_next/"      (one per runtime chunk)
 *   unminified: CHUNK_BASE_PATH="/_next/"              (dev/fallback form)
 *        ->     ...="<cdnOrigin>/_next/"
 *
 * Server-rendered HTML picks the prefix up separately via the
 * NEXT_BUILD_ENV_ASSET_PREFIX env var at boot (pages router, non-standalone
 * `next start`), and the PageLoader route chunks already prepend the runtime
 * __NEXT_DATA__.assetPrefix — so the Turbopack runtime chunks are the only
 * build artifacts that need patching. community/plugins/.next is a separate
 * app with no CDN prefix; deliberately out of scope.
 *
 * Usage:
 *   node patch-asset-prefix.mjs <cdnOrigin> [appRoot]
 *     cdnOrigin  e.g. https://sss.teable.ai   (origin only, no path)
 *     appRoot    default /app
 *
 * Env:
 *   PATCH_DRY_RUN=1        scan + report only, write nothing
 *
 * Lives in this repo (deploy policy, like the wrapper Dockerfile inlined in
 * the workflows) and is bind-mounted into the image build — nothing is baked
 * into product images and ANY existing image is patchable. The pattern list
 * below is coupled to the Turbopack/minifier version of the teable-ee build:
 * when an upgrade changes the emitted form, ADD the new pattern — never
 * remove old ones, or patching older images (rollbacks!) breaks. The
 * verify-cdn-patchability canary in build-teable.yaml dry-runs this script
 * against every fresh build so a pattern drift shows up there first.
 *
 * This script is a release gate: every turbopack-*.js runtime chunk must
 * match exactly once, anything else aborts with a non-zero exit — a broken
 * launch is always preferable to a half-patched image.
 */

import fs from 'node:fs';
import path from 'node:path';

const MINIFIED_RE = /(\bTURBOPACK\)\)return;let [A-Za-z_$][A-Za-z0-9_$]*=)"\/_next\/"/g;
const UNMINIFIED_RE = /(\bCHUNK_BASE_PATH=)"\/_next\/"/g;

function fail(msg) {
  console.error(`[patch-asset-prefix] FATAL: ${msg}`);
  process.exit(1);
}

const [, , cdnOriginArg, appRootArg] = process.argv;
if (!cdnOriginArg) fail('missing <cdnOrigin> argument');

let cdnOrigin;
try {
  const url = new URL(cdnOriginArg);
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new Error('bad protocol');
  if (url.pathname !== '/' || url.search || url.hash) {
    throw new Error('origin only — no path, query or hash');
  }
  cdnOrigin = url.origin;
} catch (e) {
  fail(`invalid cdnOrigin "${cdnOriginArg}": ${e.message}`);
}

const appRoot = appRootArg ?? '/app';
const dryRun = process.env.PATCH_DRY_RUN === '1';
const chunksDir = path.join(appRoot, 'enterprise/app-ee/.next/static/chunks');

if (!fs.existsSync(chunksDir)) fail(`chunks dir does not exist: ${chunksDir}`);

const runtimeChunks = fs
  .readdirSync(chunksDir)
  .filter((name) => /^turbopack-[0-9a-f]+\.js$/.test(name))
  .sort();

if (runtimeChunks.length === 0) fail(`no turbopack-*.js runtime chunks found in ${chunksDir}`);

let patched = 0;

for (const name of runtimeChunks) {
  const file = path.join(chunksDir, name);
  const content = fs.readFileSync(file, 'utf8');

  const minified = [...content.matchAll(MINIFIED_RE)];
  const unminified = [...content.matchAll(UNMINIFIED_RE)];
  const total = minified.length + unminified.length;

  if (total !== 1) {
    fail(
      `expected exactly 1 chunk-base occurrence in ${name}, found ${total} ` +
        `(minified=${minified.length}, unminified=${unminified.length}) — bundler output changed?`
    );
  }

  if (!dryRun) {
    const next = content
      .replace(MINIFIED_RE, `$1"${cdnOrigin}/_next/"`)
      .replace(UNMINIFIED_RE, `$1"${cdnOrigin}/_next/"`);
    fs.writeFileSync(file, next);

    // Re-read and assert: original pattern gone, patched base present.
    const verify = fs.readFileSync(file, 'utf8');
    MINIFIED_RE.lastIndex = 0;
    UNMINIFIED_RE.lastIndex = 0;
    if (MINIFIED_RE.test(verify) || UNMINIFIED_RE.test(verify)) {
      fail(`verification failed: unpatched pattern still present in ${name}`);
    }
    if (!verify.includes(`"${cdnOrigin}/_next/"`)) {
      fail(`verification failed: patched base missing in ${name}`);
    }
  }

  patched += 1;
}

// Global backstop: after patching, NO file under static/ may still contain
// the chunk-base bootstrap pattern. Catches runtime code hiding outside the
// turbopack-*.js naming convention (e.g. after a Next/Turbopack upgrade).
if (!dryRun) {
  const staticRoot = path.join(appRoot, 'enterprise/app-ee/.next/static');
  const leftovers = [];
  const sweep = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) sweep(p);
      else if (entry.isFile() && entry.name.endsWith('.js')) {
        const content = fs.readFileSync(p, 'utf8');
        MINIFIED_RE.lastIndex = 0;
        UNMINIFIED_RE.lastIndex = 0;
        if (MINIFIED_RE.test(content) || UNMINIFIED_RE.test(content)) leftovers.push(p);
      }
    }
  };
  sweep(staticRoot);
  if (leftovers.length > 0) {
    fail(`global sweep found unpatched chunk-base pattern in: ${leftovers.join(', ')}`);
  }
}

console.log(
  `[patch-asset-prefix] ${dryRun ? 'would patch' : 'patched'} ${patched}/${runtimeChunks.length} ` +
    `turbopack runtime chunk(s) with prefix ${cdnOrigin}${dryRun ? '' : ', global sweep clean'}`
);
