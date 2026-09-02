# `hydrate-helm-to-oci`

Renders a Helm chart from Git and publishes the rendered manifests to an OCI
registry as an OCI 1.1 artifact — one Argo CD can sync directly, with no
rendered-manifests branch and no commit.

```
git-clone → helm-template → tar → oci-push → oci-push (retag) → compose-output
```

## Vars

| Var | Default | Description |
|---|---|---|
| `repoURL` | *required* | Git repository holding the chart. |
| `ociRepo` | *required* | OCI repository to publish to, without a tag. e.g. `ghcr.io/example/config/app`. |
| `chartPath` | `chart` | Path to the chart within the repository. |
| `releaseName` | `${{ ctx.project }}` | The value of `.Release.Name` while rendering. |
| `namespace` | `${{ ctx.project }}-${{ ctx.stage }}` | The value of `.Release.Namespace`. |
| `tag` | `${{ ctx.promotion }}` | Immutable tag, one per promotion. |
| `mutableTag` | `${{ ctx.stage }}` | Mutable tag, moved to each promotion's artifact. Set it equal to `tag` to publish only the immutable tag. |
| `includeCRDs` | `true` | Whether to render the chart's `crds/` directory. |
| `buildDependencies` | `false` | Whether to build chart dependencies first. Needs network access from the promotion pod. |

Values files are conventional rather than configurable: the task passes
`<chartPath>/values.yaml` and `<chartPath>/values-${{ ctx.stage }}.yaml` with
`ignoreMissingValueFiles: true`, so a Stage with no file of its own renders from
`values.yaml` alone. A chart needing a different arrangement wants a copy of
this task rather than another var.

## Outputs

| Output | Description |
|---|---|
| `ref` | The immutable, digest-pinned reference, `<ociRepo>@<digest>`. This is the one to record anywhere durable. |
| `digest` | Digest of the pushed artifact. Pass this as `deploy-oci-to-argocd`'s `revision`. |
| `tag` | The immutable tag that was applied. |
| `mutableTag` | The mutable tag that was moved. |
| `ociRepo` | Echoed back, so a later step needs only this task's output. |
| `manifestsPath` | Where the rendered manifests are in the workspace, for a step that wants to validate them before they ship. |

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

## Notes

`mediaType` and `artifactType` are deliberately unset, so the layer is published
as `application/vnd.oci.image.layer.v1.tar+gzip` — one of the three types Argo
CD's repo-server reads by default. Publishing Flux's media types instead needs an
operator to extend `--oci-layer-media-types`.

The `tar` step sets `gzip: true`, which is not optional: `oci-push` defaults the
layer media type to the gzipped one, so an uncompressed archive would be
published under a media type that lies about it. See
[the family README](../../README.md#what-these-tasks-get-right-and-why-it-is-not-obvious).

The task is idempotent, so retrying a promotion is safe: the render is
deterministic, and re-pushing produces the same blobs under the same tags.

## Examples

- [`examples/stage.yaml`](examples/stage.yaml) — a Stage that hydrates and
  deploys in one promotion.
- [`examples/warehouse.yaml`](examples/warehouse.yaml) — the Warehouse it draws
  Freight from.

To hydrate once and deploy from several Stages instead, see
[`../deploy-oci-to-argocd/examples/`](../deploy-oci-to-argocd/examples/).
