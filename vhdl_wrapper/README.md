# VHDL wrapper

`fir_core_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `fir_core` module under a VHDL-friendly interface. Use
it from a VHDL design that does not want to touch SystemVerilog directly.

## Status

**Wrapper only.** The FIR datapath and saturating clamp live in
`rtl/*.sv` and are instantiated as a SystemVerilog black-box.
Mixed-language elaboration is supported by every commercial simulator
and synthesiser the core has been tested against.

A pure VHDL re-implementation of the datapath is on the roadmap
(Premium tier, scope: parity with `rtl/fir_core.sv` including the same
testbench checks). Until then, treat this directory as a binding layer,
not as a second implementation.

## Usage

### Vivado / Quartus / Diamond

Add both the SystemVerilog files and `fir_core_vhdl.vhd` to the same
project library (`work` is fine). The toolchain resolves the SV
component automatically:

```tcl
# Vivado
read_verilog -sv {rtl/fir_saturate.sv rtl/fir_core.sv}
read_vhdl -vhdl2008 vhdl_wrapper/fir_core_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/fir_saturate.sv rtl/fir_core.sv
vcom -2008 vhdl_wrapper/fir_core_vhdl.vhd
```

### GHDL + Verilator (open-source co-sim)

GHDL compiles the VHDL side, Verilator compiles the SV side, and the
two are linked through GHDL's VHPI bridge. The provided `make
vhdl-test` target wraps this; run it from the repository root:

```
make vhdl-test
```

The target is a no-op (with a notice) if `ghdl` is not on `$PATH`.

## Instantiation example

```vhdl
library ieee;
  use ieee.std_logic_1164.all;

entity my_design is end entity;
architecture rtl of my_design is
  constant N_TAPS : integer := 16;
  signal clk, rstn                            : std_logic;
  signal coeff                                : std_logic_vector(N_TAPS*16-1 downto 0);
  signal s_data, m_data                       : std_logic_vector(15 downto 0);
  signal s_valid, s_ready, m_valid, m_ready   : std_logic;
  signal m_user                               : std_logic;
begin
  u_fir : entity work.fir_core_vhdl
    generic map (
      N_TAPS      => N_TAPS,
      DATA_WIDTH  => 16,
      COEFF_WIDTH => 16
    )
    port map (
      clk_i           => clk,
      rst_ni          => rstn,
      coeff_i         => coeff,
      s_axis_tdata_i  => s_data,
      s_axis_tvalid_i => s_valid,
      s_axis_tready_o => s_ready,
      m_axis_tdata_o  => m_data,
      m_axis_tvalid_o => m_valid,
      m_axis_tready_i => m_ready,
      m_axis_tuser_o  => m_user
    );
end architecture;
```

## What this wrapper does NOT change

* Latency: identical to `fir_core.sv`. 2 cycles from input accept to
  output TVALID.
* Endianness: scalar fields. The coefficient bus uses the same
  bit-packing convention (tap k = bits k*COEFF_WIDTH +: COEFF_WIDTH).
* Reset polarity: still active-low synchronous (`rst_ni`).
* Q-format: the wrapper does not change the signed Q1.(COEFF_WIDTH-1)
  convention. The host writes coefficients as that fixed-point format.
