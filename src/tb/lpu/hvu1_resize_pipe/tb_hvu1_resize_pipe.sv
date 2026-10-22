//=============================================================================
// tb_hvu1_resize_pipe — directed unit bench (no UVM)
// Run via Makefile with +TEST=<name>  (see Makefile TESTS list)
//=============================================================================

`timescale 1ns/1ps

module tb_hvu1_resize_pipe;
	import hvu1_resize_pipe_pkg::*;

	localparam int TIMEOUT = 100000;

	logic        clk;
	logic        rstn = 1'b0;
	logic        start = 1'b0;
	logic        en = 1'b0;
	logic [1:0]  interpolation = 2'b00;
	logic [15:0] src_width = 16'd0;
	logic [15:0] src_height = 16'd0;
	logic [15:0] dst_width = 16'd0;
	logic [15:0] dst_height = 16'd0;
	logic        frame_done;

	logic [15:0] pos_x;
	logic [15:0] pos_y;
	logic        pixel_req_valid;
	logic        pixel_req_ready;

	logic        csc_pvalid;
	logic        csc_pready;
	logic [11:0] csc_r, csc_g, csc_b, csc_a;

	logic [11:0] cu_r, cu_g, cu_b, cu_a;
	logic        cu_pvalid;
	logic        cu_pready;
	logic        dst_last;
	logic        dst_eol;

	hvu1_resize_pipe dut (
		.clk             (clk),
		.rstn            (rstn),
		.start           (start),
		.en              (en),
		.interpolation   (interpolation),
		.src_width       (src_width),
		.src_height      (src_height),
		.dst_width       (dst_width),
		.dst_height      (dst_height),
		.frame_done      (frame_done),
		.pos_x           (pos_x),
		.pos_y           (pos_y),
		.pixel_req_valid (pixel_req_valid),
		.pixel_req_ready (pixel_req_ready),
		.csc_pvalid      (csc_pvalid),
		.csc_pready      (csc_pready),
		.csc_r           (csc_r),
		.csc_g           (csc_g),
		.csc_b           (csc_b),
		.csc_a           (csc_a),
		.cu_r            (cu_r),
		.cu_g            (cu_g),
		.cu_b            (cu_b),
		.cu_a            (cu_a),
		.cu_pvalid       (cu_pvalid),
		.cu_pready       (cu_pready),
		.dst_last        (dst_last),
		.dst_eol         (dst_eol)
	);

	// ---- clock ----
	initial clk = 1'b0;
	always #5 clk = ~clk;

	// ---- config / scoreboard ----
	px_t      src_mem[HMAX][WMAX];
	cu_beat_t exp_q[$];

	int err_cnt;
	int cu_cnt;
	int fetch_cnt;
	int taps_since_cu;
	int expect_taps;
	int cfg_sw, cfg_sh, cfg_dw, cfg_dh;
	logic cfg_en;
	logic [1:0] cfg_interp;
	bit   check_cu;
	bit   check_fetch_range;
	bit   check_tap_budget;
	bit   check_bypass_pos;
	bit   check_tap_order;
	int   stall_plus;
	bit   stall_req;
	bit   stall_csc;
	bit   stall_cu;
	int   csc_delay;
	int   dest_idx;
	pos_t dest_taps_got[$];

	typedef struct {
		pos_t p;
		int   due;
	} csc_item_t;
	csc_item_t csc_q[$];
	int cycle;

	function automatic string px_s(px_t p);
		return $sformatf("r=%0h g=%0h b=%0h a=%0h", p.r, p.g, p.b, p.a);
	endfunction

	task automatic fail(string msg);
		err_cnt++;
		$error("%0t %s", $time, msg);
	endtask

	// ---- reset / start ----
	task automatic do_reset();
		rstn            <= 1'b0;
		start           <= 1'b0;
		en              <= 1'b0;
		interpolation   <= 2'b00;
		src_width       <= 16'd0;
		src_height      <= 16'd0;
		dst_width       <= 16'd0;
		dst_height      <= 16'd0;
		check_cu          = 1'b0;
		check_fetch_range = 1'b0;
		check_tap_budget  = 1'b0;
		check_bypass_pos  = 1'b0;
		check_tap_order   = 1'b0;
		exp_q.delete();
		csc_q.delete();
		dest_taps_got.delete();
		cu_cnt          = 0;
		fetch_cnt       = 0;
		taps_since_cu   = 0;
		expect_taps     = 1;
		dest_idx        = 0;
		repeat (5) @(posedge clk);
		rstn <= 1'b1;
		repeat (2) @(posedge clk);
	endtask

	task automatic start_frame(
		input logic       en_i,
		input logic [1:0] interp_i,
		input int         sw,
		input int         sh,
		input int         dw,
		input int         dh
	);
		cfg_en     = en_i;
		cfg_interp = interp_i;
		cfg_sw     = sw;
		cfg_sh     = sh;
		cfg_dw     = dw;
		cfg_dh     = dh;
		expect_taps = is_bilinear(en_i, interp_i) ? 4 : 1;
		@(negedge clk);
		en            <= en_i;
		interpolation <= interp_i;
		src_width     <= 16'(sw);
		src_height    <= 16'(sh);
		dst_width     <= 16'(dw);
		dst_height    <= 16'(dh);
		start         <= 1'b1;
		@(negedge clk);
		start <= 1'b0;
	endtask

	task automatic pulse_start_pins(
		input logic       en_i,
		input logic [1:0] interp_i,
		input int         sw,
		input int         sh,
		input int         dw,
		input int         dh
	);
		@(negedge clk);
		en            <= en_i;
		interpolation <= interp_i;
		src_width     <= 16'(sw);
		src_height    <= 16'(sh);
		dst_width     <= 16'(dw);
		dst_height    <= 16'(dh);
		start         <= 1'b1;
		@(negedge clk);
		start <= 1'b0;
	endtask

	task automatic arm_expect(
		input logic       en_i,
		input logic [1:0] interp_i,
		input int         sw,
		input int         sh,
		input int         dw,
		input int         dh
	);
		fill_src(src_mem, sw, sh);
		expect_frame(en_i, interp_i, sw, sh, dw, dh, src_mem, exp_q);
		cu_cnt         = 0;
		fetch_cnt      = 0;
		taps_since_cu  = 0;
		dest_idx       = 0;
		dest_taps_got.delete();
		check_cu          = 1'b1;
		check_fetch_range = 1'b1;
		check_tap_budget  = 1'b1;
	endtask

	task automatic wait_frame_done(input int to = TIMEOUT);
		int i;
		bit seen;
		seen = 1'b0;
		for (i = 0; i < to; i++) begin
			@(posedge clk);
			if (frame_done) begin
				seen = 1'b1;
				@(posedge clk);
				if (frame_done)
					fail("frame_done held more than one cycle");
				break;
			end
		end
		if (!seen)
			fail($sformatf("timeout waiting for frame_done (%0d cycles)", to));
	endtask

	task automatic wait_cycles(input int n);
		repeat (n) @(posedge clk);
	endtask

	task automatic finish_frame_checks(input int dw, input int dh);
		wait_frame_done();
		wait_cycles(2);
		if (cu_cnt != dw * dh)
			fail($sformatf("CU count %0d != %0d", cu_cnt, dw * dh));
		if (exp_q.size() != 0)
			fail($sformatf("%0d expected CU beats leftover", exp_q.size()));
		if (taps_since_cu != 0)
			fail($sformatf("taps_since_cu leftover %0d", taps_since_cu));
	endtask

	task automatic run_frame(
		input logic       en_i,
		input logic [1:0] interp_i,
		input int         sw,
		input int         sh,
		input int         dw,
		input int         dh
	);
		arm_expect(en_i, interp_i, sw, sh, dw, dh);
		start_frame(en_i, interp_i, sw, sh, dw, dh);
		finish_frame_checks(dw, dh);
	endtask

	// ---- cycle counter ----
	always_ff @(posedge clk or negedge rstn) begin
		if (!rstn)
			cycle <= 0;
		else
			cycle <= cycle + 1;
	end

	// ---- fetch ready stall ----
	always_ff @(posedge clk or negedge rstn) begin
		if (!rstn)
			pixel_req_ready <= 1'b1;
		else if (stall_req) begin
			if (stall_plus)
				pixel_req_ready <= $urandom_range(0, 1);
			else
				pixel_req_ready <= ~pixel_req_ready;
		end else
			pixel_req_ready <= 1'b1;
	end

	// ---- CU ready stall ----
	logic        cu_hold_valid;
	logic        cu_hold_eol, cu_hold_last;
	logic [11:0] cu_hold_r, cu_hold_g, cu_hold_b, cu_hold_a;

	always_ff @(posedge clk or negedge rstn) begin
		if (!rstn)
			cu_pready <= 1'b1;
		else if (stall_cu) begin
			if (stall_plus)
				cu_pready <= $urandom_range(0, 1);
			else
				cu_pready <= ~cu_pready;
		end else
			cu_pready <= 1'b1;
	end

	always_ff @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			cu_hold_valid <= 1'b0;
		end else if (cu_pvalid && !cu_pready) begin
			if (cu_hold_valid) begin
				if (cu_hold_eol != dst_eol || cu_hold_last != dst_last ||
				    cu_hold_r != cu_r || cu_hold_g != cu_g ||
				    cu_hold_b != cu_b || cu_hold_a != cu_a)
					fail("CU beat changed while cu_pready=0");
			end
			cu_hold_valid <= 1'b1;
			cu_hold_eol   <= dst_eol;
			cu_hold_last  <= dst_last;
			cu_hold_r     <= cu_r;
			cu_hold_g     <= cu_g;
			cu_hold_b     <= cu_b;
			cu_hold_a     <= cu_a;
		end else if (cu_pvalid && cu_pready) begin
			cu_hold_valid <= 1'b0;
		end
	end

	// ---- fetch capture + CSC queue ----
	always_ff @(posedge clk) begin
		if (rstn && pixel_req_valid && pixel_req_ready) begin
			pos_t fp;
			fp.x = pos_x;
			fp.y = pos_y;
			fetch_cnt++;
			taps_since_cu++;
			if (check_fetch_range) begin
				if (pos_x >= 16'(cfg_sw) || pos_y >= 16'(cfg_sh))
					fail($sformatf("fetch out of range (%0d,%0d) src=%0dx%0d",
					               pos_x, pos_y, cfg_sw, cfg_sh));
			end
			if (check_tap_budget && taps_since_cu > expect_taps)
				fail($sformatf("taps_since_cu=%0d > expect_taps=%0d (next dest before CU?)",
				               taps_since_cu, expect_taps));
			if (check_bypass_pos) begin
				int dx, dy;
				dy = (fetch_cnt - 1) / cfg_dw;
				dx = (fetch_cnt - 1) % cfg_dw;
				if (pos_x != 16'(dx) || pos_y != 16'(dy))
					fail($sformatf("bypass pos (%0d,%0d) != dest (%0d,%0d)",
					               pos_x, pos_y, dx, dy));
			end
			if (check_tap_order)
				dest_taps_got.push_back(fp);
			csc_q.push_back('{p: fp, due: cycle + csc_delay});
		end
	end

	// ---- CSC responder (in-order) ----
	always_ff @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			csc_pvalid <= 1'b0;
			csc_r      <= 12'd0;
			csc_g      <= 12'd0;
			csc_b      <= 12'd0;
			csc_a      <= 12'd0;
		end else begin
			if (csc_pvalid && csc_pready && (csc_q.size() != 0))
				csc_q.pop_front();
			if (csc_q.size() != 0 && (cycle >= csc_q[0].due)) begin
				px_t pix;
				pix        = src_mem[csc_q[0].p.y][csc_q[0].p.x];
				csc_r      <= pix.r;
				csc_g      <= pix.g;
				csc_b      <= pix.b;
				csc_a      <= pix.a;
				csc_pvalid <= 1'b1;
			end else if (csc_pvalid && !csc_pready) begin
				csc_pvalid <= 1'b1;
			end else begin
				csc_pvalid <= 1'b0;
			end
		end
	end

	// ---- CU checker ----
	always_ff @(posedge clk) begin
		if (rstn && cu_pvalid && cu_pready) begin
			cu_beat_t e;
			px_t got;
			got = '{r: cu_r, g: cu_g, b: cu_b, a: cu_a};
			cu_cnt++;
			if (check_tap_budget && taps_since_cu != expect_taps)
				fail($sformatf("CU with taps_since_cu=%0d expect %0d",
				               taps_since_cu, expect_taps));
			if (check_tap_order) begin
				pos_t want[4];
				logic [31:0] sx, sy, rw, rh;
				int dx, dy, k;
				dy = dest_idx / cfg_dw;
				dx = dest_idx % cfg_dw;
				rw = cfg_en ? q_ratio(cfg_sw, cfg_dw) : 32'd0;
				rh = cfg_en ? q_ratio(cfg_sh, cfg_dh) : 32'd0;
				sx = map_src(cfg_en, 16'(dx), rw);
				sy = map_src(cfg_en, 16'(dy), rh);
				bilinear_taps(sx, sy, cfg_sw, cfg_sh, want);
				if (dest_taps_got.size() != 4)
					fail($sformatf("dest %0d got %0d taps, expected 4",
					               dest_idx, dest_taps_got.size()));
				else begin
					for (k = 0; k < 4; k++) begin
						if (dest_taps_got[k].x != want[k].x ||
						    dest_taps_got[k].y != want[k].y)
							fail($sformatf("dest %0d tap%0d got (%0d,%0d) want (%0d,%0d)",
							               dest_idx, k,
							               dest_taps_got[k].x, dest_taps_got[k].y,
							               want[k].x, want[k].y));
					end
				end
				dest_taps_got.delete();
			end
			taps_since_cu = 0;
			dest_idx++;
			if (check_cu) begin
				if (exp_q.size() == 0)
					fail("unexpected CU beat (golden queue empty)");
				else begin
					e = exp_q.pop_front();
					if (got !== e.px)
						fail($sformatf("CU pixel mismatch got %s want %s",
						               px_s(got), px_s(e.px)));
					if (dst_eol !== e.eol)
						fail($sformatf("dst_eol=%0b want %0b at pixel %0d",
						               dst_eol, e.eol, cu_cnt));
					if (dst_last !== e.last)
						fail($sformatf("dst_last=%0b want %0b at pixel %0d",
						               dst_last, e.last, cu_cnt));
				end
			end
		end
	end

	// ---- stall knobs ----
	task automatic set_stalls(input bit req, input bit csc, input bit cu);
		stall_req = req;
		stall_csc = csc;
		stall_cu  = cu;
		if (csc)
			csc_delay = stall_plus ? $urandom_range(2, 8) : 4;
		else
			csc_delay = 1;
	endtask

	// ---- tests ----
	task automatic t_reset_idle();
		do_reset();
		if (pixel_req_valid)
			fail("pixel_req_valid after reset");
		if (cu_pvalid)
			fail("cu_pvalid after reset");
		if (csc_pready)
			fail("csc_pready after reset");
		if (frame_done)
			fail("frame_done after reset");
		wait_cycles(10);
		if (pixel_req_valid || cu_pvalid || frame_done)
			fail("activity while idle with no start");
	endtask

	task automatic t_start_illegal_zero_dst();
		do_reset();
		check_cu = 1'b0;
		start_frame(1'b1, 2'b00, 4, 4, 0, 4);
		wait_cycles(40);
		if (pixel_req_valid)
			fail("fetch after start with dst_width=0");
		if (frame_done)
			fail("frame_done after illegal start (width)");
		start_frame(1'b1, 2'b00, 4, 4, 4, 0);
		wait_cycles(40);
		if (pixel_req_valid)
			fail("fetch after start with dst_height=0");
		if (frame_done)
			fail("frame_done after illegal start (height)");
	endtask

	task automatic t_start_ignored_busy();
		do_reset();
		arm_expect(1'b0, 2'b00, 3, 2, 3, 2);
		check_bypass_pos = 1'b1;
		start_frame(1'b0, 2'b00, 3, 2, 3, 2);
		while (cu_cnt < 2)
			@(posedge clk);
		pulse_start_pins(1'b1, 2'b01, 1, 1, 1, 1);
		finish_frame_checks(3, 2);
	endtask

	task automatic t_two_frames();
		do_reset();
		run_frame(1'b0, 2'b00, 2, 2, 2, 2);
		run_frame(1'b1, 2'b00, 2, 2, 4, 4);
	endtask

	task automatic t_bypass_2x2();
		do_reset();
		check_bypass_pos = 1'b1;
		run_frame(1'b0, 2'b00, 2, 2, 2, 2);
	endtask

	task automatic t_bypass_1x1();
		do_reset();
		check_bypass_pos = 1'b1;
		run_frame(1'b0, 2'b00, 1, 1, 1, 1);
	endtask

	task automatic t_bypass_eol_last();
		do_reset();
		check_bypass_pos = 1'b1;
		run_frame(1'b0, 2'b00, 3, 2, 3, 2);
	endtask

	task automatic t_near_identity();
		do_reset();
		run_frame(1'b1, 2'b00, 4, 4, 4, 4);
	endtask

	task automatic t_near_upscale_2to4();
		do_reset();
		run_frame(1'b1, 2'b00, 2, 2, 4, 4);
	endtask

	task automatic t_near_downscale();
		do_reset();
		run_frame(1'b1, 2'b00, 4, 4, 2, 2);
	endtask

	task automatic t_near_round_half_up();
		logic [31:0] sx;
		do_reset();
		run_frame(1'b1, 2'b00, 2, 2, 4, 4);
		sx = map_src(1'b1, 16'd1, q_ratio(2, 4));
		if (sx[15:0] != 16'h8000)
			fail($sformatf("T23 ratio frac expected 0x8000 got %h", sx));
		if (nearest_round(sx) != 16'd1)
			fail("T23 round-half-up did not yield 1");
	endtask

	task automatic t_near_clamp_edge();
		logic [31:0] sx;
		logic [15:0] fx;
		do_reset();
		run_frame(1'b1, 2'b00, 2, 2, 4, 4);
		sx = map_src(1'b1, 16'd3, q_ratio(2, 4));
		fx = nearest_fetch(sx, 2);
		if (nearest_round(sx) <= 16'd1)
			fail("T24 expected unclamped round past src_width-1");
		if (fx != 16'd1)
			fail($sformatf("T24 clamp got %0d want 1", fx));
	endtask

	task automatic t_near_reserved_interp();
		do_reset();
		run_frame(1'b1, 2'b10, 2, 2, 4, 4);
		run_frame(1'b1, 2'b11, 4, 4, 2, 2);
	endtask

	task automatic t_bilin_2x2_to_4x4();
		do_reset();
		check_tap_order = 1'b1;
		run_frame(1'b1, 2'b01, 2, 2, 4, 4);
	endtask

	task automatic t_bilin_identity_frac0();
		do_reset();
		run_frame(1'b1, 2'b01, 4, 4, 4, 4);
	endtask

	task automatic t_bilin_edge_dup_taps();
		do_reset();
		check_tap_order = 1'b1;
		run_frame(1'b1, 2'b01, 2, 2, 4, 4);
	endtask

	task automatic t_bilin_alpha();
		do_reset();
		run_frame(1'b1, 2'b01, 3, 3, 5, 4);
	endtask

	task automatic t_stall_fetch();
		do_reset();
		set_stalls(1'b1, 1'b0, 1'b0);
		run_frame(1'b1, 2'b00, 2, 2, 4, 4);
		set_stalls(1'b0, 1'b0, 1'b0);
	endtask

	task automatic t_stall_csc();
		do_reset();
		set_stalls(1'b0, 1'b1, 1'b0);
		run_frame(1'b1, 2'b01, 2, 2, 4, 4);
		set_stalls(1'b0, 1'b0, 1'b0);
	endtask

	task automatic t_stall_cu();
		do_reset();
		set_stalls(1'b0, 1'b0, 1'b1);
		run_frame(1'b1, 2'b00, 3, 2, 3, 2);
		set_stalls(1'b0, 1'b0, 1'b0);
	endtask

	task automatic t_stall_all();
		do_reset();
		set_stalls(1'b1, 1'b1, 1'b1);
		run_frame(1'b1, 2'b01, 2, 2, 3, 3);
		set_stalls(1'b0, 1'b0, 1'b0);
	endtask

	task automatic t_idle_interp_quiet();
		do_reset();
		run_frame(1'b1, 2'b00, 4, 4, 4, 4);
		if (fetch_cnt != 16)
			fail($sformatf("nearest fetch_cnt=%0d want 16 (1 tap/pixel)", fetch_cnt));
		run_frame(1'b1, 2'b01, 2, 2, 4, 4);
		if (fetch_cnt != 64)
			fail($sformatf("bilinear fetch_cnt=%0d want 64 (4 taps/pixel)", fetch_cnt));
	endtask

	// ---- plusargs / main ----
	string test_name;
	int    stall_i;

	initial begin
		stall_plus = 0;
		stall_req  = 0;
		stall_csc  = 0;
		stall_cu   = 0;
		csc_delay  = 1;
		err_cnt    = 0;
		if (!$value$plusargs("TEST=%s", test_name))
			test_name = "bypass";
		if ($value$plusargs("STALL=%d", stall_i))
			stall_plus = (stall_i != 0);
		$display("TEST=%s STALL=%0d", test_name, stall_plus);
		void'($urandom(32'hC0FFEE));

		if (test_name == "bypass")
			test_name = "bypass_2x2";

		case (test_name)
			"reset_idle":             t_reset_idle();
			"start_illegal_zero_dst": t_start_illegal_zero_dst();
			"start_ignored_busy":     t_start_ignored_busy();
			"two_frames":             t_two_frames();
			"bypass_2x2":             t_bypass_2x2();
			"bypass_1x1":             t_bypass_1x1();
			"bypass_eol_last":        t_bypass_eol_last();
			"near_identity":          t_near_identity();
			"near_upscale_2to4":      t_near_upscale_2to4();
			"near_downscale":         t_near_downscale();
			"near_round_half_up":     t_near_round_half_up();
			"near_clamp_edge":        t_near_clamp_edge();
			"near_reserved_interp":   t_near_reserved_interp();
			"bilin_2x2_to_4x4":       t_bilin_2x2_to_4x4();
			"bilin_identity_frac0":   t_bilin_identity_frac0();
			"bilin_edge_dup_taps":    t_bilin_edge_dup_taps();
			"bilin_alpha":            t_bilin_alpha();
			"stall_fetch":            t_stall_fetch();
			"stall_csc":              t_stall_csc();
			"stall_cu":               t_stall_cu();
			"stall_all":              t_stall_all();
			"idle_interp_quiet":      t_idle_interp_quiet();
			default: $fatal(1, "unknown TEST=%s", test_name);
		endcase

		wait_cycles(4);
		if (err_cnt != 0)
			$fatal(1, "FAILED TEST=%s errors=%0d", test_name, err_cnt);
		$display("PASSED TEST=%s", test_name);
		$finish;
	end

	initial begin
		#(TIMEOUT * 10ns * 2);
		$fatal(1, "global watchdog timeout");
	end

endmodule
