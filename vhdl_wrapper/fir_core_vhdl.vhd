-- SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog fir_core module.
--
-- This entity exposes the FIR core's port list in VHDL syntax. The
-- architecture instantiates the SystemVerilog module by component name;
-- mixed-language elaboration is supported natively by Vivado, Quartus,
-- ModelSim/Questa, and Aldec, and via the GHDL VHPI bridge for open
-- simulation.
--
-- Status: WRAPPER ONLY. The FIR datapath itself remains in SystemVerilog
-- (rtl/*.sv). A native VHDL port of the datapath is listed as future work.
--
-- I/O contract: identical to fir_core.sv (see PORT_DESCRIPTION.md).
--   * Single clock, active-low synchronous reset.
--   * AXI4-Stream input + output handshakes.
--   * Flat packed coefficient bus: tap k = bits k*COEFF_WIDTH +: COEFF_WIDTH.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity fir_core_vhdl is
  generic (
    N_TAPS      : integer := 16;
    DATA_WIDTH  : integer := 16;
    COEFF_WIDTH : integer := 16
  );
  port (
    clk_i           : in  std_logic;
    rst_ni          : in  std_logic;

    coeff_i         : in  std_logic_vector(N_TAPS*COEFF_WIDTH-1 downto 0);

    s_axis_tdata_i  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    s_axis_tvalid_i : in  std_logic;
    s_axis_tready_o : out std_logic;

    m_axis_tdata_o  : out std_logic_vector(DATA_WIDTH-1 downto 0);
    m_axis_tvalid_o : out std_logic;
    m_axis_tready_i : in  std_logic;
    m_axis_tuser_o  : out std_logic
  );
end entity fir_core_vhdl;

architecture rtl of fir_core_vhdl is

  component fir_core
    generic (
      N_TAPS      : integer := 16;
      DATA_WIDTH  : integer := 16;
      COEFF_WIDTH : integer := 16;
      COEFF_FRAC  : integer := 15;
      ACC_W       : integer := 37
    );
    port (
      clk_i           : in  std_logic;
      rst_ni          : in  std_logic;
      coeff_i         : in  std_logic_vector(N_TAPS*COEFF_WIDTH-1 downto 0);
      s_axis_tdata_i  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
      s_axis_tvalid_i : in  std_logic;
      s_axis_tready_o : out std_logic;
      m_axis_tdata_o  : out std_logic_vector(DATA_WIDTH-1 downto 0);
      m_axis_tvalid_o : out std_logic;
      m_axis_tready_i : in  std_logic;
      m_axis_tuser_o  : out std_logic
    );
  end component;

begin

  u_fir : fir_core
    generic map (
      N_TAPS      => N_TAPS,
      DATA_WIDTH  => DATA_WIDTH,
      COEFF_WIDTH => COEFF_WIDTH
    )
    port map (
      clk_i           => clk_i,
      rst_ni          => rst_ni,
      coeff_i         => coeff_i,
      s_axis_tdata_i  => s_axis_tdata_i,
      s_axis_tvalid_i => s_axis_tvalid_i,
      s_axis_tready_o => s_axis_tready_o,
      m_axis_tdata_o  => m_axis_tdata_o,
      m_axis_tvalid_o => m_axis_tvalid_o,
      m_axis_tready_i => m_axis_tready_i,
      m_axis_tuser_o  => m_axis_tuser_o
    );

end architecture rtl;
