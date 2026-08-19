#!/usr/bin/env bash
# End-to-end check against kyverno/examples/kyverno-policies: render the chart with Helm
# exactly as the `helm-template` promotion step would, then validate the output
# with the step image. Requires docker and helm.
#
#   IMAGE=kyverno-validate:dev ./test/e2e-chart.sh

set -uo pipefail

IMAGE="${IMAGE:-kyverno-validate:dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$(cd "$HERE/../../.." && pwd)"
EXAMPLE="$BASE/examples/kyverno-policies"

WORK="$(mktemp -d)"
chmod 777 "$WORK"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

render() { # out-subdir [helm args...]
  local out="$WORK/$1"
  shift
  rm -rf "$out"
  helm template kyverno-policies "$EXAMPLE/chart" --output-dir "$out" "$@" > /dev/null
}

validate() { # config-json
  docker run --rm \
    -v "$WORK:/workdir" \
    -v "$EXAMPLE:/example:ro" \
    -w /workdir \
    -e KYVERNO_VALIDATE_CONFIG="$1" \
    -e KARGO_OUTPUT=/workdir/output.json \
    "$IMAGE"
}

check() { # description expected-status config-json
  local description="$1" expected="$2" config="$3" status
  printf '\n\033[1m• %s\033[0m\n' "$description"
  validate "$config" | sed 's/^/    /'
  status="${PIPESTATUS[0]}"
  if [ "$status" = "$expected" ]; then
    printf '  \033[32m✓\033[0m exit code %s\n' "$status"
  else
    printf '  \033[31m✗\033[0m expected exit code %s, got %s\n' "$expected" "$status"
    FAILURES=$((FAILURES + 1))
  fi
}

render rendered
check 'compliant manifests pass against the rendered chart' 0 \
  '{"policies": "rendered", "manifests": "/example/manifests"}'

check 'the counterexample manifest is rejected' 1 \
  '{"policies": "rendered", "manifests": "/example/counterexamples"}'

check 'the counterexample is reported but tolerated with failOn: none' 0 \
  '{"policies": "rendered", "manifests": "/example/counterexamples", "failOn": "none"}'

# A bad Helm value renders a policy that Kyverno rejects. `kyverno apply` would
# skip it and exit 0; the step has to catch it.
render rendered-bad-values --set validate.allowedRepos.validationFailureAction=Bogus
check 'an invalid value in the chart is caught' 1 \
  '{"policies": "rendered-bad-values", "manifests": "/example/manifests"}'

printf '\n'
if [ "$FAILURES" = 0 ]; then
  printf '\033[1mall e2e checks passed\033[0m\n'
else
  printf '\033[1m%s e2e check(s) failed\033[0m\n' "$FAILURES"
fi
[ "$FAILURES" = 0 ]
