#!/usr/bin/env bats
# shellcheck disable=SC2034  # CONTEXT is read by fail_with in helpers.bash
# Runs the tasks in a real Kargo: a kind cluster, the Kargo chart, a registry
# and a Git server, and a promotion that calls
# tasks/publish-manifests-to-oci/cluster-promotion-task.yaml itself.
#
#   bats test/e2e-kargo.bats
#
# Needs docker, kind, kubectl, helm, git and curl. Takes a few minutes: the
# cluster, cert-manager and Kargo are built once in setup_file, and every case
# reads the results of the two promotions it runs.
#
# Why this suite exists
# ---------------------
# e2e-recipe.bats runs a *replica* of the `tar` and `oci-push` steps, written
# from reading their source. It establishes the recipe is sound and nothing
# more. These cases run the steps themselves, so they are the ones that can say
# Kargo's implementation agrees: that `oci-push`'s srcPath mode publishes the
# layer media type the tasks count on, that the retag really republishes one
# digest, that `set-metadata` lands where `deploy-oci-to-argocd` reads it, and
# that `helm-template`'s flat layout unpacks where an Argo CD Application with
# no `path` will look.
#
# It is also the only check on this repository's manifests as manifests: the
# tasks are applied to a real Kargo, so their CRD schema and CEL rules are
# enforced by the thing that will enforce them in production, not by the
# vendored schemas in test/schemas.
#
# Keeping the cluster between runs, which makes iterating bearable:
#
#   KARGO_E2E_KEEP=1 bats test/e2e-kargo.bats
#
# Everything in setup_file is idempotent, so a kept cluster is reused.

setup_file() {
  load helpers
  require docker kind kubectl helm git curl || return 1

  start_cluster
  deploy_infra
  install_kargo
  seed_git_repo
  apply_project

  # The shape under test: one clone, one render per Stage, one artifact.
  promote test promotion
  # The negative control, in its own Stage against its own repository.
  promote ungzipped ungzipped-promotion

  start_registry_forward
}

teardown_file() {
  load helpers
  stop_registry_forward
  if [ -n "${KARGO_E2E_KEEP:-}" ]; then
    say "keeping the kind cluster $KARGO_CLUSTER (KARGO_E2E_KEEP is set)"
  else
    delete_cluster
  fi
}

setup() {
  load helpers
  use_registry
  OCI_REPO_PATH="config/example-app"
  UNGZIPPED_REPO_PATH="config/ungzipped"
}

# Reads `.spec.replicas` out of whichever rendered file holds the Deployment.
# By name would be brittle: `helm-template`'s flat layout names files after the
# resource, not after the template they came from.
deployment_replicas() { # dir
  local file
  file="$(grep -rl 'kind: Deployment' "$1" | head -1)"
  [ -n "$file" ] || fail_with "no Deployment manifest under $1" || return 1
  q "$file" '.spec.replicas'
}

# Pulls the artifact's single layer and unpacks it. The layer digest comes from
# the manifest, as any client reading the artifact would take it.
unpack_artifact() { # repo-path tag out-dir
  local digest tarball="$BATS_TEST_TMPDIR/layer.tar.gz"
  digest="$(fetch_manifest "$1" "$2" | jqq -r '.layers[0].digest')"
  fetch_blob "$1" "$digest" "$tarball"
  mkdir -p "$3"
  tar -C "$3" -xzf "$tarball"
  printf '%s' "$tarball"
}

# --------------------------------------------------------------- the promotion

@test 'a real Kargo promotion through publish-manifests-to-oci succeeds' {
  # The check oci/README.md asks for before relying on these tasks, and the one
  # no amount of schema linting can stand in for.
  assert_promotion_succeeded promotion
}

@test 'the task exposes the outputs its README promises' {
  local digest ref tag mutable repo
  digest="$(promotion_output promotion publish '.digest')"
  ref="$(promotion_output promotion publish '.ref')"
  tag="$(promotion_output promotion publish '.tag')"
  mutable="$(promotion_output promotion publish '.mutableTag')"
  repo="$(promotion_output promotion publish '.ociRepo')"
  CONTEXT="ref=$ref digest=$digest tag=$tag mutableTag=$mutable"

  case "$digest" in sha256:*) ;; *) fail_with "digest is not a digest: $digest" ;; esac
  assert_equal "$ref" "$repo@$digest" 'ref must be the digest-pinned reference'
  assert_equal "$mutable" "test" 'mutableTag defaults to the publishing stage'
  # The immutable tag defaults to the promotion's name, which is what makes a
  # rollback a tag that already exists.
  assert_equal "$tag" "$(kargo_state promotion)" 'tag defaults to the promotion'
}

@test 'both tags resolve to one digest, as the retag step intends' {
  local pushed immutable mutable
  pushed="$(promotion_output promotion publish '.digest')"
  immutable="$(resolve_digest "$OCI_REPO_PATH" "$(kargo_state promotion)")"
  mutable="$(resolve_digest "$OCI_REPO_PATH" test)"
  CONTEXT="pushed=$pushed immutable=$immutable mutable=$mutable"

  assert_equal "$immutable" "$pushed" 'the immutable tag must resolve to the pushed digest'
  # The retag republishes the manifest bytes untouched, so the mutable tag has
  # to land on the same digest. If it did not, a downstream Warehouse would see
  # a different artifact than the one this promotion recorded.
  assert_equal "$mutable" "$pushed" 'the mutable tag must resolve to the same digest'
}

# --------------------------------------------------------------- the artifact

@test 'the published artifact is the OCI 1.1 shape Argo CD can read' {
  local manifest
  manifest="$(fetch_manifest "$OCI_REPO_PATH" test)"
  CONTEXT="$manifest"

  assert_equal "$(printf '%s' "$manifest" | jqq -r '.mediaType')" \
    'application/vnd.oci.image.manifest.v1+json' 'the manifest media type'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.artifactType')" \
    'application/vnd.unknown.artifact.v1' 'the artifact type oci-push defaults to'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.config.mediaType')" \
    'application/vnd.oci.empty.v1+json' 'the config media type'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.layers | length')" \
    '1' 'the layer count'

  # The allow-list is why the tasks leave mediaType unset and take the default.
  assert_argocd_readable_layer_type \
    "$(printf '%s' "$manifest" | jqq -r '.layers[0].mediaType')"
}

@test 'the published layer really is gzip, not a plain tar wearing the label' {
  # The trap this family exists to close, asserted against the bytes a real
  # promotion published rather than against a replica of the steps.
  local tarball
  tarball="$(unpack_artifact "$OCI_REPO_PATH" test "$BATS_TEST_TMPDIR/unpacked")"
  assert_gzipped "$tarball"
  run gzip -t "$tarball"
  [ "$status" -eq 0 ] || fail_with "gzip rejected the published layer: $output"
}

@test 'the artifact carries the provenance annotations the task stamps on it' {
  local manifest
  manifest="$(fetch_manifest "$OCI_REPO_PATH" test)"
  CONTEXT="$manifest"

  # With a Warehouse boundary these annotations are the only way back from an
  # artifact to the commit that produced it, which is why the task sets them.
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.annotations["org.opencontainers.image.source"]')" \
    "$(kargo_state git-repo)" 'the source annotation'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.annotations["org.opencontainers.image.revision"]')" \
    "$(kargo_state commit)" 'the revision annotation must be the Freight commit'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.annotations["io.kargo.project"]')" \
    "$KARGO_PROJECT" 'the project annotation'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.annotations["io.kargo.stage"]')" \
    'test' 'the stage annotation'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.annotations["io.kargo.promotion"]')" \
    "$(kargo_state promotion)" 'the promotion annotation'
}

# ------------------------------------------------- one artifact, every stage

@test 'one artifact holds one directory per stage, each rendered with its own values' {
  local out="$BATS_TEST_TMPDIR/unpacked"
  unpack_artifact "$OCI_REPO_PATH" test "$out" > /dev/null
  CONTEXT="$(find "$out" -type f | sed "s|$out/||" | tr '\n' ' ')"

  [ -d "$out/test" ] || fail_with 'no test/ directory in the artifact'
  [ -d "$out/prod" ] || fail_with 'no prod/ directory in the artifact'
  # Nothing at the root: an Application selects its Stage with `path`, so a file
  # loose at the root would be applied by every Stage.
  local loose
  loose="$(find "$out" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  assert_equal "$loose" "0" 'no manifest may sit at the root of a per-stage artifact'

  # The claim the "hydrate once for every Stage" shape rests on: prod's copy is
  # prod's render, produced in the same promotion as test's. If these agreed,
  # one artifact would be shipping the wrong manifests to one of the two.
  local test_replicas prod_replicas
  test_replicas="$(deployment_replicas "$out/test")"
  prod_replicas="$(deployment_replicas "$out/prod")"
  CONTEXT="test=$test_replicas prod=$prod_replicas"
  # The chart has no values-test.yaml, so test takes the chart's default — which
  # also says `ignoreMissingValueFiles` did what the render steps rely on.
  assert_equal "$test_replicas" "1" 'test replicas (chart default, no values-test.yaml)'
  assert_equal "$prod_replicas" "3" 'prod replicas (values-prod.yaml)'
}

@test 'the CRDs the chart renders are in the artifact' {
  local out="$BATS_TEST_TMPDIR/unpacked"
  unpack_artifact "$OCI_REPO_PATH" test "$out" > /dev/null
  CONTEXT="$(find "$out" -type f | sed "s|$out/||" | tr '\n' ' ')"
  # includeCRDs is set on every render step in the examples: crds/ is not
  # rendered otherwise, and nothing downstream of the artifact would apply it.
  grep -rq 'kind: CustomResourceDefinition' "$out/prod" ||
    fail_with 'no CRD in the artifact — includeCRDs did not take effect'
}

# --------------------------------------------------------- the freight record

@test 'the digest is recorded on the Freight, where a downstream Stage reads it' {
  local digest
  digest="$(promotion_output promotion publish '.digest')"
  CONTEXT="$(freight_metadata '.ociManifests')"

  # `deploy-oci-to-argocd` reads exactly these keys by default. One Freight
  # carries the manifests through the pipeline; nothing downstream re-renders.
  assert_equal "$(freight_metadata '.ociManifests.digest')" "$digest" 'the recorded digest'
  assert_equal "$(freight_metadata '.ociManifests.repo')" \
    "$(kargo_state oci-repo)" 'the recorded repository'
  assert_equal "$(freight_metadata '.ociManifests.tag')" \
    "$(kargo_state promotion)" 'the recorded immutable tag'
  assert_equal "$(freight_metadata '.ociManifests.mutableTag')" 'test' 'the recorded mutable tag'
}

# ------------------------------------------------------------ the manifests

@test 'every task in tasks/ is accepted by a real Kargo' {
  # A server-side dry run puts the tasks through the CRD's structural schema and
  # its CEL rules — including `has(self.uses) && !has(self.task)`, which is why
  # hydrate-then-deploy is two task references rather than one nested task. The
  # vendored schemas in test/schemas cannot check any of that.
  local task output
  for task in "$TASKS_DIR"/*/cluster-promotion-task.yaml; do
    output="$(kube apply --dry-run=server -f "$task" 2>&1)" || {
      CONTEXT="$output"
      fail_with "real Kargo rejected $(basename "$(dirname "$task")")" || return 1
    }
  done
}

# ------------------------------------------------------- the negative control

@test 'a task that forgets gzip goes green and publishes a layer nothing can read' {
  # The whole reason the linter and e2e-recipe.bats check compression, now
  # established against real Kargo rather than against a replica: `tar` defaults
  # to no compression, `oci-push` defaults the layer media type to `...+gzip`,
  # and neither step nor registry objects.
  assert_promotion_succeeded ungzipped-promotion

  local manifest digest tarball
  manifest="$(fetch_manifest "$UNGZIPPED_REPO_PATH" latest)"
  CONTEXT="$manifest"
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.layers[0].mediaType')" \
    'application/vnd.oci.image.layer.v1.tar+gzip' 'the layer claims to be gzipped'

  digest="$(printf '%s' "$manifest" | jqq -r '.layers[0].digest')"
  tarball="$BATS_TEST_TMPDIR/ungzipped.tar.gz"
  fetch_blob "$UNGZIPPED_REPO_PATH" "$digest" "$tarball"

  # Probed with `gzip -t` rather than `tar -tzf`: libarchive, which is macOS's
  # tar, sniffs the format and reads an uncompressed archive despite -z. Argo
  # CD's repo-server does not — it trusts the media type and decompresses.
  run gzip -t "$tarball"
  [ "$status" -ne 0 ] || {
    printf 'assertion failed: the layer this control publishes is gzipped, so it proves nothing\n'
    printf '  either the tar step now compresses by default, or the fixture changed\n'
    return 1
  }
}
