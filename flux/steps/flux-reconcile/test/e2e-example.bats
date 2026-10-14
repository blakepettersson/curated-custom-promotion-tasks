#!/usr/bin/env bats
# shellcheck disable=SC2016  # jq filters are single-quoted on purpose
# shellcheck disable=SC2034  # CONTEXT is read by diagnose in helpers.bash
# The family's examples, end to end: examples/flux-app in a real Flux, promoted
# the way examples/cluster-promotion-task.yaml promotes it.
#
#   IMAGE=flux-reconcile:dev bats test/e2e-example.bats
#
# Needs docker, kind, kubectl, curl, helm, yq and python3.
#
# CustomPromotionStep is Kargo Enterprise, so there is no Kargo here to run the
# task. Instead the suite does what the task's built-in steps would — commits
# the new chart version where yaml-update writes it, as git-push would push it
# — and then runs the step with the task's own flux-reconcile config, its
# expressions substituted. Every expression must be accounted for, so an edit
# to the example's config cannot slip past this suite. The task as a whole is
# checked against Kargo's step schemas by oci/test/lint-task.py.

EXAMPLE_TASK=""
EXAMPLE_APP=""

setup_file() {
  load helpers
  start_flux_cluster
  require helm yq python3 || return 1
  start_registry_forward
  # shellcheck disable=SC2153  # FAMILY_DIR is set by helpers.bash
  local app="$FAMILY_DIR/examples/flux-app" seed="$BATS_FILE_TMPDIR/flux-app"

  say 'publishing the example chart at 0.1.0 and 0.2.0'
  push_chart "$app/chart" 0.1.0 charts > /dev/null
  push_chart "$app/chart" 0.2.0 charts > /dev/null

  # A kept cluster holds the release from the last run, at 0.2.0: start over.
  kube -n flux-system delete kustomizations.kustomize.toolkit.fluxcd.io apps --ignore-not-found --wait > /dev/null
  kube -n flux-system delete helmreleases.helm.toolkit.fluxcd.io demo --ignore-not-found --wait > /dev/null

  # The repository as the example holds it, but pointing at this cluster's
  # registry — the one change the suite makes to it.
  rm -rf "$seed"
  cp -R "$app" "$seed"
  yqq -i ".spec.url = \"oci://$(registry)/charts\" | .spec.insecure = true" \
    "$seed/apps/demo/helmrepository.yaml"
  say 'seeding the example repository'
  git_seed flux-app main "$seed" > /dev/null

  yqq ".spec.url = \"$GIT_URL/flux-app.git\"" "$app/flux/gitrepository.yaml" | apply_yaml
  apply_yaml < "$app/flux/kustomization.yaml"
  say 'waiting for the example to install'
  kube -n flux-system wait --for=condition=Ready --timeout=300s \
    kustomizations.kustomize.toolkit.fluxcd.io/apps helmreleases.helm.toolkit.fluxcd.io/demo > /dev/null
}

teardown_file() {
  load helpers
  stop_registry_forward
  teardown_cluster
}

setup() {
  load helpers
  EXAMPLE_TASK="$STEP_DIR/examples/cluster-promotion-task.yaml"
  EXAMPLE_APP="$FAMILY_DIR/examples/flux-app"
}

lint_example() { # task.yaml
  LOG="$(python3 "$FAMILY_DIR/../oci/test/lint-task.py" "$BATS_TEST_DIRNAME/schemas" \
    <(yqq -o=json "$1") 2>&1)" && STATUS=0 || STATUS=$?
}

task_var() { # name — the task's default for a var
  yqq ".spec.vars[] | select(.name == \"$1\") | .value" "$EXAMPLE_TASK"
}

# The task's flux-reconcile config with every expression replaced by what
# Kargo would evaluate it to. Fails, naming it, on any expression not handled.
render_reconcile_config() { # pushed-commit chart-version
  local raw rendered name value
  raw="$(yqq -o=json '.spec.steps[] | select(.uses == "flux-reconcile") | .config' "$EXAMPLE_TASK")"
  rendered="$(jqq -n --argjson c "$raw" \
    --rawfile kc "$BATS_FILE_TMPDIR/step.kubeconfig" \
    --arg commit "$1" --arg version "$2" '
    $c | walk(if type == "string" then
      if . == "${{ secret(vars.fluxCredentials).kubeconfig }}" then $kc
      elif . == "${{ task.outputs.push.commit }}" then $commit
      elif . == "${{ chartFrom(vars.chartRepoURL).Version }}" then $version
      else . end
    else . end)')"
  for name in kustomization helmRelease fluxNamespace; do
    value="$(task_var "$name")"
    rendered="$(printf '%s' "$rendered" | jqq --arg e "\${{ vars.$name }}" --arg v "$value" \
      'walk(if . == $e then $v else . end)')"
  done
  if printf '%s' "$rendered" | grep -qF '${{'; then
    printf 'unhandled expression in the example config: %s\n' \
      "$(printf '%s' "$rendered" | grep -oF '${{' -m1 || true)" >&2
    printf '%s\n' "$rendered" | grep -F '${{' >&2
    return 1
  fi
  printf '%s' "$rendered"
}

@test 'the example task lints clean against the step schemas' {
  lint_example "$EXAMPLE_TASK"
  [ "$STATUS" = 0 ] || {
    printf 'lint findings:\n%s\n' "$LOG"
    return 1
  }
}

@test 'the linter does check the flux-reconcile config (negative control)' {
  local broken="$BATS_TEST_TMPDIR/broken.yaml"
  yqq '(.spec.steps[] | select(.uses == "flux-reconcile") | .config.targets[0]) |= (.desiredRevison = .desiredRevision | del(.desiredRevision) | .kind = "Application")' \
    "$EXAMPLE_TASK" > "$broken"
  lint_example "$broken"
  [ "$STATUS" = 1 ] || {
    printf 'expected findings, got none; the linter is not checking this step\n'
    return 1
  }
  printf '%s' "$LOG" | grep -qF "unknown key 'desiredRevison'" || {
    printf 'missing the unknown-key finding:\n%s\n' "$LOG"
    return 1
  }
  printf '%s' "$LOG" | grep -qF '"Application" is not one of' || {
    printf 'missing the enum finding:\n%s\n' "$LOG"
    return 1
  }
}

@test 'the example Stage passes every var the task requires' {
  local required passed name
  required="$(yqq '.spec.vars[] | select(has("value") | not) | .name' "$EXAMPLE_TASK")"
  passed="$(yqq '.spec.promotionTemplate.spec.steps[0].vars[].name' "$STEP_DIR/examples/stage.yaml")"
  for name in $required; do
    printf '%s\n' "$passed" | grep -qxF "$name" || {
      printf 'the Stage does not pass %s, which the task requires\n' "$name"
      return 1
    }
  done
  assert_equal "$(yqq '.spec.promotionTemplate.spec.steps[0].task.name' "$STEP_DIR/examples/stage.yaml")" \
    "$(yqq '.metadata.name' "$EXAMPLE_TASK")" 'the task the Stage calls'
}

@test 'the example Secret holds what the task reads from it' {
  local secret="$STEP_DIR/examples/kargo-secret.yaml"
  assert_equal "$(yqq '.metadata.name' "$secret")" "$(task_var fluxCredentials)" 'the Secret name'
  assert_equal "$(yqq '.metadata.labels["kargo.akuity.io/cred-type"]' "$secret")" generic \
    'the credential type secret() can read'
  assert_equal "$(yqq '.stringData | has("kubeconfig")' "$secret")" true 'the kubeconfig key'
}

@test 'promoting 0.2.0 as the example task does upgrades the release through the Kustomization' {
  local file="$BATS_TEST_TMPDIR/helmrelease.yaml" path sha config
  path="$(task_var helmReleasePath)"
  # What yaml-update and git-commit/git-push do.
  yqq '.spec.chart.spec.version = "0.2.0"' "$EXAMPLE_APP/$path" > "$file"
  sha="$(git_write flux-app main "$path" < "$file")"
  CONTEXT="pushed $sha"

  config="$(render_reconcile_config "$sha" 0.2.0)"
  run_step "$config"
  assert_status 0
  assert_jq '.targets[0].kind' Kustomization
  assert_jq '.targets[0].revision' "main@sha1:$sha"
  assert_jq '.targets[1].kind' HelmRelease
  assert_jq '.targets[1].revision' 0.2.0
  # The Kustomization waits, and Helm waits: both targets were health-checked,
  # which the task passes on through compose-output.
  assert_jq '.healthChecked' true
  assert_jq '.message | type' string
  assert_equal "$(kube -n demo get configmap -o json | jqq -r '[.items[].data.chartVersion // empty] | first')" \
    0.2.0 'the release in the cluster'
}
