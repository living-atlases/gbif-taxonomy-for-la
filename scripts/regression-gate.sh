#!/bin/bash
# Regression gate entry point, run on the Jenkins agent by the "Regression gate" stage
# (see Jenkinsfile: gated on RUN_REGRESSION && fileExists('scripts/regression-gate.sh')).
#
# Runs the golden-set regression check INSIDE the container against the index built by the
# "Build indexes + DwCA" stage: it starts the ALA namematching server and queries a curated
# set of names (scripts/regression-check.js), failing the build on any regression.
#
# The golden set (test/golden/regression-names.tsv) is curated; bootstrap/expand it from a
# real build with:  ./gbif-taxonomy-for-la-docker --regression <release>  after adding
# `--record`-captured rows (see scripts/regression-check.js).
set -e

RELEASE="${1:?usage: regression-gate.sh <release-suffix>}"
cd "$(dirname "$0")/.."

exec ./gbif-taxonomy-for-la-docker --regression "$RELEASE"
