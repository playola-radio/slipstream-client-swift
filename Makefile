.PHONY: demo demo-manual demo-headless prep-release

# A throwaway daemon, a scratch repo that keeps changing, and the app pointed at it.
# Ctrl-C or quitting the app cleans everything up; add KEEP=1 to leave the scratch
# directory behind. See scripts/demo.mjs for flags.

DEMO_FLAGS = $(if $(KEEP),--keep)

demo:
	node scripts/demo.mjs $(DEMO_FLAGS)

demo-manual:
	node scripts/demo.mjs --manual $(DEMO_FLAGS)

demo-headless:
	node scripts/demo.mjs --no-app $(DEMO_FLAGS)

# Moves CHANGELOG.md's [Unreleased] notes and the changelog.d/ notes under VERSION,
# deletes those changelog.d/ files and bumps project.yml, in one commit. Only for a
# version other than the next patch: run on a branch off develop; merging it publishes it.
prep-release:
	@test -n "$(VERSION)" || { echo "usage: make prep-release VERSION=x.y.z" >&2; exit 1; }
	bundle exec fastlane mac bump version:$(VERSION)
