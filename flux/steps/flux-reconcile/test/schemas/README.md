# Step config schemas

What `test/e2e-example.bats` checks `examples/cluster-promotion-task.yaml`
against, with [`oci/test/lint-task.py`](../../../../../oci/test/lint-task.py):
every step's config against its schema, plus the cross-step rules no schema
can express (`task.outputs` aliases, declared and used vars, empty defaults).

- `flux-reconcile.json` is this step's own, written here. The step enforces
  the same rules at runtime, at the top of `src/flux-reconcile`; change both
  together.
- The rest are Kargo's built-in step schemas, copied from
  `pkg/promotion/runner/builtin/schemas/` in
  [akuity/kargo](https://github.com/akuity/kargo) at commit
  [`5ba9f4f`](https://github.com/akuity/kargo/commit/5ba9f4f2be181b9bb4a8753257a97feac9c25560),
  and stored as `<step>.json` so the linter finds a schema by its step's `uses`.

Refresh them, and bump the commit above, with:

```console
REF=<commit-or-tag>
for s in git-clone yaml-update git-commit git-push compose-output; do
  gh api "repos/akuity/kargo/contents/pkg/promotion/runner/builtin/schemas/$s-config.json?ref=$REF" \
    --jq '.content' | base64 -d > "$s.json"
done
```
