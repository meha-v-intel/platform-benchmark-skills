#!/bin/bash

# =========================

# Memory Latency-Bandwidth Curve (Intel MLC)

# System: GNR Imperia baseline

# Tool: Intel MLC v3.12

# =========================

# -------- Paths --------

MLC=/root/Linux/mlc

NUMACTL=/usr/bin/numactl

RES_PATH=/data/mlc_res

mkdir -p ${RES_PATH}

rm -rf ${RES_PATH}/*

# -------- Parameters --------

cpu_start=1      # bandwidth cores start index

lat_core=0       # core used for idle latency measurement

mem_node=0       # MLC restriction (must be 0)

MAX_CORES=120    # capped to avoid OOM / HT artifacts

echo "Starting MLC Memory Latency-Bandwidth sweep"

echo "Results directory: ${RES_PATH}"

echo "Max BW cores: ${MAX_CORES}"

# -------- Sweep --------

for i in $(seq 1 ${MAX_CORES}); do

    echo "==== BW cores: $i ===="

    cpu_list="${cpu_start}-${i}"

    # Start bandwidth + loaded latency test

    ${NUMACTL} -m ${mem_node} \
    ${MLC} --loaded_latency -e -b1g -t50 -T \
    -k"${cpu_list}" -d0 -W2 \
    >> ${RES_PATH}/bw_mlc_${i}.log 2>&1 &

    bw_pid=$!

    sleep 20

    # Idle latency measurement

    ${NUMACTL} -m ${mem_node} \
    ${MLC} --idle_latency -b2g -c${lat_core} -r -t20 \
    > ${RES_PATH}/latency_mlc_${i}.log

    lat=$(grep frequency ${RES_PATH}/latency_mlc_${i}.log | awk '{print $9}')

    wait ${bw_pid}

    # Robust bandwidth extraction (ignore status text)

    bw=$(grep -E '^[0-9]+\s+[0-9]+' ${RES_PATH}/bw_mlc_${i}.log | tail -1 | awk '{print $3}')

    echo "$i ${bw} ${lat}" >> ${RES_PATH}/lat_bw.data

    echo "Completed: cores=$i BW=${bw}MB/s LAT=${lat}ns"

done

echo "MLC sweep completed"

echo "Raw data: ${RES_PATH}/lat_bw.data"
