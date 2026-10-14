# Flux

Promotion pieces for clusters that deploy with [Flux](https://fluxcd.io) rather
than Argo CD.

| | |
|---|---|
| [`flux-reconcile`](steps/flux-reconcile) | A custom step: has Flux reconcile a Kustomization or HelmRelease, and its sources, now — and waits until it has applied the revision the promotion produced. The Flux counterpart of `argocd-update`. |

A promotion to a Flux cluster is then the usual Git flow with this step at the
end: clone, change, commit, push, `flux-reconcile`.
[`steps/flux-reconcile/examples/cluster-promotion-task.yaml`](steps/flux-reconcile/examples/cluster-promotion-task.yaml)
is that flow for a chart version, against the repository in
[`examples/flux-app`](examples/flux-app).

Like every custom step, it needs Kargo on the Akuity Platform v1.10+ with the
Promotion Controller enabled and a self-hosted agent. It also needs a
kubeconfig for the cluster Flux runs in — Kargo gives custom steps no
Kubernetes credentials of their own. The step's README has the RBAC and how to
store the kubeconfig.

## Develop

```console
make lint    # shellcheck
make test    # behaviour tests against real Flux controllers in kind
make e2e     # examples/flux-app, promoted as the example task does
make all
```

Both suites build a kind cluster with Flux, Gitea and a registry;
`FLUX_E2E_KEEP=1` keeps it for the next run. They need docker, bats, kind,
kubectl, curl and helm, and the e2e suite also yq and python3. It lints the
example task with [`oci/test/lint-task.py`](../oci/test/lint-task.py), the
linter the `oci` family's tasks are held to.
