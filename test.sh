#!/usr/bin/env bash
# test.sh
# Build the rtl_unit_tools Docker image, generate an rtl_unit test project,
# exercise every open-source tool, and print a pass/fail report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/../rtl_unit" && pwd)"
BSV_LIB_DIR="$(cd "$SCRIPT_DIR/../bsv_axi" && pwd)"
IMAGE="rtl_unit_tools"

# Purge stale .bo files in the mounted BSV lib — they will otherwise trigger
# "S0005 Binary version mismatch" if compiled with a different BSC version.
find "$BSV_LIB_DIR" -name '*.bo' -delete 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "\n${BOLD}==> $*${NC}"; }
die()  { echo -e "${RED}FATAL: $*${NC}" >&2; exit 1; }

# -------------------------------------------------------------------------
# 1. Build
# -------------------------------------------------------------------------
# Skip the local build if the image is already present (e.g. because CI
# pulled it from ghcr.io beforehand, or the last local run built it and
# nothing changed). Set REBUILD=1 to force a rebuild.
if [ "${REBUILD:-0}" = "1" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  info "Building Docker image: $IMAGE"
  docker build -t "$IMAGE" "$SCRIPT_DIR" || die "docker build failed"
else
  info "Using existing Docker image: $IMAGE (set REBUILD=1 to force rebuild)"
fi

# -------------------------------------------------------------------------
# 2. Run all tests inside the container
#    Results are written to a host-mounted tmpdir as <n>_<name>.status
#    (PASS or FAIL) and <n>_<name>.detail (last lines of output on failure).
# -------------------------------------------------------------------------
RESULTS_DIR="$(mktemp -d)"
IP_DIR="$SCRIPT_DIR/myip"
rm -rf "$IP_DIR"
mkdir -p "$IP_DIR"

info "Running tests"
echo "  template : $TEMPLATE_DIR"
echo "  bsv lib  : $BSV_LIB_DIR"
echo "  ip dir   : $IP_DIR"
echo "  results  : $RESULTS_DIR"

docker run --rm -i \
  -v "$TEMPLATE_DIR:/template:ro" \
  -v "$BSV_LIB_DIR:/bsv_axi:ro" \
  -v "$RESULTS_DIR:/results" \
  -v "$IP_DIR:/tmp/myip" \
  "$IMAGE" bash -s << 'CONTAINER_EOF'

set +e
R=/results

pass() { printf 'PASS' > "$R/$1.status"; }
fail() { printf 'FAIL' > "$R/$1.status"; printf '%s' "$2" | tail -25 > "$R/$1.detail"; }

# Quick environment diagnostics (appear in log for debugging)
echo "==> DIAG: MAKEFLAGS=[${MAKEFLAGS:-unset}]"
echo "==> DIAG: BLUESPEC_HOME=[${BLUESPEC_HOME:-unset}]"
ls "${BLUESPEC_HOME}/lib/Verilog/FIFO1.v" > /dev/null 2>&1 \
  && echo "==> DIAG: BSC lib/Verilog OK" \
  || echo "==> DIAG: BSC lib/Verilog NOT FOUND"
which peakrdl > /dev/null 2>&1 \
  && echo "==> DIAG: peakrdl=$(which peakrdl)" \
  || echo "==> DIAG: peakrdl NOT FOUND"

# ---- 1. copier: generate a test project from the template ----------------
# Copy the working-tree template while stripping directories that contain
# symlinks pointing outside the tree (e.g. .venv/bin/python3 -> /usr/bin/…),
# which copier 9.16+ rejects before _exclude filtering can suppress them.
cp -r /template/. /tmp/template_clean
rm -rf /tmp/template_clean/.venv \
       /tmp/template_clean/bo \
       /tmp/template_clean/verilog \
       /tmp/template_clean/__pycache__ \
       /tmp/template_clean/.git
out=$(copier copy --overwrite --trust --defaults \
  -d ip_name=myip \
  -d ip_short_desc="CI test IP" \
  -d ip_long_desc="Auto-generated IP for testing" \
  -d author="CI Bot" \
  -d email="ci@example.com" \
  -d target_process=sky130 \
  -d clock_freq_mhz=100 \
  -d bus_protocol=axi4-lite \
  -d enable_fpga=true \
  -d enable_formal=true \
  -d liberty_file="" \
  -d lef_file="" \
  /tmp/template_clean /tmp/myip 2>&1)
[ $? -eq 0 ] && pass "1_copier" || fail "1_copier" "$out"

# ---- 2. peakrdl+bsc: RDL → BSV (peakrdl) → Verilog (bsc myip.bsv) ------
export MYIP_ROOT=/tmp/myip
# All AMBA libraries from unified_axi (clean, no Logger/FIFOLevelIfc bugs).
# '.' = bsv/ working dir, where peakrdl-generated *_Reg_csr.bsv packages live.
export BSC_PATH=.:/bsv_axi/src/axi4:/bsv_axi/src/apb:/bsv_axi/src/common:+
out=$(MAKEFLAGS= make -C /tmp/myip rtl 2>&1)
[ $? -eq 0 ] && pass "2_peakrdl" || fail "2_peakrdl" "$out"

# ---- 3. bsc: compile a minimal self-contained BSV module ----------------
mkdir -p /tmp/bsc_bo
cat > /tmp/bsc_test.bsv << 'BSV'
module sysHello(Empty);
  rule r; $display("BSC OK"); $finish; endrule
endmodule
BSV
out=$(bsc -sim -bdir /tmp/bsc_bo -u /tmp/bsc_test.bsv 2>&1)
[ $? -eq 0 ] && pass "3_bsc" || fail "3_bsc" "$out"

# The BSC top module is mkMyip.v (mk + capitalize(ip_name)).
# Exclude BRAM*.v: BSC library BRAMs use $fopen/sim pragmas yosys 0.33 can't parse.
top_v=/tmp/myip/verilog/mkMyip.v
top_mod=mkMyip
v_files=$(ls /tmp/myip/verilog/*.v 2>/dev/null | grep -v 'BRAM' | tr '\n' ' ')

# ---- 4. verilator: lint the top-level BSC-compiled Verilog --------------
# Use -y to supply the verilog/ dir so sub-module files are found implicitly.
if [ -z "$top_v" ]; then
  fail "4_verilator" "no mk*.v found - peakrdl/bsc step may have failed"
else
  out=$(verilator --lint-only \
    -y /tmp/myip/verilog \
    -Wno-UNUSED -Wno-UNDRIVEN -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME \
    -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-CASEOVERLAP \
    -Wno-INITIALDLY -Wno-STMTDLY -Wno-BLKSEQ -Wno-COMBDLY \
    -Wno-MULTIDRIVEN \
    "$top_v" 2>&1)
  [ $? -eq 0 ] && pass "4_verilator" || fail "4_verilator" "$out"
fi

# ---- 5. verible: lint the top-level BSC-compiled Verilog ----------------
if [ -z "$top_v" ]; then
  fail "5_verible" "no mk*.v found - peakrdl/bsc step may have failed"
else
  out=$(verible-verilog-lint \
    --rules="-no-trailing-spaces,-no-tabs,-explicit-parameter-storage-type,-struct-union-name-style,-parameter-name-style,-typedef-structs-unions" \
    "$top_v" 2>&1)
  [ $? -eq 0 ] && pass "5_verible" || fail "5_verible" "$out"
fi

# ---- 6. yosys: synthesise the BSC-compiled CSR Verilog ------------------
# Read all *.v files (top + any sub-modules BSC generated), top derived from
# the mk*.v filename so this works regardless of the exact module name.
if [ -z "$top_v" ]; then
  fail "6_yosys" "no mk*.v found - peakrdl/bsc step may have failed"
else
  mkdir -p /tmp/yosys_out
  out=$(yosys -p "read_verilog $v_files; synth -top $top_mod; write_verilog /tmp/yosys_out/synth.v" 2>&1)
  [ $? -eq 0 ] && pass "6_yosys" || fail "6_yosys" "$out"
fi

# ---- 7. formal/Makefile: sby-prove via generated Makefile ------------------
if [ -z "$v_files" ]; then
  fail "7_sby" "no verilog files found - peakrdl/bsc step may have failed"
else
  out=$(make -C /tmp/myip/formal sby-prove 2>&1)
  [ $? -eq 0 ] && pass "7_sby" || fail "7_sby" "$out"
fi

# ---- 8. tb/Makefile: cocotb RAL test (APB + AXI4 + peakrdl-cocotb-ralgen) --
if [ -z "$v_files" ]; then
  fail "8_tb_ral" "no verilog files found - peakrdl/bsc step may have failed"
else
  out=$(make -C /tmp/myip/tb 2>&1)
  [ $? -eq 0 ] && pass "8_tb_ral" || fail "8_tb_ral" "$out"
fi

# ---- 9. lint/Makefile: verilator lint via generated Makefile ---------------
if [ -z "$top_v" ]; then
  fail "9_lint" "no mk*.v found - BSC step may have failed"
else
  out=$(make -C /tmp/myip/lint verilator 2>&1)
  [ $? -eq 0 ] && pass "9_lint" || fail "9_lint" "$out"
fi

# ---- 10. synth/Makefile: yosys synthesis via generated Makefile ------------
if [ -z "$top_v" ]; then
  fail "10_synth" "no mk*.v found - BSC step may have failed"
else
  out=$(make -C /tmp/myip/synth synth_yosys 2>&1)
  [ $? -eq 0 ] && pass "10_synth" || fail "10_synth" "$out"
fi

# ---- 11. cdc/Makefile: yosys CDC check via generated Makefile --------------
if [ -z "$top_v" ]; then
  fail "11_cdc" "no mk*.v found - BSC step may have failed"
else
  out=$(make -C /tmp/myip/cdc yosys_cdc 2>&1)
  [ $? -eq 0 ] && pass "11_cdc" || fail "11_cdc" "$out"
fi

# ---- 12. systemrdl/Makefile: peakrdl markdown doc generation ---------------
out=$(make -C /tmp/myip/systemrdl doc 2>&1)
[ $? -eq 0 ] && pass "12_systemrdl" || fail "12_systemrdl" "$out"

# ---- 13. constraints: sdc file with correct clock constraint generated -----
if grep -q 'create_clock' /tmp/myip/constraints/myip.sdc 2>/dev/null; then
  pass "13_constraints"
else
  fail "13_constraints" "constraints/myip.sdc missing or lacks create_clock"
fi

# ---- 14. ci: ci/Makefile orchestration — delegates lint via MYIP_ROOT -----
if [ -f /tmp/myip/ci/Makefile ]; then
  out=$(make -C /tmp/myip/ci lint 2>&1)
  [ $? -eq 0 ] && pass "14_ci" || fail "14_ci" "$out"
else
  fail "14_ci" "ci/Makefile not generated"
fi

# ---- 15. pnr: LibreLane RTL-to-GDS flow (sky130A) -------------------------
if [ -z "$v_files" ]; then
  fail "15_pnr" "no verilog files found - BSC step may have failed"
else
  out=$(make -C /tmp/myip/pnr pnr PDK_ROOT=/opt/pdk 2>&1)
  [ $? -eq 0 ] && pass "15_pnr" || fail "15_pnr" "$out"
fi

# ---- 16. drc: Magic DRC on LibreLane GDS output ----------------------------
if [ ! -f /tmp/myip/drc/Makefile ] || [ ! -f /tmp/myip/drc/magic_drc.tcl ]; then
  fail "16_drc" "drc/ template files missing"
elif [ -z "$(find /tmp/myip/pnr/runs -name 'mkMyip.gds' -path '*/final/gds/*' 2>/dev/null | head -1)" ]; then
  fail "16_drc" "no GDS found under pnr/runs/ - pnr step may have failed"
else
  out=$(make -C /tmp/myip/drc drc PDK_ROOT=/opt/pdk 2>&1)
  [ $? -eq 0 ] && pass "16_drc" || fail "16_drc" "$out"
fi

# ---- 17. sta: OpenSTA timing analysis on synthesized netlist ---------------
if [ ! -f /tmp/myip/sta/Makefile ] || [ ! -f /tmp/myip/sta/run_sta.tcl ]; then
  fail "17_sta" "sta/ template files missing"
elif [ ! -f /tmp/myip/synth/output/mkMyip_synth.v ]; then
  fail "17_sta" "synth/output/mkMyip_synth.v missing - run synth first"
else
  out=$(make -C /tmp/myip/sta sta PDK_ROOT=/opt/pdk 2>&1)
  [ $? -eq 0 ] && pass "17_sta" || fail "17_sta" "$out"
fi

# ---- 18. power: OpenSTA power analysis (LibreLane netlist + cocotb VCD) ----
if [ ! -f /tmp/myip/power/Makefile ] || [ ! -f /tmp/myip/power/run_power.tcl ]; then
  fail "18_power" "power/ template files missing"
elif [ -z "$(find /tmp/myip/pnr/runs -name 'mkMyip.nl.v' -path '*/final/nl/*' 2>/dev/null | head -1)" ]; then
  fail "18_power" "no gate-level netlist found under pnr/runs/ - pnr step may have failed"
elif [ -z "$(find /tmp/myip/tb -name '*.vcd' 2>/dev/null | head -1)" ]; then
  fail "18_power" "no VCD found under tb/ - tb simulation step may have failed"
else
  out=$(make -C /tmp/myip/power power PDK_ROOT=/opt/pdk 2>&1)
  [ $? -eq 0 ] && pass "18_power" || fail "18_power" "$out"
fi

# ---- 19. doc: pandoc HTML generation --------------------------------------
out=$(make -C /tmp/myip/doc doc 2>&1)
[ $? -eq 0 ] && pass "19_doc" || fail "19_doc" "$out"

# ---- 20. fpga: template files generated (Vivado) --------------------------
if [ -f /tmp/myip/fpga/Makefile ] && [ -f /tmp/myip/fpga/vivado_flow.tcl ]; then
  pass "20_fpga"
else
  fail "20_fpga" "fpga/ template files missing"
fi

# ---- 21. systemC: README generated ----------------------------------------
if [ -f /tmp/myip/systemC/README.md ]; then
  pass "21_systemC"
else
  fail "21_systemC" "systemC/README.md not generated"
fi

CONTAINER_EOF

# -------------------------------------------------------------------------
# 3. Report
# -------------------------------------------------------------------------
info "=== Test Report ==="
echo

TESTS=(
  "1_copier:copier           template generation"
  "2_peakrdl:peakrdl+bsc      CSR BSV → Verilog"
  "3_bsc:bsc               BSV compiler smoke test"
  "4_verilator:verilator       BSC Verilog lint"
  "5_verible:verible          BSC Verilog lint"
  "6_yosys:yosys             CSR Verilog synthesis"
  "7_sby:formal/Makefile    sby-prove"
  "8_tb_ral:tb/Makefile       cocotb RAL (APB + AXI4 + ralgen)"
  "9_lint:lint/Makefile     verilator lint"
  "10_synth:synth/Makefile  yosys synthesis"
  "11_cdc:cdc/Makefile      yosys CDC check"
  "12_systemrdl:systemrdl/Make  peakrdl markdown"
  "13_constraints:constraints    sdc clock constraint"
  "14_ci:ci/Makefile        lint via ci orchestration"
  "15_pnr:pnr/              LibreLane RTL-to-GDS (sky130A)"
  "16_drc:drc/              Magic DRC on LibreLane GDS"
  "17_sta:sta/              OpenSTA timing analysis"
  "18_power:power/            OpenSTA power (LibreLane netlist + VCD)"
  "19_doc:doc/              pandoc HTML reference manual"
  "20_fpga:fpga/             vivado_flow.tcl generated"
  "21_systemC:systemC/          README generated"
)

pass_count=0
fail_count=0

for entry in "${TESTS[@]}"; do
  key="${entry%%:*}"
  label="${entry#*:}"
  sf="$RESULTS_DIR/${key}.status"
  df="$RESULTS_DIR/${key}.detail"

  if [ ! -f "$sf" ]; then
    echo -e "  ${RED}[FAIL]${NC}  $label  (no result recorded)"
    fail_count=$((fail_count + 1))
    continue
  fi

  if [ "$(cat "$sf")" = "PASS" ]; then
    echo -e "  ${GREEN}[PASS]${NC}  $label"
    pass_count=$((pass_count + 1))
  else
    echo -e "  ${RED}[FAIL]${NC}  $label"
    if [ -s "$df" ]; then
      while IFS= read -r line; do
        echo -e "         ${YELLOW}| $line${NC}"
      done < "$df"
    fi
    fail_count=$((fail_count + 1))
  fi
done

echo
total=$((pass_count + fail_count))

# Write compact summary (read by Haiku agent for analysis — keep brief)
SUMMARY="$SCRIPT_DIR/test_summary.txt"
{
  echo "run=$(date -Iseconds) pass=$pass_count fail=$fail_count total=$total"
  for entry in "${TESTS[@]}"; do
    key="${entry%%:*}"; label="${entry#*:}"
    sf="$RESULTS_DIR/${key}.status"; df="$RESULTS_DIR/${key}.detail"
    status=$(cat "$sf" 2>/dev/null || echo MISSING)
    if [ "$status" != "PASS" ]; then
      echo "FAIL $key | $label"
      [ -s "$df" ] && sed 's/^/  /' "$df"
    fi
  done
  [ "$fail_count" -eq 0 ] && echo "ALL_PASSED"
} > "$SUMMARY"

if [ $fail_count -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}All $total/$total tests passed.${NC}"
  rm -rf "$RESULTS_DIR"
  exit 0
else
  echo -e "  ${RED}${BOLD}$fail_count/$total tests failed.${NC}"
  echo -e "  ${YELLOW}Results dir: $RESULTS_DIR${NC}"
  echo -e "  Summary: $SUMMARY"
  exit 1
fi
