// Laptop-light unit check for the schema-aware name/author transform — no index, no
// namematching server, no taxonomy download. Runs the committed fixtures through
// taxonTransform in both layouts and asserts the (scientificName, authorship) split.
//
//   node scripts/check-transform.js
//
// Cases are keyed by the fixture row's taxonID (column 0), so fixture rows and their
// expectations can be reordered independently, and every row must have an expectation
// (and vice versa). Covers the legacy GBIF backbone layout (authorship bundled into
// scientificName -> split via canonicalName: parenthetical author, author with comma,
// name_author underscore, 'name, author', infraspecific var./f./subsp., autonyms with
// no author, complex/Unicode authors) and the COL XR layout (scientificName already
// author-free -> pass-through, plus a defensive trailing-author strip).

const fs = require('fs');
const assert = require('assert');
const { parse } = require('csv-parse/sync');
const { taxonTransform, columnsFromHeader } = require('../taxonTransform.js');

// taxonID -> expected { scientificName, scientificNameAuthorship } after the transform.
const GBIF_EXPECT = {
  cenchrus:        { sci: 'Cenchrus setaceus', auth: '(Forssk.) Morrone' },            // parenthetical author
  rhopalosiphum:   { sci: 'Rhopalosiphum', auth: 'Koch, 1854' },                       // genus + author, year
  festuca:         { sci: 'Festuca alpina', auth: 'Suter' },                           // species + bare author
  striatopollis:   { sci: 'Striatopollis trochuensis', auth: 'Ward, 1986' },
  anaerofustis:    { sci: 'Anaerofustis stercorihominis', auth: 'A' },                 // name_author (underscore)
  perciformorum:   { sci: 'Perciformorum', auth: '1900' },                            // 'name, author' via canonical
  epialtoides:     { sci: 'Epialtoides hiltoni', auth: '(Rathbun, 1923)' },
  agrotis:         { sci: 'Agrotis segetum', auth: '(Denis & Schiffermüller), 1775' }, // Unicode + ampersand
  nitella_var:     { sci: 'Nitella mucronata var. robustior', auth: 'A.Braun, 1867' }, // infraspecific var.
  nitella_f:       { sci: 'Nitella mucronata f. heteromorpha', auth: 'Fil.' },         // infraspecific f.
  claroideoglomus: { sci: 'Claroideoglomus luteum', auth: '(L.J.Kenn., J.C.Stutz & J.B.Morton) C.Walker & A.Schüßler' },
  pacispora:       { sci: 'Pacispora scintillans', auth: '(S.L.Rose & Trappe) Sieverd. & Oehl' },
  leucanthemum:    { sci: 'Leucanthemum gayanum subsp. demnatense', auth: '(Murb.), 1939' }, // subsp.
  silene:          { sci: 'Silene vulgaris f. vulgaris', auth: '' },                   // autonym, no author
  hippomarathrum:  { sci: 'Hippomarathrum montanum subsp. polyphyllum', auth: '(Ten.)' },
  erucastrum:      { sci: 'Erucastrum nasturtiifolium subsp. nasturtiifolium', auth: '' }, // autonym subsp.
};

const COL_EXPECT = {
  col_cenchrus:      { sci: 'Cenchrus setaceus', auth: '(Forssk.) Morrone' },          // author-free pass-through
  col_infraspecific: { sci: 'Solanum pentaphyllum var. pentaphyllum', auth: '' },
  col_defensive:     { sci: 'Foo bar', auth: 'Author' },                              // defensive trailing-author strip
  col_autonym:       { sci: 'Silene vulgaris f. vulgaris', auth: '' },
  col_subsp:         { sci: 'Leucanthemum gayanum subsp. demnatense', auth: '(Murb.) 1939' },
};

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

function runLayout(title, file, expect) {
  console.log(title);
  const rows = parse(fs.readFileSync(file), { quote: null, delimiter: '\t' });
  const cols = columnsFromHeader(rows[0]);
  const seen = {};
  rows.slice(1).forEach((r) => {
    const id = r[0];
    seen[id] = true;
    const exp = expect[id];
    if (!exp) { failures++; console.log(`  FAIL <no expectation for fixture row '${id}'>`); return; }
    const out = taxonTransform([...r], undefined, cols);
    check(id, { sci: out[cols.scientificName], auth: out[cols.scientificNameAuthorship] }, exp);
  });
  Object.keys(expect).forEach((id) => {
    if (!seen[id]) { failures++; console.log(`  FAIL <expectation '${id}' has no fixture row>`); }
  });
}

runLayout('Legacy GBIF backbone layout (author bundled, split via canonicalName):',
  __dirname + '/../test/fixtures/gbif-taxon-sample.tsv', GBIF_EXPECT);
runLayout('COL XR layout (scientificName author-free):',
  __dirname + '/../test/fixtures/col-taxon-sample.tsv', COL_EXPECT);

if (failures) { console.error(`\n${failures} check(s) failed`); process.exit(1); }
console.log(`\nAll transform checks passed (${Object.keys(GBIF_EXPECT).length} GBIF + ${Object.keys(COL_EXPECT).length} COL).`);
