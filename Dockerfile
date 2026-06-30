FROM openjdk:11-jre-slim

RUN apt-get update && apt-get install -y wget zip unzip curl bash procps

ARG NODE_VERSION=18
ARG URL_IRMNG=https://www.irmng.org/export/IRMNG_genera_DwCA.zip
ARG URL_NAMESDIST=https://nexus.ala.org.au/service/local/repositories/releases/content/au/org/ala/ala-name-matching-distribution/4.3/ala-name-matching-distribution-4.3-distribution.zip
ARG URL_NAMESDIST_LEGACY=https://nexus.ala.org.au/repository/releases/au/org/ala/ala-name-matching/3.5/ala-name-matching-3.5-distribution.zip
# Source taxonomy: Catalogue of Life eXtended Release (COL XR), the replacement for the
# frozen GBIF backbone. The active download lives in the `gbif-taxonomy-for-la` script
# (SRC_TAXONOMY_URL); this ARG documents the default and is overridable at build time.
ARG URL_SRC_TAXONOMY=https://download.checklistbank.org/col/xr_latest_dwca.zip

# install NodeJS
RUN apt-get update -yq \
    && apt-get install -yq ca-certificates curl gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_VERSION.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update -yq \
    && apt-get install nodejs -yq \
    && npm install -g npm

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
RUN wget https://nexus.ala.org.au/repository/releases/au/org/ala/names/ala-namematching-server/1.8.1/ala-namematching-server-1.8.1.jar -O /data/ala-namematching-server.jar
COPY ./config.yml /data/config.yml

#COPY col_vernacular.txt.patch
COPY main.js taxonTransform.js gbif-taxonomy-for-la ./
COPY test test

VOLUME /data/lucene/target

RUN chmod +x gbif-taxonomy-for-la

ENTRYPOINT ["./gbif-taxonomy-for-la"]
