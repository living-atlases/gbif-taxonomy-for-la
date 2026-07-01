// Regression gate for the COL migration: query a running ALA namematching server with a
// curated "golden set" of names and fail if a name that used to resolve stops resolving
// (or resolves differently). This guards against the migration to Catalogue of Life (COL
// XR) silently breaking name matching.
//
//   node scripts/regression-check.js [--golden <file>] [--url <base>] [--record]
//
//   --golden <file>  golden-set TSV (default: test/golden/regression-names.tsv)
//   --url <base>     namematching base URL (default: $NM_URL or http://localhost:9179)
//   --record         don't assert; query every name and print a golden-set TSV of the
//                    CURRENT answers to stdout, for a human to review and commit as the
//                    baseline (bootstraps the set from a real build).
//
// Golden TSV columns (tab-separated, with header):
//   query            the name to look up (e.g. "Oenanthe", "Cenchrus setaceus")
//   expectSuccess    "true" | "false"
//   expectName       expected response.scientificName        (blank = don't assert)
//   expectAuthor     expected response.scientificNameAuthorship (blank = don't assert)
//   expectIssues     comma-separated response.issues, order-insensitive (blank = don't assert)
//   note             free text
//
// taxonConceptID is intentionally NOT asserted by value: COL uses release-dependent
// alphanumeric ids (the old GBIF integer is gone). When expectSuccess is true we only
// assert that some taxonConceptID is present.

const fs = require('fs');
const axios = require('axios');

function parseArgs(argv) {
  const a = { golden: __dirname + '/../test/golden/regression-names.tsv',
              url: process.env.NM_URL || 'http://localhost:9179', record: false };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--golden') a.golden = argv[++i];
    else if (argv[i] === '--url') a.url = argv[++i];
    else if (argv[i] === '--record') a.record = true;
  }
  return a;
}

function readGolden(file) {
  const lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.length > 0);
  const header = lines[0].split('\t');
  const col = (name) => header.indexOf(name);
  return lines.slice(1).map((l) => {
    const f = l.split('\t');
    return {
      query: f[col('query')],
      expectSuccess: (f[col('expectSuccess')] || '').trim(),
      expectName: (f[col('expectName')] || '').trim(),
      expectAuthor: (f[col('expectAuthor')] || '').trim(),
      expectIssues: (f[col('expectIssues')] || '').trim(),
      note: (f[col('note')] || '').trim(),
    };
  });
}

const norm = (s) => (s === undefined || s === null ? '' : String(s));
const issuesArr = (s) => norm(s).split(',').map((x) => x.trim()).filter(Boolean).sort();
const eqIssues = (a, b) => { const x = issuesArr(a), y = issuesArr(b); return x.length === y.length && x.every((v, i) => v === y[i]); };

async function query(base, name) {
  const res = await axios.get(`${base}/api/search?q=${encodeURIComponent(name)}`, { timeout: 20000 });
  return res.data || {};
}

// Returns [] if the row matches expectations, or a list of human-readable diffs.
function compare(row, data) {
  const diffs = [];
  const gotSuccess = data.success === true;
  const wantSuccess = row.expectSuccess.toLowerCase() === 'true';
  if (row.expectSuccess !== '' && gotSuccess !== wantSuccess)
    diffs.push(`success: expected ${wantSuccess}, got ${gotSuccess}`);
  if (row.expectName !== '' && norm(data.scientificName) !== row.expectName)
    diffs.push(`scientificName: expected "${row.expectName}", got "${norm(data.scientificName)}"`);
  if (row.expectAuthor !== '' && norm(data.scientificNameAuthorship) !== row.expectAuthor)
    diffs.push(`author: expected "${row.expectAuthor}", got "${norm(data.scientificNameAuthorship)}"`);
  if (row.expectIssues !== '' && !eqIssues(row.expectIssues, (data.issues || []).join(',')))
    diffs.push(`issues: expected [${issuesArr(row.expectIssues)}], got [${issuesArr((data.issues || []).join(','))}]`);
  // When we expect a successful match, require *some* taxonConceptID (value is COL-dependent).
  if (row.expectSuccess.toLowerCase() === 'true' && gotSuccess && !norm(data.taxonConceptID))
    diffs.push('taxonConceptID: expected a value, got none');
  return diffs;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const rows = readGolden(args.golden);

  if (args.record) {
    // Emit a golden-set TSV of the current answers for review/curation.
    process.stdout.write('query\texpectSuccess\texpectName\texpectAuthor\texpectIssues\tnote\n');
    for (const row of rows) {
      let d = {};
      try { d = await query(args.url, row.query); } catch (e) { d = { success: false, _error: e.message }; }
      const out = [row.query, String(d.success === true), norm(d.scientificName), norm(d.scientificNameAuthorship),
                   (d.issues || []).join(','), row.note || (d._error ? `ERROR ${d._error}` : 'recorded')];
      process.stdout.write(out.join('\t') + '\n');
    }
    return;
  }

  let regressions = 0;
  console.log(`Regression gate: ${rows.length} golden names against ${args.url}`);
  for (const row of rows) {
    let data, err;
    try { data = await query(args.url, row.query); } catch (e) { err = e.message; }
    if (err) { regressions++; console.log(`  FAIL  ${row.query}\n        request error: ${err}`); continue; }
    const diffs = compare(row, data);
    if (diffs.length === 0) console.log(`  ok    ${row.query}`);
    else { regressions++; console.log(`  FAIL  ${row.query}\n        ${diffs.join('\n        ')}`); }
  }
  if (regressions) { console.error(`\n${regressions} regression(s) detected`); process.exit(1); }
  console.log(`\nNo regressions (${rows.length} names checked).`);
}

if (require.main === module) {
  main().catch((e) => { console.error(`regression-check fatal: ${e.stack || e}`); process.exit(2); });
}

module.exports = { parseArgs, readGolden, compare, issuesArr, eqIssues };
