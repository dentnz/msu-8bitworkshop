module msu_audio(
  input clk,
  input reset,
  
  //output test results.. these will be removed in final code
  output [8:0] msu_audio_end_frame_byte_offset,
  output msu_audio_end_frame,
  output debug_expected_high, 
  output msu_audio_state,
  output msu_audio_mode,
  output msu_trig_play,
  output sd_lba_1
);

  
  reg [20:0] msu_audio_current_frame = 21'd0;
  reg [20:0] msu_audio_end_frame = 21'd2097151;
  reg [20:0] sd_lba_1 = 21'd0;
  
  // Following are test values
  //////////////////////////////////////////////
  // Assumed we are playing
  reg msu_audio_play = 1;
  reg msu_trig_play = 1;
  reg msu_trackmounting_falling = 1;
  // Assumed image size
  //reg [63:0] img_size = 64'd2560;
  reg [63:0] img_size = 64'd2048;
  // force repeating when high
  reg msu_repeat_out = 1;
  // loop point is first sample
  reg [31:0] msu_audio_loop_index = 32'd0;
  reg [1:0] sd_ack = 0;
  reg [1:0] sd_rd = 0;
  reg sd_buff_wr = 1;
  reg [31:0] audio_fifo_usedw = 32'd0;
  
  //////////////////////////////////////////////
  
  // Have to be careful we don't go to negative one here?
  assign msu_audio_end_frame = (img_size[20:0] >> 9) - 1;
  assign msu_audio_end_frame_byte_offset = img_size[8:0];
  wire [20:0] msu_audio_loop_index_frame = msu_audio_loop_index[20:0] >> 7; 
  
  reg [8:0] msu_audio_mode = 0'd0;
  reg [8:0] msu_audio_state = 0'd0;
  reg [7:0] msu_audio_word_count = 8'd0;	

  always @(posedge clk) begin
    debug_expected_high <= 0;
    // We have a trigger to play...
    if (msu_trig_play) begin
      // Stop any existing audio playback
      msu_audio_current_frame <= 0;
      msu_audio_state <= 0;
      msu_audio_play <= 0;
      sd_ack[1] <= 1'b1;
      // Work out the audio playback mode
      if (!msu_repeat_out) begin
        msu_audio_mode <= 1;
      end else begin
        msu_audio_mode <= 2;
      end
      // This would normally happen on the next few clock cycles - hardcoding for now
      msu_trig_play <= 0; // @todo remove this
      //msu_audio_loop_index <= 0;
    end else begin
      case (msu_audio_state)
        0: begin
          if (msu_trackmounting_falling) begin
            msu_audio_play <= 1'b1;
            // Advance the SD card LBA and read in the next sector
            sd_lba_1 <= msu_audio_current_frame;
            // Determine audio playback mode

            // Go! (request a sector from the HPS). 256 WORDS. 512 BYTES.
            sd_rd[1] <= 1'b1;

            msu_audio_state <= msu_audio_state + 1;
            msu_trackmounting_falling <= 0; // @todo remove this
          end
        end
        1: begin
          // sd_ack goes high at the start of a sector transfer (and during)
          if (sd_ack[1]) begin
            sd_rd[1] <= 1'b0;
            // Sanity check
            msu_audio_word_count <= 0;
            msu_audio_state <= msu_audio_state + 1;
          end
        end
        2: begin
          if (sd_ack[1] && sd_buff_wr) begin
            msu_audio_word_count <= msu_audio_word_count + 1;
            // @todo remove the next line in non-test mode
            sd_ack[1] <= 0; // remove this
          end
           
          if (!sd_ack[1] && audio_fifo_usedw < 1792) begin
            // Check if we've reached end_frame yet (and msu_audio_play is still set).
            if ((msu_audio_current_frame < msu_audio_end_frame - 2) && msu_audio_play) begin
              msu_audio_current_frame <= msu_audio_current_frame + 1;
              // Fetch another sector
              sd_lba_1 <= sd_lba_1 + 1;
              sd_rd[1] <= 1'b1;
              // @todo remove the next line
              sd_ack[1] <= 1'b1; // remove this
              msu_audio_state <= 1;
            end else if (msu_audio_play && msu_audio_end_frame_byte_offset == 0 && msu_audio_current_frame != msu_audio_end_frame) begin
              msu_audio_current_frame <= msu_audio_current_frame + 1;
              // fetch the final *full* sector
              sd_lba_1 <= sd_lba_1 + 1;
              sd_rd[1] <= 1'b1;
              // @todo remove the next line
              sd_ack[1] <= 1'b1; // remove this
              msu_audio_state <= 1;
            end else if (msu_audio_play && msu_audio_end_frame_byte_offset != 0 && msu_audio_current_frame != msu_audio_end_frame) begin
              // We have a final *partial* sector to deal with
              if (sd_lba_1 == msu_audio_end_frame) begin
                // We have the entire last frame, put the last remaining bytes into the buffer?
              end else begin
                // Read the entire last frame
                sd_lba_1 <= sd_lba_1 + 1;
                sd_rd[1] <= 1'b1;
                // @todo remove the next line
                sd_ack[1] <= 1'b1; // remove this
                msu_audio_state <= 1;
              end
     
            end else begin
              // We have reached the end of audio track playback... what do we do next?
              case (msu_audio_mode)
                // Audio not repeating. stop
                1: begin 
                  // set our status to not audio_playing
                  msu_audio_play <= 0;
                  msu_audio_state <= 0;
                end
                // Audio repeating
                2: begin
                  // Set back to the start frame
                  msu_audio_current_frame <= msu_audio_loop_index_frame;
                  sd_lba_1 <= 0;
                end
              endcase
            end
          end
        end
        default:; // Do nothing but wait
      endcase
    end	
  end // Ends clocked block

endmodule
