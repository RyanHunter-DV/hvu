//=============================================================================
// hvu1_nearest_interp — Q16.16 rounder + CSC→CU pass-through
//=============================================================================
//
// Normal round (round-half-up): out = integer + frac[15].
// When en is set: issue rounded integer, take CSC pixel, send it to CU.
// When en is low: FSM idle (no out_valid, no csc_pready, no cu_pvalid).
// No clamp to source size — parent clamps before fetch.
//
// See: doc/spec/modules/hvu1_resize_pipe.md
//=============================================================================

module hvu1_nearest_interp (
	input  wire        clk,
	input  wire        rstn,
	input  wire        en,

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

	localparam IDLE = 2'd0;
	localparam REQ  = 2'd1;
	localparam CSC  = 2'd2;
	localparam EMIT = 2'd3;

	reg [1:0] state;

	wire [16:0] rnd_x = {1'b0, pos_x[31:16]} + pos_x[15];
	wire [16:0] rnd_y = {1'b0, pos_y[31:16]} + pos_y[15];
	wire [15:0] sat_x = rnd_x[16] ? 16'hFFFF : rnd_x[15:0];
	wire [15:0] sat_y = rnd_y[16] ? 16'hFFFF : rnd_y[15:0];

	assign in_ready   = en && (state == IDLE);
	assign out_valid  = en && (state == REQ);
	assign csc_pready = en && (state == CSC);
	assign cu_pvalid  = en && (state == EMIT);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state     <= IDLE;
			pos_x_int <= 16'd0;
			pos_y_int <= 16'd0;
			cu_r      <= 12'd0;
			cu_g      <= 12'd0;
			cu_b      <= 12'd0;
			cu_a      <= 12'd0;
		end else if (!en) begin
			state <= IDLE;
		end else begin
			case (state)
				IDLE: begin
					if (in_valid) begin
						pos_x_int <= sat_x;
						pos_y_int <= sat_y;
						state     <= REQ;
					end
				end
				REQ: begin
					if (out_ready)
						state <= CSC;
				end
				CSC: begin
					if (csc_pvalid) begin
						cu_r  <= csc_r;
						cu_g  <= csc_g;
						cu_b  <= csc_b;
						cu_a  <= csc_a;
						state <= EMIT;
					end
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
