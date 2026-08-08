#!/usr/bin/env bash
# Vivado only. Never source alongside env/oss.sh -- Vivado ships its own
# libstdc++ and rewrites LD_LIBRARY_PATH, which breaks OSS CAD Suite binaries
# with errors that look like tool bugs.
source /opt/Xilinx/Vivado/2024.1/settings64.sh
