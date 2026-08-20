# Example Kyverno policy chart

A small Helm chart of Kyverno policies with the manifests to validate against
them. It stands in for the repository a Kargo project would promote, and it is
what `../../steps/kyverno-validate/test/e2e-chart.bats` exercises.

```
chart/                    Helm chart: the allowed-repos ClusterPolicy, values, prod overlay
manifests/                manifests that must pass
counterexamples/          manifests that must be rejected
```

Render and validate it the way the promotion does:

```console
helm template kyverno-policies chart --output-dir /tmp/rendered
docker run --rm -v /tmp:/workdir -v "$PWD:/example:ro" -w /workdir \
  -e KYVERNO_VALIDATE_CONFIG='{"policies": "rendered", "manifests": "/example/manifests"}' \
  kyverno-validate:dev
```

`manifests/excluded-namespace-pod.yaml` uses an image the policy disallows but
lives in an excluded namespace, so the policy's precondition skips it — the
rendered output is checked, preconditions and all, not just the templating.
