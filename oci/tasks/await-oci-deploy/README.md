# `await-oci-deploy`

Waits for something Kargo cannot reach to report that it is running a given
artifact digest.

```
http (poll) → compose-output
```

For a Stage whose cluster Kargo has no route to — an air-gapped enclave, a
customer-managed cluster, anything behind a one-way boundary — so
[`deploy-oci-to-argocd`](../deploy-oci-to-argocd) is not an option. The
promotion mirrors the artifact across the boundary, then blocks here until a
status endpoint *both sides can reach outbound* reports the digest live.

Neither side has to accept inbound connections. The enclave pushes its status
out; Kargo polls the same place. That is the only shape that works when the
boundary is one-way, which it usually is.

## Vars

| Var | Default | Description |
|---|---|---|
| `statusURL` | *required* | Endpoint to poll. Must be reachable from the Kargo controller. |
| `digest` | `${{ freightMetadata(…).ociManifests.digest }}` | The digest the endpoint must report. Defaults to what [`publish-manifests-to-oci`](../publish-manifests-to-oci) recorded on the Freight. |
| `revisionField` | `revision` | The JSON field of the response carrying the digest currently deployed. |

## Outputs

| Output | Description |
|---|---|
| `revision` | The digest the endpoint reported. |
| `status` | The HTTP status of the successful poll. |
| `statusURL` | Echoed back. |

[`examples/status-contract.md`](examples/status-contract.md) is the endpoint
contract: what each status code means, what the enclave has to publish, and the
one mistake that makes this gate worthless.

## Why it compares digests

The success expression checks `response.body.revision == "<digest>"`, not merely
that the endpoint is healthy. An endpoint will normally be reporting the
*previous* digest when polling starts, so a bare health check succeeds on the
first poll and the promotion reports a rollout that has not happened.

A `404` is treated as neither success nor failure. An enclave that has never
deployed this application yet is not an error, so it falls through to Running
and is retried.

## Two things the step's shape forces

**`successExpression` is evaluated with only `response` in scope** — no `vars`,
no `ctx`. So the digest is interpolated into the expression's *text* by the
config templating rather than referenced from inside it. This is why the task
declares `digest` as a var and builds the expression around it.

**`retry.timeout` cannot be a var.** It is a typed duration on the step rather
than part of `config`, so it is never expression-templated: `${{ vars.timeout }}`
there fails as a duration that will not parse. It is fixed at `1h`; an enclave
with different patience needs its own copy of this task. `test/lint-task.py`
rejects an expression there, because nothing else would notice.

## What this is not

It is a gate, not a deploy. Nothing here causes the rollout, so an enclave that
never rolls out produces a timeout rather than a failure with a cause. If you
have any route inward at all — even an outbound-only Kargo controller shard
running *inside* the enclave — prefer that: see
[the family README](../../README.md#air-gapped-stages).

## Examples

- [`examples/stage.yaml`](examples/stage.yaml) — mirror the artifact across the
  boundary by digest, then wait for confirmation.
- [`examples/status-contract.md`](examples/status-contract.md) — the endpoint
  contract.
