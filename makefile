IMAGE_NAME ?= opencode

# Containerfiles live in variants/ and are selected by name only. The shared
# base is built from variants/base.containerfile and is not a runnable variant;
# every runnable variant builds FROM it.
#   make build                 ->  base, then variants/standard.containerfile -> opencode:standard
#   make build VARIANT=minimal ->  base, then variants/minimal.containerfile  -> opencode:minimal
VARIANT ?= standard
BASE_NAME := base

AVAILABLE_VARIANTS := $(filter-out $(BASE_NAME), \
	$(patsubst variants/%.containerfile,%,$(wildcard variants/*.containerfile)))

# CONTAINERFILE was replaced by VARIANT; fail loudly instead of silently
# ignoring a command-line override.
ifneq ($(CONTAINERFILE),)
  $(error CONTAINERFILE is no longer supported; use VARIANT=<name> (available: $(if $(AVAILABLE_VARIANTS),$(AVAILABLE_VARIANTS),none)))
endif

ifneq ($(findstring ',$(VARIANT)),)
  $(error invalid variant name '$(VARIANT)')
endif
ifeq ($(shell printf '%s' '$(VARIANT)' | grep -qE '^[a-z0-9-]+$$' && echo ok),)
  $(error invalid variant name '$(VARIANT)' (expected [a-z0-9-]))
endif
ifeq ($(filter $(VARIANT),$(AVAILABLE_VARIANTS)),)
  $(error unknown variant '$(VARIANT)' (available: $(if $(AVAILABLE_VARIANTS),$(AVAILABLE_VARIANTS),none)))
endif

VARIANT_FILE := variants/$(VARIANT).containerfile
IMAGE := $(IMAGE_NAME):$(VARIANT)

BASE_FILE := variants/$(BASE_NAME).containerfile
BASE_IMAGE := $(IMAGE_NAME):$(BASE_NAME)

# Directory mounted at ~/.config inside the container; the token lands there so
# it survives container restarts. Defaults to the repo's .config/git, matching
# the launcher. OPENCODE_GITCONFIG overrides it.
GITCONFIG ?= $(if $(OPENCODE_GITCONFIG),$(OPENCODE_GITCONFIG),$(CURDIR)/.config/git)

.PHONY: all build rebuild base rebuild-base clean clean-base lint check install-token

all: build

# Store a GitHub token for git (and gh) in the persistent credential file.
#   make install-token                     # prompts for user + token
#   make install-token GITHUB_USER=me      # prompts for the token only
#   GITHUB_TOKEN=... make install-token    # token from the environment
# The token is verified against api.github.com unless SKIP_VERIFY=1. Prefer the
# environment or the prompt: values given on the make command line are visible
# in `ps` while make runs.
install-token:
	@GITCONFIG='$(GITCONFIG)' \
	GITHUB_USER='$(GITHUB_USER)' \
	GITHUB_TOKEN='$(GITHUB_TOKEN)' \
	SKIP_VERIFY='$(SKIP_VERIFY)' \
	sh ./install-token.sh

base:
	podman build \
		-t $(BASE_IMAGE) \
		-f $(BASE_FILE) \
		.

rebuild-base:
	podman build \
		--no-cache \
		-t $(BASE_IMAGE) \
		-f $(BASE_FILE) \
		.

build: base
	podman build \
		-t $(IMAGE) \
		--build-arg BASE_IMAGE=$(BASE_IMAGE) \
		-f $(VARIANT_FILE) \
		.

rebuild: rebuild-base
	podman build \
		--no-cache \
		-t $(IMAGE) \
		--build-arg BASE_IMAGE=$(BASE_IMAGE) \
		-f $(VARIANT_FILE) \
		.

clean:
	podman image rm -f $(IMAGE) || true

clean-base:
	podman image rm -f $(BASE_IMAGE) || true

# Every runnable variant must build FROM the shared base.
lint:
	@test -f $(BASE_FILE) || { echo "lint: missing $(BASE_FILE)"; exit 1; }
	@status=0; \
	for f in $(wildcard variants/*.containerfile); do \
		case "$$f" in \
			"$(BASE_FILE)") continue ;; \
		esac; \
		grep -qxF 'FROM $${BASE_IMAGE}' "$$f" || { \
			echo "lint: $$f must build FROM the shared base"; \
			status=1; \
		}; \
	done; \
	exit $$status

# Run the common health check inside every built variant.
check: lint
	@IMAGE_NAME='$(IMAGE_NAME)' sh ./scripts/check-variants.sh $(AVAILABLE_VARIANTS)
