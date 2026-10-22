//=============================================================================
// hvu1_bilinear_interp — 2×2 fetch + separable lerp, CSC in / CU out
//=============================================================================
//
// Same port groups as nearest: en, Q16.16 pos, integer tap out, csc_*, cu_*.
// Floor/floor+1 taps, issue order (x0,y0),(x1,y0),(x0,y1),(x1,y1).
// Shared 12×17 lerp, three beats (H top, H bottom, V).
// When en is low: FSM idle.
//
// See: doc/spec/modules/hvu1_resize_pipe.md
//=============================================================================

module hvu1_bilinear_interp (
	input  wire        clk,
	input  wire        rstn,
	input  wire        en,

	input  wire [15:0] src_width,
	input  wire [15:0] src_height,
	input  wire [31:0] pos_x,
	input  wire [31:0] pos_y,
	input  wire        in_valid,
	output wire        in_ready,

	output reg  [15:0] pos_x_int,
	output reg  [15:0] pos_y_int,
	output wire        out_valid,
	input  wire        out_ready,

	input  wire        csc_pvalid,
	output wire        csc_pready,
	input  wire [11:0] csc_r,
	input  wire [11:0] csc_g,
	input  wire [11:0] csc_b,
	input  wire [11:0] csc_a,

	output reg  [11:0] cu_r,
	output reg  [11:0] cu_g,
	output reg  [11:0] cu_b,
	output reg  [11:0] cu_a,
	output wire        cu_pvalid,
	input  wire        cu_pready
);

	localparam IDLE   = 3'd0;
	localparam FETCH  = 3'd1;
	localparam BLEND0 = 3'd2;
	localparam BLEND1 = 3'd3;
	localparam BLEND2 = 3'd4;
	localparam EMIT   = 3'd5;

	reg [2:0]  state;
	reg [2:0]  tap_wr;
	reg [2:0]  tap_rd;

	reg [15:0] x0, x1, y0, y1;
	reg [16:0] wx0, wx1, wy0, wy1;

	reg [11:0] p00_r, p00_g, p00_b, p00_a;
	reg [11:0] p10_r, p10_g, p10_b, p10_a;
	reg [11:0] p01_r, p01_g, p01_b, p01_a;
	reg [11:0] p11_r, p11_g, p11_b, p11_a;

	reg [11:0] h0_r, h0_g, h0_b, h0_a;
	reg [11:0] h1_r, h1_g, h1_b, h1_a;

	function [15:0] clamp_u16;
		input [16:0] val;
		input [15:0] maxv;
		begin
			clamp_u16 = (val > {1'b0, maxv}) ? maxv : val[15:0];
		end
	endfunction

	function [11:0] lerp12;
		input [11:0] p0;
		input [11:0] p1;
		input [16:0] w0;
		input [16:0] w1;
		reg   [29:0] acc;
		begin
			acc    = p0 * w0 + p1 * w1 + 30'd32768;
			lerp12 = (acc[29:16] > 14'h0FFF) ? 12'hFFF : acc[27:16];
		end
	endfunction

	wire [15:0] x_max = (src_width  == 16'd0) ? 16'd0 : (src_width  - 16'd1);
	wire [15:0] y_max = (src_height == 16'd0) ? 16'd0 : (src_height - 16'd1);

	wire [15:0] x0_w = clamp_u16({1'b0, pos_x[31:16]},           x_max);
	wire [15:0] y0_w = clamp_u16({1'b0, pos_y[31:16]},           y_max);
	wire [15:0] x1_w = clamp_u16({1'b0, pos_x[31:16]} + 17'd1,   x_max);
	wire [15:0] y1_w = clamp_u16({1'b0, pos_y[31:16]} + 17'd1,   y_max);

	wire [16:0] wx1_w = {1'b0, pos_x[15:0]};
	wire [16:0] wx0_w = 17'h10000 - wx1_w;
	wire [16:0] wy1_w = {1'b0, pos_y[15:0]};
	wire [16:0] wy0_w = 17'h10000 - wy1_w;

	assign in_ready   = en && (state == IDLE);
	assign out_valid  = en && (state == FETCH) && (tap_wr != 3'd4);
	assign csc_pready = en && (state == FETCH) && (tap_rd != 3'd4);
	assign cu_pvalid  = en && (state == EMIT);

	always @(*) begin
		case (tap_wr[1:0])
			2'd0:    begin pos_x_int = x0; pos_y_int = y0; end
			2'd1:    begin pos_x_int = x1; pos_y_int = y0; end
			2'd2:    begin pos_x_int = x0; pos_y_int = y1; end
			default: begin pos_x_int = x1; pos_y_int = y1; end
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state  <= IDLE;
			tap_wr <= 3'd0;
			tap_rd <= 3'd0;
			x0 <= 16'd0;
			x1 <= 16'd0;
			y0 <= 16'd0;
			y1 <= 16'd0;
			wx0 <= 17'd0;
			wx1 <= 17'd0;
			wy0 <= 17'd0;
			wy1 <= 17'd0;
			p00_r <= 12'd0; p00_g <= 12'd0; p00_b <= 12'd0; p00_a <= 12'd0;
			p10_r <= 12'd0; p10_g <= 12'd0; p10_b <= 12'd0; p10_a <= 12'd0;
			p01_r <= 12'd0; p01_g <= 12'd0; p01_b <= 12'd0; p01_a <= 12'd0;
			p11_r <= 12'd0; p11_g <= 12'd0; p11_b <= 12'd0; p11_a <= 12'd0;
			h0_r <= 12'd0; h0_g <= 12'd0; h0_b <= 12'd0; h0_a <= 12'd0;
			h1_r <= 12'd0; h1_g <= 12'd0; h1_b <= 12'd0; h1_a <= 12'd0;
			cu_r <= 12'd0; cu_g <= 12'd0; cu_b <= 12'd0; cu_a <= 12'd0;
		end else if (!en) begin
			state  <= IDLE;
			tap_wr <= 3'd0;
			tap_rd <= 3'd0;
		end else begin
			case (state)
				IDLE: begin
					if (in_valid) begin
						x0     <= x0_w;
						x1     <= x1_w;
						y0     <= y0_w;
						y1     <= y1_w;
						wx0    <= wx0_w;
						wx1    <= wx1_w;
						wy0    <= wy0_w;
						wy1    <= wy1_w;
						tap_wr <= 3'd0;
						tap_rd <= 3'd0;
						state  <= FETCH;
					end
				end

				FETCH: begin
					if (out_valid && out_ready)
						tap_wr <= tap_wr + 3'd1;
					if (csc_pready && csc_pvalid) begin
						case (tap_rd[1:0])
							2'd0: begin
								p00_r <= csc_r; p00_g <= csc_g;
								p00_b <= csc_b; p00_a <= csc_a;
							end
							2'd1: begin
								p10_r <= csc_r; p10_g <= csc_g;
								p10_b <= csc_b; p10_a <= csc_a;
							end
							2'd2: begin
								p01_r <= csc_r; p01_g <= csc_g;
								p01_b <= csc_b; p01_a <= csc_a;
							end
							default: begin
								p11_r <= csc_r; p11_g <= csc_g;
								p11_b <= csc_b; p11_a <= csc_a;
							end
						endcase
						if (tap_rd == 3'd3)
							state <= BLEND0;
						tap_rd <= tap_rd + 3'd1;
					end
				end

				BLEND0: begin
					h0_r <= lerp12(p00_r, p10_r, wx0, wx1);
					h0_g <= lerp12(p00_g, p10_g, wx0, wx1);
					h0_b <= lerp12(p00_b, p10_b, wx0, wx1);
					h0_a <= lerp12(p00_a, p10_a, wx0, wx1);
					state <= BLEND1;
				end

				BLEND1: begin
					h1_r <= lerp12(p01_r, p11_r, wx0, wx1);
					h1_g <= lerp12(p01_g, p11_g, wx0, wx1);
					h1_b <= lerp12(p01_b, p11_b, wx0, wx1);
					h1_a <= lerp12(p01_a, p11_a, wx0, wx1);
					state <= BLEND2;
				end

				BLEND2: begin
					cu_r  <= lerp12(h0_r, h1_r, wy0, wy1);
					cu_g  <= lerp12(h0_g, h1_g, wy0, wy1);
					cu_b  <= lerp12(h0_b, h1_b, wy0, wy1);
					cu_a  <= lerp12(h0_a, h1_a, wy0, wy1);
					state <= EMIT;
				end

				EMIT: begin
					if (cu_pready)
						state <= IDLE;
				end

				default: state <= IDLE;
			endcase
		end
	end

endmodule
