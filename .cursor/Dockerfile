FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Cloud Agent 默认镜像已含 Flutter/Rust/Java；此 Dockerfile 仅补齐 Android 交叉编译常用系统包。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        unzip \
        zip \
        git \
        ca-certificates \
        openjdk-21-jdk-headless \
        clang \
        cmake \
        ninja-build \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

USER ubuntu
