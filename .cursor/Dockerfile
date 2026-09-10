# SPDX-License-Identifier: MIT OR Apache-2.0
# Base image for the silicon-hdl Cloud Agent environment.
#
# Bakes the slow, stable free-stack toolchain (Verilator + C++ compiler for the
# --binary --timing flow, Python, git) into the image. Repo-tied Python deps
# (requirements-dev.txt) are installed in the environment.json `install` step so
# they track the checked-out source. Vivado is intentionally NOT installed here:
# the repo assumes no local Vivado license and uses Verilator for iteration.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        verilator \
        build-essential \
        git \
        ca-certificates \
        python3 \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

# The ubuntu:24.04 base image already ships a non-root `ubuntu` user (UID 1000).
USER ubuntu
