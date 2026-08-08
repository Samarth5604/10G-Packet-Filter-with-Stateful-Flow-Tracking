# Toolchain

Host: RHEL 9.4. All tools install user-local; none require root except the
RHEL compatibility packages.

## Versions (pin these)

| tool | version | source |
|---|---|---|
| Vivado ML | 2024.1 | AMD unified installer |
| OCaml | 4.14.x | opam switch |
| Hardcaml | pin in `opam.locked` | opam |
| cocotb | pin exactly | pip, in a venv |
| Verilator | from OSS CAD Suite | YosysHQ tarball |
| Yosys + sby + SMT solvers | from OSS CAD Suite | YosysHQ tarball |
| Python | 3.11 | `dnf install python3.11` |

`dune build` and `make` must be reproducible from a clean clone. `opam.locked`
and `requirements.txt` are checked in.

## RHEL 9.4 notes

Vivado 2024.1's validated OS list stops short of 9.4, so the installer shows an
unsupported-OS warning. It is safe to proceed. Install first:

```
sudo dnf install ncurses-compat-libs libnsl libXtst libXft glibc-langpack-en
```

`ncurses-compat-libs` provides `libtinfo.so.5`, which Vivado still links.

## Environment isolation -- important

Vivado ships its own `libstdc++` and rewrites `LD_LIBRARY_PATH` on startup. The
OSS CAD Suite prepends its own binaries and libraries. Sourcing both in one
shell produces library-mismatch errors that look like tool bugs and are not.

**Three environments, never combined:**

```
env/vivado.sh      # source /opt/Xilinx/Vivado/2024.1/settings64.sh
env/oss.sh         # source ~/oss-cad-suite/environment
env/ocaml.sh       # eval $(opam env --switch=./ --set-switch)
```

Use `direnv` per subdirectory, or invoke each tool through a wrapper that sets
up only its own environment in a subshell. Do not put any of these in
`.bashrc`.

## OCaml

Ignore the distro package; it is too old and irrelevant.

```
bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh)"
opam init --bare
opam switch create . 4.14.2
eval $(opam env)
opam install hardcaml hardcaml_waveterm ppx_jane
```

4.14 rather than 5.x: Jane Street's releases are best-tested there, and nothing
here needs effects or multicore.

## Python and cocotb

```
python3.11 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
```

Pin cocotb exactly. It has had a major-version API break; a floating version
means a fresh clone can fail to build for reasons unrelated to any change here.

## Simulator tiering

- **Icarus** for iteration and waveform debug.
- **Verilator** for the full-volume differential regression. Icarus will not
  finish a multi-million-packet run in useful time.

## Synthesis

Out-of-context, per block, from the start -- the alignment network first. If the
barrel shifter misses 156.25 MHz on a -2 part, that must surface in week two,
not after three blocks are stacked on it.

Project mode is used for iteration. `write_project_tcl` output is checked in so
the project is reconstructible from source.
