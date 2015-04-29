`timescale 1ns / 1ps
`include "noc/connect_parameters.v"

module processing_element(sys_clk, reset, processor_id, flit, send_credit, credit_in, EN_putFlit, putFlit); //, found_nonce);
    input sys_clk, reset;
	input [4:0] processor_id;
	
	localparam vc_bits = 2;
	localparam dest_bits = 5;
	localparam flit_port_width = 2 /*valid and tail bits*/+ `FLIT_DATA_WIDTH + dest_bits + vc_bits;
	localparam credit_port_width = 1 + vc_bits; // 1 valid bit
	localparam test_cycles = 20;
	
    // stores data to be sent into network 
    output reg [flit_port_width-1:0] putFlit;
     
    // bit to put a flit in the network
    output reg EN_putFlit;
	
	input [flit_port_width-1:0] flit;
	output reg send_credit;
	output reg [credit_port_width-1:0] credit_in;
	
	reg [63:0] Clk_cnt;
	
	reg found_nonce;

    reg [1023:0] buffer;
    wire [255:0] hash_out;
    reg [511:0] msg_in;
    reg [1:0] blk_type;
    wire blk_done;
    reg start;
	reg [31:0] nonce;
	reg [9:0] flit_cnt;
	//reg [`FLIT_DATA_WIDTH-1:0] data [0:9];

    reg [2:0] state;
    reg blk_iteration;

	wire reset;
	reg [2:0] output_cnt;
	//assign reset = BTNC;
	
	/*reg reset, sim_clk;	
	initial begin
		sim_clk <= 0;
		reset <= 0;
		#10 reset <= 1;
		#10 reset <= 0;
	end
	
	always #5 sim_clk = ~sim_clk;
	*/
	
    localparam
    INIT =                 3'd0,
    PREPROCESS =           3'd1,
    INPUT_FIRST_BLOCK =    3'd2,
    FIRST_BLOCK_WAITING =  3'd3,
    SECOND_BLOCK_WAITING = 3'd4,
    WAIT_HASH =            3'd5,
    SEND_RESULT =          3'd6,
	DONE =				   3'd7;

    localparam
    HASH =         2'b00,
    MERKLE_LEAF =  2'b01,
    HEADER =       2'b10;

	localparam testheader = 640'h8601a8807d39ef0f73ac5b3aac28c527c89542b8029600809f5fe5ace2ea82b273fcdb297fba14e33f9d2921356b84cf853b629d639e028729d5b40f2b0f6a9649b8965140e8a10adf06070a00000000;
	localparam FOUND_BITCOIN_MSG = 64'h00000001;
	
	always @(posedge sys_clk)
	begin
		if (~reset)
		begin
			blk_type <= 2'b11;
			state <= INIT;
			blk_iteration <= 1'b0;
			start <= 1'b0;
			nonce <= processor_id - 1 + 'ha;  // first processor_id = 1
			found_nonce <= 1'b0;
			//processor_id <= 0;
			flit_cnt <= 0;
			buffer <= 0;
			EN_putFlit <= 1'b0;
			putFlit <= 0;
			output_cnt <= 0;
		end
		else
		begin
			case (state)
				INIT:
				begin
					start <= 1'b0;
					blk_iteration <= 1'b0;
					//buffer <= testheader;
					blk_type <= HEADER;
					
					if(flit[flit_port_width-1]) begin // valid flit
						$display("Ejecting flit %x at receive port %0d", flit, processor_id);
						send_credit <= 1'b1;
						credit_in <= 3'b100;
						buffer[flit_cnt+:64] <= flit[63:0];
						flit_cnt <= (flit_cnt + 64) % 640;
					end
					else begin
						send_credit <= 0;
						credit_in <= 0;
					end
					
					if(flit_cnt == 576)
						state <= PREPROCESS;
				end
				
				PREPROCESS:
				begin
					//$display("buffer = %h", buffer);
					if (blk_type == MERKLE_LEAF)
					begin
						buffer <= {buffer[511:0],1'b1,{447{1'b0}},64'h200};
					end
					else if (blk_type == HEADER)
					begin
						buffer <= {buffer[639:32], nonce, 1'b1, {319{1'b0}}, 64'h280};
					end
					state <= INPUT_FIRST_BLOCK;
				end
				
				INPUT_FIRST_BLOCK:
				begin
					msg_in <= buffer[1023:512];
					
					state <= FIRST_BLOCK_WAITING;
					start <= 1'b1;
					/*
					found_nonce <= 1'b1;
					state <= SEND_RESULT;
					*/
				end
				
				FIRST_BLOCK_WAITING:
				begin
					start <= 1'b0;
					if (blk_done)
					begin
						state <= SECOND_BLOCK_WAITING;
						msg_in <= buffer[511:0];
						start <= 1'b1;
					end
				end
				
				SECOND_BLOCK_WAITING:
				begin
					if (blk_done)
					begin
						start <= 1'b1;
						state <= WAIT_HASH;
						blk_type <= HASH;
						msg_in[511:0] <= {hash_out, 1'b1, {191{1'b0}},64'h100};
					end
				end
				
				WAIT_HASH:
				begin
					start <= 1'b0;
					if (blk_done & (hash_out[255:228] == 28'd0) & (nonce <= 32'hffff_ffff))
					begin
						found_nonce <= 1'b1;
						state <= SEND_RESULT;
					end
					else if (blk_done & (hash_out[255:228] != 28'd0) & (nonce < 32'hffff_ffff))
					begin
						nonce <= nonce + 5'd24;
						state <= INIT;
					end
					else
						state <= state;
				end
				
				SEND_RESULT:
				begin
					//if(processor_id == 5'd1)
						//$stop;
					EN_putFlit <= 1'b1;
					
					case (output_cnt)
						0: begin
							putFlit <= 
							{1'b1, // Valid bit
							(output_cnt == 2) ? 1'b1 : 1'b0, // Tail bit
							5'd0,    // Destination 
							2'd0,     // Virtual channel
							FOUND_BITCOIN_MSG}; // actual data
						end
						1: begin
							putFlit <= 
							{1'b1, // Valid bit
							(output_cnt == 2) ? 1'b1 : 1'b0, // Tail bit
							5'd0,    // Destination 
							2'd0,     // Virtual channel
							{32'h0000_0000, nonce} }; // actual data
						end
						2: begin
							putFlit <= 
							{1'b1, // Valid bit
							(output_cnt == 2) ? 1'b1 : 1'b0, // Tail bit
							5'd0,    // Destination 
							2'd0,     // Virtual channel
							Clk_cnt }; // actual data
						end
						default: putFlit <= 0;
					endcase

					output_cnt = output_cnt + 1;
					
					if (output_cnt == 4) begin
						EN_putFlit <= 1'b0;
						state <= DONE;						
					end
				end
				
				DONE:
				begin
					//$display("nonce = %h", nonce);
					//$display("CLKS = %h", Clk_cnt);
					//$stop;
				end
				
				default:
					state <= 3'd7;
			endcase
		end
	end
    SHA256 UUT(.CLK(sys_clk), .nreset(~reset), .start(start), .msg(msg_in), .hash(hash_out), .blk_done(blk_done), .blk_type(blk_type));
	
	always @(posedge sys_clk)
	begin
		if (~reset)
			Clk_cnt <= 0;
		else if( (Clk_cnt < 64'hffff_ffff_ffff_ffff) & (~found_nonce) )
			Clk_cnt <= Clk_cnt + 1'b1;
		else
			Clk_cnt <= Clk_cnt;
	end
	
endmodule