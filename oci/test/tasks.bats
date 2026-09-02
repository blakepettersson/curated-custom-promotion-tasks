#!/usr/bin/env bats
# shellcheck disable=SC2034  # CONTEXT is read by fail_with in helpers.bash
# shellcheck disable=SC2016  # this file asserts literal ${{ }} and `backtick` text
# Checks each task in oci/tasks/ against Kargo's own step config schemas, and
# each stage example against the task it calls.
#
#   bats test/tasks.bats
#
# The cases in broken/ are negative controls. A linter nobody has watched fail
# is a linter that passes everything, so there is one fixture per check it
# claims to make, and each asserts the message an operator would have to act on.
#
# Needs python3 (stdlib only) and yq or docker.

setup() {
  load helpers
}

# --------------------------------------------------------------- the real tasks

@test 'hydrate-helm-to-oci lints clean' {
  lint_task "$TASKS_DIR/hydrate-helm-to-oci/cluster-promotion-task.yaml"
  assert_lint_clean
}

@test 'hydrate-kustomize-to-oci lints clean' {
  lint_task "$TASKS_DIR/hydrate-kustomize-to-oci/cluster-promotion-task.yaml"
  assert_lint_clean
}

@test 'deploy-oci-to-argocd lints clean' {
  lint_task "$TASKS_DIR/deploy-oci-to-argocd/cluster-promotion-task.yaml"
  assert_lint_clean
}

@test 'every task in tasks/ lints clean' {
  # Guards against a task added later that no case above knows about.
  local tasks=()
  while IFS= read -r task; do
    tasks+=("$task")
  done < <(find "$TASKS_DIR" -name 'cluster-promotion-task.yaml' | sort)
  [ "${#tasks[@]}" -ge 3 ] || {
    printf 'expected at least 3 tasks, found %s\n' "${#tasks[@]}"
    return 1
  }
  lint_task "${tasks[@]}"
  assert_lint_clean
}

# The trap this whole family is built around: `tar` defaults to no compression
# while `oci-push` defaults its layer media type to `...tar+gzip`. Assert the
# hydrate tasks stay on the compressed side of it, since the linter's coherence
# check only proves the two agree — not that they agree on gzip, which is what
# Argo CD's allow-list requires.
@test 'the hydrate tasks archive with gzip and publish an Argo CD readable layer type' {
  local task
  for task in hydrate-helm-to-oci hydrate-kustomize-to-oci; do
    local yaml="$TASKS_DIR/$task/cluster-promotion-task.yaml"
    CONTEXT="$task"

    local gzip
    gzip="$(q "$yaml" '[.spec.steps[] | select(.uses == "tar")] | .[0].config.gzip')"
    assert_equal "$gzip" "true" "$task: the tar step's gzip"

    # An unset mediaType means oci-push's default, which is the gzipped OCI
    # layer type. If a task ever sets one explicitly it has to stay inside Argo
    # CD's allow-list.
    local media_type
    media_type="$(q "$yaml" \
      '[.spec.steps[] | select(.uses == "oci-push" and has("config") and (.config | has("srcPath")))] | .[0].config.mediaType // "application/vnd.oci.image.layer.v1.tar+gzip"')"
    assert_argocd_readable_layer_type "$media_type"
  done
}

# The second push has to be a retag of the first push's digest rather than a
# second archive push. Both work, but only the retag cannot drift: a second
# srcPath push is byte-identical only for as long as every annotation stays so,
# and a digest that quietly diverges from the immutable tag is the one bug this
# design exists to prevent.
@test 'the hydrate tasks apply the mutable tag by retagging the pushed digest' {
  local task
  for task in hydrate-helm-to-oci hydrate-kustomize-to-oci; do
    local yaml="$TASKS_DIR/$task/cluster-promotion-task.yaml"
    CONTEXT="$task"

    local src_ref dest_ref
    src_ref="$(q "$yaml" '.spec.steps[] | select(.as == "retag") | .config.srcRef')"
    dest_ref="$(q "$yaml" '.spec.steps[] | select(.as == "retag") | .config.destRef')"
    assert_equal "$src_ref" '${{ vars.ociRepo }}@${{ task.outputs.push.digest }}' \
      "$task: the retag step's srcRef"
    assert_equal "$dest_ref" '${{ vars.ociRepo }}:${{ vars.mutableTag }}' \
      "$task: the retag step's destRef"

    # A retag across repositories would transfer blobs and be subject to the
    # artifact size limit; within one repository it is metadata only.
    local push_repo retag_repo
    push_repo="${dest_ref%%:*}"
    retag_repo="${src_ref%%@*}"
    assert_equal "$retag_repo" "$push_repo" "$task: the retag must stay in one repository"
  done
}

# ------------------------------------------------------------- stage examples

# The examples are the documentation most people will copy, so a var renamed in
# a task without the examples following is a broken copy-paste. Checked both
# ways: no example may pass a var the task does not declare, and no example may
# omit a var the task requires of its caller (one declared with no default).
@test 'every stage example agrees with the tasks it calls about their vars' {
  local example
  while IFS= read -r example; do
    local count i
    count="$(q "$example" '[.spec.promotionTemplate.spec.steps[] | select(has("task"))] | length')"
    for ((i = 0; i < count; i++)); do
      local name task_yaml
      name="$(task_call_field "$example" "$i" '.task.name')"
      CONTEXT="$example calling $name"
      task_yaml="$TASKS_DIR/$name/cluster-promotion-task.yaml"
      [ -f "$task_yaml" ] ||
        fail_with "calls a task that does not exist in tasks/" || return 1

      task_call_field "$example" "$i" '(.vars // [])[].name' > "$BATS_TEST_TMPDIR/passed"
      q "$task_yaml" '.spec.vars[].name' > "$BATS_TEST_TMPDIR/declared"
      q "$task_yaml" '.spec.vars[] | select(has("value") | not) | .name' \
        > "$BATS_TEST_TMPDIR/required"

      assert_subset "$BATS_TEST_TMPDIR/passed" "$BATS_TEST_TMPDIR/declared" \
        "passes a var $name does not declare" || return 1
      assert_subset "$BATS_TEST_TMPDIR/required" "$BATS_TEST_TMPDIR/passed" \
        "omits a var $name requires of its caller (it has no default)" || return 1
    done
  done < <(find "$TASKS_DIR" -path '*/examples/stage.yaml' | sort)
}

# A stage example must use `outputs.<alias>`, never `task.outputs.<alias>`:
# `task.outputs` only resolves inside a task. The inverse of the check the
# linter makes on the tasks themselves.
@test 'stage examples reference task output as outputs, not task.outputs' {
  local example
  while IFS= read -r example; do
    ! grep -q 'task\.outputs' "$example" || {
      printf 'assertion failed: %s uses task.outputs, which resolves only inside a task\n' "$example"
      grep -n 'task\.outputs' "$example" | sed 's/^/    /'
      return 1
    }
  done < <(find "$TASKS_DIR" -path '*/examples/*.yaml' | sort)
}

# ------------------------------------------------------- negative controls

@test 'the fixture the negative controls are derived from lints clean' {
  lint_task "$FIXTURES_DIR/good.yaml"
  assert_lint_clean
}

@test 'a config key the schema does not define is rejected' {
  lint_task "$FIXTURES_DIR/broken/unknown-key.yaml"
  assert_lint_fails
  assert_lint_reports "unknown key 'srcPatth'"
}

@test 'a missing required config key is rejected' {
  lint_task "$FIXTURES_DIR/broken/missing-required.yaml"
  assert_lint_fails
  assert_lint_reports "missing required key 'outPath'"
}

@test 'a literal outside an enum is rejected' {
  lint_task "$FIXTURES_DIR/broken/bad-enum.yaml"
  assert_lint_fails
  assert_lint_reports 'config.outLayout'
}

@test 'a step that is not a built-in Kargo step is rejected' {
  lint_task "$FIXTURES_DIR/broken/unknown-step.yaml"
  assert_lint_fails
  assert_lint_reports 'no schema for this step'
}

@test 'an undeclared var reference is rejected' {
  lint_task "$FIXTURES_DIR/broken/undeclared-var.yaml"
  assert_lint_fails
  assert_lint_reports 'vars.ociRepoo is referenced but not declared'
}

@test 'a declared var nothing references is rejected' {
  lint_task "$FIXTURES_DIR/broken/unused-var.yaml"
  assert_lint_fails
  assert_lint_reports "'unusedVar' is declared but never referenced"
}

@test 'a var with an empty default is rejected' {
  lint_task "$FIXTURES_DIR/broken/empty-var-default.yaml"
  assert_lint_fails
  assert_lint_reports 'empty default'
}

@test 'outputs.foo inside a task is rejected in favour of task.outputs.foo' {
  lint_task "$FIXTURES_DIR/broken/bare-outputs.yaml"
  assert_lint_fails
  assert_lint_reports 'use `task.outputs.push`'
}

@test 'a task.outputs reference to a later step is rejected' {
  lint_task "$FIXTURES_DIR/broken/forward-output.yaml"
  assert_lint_fails
  assert_lint_reports 'names no earlier step'
}

@test 'a step with no alias is rejected' {
  lint_task "$FIXTURES_DIR/broken/no-alias.yaml"
  assert_lint_fails
  assert_lint_reports 'no `as` alias'
}

@test 'a task step referencing another task is rejected' {
  lint_task "$FIXTURES_DIR/broken/nested-task.yaml"
  assert_lint_fails
  assert_lint_reports 'cannot reference another task'
}

# An expression interpolated into surrounding text always evaluates to a string,
# so it can never satisfy a boolean field — unlike a whole-value expression,
# which Kargo replaces with the expression's typed result.
@test 'an expression interpolated into text in a boolean field is rejected' {
  lint_task "$FIXTURES_DIR/broken/interpolated-boolean.yaml"
  assert_lint_fails
  assert_lint_reports 'config.gzip: expected boolean'
}

# The one no schema can express, and the reason the linter knows about this
# family at all.
@test 'a tar step without gzip feeding a gzip media type is rejected' {
  lint_task "$FIXTURES_DIR/broken/ungzipped.yaml"
  assert_lint_fails
  assert_lint_reports 'uncompressed tar labelled as gzip'
}

# A whole-value expression must still be accepted in a boolean field, or the
# check above would just be banning expressions.
@test 'a whole-value expression in a boolean field is accepted' {
  lint_task "$TASKS_DIR/hydrate-helm-to-oci/cluster-promotion-task.yaml"
  assert_lint_clean
  grep -q 'includeCRDs: ${{ vars.includeCRDs }}' \
    "$TASKS_DIR/hydrate-helm-to-oci/cluster-promotion-task.yaml" || {
    printf 'assertion failed: hydrate-helm-to-oci no longer drives a boolean field from a var, so this case proves nothing\n'
    return 1
  }
}
