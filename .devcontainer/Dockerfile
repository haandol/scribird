# git 작업 전용 컨테이너. Swift 툴체인은 넣지 않는다 —
# Package.swift가 .macOS(.v26)이고 AVFoundation / SpeechAnalyzer / Core Audio가
# Linux에 없어서 컨테이너 안에서는 어차피 빌드가 되지 않는다.
# 빌드·테스트는 호스트 macOS에서 ./build.sh 로 한다.
FROM alpine:3.22

# libstdc++는 VS Code Server(musl 빌드)가 요구한다. 없으면 컨테이너에 붙지 못한다.
# github-cli는 HTTPS 원격 인증(gh auth git-credential)용,
# openssh-client는 SSH 원격으로 바꿀 때를 위해 둔다.
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        git \
        git-lfs \
        github-cli \
        jq \
        lazygit \
        less \
        libstdc++ \
        openssh-client \
        ripgrep \
    && git lfs install --system

ENV SHELL=/bin/bash
