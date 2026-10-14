#!/usr/bin/env bats
# shellcheck disable=SC2016  # jq filters are single-quoted on purpose
# shellcheck disable=SC2034  # CONTEXT is read by diagnose in helpers.bash
# Behaviour tests for the flux-reconcile step, run against real Flux
# controllers in a kind cluster. One @test per behaviour; see helpers.bash for
# how the image is driven and how the cluster is built.
#
#   IMAGE=flux-reconcile:dev bats test/flux-reconcile.bats
#
# Needs docker, kind, kubectl, curl and helm. Every case gets its own branch,
# GitRepository and namespace, so cases cannot see each other's commits.

setup_file() {
  load helpers
  start_flux_cluster
  require helm || return 1
  start_registry_forward
}

teardown_file() {
  load helpers
  stop_registry_forward
  teardown_cluster
}

setup() {
  load helpers
}

# A case with a GitRepository and a Kustomization over ./deploy, reconciled
# once so that it starts from a known, applied revision. Prints the seeded
# commit.
ready_kustomization() { # name [extra kustomization spec]
  local sha
  sha="$(new_case "$1")"
  git_repository "$1"
  kustomization "$1" ./deploy "${2:-}"
  wait_ready kustomizations "$1"
  printf '%s' "$sha"
}

helm_release_from_git() { # name
  apply_yaml << EOF
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $1
  namespace: flux-system
spec:
  interval: 1h
  targetNamespace: case-$1
  chart:
    spec:
      chart: ./charts/demo
      sourceRef:
        kind: GitRepository
        name: $1
EOF
}

helm_release_from_oci() { # name oci-repository-path
  apply_yaml << EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: $1
  namespace: flux-system
spec:
  interval: 1h
  url: oci://$(registry)/$2/demo
  insecure: true
  ref:
    semver: ">=0.1.0"
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $1
  namespace: flux-system
spec:
  interval: 1h
  targetNamespace: case-$1
  chartRef:
    kind: OCIRepository
    name: $1
EOF
}

hr_target() { # name [desiredRevision]
  jqq -n --arg name "$1" --arg want "${2:-}" \
    '{kind: "HelmRelease", name: $name}
     + (if $want == "" then {} else {desiredRevision: $want} end)'
}

# The chart version the release's ConfigMap reports, as the cluster holds it.
released_chart_version() { # case
  kube -n "case-$1" get configmaps -o json |
    jqq -r '[.items[] | .data.chartVersion // empty] | first // ""'
}

chart_yaml_at() { # version
  sed "s/^version: .*/version: $1/" "$FIXTURES/repo/charts/demo/Chart.yaml"
}

# --------------------------------------------------------------- configuration

@test 'no config at all is a misconfiguration' {
  run_step 'null'
  assert_status 2
  assert_log 'kubeconfig is required'
  # The output is written even for a misconfiguration: it is what the operator
  # reads in the promotion.
  assert_jq '.message | test("kubeconfig is required")' true
  assert_jq '.targets | length' 0
}

@test 'a config with no targets is a misconfiguration' {
  run_step "$(step_config '[]')"
  assert_status 2
  assert_log 'targets is required'
}

@test 'a kind other than Kustomization or HelmRelease is a misconfiguration' {
  run_step "$(step_config '[{"kind": "GitRepository", "name": "x"}]')"
  assert_status 2
  assert_log 'targets[0].kind must be Kustomization or HelmRelease, not GitRepository'
}

@test 'the failing target is named by its index' {
  run_step "$(step_config '[{"kind": "Kustomization", "name": "a"}, {"kind": "Kustomization"}]')"
  assert_status 2
  assert_log 'targets[1].name is required'
}

@test 'a timeout that is not a duration is a misconfiguration' {
  run_step "$(step_config '[{"kind": "Kustomization", "name": "a"}]' '{"timeout": "ten minutes"}')"
  assert_status 2
  assert_log 'timeout must be a duration'
}

@test 'withSource must be a boolean: the string "false" is refused, not read as true' {
  run_step "$(step_config '[{"kind": "Kustomization", "name": "a", "withSource": "false"}]')"
  assert_status 2
  assert_log 'targets[0].withSource must be a boolean'
}

@test 'an empty desiredRevision is refused rather than treated as absent' {
  run_step "$(step_config '[{"kind": "Kustomization", "name": "a", "desiredRevision": ""}]')"
  assert_status 2
  assert_log 'targets[0].desiredRevision must be a non-empty string'
}

@test 'more than 20 targets is a misconfiguration' {
  local targets
  targets="$(jqq -n '[range(21) | {kind: "Kustomization", name: "t\(.)"}]')"
  run_step "$(step_config "$targets")"
  assert_status 2
  assert_log 'at most 20 targets'
}

@test 'a context the kubeconfig does not have is a misconfiguration' {
  run_step "$(step_config '[{"kind": "Kustomization", "name": "a"}]' '{"context": "nowhere"}')"
  assert_status 2
  assert_log 'context nowhere'
}

@test 'a kubeconfig that does not parse is a misconfiguration' {
  run_step '{"kubeconfig": "not a kubeconfig", "targets": [{"kind": "Kustomization", "name": "a"}]}'
  assert_status 2
  assert_log 'kubeconfig: '
  refute_log 'Kustomization flux-system/a'
}

@test 'a Kustomization that does not exist is a misconfiguration, and is reported' {
  run_step "$(step_config "[$(ks_target no-such-kustomization)]")"
  assert_status 2
  assert_log 'not found'
  assert_jq '.targets[0].name' no-such-kustomization
  assert_jq '.targets[0].ready' false
}

@test 'a kubeconfig without permission on Flux objects is a misconfiguration' {
  local config
  config="$(jqq -n --rawfile kc "$BATS_FILE_TMPDIR/no-access.kubeconfig" \
    '{kubeconfig: $kc, targets: [{kind: "Kustomization", name: "anything"}]}')"
  run_step "$config"
  assert_status 2
  assert_log 'forbidden'
}

# --------------------------------------------------------------- Kustomization

@test 'a Kustomization applies the promoted commit, and the output says which' {
  local sha
  ready_kustomization ks-applies > /dev/null
  sha="$(configmap_version 2 | git_write fixtures ks-applies deploy/configmap.yaml)"

  run_step "$(step_config "[$(ks_target ks-applies "$sha")]")"
  assert_status 0
  assert_jq '.targets[0].revision' "ks-applies@sha1:$sha"
  assert_jq '.targets[0].source.kind' GitRepository
  assert_jq '.targets[0].source.revision' "ks-applies@sha1:$sha"
  assert_jq '.targets[0].ready' true
  assert_jq '.revision' "ks-applies@sha1:$sha"
  assert_equal "$(applied_version ks-applies)" 2 'the ConfigMap in the cluster'
}

@test 'the reconcile request names the promotion that made it' {
  ready_kustomization ks-token > /dev/null
  run_step "$(step_config "[$(ks_target ks-token)]")"
  assert_status 0
  case "$(flux_field kustomizations ks-token '{.status.lastHandledReconcileAt}')" in
    kargo-suite-*) ;;
    *) diagnose 'lastHandledReconcileAt does not carry the promotion name' && return 1 ;;
  esac
}

@test 'without a desiredRevision, a Kustomization must apply what its source now holds' {
  local sha
  ready_kustomization ks-follows > /dev/null
  sha="$(configmap_version 3 | git_write fixtures ks-follows deploy/configmap.yaml)"

  run_step "$(step_config "[$(ks_target ks-follows)]")"
  assert_status 0
  assert_jq '.targets[0].revision' "ks-follows@sha1:$sha"
  assert_jq '.targets[0].desiredRevision' null
  assert_equal "$(applied_version ks-follows)" 3 'the ConfigMap in the cluster'
}

# The trap the reference `kubectl annotate && wait for Ready` approach falls
# into: reconciled without its source, the Kustomization handles the request
# and is Ready=True on the revision it already had.
@test 'Ready on the old revision is not success: without its source, the step times out' {
  local sha
  ready_kustomization ks-stale > /dev/null
  sha="$(configmap_version 2 | git_write fixtures ks-stale deploy/configmap.yaml)"

  run_step "$(step_config "[$(ks_target ks-stale "$sha" '{"withSource": false}')]" '{"timeout": "10s"}')"
  assert_status 1
  assert_log 'Ready at ks-stale@sha1:'
  assert_jq '.message | test("timed out")' true
  assert_jq '.targets[0].ready' false
  assert_equal "$(applied_version ks-stale)" 1 'the ConfigMap in the cluster'
}

# Flux stamps lastHandledReconcileAt on a suspended object and leaves its old
# Ready=True in place: by token and condition it looks reconciled.
@test 'a suspended Kustomization fails without being asked to reconcile' {
  local sha
  ready_kustomization ks-suspended > /dev/null
  suspend kustomizations ks-suspended
  sha="$(configmap_version 2 | git_write fixtures ks-suspended deploy/configmap.yaml)"

  run_step "$(step_config "[$(ks_target ks-suspended "$sha")]")"
  assert_status 1
  assert_jq '.message | test("is suspended")' true
  assert_jq '.targets[0].ready' false
  refute_log 'requested'
  assert_equal "$(applied_version ks-suspended)" 1 'the ConfigMap in the cluster'
}

@test 'a suspended source fails, naming the source' {
  ready_kustomization ks-source-suspended > /dev/null
  suspend gitrepositories ks-source-suspended

  run_step "$(step_config "[$(ks_target ks-source-suspended)]")"
  assert_status 1
  assert_jq '.message' 'GitRepository flux-system/ks-source-suspended is suspended: Flux would mark the reconcile handled and fetch nothing'
}

@test "a commit that fails to apply fails fast, with Flux's reason, and reports what is still applied" {
  local good bad started
  good="$(ready_kustomization ks-broken)"
  # data values must be strings: the API server refuses an integer.
  bad="$(configmap_version 2 | sed 's/version: "2"/version: 2/' |
    git_write fixtures ks-broken deploy/configmap.yaml)"

  started="$SECONDS"
  run_step "$(step_config "[$(ks_target ks-broken "$bad")]" '{"timeout": "2m"}')"
  assert_status 1
  assert_jq '.message | test("ReconciliationFailed")' true
  assert_jq '.targets[0].revision' "ks-broken@sha1:$good"
  [ $((SECONDS - started)) -lt 60 ] || {
    diagnose "took $((SECONDS - started))s: a failed apply should not wait out the timeout"
    return 1
  }
}

@test 'a desiredRevision the branch never reaches times out at the source' {
  ready_kustomization ks-never > /dev/null
  run_step "$(step_config "[$(ks_target ks-never 0123456789abcdef0123456789abcdef01234567)]" '{"timeout": "10s"}')"
  assert_status 1
  assert_jq '.message | test("to fetch 0123456789abcdef0123456789abcdef01234567")' true
  # Asked more than once: the step allows for a Git host still serving the
  # previous HEAD just after a push.
  assert_log 'requesting again'
}

@test 'neither a short SHA nor the branch name counts as the desired revision' {
  local sha
  sha="$(ready_kustomization ks-prefix)"

  run_step "$(step_config "[$(ks_target ks-prefix "${sha:0:7}")]" '{"timeout": "6s"}')"
  assert_status 1
  assert_jq '.message | test("timed out")' true

  run_step "$(step_config "[$(ks_target ks-prefix ks-prefix)]" '{"timeout": "6s"}')"
  assert_status 1
  assert_jq '.message | test("timed out")' true

  # …while the full SHA, with or without its algorithm, does.
  run_step "$(step_config "[$(ks_target ks-prefix "$sha")]")"
  assert_status 0
  run_step "$(step_config "[$(ks_target ks-prefix "sha1:$sha")]")"
  assert_status 0
}

@test 'running the step again for an applied commit succeeds again' {
  local sha
  sha="$(ready_kustomization ks-again)"
  run_step "$(step_config "[$(ks_target ks-again "$sha")]")"
  assert_status 0
  run_step "$(step_config "[$(ks_target ks-again "$sha")]")"
  assert_status 0
  assert_jq '.targets[0].revision' "ks-again@sha1:$sha"
}

# ---------------------------------------------------------------------- health

# The other trap: without wait or healthChecks, Ready=True means the apply went
# through. Here the Deployment can never pull its image.
@test 'without health checks an unhealthy workload is Ready, and the output says health was not checked' {
  new_case ks-unchecked > /dev/null
  git_repository ks-unchecked
  kustomization ks-unchecked ./unhealthy

  run_step "$(step_config "[$(ks_target ks-unchecked)]")"
  assert_status 0
  assert_jq '.targets[0].healthChecked' false
  assert_jq '.healthChecked' false
  assert_jq '.targets[0].message | test("health not checked")' true
  assert_jq '.message | test("not all check workload health")' true
  assert_log 'means applied, not healthy'
}

@test 'requireHealthCheck refuses a Kustomization without health checks before asking Flux for anything' {
  ready_kustomization ks-require > /dev/null
  run_step "$(step_config "[$(ks_target ks-require)]" '{"requireHealthCheck": true}')"
  assert_status 1
  assert_jq '.message | test("does not check workload health")' true
  refute_log 'requested'
}

@test 'with wait: true, a healthy workload is reported as health-checked' {
  new_case ks-healthy > /dev/null
  git_repository ks-healthy
  kustomization ks-healthy ./healthy '  wait: true
  timeout: 90s'

  run_step "$(step_config "[$(ks_target ks-healthy)]" '{"requireHealthCheck": true, "timeout": "2m"}')"
  assert_status 0
  assert_jq '.targets[0].healthChecked' true
  assert_jq '.healthChecked' true
  assert_jq '.message | test("passed their health checks")' true
}

@test 'with wait: true, an unhealthy workload fails the step with HealthCheckFailed' {
  new_case ks-unhealthy > /dev/null
  git_repository ks-unhealthy
  kustomization ks-unhealthy ./unhealthy '  wait: true
  timeout: 15s'

  run_step "$(step_config "[$(ks_target ks-unhealthy)]" '{"timeout": "2m"}')"
  assert_status 1
  assert_jq '.message | test("HealthCheckFailed")' true
  assert_jq '.targets[0].healthChecked' true
  assert_jq '.targets[0].ready' false
}

# --------------------------------------------------------------------- targets

@test 'targets are reconciled in order, and every one is reported' {
  local first second
  first="$(ready_kustomization ks-order-a)"
  second="$(ready_kustomization ks-order-b)"

  run_step "$(step_config "[$(ks_target ks-order-a "$first"), $(ks_target ks-order-b "$second")]")"
  assert_status 0
  assert_jq '[.targets[].name] | join(",")' 'ks-order-a,ks-order-b'
  assert_jq '.revision' "ks-order-a@sha1:$first"
}

@test 'a failing target stops the step, and the targets before it are still reported' {
  ready_kustomization ks-stop-a > /dev/null
  ready_kustomization ks-stop-b > /dev/null
  ready_kustomization ks-stop-c > /dev/null
  suspend kustomizations ks-stop-b

  run_step "$(step_config "[$(ks_target ks-stop-a), $(ks_target ks-stop-b), $(ks_target ks-stop-c)]")"
  assert_status 1
  assert_jq '.targets | length' 2
  assert_jq '.targets[0].ready' true
  assert_jq '.targets[1].ready' false
  refute_log 'Kustomization flux-system/ks-stop-c'
}

# ----------------------------------------------------------------- HelmRelease

@test 'a HelmRelease is upgraded to the promoted chart version, its source chain refreshed deepest first' {
  new_case hr-git > /dev/null
  git_repository hr-git
  helm_release_from_git hr-git
  wait_ready helmreleases hr-git
  chart_yaml_at 0.2.0 | git_write fixtures hr-git charts/demo/Chart.yaml > /dev/null

  run_step "$(step_config "[$(hr_target hr-git 0.2.0)]" '{"timeout": "2m"}')"
  assert_status 0
  assert_jq '.targets[0].revision' 0.2.0
  assert_jq '.targets[0].source.kind' HelmChart
  assert_jq '.targets[0].source.name' flux-system-hr-git
  # Helm waits for the release's resources by default.
  assert_jq '.targets[0].healthChecked' true
  assert_equal "$(released_chart_version hr-git)" 0.2.0 'the release in the cluster'

  local order
  order="$(printf '%s\n' "$LOG" | sed -n 's/^  requested \([A-Za-z]*\) .*/\1/p' | paste -sd, -)"
  assert_equal "$order" GitRepository,HelmChart,HelmRelease 'the order of the reconcile requests'
}

@test 'a chart version that never arrives times out' {
  new_case hr-never > /dev/null
  git_repository hr-never
  helm_release_from_git hr-never
  wait_ready helmreleases hr-never

  run_step "$(step_config "[$(hr_target hr-never 9.9.9)]" '{"timeout": "10s"}')"
  assert_status 1
  assert_jq '.message | test("expected 9.9.9")' true
  assert_jq '.targets[0].revision' 0.1.0
}

@test 'a suspended HelmRelease fails without being asked to reconcile' {
  new_case hr-suspended > /dev/null
  git_repository hr-suspended
  helm_release_from_git hr-suspended
  wait_ready helmreleases hr-suspended
  suspend helmreleases hr-suspended

  run_step "$(step_config "[$(hr_target hr-suspended)]")"
  assert_status 1
  assert_jq '.message | test("is suspended")' true
  refute_log 'requested'
}

# helm-controller records a chart from an OCIRepository as
# `<version>+<first 12 hex of the digest>` — and so does the chart's own
# .Chart.Version — so `0.2.0` must match `0.2.0+…`.
@test 'a HelmRelease from an OCIRepository matches by chart version and by digest' {
  local digest repo
  new_case hr-oci > /dev/null
  # A repository of its own per run: the registry outlives a kept cluster's
  # runs, and one already holding 0.2.0 would make this case pass vacuously.
  repo="charts-hr-oci-$(date +%s)"
  push_chart "$FIXTURES/repo/charts/demo" 0.1.0 "$repo" > /dev/null
  helm_release_from_oci hr-oci "$repo"
  wait_ready helmreleases hr-oci
  digest="$(push_chart "$FIXTURES/repo/charts/demo" 0.2.0 "$repo")"
  CONTEXT="pushed 0.2.0 as $digest"

  run_step "$(step_config "[$(hr_target hr-oci 0.2.0)]" '{"timeout": "2m"}')"
  assert_status 0
  assert_jq '.targets[0].revision | startswith("0.2.0+")' true
  assert_jq '.targets[0].source.kind' OCIRepository
  assert_jq '.targets[0].source.revision' "0.2.0@$digest"
  local hex="${digest#sha256:}"
  assert_equal "$(released_chart_version hr-oci)" "0.2.0+${hex:0:12}" 'the release in the cluster'

  run_step "$(step_config "[$(hr_target hr-oci "$digest")]")"
  assert_status 0
}
