// Laptop-light unit check for the schema-aware name/author transform — no index, no
// namematching server, no taxonomy download. Runs the committed fixtures through
// taxonTransform in both layouts and asserts the split.
//
//   node scripts/check-transform.js
//
// Covers: COL XR layout (scientificName already author-free -> pass-through, with a
// defensive trailing-author strip) and the legacy GBIF backbone layout (author bundled
// into scientificName -> split using canonicalName).

const fs = require('fs');
const assert = require('assert');
const { parse } = require('csv-parse/sync');
const { taxonTransform, columnsFromHeader } = require('../taxonTransform.js');

function run(file) {
  const rows = parse(fs.readFileSync(file), { quote: null, delimiter: '\t' });
  const cols = columnsFromHeader(rows[0]);
  return rows.slice(1).map((r) => {
    const out = taxonTransform([...r], undefined, cols);
    return { sci: out[cols.scientificName], auth: out[cols.scientificNameAuthorship] };
  });
}

let failures = 0;
function check(label, actual, expected) {
  try {
    assert.deepStrictEqual(actual, expected);
    console.log(`  ok   ${label}`);
  } catch (e) {
    failures++;
    console.log(`  FAIL ${label}\n       expected ${JSON.stringify(expected)}\n       got      ${JSON.stringify(actual)}`);
  }
}

console.log('COL XR layout (scientificName author-free):');
const col = run(__dirname + '/../test/fixtures/col-taxon-sample.tsv');
check('clean name kept verbatim',        col[0], { sci: 'Cenchrus setaceus', auth: '(Forssk.) Morrone' });
check('infraspecific name kept verbatim', col[1], { sci: 'Solanum pentaphyllum var. pentaphyllum', auth: '' });
check('defensive trailing-author strip',  col[2], { sci: 'Foo bar', auth: 'Author' });

console.log('Legacy GBIF backbone layout (author bundled, split via canonicalName):');
const gbif = run(__dirname + '/../test/fixtures/gbif-taxon-sample.tsv');
check('split parenthetical author', gbif[0], { sci: 'Cenchrus setaceus', auth: '(Forssk.) Morrone' });
check('split genus + author',       gbif[1], { sci: 'Rhopalosiphum', auth: 'Koch, 1854' });
check('split species + author',     gbif[2], { sci: 'Festuca alpina', auth: 'Suter' });

if (failures) { console.error(`\n${failures} check(s) failed`); process.exit(1); }
console.log('\nAll transform checks passed.');
