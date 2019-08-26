`define debug = 1;

module msu_audio(
  input clk,
  input reset,
  
  `ifndef debug
  input [31:0] img_size,
  input msu_trig_play,
  input [3:0] sd_ack,
  input msu_repeat_out,
  input msu_trackmounting_falling,
  input sd_buff_wr,
  input [11:0] audio_fifo_usedw,
  `endif
  
  // Used to tell sd card handling which LBA to jump to
  output [20:0] sd_lba_1,
  // Allows us to skip over samples when loop points are not on a sector boundary
  output ignore_sd_buffer_out,
  output sd_rd_1 // Needs to be wired to sd_rd[1] in consumer of this module
);

  reg ignore_sd_buffer_out = 0;
  reg [20:0] current_frame = 21'd0;
  reg [20:0] end_frame = 21'd2097151;
  
  `ifndef debug
  reg audio_play = 0;
  reg [31:0] loop_index = 32'd0;
  reg [31:0] img_size = 32'd0;
  reg [8:0] sector_size_words = 9'd256;
  `endif
  
  `ifdef debug
  ///////////////////////////////////////////////
  // Debug testing things... please ignore if you
  // are not running this in 8bitworkshop
  // Assumed we are playing
  reg audio_play = 0;
  reg trig_play = 1;
  reg trackmounting_falling = 1;
  // Assumed image size
  reg [63:0] img_size = 64'd2048;
  // force repeating when high
  reg repeat_out = 1;
  // loop point in samples (not minus the 8 byte header)
  reg [31:0] loop_index = 32'd20;
  reg [1:0] sd_ack = 0;
  reg [1:0] sd_rd = 0;
  reg sd_buff_wr = 1;
  reg [31:0] audio_fifo_usedw = 32'd0;
  // Typically this is 512 bytes
  reg [8:0] sector_size_words = 9'd64;
  ///////////////////////////////////////////////
  `endif
  
  // End frame handling
  // Have to be careful we don't go to negative one here?
  reg [8:0] end_frame_byte_offset;
  assign end_frame = (img_size[20:0] >> 9) - 1;
  assign end_frame_byte_offset = img_size[8:0];
  wire [8:0] end_frame_word_offset = end_frame_byte_offset / 2;
  reg [7:0] partial_frame_state = 0'd0;
  
  // Loop handling
  wire [20:0] loop_frame = loop_index[20:0] >> 9;
  wire [8:0] loop_frame_word_offset = loop_index[8:0];
  reg looping = 0;
  
  reg [7:0] mode = 0'd0;
  reg [7:0] state = 0'd0;
  // 256 WORDS in a 512 byte sector
  reg [8:0] word_count = 9'd0;
  
  always @(posedge clk) begin
    // We have a trigger to play...
    if (reset || trig_play) begin
      // Stop any existing audio playback
      current_frame <= 0;
      state <= 0;
      audio_play <= 0;
      word_count <= 0;
      sd_lba_1 <= 0;
      partial_frame_state <= 0;
      looping <= 0;
      // Work out the audio playback mode
      if (!repeat_out) begin
        // Audio is not repeating and will stop
        mode <= 8'd1;
      end else begin
        // Audio is repeating
        mode <= 8'd2;
      end
      `ifdef debug
      sd_ack[1] <= 1'b1;
      trig_play <= 0;
      `endif
    end else begin
      case (state)
        0: begin
          // Audio track has finished mounting
          if (trackmounting_falling) begin
            audio_play <= 1'b1;
            // Advance the SD card LBA and read in the next sector
            sd_lba_1 <= current_frame;
            // Go! (request a sector from the HPS). 256 WORDS. 512 BYTES.
            sd_rd_1 <= 1'b1;
            state <= state + 1;
            `ifdef debug
            trackmounting_falling <= 0;
            `endif
          end
        end
        1: begin
          // Wait for ACK
          // sd_ack goes high at the start of a sector transfer (and during)
          if (sd_ack[1]) begin
            sd_rd_1 <= 1'b0;
            // Sanity check
            word_count <= 0;
            state <= state + 1;
          end
        end
        2: begin
          // Keep collecting words until we hit the buffer limit 
          if (sd_ack[1] && sd_buff_wr) begin
            word_count <= word_count + 1;
            if (looping) begin
              // We may need to deal with some remainder samples after the loop frame
              if (word_count < loop_frame_word_offset) begin
                ignore_sd_buffer_out <= 1;
              end else begin
                looping <= 0;
                ignore_sd_buffer_out <= 0;
              end
            end
          end
          if (word_count == sector_size_words) begin
            word_count <= 0;
            `ifdef debug
            sd_ack[1] <= 0;
            `endif
          end
          if (partial_frame_state == 1 && word_count == end_frame_word_offset) begin
            word_count <= 0;
            partial_frame_state <= 2;
            `ifdef debug
            sd_ack[1] <= 0;
            `endif
          end
          // Only add new frames if we haven't filled the buffer
          if (!sd_ack[1] && audio_fifo_usedw < 1792) begin
            state <= state + 1;
          end
        end
        3: begin
          // Check if we've reached end_frame yet
          if ((current_frame < end_frame) && audio_play) begin
            current_frame <= current_frame + 1;
            // Fetch another sector
            sd_lba_1 <= sd_lba_1 + 1;
            sd_rd_1 <= 1'b1;
            state <= 1;
            `ifdef debug
            sd_ack[1] <= 1'b1;
            `endif
          end else begin
            state <= state + 1;
          end
        end
        4: begin
          // Final frame handling
          if (audio_play && end_frame_byte_offset == 0) begin
            // Handle a full frame
            if (mode == 8'd1) begin
              // Full final frame, stopped
              audio_play <= 0;
              state <= 0;
              sd_lba_1 <= 0;
              looping <= 0;
            end else begin
              // Full final frame, Looped
              current_frame <= loop_frame;
              sd_lba_1 <= 0;
              sd_rd_1 <= 1'b1;
              state <= 1;
              looping <= 1;
              `ifdef debug
              sd_ack[1] <= 1'b1;
              `endif
            end
          end else begin
            case (partial_frame_state)
              0: begin
                // Move to the partial frame, which will be the last full frame + 1
                current_frame <= current_frame + 1;
                sd_lba_1 <= current_frame + 1;
                partial_frame_state <= 8'd1;
              end 
              1: begin
                // Keep reading bytes from the file for the partial frame
                sd_rd_1 <= 1'b1;
                state <= 1;
                `ifdef debug
                sd_ack[1] <= 1'b1;
                `endif
              end
              2: begin
                // We've reached the end of the partial frame now.. handle stopping/looping
                if (mode == 8'd1) begin
                  // Stopping
                  audio_play <= 0;
                  state <= 0;
                  sd_lba_1 <= 0;
                  partial_frame_state <= 0;
                end else begin
                  // Loop
                  looping <= 1;
                  if (loop_frame == 0) begin
                    // Loop frame is zero, so just go back to 0
                    partial_frame_state <= 0;
                    current_frame <= 0;  
                    sd_lba_1 <= 0;
                  end else begin
                    // Our loop point is a non-zero sample, go back to the loop frame first 
                    current_frame <= loop_frame;
                    sd_lba_1 <= loop_frame;
                    // We will deal with loop frame word offsets above
                  end
                  word_count <= 0;
                  audio_play <= 1;
                  state <= 1;
                  sd_rd_1 <= 1'b1;
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