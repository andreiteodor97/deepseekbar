#!/bin/bash
#
# Quick terminal read-out of DeepSeek's peak / off-peak windows.
#
# Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday through Friday; off-peak
# rates are exactly half of peak. Rates match https://api-docs.deepseek.com/quick_start/pricing
# (deepseek-flash: $0.003 / $0.15 / $0.60 per 1M tokens off-peak).

H=$(date -u +%H)
W=$(date -u +%u)   # 1 = Monday … 7 = Sunday
if [ "$W" -le 5 ] && { [ "$H" -ge 1 ] && [ "$H" -lt 4 ] || [ "$H" -ge 6 ] && [ "$H" -lt 10 ]; }; then
  MODE="PEAK    (x2)"; HIT=0.006; MISS=0.30; OUT=1.20
else
  MODE="OFF-PEAK (x1)"; HIT=0.003; MISS=0.15; OUT=0.60
fi
printf '%s  deepseek-flash: in-hit $%.3f  in-miss $%.2f  out $%.2f  (per 1M tokens)\n' "$MODE" "$HIT" "$MISS" "$OUT"
printf 'UTC now: %s   local now: %s\n' "$(date -u '+%H:%M %a')" "$(date '+%H:%M %a %Z')"
