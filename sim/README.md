# sim

Differential regression: `rtl/header_parser.v` against the OCaml golden model.

    make vectors     # bin/gen_vectors.ml -> sim/vectors.txt
    make sim         # drive the RTL, compare every packet

`vectors.txt` holds one packet per line -- frame bytes, expected verdict,
expected error code, expected key -- produced by the model. The testbench drives
and compares; it does not know the protocol and does not reimplement the model.

Both the verdict and the reason are compared. The reason mapping is
`Golden_model.err_code`, defined next to the model so the testbench and the RTL
generator read it from one place.

Profile and seed are parameters:

    make sim VEC_PROFILE=adversarial VEC_COUNT=50000
    make sim VEC_PROFILE=smoke VEC_COUNT=1000000 VEC_SEED=7

`vectors.txt` is not committed -- it is reproducible from profile and seed, both
of which are recorded in the generator's stderr line.

Verilator is the simulator for volume; Icarus stays usable for waveform debug on
a small file (`make sim SIM=icarus VEC_COUNT=100`).