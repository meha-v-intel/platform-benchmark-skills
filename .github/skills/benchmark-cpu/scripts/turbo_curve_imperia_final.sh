#!/bin/bash

set -e

TSTAT="/usr/bin/turbostat"

OUT="/data/turbo_curve.txt"

TMP="/data/temp_turbo"

# Observation core

OBS_CPU=0

# Load cores (exclude CPU 0)

LOAD_CORES=(

1 2 3 4 5 6 7 8 9

10 11 12 13 14 15 16 17 18 19

20 21 22 23 24 25 26 27 28 29

30 31 32 33 34 35 36 37 38 39

40 41 42 43 44 45 46 47 48 49

50 51 52 53 54 55 56 57 58 59

)

rm -f "$OUT" "$TMP"

echo "ActiveCores Bzy_MHz" >> "$OUT"

collect_freq() {

$TSTAT --quiet -c $OBS_CPU -i 1 -n 1 \

-s Core,CPU,Busy%,Bzy_MHz > "$TMP"

awk 'END {print cores, $4}' cores="$1" "$TMP" >> "$OUT"

}

echo "Starting Turbo Curve test (corrected)..."

for ((n=1; n<=${#LOAD_CORES[@]}; n++)); do

cpu_list=$(printf "%s " "${LOAD_CORES[@]:0:$n}")

systemd-run --scope --slice=system.slice \

bash -c "

for cpu in $cpu_list; do

taskset -c \$cpu yes > /dev/null &

done

sleep 15

"

sleep 5

collect_freq "$n"

pkill yes

sleep 2

echo "done $n cores"

done

echo "Turbo curve complete -> $OUT"
