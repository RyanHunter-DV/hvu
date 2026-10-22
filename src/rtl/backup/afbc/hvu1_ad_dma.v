
module hvu1_ad_dma(

);
// inputs:
// clk_i, rstn_i
// dma_req_valid_i, dma_req_hdr_i, dma_req_group_i, dma_req_end_of_tile_i, dma_req_dummy_i
// dma_req_addr_i, 39:0
// dma_req_size_i, 8:0
// dma_req_tile_id_i, 9:0
// dma_req_header_i, 1 bit
// dmar_ready_i, 1 bit



// outputs logic
//TODO, more detailed behavior will be built while creating this module.
dmar_end_of_tile:
while the last cycle of the payload fetching, if the dma_req_group is 0, then the end_of_tile will be the incoming end_of_tile flag, other conditions will be always 0.
dmar_payload_group: when in last payload cycle, when in payload fetch, value will be !dma_req_group, other conditions will be 0, default is dmar_payload_group_q
dmar_payload_last: flag of the last payload cycle.
dmar_tile_id: while payload fetch state, pass to dma_req_tile_id

arlen: each time any of the update will decrease 1, at first time start header fetch, will gets from the axi_burstlen.
dma_req_finished: granted current beat according to the input dmar_ready, and now is end of fetch.
rd_req_active: one cycle delay of dmar_valid
dma_req_ready: next cycle when incoming dma_req_valid, will raise, and drop when dma_req_valid done.






	// internal logic operations and signal declaration //
	// start_header_fetch:
	// this is combinational signal when req valid and size not 0 and header input
	wire start_header_fetch;
	assign start_header_fetch = dma_req_valid & size_not_zero & dma_req_header_i;




//araddr:
//when start of header or payload fetch, then the output address will be input {dma_req_addr >> 4,1'b0}, else when one beat is received by indicating of input ready, then to update the address according to current different burst length.
//the burst length with different phase is not the same.
	wire [39:0] next_araddr;
	reg  [39:0] araddr_r;
	wire [39:0] incr_addr;

// (axi_burstlen -1) & next_dma_req_addr[10:4] -> is current requested bytes
// TODO, marker

	assign incr_addr = araddr_r + <TODO>;



	assign next_araddr = (prefetch)? 40'h0 : (start_header_fetch|start_payload_fetch) ? {dma_req_addr >> 4,1'b0} : (update_araddr)? incr_addr : araddr_r;





	//dmar_valid:
	//detecting when the incoming request is valid, size not 0, not prefetch and not dmar_ready, the dmar_ready shall be asserted only after the dmar_valid high from in port.

	assign size_not_zero = |dma_req_size;
	assign next_dmar_valid = dma_req_valid & size_not_zero & !prefetch & !dmar_ready;

	reg dmar_valid_r;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			dmar_valid_r <= 0;
		end else begin
			dmar_valid_r <= next_dmar_valid;
		end
	end
	assign dmar_valid_o = dmar_valid_r;


// ready & last
// dmar_last_received, the dmar side protocol, the incoming ready high and is last fetch burst.
// TODO



//dmar_dummy:
//when start_payload_fetch, will be the input dma_req_dummy, else in other condition will be 0, default is dmar_dummy_q

	reg payload_dummy_r;
	wire next_payload_dummy;

	assign next_payload_dummy = start_payload_fetch ? dma_req_dummy : (prefetch|start_header_fetch|dmar_last_received) ? 1'b0: payload_dummy_r;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			payload_dummy_r <= 0;
		end else begin
			payload_dummy_r <= next_payload_dummy;
		end
	end
	assign dmar_dummy_o = payload_dummy_r;


//dmar_header:
//anytime when not in payload fetch, the dmar_header flag is always 1. now to enhance the header, that will only high when the incoming dma_req_valid and headerr flag high.
	reg dmar_header_r;
	wire next_dmar_header;
	assign next_dmar_header = dma_req_valid & start_header_fetch;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			dmar_header_r <= 0;
		end else begin
			dmar_header_r <= next_dmar_header;
		end
	end
	assign dmar_header_o = dmar_header_r;





// summarize:
//a handshake protocol module, that the incoming is dma_req* internal interface protocol, and will translated to ad_dmar_* protocol.


endmodule