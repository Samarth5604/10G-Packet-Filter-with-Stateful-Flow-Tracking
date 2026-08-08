# 5. IPv4 only; non-initial fragments are unparseable

**Decision:** classify IPv4 exclusively. Model fragmentation as a `guard` on the
IPv4 to L4 edge requiring `frag_offset = 0`. Frames failing any guard, or
carrying an unmatched EtherType or IP protocol, are dropped with a per-reason
counter.

A fragmented IPv4 packet with `frag_offset > 0` carries no L4 header, so no
5-tuple exists for it. The initial fragment (offset 0, MF set) parses normally.

## Alternative: ignore fragmentation entirely

**Pros**
- No guard mechanism needed in the type or the generated RTL.
- Marginally smaller parse logic.

**Cons**
- Later fragments would be parsed as though bytes 20-24 of the payload were L4
  ports, producing a well-formed but meaningless flow key.
- The resulting misclassification is silent: no counter, no drop, no signal that
  anything went wrong.
- Fragment-based classifier evasion is a known attack class against exactly this
  construction.
- Costs nothing to avoid: `frag_offset` ends at bit 64, inside the 20 bytes of
  IPv4 already read for `src_ip` and `dst_ip`, so the parse window is unchanged
  at 46 bytes.

## Alternative: inherit the initial fragment's decision

A secondary table keyed on `(src_ip, dst_ip, id, protocol)` recording the
initial fragment's verdict, so later fragments of the same datagram inherit it.

**Pros**
- Correct forwarding for fragmented traffic rather than a blanket drop.
- What production firewalls do; composes naturally with the existing flow table.

**Cons**
- A second table with its own insert path, eviction policy and memory-port
  contention against the primary table.
- Requires a timeout to avoid unbounded state from datagrams whose remaining
  fragments never arrive, and therefore an ageing mechanism.
- Out-of-order arrival means a later fragment can precede its initial fragment,
  so the miss case still needs a defined policy.
- Deferred to `future/`. Dropping is the safe default.

## Alternative: also classify IPv6

**Pros**
- Broader applicability.

**Cons**
- Extension-header chains are variable-length and variably many, so the parse
  window becomes a function of chain depth and must be bounded arbitrarily.
- A 40-byte fixed header plus chain traversal exceeds the 48-byte asserted parse
  window, raising the cut-through threshold and the floor on latency.
- The 5-tuple widens from 104 to 296 bits, roughly tripling table width.

## Consequences

- Controlling the traffic source narrows what is classified, not what must be
  survived. ARP, IPv6 and LLDP are emitted as negative stimulus; the datapath
  has defined behaviour for every frame it can receive.
- Guard outcomes appear as coverage bins automatically.
