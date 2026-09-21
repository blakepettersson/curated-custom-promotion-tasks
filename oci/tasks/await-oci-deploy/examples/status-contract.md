# The status endpoint contract

`await-oci-deploy` polls a URL until it reports the digest the promotion
published. The endpoint is the whole interface across the boundary, so it is
worth being explicit about what it has to do.

## What Kargo expects

A `GET` returning JSON. By default the task reads `.revision`:

```json
{ "revision": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" }
```

- **`200` with a matching `revision`** — success. The promotion completes.
- **`200` with any other `revision`** — not yet. The step reports Running and
  polls again. This is the case that matters: the endpoint will usually be
  reporting the *previous* digest, and a task that checked only for a healthy
  status would succeed immediately against it.
- **`404`** — nothing has reported yet. Also Running, also retried. An enclave
  that has never deployed this application is not a failure.
- **`4xx` other than `404`, or `5xx`** — failure. The promotion fails now rather
  than waiting out the timeout.
- **No response at all, for an hour** — the task's `retry.timeout` expires and
  the promotion fails.

Set `revisionField` if your endpoint names the field something else.

## What the enclave has to do

Push its state outward. Anything that can write to the endpoint works: a
CronJob reading `Application.status.sync.revision` and POSTing it, a sidecar, an
Argo CD notification trigger. The direction is the point — the enclave makes an
outbound call, and neither it nor Kargo has to accept an inbound one.

Report the digest **actually running**, read back from the cluster. An endpoint
that echoes the digest it was *told to deploy* turns this gate into a very slow
way of confirming that the mirror step ran, which the mirror step already
confirmed.

## What this cannot do

If nothing can cross the boundary in either direction, no endpoint exists and
this task has nothing to poll. See
[the family README](../../../README.md#air-gapped-stages) for what to do
instead — the short version being: stop modelling the enclave as a Kargo Stage,
and let the artifact be the entire interface.
