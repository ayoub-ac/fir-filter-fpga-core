# Resource estimates

Numbers below are from Yosys 0.x generic synthesis (`make synth_report`).
They are pre-place-and-route. See `SYNTH_REPORT.md` for the most recent
run; this document explains what dominates the area and how to shrink
it.

## Summary (post-Yosys, pre-PnR)

Configuration: `N_TAPS = 16`, `DATA_WIDTH = 16`, `COEFF_WIDTH = 16`.

| Target                         | Comment |
|--------------------------------|---------|
| Lattice iCE40 UP5K             | LUT-heavy when DSP inference is off (16 signed multipliers cost ~1500 LUT4); with `synth_ice40 -dsp` Yosys infers SB_MAC16 blocks and the soft LUT count drops below 600. The UP5K has 8 SB_MAC16 blocks, so a 16-tap filter at default width fits but is tight; a 32-tap filter requires the Premium symmetric-folded variant. |
| Lattice ECP5 LFE5UM-25         | ECP5 has MULT18X18 blocks; Yosys with `-abc9` packs each multiplier into one and the soft LUT count drops to a couple of dozen. 16 DSPs used. |
| Xilinx Artix-7 XC7A35T         | Yosys-generic synthesis here splits each 16x16 into two halves (`mul_int_l/h`), so the DSP count appears doubled. Vivado synth_design folds each multiplier into a single DSP48E1 with one input register and one output register; the soft LUT count drops further. |
| Cyclone V 5CSEMA5F31C6         | Quartus folds each multiplier into a single MULT18X18 block. ALM count is much lower than the Yosys soft estimate. |
| Gowin GW1NR-9 (Tang Nano 9K)   | Not characterised here. Vendor flow uses MULT9X9 / MULT18X18 hard blocks; size comparable to ECP5. |

For exact LUT/FF/DSP/BRAM numbers run `make synth_report` and read
`SYNTH_REPORT.md`. The synthesis-comparison report is regenerated on
every CI build.

## What dominates the area

- **`N_TAPS` parallel signed multipliers** (`x[n] * h[k]`). With
  default `DATA_WIDTH = COEFF_WIDTH = 16`, each is a 16-bit signed *
  16-bit signed product (32-bit result). Yosys generic flow maps them
  to LUT4 carry chains; vendor flows pack each into a single DSP block.
- **`N_TAPS` per-tap accumulator registers**, each `ACC_W` bits wide
  (`DATA_WIDTH + COEFF_WIDTH + ceil(log2(N_TAPS)) + 1` = 37 bits at
  default). Total FF count grows linearly with the tap count.
- **`N_TAPS` per-tap adders** on the partial-sum chain; the synthesiser
  packs the carry chain. The adder critical path is exactly one adder
  long regardless of the tap count.
- **Saturating output cast**: a pair of `ACC_W`-bit comparators plus a
  3:1 mux. Negligible compared to the multipliers.
- **AXIS handshake glue**: a single FF (`out_full_q`) plus an
  in-flight tracking FF (`accept_q1`). Negligible.

## What you can do to shrink it

- **Reduce `COEFF_WIDTH`**. Q1.7 (`COEFF_WIDTH = 8`) cuts each
  multiplier by ~4x area and may be perfectly fine for low-fidelity
  audio or instrumentation. Stop-band rejection drops to ~50 dB.
- **Reduce `DATA_WIDTH`**. 12-bit ADC front-ends often drive a 12-bit
  data path; the multiplier becomes 12 * 16 -> 28-bit and the
  accumulator narrows accordingly.
- **Symmetric folding** (Premium tier). For symmetric impulse
  responses (linear-phase filters), pair-add the mirrored taps before
  the multiply. Halves the multiplier count for even `N_TAPS`.
- **Time-multiplexed single multiplier** (Premium tier). One
  multiplier shared across all taps, latency = `N_TAPS` cycles
  per sample. Recommended for tiny iCE40 designs where the DSP
  count is the binding constraint.
- **Vendor flow with DSP inference**: on Vivado / Quartus / Diamond,
  setting the multiplier registers as input + output pipeline stages
  lets the DSP block absorb both stages. The Yosys-generic estimate
  is the upper bound.

## What you can do to push throughput / accuracy

- **Increased `COEFF_WIDTH`** for high-SFDR filters. Q1.23 (24-bit
  coefficients) gives >120 dB stop-band rejection at the cost of
  ~50% more multiplier area on Yosys, ~0% on Vivado / Quartus (same
  DSP block accepts up to 18-bit operands).
- **Polyphase decimator / interpolator** (roadmap). For sample-rate
  conversion by an integer factor M, run only one phase of the
  filter per output sample; the multiplier count stays the same but
  the output rate is divided by M.
- **Pipelined multiplier register stage** (roadmap). Insert a register
  in front of each multiplier; vendor DSP blocks absorb it for free,
  and `f_max` rises to >300 MHz on Artix-7.

## Frequency

- iCE40 UP5K with `synth_ice40 -dsp`: SB_MAC16 multiplier path ~80
  MHz; plenty for 48 kHz audio (which only needs ~1 MHz of compute
  budget for a 16-tap filter).
- ECP5 with MULT18X18 packing: ~150-200 MHz.
- Artix-7 -1 speed grade: ~150 MHz with Yosys, ~250+ MHz with Vivado
  synth_design and DSP retiming.
- Cyclone V: similar to Artix-7 with MULT18X18 blocks.

## Power

Ballpark: 5-15 mW dynamic on iCE40 UP5K at 50 MHz, depending on input
duty cycle. The 16 multipliers toggle once per accepted sample; the
accumulator chain toggles once per accept. Static power is dominated
by the FPGA itself.

## How to reproduce

```bash
make synth_report
```

This runs Yosys with `synth_ice40 -dsp`, `synth_ecp5 -abc9`, and
`synth_xilinx`, then `stat`, and writes the result to
`SYNTH_REPORT.md`. Vendor flows (Vivado, Quartus) are detected
automatically when on PATH.

For end-to-end place-and-route numbers (post-PnR LUT counts and
timing), run the vendor flow:

- iCE40 / ECP5: `nextpnr-ice40` / `nextpnr-ecp5` with Yosys output.
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
- Quartus: project with `rtl/` added.
