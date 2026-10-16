// Renders one frame of the screen to sim/frame_<n>.ppm with made-up status values.
`timescale 1ns/1ns
module tb_screen;
	reg clk = 0; always #25 clk = ~clk;
	reg [2:0] map[0:1023];
	reg [9:0] map_addr_q;
	wire [9:0] map_addr;
	reg  [2:0] map_data;
	always @(posedge clk) map_data <= map[map_addr];
	wire ce, hb, vb, hs, vs; wire [7:0] r, g, b;
	reg [2:0] phase, job; reg [1:0] cs, fs; reg [3:0] result; reg tool;
	reg [9:0] cur; reg [10:0] nd, nok, nre, nfa, ndi, nwr;
	reg [1:0] pon = 0; reg [15:0] pid = 0; reg [31:0] pbtn = 0; reg [63:0] pana = 0; reg [3:0] pcard = 0;
	screen dut(.clk(clk), .reset(1'b0), .phase(phase), .job(job), .result(result), .card_state(cs),
		.file_state(fs), .from_tool(tool), .step(2'd0), .port2(1'b0), .pad_on(pon), .pad_id(pid), .pad_btn(pbtn), .pad_ana(pana), .pad_card(pcard), .wdiag(40'h0001100818), .cur_sector(cur), .n_done(nd), .n_ok(nok), .n_retried(nre),
		.n_failed(nfa), .n_differ(ndi), .n_written(nwr), .map_addr(map_addr), .map_data(map_data),
		.ce_pix(ce), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs), .r(r), .g(g), .b(b));
	integer f, i, x, y, scene;
	initial begin
		if (!$value$plusargs("scene=%d", scene)) scene = 0;
		for (i = 0; i < 1024; i = i + 1) map[i] = 0;
		if (scene == 0) begin   // reading, 60%
			phase = 3; job = 1; result = 0; cs = 1; fs = 1; tool = 1; cur = 612;
			for (i = 0; i < 612; i = i + 1) map[i] = 1;
			map[77] = 2; map[300] = 2; map[301] = 3;
			nd = 612; nok = 609; nre = 2; nfa = 1; ndi = 0;
			nwr = 0;
		end else if (scene == 2) begin   // writing
			phase = 3; job = 3; result = 0; cs = 1; fs = 1; tool = 1; cur = 300;
			for (i = 0; i < 300; i = i + 1) map[i] = 1;
			map[1] = 5; map[64] = 5; map[65] = 5;
			nd = 300; nok = 297; nre = 0; nfa = 0; ndi = 0; nwr = 3;
		end else if (scene == 3) begin   // controller test: port 1 DualShock, port 2 digital pad
			phase = 7; job = 4; result = 0; cs = 1; fs = 1; tool = 1; cur = 0;
			nd = 0; nok = 0; nre = 0; nfa = 0; ndi = 0; nwr = 0;
			pon = 2'b11; pid = 16'h4173; pbtn = {16'h0008, 16'h4011}; pana = {32'h80808080, 32'h10FF8040}; pcard = 4'b0001;
		end else begin          // done
			phase = 0; job = 1; result = 2; cs = 1; fs = 1; tool = 1; cur = 1023;
			for (i = 0; i < 1024; i = i + 1) map[i] = 1;
			map[77] = 2;
			nd = 1024; nok = 1023; nre = 1; nfa = 0; ndi = 0; nwr = 0;
		end
		// wait for the start of a frame
		wait (vb); wait (!vb);
		f = $fopen($sformatf("frame_%0d.ppm", scene), "w");
		$fwrite(f, "P3\n512 240\n255\n");
		for (y = 0; y < 240; y = y + 1) begin
			x = 0;
			while (x < 512) begin
				@(posedge clk);
				if (ce && !hb && dut.hc >= 9 && dut.hc < 9 + 512) begin
					$fwrite(f, "%0d %0d %0d\n", r, g, b); x = x + 1;
				end
			end
			wait (hb);
			wait (!hb);
		end
		$fclose(f);
		$finish;
	end
endmodule
