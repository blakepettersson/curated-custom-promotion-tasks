# flux-reconcile

A Kargo custom promotion step that does for Flux what `argocd-update` does for
Argo CD: after a promotion has pushed a change, it has Flux reconcile **now**,
and waits until Flux has applied the revision that promotion produced.

For each target, in order, it runs `flux reconcile <kind> --with-source`, which
refreshes the source chain (GitRepository, OCIRepository, HelmChart and so on),
requests the reconcile, and waits for Ready. Then it checks the one thing
`flux reconcile` cannot be asked to: that the revision applied is the one the
promotion produced.

It changes no spec and touches no workload: all `flux reconcile` writes is the
`reconcile.fluxcd.io/requestedAt` annotation.

```yaml
- uses: flux-reconcile
  as: reconcile
  config:
    kubeconfig: ${{ secret('flux-cluster').kubeconfig }}
    targets:
      - kind: Kustomization
        name: apps
        desiredRevision: ${{ outputs.push.commit }}
      - kind: HelmRelease
        name: demo
        desiredRevision: ${{ chartFrom('oci://ghcr.io/example/charts/demo').Version }}
```

[`examples/cluster-promotion-task.yaml`](examples/cluster-promotion-task.yaml)
is the whole flow — bump a chart version in Git, push, reconcile — and
[`examples/stage.yaml`](examples/stage.yaml) calls it.

## What it adds to `flux reconcile`

Against Flux v2.9, each of these is a case in
[`test/flux-reconcile.bats`](test/flux-reconcile.bats):

- **The revision.** `flux reconcile` takes no expected revision, and exits 0 on
  whatever the source held when it looked. A Git host can serve the previous
  HEAD for a moment after a push, and a source fetched then is Ready on the
  wrong commit. Given a `desiredRevision`, the step compares the applied
  revision and runs `flux reconcile` again until it matches or the timeout
  passes.
- **Why it failed.** A reconcile that fails — a manifest the API server
  rejects, a failed health check, a dependency that is not ready — keeps
  `flux reconcile` waiting until its timeout, and it then reports only
  "context deadline exceeded". The step adds the Ready condition's reason and
  message, which is what Flux actually said.
- **Ready is not healthy.** A Kustomization without `wait` or `healthChecks`
  is `Ready=True` as soon as its apply succeeds — here, with a Deployment whose
  image cannot be pulled. The step reports `healthChecked: false` for such a
  target rather than calling it healthy, and `requireHealthCheck: true` fails
  it outright.

What `flux reconcile` does that the step relies on, and that the suite holds it
to: it refuses a suspended target or source ("resource is suspended") rather
than reporting a reconcile that a suspended object would mark handled and never
perform, and with `--with-source` it refreshes a HelmRelease's whole chain —
GitRepository, then HelmChart, then the release.

**A failure takes the whole timeout.** Because `flux reconcile` does not stop on
a failed reconcile, a broken commit fails the step at `timeout` (10m unless
configured), not as soon as Flux reports it. Set `timeout` to what you would
wait for a healthy rollout.

## Config

| Key | Required | Default | |
|---|---|---|---|
| `kubeconfig` | yes | | Contents of a kubeconfig for the cluster Flux runs in. See [Credentials](#credentials). |
| `context` | | its current-context | Context to use from the kubeconfig. |
| `targets` | yes | | 1–20 objects to reconcile, in order. |
| `targets[].kind` | yes | | `Kustomization` or `HelmRelease`. |
| `targets[].name` | yes | | |
| `targets[].namespace` | | `flux-system` | |
| `targets[].desiredRevision` | | | What the target must have applied. Kustomization: a full commit SHA, or an OCI digest, with or without its `sha1:`/`sha256:` prefix. HelmRelease: a chart version (`0.2.0` also matches the `0.2.0+<digest>` helm-controller records for an OCIRepository chart), or the chart's digest. |
| `targets[].withSource` | | `true` | Refresh the source chain first. |
| `timeout` | | `10m` | For all targets together: `90s`, `10m`, `1h30m`. |
| `requireHealthCheck` | | `false` | Fail a target whose Ready would not mean healthy. |

Without a `desiredRevision`, the step accepts whatever `flux reconcile` reports
applied — with `withSource`, what the source held once refreshed. Set it
whenever the promotion knows the revision — after a `git-push`, that is
`outputs.<alias>.commit` — or a source fetched a moment too early passes.

A short SHA does not match, and nor does a ref name: `main` would match every
commit on main.

The step's `timeout` must fit inside the promotion's own limit on the step,
`defaultTimeout: 15m` in
[`custom-promotion-step.yaml`](custom-promotion-step.yaml). At that limit the
step is killed and writes no output; at its own timeout it fails saying what
Flux reported. If you raise `timeout`, set the step's `retry.timeout` above it.

## Output

```json
{
  "message": "reconciled 2 Flux object(s); all applied the expected revision and passed their health checks",
  "revision": "main@sha1:4f1c…",
  "healthChecked": true,
  "targets": [
    {
      "kind": "Kustomization", "namespace": "flux-system", "name": "apps",
      "revision": "main@sha1:4f1c…", "desiredRevision": "4f1c…",
      "healthChecked": true, "ready": true,
      "message": "applied main@sha1:4f1c… and passed its health checks"
    }
  ]
}
```

`revision` is the first target's. `healthChecked` is true only if every target
checked workload health. The output is written on failure too, holding every
target reached so far; the failing one has `ready: false` and the reason.

| Exit | Meaning |
|---|---|
| 0 | Every target applied the expected revision. |
| 1 | Flux failed to apply or pass health checks, a target or source is suspended, or the timeout passed. |
| 2 | Misconfiguration: bad config, a kubeconfig that does not parse, or a target that does not exist or that the kubeconfig may not read. |

## Credentials

Kargo gives a custom step's container no Kubernetes credentials of its own: the
promotion pod mounts no service account token, and the `access-*` capabilities
reach Kargo's and Argo CD's clusters, not Flux's. So the step takes a
kubeconfig in its config, read from a Kargo Secret:

1. On the cluster Flux runs in, apply [`examples/rbac.yaml`](examples/rbac.yaml):
   a ServiceAccount allowed `get` and `patch` on Flux's own kinds, and nothing
   else — no Secrets, no workloads. Use RoleBindings instead of the
   ClusterRoleBinding to confine it to a project's namespaces.
2. Build a kubeconfig from its token, with a server address the Kargo agent can
   reach, and store it in the project namespace as a `generic` Secret —
   [`examples/kargo-secret.yaml`](examples/kargo-secret.yaml) shows how.
3. Pass it as `kubeconfig: ${{ secret('flux-cluster').kubeconfig }}`.

The kubeconfig is written only to the step's private temporary directory, never
to the promotion workspace that later steps share. It must use static
credentials: the image carries no exec credential plugins (`aws`,
`gke-gcloud-auth-plugin`, `kubelogin`).

Every test runs the step with the identity in `rbac.yaml`, so those
permissions are known to be enough.

Unlike `argocd-update`, the step does not check for a
`kargo.akuity.io/authorized-stage` annotation on its targets. Asking Flux to
reconcile changes nothing Flux would not do at its next interval, and what a
project may reach is decided by the RBAC behind the kubeconfig it holds.

## Not covered

- **HelmReleases that have exhausted their retries.** helm-controller does not
  retry a release whose remediation retries are spent on a plain reconcile
  request; it needs `flux reconcile hr --reset` or `--force`. The step makes no
  such request: promoting a new chart version changes the spec, which starts a
  fresh attempt anyway.
- **Source kinds `flux reconcile --with-source` does not handle** are left to
  Flux's own interval.
- **Changing what Flux deploys.** The step never edits a source's ref the way
  `argocd-update` can set `targetRevision`. The promotion's Git commit is the
  change; this step only makes Flux act on it now and confirms it did.

## Develop

From [`flux/`](..):

```console
make lint    # shellcheck
make test    # behaviour tests: builds a kind cluster with Flux (needs bats, kind, kubectl, helm)
make e2e     # examples/flux-app through the example task's config (also yq, python3)
FLUX_E2E_KEEP=1 make test   # keep the cluster for the next run
```
