#!/usr/bin/env node
// Manual/release-time snapshots: no public badge service or scheduled workflow.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const run = promisify(execFile);
const root = new URL('../', import.meta.url);
const output = new URL('docs/badges/', root);
const repository = 'MuQY1818/OpenYoink';
const args = process.argv.slice(2);
if (args.length && (args.length !== 2 || args[0] !== '--version'
    || !/^\d+\.\d+\.\d+$/.test(args[1]))) {
  console.error('Usage: node Scripts/update-readme-badges.mjs [--version X.Y.Z]');
  process.exit(1);
}
const requestedVersion = args[1] ? `v${args[1]}` : undefined;

async function api(endpoint, paginate = false) {
  const { stdout } = await run('gh', [
    'api', ...(paginate ? ['--paginate', '--slurp'] : []), endpoint,
  ], { timeout: 45000, maxBuffer: 16 * 1024 * 1024 });
  return JSON.parse(stdout);
}

function count(value) {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('Invalid GitHub count');
  return value;
}

function validate(data) {
  if (data.schemaVersion !== 1 || !/^v\d+\.\d+\.\d+$/.test(data.release)
      || !Number.isFinite(Date.parse(data.sampledAt))) {
    throw new Error('Invalid badge snapshot');
  }
  count(data.stars);
  count(data.downloads);
  return data;
}

function xml(value) {
  return String(value).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;',
  })[c]);
}

function badge(label, value, color, sampledAt) {
  // All current labels and values are ASCII; leave enough space for Verdana
  // without depending on a system font renderer or a remote SVG generator.
  const left = label.length * 7 + 12;
  const right = value.length * 7 + 12;
  const width = left + right;
  const title = xml(`${label}: ${value}${sampledAt ? ` (as of ${sampledAt.slice(0, 10)} UTC)` : ''}`);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="20" viewBox="0 0 ${width} 20" role="img" aria-label="${title}">
  <title>${title}</title>
  <rect width="${left}" height="20" fill="#555"/>
  <rect x="${left}" width="${right}" height="20" fill="${color}"/>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11">
    <text x="${left / 2}" y="14">${xml(label)}</text>
    <text x="${left + right / 2}" y="14">${xml(value)}</text>
  </g>
</svg>
`;
}

async function main() {
  // License metadata is defined by the repository, not API availability.
  const license = await readFile(new URL('LICENSE', root), 'utf8');
  if (!license.startsWith('MIT License\n')) throw new Error('Review license badge before updating');
  let data;
  try {
    const [repo, latest, pages] = await Promise.all([
      api(`repos/${repository}`),
      api(`repos/${repository}/releases/latest`),
      api(`repos/${repository}/releases?per_page=100`, true),
    ]);
    const downloads = pages.flat().filter(release => !release.draft)
      .reduce((total, release) => total + release.assets
        .reduce((sum, asset) => sum + count(asset.download_count), 0), 0);
    data = validate({
      schemaVersion: 1,
      release: requestedVersion ?? latest.tag_name,
      stars: count(repo.stargazers_count),
      downloads,
      sampledAt: new Date().toISOString(),
    });
  } catch {
    // Packaging runs before the new GitHub Release exists. Its explicit version
    // remains authoritative; preserve dated counts if GitHub is unavailable.
    if (!requestedVersion) throw new Error('GitHub refresh failed; existing badges were left unchanged');
    data = validate(JSON.parse(await readFile(new URL('data.json', output), 'utf8')));
    data.release = requestedVersion;
    console.warn(`GitHub refresh unavailable; keeping counts from ${data.sampledAt}`);
  }

  const files = {
    'release.svg': badge('release', data.release, '#007ec6'),
    'downloads.svg': badge('downloads', String(data.downloads), '#4c1', data.sampledAt),
    'macos.svg': badge('macOS', '15+', '#000'),
    'stars.svg': badge('stars', String(data.stars), '#dfb317', data.sampledAt),
    'license.svg': badge('license', 'MIT', '#007ec6'),
    'data.json': `${JSON.stringify(data, null, 2)}\n`,
  };
  await mkdir(output, { recursive: true });
  await Promise.all(Object.entries(files).map(([name, content]) =>
    writeFile(new URL(name, output), content)));
  console.log(`Updated ${fileURLToPath(output)}: ${data.release}, ${data.stars} stars, ${data.downloads} downloads`);
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
