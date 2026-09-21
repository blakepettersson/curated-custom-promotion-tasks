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
[`test/schemas/README.md`](test/schemas/README.md). The suite that promotes
through a real Kargo pins the chart it installs in
[`test/helpers.bash`](test/helpers.bash), which is the build these tasks are
known to work against.

For the Argo CD side you need Argo CD with OCI source support, and an
`Application` annotated `kargo.akuity.io/authorized-stage`.

## Catalog

| Task | What it does |
|---|---|
| [`publish-manifests-to-oci`](tasks/publish-manifests-to-oci) | Packages a directory of rendered manifests, publishes it as an OCI artifact, and records the digest on the Freight. |
| [`deploy-oci-to-argocd`](tasks/deploy-oci-to-argocd) | Points an Argo CD Application's OCI source at a digest and waits for it to sync. |
| [`await-oci-deploy`](tasks/await-oci-deploy) | Waits for a cluster Kargo cannot reach to report that it is running a digest. |

## Rendering is yours

There is no "clone, render and push" task here, and that is a decision rather
than a gap. An all-in-one task can only render **one** Stage: a promotion's
steps are static, Kargo has no loop construct, and a `stages: [...]` var
therefore cannot drive N renders. Since rendering every Stage at once is the
shape worth having, the publish half has to stand alone — so it does, once, and
the render steps are Kargo's own `helm-template` and `kustomize-build`, written
out in the promotion template.

The cost is a few more lines in the promotion template. What it buys is one way
to do this instead of two, no all-in-one variant per renderer, and — because a
task cannot call another task — no duplicated archive/push/retag tail to keep in
agreement across three copies.

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
kargo apply -f tasks/publish-manifests-to-oci/cluster-promotion-task.yaml
kargo apply -f tasks/deploy-oci-to-argocd/cluster-promotion-task.yaml
kargo apply -f tasks/await-oci-deploy/cluster-promotion-task.yaml
```

Then render, publish and deploy from a promotion template. The render steps are
Kargo's own; the tasks are the two either side of them:

```yaml
steps:
  - uses: git-clone
    as: clone
    config:
      repoURL: ${{ vars.repoURL }}
      checkout:
        - commit: ${{ commitFrom(vars.repoURL).ID }}
          path: ./src

  - uses: helm-template
    as: render
    config:
      path: ./src/chart
      releaseName: example-app
      outPath: ./manifests
      outLayout: flat
      includeCRDs: true

  - task:
      name: publish-manifests-to-oci
      kind: ClusterPromotionTask
    as: publish
    vars:
      - name: repoURL
        value: ${{ vars.repoURL }}
      - name: ociRepo
        value: ghcr.io/example/config/example-app

  - task:
      name: deploy-oci-to-argocd
      kind: ClusterPromotionTask
    as: deploy
    vars:
      - name: ociRepo
        value: ghcr.io/example/config/example-app
      - name: revision
        value: ${{ outputs.publish.digest }}
      - name: appName
        value: example-app-${{ ctx.stage }}
```

Each task's README lists its vars and outputs;
[`tasks/publish-manifests-to-oci/examples/`](tasks/publish-manifests-to-oci/examples/)
has runnable `Stage`, `Warehouse` and Argo CD `Application` manifests for every
shape below.

Which tasks you need depends on the shape you pick, which is the next section.

## Multiple Stages: render per Stage, or once for all of them?

Both work, and they differ in one thing that matters. **Prefer rendering once
for every Stage** unless the pipeline is small enough that you would rather have
the simpler promotion template.

Both shapes use the same task. They differ only in how many render steps the
promotion template has, and in which Stage runs them.

### Render per Stage

Each Stage's promotion clones, renders with its own values file or overlay, and
publishes its own artifact under its own tag —
[`examples/single-stage.yaml`](tasks/publish-manifests-to-oci/examples/single-stage.yaml).

```
test  ──clone, render, push──▶  :test   ──▶ Application(path: .)
stage ──clone, render, push──▶  :stage  ──▶ Application(path: .)
prod  ──clone, render, push──▶  :prod   ──▶ Application(path: .)
```

This is not as weak as it first looks: the Freight pins the commit, so prod
renders from *the same commit* test did, not from whatever `main` says at prod
promotion time. It is reproducible.

What it does not give you is identity. Prod's manifests are a **re-render**, and
a re-render is only as trustworthy as its inputs are pinned — the chart's
dependencies, the Helm version in the promotion pod, a `values-prod.yaml` that
nobody validated because no Stage before prod reads it. Prod's render also
happens for the first time during prod's promotion, so a template error in the
prod path surfaces there and nowhere earlier.

Use this shape when a pipeline has one or two Stages, or when Stages differ so
much that a shared render is meaningless.

### Render once for every Stage

The entry Stage renders *every* Stage, each into its own subdirectory, and
publishes all of them as **one artifact with one digest**. Each Stage's Argo CD
Application selects its own subdirectory with `path`.

```
test ──clone, render ×3, push──▶  :test ── one digest ──┬──▶ Application(path: test)
                                                        ├──▶ Application(path: stage)
                                                        └──▶ Application(path: prod)
```

- **Prod deploys bytes, not a promise.** The manifests prod applies are the ones
  produced when the Freight entered the pipeline, byte for byte. There is no
  re-render to disagree.
- **Every Stage's render is exercised on the first promotion.** A broken
  `values-prod.yaml` fails at the entry Stage, not at 2am during the prod
  promotion.
- **Downstream promotions need almost nothing.** No Git, no Helm, no Kustomize,
  no chart repositories — a downstream promotion talks to the registry and to
  Argo CD and to nothing else. This is what makes an air-gapped Stage tractable
  at all, and it is the main reason to prefer this shape.
- **One thing to promote, inspect, mirror and roll back.** One digest, not one
  per Stage.

The costs are real and worth stating:

- **The render loop is written out, not parameterised.** A promotion's steps are
  static, so there is no way to iterate a list of Stages. Adding a Stage means
  adding a `helm-template` step to the entry Stage's promotion template.
- **A config change only takes effect on re-entry.** Editing `values-prod.yaml`
  changes nothing until new Freight passes through the entry Stage. That is
  arguably the correct behaviour — config changes flow through the pipeline like
  everything else, and get whatever verification the earlier Stages provide —
  but it does surprise people who expect to edit prod's values and promote.
- **Every Stage's manifests are in every Stage's artifact.** Harmless (Argo CD
  reads only its `path`) and negligible in size, but it is not a secrets
  boundary. Rendered manifests are not a place for secrets in either shape.

See [`examples/entry-stage.yaml`](tasks/publish-manifests-to-oci/examples/entry-stage.yaml)
for the entry Stage, [`examples/downstream-stage.yaml`](tasks/publish-manifests-to-oci/examples/downstream-stage.yaml)
for a downstream Stage whose whole promotion is one step, and
[`examples/entry-stage-kustomize.yaml`](tasks/publish-manifests-to-oci/examples/entry-stage-kustomize.yaml)
for the same with Kustomize.

### Not worth building: one artifact for all Stages with no per-Stage rendering

The tempting third option is to render once, stage-agnostically, and let each
environment differ some other way. It needs the manifests to carry no per-Stage
difference at all, which is almost never true of a real chart — replicas,
hostnames, resource limits, namespaces. Reach for it only if you already run
that way deliberately.

## How a downstream Stage learns the digest

Two mechanisms, for two topologies. This is worth getting right, because they
have different consequences for Freight lineage.

**Freight metadata — within one pipeline.** `publish-manifests-to-oci` records
`ociManifests.{repo,digest,tag}` on the Freight with `set-metadata`, and
`deploy-oci-to-argocd` reads it back with `freightMetadata()` by default. **One**
Freight then flows through the whole pipeline: prod is promoting the same
Freight — the same commit, the same image digests, the same verification history
— and the manifests are a property of it. Nothing new is created and no second
Warehouse exists.

**A Warehouse on the registry — across a boundary.** A Stage subscribes to the
OCI repository and its Freight *is* the artifact. This is the only shape that
works when Freight metadata cannot travel: a separate Kargo project, a separate
Kargo instance, an air-gapped enclave. The cost is lineage — the new Freight is
"manifests digest X", and the commit and image digests that produced it are no
longer in it. Kargo's `imageFrom()` on the artifact repository gives you a
digest and nothing about its provenance, which is why the hydrate tasks stamp
`org.opencontainers.image.revision` onto the artifact itself: with a Warehouse
boundary, the OCI annotations are the only way back to the source.

So: within a pipeline, metadata. Across a boundary, a Warehouse — and design the
boundary knowing that Freight identity stops there.

`deploy-oci-to-argocd`'s default `revision` tries metadata first and falls back
to `imageFrom()`, so both shapes work without configuring anything.

## Air-gapped Stages

The artifact is the interface. That is the whole answer, and everything below is
about how much of a control loop you can get back on top of it.

Design the boundary so that **only the artifact crosses it** — which is exactly
what "render once for every Stage" buys, since a downstream promotion then needs
no Git, no chart repository and no Helm. Mirror by digest, never by tag, so what
lands inside cannot depend on when the mirror ran. Three tiers, in order of
preference:

### 1. A Kargo controller shard inside the enclave

If the enclave can open an **outbound** connection to the Kargo control plane,
run a controller shard in there and put the Stage on it. The shard pulls its
work, runs `deploy-oci-to-argocd` against the enclave's own Argo CD, and reports
status back out. Nothing needs to accept inbound connections, and you keep the
whole control loop: real health checks, real sync waits, real failures with
causes.

This is the shape to push for. It is a networking conversation, not an
architecture change — the tasks are unchanged, and the only extra moving part is
mirroring the artifact into a registry the enclave can read.

### 2. No Kargo inside, but a shared status endpoint

If nothing inside can run a controller but *something* inside can make outbound
HTTP calls, use [`await-oci-deploy`](tasks/await-oci-deploy). The promotion
mirrors the artifact by digest and then polls a status endpoint until it reports
that digest live. Both sides reach the endpoint outbound; neither accepts
inbound.

This is the webhook idea, inverted into a poll — which is strictly better here,
because an inbound webhook would require *Kargo* to be reachable, and that is
the assumption an air-gapped enclave is least likely to grant. Kargo's `http`
step reports Running and retries whenever neither the success nor the failure
expression matches, so the promotion stays open and visible while the rollout
happens somewhere Kargo cannot see.

Two things to get right, both covered in
[the endpoint contract](tasks/await-oci-deploy/examples/status-contract.md):

- **Compare digests, not health.** The endpoint is normally reporting the
  *previous* digest when polling starts, so a bare health check succeeds on the
  first poll and reports a rollout that has not happened.
- **Report what is running, read back from the cluster** — not what the enclave
  was told to deploy. Otherwise the gate confirms only that the mirror step ran,
  which the mirror step already confirmed.

Be honest about what you have: a gate, not a deploy. Nothing in the promotion
causes the rollout, so an enclave that never rolls out yields a timeout rather
than a failure with a cause.

### 3. Genuinely no path in either direction

Then you are, as you'd expect, out of luck for a control loop — and the mistake
is to model the enclave as a Kargo Stage anyway. A Stage that cannot observe its
own outcome reports success for having *published*, which is worse than not
modelling it: the pipeline shows green for a deploy nobody has confirmed.

Instead, end the outer pipeline at the boundary. Its last Stage publishes the
artifact, and its success means "this digest is released and mirrored", which is
true and useful. Inside the enclave, run a second, self-contained Kargo with a
`Warehouse` subscribed to the inner registry — it discovers artifacts as they
arrive, and promotes them through inner Stages with a full control loop, because
everything it needs is inside. The two pipelines are joined only by the artifact
and never talk.

That is the same boundary as tier 1 or 2, drawn honestly: the artifact carries
the release, the OCI annotations carry the provenance, and neither pipeline
pretends to know the other's state.

## What these tasks get right, and why it is not obvious

Each of these is a way to build a green promotion that deploys nothing, or the
wrong thing. All of them are checked by the suites in [`test/`](test).

**`tar` defaults to `gzip: false`; `oci-push` defaults its layer media type to
`application/vnd.oci.image.layer.v1.tar+gzip`.** Omit `gzip: true` and you
publish a plain tar labelled as gzip. Both steps succeed, the registry accepts
it without complaint, and Argo CD's repo-server then fails to decompress the
layer. `test/lint-task.py` refuses a task whose archive and media type disagree, and
`test/e2e-recipe.bats` asserts the published bytes really are gzip.

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
references in the calling Stage, not one task calling another. It is also why
there is one publishing task rather than one per renderer: every all-in-one
variant would carry its own copy of the archive/push/retag tail, with nothing
but a test able to hold the copies in agreement.

**`argocd-update` cannot set a source's `path`.** Its source update accepts
`repoURL`, `chart`, `desiredRevision`, `updateTargetRevision`, `helm` and
`kustomize`, and nothing else. So `path` is set on the `Application` once, per
environment — which is right: which subdirectory an environment reads is a
property of that environment, not of the release flowing through it.

**A step's `retry` block is never expression-templated.** Only `config` is.
`retry.timeout` is a typed `metav1.Duration`, so `${{ vars.timeout }}` there
fails as a duration that will not parse, and nothing but the linter would notice.

**`successExpression` in the `http` step sees only `response`.** No `vars`, no
`ctx`. A value from a var has to be interpolated into the expression's *text* by
the config templating, not referenced from inside it.

## Subscribing to hydrated manifests

For when a `Warehouse` is the right way to carry the artifact across a boundary
— see [How a downstream Stage learns the digest](#how-a-downstream-stage-learns-the-digest)
for when it is and is not.

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
make e2e-kargo # promote through a real Kargo in a kind cluster
```

`make test` needs [bats](https://github.com/bats-core/bats-core), python3 and
yq; `make e2e` also needs docker, helm and kustomize; `make e2e-kargo` needs
kind, kubectl, helm and git, and takes a few minutes to build its cluster. It is
not part of `make all` for that reason — CI runs it as its own job. Keep the
cluster to iterate against:

```console
KARGO_E2E_KEEP=1 make e2e-kargo
```

Narrow a run while debugging:

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

Neither of those runs Kargo, so the recipe suite exercises a *replica* of the
steps, written from reading `tar_creator.go` and `oci_pusher.go`. It establishes
that the recipe is sound; it cannot establish that Kargo's implementation agrees
byte for byte.

`test/e2e-kargo.bats` is what closes that gap. It stands Kargo up in a kind
cluster — the unstable chart, since `oci-push --srcPath` is not released — with
a registry and a Git server beside it, and promotes real Freight through
[`publish-manifests-to-oci`](tasks/publish-manifests-to-oci) itself, not a copy
of it. So the assumptions the task rests on are checked against the code that
implements them: that the layer really is gzip and carries a media type Argo CD
reads, that both tags resolve to one digest, that the artifact unpacks to one
directory per Stage each rendered with its own values, that `set-metadata` lands
where `deploy-oci-to-argocd` reads it, and — as a negative control, with the
`fixture-ungzipped` task from `test/fixtures/broken/` — that forgetting
`gzip: true` yields a **green promotion** publishing a layer nothing can
decompress. Applying the tasks to a real Kargo is a check in itself: the CRD's
structural schema and its CEL rules are enforced there, and the vendored schemas
cannot see them.

Two things it still does not cover. **Argo CD**: there is none in the test
cluster and no status endpoint, so `deploy-oci-to-argocd` and `await-oci-deploy`
are checked against the schemas and nothing more — before relying on those two,
point them at a real Argo CD and watch it sync. And **the Kargo it runs is a
daily build of `main`**, pinned in [`test/helpers.bash`](test/helpers.bash): a
release may behave differently, and bumping that pin is how you find out.

## CI

[`../.github/workflows/oci-tasks.yaml`](../.github/workflows/oci-tasks.yaml)
lints and runs all three suites, the real-Kargo one as its own job since it
builds a cluster. There is no publish job: the family ships YAML, so a merge to
`main` is the release.
