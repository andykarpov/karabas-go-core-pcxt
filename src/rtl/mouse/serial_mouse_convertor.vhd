-------------------------------------------------------------------------------
-- USB HID mouse to serial MS mouse transformer
-------------------------------------------------------------------------------

library IEEE; 
use IEEE.std_logic_1164.all; 
use ieee.numeric_std.all;

entity serial_mouse_convertor is
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
	 MOUSE_TX : out std_logic := '1';
	 MOUSE_RTS : in std_logic
	 
	);
end serial_mouse_convertor;

architecture rtl of serial_mouse_convertor is

	type qmachine IS(idle, rts_m, send_m, send_byte1, send_byte2, send_byte3);
	signal qstate : qmachine := idle;
	
	type smachine IS(serial_idle, send_byte, serial_tx, serial_end);
	signal sstate : smachine := serial_idle;
	
	signal acc_x : std_logic_vector(7 downto 0) := x"00";
	signal acc_y : std_logic_vector(7 downto 0) := x"00";
	signal acc_b : std_logic_vector(2 downto 0) := "000";
	signal prev_ms_upd : std_logic := '0';
	signal prev_b : std_logic_vector(2 downto 0);

	signal rts_prev : std_logic := '0';
    signal rts_req : std_logic := '0';
	signal mousebuf_x : std_logic_vector(7 downto 0) := "00000000";
	signal mousebuf_y : std_logic_vector(7 downto 0) := "00000000";
	signal mousebuf_b : std_logic_vector(2 downto 0) := "000";
	signal serialbuf : std_logic_vector(8 downto 0) := (others => '1'); -- stop bit , 7 bit data, start bit

	signal cnt : std_logic_vector(15 downto 0) := (others => '0'); -- serial prescaler counter
	signal prescaler: std_logic_vector(15 downto 0) := "1010001011000010"; -- serial prescaler = 50000000 / 1200
	signal bitcnt : std_logic_vector(3 downto 0) := (others => '0');
	
begin 

	process (CLK) 
	begin
		if rising_edge(CLK) then
			
			-- load rts buffer
			rts_prev <= MOUSE_RTS;
			
			-- prescaler counter
			if (cnt = prescaler) then 
				cnt <= (others => '0');
			else
				cnt <= std_logic_vector(unsigned(cnt) + 1);
			end if;
			
			-- accumulate usb hid data into acc_x, acc_y, acc_b
			if ms_upd /= prev_ms_upd then 
				acc_x <= std_logic_vector(signed(acc_x) + signed(ms_x));
				acc_y <= std_logic_vector(signed(acc_y) + signed(ms_y));
				acc_b <= ms_b;
				prev_ms_upd <= ms_upd;
			end if;

            -- rts request
            if rts_prev /= MOUSE_RTS and MOUSE_RTS = '1' then
                rts_req <= '1';
            end if;
			
			-- mouse fsm
			case qstate is 
			
                -- idle state: listen to events
				when idle => 
                    -- rts request => send M
					if rts_req = '1' then 
                  rts_req <= '0';
						qstate <= rts_m;
                    -- mouse data changed => send mouse data
					elsif (acc_x /= x"00" or acc_y /= x"00" or acc_b /= prev_b) and sstate = serial_idle and MOUSE_RTS = '1' then 
                        mousebuf_x <= acc_x;
                        mousebuf_y <= acc_y;
						mousebuf_b <= acc_b;
						acc_x <= x"00";
						acc_y <= x"00";
						prev_b <= acc_b;
						qstate <= send_byte1;
					end if;

				-- rts request => clear buffer, abort tx
				 when rts_m => 
					  serialbuf <= "111111111";
					  sstate <= serial_idle;
					  qstate <= send_m;			

				-- send M character (0x4D) as response to RTS request
				when send_m => 
                    if (sstate = serial_idle) then
						serialbuf <= '1' & "1001101" & '0';
						sstate <= send_byte;
					elsif (sstate = serial_end) then 
						qstate <= idle;
					end if;
					
				-- send mouse byte 1
				when send_byte1 => 
					if (sstate = serial_idle) then
						serialbuf <= '1' & "1" & mousebuf_b(0) & mousebuf_b(1) & mousebuf_y(7 downto 6) & mousebuf_x(7 downto 6) & '0';
						sstate <= send_byte;
					elsif (sstate = serial_end) then 
						qstate <= send_byte2;
					end if;
					
				-- send mouse byte 2
				when send_byte2 => 
					if (sstate = serial_idle) then
						serialbuf <= '1' & "0" & mousebuf_x(5 downto 0) & '0';
						sstate <= send_byte;
					elsif (sstate = serial_end) then 
						qstate <= send_byte3;
					end if;

				-- send mouse byte 3
				when send_byte3 => 
					if (sstate = serial_idle) then
						serialbuf <= '1' & "0" & mousebuf_y(5 downto 0) & '0';
						sstate <= send_byte;
					elsif (sstate = serial_end) then 
						qstate <= idle;
					end if;					
			end case;
			
			-- uart tx fsm
			case sstate is

				when serial_idle => null;

				-- init bit counter
				when send_byte => 
                    cnt <= "0000000000000000";
					bitcnt <= "1000"; --8
					sstate <= serial_tx;				

				-- serial transfer
				when serial_tx => 
                    -- abort send if rts request
                    if rts_req = '1' then 
                        qstate <= idle;
                        sstate <= serial_idle;
                        serialbuf <= "111111111";
					elsif cnt = prescaler then
						bitcnt <= std_logic_vector(unsigned(bitcnt) - 1);
						serialbuf <= '1' & serialbuf(8 downto 1);
						if (bitcnt = "0000") then 
							sstate <= serial_end;
						end if;
					end if;
				
				-- end of serial transfer
				when serial_end => 
					sstate <= serial_idle;
					
			end case;
			
		end if;
	end process;

    mouse_tx <= serialbuf(0);

end rtl;
