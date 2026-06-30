#!/bin/bash
#
# inspect-col-schema.sh — Step-1 spike, operationalized.
#
# Extracts ONLY the schema bits we need from a (large) taxonomy DwCA so we can map the
# Catalogue of Life (COL XR) columns before touching the transform code:
#   - meta.xml             → the DwC term → column-index mapping (core + extensions)
#   - core file header/rows → confirm whether scientificName already excludes authorship
#
# It does NOT build any Lucene index, so it is far lighter than a full run — but the COL XR
# archive is ~750 MB, so run this on a CI agent (or a box with bandwidth), not casually on a
# laptop. Output: a human summary + target/col-schema.json (term→index) for the transform.
#
# Usage:
#   scripts/inspect-col-schema.sh [DWCA_URL]
# Default URL = the stable COL XR "latest" DwCA (GBIF dataset 7ddf754f-… DWC_ARCHIVE endpoint).

set -euo pipefail

URL="${1:-https://download.checklistbank.org/col/xr_latest_dwca.zip}"
OUT_DIR="${OUT_DIR:-target}"
WORK="$(mktemp -d)"
ZIP="$WORK/dwca.zip"
META="$WORK/meta.xml"

mkdir -p "$OUT_DIR"
echo ">> Source: $URL"
echo ">> Downloading archive (schema inspection only; no index build) ..."
curl -fSL --retry 3 "$URL" -o "$ZIP"
echo ">> Downloaded $(du -h "$ZIP" | cut -f1)"

# meta.xml is small; pull just it from the complete archive.
unzip -o "$ZIP" meta.xml -d "$WORK" >/dev/null
echo
echo "=== meta.xml: core + extensions, term → column index ==="

# Emit one "<rowType>\t<index>\t<shortTerm>" line per declared field, and a JSON map.
python3 - "$META" "$OUT_DIR/col-schema.json" <<'PY'
import sys, re, json, xml.etree.ElementTree as ET

meta_path, json_path = sys.argv[1], sys.argv[2]
# Darwin Core meta.xml is namespaced; strip namespaces for simple access.
xml = open(meta_path, encoding="utf-8").read()
xml = re.sub(r'\sxmlns(:\w+)?="[^"]+"', '', xml)
xml = re.sub(r'<(/?)\w+:', r'<\1', xml)
root = ET.fromstring(xml)

def short(term):
    return re.split(r'[/:#]', term.rstrip('/'))[-1]

schema = {}
for block in root.iter():
    if block.tag not in ("core", "extension"):
        continue
    row_type = short(block.get("rowType", "")) or block.tag
    files = block.find("files")
    location = files.find("location").text if files is not None and files.find("location") is not None else "?"
    cols = {}
    # id column
    idel = block.find("id")
    if idel is not None and idel.get("index") is not None:
        cols["_id"] = int(idel.get("index"))
    for f in block.findall("field"):
        if f.get("index") is not None:
            cols[short(f.get("term", ""))] = int(f.get("index"))
    schema[row_type] = {"file": location, "columns": cols}
    print(f"\n# {block.tag.upper()} rowType={row_type} file={location}")
    for name, idx in sorted(cols.items(), key=lambda kv: kv[1]):
        print(f"  {idx:>3}  {name}")

json.dump(schema, open(json_path, "w"), indent=2)
print(f"\n>> wrote {json_path}")

core = schema.get("Taxon") or next(iter(schema.values()), {})
c = core.get("columns", {})
for need in ("scientificName", "scientificNameAuthorship", "canonicalName", "taxonID",
             "taxonomicStatus", "acceptedNameUsageID", "parentNameUsageID", "taxonRank"):
    print(f"   {'OK ' if need in c else 'MISSING'} {need}" + (f" -> col {c[need]}" if need in c else ""))
PY

# Show a few real core rows so we can SEE whether scientificName carries authorship.
CORE_FILE="$(python3 -c "import json,sys; s=json.load(open('$OUT_DIR/col-schema.json')); core=s.get('Taxon') or list(s.values())[0]; print(core['file'])" 2>/dev/null || echo Taxon.tsv)"
echo
echo "=== first 5 rows of core file ($CORE_FILE) ==="
unzip -p "$ZIP" "$CORE_FILE" | head -5 || echo "(could not read core file $CORE_FILE)"

rm -rf "$WORK"
echo
echo ">> Done. Use target/col-schema.json to drive the schema-aware transform (Step 3)."
