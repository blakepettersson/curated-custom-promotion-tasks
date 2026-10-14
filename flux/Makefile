# Local development for the Flux promotion steps. Run from this directory.
# CI runs the same targets: see ../.github/workflows/.

IMAGE ?= flux-reconcile:dev
BATS_ARGS ?=
STEP_DIR := steps/flux-reconcile

.PHONY: help
help:
	@echo "build   build the flux-reconcile image as $(IMAGE)"
	@echo "lint    shellcheck the step script and its tests"
	@echo "test    run the step behaviour tests against $(IMAGE)"
	@echo "        (needs bats, kind, kubectl, helm and curl: builds a kind"
	@echo "        cluster with Flux; FLUX_E2E_KEEP=1 keeps it for the next run)"
	@echo "        BATS_ARGS='--filter HelmRelease' make test   runs a subset"
	@echo "e2e     run examples/flux-app through the example task's config"
	@echo "all     lint, build, test, e2e"

.PHONY: build
build:
	docker build -t $(IMAGE) $(STEP_DIR)

.PHONY: lint
lint:
	shellcheck --shell=sh $(STEP_DIR)/src/flux-reconcile
	shellcheck $(STEP_DIR)/test/helpers.bash $(STEP_DIR)/test/*.bats

.PHONY: test
test: build
	IMAGE=$(IMAGE) bats $(BATS_ARGS) $(STEP_DIR)/test/flux-reconcile.bats

.PHONY: e2e
e2e: build
	IMAGE=$(IMAGE) bats $(BATS_ARGS) $(STEP_DIR)/test/e2e-example.bats

.PHONY: all
all: lint test e2e
