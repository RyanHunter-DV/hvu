//=============================================================================
// Golden model and types for hvu1_resize_pipe unit tests
// Matches doc/spec/modules/hvu1_resize_pipe.md
//=============================================================================

package hvu1_resize_pipe_pkg;

	parameter int WMAX = 16;
	parameter int HMAX = 16;

	typedef struct packed {
		logic [11:0] r;
		logic [11:0] g;
		logic [11:0] b;
		logic [11:0] a;
	} px_t;

	typedef struct packed {
		px_t  px;
		logic eol;
		logic last;
	} cu_beat_t;

	typedef struct packed {
		logic [15:0] x;
		logic [15:0] y;
	} pos_t;

	function automatic logic [15:0] clamp_to_max(
		input logic [15:0] val,
		input int          dim
	);
		logic [15:0] maxv;
		if (dim <= 0)
			return 16'd0;
		maxv = 16'(dim - 1);
		return (val > maxv) ? maxv : val;
	endfunction

	function automatic logic [31:0] q_ratio(
		input int src_dim,
		input int dst_dim
	);
		logic [31:0] src_q;
		if (dst_dim == 0)
			return 32'd0;
		src_q = {16'(src_dim), 16'd0};
		return src_q / 32'(dst_dim);
	endfunction

	function automatic logic [31:0] map_src(
		input logic        en,
		input logic [15:0] dst,
		input logic [31:0] ratio
	);
		logic [47:0] prod;
		if (!en)
			return {dst, 16'd0};
		prod = 48'(dst) * 48'(ratio);
		return prod[31:0];
	endfunction

	function automatic logic [15:0] nearest_round(
		input logic [31:0] pos_q
	);
		logic [16:0] rnd;
		rnd = {1'b0, pos_q[31:16]} + pos_q[15];
		return rnd[16] ? 16'hFFFF : rnd[15:0];
	endfunction

	function automatic logic [15:0] nearest_fetch(
		input logic [31:0] pos_q,
		input int          dim
	);
		return clamp_to_max(nearest_round(pos_q), dim);
	endfunction

	function automatic logic [11:0] lerp12(
		input logic [11:0] p0,
		input logic [11:0] p1,
		input logic [16:0] w0,
		input logic [16:0] w1
	);
		logic [29:0] acc;
		acc = 30'(p0) * 30'(w0) + 30'(p1) * 30'(w1) + 30'd32768;
		if (acc[29:16] > 14'h0FFF)
			return 12'hFFF;
		return acc[27:16];
	endfunction

	function automatic px_t lerp_px(
		input px_t         p0,
		input px_t         p1,
		input logic [16:0] w0,
		input logic [16:0] w1
	);
		px_t o;
		o.r = lerp12(p0.r, p1.r, w0, w1);
		o.g = lerp12(p0.g, p1.g, w0, w1);
		o.b = lerp12(p0.b, p1.b, w0, w1);
		o.a = lerp12(p0.a, p1.a, w0, w1);
		return o;
	endfunction

	function automatic px_t src_at(
		input px_t src[HMAX][WMAX],
		input int  x,
		input int  y
	);
		return src[y][x];
	endfunction

	function automatic void bilinear_taps(
		input  logic [31:0] sx,
		input  logic [31:0] sy,
		input  int          sw,
		input  int          sh,
		output pos_t        taps[4]
	);
		logic [15:0] x0, x1, y0, y1;
		x0 = clamp_to_max(sx[31:16], sw);
		y0 = clamp_to_max(sy[31:16], sh);
		x1 = clamp_to_max(sx[31:16] + 16'd1, sw);
		y1 = clamp_to_max(sy[31:16] + 16'd1, sh);
		taps[0] = '{x: x0, y: y0};
		taps[1] = '{x: x1, y: y0};
		taps[2] = '{x: x0, y: y1};
		taps[3] = '{x: x1, y: y1};
	endfunction

	function automatic px_t bilinear_sample(
		input logic [31:0] sx,
		input logic [31:0] sy,
		input int          sw,
		input int          sh,
		input px_t         src[HMAX][WMAX]
	);
		pos_t        taps[4];
		logic [16:0] wx0, wx1, wy0, wy1;
		px_t         p00, p10, p01, p11, h0, h1;
		bilinear_taps(sx, sy, sw, sh, taps);
		wx1 = {1'b0, sx[15:0]};
		wx0 = 17'h10000 - wx1;
		wy1 = {1'b0, sy[15:0]};
		wy0 = 17'h10000 - wy1;
		p00 = src_at(src, taps[0].x, taps[0].y);
		p10 = src_at(src, taps[1].x, taps[1].y);
		p01 = src_at(src, taps[2].x, taps[2].y);
		p11 = src_at(src, taps[3].x, taps[3].y);
		h0  = lerp_px(p00, p10, wx0, wx1);
		h1  = lerp_px(p01, p11, wx0, wx1);
		return lerp_px(h0, h1, wy0, wy1);
	endfunction

	function automatic logic is_bilinear(
		input logic       en,
		input logic [1:0] interpolation
	);
		return en && (interpolation == 2'b01);
	endfunction

	function automatic px_t gold_pixel(
		input logic        en,
		input logic [1:0]  interpolation,
		input int          sw,
		input int          sh,
		input int          dw,
		input int          dh,
		input int          dst_x,
		input int          dst_y,
		input px_t         src[HMAX][WMAX]
	);
		logic [31:0] ratio_w, ratio_h, sx, sy;
		logic [15:0] fx, fy;
		ratio_w = en ? q_ratio(sw, dw) : 32'd0;
		ratio_h = en ? q_ratio(sh, dh) : 32'd0;
		sx = map_src(en, 16'(dst_x), ratio_w);
		sy = map_src(en, 16'(dst_y), ratio_h);
		if (is_bilinear(en, interpolation))
			return bilinear_sample(sx, sy, sw, sh, src);
		fx = nearest_fetch(sx, sw);
		fy = nearest_fetch(sy, sh);
		return src_at(src, fx, fy);
	endfunction

	function automatic void expect_frame(
		input logic       en,
		input logic [1:0] interpolation,
		input int         sw,
		input int         sh,
		input int         dw,
		input int         dh,
		input px_t        src[HMAX][WMAX],
		ref   cu_beat_t   beats[$]
	);
		int x, y;
		cu_beat_t b;
		beats.delete();
		for (y = 0; y < dh; y++) begin
			for (x = 0; x < dw; x++) begin
				b.px   = gold_pixel(en, interpolation, sw, sh, dw, dh, x, y, src);
				b.eol  = (x == (dw - 1));
				b.last = (x == (dw - 1)) && (y == (dh - 1));
				beats.push_back(b);
			end
		end
	endfunction

	function automatic void fill_src(
		ref  px_t src[HMAX][WMAX],
		input int sw,
		input int sh
	);
		int x, y;
		for (y = 0; y < HMAX; y++) begin
			for (x = 0; x < WMAX; x++) begin
				src[y][x].r = 12'(x);
				src[y][x].g = 12'(y);
				src[y][x].b = 12'(x ^ y);
				src[y][x].a = 12'(12'h200 + x * 3 + y * 11);
			end
		end
		if (sw < 0 || sh < 0)
			return;
	endfunction

endpackage
