-------------------------------------------------------------------------------
-- MCU HID keyboard to ps/2 transformer
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.conv_integer;
use IEEE.numeric_std.all;
use IEEE.std_logic_unsigned.all;

entity hid_parser is
	port
	(
	 CLK			 : in std_logic;
	 RESET 		 : in std_logic;
	 
	 -- incoming usb hid report data
	 KB_STATUS : in std_logic_vector(7 downto 0);
	 KB_DAT0 : in std_logic_vector(7 downto 0);
	 KB_DAT1 : in std_logic_vector(7 downto 0);
	 KB_DAT2 : in std_logic_vector(7 downto 0);
	 KB_DAT3 : in std_logic_vector(7 downto 0);
	 KB_DAT4 : in std_logic_vector(7 downto 0);
	 KB_DAT5 : in std_logic_vector(7 downto 0);

	 -- ps/2
	 PS2_CLK : out std_logic;
	 PS2_DAT : out std_logic;
	 
	 -- incoming usb mouse events
	 MS_X    : in std_logic_vector(7 downto 0);
	 MS_Y    : in std_logic_vector(7 downto 0);
	 MS_B    : in std_logic_vector(2 downto 0);
	 MS_UPD  : in std_logic;
	 
	 -- serial mouse uart
	 MOUSE_TX : out std_logic;
	 MOUSE_RTS : in std_logic
	 
	);
end hid_parser;

architecture rtl of hid_parser is

    signal o_kb_status : std_logic_vector(7 downto 0);
    signal o_kb_dat0 : std_logic_vector(7 downto 0);
    signal o_kb_dat1 : std_logic_vector(7 downto 0);
    signal o_kb_dat2 : std_logic_vector(7 downto 0);
    signal o_kb_dat3 : std_logic_vector(7 downto 0);
    signal o_kb_dat4 : std_logic_vector(7 downto 0);
    signal o_kb_dat5 : std_logic_vector(7 downto 0);

begin 

    U_typematic: entity work.hid_typematic
    port map(
        CLK => CLK,
        RESET => RESET,
		KB_STATUS => KB_STATUS,
		KB_DAT0 => KB_DAT0,
		KB_DAT1 => KB_DAT1,
		KB_DAT2 => KB_DAT2,
		KB_DAT3 => KB_DAT3,
		KB_DAT4 => KB_DAT4,
		KB_DAT5 => KB_DAT5,

        O_KB_DAT0 => o_kb_dat0,
        O_KB_DAT1 => o_kb_dat1,
        O_KB_DAT2 => o_kb_dat2,
        O_KB_DAT3 => o_kb_dat3,
        O_KB_DAT4 => o_kb_dat4,
        O_KB_DAT5 => o_kb_dat5
    );

	U_ps2_convertor: entity work.usb_ps2_convertor
	port map(
		clk => CLK,
		kb_status => O_KB_STATUS,
		kb_dat0 => O_KB_DAT0,
		kb_dat1 => O_KB_DAT1,
		kb_dat2 => O_KB_DAT2,
		kb_dat3 => O_KB_DAT3,
		kb_dat4 => O_KB_DAT4,
		kb_dat5 => O_KB_DAT5,
		PS2data => PS2_DAT,
		PS2clock => PS2_CLK
	);
	
	U_serial_mouse: entity work.serial_mouse_convertor
	port map(
		clk => CLK,
		reset => RESET,		
		ms_x => MS_X,
		ms_y => MS_Y,
		ms_b => MS_B,
		ms_upd => MS_UPD,
		mouse_rts => MOUSE_RTS,
		mouse_tx => MOUSE_TX
	);

end rtl;
