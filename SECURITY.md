# Security model

`fir-filter-fpga-core` is a DSP IP core, not a cryptographic
primitive. The "security" considerations are different from an
AES / SHA / signature core: there are no keys, no nonces, and no
confidentiality goal. What the consumer of this core needs to evaluate
is **functional correctness** — the conditions under which the filter
produces a result that does not match the mathematical specification.

If this core sits in a path where a wrong filter output can damage
hardware or harm a human (closed-loop control with a FIR pre-filter,
SDR receiver feeding a transmitter, instrumentation feeding a safety
interlock), read this whole document and decide whether the failure
modes match your deployment.

## What the RTL is intended to provide (not verified)

### 1. Bit-exact match against `scipy.signal.lfilter`

Every output beat is intended to be bit-exact equal to the corresponding sample of
`scipy.signal.lfilter(h, [1], x)` followed by an arithmetic right
shift of `COEFF_FRAC` and a signed clip to `DATA_WIDTH` bits.
The included testbench is written to check this across 256 random
int16 input samples for 16-tap and 32-tap Hamming-windowed low-pass
filters, with a second hand-rolled integer convolution as a parallel
oracle. Tests are included; results not independently confirmed.

### 2. Output stays within `[-2^(DATA_WIDTH-1), 2^(DATA_WIDTH-1)-1]`

Every published sample is clamped by `fir_saturate.sv` before being
registered. The clamp is intended to be enforced in hardware; not
verified. SVA property `p_output_bounded` is written to fail the
regression if `m_axis_tuser_o` is high
and `m_axis_tdata_o` is not at one of the rails.

### 3. AXI4-Stream handshake rules

`m_axis_tvalid_o` and `m_axis_tdata_o` are intended to be stable once
asserted, and to remain asserted until accepted by the consumer; not
verified. SVA properties `p_tvalid_stable` and `p_tdata_stable` are
written to check this on every cycle. Backpressure on the output is
intended to stall the input so that no beats are dropped or reordered;
not verified.

### 4. Intended 2-cycle latency

From the cycle a sample is accepted (TVALID & TREADY both high) to
the cycle the corresponding output beat is visible (TVALID high) is
intended to be 2 clock cycles (not verified), regardless of `N_TAPS`, `DATA_WIDTH`, or the
sample value. There is no data-dependent timing.

### 5. Reset clears all state

`rst_ni == 0` is intended to synchronously zero every per-tap accumulator, the
output register, the saturation flag, and the in-flight valid bit.
After de-assertion, the first accepted sample should produce a result
as if the filter had never run. Not verified.

## What is NOT covered (be honest)

- **Faulty coefficient values.** If the host writes coefficients
  whose integer sum exceeds `2^COEFF_FRAC`, the filter has DC gain
  greater than 1.0 and the output will saturate aggressively on
  full-scale input. The hardware reports saturation via `tuser_o`
  but does not refuse the configuration. A range-check in the host
  is the right place to enforce coefficient policy.
- **Coefficient bus glitches.** `coeff_i` is sampled combinationally
  on the cycle a sample is accepted. If the host changes coefficients
  in the same cycle as TVALID is high (and TREADY is high), the
  resulting output may be a hybrid of old and new. Hold coefficients
  stable across the accept boundary.
- **Single-event upsets / radiation.** No TMR, no parity, no
  duplicated state. For aerospace deployment, wrap the core in TMR
  or use the FPGA's safety primitives.
- **Numerical noise from quantisation.** Coefficients are signed
  Q1.(COEFF_WIDTH-1). Designs that need >120 dB stop-band rejection
  may need wider coefficients than the default 16 bits; bump
  `COEFF_WIDTH` and re-run synthesis.
- **Side channels.** This is a DSP core. Power / EM analysis to
  recover coefficients is possible in principle but uninteresting in
  practice (coefficients are typically not secret). No specific
  countermeasure.

## Evaluating the implementation

The included testbench is written to cover six failure modes (tests are
included; results not independently confirmed):

1. **Reset behaviour.** Outputs are TVALID = 0 after reset until a
   sample propagates through the pipeline.
2. **16-tap low-pass cross-validation** (256 random int16 samples).
   Every output beat is compared against `scipy.signal.lfilter`.
3. **32-tap low-pass cross-validation** (256 samples).
4. **Backpressure.** TREADY toggled on a 1/N duty cycle for both
   filters; output stream compared bit-exactly.
5. **Saturation.** A deliberately-overscaled filter forces clipping;
   `tuser_o` is checked against the rail value.
6. **Coefficient reconfig mid-stream.** Identity-ish filter, then
   low-pass; the output transition on the next sample is checked.

Six SVA properties are written to be checked on every cycle of every
test (`tvalid_stable`, `tdata_stable`, `tready_no_x`, `output_bounded`,
`no_phantom_out`, `inflight_bounded`). Eight functional coverage bins
are defined. Assertion and coverage results are not independently
confirmed.

## Safe-deployment checklist

1. Validate the integer-domain sum of your coefficient bank in the
   host before writing it: it should equal `1 << (COEFF_FRAC)` for a
   unity-DC-gain filter.
2. Hold `rst_ni` low for at least 4 cycles after power-on and before
   the first AXIS beat. The hardware needs the registers to settle.
3. If the consumer can stall for an extended period, decide whether
   to drop samples (let the input back off via TREADY) or buffer
   them externally. The core is intended to buffer 1 in-flight beat
   plus 1 output beat (not verified); longer stalls back-pressure the upstream.
4. If the application requires >100 dB SFDR at the filter output,
   bump `COEFF_WIDTH` to 24 or 32 and re-validate against scipy with
   the same scaling.

## Reporting issues

Found a discrepancy with `scipy.signal.lfilter`, an AXIS contract
violation, or a corner case the assertions miss? Open a GitHub issue
(do not include confidential details). No support or maintenance is
provided. We do not currently offer a bug bounty.
