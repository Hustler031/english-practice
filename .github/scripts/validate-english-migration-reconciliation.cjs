const fs = require('fs');
const crypto = require('crypto');

const ledgerPath = 'supabase/managed-migrations/ENGLISH_LIVE_LEDGER.json';
const expectedDigest = '7e4db65c9f58f22e4f7cb123104766d9524afa3a1892e465096faccc20f7c65f';
const fail = (message) => { throw new Error(`English migration reconciliation: ${message}`); };

if (!fs.existsSync(ledgerPath)) fail(`missing ${ledgerPath}`);
const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
if (ledger.project_ref !== 'hytehindbmjdwcfptsic') fail('unexpected Supabase project ref');
if (ledger.scope?.from !== '20260901' || ledger.scope?.through !== '20260904') fail('scope must remain Sep 1 through Sep 4, 2026');
if (ledger.expected_live_count !== 70) fail(`expected_live_count must be 70, got ${ledger.expected_live_count}`);
if (ledger.expected_tuple_sha256 !== expectedDigest) fail('ledger tuple fingerprint metadata changed');
if (!Array.isArray(ledger.live) || ledger.live.length !== 70) fail(`expected 70 live entries, got ${ledger.live?.length ?? 'none'}`);

const versions = new Set();
const tuples = [];
const dayCounts = new Map();
for (const row of ledger.live) {
  if (!/^202609(?:01|02|04)\d{6}$/.test(row.version)) fail(`out-of-scope version ${row.version}`);
  if (!/^english_/.test(row.name)) fail(`non-English migration ${row.version}:${row.name}`);
  if (versions.has(row.version)) fail(`duplicate live version ${row.version}`);
  versions.add(row.version);
  if (!['normalized', 'consolidated'].includes(row.mapping)) fail(`invalid mapping type for ${row.version}`);
  if (!Array.isArray(row.sources) || row.sources.length === 0) fail(`missing managed source for ${row.version}`);

  for (const source of row.sources) {
    if (!source.startsWith('supabase/managed-migrations/') || !source.endsWith('.sql')) fail(`invalid managed source path ${source}`);
    if (!fs.existsSync(source)) fail(`managed source does not exist: ${source}`);
  }
  for (const marker of row.markers || []) {
    const present = row.sources.some((source) => fs.readFileSync(source, 'utf8').includes(marker));
    if (!present) fail(`fingerprint marker missing for ${row.version}: ${marker}`);
  }

  tuples.push(`${row.version}:${row.name}`);
  const day = row.version.slice(0, 8);
  dayCounts.set(day, (dayCounts.get(day) || 0) + 1);
}

const digest = crypto.createHash('sha256').update(tuples.sort().join('\n')).digest('hex');
if (digest !== expectedDigest) fail(`live version/name set changed: ${digest}`);
const expectedDayCounts = { '20260901': 34, '20260902': 24, '20260904': 12 };
for (const [day, count] of Object.entries(expectedDayCounts)) {
  if (dayCounts.get(day) !== count) fail(`${day} expected ${count} entries, got ${dayCounts.get(day) || 0}`);
}

console.log(`English migration reconciliation passed: ${ledger.live.length}/70 live Sep1-Sep4 entries mapped.`);
