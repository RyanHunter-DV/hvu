//=============================================================================
// hvu1_resize_pipe — Destination-driven scaler
//=============================================================================
//
// Local operations (this module):
//   1. Frame latch + Q16.16 ratio (one divide per frame)
//   2. Destination raster walk
//   3. Inverse map dst → src_x_c / src_y_c
//   4. Interpolator en / in_valid steering
//   5. Nearest integer clamp
//   6. Fetch / CSC / CU mux
//   7. dst_eol, dst_last, frame_done
//
// Interpolators: nearest rounds + CSC→CU; bilinear 2×2 + blend.
//
// See: doc/spec/modules/hvu1_resize_pipe.md
//=============================================================================

module hvu1_resize_pipe (
	input  wire        clk,
	input  wire        rstn,

	input  wire        start,
	input  wire        en,
	input  wire [1:0]  interpolation,
	input  wire [15:0] src_width,
	input  wire [15:0] src_height,
	input  wire [15:0] dst_width,
	input  wire [15:0] dst_height,
	output wire        frame_done,

	output wire [15:0] pos_x,
	output wire [15:0] pos_y,
	output wire        pixel_req_valid,
	input  wire        pixel_req_ready,

	input  wire        csc_pvalid,
	output wire        csc_pready,
	input  wire [11:0] csc_r,
	input  wire [11:0] csc_g,
	input  wire [11:0] csc_b,
	input  wire [11:0] csc_a,

	output wire [11:0] cu_r,
	output wire [11:0] cu_g,
	output wire [11:0] cu_b,
	output wire [11:0] cu_a,
	output wire        cu_pvalid,
	input  wire        cu_pready,
	output wire        dst_last,
	output wire        dst_eol
);

	localparam S_IDLE = 2'd0;
	localparam S_MAP  = 2'd1;
	localparam S_WAIT = 2'd2;

	reg [1:0]  state;
	reg        en_r;
	reg        sel_bilinear_r;
	reg [15:0] src_width_r;
	reg [15:0] src_height_r;
	reg [15:0] dst_width_r;
	reg [15:0] dst_height_r;
	reg [31:0] ratio_w_r;
	reg [31:0] ratio_h_r;
	reg [15:0] dst_x;
	reg [15:0] dst_y;

	wire dims_ok = (dst_width != 16'd0) && (dst_height != 16'd0);
	wire last_px = (dst_x == (dst_width_r  - 16'd1)) &&
	               (dst_y == (dst_height_r - 16'd1));
	wire row_end = (dst_x == (dst_width_r - 16'd1));

	// ---- 3. Inverse map (Q16.16) ----
	wire [47:0] prod_x  = dst_x * ratio_w_r;
	wire [47:0] prod_y  = dst_y * ratio_h_r;
	wire [31:0] src_x_c = en_r ? prod_x[31:0] : {dst_x, 16'd0};
	wire [31:0] src_y_c = en_r ? prod_y[31:0] : {dst_y, 16'd0};

	// ---- 4. Interpolator steering ----
	wire frame_active = (state != S_IDLE);
	wire near_en  = frame_active && !sel_bilinear_r;
	wire bilin_en = frame_active &&  sel_bilinear_r;

	wire        near_in_ready;
	wire [15:0] near_pos_x_int;
	wire [15:0] near_pos_y_int;
	wire        near_out_valid;
	wire        near_csc_pready;
	wire [11:0] near_cu_r, near_cu_g, near_cu_b, near_cu_a;
	wire        near_cu_pvalid;

	wire        bilin_in_ready;
	wire [15:0] bilin_pos_x_int;
	wire [15:0] bilin_pos_y_int;
	wire        bilin_out_valid;
	wire        bilin_csc_pready;
	wire [11:0] bilin_cu_r, bilin_cu_g, bilin_cu_b, bilin_cu_a;
	wire        bilin_cu_pvalid;

	wire near_in_valid  = (state == S_MAP) && !sel_bilinear_r;
	wire bilin_in_valid = (state == S_MAP) &&  sel_bilinear_r;
	wire interp_in_ready = sel_bilinear_r ? bilin_in_ready : near_in_ready;

	hvu1_nearest_interp u_nearest (
		.clk        (clk),
		.rstn       (rstn),
		.en         (near_en),
		.pos_x      (src_x_c),
		.pos_y      (src_y_c),
		.in_valid   (near_in_valid),
		.in_ready   (near_in_ready),
		.pos_x_int  (near_pos_x_int),
		.pos_y_int  (near_pos_y_int),
		.out_valid  (near_out_valid),
		.out_ready  (sel_bilinear_r ? 1'b0 : pixel_req_ready),
		.csc_pvalid (sel_bilinear_r ? 1'b0 : csc_pvalid),
		.csc_pready (near_csc_pready),
		.csc_r      (csc_r),
		.csc_g      (csc_g),
		.csc_b      (csc_b),
		.csc_a      (csc_a),
		.cu_r       (near_cu_r),
		.cu_g       (near_cu_g),
		.cu_b       (near_cu_b),
		.cu_a       (near_cu_a),
		.cu_pvalid  (near_cu_pvalid),
		.cu_pready  (sel_bilinear_r ? 1'b0 : cu_pready)
	);

	hvu1_bilinear_interp u_bilinear (
		.clk        (clk),
		.rstn       (rstn),
		.en         (bilin_en),
		.src_width  (src_width_r),
		.src_height (src_height_r),
		.pos_x      (src_x_c),
		.pos_y      (src_y_c),
		.in_valid   (bilin_in_valid),
		.in_ready   (bilin_in_ready),
		.pos_x_int  (bilin_pos_x_int),
		.pos_y_int  (bilin_pos_y_int),
		.out_valid  (bilin_out_valid),
		.out_ready  (sel_bilinear_r ? pixel_req_ready : 1'b0),
		.csc_pvalid (sel_bilinear_r ? csc_pvalid : 1'b0),
		.csc_pready (bilin_csc_pready),
		.csc_r      (csc_r),
		.csc_g      (csc_g),
		.csc_b      (csc_b),
		.csc_a      (csc_a),
		.cu_r       (bilin_cu_r),
		.cu_g       (bilin_cu_g),
		.cu_b       (bilin_cu_b),
		.cu_a       (bilin_cu_a),
		.cu_pvalid  (bilin_cu_pvalid),
		.cu_pready  (sel_bilinear_r ? cu_pready : 1'b0)
	);

	// ---- 5. Nearest integer clamp ----
	wire [15:0] x_max = (src_width_r  == 16'd0) ? 16'd0 : (src_width_r  - 16'd1);
	wire [15:0] y_max = (src_height_r == 16'd0) ? 16'd0 : (src_height_r - 16'd1);
	wire [15:0] near_x_clamped = (near_pos_x_int > x_max) ? x_max : near_pos_x_int;
	wire [15:0] near_y_clamped = (near_pos_y_int > y_max) ? y_max : near_pos_y_int;

	// ---- 6. Fetch / CSC / CU mux ----
	assign pos_x           = sel_bilinear_r ? bilin_pos_x_int : near_x_clamped;
	assign pos_y           = sel_bilinear_r ? bilin_pos_y_int : near_y_clamped;
	assign pixel_req_valid = sel_bilinear_r ? bilin_out_valid : near_out_valid;
	assign csc_pready      = sel_bilinear_r ? bilin_csc_pready : near_csc_pready;
	assign cu_r            = sel_bilinear_r ? bilin_cu_r : near_cu_r;
	assign cu_g            = sel_bilinear_r ? bilin_cu_g : near_cu_g;
	assign cu_b            = sel_bilinear_r ? bilin_cu_b : near_cu_b;
	assign cu_a            = sel_bilinear_r ? bilin_cu_a : near_cu_a;
	assign cu_pvalid       = sel_bilinear_r ? bilin_cu_pvalid : near_cu_pvalid;

	// ---- 7. CU line/frame flags ----
	assign dst_eol    = cu_pvalid && row_end;
	assign dst_last   = cu_pvalid && last_px;
	assign frame_done = (state == S_WAIT) && cu_pvalid && cu_pready && last_px;

	// ---- 1–2. Frame latch, ratio, destination walk ----
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state          <= S_IDLE;
			en_r           <= 1'b0;
			sel_bilinear_r <= 1'b0;
			src_width_r    <= 16'd0;
			src_height_r   <= 16'd0;
			dst_width_r    <= 16'd0;
			dst_height_r   <= 16'd0;
			ratio_w_r      <= 32'd0;
			ratio_h_r      <= 32'd0;
			dst_x          <= 16'd0;
			dst_y          <= 16'd0;
		end else begin
			case (state)
				S_IDLE: begin
					if (start && dims_ok) begin
						en_r           <= en;
						sel_bilinear_r <= en && (interpolation == 2'b01);
						src_width_r    <= src_width;
						src_height_r   <= src_height;
						dst_width_r    <= dst_width;
						dst_height_r   <= dst_height;
						dst_x          <= 16'd0;
						dst_y          <= 16'd0;
						if (en) begin
							ratio_w_r <= ({src_width,  16'd0}) / dst_width;
							ratio_h_r <= ({src_height, 16'd0}) / dst_height;
						end else begin
							ratio_w_r <= 32'd0;
							ratio_h_r <= 32'd0;
						end
						state <= S_MAP;
					end
				end

				S_MAP: begin
					if (interp_in_ready)
						state <= S_WAIT;
				end

				S_WAIT: begin
					if (cu_pvalid && cu_pready) begin
						if (last_px) begin
							state <= S_IDLE;
						end else begin
							if (row_end) begin
								dst_x <= 16'd0;
								dst_y <= dst_y + 16'd1;
							end else begin
								dst_x <= dst_x + 16'd1;
							end
							state <= S_MAP;
						end
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
