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

// --- PROFILE helpers -------------------------------------------------------
// The Spain (gbif-es) index is the SAME pipeline parameterised: filter vernaculars to
// es,eu,ca,gl and suffix the release with `-es` (the build names artifacts after the
// release string, so `-es` is all it takes). PROFILE=es fills those in so you don't have
// to remember the recipe; explicit RELEASE/FILTER_LANG still win.
def resolveRelease() {
  def base = params.RELEASE?.trim() ?: ('build-' + env.BUILD_NUMBER)
  if (params.PROFILE == 'es' && !base.endsWith('-es')) { base += '-es' }
  return base
}
def resolveLang() {
  def lang = params.FILTER_LANG?.trim()
  if (!lang && params.PROFILE == 'es') { lang = 'es,eu,ca,gl' }
  return lang
}

pipeline {

  // A node with Docker + ≥8–12 GB RAM + plenty of disk. Override the label to match the
  // agent you provision (e.g. a dedicated 'taxonomy' / 'big' node).
  agent { label params.AGENT_LABEL }

  options {
    disableConcurrentBuilds()                       // the docker wrapper uses a fixed container name
    timestamps()
    // No pipeline timeout: a full (non-TEST_MODE) build indexes all of COL and legitimately
    // runs many hours — normally overnight. The previous 6h cap aborted build #18 mid-index.
    buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '3'))  // cap disk on the agent
  }

  parameters {
    string(name: 'AGENT_LABEL',   defaultValue: '',
           description: 'Jenkins agent label. Empty = any agent (fine for the schema spike). For the heavy index build set a node with Docker, ≥8–12 GB RAM, large disk.')
    booleanParam(name: 'INSPECT_SCHEMA', defaultValue: true,
           description: 'Run the Step-1 spike only: extract COL DwCA meta.xml + sample rows (no index build), then stop. Defaults true during migration so the first SCM build is safe/light; set false for a real index build.')
    booleanParam(name: 'TEST_MODE', defaultValue: false,
           description: 'Fast dev loop: build the index from a ~10k-taxon SUBSET (+ tested species) and run the mocha tests. Skips the full download/index. Minutes, not the full run.')
    choice(name: 'PROFILE', choices: ['generic', 'es'],
           description: 'generic = backbone with all vernaculars. es = gbif-es index: forces FILTER_LANG=es,eu,ca,gl (if empty) and appends -es to RELEASE (if missing).')
    string(name: 'RELEASE',       defaultValue: '',
           description: 'Release suffix used in artifact names, e.g. 2026-06-30 or 2026-06-30-sv. Leave empty to use BUILD_TIMESTAMP. With PROFILE=es a -es suffix is added automatically.')
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
           description: 'Publish the index .tgz/.zip to the LA download host(s) via rsync/ssh (see scripts/publish.sh)')
    // --- Publish target (only used when PUBLISH=true) ---
    string(name: 'PUBLISH_SSH_CRED',      defaultValue: 'datos-gbif-es',
           description: 'Jenkins SSH credential id (SSH Username with private key; SSH Credentials plugin, no ssh-agent). Empty = use the jenkins user's own ~/.ssh identity.')
    string(name: 'PUBLISH_HOST',          defaultValue: 'datos.gbif.es',
           description: 'Publish host')
    string(name: 'PUBLISH_USER',          defaultValue: 'ubuntu',
           description: 'SSH user on the publish host (must be able to write the docroots)')
    string(name: 'PUBLISH_OTHERS_PATH',   defaultValue: '/srv/auth.gbif.es/www/others',
           description: 'Server docroot served at /others (the .tgz land here). datos.gbif.es and demo.gbif.es are CNAMEs to this same vhost, so one publish serves both.')
    string(name: 'PUBLISH_NAMEDATA_PATH', defaultValue: '/srv/auth.gbif.es/www/namedata',
           description: 'Server docroot served at /namedata (the DwCA .zip lands here)')
    string(name: 'PUBLISH_URL_BASE',      defaultValue: 'https://datos.gbif.es',
           description: 'Base URL used to build the inventory snippet')
    booleanParam(name: 'PUBLISH_DEMO',    defaultValue: false,
           description: 'Extra mirror to a SEPARATE demo docroot. Off by default: datos + demo are CNAMEs to the same vhost (/srv/auth.gbif.es/www), so a single publish already serves both.')
    string(name: 'DEMO_HOST',             defaultValue: 'demo.gbif.es',
           description: 'Demo host (only used if PUBLISH_DEMO=true)')
    string(name: 'DEMO_OTHERS_PATH',      defaultValue: '',
           description: 'Demo docroot served at /others (empty = reuse PUBLISH_OTHERS_PATH)')
    string(name: 'DEMO_NAMEDATA_PATH',    defaultValue: '',
           description: 'Demo docroot served at /namedata (empty = reuse PUBLISH_NAMEDATA_PATH)')
  }

  environment {
    // Resolve a release suffix and the vernacular filter once (PROFILE-aware, see the
    // resolveRelease()/resolveLang() helpers), so every stage uses the same value.
    RELEASE_SUFFIX = "${resolveRelease()}"
    FILTER_ARG     = "${resolveLang() ? '--filter_lang=' + resolveLang() : ''}"
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

    stage('Fast test (subset)') {
      // Fast dev loop: download (cached) -> ~10k-taxon subset -> build a small index ->
      // run mocha. Two docker runs because the script runs its blocks top-to-bottom, and
      // the --tests block precedes --namematching-index (so the index must exist first).
      when { expression { return params.TEST_MODE && !params.INSPECT_SCHEMA } }
      steps {
        sh "./gbif-taxonomy-for-la-docker --backbone --prepare-tests --namematching-distri=${params.NM_DISTRI} --namematching-index ${env.RELEASE_SUFFIX}"
        sh "./gbif-taxonomy-for-la-docker --tests ${env.RELEASE_SUFFIX}"
      }
    }

    stage('Download taxonomy + split names') {
      // Downloads the source DwCA (COL XR after migration) and splits
      // scientificName / scientificNameAuthorship. Heavy download.
      when { expression { return !params.INSPECT_SCHEMA && !params.TEST_MODE } }
      steps {
        // Single-quoted: the shell expands $FILTER_ARG/$RELEASE_SUFFIX (declarative
        // environment{} vars are exported to sh). They are NOT Groovy bindings, so
        // double-quoted Groovy interpolation ${FILTER_ARG} would throw MissingProperty.
        sh './gbif-taxonomy-for-la-docker --backbone $FILTER_ARG --name-authors $RELEASE_SUFFIX'
      }
    }

    stage('Build indexes + DwCA') {
      // The multi-GB Lucene index build. Memory is bounded by the script's JAVA_OPTIONS (-Xmx).
      when { expression { return !params.INSPECT_SCHEMA && !params.TEST_MODE } }
      steps {
        script {
          def flags = ['--namematching-index']
          if (params.LEGACY_INDEX) { flags << '--namematching-index-legacy' }
          if (params.BUILD_DWCA)   { flags << '--dwca' }
          sh "./gbif-taxonomy-for-la-docker --namematching-distri=${params.NM_DISTRI} ${flags.join(' ')} ${env.RELEASE_SUFFIX}"
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

    stage('Publish') {
      // Ship the built .tgz/.zip to the LA download host(s): sha1 + rsync to /others and
      // /namedata, create the historical nameindex-* aliases (server-side symlinks), and
      // emit a paste-ready inventory snippet. A real stage (not post{}) so the sshagent is
      // in scope and an upload failure fails the build. See scripts/publish.sh.
      when { expression { return params.PUBLISH && !params.INSPECT_SCHEMA && !params.TEST_MODE } }
      environment {
        PUBLISH_HOST          = "${params.PUBLISH_HOST}"
        PUBLISH_USER          = "${params.PUBLISH_USER}"
        PUBLISH_OTHERS_PATH   = "${params.PUBLISH_OTHERS_PATH}"
        PUBLISH_NAMEDATA_PATH = "${params.PUBLISH_NAMEDATA_PATH}"
        PUBLISH_URL_BASE      = "${params.PUBLISH_URL_BASE}"
        PUBLISH_DEMO          = "${params.PUBLISH_DEMO}"
        DEMO_HOST             = "${params.DEMO_HOST}"
        DEMO_OTHERS_PATH      = "${params.DEMO_OTHERS_PATH}"
        DEMO_NAMEDATA_PATH    = "${params.DEMO_NAMEDATA_PATH}"
      }
      steps {
        // No ssh-agent plugin: bind the SSH private key to a file (SSH Credentials plugin)
        // and let publish.sh use `ssh -i $PUBLISH_SSH_KEY`. If PUBLISH_SSH_CRED is empty,
        // fall back to the jenkins user's own ~/.ssh identity.
        script {
          if (params.PUBLISH_SSH_CRED?.trim()) {
            withCredentials([sshUserPrivateKey(credentialsId: params.PUBLISH_SSH_CRED,
                                               keyFileVariable: 'PUBLISH_SSH_KEY')]) {
              sh 'bash scripts/publish.sh "$RELEASE_SUFFIX"'
            }
          } else {
            sh 'bash scripts/publish.sh "$RELEASE_SUFFIX"'
          }
        }
      }
    }
  }

  post {
    always {
      // Capture everything useful for review even on failure.
      // Archive the index build logs too (runs in `always`, before the `cleanup` rm below,
      // so they're captured even on abort/failure — the visibility we lacked on #18/#19).
      archiveArtifacts artifacts: 'target/*.tgz, target/*.zip, target/**/issues.tsv, target/*mapping*.tsv, target/**/regression-report.*, target/index-lucene8-*.log, target/index-lucene6-*.log, target/SHA1SUMS-*.txt, target/inventory-snippet-*.ini',
                       allowEmptyArchive: true, fingerprint: true
    }
    success {
      script {
        if (params.PUBLISH && !params.INSPECT_SCHEMA && !params.TEST_MODE) {
          echo "Published release ${env.RELEASE_SUFFIX}. Grab target/inventory-snippet-${env.RELEASE_SUFFIX}.ini and paste it into la-toolkit gbif-es-local-extras.ini."
        }
      }
    }
    cleanup {
      // The container writes target/* as root, so the Jenkins user can't delete them
      // (that produced thousands of "Permission denied" lines). Remove the multi-GB
      // unzipped dirs from inside a root container; KEEP target/cache (the ~750 MB source
      // archive) so the next build reuses it. Fallback to a plain rm if the image is absent.
      sh '''
        docker run --rm -v "$PWD/target:/data/lucene/target" --entrypoint bash gbif-taxonomy-for-la \
          -c 'rm -rf /data/lucene/target/backbone /data/lucene/target/backbone-pre-* /data/lucene/target/tmp /data/lucene/target/index-*.log' \
          2>/dev/null || rm -rf target/backbone target/backbone-pre-* target/tmp target/index-*.log 2>/dev/null || true
      '''
    }
  }
}
