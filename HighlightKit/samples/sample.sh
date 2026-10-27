#!/bin/sh
# Hand the reply to the waiting command
set -e
f=~/.clauntty/reviews/$1
[ -f "$f.json" ] || { echo answered; exit 0; }
i=0
while [ $i -lt 15 ]; do
  [ -f "$f.reply" ] || { echo delivered; exit 0; }
  sleep 0.2 2>/dev/null || sleep 1
  i=$((i+1))
done
case "$2" in
  -q|--quiet) ;;
  *) printf '%s\n' "gone after ${i} tries" ;;
esac
