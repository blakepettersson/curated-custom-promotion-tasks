#!/usr/bin/env bats
# Behavioural tests for the kyverno-validate step image. Requires bats and
# docker.
#
#   bats test/kyverno-validate.bats             against the locally built image
#   IMAGE=ghcr.io/…/kyverno-validate:v0.1.0 bats test/kyverno-validate.bats
#   bats --filter Audit test/kyverno-validate.bats   just the cases you debug
#
# Named explicitly rather than `bats test/`, which would sweep up
# e2e-chart.bats and need helm to render the example chart first.
#
# See helpers.bash for how a case drives the image.

setup() {
  load helpers
}

@test 'valid policies pass' {
  run_step '{"policies": "policies"}'
  assert_status 0
  assert_jq_true '.passed'
  assert_jq '.policyFileCount' 2
  assert_jq_true '.ruleCount > 0'
  assert_jq '.loadErrorCount' 0
  assert_jq_true '.applied == false'
}

@test 'a glob is expanded' {
  run_step '{"policies": "policies/*-tag.yaml"}'
  assert_status 0
  assert_jq '.policyFileCount' 1
}

# The workspace a promotion hands the step is whatever the step before it wrote,
# and in the e2e suite that is a directory bats made with a bare mkdir — so its
# mode is the developer's umask. At umask 077 the step, uid 65532, cannot
# traverse it: every path expands to nothing and the step reports being
# misconfigured, which is a true statement about the wrong thing. Verified
# against a 0700 directory on a Linux filesystem: exit 2, `no files matched
# path "policies"`.
#
# This case only *guards* that on Linux, which is where CI runs. A Docker
# Desktop or OrbStack VM remaps ownership on a bind mount from the host, so on
# macOS the step reads a 0700 directory regardless and this passes either way.
@test 'a workspace created under a restrictive umask is still readable' {
  local work="$BATS_TEST_TMPDIR/umask-077"
  (
    umask 077
    mkdir -p "$work/policies"
  )
  cp "$BATS_TEST_DIRNAME"/fixtures/policies/*.yaml "$work/policies/"
  run_step_in "$work" '{"policies": "policies"}'
  assert_status 0
  assert_jq '.policyFileCount' 2
}

@test 'a list of paths is accepted' {
  run_step '{"policies": ["policies/disallow-latest-tag.yaml", "policies/require-allowed-repos.yaml"]}'
  assert_status 0
  assert_jq '.policyFileCount' 2
}

@test 'unloadable policies fail with per-file reasons' {
  run_step '{"policies": "broken"}'
  assert_status 1
  assert_jq '.passed' false
  assert_jq '.loadErrorCount' 4
  assert_jq_true '[.loadErrors[].file] | contains(["broken/unknown-field.yaml"])'
  assert_jq_true '.loadErrors[] | select(.file == "broken/unknown-field.yaml") | .error | test("unknown field")'
  assert_jq_true '.loadErrors[] | select(.file == "broken/invalid-yaml.yaml") | .error | test("failed to parse")'
  assert_jq_true '.loadErrors[] | select(.file == "broken/invalid-enum.yaml") | .error | test("Unsupported value")'
  assert_jq_true '.loadErrors[] | select(.file == "broken/no-rules.yaml") | .error | test("no policy rules")'
}

@test 'one bad file in a directory does not silently disable the rest' {
  # `kyverno apply <dir>` skips the whole directory and exits 0 in this case.
  run_step '{"policies": "mixed"}'
  assert_status 1
  assert_jq '.loadErrorCount' 1
  assert_jq_true '.ruleCount > 0'
}

@test 'exclude skips a known-bad file' {
  run_step '{"policies": "mixed", "exclude": "unknown-field.yaml"}'
  assert_status 0
  assert_jq '.loadErrorCount' 0
  assert_jq '.policyFileCount' 1
}

@test 'manifests without policies are reported as missing policies' {
  run_step '{"policies": "not-a-policy.yaml"}'
  assert_status 1
  assert_jq_true '.message | test("no Kyverno policy rules")'
}

@test 'requirePolicies: false tolerates manifests without policies' {
  run_step '{"policies": "not-a-policy.yaml", "requirePolicies": false}'
  assert_status 0
  assert_jq '.ruleCount' 0
}

@test 'a violating manifest fails the step' {
  run_step '{"policies": "policies", "manifests": "resources/violating-pod.yaml"}'
  assert_status 1
  assert_jq_true '.applied'
  assert_jq_true '.violationCount > 0'
  assert_jq_true '[.violations[].policy] | contains(["allowed-repos"])'
  assert_jq_true '.summary.fail > 0'
  assert_log 'allowed-repos'
}

@test 'resources is accepted as an alias for manifests' {
  run_step '{"policies": "policies", "resources": "resources/violating-pod.yaml"}'
  assert_status 1
  assert_jq_true '.applied'
}

@test 'a compliant manifest passes the step' {
  run_step '{"policies": "policies", "manifests": "resources/compliant-pod.yaml"}'
  assert_status 0
  assert_jq_true '.passed'
  assert_jq_true '.summary.pass > 0'
  assert_jq '.summary.fail' 0
}

@test 'failOn: none reports violations without failing' {
  run_step '{"policies": "policies", "manifests": "resources/violating-pod.yaml", "failOn": "none"}'
  assert_status 0
  assert_jq_true '.passed'
  assert_jq_true '.violationCount > 0'
}

# One case per spelling and action; see assert_violation_is_fail_not_warn.

@test 'Audit at policy level is a fail result, never a warn' {
  assert_violation_is_fail_not_warn audit-legacy
}

@test 'Enforce at policy level is a fail result, never a warn' {
  assert_violation_is_fail_not_warn enforce-legacy
}

@test 'Audit per rule is a fail result, never a warn' {
  assert_violation_is_fail_not_warn audit-rule
}

@test 'Enforce per rule is a fail result, never a warn' {
  assert_violation_is_fail_not_warn enforce-rule
}

@test 'failOn is what makes an Audit policy advisory, not the policy itself' {
  run_step '{"policies": "failure-action/audit-legacy.yaml", "manifests": "resources/violating-pod.yaml", "failOn": "none"}'
  assert_status 0
  assert_jq_true '.passed'
  assert_jq_true '.violationCount > 0'
}

@test 'failOn: warn does not rescue an Audit-mode violation' {
  run_step '{"policies": "failure-action/audit-legacy.yaml", "manifests": "resources/violating-pod.yaml", "failOn": "warn"}'
  assert_status 1
  assert_jq '.passed' false
}

@test 'kyverno test suites run' {
  run_step '{"policies": "suite", "tests": "suite"}'
  assert_status 0
  assert_jq_true '.tested'
  assert_log 'Test Summary: 1 tests passed'
}

@test 'a policy that contributes no rules is a load error' {
  # `kyverno apply` accepts it, reports zero rules and exits 0.
  run_step '{"policies": "broken/no-rules.yaml"}'
  assert_status 1
  assert_jq '.loadErrorCount' 1
  assert_jq_true '.loadErrors[0].error | test("no policy rules")'
}

@test 'a CRD Kyverno does not know is skipped, not failed' {
  run_step '{"policies": ["unknown-crd.yaml", "policies/disallow-latest-tag.yaml"]}'
  assert_status 0
  assert_jq '.loadErrorCount' 0
  assert_jq '.nonPolicyFileCount' 1
  assert_jq_true '.ruleCount > 0'
}

@test 'a PolicyException among the policies is skipped, not failed' {
  run_step '{"policies": ["policy-exception.yaml", "policies/disallow-latest-tag.yaml"]}'
  assert_status 0
  assert_jq '.loadErrorCount' 0
  assert_jq '.nonPolicyFileCount' 1
}

@test 'one missing path among several is a configuration error' {
  run_step '{"policies": ["policies", "does-not-exist"]}'
  assert_status 2
  assert_log 'no files matched'
}

@test 'one missing manifest path among several is a configuration error' {
  run_step '{"policies": "policies", "manifests": ["resources/compliant-pod.yaml", "does-not-exist"]}'
  assert_status 2
  assert_log 'no files matched'
}

@test 'an exclude glob is matched against the policy paths, not the working directory' {
  run_step '{"policies": "mixed", "exclude": "*-field.yaml"}'
  assert_status 0
  assert_jq '.loadErrorCount' 0
  assert_jq '.policyFileCount' 1
}

@test 'manifests no policy matches produce an empty report, not a failure' {
  run_step '{"policies": "policies", "manifests": "service.yaml"}'
  assert_status 0
  assert_jq_true '.passed'
  assert_jq_true '.applied'
  assert_jq '.summary.pass' 0
  assert_jq '.summary.fail' 0
  assert_log 'no policy matched the given manifests'
}

@test 'a tolerated violation is not reported as compliance' {
  run_step '{"policies": "policies", "manifests": "resources/violating-pod.yaml", "failOn": "none"}'
  assert_status 0
  assert_jq_true '.message | test("tolerated by failOn: none")'
  assert_jq_true '.message | test("comply") | not'
}

@test 'skipping the apply phase is stated in the message' {
  run_step '{"policies": "not-a-policy.yaml", "requirePolicies": false, "manifests": "resources/violating-pod.yaml"}'
  assert_status 0
  assert_jq '.applied' false
  assert_jq_true '.message | test("manifests were not checked")'
}

@test 'a null config reports the missing key once' {
  run_step 'null'
  assert_status 2
  assert_log 'config.policies is required'
  assert_log_count 'is not valid JSON' 0
}

@test 'a config that is not an object is rejected' {
  run_step '[]'
  assert_status 2
  assert_log 'must be a JSON object'
}

@test 'missing config.policies is a configuration error' {
  run_step '{}'
  assert_status 2
  assert_log 'config.policies is required'
}

@test 'a path that matches nothing is a configuration error' {
  run_step '{"policies": "does-not-exist/*.yaml"}'
  assert_status 2
  assert_log 'no files matched'
}

@test 'an invalid failOn is a configuration error' {
  run_step '{"policies": "policies", "failOn": "sometimes"}'
  assert_status 2
  assert_log 'config.failOn must be one of'
}
