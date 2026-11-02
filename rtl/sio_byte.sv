// SS1 Memory Card Tool
// Copyright (C) 2026 f3bandit
//
// This program is free software: you can redistribute it and/or modify it under the terms of
// the GNU General Public License as published by the Free Software Foundation, either version 3
// of the License, or (at your option) any later version.
//
// sio_byte: sends and receives one byte on the PlayStation controller/memory card bus.
//
// The bus is the PS1's synchronous serial link: the console drives CLK and CMD and the card
// answers on DAT, least significant bit first. CLK idles high; CMD changes while CLK is low and
// both sides sample on the rising edge. After every byte except the last one of a command the
// card pulls ACK low for a few microseconds to say "send the next byte".

module sio_byte
(
	input             clk,
	input             reset,

	input      [15:0] half_period,  // clk cycles per half bit
	input      [15:0] ack_timeout,  // clk cycles to wait for ACK after the byte

	input             start,        // pulse: send tx
	input             last,         // last byte of a command: no ACK follows
	input       [7:0] tx,
	output reg  [7:0] rx,
	output reg        done,         // pulse: byte finished (rx valid, ack_seen valid)
	output reg        ack_seen,     // the card acknowledged this byte

	output reg        sio_clk,
	output reg        sio_cmd,
	input             sio_dat,      // synchronised, high when idle
	input             sio_ack       // synchronised, active low
);

localparam S_IDLE = 0, S_LOW = 1, S_HIGH = 2, S_ACK = 3, S_ACKHI = 4;

reg  [2:0] state;
reg  [2:0] bitn;
reg  [7:0] sh_tx;
reg [15:0] cnt;

always @(posedge clk) begin
	done <= 0;

	if (reset) begin
		state    <= S_IDLE;
		sio_clk  <= 1;
		sio_cmd  <= 1;
		ack_seen <= 0;
	end
	else begin
	// a fast card may pulse ACK before the last bit has finished
	if ((state == S_HIGH || state == S_LOW) && bitn == 7 && !sio_ack) ack_seen <= 1;

	case (state)
		S_IDLE: if (start) begin
			sh_tx    <= tx;
			bitn     <= 0;
			ack_seen <= 0;
			sio_clk  <= 0;
			sio_cmd  <= tx[0];
			cnt      <= half_period;
			state    <= S_LOW;
		end

		S_LOW: if (cnt) cnt <= cnt - 1'd1; else begin
			sio_clk <= 1;
			rx      <= {sio_dat, rx[7:1]};
			cnt     <= half_period;
			state   <= S_HIGH;
		end

		S_HIGH: if (cnt) cnt <= cnt - 1'd1; else begin
			if (bitn == 7) begin
				sio_cmd <= 1;
				cnt     <= ack_timeout;
				if (last) begin
					done  <= 1;
					state <= S_IDLE;
				end
				else state <= S_ACK;
			end
			else begin
				bitn    <= bitn + 1'd1;
				sh_tx   <= {1'b1, sh_tx[7:1]};
				sio_cmd <= sh_tx[1];
				sio_clk <= 0;
				cnt     <= half_period;
				state   <= S_LOW;
			end
		end

		// wait for the card's ACK pulse (low), then for it to end
		S_ACK: if (!sio_ack || ack_seen) begin
			ack_seen <= 1;
			cnt      <= ack_timeout;
			state    <= S_ACKHI;
		end
		else if (cnt) cnt <= cnt - 1'd1;
		else begin
			done  <= 1;
			state <= S_IDLE;
		end

		S_ACKHI: if (sio_ack || !cnt) begin
			done  <= 1;
			state <= S_IDLE;
		end
		else cnt <= cnt - 1'd1;
	endcase
	end
end

endmodule
