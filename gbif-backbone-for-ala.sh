#!/bin/bash

T=./target
B=$T/backbone
DATE=`date +%Y-%m-%d_%H-%M`

CMD=$(basename $0)
FIND_DOCOPTS=$(which docopts)

# Logs to console and file
# https://stackoverflow.com/questions/18460186/writing-outputs-to-log-file-and-console
LOG_FILE=`basename $CMD .sh`-$DATE.log
LOG_FILE_LINK=`basename $CMD .sh`.log
exec > >(tee ${LOG_FILE}) 2>&1
ln -sf $LOG_FILE $LOG_FILE_LINK

if [[ -z $FIND_DOCOPTS ]]
then
  echo "ERROR: Please install docopts https://github.com/docopt/docopts an copy it in your PATH"
  exit 1
fi

eval "$(docopts -V - -h - : "$@" <<EOF
Usage: $CMD [options] <release-date>

Options:
      --backbone                    Download GBIF backbone
      --name-authors                Split name and authors from the GBIF backbone
      --namematching-distri=<nmv>   Download ALA namematching-distribution version [default: 4.2].
      --namematching-index          Generate namematching index
      --namematching-index-legacy   Generate namematching index legacy (pre namemaching-service)
      --help                        Show help options.
      --version                     Print program version.
----
$CMD 0.0.1
Copyright (C) 2022 vjrj
License MIT
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
EOF
)"

if [[ ! -d "$T" ]]
then
  mkdir "$T"
fi

if ($backbone)
then
  wget -O $T/backbone.zip https://hosted-datasets.gbif.org/datasets/backbone/current/backbone.zip
  if [[ -d "$B" ]]
  then
    mv $T/backbone $T/backbone-pre-$DATE
  fi
  (cd $T; unzip -q backbone.zip)
  rm "$T/backbone.zip"
fi

if ($name_authors)
then
  if [[ ! -f "$B/Taxon.tsv.orig" ]]; then
    echo "Taxon.tsv.orig doesn't exist. Creating it"
    mv "$B/Taxon.tsv" "$B/Taxon.tsv.orig"
  fi

  if [[ ! -f "$B/Taxon-tests.tsv" ]]
  then
    head -100000 "$B/Taxon.tsv.orig" > "$B/Taxon-tests.tsv"
  fi

  echo "Trying to install node deps"
  npm install

  echo "Spliting scientificName and scientificNameAuthorship"
  node main.js > "$B/Taxon.tsv"
fi

# https://github.com/AtlasOfLivingAustralia/ala-name-matching
if [[ ! -d "$T/ala-name-matching-distri-$namematching_distri" ]]
then
  mkdir $T/ala-name-matching-distri-$namematching_distri
  wget -O $T/ala-name-matching-distri-$namematching_distri/ala-name-matching-distribution-$namematching_distri-distribution.zip https://nexus.ala.org.au/service/local/repositories/releases/content/au/org/ala/ala-name-matching-distribution/$namematching_distri/ala-name-matching-distribution-$namematching_distri-distribution.zip
  (cd $T/ala-name-matching-distri-$namematching_distri/; unzip -q ala-name-matching-distribution-$namematching_distri-distribution.zip)
fi

# Fix for: https://github.com/gbif/portal-feedback/issues/3781
egrep -v '^2925549	\\.*The Woody Plants of Korea' $B/VernacularName.tsv > $B/VernacularName.tsv.fixed
mv $B/VernacularName.tsv.fixed  $B/VernacularName.tsv

if ($namematching_index_legacy)
then
  NTLO=$T/namematching-gbif-backbone-lucene-6-$release_date
  NTL=$T/nameindex-gbif-backbone-lucene-6-$release_date.tgz

  if [[ -d "$NTLO" ]]; then
    rm -rf "$NTLO"
  fi

  if [[ -f "$NTL" ]]; then
    rm "$NTL"
  fi

  java -Dlog4j.configuration=file:/usr/lib/nameindexer/log4j.xml -Dfile.encoding=UTF8 -Djava.util.Arrays.useLegacyMergeSort=true -Xmx8g -Xms1g \
    -jar /usr/lib/nameindexer/nameindexer.*jar -all --dwca $B --irmng /data/lucene/sources/IRMNG_DWC_HOMONYMS --common $B/VernacularName.tsv

  mv namematching $NTLO
  tar cfz $NTL $NTLO
  echo "Generated $NTL"
fi

if ($namematching_index)
then
  export JAVA_OPTIONS="-Xmx3g -Xms3g"

  if [[ ! -d "$T/ala-name-matching-distri-$namematching_distri" ]]
  then
    echo "Use --namematching-distri=4.2 or similar before this"
    exit 1
  fi

  NTO=$T/namematching-gbif-backbone-lucene-8-$release_date/
  NT=$T/nameindex-gbif-backbone-lucene-8-$release_date.tgz

  if [[ -d "$NTO" ]]; then
    rm -rf "$NTO"
  fi

  if [[ -f "$NT" ]]; then
    rm "$NT"
  fi

  (cd $T/ala-name-matching-distri-$namematching_distri/; chmod +x ./index.sh ; ./index.sh --all --dwca ../../$B --target ../../$NTO --irmng /data/lucene/sources/IRMNG_DWC_HOMONYMS/ --common ../../$B/VernacularName.tsv)

  tar cfz $NT $NTO
  echo "Generated $NT"
fi

if [[ -f "$T/gbif-backbone-$release_date.zip" ]]
then
  rm $T/gbif-backbone-$release_date.zip
  (cd $T/; zip gbif-backbone-$release_date.zip backbone/* --exclude Taxon.tsv.orig Taxon-tests.tsv issues.tsv)
fi