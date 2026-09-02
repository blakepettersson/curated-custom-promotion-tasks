#!/usr/bin/env bash
# shellcheck disable=SC2034  # this is a library: its variables are read by the .bats files that load it
# Helpers for the oci/ task suites, loaded by the .bats files.
#
# There is no step image here: these tasks are compositions of Kargo's built-in
# steps, so there is nothing to `docker run`. The suites therefore split in two:
#
#   tasks.bats       checks each task against Kargo's own step config schemas
#                    (test/lint-task.py), and checks the stage examples against
#                    the tasks they call.
#   e2e-recipe.bats  runs the pipeline the tasks describe — render, archive,
#                    push, pull — against a real registry, so the media types
#                    and layout the tasks rely on are checked against something
#                    that actually reads them.
#
# Every assertion dumps what it saw on failure; bats only shows it for the case
# that failed, so there is no reason to be terse.

# Repository paths, resolved from the test directory so a suite can be run from
# anywhere.
OCI_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
TASKS_DIR="$OCI_DIR/tasks"
SCHEMAS_DIR="$BATS_TEST_DIRNAME/schemas"
FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"
EXAMPLE_APP="$OCI_DIR/examples/example-app"
LINTER="$BATS_TEST_DIRNAME/lint-task.py"

# The three layer media types Argo CD's repo-server accepts without an operator
# extending --oci-layer-media-types. A hydrate task that publishes anything else
# produces an artifact Argo CD will refuse to read.
ARGOCD_DEFAULT_LAYER_MEDIA_TYPES=(
  "application/vnd.oci.image.layer.v1.tar"
  "application/vnd.oci.image.layer.v1.tar+gzip"
  "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
)

# Set by lint_task, read by the assertions below.
STATUS=0
LINT=""

# yq and jq are only needed to read YAML and JSON on the host. Fall back to a
# container so the suite runs on a machine without them, as the kyverno suite
# does for jq.
yqq() {
  if command -v yq > /dev/null 2>&1; then
    yq "$@"
  else
    docker run --rm -i mikefarah/yq:4 "$@"
  fi
}

jqq() {
  if command -v jq > /dev/null 2>&1; then
    jq "$@"
  else
    docker run --rm -i --entrypoint jq ghcr.io/jqlang/jq:1.7.1 "$@"
  fi
}

# A writable scratch directory that exists in both a test and in setup_file,
# where BATS_TEST_TMPDIR is not yet set.
scratch() {
  printf '%s' "${BATS_TEST_TMPDIR:-$BATS_FILE_TMPDIR}"
}

require() { # tool...
  local missing=()
  for tool in "$@"; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'these checks need %s on PATH\n' "${missing[*]}" >&2
    return 1
  }
}

# ---------------------------------------------------------------- task linting

# Runs the linter over one or more task manifests. Converts YAML to JSON first:
# the linter is stdlib-only Python, so the suite needs no Python packages.
lint_task() { # task.yaml...
  local json=()
  local i=0
  for yaml in "$@"; do
    local out="$BATS_TEST_TMPDIR/task-$i.json"
    yqq -o=json "$yaml" > "$out"
    json+=("$out")
    i=$((i + 1))
  done
  # `&& STATUS=0 || STATUS=$?` keeps a non-zero exit — which the negative
  # controls expect — from tripping the `set -e` that bats runs tests under.
  LINT="$(python3 "$LINTER" "$SCHEMAS_DIR" "${json[@]}" 2>&1)" && STATUS=0 || STATUS=$?
}

diagnose() { # message
  printf 'assertion failed: %s\n' "$1"
  printf '  linter exit code: %s\n' "$STATUS"
  printf '  linter output:\n%s\n' "$(printf '%s\n' "${LINT:-<empty>}" | sed 's/^/    /')"
}

assert_lint_clean() {
  [ "$STATUS" = 0 ] && [ -z "$LINT" ] || {
    diagnose "expected the task to lint clean"
    return 1
  }
}

assert_lint_fails() {
  [ "$STATUS" != 0 ] || {
    diagnose "expected the linter to reject this task"
    return 1
  }
}

assert_lint_reports() { # substring
  printf '%s' "$LINT" | grep -qF -- "$1" || {
    diagnose "expected the linter to report \"$1\""
    return 1
  }
}

# ------------------------------------------------------------------- registry

# Where start_registry records what it started. A file rather than an exported
# variable: bats runs setup_file, each test and teardown_file in separate
# processes, and the file is the only channel all three reliably share.
REGISTRY_STATE="${BATS_FILE_TMPDIR:-${BATS_TEST_TMPDIR:-/tmp}}/registry"

# Starts a throwaway registry on an ephemeral port and waits for it to answer.
# Ephemeral so that a suite does not collide with a registry the developer is
# already running, or with a second copy of itself.
start_registry() {
  local container port i
  container="oci-tasks-test-$$"
  docker run -d --name "$container" -P registry:2 > /dev/null
  printf '%s\n' "$container" > "$REGISTRY_STATE.container"
  port="$(docker port "$container" 5000/tcp | head -1 | sed 's/.*://')"
  printf 'localhost:%s\n' "$port" > "$REGISTRY_STATE.endpoint"
  REGISTRY="localhost:$port"
  for i in $(seq 1 50); do
    if curl -fsS "http://$REGISTRY/v2/" > /dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  printf 'registry at %s never became ready\n' "$REGISTRY" >&2
  docker logs "$container" >&2 || true
  return 1
}

# Reads back the endpoint start_registry recorded. Called from setup, since a
# test cannot see variables set in setup_file unless they were exported.
use_registry() {
  [ -f "$REGISTRY_STATE.endpoint" ] || {
    printf 'no registry was started for this suite\n' >&2
    return 1
  }
  REGISTRY="$(cat "$REGISTRY_STATE.endpoint")"
}

stop_registry() {
  [ -f "$REGISTRY_STATE.container" ] || return 0
  docker rm -f "$(cat "$REGISTRY_STATE.container")" > /dev/null 2>&1 || true
  rm -f "$REGISTRY_STATE.container" "$REGISTRY_STATE.endpoint"
}

# Uploads a blob and prints its digest.
put_blob() { # repo file
  local repo="$1" file="$2" digest location
  digest="sha256:$(shasum -a 256 "$file" | cut -d' ' -f1)"
  location="$(
    curl -fsS -X POST -D - -o /dev/null "http://$REGISTRY/v2/$repo/blobs/uploads/" |
      tr -d '\r' | awk 'tolower($1)=="location:"{print $2}'
  )"
  case "$location" in
    http*) ;;
    *) location="http://$REGISTRY$location" ;;
  esac
  curl -fsS -X PUT -H 'Content-Type: application/octet-stream' \
    --data-binary "@$file" "$location&digest=$digest" -o /dev/null
  printf '%s' "$digest"
}

# Publishes a file as a single-layer OCI 1.1 artifact, building the manifest the
# way the `oci-push` step's srcPath mode does: the file's bytes as the sole
# layer, the OCI empty descriptor as the config, and artifactType on the
# manifest. See pkg/promotion/runner/builtin/oci_pusher.go in akuity/kargo.
#
# This is a replica, not the step itself — Kargo is not available here — so it
# proves the shape of artifact the tasks configure is one a registry accepts and
# a client can read back, not that Kargo's implementation agrees byte for byte.
push_artifact() { # repo tag file [layer-media-type] [artifact-type]
  local repo="$1" tag="$2" file="$3"
  local layer_type="${4:-application/vnd.oci.image.layer.v1.tar+gzip}"
  local artifact_type="${5:-application/vnd.unknown.artifact.v1}"

  local empty config_digest layer_digest manifest
  empty="$(scratch)/empty.json"
  printf '{}' > "$empty"
  config_digest="$(put_blob "$repo" "$empty")"
  layer_digest="$(put_blob "$repo" "$file")"
  manifest="$(scratch)/manifest-$tag.json"

  # shellcheck disable=SC2016  # the braces below are jq object syntax, not shell
  jqq -nc \
    --arg cd "$config_digest" --argjson cs "$(wc -c < "$empty")" \
    --arg ld "$layer_digest" --argjson ls "$(wc -c < "$file")" \
    --arg lt "$layer_type" --arg at "$artifact_type" \
    '{
       schemaVersion: 2,
       mediaType: "application/vnd.oci.image.manifest.v1+json",
       artifactType: $at,
       config: {
         mediaType: "application/vnd.oci.empty.v1+json",
         digest: $cd,
         size: $cs
       },
       layers: [{mediaType: $lt, digest: $ld, size: $ls}]
     }' > "$manifest"

  curl -fsS -X PUT \
    -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
    --data-binary "@$manifest" \
    "http://$REGISTRY/v2/$repo/manifests/$tag" -o /dev/null
}

# Prints the digest a tag resolves to, as a client following the tag would see
# it — the value Argo CD records as an OCI source's revision.
resolve_digest() { # repo tag
  curl -fsSI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://$REGISTRY/v2/$1/manifests/$2" |
    tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
}

fetch_manifest() { # repo tag
  curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://$REGISTRY/v2/$1/manifests/$2"
}

fetch_blob() { # repo digest out-file
  curl -fsSL "http://$REGISTRY/v2/$1/blobs/$2" -o "$3"
}

# ------------------------------------------------------------------ rendering

# Renders the example chart the way the `helm-template` step configured by
# hydrate-helm-to-oci does: a flat directory of manifests, CRDs included, with
# an optional per-stage values overlay that is skipped when absent
# (ignoreMissingValueFiles).
render_helm() { # stage out-dir
  local stage="$1" out="$2"
  local args=(-f "$EXAMPLE_APP/chart/values.yaml")
  [ -f "$EXAMPLE_APP/chart/values-$stage.yaml" ] &&
    args+=(-f "$EXAMPLE_APP/chart/values-$stage.yaml")
  local staging
  staging="$(scratch)/helm-staging-$stage"
  rm -rf "$staging" "$out"
  mkdir -p "$staging" "$out"
  helm template "example-app" "$EXAMPLE_APP/chart" \
    --namespace "example-app-$stage" \
    --include-crds \
    "${args[@]}" \
    --output-dir "$staging" > /dev/null
  # `helm template --output-dir` nests output under <chart>/templates; the step's
  # `outLayout: flat` writes the same manifests directly into outPath.
  find "$staging" -name '*.yaml' -exec cp {} "$out/" \;
}

# Renders the example overlay the way the `kustomize-build` step configured by
# hydrate-kustomize-to-oci does: one file per resource in an output directory.
render_kustomize() { # stage out-dir
  local stage="$1" out="$2"
  rm -rf "$out"
  mkdir -p "$out"
  kustomize build "$EXAMPLE_APP/overlays/$stage" -o "$out"
}

# Archives a rendered directory as the `tar` step with `gzip: true` does.
#
# The step names each entry relative to `inPath` and skips the root directory
# entry, so the archive unpacks to a flat root of manifests rather than to a
# `manifests/` directory. That is why the Argo CD Application's OCI source needs
# no `path`. A plain `tar -czf out manifests` would prefix every entry, so build
# the entry list explicitly instead.
archive() { # in-dir out-file
  local list
  list="$(scratch)/tar-entries-$$"
  (cd "$1" && find . -mindepth 1 | sed 's|^\./||') > "$list"
  tar -C "$1" -czf "$2" -T "$list"
}

# ----------------------------------------------------------------- assertions

# Set by the e2e cases before asserting, so failures can say what they saw.
CONTEXT=""

fail_with() { # message
  printf 'assertion failed: %s\n' "$1"
  [ -n "$CONTEXT" ] && printf '  context: %s\n' "$CONTEXT"
  return 1
}

assert_equal() { # actual expected description
  [ "$1" = "$2" ] || fail_with "$3: expected \"$2\", got \"$1\""
}

# Queries a YAML file with a jq filter, by way of JSON. Going through JSON
# rather than querying the YAML with yq directly keeps yq's header-comment
# preprocessing from prepending a file's leading comments to every result.
q() { # file jq-filter
  yqq -o=json "$1" | jqq -r "$2"
}

# Reads a field of the nth task-calling step of a Stage's promotion template.
task_call_field() { # stage.yaml index jq-filter
  q "$1" "[.spec.promotionTemplate.spec.steps[] | select(has(\"task\"))] | .[$2] | $3"
}

# Asserts every non-empty line of `subset` appears in `superset`. Both are
# files, one name per line, so no word splitting is involved.
assert_subset() { # subset-file superset-file description
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$2" || {
      fail_with "$3: $line"
      printf '  had: %s\n' "$(tr '\n' ' ' < "$2")"
      return 1
    }
  done < "$1"
}

assert_gzipped() { # file
  local magic
  magic="$(head -c 2 "$1" | xxd -p)"
  [ "$magic" = "1f8b" ] ||
    fail_with "$1 is not gzip-compressed (magic bytes ${magic:-<empty>}, want 1f8b)"
}

assert_argocd_readable_layer_type() { # media-type
  local type
  for type in "${ARGOCD_DEFAULT_LAYER_MEDIA_TYPES[@]}"; do
    [ "$1" = "$type" ] && return 0
  done
  fail_with "layer media type \"$1\" is outside Argo CD's default allow-list (${ARGOCD_DEFAULT_LAYER_MEDIA_TYPES[*]})"
}
