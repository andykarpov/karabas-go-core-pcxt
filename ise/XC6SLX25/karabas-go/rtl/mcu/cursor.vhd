-------------------------------------------------------------------------------
-- MCU HID mouse / absolute cursor transformer
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.conv_integer;
use IEEE.numeric_std.all;
use IEEE.std_logic_unsigned.all;

entity cursor is
	port
	(
	 CLK			 : in std_logic;
	 RESET 		 : in std_logic;
	 
	 MS_X :    in std_logic_vector(7 downto 0);
	 MS_Y :    in std_logic_vector(7 downto 0);
	 MS_Z :    in std_logic_vector(3 downto 0);
	 MS_B :    in std_logic_vector(2 downto 0);
	 MS_UPD  : in std_logic := '0';

	 OUT_READ : in std_logic;
	 OUT_X : out std_logic_vector(7 downto 0);
	 OUT_Y : out std_logic_vector(7 downto 0);
	 OUT_Z : out std_logic_vector(3 downto 0);
	 OUT_B : out std_logic_vector(2 downto 0)
	);
end cursor;

architecture rtl of cursor is

	 -- mouse
	 signal cursorX 			: signed(7 downto 0) := X"00";
	 signal cursorY 			: signed(7 downto 0) := X"00";
    signal cursorZ         : signed(3 downto 0) := X"0";

	 signal deltaX				: signed(7 downto 0);
	 signal deltaY				: signed(7 downto 0);
	 signal deltaZ				: signed(3 downto 0);

	 signal trigger 			: std_logic := '0';
	 signal ms_flag 			: std_logic := '0';

begin 

	process (CLK) 
	begin
			if (rising_edge(CLK)) then
				trigger <= '0';
				-- update mouse only on ms flag changed
				if (ms_flag /= MS_UPD) then 
					deltaX <= signed(MS_X);
					deltaY <= -signed(MS_Y);
					deltaZ <= signed(MS_Z);
					ms_flag <= MS_UPD;
					trigger <= '1';
				end if;
			end if;
	end process;

	process (CLK)
	begin
		if rising_edge (CLK) then
			
			if OUT_READ = '1' then 
				cursorX <= to_signed(0, cursorX'length);
				cursorY <= to_signed(0, cursorY'length);
				cursorZ <= to_signed(0, cursorZ'length);
			end if;
			
			if trigger = '1' then
				cursorX <= cursorX + deltaX;
				cursorY <= cursorY + deltaY;
				cursorZ <= cursorZ + deltaZ;
			end if;
		end if;
	end process;
	
	OUT_X <= std_logic_vector(cursorX);
	OUT_Y <= std_logic_vector(cursorY);
	OUT_Z	<= std_logic_vector(cursorZ);
	OUT_B <= MS_B;

end rtl;
