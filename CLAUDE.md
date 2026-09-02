# Working in this repository

Two kinds of thing live here:

- **Custom promotion steps** — a container image per step, the
  `CustomPromotionStep` manifest that registers it, promotion tasks that compose
  it, and CI that builds, tests and publishes the image.
- **Promotion tasks** — `ClusterPromotionTask` manifests composed entirely of
  Kargo's *built-in* steps. No image, no registry, no publish job.

Read [`README.md`](README.md) for the layout,
[`kyverno/steps/kyverno-validate`](kyverno/steps/kyverno-validate) as the
reference step, and [`oci/`](oci) as the reference task family. Everything below
is what a new one has to get right.

## Where things go

One directory per tool family (`kyverno/`, `oci/`, and siblings to come). A
family holds `steps/` when it ships images, `tasks/` when it ships YAML, or
both:

```
<family>/Makefile                          lint, test, e2e (and build, for steps)
<family>/steps/<step>/Dockerfile
<family>/steps/<step>/src/<step>           entrypoint script (executable, 0755)
<family>/steps/<step>/custom-promotion-step.yaml
<family>/steps/<step>/examples/            promotion task + stage
<family>/steps/<step>/test/<step>.bats     behaviour tests (bats)
<family>/steps/<step>/test/e2e-chart.bats  the family's examples, end to end
<family>/steps/<step>/test/helpers.bash    run_step + assertions the .bats files load
<family>/steps/<step>/test/fixtures/
<family>/tasks/<task>/cluster-promotion-task.yaml
<family>/tasks/<task>/README.md            vars, outputs, and the traps it closes
<family>/tasks/<task>/examples/            stage, warehouse, anything it expects
<family>/test/                             the family's suites, for a task family
<family>/examples/                         fixtures a real project would hold
.github/workflows/<name>.yaml              one per step, one per task family
```

## The Kargo contract

Facts a step must respect. They come from `api/v1alpha1/custom_promotion_step_types.go`
and `internal/promotion/pod_engine.go` in `kargo-enterprise`, plus the custom
steps reference page in the `kargo` docs.

- `CustomPromotionStep` is `ee.kargo.akuity.io/v1alpha1`, **cluster-scoped**, and
  needs Kargo on the Akuity Platform v1.10+ with the Promotion Controller
  enabled and a self-hosted agent. Steps run as pods.
- Register with **`kargo apply -f`**, never `kubectl` — on the Akuity Platform
  the control plane is not directly reachable.
- `spec.command` is run by an executor wrapper, *not* as the image entrypoint.
  Use an absolute path.
- Config reaches the step through `env`, rendered with an expression language
  that only exposes `config` and `ctx`. Pass the whole object as one variable:

  ```yaml
  env:
    - name: MY_STEP_CONFIG
      value: ${{ asJSON(config) }}
  ```

  Per-key `env` entries look tidier and are a trap: an absent key renders as the
  literal string `<nil>`, not empty. `asJSON(config)` of an absent config renders
  as `null`, so normalize that to `{}` in the script.
- Write results as JSON to `$KARGO_OUTPUT` and declare
  `output: {source: {type: Pipe, format: JSON}}`. Output is collected **even when
  the command exits non-zero**, so write it before failing. Hard cap 256 KiB;
  cap any list you emit.
- Exit non-zero to fail the promotion. Reserve a distinct code (this repo uses
  `2`) for misconfiguration, so tests can tell "found a problem" from "was told
  something impossible".
- The container runs as **uid 65532:65532**, non-root, no privileges, all
  capabilities dropped. The working directory is the promotion workspace shared
  by every step in the promotion; write nothing outside it and `/tmp`.
- Only **linux/amd64** and **linux/arm64** are supported.
- A step may be retried, which re-runs the command — keep it idempotent. For a
  deterministic check set `defaultErrorThreshold: 1`: a retry cannot turn a
  rejected input into an accepted one.
- All steps of a promotion share one pod. Keep `resources` honest and avoid
  memory-hungry work.

## Verify the tool, do not trust it

The premise of a validation step is that it fails when the input is bad. Prove
that against the real binary before designing around it, and encode each proof
as a test.

`kyverno apply` was the cautionary case: given an unparsable policy it logs only
at `-v 3`, applies whatever remains and **exits 0**; given a *directory*, one bad
file makes it skip the whole directory, still exiting 0 having applied nothing. A
gate built on that exit code passes every broken policy set. Hence
`kyverno-validate` loads files one at a time and parses the CLI's log.

Assume any tool may: exit 0 on partial failure, report problems only at raised
verbosity, write results to stdout in one mode and nothing at all in another, or
treat "no results" and "everything passed" identically.

## Promotion task conventions

A task is YAML, so every mistake it can hold is one Kargo reports halfway
through someone's release. These are the ones that have bitten here.

- Give every step an `as` alias. Inside a task, an earlier step's output is
  `task.outputs.<alias>`; plain `outputs.<alias>` does not resolve, and the
  calling Stage uses the plain form for the task's own output. Getting these
  backwards is the most common error.
- Expose results with a final `compose-output` step. Echo back what a caller
  would otherwise have to recompute — the digest-pinned reference, not just the
  digest.
- Declare a var with no `value` to require it of the caller. Never write
  `value: ""`: every string field in the step schemas is `minLength: 1`, so an
  empty default reaches the step as `""` and is rejected. It is not treated as
  absent.
- A whole-value expression takes the expression's type: `${{ vars.gzip }}` alone
  in a boolean field evaluates to a boolean. Interpolated into surrounding text
  it is always a string, and a boolean field then fails. A var value that parses
  as JSON becomes that JSON, so a var can carry a list into an array field.
- Var defaults may reference `ctx` and previously declared vars, so declare them
  in dependency order.
- Tasks do not nest — Kargo validates a task's steps as
  `has(self.uses) && !has(self.task)`. A two-part flow is two task references in
  the calling Stage.
- Field access in expressions uses **Go field names**, not JSON keys:
  `commitFrom(...).ID`, `.RepoURL`, `imageFrom(...).Digest`, `.Tag`. Kargo
  compiles expressions with a plain `expr.Compile` and its API types carry no
  `expr:` tags, so `expr`'s `runtime.Fetch` matches the field name exactly.
  Lowercase spellings appear in some upstream docs examples and do not work.
- Read the step's schema in
  `pkg/promotion/runner/builtin/schemas/<step>-config.json`, not just the docs
  page: the published docs describe the last release, and a step whose behaviour
  you depend on may only have it on `main`.

Test a task against those schemas. [`oci/test/`](oci/test) is the pattern:
`lint-task.py` checks each task against vendored, pinned copies of Kargo's own
schemas and adds the cross-step rules no schema can express, `tasks.bats` drives
it with one negative-control fixture per check, and `e2e-recipe.bats` runs the
pipeline the task describes against real tools. Vendor only the schemas the
family uses, and record the upstream commit they came from.

## Image conventions

- No `RUN` instructions. Copy binaries out of upstream images
  (`COPY --from=ghcr.io/…`). The build then needs no emulation for arm64 and
  carries no package manager.
- `busybox:*-musl` as the final base when the step needs `/bin/sh`; add `jq` from
  `ghcr.io/jqlang/jq` for JSON. Copy the CA bundle from an upstream image if the
  tool makes TLS calls.
- Pin tool versions in `ARG`s (e.g. `KYVERNO_VERSION`) and record them as labels.
- `COPY --chmod=0755` the entrypoint script, and keep the file executable in git.
- `USER 65532:65532`, `WORKDIR /workdir`.

## Step script conventions

POSIX `sh`, `set -eu`, and shellcheck-clean under `--shell=sh`. The following
have all caused silent passes here:

- `jq`'s `//` treats `false` as empty — use `if has($k) …` for config lookups, or
  a configured `false` becomes your default.
- `fatal` cannot exit from the left-hand side of a pipeline or from a command
  substitution: the `exit` kills only the subshell. Validate config once at top
  level, and redirect (`f > out`) rather than pipe (`f | sort > out`) when the
  function must be able to abort the script.
- Never iterate a token string unquoted (`for p in $PATHS`) — the shell
  pathname-expands each token against the working directory first, so a glob the
  user meant as a pattern silently becomes whatever happens to be lying around.
  Keep token lists in files and read them with `while IFS= read -r`.
- `set --` inside a function is function-local, but it clears that function's
  `$1`/`$2` — save them first.
- Emit progress to stdout as you go: it lands in the step's result message, which
  is what an operator reads when a promotion fails.
- Never claim more than was checked. A summary that says "manifests comply" when
  violations were merely tolerated ends up in a commit message.

## Testing

Tests are [bats](https://github.com/bats-core/bats-core). `test/helpers.bash`
holds `run_step`, which drives the image exactly as Kargo does — fixtures
mounted as the working directory, config in the step's config env var, results
read back from the file named by `$KARGO_OUTPUT` — plus assertions on the exit
code and that JSON. `test/<step>.bats` is one `@test` per behaviour. Add a
fixture and a case for every behaviour you rely on, and one for every bug you
fix. A finding without a test will come back.

Two things to know about writing the helpers, since bats runs every case under
`set -e` where a plain script would not:

- A command substitution that legitimately fails — `grep -c` returning 0
  matches, a `jq` filter erroring on an empty document — aborts the case at the
  assignment, before your comparison runs, so the failure surfaces with no
  diagnostics. End those with `|| true`.
- Capture a step's exit code as `LOG="$(docker run …)" && STATUS=0 || STATUS=$?`.
  Most cases expect a non-zero exit, and anything less guarded kills the case.

Have each assertion print the exit code, the output JSON and the whole step log
on failure. bats shows it only for the case that failed, so there is no reason
to be terse.

`test/e2e-chart.bats` renders `<family>/examples/` the way the promotion step
before it would, then validates the output, so the cases exercise real rendered
input rather than hand-written manifests. The render belongs in `setup_file`,
which runs once for the whole file rather than per case.

Keep it a separate file from the behaviour tests and name both explicitly in the
`Makefile`: `bats test/` would sweep up the e2e file too, and then `make test`
needs helm.

From the family directory:

```console
make lint    # shellcheck
make test    # behaviour tests against a locally built image (needs bats)
make e2e     # example fixtures end to end
make all
```

## CI

For a step, copy `.github/workflows/kyverno-validate.yaml` and change the
paths, the image name and the tag prefix. Its shape is deliberate:

- lint → test → publish, with `publish` needing both. Nothing untested is pushed.
- `paths:` filters are repo-root-relative; `../` is invalid there. They belong on
  `pull_request` only — a `push` trigger that carries tags cannot use them
  reliably, since a tag's diff is not the step's.
- `publish` needs `packages: write` and `id-token: write` (cosign keyless).
- Set `org.opencontainers.image.title`/`description` explicitly in
  `docker/metadata-action`, or it derives them from the repository and overrides
  the Dockerfile's, leaving every step image advertising itself as the repo.
- Release by tag: `<step>/vX.Y.Z` publishes `:vX.Y.Z`, `:vX.Y` and `:latest`;
  pushes to `main` publish `:main` and `:sha-<sha>`. Pin a released tag in the
  `CustomPromotionStep` manifest.

For a task family, copy `.github/workflows/oci-tasks.yaml`: lint, test, e2e and
no publish job, since there is no artifact and a merge to `main` is the release.
One workflow per family rather than per task — the suites cover the family.

## Before you call it done

1. `make lint && make test && make e2e` from the family directory.
2. For a step: `docker buildx build --platform linux/amd64,linux/arm64 --output
   type=cacheonly .` in the step directory — arm64 breaks in ways amd64 does
   not.
3. For a step, after CI publishes, run the suite against the published image:
   `IMAGE=ghcr.io/<owner>/<repo>/<step>:main bats test/`. It is the only check
   that what the registry holds behaves like what you built.
4. For a task, run a real promotion. The suites check a task against Kargo's
   schemas and its recipe against real tools, but nothing here executes Kargo,
   so nothing here proves the task runs. Register it, promote once, and verify
   the outcome by hand.
5. Report what you actually ran, and say plainly what you did not. "Tests pass"
   means you ran them; a task nobody has promoted is a task nobody has run.
