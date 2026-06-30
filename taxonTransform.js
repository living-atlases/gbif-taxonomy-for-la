const { parse } = require("csv-parse");
const { stringify } = require('csv-stringify');

const parser = parse({
  quote: null,
  delimiter: '\t'
});

const stringifier = stringify({
  quote: null,
  delimiter: '\t'
});

// https://stackoverflow.com/questions/3561493/is-there-a-regexp-escape-function-in-javascript
function escapeRegex(string) {
  return string.replace(/[/\-\\^$*+?.()|[\]{}]/g, '\\$&');
}

// Default column layout = GBIF backbone Taxon.tsv. Kept as the default so existing
// callers/tests (which pass GBIF-shaped records) behave exactly as before.
const GBIF_COLUMNS = { scientificName: 5, scientificNameAuthorship: 6, canonicalName: 7 };

// Resolve column indices from a DwCA Taxon header row by Darwin Core term, tolerating
// term prefixes/URIs (e.g. "dwc:scientificName", ".../scientificName", "col:notho").
// COL XR has scientificName/scientificNameAuthorship but NO canonicalName (-> -1).
function columnsFromHeader(header) {
  const idx = (name) => header.findIndex(h =>
    String(h).split(/[\/:#]/).pop().toLowerCase() === name.toLowerCase());
  return {
    scientificName: idx('scientificName'),
    scientificNameAuthorship: idx('scientificNameAuthorship'),
    canonicalName: idx('canonicalName'),
  };
}

function taxonTransform(record, stats = { authorWithQuote: 0, scientifiNameWithUnderscore: 0, splitted: 0, total: 0 }, cols = GBIF_COLUMNS) {
  const sci = cols.scientificName;
  const auth = cols.scientificNameAuthorship;
  const canon = cols.canonicalName;
  const hasCanonicalColumn = canon !== undefined && canon !== -1;
  const origRecord = [...record];
  stats.total++;

  if (hasCanonicalColumn) {
    // ---- GBIF backbone mode ----
    // scientificName bundles the authorship; strip it using canonicalName as the anchor.
    const hasAuthor = record[auth].length > 0;
    const hasCanonicalName = record[canon].length > 0;
    if (hasAuthor) {
      if (hasCanonicalName) {
        // Try to remove the author from scientificName
        if (record[sci].endsWith(" " + record[auth])) {
          // name[space]author
          record[sci] = record[sci].replace(new RegExp(" " + escapeRegex(record[auth]) + '$'), '');
          stats.splitted++;
        } else if (record[sci].endsWith("_" + record[auth])) {
          // name_author
          record[sci] = record[sci].replace(new RegExp("_" + escapeRegex(record[auth]) + '$'), '');
          stats.scientifiNameWithUnderscore++;
          stats.splitted++;
        } else if (record[sci].startsWith(record[canon] + ", ")) {
          // 'name, author'
          record[auth] = record[sci].replace(record[canon] + ", ", "");
          record[sci] = record[canon];
          stats.authorWithQuote++;
          stats.splitted++;
          stringifier.write(origRecord.concat([ "AUTHOR_STARS_WITH_QUOTE" ]));
        } else if (record[sci].endsWith(" " + record[auth].replace(/ , /, ", "))) {
          // name[space],[space]author
          record[sci] = record[sci].replace(new RegExp(" " + escapeRegex(record[auth].replace(/ , /, ", ")) + '$'), '');
          record[auth] = record[auth].replace(/ , /, ", ");
          stats.splitted++;
        } else if (record[sci].startsWith(record[canon])) {
          // Let's try to use cannonical name (this will not work for subsp., var., f., nothosubsp. y nothovar.)
          record[sci] = record[canon];
          // stats??
        }
      } else {
        // no canonicalName so we try to remove author from sciName if it's there
        stringifier.write(origRecord.concat([ "NO_CANONICAL" ]));
      }
    }
  } else {
    // ---- Catalogue of Life (COL XR) mode ----
    // scientificName is already the canonical name (author-free) and scientificNameAuthorship
    // is a separate column, so no split is needed. Defensive only: if a source ever bundles
    // the trailing author into scientificName, strip it.
    if (record[auth] && record[auth].length > 0 && record[sci].endsWith(" " + record[auth])) {
      record[sci] = record[sci].replace(new RegExp(" " + escapeRegex(record[auth]) + '$'), '');
      stats.splitted++;
    }
  }

  if (record[sci].length === 0) {
    // And this is mandatory, see
    // https://github.com/AtlasOfLivingAustralia/documentation/wiki/Troubleshooting#null-has-been-blacklisted-error
    stringifier.write(origRecord.concat([ "WRONG_SCIENTIFIC_NAME" ]));
    process.exit(1);
  }
  return record;
}

module.exports = { taxonTransform, columnsFromHeader, GBIF_COLUMNS, parser, stringifier };
