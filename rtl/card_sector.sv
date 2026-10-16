// SS1 Memory Card Tool
// Copyright (C) 2026 f3bandit
//
// This program is free software: you can redistribute it and/or modify it under the terms of
// the GNU General Public License as published by the Free Software Foundation, either version 3
// of the License, or (at your option) any later version.
//
// card_sector: reads one 128-byte sector from a PS1 memory card.
//
// Read command, one byte each way per step (the card's reply to step n comes back during n):
//   send 81 52 00 00 MSB LSB 00 00 00 00 [00 x128] 00 00
//   get  -- FL 5A 5D 00  MSB 5C 5D MSB LSB [data x128] CHK 47
// CHK = MSB ^ LSB ^ every data byte. 47 ('G') means good. A card that doesn't exist answers
// nothing (no ACK on the first byte); a sector number past the end comes back as FF FF.
//
// The data goes to the card buffer as it arrives (MODE_STORE), is compared with what is there
// already (MODE_COMPARE), or is only looked at (MODE_PROBE: the first two bytes are kept so the
// caller can see the "MC" header of sector 0).
//
// Controllers (pad = 1), how many bytes follows from the ID the controller sends back:
//   0 read          01 42 00 00 00 ...            -- ID 5A buttons(lo, hi) [RX RY LX LY]
//   1 enter config  01 43 00 01 00 [00 00 00 00]
//   2 analog on     01 44 00 01 02 00 00 00 00    (02: the ANALOG button still works)
//   3 leave config  01 43 00 00 5A 5A 5A 5A 5A
// A DualShock (or a receiver acting as one) starts in digital mode, where the left stick works
// as the D-pad and the sticks aren't sent; 1-2-3 switches it to analog.

module card_sector
(
	input             clk,
	input             reset,

	input      [15:0] half_period,
	input      [15:0] ack_timeout,
	input      [15:0] sel_delay,    // clk cycles between select and the first bit

	input             start,
	input             pad,          // with start: talk to the controller instead (sector/mode unused)
	input       [1:0] pcmd,         // controller: 0 read it, 1 enter config, 2 analog mode on, 3 leave config
	input       [9:0] sector,
	input       [1:0] mode,
	output reg        busy,
	output reg        done,         // pulse
	output reg  [1:0] result,       // valid with done
	output reg        mismatch,     // MODE_COMPARE: at least one byte differs (valid with done, result OK)
	output reg  [7:0] hdr0,         // first two data bytes
	output reg  [7:0] hdr1,
	output reg  [7:0] pad_id,       // controller: ID (41 digital, 73 DualShock analog...), 5A..
	output reg [15:0] pad_btn,      // its buttons as sent (active low)
	output reg [31:0] pad_ana,      // RX RY LX LY (analog controllers)

	// card buffer (128 KB), registered read
	output reg [16:0] mem_addr,
	output reg  [7:0] mem_wdata,
	output reg        mem_we,
	input       [7:0] mem_rdata,

	output reg        sio_sel_n,
	output            sio_clk,
	output            sio_cmd,
	input             sio_dat,
	input             sio_ack
);

localparam MODE_STORE = 0, MODE_COMPARE = 1, MODE_PROBE = 2, MODE_WRITE = 3;
localparam R_OK = 0, R_NOCARD = 1, R_BAD = 2, R_RANGE = 3;

reg        b_start, b_last;
reg  [7:0] b_tx;
wire [7:0] b_rx;
wire       b_done, b_ack;

sio_byte sio_byte
(
	.clk(clk), .reset(reset),
	.half_period(half_period), .ack_timeout(ack_timeout),
	.start(b_start), .last(b_last), .tx(b_tx), .rx(b_rx), .done(b_done), .ack_seen(b_ack),
	.sio_clk(sio_clk), .sio_cmd(sio_cmd), .sio_dat(sio_dat), .sio_ack(sio_ack)
);

localparam S_IDLE = 0, S_SEL = 1, S_BYTE = 2, S_WAIT = 3, S_END = 4, S_PRE = 5, S_PRE2 = 6, S_SEND = 7;

reg  [2:0] state;  // 8 states
reg  [7:0] idx;      // byte of the command, 0..139
reg [15:0] cnt;
reg  [7:0] chk;
reg  [1:0] res;
reg  [1:0] md;
reg  [9:0] sec;

wire [7:0] msb = {6'd0, sec[9:8]};
wire [7:0] lsb = sec[7:0];
wire [7:0] didx = idx - 8'd10;   // read: data comes back during bytes 10..137
wire [7:0] widx = idx - 8'd6;    // write: data goes out in bytes 6..133
wire       wr   = (md == MODE_WRITE);
reg        pd;       // talking to a controller
reg  [1:0] pc;       // which command
reg  [7:0] pad_last; // its last byte: 2 + 2 x the halfwords its ID announces
wire [7:0] last_idx = pd ? pad_last : wr ? 8'd137 : 8'd139;
wire [3:0] pad_n = (b_rx[3:0] == 0) ? 4'd1 : b_rx[3:0];
wire [7:0] pidx  = idx - 8'd3;

always @(posedge clk) begin
	b_start <= 0;
	mem_we  <= 0;
	done    <= 0;

	if (reset) begin
		state     <= S_IDLE;
		busy      <= 0;
		sio_sel_n <= 1;
	end
	else case (state)
		S_IDLE: if (start) begin
			busy      <= 1;
			sec       <= sector;
			md        <= mode;
			pd        <= pad;
			pc        <= pad ? pcmd : 2'd0;
			pad_last  <= 8'd255;
			sio_sel_n <= 0;
			cnt       <= sel_delay;
			idx       <= 0;
			chk       <= 0;
			res       <= R_OK;
			mismatch  <= 0;
			state     <= S_SEL;
		end

		S_SEL: if (cnt) cnt <= cnt - 1'd1; else state <= S_BYTE;

		// the card buffer is read a couple of clocks ahead of the byte that needs it
		S_BYTE: begin
			mem_addr <= wr ? {sec, widx[6:0]} : {sec, didx[6:0]};
			state    <= S_PRE;
		end
		S_PRE:  state <= S_PRE2;
		S_PRE2: state <= S_SEND;

		S_SEND: begin
			if (pd) begin
				case (idx)
					0:       b_tx <= 8'h01;
					1:       b_tx <= (pc == 0) ? 8'h42 : (pc == 2) ? 8'h44 : 8'h43;
					2:       b_tx <= 8'h00;
					3:       b_tx <= (pc == 1 || pc == 2) ? 8'h01 : 8'h00;
					4:       b_tx <= (pc == 2) ? 8'h02 : (pc == 3) ? 8'h5A : 8'h00;
					default: b_tx <= (pc == 3) ? 8'h5A : 8'h00;
				endcase
			end
			else if (wr) begin
				// write: 81 57 00 00 MSB LSB [data x128] CHK 00 00 00
				//  reply -- FL 5A 5D 00  MSB  ...          ... 5C 5D 47
				case (idx)
					0:   b_tx <= 8'h81;
					1:   b_tx <= 8'h57;   // 'W'
					4:   b_tx <= msb;
					5:   b_tx <= lsb;
					134: b_tx <= chk;
					default: b_tx <= (idx >= 6 && idx < 134) ? mem_rdata : 8'h00;
				endcase
				if (idx == 4 || idx == 5 || (idx >= 6 && idx < 134)) chk <= chk ^ ((idx == 4) ? msb : (idx == 5) ? lsb : mem_rdata);
			end
			else case (idx)
				0:       b_tx <= 8'h81;
				1:       b_tx <= 8'h52;   // 'R'
				4:       b_tx <= msb;
				5:       b_tx <= lsb;
				default: b_tx <= 8'h00;
			endcase
			b_last  <= (idx == last_idx);
			b_start <= 1;
			state   <= S_WAIT;
		end

		S_WAIT: if (b_done) begin
			// check the reply
			if (pd) begin
				case (idx)
					0: if (!b_ack) res <= R_NOCARD;   // no controller
					1: begin pad_id <= b_rx; pad_last <= 8'd2 + {pad_n, 1'b0}; if (b_rx == 8'hFF) res <= R_BAD; end
					2: if (b_rx != 8'h5A) res <= R_BAD;
					3: if (pc == 0) pad_btn[7:0]  <= b_rx;
					4: if (pc == 0) pad_btn[15:8] <= b_rx;
					default: if (pc == 0 && pidx < 6) pad_ana[(pidx - 8'd2) * 8 +: 8] <= b_rx;
				endcase
			end
			else if (wr) case (idx)
				0:   if (!b_ack) res <= R_NOCARD;
				2:   if (b_rx != 8'h5A) res <= R_BAD;
				3:   if (b_rx != 8'h5D) res <= R_BAD;
				135: if (b_rx != 8'h5C) res <= R_BAD;
				136: if (b_rx != 8'h5D) res <= R_BAD;
				137: if (b_rx != 8'h47) res <= (b_rx == 8'hFF) ? R_RANGE : R_BAD;   // 4E: checksum refused
				default: ;
			endcase
			else case (idx)
				0:   if (!b_ack) res <= R_NOCARD;
				2:   if (b_rx != 8'h5A) res <= R_BAD;
				3:   if (b_rx != 8'h5D) res <= R_BAD;
				6:   if (b_rx != 8'h5C) res <= R_BAD;
				7:   if (b_rx != 8'h5D) res <= R_BAD;
				8:   if (b_rx != msb) res <= (b_rx == 8'hFF) ? R_RANGE : R_BAD;
				9:   if (b_rx != lsb) res <= (b_rx == 8'hFF) ? R_RANGE : R_BAD;
				138: if (b_rx != chk) res <= R_BAD;
				139: if (b_rx != 8'h47) res <= R_BAD;
				default: ;
			endcase

			if (!wr && (idx == 8 || idx == 9)) chk <= chk ^ b_rx;
			if (!wr && idx >= 10 && idx < 138) begin
				chk <= chk ^ b_rx;
				if (idx == 10) hdr0 <= b_rx;
				if (idx == 11) hdr1 <= b_rx;
				if (md == MODE_STORE) begin
					mem_wdata <= b_rx;
					mem_we    <= 1;
				end
				if (md == MODE_COMPARE && mem_rdata != b_rx) mismatch <= 1;
			end

			// stop early on a missing ACK or a broken reply; the caller retries
			if (idx == last_idx || !b_ack) state <= S_END;
			else if ((idx == 2 && b_rx != 8'h5A) || (!wr && idx == 9 && b_rx == 8'hFF && res == R_RANGE)) state <= S_END;
			else begin
				idx   <= idx + 1'd1;
				state <= S_BYTE;
			end
			if (idx != last_idx && !b_ack && idx != 0) res <= R_BAD;
		end

		S_END: begin
			sio_sel_n <= 1;
			busy      <= 0;
			done      <= 1;
			result    <= res;
			state     <= S_IDLE;
		end
	endcase
end

endmodule
