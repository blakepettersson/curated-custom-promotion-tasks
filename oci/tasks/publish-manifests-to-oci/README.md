# `publish-manifests-to-oci`

Publishes a directory of rendered manifests to an OCI registry as an OCI 1.1
artifact, and records what it published on the Freight.

```
tar → oci-push → oci-push (retag) → set-metadata → compose-output
```

It renders nothing. The caller renders — with Kargo's built-in `helm-template`
or `kustomize-build`, as many times as it has Stages — and this task packages
and publishes whatever ended up in the directory.

That split is deliberate. An all-in-one "clone, render, push" task can only ever
render *one* Stage, because a promotion's steps are static and there is no loop
construct to iterate a list of Stages with. Rendering every Stage at once is the
shape worth having, and it needs the publish half to stand on its own — so this
is the only publishing task in the family, and the render steps are written out
in the promotion template where you can see them.

## Vars

| Var | Default | Description |
|---|---|---|
| `ociRepo` | *required* | OCI repository to publish to, without a tag. e.g. `ghcr.io/example/config/app`. |
| `repoURL` | *required* | Git repository the manifests came from, recorded on the artifact as provenance. |
| `manifestsPath` | `./manifests` | Directory to publish. Subdirectories become paths within the artifact. |
| `tag` | `${{ ctx.promotion }}` | Immutable tag, one per promotion. |
| `mutableTag` | `${{ ctx.stage }}` | Mutable tag, moved to each promotion's artifact. When one Stage renders for the whole pipeline this is that Stage's name, not the name of any Stage the artifact is destined for — the artifact is for all of them. |

## Outputs

| Output | Description |
|---|---|
| `ref` | The immutable, digest-pinned reference, `<ociRepo>@<digest>`. This is the one to record anywhere durable. |
| `digest` | Digest of the pushed artifact. Pass this as `deploy-oci-to-argocd`'s `revision`. |
| `tag` | The immutable tag that was applied. |
| `mutableTag` | The mutable tag that was moved. |
| `ociRepo` | Echoed back, so a later step needs only this task's output. |
| `manifestsPath` | Echoed back. |

## Two ways to call it

**One Stage, rendering itself.** The simple case: render into `./manifests`,
publish, deploy. The Argo CD Application uses `path: .`. See
[`examples/single-stage.yaml`](examples/single-stage.yaml).

```
git-clone → helm-template (./manifests) → publish-manifests-to-oci → deploy-oci-to-argocd
```

**One Stage, rendering every Stage.** One `helm-template` per Stage, each into
its own subdirectory, published as one artifact with one digest. Every Stage
downstream deploys that digest with its Application's `path` selecting its own
subdirectory. See [`examples/entry-stage.yaml`](examples/entry-stage.yaml) and
[the family README](../../README.md#multiple-stages-render-per-stage-or-once-for-all-of-them).

```
git-clone
helm-template  →  ./manifests/test
helm-template  →  ./manifests/stage
helm-template  →  ./manifests/prod
publish-manifests-to-oci
```

Either way the render steps are yours. `kustomize-build` substitutes for
`helm-template` without changing anything here; see
[`examples/entry-stage-kustomize.yaml`](examples/entry-stage-kustomize.yaml).

## What it records on the Freight

```yaml
ociManifests:
  repo: ghcr.io/example/config/example-app
  digest: sha256:…
  tag: test.01jq…
  mutableTag: test
```

[`deploy-oci-to-argocd`](../deploy-oci-to-argocd) and
[`await-oci-deploy`](../await-oci-deploy) both read `ociManifests.digest` by
default, so a downstream Stage in the same pipeline needs no Warehouse of its
own and sets nothing but `ociRepo` and `appName`.

This is what keeps **one** Freight flowing through the whole pipeline. The
manifests become a property of the Freight that produced them — the same commit,
the same image digests, the same verification history — rather than a new
Freight of their own.

The alternative is a Warehouse subscribed to the registry, which creates new
Freight whose lineage back to that commit is gone. That is the right choice
exactly when the metadata cannot travel: another Kargo instance, another
project, an air-gapped enclave. See
[the family README](../../README.md#how-a-downstream-stage-learns-the-digest).

## Why two tags

The immutable tag (`${{ ctx.promotion }}`) exists so a rollback has something to
point at: it is never moved, so the artifact a promotion produced stays
addressable by name after later promotions. The mutable tag (`${{ ctx.stage }}`)
exists so a downstream `Warehouse` has a fixed thing to watch — a Kargo image
subscription follows one tag and reports the digest it resolves to.

The second tag is applied by *retagging* the digest the first push returned, not
by pushing the archive again. Both would work; only the retag cannot drift. A
second `srcPath` push produces the same digest for exactly as long as every
annotation stays byte-identical between the two steps, and a mutable tag that
quietly resolves to a different digest than the immutable one is the failure this
design exists to prevent. It is also cheaper: a same-repository retag moves no
blobs and is not subject to the artifact size limit.

Setting `mutableTag` equal to `tag` makes the retag a harmless no-op, for a
pipeline that wants only immutable tags.

## Why `gzip: true` is not optional

`oci-push` defaults the layer media type to
`application/vnd.oci.image.layer.v1.tar+gzip` while `tar` defaults to
`gzip: false`. Publish an uncompressed archive under that media type and every
step succeeds, the registry accepts it without complaint, and Argo CD's
repo-server then fails to decompress the layer. `test/lint-task.py` refuses a
task whose archive and media type disagree, and `test/e2e-recipe.bats` asserts
the published bytes really are gzip.

`mediaType` and `artifactType` are likewise deliberately unset, so the layer
lands on one of the three types Argo CD's repo-server reads by default.
Publishing Flux's media types instead needs an operator to extend
`--oci-layer-media-types`.

## Examples

- [`examples/single-stage.yaml`](examples/single-stage.yaml) — one Stage
  rendering and deploying itself.
- [`examples/entry-stage.yaml`](examples/entry-stage.yaml) — one Stage rendering
  every Stage with Helm and publishing one artifact.
- [`examples/entry-stage-kustomize.yaml`](examples/entry-stage-kustomize.yaml) —
  the same with Kustomize overlays.
- [`examples/downstream-stage.yaml`](examples/downstream-stage.yaml) — a
  downstream Stage whose whole promotion is one deploy step.
- [`examples/warehouse.yaml`](examples/warehouse.yaml) — the Warehouse the
  rendering Stage draws Freight from.
- [`examples/application.yaml`](examples/application.yaml) — the Argo CD
  Application, and the `path` that makes one artifact serve every Stage.
