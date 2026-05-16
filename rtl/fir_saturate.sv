// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Saturating signed cast: take a wide signed accumulator and clip it
// down to OUT_W bits, signaling saturation. Used by fir_core to bring
// the post-accumulation product back into the I/O sample width.

module fir_saturate #(
  parameter int IN_W  = 48,
  parameter int OUT_W = 16
) (
  input  logic signed [IN_W-1:0]  in_i,
  output logic signed [OUT_W-1:0] out_o,
  output logic                    saturated_o
);

  localparam logic signed [IN_W-1:0] MAX_POS =
      {{(IN_W-OUT_W+1){1'b0}}, {(OUT_W-1){1'b1}}};
  localparam logic signed [IN_W-1:0] MIN_NEG =
      {{(IN_W-OUT_W+1){1'b1}}, {(OUT_W-1){1'b0}}};

  always_comb begin
    if (in_i > MAX_POS) begin
      out_o       = {1'b0, {(OUT_W-1){1'b1}}};
      saturated_o = 1'b1;
    end else if (in_i < MIN_NEG) begin
      out_o       = {1'b1, {(OUT_W-1){1'b0}}};
      saturated_o = 1'b1;
    end else begin
      out_o       = in_i[OUT_W-1:0];
      saturated_o = 1'b0;
    end
  end

endmodule
