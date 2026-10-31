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
begin 
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
