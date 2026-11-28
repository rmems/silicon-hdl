<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->

# Consuming a silicon-bridge NIR/AER bundle

The Basys 3 SoC consumes memory images. Spikenaut owns the canonical NIR
graph and its model provenance. silicon-bridge validates the graph, lowers
its parameters and emits the bundle. The three owning issues link to the
shared design in [silicon-hdl #74](https://github.com/rmems/silicon-hdl/issues/74).
Track the model, exporter and hardware work in
[Spikenaut-SNN #65](https://github.com/rmems/Spikenaut-SNN/issues/65),
[silicon-bridge #79](https://github.com/rmems/silicon-bridge/issues/79)
and [silicon-hdl #71](https://github.com/rmems/silicon-hdl/issues/71).

## Graph and route selection

The exporter accepts a dense feed-forward graph with 16 inputs, 16 hidden
neurons and a required three-class readout. Its runnable example uses
`Input[16] → Linear[16×16] → LIF[16] → Linear[3×16] → Output[3]`.
A graph ending directly at `Output[16]` lacks the readout required by this
profile. The producer checks graph structure and neuron parameters before
export. Unsupported nodes such as CubaLIF return `MapError::Unsupported`.
Incompatible profile dimensions or a missing readout return
`MapError::InvalidParameter`. [Producer implementation](https://github.com/rmems/silicon-bridge/blob/b0cdcf8776dbe98fcb1519185edddbc4ce74fb5e/src/nir_map.rs)

Passing `None` to `aer_export_config_from_nir` derives identity from the
input lane order. Passing `Some(table)` supplies the physical routing plan
explicitly. Ordinary NIR edges describe graph connectivity. Either mode can
set `nir_derived: true`, so inspect `route_source` to distinguish them.
The producer rejects reserved bits, dangling forwarding chains and paths
that exceed the four-lookup budget. A disabled source is valid and drops
its event. [Route entry ABI and fault behavior](aer-routing-contract.md#entry-abi)

## Reading the bundle

Read the following fields under `metadata` in `parameters.json` before
selecting images for this SoC. These identifiers describe the AER profile
added in [silicon-bridge PR #150](https://github.com/rmems/silicon-bridge/pull/150).

| Field | Value or check |
| --- | --- |
| `profile` / `schema_version` | `silicon-hdl-v3-aer-route-v1` / `silicon-hdl-v3-aer-route-v1-profile-v1` |
| `compatibility.contract_id` | `silicon-bridge-silicon-hdl-v3-aer-route-v1-contract-v1` |
| `aer_routing.schema` / `filename` | `aer-route-v1` / `aer_routes.mem`. The filename also appears in `compatibility.aer_routes`. |
| `aer_routing.entry_count`, `entry_width`, `address_width`, `max_hops` | 16 entries, 16 bits per entry, 4 address bits, 4 lookups including the first |
| `aer_routing.route_source` / `nir_derived` | `canonical_input_order` or `explicit_hardware_plan`, plus the NIR provenance flag |
| `aer_routing.hdl_revision` / `compatibility.reference.revision` | Both identify the producer's reference HDL revision, `bcdf630c01016ea0ba4d4637af4911b81e30a592` at the producer pin below. Record the HDL commit actually tested separately. |
| `producer_crate`, `producer_version`, `compatibility.silicon_bridge_revision` | Identify the exporter. Record the checkout SHA separately when the build reports `unknown`. |
| `artifact_hashes` | Lowercase SHA-256 keyed by filename for every emitted `.mem`. Hash the exact file bytes, including line endings. |

Match the parameter banks using `compatibility.files`. They contain signed
Q8.8 words. The checked profile truncates toward zero and rejects overflow.

| Bundle image | Consumer and address order |
| --- | --- |
| `parameters_weights.mem` | Hidden weight RAM, 16 neuron rows × 16 input columns |
| `parameters.mem` / `parameters_decay.mem` | Threshold / leak RAM, one word per hidden neuron |
| `hdl_readout_neuron_major.mem` | OutputLayer, 16 neuron rows × 3 classes. The producer also emits `parameters_output_weights.mem` in class-major order for generic clients. |
| `aer_routes.mem` | AerRouteTable, one unquantized route entry per source lane |

SiliconBridge v3.0 uses a 33-byte stimulus request and a 36-byte response.
The existing five-byte `0xA5` write selects target 3 for a route entry.
The output readout bank is initialized at configuration time.
[UART wire layout](interface-alignment.md) · [Producer profile](https://github.com/rmems/silicon-bridge/blob/b0cdcf8776dbe98fcb1519185edddbc4ce74fb5e/docs/aer-route-v1.md)

## Reproducing an example export

From silicon-bridge at `b0cdcf8776dbe98fcb1519185edddbc4ce74fb5e`, run
`cargo run --features nir --example nir_aer_export`. The example writes
`nir_aer_out/parameters.json` and six memory images using an in-memory
example graph. For a canonical Spikenaut run, package the graph revision
and digest alongside the bundle. The route provenance flag and memory-image
hashes alone cannot identify the source graph. For a board claim, record
the programmed bitstream and observed UART trace against the same bundle.
[Board evidence requirements](aer-routing-contract.md#evidence-and-claim-limits)
