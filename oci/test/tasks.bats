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

@test 'publish-manifests-to-oci lints clean' {
  lint_task "$TASKS_DIR/publish-manifests-to-oci/cluster-promotion-task.yaml"
  assert_lint_clean
}

@test 'await-oci-deploy lints clean' {
  lint_task "$TASKS_DIR/await-oci-deploy/cluster-promotion-task.yaml"
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
# while `oci-push` defaults its layer media type to `...tar+gzip`. Assert every
# task that publishes an archive stays on the compressed side of it, since the
# linter's coherence check only proves the two agree — not that they agree on
# gzip, which is what Argo CD's allow-list requires.
#
# Discovered rather than listed, so a task added later is covered without this
# case being touched.
@test 'every task that publishes an archive gzips it and uses an Argo CD readable layer type' {
  local checked=0 yaml
  while IFS= read -r yaml; do
    CONTEXT="$yaml"
    local gzip media_type
    gzip="$(q "$yaml" '[.spec.steps[] | select(.uses == "tar")] | .[0].config.gzip')"
    assert_equal "$gzip" "true" "$(basename "$(dirname "$yaml")"): the tar step's gzip" || return 1

    # An unset mediaType means oci-push's default, which is the gzipped OCI
    # layer type. If a task ever sets one explicitly it has to stay inside Argo
    # CD's allow-list.
    media_type="$(q "$yaml" \
      '[.spec.steps[] | select(.uses == "oci-push" and (.config | has("srcPath")))] | .[0].config.mediaType // "application/vnd.oci.image.layer.v1.tar+gzip"')"
    assert_argocd_readable_layer_type "$media_type" || return 1
    checked=$((checked + 1))
  done < <(archive_publishing_tasks)

  [ "$checked" -ge 1 ] || {
    printf 'assertion failed: found no archive-publishing task to check\n'
    return 1
  }
}

# The second push has to be a retag of the first push's digest rather than a
# second archive push. Both work, but only the retag cannot drift: a second
# srcPath push is byte-identical only for as long as every annotation stays so,
# and a digest that quietly diverges from the immutable tag is the one bug this
# design exists to prevent.
@test 'every task that publishes an archive applies its mutable tag by retagging' {
  local yaml
  while IFS= read -r yaml; do
    CONTEXT="$yaml"
    local name src_ref dest_ref push_repo retag_repo
    name="$(basename "$(dirname "$yaml")")"
    src_ref="$(q "$yaml" '.spec.steps[] | select(.as == "retag") | .config.srcRef')"
    dest_ref="$(q "$yaml" '.spec.steps[] | select(.as == "retag") | .config.destRef')"
    assert_equal "$src_ref" '${{ vars.ociRepo }}@${{ task.outputs.push.digest }}' \
      "$name: the retag step's srcRef" || return 1
    assert_equal "$dest_ref" '${{ vars.ociRepo }}:${{ vars.mutableTag }}' \
      "$name: the retag step's destRef" || return 1

    # A retag across repositories would transfer blobs and be subject to the
    # artifact size limit; within one repository it is metadata only.
    push_repo="${dest_ref%%:*}"
    retag_repo="${src_ref%%@*}"
    assert_equal "$retag_repo" "$push_repo" "$name: the retag must stay in one repository" || return 1
  done < <(archive_publishing_tasks)
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
  done < <(find "$TASKS_DIR" -path '*/examples/*stage.yaml' | sort)
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

# `retry` is a typed field on the step, not part of `config`, so it is never
# expression-templated and only the linter's own check covers it. The three
# cases below are the reason it has one.
@test 'an expression in retry.timeout is rejected' {
  lint_task "$FIXTURES_DIR/broken/retry-expression.yaml"
  assert_lint_fails
  assert_lint_reports 'never expression-templated'
}

@test 'a retry.timeout that is not a Go duration is rejected' {
  lint_task "$FIXTURES_DIR/broken/retry-duration.yaml"
  assert_lint_fails
  assert_lint_reports 'is not a Go duration'
}

@test 'a misspelled step-level key is rejected' {
  lint_task "$FIXTURES_DIR/broken/unknown-step-key.yaml"
  assert_lint_fails
  assert_lint_reports "unknown step key 'retires'"
}

# The counterpart: a legal retry block must still be accepted, or the checks
# above would just be banning retry.
@test 'a literal retry.timeout is accepted' {
  lint_task "$TASKS_DIR/await-oci-deploy/cluster-promotion-task.yaml"
  assert_lint_clean
  q "$TASKS_DIR/await-oci-deploy/cluster-promotion-task.yaml" \
    '[.spec.steps[] | select(.retry != null)] | length' | grep -qv '^0$' || {
    printf 'assertion failed: await-oci-deploy no longer sets retry, so this case proves nothing\n'
    return 1
  }
}

# A whole-value expression must still be accepted in a boolean field, or the
# check above would just be banning expressions.
@test 'a whole-value expression in a boolean field is accepted' {
  local yaml="$TASKS_DIR/deploy-oci-to-argocd/cluster-promotion-task.yaml"
  lint_task "$yaml"
  assert_lint_clean
  grep -q 'updateTargetRevision: ${{ vars.updateTargetRevision }}' "$yaml" || {
    printf 'assertion failed: deploy-oci-to-argocd no longer drives a boolean field from a var, so this case proves nothing\n'
    return 1
  }
}
