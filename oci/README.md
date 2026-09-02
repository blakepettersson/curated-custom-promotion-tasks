# OCI promotion tasks

Kargo promotion tasks that hydrate Helm charts and Kustomize overlays into OCI
artifacts, and that deploy those artifacts through Argo CD. See the
[repository README](../README.md) for the conventions all families share.

This family ships no images. Every task here composes Kargo's **built-in**
steps, so there is nothing to build, nothing to publish, and no
`CustomPromotionStep` to register — only `ClusterPromotionTask` manifests to
apply.

## Requirements

`oci-push`'s local-archive mode (`srcPath`) landed in
[akuity/kargo#6893](https://github.com/akuity/kargo/pull/6893) and is **not in a
released Kargo yet**. These tasks need a Kargo built from `main` at
`6c2a2a5` or later, and the version they are pinned against is recorded in
[`test/schemas/README.md`](test/schemas/README.md).

For the Argo CD side you need Argo CD with OCI source support, and an
`Application` annotated `kargo.akuity.io/authorized-stage`.

## Catalog

| Task | What it does |
|---|---|
| [`hydrate-helm-to-oci`](tasks/hydrate-helm-to-oci) | Renders a Helm chart from Git and publishes the manifests as an OCI artifact. |
| [`hydrate-kustomize-to-oci`](tasks/hydrate-kustomize-to-oci) | Builds a Kustomize overlay from Git and publishes the manifests as an OCI artifact. |
| [`deploy-oci-to-argocd`](tasks/deploy-oci-to-argocd) | Points an Argo CD Application's OCI source at a digest and waits for it to sync. |

## Why hydrate to OCI

The usual way to render manifests in Kargo is to commit them to a per-stage
branch and have Argo CD sync that branch. It works, and it leaves you
maintaining a branch per stage whose history is machine-written, whose diffs are
noise, and whose contents can be force-pushed away.

An OCI artifact gives you the same rendered manifests as a content-addressed
blob: immutable, digest-addressable, mirrorable into an airgap, and garbage
collectable by registry policy rather than by `git filter-repo`. Rendering and
deploying come apart — an artifact can sit in the registry, be inspected, and be
approved before anything points at it — and a rollback is a digest that is
already in the registry rather than a revert commit.

[Kokumi](https://kokumi.dev) is a whole delivery platform built on that idea.
These tasks are the same shape in a handful of Kargo steps.

## Using the tasks

Register them once per cluster (a cluster-admin action). `ClusterPromotionTask`
is cluster-scoped and goes in through the Kargo API:

```console
kargo login https://<your-kargo-instance>
kargo apply -f tasks/hydrate-helm-to-oci/cluster-promotion-task.yaml
kargo apply -f tasks/hydrate-kustomize-to-oci/cluster-promotion-task.yaml
kargo apply -f tasks/deploy-oci-to-argocd/cluster-promotion-task.yaml
```

Then reference one from a promotion template:

```yaml
steps:
  - task:
      name: hydrate-helm-to-oci
      kind: ClusterPromotionTask
    as: hydrate
    vars:
      - name: repoURL
        value: https://github.com/example/example-app.git
      - name: ociRepo
        value: ghcr.io/example/config/example-app
```

Each task's README lists its vars and outputs; each has an `examples/` directory
with a working `Stage`, `Warehouse` and — for the deploy task — the Argo CD
`Application` the task expects.

## Two shapes to choose between

**Hydrate and deploy in one promotion.** Every Stage renders its own manifests
and syncs its own Application. This is the simpler shape and where to start; see
[`tasks/hydrate-helm-to-oci/examples/stage.yaml`](tasks/hydrate-helm-to-oci/examples/stage.yaml).

**Hydrate once, deploy many times.** One Stage renders and publishes; downstream
Stages have a `Warehouse` subscribed to the artifact and promote the *rendered
output* rather than re-rendering it. Downstream can then never disagree with
what was tested, because it is deploying the identical bytes. See
[`tasks/deploy-oci-to-argocd/examples/`](tasks/deploy-oci-to-argocd/examples/).

## What these tasks get right, and why it is not obvious

Each of these is a way to build a green promotion that deploys nothing, or the
wrong thing. All of them are checked by the suites in [`test/`](test).

**`tar` defaults to `gzip: false`; `oci-push` defaults its layer media type to
`application/vnd.oci.image.layer.v1.tar+gzip`.** Omit `gzip: true` and you
publish a plain tar labelled as gzip. Both steps succeed, the registry accepts
it without complaint, and Argo CD's repo-server then fails to decompress the
layer. `test/lint-task.py` refuses a task whose archive and media type disagree.

**Argo CD reads only three layer media types by default** —
`application/vnd.oci.image.layer.v1.tar`, the `+gzip` form of it, and
`application/vnd.cncf.helm.chart.content.v1.tar+gzip`. Flux's media types, which
the Kargo docs show, need an operator to extend the repo-server's
`--oci-layer-media-types`. So the hydrate tasks leave `mediaType` and
`artifactType` unset and take `oci-push`'s defaults.

**`desiredRevision` must be a digest, not a tag.** Argo CD records the digest of
a synced OCI artifact as the Application's revision, and `argocd-update` waits
until that equals `desiredRevision`. Give it a tag and the step waits until the
promotion times out.

**The Argo CD source needs no `path`.** Kargo's `tar` step names entries
relative to `inPath` and skips the root directory entry, so the artifact unpacks
to a flat root of manifests rather than to a `manifests/` directory.

**A var with an empty default is not a var with no default.** Every string field
in these schemas is `minLength: 1`, so `value: ""` reaches the step as `""` and
is rejected. Omit `value` entirely to require it of the caller.

**An expression interpolated into surrounding text is always a string.**
`${{ vars.gzip }}` alone in a boolean field evaluates to a boolean, because
Kargo replaces a whole-value expression with the expression's typed result.
`"yes-${{ vars.gzip }}"` cannot.

**Tasks do not nest.** Kargo validates a `PromotionTask` step as
`has(self.uses) && !has(self.task)`, so hydrate-then-deploy is two task
references in the calling Stage, not one task calling another.

## Subscribing to hydrated manifests

There is no OCI-artifact subscription type; an `image` subscription is what
watches these artifacts, and it works because `oci-push` writes an
`application/vnd.oci.image.manifest.v1+json` manifest that Kargo's image
discovery accepts. Three constraints follow from these being artifacts rather
than images, and all three fail silently:

- **`imageSelectionStrategy: Digest`, following the mutable per-stage tag via
  `constraint`.** `NewestBuild` cannot work: the artifact carries no image
  config, so its creation time is the zero value for every artifact. `SemVer`
  and `Lexical` need version-shaped tags.
- **Never set `platform`.** Kargo collects platforms only from an image index. A
  single-manifest artifact reports none, so *any* platform constraint filters
  the artifact out and the Warehouse discovers nothing at all.
- **Do not stamp `org.opencontainers.image.created`** hoping to enable
  `NewestBuild`. The manifest digest is computed over the annotations, so a
  per-promotion timestamp makes the digest depend on the clock — and a retried
  promotion would then publish a different digest for identical content.

## Development

Run from this directory:

```console
make all       # lint, test, e2e
make test      # every task against Kargo's own step config schemas
make e2e       # render examples/example-app and push it to a throwaway registry
```

`make test` needs [bats](https://github.com/bats-core/bats-core), python3 and
yq; `make e2e` also needs docker, helm and kustomize. Narrow a run while
debugging:

```console
BATS_ARGS='--filter gzip' make test
```

### What the suites do and do not prove

`test/tasks.bats` checks every task against the Kargo step schemas vendored in
[`test/schemas/`](test/schemas), and checks every stage example against the task
it calls. `test/e2e-recipe.bats` renders
[`examples/example-app`](examples/example-app), archives it the way the `tar`
step does, publishes it to a throwaway registry the way `oci-push`'s `srcPath`
mode does, and reads it back.

Neither runs Kargo — `oci-push --srcPath` is not in a release yet — so the e2e
suite exercises a *replica* of the steps, written from reading
`tar_creator.go` and `oci_pusher.go`. It establishes that the recipe is sound;
it cannot establish that Kargo's implementation agrees byte for byte.

**So before relying on these tasks, run a real promotion.** Register the tasks
against a Kargo built from `main`, promote once, and check that the artifact
appears under both tags at one digest and that Argo CD syncs to it. That check
has not been run here, and nothing in this directory substitutes for it.

## CI

[`../.github/workflows/oci-tasks.yaml`](../.github/workflows/oci-tasks.yaml)
lints and runs both suites. There is no publish job: the family ships YAML, so a
merge to `main` is the release.
