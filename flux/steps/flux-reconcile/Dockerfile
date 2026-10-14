# syntax=docker/dockerfile:1

# Minimal image for the flux-reconcile Kargo custom promotion step: busybox (for
# /bin/sh), kubectl and jq. Nothing is compiled or installed, so the image
# builds for every platform its bases support without emulation.
#
# kubectl rather than the flux CLI: the step has to check which revision Flux
# applied, which `flux reconcile` does not, and with kubectl it reads exactly
# the status fields it decides on. See src/flux-reconcile.

ARG KUBECTL_VERSION=v1.35.8
ARG JQ_VERSION=1.8.1
ARG BUSYBOX_VERSION=1.37.0-musl

FROM registry.k8s.io/kubectl:${KUBECTL_VERSION} AS kubectl
FROM ghcr.io/jqlang/jq:${JQ_VERSION} AS jq

FROM busybox:${BUSYBOX_VERSION}

ARG KUBECTL_VERSION
LABEL org.opencontainers.image.title="flux-reconcile" \
      org.opencontainers.image.description="Kargo custom promotion step that reconciles Flux Kustomizations and HelmReleases and waits for the promoted revision" \
      org.opencontainers.image.source="https://github.com/blakepettersson/curated-custom-promotion-tasks" \
      io.kubernetes.kubectl.version="${KUBECTL_VERSION}"

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
