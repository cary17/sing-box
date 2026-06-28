#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${1:?usage: select-upstream-version.sh <stable|testing> <releases-json> <tags-json> [tag-published-at]}"
RELEASES_JSON="${2:?usage: select-upstream-version.sh <stable|testing> <releases-json> <tags-json> [tag-published-at]}"
TAGS_JSON="${3:?usage: select-upstream-version.sh <stable|testing> <releases-json> <tags-json> [tag-published-at]}"
TAG_PUBLISHED_AT="${4:-2026-06-29T00:00:00+08:00}"

case "$CHANNEL" in
  stable)
    RELEASE_FILTER='select(.draft == false and .prerelease == false)'
    TAG_FILTER='test("^[vV]?[0-9]+\\.[0-9]+\\.[0-9]+-reF1nd(\\.[0-9]+)?$")'
    ;;
  testing)
    RELEASE_FILTER='select(.draft == false and .prerelease == true)'
    TAG_FILTER='test("^[vV]?[0-9]+\\.[0-9]+\\.[0-9]+-[A-Za-z]+\\.[0-9]+-reF1nd(\\.[0-9]+)?$")'
    ;;
  *)
    echo "unsupported channel: ${CHANNEL}" >&2
    exit 2
    ;;
esac

version_key() {
  local tag="${1#v}"
  tag="${tag#V}"
  local base="${tag%%-reF1nd*}"
  local suffix="${tag#*-reF1nd}"
  local version_part prerelease_part major minor patch prerelease_number revision

  if [[ "$base" == *-* ]]; then
    version_part="${base%%-*}"
    prerelease_part="${base#*-}"
    prerelease_number="${prerelease_part##*.}"
    [[ "$prerelease_number" =~ ^[0-9]+$ ]] || prerelease_number=0
  else
    version_part="$base"
    prerelease_number=99999999
  fi

  IFS=. read -r major minor patch _ <<< "$version_part"
  if [[ "$suffix" == "$tag" || -z "$suffix" ]]; then
    revision=0
  else
    revision="${suffix#.}"
    [[ "$revision" =~ ^[0-9]+$ ]] || revision=0
  fi

  printf '%08d.%08d.%08d.%08d.%08d' "${major:-0}" "${minor:-0}" "${patch:-0}" "${prerelease_number:-0}" "${revision:-0}"
}

beijing_time() {
  TZ=Asia/Shanghai date -d "$1" +'%Y-%m-%dT%H:%M:%S+08:00'
}

best_key=""
best_published_at=""
best_source=""
best_version=""

consider_candidate() {
  local tag="$1"
  local published_at="$2"
  local source="$3"
  local key

  [[ -n "$tag" ]] || return 0
  key="$(version_key "$tag")"

  if [[ -z "$best_key" || "$key" > "$best_key" || ( "$key" == "$best_key" && "$published_at" > "$best_published_at" ) ]]; then
    best_key="$key"
    best_published_at="$published_at"
    best_source="$source"
    best_version="$tag"
  fi
}

while IFS=$'\t' read -r tag published_at; do
  [[ -n "$tag" ]] || continue
  consider_candidate "$tag" "$(beijing_time "$published_at")" "release"
done < <(jq -r ".[] | ${RELEASE_FILTER} | [.tag_name, (.published_at // .created_at)] | @tsv" "$RELEASES_JSON")

while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  consider_candidate "$tag" "$TAG_PUBLISHED_AT" "tag"
done < <(jq -r ".[] | .name | select(${TAG_FILTER})" "$TAGS_JSON")

if [[ -z "$best_version" ]]; then
  echo "no upstream ${CHANNEL} version found" >&2
  exit 1
fi

version="$best_version"
published_at="$best_published_at"
source="$best_source"
docker_tag="${version%%-reF1nd*}"

jq -n \
  --arg version "$version" \
  --arg published_at "$published_at" \
  --arg docker_tag "$docker_tag" \
  --arg source "$source" \
  '{
    version: $version,
    published_at: $published_at,
    docker_tag: $docker_tag,
    source: $source
  }'
