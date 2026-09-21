#!/usr/bin/env bats
# shellcheck disable=SC2034  # CONTEXT is read by fail_with in helpers.bash
# Runs the pipeline the hydrate tasks describe against a real registry: render
# oci/examples/example-app, archive it the way the `tar` step does, publish it
# the way `oci-push`'s srcPath mode does, then read it back the way a client
# would.
#
#   bats test/e2e-recipe.bats
#
# Needs docker, curl, helm, kustomize and jq or docker.
#
# What this proves and what it does not
# -------------------------------------
# Kargo is not available here — `oci-push --srcPath` exists only on Kargo's main
# branch — so these cases cannot run the tasks. What they run is a replica of
# the steps' behaviour, built from reading them:
#
#   * `tar` names entries relative to `inPath` and skips the root directory
#     entry (pkg/promotion/runner/builtin/tar_creator.go), so the archive
#     unpacks to a flat root.
#   * `oci-push --srcPath` pushes the file's bytes as the sole layer under the
#     configured media type, with the OCI empty descriptor as the config and
#     `artifactType` on the manifest (oci_pusher.go).
#
# So these cases establish that the *recipe* is sound: that the layout the tasks
# render unpacks where Argo CD looks for it, that the media types they publish
# under are truthful about the bytes, and that a registry and a client accept
# the result. They do not establish that Kargo's implementation agrees byte for
# byte — only running a real promotion can do that, which is what
# `oci/README.md` asks for before a release.

setup_file() {
  load helpers
  require docker curl helm kustomize || return 1
  start_registry

  # Both renders happen once for the whole file rather than per case. Each is
  # what a Stage named "stage" (helm) or "prod" (kustomize) would produce, since
  # those are the values files and overlays the example app carries.
  export E2E_HELM_DIR="$BATS_FILE_TMPDIR/rendered-helm"
  export E2E_KUSTOMIZE_DIR="$BATS_FILE_TMPDIR/rendered-kustomize"
  render_helm stage "$E2E_HELM_DIR"
  render_kustomize prod "$E2E_KUSTOMIZE_DIR"

  # The "hydrate once for every Stage" shape: one directory holding one
  # subdirectory per Stage, published as a single artifact.
  export E2E_ALL_STAGES_DIR="$BATS_FILE_TMPDIR/rendered-all-stages"
  render_helm_all_stages "$E2E_ALL_STAGES_DIR" test stage prod
}

teardown_file() {
  load helpers
  stop_registry
}

setup() {
  load helpers
  use_registry
}

# ------------------------------------------------------------------ rendering

@test 'the helm render produces a flat directory of manifests, CRDs included' {
  CONTEXT="$E2E_HELM_DIR"
  # `outLayout: flat` is the reason there is no chart-named subdirectory: the
  # archive has to unpack to manifests, not to a directory holding them.
  local nested
  nested="$(find "$E2E_HELM_DIR" -mindepth 2 | wc -l | tr -d ' ')"
  assert_equal "$nested" "0" 'the flat layout must leave no subdirectories'

  [ -f "$E2E_HELM_DIR/deployment.yaml" ] || fail_with 'no deployment.yaml'
  [ -f "$E2E_HELM_DIR/service.yaml" ] || fail_with 'no service.yaml'
  # includeCRDs defaults to true in the task, and this is the file that proves
  # it: crds/ is not rendered otherwise, and nothing downstream of the artifact
  # would ever apply it.
  [ -f "$E2E_HELM_DIR/widgets.yaml" ] || fail_with 'no widgets.yaml — CRDs were not included'
}

@test 'the kustomize render applies the overlay for the stage' {
  CONTEXT="$E2E_KUSTOMIZE_DIR"
  local replicas namespace
  replicas="$(q "$E2E_KUSTOMIZE_DIR/apps_v1_deployment_example-app.yaml" '.spec.replicas')"
  namespace="$(q "$E2E_KUSTOMIZE_DIR/apps_v1_deployment_example-app.yaml" '.metadata.namespace')"
  assert_equal "$replicas" "3" 'the prod overlay sets replicas'
  assert_equal "$namespace" "example-app-prod" 'the prod overlay sets the namespace'
}

# ------------------------------------------------------------------ archiving

@test 'the archive is gzip-compressed, as the layer media type claims' {
  # The trap the tasks exist to close: `tar` defaults to gzip: false while
  # oci-push defaults the layer media type to ...tar+gzip. Assert the bytes
  # positively, not just the config.
  local tarball="$BATS_TEST_TMPDIR/manifests.tar.gz"
  archive "$E2E_HELM_DIR" "$tarball"
  assert_gzipped "$tarball"
}

@test 'the archive unpacks to a flat root, so the Argo CD source needs no path' {
  local tarball="$BATS_TEST_TMPDIR/manifests.tar.gz"
  archive "$E2E_HELM_DIR" "$tarball"
  # Every entry must be a bare filename. An entry prefixed with the directory
  # name would mean the manifests land one level down and the Application needs
  # `path: manifests` — which the examples do not set.
  local prefixed
  prefixed="$(tar -tzf "$tarball" | grep -c '/' || true)"
  CONTEXT="$(tar -tzf "$tarball" | tr '\n' ' ')"
  assert_equal "$prefixed" "0" 'no archive entry may carry a directory prefix'
}

# ------------------------------------------------------- one artifact, N stages

# The claim the "hydrate once" design rests on: a single artifact can carry a
# correctly rendered copy for every Stage, because Argo CD's OCI source takes a
# `path` that selects one subdirectory of the expanded artifact.
@test 'one render produces a per-stage subdirectory that really differs' {
  CONTEXT="$E2E_ALL_STAGES_DIR"
  local stage
  for stage in test stage prod; do
    [ -f "$E2E_ALL_STAGES_DIR/$stage/deployment.yaml" ] ||
      fail_with "no deployment.yaml rendered for $stage" || return 1
  done

  # values-<stage>.yaml sets replicas per Stage, so if these three agreed the
  # per-Stage values files were not applied and one artifact would be shipping
  # the wrong manifests to two of the three.
  local test_replicas stage_replicas prod_replicas
  test_replicas="$(q "$E2E_ALL_STAGES_DIR/test/deployment.yaml" '.spec.replicas')"
  stage_replicas="$(q "$E2E_ALL_STAGES_DIR/stage/deployment.yaml" '.spec.replicas')"
  prod_replicas="$(q "$E2E_ALL_STAGES_DIR/prod/deployment.yaml" '.spec.replicas')"
  CONTEXT="test=$test_replicas stage=$stage_replicas prod=$prod_replicas"
  assert_equal "$test_replicas" "1" "test replicas (values.yaml alone)"
  assert_equal "$stage_replicas" "2" "stage replicas (values-stage.yaml)"
  assert_equal "$prod_replicas" "3" "prod replicas (values-prod.yaml)"
}

@test 'the multi-stage artifact round-trips with one subdirectory per stage' {
  local tarball="$BATS_TEST_TMPDIR/manifests.tar.gz"
  archive "$E2E_ALL_STAGES_DIR" "$tarball"
  push_artifact config/all-stages promo-1 "$tarball"

  # Every entry is prefixed with its Stage, which is what an Application's
  # `path` selects. The single-stage shape asserts the opposite, and the two
  # together are the whole difference between the designs.
  CONTEXT="$(tar -tzf "$tarball" | tr '\n' ' ')"
  local unprefixed
  unprefixed="$(tar -tzf "$tarball" | grep -vc '/' || true)"
  assert_equal "$unprefixed" "0" 'every entry must sit under its stage directory'

  local digest pulled unpacked
  digest="$(fetch_manifest config/all-stages promo-1 | jqq -r '.layers[0].digest')"
  pulled="$BATS_TEST_TMPDIR/pulled.tar.gz"
  unpacked="$BATS_TEST_TMPDIR/unpacked-all"
  fetch_blob config/all-stages "$digest" "$pulled"
  mkdir -p "$unpacked"
  tar -C "$unpacked" -xzf "$pulled"

  CONTEXT="$(diff -r "$E2E_ALL_STAGES_DIR" "$unpacked" 2>&1 | head -20)"
  diff -r "$E2E_ALL_STAGES_DIR" "$unpacked" > /dev/null ||
    fail_with 'the pulled artifact differs from the rendered manifests'

  # One digest, three Stages. This is the property that makes prod provably the
  # same render as test rather than a re-render that agreed at the time.
  local prod_digest
  push_artifact config/all-stages prod-deploy "$tarball"
  prod_digest="$(resolve_digest config/all-stages prod-deploy)"
  assert_equal "$prod_digest" "$(resolve_digest config/all-stages promo-1)" \
    'every stage deploys one digest'
}

# ------------------------------------------------------------------- pushing

@test 'the pushed artifact is an OCI 1.1 artifact Argo CD can read' {
  local tarball="$BATS_TEST_TMPDIR/manifests.tar.gz"
  archive "$E2E_HELM_DIR" "$tarball"
  push_artifact config/helm-app promo-1 "$tarball"

  local manifest
  manifest="$(fetch_manifest config/helm-app promo-1)"
  CONTEXT="$manifest"

  # The shape oci-push builds when neither mediaType nor artifactType is
  # configured, which is how both hydrate tasks leave them.
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.mediaType')" \
    'application/vnd.oci.image.manifest.v1+json' 'the manifest media type'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.artifactType')" \
    'application/vnd.unknown.artifact.v1' 'the artifact type'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.config.mediaType')" \
    'application/vnd.oci.empty.v1+json' 'the config media type'
  assert_equal "$(printf '%s' "$manifest" | jqq -r '.layers | length')" \
    '1' 'the layer count'

  assert_argocd_readable_layer_type \
    "$(printf '%s' "$manifest" | jqq -r '.layers[0].mediaType')"
}

@test 'the artifact round-trips: what is pulled is what was rendered' {
  local tarball="$BATS_TEST_TMPDIR/manifests.tar.gz"
  archive "$E2E_KUSTOMIZE_DIR" "$tarball"
  push_artifact config/kustomize-app promo-1 "$tarball"

  local digest pulled unpacked
  digest="$(fetch_manifest config/kustomize-app promo-1 | jqq -r '.layers[0].digest')"
  pulled="$BATS_TEST_TMPDIR/pulled.tar.gz"
  unpacked="$BATS_TEST_TMPDIR/unpacked"
  fetch_blob config/kustomize-app "$digest" "$pulled"
  mkdir -p "$unpacked"
  tar -C "$unpacked" -xzf "$pulled"

  CONTEXT="$(diff -r "$E2E_KUSTOMIZE_DIR" "$unpacked" 2>&1 | head -20)"
  diff -r "$E2E_KUSTOMIZE_DIR" "$unpacked" > /dev/null ||
    fail_with 'the pulled artifact differs from the rendered manifests'
}

@test 'both tags resolve to one digest, as the retag step intends' {
  local tarball="$BATS_TEST_TMPDIR/manifests.tar.gz"
  archive "$E2E_HELM_DIR" "$tarball"
  # The immutable tag, then the mutable one pointing at the same manifest —
  # what the task's `push` and `retag` steps produce between them.
  push_artifact config/two-tags promo-2 "$tarball"
  push_artifact config/two-tags stage "$tarball"

  local immutable mutable
  immutable="$(resolve_digest config/two-tags promo-2)"
  mutable="$(resolve_digest config/two-tags stage)"
  CONTEXT="promo-2=$immutable stage=$mutable"
  [ -n "$immutable" ] || fail_with 'the registry returned no digest for the immutable tag'
  assert_equal "$mutable" "$immutable" 'the mutable tag must resolve to the pushed digest'
}

# A Warehouse subscribing to these artifacts uses the Digest strategy, which
# resolves a tag to a digest on every interval. That only produces new Freight
# if moving the tag changes what the tag resolves to.
@test 'moving the mutable tag changes the digest it resolves to' {
  local first second
  archive "$E2E_HELM_DIR" "$BATS_TEST_TMPDIR/first.tar.gz"
  archive "$E2E_KUSTOMIZE_DIR" "$BATS_TEST_TMPDIR/second.tar.gz"

  push_artifact config/moving-tag stage "$BATS_TEST_TMPDIR/first.tar.gz"
  first="$(resolve_digest config/moving-tag stage)"
  push_artifact config/moving-tag stage "$BATS_TEST_TMPDIR/second.tar.gz"
  second="$(resolve_digest config/moving-tag stage)"

  CONTEXT="before=$first after=$second"
  [ -n "$first" ] && [ -n "$second" ] || fail_with 'the registry returned no digest'
  [ "$first" != "$second" ] ||
    fail_with 'the tag resolved to the same digest after being moved, so a Digest subscription would never see new Freight'
}

# The counterexample for the gzip trap: a plain tar published under the gzipped
# layer media type is accepted by the registry without complaint, and only
# fails when a client tries to decompress it. Which is why the linter checks
# the task and this suite checks the bytes — the registry will not.
@test 'a plain tar published as gzip is accepted by the registry but cannot be decompressed' {
  local plain="$BATS_TEST_TMPDIR/plain.tar"
  local list="$BATS_TEST_TMPDIR/entries"
  (cd "$E2E_HELM_DIR" && find . -mindepth 1 | sed 's|^\./||') > "$list"
  tar -C "$E2E_HELM_DIR" -cf "$plain" -T "$list"

  # Not gzip, and the registry does not care.
  run assert_gzipped "$plain"
  [ "$status" -ne 0 ] || {
    printf 'assertion failed: the fixture for this case is gzipped, so it proves nothing\n'
    return 1
  }
  push_artifact config/mislabelled stage "$plain"

  local digest pulled
  digest="$(fetch_manifest config/mislabelled stage | jqq -r '.layers[0].digest')"
  assert_equal "$(fetch_manifest config/mislabelled stage | jqq -r '.layers[0].mediaType')" \
    'application/vnd.oci.image.layer.v1.tar+gzip' 'the layer claims to be gzipped'

  pulled="$BATS_TEST_TMPDIR/mislabelled.tar.gz"
  fetch_blob config/mislabelled "$digest" "$pulled"

  # A client that trusts the media type and gunzips the layer — which is what
  # Argo CD's repo-server does — gets an error here. The promotion that
  # published this would have gone green.
  #
  # Probed with `gzip -t` rather than `tar -tzf` on purpose: libarchive, which
  # is macOS's tar, sniffs the format and reads an uncompressed archive despite
  # -z, so tar is not a witness to this failure. Nothing in the publishing path
  # is either, which is the whole point.
  run gzip -t "$pulled"
  [ "$status" -ne 0 ] || {
    printf 'assertion failed: gzip accepted a plain tar, so this case no longer describes the trap\n'
    return 1
  }
}
