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

# Verilator needs the timescale the Verilog does not carry.
EXTRA_ARGS += --timing --timescale 1ns/1ps

export VECTORS ?= $(CURDIR)/vectors.txt

include $(shell cocotb-config --makefiles)/Makefile.sim