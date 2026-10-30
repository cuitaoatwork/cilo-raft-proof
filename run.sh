#!/usr/bin/env bash
# Model-check the three read variants of the CILO interlock check and compare
# the outcome with the expected one. Exit status 0 means: the result is as
# claimed in the paper (Local and LeaderLocal refuted, Barrier verified).
set -u
JAR="${TLA2TOOLS:-/opt/tla2tools.jar}"
WORKERS="${WORKERS:-auto}"
OUT="${OUT:-results}"
mkdir -p "$OUT"

declare -A expect=([Local]=violated [LeaderLocal]=violated [Barrier]=holds)
status=0
printf '%-12s %-10s %-10s %12s %8s\n' Mode Expected Result "States" Time
for mode in Local LeaderLocal Barrier; do
  log="$OUT/$mode.log"
  start=$(date +%s)
  # one worker for the refuted modes: breadth-first, so the trace is a shortest one
  [ "$mode" = Barrier ] && w="$WORKERS" || w=1
  java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers "$w" -deadlock \
       -metadir "/tmp/tlc-$mode-$$" -config "$mode.cfg" MC.tla > "$log" 2>&1
  secs=$(( $(date +%s) - start ))
  if grep -q "No error has been found" "$log"; then result=holds
  elif grep -q "is violated" "$log"; then result=violated
  else result=error; fi
  states=$(grep -oE '[0-9]+ distinct states found' "$log" | tail -1 | cut -d' ' -f1)
  printf '%-12s %-10s %-10s %12s %7ss\n' "$mode" "${expect[$mode]}" "$result" "${states:-?}" "$secs"
  [ "$result" = "${expect[$mode]}" ] || status=1
done
echo
echo "Counterexample traces and full TLC output: $OUT/<Mode>.log"
[ $status -eq 0 ] && echo "OK: results match the paper." || echo "MISMATCH: see logs."
exit $status
