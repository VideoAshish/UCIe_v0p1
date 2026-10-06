//==============================================================================
// tlc_permission_mgr.sv
//
// TileLink-C Permission Manager
//
// Responsibilities
// ----------------
//   * Validate AcquireBlock / AcquirePerm requests
//   * Validate Release / ReleaseData requests
//   * Determine requested permission
//   * Determine granted permission
//   * Check requester ownership
//   * Check Shared/Exclusive/Modified/Owned transitions
//   * Determine whether probing is required
//   * Determine whether dirty data must be collected
//   * Generate Grant/Probe permission parameters
//   * Reject illegal permission transitions
//
// Architectural rule
// ------------------
// tlc_directory.sv owns the physical directory state.
//
// tlc_permission_mgr.sv owns the POLICY:
//
//      "Is this transition legal, and what permission may be granted?"
//
// It does NOT allocate source IDs or sink IDs and does NOT drive B/C/D/E
// channels directly.
//
//==============================================================================

module tlc_permission_mgr #(
  parameter int unsigned SOURCE_W    = 8,
  parameter int unsigned CLIENT_W    = 4,
  parameter int unsigned NUM_CLIENTS = 8,

  parameter bit ENABLE_MSI  = 1'b0,
  parameter bit ENABLE_MESI = 1'b0,
  parameter bit ENABLE_MOESI = 1'b1,

  parameter bit ALLOW_SHARED = 1'b1,
  parameter bit ALLOW_EXCLUSIVE = 1'b1,

  parameter bit ENABLE_ASSERTIONS = 1'b1
) (
  input  logic clk,
  input  logic rst_n,

  //==========================================================================
  // Request
  //==========================================================================

  input  logic                    req_valid,

  input  logic [SOURCE_W-1:0]     req_source,

  input  logic [CLIENT_W-1:0]     req_client_id,

  input  logic [2:0]              req_opcode,
  input  logic [2:0]              req_param,

  input  logic                    req_is_acquire,
  input  logic                    req_is_release,

  input  logic                    req_acquire_block,
  input  logic                    req_acquire_perm,

  input  logic                    req_release,
  input  logic                    req_release_data,

  //==========================================================================
  // Current directory state
  //==========================================================================

  input  logic                    line_valid,

  input  logic [NUM_CLIENTS-1:0]  line_sharers,

  input  logic [CLIENT_W-1:0]     line_owner,

  input  logic                    line_owner_valid,

  input  logic                    line_dirty,

  input  logic [2:0]              line_state,

  //==========================================================================
  // Requester's current permission
  //==========================================================================

  input  logic                    requester_is_sharer,

  input  logic                    requester_is_owner,

  //==========================================================================
  // Probe result
  //==========================================================================

  input  logic                    probes_required,

  input  logic                    probes_complete,

  input  logic                    dirty_data_required,

  input  logic                    dirty_data_received,

  //==========================================================================
  // Permission decision
  //==========================================================================

  output logic                    decision_valid,

  output logic                    decision_allow,

  output logic                    decision_deny,

  output logic                    decision_wait,

  output logic                    decision_error,

  //==========================================================================
  // Grant permission
  //
  // 00 = none / deny
  // 01 = shared
  // 10 = exclusive clean
  // 11 = exclusive dirty
  //==========================================================================

  output logic [1:0]              grant_permission,

  output logic                    grant_shared,

  output logic                    grant_exclusive,

  output logic                    grant_dirty,

  //==========================================================================
  // Probe requirement
  //==========================================================================

  output logic                    need_probe,

  output logic                    need_dirty_data,

  output logic                    need_owner_probe,

  output logic                    need_sharer_probe,

  //==========================================================================
  // Resulting directory state
  //==========================================================================

  output logic [2:0]              next_state,

  output logic [NUM_CLIENTS-1:0]  next_sharers,

  output logic [CLIENT_W-1:0]    next_owner,

  output logic                    next_owner_valid,

  output logic                    next_dirty,

  //==========================================================================
  // Error classification
  //==========================================================================

  output logic                    illegal_opcode,

  output logic                    illegal_param,

  output logic                    requester_not_owner,

  output logic                    conflicting_owner,

  output logic                    invalid_transition,

  output logic                    dirty_data_missing
);


  //==========================================================================
  // TileLink A-channel opcodes
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
  // Permission encoding
  //==========================================================================

  localparam logic [1:0] PERM_NONE =
      2'b00;

  localparam logic [1:0] PERM_SHARED =
      2'b01;

  localparam logic [1:0] PERM_EXCLUSIVE =
      2'b10;

  localparam logic [1:0] PERM_DIRTY =
      2'b11;


  //==========================================================================
  // Directory state encoding
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
  // Internal classification
  //==========================================================================

  logic request_is_read;
  logic request_is_write;

  logic request_requires_exclusive;

  logic line_has_other_sharers;

  logic line_has_other_owner;

  logic owner_is_requester;

  logic requester_has_any_permission;


  //==========================================================================
  // Request classification
  //==========================================================================

  always_comb begin

    request_is_read =
        (req_opcode == A_GET);

    request_is_write =
        (req_opcode == A_PUTFULL) ||
        (req_opcode == A_PUTPARTIAL);

    request_requires_exclusive =
        req_acquire_block ||
        req_acquire_perm ||
        request_is_write;

  end


  //==========================================================================
  // Directory relationships
  //==========================================================================

  always_comb begin

    owner_is_requester =
        line_owner_valid &&
        (line_owner == req_client_id);

    requester_has_any_permission =
        requester_is_sharer ||
        requester_is_owner;

    line_has_other_owner =
        line_owner_valid &&
        !owner_is_requester;

    line_has_other_sharers =
        |(
          line_sharers &
          ~(
            ({{(NUM_CLIENTS-1){1'b0}},1'b1})
            << req_client_id
          )
        );

  end


  //==========================================================================
  // Probe requirement
  //==========================================================================

  always_comb begin

    need_probe =
        1'b0;

    need_owner_probe =
        1'b0;

    need_sharer_probe =
        1'b0;

    //======================================================================
    // Exclusive request
    //======================================================================

    if (request_requires_exclusive) begin

      if (line_has_other_owner) begin

        need_probe =
            1'b1;

        need_owner_probe =
            1'b1;

      end

      if (line_has_other_sharers) begin

        need_probe =
            1'b1;

        need_sharer_probe =
            1'b1;

      end

    end

    //======================================================================
    // Read request
    //======================================================================

    else if (request_is_read) begin

      // A read from a dirty owner requires intervention.
      if (line_has_other_owner &&
          line_dirty) begin

        need_probe =
            1'b1;

        need_owner_probe =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Dirty data requirement
  //==========================================================================

  always_comb begin

    need_dirty_data =
        1'b0;

    if (line_dirty &&
        need_owner_probe) begin

      need_dirty_data =
          1'b1;

    end

    if (dirty_data_required)
      need_dirty_data = 1'b1;

  end


  //==========================================================================
  // Error detection
  //==========================================================================

  always_comb begin

    illegal_opcode =
        1'b0;

    illegal_param =
        1'b0;

    requester_not_owner =
        1'b0;

    conflicting_owner =
        1'b0;

    invalid_transition =
        1'b0;

    dirty_data_missing =
        1'b0;


    //======================================================================
    // Opcode validation
    //======================================================================

    if (req_valid) begin

      case (req_opcode)

        A_PUTFULL,
        A_PUTPARTIAL,
        A_ARITHMETIC,
        A_LOGICAL,
        A_GET,
        A_INTENT,
        A_ACQUIREBLOCK,
        A_ACQUIREPERM: begin
          // Legal A opcode.
        end

        default: begin
          illegal_opcode = 1'b1;
        end

      endcase

    end


    //======================================================================
    // Acquire classification consistency
    //======================================================================

    if (req_valid &&
        req_acquire_block &&
        req_acquire_perm) begin

      illegal_param = 1'b1;

    end


    //======================================================================
    // Release classification consistency
    //======================================================================

    if (req_valid &&
        req_release_data &&
        !req_release) begin

      illegal_param = 1'b1;

    end


    //======================================================================
    // Release ownership
    //
    // A release from a client that has neither ownership nor a sharer
    // entry is illegal.
    //======================================================================

    if (req_valid &&
        req_release) begin

      if (!requester_has_any_permission) begin

        requester_not_owner = 1'b1;

      end

    end


    //======================================================================
    // Multiple exclusive owners are illegal.
    //======================================================================

    if (line_valid &&
        line_owner_valid &&
        (line_state == DIR_M) &&
        (line_sharers != '0)) begin

      conflicting_owner = 1'b1;

    end


    //======================================================================
    // Dirty data must be available before granting a transaction that
    // requires dirty intervention.
    //======================================================================

    if (req_valid &&
        need_dirty_data &&
        probes_complete &&
        !dirty_data_received) begin

      dirty_data_missing = 1'b1;

    end

  end


  //==========================================================================
  // Permission decision
  //==========================================================================

  always_comb begin

    decision_valid =
        req_valid;

    decision_allow =
        1'b0;

    decision_deny =
        1'b0;

    decision_wait =
        1'b0;

    decision_error =
        1'b0;


    //======================================================================
    // Hard errors
    //======================================================================

    if (
      illegal_opcode ||
      illegal_param ||
      requester_not_owner ||
      conflicting_owner ||
      invalid_transition
    ) begin

      decision_error =
          1'b1;

      decision_deny =
          1'b1;

    end

    //======================================================================
    // Probe in progress
    //======================================================================

    else if (need_probe &&
             !probes_complete) begin

      decision_wait =
          1'b1;

    end

    //======================================================================
    // Dirty data still required
    //======================================================================

    else if (need_dirty_data &&
             !dirty_data_received) begin

      decision_wait =
          1'b1;

    end

    //======================================================================
    // Request can be granted
    //======================================================================

    else begin

      decision_allow =
          1'b1;

    end

  end


  //==========================================================================
  // Grant permission
  //==========================================================================

  always_comb begin

    grant_permission =
        PERM_NONE;

    grant_shared =
        1'b0;

    grant_exclusive =
        1'b0;

    grant_dirty =
        1'b0;


    if (decision_allow) begin

      //====================================================================
      // AcquireBlock
      //====================================================================

      if (req_acquire_block) begin

        grant_exclusive =
            1'b1;

        if (line_dirty &&
            dirty_data_received) begin

          grant_permission =
              PERM_DIRTY;

          grant_dirty =
              1'b1;

        end
        else begin

          grant_permission =
              PERM_EXCLUSIVE;

        end

      end

      //====================================================================
      // AcquirePerm
      //====================================================================

      else if (req_acquire_perm) begin

        grant_exclusive =
            1'b1;

        if (line_dirty &&
            dirty_data_received) begin

          grant_permission =
              PERM_DIRTY;

          grant_dirty =
              1'b1;

        end
        else begin

          grant_permission =
              PERM_EXCLUSIVE;

        end

      end

      //====================================================================
      // Read
      //====================================================================

      else if (request_is_read) begin

        grant_shared =
            1'b1;

        grant_permission =
            PERM_SHARED;

      end

      //====================================================================
      // Write
      //====================================================================

      else if (request_is_write) begin

        grant_exclusive =
            1'b1;

        grant_permission =
            PERM_DIRTY;

        grant_dirty =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Next directory state
  //==========================================================================

  always_comb begin

    next_state =
        DIR_I;

    next_sharers =
        '0;

    next_owner =
        '0;

    next_owner_valid =
        1'b0;

    next_dirty =
        1'b0;


    //======================================================================
    // DENIED request
    //======================================================================

    if (decision_deny) begin

      next_state =
          line_state;

      next_sharers =
          line_sharers;

      next_owner =
          line_owner;

      next_owner_valid =
          line_owner_valid;

      next_dirty =
          line_dirty;

    end

    //======================================================================
    // READ -> Shared
    //======================================================================

    else if (request_is_read &&
             decision_allow) begin

      next_state =
          DIR_S;

      next_sharers =
          line_sharers;

      next_sharers[req_client_id] =
          1'b1;

      next_owner_valid =
          1'b0;

      next_dirty =
          line_dirty &&
          !dirty_data_received;

    end

    //======================================================================
    // AcquireBlock
    //======================================================================

    else if (req_acquire_block &&
             decision_allow) begin

      next_owner =
          req_client_id;

      next_owner_valid =
          1'b1;

      next_sharers =
          '0;

      if (grant_dirty) begin

        next_state =
            DIR_M;

        next_dirty =
            1'b1;

      end
      else begin

        next_state =
            DIR_E;

        next_dirty =
            1'b0;

      end

    end

    //======================================================================
    // AcquirePerm
    //======================================================================

    else if (req_acquire_perm &&
             decision_allow) begin

      next_owner =
          req_client_id;

      next_owner_valid =
          1'b1;

      next_sharers =
          '0;

      if (grant_dirty) begin

        next_state =
            DIR_M;

        next_dirty =
            1'b1;

      end
      else begin

        next_state =
            DIR_E;

        next_dirty =
            1'b0;

      end

    end

    //======================================================================
    // Write
    //======================================================================

    else if (request_is_write &&
             decision_allow) begin

      next_owner =
          req_client_id;

      next_owner_valid =
          1'b1;

      next_sharers =
          '0;

      next_state =
          DIR_M;

      next_dirty =
          1'b1;

    end

    //======================================================================
    // Release
    //======================================================================

    else if (req_release &&
             decision_allow) begin

      next_sharers =
          line_sharers;

      next_sharers[req_client_id] =
          1'b0;

      if (line_owner_valid &&
          (line_owner == req_client_id)) begin

        next_owner_valid =
            1'b0;

      end
      else begin

        next_owner =
            line_owner;

        next_owner_valid =
            line_owner_valid;

      end

      if (req_release_data) begin

        next_dirty =
            1'b1;

        next_state =
            DIR_M;

        next_owner =
            req_client_id;

        next_owner_valid =
            1'b1;

        next_sharers =
            '0;

      end
      else if (next_sharers != '0) begin

        next_state =
            DIR_S;

        next_dirty =
            1'b0;

      end
      else begin

        next_state =
            DIR_I;

        next_dirty =
            1'b0;

        next_owner_valid =
            1'b0;

      end

    end

  end


  //==========================================================================
  // MESI/MOESI consistency checks
  //==========================================================================

  always_comb begin

    invalid_transition =
        1'b0;

    //======================================================================
    // Shared permission disabled.
    //======================================================================

    if (request_is_read &&
        !ALLOW_SHARED) begin

      invalid_transition =
          1'b1;

    end


    //======================================================================
    // Exclusive permission disabled.
    //======================================================================

    if (request_requires_exclusive &&
        !ALLOW_EXCLUSIVE) begin

      invalid_transition =
          1'b1;

    end


    //======================================================================
    // MOESI O state requires an owner.
    //======================================================================

    if (line_state == DIR_O &&
        !ENABLE_MOESI) begin

      invalid_transition =
          1'b1;

    end


    //======================================================================
    // MESI-only configuration cannot use Owned.
    //======================================================================

    if ((line_state == DIR_O) &&
        ENABLE_MESI &&
        !ENABLE_MOESI) begin

      invalid_transition =
          1'b1;

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_PERMISSION_ASSERTIONS

      //====================================================================
      // Cannot grant and deny simultaneously.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(decision_allow && decision_deny)
      )
      else $error(
        "TLC PERMISSION: allow and deny simultaneously asserted"
      );


      //====================================================================
      // Error implies deny.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        decision_error
        |-> decision_deny
      )
      else $error(
        "TLC PERMISSION: error without deny"
      );


      //====================================================================
      // Wait and allow cannot coexist.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(decision_wait && decision_allow)
      )
      else $error(
        "TLC PERMISSION: wait and allow simultaneously asserted"
      );


      //====================================================================
      // Exclusive grant cannot have sharers.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        decision_allow &&
        grant_exclusive
        |-> (next_sharers == '0)
      )
      else $error(
        "TLC PERMISSION: exclusive grant with sharers"
      );


      //====================================================================
      // Dirty permission requires dirty state.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_dirty
        |-> next_dirty
      )
      else $error(
        "TLC PERMISSION: dirty permission without dirty state"
      );


      //====================================================================
      // Modified state requires owner.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        next_state == DIR_M
        |-> next_owner_valid
      )
      else $error(
        "TLC PERMISSION: Modified state without owner"
      );


      //====================================================================
      // Exclusive state requires owner.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        next_state == DIR_E
        |-> next_owner_valid
      )
      else $error(
        "TLC PERMISSION: Exclusive state without owner"
      );


      //====================================================================
      // Shared state cannot have exclusive owner.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        next_state == DIR_S
        |-> !next_owner_valid
      )
      else $error(
        "TLC PERMISSION: Shared state has exclusive owner"
      );


      //====================================================================
      // AcquireBlock cannot be granted while probes are incomplete.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        req_acquire_block &&
        need_probe
        |-> (
          !decision_allow ||
          probes_complete
        )
      )
      else $error(
        "TLC PERMISSION: AcquireBlock granted before Probe completion"
      );


      //====================================================================
      // Dirty intervention requires dirty data.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        decision_allow &&
        need_dirty_data
        |-> dirty_data_received
      )
      else $error(
        "TLC PERMISSION: dirty permission granted without data"
      );


      //====================================================================
      // ReleaseData requires Release.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        req_release_data
        |-> req_release
      )
      else $error(
        "TLC PERMISSION: ReleaseData without Release"
      );


      //====================================================================
      // AcquireBlock and AcquirePerm mutually exclusive.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(req_acquire_block &&
          req_acquire_perm)
      )
      else $error(
        "TLC PERMISSION: AcquireBlock and AcquirePerm simultaneously set"
      );


      //====================================================================
      // A requester cannot acquire exclusive permission while another
      // owner exists unless intervention/probing is required.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        decision_allow &&
        request_requires_exclusive &&
        line_has_other_owner
        |-> probes_complete
      )
      else $error(
        "TLC PERMISSION: exclusive permission granted despite owner"
      );


      //====================================================================
      // Dirty line cannot silently transition to clean without either
      // retained dirty ownership or dirty-data collection.
      //====================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        line_valid &&
        line_dirty &&
        decision_allow &&
        !next_dirty
        |-> (
          dirty_data_received ||
          req_release
        )
      )
      else $error(
        "TLC PERMISSION: dirty state lost without data transition"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Elaboration checks
  //==========================================================================

  initial begin

    if (NUM_CLIENTS == 0)
      $error(
        "TLC PERMISSION: NUM_CLIENTS must be > 0"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC PERMISSION: SOURCE_W must be > 0"
      );

    if (CLIENT_W == 0)
      $error(
        "TLC PERMISSION: CLIENT_W must be > 0"
      );

    if (NUM_CLIENTS > (1 << CLIENT_W))
      $error(
        "TLC PERMISSION: CLIENT_W cannot encode all clients"
      );

  end

endmodule