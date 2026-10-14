# flux-app

The fixtures a Flux user would hold, used by
[`steps/flux-reconcile/test/e2e-example.bats`](../../steps/flux-reconcile/test/e2e-example.bats)
to run the example promotion task's flow end to end.

| Path | What it is |
|---|---|
| `flux/` | Applied to the cluster once, by hand or by `flux bootstrap`: a GitRepository for this repository and a Kustomization over `apps/`. |
| `apps/demo/` | What the Kustomization applies: a HelmRepository and the HelmRelease Kargo promotes by bumping `spec.chart.spec.version`. |
| `chart/` | The chart the HelmRelease installs, published to an OCI registry by its own pipeline. Kargo's Warehouse subscribes to it there. |

A promotion of a new chart version is then: Kargo commits the version into
`apps/demo/helmrelease.yaml`, and `flux-reconcile` makes Flux fetch that
commit, apply it through the `apps` Kustomization, and upgrade the release —
waiting at each link for the revision it was given.

The registry and repository URLs are placeholders; the suite substitutes its
own.
