# openjdk:* Docker Hub images were deprecated and removed; Eclipse Temurin is the
# standard successor (same Debian/Ubuntu apt base, Java 11 JRE for the ALA indexer).
FROM eclipse-temurin:11-jre

RUN apt-get update && apt-get install -y wget zip unzip curl bash procps gnu-coreutils

# Ubuntu 26.04 (the Temurin base) ships uutils coreutils; its `sort` 0.8.0 DEADLOCKS on the
# huge external sort the ALA indexer runs (`sed 1d Taxon.tsv | sort`, ~2.4 GB) and ignores
# TMPDIR (spilling temp to /tmp on the small root fs — which filled the disk). Point plain
# `sort` at GNU sort (installed by gnu-coreutils as `gnusort`) via /usr/local/bin, which
# precedes /usr/bin in PATH. GNU sort honors TMPDIR, so the temp lands on the big volume.
RUN ln -sf /usr/bin/gnusort /usr/local/bin/sort && sort --version | head -1

ARG URL_IRMNG=https://www.irmng.org/export/IRMNG_genera_DwCA.zip
ARG URL_NAMESDIST=https://nexus.ala.org.au/repository/releases/au/org/ala/ala-name-matching-distribution/4.3/ala-name-matching-distribution-4.3-distribution.zip
ARG URL_NAMESDIST_LEGACY=https://nexus.ala.org.au/repository/releases/au/org/ala/ala-name-matching/3.5/ala-name-matching-3.5-distribution.zip
# Source taxonomy: Catalogue of Life eXtended Release (COL XR), the replacement for the
# frozen GBIF backbone. The active download lives in the `gbif-taxonomy-for-la` script
# (SRC_TAXONOMY_URL); this ARG documents the default and is overridable at build time.
ARG URL_SRC_TAXONOMY=https://download.checklistbank.org/col/xr_latest_dwca.zip

# install NodeJS + npm. The Ubuntu-based Temurin image ships them in its own repos and
# packages npm separately from nodejs (the old NodeSource setup pulled the distro nodejs
# without npm -> "npm: not found"). Node 22 from the base runs the transform fine.
RUN apt-get update -yq \
    && apt-get install -yq nodejs npm \
    && node --version && npm --version

RUN npm install -g mocha

RUN wget -O /usr/local/bin/docopts  https://github.com/docopt/docopts/releases/download/v0.6.4-with-no-mangle-double-dash/docopts_linux_amd64 \
    && chmod +x /usr/local/bin/docopts

WORKDIR /usr/lib/nameindexer

RUN mkdir -p /data/lucene/sources/IRMNG_DWC_HOMONYMS \
    && wget "$URL_IRMNG" -O /data/lucene/sources/IRMNG_DWC_HOMONYMS.zip \
    && unzip -u /data/lucene/sources/IRMNG_DWC_HOMONYMS.zip -d /data/lucene/sources/IRMNG_DWC_HOMONYMS \
    && rm /data/lucene/sources/IRMNG_DWC_HOMONYMS.zip

# Legacy nameindexer
RUN mkdir -p /usr/lib/nameindexer \
    && wget "$URL_NAMESDIST_LEGACY" -O /usr/lib/nameindexer/ala-name-matching-distribution.zip \
    && unzip -u /usr/lib/nameindexer/ala-name-matching-distribution.zip -d /usr/lib/nameindexer \
    && rm /usr/lib/nameindexer/ala-name-matching-distribution.zip
COPY log4j.xml /usr/lib/nameindexer/log4j.xml
COPY nameindexer.sh /usr/lib/nameindexer/nameindexer
RUN mv /usr/lib/nameindexer/ala-name-matching-3.5.jar /usr/lib/nameindexer/nameindexer.jar \
    && cat /usr/lib/nameindexer/nameindexer.jar >> /usr/lib/nameindexer/nameindexer \
    && chmod +x /usr/lib/nameindexer/nameindexer \
    && ln -s /usr/lib/nameindexer/nameindexer /usr/bin/nameindexer

#RUN mkdir -p /data/lucene/sources/backbone \
#    && wget "$URL_GBIF_BACKBONE" -O /data/lucene/sources/backbone.zip

# Sometimes the unzip fails, so let do this after the wget
#RUN unzip -u /data/lucene/sources/backbone.zip -d /data/lucene/sources/backbone \
#     && rm /data/lucene/sources/backbone.zip

#RUN mv "/data/lucene/sources/backbone/Taxon.tsv" "/data/lucene/sources/backbone/Taxon.tsv.orig"

RUN mkdir -p /data/lucene/target

COPY package*.json ./
RUN npm install

# Namematching-service using for tests
RUN mkdir -p /data/lucene
RUN mkdir -p /data/ala-namematching-service/config
COPY ./subgroups.json /data/ala-namematching-service/config/subgroups.json
COPY ./groups.json /data/ala-namematching-service/config/groups.json
# The namematching-server jar is fetched and cached at run time by the `--tests` step in
# gbif-taxonomy-for-la (into $T/cache on the persistent volume) so image builds don't hit
# the ALA Nexus on every rebuild. See the `if ($tests)` block there.
COPY ./config.yml /data/config.yml

#COPY col_vernacular.txt.patch
COPY main.js taxonTransform.js gbif-taxonomy-for-la ./
COPY test test
# scripts/ holds check-transform.js (run by the --tests step) and the regression helpers.
COPY scripts scripts

VOLUME /data/lucene/target

RUN chmod +x gbif-taxonomy-for-la

ENTRYPOINT ["./gbif-taxonomy-for-la"]
