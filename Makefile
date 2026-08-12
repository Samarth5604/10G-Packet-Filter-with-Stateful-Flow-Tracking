# Build entry points. Every target is either implemented and reproducible from
# a clean clone, or fails loudly. No target silently succeeds without doing
# the work it names.
#
# Environments must not be combined -- see docs/toolchain.md.

PART      := xczu7ev-ffvc1156-2-e
TOP       ?= header_parser
RTL_DIR   := rtl
REPORTS   := reports

.PHONY: all derive docs docs-check model stimulus crc rtl vectors sim formal synth clean help

help:
	@echo "derive      validate spec, print derived bounds        [implemented]"
	@echo "docs        regenerate docs/protocol.md                [implemented]"
	@echo "docs-check  fail if docs/protocol.md is stale          [implemented]"
	@echo "model       build + self-test OCaml golden model       [implemented]"
	@echo "stimulus    generator round-trip against the model     [implemented]"
	@echo "rtl         generate rtl/*.v via Hardcaml              [implemented]"
	@echo "crc         self-test the parallel CRC32 derivation    [implemented]"
	@echo "vectors     stimulus + expected results -> sim/         [implemented]"
	@echo "sim         Verilator differential regression          [implemented]"
	@echo "formal      SymbiYosys proofs                          [not implemented]"
	@echo "synth       out-of-context synthesis -> $(REPORTS)/    [needs rtl/]"

all: derive model stimulus crc docs-check

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
	@echo "regenerated rtl/header_parser.v rtl/crc32_par.v rtl/crc32_par_ooc.v"

crc:
	dune build @all
	dune exec test/crc_test.exe

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
	@echo "NOT IMPLEMENTED: SymbiYosys proofs."
	@exit 1

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