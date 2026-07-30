#!/bin/sh
# Dev Containers 확장이 호스트의 ~/.gitconfig 를 컨테이너로 복사한다. 이 저장소 호스트의
# credential.helper 는 호스트에만 있는 경로(/opt/homebrew/bin/gh, aws)를 가리키므로
# 컨테이너에서는 git 호출마다 "not found" 를 stderr 로 뱉는다. 인증 자체는 확장이
# GIT_ASKPASS 로 호스트에 넘겨 처리하니(측정: 헬퍼가 깨진 상태에서도 credential fill 이
# username/password 를 채우고 exit 0) 복사된 헬퍼는 지워야 조용해진다.
set -e

git config --global --get-regexp '^credential\..*helper$' 2>/dev/null |
    awk '{ print $1 }' | sort -u |
    while read -r key; do
        git config --global --unset-all "$key" || true
    done

# 바인드 마운트된 작업 폴더의 소유자가 컨테이너 사용자와 달라 "dubious ownership" 으로
# 막히는 경우를 없앤다. 이미 등록돼 있으면 중복으로 쌓지 않는다.
workspace=$(pwd)
if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$workspace"; then
    git config --global --add safe.directory "$workspace"
fi
