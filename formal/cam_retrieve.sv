// cam_retrieve.sv -- retrieval sub-property for cam_d8_w104 (the flow-table
// stash CAM), checked with SymbiYosys.
// -----------------------------------------------------------------------
// SCOPE, READ THIS FIRST: this is NOT ADR 0006 property #4 ("any inserted,
// non-evicted key is retrievable within the bounded probe count"). That
// property is about the whole flow table -- cuckoo hash ways plus this
// stash -- and the cuckoo-way RTL does not exist yet, only this CAM has
// been generated. What is proved here is a necessary sub-property: the
// stash itself never loses or misreports an entry it holds. It says
// nothing about whether an insert successfully reaches a slot in the
// first place, or about probe count, because that logic is not RTL yet.
//
// Semantics under proof (read from bin/gen_cam.ml, not guessed from the
// obfuscated netlist):
//   - entries[wr_idx] <= wr_key, valid[wr_idx] <= wr_valid, both registered
//     on any cycle with wr_en=1. wr_valid=0 invalidates the slot.
//   - match_found / match_idx / free_idx / full are THEMSELVES registered:
//     one cycle of latency from search_key to the match outputs.
//   - `clear` independently resets EVERY register in the design on the same
//     edge -- entries[], AND match_found/match_idx's own registers -- not
//     just storage. Confirmed by reading the generated netlist and by
//     simulating a real counterexample: a clear pulse coincident with a
//     search always reports "no match" that cycle, even if the entry being
//     searched for was genuinely present a moment before the clear.
//   - gen_cam.ml's own comment: "entries are unique by construction -- the
//     caller must not write the same key twice". That is an assumption on
//     the (not-yet-built) allocator, not something this module enforces or
//     this proof can establish -- it is assumed below, explicitly, so the
//     assumption is visible rather than silently baked in.
//
// STATUS: `bmc` (bounded, depth 40) and `prove`'s basecase verified clean
// against the three fixes below, each confirmed by replaying the real
// counterexample through a plain simulator (Icarus). `prove`'s induction
// step fails on those three alone -- not because they are wrong
// (bmc/basecase agree they aren't), but because k-induction's arbitrary
// starting window isn't anchored by $initstate the way bmc/basecase's
// reset-anchored reachability is, so induction can pick a window where the
// ghost `holds` and the DUT's real stored entry were never forced to
// agree. An attempt to close that gap by comparing `holds` directly
// against cam.v's internal registers (via `dut._17`-style hierarchical
// references) was tried and removed: it is fundamentally incompatible with
// Yosys's `-formal` frontend, which silently creates disconnected phantom
// wires for such references instead of resolving them (visible as
// "implicitly declared" / "used but has no driver" warnings in the build
// log -- read those as disqualifying, not incidental, if they appear
// again). Confirmed by simulation that the underlying structural reasoning
// was sound; the failure was purely a tooling limitation. Full induction
// on this property remains open. Document it as such in the ADR rather
// than force a fix that doesn't actually check what it claims to.

module cam_retrieve_check (
    input             clock,
    input             clear,
    input      [103:0] search_key,
    input      [103:0] wr_key,
    input      [2:0]   wr_idx,
    input              wr_en,
    input              wr_valid
);

  wire match_found;
  wire [2:0] match_idx;
  wire [2:0] free_idx;
  wire full;

  cam_d8_w104 dut (
      .clock(clock),
      .clear(clear),
      .search_key(search_key),
      .wr_key(wr_key),
      .wr_idx(wr_idx),
      .wr_en(wr_en),
      .wr_valid(wr_valid),
      .match_found(match_found),
      .match_idx(match_idx),
      .free_idx(free_idx),
      .full(full)
  );

  // A symbolic key and index, fixed for the whole trace: $anyconst picks
  // one value and holds it, which is exactly "for any key, for any index"
  // under bounded model checking / k-induction.
  (* anyconst *) reg [103:0] target_key;
  (* anyconst *) reg [2:0]   target_idx;

  reg first;
  initial first = 1;

  // BUG FIXED HERE, first attempt: without this, `clear` is a free input and
  // the DUT's internal entries[i].(key,valid) registers start completely
  // unconstrained in BMC/induction -- independent free variables from the
  // ghost `holds` bit below, with nothing tying them together. The solver
  // is then free to pick an initial state where some entry is already
  // "valid" with garbage content before any wr_en has ever fired, which is
  // exactly what produced the first counterexample (target_key = all-ones,
  // i.e. the solver's cheapest way to hit that free initial state). Forcing
  // clear=1 at the first cycle makes the DUT's synchronous clear and the
  // ghost's `if (clear) holds <= 0` fire together, so both provably start
  // from the same known-empty state instead of two uncorrelated ones.
  always @* begin
    if ($initstate)
      assume (clear);
  end

  // Ghost bit: tracks ground truth for "is target_key currently live at
  // target_idx", independent of the DUT, so the DUT's outputs can be
  // checked against it instead of against themselves.
  reg holds;
  initial holds = 1'b0;

  always @(posedge clock) begin
    if (clear)
      holds <= 1'b0;
    else if (wr_en && wr_idx == target_idx)
      // BUG FIXED HERE, second attempt: this used to be just `holds <=
      // wr_valid`, which only checks that the write landed at target_idx --
      // not that it was a write OF target_key. A write of some other key to
      // target_idx with wr_valid=1 made the ghost believe target_key was
      // now live there, when the DUT correctly now holds a different key.
      // That produced a counterexample where match_found was correctly 0
      // and the ghost's assertion that it should be 1 was simply wrong.
      holds <= wr_valid && (wr_key == target_key);
    first <= 1'b0;
  end

  // Assumed, not proved: gen_cam.ml's documented contract on its caller
  // ("entries are unique by construction"). Written explicitly so it is
  // visible as a precondition of this proof rather than an invisible one.
  //
  // BUG FIXED HERE, third attempt: this used to be `if (wr_en && wr_key ==
  // target_key && wr_idx != target_idx) assume (!holds)` -- which only
  // blocked writing target_key elsewhere WHILE it was currently held at
  // target_idx. It said nothing about the reverse order: write target_key
  // to some other index FIRST (while holds is still false, so that guard
  // was trivially satisfied), then write target_key to target_idx too --
  // a genuine duplicate that "unique by construction" is supposed to rule
  // out entirely. Confirmed by simulation: a real counterexample wrote
  // target_key to index 6, then to target_idx=7, and the CAM correctly
  // reported match_idx=6 (lower index wins priority) while the old,
  // order-dependent assumption never noticed the first write was a problem.
  // The fix is unconditional: target_key is never written anywhere other
  // than target_idx, for the whole trace, regardless of holds' value.
  always @(posedge clock) begin
    if (!first && wr_en && wr_valid && wr_key == target_key && wr_idx != target_idx)
      assume (1'b0);
  end

  reg holds_d, search_was_target, clear_d;
  initial clear_d = 1'b0;
  always @(posedge clock) begin
    holds_d <= holds;
    search_was_target <= (search_key == target_key);
    // Confirmed by simulating a real counterexample against the actual
    // netlist (not assumed): `clear` does not only gate whether entries[]
    // update -- match_found's and match_idx's own registers (_99, _159 in
    // the generated netlist) ALSO reset independently on the same edge
    // under `if (clear)`, overriding whatever the combinational match
    // result was that cycle. A clear pulse coincident with a search
    // therefore always reports "no match" that cycle, even if the entry
    // being searched for was genuinely present a moment before the clear.
    // That is real, intentional behaviour (global synchronous clear wipes
    // downstream results too, not just storage) -- the fix is to account
    // for it, not to assume it away.
    clear_d <= clear;
  end

  // AN AUXILIARY INVARIANT WAS ATTEMPTED HERE AND REMOVED. It tried to
  // anchor k-induction by comparing `holds` directly against cam.v's
  // internal per-entry registers via hierarchical dot references
  // (dut._17, dut._64, etc.), reasoning that both update from identical
  // trigger conditions every cycle and should therefore provably agree.
  // That reasoning was correct -- confirmed by simulating a real,
  // reset-anchored counterexample through Icarus, which showed zero
  // discrepancy at every step. Yosys's own SMT encoding disagreed anyway,
  // and the reason is a tooling incompatibility, not a logic error: Yosys's
  // `-formal` Verilog frontend does not resolve `dut._17`-style hierarchical
  // references into a submodule's internal (non-port) signals the way
  // Icarus does. It silently declares a brand-new, disconnected wire with
  // that literal name instead of erroring -- visible in the build log as
  // "Identifier `\dut._17' is implicitly declared" / "Wire ... is used but
  // has no driver", which should have been read as disqualifying the whole
  // approach the first time they appeared, not treated as incidental noise.
  // The result: true_valid/true_key were free, unconstrained variables in
  // the SMT model, not real state, and the solver exploited exactly that.
  // A working version of this technique would need cam.v's internal state
  // genuinely exposed through real output ports (a wrapper module, or
  // regenerating cam.v with debug ports) rather than an ad-hoc hierarchical
  // reference -- out of scope for now.

  // The property. One cycle after `holds` became true and the search was
  // for target_key, the DUT must report a match at target_idx -- unless a
  // clear was asserted on that same cycle, which correctly suppresses the
  // match result regardless of what was stored. Must NOT report a match at
  // target_idx when `holds` is false.
  always @(posedge clock) begin
    if (!first) begin
      if (holds_d && search_was_target && !clear_d) begin
        assert (match_found);
        assert (match_idx == target_idx);
      end
      if (!holds_d && search_was_target) begin
        assert (!(match_found && match_idx == target_idx));
      end
    end
  end

endmodule