`define DEBUG;

module MSUDATA(
  input		clk,
  input		sd_buff_wr,
  input	 [31:0]	msu_data_addr,

  `ifndef DEBUG
  input         reset,
  input         msu_dataseekfinished_in,
  input         msu_data_seek,
  input 	sd_ack_2,    			// sd_ack[2]
  
  output	msu_data_busy,
  `endif

  output [31:0] sd_lba_2,
  output	sd_rd_2 = 0, 			// sd_rd[2] 
  output	clk_count,
  output	msu_data_fifo_busy = 0,
  output 	msu_dataseekfinished = 1,
  output        msu_data_fifo_usedw,
  output	msu_data_debug
);
  reg [7:0] msu_data_debug = 0;
  reg msu_dataseekfinished = 1;
  reg msu_data_fifo_busy = 0;
  reg msu_data_seek_out = 0;
  reg msu_data_seek_old = 0;
  reg msu_dataseekfinished_in_old = 0;

  reg [7:0] msu_data_debug_dataseeks = 0;

  `ifndef DEBUG

  parameter LBA_MAX = 32'd60;
  parameter FIFO_MAX_W = 16'd16128;
  `endif
  
  `ifdef DEBUG
  parameter LBA_MAX = 32'd60;
  parameter FIFO_MAX_W = 16'd100;
  reg [15:0] msu_data_fifo_usedw = 0;

  // Debug
  reg [15:0] clk_count = 0; 
  reg msu_data_seek = 0;
  reg reset = 0;
  reg sd_ack_2 = 0;
  reg msu_dataseekfinished_in = 0;
  wire msu_data_busy = msu_data_fifo_busy || (msu_dataseekfinished != 1);
  
  // Simulate some req/ack and events at specific clock cycles
  always @(posedge clk) begin
    clk_count <= clk_count + 1;
    if (clk_count == 0) begin
      reset <= 1;
    end
    
    if (clk_count == 5) begin
      reset <= 0;
    end
    
      
    if (sd_rd_2 == 1) begin
      sd_ack_2 <= 1;
    end
    
    if (sd_rd_2 ==0) begin
      sd_ack_2 <= 0;
      msu_data_fifo_usedw <= msu_data_fifo_usedw + 1;
    end
    
    // MSU has seeked
    if (clk_count == 21) begin
      msu_data_seek <= 1;
    end
    
    if (clk_count == 22) begin
      msu_data_seek <= 0;
    end
    
    // Hps has finished seeking
    if (clk_count == 30) begin
      msu_dataseekfinished_in <= 1;
    end
    
    if (clk_count % 10 == 0) begin
      msu_data_fifo_usedw <= msu_data_fifo_usedw - 5;
    end
  end    
       
`endif
  
// MSU Data track reading state machine
always @(posedge clk)
  if (reset) begin
    msu_data_debug_dataseeks <= 0;
    // pause the state machine in state 4 on reset
    msu_data_state <= 8'd4;
    sd_lba_2 <= 0;
    sd_rd_2 <= 0;

    msu_data_addr_bit1_old <= 0;

    msu_data_fifo_busy <= 0;
    msu_dataseekfinished <= 1;
    msu_dataseekfinished_in_old <= 0;
    msu_data_debug <= 8'd0;
    msu_data_seek_old <= 0;
  end else begin
    // falling edge stuff
    msu_data_addr_bit1_old <= msu_data_addr[1];
    msu_dataseekfinished_in_old <= msu_dataseekfinished_in;
    msu_data_seek_old <= msu_data_seek;

    // For HPS seek pulse
    msu_data_seek_out <= 0;
		
    if (msu_dataseekfinished_in_old == 1 && msu_dataseekfinished_in == 0) begin
      msu_data_debug <= 8'd255;
      msu_dataseekfinished <= 1;
    end

    // Rising edge
    if (msu_data_seek_old == 0 && msu_data_seek == 1) begin
      msu_data_debug_dataseeks <= msu_data_debug_dataseeks + 1;
      // Both our fifo and hps are seeking
      msu_data_fifo_busy <= 1;
      msu_dataseekfinished <= 0;
      // Init sd, fifo, internal counters
      sd_lba_2 <= 0;
      sd_rd_2 <= 1'b0;
      // Tell the hps to seek now, one pulse
      msu_data_seek_out <= 1;

      // Kick off the state machine
      msu_data_state <= 0;
    end	
	
    case (msu_data_state)
      0: begin
        sd_rd_2 <= 1'b1;
        msu_data_state <= msu_data_state + 1;
      end
      1: if (sd_ack_2) begin
        // Sector transfer has started. (Need to check sd_ack[2], so we know the data is for us.)
        sd_rd_2 <= 1'b0;
        msu_data_state <= msu_data_state + 1;
      end
	
      2: begin	
        // See if we have filled up our 32 sector (16kb) buffer yet BEFORE we say our seek is finished
        if (!sd_ack_2 & sd_lba_2 >= LBA_MAX) begin
          
          // Let the MSU know the seek has finished, at least in terms of the fifo buffer, hps could still
          // be seeking...
          msu_data_fifo_busy <= 0;

          msu_data_debug <= 8'd7;
          
          if (msu_data_fifo_usedw < FIFO_MAX_W) begin
            // Buffer is not full, so just top up as normal
            sd_lba_2 <= sd_lba_2 + 1;
            msu_data_state <= 0;
            msu_data_debug <= 8'd22;
          end
        end else if (!sd_ack_2) begin
          msu_data_debug <= 8'd6;

          if (msu_data_fifo_usedw < FIFO_MAX_W) begin
            // Buffer is not full, so just top up as normal
            sd_lba_2 <= sd_lba_2 + 1;
            msu_data_state <= 0;
            msu_data_debug <= 8'd23;
          end
        end
      end

      4: begin
        // Initial 'Paused' state
        msu_data_debug <= 8'd5;
      end

      default:;
    endcase
  end

  wire [15:0] msu_data_fifo_dout;
  wire msu_data_fifo_empty;

  reg msu_data_addr_bit1_old = 0;
  reg msu_dataseekfinished_out_old = 0;

  /*
  wire msu_data_req;
  wire [15:0] msu_data_fifo_usedw;

wire msu_data_fifo_rdreq = msu_data_req && (msu_data_addr_bit1_old != msu_data_addr[1]);
  
  
  // Clear the FIFO, for only ONE clock pulse, else it will clear the first sector we transfer.
  wire msu_data_fifo_clear = msu_data_seek || reset;

  wire msu_data_fifo_full;
  wire msu_data_fifo_wr = !msu_data_fifo_full && sd_ack_2 && sd_buff_wr;
  
  msu_data_fifo msu_data_fifo_inst (
    .sclr(msu_data_fifo_clear),
    .clock(clk_sys),
    .wrreq(msu_data_fifo_wr),
    .full(msu_data_fifo_full),
    .usedw(msu_data_fifo_usedw),
    .data(sd_buff_dout),
    .rdreq(msu_data_fifo_rdreq),
    .empty(msu_data_fifo_empty),
    .q(msu_data_fifo_dout)	
  );
  */
  
  reg [7:0] msu_data_state = 8'd4;

endmodule;
    
