// Jenkinsfile — build the LA name-matching taxonomy index on CI, NOT on a laptop.
//
// The full build is heavy: it downloads a large taxonomy DwCA (the GBIF backbone today,
// the Catalogue of Life eXtended Release / COL XR after the migration) and builds multi-GB
// Lucene indexes with the ALA name-matching indexer. Run it on a Jenkins agent with enough
// RAM and disk; keep the laptop for `--prepare-tests`/`--tests` on subsets.
//
// The taxonomy SOURCE (GBIF backbone vs COL XR) is selected inside the Dockerfile/script,
// so this pipeline only passes the release suffix and the usual flags.
//
// Target CI: the Living Atlases community Jenkins (jenkins.gbif.es), alongside
// `la-docker-images` and the `*-deb-*` jobs.

pipeline {

  // A node with Docker + ≥8–12 GB RAM + plenty of disk. Override the label to match the
  // agent you provision (e.g. a dedicated 'taxonomy' / 'big' node).
  agent { label params.AGENT_LABEL }

  options {
    disableConcurrentBuilds()                       // the docker wrapper uses a fixed container name
    timestamps()
    timeout(time: 6, unit: 'HOURS')
    buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '3'))  // cap disk on the agent
  }

  parameters {
    string(name: 'AGENT_LABEL',   defaultValue: '',
           description: 'Jenkins agent label. Empty = any agent (fine for the schema spike). For the heavy index build set a node with Docker, ≥8–12 GB RAM, large disk.')
    booleanParam(name: 'INSPECT_SCHEMA', defaultValue: true,
           description: 'Run the Step-1 spike only: extract COL DwCA meta.xml + sample rows (no index build), then stop. Defaults true during migration so the first SCM build is safe/light; set false for a real index build.')
    string(name: 'RELEASE',       defaultValue: '',
           description: 'Release suffix used in artifact names, e.g. 2026-06-30 or 2026-06-30-sv. Leave empty to use BUILD_TIMESTAMP.')
    string(name: 'NM_DISTRI',     defaultValue: '4.3',
           description: 'ala-name-matching-distribution version')
    string(name: 'FILTER_LANG',   defaultValue: '',
           description: 'Comma-separated vernacular language filter, e.g. en,sv (empty = keep all)')
    booleanParam(name: 'LEGACY_INDEX', defaultValue: true,
           description: 'Also build the legacy Lucene 6 index')
    booleanParam(name: 'BUILD_DWCA',   defaultValue: true,
           description: 'Regenerate the modified DwCA for the BIE indexer')
    booleanParam(name: 'RUN_REGRESSION', defaultValue: true,
           description: 'Run the baseline-vs-new regression gate (fails the build on unexplained regressions)')
    booleanParam(name: 'PUBLISH',      defaultValue: false,
           description: 'Publish the index .tgz artifacts to the LA download location')
  }

  environment {
    // Resolve a release suffix once, so every stage uses the same value.
    RELEASE_SUFFIX = "${params.RELEASE?.trim() ? params.RELEASE.trim() : BUILD_TIMESTAMP}"
    FILTER_ARG     = "${params.FILTER_LANG?.trim() ? '--filter_lang=' + params.FILTER_LANG.trim() : ''}"
  }

  stages {

    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Inspect COL schema (spike)') {
      // Step 1: confirm the COL DwCA column layout (meta.xml + sample rows) without an index
      // build. When INSPECT_SCHEMA is on, this is the whole job — archive the schema and stop.
      when { expression { return params.INSPECT_SCHEMA } }
      steps {
        sh 'bash scripts/inspect-col-schema.sh'
        archiveArtifacts artifacts: 'target/col-schema.json', allowEmptyArchive: true
      }
    }

    stage('Build image') {
      when { expression { return !params.INSPECT_SCHEMA } }
      steps {
        sh 'docker build . --tag gbif-taxonomy-for-la'
      }
    }

    stage('Download taxonomy + split names') {
      // Downloads the source DwCA (COL XR after migration) and splits
      // scientificName / scientificNameAuthorship. Heavy download.
      when { expression { return !params.INSPECT_SCHEMA } }
      steps {
        sh """
          ./gbif-taxonomy-for-la-docker --backbone ${FILTER_ARG} --name-authors ${RELEASE_SUFFIX}
        """
      }
    }

    stage('Build indexes + DwCA') {
      // The multi-GB Lucene index build. Memory is bounded by the script's JAVA_OPTIONS (-Xmx).
      when { expression { return !params.INSPECT_SCHEMA } }
      steps {
        script {
          def flags = ['--namematching-index']
          if (params.LEGACY_INDEX) { flags << '--namematching-index-legacy' }
          if (params.BUILD_DWCA)   { flags << '--dwca' }
          sh "./gbif-taxonomy-for-la-docker --namematching-distri=${params.NM_DISTRI} ${flags.join(' ')} ${RELEASE_SUFFIX}"
        }
      }
    }

    stage('Legacy → COL id mapping') {
      // Step 5: emit the GBIF-integer-taxonKey → COL-id mapping sidecar so historical
      // LA taxonConceptIDs still resolve. TODO: wire to the mapping-download step once added.
      when { expression { return fileExists('scripts/emit-legacy-mapping.sh') } }
      steps {
        sh 'bash scripts/emit-legacy-mapping.sh "$RELEASE_SUFFIX"'
      }
    }

    stage('Regression gate') {
      // Step 7: replay the Step-0 corpus through the new index and diff against the
      // committed baseline (compare on resolved name/rank/classification, NOT raw id).
      // Non-fatal until the harness lands, then it should fail the build on regressions.
      when { expression { return params.RUN_REGRESSION && fileExists('scripts/regression-gate.sh') } }
      steps {
        sh 'bash scripts/regression-gate.sh "$RELEASE_SUFFIX"'
      }
    }
  }

  post {
    always {
      // Capture everything useful for review even on failure.
      archiveArtifacts artifacts: 'target/*.tgz, target/*.zip, target/**/issues.tsv, target/*mapping*.tsv, target/**/regression-report.*',
                       allowEmptyArchive: true, fingerprint: true
    }
    success {
      script {
        if (params.PUBLISH) {
          // TODO: upload target/*.tgz to the LA download host that la-toolkit / ansible
          // inventories pull the namematching index from.
          echo 'PUBLISH requested — wire upload of target/*.tgz to the LA download location.'
        }
      }
    }
    cleanup {
      // Free the agent's disk between runs (artifacts are already archived above).
      sh 'rm -rf target/backbone target/tmp || true'
    }
  }
}
