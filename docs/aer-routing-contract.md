<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- Last updated: 2026-09-20 -->

# AER routing contract (aer-route-v1)

This document defines the bounded routing ABI consumed by silicon-hdl for
[GitHub #71](https://github.com/rmems/silicon-hdl/issues/71) / Linear RM-259.
It is a hardware-consumer contract. silicon-hdl does not parse NIR and does not
depend on Rust or nir-rs.

## Ownership boundary

| Layer | Responsibility |
| --- | --- |
| Spikenaut | Treat its canonical NirGraph as the model source, validate the supported Input[16] -> Linear[16x16] -> LIF[16] -> Output[16] shape, and preserve provenance |
| silicon-bridge | Optionally lower validated NIR plus an explicit hardware route plan into a silicon-hdl-v3 + aer-route-v1 bundle; encode route entries and provide target-3 runtime writes |
| silicon-hdl | Load and consume the 16-word route image, expose safe runtime writes, route the selected ingress lane before LIF/STDP, and prove the implementation in simulation, Vivado, and on Basys 3 |

Standard NIR edges do not describe physical FPGA hops. The committed identity
image in this repository is only the silicon-hdl reset/default fixture; it was
not produced from a `nir-rs` `NirGraph` and carries no Spikenaut provenance.
The future producer may lower the current feed-forward graph to identity after
validating that graph and recording its provenance. The synthetic 0 -> 1 -> 2
case proves a hardware capability; it is not topology extracted from NIR.

## Entry ABI

The table contains 16 entries of 16 bits. Address width is 4 and the v1 hop
budget is four lookups.

| Bits | Field | Meaning |
| --- | --- | --- |
| 15 | valid | Zero drops the event and pulses route_fault |
| 14 | terminal | One delivers next_addr; zero performs another lookup |
| 13:4 | reserved | Must be zero; a runtime write or lookup with any bit set fails closed |
| 3:0 | next_addr | Address delivered or used for the next lookup |

Identity entry i is 0xC000 OR i. The committed default image is
synapse-link-hdl/mem/aer_routes_identity_n16.mem with matching JSON metadata.
Its metadata explicitly records `nir_derived: false`; it is not a substitute
for the pending silicon-bridge/Spikenaut producer artifact.
Regenerate it only through:

    python3 scripts/gen_aer_route_vectors.py

Check it without changing files:

    python3 scripts/gen_aer_route_vectors.py --check

## Handshake and timing

AerRouteTable accepts one source address when in_valid and in_ready are both
high. One event may be in flight. Each table lookup consumes one fabric cycle.
in_ready remains low while busy or while a configuration write owns the idle
cycle. A terminal entry produces exactly one out_valid pulse. Invalid entries,
reserved bits encountered during lookup, and failure to reach a terminal entry
within four lookups produce exactly one route_fault pulse and no output.

Reset clears the lookup FSM and pulses but does not clear route memory. The
table starts from identity, an INIT_FILE overrides that image at configuration
time, and accepted runtime writes persist until FPGA reconfiguration.

Configuration writes during an active lookup are rejected with route_fault and
do not modify the table or abort the route already in flight. The main SoC also
holds host writes until the route engine, LIF PE, and STDP writeback are idle.

## Main-SoC behavior

The fixed 0xAA request remains 33 bytes. After SocProtocolFsm atomically commits
the frame, the SoC chooses the lowest nonzero input lane and submits its 4-bit
address to AerRouteTable. Multi-active-lane accumulation remains out of scope.

A successful result is held until a safe logical step_en. The routed address
selects both LifNeuronArray's weight column and StdpWriteback's pre-event
column. If a logical tick arrives before routing finishes, the request remains
pending and is not partially consumed. A route failure resolves the request as
a no-input tick: normal membrane leak/state progression continues and exactly
one normal 36-byte response is armed after that tick.

An all-zero stimulus frame also resolves as a no-input tick without inventing a
route lookup. Routing never adds a UART response field.

## Runtime command

The five-byte write command remains 0xA5, target, address, data_hi, data_lo.

| Target | Destination |
| --- | --- |
| 0 | Weight RAM |
| 1 | Threshold RAM |
| 2 | Leak RAM |
| 3 | AER route table |

Targets above 3 are invalid. Target 3 uses the low four address bits; an
address above 15 or an entry with reserved bits set is rejected and pulses
route_fault. No partial table update occurs.

## Physical diagnostic

Status bit 3 is ingress_fault, the sticky OR of SocProtocolFsm.rx_abort and
AerRouteTable/configuration route_fault. It clears only on reset or the next
completely accepted 0xAA frame. A coincident fault wins over clear. The causes
remain separate in unit-level signals and assertions but share LD3 because the
16-bit physical status map is allocated.

## Compatibility and non-goals

The SiliconBridge v3.0 wire framing is unchanged: 33-byte stimulus request,
36-byte response, lane 0 first, big-endian signed Q8.8 words, and output class
on LEDs only. This work does not add multicast, multiple physical output
ports, arbitration, virtual channels, recurrent synthesis, full vector
accumulation, or NIR parsing in SystemVerilog. SynapseRouter remains the
identity-only standalone demo module; AerRouteTable is the canonical bounded
table used by the main SoC.

Build order is:

    lib_bridge + lib_core + lib_synapse -> lib_soc

## Evidence and claim limits

The free stack proves deterministic table semantics, target-3 decoding, routed
LIF/STDP selection, fault/no-input response behavior, unchanged golden wire
framing, and reproducible generated artifacts. Vivado evidence must additionally
record the exact commit and version, all XSim results, DRC/errors, utilization,
WNS/TNS/WHS/THS, bitstream path, and hashes for xc7a35tcpg236-1.

RM-259 is not complete until a detected Basys 3 is programmed with an identity
bundle exported from Spikenaut's canonical NirGraph through silicon-bridge, a
real 36-byte response matches the simulator/golden expectation, synthetic
0 -> 1 -> 2 changes the observed computation as predicted, and invalid/cyclic
routes produce a normal response plus sticky LD3 that clears on the next valid
frame. A bitstream build or heartbeat-only smoke does not satisfy that gate.
