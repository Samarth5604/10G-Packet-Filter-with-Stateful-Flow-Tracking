# Build entry points. Every target is either implemented and reproducible from
# a clean clone, or fails loudly. No target silently succeeds without doing
# the work it names.
#
# Environments must not be combined -- see docs/toolchain.md.

PART      := xczu7ev-ffvc1156-2-e
TOP       ?= header_parser
RTL_DIR   := rtl
REPORTS   := reports

.PHONY: all derive docs docs-check model sim formal synth clean help

help:
	@echo "derive      validate spec, print derived bounds        [implemented]"
	@echo "docs        regenerate docs/protocol.md                [implemented]"
	@echo "docs-check  fail if docs/protocol.md is stale          [implemented]"
	@echo "model       build + self-test OCaml golden model       [not implemented]"
	@echo "sim         Verilator differential regression          [not implemented]"
	@echo "formal      SymbiYosys proofs                          [not implemented]"
	@echo "synth       out-of-context synthesis -> $(REPORTS)/    [needs rtl/]"

all: derive docs-check

# ---------------------------------------------------------------- implemented

derive:
	dune build @all
	dune exec test/derive.exe

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

model:
	@echo "NOT IMPLEMENTED: OCaml golden model. See docs/adr/0006-scope-freeze.md"
	@exit 1

sim:
	@echo "NOT IMPLEMENTED: Verilator differential regression."
	@exit 1

formal:
	@echo "NOT IMPLEMENTED: SymbiYosys proofs."
	@exit 1

# ------------------------------------------------------------------ toolchain

synth:
	@if [ ! -d "$(RTL_DIR)" ]; then \
	  echo "ERROR: no $(RTL_DIR)/ yet -- nothing to synthesise."; exit 1; fi
	@if ! command -v vivado > /dev/null 2>&1; then \
	  echo "ERROR: vivado not on PATH. source env/vivado.sh first."; exit 1; fi
	@mkdir -p $(REPORTS)
	vivado -mode batch -nojournal -nolog \
	  -source syn/synth_ooc.tcl -tclargs $(PART) $(TOP) $(RTL_DIR) $(REPORTS)

clean:
	dune clean
	rm -rf $(REPORTS) docs/protocol.md.new
