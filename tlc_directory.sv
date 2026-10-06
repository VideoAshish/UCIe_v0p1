//==============================================================================
// tlc_directory.sv
//
// TileLink-C Directory / Coherence State Manager
//
// Responsibilities
// ----------------
//   * Cache-line lookup
//   * Per-line coherence state
//   * Owner tracking
//   * Sharer tracking
//   * Acquire permission evaluation
//   * Release permission evaluation
//   * Probe target generation
//   * Probe fanout tracking
//   * Dirty-owner identification
//   * Grant permission generation
//   * Release/Probe state transitions
//
// This module is a DIRECTORY / COHERENCE STATE MACHINE.
// It is intentionally independent of:
//
//   * A/B/C/D/E channel transport
//   * source-ID allocation
//   * sink-ID allocation
//   * replay buffering
//   * physical RAM implementation
//
// Typical architecture:
//
//                     +---------------------+
// A/C transactions -->|                     |
//                     |  tlc_directory      |----> Probe requests
//                     |                     |
//                     |  directory RAM      |----> Grant permission
//                     |                     |
//                     +----------+----------+
//                                |
//                                v
//                         tlc_txn_table
//
//==============================================================================

module tlc_directory #(
  parameter int unsigned ADDR_W          = 48,
  parameter int unsigned SOURCE_W        = 8,
  parameter int unsigned SINK_W          = 8,

  parameter int unsigned NUM_CLIENTS     = 8,

  parameter int unsigned NUM_SETS        = 1024,

  parameter int unsigned CACHE_LINE_BYTES = 64,

  parameter int unsigned DATA_W          = 256,

  parameter bit ENABLE_MSI               = 1'b0,
  parameter bit ENABLE_MESI              = 1'b0,
  parameter bit ENABLE_MOESI             = 1'b1,

  parameter bit ENABLE_ASSERTIONS       = 1'b1
) (

  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // Transaction request
  //
  // Usually driven by tlc_txn_table / A-channel controller.
  //==========================================================================

  input  logic                    req_valid,
  output logic                    req_ready,

  input  logic [SOURCE_W-1:0]      req_source,

  input  logic [2:0]               req_opcode,
  input  logic [2:0]               req_param,

  input  logic [ADDR_W-1:0]        req_address,

  input  logic [2:0]               req_size,

  input  logic                    req_is_acquire,
  input  logic                    req_is_release,

  //==========================================================================
  // Release information
  //==========================================================================

  input  logic                    release_dirty,
  input  logic                    release_data_valid,

  //==========================================================================
  // Probe acknowledgement
  //==========================================================================

  input  logic                    probe_ack_valid,

  input  logic [SOURCE_W-1:0]      probe_ack_source,

  input  logic [2:0]               probe_ack_param,

  input  logic                    probe_ack_dirty,

  input  logic                    probe_ack_data_valid,

  //==========================================================================
  // Grant completion
  //==========================================================================

  input  logic                    grant_ack_valid,

  input  logic [SINK_W-1:0]        grant_ack_sink,

  //==========================================================================
  // Directory lookup
  //==========================================================================

  input  logic                    lookup_valid,

  input  logic [ADDR_W-1:0]        lookup_address,

  output logic                    lookup_hit,

  output logic [NUM_CLIENTS-1:0]   lookup_sharers,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  lookup_owner,

  output logic                    lookup_owner_valid,

  output logic                    lookup_dirty,

  output logic [2:0]              lookup_state,

  //==========================================================================
  // Probe request output
  //
  // One client is emitted at a time. Arbitration / buffering belongs outside
  // this directory.
  //==========================================================================

  output logic                    probe_valid,
  input  logic                    probe_ready,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  probe_client,

  output logic [ADDR_W-1:0]        probe_address,

  output logic [SOURCE_W-1:0]      probe_source,

  output logic [2:0]               probe_param,

  //==========================================================================
  // Probe fanout status
  //==========================================================================

  output logic                    probe_active,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  probe_expected,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  probe_sent,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  probe_received,

  output logic                    probe_done,

  //==========================================================================
  // Grant decision
  //==========================================================================

  output logic                    grant_valid,

  output logic [SOURCE_W-1:0]      grant_source,

  output logic [2:0]               grant_param,

  output logic                    grant_data,

  output logic                    grant_denied,

  //==========================================================================
  // Directory update
  //==========================================================================

  output logic                    update_valid,

  output logic [ADDR_W-1:0]        update_address,

  output logic [NUM_CLIENTS-1:0]   update_sharers,

  output logic [$clog2(NUM_CLIENTS+1)-1:0]
                                  update_owner,

  output logic                    update_owner_valid,

  output logic                    update_dirty,

  output logic [2:0]               update_state,

  //==========================================================================
  // Errors
  //==========================================================================

  output logic                    illegal_request,

  output logic                    invalid_client,

  output logic                    permission_error,

  output logic                    directory_error
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned CLIENT_W =
      (NUM_CLIENTS <= 1) ? 1 :
      $clog2(NUM_CLIENTS);

  localparam int unsigned OWNER_W =
      $clog2(NUM_CLIENTS + 1);

  localparam int unsigned SET_W =
      (NUM_SETS <= 1) ? 1 :
      $clog2(NUM_SETS);

  localparam int unsigned LINE_OFF_W =
      (CACHE_LINE_BYTES <= 1) ? 0 :
      $clog2(CACHE_LINE_BYTES);


  //==========================================================================
  // TileLink A opcodes
  //==========================================================================

  localparam logic [2:0] A_PUTFULL =
      3'd0;

  localparam logic [2:0] A_PUTPARTIAL =
      3'd1;

  localparam logic [2:0] A_ARITHMETIC =
      3'd2;

  localparam logic [2:0] A_LOGICAL =
      3'd3;

  localparam logic [2:0] A_GET =
      3'd4;

  localparam logic [2:0] A_INTENT =
      3'd5;

  localparam logic [2:0] A_ACQUIREBLOCK =
      3'd6;

  localparam logic [2:0] A_ACQUIREPERM =
      3'd7;


  //==========================================================================
  // Directory coherence states
  //
  // State encoding:
  //
  // I = Invalid
  // S = Shared
  // E = Exclusive clean
  // M = Modified
  // O = Owned
  //
  // The exact state set can be restricted by the parameterized protocol
  // configuration.
  //==========================================================================

  localparam logic [2:0] DIR_I =
      3'd0;

  localparam logic [2:0] DIR_S =
      3'd1;

  localparam logic [2:0] DIR_E =
      3'd2;

  localparam logic [2:0] DIR_M =
      3'd3;

  localparam logic [2:0] DIR_O =
      3'd4;


  //==========================================================================
  // Directory entry
  //==========================================================================

  typedef struct packed {

    logic                   valid;

    logic [NUM_CLIENTS-1:0] sharers;

    logic [OWNER_W-1:0]     owner;

    logic                   owner_valid;

    logic                   dirty;

    logic [2:0]             state;

  } directory_entry_t;


  directory_entry_t directory [0:NUM_SETS-1];


  //==========================================================================
  // Request context
  //
  // The context is latched before probes are issued.
  //==========================================================================

  typedef struct packed {

    logic                   valid;

    logic [SOURCE_W-1:0]    source;

    logic [ADDR_W-1:0]      address;

    logic [SET_W-1:0]       set;

    logic [2:0]             opcode;

    logic [2:0]             param;

    logic                   is_acquire;

    logic                   is_release;

    logic                   release_dirty;

    logic                   release_data_valid;

    logic [NUM_CLIENTS-1:0] target_clients;

    logic [NUM_CLIENTS-1:0] probe_sent_bitmap;

    logic [NUM_CLIENTS-1:0] probe_ack_bitmap;

    logic                   probe_required;

    logic                   dirty_required;

    logic                   dirty_received;

    logic                   grant_pending;

    logic                   grant_sent;

    logic [2:0]             grant_param;

    logic                   grant_data;

  } request_ctx_t;


  request_ctx_t ctx;


  //==========================================================================
  // Address decode
  //==========================================================================

  logic [SET_W-1:0] req_set;

  always_comb begin

    if (LINE_OFF_W == 0) begin
      req_set = req_address[SET_W-1:0];
    end
    else begin
      req_set =
          req_address[LINE_OFF_W +: SET_W];
    end

  end


  //==========================================================================
  // Request acceptance
  //==========================================================================

  assign req_ready =
      !ctx.valid;

  wire req_fire =
      req_valid &&
      req_ready;


  //==========================================================================
  // Directory lookup
  //==========================================================================

  logic [SET_W-1:0] lookup_set;

  always_comb begin

    if (LINE_OFF_W == 0) begin
      lookup_set =
          lookup_address[SET_W-1:0];
    end
    else begin
      lookup_set =
          lookup_address[LINE_OFF_W +: SET_W];
    end

  end


  always_comb begin

    lookup_hit =
        lookup_valid &&
        directory[lookup_set].valid;

    lookup_sharers =
        directory[lookup_set].sharers;

    lookup_owner =
        directory[lookup_set].owner;

    lookup_owner_valid =
        directory[lookup_set].owner_valid;

    lookup_dirty =
        directory[lookup_set].dirty;

    lookup_state =
        directory[lookup_set].state;

  end


  //==========================================================================
  // Client validation
  //==========================================================================

  always_comb begin

    invalid_client = 1'b0;

    if (probe_ack_valid) begin

      if (probe_ack_source >=
          NUM_CLIENTS) begin

        invalid_client = 1'b1;

      end

    end

  end


  //==========================================================================
  // Determine target clients
  //
  // AcquireBlock / AcquirePerm may require probing all other sharers/owner.
  //==========================================================================

  logic [NUM_CLIENTS-1:0] calculated_targets;

  always_comb begin

    calculated_targets = '0;

    if (req_valid) begin

      if (req_is_acquire) begin

        calculated_targets =
            directory[req_set].sharers;

        if (directory[req_set].owner_valid) begin

          calculated_targets[
            directory[req_set].owner
          ] = 1'b1;

        end

      end

      if (req_is_release) begin

        calculated_targets = '0;
      end

    end

  end


  //==========================================================================
  // Remove requester from probe target set.
  //
  // The requester cannot need to invalidate itself.
  //
  // This assumes req_source identifies the coherent client.
  // In systems where source IDs are globally independent of client IDs,
  // an explicit client-ID input should be used instead.
  //==========================================================================

  logic [NUM_CLIENTS-1:0] probe_targets;

  always_comb begin

    probe_targets =
        calculated_targets;

    if (req_source < NUM_CLIENTS)
      probe_targets[req_source] = 1'b0;

  end


  //==========================================================================
  // Probe generation
  //==========================================================================

  logic probe_selection_found;

  always_comb begin

    probe_valid = 1'b0;

    probe_client =
        '0;

    probe_address =
        ctx.address;

    probe_source =
        ctx.source;

    probe_param =
        3'b000;

    probe_selection_found =
        1'b0;

    if (ctx.valid &&
        ctx.probe_required) begin

      for (int unsigned i = 0;
           i < NUM_CLIENTS;
           i++) begin

        if (!probe_selection_found &&
            ctx.target_clients[i] &&
            !ctx.probe_sent_bitmap[i]) begin

          probe_valid =
              1'b1;

          probe_client =
              CLIENT_W'(i);

          probe_selection_found =
              1'b1;

          probe_address =
              ctx.address;

          probe_source =
              ctx.source;

          // Default coherence request:
          // invalidate / downgrade.
          probe_param =
              3'b000;

        end

      end

    end

  end


  wire probe_fire =
      probe_valid &&
      probe_ready;


  //==========================================================================
  // Probe counters
  //==========================================================================

  always_comb begin

    probe_expected =
        '0;

    probe_sent =
        '0;

    probe_received =
        '0;

    for (int unsigned i = 0;
         i < NUM_CLIENTS;
         i++) begin

      if (ctx.target_clients[i])
        probe_expected++;

      if (ctx.probe_sent_bitmap[i])
        probe_sent++;

      if (ctx.probe_ack_bitmap[i])
        probe_received++;

    end

  end


  assign probe_active =
      ctx.valid &&
      ctx.probe_required;

  assign probe_done =
      ctx.valid &&
      (
        !ctx.probe_required ||
        (
          (probe_received ==
           probe_expected) &&
          (probe_sent ==
           probe_expected)
        )
      );


  //==========================================================================
  // Dirty-data requirement
  //==========================================================================

  always_comb begin

    if (!ctx.valid) begin

      ctx_dirty_required_comb = 1'b0;

    end
    else begin

      ctx_dirty_required_comb =
          ctx.dirty_required;

    end

  end

  logic ctx_dirty_required_comb;


  //==========================================================================
  // Grant decision
  //==========================================================================

  always_comb begin

    grant_valid  = 1'b0;
    grant_source = ctx.source;
    grant_param  = ctx.grant_param;
    grant_data   = ctx.grant_data;
    grant_denied = 1'b0;

    if (ctx.valid &&
        ctx.grant_pending) begin

      if (
        probe_done &&
        (
          !ctx.dirty_required ||
          ctx.dirty_received
        )
      ) begin

        grant_valid =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Permission / state decision
  //==========================================================================

  logic [2:0] next_grant_param;
  logic        next_grant_data;
  logic        next_dirty;
  logic [NUM_CLIENTS-1:0] next_sharers;
  logic [OWNER_W-1:0] next_owner;
  logic        next_owner_valid;
  logic [2:0] next_state;


  always_comb begin

    next_grant_param =
        3'b000;

    next_grant_data =
        1'b0;

    next_dirty =
        1'b0;

    next_sharers =
        '0;

    next_owner =
        '0;

    next_owner_valid =
        1'b0;

    next_state =
        DIR_I;


    //======================================================================
    // RELEASE
    //======================================================================

    if (ctx.is_release) begin

      next_sharers =
          directory[req_set].sharers;

      if (ctx.source < NUM_CLIENTS)
        next_sharers[ctx.source] = 1'b0;

      next_dirty =
          ctx.release_dirty ?
          1'b1 :
          directory[req_set].dirty;

      next_state =
          DIR_S;

      if (ctx.release_dirty) begin

        next_state =
            DIR_M;

        next_owner =
            ctx.source;

        next_owner_valid =
            1'b1;

        next_sharers =
            '0;

      end

    end

    //======================================================================
    // ACQUIRE
    //======================================================================

    else if (ctx.is_acquire) begin

      // AcquireBlock / AcquirePerm obtains exclusive ownership.

      next_owner =
          ctx.source;

      next_owner_valid =
          1'b1;

      next_sharers =
          '0;

      next_dirty =
          1'b0;

      if (ctx.opcode == A_ACQUIREBLOCK) begin

        next_grant_param =
            3'b000;

        next_grant_data =
            directory[req_set].valid;

      end
      else begin

        next_grant_param =
            3'b000;

        next_grant_data =
            1'b0;

      end

      // If dirty data was collected from another owner, new owner receives
      // dirty data.

      if (ctx.dirty_received) begin

        next_dirty =
            1'b1;

        next_state =
            DIR_M;

      end
      else begin

        next_state =
            DIR_E;

      end

    end

    //======================================================================
    // NORMAL READ
    //======================================================================

    else if (ctx.opcode == A_GET) begin

      next_sharers =
          directory[req_set].sharers;

      if (ctx.source < NUM_CLIENTS)
        next_sharers[ctx.source] = 1'b1;

      next_owner_valid =
          1'b0;

      next_dirty =
          directory[req_set].dirty;

      next_state =
          DIR_S;

    end

    //======================================================================
    // PUT / write transaction
    //======================================================================

    else if (
      (ctx.opcode == A_PUTFULL) ||
      (ctx.opcode == A_PUTPARTIAL)
    ) begin

      next_owner =
          ctx.source;

      next_owner_valid =
          1'b1;

      next_sharers =
          '0;

      next_dirty =
          1'b1;

      next_state =
          DIR_M;

    end

  end


  //==========================================================================
  // Directory update output
  //==========================================================================

  assign update_valid =
      grant_valid ||
      (
        ctx.valid &&
        ctx.is_release
      );

  assign update_address =
      ctx.address;

  assign update_sharers =
      next_sharers;

  assign update_owner =
      next_owner;

  assign update_owner_valid =
      next_owner_valid;

  assign update_dirty =
      next_dirty;

  assign update_state =
      next_state;


  //==========================================================================
  // Illegal request detection
  //==========================================================================

  always_comb begin

    illegal_request = 1'b0;

    if (req_valid) begin

      // Acquire and Release cannot both describe one request.
      if (req_is_acquire &&
          req_is_release) begin

        illegal_request = 1'b1;

      end

      // Only recognized A-channel operations are accepted.
      case (req_opcode)

        A_PUTFULL,
        A_PUTPARTIAL,
        A_ARITHMETIC,
        A_LOGICAL,
        A_GET,
        A_INTENT,
        A_ACQUIREBLOCK,
        A_ACQUIREPERM: begin
          // Legal opcode.
        end

        default: begin

          illegal_request = 1'b1;

        end

      endcase

    end

  end


  //==========================================================================
  // Permission error
  //
  // The exact TL-C permission policy is system-specific. This module
  // provides conservative checks for ownership-sensitive operations.
  //==========================================================================

  always_comb begin

    permission_error = 1'b0;

    if (req_valid &&
        req_is_release) begin

      if (directory[req_set].owner_valid &&
          (directory[req_set].owner != req_source) &&
          !directory[req_set].sharers[req_source]) begin

        permission_error = 1'b1;

      end

    end

  end


  //==========================================================================
  // Directory error
  //==========================================================================

  assign directory_error =
      illegal_request ||
      invalid_client ||
      permission_error;


  //==========================================================================
  // Sequential state machine
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      //======================================================================
      // Reset directory.
      //======================================================================

      for (int unsigned i = 0;
           i < NUM_SETS;
           i++) begin

        directory[i].valid       <= 1'b0;
        directory[i].sharers     <= '0;
        directory[i].owner       <= '0;
        directory[i].owner_valid <= 1'b0;
        directory[i].dirty       <= 1'b0;
        directory[i].state       <= DIR_I;

      end

      //======================================================================
      // Reset request context.
      //======================================================================

      ctx <= '0;

    end
    else begin

      //======================================================================
      // Accept a new coherence request.
      //======================================================================

      if (req_fire &&
          !directory_error) begin

        ctx.valid <=
            1'b1;

        ctx.source <=
            req_source;

        ctx.address <=
            req_address;

        ctx.set <=
            req_set;

        ctx.opcode <=
            req_opcode;

        ctx.param <=
            req_param;

        ctx.is_acquire <=
            req_is_acquire;

        ctx.is_release <=
            req_is_release;

        ctx.release_dirty <=
            release_dirty;

        ctx.release_data_valid <=
            release_data_valid;

        //==================================================================
        // Calculate probe targets.
        //==================================================================

        ctx.target_clients <=
            probe_targets;

        ctx.probe_sent_bitmap <=
            '0;

        ctx.probe_ack_bitmap <=
            '0;

        ctx.probe_required <=
            |probe_targets;

        //==================================================================
        // Dirty data may be required when current line is dirty.
        //==================================================================

        ctx.dirty_required <=
            directory[req_set].valid &&
            directory[req_set].dirty &&
            (|probe_targets);

        ctx.dirty_received <=
            1'b0;

        ctx.grant_pending <=
            req_is_acquire;

        ctx.grant_sent <=
            1'b0;

        ctx.grant_param <=
            3'b000;

        ctx.grant_data <=
            directory[req_set].valid;

      end


      //======================================================================
      // Probe request accepted.
      //======================================================================

      if (probe_fire) begin

        ctx.probe_sent_bitmap[
          probe_client
        ] <=
            1'b1;

      end


      //======================================================================
      // Probe acknowledgement.
      //
      // probe_ack_source is interpreted as the client ID in this directory
      // implementation. A production integration can add an explicit
      // probe_client_id field if source IDs are not client IDs.
      //======================================================================

      if (probe_ack_valid &&
          ctx.valid) begin

        if (probe_ack_source < NUM_CLIENTS) begin

          if (ctx.target_clients[probe_ack_source]) begin

            ctx.probe_ack_bitmap[
              probe_ack_source
            ] <=
                1'b1;

            if (probe_ack_dirty) begin

              ctx.dirty_received <=
                  1'b1;

            end

          end

        end

      end


      //======================================================================
      // Dirty data notification.
      //======================================================================

      if (probe_ack_data_valid &&
          probe_ack_valid &&
          probe_ack_dirty) begin

        ctx.dirty_received <=
            1'b1;

      end


      //======================================================================
      // Grant accepted by downstream.
      //
      // grant_valid here represents the directory's grant decision being
      // consumed by the coherence controller.
      //======================================================================

      if (grant_valid) begin

        ctx.grant_sent <=
            1'b1;

        ctx.grant_pending <=
            1'b0;

        //==============================================================
        // Commit directory state.
        //==============================================================

        directory[ctx.set].valid <=
            1'b1;

        directory[ctx.set].sharers <=
            next_sharers;

        directory[ctx.set].owner <=
            next_owner;

        directory[ctx.set].owner_valid <=
            next_owner_valid;

        directory[ctx.set].dirty <=
            next_dirty;

        directory[ctx.set].state <=
            next_state;

        //==============================================================
        // Transaction is now waiting for GrantAck.
        //==============================================================

        ctx.valid <=
            1'b0;

      end


      //======================================================================
      // Release-only directory update.
      //======================================================================

      if (ctx.valid &&
          ctx.is_release &&
          !ctx.is_acquire) begin

        if (!probe_active) begin

          directory[ctx.set].valid <=
              1'b1;

          directory[ctx.set].sharers <=
              next_sharers;

          directory[ctx.set].owner <=
              next_owner;

          directory[ctx.set].owner_valid <=
              next_owner_valid;

          directory[ctx.set].dirty <=
              next_dirty;

          directory[ctx.set].state <=
              next_state;

          ctx.valid <=
              1'b0;

        end

      end

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_DIRECTORY_ASSERTIONS

      //======================================================================
      // Directory state validity.
      //======================================================================

      for (genvar g = 0;
           g < NUM_SETS;
           g++) begin : GEN_DIR_ASSERT

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          directory[g].valid
          |-> (
            directory[g].state != DIR_I
          )
        )
        else $error(
          "TLC DIRECTORY: valid entry has Invalid state"
        );


        //====================================================================
        // Invalid line cannot be dirty.
        //====================================================================

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          !directory[g].valid
          |-> !directory[g].dirty
        )
        else $error(
          "TLC DIRECTORY: invalid line marked dirty"
        );


        //====================================================================
        // Modified state must have owner.
        //====================================================================

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          directory[g].valid &&
          (directory[g].state == DIR_M)
          |-> directory[g].owner_valid
        )
        else $error(
          "TLC DIRECTORY: Modified state without owner"
        );


        //====================================================================
        // Exclusive state must have owner.
        //====================================================================

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          directory[g].valid &&
          (directory[g].state == DIR_E)
          |-> directory[g].owner_valid
        )
        else $error(
          "TLC DIRECTORY: Exclusive state without owner"
        );


        //====================================================================
        // Shared state should not have owner.
        //====================================================================

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          directory[g].valid &&
          (directory[g].state == DIR_S)
          |-> !directory[g].owner_valid
        )
        else $error(
          "TLC DIRECTORY: Shared state has owner"
        );


        //====================================================================
        // Dirty state requires valid line.
        //====================================================================

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          directory[g].dirty
          |-> directory[g].valid
        )
        else $error(
          "TLC DIRECTORY: dirty invalid line"
        );

      end


      //======================================================================
      // Probe acknowledgement must belong to active request.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_ack_valid
        |-> ctx.valid
      )
      else $error(
        "TLC DIRECTORY: ProbeAck without active transaction"
      );


      //======================================================================
      // Probe acknowledgement cannot exceed fanout.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_ack_valid &&
        ctx.valid
        |-> ctx.target_clients[probe_ack_source]
      )
      else $error(
        "TLC DIRECTORY: ProbeAck from non-target client"
      );


      //======================================================================
      // Probe request must be a target.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_fire
        |-> ctx.target_clients[probe_client]
      )
      else $error(
        "TLC DIRECTORY: Probe issued to non-target client"
      );


      //======================================================================
      // No probe after all probes have been acknowledged.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_fire
        |-> (probe_received < probe_expected)
      )
      else $error(
        "TLC DIRECTORY: Probe issued after fanout completion"
      );


      //======================================================================
      // Grant requires all probes to be complete.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_valid
        |-> probe_done
      )
      else $error(
        "TLC DIRECTORY: Grant issued before probes completed"
      );


      //======================================================================
      // Dirty grant requires dirty data.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_valid &&
        ctx.dirty_required
        |-> ctx.dirty_received
      )
      else $error(
        "TLC DIRECTORY: Grant issued without required dirty data"
      );


      //======================================================================
      // Request context persistence.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        ctx.valid &&
        !grant_valid
        |=> ctx.valid
      )
      else $error(
        "TLC DIRECTORY: active request context disappeared"
      );


      //======================================================================
      // Reset clears directory.
      //======================================================================

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (
          ctx.valid == 1'b0
        )
      )
      else $error(
        "TLC DIRECTORY: context not cleared by reset"
      );


      //======================================================================
      // No simultaneous acquire and release.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        req_valid
        |-> !(req_is_acquire && req_is_release)
      )
      else $error(
        "TLC DIRECTORY: request is both Acquire and Release"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Elaboration checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC DIRECTORY: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC DIRECTORY: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC DIRECTORY: DATA_W must be byte aligned"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC DIRECTORY: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC DIRECTORY: SINK_W must be > 0"
      );

    if (NUM_CLIENTS == 0)
      $error(
        "TLC DIRECTORY: NUM_CLIENTS must be > 0"
      );

    if (NUM_SETS == 0)
      $error(
        "TLC DIRECTORY: NUM_SETS must be > 0"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC DIRECTORY: CACHE_LINE_BYTES must be > 0"
      );

    if ((CACHE_LINE_BYTES &
         (CACHE_LINE_BYTES - 1)) != 0)
      $error(
        "TLC DIRECTORY: CACHE_LINE_BYTES must be power-of-two"
      );

    if (NUM_CLIENTS > (1 << SOURCE_W))
      $error(
        "TLC DIRECTORY: SOURCE_W insufficient to encode clients"
      );

  end

endmodule