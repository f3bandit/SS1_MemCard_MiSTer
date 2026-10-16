// SS1 Memory Card Tool
// Copyright (C) 2026 f3bandit
//
// This program is free software: you can redistribute it and/or modify it under the terms of
// the GNU General Public License as published by the Free Software Foundation, either version 3
// of the License, or (at your option) any later version.
//
// screen: what the TV shows. 240p, 15 kHz (MiSTer scales it for HDMI): a 64x30 grid of
// 8x8 characters, a progress bar and a 32x32 map of the card's 1024 sectors.

module screen
(
	input             clk,          // 20 MHz
	input             reset,

	input       [2:0] phase,
	input       [1:0] job,
	input       [3:0] result,
	input       [1:0] card_state,
	input       [1:0] file_state,
	input             from_tool,
	input       [1:0] step,         // SS1 Tool's copy: 1 the backup first, 2 the write
	input       [9:0] cur_sector,
	input      [10:0] n_done,
	input      [10:0] n_ok,
	input      [10:0] n_retried,
	input      [10:0] n_failed,
	input      [10:0] n_differ,
	input      [10:0] n_written,
	output reg  [9:0] map_addr,
	input       [2:0] map_data,     // one clock after map_addr

	output reg        ce_pix,
	output reg        hblank,
	output reg        vblank,
	output reg        hsync,
	output reg        vsync,
	output reg  [7:0] r,
	output reg  [7:0] g,
	output reg  [7:0] b
);

`include "messages.vh"

localparam P_IDLE = 0, P_CLEAR = 1, P_LOAD = 2, P_READ = 3, P_SAVE = 4, P_REPORT = 5, P_DONE = 6;

////////////////////////////// timing (same as MiSTer's template core) //////////////////////////////

reg [9:0] hc = 0, vc = 0;
initial ce_pix = 0;
always @(posedge clk) begin
	ce_pix <= ~ce_pix;
	if (reset) begin hc <= 0; vc <= 0; end
	else if (ce_pix) begin
		if (hc == 637) begin
			hc <= 0;
			vc <= (vc == 261) ? 10'd0 : vc + 1'd1;
		end
		else hc <= hc + 1'd1;
	end
end

always @(posedge clk) if (ce_pix) begin
	if (hc == 529) hblank <= 1; else if (hc == 0) hblank <= 0;
	if (hc == 544) begin
		hsync <= 1;
		if (vc == 245) vsync <= 1; else if (vc == 248) vsync <= 0;
		if (vc == 240) vblank <= 1; else if (vc == 0) vblank <= 0;
	end
	if (hc == 590) hsync <= 0;
end

////////////////////////////// text //////////////////////////////

reg [5:0] msgs[0:4095];
initial $readmemh("rtl/messages.hex", msgs);

function [5:0] digit(input [10:0] v, input [1:0] pos);   // pos 0 = thousands
	reg [10:0] t;
	begin
		case (pos)
			0: t = v / 1000;
			1: t = (v / 100) % 10;
			2: t = (v / 10) % 10;
			3: t = v % 10;
		endcase
		digit = 6'd16 + t[5:0];   // '0' - 32
	end
endfunction

// the next pixel's cell
wire [9:0] nx = hc + 1'd1 - 10'd8;   // 8 pixels of border on the left
wire [5:0] ncol = nx[8:3];
wire [4:0] nrow = vc[7:3];

reg  [5:0] msg;       // message on this row
reg  [5:0] mcol;      // column where it starts
reg        is_num;
reg [10:0] num;
reg  [1:0] npos;
reg        blank;

wire [10:0] sector_no = cur_sector + 1'd1;
wire        busy = (phase != P_IDLE && phase != P_DONE);

always @(*) begin
	msg = M_R_NONE; mcol = 2; is_num = 0; num = 0; npos = 0; blank = 0;
	case (nrow)
		1:  msg = M_TITLE;
		2:  begin msg = M_RULE; mcol = 1; end
		4:  if (ncol < 9) msg = M_CARD; else begin mcol = 9;
				msg = (card_state == 1) ? M_C_FMT : (card_state == 2) ? M_C_BLANK : M_C_NONE; end
		5:  if (ncol < 9) msg = M_FILE; else begin mcol = 9;
				msg = (file_state == 1) ? M_F_OK : (file_state == 2) ? M_F_BAD : M_F_NONE; end
		6:  if (ncol < 9) msg = M_JOB; else begin mcol = 9;
				msg = (step == 1 && job == 1) ? M_J_STEP1 : (step == 2 && job == 3) ? M_J_STEP2 :
				      (job == 1) ? M_J_BACKUP : (job == 2) ? M_J_VERIFY : (job == 3) ? M_J_WRITE : M_J_NONE; end
		7:  if (from_tool && job != 0) begin mcol = 9; msg = M_J_TOOL; end
		9:  case (phase)
				P_LOAD:   msg = M_P_LOAD;
				P_READ:   begin msg = (job == 3) ? M_P_WRITE : M_P_READ; if (ncol >= 17 && ncol <= 20) begin is_num = 1; num = sector_no; npos = ncol - 6'd17; end end
				P_SAVE:   msg = M_P_SAVE;
				P_REPORT: msg = M_P_REPORT;
				default:  msg = result ? M_P_DONE : M_P_IDLE;
			endcase
		12: begin mcol = 38; msg = M_L_OK;    end
		13: begin mcol = 38; msg = M_L_RETRY; end
		14: begin mcol = 38; msg = M_L_FAIL;  end
		15: begin mcol = 38; msg = M_L_DIFF;  end
		16: begin mcol = 38; msg = M_L_WRITTEN; end
		17: begin mcol = 38; msg = M_L_NONE;  end
		19, 20, 21, 22, 23: begin
				mcol = 36;
				case (nrow)
					19: begin msg = M_N_OK;    num = n_ok;      end
					20: begin msg = M_N_RETRY; num = n_retried; end
					21: begin msg = M_N_FAIL;  num = n_failed;  end
					22: begin msg = M_N_DIFF; num = n_differ; end
					default: begin msg = M_N_WRITTEN; num = n_written; end
				endcase
				if (ncol >= 47 && ncol <= 50) begin is_num = 1; npos = ncol - 6'd47; end
			end
		28: case (result)
				1:  msg = (job == 2) ? M_R_V_OK : M_R_OK;
				2:  msg = (job == 2) ? M_R_V_OK : M_R_OK_RETRY;
				3:  msg = (job == 2) ? M_V_FAILED : (job == 3) ? M_W_FAILED : M_R_FAILED;
				9:  msg = M_W_OK;
				4:  msg = M_R_NOCARD;
				5:  msg = M_R_DIFFER;
				6:  msg = M_R_BADFILE;
				7:  msg = M_R_READONLY;
				8:  msg = M_R_SAVED_BAD;
				default: msg = M_R_NONE;
			endcase
		29: msg = busy ? M_H_BUSY : M_H_IDLE;
		default: blank = 1;
	endcase
	if (ncol < mcol || nx[9]) blank = 1;
end

// sector map: 32 x 32 cells of 8x4 pixels from (16, 96)
wire [9:0] ny = vc - 10'd96;
wire [9:0] nxm = hc + 1'd1 - 10'd16;
wire [4:0] ncol_map = nxm[7:3];
wire [4:0] nrow_map = ny[6:2];

wire [5:0] off = ncol - mcol;
reg  [5:0] ch;
always @(posedge clk) if (ce_pix) begin
	if (blank) ch <= 0;
	else if (is_num) ch <= ((npos == 0 && num < 1000) || (npos == 1 && num < 100) || (npos == 2 && num < 10)) ? 6'd0 : digit(num, npos);
	else ch <= msgs[{msg, off}];
	map_addr <= {nrow_map[4:0], ncol_map[4:0]};
end


wire [7:0] font_q;
font font(.ch(ch), .row(vc[2:0]), .q(font_q));

////////////////////////////// colours //////////////////////////////

wire [9:0] x = hc - 10'd8;
wire [4:0] row = vc[7:3];
wire       pix = font_q[~x[2:0]];

wire in_map  = (hc >= 16) && (hc < 16 + 256) && (vc >= 96) && (vc < 96 + 128);
wire cell_in = (hc - 10'd16) % 8 != 7 && (vc - 10'd96) % 4 != 3;
wire [9:0] ny_cur = vc - 10'd96;
wire [9:0] hx_cur = hc - 10'd16;
wire [9:0] cellno = {ny_cur[6:2], hx_cur[7:3]};

wire in_bar   = (vc >= 82) && (vc < 86) && (hc >= 16) && (hc < 16 + 256);
wire bar_fill = (hc - 10'd16) < n_done[10:2];

// legend squares at column 36, rows 12-16
wire in_leg = (x[9:3] == 36) && (row >= 12) && (row <= 17) && (vc[2:0] >= 1) && (vc[2:0] <= 6) && (x[2:0] >= 1) && (x[2:0] <= 6);

function [23:0] map_col(input [2:0] v);
	case (v)
		1: map_col = 24'h38C058;   // read OK
		2: map_col = 24'hE8C030;   // needed a retry
		3: map_col = 24'hE84040;   // failed
		4: map_col = 24'hD070E8;   // differs from the file
		5: map_col = 24'h4A9CF0;   // written and checked
		default: map_col = 24'h343A50;
	endcase
endfunction

reg [23:0] c;
always @(*) begin
	c = 24'h101428;   // background
	if (in_map) begin
		if (cell_in) c = (busy && phase == P_READ && cellno == cur_sector) ? 24'hFFFFFF : map_col(map_data);
	end
	else if (in_bar) c = bar_fill ? 24'h38C058 : 24'h343A50;
	else if (in_leg) c = map_col(row == 12 ? 3'd1 : row == 13 ? 3'd2 : row == 14 ? 3'd3 : row == 15 ? 3'd4 : row == 16 ? 3'd5 : 3'd0);
	else if (pix) begin
		case (row)
			1:  c = 24'h60D0FF;
			28: case (result)
					1, 2, 9: c = (result == 2 && job != 2) ? 24'hE8C030 : 24'h48E070;
					8:       c = 24'hE8C030;
					default: c = 24'hFF5050;
				endcase
			29: c = busy ? 24'hE8C030 : 24'h9098B0;
			default: c = 24'hE8ECF4;
		endcase
	end
end

always @(posedge clk) if (ce_pix) begin
	{r, g, b} <= (hblank || vblank) ? 24'h000000 : c;
end

endmodule
