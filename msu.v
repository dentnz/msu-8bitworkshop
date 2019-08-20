`define debug = 1;

module msu_audio(
  input clk,
  input reset,
  
  `ifndef debug
  inout [31:0] img_size,
  input msu_trig_play,
  input [3:0] sd_ack,
  input msu_repeat_out,
  input msu_trackmounting_falling,
  input sd_buff_wr,
  input [11:0] audio_fifo_usedw,
  `endif
  
  output [8:0] msu_audio_end_frame_byte_offset,
  output msu_audio_end_frame,
  output [7:0] debug_expected_high,
  output msu_audio_state,
  output [20:0] sd_lba_1,
  output sd_rd_1 // Needs to be wired to sd_rd[1]
);

  reg [20:0] msu_audio_current_frame = 21'd0;
  reg [20:0] msu_audio_end_frame = 21'd2097151;
  `ifndef debug
  reg msu_audio_play = 0;
  reg [31:0] msu_audio_loop_index = 32'd0;
  reg [31:0] img_size = 32'd1024;
  `endif
  
  `ifdef debug
  // Assumed we are playing
  reg msu_audio_play = 0;
  reg msu_trig_play = 1;
  reg msu_trackmounting_falling = 1;
  // Assumed image size
  //reg [63:0] img_size = 64'd2560;
  reg [63:0] img_size = 64'd1028;
  // force repeating when high
  reg msu_repeat_out = 0;
  // loop point is first sample
  reg [31:0] msu_audio_loop_index = 32'd0;
  reg [1:0] sd_ack = 0;
  reg [1:0] sd_rd = 0;
  reg sd_buff_wr = 1;
  reg [31:0] audio_fifo_usedw = 32'd0;
  reg debug_expected_high = 8'd0;
  `endif

  reg [8:0] sector_size = 9'd63;
  
  // Have to be careful we don't go to negative one here?
  assign msu_audio_end_frame = (img_size[20:0] >> 9) - 1;
  assign msu_audio_end_frame_byte_offset = img_size[8:0];
  wire [8:0] msu_audio_end_frame_word_offset = msu_audio_end_frame_byte_offset / 2;
  wire [20:0] msu_audio_loop_index_frame = msu_audio_loop_index[20:0] >> 7; 
  
  reg [7:0] msu_audio_mode = 0'd0;
  reg [7:0] msu_audio_state = 0'd0;
  reg [7:0] partial_frame_state = 0'd0;
  // 256 WORDS in a 512 byte sector
  reg [8:0] msu_audio_word_count = 9'd0;
  
  always @(posedge clk) begin
    // We have a trigger to play...
    if (reset || msu_trig_play) begin
      // Stop any existing audio playback
      msu_audio_current_frame <= 0;
      msu_audio_state <= 0;
      msu_audio_play <= 0;
      msu_audio_word_count <= 0;
      sd_lba_1 <= 0;
      partial_frame_state <= 0;
      msu_audio_loop_index <= 0;
      // Work out the audio playback mode
      if (!msu_repeat_out) begin
        msu_audio_mode <= 8'd1;
      end else begin
        msu_audio_mode <= 8'd2;
      end
      `ifdef debug
      sd_ack[1] <= 1'b1;
      msu_trig_play <= 0;
      `endif
    end else begin
      case (msu_audio_state)
        0: begin
          if (msu_trackmounting_falling) begin
            msu_audio_play <= 1'b1;
            // Advance the SD card LBA and read in the next sector
            sd_lba_1 <= msu_audio_current_frame;

            // Go! (request a sector from the HPS). 256 WORDS. 512 BYTES.
            sd_rd_1 <= 1'b1;

            msu_audio_state <= msu_audio_state + 1;
            `ifdef debug
            msu_trackmounting_falling <= 0;
            `endif
          end
        end
        1: begin
          // Wait for ACK
          // sd_ack goes high at the start of a sector transfer (and during)
          if (sd_ack[1]) begin
            sd_rd_1 <= 1'b0;
            // Sanity check
            msu_audio_word_count <= 0;
            msu_audio_state <= msu_audio_state + 1;
          end
        end
        2: begin
          // Keep collecting until we hit the buffer limit 
          if (sd_ack[1] && sd_buff_wr) begin
            msu_audio_word_count <= msu_audio_word_count + 1;
          end
          
          if (msu_audio_word_count == sector_size) begin
            msu_audio_word_count <= 0;
            `ifdef debug
            sd_ack[1] <= 0;
            `endif
          end
          
          if (partial_frame_state == 1 && msu_audio_word_count == msu_audio_end_frame_word_offset) begin
            msu_audio_word_count <= 0;
            partial_frame_state <= 2;
            `ifdef debug
            sd_ack[1] <= 0;
            `endif
          end
          
          // Only add new frames if we haven't filled the buffer
          if (!sd_ack[1] && audio_fifo_usedw < 1792) begin
            msu_audio_state <= msu_audio_state + 1;
          end
        end
        3: begin
          // Check if we've reached end_frame yet
          if ((msu_audio_current_frame < msu_audio_end_frame) && msu_audio_play) begin
            msu_audio_current_frame <= msu_audio_current_frame + 1;
            // Fetch another sector
            sd_lba_1 <= sd_lba_1 + 1;
            sd_rd_1 <= 1'b1;
            msu_audio_state <= 1;
            `ifdef debug
            sd_ack[1] <= 1'b1;
            `endif
          end else begin
            msu_audio_state <= msu_audio_state + 1;
          end
        end
        4: begin
          // Final frame handling
          if (msu_audio_play && msu_audio_end_frame_byte_offset == 0 && msu_audio_play) begin
            // Handle a full frame
            if (msu_audio_mode == 8'd1) begin
              debug_expected_high <= 8'd50;
              // Full final frame, stopped
              msu_audio_play <= 0;
              msu_audio_state <= 0;
              sd_lba_1 <= 0;
            end else begin
              // Full final frame, Looped
              // @todo need to deal with loop point that isn't 0
              msu_audio_current_frame <= msu_audio_loop_index_frame;
              sd_lba_1 <= 0;
              sd_rd_1 <= 1'b1;
              msu_audio_state <= 1;
              `ifdef debug
              sd_ack[1] <= 1'b1;
              `endif
            end
          end else begin
            case (partial_frame_state)
              0: begin
                msu_audio_current_frame <= msu_audio_current_frame + 1;
                sd_lba_1 <= msu_audio_current_frame + 1;
                partial_frame_state <= 8'd1;
              end 
              1: begin
                sd_rd_1 <= 1'b1;
                msu_audio_state <= 1;
                `ifdef debug
                sd_ack[1] <= 1'b1;
                `endif
              end
              2: begin
                if (msu_audio_mode == 8'd1) begin
                  // Stop
                  msu_audio_play <= 0;
                  msu_audio_state <= 0;
                  sd_lba_1 <= 0;
                  partial_frame_state <= 0;
                end else begin
                  // Loop
                  msu_audio_current_frame <= 0;
                  msu_audio_play <= 1;
                  msu_audio_state <= 1;
                  sd_rd_1 <= 1'b1;
                  sd_lba_1 <= 0;
                  partial_frame_state <= 0;
                  `ifdef debug
                  sd_ack[1] <= 1'b1;
                  `endif
                end
              end
            endcase
          end
        end 
        default:; // Do nothing but wait
      endcase
    end	
  end // Ends clocked block

endmodule
