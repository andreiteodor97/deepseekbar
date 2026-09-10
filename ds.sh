#!/bin/bash
H=$(date -u +%H)
W=$(date -u +%u)
if [ "$W" -ge 1 ] && [ "$W" -le 5 ] && { [ "$H" -ge 1 ] && [ "$H" -lt 4 ] || [ "$H" -ge 6 ] && [ "$H" -lt 10 ]; }; then
  echo "PEAK   (Mon-Fri UTC 01-04 & 06-10):  in-hit \$0.006  in-miss \$0.30  out \$1.20"
else
  echo "CHEAP  (off-peak): in-hit \$0.003  in-miss \$0.15  out \$0.60"
fi
echo "UTC: $(date -u '+%H:%M %a')  local: $(date '+%H:%M %a %Z')"
