# Local development for the OCI promotion tasks. Run from this directory.
# CI runs the same targets: see ../.github/workflows/oci-tasks.yaml.
#
# There is no `build` target and no IMAGE. These tasks compose Kargo's built-in
# steps, so the family ships YAML and nothing else — nothing is built and
# nothing is published.

BATS_ARGS ?=

.PHONY: help
help:
	@echo "lint    shellcheck the test helpers and byte-compile the task linter"
	@echo "test    check every task against Kargo's step schemas (needs bats, python3, yq)"
	@echo "        BATS_ARGS='--filter gzip' make test   runs a subset"
	@echo "e2e     render examples/example-app and push it to a throwaway registry"
	@echo "        (needs docker, helm and kustomize as well as bats)"
	@echo "all     lint, test, e2e"

.PHONY: lint
lint:
	shellcheck test/helpers.bash test/*.bats
	python3 -m py_compile test/lint-task.py
	@rm -rf test/__pycache__

.PHONY: test
test:
	bats $(BATS_ARGS) test/tasks.bats

.PHONY: e2e
e2e:
	bats $(BATS_ARGS) test/e2e-recipe.bats

.PHONY: all
all: lint test e2e
