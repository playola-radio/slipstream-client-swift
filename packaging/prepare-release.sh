#!/usr/bin/env bash
# Decides what a merge to develop publishes (.github/workflows/release.yml). Run from a
# clean checkout of the merge that started the workflow. Writes release=true|false and
# the sha to publish to $GITHUB_OUTPUT.
#
# - develop has moved past this merge: publish nothing; the newer merge's run will.
# - project.yml's version is untagged (a `make prep-release` bump, or a release that
#   failed): publish this commit as is.
# - Tagged, with ### Changes notes waiting: bump the patch version, push it to develop,
#   publish that commit.
# - Tagged, nothing to announce: publish nothing.
set -euo pipefail

output="${GITHUB_OUTPUT:-/dev/stdout}"
base="$(git rev-parse HEAD)"

skip() {
  echo "$1"
  echo "release=false" >> "$output"
  exit 0
}

publish() {
  echo "release=true" >> "$output"
  echo "sha=$(git rev-parse HEAD)" >> "$output"
  exit 0
}

tip="$(git ls-remote --exit-code origin refs/heads/develop | cut -f1)"
[[ "$tip" == "$base" ]] || skip "develop has moved on to $tip; its run releases it"

version="$(sed -n 's/.*MARKETING_VERSION: "\([0-9][0-9.]*\)".*/\1/p' project.yml)"
build="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)"
[[ -n "$version" && -n "$build" ]] || { echo "cannot read version from project.yml" >&2; exit 1; }
tag="v$version-b$build"

status=0
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || status=$?
case "$status" in
  0) ;;
  2) echo "releasing $tag as it is"; publish ;;
  *) echo "cannot check for tag $tag" >&2; exit "$status" ;;
esac

pending="$(ruby packaging/release_notes.rb pending CHANGELOG.md changelog.d)"
[[ "$pending" == true ]] || skip "$tag is already released and no ### Changes notes are waiting"

IFS=. read -r major minor patch <<<"$version"
next="$major.$minor.$((patch + 1))"
bundle exec fastlane mac bump "version:$next"

if ! git push origin HEAD:refs/heads/develop; then
  git fetch --quiet origin develop
  remote="$(git rev-parse FETCH_HEAD)"
  # A push can land even though its reply was lost.
  if [[ "$remote" == "$(git rev-parse HEAD)" ]]; then
    publish
  elif [[ "$remote" != "$base" ]]; then
    skip "develop moved while bumping to $next; the newer merge's run releases it"
  fi
  echo "cannot push the $next bump to develop" >&2
  exit 1
fi
publish
