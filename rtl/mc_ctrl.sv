// SS1 Memory Card Tool
// Copyright (C) 2026 f3bandit
//
// This program is free software: you can redistribute it and/or modify it under the terms of
// the GNU General Public License as published by the Free Software Foundation, either version 3
// of the License, or (at your option) any later version.
//
// mc_ctrl: runs the jobs.
//
// Two files are mounted by MiSTer:
//   drive 0  the card file (raw 128 KB .mcd/.mcr/.sav image): written by a backup, read by a verify
//   drive 1  the job file (optional, written by SS1 Tool): a request in, a report out
//
// Job file request (block 0): "SMCQ", job (1 backup, 2 verify, 3 write), 0, flags, 0, 4-byte id.
//   flags bit 0: this backup is step 1 of SS1 Tool's copy; bit 1: this write is step 2
//   blocks 1-2: one byte per sector; non-zero = a write job writes that sector even if it matches
// Job file report:            block 0  "SMCR", version, job, result, card state,
//                                      id (4), ok, retried, failed, differ, retries (16-bit LE),
//                                      sectors done (16-bit LE), speed
//                             blocks 1-2  one status byte per sector (MAP_* below)
//
// Backup: the whole card is read into the card buffer (retrying sectors that come back
// broken), then written to drive 0 in one go. Nothing is written when a sector couldn't be
// read, unless "save anyway" is on.
//
// Write (job 3, only from SS1 Tool's job file): the file goes into the card buffer, then every
// sector of the card is compared with it; a sector that differs is written and read back until
// it matches (or it's marked failed). Sectors that already match are never written.

module mc_ctrl
#(
	// times in 20 MHz clock cycles (the testbench shortens them)
	parameter HALF_FAST  = 39,       // 250 kHz bus
	parameter HALF_SLOW  = 79,       // 125 kHz bus
	parameter ACK_TO     = 4000,     // 200 us
	parameter SEL_DLY    = 400,      // 20 us
	parameter GAP        = 2000,     // 100 us between commands
	parameter RETRY_WAIT = 20000,    // 1 ms before a retry (10 ms on the slow bus)
	parameter POLL       = 6000000,  // look for a card every 0.3 s
	parameter PROGRESS   = 5000000,  // progress into the job file every 0.25 s
	parameter WRITE_GAP  = 100000,   // 5 ms after writing a sector before reading it back
	parameter PAD_GAP    = 165000    // controller test: a read every ~8 ms, the two ports in turn
)
(
	input             clk,
	input             reset,

	// OSD
	input             cmd_backup,     // pulse
	input             cmd_verify,     // pulse
	input             opt_auto,       // back up as soon as a card file is mounted
	input             opt_slow,       // half speed bus
	input             opt_save_bad,   // save the backup even when sectors failed

	// MiSTer file interface (hps_io, 512-byte blocks)
	input       [1:0] img_mounted,
	input      [63:0] img_size,
	input             img_readonly,
	output reg [31:0] sd_lba0,
	output reg [31:0] sd_lba1,
	output reg  [1:0] sd_rd,
	output reg  [1:0] sd_wr,
	input       [1:0] sd_ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,
	output      [7:0] sd_buff_din0,
	output      [7:0] sd_buff_din1,

	// for the screen
	output reg  [2:0] phase,
	output reg  [2:0] job,
	output reg  [3:0] result,
	output reg  [1:0] card_state,
	output reg  [1:0] file_state,
	output reg  [9:0] cur_sector,
	output reg [10:0] n_done,
	output reg [10:0] n_ok,
	output reg [10:0] n_retried,
	output reg [10:0] n_failed,
	output reg [10:0] n_differ,
	output reg [10:0] n_written,
	output reg        req_from_tool,
	output reg  [1:0] step,         // SS1 Tool's copy: 1 the backup before writing, 2 the write
	output reg        port2,        // the front port used: 0 port 1, 1 port 2
	output reg        pin6,         // controller test, wiring check: select on USER_OUT[6] instead
	input       [6:0] bus_low,      // USER_IN pins something else pulls low
	output     [39:0] wdiag,        // wiring check: {pin 6 ID, pin 6 answered, pin 6 pins, port 2 pins, port 1 pins}
	// controller test, both front ports: [port 1, then port 2 in the upper half]
	output reg  [1:0] pad_on,       // a controller answers
	output reg [15:0] pad_id,
	output reg [31:0] pad_btn,      // pressed = 1: 0 Select 1 L3 2 R3 3 Start 4 Up 5 Right 6 Down 7 Left
	                                //              8 L2 9 R2 10 L1 11 R1 12 Triangle 13 Circle 14 Cross 15 Square
	output reg [63:0] pad_ana,      // RX RY LX LY
	output reg  [3:0] pad_card,     // memory card in that port: 0 none, 1 formatted, 2 not formatted
	input       [9:0] map_vaddr,
	output reg  [2:0] map_vdata,

	// the card
	output            sio_sel_n,
	output            sio_clk,
	output            sio_cmd,
	input             sio_dat,
	input             sio_ack
);

// phases
localparam P_IDLE = 0, P_CLEAR = 1, P_LOAD = 2, P_READ = 3, P_SAVE = 4, P_REPORT = 5, P_DONE = 6, P_PAD = 7;
// jobs
localparam J_NONE = 0, J_BACKUP = 1, J_VERIFY = 2, J_WRITE = 3, J_PAD = 4;
// results
localparam RS_NONE = 0, RS_OK = 1, RS_OK_RETRY = 2, RS_FAILED = 3, RS_NOCARD = 4, RS_DIFFER = 5,
           RS_BADFILE = 6, RS_READONLY = 7, RS_SAVED_BAD = 8, RS_WRITTEN = 9;
// card state
localparam C_NONE = 0, C_FORMATTED = 1, C_BLANK = 2;
// file state
localparam F_NONE = 0, F_OK = 1, F_BAD = 2;
// sector map
localparam MAP_NONE = 0, MAP_OK = 1, MAP_RETRY = 2, MAP_FAIL = 3, MAP_DIFFER = 4, MAP_WRITTEN = 5;

localparam MAX_TRIES = 6;
localparam VERSION   = 4;   // 2: request flags (step 1/2 of a copy) and forced sectors; 3: front port 2, controller test
                            // 4: the controller test reads both ports and switches DualShocks to analog

////////////////////////////// card buffer (128 KB) //////////////////////////////

reg  [7:0] mem[0:131071];
reg [16:0] m_addr;
reg  [7:0] m_wdata;
reg        m_we;
reg  [7:0] m_q;
always @(posedge clk) begin
	if (m_we) mem[m_addr] <= m_wdata;
	m_q <= mem[m_addr];
end

////////////////////////////// sector map (1024 x 3 bits) //////////////////////////////

reg [2:0] map[0:1023];
reg [9:0] map_addr;
reg [2:0] map_wdata;
reg       map_we;
reg [2:0] map_q;
wire [9:0] map_ra = (phase == P_REPORT || pr_st != 0) ? {rep_blk_sel[1], sd_buff_addr} : map_addr;
always @(posedge clk) begin
	if (map_we) map[map_addr] <= map_wdata;
	map_q <= map[map_ra];
end
always @(posedge clk) map_vdata <= map[map_vaddr];

////////////////////////////// sector reader //////////////////////////////

reg         cs_start;
reg   [9:0] cs_sector;
reg   [1:0] cs_mode;
wire        cs_done, cs_mismatch;
wire  [1:0] cs_result;
wire  [7:0] cs_hdr0, cs_hdr1;
wire [16:0] cs_addr;
wire  [7:0] cs_wdata;
wire        cs_we;

reg         cs_pad;    // in the controller test: talk to the controller (else look for a card)
reg   [1:0] cs_pcmd;   // 0 read it, 1-3 the steps that switch a DualShock to analog
wire  [7:0] cs_pid;
wire [15:0] cs_pbtn;
wire [31:0] cs_pana;

card_sector card_sector
(
	.clk(clk), .reset(reset),
	.half_period(opt_slow ? 16'(HALF_SLOW) : 16'(HALF_FAST)),
	.ack_timeout(16'(ACK_TO)),
	.sel_delay(16'(SEL_DLY)),
	.start(cs_start), .pad(cs_pad && phase == P_PAD), .pcmd(cs_pcmd), .sector(cs_sector), .mode(cs_mode),
	.pad_id(cs_pid), .pad_btn(cs_pbtn), .pad_ana(cs_pana),
	.busy(), .done(cs_done), .result(cs_result), .mismatch(cs_mismatch),
	.hdr0(cs_hdr0), .hdr1(cs_hdr1),
	.mem_addr(cs_addr), .mem_wdata(cs_wdata), .mem_we(cs_we), .mem_rdata(m_q),
	.sio_sel_n(sio_sel_n), .sio_clk(sio_clk), .sio_cmd(sio_cmd), .sio_dat(sio_dat), .sio_ack(sio_ack)
);

localparam CS_STORE = 0, CS_COMPARE = 1, CS_PROBE = 2, CS_WRITE = 3;
localparam R_OK = 0, R_NOCARD = 1, R_BAD = 2, R_RANGE = 3;

////////////////////////////// job file //////////////////////////////

reg  [7:0] req[0:15];
reg        req_valid;
reg  [2:0] req_job;
reg        jf_mounted;
reg        req_rd;       // reading the request from the job file
reg  [1:0] req_blk;      // which of its 3 blocks
reg        req_port2;    // the request is for front port 2
reg  [7:0] pad_cnt;      // controller test: reads so far
reg        pp;           // the port being read: 0 port 1, 1 port 2
reg  [5:0] pad_n1, pad_n2;   // reads until the next look for a memory card in that port
reg  [1:0] cfg1, cfg2;   // switching that port's controller to analog: the next step (0 none)
reg  [1:0] tried;        // the switch was sent to that port's controller (until it's unplugged)
reg  [5:0] swc1, swc2;   // reads until the switch is sent again while that pad stays digital
reg  [7:0] sw_cnt;       // analog switches sent
// wiring check: the pins pulled low during the last read of port 1, port 2 and with pin 6 as
// the select, and whether a controller answered on pin 6
reg  [6:0] acc, act1, act2, act6;
reg        on6, scanning;
reg  [7:0] id6;
reg  [4:0] scn;          // reads until the next pin 6 try
assign wdiag = {id6, 7'd0, on6, 1'b0, act6, 1'b0, act2, 1'b0, act1};
wire [1:0] cfg_pp = pp ? cfg2 : cfg1;
wire [5:0] pn_pp  = pp ? pad_n2 : pad_n1;
reg        jf_full;      // the job file has all 3 blocks
reg [1023:0] force_wr;   // write job: sectors to write even when they already match
reg        cf_new;       // a card file was just mounted
reg        rep_final;    // the report is final ("SMCR"), not progress ("SMCP")
reg  [1:0] pr_st;        // progress writer
reg  [1:0] pr_blk;
reg [23:0] pr_tmr;
reg        cf_mounted;
reg        cf_readonly;
reg  [8:0] rep_blk_sel;   // which report block hps_io is reading (0..2)
reg [10:0] n_retries;

// report bytes, block 0
reg  [7:0] rep0;
always @(*) begin
	case (sd_buff_addr)
		0: rep0 = "S";  1: rep0 = "M";  2: rep0 = "C";  3: rep0 = rep_final ? "R" : "P";
		4: rep0 = VERSION;
		5: rep0 = job;
		6: rep0 = result;
		7: rep0 = card_state;
		8: rep0 = req[8];  9: rep0 = req[9];  10: rep0 = req[10];  11: rep0 = req[11];
		12: rep0 = n_ok[7:0];      13: rep0 = n_ok[10:8];
		14: rep0 = n_retried[7:0]; 15: rep0 = n_retried[10:8];
		16: rep0 = n_failed[7:0];  17: rep0 = n_failed[10:8];
		18: rep0 = n_differ[7:0];  19: rep0 = n_differ[10:8];
		20: rep0 = n_retries[7:0]; 21: rep0 = n_retries[10:8];
		22: rep0 = n_done[7:0];    23: rep0 = n_done[10:8];
		24: rep0 = opt_slow;
		28: rep0 = n_written[7:0]; 29: rep0 = n_written[10:8];
		25: rep0 = phase;
		26: rep0 = cur_sector[7:0]; 27: rep0 = cur_sector[9:8];
		// controller test: port 1 at 32, port 2 at 48 (port, answers, ID, buttons x2, RX RY LX LY,
		// reads so far, memory card, analog switch sent)
		32: rep0 = 1;  48: rep0 = 2;
		33: rep0 = pad_on[0];          49: rep0 = pad_on[1];
		34: rep0 = pad_id[7:0];        50: rep0 = pad_id[15:8];
		35: rep0 = pad_btn[7:0];       51: rep0 = pad_btn[23:16];
		36: rep0 = pad_btn[15:8];      52: rep0 = pad_btn[31:24];
		37: rep0 = pad_ana[7:0];       53: rep0 = pad_ana[39:32];
		38: rep0 = pad_ana[15:8];      54: rep0 = pad_ana[47:40];
		39: rep0 = pad_ana[23:16];     55: rep0 = pad_ana[55:48];
		40: rep0 = pad_ana[31:24];     56: rep0 = pad_ana[63:56];
		41: rep0 = pad_cnt;            57: rep0 = pad_cnt;
		42: rep0 = pad_card[1:0];      58: rep0 = pad_card[3:2];
		43: rep0 = tried[0];           59: rep0 = tried[1];
		44: rep0 = sw_cnt;
		// wiring check: pins pulled low (bit n = USER_IN[n]) for port 1, port 2, pin 6 as select
		64: rep0 = act1;  65: rep0 = act2;  66: rep0 = act6;  67: rep0 = on6;  68: rep0 = id6;
		default: rep0 = 0;
	endcase
end
assign sd_buff_din1 = rep_blk_sel ? {5'd0, map_q} : rep0;
assign sd_buff_din0 = m_q;

// one sector is finished: mark it on the map, count it, go to the next one
task finish_sector(input [2:0] code);
	begin
		map_addr  <= cur_sector;
		map_wdata <= code;
		map_we    <= 1;
		n_done    <= n_done_next;
		case (code)
			MAP_OK:      n_ok      <= n_ok + 1'd1;
			MAP_RETRY:   n_retried <= n_retried + 1'd1;
			MAP_DIFFER:  n_differ  <= n_differ + 1'd1;
			MAP_WRITTEN: n_written <= n_written + 1'd1;
			default:     n_failed  <= n_failed + 1'd1;
		endcase
		nocard_run <= (cs_result == R_NOCARD) ? nocard_run + 1'd1 : 3'd0;
		if (cs_result == R_NOCARD && (n_done == 0 || nocard_run == 3)) begin
			// no card after all, or it was pulled out
			result     <= RS_NOCARD;
			card_state <= C_NONE;
			phase      <= P_REPORT;
			blk        <= 0;
		end
		else if (cur_sector == 1023) begin
			phase <= P_SAVE;
			blk   <= 0;
		end
		else begin
			cur_sector <= cur_sector + 1'd1;
			tries      <= 0;
		end
	end
endtask

////////////////////////////// main state machine //////////////////////////////

reg  [2:0] sd_st;        // file transfer sub-state
reg  [8:0] blk;          // block counter
reg [23:0] tmr;
reg  [2:0] tries;
reg  [2:0] wtries;
reg        any_retry;
reg  [2:0] pend_job;     // job waiting for a card or a file
reg  [1:0] old_ack;
reg  [2:0] nocard_run;   // sectors in a row with no card answering

wire [10:0] n_done_next = n_done + 1'd1;

always @(posedge clk) begin
	cs_start <= 0;
	map_we   <= 0;
	old_ack  <= sd_ack;

	if (reset) begin
		job        <= J_NONE;
		pend_job   <= J_NONE;
		result     <= RS_NONE;
		card_state <= C_NONE;
		file_state <= F_NONE;
		sd_rd      <= 0;
		sd_wr      <= 0;
		sd_st      <= 0;
		req_valid  <= 0;
		jf_mounted <= 0;
		req_rd     <= 0;
		// a reset starts the screen afresh: counts and the sector map are cleared
		n_done     <= 0;
		n_ok       <= 0;
		n_retried  <= 0;
		n_failed   <= 0;
		n_differ   <= 0;
		n_written  <= 0;
		n_retries  <= 0;
		cur_sector <= 0;
		map_addr   <= 0;
		phase      <= P_CLEAR;
		cf_new     <= 0;
		step       <= 0;
		port2      <= 0;
		pad_on     <= 0;
		pad_cnt    <= 0;
		pad_card   <= 0;
		tried      <= 0;
		pad_n1     <= 0;
		pad_n2     <= 0;
		swc1       <= 0;
		swc2       <= 0;
		pin6       <= 0;
		scn        <= 5'd4;
		scanning   <= 0;
		act1       <= 0;
		act2       <= 0;
		act6       <= 0;
		on6        <= 0;
		id6        <= 0;
		cfg1       <= 0;
		cfg2       <= 0;
		sw_cnt     <= 0;
		pp         <= 0;
		req_port2  <= 0;
		req_blk    <= 0;
		rep_final  <= 1;
		pr_st      <= 0;
		pr_tmr     <= 0;
		cf_mounted <= 0;
		tmr        <= 0;
		req_from_tool <= 0;
	end
	else begin
		if (phase != P_PAD) pin6 <= 0;   // the wiring check's select only ever in the controller test

		// files being mounted (hps_io pulses img_mounted with img_size valid)
		if (img_mounted[1]) begin
			jf_mounted <= (img_size != 0);
			req_valid  <= 0;
			if (img_size != 0 && phase == P_PAD) phase <= P_IDLE;   // a new job ends the controller test
			if (img_size != 0 && (phase == P_IDLE || phase == P_PAD)) begin
				// read the request: block 0, then the forced-sector list in blocks 1-2
				sd_lba1  <= 0;
				sd_rd[1] <= 1;
				req_rd   <= 1;
				req_blk  <= 0;
				jf_full  <= (img_size >= 1536);
				force_wr <= 0;
			end
		end
		if (img_mounted[0]) begin
			cf_mounted  <= (img_size == 131072);
			cf_readonly <= img_readonly;
			file_state  <= (img_size == 0) ? F_NONE : (img_size == 131072) ? F_OK : F_BAD;
			if (img_size == 131072) cf_new <= 1;
			else if (img_size != 0) begin
				result <= RS_BADFILE;
			end
		end

		// the request arrives
		if (sd_ack[1] && sd_buff_wr && req_rd && req_blk == 0 && sd_buff_addr < 16) req[sd_buff_addr[3:0]] <= sd_buff_dout;
		if (sd_ack[1] && sd_buff_wr && req_rd && req_blk != 0) force_wr[{req_blk[1], sd_buff_addr}] <= (sd_buff_dout != 0);
		if (sd_ack[1]) sd_rd[1] <= 0;
		if (old_ack[1] && !sd_ack[1] && req_rd && jf_full && req_blk != 2) begin
			req_blk  <= req_blk + 1'd1;
			sd_lba1  <= req_blk + 1'd1;
			sd_rd[1] <= 1;
		end
		else if (old_ack[1] && !sd_ack[1] && req_rd) begin
			req_rd <= 0;
			if (req[0] == "S" && req[1] == "M" && req[2] == "C" && req[3] == "Q" && (req[4] == J_BACKUP || req[4] == J_VERIFY || req[4] == J_WRITE || req[4] == J_PAD)) begin
				req_valid <= 1;
				req_job   <= req[4][2:0];
				req_port2 <= (req[7] == 2);
			end
		end

		// a new card file: do what the job file asked for (once it has been read), or back up
		if (cf_new && !req_rd && !sd_rd[1]) begin
			cf_new <= 0;
			if (req_valid) begin
				pend_job      <= req_job;
				port2         <= req_port2;
				req_from_tool <= 1;
				req_valid     <= 0;
				step          <= req[6][1:0];
			end
			else if (opt_auto) begin
				pend_job      <= J_BACKUP;
				port2         <= 0;
				req_from_tool <= 0;
				step          <= 0;
			end
		end

		if (cmd_backup && phase == P_IDLE) begin pend_job <= J_BACKUP; req_from_tool <= 0; step <= 0; port2 <= 0; end
		if (cmd_verify && phase == P_IDLE) begin pend_job <= J_VERIFY; req_from_tool <= 0; step <= 0; port2 <= 0; end

		if (tmr) tmr <= tmr - 1'd1;
		if (pr_tmr) pr_tmr <= pr_tmr - 1'd1;

		// progress for SS1 Tool: while a job runs, the job file gets the counts and the
		// sector map (as "SMCP") every quarter second; the final report says "SMCR"
		case (pr_st)
			0: if (jf_mounted && !pr_tmr && (phase == P_LOAD || phase == P_READ || phase == P_SAVE || phase == P_PAD)) begin
				pr_blk <= 0;
				pr_st  <= 1;
			end
			1: begin rep_blk_sel <= pr_blk; sd_lba1 <= pr_blk; sd_wr[1] <= 1; pr_st <= 2; end
			2: if (sd_ack[1]) begin sd_wr[1] <= 0; pr_st <= 3; end
			3: if (!sd_ack[1]) begin
				if (phase == P_PAD) begin pr_st <= 0; pr_tmr <= 24'(PROGRESS / 3); end   // controller test: block 0, ~12 a second
				else if (pr_blk == 2) begin pr_st <= 0; pr_tmr <= 24'(PROGRESS); end
				else begin pr_blk <= pr_blk + 1'd1; pr_st <= 1; end
			end
		endcase

		case (phase)
			// look at the card every 0.3 s; start a job once there is a card and a file
			P_IDLE: begin
				if (pend_job != J_NONE && !cf_mounted) begin
					result   <= (file_state == F_BAD) ? RS_BADFILE : RS_NONE;
					pend_job <= J_NONE;
				end
				else if (pend_job != J_NONE && (card_state != C_NONE || pend_job == J_PAD) && !sd_rd[1] && sd_st == 0) begin
					if (pend_job == J_BACKUP && cf_readonly) begin
						job      <= J_BACKUP;
						result   <= RS_READONLY;
						pend_job <= J_NONE;
						phase    <= P_REPORT;
						blk      <= 0;
						sd_st    <= 0;
					end
					else begin
						job       <= pend_job;
						pend_job  <= J_NONE;
						result    <= RS_NONE;
						n_done    <= 0;
						n_ok      <= 0;
						n_retried <= 0;
						n_failed  <= 0;
						n_differ  <= 0;
						n_written <= 0;
						n_retries <= 0;
						nocard_run <= 0;
						rep_final <= 0;
						pr_tmr    <= 24'(PROGRESS / 4);
						any_retry <= 0;
						cur_sector <= 0;
						map_addr  <= 0;
						phase     <= P_CLEAR;
					end
				end
				else if (!tmr && sd_st == 0) begin
					if (sd_st == 0) begin
						cs_sector <= 0;
						cs_mode   <= CS_PROBE;
						cs_start  <= 1;
						sd_st     <= 1;
					end
				end
				else if (sd_st == 1 && cs_done) begin
					sd_st <= 0;
					tmr   <= 24'(POLL);
					if (cs_result == R_NOCARD) card_state <= C_NONE;
					else if (cs_result == R_OK) card_state <= (cs_hdr0 == "M" && cs_hdr1 == "C") ? C_FORMATTED : C_BLANK;
					// a broken reply: keep what we had and look again
				end
			end

			P_CLEAR: begin
				map_wdata <= MAP_NONE;
				map_we    <= 1;
				map_addr  <= map_addr + 1'd1;
				if (map_addr == 1023) begin
					blk   <= 0;
					sd_st <= 0;
					phase <= (job == J_VERIFY || job == J_WRITE) ? P_LOAD : (job == J_BACKUP) ? P_READ : (job == J_PAD) ? P_PAD : P_IDLE;
					tries <= 0;
					// the controller test starts from scratch
					pp <= 0; pad_n1 <= 0; pad_n2 <= 0; cfg1 <= 0; cfg2 <= 0; tried <= 0; swc1 <= 0; swc2 <= 0;
					scn <= 5'd4; act1 <= 0; act2 <= 0; act6 <= 0; on6 <= 0; id6 <= 0; pin6 <= 0;
					pad_on <= 0; pad_card <= 0; pad_btn <= 0; pad_cnt <= 0;
				end
			end

			// verify: the file goes into the card buffer first
			P_LOAD: case (sd_st)
				0: begin sd_lba0 <= blk; sd_rd[0] <= 1; sd_st <= 1; end
				1: if (sd_ack[0]) begin sd_rd[0] <= 0; sd_st <= 2; end
				2: if (!sd_ack[0]) begin
					if (blk == 255) begin phase <= P_READ; sd_st <= 0; tries <= 0; end
					else begin blk <= blk + 1'd1; sd_st <= 0; end
				end
			endcase

			// read every sector (backup, check), or bring the card in line with the file (write)
			P_READ: case (sd_st)
				0: if (!tmr) begin
					cs_sector <= cur_sector;
					cs_mode   <= (job == J_BACKUP) ? CS_STORE : CS_COMPARE;
					cs_start  <= 1;
					sd_st     <= 1;
				end
				1: if (cs_done) begin
					tmr   <= 24'(GAP);
					sd_st <= 0;
					if (cs_result == R_OK && job == J_WRITE && (cs_mismatch || force_wr[cur_sector])) begin
						// this sector differs from the file (or SS1 Tool asked for it): write it
						wtries <= 0;
						sd_st  <= 2;
					end
					else if (cs_result == R_OK || tries == MAX_TRIES - 1 || cs_result == R_RANGE) begin
						if (cs_result != R_OK) finish_sector(MAP_FAIL);
						else if (job == J_VERIFY && cs_mismatch) finish_sector(MAP_DIFFER);
						else if (tries) finish_sector(MAP_RETRY);
						else finish_sector(MAP_OK);
					end
					else begin
						tries     <= tries + 1'd1;
						n_retries <= n_retries + 1'd1;
						tmr       <= opt_slow ? 24'(RETRY_WAIT * 10) : 24'(RETRY_WAIT);
					end
				end
				2: if (!tmr) begin
					cs_sector <= cur_sector;
					cs_mode   <= CS_WRITE;
					cs_start  <= 1;
					sd_st     <= 3;
				end
				3: if (cs_done) begin
					tmr   <= 24'(WRITE_GAP);
					sd_st <= 4;
				end
				// read it back: it must match the file now
				4: if (!tmr) begin
					cs_sector <= cur_sector;
					cs_mode   <= CS_COMPARE;
					cs_start  <= 1;
					sd_st     <= 5;
				end
				5: if (cs_done) begin
					tmr <= 24'(GAP);
					if (cs_result == R_OK && !cs_mismatch) begin
						sd_st <= 0;
						finish_sector(MAP_WRITTEN);
					end
					else if (wtries == MAX_TRIES - 1) begin
						sd_st <= 0;
						finish_sector(MAP_FAIL);
					end
					else begin
						wtries    <= wtries + 1'd1;
						n_retries <= n_retries + 1'd1;
						tmr       <= opt_slow ? 24'(RETRY_WAIT * 10) : 24'(RETRY_WAIT);
						sd_st     <= 2;
					end
				end
			endcase

			// backup: write the card buffer to the card file
			P_SAVE: begin
				if (job != J_BACKUP) begin
					if (job == J_WRITE) result <= n_failed ? RS_FAILED : RS_WRITTEN;
					else result <= n_differ ? RS_DIFFER : n_failed ? RS_FAILED : n_retried ? RS_OK_RETRY : RS_OK;
					phase  <= P_REPORT;
					blk    <= 0;
					sd_st  <= 0;
				end
				else if (n_failed && !opt_save_bad) begin
					result <= RS_FAILED;
					phase  <= P_REPORT;
					blk    <= 0;
					sd_st  <= 0;
				end
				else case (sd_st)
					0: begin sd_lba0 <= blk; sd_wr[0] <= 1; sd_st <= 1; end
					1: if (sd_ack[0]) begin sd_wr[0] <= 0; sd_st <= 2; end
					2: if (!sd_ack[0]) begin
						if (blk == 255) begin
							result <= n_failed ? RS_SAVED_BAD : n_retried ? RS_OK_RETRY : RS_OK;
							phase  <= P_REPORT;
							blk    <= 0;
							sd_st  <= 0;
						end
						else begin blk <= blk + 1'd1; sd_st <= 0; end
					end
				endcase
			end

			// the report goes into the job file, when SS1 Tool gave one
			P_REPORT: begin
				if (!jf_mounted) phase <= P_DONE;
				else case (sd_st)
					0: if (pr_st == 0) begin rep_final <= 1; rep_blk_sel <= blk; sd_lba1 <= blk; sd_wr[1] <= 1; sd_st <= 1; end
					1: if (sd_ack[1]) begin sd_wr[1] <= 0; sd_st <= 2; end
					2: if (!sd_ack[1]) begin
						if (blk == 2) begin phase <= P_DONE; sd_st <= 0; end
						else begin blk <= blk + 1'd1; sd_st <= 0; end
					end
				endcase
			end

			// shows the result until the next job; keeps watching the card
			// controller test: read the controller about 60 times a second, and look for a memory
			// card in the same port once a second. It runs until a new job file or a reset.
			P_PAD: case (sd_st)
				0: if (!tmr) begin
					scanning  <= (scn == 0);
					port2     <= pp;
					pin6      <= (scn == 0);
					acc       <= 0;
					cs_pad    <= (scn == 0) || (pn_pp != 0) || (cfg_pp != 0);
					cs_pcmd   <= (scn == 0) ? 2'd0 : cfg_pp;
					cs_sector <= 0;
					cs_mode   <= CS_PROBE;
					cs_start  <= 1;
					sd_st     <= 1;
				end
				1: if (!cs_done) begin
					if (!sio_sel_n) acc <= acc | bus_low;
				end
				else begin
					sd_st <= 0;
					tmr   <= 24'(PAD_GAP);
					pin6  <= 0;
					if (scanning) begin
						// the wiring check's read: record it, don't touch the ports
						act6 <= acc;
						on6  <= (cs_result == R_OK);
						id6  <= (cs_result == R_OK) ? cs_pid : 8'd0;
						scn  <= 5'd30;
					end
					else begin
					if (scn != 0) scn <= scn - 1'd1;
					if (pp) act2 <= acc; else act1 <= acc;
					pp    <= ~pp;
					if (cs_pad && cs_pcmd != 0) begin
						// a step of the switch to analog: on to the next one
						if (pp) cfg2 <= (cfg2 == 3) ? 2'd0 : cfg2 + 1'd1;
						else    cfg1 <= (cfg1 == 3) ? 2'd0 : cfg1 + 1'd1;
					end
					else if (cs_pad) begin
						if (!pp) pad_cnt <= pad_cnt + 1'd1;
						if (pp) pad_n2 <= pad_n2 - 1'd1; else pad_n1 <= pad_n1 - 1'd1;
						if (pp) pad_on[1] <= (cs_result == R_OK); else pad_on[0] <= (cs_result == R_OK);
						if (cs_result == R_OK) begin
							if (pp) begin
								pad_id[15:8]   <= cs_pid;
								pad_btn[31:16] <= ~cs_pbtn;
								pad_ana[63:32] <= (cs_pid[3:0] >= 3) ? cs_pana : 32'h80808080;
							end
							else begin
								pad_id[7:0]    <= cs_pid;
								pad_btn[15:0]  <= ~cs_pbtn;
								pad_ana[31:0]  <= (cs_pid[3:0] >= 3) ? cs_pana : 32'h80808080;
							end
							// a digital pad that may be a DualShock: ask for analog mode, and again about
							// once a second while it stays digital (a wireless receiver answers as a
							// digital pad before its controller has paired)
							if (cs_pid == 8'h41) begin
								if ((pp ? swc2 : swc1) == 0) begin
									if (pp) begin cfg2 <= 1; swc2 <= 6'd60; end else begin cfg1 <= 1; swc1 <= 6'd60; end
									tried[pp] <= 1;
									sw_cnt    <= sw_cnt + 1'd1;
								end
								else if (pp) swc2 <= swc2 - 1'd1; else swc1 <= swc1 - 1'd1;
							end
							// left in config mode somehow: leave it
							if (cs_pid == 8'hF3) begin
								if (pp) cfg2 <= 3; else cfg1 <= 3;
							end
						end
						else begin
							if (pp) pad_btn[31:16] <= 0; else pad_btn[15:0] <= 0;
							if (cs_result == R_NOCARD) begin   // unplugged: switch it straight away when it's back
								tried[pp] <= 0;
								if (pp) swc2 <= 0; else swc1 <= 0;
							end
						end
					end
					else begin
						if (pp) pad_card[3:2] <= (cs_result == R_NOCARD) ? C_NONE : (cs_result == R_OK) ? ((cs_hdr0 == "M" && cs_hdr1 == "C") ? C_FORMATTED : C_BLANK) : pad_card[3:2];
						else    pad_card[1:0] <= (cs_result == R_NOCARD) ? C_NONE : (cs_result == R_OK) ? ((cs_hdr0 == "M" && cs_hdr1 == "C") ? C_FORMATTED : C_BLANK) : pad_card[1:0];
						if (pp) pad_n2 <= 6'd60; else pad_n1 <= 6'd60;
					end
					end
				end
			endcase

			P_DONE: begin
				phase <= P_IDLE;
				tmr   <= 24'(POLL);
				sd_st <= 0;
			end
		endcase
	end
end

// who drives the card buffer and the map
always @(*) begin
	m_we    = 0;
	m_wdata = 0;
	m_addr  = cs_addr;
	if (phase == P_LOAD) begin
		m_addr  = {blk[7:0], sd_buff_addr};
		m_wdata = sd_buff_dout;
		m_we    = sd_buff_wr & sd_ack[0];
	end
	else if (phase == P_SAVE) begin
		m_addr  = {blk[7:0], sd_buff_addr};
	end
	else if (phase == P_READ) begin
		m_wdata = cs_wdata;
		m_we    = cs_we;
	end
end

endmodule
