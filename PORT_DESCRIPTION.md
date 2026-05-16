# Port description

Detailed signal protocol and timing for `fir_core`.

## Reset

`rst_ni` is **synchronous active-low**. Hold it low for at least 4
clock cycles before the first AXI4-Stream beat. After de-assertion,
the filter is in the IDLE state with all per-tap accumulator
registers and the output register cleared. `m_axis_tvalid_o` is held
low until the first sample has propagated through the 2-cycle
pipeline.

```
clk_i             __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
rst_ni            ‾‾‾‾‾‾‾|_______________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾
m_axis_tvalid_o   X X X X 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
m_axis_tdata_o    X X X X 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
```

## AXI4-Stream input handshake

The producer drives `s_axis_tvalid_i` and `s_axis_tdata_i`; the FIR
asserts `s_axis_tready_o` when it has room to accept a sample. A beat
is transferred on every cycle where both are high. `s_axis_tready_o`
goes low when the output register is full and the consumer is not
draining it.

```
clk_i           |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
s_axis_tvalid_i  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
s_axis_tready_o  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|_‾‾
s_axis_tdata_i   x0 x1 x2 x3 x4 x5    x6
                                  ^stalled^
```

`tdata_i` and `tvalid_i` may change freely until a beat is offered;
once `tvalid_i` is asserted, AXIS rules apply (the producer must not
de-assert it before `tready_o` accepts the beat).

## AXI4-Stream output handshake

The FIR drives `m_axis_tvalid_o` and `m_axis_tdata_o`; the consumer
drives `m_axis_tready_i`. Once asserted, `m_axis_tvalid_o` and
`m_axis_tdata_o` are stable until the consumer accepts the beat
(SVA-checked).

```
clk_i           |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
m_axis_tvalid_o  __|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|_
m_axis_tready_i  __________|‾‾‾‾‾‾‾‾‾‾‾‾‾
m_axis_tdata_o   xx y0 (held until accepted)
m_axis_tuser_o   xx s0 (held until accepted; 1 = saturated this beat)
```

## Latency

From the cycle a sample is accepted on the input side (TVALID and
TREADY both high) to the cycle the corresponding output beat is
visible on the output side (TVALID high) is exactly **2 clock cycles**:

- Cycle 0: input accepted, partial-sum chain advances.
- Cycle 1: chain settled, accumulator at tap 0 holds the output value.
- Cycle 2: saturated output is registered, `m_axis_tvalid_o` rises.

Latency does NOT depend on `N_TAPS`; it is fixed by the structure of
the pipeline.

## Coefficients

`coeff_i` is a flat packed bus of width `N_TAPS * COEFF_WIDTH`. Tap
`k` occupies bits `[k*COEFF_WIDTH +: COEFF_WIDTH]`. The bus is sampled
combinationally on every accepted input beat, so the host may change
coefficients between beats and the new values take effect on the next
accepted sample.

The coefficient encoding is signed Q1.(COEFF_WIDTH-1) fixed-point. A
coefficient of value `(1 << (COEFF_WIDTH-1))` represents 1.0 (and
saturates to the closest representable value, e.g. 32767 for 16-bit
coefficients). For unity DC gain, the integer-domain sum of all taps
should equal `(1 << (COEFF_WIDTH-1))`.

The accumulator is arithmetic-right-shifted by `COEFF_FRAC` (default
`COEFF_WIDTH-1`) before the saturating output cast, so an input at
full-scale through a unity-DC-gain filter produces an output at
full-scale.

## Saturation

The accumulator is sized to hold the worst-case sum of N_TAPS
products, and the post-shift accumulator is cast to `DATA_WIDTH` with
signed saturation:

- positive overflow -> `(1 << (DATA_WIDTH-1)) - 1`, `tuser_o = 1`
- negative overflow -> `-(1 << (DATA_WIDTH-1))`, `tuser_o = 1`
- in-range          -> exact cast, `tuser_o = 0`

`m_axis_tuser_o` is registered together with the output sample so
the flag is meaningful per-beat, not cumulative.

## Throughput

One sample per cycle once the pipeline is primed and the consumer is
not back-pressuring. Every cycle in steady state can transfer one
input AND one output AXIS beat, because the input acceptance and the
output drain run on independent halves of the same cycle.
