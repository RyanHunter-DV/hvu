//=============================================================================
// hvu1_rot_flip_pipe — Map (pos_x, pos_y) through rotate then flip
//=============================================================================
//
// Input sample (pos_x, pos_y) is in the rotated-then-flipped image.
// Output (src_x, src_y) is the original buffer coordinate.
//
// Flip on the input (rotated) raster, then rotation to original:
//   ox' = hflip ? (out_w-1 - pos_x) : pos_x
//   oy' = vflip ? (out_h-1 - pos_y) : pos_y
//   rot=00 (  0°):  (src_x, src_y) = (ox',           oy')
//   rot=01 ( 90°):  (src_x, src_y) = (oy',           H-1-ox')
//   rot=10 (180°):  (src_x, src_y) = (W-1-ox',       H-1-oy')
//   rot=11 (270°):  (src_x, src_y) = (W-1-oy',       ox')
//
// 90°/270°: out_w = H, out_h = W.  Otherwise out_w = W, out_h = H.
//
// in_valid/in_ready and out_valid/out_ready; one mapped position per cycle
// when both sides transfer. One-cycle latency through the output register.
//
// See: doc/spec/hvu1_layer_unit.md
//=============================================================================

module hvu1_rot_flip_pipe (
	input  wire        clk,
	input  wire        rst_n,

	input  wire [15:0] img_width,
	input  wire [15:0] img_height,
	input  wire [1:0]  rot,
	input  wire        hflip,
	input  wire        vflip,

	input  wire [15:0] pos_x,
	input  wire [15:0] pos_y,
	input  wire        in_valid,
	output wire        in_ready,

	output reg  [15:0] src_x,
	output reg  [15:0] src_y,
	output reg         out_valid,
	input  wire        out_ready
);

	wire        rot_swap = (rot == 2'b01) || (rot == 2'b11);
	wire [15:0] out_w    = rot_swap ? img_height : img_width;
	wire [15:0] out_h    = rot_swap ? img_width  : img_height;

	wire [15:0] ox = hflip ? (out_w - 16'd1 - pos_x) : pos_x;
	wire [15:0] oy = vflip ? (out_h - 16'd1 - pos_y) : pos_y;

	reg [15:0] map_x;
	reg [15:0] map_y;

	always @(*) begin
		case (rot)
			2'b00: begin
				map_x = ox;
				map_y = oy;
			end
			2'b01: begin
				map_x = oy;
				map_y = img_height - 16'd1 - ox;
			end
			2'b10: begin
				map_x = img_width  - 16'd1 - ox;
				map_y = img_height - 16'd1 - oy;
			end
			default: begin
				map_x = img_width  - 16'd1 - oy;
				map_y = ox;
			end
		endcase
	end

	assign in_ready = !out_valid || out_ready;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			src_x     <= 16'd0;
			src_y     <= 16'd0;
			out_valid <= 1'b0;
		end else if (in_valid && in_ready) begin
			src_x     <= map_x;
			src_y     <= map_y;
			out_valid <= 1'b1;
		end else if (out_valid && out_ready) begin
			out_valid <= 1'b0;
		end
	end

endmodule
