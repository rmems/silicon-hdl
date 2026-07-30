# Limen-Neural/silicon-hdl Wiki

> This directory is machine-managed by cubic. Edit wiki content through [cubic wiki settings](https://www.cubic.dev/wiki/Limen-Neural/silicon-hdl) and custom instructions.

Wiki version: 2
Source commit: 363bd74df1bb4da85a49af8ab8802170c1251f6c
Source branch: main
Generated: 2026-07-30T06:24:01.699Z

## Contents

### Overview

- [Home](01-sec-overview/01-page-home.md)
- [Getting Started & Setup](01-sec-overview/02-page-getting-started.md)
- [AI & Agent Workflows](01-sec-overview/03-page-agent-workflows.md)
- [Changelog](01-sec-overview/04-page-changelog.md)

### System Architecture

- [Monorepo Layout & Dependencies](02-sec-architecture/01-page-monorepo-layout.md)
- [Deduplication Guardian Engine](02-sec-architecture/02-page-dedup-guardian.md)

### Core Features (SNN Logic)

- [LifNeuron (Leaky Integrate-and-Fire)](03-sec-core-features/01-page-lif-neuron.md)
- [WeightRam (Synaptic Weights)](03-sec-core-features/02-page-weight-ram.md)
- [NeuronParamRam](03-sec-core-features/03-page-neuron-param-ram.md)
- [StdpController (STDP Plasticity)](03-sec-core-features/04-page-stdp-controller.md)
- [SynapseRouter (AER Routing)](03-sec-core-features/05-page-synapse-router.md)

### Bridge & Communication

- [UART Receiver (UartRx)](04-sec-bridge/01-page-uart-rx.md)
- [UART Transmitter (UartTx)](04-sec-bridge/02-page-uart-tx.md)
- [SiliconBridge Protocol Layer](04-sec-bridge/03-page-silicon-bridge.md)

### SoC Integration & Constraints

- [Spikenaut SoC Basys3 Wrapper](05-sec-soc/01-page-soc-basys3.md)
- [Synapse Demo Basys3 Wrapper](05-sec-soc/02-page-synapse-demo.md)
- [FPGA Pin Constraints (XDC)](05-sec-soc/03-page-fpga-constraints.md)

### Testing & QA

- [Verilator Unit Simulation](06-sec-testing/01-page-verilator-sim.md)
- [Local QA Workflow (quality.sh)](06-sec-testing/02-page-local-qa.md)
- [Vivado Simulation](06-sec-testing/03-page-vivado-sim.md)

### Deployment & Infrastructure

- [Vivado Synthesis & Implementation](07-sec-deployment/01-page-vivado-build.md)
- [Self-Hosted Vivado CI](07-sec-deployment/02-page-vivado-ci.md)
- [Timing Analysis & WNS Checks](07-sec-deployment/03-page-timing-analysis.md)
