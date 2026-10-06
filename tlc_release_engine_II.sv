//==============================================================================
// tlc_release_engine.sv
//
// TileLink-C Release Engine
//
// Supports:
//   * Release
//   * ReleaseData
//   * Source-ID correlation
//   * Cache-line alignment checking
//   * Byte-mask validation
//   * Dirty-data validation
//   * Directory update request
//   * C-channel Release generation
//   * Release completion
//   * Timeout detection
//   * Protocol / malformed transaction detection
//
// Intended architecture:
//
//                    A CHANNEL
//                        |
//                        v
//               +-------------------+
//               | tlc_release_engine|
//               +---------+---------+
//                         |
//              +----------+----------+
//              |                     |
//              v                     v
//       directory update       C CHANNEL
//              |                     |
//              v                     v
//        directory/state       ReleaseData
//
// IMPORTANT:
//   This module assumes tlc_c_channel.sv performs the physical TileLink
//   channel packing. This engine operates on normalized transaction fields.
//
//==============================================================================

module tlc_release_engine #(
  parameter int unsigned ADDR_W =
      48,

  parameter int unsigned DATA_W =
      256,

  parameter int unsigned SOURCE_W =
      8,

  parameter int unsigned CLIENT_W =
      4,

  parameter int unsigned NUM_CLIENTS =
      8,

  parameter int unsigned CACHE_LINE_BYTES =
      DATA_W / 8,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_TIMEOUT =
      1'b1,

  parameter bit ENABLE_ASSERTIONS =
      1'b1,

  parameter bit ALLOW_RELEASE_WITHOUT_DATA =
      1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // A-channel Release input
  //==========================================================================

  input  logic                    a_valid,
  output logic                    a_ready,

  input  logic [ADDR_W-1:0]       a_address,
  input  logic [SOURCE_W-1:0]     a_source,

  input  logic [CLIENT_W-1:0]     a_requester,

  input  logic [2:0]              a_opcode,
  input  logic [2:0]              a_param,

  input  logic [DATA_W-1:0]       a_data,
  input  logic [DATA_W/8-1:0]     a_mask,

  input  logic                    a_is_release,
  input  logic                    a_is_release_data,

  //==========================================================================
  // Directory update interface
  //==========================================================================

  output logic                    dir_valid,
  input  logic                    dir_ready,

  output logic [ADDR_W-1:0]       dir_address,
  output logic [SOURCE_W-1:0]     dir_source,

  output logic [CLIENT_W-1:0]     dir_client,

  output logic                    dir_has_data,
  output logic                    dir_dirty,

  output logic [DATA_W-1:0]       dir_data,
  output logic [DATA_W/8-1:0]     dir_mask,

  input  logic                    dir_accept,
  input  logic                    dir_error,

  //==========================================================================
  // C-channel Release output
  //==========================================================================

  output logic                    c_valid,
  input  logic                    c_ready,

  output logic [ADDR_W-1:0]       c_address,
  output logic [SOURCE_W-1:0]     c_source,

  output logic [CLIENT_W-1:0]     c_client,

  output logic [2:0]              c_opcode,
  output logic [2:0]              c_param,

  output logic                    c_data_valid,
  output logic [DATA_W-1:0]       c_data,

  output logic [DATA_W/8-1:0]     c_mask,

  //==========================================================================
  // Completion
  //==========================================================================

  output logic                    complete_valid,
  input  logic                    complete_ready,

  output logic [SOURCE_W-1:0]     complete_source,

  output logic [CLIENT_W-1:0]     complete_client,

  //==========================================================================
  // Status
  //==========================================================================

  output logic                    busy,

  output logic                    directory_pending,

  output logic                    release_pending,

  output logic                    release_sent,

  //==========================================================================
  // Errors
  //==========================================================================

  output logic                    illegal_opcode,
  output logic                    malformed_transaction,
  output logic                    alignment_error,
  output logic                    mask_error,
  output logic                    source_error,
  output logic                    directory_error,
  output logic                    timeout_error,

  output logic                    protocol_error
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // TileLink normalized A opcodes
  //
  // Keep these synchronized with tlc_pkg.sv.
  //==========================================================================

  localparam logic [2:0] A_RELEASE =
      3'd5;

  localparam logic [2:0] A_RELEASE_DATA =
      3'd6;


  //==========================================================================
  // TileLink normalized C opcodes
  //
  // Physical encoding should be centralized in tlc_pkg.sv.
  //==========================================================================

  localparam logic [2:0] C_RELEASE =
      3'd4;

  localparam logic [2:0] C_RELEASE_DATA =
      3'd5;


  //==========================================================================
  // FSM
  //==========================================================================

  typedef enum logic [2:0] {

    ST_IDLE      = 3'd0,

    ST_VALIDATE  = 3'd1,

    ST_DIRECTORY = 3'd2,

    ST_RELEASE   = 3'd3,

    ST_COMPLETE  = 3'd4,

    ST_ERROR     = 3'd5

  } state_e;

  state_e state_q;
  state_e state_d;


  //==========================================================================
  // Latched transaction
  //==========================================================================

  logic [ADDR_W-1:0]      address_q;

  logic [SOURCE_W-1:0]    source_q;

  logic [CLIENT_W-1:0]    client_q;

  logic [2:0]             opcode_q;

  logic [2:0]             param_q;

  logic [DATA_W-1:0]      data_q;

  logic [BYTE_W-1:0]      mask_q;

  logic                   has_data_q;

  logic                   dirty_q;


  //==========================================================================
  // Transaction progress
  //==========================================================================

  logic directory_done_q;

  logic release_sent_q;

  logic completion_q;


  //==========================================================================
  // Error state
  //==========================================================================

  logic illegal_opcode_q;

  logic malformed_q;

  logic alignment_error_q;

  logic mask_error_q;

  logic source_error_q;

  logic directory_error_q;

  logic timeout_error_q;


  //==========================================================================
  // Timeout counter
  //==========================================================================

  logic [TIMEOUT_W-1:0] age_q;


  //==========================================================================
  // Handshakes
  //==========================================================================

  logic a_fire;

  logic dir_fire;

  logic c_fire;

  logic complete_fire;


  assign a_fire =
      a_valid &&
      a_ready;


  assign dir_fire =
      dir_valid &&
      dir_ready;


  assign c_fire =
      c_valid &&
      c_ready;


  assign complete_fire =
      complete_valid &&
      complete_ready;


  //==========================================================================
  // A-channel acceptance
  //==========================================================================

  assign a_ready =
      (state_q == ST_IDLE);


  //==========================================================================
  // Opcode validation
  //==========================================================================

  always_comb begin

    illegal_opcode =
        1'b0;

    if (a_fire) begin

      if (
        !a_is_release &&
        !a_is_release_data
      ) begin

        illegal_opcode =
            1'b1;

      end

      if (
        (a_opcode != A_RELEASE) &&
        (a_opcode != A_RELEASE_DATA)
      ) begin

        illegal_opcode =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Release type consistency
  //==========================================================================

  always_comb begin

    malformed_transaction =
        1'b0;

    if (a_fire) begin

      if (
        a_is_release &&
        a_is_release_data
      ) begin

        malformed_transaction =
            1'b1;

      end

      if (
        a_is_release &&
        (a_opcode != A_RELEASE)
      ) begin

        malformed_transaction =
            1'b1;

      end

      if (
        a_is_release_data &&
        (a_opcode != A_RELEASE_DATA)
      ) begin

        malformed_transaction =
            1'b1;

      end

      if (
        a_requester >= NUM_CLIENTS
      ) begin

        malformed_transaction =
            1'b1;

      end

      if ($isunknown(a_source)) begin

        malformed_transaction =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Address alignment
  //==========================================================================

  always_comb begin

    alignment_error =
        1'b0;

    if (a_fire) begin

      if (
        (a_address % CACHE_LINE_BYTES) != 0
      ) begin

        alignment_error =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Byte-mask validation
  //==========================================================================

  always_comb begin

    mask_error =
        1'b0;

    if (a_fire) begin

      if (a_is_release_data) begin

        // ReleaseData must contain at least one valid byte.

        if (a_mask == '0) begin

          mask_error =
              1'b1;

        end

      end
      else begin

        // Release without data must not claim byte data.

        if (a_mask != '0) begin

          mask_error =
              1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Source validation
  //==========================================================================

  always_comb begin

    source_error =
        1'b0;

    if (a_fire) begin

      if ($isunknown(a_source)) begin

        source_error =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Directory update interface
  //==========================================================================

  always_comb begin

    dir_valid =
        1'b0;

    dir_address =
        address_q;

    dir_source =
        source_q;

    dir_client =
        client_q;

    dir_has_data =
        has_data_q;

    dir_dirty =
        dirty_q;

    dir_data =
        data_q;

    dir_mask =
        mask_q;


    if (state_q == ST_DIRECTORY) begin

      dir_valid =
          1'b1;

    end

  end


  //==========================================================================
  // C-channel Release
  //==========================================================================

  always_comb begin

    c_valid =
        1'b0;

    c_address =
        address_q;

    c_source =
        source_q;

    c_client =
        client_q;

    c_opcode =
        has_data_q ?
        C_RELEASE_DATA :
        C_RELEASE;

    c_param =
        param_q;

    c_data_valid =
        has_data_q;

    c_data =
        data_q;

    c_mask =
        mask_q;


    if (state_q == ST_RELEASE &&
        !release_sent_q) begin

      c_valid =
          1'b1;

    end

  end


  //==========================================================================
  // FSM next-state logic
  //==========================================================================

  always_comb begin

    state_d =
        state_q;

    case (state_q)

      //======================================================================
      // IDLE
      //======================================================================

      ST_IDLE: begin

        if (a_fire) begin

          if (
            illegal_opcode ||
            malformed_transaction ||
            alignment_error ||
            mask_error ||
            source_error
          ) begin

            state_d =
                ST_ERROR;

          end
          else begin

            state_d =
                ST_VALIDATE;

          end

        end

      end


      //======================================================================
      // VALIDATE
      //======================================================================

      ST_VALIDATE: begin

        if (
          illegal_opcode_q ||
          malformed_q ||
          alignment_error_q ||
          mask_error_q ||
          source_error_q
        ) begin

          state_d =
              ST_ERROR;

        end
        else begin

          state_d =
              ST_DIRECTORY;

        end

      end


      //======================================================================
      // DIRECTORY UPDATE
      //======================================================================

      ST_DIRECTORY: begin

        if (dir_fire) begin

          if (dir_error) begin

            state_d =
                ST_ERROR;

          end
          else begin

            state_d =
                ST_RELEASE;

          end

        end

      end


      //======================================================================
      // C-channel Release
      //======================================================================

      ST_RELEASE: begin

        if (c_fire) begin

          state_d =
              ST_COMPLETE;

        end

      end


      //======================================================================
      // COMPLETION
      //======================================================================

      ST_COMPLETE: begin

        if (complete_fire) begin

          state_d =
              ST_IDLE;

        end

      end


      //======================================================================
      // ERROR
      //======================================================================

      ST_ERROR: begin

        // Explicit reset recovery.

        state_d =
            ST_ERROR;

      end


      default: begin

        state_d =
            ST_ERROR;

      end

    endcase

  end


  //==========================================================================
  // Sequential state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      state_q <=
          ST_IDLE;

      address_q <=
          '0;

      source_q <=
          '0;

      client_q <=
          '0;

      opcode_q <=
          '0;

      param_q <=
          '0;

      data_q <=
          '0;

      mask_q <=
          '0;

      has_data_q <=
          1'b0;

      dirty_q <=
          1'b0;

      directory_done_q <=
          1'b0;

      release_sent_q <=
          1'b0;

      completion_q <=
          1'b0;

      illegal_opcode_q <=
          1'b0;

      malformed_q <=
          1'b0;

      alignment_error_q <=
          1'b0;

      mask_error_q <=
          1'b0;

      source_error_q <=
          1'b0;

      directory_error_q <=
          1'b0;

      timeout_error_q <=
          1'b0;

      age_q <=
          '0;

    end
    else begin

      //======================================================================
      // Completion is a one-cycle pulse.
      //======================================================================

      completion_q <=
          1'b0;


      //======================================================================
      // Timeout age
      //======================================================================

      if (state_q != ST_IDLE) begin

        if (ENABLE_TIMEOUT) begin

          if (
            age_q <
            TIMEOUT_CYCLES[TIMEOUT_W-1:0]
          ) begin

            age_q <=
                age_q + 1'b1;

          end

        end

      end
      else begin

        age_q <=
            '0;

      end


      //======================================================================
      // Capture incoming Release
      //======================================================================

      if (a_fire) begin

        address_q <=
            a_address;

        source_q <=
            a_source;

        client_q <=
            a_requester;

        opcode_q <=
            a_opcode;

        param_q <=
            a_param;

        data_q <=
            a_data;

        mask_q <=
            a_mask;

        has_data_q <=
            a_is_release_data;

        // A ReleaseData is carrying data being surrendered by the client.
        // It is therefore treated as dirty ownership information at this
        // engine boundary.

        dirty_q <=
            a_is_release_data;

        illegal_opcode_q <=
            illegal_opcode;

        malformed_q <=
            malformed_transaction;

        alignment_error_q <=
            alignment_error;

        mask_error_q <=
            mask_error;

        source_error_q <=
            source_error;

        directory_error_q <=
            1'b0;

        timeout_error_q <=
            1'b0;

        directory_done_q <=
            1'b0;

        release_sent_q <=
            1'b0;

      end


      //======================================================================
      // Directory accepted Release
      //======================================================================

      if (dir_fire) begin

        if (dir_error) begin

          directory_error_q <=
              1'b1;

        end
        else begin

          directory_done_q <=
              1'b1;

        end

      end


      //======================================================================
      // C-channel accepted Release
      //======================================================================

      if (c_fire) begin

        release_sent_q <=
            1'b1;

      end


      //======================================================================
      // Timeout
      //======================================================================

      if (
        ENABLE_TIMEOUT &&
        age_q >= TIMEOUT_CYCLES[TIMEOUT_W-1:0]
      ) begin

        timeout_error_q <=
            1'b1;

      end


      //======================================================================
      // Completion
      //======================================================================

      if (
        state_q == ST_COMPLETE
      ) begin

        completion_q <=
            1'b1;

      end

    end

  end


  //==========================================================================
  // Completion interface
  //==========================================================================

  assign complete_valid =
      (state_q == ST_COMPLETE) &&
      directory_done_q &&
      release_sent_q &&
      !protocol_error;

  assign complete_source =
      source_q;

  assign complete_client =
      client_q;


  //==========================================================================
  // Status
  //==========================================================================

  assign busy =
      (state_q != ST_IDLE);

  assign directory_pending =
      (state_q == ST_DIRECTORY);

  assign release_pending =
      (state_q == ST_RELEASE) &&
      !release_sent_q;

  assign release_sent =
      release_sent_q;


  //==========================================================================
  // Errors
  //==========================================================================

  assign illegal_opcode =
      illegal_opcode_q;

  assign malformed_transaction =
      malformed_q;

  assign alignment_error =
      alignment_error_q;

  assign mask_error =
      mask_error_q;

  assign source_error =
      source_error_q;

  assign directory_error =
      directory_error_q;

  assign timeout_error =
      timeout_error_q;


  assign protocol_error =
      illegal_opcode_q ||
      malformed_q ||
      alignment_error_q ||
      mask_error_q ||
      source_error_q ||
      directory_error_q ||
      timeout_error_q;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_RELEASE_ASSERTIONS

      //--------------------------------------------------------------------
      // Only accept A-channel request while idle.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> (state_q == ST_IDLE)
      )
      else $error(
        "TLC RELEASE: A request accepted outside IDLE"
      );


      //--------------------------------------------------------------------
      // Exactly one Release type.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> (a_is_release ^ a_is_release_data)
      )
      else $error(
        "TLC RELEASE: invalid Release type"
      );


      //--------------------------------------------------------------------
      // Release opcode consistency.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire &&
        a_is_release
        |-> (a_opcode == A_RELEASE)
      )
      else $error(
        "TLC RELEASE: Release opcode mismatch"
      );


      //--------------------------------------------------------------------
      // ReleaseData opcode consistency.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire &&
        a_is_release_data
        |-> (a_opcode == A_RELEASE_DATA)
      )
      else $error(
        "TLC RELEASE: ReleaseData opcode mismatch"
      );


      //--------------------------------------------------------------------
      // Address must be cache-line aligned.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> ((a_address % CACHE_LINE_BYTES) == 0)
      )
      else $error(
        "TLC RELEASE: cache-line alignment error"
      );


      //--------------------------------------------------------------------
      // Requester must be legal.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> (a_requester < NUM_CLIENTS)
      )
      else $error(
        "TLC RELEASE: invalid requester"
      );


      //--------------------------------------------------------------------
      // ReleaseData must contain data.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire &&
        a_is_release_data
        |-> (a_mask != '0)
      )
      else $error(
        "TLC RELEASE: ReleaseData has empty byte mask"
      );


      //--------------------------------------------------------------------
      // Release without data must have zero mask.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire &&
        a_is_release
        |-> (a_mask == '0)
      )
      else $error(
        "TLC RELEASE: Release without data contains byte mask"
      );


      //--------------------------------------------------------------------
      // C-channel must preserve source.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_valid
        |-> (c_source == source_q)
      )
      else $error(
        "TLC RELEASE: C source mismatch"
      );


      //--------------------------------------------------------------------
      // C-channel client must preserve requester.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_valid
        |-> (c_client == client_q)
      )
      else $error(
        "TLC RELEASE: C client mismatch"
      );


      //--------------------------------------------------------------------
      // ReleaseData must use ReleaseData opcode.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_valid &&
        c_data_valid
        |-> (c_opcode == C_RELEASE_DATA)
      )
      else $error(
        "TLC RELEASE: ReleaseData opcode mismatch"
      );


      //--------------------------------------------------------------------
      // Release without data must not have data valid.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_valid &&
        !has_data_q
        |-> !c_data_valid
      )
      else $error(
        "TLC RELEASE: data unexpectedly present"
      );


      //--------------------------------------------------------------------
      // Completion requires directory update and C transmission.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_valid
        |-> (
          directory_done_q &&
          release_sent_q
        )
      )
      else $error(
        "TLC RELEASE: completion before directory/C completion"
      );


      //--------------------------------------------------------------------
      // Completion cannot occur with error.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(complete_valid && protocol_error)
      )
      else $error(
        "TLC RELEASE: completion with protocol error"
      );


      //--------------------------------------------------------------------
      // Busy must prevent new A transaction.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        busy
        |-> !a_ready
      )
      else $error(
        "TLC RELEASE: A ready asserted while busy"
      );


      //--------------------------------------------------------------------
      // Reset must return to IDLE.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (state_q == ST_IDLE)
      )
      else $error(
        "TLC RELEASE: reset did not return to IDLE"
      );


      //--------------------------------------------------------------------
      // Release cannot be transmitted before directory acceptance.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_valid
        |-> directory_done_q
      )
      else $error(
        "TLC RELEASE: C Release before directory update"
      );


      //--------------------------------------------------------------------
      // Release sent only once.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        release_sent_q
        |-> !c_valid
      )
      else $error(
        "TLC RELEASE: duplicate C Release transmission"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static parameter checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC RELEASE: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC RELEASE: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC RELEASE: DATA_W must be byte aligned"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC RELEASE: SOURCE_W must be > 0"
      );

    if (CLIENT_W == 0)
      $error(
        "TLC RELEASE: CLIENT_W must be > 0"
      );

    if (NUM_CLIENTS == 0)
      $error(
        "TLC RELEASE: NUM_CLIENTS must be > 0"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC RELEASE: CACHE_LINE_BYTES must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC RELEASE: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule