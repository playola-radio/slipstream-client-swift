#!/bin/sh
# Stands in for claude in ProcessIntegrationTests. The first argument picks the behaviour.
case "$1" in
  echo)
    while IFS= read -r line; do
      printf '{"echo":%s}\n' "$line"
    done
    ;;
  count-stdin)
    printf '{"length":%s}\n' "$(wc -c | tr -d ' ')"
    ;;
  stderr-then-exit)
    i=0
    while [ "$i" -lt 100 ]; do
      printf 'filler line %03d, enough of them to push stderr past four kilobytes\n' "$i" >&2
      i=$((i + 1))
    done
    printf 'last words\n' >&2
    exit 3
    ;;
  ignore-term)
    trap '' TERM
    printf '{"ready":true}\n'
    sleep 100
    ;;
  spawn-child)
    sleep 100 &
    printf '{"child":%s}\n' "$!"
    sleep 100
    ;;
esac
