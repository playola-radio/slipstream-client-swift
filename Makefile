.PHONY: demo demo-manual demo-headless

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
