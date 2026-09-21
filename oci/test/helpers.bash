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
  # Spelled as an `if` rather than `A && B || C`: shellcheck rejects the latter
  # (SC2015), and it would be wrong here anyway — C runs when A succeeds and B
  # fails, which is exactly the case this has to report.
  if [ "$STATUS" != 0 ] || [ -n "$LINT" ]; then
    diagnose "expected the task to lint clean"
    return 1
  fi
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

# Renders the example chart the way the `helm-template` step in
# publish-manifests-to-oci/examples/single-stage.yaml does: a flat directory of
# manifests, CRDs included, with an optional per-stage values overlay that is
# skipped when absent (ignoreMissingValueFiles).
#
# One thing this replica cannot match: the file *names*. `helm template
# --output-dir` names each file after the template it came from
# (deployment.yaml), while the step names it after the resource
# (apps-deployment-example-app-prod-example-app.yaml) — as e2e-kargo.bats sees
# when it reads a real artifact, and why it finds manifests by content. The
# layout is the same and nothing downstream reads the names, Argo CD included.
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

# Renders the example overlay the way the `kustomize-build` step in
# publish-manifests-to-oci/examples/entry-stage-kustomize.yaml does: one file
# per resource in an output directory.
render_kustomize() { # stage out-dir
  local stage="$1" out="$2"
  rm -rf "$out"
  mkdir -p "$out"
  kustomize build "$EXAMPLE_APP/overlays/$stage" -o "$out"
}

# Renders every named Stage into its own subdirectory of one output directory,
# as the promotion template in publish-manifests-to-oci/examples/stage.yaml
# does: one helm-template step per Stage, each with that Stage's values file.
render_helm_all_stages() { # out-dir stage...
  local out="$1"
  shift
  rm -rf "$out"
  mkdir -p "$out"
  local stage
  for stage in "$@"; do
    render_helm "$stage" "$out/$stage"
  done
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

# Every task that packages a directory and pushes it as an artifact, i.e. that
# carries the archive/push/retag tail. There is one today — publishing lives in
# a single task on purpose, since a task cannot call another and every
# all-in-one variant would duplicate this tail. Discovered rather than named so
# that a second one cannot be added without these checks covering it.
archive_publishing_tasks() {
  local yaml
  for yaml in "$TASKS_DIR"/*/cluster-promotion-task.yaml; do
    if [ "$(q "$yaml" '[.spec.steps[] | select(.uses == "oci-push" and (.config | has("srcPath")))] | length')" != "0" ]; then
      printf '%s\n' "$yaml"
    fi
  done
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

# ------------------------------------------------------------------ real Kargo

# Everything below belongs to e2e-kargo.bats, which stands a real Kargo up in a
# kind cluster and promotes through it. The other two suites need none of it.
#
# The versions are pinned. `oci-push`'s local-archive mode (srcPath) is not in a
# released Kargo, so the chart is an unstable daily build — which means the
# version here is also the statement of which Kargo these tasks are known to
# work against. Bump it deliberately, and expect to find out what changed.
#
# The image repository has to be overridden alongside it: unstable charts are
# published with the release chart's default image repository, and unstable
# images go to a repository of their own.
KARGO_CLUSTER="${KARGO_CLUSTER:-kargo-oci-e2e}"
KARGO_CONTEXT="kind-$KARGO_CLUSTER"
KARGO_CHART="${KARGO_CHART:-oci://ghcr.io/akuity/kargo-charts-unstable/kargo}"
KARGO_CHART_VERSION="${KARGO_CHART_VERSION:-1.12.0-unstable-20260917}"
KARGO_IMAGE_REPO="${KARGO_IMAGE_REPO:-ghcr.io/akuity/kargo-unstable}"
# Kargo's webhook servers are served by cert-manager-issued certificates, so the
# chart will not install without it.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.19.1}"

KARGO_PROJECT=oci-e2e
KARGO_INFRA_NS=oci-e2e-infra
KARGO_MANIFESTS="$BATS_TEST_DIRNAME/kargo"

# Where setup_file records what it built, for the cases and teardown_file to
# read back. A directory rather than variables: bats runs setup_file, each case
# and teardown_file in separate processes.
KARGO_STATE="${BATS_FILE_TMPDIR:-${BATS_TEST_TMPDIR:-/tmp}}/kargo-state"

kube() {
  kubectl --context "$KARGO_CONTEXT" "$@"
}

kargo_state() { # key [value]
  mkdir -p "$KARGO_STATE"
  if [ "$#" -gt 1 ]; then
    printf '%s\n' "$2" > "$KARGO_STATE/$1"
  else
    cat "$KARGO_STATE/$1"
  fi
}

# Prints progress where bats will show it during a long setup_file. Without the
# fd 3 redirect a five-minute cluster build looks like a hang.
say() { # message
  printf '# %s\n' "$*" >&3 2>/dev/null || printf '# %s\n' "$*" >&2
}

# Polls until a command succeeds. Returns non-zero on timeout, having said what
# it was waiting for, so setup_file fails with a reason rather than a stack.
retry_until() { # description timeout-seconds command...
  local description="$1" timeout="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@" > /dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  printf 'timed out after %ss waiting for %s\n' "$timeout" "$description" >&2
  return 1
}

# ---------------------------------------------------------------- the cluster

start_cluster() {
  if kind get clusters 2> /dev/null | grep -qxF "$KARGO_CLUSTER"; then
    say "reusing the kind cluster $KARGO_CLUSTER"
    return 0
  fi
  say "creating the kind cluster $KARGO_CLUSTER"
  kind create cluster --name "$KARGO_CLUSTER" > /dev/null
}

delete_cluster() {
  kind delete cluster --name "$KARGO_CLUSTER" > /dev/null 2>&1 || true
}

# Both installs are `helm upgrade --install`, so a kept cluster (KARGO_E2E_KEEP)
# can be reused by the next run without being torn down first.
install_kargo() {
  say "installing cert-manager $CERT_MANAGER_VERSION"
  helm upgrade --install cert-manager cert-manager \
    --repo https://charts.jetstack.io \
    --version "$CERT_MANAGER_VERSION" \
    --kube-context "$KARGO_CONTEXT" \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 6m > /dev/null

  say "installing kargo $KARGO_CHART_VERSION"
  # The API server is off: these cases drive Kargo with kubectl, and skipping it
  # skips Dex, the UI and a certificate.
  helm upgrade --install kargo "$KARGO_CHART" \
    --version "$KARGO_CHART_VERSION" \
    --kube-context "$KARGO_CONTEXT" \
    --namespace kargo --create-namespace \
    --set image.repository="$KARGO_IMAGE_REPO" \
    --set api.enabled=false \
    --wait --timeout 8m > /dev/null
}

# The registry and the Git server. Records the registry's ClusterIP, which is
# the address the tasks under test are pointed at: go-containerregistry treats
# an RFC1918 address as plain HTTP, so no certificate is involved.
deploy_infra() {
  say 'deploying the registry and the git server'
  kube apply -f "$KARGO_MANIFESTS/infra.yaml" > /dev/null
  kube -n "$KARGO_INFRA_NS" wait --for=condition=available \
    deploy/registry deploy/git --timeout=180s > /dev/null
  kargo_state registry-ip "$(kube -n "$KARGO_INFRA_NS" get svc registry -o jsonpath='{.spec.clusterIP}')"
}

# Publishes oci/examples/example-app as a Git repository the cluster can clone.
#
# A bare repository plus `git update-server-info` is all nginx needs to serve a
# clonable remote over dumb HTTP, which is why there is no Git server to
# configure here. Seeded with `kubectl cp` so the suite runs against the working
# tree — including changes that are not committed, let alone pushed.
seed_git_repo() {
  local work="$BATS_FILE_TMPDIR/git-work" bare="$BATS_FILE_TMPDIR/example-app.git"
  say 'seeding the git server with examples/example-app'
  rm -rf "$work" "$bare"
  mkdir -p "$work"
  cp -R "$EXAMPLE_APP/." "$work/"
  git -C "$work" init -q -b main
  git -C "$work" add -A
  git -C "$work" -c user.email=e2e@example.test -c user.name='oci e2e' \
    commit -q -m 'example app'
  git clone -q --bare "$work" "$bare"
  # What makes the bare repository readable over dumb HTTP.
  git -C "$bare" update-server-info

  local pod served=/usr/share/nginx/html/example-app.git
  pod="$(kube -n "$KARGO_INFRA_NS" get pod -l app=git -o jsonpath='{.items[0].metadata.name}')"
  # Removed first: `kubectl cp` onto an existing directory copies *into* it, so
  # on a reused cluster the previous run's repository would still be the one
  # served — and the Warehouse would keep discovering its commit.
  kube -n "$KARGO_INFRA_NS" exec "$pod" -- rm -rf "$served"
  kube -n "$KARGO_INFRA_NS" cp "$bare" "$pod:$served" > /dev/null

  kargo_state commit "$(git -C "$bare" rev-parse HEAD)"
  kargo_state git-repo "http://git.$KARGO_INFRA_NS.svc.cluster.local/example-app.git"
}

# Applies every task in tasks/ — real Kargo's CRD schema and its CEL rules are a
# check the vendored schemas cannot make — plus the ungzipped fixture the
# negative control calls, and the project.
apply_project() {
  say 'applying the tasks and the project'
  local task
  for task in "$TASKS_DIR"/*/cluster-promotion-task.yaml; do
    kube apply -f "$task" > /dev/null
  done
  kube apply -f "$FIXTURES_DIR/broken/ungzipped.yaml" > /dev/null

  local registry_ip rendered
  registry_ip="$(kargo_state registry-ip)"
  kargo_state oci-repo "$registry_ip:5000/config/example-app"
  kargo_state oci-repo-ungzipped "$registry_ip:5000/config/ungzipped"
  rendered="$BATS_FILE_TMPDIR/project.yaml"
  sed -e "s|@@GIT_REPO@@|$(kargo_state git-repo)|g" \
    -e "s|@@OCI_REPO@@|$(kargo_state oci-repo)|g" \
    -e "s|@@OCI_REPO_UNGZIPPED@@|$(kargo_state oci-repo-ungzipped)|g" \
    "$KARGO_MANIFESTS/project.yaml" > "$rendered"
  kube apply -f "$rendered" > /dev/null

  # Refresh rather than wait out the Warehouse's interval, then wait for the
  # Freight carrying the commit just seeded. Taking whatever Freight exists
  # would promote the previous run's commit on a reused cluster, and every
  # assertion about the artifact's provenance would be comparing the seeded
  # commit against an artifact rendered from an older tree.
  kube -n "$KARGO_PROJECT" annotate warehouse example-app \
    kargo.akuity.io/refresh="$(date +%s)" --overwrite > /dev/null
  retry_until 'the warehouse to discover the seeded commit' 180 freight_for_commit
  kargo_state freight "$(freight_for_commit)"
}

# Prints the Freight whose Git commit is the one seed_git_repo published, or
# nothing if the Warehouse has not discovered it yet.
freight_for_commit() {
  local name
  # shellcheck disable=SC2016  # $commit is jq's --arg, not a shell variable
  name="$(
    kube -n "$KARGO_PROJECT" get freight -o json |
      jqq -r --arg commit "$(kargo_state commit)" \
        'first(.items[] | select(any(.commits[]?; .id == $commit)) | .metadata.name) // empty'
  )"
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# --------------------------------------------------------------- promoting

# Promotes the discovered Freight into a Stage and waits for the promotion to
# reach a terminal phase — including a failed one, since a case may be asserting
# that. Records the promotion's name, which Kargo assigns itself.
promote() { # stage state-key
  local stage="$1" key="$2" name
  say "promoting into $stage"
  name="$(
    kube create -o name -f - <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  generateName: e2e-
  namespace: $KARGO_PROJECT
spec:
  stage: $stage
  freight: $(kargo_state freight)
EOF
  )"
  name="${name#*/}"
  kargo_state "$key" "$name"
  retry_until "the $stage promotion to finish" 300 promotion_finished "$name"
}

promotion_finished() { # promotion
  case "$(promotion_field "$1" '{.status.phase}')" in
    Succeeded | Failed | Errored) return 0 ;;
    *) return 1 ;;
  esac
}

promotion_field() { # promotion jsonpath
  kube -n "$KARGO_PROJECT" get promotion "$1" -o jsonpath="$2" 2> /dev/null || true
}

promotion_phase() { # state-key
  promotion_field "$(kargo_state "$1")" '{.status.phase}'
}

# Prints one step's output as JSON. Kargo keys a task's step outputs by
# `<alias>::<step alias>`, and the task's own output by the alias alone.
promotion_output() { # state-key key jq-filter
  kube -n "$KARGO_PROJECT" get promotion "$(kargo_state "$1")" -o json |
    jqq -r ".status.state[\"$2\"] | $3" 2> /dev/null || true
}

# The Freight's status metadata, which is where `set-metadata` records the
# artifact for a downstream Stage in the same pipeline to read back.
freight_metadata() { # jq-filter
  kube -n "$KARGO_PROJECT" get freight "$(kargo_state freight)" -o json |
    jqq -r ".status.metadata | $1" 2> /dev/null || true
}

# Everything an operator would look at when a promotion does not do what it
# should: the phase, the message, each step's status, and the controller's own
# account of it.
diagnose_kargo() { # message state-key
  local name
  name="$(kargo_state "$2" 2> /dev/null || printf '<none>')"
  printf 'assertion failed: %s\n' "$1"
  printf '  promotion:  %s\n' "$name"
  printf '  phase:      %s\n' "$(promotion_field "$name" '{.status.phase}')"
  printf '  message:    %s\n' "$(promotion_field "$name" '{.status.message}')"
  printf '  steps:\n'
  kube -n "$KARGO_PROJECT" get promotion "$name" -o json 2> /dev/null |
    jqq -r '.status.stepExecutionMetadata // [] | .[] | "    \(.alias // "?") \(.status) \(.message // "")"' 2> /dev/null ||
    printf '    <none>\n'
  printf '  controller log (last 40 lines):\n'
  kube -n kargo logs deploy/kargo-controller --tail=40 2> /dev/null | sed 's/^/    /' ||
    printf '    <unavailable>\n'
}

assert_promotion_succeeded() { # state-key
  [ "$(promotion_phase "$1")" = "Succeeded" ] || {
    diagnose_kargo "expected the $1 promotion to succeed" "$1"
    return 1
  }
}

# ---------------------------------------------------- registry, from the host

# Forwards the in-cluster registry to a local port and records it where
# use_registry expects it, so the curl helpers above read the artifact Kargo
# published exactly as they read the one e2e-recipe.bats pushes.
start_registry_forward() {
  local log="$BATS_FILE_TMPDIR/port-forward.log" port i
  : > "$log"
  # kubectl directly rather than the `kube` function, and fd 3 closed. Both
  # matter: backgrounding a function makes `$!` the subshell's PID, so the
  # teardown kill would leave kubectl orphaned — and an orphan holding bats'
  # output descriptor keeps the whole run from ever finishing.
  kubectl --context "$KARGO_CONTEXT" -n "$KARGO_INFRA_NS" \
    port-forward svc/registry :5000 >> "$log" 2>&1 3>&- &
  kargo_state forward-pid "$!"
  for i in $(seq 1 60); do
    port="$(sed -n 's|^Forwarding from 127\.0\.0\.1:\([0-9]*\).*|\1|p' "$log" | head -1)"
    [ -n "$port" ] && break
    sleep 0.5
  done
  [ -n "$port" ] || {
    printf 'the registry port-forward never came up\n' >&2
    cat "$log" >&2
    return 1
  }
  mkdir -p "$(dirname "$REGISTRY_STATE")"
  printf 'localhost:%s\n' "$port" > "$REGISTRY_STATE.endpoint"
  retry_until 'the forwarded registry to answer' 60 \
    curl -fsS "http://localhost:$port/v2/"
}

stop_registry_forward() {
  local pid i
  pid="$(kargo_state forward-pid 2> /dev/null || true)"
  if [ -n "$pid" ]; then
    kill "$pid" 2> /dev/null || true
    # Confirm it is gone rather than assuming: teardown_file is a different
    # process than the one that started it, so there is no `wait` to rely on,
    # and a survivor holds bats open.
    for i in $(seq 1 20); do
      kill -0 "$pid" 2> /dev/null || break
      sleep 0.5
    done
    kill -9 "$pid" 2> /dev/null || true
  fi
  rm -f "$REGISTRY_STATE.endpoint"
  return 0
}
