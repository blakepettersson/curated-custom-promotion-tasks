# Kyverno promotion steps

Kargo custom promotion steps for [Kyverno](https://kyverno.io), with the
`CustomPromotionStep` manifests that register them and the promotion tasks that
compose them. See the [repository README](../README.md) for the conventions all
step families share.

## Catalog

| Step | What it does |
|---|---|
| [`kyverno-validate`](steps/kyverno-validate) | Validates Kyverno policies with the Kyverno CLI and checks manifests against them. Takes a policies path and a manifests path; fails the promotion on an unloadable policy or a violating manifest. |

## Layout

```
steps/<name>/
  Dockerfile                   image for the step
  src/                         the step's entrypoint script and its data files
  custom-promotion-step.yaml   registers the step with a Kargo cluster
  examples/                    promotion task and stage showing the step in use
  test/                        behaviour tests driven the way Kargo drives the image
examples/kyverno-policies/     a Helm chart of policies plus manifests, used by the tests
```

## Using a step

Register it once per cluster (a cluster-admin action). Both resources are
cluster-scoped and go in through the Kargo API — custom steps are an Akuity
Platform feature, so there is no control plane to `kubectl apply` against:

```console
kargo login https://<your-kargo-instance>
kargo apply -f steps/kyverno-validate/custom-promotion-step.yaml
kargo apply -f steps/kyverno-validate/examples/cluster-promotion-task.yaml
```

Then reference it from a promotion template, by name, like a built-in step:

```yaml
steps:
  - uses: kyverno-validate
    as: validate
    config:
      policies: ./rendered
      manifests: ./src/manifests
```

Or reference the `ClusterPromotionTask` that renders a policy chart and validates
it in one go — see
[`steps/kyverno-validate/examples/stage.yaml`](steps/kyverno-validate/examples/stage.yaml).

## Development

Run from this directory:

```console
make all       # lint, build, test, e2e
make test      # behaviour tests against a locally built image
```

`make test` needs docker; `make e2e` also needs helm.

## CI

[`../.github/workflows/kyverno-validate.yaml`](../.github/workflows/kyverno-validate.yaml)
lints the step script, builds the image, runs both test suites against the image
it just built, and only then publishes:

| Trigger | Result |
|---|---|
| pull request | lint and test only |
| push to `main` | `:main`, `:sha-<short sha>` |
| tag `kyverno-validate/v1.2.3` | `:v1.2.3`, `:v1.2`, `:latest` |

Images are published to
`ghcr.io/blakepettersson/curated-custom-promotion-tasks/kyverno-validate` for
`linux/amd64` and `linux/arm64`, with SBOM and provenance attestations, and
signed with cosign (keyless). Pin a released tag or a digest in the
`CustomPromotionStep` manifest for production use.
