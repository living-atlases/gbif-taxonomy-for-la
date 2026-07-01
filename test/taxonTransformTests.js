// End-to-end tests over a SUBSET of the taxonomy (see `--prepare-tests`), so development
// is fast: the index is built from ~10k taxa + the species referenced here, not the full
// dataset. Run with: ./gbif-taxonomy-for-la-docker --backbone --prepare-tests --namematching-index --tests <date>
//
// The pure name/author split logic is covered deterministically (no download, no server)
// by ../scripts/check-transform.js. This suite focuses on what genuinely needs a built
// index + the namematching server, and on a schema-aware split sanity check.

const waitOn = require("wait-on");
const assert = require("assert");
const { taxonTransform, columnsFromHeader } = require("../taxonTransform.js");
const { parse } = require("csv-parse/sync");
const fs = require('fs');
const kill = require('tree-kill');
const { execFile } = require('child_process');
const axios = require('axios');

const taxonFile = process.env.TAXON_FILE;

// Column layout resolved from the Taxon(-tests).tsv header, so tests work on both the
// legacy GBIF backbone and COL (dwc:-prefixed terms, different column order).
let cols;

// execFile (no shell) avoids command injection; grep exits 1 when there is no match.
function grepName(name, done) {
  execFile('grep', ['-m', '1', name, taxonFile], { timeout: 50000 }, (err, stdout) => {
    if (err && err.code !== 1) return done(err);
    done(null, stdout || '');
  });
}

let serviceProcess = null;

before(function(done) {
  this.timeout(60000);

  const header = fs.readFileSync(taxonFile, 'utf8').split('\n', 1)[0].split('\t');
  cols = columnsFromHeader(header);
  assert.ok(cols.scientificName >= 0 && cols.scientificNameAuthorship >= 0,
    "could not resolve scientificName/scientificNameAuthorship columns from header");

  serviceProcess = execFile('java', ['-jar', '/data/ala-namematching-server.jar', 'server', '/data/config.yml']);
  serviceProcess.stdout.on('data', (data) => console.log(`stdout: ${data}`));
  serviceProcess.stderr.on('data', (data) => console.error(`stderr: ${data}`));
  serviceProcess.on('error', (error) => console.error(`Error starting service: ${error}`));

  waitOn({ resources: ["http://localhost:9179"], delay: 10000, timeout: 30000 }, err => {
    if (err) { console.error(`Error waiting for service: ${err}`); return done(err); }
    console.log("Namematching service ready");
    done();
  });
});

after(function() {
  if (serviceProcess) {
    kill(serviceProcess.pid);
    console.log("Service process terminated");
  }
});

describe("scientificName / scientificNameAuthorship split (schema-aware sanity)", function() {
  it("taxon file should exist", function() {
    assert.equal(fs.existsSync(taxonFile), true);
  });

  it("splits a name with a parenthetical author (Cenchrus setaceus)", function(done) {
    grepName("Cenchrus setaceus (Forssk.) Morrone", function(err, line) {
      if (err) return done(err);
      assert.ok(line && line.length > 0, "Cenchrus setaceus not found in the subset");
      const record = taxonTransform(parse(line, { quote: null, delimiter: '\t' })[0], undefined, cols);
      assert.equal(record[cols.scientificName], "Cenchrus setaceus");
      assert.equal(record[cols.scientificNameAuthorship], "(Forssk.) Morrone");
      done();
    });
  });
});

describe("namematching service (end-to-end, subset index)", function() {
  it("Oenanthe is reported as a homonym", async function() {
    const response = await axios.get('http://localhost:9179/api/search?q=Oenanthe');
    assert.equal(response.data.success, false);
    assert.deepEqual(response.data.issues, ["homonym"]);
  });

  it("Cenchrus setaceus matches with the expected name and author", async function() {
    const response = await axios.get('http://localhost:9179/api/search?q=Cenchrus%20setaceus');
    assert.equal(response.data.success, true);
    assert.equal(response.data.scientificName, "Cenchrus setaceus");
    assert.equal(response.data.scientificNameAuthorship, "(Forssk.) Morrone");
    // taxonConceptID is now a COL identifier (alphanumeric, release-dependent), so assert
    // that one is returned rather than a fixed value (was the GBIF integer "5828232").
    assert.ok(response.data.taxonConceptID && String(response.data.taxonConceptID).length > 0,
      "expected a COL taxonConceptID");
  });
});
