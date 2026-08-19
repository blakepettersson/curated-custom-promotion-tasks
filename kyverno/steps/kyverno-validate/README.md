# `kyverno-validate`

A Kargo custom promotion step that validates Kyverno policies with the Kyverno
CLI, and optionally validates a set of manifests against those policies. It
takes two inputs — a path holding **policies** and a path holding the
**manifests** to check — either of which may be a file, a directory or a glob.

```yaml
- uses: kyverno-validate
  as: validate
  config:
    policies: ./rendered           # dir, file or glob of Kyverno policies
    manifests: ./src/manifests     # dir, file or glob of manifests to check
```

The step fails the promotion when a policy is not loadable by Kyverno, or when a
manifest violates one of the policies.

## Why the step does more than call `kyverno apply`

`kyverno apply` is not a validator on its own. Given a policy file it cannot
parse, it logs a message only at `-v 3`, applies whatever remains and **exits
0**. When the policy argument is a *directory*, one unparsable file makes it skip
the entire directory — still exiting 0, having applied nothing:

```console
$ kyverno apply policies -r pod.yaml   # policies/ holds one malformed file
Applying 0 policy rule(s) to 1 resource(s)...
pass: 0, fail: 0, warn: 0, error: 0, skip: 0
$ echo $?
0
```

A promotion gate built on that exit code passes every broken policy set. So the
step runs in phases:

1. **load** — each policy file is loaded on its own, and the CLI's log is parsed
   for load failures, so every rejected file is reported with its path and
   reason. A file that is valid YAML but is not a Kyverno policy (charts often
   render ConfigMaps, workloads or unrelated CRDs next to policies) is skipped,
   not failed — but a file that *declares* a Kyverno policy kind and still
   contributes no rules is failed, since that is what a Helm `range` over an
   empty list renders and it would install as a no-op. The step also fails when
   *no* policy rules were found at all, which catches an empty render or a wrong
   path.
2. **apply** — the policies that loaded are applied to the manifests, and the
   resulting policy report decides the outcome. Runs when `manifests` is set. If
   no policy matches any manifest the report comes back empty, which is reported
   as such and is not a failure.
3. **test** — `kyverno test` runs any Kyverno test suites. Runs when `tests` is
   set.

## Configuration

| Key | Type | Default | Description |
|---|---|---|---|
| `policies` | string or list | — | **Required.** Files, directories or globs holding Kyverno policies. Directories are searched recursively for `.yaml`, `.yml` and `.json`. |
| `manifests` | string or list | — | Files, directories or globs holding the manifests to validate against the policies. Omit to only check that the policies themselves are valid. `resources` is accepted as an alias. |
| `failOn` | string | `fail` | Which policy results fail the step: `fail` (failures and errors), `error` (errors only), `warn` (warnings too), or `none` (report only). |
| `exceptions` | string or list | — | `PolicyException` manifests to take into account. |
| `tests` | string or list | — | Directories or files to hand to `kyverno test`. |
| `valuesFile` | string | — | Kyverno CLI values file, for policies that reference variables. |
| `exclude` | string or list | — | Globs matched against each policy path and basename; matches are skipped. |
| `requirePolicies` | bool | `true` | Fail when the `policies` paths yield no policy rules. With `false` and no rules loaded, the apply phase is skipped — the manifests are *not* checked, and `applied` and `message` say so. |
| `detailedResults` | bool | `false` | Pass `--detailed-results` to `kyverno apply`. |
| `maxViolations` | int | `20` | Maximum number of violations included in the step output. |
| `extraArgs` | string or list | — | Extra flags for `kyverno apply`, e.g. `--cluster-wide-resources`. |

Values may be written as a YAML list or as a comma-separated string:

```yaml
config:
  policies:
    - ./rendered/policies
    - ./src/extra-policy.yaml
  manifests: ./src/manifests, ./src/overlays
```

Files named `kyverno-test.yaml` are never treated as policies.

## Output

| Key | Type | Description |
|---|---|---|
| `passed` | bool | Whether validation passed. |
| `message` | string | One-line summary, suitable for a commit message or notification. States tolerated violations and a skipped apply phase rather than claiming compliance. |
| `policyFileCount` | int | Policy files examined. |
| `nonPolicyFileCount` | int | Files that held no Kyverno policies. |
| `ruleCount` | int | Policy rules loaded (including Kyverno's auto-generated rules). |
| `loadErrorCount` | int | Files Kyverno refused to load. |
| `loadErrors` | list | `{file, error}` for each rejected file. |
| `applied` | bool | Whether the apply phase ran. |
| `manifestCount` | int | Manifests validated. |
| `tested` | bool | Whether the test phase ran. |
| `summary` | object | `{pass, fail, warn, error, skip}` counts from the policy report. |
| `violationCount` | int | Failing plus erroring results. |
| `violations` | list | `{policy, rule, result, resource, message}`, capped at `maxViolations`. |

```yaml
- uses: kyverno-validate
  as: validate
  config:
    policies: ./rendered
    manifests: ./src/manifests
    failOn: none
- uses: fail
  if: ${{ outputs.validate.violationCount > 5 }}
  config:
    message: ${{ outputs.validate.message }}
```

Exit codes: `0` valid, `1` validation failed, `2` misconfiguration (a required
key missing, a path that matches nothing, an unusable value).

## Registering the step

```console
kargo login https://<your-kargo-instance>
kargo apply -f custom-promotion-step.yaml
```

`kargo`, not `kubectl`: custom steps only exist on Kargo hosted by the Akuity
Platform, whose control plane you do not have direct access to, so resources go
in through the Kargo API.

The manifest is pinned to
`ghcr.io/blakepettersson/curated-custom-promotion-tasks/kyverno-validate:v0.1.0`.
`:main` tracks every push to the default branch if you would rather follow along,
and a digest makes it immutable.

`CustomPromotionStep` is cluster-scoped and requires Kargo on the Akuity
Platform v1.10+, with the Promotion Controller enabled and a self-hosted agent —
custom steps run as pods. Registration is a cluster-admin action; project
authors then reference the step by name.

See [`examples/`](examples) for a `ClusterPromotionTask` that renders a Helm
chart of policies and validates it, plus a `Stage` that uses it.

## The image

`busybox` (for `/bin/sh`), plus three files: the Kyverno CLI binary, `jq`, and
the step script. Nothing is compiled or installed, so `linux/amd64` and
`linux/arm64` — the platforms Kargo supports — build from the same instructions
without emulation, and the image carries no package manager, no shell utilities
beyond busybox and no CA bundle beyond the one the CLI ships with.

The Kyverno CLI binary is ~290 MB on its own and dominates the image; the step
adds roughly 3 MB to it. Pin the CLI version with the `KYVERNO_VERSION` build
argument (the current default is in the [`Dockerfile`](Dockerfile)).

The container runs as uid 65532, as Kargo requires, and needs no filesystem
access outside the promotion workspace.

## Working on it locally

From the `kyverno/` directory:

```console
make build          # docker build
make lint           # shellcheck
make test           # behaviour tests against the built image
make e2e            # renders examples/kyverno-policies and validates it
```

The tests drive the image the way Kargo does: fixtures mounted as the working
directory, config in `KYVERNO_VALIDATE_CONFIG`, results read back from the file
named by `KARGO_OUTPUT`.

To drive it by hand, from this directory:

```console
docker run --rm -v "$PWD/test/fixtures:/workdir:ro" -w /workdir \
  -e KYVERNO_VALIDATE_CONFIG='{"policies": "policies", "manifests": "resources"}' \
  kyverno-validate:dev
```

## Limitations

- The step has no cluster connection, so policies whose `context` reads live
  cluster state cannot be fully evaluated; those rules surface as `error`
  results. Supply a `valuesFile`, or set `failOn: none` for such policy sets —
  note that `failOn: error` fails on exactly those results.
- Kyverno has no CLI command that reports *deprecated* policy syntax, so the
  step cannot warn about fields that still load but are on their way out.
- Policy results depend on the CLI version in the image, not on the Kyverno
  version installed in the target cluster. Keep `KYVERNO_VERSION` aligned with
  the clusters you promote to.
