# goose desktop-agent sandbox image
# Build:  podman build -t goose-desktop-agent:latest ~/Documents/openshell-setup/
#
# Contains the goose CLI plus a sane toolchain for the developer extension.
# goose runs as `goose serve` (ACP backend) and is driven by goose Desktop on
# the host through an OpenShell port forward. No secrets are baked in: the
# enmaas API key arrives as an OpenShell provider placeholder at runtime.
#
# Fedora base — same distro as the host and as the NetObserv Go/eBPF builder
# images (scripts/generators.Dockerfile: `FROM fedora:44` + distro clang/llvm).
# Distro clang/LLVM 22 needs no version-suffixed package names and no
# third-party toolchain repo (Ubuntu 24.04 tops out at clang-18 in its own
# archives, which is what broke the earlier ubuntu:24.04 version of this file).

FROM fedora:44

# Common agent tooling (nodejs/npm NOT from the distro: pinned via tarball
# below to match the host and web-console's runtime image; its CI floor is 22).
# Fedora's fd-find ships the binary as `fd` directly (Debian needs fdfind).
RUN dnf install -y --setopt=install_weak_deps=False \
      ca-certificates curl git ripgrep fd-find jq zip unzip bzip2 xz tar gzip \
      diffutils patch which file man-db man-pages \
      python3 python3-pip procps-ng procps less findutils \
      shellcheck yq \
    && dnf clean all

# --- Node.js 24 (matches the host and web-console's runtime image; its CI floor is 22).
# Tarball bundles npm/npx. Node arch names differ from uname's (x64 vs x86_64, arm64 vs aarch64). ---
ARG NODE_VERSION=24.22.3
RUN case "$(uname -m)" in \
      x86_64) A=x64 ;; aarch64) A=arm64 ;; *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${A}.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1

# --- Go + eBPF toolchain: mirrors scripts/generators.Dockerfile of the NetObserv
# Go/eBPF repos (Fedora + distro clang/llvm, same major version as the host).
# Binaries are unversioned (clang, clang-format via clang-tools-extra), so no
# /usr/local/bin symlinks are needed. Add kernel-devel here if kernel headers
# are ever required. ---
RUN dnf install -y --setopt=install_weak_deps=False \
      make gcc gcc-c++ unzip \
      clang clang-tools-extra llvm \
    && dnf clean all

ARG GO_VERSION=1.26.11
RUN case "$(uname -m)" in \
      x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz

ENV PATH=/usr/local/go/bin:/usr/local/bin:$PATH \
    GOPATH=/go

# Shell formatting (agent-agnostic, lives in base so any future agent benefits)
RUN go install mvdan.cc/sh/v3/cmd/shfmt@latest && ln -sf /go/bin/shfmt /usr/local/bin/shfmt

# Git identity for commits made inside the sandbox. System scope (/etc):
# root-owned and read-only at runtime, so the agent commits as the user but
# cannot change the identity.
COPY gitconfig /etc/gitconfig
