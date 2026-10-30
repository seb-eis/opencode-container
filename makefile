IMAGE_NAME ?= opencode
IMAGE_TAG  ?= latest
IMAGE      := $(IMAGE_NAME):$(IMAGE_TAG)

CONTAINERFILE ?= containerfile

# Host directory bind-mounted at ~/.config/git inside the container; the token
# lands there so it survives container restarts. Matches the launcher's
# OPENCODE_GITCONFIG default.
GITCONFIG ?= $(if $(OPENCODE_GITCONFIG),$(OPENCODE_GITCONFIG),$(HOME)/.config/git)

.PHONY: all build rebuild clean run shell install-token

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
		-f $(CONTAINERFILE) \
		.

rebuild:
	podman build \
		--no-cache \
		-t $(IMAGE) \
		-f $(CONTAINERFILE) \
		.

clean:
	podman image rm -f $(IMAGE) || true
