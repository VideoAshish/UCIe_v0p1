//==============================================================================
// tlc_acquire_engine.sv
//
// TileLink-C Acquire Engine
//
// Handles:
//   * AcquireBlock
//   * AcquirePerm
//   * Source-ID allocation
//   * Address/alignment validation
//   * Permission validation
//   * Partial-byte-mask validation
//   * Outstanding Acquire tracking
//   * Probe-engine request generation
//   * Grant correlation
//   * Timeout detection
//   * Protocol-error detection
//
// Intended architecture:
//
//   A Channel
//      |
//      v
//   tlc_acquire_engine
//      |
//      +---- tlc_source_table
//      |
//      +---- tlc_txn_table
//      |
//      +---- tlc_permission_mgr
//      |
//      +---- tlc_probe_engine
//      |
//      +---- D Channel / Grant path
//
// Notes:
//   This module deliberately uses decoupled interfaces at every boundary.
//   No ready signal depends combinationally on a downstream valid signal.
//
//==============================================================================

module tlc_acquire_engine #(
  parameter int unsigned ADDR_W          = 48,
  parameter int unsigned DATA_W          = 256,
  parameter int unsigned SOURCE_W        = 8,
  parameter int unsigned SINK_W          = 8,
  parameter int unsigned CLIENT_W        = 4,

  parameter int unsigned NUM_CLIENTS     = 8,
  parameter int unsigned MAX_OUTSTANDING = 16,

  parameter int unsigned CACHE_LINE_BYTES =
      DATA_W / 8,

  parameter int unsigned TIMEOUT_CYCLES  = 100000,

  parameter bit ENABLE_TIMEOUT           = 1'b1,
  parameter bit ENABLE_ASSERTIONS        = 1'b1,

  parameter bit ALLOW_PARTIAL_WRITE      = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // A-channel input
  //
  // These signals are normalized from tlc_a_channel.sv.
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

  //==========================================================================
  // Acquire type
  //
  // These are derived from A opcode by the channel adapter.
  //==========================================================================

  input  logic                    a_is_acquire_block,
  input  logic                    a_is_acquire_perm,

  //==========================================================================
  // Current requester permission/state
  //
  // Provided by tlc_permission_mgr / directory.
  //==========================================================================

  input  logic [2:0]              requester_permission,

  input  logic                    requester_has_data,

  //==========================================================================
  // Directory lookup
  //==========================================================================

  output logic                    dir_lookup_valid,
  input  logic                    dir_lookup_ready,

  output logic [ADDR_W-1:0]       dir_lookup_address,

  input  logic                    dir_hit,

  input  logic [CLIENT_W-1:0]     dir_owner,

  input  logic [NUM_CLIENTS-1:0]  dir_sharers,

  input  logic [2:0]              dir_state,

  input  logic                    dir_dirty,

  //==========================================================================
  // Probe engine request
  //==========================================================================

  output logic                    probe_req_valid,
  input  logic                    probe_req_ready,

  output logic [ADDR_W-1:0]       probe_address,
  output logic [SOURCE_W-1:0]     probe_source,
  output logic [CLIENT_W-1:0]     probe_requester,

  output logic [NUM_CLIENTS-1:0]  probe_targets,

  output logic [2:0]              probe_param,

  output logic                    probe_dirty_required,

  //==========================================================================
  // Grant result
  //
  // This is a normalized D-channel completion interface.
  //==========================================================================

  input  logic                    grant_valid,
  output logic                    grant_ready,

  input  logic [SOURCE_W-1:0]     grant_source,

  input  logic [SINK_W-1:0]       grant_sink,

  input  logic [2:0]              grant_opcode,
  input  logic [2:0]              grant_param,

  input  logic                    grant_data_valid,
  input  logic [DATA_W-1:0]       grant_data,

  //==========================================================================
  // Completion
  //==========================================================================

  output logic                    complete_valid,
  input  logic                    complete_ready,

  output logic [SOURCE_W-1:0]     complete_source,

  output logic [SINK_W-1:0]       complete_sink,

  output logic [2:0]              complete_opcode,

  output logic [2:0]              complete_param,

  output logic                    complete_data_valid,

  output logic [DATA_W-1:0]       complete_data,

  //==========================================================================
  // Transaction status
  //==========================================================================

  output logic                    busy,

  output logic                    outstanding,

  output logic                    probe_pending,

  output logic                    grant_pending,

  //==========================================================================
  // Error reporting
  //==========================================================================

  output logic                    illegal_opcode,

  output logic                    malformed_transaction,

  output logic                    alignment_error,

  output logic                    permission_error,

  output logic                    mask_error,

  output logic                    source_error,

  output logic                    timeout_error,

  output logic                    protocol_error
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned COUNT_W =
      (MAX_OUTSTANDING <= 1) ?
      1 :
      $clog2(MAX_OUTSTANDING + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // Normalized TileLink opcodes
  //
  // Keep these synchronized with tlc_pkg.sv.
  //==========================================================================

  localparam logic [2:0] A_ACQUIRE_BLOCK =
      3'd6;

  localparam logic [2:0] A_ACQUIRE_PERM =
      3'd7;


  //==========================================================================
  // Internal state machine
  //==========================================================================

  typedef enum logic [3:0] {
    ST_IDLE       = 4'd0,
    ST_LOOKUP     = 4'd1,
    ST_VALIDATE   = 4'd2,
    ST_PROBE      = 4'd3,
    ST_GRANT      = 4'd4,
    ST_COMPLETE   = 4'd5,
    ST_ERROR      = 4'd6
  } state_e;

  state_e state_q;
  state_e state_d;


  //==========================================================================
  // Latched transaction
  //==========================================================================

  logic [ADDR_W-1:0]      address_q;
  logic [SOURCE_W-1:0]    source_q;
  logic [CLIENT_W-1:0]    requester_q;

  logic [2:0]             opcode_q;
  logic [2:0]             param_q;

  logic [DATA_W-1:0]      data_q;
  logic [BYTE_W-1:0]      mask_q;

  logic                    is_acquire_block_q;
  logic                    is_acquire_perm_q;

  logic [TIMEOUT_W-1:0]   age_q;


  //==========================================================================
  // Directory snapshot
  //==========================================================================

  logic                    dir_hit_q;

  logic [CLIENT_W-1:0]     dir_owner_q;

  logic [NUM_CLIENTS-1:0] dir_sharers_q;

  logic [2:0]              dir_state_q;

  logic                    dir_dirty_q;


  //==========================================================================
  // Probe information
  //==========================================================================

  logic [NUM_CLIENTS-1:0] probe_targets_q;

  logic                    probe_required_q;

  logic                    probe_done_q;


  //==========================================================================
  // Grant information
  //==========================================================================

  logic                    grant_received_q;

  logic [SINK_W-1:0]       grant_sink_q;

  logic [2:0]              grant_opcode_q;

  logic [2:0]              grant_param_q;

  logic                    grant_data_valid_q;

  logic [DATA_W-1:0]       grant_data_q;


  //==========================================================================
  // Error latches
  //==========================================================================

  logic illegal_opcode_q;
  logic malformed_q;
  logic alignment_error_q;
  logic permission_error_q;
  logic mask_error_q;
  logic source_error_q;
  logic timeout_error_q;


  //==========================================================================
  // Handshake signals
  //==========================================================================

  logic a_fire;
  logic dir_fire;
  logic probe_fire;
  logic grant_fire;
  logic complete_fire;


  assign a_fire =
      a_valid &&
      a_ready;

  assign dir_fire =
      dir_lookup_valid &&
      dir_lookup_ready;

  assign probe_fire =
      probe_req_valid &&
      probe_req_ready;

  assign grant_fire =
      grant_valid &&
      grant_ready;

  assign complete_fire =
      complete_valid &&
      complete_ready;


  //==========================================================================
  // A-channel ready
  //
  // Only accept a new Acquire in IDLE.
  //==========================================================================

  assign a_ready =
      (state_q == ST_IDLE);


  //==========================================================================
  // Directory lookup
  //==========================================================================

  always_comb begin

    dir_lookup_valid =
        1'b0;

    dir_lookup_address =
        address_q;

    if (state_q == ST_LOOKUP) begin

      dir_lookup_valid =
          1'b1;

    end

  end


  //==========================================================================
  // Address alignment check
  //
  // AcquireBlock and AcquirePerm operate on a cache-line granularity.
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
  // Opcode validation
  //==========================================================================

  always_comb begin

    illegal_opcode =
        1'b0;

    if (a_fire) begin

      if (
        !a_is_acquire_block &&
        !a_is_acquire_perm
      ) begin

        illegal_opcode =
            1'b1;

      end

      if (
        a_opcode != A_ACQUIRE_BLOCK &&
        a_opcode != A_ACQUIRE_PERM
      ) begin

        illegal_opcode =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Malformed transaction validation
  //==========================================================================

  always_comb begin

    malformed_transaction =
        1'b0;

    if (a_fire) begin

      // AcquireBlock must carry a coherent cache-line request.
      if (a_is_acquire_block &&
          a_is_acquire_perm) begin

        malformed_transaction =
            1'b1;

      end

      // Source ID cannot be X/invalid.
      if ($isunknown(a_source)) begin

        malformed_transaction =
            1'b1;

      end

      // Requester ID must be representable.
      if (a_requester >= NUM_CLIENTS) begin

        malformed_transaction =
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

      // Acquire operations normally do not carry partial write masks.
      //
      // If the implementation allows partial writes, the mask must contain
      // at least one valid byte.

      if (ALLOW_PARTIAL_WRITE) begin

        if (a_is_acquire_block ||
            a_is_acquire_perm) begin

          if (a_mask == '0) begin

            mask_error =
                1'b1;

          end

        end

      end
      else begin

        if (a_mask != {BYTE_W{1'b1}}) begin

          mask_error =
              1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Permission validation
  //
  // Normalized permission encoding:
  //
  //   000 = none
  //   001 = B
  //   010 = T
  //   011 = N
  //
  // Exact mapping should be centralized in tlc_pkg.sv.
  //==========================================================================

  always_comb begin

    permission_error =
        1'b0;

    if (a_fire) begin

      if (a_is_acquire_block) begin

        // AcquireBlock requires the requester to be able to obtain
        // a block copy.

        if (requester_permission == 3'b000) begin

          permission_error =
              1'b1;

        end

      end

      if (a_is_acquire_perm) begin

        // AcquirePerm requires an existing block / legal permission
        // transition.

        if (!requester_has_data &&
            !dir_hit) begin

          permission_error =
              1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Probe target generation
  //
  // Requester itself must never be probed.
  //
  // AcquireBlock:
  //   probe sharers/owner when another client may hold the line.
  //
  // AcquirePerm:
  //   probe conflicting owners/sharers.
  //==========================================================================

  always_comb begin

    probe_targets_q =
        '0;

    probe_required_q =
        1'b0;


    if (dir_hit_q) begin

      if (is_acquire_block_q) begin

        // Invalidate/collect other copies as required.

        probe_targets_q =
            dir_sharers_q;

        if (dir_dirty_q) begin

          probe_targets_q[dir_owner_q] =
              1'b1;

        end

      end


      if (is_acquire_perm_q) begin

        // Permission upgrade requires conflicting sharers/owner to
        // relinquish permissions.

        probe_targets_q =
            dir_sharers_q;

        probe_targets_q[dir_owner_q] =
            1'b1;

      end

    end


    // Never probe requester.

    if (requester_q < NUM_CLIENTS) begin

      probe_targets_q[requester_q] =
          1'b0;

    end


    probe_required_q =
        (probe_targets_q != '0);

  end


  //==========================================================================
  // Probe engine interface
  //==========================================================================

  always_comb begin

    probe_req_valid =
        1'b0;

    probe_address =
        address_q;

    probe_source =
        source_q;

    probe_requester =
        requester_q;

    probe_targets =
        probe_targets_q;

    probe_param =
        param_q;

    probe_dirty_required =
        dir_dirty_q;


    if (state_q == ST_PROBE &&
        !probe_done_q) begin

      probe_req_valid =
          1'b1;

    end

  end


  //==========================================================================
  // Grant interface
  //==========================================================================

  assign grant_ready =
      (state_q == ST_GRANT);


  //==========================================================================
  // FSM
  //==========================================================================

  always_comb begin

    state_d =
        state_q;

    case (state_q)

      //----------------------------------------------------------------------
      // IDLE
      //----------------------------------------------------------------------

      ST_IDLE: begin

        if (a_fire) begin

          if (
            illegal_opcode ||
            malformed_transaction ||
            alignment_error ||
            permission_error ||
            mask_error
          ) begin

            state_d =
                ST_ERROR;

          end
          else begin

            state_d =
                ST_LOOKUP;

          end

        end

      end


      //----------------------------------------------------------------------
      // DIRECTORY LOOKUP
      //----------------------------------------------------------------------

      ST_LOOKUP: begin

        if (dir_fire) begin

          state_d =
              ST_VALIDATE;

        end

      end


      //----------------------------------------------------------------------
      // VALIDATE DIRECTORY RESULT
      //----------------------------------------------------------------------

      ST_VALIDATE: begin

        if (
          illegal_opcode_q ||
          malformed_q ||
          alignment_error_q ||
          permission_error_q ||
          mask_error_q
        ) begin

          state_d =
              ST_ERROR;

        end
        else if (probe_required_q) begin

          state_d =
              ST_PROBE;

        end
        else begin

          state_d =
              ST_GRANT;

        end

      end


      //----------------------------------------------------------------------
      // PROBE
      //----------------------------------------------------------------------

      ST_PROBE: begin

        if (probe_fire) begin

          state_d =
              ST_GRANT;

        end

      end


      //----------------------------------------------------------------------
      // WAIT FOR GRANT
      //----------------------------------------------------------------------

      ST_GRANT: begin

        if (grant_fire) begin

          state_d =
              ST_COMPLETE;

        end

      end


      //----------------------------------------------------------------------
      // COMPLETE
      //----------------------------------------------------------------------

      ST_COMPLETE: begin

        if (complete_fire) begin

          state_d =
              ST_IDLE;

        end

      end


      //----------------------------------------------------------------------
      // ERROR
      //----------------------------------------------------------------------

      ST_ERROR: begin

        // Explicit reset recovery.
        //
        // A production implementation may instead generate an error
        // response on D-channel and return to IDLE.
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
  // Sequential logic
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      state_q <=
          ST_IDLE;

      address_q <=
          '0;

      source_q <=
          '0;

      requester_q <=
          '0;

      opcode_q <=
          '0;

      param_q <=
          '0;

      data_q <=
          '0;

      mask_q <=
          '0;

      is_acquire_block_q <=
          1'b0;

      is_acquire_perm_q <=
          1'b0;

      age_q <=
          '0;

      dir_hit_q <=
          1'b0;

      dir_owner_q <=
          '0;

      dir_sharers_q <=
          '0;

      dir_state_q <=
          '0;

      dir_dirty_q <=
          1'b0;

      probe_done_q <=
          1'b0;

      grant_received_q <=
          1'b0;

      grant_sink_q <=
          '0;

      grant_opcode_q <=
          '0;

      grant_param_q <=
          '0;

      grant_data_valid_q <=
          1'b0;

      grant_data_q <=
          '0;

      illegal_opcode_q <=
          1'b0;

      malformed_q <=
          1'b0;

      alignment_error_q <=
          1'b0;

      permission_error_q <=
          1'b0;

      mask_error_q <=
          1'b0;

      source_error_q <=
          1'b0;

      timeout_error_q <=
          1'b0;

    end
    else begin

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
      // Capture incoming Acquire
      //======================================================================

      if (a_fire) begin

        address_q <=
            a_address;

        source_q <=
            a_source;

        requester_q <=
            a_requester;

        opcode_q <=
            a_opcode;

        param_q <=
            a_param;

        data_q <=
            a_data;

        mask_q <=
            a_mask;

        is_acquire_block_q <=
            a_is_acquire_block;

        is_acquire_perm_q <=
            a_is_acquire_perm;


        //==============================================================
        // Capture validation errors
        //==============================================================

        illegal_opcode_q <=
            illegal_opcode;

        malformed_q <=
            malformed_transaction;

        alignment_error_q <=
            alignment_error;

        permission_error_q <=
            permission_error;

        mask_error_q <=
            mask_error;

        source_error_q <=
            1'b0;

      end


      //======================================================================
      // Directory response capture
      //======================================================================

      if (dir_fire) begin

        dir_hit_q <=
            dir_hit;

        dir_owner_q <=
            dir_owner;

        dir_sharers_q <=
            dir_sharers;

        dir_state_q <=
            dir_state;

        dir_dirty_q <=
            dir_dirty;

      end


      //======================================================================
      // Probe request accepted
      //======================================================================

      if (probe_fire) begin

        probe_done_q <=
            1'b1;

      end


      //======================================================================
      // Grant received
      //======================================================================

      if (grant_fire) begin

        if (grant_source != source_q) begin

          source_error_q <=
              1'b1;

        end
        else begin

          grant_received_q <=
              1'b1;

          grant_sink_q <=
              grant_sink;

          grant_opcode_q <=
              grant_opcode;

          grant_param_q <=
              grant_param;

          grant_data_valid_q <=
              grant_data_valid;

          grant_data_q <=
              grant_data;

        end

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

    end

  end


  //==========================================================================
  // Completion output
  //==========================================================================

  always_comb begin

    complete_valid =
        (state_q == ST_COMPLETE) &&
        grant_received_q &&
        !source_error_q;

    complete_source =
        source_q;

    complete_sink =
        grant_sink_q;

    complete_opcode =
        grant_opcode_q;

    complete_param =
        grant_param_q;

    complete_data_valid =
        grant_data_valid_q;

    complete_data =
        grant_data_q;

  end


  //==========================================================================
  // Status outputs
  //==========================================================================

  assign busy =
      (state_q != ST_IDLE);

  assign outstanding =
      busy;

  assign probe_pending =
      (state_q == ST_PROBE);

  assign grant_pending =
      (state_q == ST_GRANT);


  //==========================================================================
  // Error outputs
  //==========================================================================

  assign timeout_error =
      timeout_error_q;

  assign source_error =
      source_error_q;


  assign protocol_error =
      illegal_opcode_q ||
      malformed_q ||
      alignment_error_q ||
      permission_error_q ||
      mask_error_q ||
      source_error_q ||
      timeout_error_q;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_ACQUIRE_ASSERTIONS

      //--------------------------------------------------------------------
      // A request only accepted while idle.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> (state_q == ST_IDLE)
      )
      else $error(
        "TLC ACQUIRE: A request accepted outside IDLE"
      );


      //--------------------------------------------------------------------
      // Acquire must be one of the supported types.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> (a_is_acquire_block ^ a_is_acquire_perm)
      )
      else $error(
        "TLC ACQUIRE: invalid Acquire type"
      );


      //--------------------------------------------------------------------
      // AcquireBlock and AcquirePerm opcode consistency.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire &&
        a_is_acquire_block
        |-> (a_opcode == A_ACQUIRE_BLOCK)
      )
      else $error(
        "TLC ACQUIRE: AcquireBlock opcode mismatch"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire &&
        a_is_acquire_perm
        |-> (a_opcode == A_ACQUIRE_PERM)
      )
      else $error(
        "TLC ACQUIRE: AcquirePerm opcode mismatch"
      );


      //--------------------------------------------------------------------
      // Address alignment.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> ((a_address % CACHE_LINE_BYTES) == 0)
      )
      else $error(
        "TLC ACQUIRE: cache-line alignment violation"
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
        "TLC ACQUIRE: invalid requester ID"
      );


      //--------------------------------------------------------------------
      // Probe targets cannot contain requester.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_req_valid
        |-> !probe_targets[requester_q]
      )
      else $error(
        "TLC ACQUIRE: requester included in Probe fanout"
      );


      //--------------------------------------------------------------------
      // Probe request source must match Acquire source.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_req_valid
        |-> (probe_source == source_q)
      )
      else $error(
        "TLC ACQUIRE: Probe source mismatch"
      );


      //--------------------------------------------------------------------
      // Grant source must match Acquire source.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_fire
        |-> (grant_source == source_q)
      )
      else $error(
        "TLC ACQUIRE: Grant source mismatch"
      );


      //--------------------------------------------------------------------
      // Cannot accept a new A request while busy.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        busy
        |-> !a_ready
      )
      else $error(
        "TLC ACQUIRE: busy engine asserted A ready"
      );


      //--------------------------------------------------------------------
      // Completion only after Grant.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_valid
        |-> grant_received_q
      )
      else $error(
        "TLC ACQUIRE: completion without Grant"
      );


      //--------------------------------------------------------------------
      // Timeout is only possible for an outstanding transaction.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        timeout_error_q
        |-> busy
      )
      else $error(
        "TLC ACQUIRE: timeout without active transaction"
      );


      //--------------------------------------------------------------------
      // No simultaneous completion and protocol error.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(complete_valid && protocol_error)
      )
      else $error(
        "TLC ACQUIRE: completion and protocol error simultaneously"
      );


      //--------------------------------------------------------------------
      // Reset state.
      //--------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (state_q == ST_IDLE)
      )
      else $error(
        "TLC ACQUIRE: reset did not return to IDLE"
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
        "TLC ACQUIRE: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC ACQUIRE: DATA_W must be > 0"
      );

    if (DATA_W % 8 != 0)
      $error(
        "TLC ACQUIRE: DATA_W must be byte aligned"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC ACQUIRE: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC ACQUIRE: SINK_W must be > 0"
      );

    if (CLIENT_W == 0)
      $error(
        "TLC ACQUIRE: CLIENT_W must be > 0"
      );

    if (NUM_CLIENTS == 0)
      $error(
        "TLC ACQUIRE: NUM_CLIENTS must be > 0"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC ACQUIRE: CACHE_LINE_BYTES must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC ACQUIRE: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule