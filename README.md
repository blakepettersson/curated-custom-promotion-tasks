# Curated Kargo promotion steps and tasks

Reusable pieces for [Kargo](https://kargo.io) promotions, in two flavours:

- **Custom promotion steps** — a container image, the `CustomPromotionStep`
  manifest that registers it, the promotion tasks that compose it, and CI that
  builds, tests and publishes the image.
- **Promotion tasks** — `ClusterPromotionTask` manifests composed entirely of
  Kargo's *built-in* steps. Nothing to build, nothing to publish; the YAML is
  the deliverable.

Custom steps require Kargo on the
[Akuity Platform](https://akuity.io/akuity-platform) v1.10 or newer, with the
Promotion Controller enabled and a self-hosted agent, since each step runs as a
pod. Task-only families have no such requirement beyond the steps they use —
though the `oci/` tasks need a Kargo newer than any current release, for the
reason its README gives.

## Families

One directory per tool, each self-contained with its own examples, tests and
`Makefile`.

| Family | Contents |
|---|---|
| [`kyverno/`](kyverno) | [`kyverno-validate`](kyverno/steps/kyverno-validate) — validates Kyverno policies with the Kyverno CLI and checks manifests against them |
| [`oci/`](oci) | [`hydrate-helm-to-oci`](oci/tasks/hydrate-helm-to-oci), [`hydrate-kustomize-to-oci`](oci/tasks/hydrate-kustomize-to-oci) — render manifests and publish them as an OCI artifact; [`deploy-oci-to-argocd`](oci/tasks/deploy-oci-to-argocd) — sync an Argo CD Application to one |

A family holds `steps/` when it ships images, `tasks/` when it ships YAML, or
both.

```
<family>/
  Makefile                       lint, test, e2e (and build, for a step family)
  steps/<name>/                  one custom promotion step
    Dockerfile                   image for the step
    src/                         the step's entrypoint script and its data files
    custom-promotion-step.yaml   registers the step with a Kargo cluster
    examples/                    promotion task and stage showing the step in use
    test/                        behaviour tests driven the way Kargo drives the image
  tasks/<name>/                  one promotion task built from built-in steps
    cluster-promotion-task.yaml  the task itself
    examples/                    stage, warehouse and any resources it expects
  test/                          the family's suites, for a task family
  examples/                      fixtures a real project would hold, used by the tests
.github/workflows/<name>.yaml    one workflow per step or task family
```

## CI

One workflow per step, and one per task family.

A **step** workflow lints, builds the image, runs the step's test suites against
the image it just built, and only then publishes to
`ghcr.io/<owner>/<repo>/<step name>` for `linux/amd64` and `linux/arm64` — with
SBOM and provenance attestations, signed with cosign (keyless).

| Trigger | Result |
|---|---|
| pull request | lint and test only |
| push to `main` | `:main`, `:sha-<short sha>` |
| tag `<step name>/v1.2.3` | `:v1.2.3`, `:v1.2`, `:latest` |

Pin a released tag or a digest in the `CustomPromotionStep` manifest for
production use.

A **task** workflow lints and tests, and has no publish job: there is no
artifact, so a merge to `main` is the release.

## Adding a step

Steps ship an image. For a task built only from Kargo's built-in steps, see
[Adding a task](#adding-a-task) below.

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

## Adding a task

A task that composes only built-in steps needs no image and no registry, so most
of the list above does not apply. What is left:

1. Create `<family>/tasks/<name>/cluster-promotion-task.yaml` plus an
   `examples/` directory holding a `Stage`, a `Warehouse`, and whatever else the
   task expects to exist. The examples are the documentation people will copy,
   so keep them runnable.
2. Give every step an `as` alias, reference an earlier step's output as
   `task.outputs.<alias>` — inside a task, plain `outputs` does not resolve —
   and expose results to the caller with a final `compose-output` step.
3. Declare a var with no `value` to require it of the caller. Never give one
   `value: ""`: every string field in Kargo's step schemas is `minLength: 1`, so
   an empty default is rejected at promotion time rather than treated as absent.
4. Tasks cannot nest. Kargo validates a task's steps as
   `has(self.uses) && !has(self.task)`, so a two-part flow is two task
   references in the calling Stage.
5. Test it. [`oci/test/`](oci/test) has the pattern: check each task against
   Kargo's own step config schemas, vendored and pinned, and check each example
   against the task it calls. A task is YAML, so every mistake it can hold is
   one Kargo would otherwise report halfway through a release.
