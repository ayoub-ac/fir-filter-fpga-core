# fir-filter-fpga-core

[![License: GPL-3.0 | commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)

> **Status: experimental and unverified.** This core was written with AI assistance and has not been independently verified in simulation regressions, formal proofs or hardware. Claims in this repository about protocol compliance, test results, timing and resource use are unverified. Do not use it in production or safety-critical designs without your own verification. No support or maintenance is provided.

A small, synthesisable parametric FIR filter IP core in SystemVerilog.
Transposed direct form, AXI4-Stream input/output, signed saturating
output cast, runtime-reconfigurable coefficients. Intended for iCE40, ECP5,
Xilinx 7-series, Cyclone V, and Tang Nano 9K; not verified on any of them.

The included testbench is intended to compare the core bit-exactly
against `scipy.signal.lfilter` running the same coefficients on the
same input streams (16-tap and 32-tap Hamming-windowed low-pass), with
backpressure, saturation, and mid-stream coefficient-reconfiguration
tests added on top. Tests are included; results not independently
confirmed. No FPGA hardware is required for the test suite.

## What this core is for

| Domain                       | Use                                             |
|------------------------------|-------------------------------------------------|
| Software-defined radio       | Channel select / decimation / interpolation     |
| Audio DSP                    | EQ stages, anti-aliasing, anti-imaging          |
| Instrumentation              | Anti-alias before ADC, smoothing after ADC      |
| ML preprocessing             | Pre-emphasis, low-pass before resampling        |
| Industrial sensor front-end  | Mains-hum notch, sensor noise filtering         |

One sample in, one sample out, intended 2-cycle latency
(input-accept to TVALID; not verified). The longest combinational path
is intended to be one multiplier + one adder, so f_max should scale
independently of the tap count (not verified).

## Architecture

Transposed direct form: data is broadcast to all per-tap multipliers,
and the registers sit on the partial-sum accumulator chain rather
than on a sample delay line.

```
       x[n]
        |
    .---+---+---+--- ... ---+---.
    *h0 *h1 *h2             *h_{N-1}
     \    \   \                /
      (+)< (+)< ...           /
       |    |                |
     [reg][reg]            [reg]
       |    |                |
       '----+----- ... ------'   ->  >>> (Q1.15)  ->  saturate(int16)
```

Properties:

- Per-tap multiplier is intended to infer a single DSP block on Vivado / Quartus (not verified).
- One register per tap; pipeline depth is constant in N.
- Coefficients sampled combinationally on every accepted input
  (runtime reconfiguration takes effect on the next sample).

## Quickstart

```bash
git clone https://github.com/ayoub-ac/fir-filter-fpga-core.git
cd fir-filter-fpga-core
make lint test            # Verilator lint + scipy cross-validation (results not independently confirmed)
make synth_report         # SYNTH_REPORT.md across iCE40/ECP5/Xilinx/Vivado/Quartus
```

Requires Verilator 5.0+ for simulation, Yosys 0.30+ for the open synth
flow, and Python 3 with `numpy` + `scipy` for vector regeneration.

## Port summary

| Signal                          | Dir | Width             | Description                                    |
|---------------------------------|-----|-------------------|------------------------------------------------|
| `clk_i / rst_ni`                | in  | 1                 | System clock; synchronous active-low reset.    |
| `coeff_i`                       | in  | N_TAPS*COEFF_W    | Flat packed coefficient bus (tap k = bits k*W).|
| `s_axis_tdata_i`                | in  | DATA_WIDTH        | Input sample, signed.                          |
| `s_axis_tvalid_i / _tready_o`   | in/out | 1              | AXI4-Stream input handshake.                   |
| `m_axis_tdata_o`                | out | DATA_WIDTH        | Output sample, signed, saturated.              |
| `m_axis_tvalid_o / _tready_i`   | out/in | 1              | AXI4-Stream output handshake.                  |
| `m_axis_tuser_o`                | out | 1                 | Saturation flag for the current output beat.   |

Detailed handshake timing in [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md).

## Build & test

```bash
make lint            # static check the RTL
make test            # build and run the full regression
```

The testbench is written to end with `+PASS all tests passed` and exit 0 on success. Tests are included; results not independently confirmed.

## Verification

Intended tests (included in `tb/`; results not independently confirmed):

| # | Test                              | Coverage                                                    |
|---|-----------------------------------|-------------------------------------------------------------|
| 1 | Reset behaviour                   | TVALID held low after reset                                 |
| 2 | 16-tap low-pass cross-validation  | 256 random int16 samples, bit-exact vs `scipy.signal.lfilter` |
| 3 | 32-tap low-pass cross-validation  | 256 samples, bit-exact vs `scipy.signal.lfilter`            |
| 4 | Backpressure                      | Throttled TREADY, output stream compared bit-exactly        |
| 5 | Saturation                        | Overscaled coefficients force clip; tuser agrees with rail  |
| 6 | Coefficient reconfig mid-stream   | Identity to low-pass swap; output transitions on next sample|

Six SVA properties are written to be checked on every cycle (TVALID
stable, TDATA stable, TREADY non-X, output bounded under saturation,
no phantom outputs, in-flight count bounded). Eight functional coverage
bins are defined; coverage results not independently confirmed
(`in16_handshake`, `in32_handshake`, `out16_handshake`,
`out32_handshake`, `backpressure_in`, `backpressure_out`,
`saturated_high`, `saturated_low`).

## Synthesis

`make synth_report` runs every available toolchain on the same RTL
and emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md). Yosys (ice40 / ecp5 /
xilinx) is mandatory; Vivado and Quartus are detected automatically.

## Variants

| Variant                            | Use case                                            |
|------------------------------------|-----------------------------------------------------|
| `rtl/fir_core.sv`                  | Default 16-tap / 16-bit / Q1.15 transposed FIR      |
| `rtl/fir_saturate.sv`              | Saturating signed cast (drop-in)                    |
| `vhdl_wrapper/fir_core_vhdl.vhd`   | VHDL-2008 entity wrapping the SV core               |

Possible future variants (not implemented): symmetric-coefficient
folded variant to reduce the multiplier count, time-multiplexed single-
multiplier variant for tiny iCE40 targets, polyphase decimator /
interpolator variants for sample-rate conversion.

## License

Dual-licensed: **GPL-3.0-or-later** for open-source projects, or
**commercial** for closed-source products. See [`LICENSE.md`](LICENSE.md).

## Citation

```bibtex
@misc{fir-filter-fpga-core,
  title  = {{fir-filter-fpga-core}: a small dual-licensed parametric FIR filter IP core in SystemVerilog},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/fir-filter-fpga-core}}
}
```

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
