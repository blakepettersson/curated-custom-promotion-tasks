# syntax=docker/dockerfile:1

# Minimal image for the kyverno-validate Kargo custom promotion step: busybox
# (for /bin/sh), the Kyverno CLI, and jq. Nothing is compiled or installed, so
# the image builds for every platform its bases support without emulation.

ARG KYVERNO_VERSION=v1.18.2
ARG JQ_VERSION=1.8.1
ARG BUSYBOX_VERSION=1.37.0-musl

FROM ghcr.io/kyverno/kyverno-cli:${KYVERNO_VERSION} AS kyverno
FROM ghcr.io/jqlang/jq:${JQ_VERSION} AS jq

FROM busybox:${BUSYBOX_VERSION}

ARG KYVERNO_VERSION
LABEL org.opencontainers.image.title="kyverno-validate" \
      org.opencontainers.image.description="Kargo custom promotion step that validates Kyverno policies with the Kyverno CLI" \
      org.opencontainers.image.source="https://github.com/blakepettersson/curated-custom-promotion-tasks" \
      io.kyverno.cli.version="${KYVERNO_VERSION}"

COPY --from=kyverno /ko-app/kubectl-kyverno /usr/local/bin/kyverno
COPY --from=kyverno /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=jq /jq /usr/local/bin/jq
COPY --chmod=0755 src/kyverno-validate /usr/local/bin/kyverno-validate
COPY src/probe.yaml /etc/kyverno-validate/probe.yaml

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    HOME=/tmp

# Kargo runs custom step containers as 65532:65532.
USER 65532:65532
WORKDIR /workdir

ENTRYPOINT ["/usr/local/bin/kyverno-validate"]
