#!/usr/bin/env bats
# End-to-end checks against kyverno/examples/kyverno-policies: render the chart
# with Helm exactly as the `helm-template` promotion step would, then validate
# the output with the step image. So the cases below run against real rendered
# input rather than hand-written manifests. Requires bats, docker and helm.
#
#   bats test/e2e-chart.bats
#
# Both renders happen once in setup_file and are shared by every case.

setup_file() {
  command -v helm > /dev/null || {
    printf 'helm is required for the e2e checks\n' >&2
    return 1
  }
  local example
  example="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/examples/kyverno-policies"

  helm template kyverno-policies "$example/chart" \
    --output-dir "$BATS_FILE_TMPDIR/rendered" > /dev/null

  # A bad Helm value renders a policy that Kyverno rejects. `kyverno apply`
  # would skip it and exit 0; the step has to catch it.
  helm template kyverno-policies "$example/chart" \
    --set validate.allowedRepos.validationFailureAction=Bogus \
    --output-dir "$BATS_FILE_TMPDIR/rendered-bad-values" > /dev/null
}

setup() {
  load helpers
  EXAMPLE="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/examples/kyverno-policies"
}

# The rendered output is the working directory, so `policies` is a path within
# it; the example project is mounted alongside for its manifests.
render_step() { # config-json
  run_step_in "$BATS_FILE_TMPDIR" "$1" -v "$EXAMPLE:/example:ro"
}

@test 'compliant manifests pass against the rendered chart' {
  render_step '{"policies": "rendered", "manifests": "/example/manifests"}'
  assert_status 0
  assert_jq_true '.passed'
  assert_jq '.loadErrorCount' 0
  assert_jq_true '.ruleCount > 0'
}

@test 'the counterexample manifest is rejected' {
  render_step '{"policies": "rendered", "manifests": "/example/counterexamples"}'
  assert_status 1
  assert_jq '.passed' false
  assert_jq_true '.violationCount > 0'
}

@test 'the counterexample is reported but tolerated with failOn: none' {
  render_step '{"policies": "rendered", "manifests": "/example/counterexamples", "failOn": "none"}'
  assert_status 0
  assert_jq_true '.passed'
  assert_jq_true '.violationCount > 0'
}

@test 'an invalid value in the chart is caught' {
  render_step '{"policies": "rendered-bad-values", "manifests": "/example/manifests"}'
  assert_status 1
  assert_jq_true '.loadErrorCount > 0'
}
