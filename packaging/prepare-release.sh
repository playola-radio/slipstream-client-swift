#!/usr/bin/env bash
# Decides what a merge to develop publishes (.github/workflows/release.yml). Run from a
# clean, full-history checkout of develop's tip. Writes release=true|false and the sha
# to publish to $GITHUB_OUTPUT.
#
# - project.yml's version is untagged (a `make prep-release` bump, or a bump whose
#   release failed): publish the commit that bumped to it, so notes merged since then
#   wait for their own release instead of shipping unannounced.
# - Tagged, with ### Changes notes waiting: bump the patch version, push it to develop,
#   publish that commit. If develop moved meanwhile, the newer merge's run does it.
# - Tagged, nothing to announce: publish nothing.
set -euo pipefail

output="${GITHUB_OUTPUT:-/dev/stdout}"

version="$(sed -n 's/.*MARKETING_VERSION: "\([0-9][0-9.]*\)".*/\1/p' project.yml)"
build="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)"
[[ -n "$version" && -n "$build" ]] || { echo "cannot read version from project.yml" >&2; exit 1; }
tag="v$version-b$build"

status=0
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || status=$?
case "$status" in
  0) ;;
  2)
    bump="$(git log -1 --format=%H -S "CURRENT_PROJECT_VERSION: \"$build\"" -- project.yml)"
    [[ -n "$bump" ]] || { echo "cannot find the commit that bumped to $tag" >&2; exit 1; }
    echo "releasing $tag from $bump, the commit that bumped to it"
    echo "release=true" >> "$output"
    echo "sha=$bump" >> "$output"
    exit 0
    ;;
  *) echo "cannot check for tag $tag" >&2; exit "$status" ;;
esac

pending="$(ruby packaging/release_notes.rb pending CHANGELOG.md changelog.d)"
if [[ "$pending" != true ]]; then
  echo "$tag is already released and no ### Changes notes are waiting; nothing to do"
  echo "release=false" >> "$output"
  exit 0
fi

IFS=. read -r major minor patch <<<"$version"
next="$major.$minor.$((patch + 1))"
base="$(git rev-parse HEAD)"
bundle exec fastlane mac bump "version:$next"

if ! git push origin HEAD:refs/heads/develop; then
  git fetch --quiet origin develop
  if [[ "$(git rev-parse FETCH_HEAD)" != "$base" ]]; then
    echo "develop moved while bumping to $next; the newer merge's run releases it"
    echo "release=false" >> "$output"
    exit 0
  fi
  echo "cannot push the $next bump to develop" >&2
  exit 1
fi
echo "release=true" >> "$output"
echo "sha=$(git rev-parse HEAD)" >> "$output"
