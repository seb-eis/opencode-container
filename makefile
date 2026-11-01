IMAGE_NAME ?= opencode

# Every containerfile lives in variants/ and is selected by name only:
#   make build                 ->  -f variants/standard.containerfile -t opencode:standard
#   make build VARIANT=minimal ->  -f variants/minimal.containerfile  -t opencode:minimal
VARIANT ?= standard

AVAILABLE_VARIANTS := $(patsubst variants/%.containerfile,%,$(wildcard variants/*.containerfile))

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

# Directory mounted at ~/.config inside the container; the token lands there so
# it survives container restarts. Defaults to the repo's .config/git, matching
# the launcher. OPENCODE_GITCONFIG overrides it.
GITCONFIG ?= $(if $(OPENCODE_GITCONFIG),$(OPENCODE_GITCONFIG),$(CURDIR)/.config/git)

.PHONY: all build rebuild clean install-token

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

build:
	podman build \
		-t $(IMAGE) \
		-f $(VARIANT_FILE) \
		.

rebuild:
	podman build \
		--no-cache \
		-t $(IMAGE) \
		-f $(VARIANT_FILE) \
		.

clean:
	podman image rm -f $(IMAGE) || true
