# Build entry points. Every target is either implemented and reproducible from
# a clean clone, or fails loudly. No target silently succeeds without doing
# the work it names.
#
# Environments must not be combined -- see docs/toolchain.md.

PART      := xczu7ev-ffvc1156-2-e
TOP       ?= header_parser
RTL_DIR   := rtl
REPORTS   := reports

.PHONY: all derive docs docs-check model stimulus crc flowtable pipeline sweep rtl cam-sweep vectors sim formal synth clean help

help:
	@echo "derive      validate spec, print derived bounds        [implemented]"
	@echo "docs        regenerate docs/protocol.md                [implemented]"
	@echo "docs-check  fail if docs/protocol.md is stale          [implemented]"
	@echo "model       build + self-test OCaml golden model       [implemented]"
	@echo "stimulus    generator round-trip against the model     [implemented]"
	@echo "rtl         generate rtl/*.v via Hardcaml              [implemented]"
	@echo "cam-sweep   synthesise the CAM at 8/12/16/32/64 deep   [needs vivado]"
	@echo "crc         self-test the parallel CRC32 derivation    [implemented]"
	@echo "flowtable   self-test the cuckoo hash model            [implemented]"
	@echo "sweep       occupancy sweep -> eviction chain depth    [implemented]"
	@echo "pipeline    timed model: pending-insert race + CAM depth [implemented]"
	@echo "vectors     stimulus + expected results -> sim/         [implemented]"
	@echo "sim         Verilator differential regression          [implemented]"
	@echo "formal      SymbiYosys proofs                          [partial -- see formal/README.md]"
	@echo "synth       out-of-context synthesis -> $(REPORTS)/    [needs rtl/]"

all: derive model stimulus crc flowtable pipeline docs-check

# ---------------------------------------------------------------- implemented

derive:
	dune build @all
	dune exec test/derive.exe

model:
	dune build @all
	dune exec test/model_test.exe

stimulus:
	dune build @all
	dune exec test/stimulus_test.exe

# Generated, and committed: syn/ and any clone must build without an opam
# switch. Regenerate and commit whenever the spec changes.
rtl:
	dune build @all
	dune exec bin/gen_rtl.exe > rtl/header_parser.v
	dune exec bin/gen_crc.exe > rtl/crc32_par.v
	dune exec bin/gen_crc.exe -- --ooc > rtl/crc32_par_ooc.v
	dune exec bin/gen_cam.exe -- $(CAM_DEPTH) $(CAM_WIDTH) > rtl/cam.v
	@echo "regenerated rtl/header_parser.v rtl/crc32_par.v rtl/crc32_par_ooc.v rtl/cam.v"

crc:
	dune build @all
	dune exec test/crc_test.exe

flowtable:
	dune build @all
	dune exec test/flow_table_test.exe

pipeline:
	dune build @all
	dune exec test/flow_pipeline_test.exe

# Picks ways, eviction bound and stash depth for the RTL. Defaults are the
# values ADR 0008 settled on; override to re-derive them.
SWEEP_WAYS  ?= 4
SWEEP_ROWS  ?= 14
SWEEP_EVICT ?= 32
SWEEP_STASH ?= 8

sweep:
	dune build @all
	dune exec bin/gen_sweep.exe -- \
	  $(SWEEP_WAYS) $(SWEEP_ROWS) $(SWEEP_EVICT) $(SWEEP_STASH)

docs:
	dune exec bin/gen_docs.exe > docs/protocol.md
	@echo "regenerated docs/protocol.md"

# CI gate: documentation is generated, so a stale committed copy is a build
# failure rather than a silently wrong document.
docs-check:
	@dune exec bin/gen_docs.exe > docs/protocol.md.new
	@if ! diff -q docs/protocol.md docs/protocol.md.new > /dev/null 2>&1; then \
	  echo "ERROR: docs/protocol.md is stale. Run 'make docs' and commit."; \
	  diff -u docs/protocol.md docs/protocol.md.new || true; \
	  rm -f docs/protocol.md.new; exit 1; \
	fi
	@rm -f docs/protocol.md.new
	@echo "docs up to date"

# ------------------------------------------------------------ not implemented
# These fail rather than no-op. A green build must mean the work was done.

# Vector generation is separate from the run: regenerating is cheap, but a
# regression should be reproducible from a fixed file, and the file records
# which profile and seed produced a failure.
# CAM instances: the stash (32) and the pending-insert table (8..16). Depth is
# swept by cam-sweep to compare area and logic depth.
CAM_DEPTH ?= 8
CAM_WIDTH ?= 104

# Generate and synthesise a CAM at each depth, so the cost of a deeper CAM is
# measured rather than estimated.
#
# Each depth goes into its own directory with a filename matching the module
# name, because `make synth` guards on rtl/$$(TOP).v -- generating every depth
# into rtl/cam.v made that guard fail silently and the sweep printed nothing.
CAM_SWEEP_DIR := build/cam_sweep

cam-sweep:
	@mkdir -p $(CAM_SWEEP_DIR) $(REPORTS)
	@for d in 8 12 16 32 64; do \
	  top=cam_d$${d}_w$(CAM_WIDTH); \
	  rm -f $(CAM_SWEEP_DIR)/*.v; \
	  dune exec bin/gen_cam.exe -- $$d $(CAM_WIDTH) > $(CAM_SWEEP_DIR)/$$top.v; \
	  echo "=== depth $$d ==="; \
	  $(MAKE) --no-print-directory synth \
	    RTL_DIR=$(CAM_SWEEP_DIR) TOP=$$top REPORTS=$(REPORTS) > $(CAM_SWEEP_DIR)/$$top.log 2>&1 \
	    || echo "  synthesis failed -- see $(CAM_SWEEP_DIR)/$$top.log"; \
	  grep -E "^\|[0-9]+ *\|(LUT|FDRE)" $(CAM_SWEEP_DIR)/$$top.log | \
	    awk -F'|' '{gsub(/ /,"",$$3); gsub(/ /,"",$$4); printf "  %-6s %s\n", $$3, $$4}'; \
	  grep -E "WNS reg-to-reg|WNS overall|max frequency" $(CAM_SWEEP_DIR)/$$top.log \
	    | sed 's/^/  /'; \
	done

VEC_PROFILE ?= smoke
VEC_COUNT   ?= 10000
VEC_SEED    ?=

vectors:
	dune build @all
	dune exec bin/gen_vectors.exe -- $(VEC_PROFILE) $(VEC_COUNT) $(VEC_SEED) \
	  > sim/vectors.txt
	@wc -l < sim/vectors.txt | xargs printf "sim/vectors.txt: %s packets\n"

sim: vectors
	@command -v verilator > /dev/null 2>&1 || { \
	  echo "ERROR: verilator not on PATH. source env/oss.sh first."; exit 1; }
	@[ -f rtl/header_parser.v ] || { echo "ERROR: run 'make rtl' first."; exit 1; }
	$(MAKE) -C sim

formal:
	@command -v sby > /dev/null 2>&1 || { \
	  echo "ERROR: sby not on PATH. source env/oss.sh first."; exit 1; }
	@[ -f rtl/header_parser.v ] || { echo "ERROR: run 'make rtl' first."; exit 1; }
	@fail=0; \
	for f in formal/*.sby; do \
	  [ -e "$$f" ] || continue; \
	  name=$$(basename $$f .sby); \
	  echo "=== $$name ==="; \
	  (cd formal && sby -f $$name.sby) || fail=1; \
	done; \
	if [ $$fail -ne 0 ]; then \
	  echo "one or more formal proofs FAILED -- see formal/<name>/ for the counterexample trace"; \
	  exit 1; \
	fi
	@echo "all formal proofs passed"

# ------------------------------------------------------------------ toolchain

synth:
	@if [ ! -f "$(RTL_DIR)/$(TOP).v" ]; then \
	  echo "ERROR: no $(RTL_DIR)/$(TOP).v -- run 'make rtl' first."; exit 1; fi
	@if ! command -v vivado > /dev/null 2>&1; then \
	  echo "ERROR: vivado not on PATH. source env/vivado.sh first."; exit 1; fi
	@mkdir -p $(REPORTS)
	vivado -mode batch -nojournal -nolog \
	  -source syn/synth_ooc.tcl -tclargs $(PART) $(TOP) $(RTL_DIR) $(REPORTS)

clean:
	dune clean
	$(MAKE) -C sim clean 2>/dev/null || true
	rm -f sim/vectors.txt
	rm -rf $(REPORTS) docs/protocol.md.new