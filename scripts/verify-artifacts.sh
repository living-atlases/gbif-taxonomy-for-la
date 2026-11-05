#!/bin/bash
# Structural validation of the build artifacts, run on the Jenkins agent HOST (like
# scripts/publish.sh, not inside the container) by the "Verify artifacts" stage, and again
# from publish.sh so nothing can be uploaded unverified.
#
# Why this exists: the pipeline could ship a .tgz whose *content* is wrong while every check
# we had stayed green. sha1 only proves the bytes arrived intact, and the regression gate
# queries a server that was started against the build directory, never against the packaged
# artifact. When gbif-es hit
#     java.io.FileNotFoundException: /data/lucene/namematching-nm/cb
# the first suspect was the tarball, and answering "no, the tarball is fine" took a day of
# poking at production. This answers it in seconds, and catches the failure this could have
# been: an indexer that writes an empty cb/, or a Lucene 6 payload under a lucene-8 name.
#
# Checks per index .tgz:
#   1. exactly one top-level directory, named after the artifact (no tar bombs, no stray roots)
#   2. no absolute or ../ members
#   3. every entry of the golden layout is present (test/golden/artifact-layout-lucene-*.txt),
#      extras are reported but allowed
#   4. every sub-index carries a segments_* file — that is what ALANameSearcher opens
#   5. cb/ is not a hollow index (MIN_CB_BYTES, set to 0 for TEST_MODE subset builds)
#   6. metadata.json (Lucene 8 only) parses and its luceneVersion matches the artifact name
# Plus, for the DwCA .zip: meta.xml + Taxon.tsv + VernacularName.tsv present, and — when
# FILTER_LANG is set — no vernacular language outside the filter survived.
#
# Usage:   scripts/verify-artifacts.sh <release-suffix>
# Env:     TARGET (default: target), MIN_CB_BYTES (default: 50000000), FILTER_LANG
set -euo pipefail

RELEASE="${1:?usage: verify-artifacts.sh <release-suffix>}"
cd "$(dirname "$0")/.."
TARGET="${TARGET:-target}"
GOLDEN_DIR="test/golden"
MIN_CB_BYTES="${MIN_CB_BYTES:-50000000}"
FILTER_LANG="${FILTER_LANG:-}"

errors=0
fail()  { echo "FAIL: $*" >&2; errors=$((errors + 1)); }
note()  { echo "note: $*"; }
ok()    { echo "  ok  $*"; }

# ---------------------------------------------------------------------------
# One index tarball: $1 = lucene major (6|8)
# ---------------------------------------------------------------------------
verify_index() {
  local major="$1"
  local base="namematching-gbif-backbone-lucene-${major}-${RELEASE}"
  local tgz="$TARGET/${base}.tgz"
  local golden="$GOLDEN_DIR/artifact-layout-lucene-${major}.txt"

  if [[ ! -f "$tgz" ]]; then
    note "$tgz not built, skipping"
    return 0
  fi
  echo "== $tgz"

  # One decompression pass for both names and sizes; a 1 GB archive takes ~20s.
  local listing
  listing="$(mktemp)"
  trap 'rm -f "$listing"' RETURN
  tar tzvf "$tgz" > "$listing"

  local names
  names="$(awk '{print $NF}' "$listing")"

  # 1. single root directory, named after the artifact
  local roots
  roots="$(printf '%s\n' "$names" | cut -d/ -f1 | sort -u)"
  if [[ "$(printf '%s\n' "$roots" | wc -l)" -ne 1 ]]; then
    fail "$tgz unpacks to more than one root: $(printf '%s ' $roots)"
    return 0
  fi
  if [[ "$roots" != "$base" ]]; then
    fail "$tgz root directory is '$roots', expected '$base'"
    return 0
  fi
  ok "single root directory $base/"

  # 2. nothing that would escape the extraction directory
  if printf '%s\n' "$names" | grep -qE '^/|(^|/)\.\./'; then
    fail "$tgz contains absolute or ../ members"
  else
    ok "no absolute or ../ members"
  fi

  # 3. golden layout is a subset of what we shipped
  local top expected missing extra
  top="$(printf '%s\n' "$names" \
        | sed -n "s|^${base}/\([^/]*/\?\)$|\1|p" | sort -u)"
  expected="$(grep -vE '^\s*(#|$)' "$golden" | sort -u)"
  missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$top") || true)"
  extra="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$top") || true)"
  if [[ -n "$missing" ]]; then
    fail "$tgz is missing entries the known-good layout has: $(printf '%s ' $missing)"
  else
    ok "layout matches $golden"
  fi
  [[ -n "$extra" ]] && note "new entries not in $golden: $(printf '%s ' $extra)"

  # 4. every sub-index looks like a Lucene index
  local d
  while read -r d; do
    [[ -z "$d" ]] && continue
    if printf '%s\n' "$names" | grep -q "^${base}/${d}segments_"; then
      ok "${d} has a segments file"
    else
      fail "$tgz: ${base}/${d} has no segments_* file — the name-matching service will die with \"Unable to initialise searcher: .../${d%/}\""
    fi
  done < <(printf '%s\n' "$expected" | grep '/$' || true)

  # 5. cb/ must hold a real index, not an empty shell
  local cb_bytes
  cb_bytes="$(awk -v p="${base}/cb/" '$NF ~ "^"p {s += $3} END {print s + 0}' "$listing")"
  if [[ "$cb_bytes" -lt "$MIN_CB_BYTES" ]]; then
    fail "$tgz: cb/ is only ${cb_bytes} bytes (minimum ${MIN_CB_BYTES}); the index is probably empty"
  else
    ok "cb/ holds ${cb_bytes} bytes"
  fi

  # 6. the packaged index must be the Lucene version its name claims
  if printf '%s\n' "$names" | grep -qx "${base}/metadata.json"; then
    local meta
    meta="$(tar xzOf "$tgz" --occurrence=1 "${base}/metadata.json")"
    if ! printf '%s' "$meta" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      fail "$tgz: metadata.json is not valid JSON"
    else
      local lv
      lv="$(printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("luceneVersion",""))')"
      if [[ "$lv" == "$major".* ]]; then
        ok "metadata.json reports Lucene $lv"
      else
        fail "$tgz claims Lucene $major in its name but metadata.json reports '${lv:-none}'"
      fi
    fi
  else
    note "no metadata.json in this index (expected for the Lucene 6 build)"
  fi
}

# ---------------------------------------------------------------------------
# The DwCA consumed by the BIE indexer
# ---------------------------------------------------------------------------
verify_dwca() {
  local zip="$TARGET/gbif-backbone-${RELEASE}.zip"
  if [[ ! -f "$zip" ]]; then
    note "$zip not built, skipping"
    return 0
  fi
  echo "== $zip"

  local members f
  members="$(unzip -Z1 "$zip")"
  for f in meta.xml Taxon.tsv VernacularName.tsv; do
    if printf '%s\n' "$members" | grep -qx "$f"; then
      ok "$f present"
    else
      fail "$zip is missing $f"
    fi
  done

  # The -es profile exists to drop vernaculars outside es,eu,ca,gl. Nothing checked that the
  # filter actually bit, so a silently unfiltered build would publish under an -es name.
  if [[ -n "$FILTER_LANG" ]] && printf '%s\n' "$members" | grep -qx VernacularName.tsv; then
    local header col
    header="$(unzip -p "$zip" VernacularName.tsv | head -1)"
    # COL XR prefixes the term (dwc:language); the backbone does not.
    col="$(printf '%s' "$header" | tr '\t' '\n' | grep -inxE '(dwc:)?language' | head -1 | cut -d: -f1)"
    if [[ -z "$col" ]]; then
      note "no language column in VernacularName.tsv, skipping the FILTER_LANG check"
    else
      local allowed unexpected
      allowed="$(bash scripts/lang-codes.sh "$FILTER_LANG" | sort -u)"
      unexpected="$(unzip -p "$zip" VernacularName.tsv | tail -n +2 | cut -f"$col" \
                    | tr '[:upper:]' '[:lower:]' | sort -u | grep -v '^$' \
                    | comm -23 - <(printf '%s\n' "$allowed") || true)"
      if [[ -n "$unexpected" ]]; then
        fail "$zip has vernacular languages outside FILTER_LANG=$FILTER_LANG: $(printf '%s ' $unexpected)"
      else
        ok "vernacular languages restricted to $FILTER_LANG"
      fi
    fi
  fi
}

verify_index 8
verify_index 6
verify_dwca

echo
if [[ "$errors" -gt 0 ]]; then
  echo "$errors artifact check(s) failed for release '$RELEASE'." >&2
  exit 1
fi
echo "All artifact checks passed for release '$RELEASE'."
