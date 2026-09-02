# Vendored Kargo step config schemas

The JSON Schemas Kargo validates each built-in step's `config` against, copied
from `pkg/promotion/runner/builtin/schemas/` in
[akuity/kargo](https://github.com/akuity/kargo). `test/lint-task.py` checks the
tasks in this family against them, so a field renamed upstream shows up as a
test failure here rather than as a failed promotion.

Pinned to commit
[`6c2a2a5`](https://github.com/akuity/kargo/commit/6c2a2a558d0a0642a5e2dd069577276f92668c2f)
— the merge of [#6893](https://github.com/akuity/kargo/pull/6893), which added
`oci-push`'s `srcPath` mode and is the earliest commit these tasks work against.

Refresh them, and bump the commit above, with:

```console
REF=<commit-or-tag>
for s in oci-push tar helm-template kustomize-build git-clone \
         argocd-update argocd-common common compose-output; do
  gh api "repos/akuity/kargo/contents/pkg/promotion/runner/builtin/schemas/$s.json?ref=$REF" \
    --jq '.content' 2>/dev/null | base64 -d > "$s.json" ||
  gh api "repos/akuity/kargo/contents/pkg/promotion/runner/builtin/schemas/$s-config.json?ref=$REF" \
    --jq '.content' | base64 -d > "$s.json"
done
```

Upstream names most of these `<step>-config.json` and the two shared definition
files `argocd-common.json` and `common.json`; they are stored here as
`<step>.json` so the linter can find a step's schema from its `uses` value, and
resolve a `$ref` to a shared file by its own name.

Only steps this family uses are vendored. A task that reaches for another
built-in step will fail its own lint with "no schema for this step" until that
step's schema is added to the loop above.
