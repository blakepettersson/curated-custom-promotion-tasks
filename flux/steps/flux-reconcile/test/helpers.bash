#!/usr/bin/env bash
# shellcheck disable=SC2034  # a library: its variables are read by the .bats files that load it
# shellcheck disable=SC2016  # jq filters and the in-pod git script are single-quoted on purpose
# Helpers for the flux-reconcile suites, loaded by the .bats files.
#
# A step that talks to Flux cannot be tested without Flux, so unlike
# kyverno-validate these suites need a cluster: setup_file builds a kind
# cluster with the Flux controllers, a Git server and a registry, and every
# case runs the image against it exactly as Kargo does — config in
# FLUX_RECONCILE_CONFIG, results read back from the file named by
# $KARGO_OUTPUT. The kubeconfig handed to the step is built from the
# ServiceAccount in examples/rbac.yaml, so every case is also a check that the
# documented permissions are enough.
#
# Keeping the cluster between runs, which makes iterating bearable:
#
#   FLUX_E2E_KEEP=1 bats test/flux-reconcile.bats
#
# Everything in setup_file is idempotent, so a kept cluster is reused.

IMAGE="${IMAGE:-flux-reconcile:dev}"
FLUX_VERSION="${FLUX_VERSION:-v2.9.5}"
FLUX_E2E_CLUSTER="${FLUX_E2E_CLUSTER:-flux-reconcile-e2e}"
KUBE_CONTEXT="kind-$FLUX_E2E_CLUSTER"
INFRA_NS=flux-e2e-infra
# What a promotion would pass as kubeconfig is reachable from the step
# container on kind's docker network, by the control plane's container name.
API_SERVER="https://$FLUX_E2E_CLUSTER-control-plane:6443"

STEP_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
FAMILY_DIR="$(cd "$STEP_DIR/../.." && pwd)"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

GIT_USER=kargo
GIT_PASSWORD=flux-e2e-password
GIT_URL="http://gitea.$INFRA_NS.svc.cluster.local:3000/$GIT_USER"

# Set by run_step, read by the assertions below.
STATUS=0
OUTPUT=""
LOG=""
# Extra context an assertion prints on failure.
CONTEXT=""

# ------------------------------------------------------------------- utilities

jqq() {
  if command -v jq > /dev/null 2>&1; then
    jq "$@"
  else
    docker run --rm -i --entrypoint jq "$IMAGE" "$@"
  fi
}

yqq() {
  if command -v yq > /dev/null 2>&1; then
    yq "$@"
  else
    docker run --rm -i mikefarah/yq:4 "$@"
  fi
}

require() { # tool...
  local missing=() tool
  for tool in "$@"; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'these checks need %s on PATH\n' "${missing[*]}" >&2
    return 1
  }
}

# Prints progress where bats will show it during a long setup_file. Without the
# fd 3 redirect a few minutes of cluster build looks like a hang.
say() { # message
  printf '# %s\n' "$*" >&3 2> /dev/null || printf '# %s\n' "$*" >&2
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

kube() {
  kubectl --context "$KUBE_CONTEXT" "$@"
}

# ----------------------------------------------------------------- the cluster

start_cluster() {
  if kind get clusters 2> /dev/null | grep -qxF "$FLUX_E2E_CLUSTER"; then
    say "reusing the kind cluster $FLUX_E2E_CLUSTER"
    return 0
  fi
  say "creating the kind cluster $FLUX_E2E_CLUSTER"
  kind create cluster --name "$FLUX_E2E_CLUSTER" --wait 120s > /dev/null
}

delete_cluster() {
  kind delete cluster --name "$FLUX_E2E_CLUSTER" > /dev/null 2>&1 || true
}

teardown_cluster() {
  if [ -n "${FLUX_E2E_KEEP:-}" ]; then
    say "keeping the kind cluster $FLUX_E2E_CLUSTER (FLUX_E2E_KEEP is set)"
  else
    delete_cluster
  fi
}

install_flux() {
  local manifest="$BATS_FILE_TMPDIR/flux-install.yaml"
  say "installing flux $FLUX_VERSION"
  curl -fsSL -o "$manifest" \
    "https://github.com/fluxcd/flux2/releases/download/$FLUX_VERSION/install.yaml"
  kube apply -f "$manifest" > /dev/null
  kube -n flux-system wait --for=condition=available --timeout=180s \
    deploy/source-controller deploy/kustomize-controller deploy/helm-controller > /dev/null
}

deploy_infra() {
  say 'deploying the git server and the registry'
  kube apply -f "$BATS_TEST_DIRNAME/cluster/infra.yaml" > /dev/null
  kube -n "$INFRA_NS" wait --for=condition=available \
    deploy/gitea deploy/registry --timeout=180s > /dev/null
  # Idempotent: a kept cluster already has the user.
  kube -n "$INFRA_NS" exec deploy/gitea -- gitea admin user create \
    --username "$GIT_USER" --password "$GIT_PASSWORD" --email kargo@example.com \
    --must-change-password=false > /dev/null 2>&1 || true
  REGISTRY="$(kube -n "$INFRA_NS" get svc registry -o jsonpath='{.spec.clusterIP}'):5000"
  printf '%s' "$REGISTRY" > "$BATS_FILE_TMPDIR/registry"
}

registry() {
  cat "$BATS_FILE_TMPDIR/registry"
}

# A kubeconfig for a ServiceAccount, by its token Secret, addressed as the step
# container sees the API server.
service_account_kubeconfig() { # namespace token-secret out-file
  local token ca
  retry_until "the token in $1/$2" 60 \
    sh -c "kubectl --context '$KUBE_CONTEXT' -n '$1' get secret '$2' -o jsonpath='{.data.token}' | grep -q ."
  token="$(kube -n "$1" get secret "$2" -o jsonpath='{.data.token}' | base64 -d)"
  ca="$(kube -n "$1" get secret "$2" -o jsonpath='{.data.ca\.crt}')"
  cat > "$3" << EOF
apiVersion: v1
kind: Config
clusters:
  - name: flux
    cluster:
      server: $API_SERVER
      certificate-authority-data: $ca
users:
  - name: kargo
    user:
      token: $token
contexts:
  - name: flux
    context:
      cluster: flux
      user: kargo
current-context: flux
EOF
}

# The step's identity is the one examples/rbac.yaml documents.
grant_step_access() {
  kube apply -f "$STEP_DIR/examples/rbac.yaml" > /dev/null
  service_account_kubeconfig flux-system kargo-flux-reconcile-token "$BATS_FILE_TMPDIR/step.kubeconfig"
  service_account_kubeconfig "$INFRA_NS" no-access-token "$BATS_FILE_TMPDIR/no-access.kubeconfig"
}

start_flux_cluster() {
  require docker kind kubectl curl || return 1
  docker image inspect "$IMAGE" > /dev/null 2>&1 || {
    printf 'no image %s: run `make build` first\n' "$IMAGE" >&2
    return 1
  }
  start_cluster
  install_flux
  deploy_infra
  grant_step_access
}

# -------------------------------------------------------------------- git

# Runs inside the Gitea pod, which has git: one commit to one branch of one
# repository, pushed over HTTP. Working in the pod rather than through a
# port-forward keeps the suite free of background processes for Git.
#
#   seed  replaces the branch's contents with a tar read from stdin
#   write replaces one file with stdin
#   rm    deletes one path
GIT_SCRIPT='
set -eu
op="$1" repo="$2" branch="$3" path="${4:-}"
url="http://$GIT_USER:$GIT_PASSWORD@localhost:3000/$GIT_USER/$repo.git"
w="$(mktemp -d)"
if git ls-remote --exit-code --heads "$url" "$branch" > /dev/null 2>&1; then
  git clone -q --branch "$branch" "$url" "$w"
else
  git init -q -b "$branch" "$w"
  git -C "$w" remote add origin "$url"
fi
case "$op" in
  seed)
    find "$w" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    tar -xf - -C "$w"
    ;;
  write) mkdir -p "$w/$(dirname "$path")"; cat > "$w/$path" ;;
  rm) rm -rf "${w:?}/$path" ;;
esac
cd "$w"
git add -A
git -c user.name=suite -c user.email=suite@example.com commit -q --allow-empty -m "$op $branch $path"
# Gitea answers every push with a "create a pull request" banner on stderr;
# show it only if the push fails.
git push -q origin "$branch" 2> "$w.err" || { cat "$w.err" >&2; exit 1; }
git rev-parse HEAD
rm -rf "$w" "$w.err"
'

git_op() { # op repo branch [path] — stdin as the op wants it; prints the commit
  kube -n "$INFRA_NS" exec -i deploy/gitea -- \
    env GIT_USER="$GIT_USER" GIT_PASSWORD="$GIT_PASSWORD" \
    sh -c "$GIT_SCRIPT" git-op "$@"
}

git_seed() { # repo branch dir — prints the commit
  # COPYFILE_DISABLE: macOS tar otherwise adds an AppleDouble `._<name>` file
  # beside each one with extended attributes — `._configmap.yaml` in deploy/,
  # which kustomize-controller then fails to decode.
  COPYFILE_DISABLE=1 tar -C "$3" --exclude '._*' -cf - . | git_op seed "$1" "$2"
}

git_write() { # repo branch path — content on stdin; prints the commit
  git_op write "$1" "$2" "$3"
}

# ------------------------------------------------------------- flux objects

apply_yaml() { # yaml on stdin
  kube apply -f - > /dev/null
}

# A case's own branch of the fixture repository, its own GitRepository
# tracking it, and its own namespace to apply into, so no case can see another
# case's commits. Prints the seeded commit.
#
# Starts from nothing on a kept cluster too: Flux objects a previous run left
# behind are deleted, since `kubectl apply` would not undo what a case did to
# them with a patch — a suspended Kustomization would stay suspended.
new_case() { # name
  local resource
  for resource in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io \
    gitrepositories.source.toolkit.fluxcd.io ocirepositories.source.toolkit.fluxcd.io; do
    kube -n flux-system delete "$resource" "$1" --ignore-not-found --wait > /dev/null
  done
  kube create namespace "case-$1" > /dev/null 2>&1 || true
  git_seed fixtures "$1" "$FIXTURES/repo"
}

git_repository() { # name [extra spec yaml, indented two spaces]
  apply_yaml << EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: $1
  namespace: flux-system
spec:
  interval: 1h
  url: $GIT_URL/fixtures.git
  ref:
    branch: $1
${2:-}
EOF
}

# Intervals are an hour throughout: nothing here may reconcile because time
# passed, only because the step asked.
kustomization() { # name path [extra spec yaml, indented two spaces]
  apply_yaml << EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $1
  namespace: flux-system
spec:
  interval: 1h
  path: $2
  prune: true
  targetNamespace: case-$1
  sourceRef:
    kind: GitRepository
    name: $1
${3:-}
EOF
}

wait_ready() { # resource name [namespace]
  kube -n "${3:-flux-system}" wait --for=condition=Ready --timeout=120s "$1/$2" > /dev/null
}

suspend() { # resource name
  kube -n flux-system patch "$1" "$2" --type merge -p '{"spec":{"suspend":true}}' > /dev/null
}

# The ConfigMap a Kustomization case applies, as the cluster holds it.
applied_version() { # case
  kube -n "case-$1" get configmap demo -o jsonpath='{.data.version}' 2> /dev/null || true
}

configmap_version() { # version — the fixture ConfigMap with data.version set
  sed "s/version: \"1\"/version: \"$1\"/" "$FIXTURES/repo/deploy/configmap.yaml"
}

flux_field() { # resource name jsonpath [namespace]
  kube -n "${4:-flux-system}" get "$1" "$2" -o jsonpath="$3" 2> /dev/null || true
}

# --------------------------------------------------------------- the step

# The config a promotion would hand the step, around a list of targets.
step_config() { # targets-json [extra-config-json]
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jqq -n --rawfile kc "$BATS_FILE_TMPDIR/step.kubeconfig" \
    --argjson targets "$1" --argjson extra "$extra" \
    '{kubeconfig: $kc, timeout: "90s", targets: $targets} + $extra'
}

run_step() { # config-json [docker args...]
  local config="$1"
  shift
  local out="$BATS_TEST_TMPDIR/output.json"
  : > "$out"
  # The step runs as uid 65532 and has to be able to write its results.
  chmod 777 "$BATS_TEST_TMPDIR"
  chmod 666 "$out"
  # `&& STATUS=0 || STATUS=$?` keeps a non-zero exit — which many of these
  # cases expect — from tripping the `set -e` that bats runs tests under.
  LOG="$(
    docker run --rm --network kind \
      -v "$BATS_TEST_TMPDIR:/out" \
      -e FLUX_RECONCILE_CONFIG="$config" \
      -e KARGO_OUTPUT=/out/output.json \
      -e FLUX_RECONCILE_RETRY_SECONDS=2 \
      "$@" \
      "$IMAGE" 2>&1
  )" && STATUS=0 || STATUS=$?
  OUTPUT="$(cat "$out")"
}

ks_target() { # name [desiredRevision] [extra-json]
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jqq -n --arg name "$1" --arg want "${2:-}" --argjson extra "$extra" \
    '{kind: "Kustomization", name: $name}
     + (if $want == "" then {} else {desiredRevision: $want} end) + $extra'
}

# ------------------------------------------------------------- the registry

# The chart a HelmRelease pulls through an OCIRepository is pushed from the
# host, through a port-forward. kubectl directly rather than the `kube`
# function, and fd 3 closed: backgrounding a function makes `$!` the
# subshell's pid, so the kill in teardown would orphan kubectl — and an orphan
# holding bats' output descriptor keeps the run from ever finishing.
start_registry_forward() {
  local log="$BATS_FILE_TMPDIR/port-forward.log" port i
  : > "$log"
  kubectl --context "$KUBE_CONTEXT" -n "$INFRA_NS" \
    port-forward svc/registry :5000 >> "$log" 2>&1 3>&- &
  printf '%s' "$!" > "$BATS_FILE_TMPDIR/forward.pid"
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
  printf 'localhost:%s' "$port" > "$BATS_FILE_TMPDIR/registry-forward"
  retry_until 'the forwarded registry to answer' 60 curl -fsS "http://localhost:$port/v2/"
}

stop_registry_forward() {
  local pid i
  pid="$(cat "$BATS_FILE_TMPDIR/forward.pid" 2> /dev/null || true)"
  [ -n "$pid" ] || return 0
  kill "$pid" 2> /dev/null || true
  # Confirm it is gone: teardown_file is not the process that started it, so
  # there is no `wait` to rely on, and a survivor holds bats open.
  for i in $(seq 1 20); do
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.5
  done
  kill -9 "$pid" 2> /dev/null || true
  rm -f "$BATS_FILE_TMPDIR/forward.pid"
}

# Packages a chart directory at a given version and pushes it to
# oci://<registry>/<repo>/<name>. Prints the pushed digest.
push_chart() { # chart-dir version repo
  local work="$BATS_FILE_TMPDIR/chart-$2" name
  rm -rf "$work"
  cp -R "$1" "$work"
  sed -i.bak "s/^version: .*/version: $2/" "$work/Chart.yaml" && rm -f "$work/Chart.yaml.bak"
  name="$(sed -n 's/^name: //p' "$work/Chart.yaml")"
  helm package "$work" -d "$BATS_FILE_TMPDIR/packages" > /dev/null
  helm push "$BATS_FILE_TMPDIR/packages/$name-$2.tgz" \
    "oci://$(cat "$BATS_FILE_TMPDIR/registry-forward")/$3" --plain-http 2>&1 |
    sed -n 's/^Digest: //p'
}

# ------------------------------------------------------------------ assertions

diagnose() { # message
  printf 'assertion failed: %s\n' "$1"
  [ -n "$CONTEXT" ] && printf '  context: %s\n' "$CONTEXT"
  printf '  step exit code: %s\n' "$STATUS"
  printf '  step output:    %s\n' "${OUTPUT:-<empty>}"
  printf '  step log:\n%s\n' "$(printf '%s\n' "$LOG" | sed 's/^/    /')"
  printf '  flux objects:\n%s\n' "$(
    kube -n flux-system get gitrepositories,ocirepositories,helmcharts,kustomizations,helmreleases \
      2>&1 | sed 's/^/    /'
  )"
}

assert_status() { # expected
  [ "$STATUS" = "$1" ] || {
    diagnose "expected exit code $1, got $STATUS"
    return 1
  }
}

assert_jq() { # filter expected
  local actual
  # `|| true`: a filter that errors on an empty document would otherwise abort
  # the case under `set -e`, losing the diagnostics that say why.
  actual="$(printf '%s' "$OUTPUT" | jqq -r "$1" 2> /dev/null || true)"
  [ "$actual" = "$2" ] || {
    diagnose "expected $1 to be \"$2\", got \"$actual\""
    return 1
  }
}

assert_jq_true() { # filter
  assert_jq "$1" true
}

assert_log() { # substring
  printf '%s' "$LOG" | grep -qF -- "$1" || {
    diagnose "expected log to contain \"$1\""
    return 1
  }
}

refute_log() { # substring
  if printf '%s' "$LOG" | grep -qF -- "$1"; then
    diagnose "expected log not to contain \"$1\""
    return 1
  fi
}

assert_equal() { # actual expected description
  [ "$1" = "$2" ] || {
    diagnose "$3: expected \"$2\", got \"$1\""
    return 1
  }
}
