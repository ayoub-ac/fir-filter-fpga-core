# fir-filter-fpga-core

[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen.svg)](#verification)
[![Lint](https://img.shields.io/badge/Verilator%20lint-clean-brightgreen.svg)](#build--test)

A small, synthesisable parametric FIR filter IP core in SystemVerilog.
Transposed direct form, AXI4-Stream input/output, signed saturating
output cast, runtime-reconfigurable coefficients. Targets iCE40, ECP5,
Xilinx 7-series, Cyclone V, and Tang Nano 9K.

The core is verified bit-exactly against `scipy.signal.lfilter`
running the same coefficients on the same input streams (16-tap and
32-tap Hamming-windowed low-pass), with backpressure, saturation, and
mid-stream coefficient-reconfiguration tests added on top. No FPGA
hardware is required for the test suite.

## What this core is for

| Domain                       | Use                                             |
|------------------------------|-------------------------------------------------|
| Software-defined radio       | Channel select / decimation / interpolation     |
| Audio DSP                    | EQ stages, anti-aliasing, anti-imaging          |
| Instrumentation              | Anti-alias before ADC, smoothing after ADC      |
| ML preprocessing             | Pre-emphasis, low-pass before resampling        |
| Industrial sensor front-end  | Mains-hum notch, sensor noise filtering         |

One sample in, one sample out, deterministic 2-cycle latency
(input-accept to TVALID). The longest combinational path is exactly
one multiplier + one adder, so f_max scales independently of the tap
count.

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

- Per-tap multiplier infers a single DSP block on Vivado / Quartus.
- One register per tap; pipeline depth is constant in N.
- Coefficients sampled combinationally on every accepted input
  (runtime reconfiguration takes effect on the next sample).

## Quickstart

```bash
git clone https://github.com/ayoub-ac/fir-filter-fpga-core.git
cd fir-filter-fpga-core
make lint test            # Verilator lint + scipy cross-validation
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

A passing run ends with `+PASS all tests passed` and exits 0.

## Verification

| # | Test                              | Coverage                                                    |
|---|-----------------------------------|-------------------------------------------------------------|
| 1 | Reset behaviour                   | TVALID held low after reset                                 |
| 2 | 16-tap low-pass cross-validation  | 256 random int16 samples, bit-exact vs `scipy.signal.lfilter` |
| 3 | 32-tap low-pass cross-validation  | 256 samples, bit-exact vs `scipy.signal.lfilter`            |
| 4 | Backpressure                      | Throttled TREADY, output stream still bit-exact             |
| 5 | Saturation                        | Overscaled coefficients force clip; tuser agrees with rail  |
| 6 | Coefficient reconfig mid-stream   | Identity to low-pass swap; output transitions on next sample|

Six SVA properties run on every cycle (TVALID stable, TDATA stable,
TREADY non-X, output bounded under saturation, no phantom outputs,
in-flight count bounded). Eight functional coverage bins reach 100%
(`in16_handshake`, `in32_handshake`, `out16_handshake`,
`out32_handshake`, `backpressure_in`, `backpressure_out`,
`saturated_high`, `saturated_low`).

## Synthesis

`make synth_report` runs every available toolchain on the same RTL
and emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md). Yosys (ice40 / ecp5 /
xilinx) is mandatory; Vivado and Quartus are detected automatically.

## Variants

| Variant                            | Use case                                            | Tier |
|------------------------------------|-----------------------------------------------------|------|
| `rtl/fir_core.sv`                  | Default 16-tap / 16-bit / Q1.15 transposed FIR      | GPL  |
| `rtl/fir_saturate.sv`              | Saturating signed cast (drop-in)                    | GPL  |
| `vhdl_wrapper/fir_core_vhdl.vhd`   | VHDL-2008 entity wrapping the SV core               | All  |

Premium tier (on roadmap, not yet shipped): symmetric-coefficient
folded variant for 50% multiplier savings, time-multiplexed single-
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
