# Curated Kargo custom promotion steps

Custom promotion steps for [Kargo](https://kargo.io) — container images plus the
`CustomPromotionStep` manifests that register them, the promotion tasks that
compose them, and CI that builds, tests and publishes the images.

Custom steps require Kargo on the
[Akuity Platform](https://akuity.io/akuity-platform) v1.10 or newer, with the
Promotion Controller enabled and a self-hosted agent, since each step runs as a
pod.

## Families

One directory per tool, each self-contained with its own steps, examples, tests
and `Makefile`.

| Family | Steps |
|---|---|
| [`kyverno/`](kyverno) | [`kyverno-validate`](kyverno/steps/kyverno-validate) — validates Kyverno policies with the Kyverno CLI and checks manifests against them |

```
<family>/
  Makefile                       build, lint, test, e2e for this family
  steps/<name>/                  one custom promotion step
    Dockerfile                   image for the step
    src/                         the step's entrypoint script and its data files
    custom-promotion-step.yaml   registers the step with a Kargo cluster
    examples/                    promotion task and stage showing the step in use
    test/                        behaviour tests driven the way Kargo drives the image
  examples/                      fixtures a real project would hold, used by the tests
.github/workflows/<step>.yaml    build, test, publish to ghcr.io
```

## CI

One workflow per step. Each lints, builds the image, runs the step's test suites
against the image it just built, and only then publishes to
`ghcr.io/<owner>/<repo>/<step name>` for `linux/amd64` and `linux/arm64` — with
SBOM and provenance attestations, signed with cosign (keyless).

| Trigger | Result |
|---|---|
| pull request | lint and test only |
| push to `main` | `:main`, `:sha-<short sha>` |
| tag `<step name>/v1.2.3` | `:v1.2.3`, `:v1.2`, `:latest` |

Pin a released tag or a digest in the `CustomPromotionStep` manifest for
production use.

## Adding a step

1. Create `<family>/steps/<name>/` following the layout above. Keep the image
   minimal: copy the tools you need out of upstream images rather than
   installing them, so the build stays free of `RUN` instructions and needs no
   emulation for `linux/arm64`.
2. Read config from a single JSON environment variable fed by
   `${{ asJSON(config) }}` — a missing key then costs nothing, and nested values
   survive. Kargo renders unset expressions as the literal string `<nil>`, which
   is why per-key `env` entries are more trouble than they look.
3. Write results as JSON to `$KARGO_OUTPUT` and declare
   `output.source: {type: Pipe, format: JSON}`. Kargo collects the output even
   when the step exits non-zero.
4. Exit non-zero to fail the promotion. The container runs as uid 65532 with no
   privileges and only the promotion workspace to write to.
5. Copy [`.github/workflows/kyverno-validate.yaml`](.github/workflows/kyverno-validate.yaml),
   changing the paths, the image name and the tag prefix.
