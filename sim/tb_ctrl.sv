// Testbench for mc_ctrl: a modelled PS1 memory card on the bus and a stand-in for MiSTer's
// file transfers (hps_io). Run: sh sim/run.sh
`timescale 1ns/1ns

module card_model
(
	input        sel_n,
	input        sclk,
	input        cmd,
	output reg   dat,
	output reg   ack_n
);
	reg  [7:0] mem[0:131071];
	integer    present = 1;
	integer    flaky_sector = -1;   // returns a bad checksum this many times
	integer    flaky_count = 0;
	integer    dead_sector = -1;    // always bad
	integer    ack_delay = 150;     // ns after the byte

	integer    idx;
	reg  [7:0] in_sh, out_sh, nxt;
	integer    bitn;
	reg  [9:0] addr;
	reg  [7:0] chk;
	reg        active;
	reg        wmode;
	reg        pmode;               // a controller is being read
	integer    pad_present = 1;
	reg [15:0] pad_raw = 16'hFFFF;    // active low
	reg [31:0] pad_ana = 32'h80808080;
	reg        pad_analog = 1;      // sends 73 (analog); 0: 41 (digital) until switched
	reg        pad_cfg = 0;         // in config mode (sends F3)
	reg  [7:0] pad_cmd;
	integer    pad_len;
	integer    pad_switches = 0;    // times it was put into analog mode
	integer    refuse = 0;          // ignores the analog command (a receiver with no controller yet)
	reg  [7:0] wbuf[0:127];
	reg  [7:0] wchk;
	integer    writes = 0;
	integer    bad_write_sector = -1;   // refuses the first write
	integer    bad_write_count = 0;

	initial begin dat = 1; ack_n = 1; active = 0; wmode = 0; end

	always @(negedge sel_n) begin idx = 0; bitn = 0; active = present | pad_present; out_sh = 8'hFF; wmode = 0; pmode = 0; end
	always @(posedge sel_n) begin active = 0; dat = 1; end

	// card drives DAT while CLK is low, the console samples on the rising edge
	always @(negedge sclk) if (!sel_n && active) dat = out_sh[bitn];

	always @(posedge sclk) if (!sel_n && active) begin
		in_sh = {cmd, in_sh[7:1]};
		bitn  = bitn + 1;
		if (bitn == 8) begin
			bitn = 0;
			respond();
		end
	end

	function [7:0] reply(input integer i);
		integer d;
		begin
			if (pmode) begin
				case (i)
					0: reply = pad_cfg ? 8'hF3 : pad_analog ? 8'h73 : 8'h41;
					1: reply = 8'h5A;
					2: reply = pad_raw[7:0];
					3: reply = pad_raw[15:8];
					default: reply = pad_ana[(i - 4) * 8 +: 8];
				endcase
			end
			else if (wmode && i >= 3) begin
				if (i == 134) reply = 8'h5C;
				else if (i == 135) reply = 8'h5D;
				else if (i == 136) reply = (wchk == 0) ? 8'h47 : 8'h4E;
				else reply = 8'h00;
			end
			else case (i)
				0: reply = 8'h08;       // FLAG, answered during byte 1
				1: reply = 8'h5A;
				2: reply = 8'h5D;
				3: reply = 8'h00;
				4: reply = addr[9:8];
				5: reply = 8'h5C;
				6: reply = 8'h5D;
				7: reply = addr[9:8];
				8: reply = addr[7:0];
				default: begin
					if (i >= 9 && i < 137) reply = mem[{addr, 7'd0} + i - 9];
					else if (i == 137) reply = chk;
					else reply = 8'h47;
				end
			endcase
		end
	endfunction

	task respond;
		integer i;
		begin
			// in_sh is the byte just received (index idx); out byte for idx+1 is prepared now
			if (idx == 0 && in_sh == 8'h01 && pad_present) pmode = 1;
			else if (idx == 0 && (in_sh != 8'h81 || !present)) begin active = 0; disable respond; end
			if (idx == 0 && pmode) pad_len = (!pad_cfg && !pad_analog) ? 5 : 9;
			if (idx == 1 && pmode) pad_cmd = in_sh;
			if (idx == 3 && pmode && pad_cmd == 8'h43) pad_cfg = in_sh[0];
			if (idx == 3 && pmode && pad_cmd == 8'h44 && pad_cfg && !refuse) begin pad_analog = in_sh[0]; pad_switches = pad_switches + 1; end
			if (idx == 1 && !pmode) begin
				if (in_sh == 8'h52) wmode = 0;
				else if (in_sh == 8'h57) wmode = 1;
				else begin active = 0; disable respond; end
			end
			if (wmode && idx == 4) addr[9:8] = in_sh[1:0];
			if (wmode && idx == 5) begin addr[7:0] = in_sh; wchk = addr[9:8] ^ addr[7:0]; end
			if (wmode && idx >= 6 && idx < 134) begin wbuf[idx-6] = in_sh; wchk = wchk ^ in_sh; end
			if (wmode && idx == 134) begin
				wchk = wchk ^ in_sh;   // 0 when the checksum was right
				if (addr == bad_write_sector && bad_write_count > 0) begin bad_write_count = bad_write_count - 1; end
				else if (wchk == 0) begin for (i = 0; i < 128; i = i + 1) mem[{addr, 7'd0} + i] = wbuf[i]; writes = writes + 1; end
			end
			if (!wmode && idx == 4) addr[9:8] = in_sh[1:0];
			if (!wmode && idx == 5) begin
				addr[7:0] = in_sh;
				chk = addr[9:8] ^ addr[7:0];
				for (i = 0; i < 128; i = i + 1) chk = chk ^ mem[{addr, 7'd0} + i];
				if (addr == flaky_sector && flaky_count > 0) begin chk = ~chk; flaky_count = flaky_count - 1; end
				if (addr == dead_sector) chk = ~chk;
			end
			out_sh = reply(idx);
			idx = idx + 1;
			if (idx < (pmode ? pad_len : wmode ? 138 : 140)) begin
				#(ack_delay) ack_n = 0;
				#200 ack_n = 1;
			end
		end
	endtask
endmodule

module tb;
	reg clk = 0;
	always #25 clk = ~clk;   // 20 MHz

	reg reset = 1;

	reg        cmd_backup = 0, cmd_verify = 0;
	reg        opt_auto = 1, opt_slow = 0, opt_save_bad = 0;
	reg  [1:0] img_mounted = 0;
	reg [63:0] img_size = 0;
	reg        img_readonly = 0;
	wire [31:0] sd_lba0, sd_lba1;
	wire  [1:0] sd_rd, sd_wr;
	reg   [1:0] sd_ack = 0;
	reg   [8:0] sd_buff_addr = 0;
	reg   [7:0] sd_buff_dout = 0;
	reg         sd_buff_wr = 0;
	wire  [7:0] sd_buff_din0, sd_buff_din1;
	wire  [2:0] phase;
	wire  [2:0] job;
	wire  [1:0] card_state, file_state;
	wire  [3:0] result;
	wire  [9:0] cur_sector;
	wire [10:0] n_done, n_ok, n_retried, n_failed, n_differ;

	wire sel_n, sclk, scmd, dat1, ack1_n, dat2, ack2_n, port2;
	// the front ports: one select line each, DAT and ACK shared (open collector)
	wire pin6;   // the wiring check's select: nothing on it here
	wire sel1_n = (port2 || pin6) ? 1'b1 : sel_n;
	wire sel2_n = (port2 && !pin6) ? sel_n : 1'b1;
	wire dat = dat1 & dat2;
	wire ack_n = ack1_n & ack2_n;

	mc_ctrl #(.HALF_FAST(3), .HALF_SLOW(6), .ACK_TO(60), .SEL_DLY(4), .GAP(10), .RETRY_WAIT(20), .POLL(2000), .PROGRESS(50000), .PAD_GAP(2000)) dut
	(
		.clk(clk), .reset(reset),
		.cmd_backup(cmd_backup), .cmd_verify(cmd_verify),
		.opt_auto(opt_auto), .opt_slow(opt_slow), .opt_save_bad(opt_save_bad),
		.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
		.sd_lba0(sd_lba0), .sd_lba1(sd_lba1), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
		.sd_buff_din0(sd_buff_din0), .sd_buff_din1(sd_buff_din1),
		.phase(phase), .job(job), .result(result), .card_state(card_state), .file_state(file_state),
		.cur_sector(cur_sector), .n_done(n_done), .n_ok(n_ok), .n_retried(n_retried),
		.n_failed(n_failed), .n_differ(n_differ), .n_written(), .req_from_tool(), .step(), .port2(port2), .pad_on(), .pad_id(), .pad_btn(), .pad_ana(), .pad_card(), .pin6(pin6), .bus_low(7'd0), .wdiag(), .splash(),
		.map_vaddr(10'd0), .map_vdata(),
		.sio_sel_n(sel_n), .sio_clk(sclk), .sio_cmd(scmd), .sio_dat(dat), .sio_ack(ack_n)
	);

	card_model card(.sel_n(sel1_n), .sclk(sclk), .cmd(scmd), .dat(dat1), .ack_n(ack1_n));
	card_model card2(.sel_n(sel2_n), .sclk(sclk), .cmd(scmd), .dat(dat2), .ack_n(ack2_n));   // front port 2
	initial begin card2.present = 0; card2.pad_present = 0; end

	// the two files
	reg [7:0] file0[0:131071];
	reg [7:0] file1[0:1535];

	reg rd_req;

	// hps_io stand-in: one 512-byte block per request
	task automatic serve(input integer d);
		integer i;
		reg [31:0] lba;
		begin
			lba = d ? sd_lba1 : sd_lba0;
			@(posedge clk) sd_ack[d] <= 1;
			sd_buff_addr <= 0;
			repeat (4) @(posedge clk);
			for (i = 0; i < 512; i = i + 1) begin
				if (rd_req) begin
					sd_buff_addr <= i;
					sd_buff_dout <= d ? file1[lba*512 + i] : file0[lba*512 + i];
					@(posedge clk) sd_buff_wr <= 1;
					@(posedge clk) sd_buff_wr <= 0;
					repeat (2) @(posedge clk);
				end
				else begin
					sd_buff_addr <= i;
					repeat (3) @(posedge clk);
					if (d) file1[lba*512 + i] = sd_buff_din1; else file0[lba*512 + i] = sd_buff_din0;
				end
			end
			@(posedge clk) sd_ack[d] <= 0;
			repeat (4) @(posedge clk);
		end
	endtask

	always @(posedge clk) begin
		if (!sd_ack[0] && !sd_ack[1]) begin
			if (sd_rd[1] || sd_wr[1]) begin rd_req = sd_rd[1]; serve(1); end
			else if (sd_rd[0] || sd_wr[0]) begin rd_req = sd_rd[0]; serve(0); end
		end
	end

	task mount(input integer d, input integer size);
		begin
			@(posedge clk) begin img_size <= size; img_mounted[d] <= 1; end
			@(posedge clk) img_mounted <= 0;
		end
	endtask

	task wait_done;
		begin
			wait (phase != 0);
			wait (phase == 0);
			repeat (10) @(posedge clk);
		end
	endtask

	integer i, errs, fails;
	integer k;
	task check(input [8*40-1:0] name, input integer cond);
		begin
			if (cond) $display("PASS %0s", name);
			else begin $display("FAIL %0s", name); fails = fails + 1; end
		end
	endtask

	initial begin
		fails = 0;
		// a formatted card full of data
		for (i = 0; i < 131072; i = i + 1) card.mem[i] = $random;
		card.mem[0] = "M"; card.mem[1] = "C";
		for (i = 0; i < 131072; i = i + 1) file0[i] = 8'hEE;
		for (i = 0; i < 1536; i = i + 1) file1[i] = 0;

		repeat (20) @(posedge clk) ;
		reset = 0;
		wait (card_state == 1);
		check("card found and formatted", card_state == 1);

		// 1. SS1 Tool asks for a backup through the job file; one sector needs two retries
		card.flaky_sector = 77; card.flaky_count = 2;
		file1[0] = "S"; file1[1] = "M"; file1[2] = "C"; file1[3] = "Q"; file1[4] = 1;
		file1[8] = 8'hDE; file1[9] = 8'hAD; file1[10] = 8'hBE; file1[11] = 8'hEF;
		mount(1, 1536);
		repeat (20000) @(posedge clk);
		mount(0, 131072);
		wait (n_done > 600);
		repeat (60000) @(posedge clk);
		check("progress in the job file", file1[3] == "P" && file1[25] == 3 && (file1[22] + file1[23]*256) > 500 && file1[512] == 1);
		wait_done();
		errs = 0;
		for (i = 0; i < 131072; i = i + 1) if (file0[i] !== card.mem[i]) errs = errs + 1;
		check("backup file matches the card", errs == 0);
		check("result ok with retries", result == 2);
		check("one sector retried", n_retried == 1 && n_ok == 1023 && n_failed == 0);
		check("report header", file1[0] == "S" && file1[3] == "R" && file1[5] == 1 && file1[6] == 2 && file1[8] == 8'hDE && file1[11] == 8'hEF);
		check("report counts", file1[12] == 8'hFF && file1[13] == 3 && file1[14] == 1 && file1[22] == 0 && file1[23] == 4);
		check("report map", file1[512 + 77] == 2 && file1[512] == 1 && file1[1535] == 1);

		// 2. verify against the file, with one byte changed
		file0[5000] = file0[5000] ^ 8'h01;
		for (i = 0; i < 1536; i = i + 1) file1[i] = 0;
		file1[0] = "S"; file1[1] = "M"; file1[2] = "C"; file1[3] = "Q"; file1[4] = 2;
		mount(1, 1536);
		repeat (20000) @(posedge clk);
		mount(0, 131072);
		wait_done();
		check("verify finds the changed sector", result == 5 && n_differ == 1 && file1[512 + 5000/128] == 4);

		// 3. a dead sector: nothing saved
		for (i = 0; i < 131072; i = i + 1) file0[i] = 8'hEE;
		card.dead_sector = 300;
		cmd_backup <= 1; repeat (3) @(posedge clk); cmd_backup <= 0;
		wait_done();
		check("dead sector fails, file untouched", result == 3 && n_failed == 1 && file0[0] == 8'hEE);

		// 4. same, with save anyway
		opt_save_bad = 1;
		cmd_backup <= 1; repeat (3) @(posedge clk); cmd_backup <= 0;
		wait_done();
		check("save anyway writes the file", result == 8 && file0[0] == "M");
		opt_save_bad = 0; card.dead_sector = -1;

		// 5. card pulled out
		card.present = 0;
		wait (card_state == 0);
		check("card removed noticed", card_state == 0);
		cmd_backup <= 1; repeat (3) @(posedge clk); cmd_backup <= 0;
		repeat (50000) @(posedge clk);
		check("no job without a card", phase == 0);
		card.present = 1;
		wait_done();
		check("job starts when the card goes in", result == 1 || result == 2);

		// 7. SS1 Tool writes a changed image back: only the changed sectors are written,
		//    one write is refused once and retried
		for (i = 0; i < 131072; i = i + 1) file0[i] = card.mem[i];
		for (i = 0; i < 128; i = i + 1) begin file0[128*10 + i] = i; file0[128*700 + i] = ~i; file0[128*1023 + i] = 8'h5A; end
		card.writes = 0; card.bad_write_sector = 700; card.bad_write_count = 1;
		for (i = 0; i < 1536; i = i + 1) file1[i] = 0;   // a fresh job file, like SS1 Tool writes
		file1[0] = "S"; file1[1] = "M"; file1[2] = "C"; file1[3] = "Q"; file1[4] = 3;
		mount(1, 1536);
		repeat (20000) @(posedge clk);
		mount(0, 131072);
		wait_done();
		errs = 0;
		for (i = 0; i < 131072; i = i + 1) if (file0[i] !== card.mem[i]) errs = errs + 1;
		check("write: card now matches the file", errs == 0);
		check("write: only 3 sectors written", card.writes == 3 && dut.n_written == 3 && n_ok == 1021 && n_failed == 0);
		check("write: result and report", result == 9 && file1[3] == "R" && file1[5] == 3 && file1[6] == 9 && file1[28] == 3 && file1[512 + 700] == 5);
		check("write: card file left alone", file0[128*10 + 5] == 5);

		// 8. Yes on a save that's already on the card: SS1 Tool forces its sectors, which match,
		//    to be written anyway (block 1's 64 sectors and its directory frame, sector 1)
		for (i = 0; i < 131072; i = i + 1) file0[i] = card.mem[i];
		for (i = 0; i < 1536; i = i + 1) file1[i] = 0;
		file1[0] = "S"; file1[1] = "M"; file1[2] = "C"; file1[3] = "Q"; file1[4] = 3; file1[6] = 2;
		file1[512 + 1] = 1;
		for (i = 64; i < 128; i = i + 1) file1[512 + i] = 1;
		card.writes = 0; card.bad_write_sector = -1;
		mount(1, 1536);
		repeat (20000) @(posedge clk);
		mount(0, 131072);
		wait (phase == 3);
		check("step 2 shown", dut.step == 2);
		wait_done();
		check("forced: identical sectors written anyway", card.writes == 65 && dut.n_written == 65 && result == 9 && file1[512 + 64] == 5 && file1[512 + 2] == 1);
		check("report says version 4", file1[4] == 4);

		// 9. the next request without forced sectors writes nothing that matches
		file1[0] = "S"; file1[1] = "M"; file1[2] = "C"; file1[3] = "Q"; file1[4] = 3; file1[6] = 0;
		for (i = 512; i < 1536; i = i + 1) file1[i] = 0;
		card.writes = 0;
		mount(1, 1536);
		repeat (20000) @(posedge clk);
		mount(0, 131072);
		wait_done();
		check("forced list cleared by the next request", card.writes == 0 && dut.n_written == 0 && dut.step == 0);

		// 10. controller test, both ports: port 1 a DualShock in analog mode with a card, port 2 a
		// pad that starts digital (switched to analog by the core) and no card; a new job ends it
		for (i = 0; i < 1536; i = i + 1) file1[i] = 0;
		file1[0] = "S"; file1[1] = "M"; file1[2] = "C"; file1[3] = "Q"; file1[4] = 4;
		card.pad_raw = ~16'h4011;      // Cross, Up and Select held
		card.pad_ana = 32'h10203040;   // RX 40 RY 30 LX 20 LY 10
		card2.pad_present = 1; card2.pad_analog = 0;
		card2.pad_raw = ~16'h0108;     // Start and L2
		card2.pad_ana = 32'hA0B0C0D0;
		mount(1, 1536);
		repeat (20000) @(posedge clk);
		mount(0, 131072);
		wait (phase == 7);
		repeat (400000) @(posedge clk);
		check("port 1 controller", dut.pad_on[0] && dut.pad_id[7:0] == 8'h73 && dut.pad_btn[15:0] == 16'h4011 && dut.pad_ana[31:0] == 32'h10203040);
		check("port 2 switched to analog", card2.pad_switches == 1 && card2.pad_analog && !card2.pad_cfg);
		check("port 2 controller", dut.pad_on[1] && dut.pad_id[15:8] == 8'h73 && dut.pad_btn[31:16] == 16'h0108 && dut.pad_ana[63:32] == 32'hA0B0C0D0);
		check("both in the report", file1[3] == "P" && file1[4] == 4 && file1[5] == 4 && file1[32] == 1 && file1[33] == 1 && file1[34] == 8'h73 && file1[35] == 8'h11 && file1[36] == 8'h40 && file1[37] == 8'h40 && file1[40] == 8'h10
		      && file1[48] == 2 && file1[49] == 1 && file1[50] == 8'h73 && file1[51] == 8'h08 && file1[52] == 8'h01 && file1[53] == 8'hD0 && file1[56] == 8'hA0 && file1[59] == 1);
		check("wiring check: nothing on pin 6, tried", file1[67] == 0 && dut.scn != 0);
		check("memory cards: port 1 yes, port 2 no", dut.pad_card == 4'b0001 && file1[42] == 1 && file1[58] == 0);
		// a receiver whose controller pairs late: first refuses analog, later accepts it
		card2.pad_analog = 0; card2.pad_switches = 0; card2.refuse = 1;
		repeat (1000000) @(posedge clk);
		check("still digital: asked again", card2.pad_switches == 0 && dut.sw_cnt >= 3 && dut.pad_id[15:8] == 8'h41);
		card2.refuse = 0;
		repeat (400000) @(posedge clk);
		check("paired later: switched to analog", card2.pad_switches == 1 && dut.pad_id[15:8] == 8'h73);
		card2.pad_switches = 1;
		card2.pad_present = 0;
		repeat (400000) @(posedge clk);
		check("port 2 unplugged, port 1 still read", !dut.pad_on[1] && dut.pad_btn[31:16] == 0 && file1[49] == 0 && dut.pad_on[0] && file1[33] == 1);
		card2.pad_present = 1; card2.pad_analog = 0;
		repeat (400000) @(posedge clk);
		check("plugged back in: switched again", card2.pad_switches == 2 && dut.pad_id[15:8] == 8'h73);
		card2.pad_present = 0;
		card.pad_present = 1;
		for (i = 0; i < 1536; i = i + 1) file1[i] = 0;
		file1[0] = "S"; file1[1] = "M"; file1[2] = "C"; file1[3] = "Q"; file1[4] = 1;
		mount(1, 1536);
		repeat (20000) @(posedge clk);
		mount(0, 131072);
		wait_done();
		check("a new job ends the test, back on port 1", dut.port2 == 0 && result == 1 && file1[5] == 1);

		// 6. wrong file size
		mount(0, 1000);
		repeat (100) @(posedge clk);
		check("wrong size file refused", file_state == 2 && result == 6);

		if (fails) $display("%0d FAILED", fails); else $display("ALL PASSED");
		$finish;
	end

	initial begin #(64'd8000000000); $display("TIMEOUT phase=%0d sector=%0d", phase, cur_sector); $finish; end
endmodule
