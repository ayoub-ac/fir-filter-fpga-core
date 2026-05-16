// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Parametric FIR filter (transposed direct form) with AXI4-Stream
// handshake on input and output, signed saturating cast on the output.
//
// Algorithm:
//
//   y[n] = sum_{k=0..N-1} h[k] * x[n-k]
//
// In the transposed structure the registers sit on the accumulator
// chain rather than on the data delay line:
//
//          x[n]
//           |
//      .----+----.----.----.----.        .----.
//      |       |   |   |   |             |
//      v       v   v   v   v             v
//    *h0     *h1 *h2 *h3 *h4   ....   *h_{N-1}
//      \      /  \   /                    /
//       (+)<-+    (+)<-+    ...          /
//        |          |                   /
//      [reg]      [reg]              [reg]
//        |          |                  |
//        '------ -- + ---------- ... --'  -> y[n] (saturated)
//
// Properties:
//   * One (data * coeff) multiplier per tap, all running in parallel.
//   * The longest combinational path is one multiplier + one adder,
//     regardless of N_TAPS. f_max stays high as taps grow.
//   * Latency from a sample being accepted (TVALID & TREADY both high)
//     to the corresponding result being valid on the output is exactly
//     2 cycles.
//
// AXI4-Stream:
//   * `s_axis_tvalid_i / s_axis_tready_o / s_axis_tdata_i` is the input.
//   * `m_axis_tvalid_o / m_axis_tready_i / m_axis_tdata_o` is the output.
//   * One input sample produces exactly one output sample. Backpressure
//     on the output stalls the input.
//
// Coefficients:
//   * Passed as an unpacked array `coeff_i[N_TAPS]` of signed
//     COEFF_WIDTH-bit values. Sampled combinationally on every accepted
//     input; runtime reconfiguration takes effect on the next accepted
//     sample.
//
// Saturation:
//   * The accumulator is `ACC_W` bits wide (DATA_WIDTH + COEFF_WIDTH +
//     ceil(log2(N_TAPS)) + 1, computed below).
//   * The output is the accumulator cast to DATA_WIDTH with signed
//     saturation. The `m_axis_tuser_o` bit indicates saturation on the
//     corresponding output sample (one bit per beat).

module fir_core #(
  parameter int N_TAPS      = 16,
  parameter int DATA_WIDTH  = 16,
  parameter int COEFF_WIDTH = 16,
  // Coefficient fractional bits. The accumulator is arithmetic-right-
  // shifted by COEFF_FRAC before the output cast, so that coefficients
  // expressed as Q1.(COEFF_FRAC) signed fixed-point with unity DC gain
  // (sum of all taps == 2^COEFF_FRAC) produce an output sample at the
  // same scale as the input. Default COEFF_WIDTH-1 implements the
  // textbook "Q1.15" convention for signed 16-bit coefficients.
  parameter int COEFF_FRAC  = COEFF_WIDTH - 1,
  // Derived (do not override):
  parameter int ACC_W       = DATA_WIDTH + COEFF_WIDTH +
                              ((N_TAPS <=  2) ? 1 :
                               (N_TAPS <=  4) ? 2 :
                               (N_TAPS <=  8) ? 3 :
                               (N_TAPS <= 16) ? 4 :
                               (N_TAPS <= 32) ? 5 :
                               (N_TAPS <= 64) ? 6 : 7) + 1
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,

  // Coefficient bank, packed flat bus: tap k occupies bits
  // [k*COEFF_WIDTH +: COEFF_WIDTH]. Flat packing keeps this port
  // portable across Verilog-2005 / Yosys frontends that do not yet
  // accept unpacked-array module ports.
  input  logic [N_TAPS*COEFF_WIDTH-1:0]       coeff_i,

  // AXI4-Stream input
  input  logic signed [DATA_WIDTH-1:0]        s_axis_tdata_i,
  input  logic                                s_axis_tvalid_i,
  output logic                                s_axis_tready_o,

  // AXI4-Stream output
  output logic signed [DATA_WIDTH-1:0]        m_axis_tdata_o,
  output logic                                m_axis_tvalid_o,
  input  logic                                m_axis_tready_i,
  output logic                                m_axis_tuser_o   // saturation flag
);

  // -------------------------------------------------------------------
  // Backpressure. The output side has two "slots": the in-flight sample
  // (a beat that was accepted last cycle and is being computed through
  // the saturation path right now) and the visible output register. A
  // new input is accepted only when both slots have room next cycle:
  //
  //   * output register slot empty next cycle (currently empty, or
  //     being drained this cycle), AND
  //   * the in-flight slot will be empty next cycle (i.e. no sample is
  //     currently in flight that has not yet been latched).
  //
  // This avoids ever overwriting a held output beat.
  // -------------------------------------------------------------------
  logic out_full_q;
  logic accept_q1;          // sample accepted last cycle, latch this cycle
  logic accept_in;
  logic drain_out;
  logic out_slot_open_next;

  assign drain_out          = out_full_q && m_axis_tready_i;
  // Output slot is open next cycle if: (a) currently empty AND no
  // sample is about to land in it from accept_q1, OR (b) it was full
  // but is being drained this cycle. Since accept_q1 fills the slot on
  // the next clock edge and `drain_out` empties it, the predicate is:
  assign out_slot_open_next = (!out_full_q && !accept_q1) || drain_out;
  assign s_axis_tready_o    = out_slot_open_next;
  assign accept_in          = s_axis_tvalid_i && s_axis_tready_o;

  // -------------------------------------------------------------------
  // Combinational products. Transposed structure broadcasts the current
  // sample to all multipliers; the chain registers produce the delays.
  // -------------------------------------------------------------------
  localparam int MUL_W = DATA_WIDTH + COEFF_WIDTH;

  logic signed [ACC_W-1:0] prod [N_TAPS];

  always_comb begin
    logic signed [MUL_W-1:0]      mul_tmp;
    logic signed [COEFF_WIDTH-1:0] coeff_k;
    for (int k = 0; k < N_TAPS; k++) begin
      coeff_k = $signed(coeff_i[k*COEFF_WIDTH +: COEFF_WIDTH]);
      mul_tmp = $signed(s_axis_tdata_i) * coeff_k;
      // Sign-extend to ACC_W.
      prod[k] = ACC_W'(mul_tmp);
    end
  end

  // -------------------------------------------------------------------
  // Transposed partial-sum chain. On every accepted input sample, each
  // tap_q[k] is updated to (prod[k] + tap_q[k+1]). The last tap absorbs
  // only the product (no successor).
  // -------------------------------------------------------------------
  logic signed [ACC_W-1:0] tap_q [N_TAPS];

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int i = 0; i < N_TAPS; i++) tap_q[i] <= '0;
    end else if (accept_in) begin
      for (int i = 0; i < N_TAPS - 1; i++)
        tap_q[i] <= prod[i] + tap_q[i+1];
      tap_q[N_TAPS-1] <= prod[N_TAPS-1];
    end
  end

  // -------------------------------------------------------------------
  // Output: arithmetic shift of tap_q[0] back to integer-sample scale,
  // then saturating cast to DATA_WIDTH, registered for a deterministic
  // 2-cycle latency from accept to TVALID.
  // -------------------------------------------------------------------
  logic signed [ACC_W-1:0]      acc_shifted_w;
  logic signed [DATA_WIDTH-1:0] sat_data_w;
  logic                         sat_flag_w;

  // Q1.COEFF_FRAC scaling: divide accumulator by 2^COEFF_FRAC.
  assign acc_shifted_w = tap_q[0] >>> COEFF_FRAC;

  fir_saturate #(
    .IN_W  (ACC_W),
    .OUT_W (DATA_WIDTH)
  ) u_sat (
    .in_i        (acc_shifted_w),
    .out_o       (sat_data_w),
    .saturated_o (sat_flag_w)
  );

  logic signed [DATA_WIDTH-1:0] out_data_q;
  logic                         out_sat_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      accept_q1   <= 1'b0;
      out_full_q  <= 1'b0;
      out_data_q  <= '0;
      out_sat_q   <= 1'b0;
    end else begin
      accept_q1 <= accept_in;
      // Drain first; same-cycle latch may set it back to 1.
      if (drain_out)
        out_full_q <= 1'b0;
      if (accept_q1) begin
        out_data_q <= sat_data_w;
        out_sat_q  <= sat_flag_w;
        out_full_q <= 1'b1;
      end
    end
  end

  assign m_axis_tdata_o  = out_data_q;
  assign m_axis_tvalid_o = out_full_q;
  assign m_axis_tuser_o  = out_sat_q;

endmodule
