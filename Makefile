.PHONY: demo demo-manual demo-headless

# A throwaway daemon, a scratch repo that keeps changing, and the app pointed at it.
# Ctrl-C or quitting the app cleans everything up. See scripts/demo.mjs for flags.

demo:
	node scripts/demo.mjs

demo-manual:
	node scripts/demo.mjs --manual

demo-headless:
	node scripts/demo.mjs --no-app
