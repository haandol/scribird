#!/bin/bash
#
# 릴리즈 초안을 쓰기 전에 로컬 Git, 번들 버전, 선택적 GitHub 상태를 한 번에 수집한다.
# 저장소나 원격 상태를 바꾸지 않는 읽기 전용 도구다.
# Markdown backtick을 명령 치환하지 않도록 printf 형식 문자열을 작은따옴표로 감싼다.
# shellcheck disable=SC2016
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: collect_release_facts.sh [--target <git-ref>] [--online]

  --target <git-ref>  조사할 commit 또는 ref (기본값: HEAD)
  --online            gh를 사용해 공개 GitHub Release 상태도 조회
EOF
}

target="HEAD"
online=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || {
                echo "--target에는 git ref가 필요합니다." >&2
                exit 2
            }
            target="$2"
            shift 2
            ;;
        --online)
            online=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "알 수 없는 인자: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

target_sha="$(git rev-parse "${target}^{commit}")"
target_subject="$(git show -s --format=%s "$target_sha")"
target_date="$(git show -s --format=%cI "$target_sha")"

bundle_version="$(
    git show "${target_sha}:Resources/Info.plist" \
        | plutil -extract CFBundleShortVersionString raw -o - -- -
)"
bundle_build="$(
    git show "${target_sha}:Resources/Info.plist" \
        | plutil -extract CFBundleVersion raw -o - -- -
)"

base_tag="$(git describe --tags --match 'v[0-9]*' --abbrev=0 "$target_sha" 2>/dev/null || true)"
if [[ -n "$base_tag" ]]; then
    base_sha="$(git rev-list -n 1 "$base_tag")"
    range="${base_tag}..${target_sha}"
else
    base_sha=""
    empty_tree="$(git hash-object -t tree /dev/null)"
    range="${empty_tree}..${target_sha}"
fi

commit_count="$(git rev-list --count "$range")"

origin_url="$(git remote get-url origin 2>/dev/null || true)"
github_repo="$origin_url"
github_repo="${github_repo#git@github.com:}"
github_repo="${github_repo#https://github.com/}"
github_repo="${github_repo%.git}"

printf '# Scribird release facts\n\n'
printf 'Generated: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

printf '## Target\n\n'
printf -- '- Ref: `%s`\n' "$target"
printf -- '- SHA: `%s`\n' "$target_sha"
printf -- '- Commit date: `%s`\n' "$target_date"
printf -- '- Subject: %s\n' "$target_subject"
printf -- '- Bundle version: `%s`\n' "$bundle_version"
printf -- '- Bundle build: `%s`\n' "$bundle_build"
printf -- '- Origin: `%s`\n\n' "${origin_url:-없음}"

printf '## Candidate range\n\n'
if [[ -n "$base_tag" ]]; then
    printf -- '- Reachable version tag: `%s` (`%s`)\n' "$base_tag" "$base_sha"
else
    printf -- '- Reachable version tag: 없음 (초기 릴리즈 후보)\n'
fi
printf -- '- Range: `%s`\n' "$range"
printf -- '- Commits after base: `%s`\n\n' "$commit_count"

printf '## Working tree\n\n'
working_tree="$(git status --short)"
if [[ -n "$working_tree" ]]; then
    printf '미커밋 변경은 위 candidate range에 포함되지 않는다.\n\n```text\n%s\n```\n\n' "$working_tree"
else
    printf 'Clean\n\n'
fi

printf '## Commits and rationale\n\n'
if [[ "$commit_count" -eq 0 ]]; then
    printf '태그 이후 커밋이 없다. 빈 중복 릴리즈를 만들지 않는다.\n\n'
else
    git log --reverse --format='### %h %s%n%nAuthor: %an%nDate: %cI%n%n%b%n' "$range"
    printf '\n'
fi

printf '## Changed files\n\n'
if [[ "$commit_count" -eq 0 ]]; then
    printf '없음\n\n'
else
    printf '```text\n'
    git diff --name-status "$range"
    printf '```\n\n'
fi

printf '## Diff summary\n\n'
if [[ "$commit_count" -eq 0 ]]; then
    printf '없음\n\n'
else
    printf '```text\n'
    git diff --stat "$range"
    printf '```\n\n'
fi

printf '## Changed decision and user documentation\n\n'
documentation="$(
    git diff --name-only "$range" -- \
        AGENTS.md \
        README.md \
        CONTRIBUTING.md \
        SECURITY.md \
        docs \
        plugin/README.md
)"
if [[ -n "$documentation" ]]; then
    printf '```text\n%s\n```\n\n' "$documentation"
else
    printf '없음\n\n'
fi

printf '## Local release artifacts for bundle version\n\n'
artifact_found=false
for artifact in \
    "build/Scribird.app" \
    "build/Scribird-${bundle_version}.zip" \
    "build/release-notes-v${bundle_version}.md"; do
    if [[ -e "$artifact" ]]; then
        artifact_found=true
        if [[ -f "$artifact" ]]; then
            size="$(stat -f '%z' "$artifact")"
            printf -- '- `%s` (%s bytes)\n' "$artifact" "$size"
            if [[ "$artifact" == *.zip ]]; then
                checksum="$(shasum -a 256 "$artifact" | awk '{print $1}')"
                printf '  - SHA-256: `%s`\n' "$checksum"
            fi
        else
            printf -- '- `%s`\n' "$artifact"
        fi
    fi
done
if [[ "$artifact_found" == false ]]; then
    printf '없음\n'
fi
printf '\n'

if [[ "$online" == true ]]; then
    printf '## GitHub Releases\n\n'
    if ! command -v gh >/dev/null 2>&1; then
        printf '`gh`를 찾을 수 없어 조회하지 못했다.\n'
    elif [[ -z "$github_repo" || "$github_repo" == "$origin_url" ]]; then
        printf 'GitHub 저장소를 origin에서 해석하지 못했다.\n'
    elif ! gh auth status >/dev/null 2>&1; then
        printf '`gh` 인증이 없어 조회하지 못했다.\n'
    else
        printf 'Repository: `%s`\n\n```text\n' "$github_repo"
        gh release list --repo "$github_repo" --limit 10
        printf '```\n\n'
        printf '### Latest published release\n\n```json\n'
        gh release view \
            --repo "$github_repo" \
            --json name,tagName,isDraft,isPrerelease,publishedAt,url,assets
        printf '\n```\n'
    fi
fi
