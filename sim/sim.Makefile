# cocotb differential regression for header_parser.
#
# Verilator, not Icarus: the volume regression is millions of packets and Icarus
# will not finish one in useful time. Icarus stays available for waveform debug
# on a small vector file.

TOPLEVEL_LANG ?= verilog
SIM           ?= verilator
TOPLEVEL      := header_parser
MODULE        := test_header_parser

# CURDIR, not PWD: under `make -C sim` from the parent Makefile, PWD is still
# the parent's directory and every relative path resolves one level too high.
VERILOG_SOURCES := $(CURDIR)/../rtl/header_parser.v

# Verilator needs a timescale; the generated Verilog does not carry one.
EXTRA_ARGS += --timescale 1ns/1ps

# --timing exists only on Verilator 5.x and is rejected outright by 4.x, which
# is what Ubuntu's apt package still ships. Probe rather than assume, so the
# same Makefile works against the local OSS CAD Suite build (5.051) and a
# distro package in CI.
VERILATOR_HELP := $(shell verilator --help 2>&1)
ifneq (,$(findstring -timing,$(VERILATOR_HELP)))
EXTRA_ARGS += --timing
endif

export VECTORS ?= $(CURDIR)/vectors.txt

# sim_build/ caches a cocotb-generated Vtop.mk with LDFLAGS/rpath baked in for
# whichever cocotb `cocotb-config` resolved to at the time it was generated.
# If the active environment changes between runs -- a different venv on PATH,
# or forgetting to re-activate .venv after `source env/oss.sh` -- a stale
# sim_build/ relinks against the wrong cocotb and fails at link time with
# glibc symbol errors that look like an RTL problem and are not. make's
# timestamp-based staleness check cannot see that cocotb-config's answer
# changed, so it will not save you here.
#
# The whole build is a fraction of a second (Verilator reports its own
# walltime above), so there is no cost to always starting clean. Force it
# unconditionally rather than trust a cache that has already caused one
# debugging session.
$(shell rm -rf $(CURDIR)/sim_build $(CURDIR)/results.xml)

include $(shell cocotb-config --makefiles)/Makefile.sim
