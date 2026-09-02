# example-app

The fixture the `oci/` e2e suite renders: a Git repository laid out the way both
hydrate tasks expect by default.

```
chart/              a Helm chart, rendered by hydrate-helm-to-oci (chartPath: chart)
  values.yaml       the base values
  values-prod.yaml  overlaid when the Stage is named "prod"
  crds/             a CRD, rendered only because includeCRDs defaults to true
base/               shared Kustomize resources
overlays/<stage>/   one overlay per Stage, built by hydrate-kustomize-to-oci
                    (path: overlays/${{ ctx.stage }})
```

Nothing here is Kargo-specific — it is an ordinary config repository. The point
of hydrating to OCI is that this repository holds only sources: no rendered
manifests, no per-stage branch, nothing a promotion has to commit back.

The two renderers are shown side by side so the suite can prove both paths, not
because a real project would keep both.
