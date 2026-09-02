# `hydrate-kustomize-to-oci`

Builds a Kustomize overlay from Git and publishes the rendered manifests to an
OCI registry as an OCI 1.1 artifact — one Argo CD can sync directly, with no
rendered-manifests branch and no commit.

```
git-clone → kustomize-build → tar → oci-push → oci-push (retag) → compose-output
```

## Vars

| Var | Default | Description |
|---|---|---|
| `repoURL` | *required* | Git repository holding the overlays. |
| `ociRepo` | *required* | OCI repository to publish to, without a tag. e.g. `ghcr.io/example/config/app`. |
| `path` | `overlays/${{ ctx.stage }}` | Directory holding the `kustomization.yaml` to build. |
| `tag` | `${{ ctx.promotion }}` | Immutable tag, one per promotion. |
| `mutableTag` | `${{ ctx.stage }}` | Mutable tag, moved to each promotion's artifact. Set it equal to `tag` to publish only the immutable tag. |

With the default `path`, a Stage named `prod` builds `overlays/prod` and needs no
configuration beyond the two required vars.

## Outputs

| Output | Description |
|---|---|
| `ref` | The immutable, digest-pinned reference, `<ociRepo>@<digest>`. This is the one to record anywhere durable. |
| `digest` | Digest of the pushed artifact. Pass this as `deploy-oci-to-argocd`'s `revision`. |
| `tag` | The immutable tag that was applied. |
| `mutableTag` | The mutable tag that was moved. |
| `ociRepo` | Echoed back, so a later step needs only this task's output. |
| `manifestsPath` | Where the rendered manifests are in the workspace, for a step that wants to validate them before they ship. |

## Notes

`kustomize-build` writes to an `outPath` directory, so the artifact holds one
file per resource named `[namespace-]kind-name.yaml`. A single file would work
too; a directory keeps the artifact readable to anyone who pulls it.

Everything else — why there are two tags, why the second is a retag rather than a
second push, why `gzip: true` is not optional, and why `mediaType` and
`artifactType` are left unset — matches
[`hydrate-helm-to-oci`](../hydrate-helm-to-oci/README.md#why-two-tags), which
documents it in full.

## Examples

- [`examples/stage.yaml`](examples/stage.yaml) — a Stage that hydrates and
  deploys in one promotion.
- [`examples/warehouse.yaml`](examples/warehouse.yaml) — the Warehouse it draws
  Freight from.
