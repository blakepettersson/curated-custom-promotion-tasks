# Working in this repository

Kargo custom promotion steps: a container image per step, the
`CustomPromotionStep` manifest that registers it, promotion tasks that compose
it, and CI that builds, tests and publishes the image.

Read [`README.md`](README.md) for the layout and
[`kyverno/steps/kyverno-validate`](kyverno/steps/kyverno-validate) as the
reference implementation. Everything below is what a new step has to get right.

## Where things go

One directory per tool family (`kyverno/`, and siblings to come), one directory
per step beneath it:

```
<family>/Makefile                          build, lint, test, e2e for the family
<family>/steps/<step>/Dockerfile
<family>/steps/<step>/src/<step>           entrypoint script (executable, 0755)
<family>/steps/<step>/custom-promotion-step.yaml
<family>/steps/<step>/examples/            promotion task + stage
<family>/steps/<step>/test/<step>.bats     behaviour tests (bats)
<family>/steps/<step>/test/e2e-chart.bats  the family's examples, end to end
<family>/steps/<step>/test/helpers.bash    run_step + assertions the .bats files load
<family>/steps/<step>/test/fixtures/
<family>/examples/                         fixtures a real project would hold
.github/workflows/<step>.yaml              one workflow per step
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

Copy `.github/workflows/kyverno-validate.yaml` and change the paths, the image
name and the tag prefix. Its shape is deliberate:

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

## Before you call it done

1. `make lint && make test && make e2e` from the family directory.
2. `docker buildx build --platform linux/amd64,linux/arm64 --output type=cacheonly .`
   in the step directory — arm64 breaks in ways amd64 does not.
3. After CI publishes, run the suite against the published image:
   `IMAGE=ghcr.io/<owner>/<repo>/<step>:main bats test/`. It is the only check
   that what the registry holds behaves like what you built.
4. Report what you actually ran. "Tests pass" means you ran them.
