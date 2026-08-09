(lang dune 3.0)
(name packet_filter)

; Generates packet_filter.opam, which `opam install . --deps-only --with-test`
; in CI needs in order to resolve anything. Commit the generated file.
(generate_opam_files true)

(package
 (name packet_filter)
 ; Nothing here is installed: no library or executable carries a public_name.
 ; The package exists solely so `opam install . --deps-only --with-test` has a
 ; dependency list to read in CI. allow_empty states that intent; without it
 ; dune assumes a missing public_name and fails.
 (allow_empty)
 (synopsis "Line-rate 10G packet filter with stateful flow tracking")
 (description
  "Cut-through Ethernet/IPv4 packet filter generated from a single declarative\nprotocol description, verified against an OCaml golden model and\nbounded-induction proofs. Simulation and formal only; see README.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.0))))
