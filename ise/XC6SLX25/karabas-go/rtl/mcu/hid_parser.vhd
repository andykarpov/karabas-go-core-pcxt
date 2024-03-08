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
	 PS2_DAT : out std_logic
	);
end hid_parser;

architecture rtl of hid_parser is

begin 

	U_ps2_convertor: entity work.usb_ps2_convertor
	port map(
		clk => CLK,
		kb_status => KB_STATUS,
		kb_dat0 => KB_DAT0,
		kb_dat1 => KB_DAT1,
		kb_dat2 => KB_DAT2,
		kb_dat3 => KB_DAT3,
		kb_dat4 => KB_DAT4,
		kb_dat5 => KB_DAT5,
		PS2data => PS2_DAT,
		PS2clock => PS2_CLK
	);

end rtl;