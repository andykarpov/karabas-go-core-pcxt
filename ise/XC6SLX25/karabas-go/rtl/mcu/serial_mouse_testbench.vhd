library IEEE; 
use IEEE.std_logic_1164.all; 
use ieee.numeric_std.all;

entity serial_mouse_testbench is
end serial_mouse_testbench;

architecture behavior of serial_mouse_testbench is

    component serial_mouse_convertor is
        port (
            clk       : in std_logic;
            reset       : in std_logic;

            ms_x    : in std_logic_vector(7 downto 0);
            ms_y    : in std_logic_vector(7 downto 0);
            ms_b    : in std_logic_vector(2 downto 0);
            ms_upd  : in std_logic;

            mouse_tx     : out std_logic;
            mouse_rts    : in std_logic
        );
    end component;

    signal clk50  : std_logic := '0';
    signal reset : std_logic := '0';

    signal ms_x : std_logic_vector(7 downto 0) := "00000000";
    signal ms_y : std_logic_vector(7 downto 0) := "00000000";
    signal ms_b : std_logic_vector(2 downto 0) := "000";
    signal ms_upd : std_logic := '0';
    signal mouse_rts : std_logic := '0';
    signal mouse_tx : std_logic;

begin
    uut: serial_mouse_convertor 
    port map (
        clk => clk50,
        reset => reset,
        ms_x => ms_x,
        ms_y => ms_y,
        ms_b => ms_b,
        ms_upd => ms_upd,
        mouse_tx => mouse_tx,
        mouse_rts => mouse_rts
    );

    -- simulate clk 50 MHz
    clk50 <=  '1' after 10 ns when clk50 = '0' else
        '0' after 10 ns when clk50 = '1';

    -- simulate rts
    mouse_rts <= '1' after 200 ns;

    -- simulate mouse data
    ms_upd <= '0' after 300 ns, '1' after 20 ms, '0' after 60 ms;
    ms_x <= "11111111" after 300 ns, "00000001" after 20 ms, "00000000" after 60 ms;
    ms_y <= "11111111" after 300 ns, "00000001" after 20 ms, "00000000" after 60 ms;
    ms_b <= "000" after 15 ms, "011" after 60 ms;

end;
