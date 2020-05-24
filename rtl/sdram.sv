//
// sdram.v
//
// sdram controller implementation for the MiST board
// https://github.com/mist-devel/mist-board
// 
// Copyright (c) 2013 Till Harbaum <till@harbaum.org> 
// Copyright (c) 2019 Gyorgy Szombathelyi
//
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram (

	// interface to the MT48LC16M16 chip
	inout  reg [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // two byte masks
	output reg        SDRAM_DQMH, // two byte masks
	output reg [1:0]  SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output            SDRAM_nWE,  // write enable
	output            SDRAM_nRAS, // row address select
	output            SDRAM_nCAS, // columns address select
	output            SDRAM_CKE,
	output            SDRAM_CLK, 
	
	// cpu/chipset interface
	input             init_n,     // init signal after FPGA config to initialize RAM
	input             clk,        // sdram clock
	input             clkref,        // sdram clock

	input             port1_req,
	output reg        port1_ack,
	input             port1_we,
	input      [23:1] port1_a,
	input       [1:0] port1_ds,
	input      [15:0] port1_d,
	output reg [15:0] port1_q,

	input      [23:1] cpu1_addr,
	output reg [15:0] cpu1_q,
	input      [23:1] cpu2_addr,
	output reg [15:0] cpu2_q,
	input      [23:1] cpu3_addr,
	output reg [15:0] cpu3_q,

	input             port2_req,
	output reg        port2_ack,
	input             port2_we,
	input      [23:1] port2_a,
	input       [1:0] port2_ds,
	input      [15:0] port2_d,
	output reg [31:0] port2_q,
	
   input      [19:2] chr1_addr,
   output reg [31:0] chr1_q,
   input      [19:2] chr2_addr,
   output reg [31:0] chr2_q,
	input      [19:2] sp_addr,
	output reg [31:0] sp_q
);

assign SDRAM_CKE = 1;
assign SDRAM_nCS = 0;
assign { SDRAM_DQMH, SDRAM_DQML } = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd2;   // tRCD=20ns -> 2 cycles@<100MHz
localparam BURST_LENGTH   = 3'b001; // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

// 64ms/8192 rows = 7.8us -> 842 cycles@108MHz
localparam RFRSH_CYCLES = 10'd842;

// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

/*
 SDRAM state machine for 2 bank interleaved access
 1 word burst, CL2
cmd issued  registered
 0 RAS0     
 1          ras0, data1 returned
 2 CAS0     data1 returned
 3 RAS1     cas0
 4          ras1
 5 CAS1     data0 returned
 6          cas1, data0 returned (discarded)
 
*/

localparam STATE_FIRST     = 3'd0;   // first state in cycle
localparam STATE_RAS0      = 3'd0;
localparam STATE_RAS1      = 3'd3;   // Second ACTIVE command after RAS0 + tRRD (15ns)
localparam STATE_CAS0      = STATE_RAS0 + RASCAS_DELAY; // CAS phase - 2
localparam STATE_CAS1      = STATE_RAS1 + RASCAS_DELAY; // CAS phase - 5
localparam STATE_READ1     = 3'd2;
localparam STATE_READ1b    = 3'd3;
localparam STATE_READ0     = 3'd6;
localparam STATE_LAST      = 3'd6;

reg [2:0] t;
always @(posedge clk) begin
	reg clkref_d;
	clkref_d <= clkref;
	if ((~clkref_d && clkref && t == 4'd2) || (t != 4'd2)) t <= t + 1'd1;

//	t <= t + 1'd1;
	if (t == STATE_LAST) t <= STATE_FIRST;
end

// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// wait 1ms (32 8Mhz cycles) after FPGA config is done before going
// into normal operation. Initialize the ram in the last 16 reset cycles (cycles 15-0)
reg [4:0]  reset;
reg        init = 1'b1;
always @(posedge clk, negedge init_n) begin
	if(!init_n) begin
		reset <= 5'h1f;
		init <= 1'b1;
	end else begin
		if((t == STATE_LAST) && (reset != 0)) reset <= reset - 5'd1;
		init <= !(reset == 0);
	end
end

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

reg [2:0]  sd_cmd;   // current command sent to sd ram
reg [15:0] sd_din;
// drive control signals according to current command
assign SDRAM_nRAS = sd_cmd[2];
assign SDRAM_nCAS = sd_cmd[1];
assign SDRAM_nWE  = sd_cmd[0];

reg [24:1] addr_latch[3];
reg [24:1] addr_latch_next[2];
reg [23:1] addr_last[4];
reg [19:2] addr_last2[4];
reg [15:0] din_latch[2];
reg  [1:0] oe_latch;
reg  [1:0] we_latch;
reg  [1:0] ds[2];

reg        port1_state;
reg        port2_state;

localparam PORT_NONE  = 3'd0;
localparam PORT_CPU1  = 3'd1;
localparam PORT_CPU2  = 3'd2;
localparam PORT_CPU3  = 3'd3;
localparam PORT_SP    = 3'd1;
localparam PORT_CHR1  = 3'd2;
localparam PORT_CHR2  = 3'd3;
localparam PORT_REQ   = 3'd4;

reg  [2:0] next_port[2];
reg  [2:0] port[2];

reg        refresh;
reg [10:0] refresh_cnt;
reg        need_refresh;

// PORT1: bank 0,1
always @(*) begin
	if (refresh) begin
		next_port[0] = PORT_NONE;
		addr_latch_next[0] = addr_latch[0];
	end else if (port1_req ^ port1_state) begin
		next_port[0] = PORT_REQ;
		addr_latch_next[0] = port1_a;
	end else if (cpu1_addr != addr_last[PORT_CPU1]) begin
		next_port[0] = PORT_CPU1;
		addr_latch_next[0] = cpu1_addr;
	end else if (cpu2_addr != addr_last[PORT_CPU2]) begin
		next_port[0] = PORT_CPU2;
		addr_latch_next[0] = cpu2_addr;
	end else if (cpu3_addr != addr_last[PORT_CPU3]) begin
		next_port[0] = PORT_CPU3;
		addr_latch_next[0] = cpu3_addr;
	end else begin
		next_port[0] = PORT_NONE;
		addr_latch_next[0] = addr_latch[0];
	end
end

// PORT1: bank 2,3
always @(*) begin
	if (port2_req ^ port2_state) begin
		next_port[1] = PORT_REQ;
		addr_latch_next[1] = port2_a;
	end else if (sp_addr != addr_last2[PORT_SP]) begin
		next_port[1] = PORT_SP;
		addr_latch_next[1] = { sp_addr, 1'b0 };
	end else if (chr1_addr != addr_last2[PORT_CHR1]) begin
		next_port[1] = PORT_CHR1;
		addr_latch_next[1] = { chr1_addr, 1'b0 };
	end else if (chr2_addr != addr_last2[PORT_CHR2]) begin
		next_port[1] = PORT_CHR2;
		addr_latch_next[1] = { chr2_addr, 1'b0 };
	end else begin
		next_port[1] = PORT_NONE;
		addr_latch_next[1] = addr_latch[1];
	end
end

always @(posedge clk) begin

	// permanently latch ram data to reduce delays
	sd_din <= SDRAM_DQ;
	SDRAM_DQ <= 16'bZ;
	sd_cmd <= CMD_NOP;  // default: idle
	if(~&refresh_cnt) refresh_cnt <= refresh_cnt + 1'd1;
	need_refresh <= (refresh_cnt >= RFRSH_CYCLES);

	if(init) begin
		// initialization takes place at the end of the reset phase
		if(t == STATE_FIRST) begin

			if(reset == 15) begin
				sd_cmd <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1'b1;      // precharge all banks
			end

			if(reset == 10 || reset == 8) begin
				sd_cmd <= CMD_AUTO_REFRESH;
			end

			if(reset == 2) begin
				sd_cmd <= CMD_LOAD_MODE;
				SDRAM_A <= MODE;
				SDRAM_BA <= 2'b00;
			end
		end
	end else begin
		// RAS phase
		// bank 0,1
		if(t == STATE_RAS0) begin
			addr_latch[0] <= addr_latch_next[0];
			port[0] <= next_port[0];
			{ oe_latch[0], we_latch[0] } <= 2'b00;

			if (next_port[0] != PORT_NONE) begin
				sd_cmd <= CMD_ACTIVE;
				SDRAM_A <= addr_latch_next[0][22:10];
				SDRAM_BA <= {1'b0, addr_latch_next[0][23]};
				addr_last[next_port[0]] <= addr_latch_next[0];
				if (next_port[0] == PORT_REQ) begin
					{ oe_latch[0], we_latch[0] } <= { ~port1_we, port1_we };
					ds[0] <= port1_ds;
					din_latch[0] <= port1_d;
					port1_state <= port1_req;
				end else begin
					{ oe_latch[0], we_latch[0] } <= 2'b10;
					ds[0] <= 2'b11;
				end
			end
		end

		// bank 2,3
		if(t == STATE_RAS1) begin
			refresh <= 1'b0;
			addr_latch[1] <= addr_latch_next[1];
			{ oe_latch[1], we_latch[1] } <= 2'b00;
			port[1] <= next_port[1];

			if (next_port[1] != PORT_NONE) begin
				sd_cmd <= CMD_ACTIVE;
				SDRAM_A <= addr_latch_next[1][22:10];
				SDRAM_BA <= {1'b1, addr_latch_next[1][23]};
				addr_last2[next_port[1]] <= addr_latch_next[1][23:2];
				if (next_port[1] == PORT_REQ) begin
					{ oe_latch[1], we_latch[1] } <= { ~port1_we, port1_we };
					ds[1] <= port2_ds;
					din_latch[1] <= port2_d;
					port2_state <= port2_req;
				end else begin
					{ oe_latch[1], we_latch[1] } <= 2'b10;
					ds[1] <= 2'b11;
				end
			end
			else if (need_refresh && !we_latch[0] && !oe_latch[0]) begin
				refresh <= 1'b1;
				refresh_cnt <= 0;
				sd_cmd <= CMD_AUTO_REFRESH;
			end
		end

		// CAS phase
		if(t == STATE_CAS0 && (we_latch[0] || oe_latch[0])) begin
			sd_cmd <= we_latch[0]?CMD_WRITE:CMD_READ;
			SDRAM_A <= { 4'b0010, addr_latch[0][9:1] };  // auto precharge
			SDRAM_BA <= {1'b0, addr_latch[0][23]};
			if (we_latch[0]) begin
				SDRAM_A[12:11] <= ~ds[0];
				SDRAM_DQ <= din_latch[0];
				port1_ack <= port1_req;
			end
		end

		if(t == STATE_CAS1 && (we_latch[1] || oe_latch[1])) begin
			sd_cmd <= we_latch[1]?CMD_WRITE:CMD_READ;
			SDRAM_A <= { 4'b0010, addr_latch[1][9:1] };  // auto precharge
			SDRAM_BA <= {1'b1, addr_latch[1][23]};
			if (we_latch[1]) begin
				SDRAM_A[12:11] <= ~ds[1];
				SDRAM_DQ <= din_latch[1];
				port2_ack <= port2_req;
			end
		end

		// Data returned
		if(t == STATE_READ0 && oe_latch[0]) begin
			case(port[0])
				PORT_REQ:  begin port1_q <= sd_din; port1_ack <= port1_req; end
				PORT_CPU1: begin cpu1_q  <= sd_din; end
				PORT_CPU2: begin cpu2_q  <= sd_din; end
				PORT_CPU3: begin cpu3_q  <= sd_din; end
				default: ;
			endcase;
		end

		if(t == STATE_READ1 && oe_latch[1]) begin
			case(port[1])
				PORT_REQ:	port2_q[15:0] <= sd_din;
				PORT_SP :    sp_q[15:0] <= sd_din;
				PORT_CHR1 :    chr1_q[15:0] <= sd_din;
				PORT_CHR2 :    chr2_q[15:0] <= sd_din;
				default: ;
			endcase;
		end

		if(t == STATE_READ1b && oe_latch[1]) begin
			case(port[1])
				PORT_REQ: begin port2_q[31:16] <= sd_din; port2_ack <= port2_req; end
				PORT_CHR1 : begin    chr1_q[31:16] <= sd_din; end
				PORT_CHR2 : begin    chr2_q[31:16] <= sd_din; end
				PORT_SP : begin    sp_q[31:16] <= sd_din; end
				default: ;
			endcase;
		end
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
