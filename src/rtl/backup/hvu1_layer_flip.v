//=============================================================================
// hvu1_layer_flip — Source-buffer address walk for vflip then hflip
//=============================================================================
//
// Walks the *output* image left-to-right, top-to-bottom and emits the
// corresponding source byte offset so fetched pixels already appear in
// flipped scan order.
//
// Applied after rotation (see hvu1_rot_flip_pipe). Output size is unchanged
// (W × H). When both enables are set, vflip is applied first, then hflip:
//
//   after vflip:  (ix, iy) = (ox,  vflip_en ? H-1-oy : oy)
//   after hflip:  (sx, sy) = (hflip_en ? W-1-ix : ix, iy)
//
// Packed source pixel (sx, sy):
//   addr = base_addr + (sy * W + sx) * DATA_BYTES
//
// See: doc/spec/hvu1_layer_unit.md
//=============================================================================

module hvu1_layer_flip #(
	parameter DATA_BYTES = 4,
	parameter ADDR_WIDTH = 32
)(
	input  wire                    clk,
	input  wire                    rst_n,

	input  wire [15:0]             img_width,
	input  wire [15:0]             img_height,
	input  wire [ADDR_WIDTH-1:0]   base_addr,

	input  wire                    vflip_en,
	input  wire                    hflip_en,

	input  wire                    start,
	input  wire                    ready,

	output wire                    valid,
	output wire                    req_valid,
	output wire [ADDR_WIDTH-1:0]   addr_out,
	output wire                    last_pixel,
	output wire                    frame_done
);

	localparam IDLE    = 2'd0;
	localparam RUNNING = 2'd1;
	localparam DONE    = 2'd2;

	wire [31:0] total_pixels_w = img_width * img_height;

	// Sample output coordinates used to derive start / ±increments.
	// Scan is ox = 0..W-1, oy = 0..H-1; enables remap the sample.
	wire [15:0] fx0 = hflip_en ? (img_width  - 16'd1) : 16'd0;
	wire [15:0] fy0 = vflip_en ? (img_height - 16'd1) : 16'd0;
	wire [15:0] fx1 = hflip_en ? ((img_width  > 16'd1) ? (img_width  - 16'd2) : 16'd0)
							   : ((img_width  > 16'd1) ? 16'd1 : 16'd0);
	wire [15:0] fy1 = vflip_en ? ((img_height > 16'd1) ? (img_height - 16'd2) : 16'd0)
							   : ((img_height > 16'd1) ? 16'd1 : 16'd0);
	wire [15:0] fxl = hflip_en ? 16'd0 : (img_width - 16'd1);

	// Map output (ox, oy) through vflip then hflip to a packed source offset.
	function [ADDR_WIDTH-1:0] map_offset;
		input [15:0] ox;
		input [15:0] oy;
		reg [31:0] ix;
		reg [31:0] iy;
		reg [31:0] sx;
		reg [31:0] sy;
		begin
			ix = {16'd0, ox};
			iy = vflip_en ? ({16'd0, img_height} - 32'd1 - {16'd0, oy})
						  : {16'd0, oy};
			sx = hflip_en ? ({16'd0, img_width} - 32'd1 - ix) : ix;
			sy = iy;
			map_offset = (sy * {16'd0, img_width} + sx) * DATA_BYTES;
		end
	endfunction

	wire [ADDR_WIDTH-1:0] addr_00 = map_offset(fx0, fy0);
	wire [ADDR_WIDTH-1:0] addr_10 = map_offset(fx1, fy0);
	wire [ADDR_WIDTH-1:0] addr_01 = map_offset(fx0, fy1);
	wire [ADDR_WIDTH-1:0] addr_x0 = map_offset(fxl, fy0);

	wire [ADDR_WIDTH-1:0] start_off_w = addr_00;
	wire [ADDR_WIDTH-1:0] inc_x_w     = addr_10 - addr_00;
	wire [ADDR_WIDTH-1:0] inc_y_w     = addr_01 - addr_x0;

	reg [1:0]              state;
	reg [15:0]             x_cnt;
	reg [15:0]             y_cnt;
	reg [15:0]             x_limit;
	reg [15:0]             y_limit;
	reg [31:0]             pixel_cnt;
	reg [31:0]             total_pixels;
	reg [ADDR_WIDTH-1:0]   curr_off;
	reg [ADDR_WIDTH-1:0]   inc_x;
	reg [ADDR_WIDTH-1:0]   inc_y;
	reg [ADDR_WIDTH-1:0]   base_r;

	wire at_last    = (pixel_cnt == (total_pixels - 32'd1));
	wire at_row_end = (x_cnt == (x_limit - 16'd1));

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			state        <= IDLE;
			x_cnt        <= 16'd0;
			y_cnt        <= 16'd0;
			x_limit      <= 16'd0;
			y_limit      <= 16'd0;
			pixel_cnt    <= 32'd0;
			total_pixels <= 32'd0;
			curr_off     <= {ADDR_WIDTH{1'b0}};
			inc_x        <= {ADDR_WIDTH{1'b0}};
			inc_y        <= {ADDR_WIDTH{1'b0}};
			base_r       <= {ADDR_WIDTH{1'b0}};
		end else begin
			case (state)
				IDLE: begin
					if (start) begin
						x_cnt        <= 16'd0;
						y_cnt        <= 16'd0;
						pixel_cnt    <= 32'd0;
						x_limit      <= img_width;
						y_limit      <= img_height;
						total_pixels <= total_pixels_w;
						curr_off     <= start_off_w;
						inc_x        <= inc_x_w;
						inc_y        <= inc_y_w;
						base_r       <= base_addr;
						if ((img_width == 16'd0) || (img_height == 16'd0))
							state <= DONE;
						else
							state <= RUNNING;
					end
				end

				RUNNING: begin
					if (ready) begin
						if (at_last) begin
							state <= DONE;
						end else if (at_row_end) begin
							x_cnt     <= 16'd0;
							y_cnt     <= y_cnt + 16'd1;
							pixel_cnt <= pixel_cnt + 32'd1;
							curr_off  <= curr_off + inc_y;
						end else begin
							x_cnt     <= x_cnt + 16'd1;
							pixel_cnt <= pixel_cnt + 32'd1;
							curr_off  <= curr_off + inc_x;
						end
					end
				end

				DONE: begin
					state <= IDLE;
				end

				default: state <= IDLE;
			endcase
		end
	end

	assign addr_out   = base_r + curr_off;
	assign valid      = (state == RUNNING);
	assign req_valid  = (state == RUNNING);
	assign last_pixel = (state == RUNNING) && at_last;
	assign frame_done = (state == DONE);

endmodule
