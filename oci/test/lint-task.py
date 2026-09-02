#!/usr/bin/env python3
"""Checks a (Cluster)PromotionTask against Kargo's own step config schemas.

These tasks are YAML and nothing else, so every mistake they can contain is one
Kargo would report at promotion time, halfway through someone's release. This
catches the ones that are decidable statically:

  * a step that names a runner Kargo does not have
  * a config key the step's schema does not define, or a required one missing
  * a literal that is not in an enum, or an expression in a field whose type it
    cannot possibly evaluate to
  * `vars.foo` where the task declares no `foo`, or a declared var nothing uses
  * `task.outputs.foo` where no earlier step is aliased `foo`
  * `outputs.foo` inside a task, where only `task.outputs` resolves
  * a var whose default is the empty string, feeding a field that requires a
    non-empty one

What it cannot check is the value an expression evaluates to. So for a string
carrying an expression, `minLength`, `pattern`, `enum` and `format` are skipped
— the string is only confirmed to be a string. Everything structural (which
keys exist, how they nest, what types they are) is checked as Kargo would.

Reads JSON, not YAML: the caller converts. Usage:

    lint-task.py <schemas-dir> <task.json> [task.json ...]

Exits 0 when every task is clean, 1 otherwise, printing one finding per line.
Stdlib only, so the test suite needs no Python packages.
"""

import json
import os
import re
import sys

# A `${{ ... }}` expression, the only delimiter these tasks use. Kargo accepts
# others; add them here if a task starts using one.
EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)

# `vars.foo` and `vars['foo']`, and the same for `task.outputs` and `outputs`.
VAR_REFS = (
    re.compile(r"\bvars\.([A-Za-z_]\w*)"),
    re.compile(r"\bvars\[[\"']([^\"']+)[\"']\]"),
)
TASK_OUTPUT_REFS = (
    re.compile(r"\btask\.outputs\.([A-Za-z_][\w-]*)"),
    re.compile(r"\btask\.outputs\[[\"']([^\"']+)[\"']\]"),
)
BARE_OUTPUT_REFS = (
    re.compile(r"(?<!\.)\boutputs\.([A-Za-z_][\w-]*)"),
    re.compile(r"(?<!\.)\boutputs\[[\"']([^\"']+)[\"']\]"),
)

# A placeholder value of each JSON Schema type, substituted for an expression so
# the surrounding structure can still be validated.
PLACEHOLDERS = {
    "string": "\0expr",
    "boolean": True,
    "number": 1,
    "integer": 1,
    "array": [],
    "object": {},
    "null": None,
}


class Findings:
    """Collects findings so one run reports everything, not just the first."""

    def __init__(self):
        self.items = []

    def add(self, where, message):
        self.items.append(f"{where}: {message}")

    def __len__(self):
        return len(self.items)


class Schemas:
    """The vendored schemas, loaded on demand, with $ref resolution."""

    def __init__(self, directory):
        self.dir = directory
        self.cache = {}

    def load(self, name):
        if name not in self.cache:
            path = os.path.join(self.dir, f"{name}.json")
            if not os.path.exists(path):
                self.cache[name] = None
            else:
                with open(path, encoding="utf-8") as f:
                    self.cache[name] = json.load(f)
        return self.cache[name]

    def resolve(self, ref, current):
        """Resolves a $ref, either local (`#/definitions/x`) or into a sibling
        file (`argocd-common.json#/definitions/x`)."""
        file_part, _, pointer = ref.partition("#")
        root = current
        if file_part:
            root = self.load(file_part.removesuffix(".json"))
            if root is None:
                return None, None
        node = root
        for token in pointer.strip("/").split("/"):
            if not token:
                continue
            if not isinstance(node, dict) or token not in node:
                return None, None
            node = node[token]
        return node, root


def is_expr(value):
    return isinstance(value, str) and EXPR.search(value) is not None


def is_whole_expr(value):
    """True when the string is nothing but one expression. Kargo replaces such a
    value with the expression's typed result; a string with literal text around
    an expression always evaluates to a string."""
    return isinstance(value, str) and EXPR.fullmatch(value.strip()) is not None


def contains_expr(value):
    """True when an expression appears anywhere in the value, at any depth."""
    if isinstance(value, str):
        return is_expr(value)
    if isinstance(value, dict):
        return any(contains_expr(v) for v in value.values())
    if isinstance(value, list):
        return any(contains_expr(v) for v in value)
    return False


def schema_types(schema):
    t = schema.get("type")
    if t is None:
        return None
    return [t] if isinstance(t, str) else list(t)


def coerce(value, schema):
    """Substitutes a placeholder for an expression, typed as the schema expects,
    so the value can be validated structurally. Returns (value, checkable),
    where checkable is False when the real value is unknowable and so the
    value-level keywords must be skipped."""
    if not is_expr(value):
        return value, True
    types = schema_types(schema) or ["string"]
    if is_whole_expr(value):
        # A whole-value expression can evaluate to any of the accepted types, so
        # take the schema at its word and validate the shape around it.
        for t in types:
            if t in PLACEHOLDERS:
                return PLACEHOLDERS[t], False
    # Interpolation into surrounding text always yields a string. If the schema
    # does not accept one, that is a genuine error, so leave the value alone and
    # let the type check below report it.
    return value, False


def validate(value, schema, schemas, root, where, path, findings):
    """Validates `value` against `schema`, reporting findings against `where`.

    Implements the keyword subset the vendored schemas actually use: $ref, type,
    properties, additionalProperties, required, items, minItems, minLength,
    minProperties, enum, pattern, oneOf, anyOf, not. `format` and `default` are
    annotations here and ignored.
    """
    if "$ref" in schema:
        target, target_root = schemas.resolve(schema["$ref"], root)
        if target is None:
            findings.add(where, f"{path or '<root>'}: unresolvable $ref {schema['$ref']!r}")
            return
        validate(value, target, schemas, target_root, where, path, findings)
        return

    value, checkable = coerce(value, schema)
    label = path or "<root>"

    types = schema_types(schema)
    if types is not None and not type_matches(value, types):
        findings.add(
            where,
            f"{label}: expected {' or '.join(types)}, got {describe(value)}",
        )
        return

    if checkable:
        if "enum" in schema and value not in schema["enum"]:
            allowed = ", ".join(json.dumps(v) for v in schema["enum"])
            findings.add(where, f"{label}: {json.dumps(value)} is not one of {allowed}")
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                findings.add(
                    where, f"{label}: must be at least {schema['minLength']} character(s)"
                )
            if "pattern" in schema and not re.search(schema["pattern"], value):
                findings.add(where, f"{label}: {value!r} does not match {schema['pattern']}")

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                findings.add(where, f"{label}: missing required key {key!r}")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    known = ", ".join(sorted(props)) or "<none>"
                    findings.add(
                        where, f"{label}: unknown key {key!r} (schema defines: {known})"
                    )
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            findings.add(where, f"{label}: must have at least {schema['minProperties']} key(s)")
        for key, sub in props.items():
            if key in value:
                validate(
                    value[key], sub, schemas, root, where, f"{path}.{key}" if path else key,
                    findings,
                )

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            findings.add(where, f"{label}: must have at least {schema['minItems']} item(s)")
        if "items" in schema:
            for i, item in enumerate(value):
                validate(item, schema["items"], schemas, root, where, f"{label}[{i}]", findings)

    for keyword in ("oneOf", "anyOf"):
        if keyword not in schema:
            continue
        branches = schema[keyword]
        passing = [
            b for b in branches if not branch_errors(value, b, schemas, root)
        ]
        if not passing:
            findings.add(
                where,
                f"{label}: satisfies none of the {len(branches)} {keyword} branches",
            )
        elif keyword == "oneOf" and len(passing) > 1 and not contains_expr(value):
            # More than one branch matching is only a real error when every
            # value involved is a literal. Some of these oneOfs discriminate on
            # a value rather than on which keys are present — git-clone's
            # branch/commit/tag, argocd-update's desiredRevision — and an
            # expression's value is not knowable here, so several branches stay
            # open. The ones that discriminate on key presence, such as
            # oci-push's srcRef/srcPath, still resolve to exactly one.
            findings.add(
                where,
                f"{label}: matches {len(passing)} of {len(branches)} mutually "
                "exclusive oneOf branches",
            )

    if "not" in schema and not branch_errors(value, schema["not"], schemas, root):
        findings.add(where, f"{label}: must not match the schema's `not` clause")


def branch_errors(value, schema, schemas, root):
    """Validates against a subschema and returns its findings rather than
    recording them — used to test a oneOf/anyOf/not branch."""
    probe = Findings()
    validate(value, schema, schemas, root, "probe", "", probe)
    return probe.items


def type_matches(value, types):
    for t in types:
        if t == "string" and isinstance(value, str):
            return True
        if t == "boolean" and isinstance(value, bool):
            return True
        if t in ("number", "integer") and isinstance(value, (int, float)) and not isinstance(
            value, bool
        ):
            return True
        if t == "array" and isinstance(value, list):
            return True
        if t == "object" and isinstance(value, dict):
            return True
        if t == "null" and value is None:
            return True
    return False


def describe(value):
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string (an expression interpolated into text)" if is_expr(value) else "string"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    if value is None:
        return "null"
    return type(value).__name__


def collect_refs(node, patterns, found):
    """Walks any JSON structure, matching `patterns` against every string."""
    if isinstance(node, str):
        for pattern in patterns:
            found.update(pattern.findall(node))
    elif isinstance(node, dict):
        for key, value in node.items():
            collect_refs(key, patterns, found)
            collect_refs(value, patterns, found)
    elif isinstance(node, list):
        for value in node:
            collect_refs(value, patterns, found)


# The layer media type oci-push applies when none is configured.
DEFAULT_LAYER_MEDIA_TYPE = "application/vnd.oci.image.layer.v1.tar+gzip"


def check_archive_media_types(steps, where, findings):
    """Checks that a pushed archive's compression matches the media type it is
    published under.

    No schema can catch this: `tar` defaults to `gzip: false` while `oci-push`
    defaults its layer media type to `...tar+gzip`, so a task that forgets
    `gzip: true` publishes a plain tar labelled as gzip. Both steps succeed, the
    promotion goes green, and Argo CD's repo-server then fails to decompress the
    layer. The mismatch is decidable whenever one task both builds and pushes
    the archive, which is exactly the shape of every task here.
    """
    archives = {}
    for step in steps:
        if step.get("uses") != "tar":
            continue
        config = step.get("config") or {}
        out = config.get("outPath")
        if isinstance(out, str) and not is_expr(out):
            archives[os.path.normpath(out)] = bool(config.get("gzip"))

    for i, step in enumerate(steps):
        if step.get("uses") != "oci-push":
            continue
        config = step.get("config") or {}
        src = config.get("srcPath")
        if not isinstance(src, str) or is_expr(src):
            continue
        gzipped = archives.get(os.path.normpath(src))
        if gzipped is None:
            continue
        media_type = config.get("mediaType", DEFAULT_LAYER_MEDIA_TYPE)
        if is_expr(media_type):
            continue
        claims_gzip = media_type.endswith("+gzip")
        at = f"spec.steps[{i}] (oci-push)"
        if claims_gzip and not gzipped:
            findings.add(
                where,
                f"{at}: pushes {src} as {media_type} but the `tar` step that "
                "builds it does not set `gzip: true`, so the layer is an "
                "uncompressed tar labelled as gzip",
            )
        elif gzipped and not claims_gzip:
            findings.add(
                where,
                f"{at}: pushes {src} as {media_type} but the `tar` step that "
                "builds it sets `gzip: true`, so the layer is gzipped and the "
                "media type says otherwise",
            )


def lint(task, where, schemas, findings):
    if task.get("apiVersion") != "kargo.akuity.io/v1alpha1":
        findings.add(where, f"apiVersion should be kargo.akuity.io/v1alpha1, got {task.get('apiVersion')!r}")
    kind = task.get("kind")
    if kind not in ("PromotionTask", "ClusterPromotionTask"):
        findings.add(where, f"kind should be PromotionTask or ClusterPromotionTask, got {kind!r}")
    if not (task.get("metadata") or {}).get("name"):
        findings.add(where, "metadata.name is required")

    spec = task.get("spec") or {}
    steps = spec.get("steps") or []
    if not steps:
        findings.add(where, "spec.steps must hold at least one step")

    declared = []
    for i, var in enumerate(spec.get("vars") or []):
        name = var.get("name")
        if not name:
            findings.add(where, f"spec.vars[{i}]: name is required")
            continue
        declared.append(name)
        # A var declared with no `value` is required of the caller. One declared
        # with `value: ""` renders as the empty string, which every string field
        # in these schemas rejects (`minLength: 1`) — so it fails at promotion
        # time rather than defaulting to anything.
        if "value" in var and var["value"] == "":
            findings.add(
                where,
                f"spec.vars[{i}] ({name}): empty default. Omit `value` to require it "
                "of the caller; an empty string reaches the step as \"\" and is "
                "rejected by minLength",
            )
    duplicates = {n for n in declared if declared.count(n) > 1}
    for name in sorted(duplicates):
        findings.add(where, f"spec.vars: {name!r} declared more than once")

    seen_aliases = []
    for i, step in enumerate(steps):
        at = f"spec.steps[{i}]"
        if "task" in step:
            findings.add(
                where,
                f"{at}: a task step cannot reference another task — Kargo validates "
                "PromotionTask steps as `has(self.uses) && !has(self.task)`",
            )
        uses = step.get("uses")
        if not uses:
            findings.add(where, f"{at}: `uses` is required")
            continue
        at = f"{at} ({uses})"
        alias = step.get("as")
        if not alias:
            findings.add(where, f"{at}: no `as` alias; give every step one so it can be referenced")

        # Any task.outputs reference must name a step that has already run.
        refs = set()
        collect_refs(step, TASK_OUTPUT_REFS, refs)
        for ref in sorted(refs):
            if ref not in seen_aliases:
                known = ", ".join(seen_aliases) or "<none>"
                findings.add(
                    where,
                    f"{at}: task.outputs.{ref} names no earlier step "
                    f"(aliases so far: {known})",
                )
        bare = set()
        collect_refs(step, BARE_OUTPUT_REFS, bare)
        for ref in sorted(bare):
            findings.add(
                where,
                f"{at}: `outputs.{ref}` does not resolve inside a task — "
                f"use `task.outputs.{ref}`",
            )

        schema = schemas.load(uses)
        if schema is None:
            findings.add(
                where,
                f"{at}: no schema for this step. Either it is not a built-in Kargo "
                "step, or its schema needs vendoring into test/schemas",
            )
        else:
            validate(step.get("config") or {}, schema, schemas, schema, where, "config", findings)

        if alias:
            seen_aliases.append(alias)

    check_archive_media_types(steps, where, findings)

    referenced = set()
    collect_refs(spec.get("steps") or [], VAR_REFS, referenced)
    # A var's own default may reference an earlier var.
    collect_refs(spec.get("vars") or [], VAR_REFS, referenced)
    for name in sorted(referenced - set(declared)):
        known = ", ".join(declared) or "<none>"
        findings.add(where, f"vars.{name} is referenced but not declared (declared: {known})")
    for name in declared:
        if name not in referenced:
            findings.add(where, f"spec.vars: {name!r} is declared but never referenced")


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    schemas = Schemas(argv[1])
    findings = Findings()
    for path in argv[2:]:
        with open(path, encoding="utf-8") as f:
            docs = json.load(f)
        # yq emits a bare object for a single document and an array for a stream.
        for task in docs if isinstance(docs, list) else [docs]:
            name = (task.get("metadata") or {}).get("name") or os.path.basename(path)
            lint(task, name, schemas, findings)
    for item in findings.items:
        print(item)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
