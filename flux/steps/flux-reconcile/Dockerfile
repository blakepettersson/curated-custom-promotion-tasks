# syntax=docker/dockerfile:1

# Minimal image for the flux-reconcile Kargo custom promotion step: busybox
# (for /bin/sh), the flux CLI, kubectl and jq. Nothing is compiled or
# installed, so the image builds for every platform its bases support without
# emulation.
#
# `flux reconcile` does the reconciling. kubectl reads the status fields it
# cannot be asked about: which revision was applied, and why a reconcile that
# timed out never turned Ready.

ARG FLUX_VERSION=v2.9.5
ARG KUBECTL_VERSION=v1.35.8
ARG JQ_VERSION=1.8.1
ARG BUSYBOX_VERSION=1.37.0-musl

FROM ghcr.io/fluxcd/flux-cli:${FLUX_VERSION} AS flux
FROM registry.k8s.io/kubectl:${KUBECTL_VERSION} AS kubectl
FROM ghcr.io/jqlang/jq:${JQ_VERSION} AS jq

FROM busybox:${BUSYBOX_VERSION}

ARG FLUX_VERSION
ARG KUBECTL_VERSION
LABEL org.opencontainers.image.title="flux-reconcile" \
      org.opencontainers.image.description="Kargo custom promotion step that reconciles Flux Kustomizations and HelmReleases and waits for the promoted revision" \
      org.opencontainers.image.source="https://github.com/blakepettersson/curated-custom-promotion-tasks" \
      io.fluxcd.flux.version="${FLUX_VERSION}" \
      io.kubernetes.kubectl.version="${KUBECTL_VERSION}"

COPY --from=flux /usr/local/bin/flux /usr/local/bin/flux
COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl
# For API servers behind a publicly trusted certificate, whose kubeconfig
# carries no certificate-authority-data.
COPY --from=kubectl /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=jq /jq /usr/local/bin/jq
COPY --chmod=0755 src/flux-reconcile /usr/local/bin/flux-reconcile

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    HOME=/tmp

# Kargo runs custom step containers as 65532:65532.
USER 65532:65532
WORKDIR /workdir

ENTRYPOINT ["/usr/local/bin/flux-reconcile"]
