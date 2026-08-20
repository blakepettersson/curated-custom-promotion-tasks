# Local development for the Kyverno promotion steps. Run from this directory.
# CI runs the same targets: see ../.github/workflows/.

IMAGE ?= kyverno-validate:dev
BATS_ARGS ?=
STEP_DIR := steps/kyverno-validate

.PHONY: help
help:
	@echo "build   build the kyverno-validate image as $(IMAGE)"
	@echo "lint    shellcheck the step script and its tests"
	@echo "test    run the step behaviour tests against $(IMAGE) (needs bats)"
	@echo "        BATS_ARGS='--filter Audit' make test   runs a subset"
	@echo "e2e     render examples/kyverno-policies and validate it with $(IMAGE)"
	@echo "        (needs helm as well as bats)"
	@echo "all     lint, build, test, e2e"

.PHONY: build
build:
	docker build -t $(IMAGE) $(STEP_DIR)

.PHONY: lint
lint:
	shellcheck --shell=sh $(STEP_DIR)/src/kyverno-validate
	shellcheck $(STEP_DIR)/test/helpers.bash $(STEP_DIR)/test/*.bats

.PHONY: test
test: build
	IMAGE=$(IMAGE) bats $(BATS_ARGS) $(STEP_DIR)/test/kyverno-validate.bats

.PHONY: e2e
e2e: build
	IMAGE=$(IMAGE) bats $(BATS_ARGS) $(STEP_DIR)/test/e2e-chart.bats

.PHONY: all
all: lint test e2e
