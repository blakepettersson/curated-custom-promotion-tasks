#!/usr/bin/env bash
# Behavioural tests for the kyverno-validate step image. Requires docker.
#
#   IMAGE=kyverno-validate:dev ./test/run.sh
#
# Each case runs the image the way Kargo does — fixtures mounted as the working
# directory, config in KYVERNO_VALIDATE_CONFIG, results collected from the file
# named by KARGO_OUTPUT — then asserts on the exit code and that JSON.

set -uo pipefail

IMAGE="${IMAGE:-kyverno-validate:dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FIXTURES="$HERE/fixtures"
OUTDIR="$(mktemp -d)"
chmod 777 "$OUTDIR"
trap 'rm -rf "$OUTDIR"' EXIT

PASSES=0
FAILURES=0
CASE=""
STATUS=0
OUTPUT=""
LOG=""

jqq() {
  if command -v jq > /dev/null 2>&1; then
    jq "$@"
  else
    docker run --rm -i --entrypoint jq "$IMAGE" "$@"
  fi
}

run_step() { # config-json
  : > "$OUTDIR/output.json"
  chmod 666 "$OUTDIR/output.json"
  LOG="$(
    docker run --rm \
      -v "$FIXTURES:/workdir:ro" \
      -v "$OUTDIR:/out" \
      -w /workdir \
      -e KYVERNO_VALIDATE_CONFIG="$1" \
      -e KARGO_OUTPUT=/out/output.json \
      "$IMAGE" 2>&1
  )"
  STATUS=$?
  OUTPUT="$(cat "$OUTDIR/output.json")"
}

start() {
  CASE="$1"
  printf '\n\033[1m• %s\033[0m\n' "$CASE"
}

ok() {
  PASSES=$((PASSES + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

bad() {
  FAILURES=$((FAILURES + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  printf '    step exit code: %s\n' "$STATUS"
  printf '    step output:    %s\n' "${OUTPUT:-<empty>}"
  printf '    step log:\n%s\n' "$(printf '%s\n' "$LOG" | sed 's/^/      /')"
}

expect_status() { # expected
  if [ "$STATUS" = "$1" ]; then ok "exit code $1"; else bad "expected exit code $1, got $STATUS"; fi
}

expect_jq() { # filter expected
  local actual
  actual="$(printf '%s' "$OUTPUT" | jqq -r "$1" 2> /dev/null)"
  if [ "$actual" = "$2" ]; then
    ok "$1 == $2"
  else
    bad "expected $1 to be \"$2\", got \"$actual\""
  fi
}

expect_jq_true() { # filter
  expect_jq "$1" true
}

expect_log_count() { # substring expected-count
  local actual
  actual="$(printf '%s\n' "$LOG" | grep -cF -- "$1")"
  if [ "$actual" = "$2" ]; then
    ok "log mentions \"$1\" $2 time(s)"
  else
    bad "expected log to mention \"$1\" $2 time(s), got $actual"
  fi
}

expect_log() { # substring
  if printf '%s' "$LOG" | grep -qF -- "$1"; then
    ok "log contains \"$1\""
  else
    bad "expected log to contain \"$1\""
  fi
}

# ---------------------------------------------------------------------------

start 'valid policies pass'
run_step '{"policies": "policies"}'
expect_status 0
expect_jq_true '.passed'
expect_jq '.policyFileCount' 2
expect_jq_true '.ruleCount > 0'
expect_jq '.loadErrorCount' 0
expect_jq_true '.applied == false'

start 'a glob is expanded'
run_step '{"policies": "policies/*-tag.yaml"}'
expect_status 0
expect_jq '.policyFileCount' 1

start 'a list of paths is accepted'
run_step '{"policies": ["policies/disallow-latest-tag.yaml", "policies/require-allowed-repos.yaml"]}'
expect_status 0
expect_jq '.policyFileCount' 2

start 'unloadable policies fail with per-file reasons'
run_step '{"policies": "broken"}'
expect_status 1
expect_jq '.passed' false
expect_jq '.loadErrorCount' 4
expect_jq_true '[.loadErrors[].file] | contains(["broken/unknown-field.yaml"])'
expect_jq_true '.loadErrors[] | select(.file == "broken/unknown-field.yaml") | .error | test("unknown field")'
expect_jq_true '.loadErrors[] | select(.file == "broken/invalid-yaml.yaml") | .error | test("failed to parse")'
expect_jq_true '.loadErrors[] | select(.file == "broken/invalid-enum.yaml") | .error | test("Unsupported value")'
expect_jq_true '.loadErrors[] | select(.file == "broken/no-rules.yaml") | .error | test("no policy rules")'

start 'one bad file in a directory does not silently disable the rest'
# `kyverno apply <dir>` skips the whole directory and exits 0 in this case.
run_step '{"policies": "mixed"}'
expect_status 1
expect_jq '.loadErrorCount' 1
expect_jq_true '.ruleCount > 0'

start 'exclude skips a known-bad file'
run_step '{"policies": "mixed", "exclude": "unknown-field.yaml"}'
expect_status 0
expect_jq '.loadErrorCount' 0
expect_jq '.policyFileCount' 1

start 'manifests without policies are reported as missing policies'
run_step '{"policies": "not-a-policy.yaml"}'
expect_status 1
expect_jq_true '.message | test("no Kyverno policy rules")'

start 'requirePolicies: false tolerates manifests without policies'
run_step '{"policies": "not-a-policy.yaml", "requirePolicies": false}'
expect_status 0
expect_jq '.ruleCount' 0

start 'a violating manifest fails the step'
run_step '{"policies": "policies", "manifests": "resources/violating-pod.yaml"}'
expect_status 1
expect_jq_true '.applied'
expect_jq_true '.violationCount > 0'
expect_jq_true '[.violations[].policy] | contains(["allowed-repos"])'
expect_jq_true '.summary.fail > 0'
expect_log 'allowed-repos'

start 'resources is accepted as an alias for manifests'
run_step '{"policies": "policies", "resources": "resources/violating-pod.yaml"}'
expect_status 1
expect_jq_true '.applied'

start 'a compliant manifest passes the step'
run_step '{"policies": "policies", "manifests": "resources/compliant-pod.yaml"}'
expect_status 0
expect_jq_true '.passed'
expect_jq_true '.summary.pass > 0'
expect_jq '.summary.fail' 0

start 'failOn: none reports violations without failing'
run_step '{"policies": "policies", "manifests": "resources/violating-pod.yaml", "failOn": "none"}'
expect_status 0
expect_jq_true '.passed'
expect_jq_true '.violationCount > 0'

start 'kyverno test suites run'
run_step '{"policies": "suite", "tests": "suite"}'
expect_status 0
expect_jq_true '.tested'
expect_log 'Test Summary: 1 tests passed'

start 'a policy that contributes no rules is a load error'
# `kyverno apply` accepts it, reports zero rules and exits 0.
run_step '{"policies": "broken/no-rules.yaml"}'
expect_status 1
expect_jq '.loadErrorCount' 1
expect_jq_true '.loadErrors[0].error | test("no policy rules")'

start 'a CRD Kyverno does not know is skipped, not failed'
run_step '{"policies": ["unknown-crd.yaml", "policies/disallow-latest-tag.yaml"]}'
expect_status 0
expect_jq '.loadErrorCount' 0
expect_jq '.nonPolicyFileCount' 1
expect_jq_true '.ruleCount > 0'

start 'a PolicyException among the policies is skipped, not failed'
run_step '{"policies": ["policy-exception.yaml", "policies/disallow-latest-tag.yaml"]}'
expect_status 0
expect_jq '.loadErrorCount' 0
expect_jq '.nonPolicyFileCount' 1

start 'one missing path among several is a configuration error'
run_step '{"policies": ["policies", "does-not-exist"]}'
expect_status 2
expect_log 'no files matched'

start 'one missing manifest path among several is a configuration error'
run_step '{"policies": "policies", "manifests": ["resources/compliant-pod.yaml", "does-not-exist"]}'
expect_status 2
expect_log 'no files matched'

start 'an exclude glob is matched against the policy paths, not the working directory'
run_step '{"policies": "mixed", "exclude": "*-field.yaml"}'
expect_status 0
expect_jq '.loadErrorCount' 0
expect_jq '.policyFileCount' 1

start 'manifests no policy matches produce an empty report, not a failure'
run_step '{"policies": "policies", "manifests": "service.yaml"}'
expect_status 0
expect_jq_true '.passed'
expect_jq_true '.applied'
expect_jq '.summary.pass' 0
expect_jq '.summary.fail' 0
expect_log 'no policy matched the given manifests'

start 'a tolerated violation is not reported as compliance'
run_step '{"policies": "policies", "manifests": "resources/violating-pod.yaml", "failOn": "none"}'
expect_status 0
expect_jq_true '.message | test("tolerated by failOn: none")'
expect_jq_true '.message | test("comply") | not'

start 'skipping the apply phase is stated in the message'
run_step '{"policies": "not-a-policy.yaml", "requirePolicies": false, "manifests": "resources/violating-pod.yaml"}'
expect_status 0
expect_jq '.applied' false
expect_jq_true '.message | test("manifests were not checked")'

start 'a null config reports the missing key once'
run_step 'null'
expect_status 2
expect_log 'config.policies is required'
expect_log_count 'is not valid JSON' 0

start 'a config that is not an object is rejected'
run_step '[]'
expect_status 2
expect_log 'must be a JSON object'

start 'missing config.policies is a configuration error'
run_step '{}'
expect_status 2
expect_log 'config.policies is required'

start 'a path that matches nothing is a configuration error'
run_step '{"policies": "does-not-exist/*.yaml"}'
expect_status 2
expect_log 'no files matched'

start 'an invalid failOn is a configuration error'
run_step '{"policies": "policies", "failOn": "sometimes"}'
expect_status 2
expect_log 'config.failOn must be one of'

# ---------------------------------------------------------------------------

printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASSES" "$FAILURES"
[ "$FAILURES" = 0 ]
