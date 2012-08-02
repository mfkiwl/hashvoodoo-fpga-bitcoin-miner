`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// FPGA Miner Top, Ported from icarus source from ngzhang
// Paul Mumby 2012
//////////////////////////////////////////////////////////////////////////////////
module fpgaminer_top (
		osc_clk, 
		RxD, 
		TxD, 
		led, 
		dip, 
		reset_a, 
		reset_b, 
		reset_select
	);

	//Parameters:
	//================================================
	parameter OSC_CLOCK_RATE = 200000000;			//Input Clock From Controller (in Hz)
	parameter HASH_CLOCK_RATE = OSC_CLOCK_RATE;	//Hasher Clock Output from DCM (in Hz)
	parameter COMM_CLOCK_RATE = OSC_CLOCK_RATE;	//Communications Clock Output from DCM (in Hz)
	parameter UART_BAUD_RATE = 115200;				//Baud Rate to use for UART (BPS)
	parameter UART_SAMPLE_POINT = 8;					//Point in the oversampled wave to sample the bit state for the UART (6-12 should be valid)
	parameter CLOCK_FLASH_BITS = 24;					//Number of bits for divider of flasher. (24bit = approx 16M Divider)
	
	//IO Definitions:
	//================================================
   input osc_clk;			//Input Oscillator Clock From Controller
   input RxD;				//UART RX Pin (From Controller)
   output TxD;				//UART TX Pin  (To Controller)
   output [3:0] led;		//LED Array
	input [3:0]dip;		//DIP Switch Array
	input reset_a;			//Reset Signal A (position dependant) from Controller
	input reset_b;			//Reset Signal B (position dependant) from Controller
	input reset_select;	//Reset Selector (hard wired based on position)

	//Register/Wire Definitions:
	//================================================
	reg reset;								//Actual Reset Signal
	wire main_clk;							//Actually Used Clock Signals
	wire clock_flash;						//Flasher output (24bit divider of clock)
	wire nonce_start = dip[1];			//Nonce Range Start (msb of nonce range). TODO: Kill this
	wire miner_busy;						//Miner Busy Flag
   wire [32:0] slave_nonces;			//Nonce found by worker TODO: Rename/Cleanup (this is a holdover from the icarus pair code)
   wire new_nonces;						//Flag indicating new nonces found
   wire serial_send;						//Serial Send flag, Triggers UART to begin sending what's in it's buffer
   wire serial_busy;						//Serial Busy flag, Indicates the UART is currently working
   wire [31:0] golden_nonce;			//Overall Found Golden Nonce TODO: Cleanup along with previous holdovers from icarus code
   wire [255:0] midstate, data2;		//Mistate and Data2, the main payload for a new job.
	wire start_mining;					//Start Mining flag. This flag going high will trigger the worker to begin hashing on it's buffer
	wire got_ticket;						//Got Ticket flag indicates the local worker found a new nonce. TODO: Again, cleanup
	wire led_nonce_fade;					//This is the output from the fader, jumps to full power when nonce found and fades out
	reg new_ticket;						//Related to got_ticket TODO: Cleanup old icarus stuff
	reg [3:0]ticket_CS = 4'b0001;		//Again... Cleanup
	reg [3:0]ticket_NS;					//Again... Cleanup
	
	//Assignments:
	//================================================
	assign new_nonces = new_ticket;					//TODO: Cleanup
	assign led[0] = led_nonce_fade;					//LED0 (Green): New Nonce Beacon (fader)
	assign led[1] = (~TxD || ~RxD);					//LED1 (Red): UART Activity (blinks on either rx or tx)
   assign led[2] = clock_flash;						//LED2 (Blue): Clock Validator:
																//OFF: No valid clock seen at all
																//ON SOLID: Clock Signal is seen, but DCM has bad lock, or DCM output is bad
																//BLINKING: Clock signal is seen, and DCM is in good state. Output clocks are valid
 	assign led[3] = ~miner_busy;						//LED3 (Amber): Idle Indicator. Lights when miner has nothing to do.

	//Module Instantiation:
	//================================================
	
	//Clock Input BUFG
	BUFG clk_bufg (.I(osc_clk), .O(main_clk));
	
	//Hub core, this is a holdover from Icarus. This should be cleaned up and ported back to core logic, since miners are now "solo".
	//TODO: Cleanup old icarus stuff
   hub_core #(
			.SLAVES(1)
		) hc (
			.hash_clk(main_clk), 
			.new_nonces(new_nonces), 
			.golden_nonce(golden_nonce), 
			.serial_send(serial_send), 
			.serial_busy(serial_busy), 
			.slave_nonces(slave_nonces)
		);
	
	//New Serial Core. Handles all communications in and out to the host.
	serial_core #(
			.CLOCK(COMM_CLOCK_RATE),
			.BAUD(UART_BAUD_RATE),
			.SAMPLE_POINT(UART_SAMPLE_POINT)
		) SERIAL_COMM (
			.clk(main_clk),
			.rx(RxD),
			.tx(TxD),
			.rx_ready(start_mining),
			.tx_ready(serial_send),
			.midstate(midstate),
			.data2(data2),
			.word(golden_nonce),
			.tx_busy(serial_busy)
		);
		
	//Main Hashing Core, This does all the work
	sha256_top M (
			.clk(main_clk), 
			.rst(reset), 
			.midstate(midstate), 
			.data2(data2), 
			.golden_nonce(slave_nonces[31:0]), 
			.got_ticket(got_ticket), 
			.miner_busy(miner_busy), 
			.nonce_start(nonce_start), 
			.start_mining(start_mining)
		);
	
	//Flasher, this handles dividing down the comm clock by 24bits to blink the clock status LED
	flasher #(
			.BITS(CLOCK_FLASH_BITS)
		) CLK_FLASH (
			.clk(main_clk),
			.flash(clock_flash)
		);
	
	//PWM Fader core. This triggers on a new nonce found, flashes to full brightness, then fades out for nonce found LED.
	pwm_fade pf1 (
			.clk(main_clk), 
			.trigger(|new_nonces), 
			.drive(led_nonce_fade)
		);	
	
	//Toplevel Logic:
	//================================================

	//Reset handling code. Handles location specific reset signals
	always@ (reset_select or reset_a or reset_b)
		begin
			if(reset_select)
				reset <= reset_a;
			else
				reset <= reset_b;
		end

	//Clock Domain Buffering of ticket signal (I believe) TODO: Identify & Cleanup
	always@ (posedge main_clk)
		begin
			ticket_CS <= ticket_NS;
		end

	//Primary Ticket Logic TODO: Cleanup
	always@ (*)
		begin
			case(ticket_CS)
				4'b0001: if (got_ticket) ticket_NS = 4'b0010; else ticket_NS = ticket_CS;
				4'b0010: ticket_NS = 4'b0100;
				4'b0100: ticket_NS = 4'b1000;
				4'b1000: if (!got_ticket) ticket_NS = 4'b0001; else ticket_NS = ticket_CS;
				default: ticket_NS = 4'b0001;
			endcase
		end

	//Communications Clock Domain Ticket Processing code TODO: Cleanup
	always@ (posedge main_clk)
		begin
			new_ticket <= (ticket_CS == 4'b0100);
		end

endmodule

