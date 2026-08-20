#!/usr/bin/env bash
# Helpers for the kyverno-validate behaviour tests, loaded by the .bats files.
#
# `run_step` drives the image exactly as Kargo does — fixtures mounted as the
# working directory, config in KYVERNO_VALIDATE_CONFIG, results read back from
# the file named by $KARGO_OUTPUT. The assertions then check the exit code and
# that JSON. Every assertion dumps the exit code, the output and the whole step
# log on failure; bats only shows it for the case that failed.

IMAGE="${IMAGE:-kyverno-validate:dev}"

# Set by run_step, read by the assertions below.
STATUS=0
OUTPUT=""
LOG=""

# jq is only needed on the host to read the step's output. Fall back to the
# copy inside the image so the suite runs on a machine without it.
jqq() {
  if command -v jq > /dev/null 2>&1; then
    jq "$@"
  else
    docker run --rm -i --entrypoint jq "$IMAGE" "$@"
  fi
}

# Runs the image with `workdir` as the promotion workspace. Any further
# arguments are passed to `docker run` — the e2e cases use that to mount the
# example project alongside their rendered output.
run_step_in() { # workdir config-json [docker args...]
  local workdir="$1" config="$2"
  shift 2
  local out="$BATS_TEST_TMPDIR/output.json"
  : > "$out"
  # The step runs as uid 65532 and has to be able to write its results.
  chmod 777 "$BATS_TEST_TMPDIR"
  chmod 666 "$out"
  # `&& STATUS=0 || STATUS=$?` keeps a non-zero exit — which most of these
  # cases expect — from tripping the `set -e` that bats runs tests under.
  LOG="$(
    docker run --rm \
      -v "$workdir:/workdir:ro" \
      -v "$BATS_TEST_TMPDIR:/out" \
      -w /workdir \
      -e KYVERNO_VALIDATE_CONFIG="$config" \
      -e KARGO_OUTPUT=/out/output.json \
      "$@" \
      "$IMAGE" 2>&1
  )" && STATUS=0 || STATUS=$?
  OUTPUT="$(cat "$out")"
}

run_step() { # config-json
  run_step_in "$BATS_TEST_DIRNAME/fixtures" "$1"
}

diagnose() { # message
  printf 'assertion failed: %s\n' "$1"
  printf '  step exit code: %s\n' "$STATUS"
  printf '  step output:    %s\n' "${OUTPUT:-<empty>}"
  printf '  step log:\n%s\n' "$(printf '%s\n' "$LOG" | sed 's/^/    /')"
}

assert_status() { # expected
  [ "$STATUS" = "$1" ] || {
    diagnose "expected exit code $1, got $STATUS"
    return 1
  }
}

assert_jq() { # filter expected
  local actual
  # `|| true`: bats runs tests under `set -e`, and a filter that errors on an
  # empty or unexpected document would abort the case before the comparison
  # below — losing the diagnostics that say why.
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

assert_log_count() { # substring expected-count
  local actual
  # `grep -c` exits 1 when the count is 0, which is a legitimate expectation
  # here; without `|| true` that would abort the case under `set -e`.
  actual="$(printf '%s\n' "$LOG" | grep -cF -- "$1" || true)"
  [ "$actual" = "$2" ] || {
    diagnose "expected log to mention \"$1\" $2 time(s), got $actual"
    return 1
  }
}

# `validationFailureAction` (policy level) and `validate.failureAction` (per
# rule) decide what an admission controller does about a breach in a live
# cluster. They do not soften how the CLI reports one: an Audit-mode violation
# is still a `fail` result, never a `warn`, and the step still fails. Shared by
# one case per spelling and action, since all four turn up in the wild.
assert_violation_is_fail_not_warn() { # fixture-basename
  run_step "{\"policies\": \"failure-action/$1.yaml\", \"manifests\": \"resources/violating-pod.yaml\"}"
  assert_status 1
  # Guards the assertions below: a fixture that stopped loading would skip the
  # apply phase and report zero of everything, passing for the wrong reason.
  assert_jq '.loadErrorCount' 0
  assert_jq_true '.ruleCount > 0'
  assert_jq_true '.summary.fail > 0'
  assert_jq '.summary.warn' 0
  assert_jq_true '.violationCount > 0'
  assert_jq_true '[.violations[].result] | contains(["fail"])'
}
