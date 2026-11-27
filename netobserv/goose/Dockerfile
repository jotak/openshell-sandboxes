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

FROM localhost/sandbox-netobserv-base:latest

# GOPATH/GOCACHE under /home/goose: absolute env paths, so they work regardless
# of $HOME — OpenShell runs the workload with HOME=/workspace (goose config is
# COPY'd to /workspace/.config/goose below). /home/goose is explicitly
# read-write in the OpenShell policy (policy.yaml; an earlier /go at the
# filesystem root was Landlock-blocked), and keeping the Go caches out of
# /workspace means Codium Remote-SSH does not index the module cache. Tools
# installed with `go install` (protoc-gen-go, bpf2go, controller-gen, ...)
# land in /home/goose/go/bin, which is on PATH.
ENV PATH=/home/goose/go/bin:$PATH \
    GOPATH=/home/goose/go \
    GOCACHE=/home/goose/.cache/go-build \
    GOTOOLCHAIN=local

# goose CLI from the official release (non-interactive install)
RUN curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh \
      | GOOSE_BIN_DIR=/usr/local/bin CONFIGURE=false bash

# shfmt now lives in base image (agent-agnostic), no per-agent install needed.

# Non-root workload identity (OpenShell rejects root workloads by default).
# UID 1001 kept from the earlier ubuntu-based image (where UID 1000 was taken
# by the stock `ubuntu` user); Fedora's base image has no stock user, so any
# UID >= 1000 would do.
# /workspace is the sandbox working directory and must be owned by the workload user.
RUN useradd -m -u 1001 -s /bin/bash goose \
    && mkdir -p /workspace \
    && chown goose:goose /workspace

# goose configuration: custom enmaas provider + default model.
# IMPORTANT: OpenShell runs workload processes with HOME=/workspace (the
# sandbox working directory), so goose reads its config from
# /workspace/.config/goose — NOT from /home/goose.
# The API key is NOT here — OpenShell injects an opaque placeholder into
# $ENMAAS_API_KEY and swaps in the real key only at the approved endpoint.
COPY --chown=goose:goose custom_enmaas.json /workspace/.config/goose/custom_providers/custom_enmaas.json
COPY --chown=goose:goose goose-config.yaml /workspace/.config/goose/config.yaml
# Agent context: interaction + sandbox-awareness hints, and recipes
COPY --chown=goose:goose goosehints /workspace/.config/goose/.goosehints
COPY --chown=goose:goose recipes /workspace/.config/goose/recipes

USER goose
WORKDIR /workspace

# ACP backend for goose Desktop, exposed to the host via `--forward 3199`.
# Loopback bind: OpenShell port forwards relay to loopback services inside the
# sandbox, and the workload container has no other network interfaces anyway.
EXPOSE 3199
CMD ["goose", "serve", "--platform", "desktop", "--enable-scheduler", "--host", "127.0.0.1", "--port", "3199", "--tls"]
