# `deploy-oci-to-argocd`

Points an Argo CD Application's OCI source at a specific artifact digest and
waits for it to sync.

```
argocd-update → compose-output
```

Two callers, one task:

- **A downstream Stage whose Warehouse subscribes to the OCI repository.** The
  default `revision` reads the digest straight out of the Freight, so the Stage
  sets nothing but `ociRepo` and `appName`. This is the "hydrate once, deploy
  many times" shape.
- **The Stage that just hydrated the artifact.** Override `revision` with the
  hydrate task's `digest` output.

## Vars

| Var | Default | Description |
|---|---|---|
| `ociRepo` | *required* | OCI repository holding the artifact, without a tag or digest. Must match the Application source's `repoURL` less its `oci://` prefix. |
| `revision` | `${{ imageFrom(vars.ociRepo).Digest }}` | The artifact to sync to, as a digest. |
| `appName` | `${{ ctx.project }}-${{ ctx.stage }}` | Name of the Argo CD Application to update. |
| `appNamespace` | `argocd` | Namespace the Application lives in. |
| `updateTargetRevision` | `true` | Whether to rewrite the source's `targetRevision` to the digest, pinning the Application to exactly this artifact. |

## Outputs

| Output | Description |
|---|---|
| `ref` | `<ociRepo>@<revision>`, the reference that was deployed. |
| `revision` | The digest that was deployed. |
| `app` | The Application that was updated. |
| `appNamespace` | Its namespace. |

## `revision` must be a digest

Argo CD records the digest of a synced OCI artifact as the Application's
revision, and `argocd-update` reports `Running` until that value equals
`desiredRevision`. Give it a tag and the two can never match: the step waits
until the promotion times out, having deployed correctly and reported nothing.

Pinning `targetRevision` to a digest also means the Application is bound to
exactly the artifact that was verified, rather than to whatever a mutable tag
points at by the time Argo CD next looks.

There is no separate wait step. `argocd-update` is long-running: it holds the
promotion open until the Application is synced to `desiredRevision` and healthy.

## Examples

- [`examples/warehouse.yaml`](examples/warehouse.yaml) — a Warehouse that treats
  hydrated manifests as Freight. Read this one: subscribing to an OCI *artifact*
  rather than a container image has three constraints that each fail silently.
- [`examples/stage.yaml`](examples/stage.yaml) — a downstream Stage that deploys
  an artifact it did not render.
- [`examples/application.yaml`](examples/application.yaml) — the Argo CD
  Application, including the two fields that have to line up with this task's
  vars and the `path` it must not have.
