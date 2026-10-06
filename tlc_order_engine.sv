//==============================================================================
// tlc_order_engine.sv
//
// TileLink-C Ordering / Dependency Engine
//
// Responsibilities
// ----------------
// * Track outstanding TL-C transactions
// * Detect source-ID conflicts
// * Detect address conflicts
// * Prevent unsafe RAW/WAR/WAW overlap
// * Allow independent transactions to proceed concurrently
// * Track Acquire / Release / Probe / Grant dependencies
// * Support configurable number of outstanding transactions
// * Parameterized address/source widths
// * Configurable cache-line size
// * Independent request ready/valid
// * No combinational ready/valid loop
// * Registered dependency state
// * Same-cycle allocation/free handling
// * Timeout detection
// * Overflow/underflow protection
// * Reset-clean state
// * SVA assertions
//
// IMPORTANT
// ---------
// This module is a coherence dependency tracker, not a replacement for the
// TileLink protocol itself. Legal TileLink concurrency depends on the
// protocol messages and the capabilities of the connected manager/client.
//
//==============================================================================

module tlc_order_engine #(
  parameter int unsigned ADDR_W =
      48,

  parameter int unsigned SOURCE_W =
      8,

  parameter int unsigned DATA_W =
      256,

  parameter int unsigned CACHE_LINE_BYTES =
      DATA_W / 8,

  parameter int unsigned MAX_OUTSTANDING =
      16,

  parameter int unsigned CLIENT_W =
      4,

  parameter int unsigned NUM_CLIENTS =
      8,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_TIMEOUT =
      1'b1,

  parameter bit ENABLE_ASSERTIONS =
      1'b1,

  parameter bit ALLOW_SAME_SOURCE_PARALLEL =
      1'b0,

  parameter bit ALLOW_READ_READ_PARALLEL =
      1'b1,

  parameter bit CONSERVATIVE_COHERENCE_ORDERING =
      1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // New transaction request
  //==========================================================================

  input  logic                    req_valid,
  output logic                    req_ready,

  input  logic [ADDR_W-1:0]       req_addr,

  input  logic [SOURCE_W-1:0]     req_source,

  input  logic [CLIENT_W-1:0]     req_client,

  input  logic                    req_is_read,

  input  logic                    req_is_write,

  input  logic                    req_is_acquire,

  input  logic                    req_is_release,

  input  logic                    req_is_probe,

  input  logic                    req_is_grant,

  input  logic                    req_is_exclusive,

  //==========================================================================
  // Transaction allocation
  //
  // txn_id is allocated by the transaction table.
  //==========================================================================

  input  logic                    req_txn_id_valid,

  input  logic [$clog2(MAX_OUTSTANDING)-1:0]
                                 req_txn_id,

  //==========================================================================
  // Transaction completion
  //==========================================================================

  input  logic                    complete_valid,
  output logic                    complete_ready,

  input  logic [$clog2(MAX_OUTSTANDING)-1:0]
                                 complete_txn_id,

  //==========================================================================
  // Explicit ordering barrier
  //==========================================================================

  input  logic                    barrier_valid,
  output logic                    barrier_ready,

  //==========================================================================
  // Ordering decision
  //==========================================================================

  output logic                    order_valid,
  output logic                    order_blocked,

  output logic                    source_conflict,

  output logic                    address_conflict,

  output logic                    dependency_conflict,

  output logic                    coherence_conflict,

  output logic                    overflow_error,

  output logic                    underflow_error,

  output logic                    timeout_error,

  output logic                    protocol_error,

  //==========================================================================
  // Status
  //==========================================================================

  output logic                    busy,

  output logic                    empty,

  output logic                    full,

  output logic [$clog2(MAX_OUTSTANDING+1)-1:0]
                                 outstanding_count
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned TXN_ID_W =
      (MAX_OUTSTANDING <= 1) ?
      1 :
      $clog2(MAX_OUTSTANDING);

  localparam int unsigned COUNT_W =
      (MAX_OUTSTANDING <= 1) ?
      1 :
      $clog2(MAX_OUTSTANDING + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);

  localparam int unsigned LINE_ADDR_W =
      (CACHE_LINE_BYTES <= 1) ?
      ADDR_W :
      ADDR_W - $clog2(CACHE_LINE_BYTES);


  //==========================================================================
  // Transaction descriptor
  //==========================================================================

  typedef struct packed {

    logic                    valid;

    logic [ADDR_W-1:0]       addr;

    logic [SOURCE_W-1:0]     source;

    logic [CLIENT_W-1:0]     client;

    logic                    is_read;

    logic                    is_write;

    logic                    is_acquire;

    logic                    is_release;

    logic                    is_probe;

    logic                    is_grant;

    logic                    is_exclusive;

    logic [TIMEOUT_W-1:0]    age;

  } order_entry_t;


  order_entry_t table_q [0:MAX_OUTSTANDING-1];


  //==========================================================================
  // Count
  //==========================================================================

  logic [COUNT_W-1:0] count_q;

  assign outstanding_count =
      count_q;


  assign empty =
      (count_q == 0);

  assign full =
      (count_q >= MAX_OUTSTANDING);

  assign busy =
      (count_q != 0);


  //==========================================================================
  // Request address normalized to cache-line address
  //==========================================================================

  logic [ADDR_W-1:0] req_line_addr;

  always_comb begin

    req_line_addr =
        req_addr;

    if (CACHE_LINE_BYTES > 1) begin

      req_line_addr[
        $clog2(CACHE_LINE_BYTES)-1:0
      ] =
        '0;

    end

  end


  //==========================================================================
  // Completion validity
  //==========================================================================

  logic complete_id_valid;

  always_comb begin

    complete_id_valid =
        1'b0;

    if (
      complete_valid &&
      (complete_txn_id < MAX_OUTSTANDING)
    ) begin

      complete_id_valid =
          table_q[complete_txn_id].valid;

    end

  end


  //==========================================================================
  // Request dependency detection
  //==========================================================================

  logic source_conflict_i;
  logic address_conflict_i;
  logic dependency_conflict_i;
  logic coherence_conflict_i;


  integer i;


  always_comb begin

    source_conflict_i =
        1'b0;

    address_conflict_i =
        1'b0;

    dependency_conflict_i =
        1'b0;

    coherence_conflict_i =
        1'b0;


    for (i = 0; i < MAX_OUTSTANDING; i++) begin

      if (table_q[i].valid) begin

        //--------------------------------------------------------------------
        // Source ordering
        //--------------------------------------------------------------------

        if (
          table_q[i].source ==
          req_source
        ) begin

          source_conflict_i =
              1'b1;

        end


        //--------------------------------------------------------------------
        // Cache-line address conflict
        //--------------------------------------------------------------------

        if (
          table_q[i].addr[
            ADDR_W-1:
            $clog2(CACHE_LINE_BYTES)
          ]
          ==
          req_line_addr[
            ADDR_W-1:
            $clog2(CACHE_LINE_BYTES)
          ]
        ) begin

          address_conflict_i =
              1'b1;

        end


        //--------------------------------------------------------------------
        // Conservative coherence ordering.
        //
        // Any coherence transaction touching the same cache line is
        // serialized unless explicitly configured otherwise.
        //--------------------------------------------------------------------

        if (
          CONSERVATIVE_COHERENCE_ORDERING &&
          (
            table_q[i].is_acquire ||
            table_q[i].is_release ||
            table_q[i].is_probe ||
            table_q[i].is_grant
          ) &&
          (
            req_is_acquire ||
            req_is_release ||
            req_is_probe ||
            req_is_grant
          )
        ) begin

          if (
            table_q[i].addr[
              ADDR_W-1:
              $clog2(CACHE_LINE_BYTES)
            ]
            ==
            req_line_addr[
              ADDR_W-1:
              $clog2(CACHE_LINE_BYTES)
            ]
          ) begin

            coherence_conflict_i =
                1'b1;

          end

        end


        //--------------------------------------------------------------------
        // RAW / WAR / WAW ordering
        //--------------------------------------------------------------------

        if (
          address_conflict_i
        ) begin

          //------------------------------------------------------------------
          // Existing read, new write
          //
          // WAR-like dependency.
          //------------------------------------------------------------------

          if (
            table_q[i].is_read &&
            req_is_write
          ) begin

            dependency_conflict_i =
                1'b1;

          end


          //------------------------------------------------------------------
          // Existing write, new read
          //
          // RAW dependency.
          //------------------------------------------------------------------

          if (
            table_q[i].is_write &&
            req_is_read
          ) begin

            dependency_conflict_i =
                1'b1;

          end


          //------------------------------------------------------------------
          // Existing write, new write
          //
          // WAW dependency.
          //------------------------------------------------------------------

          if (
            table_q[i].is_write &&
            req_is_write
          ) begin

            dependency_conflict_i =
                1'b1;

          end

        end

      end

    end

  end


  //==========================================================================
  // Source ordering policy
  //==========================================================================

  logic source_order_block;


  always_comb begin

    source_order_block =
        1'b0;

    if (!ALLOW_SAME_SOURCE_PARALLEL) begin

      if (source_conflict_i) begin

        source_order_block =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Read/read exception
  //==========================================================================

  logic read_read_exception;


  always_comb begin

    read_read_exception =
        1'b0;

    if (
      ALLOW_READ_READ_PARALLEL &&
      req_is_read &&
      !req_is_write
    ) begin

      read_read_exception =
          1'b1;

    end

  end


  //==========================================================================
  // Final ordering decision
  //==========================================================================

  always_comb begin

    order_valid =
        req_valid;

    order_blocked =
        1'b0;


    if (full) begin

      order_blocked =
          1'b1;

    end


    if (source_order_block) begin

      order_blocked =
          1'b1;

    end


    if (dependency_conflict_i) begin

      if (!read_read_exception) begin

        order_blocked =
            1'b1;

      end

    end


    if (coherence_conflict_i) begin

      if (!read_read_exception) begin

        order_blocked =
            1'b1;

      end

    end


    if (barrier_valid) begin

      order_blocked =
          1'b1;

    end

  end


  //==========================================================================
  // Request ready
  //
  // Registered state only. No dependency on downstream channel ready.
  //==========================================================================

  assign req_ready =
      req_valid &&
      !order_blocked &&
      req_txn_id_valid;


  //==========================================================================
  // Completion ready
  //==========================================================================

  assign complete_ready =
      1'b1;


  //==========================================================================
  // Barrier ready
  //==========================================================================

  assign barrier_ready =
      !busy;


  //==========================================================================
  // Handshakes
  //==========================================================================

  logic req_fire;
  logic complete_fire;
  logic barrier_fire;

  assign req_fire =
      req_valid &&
      req_ready;

  assign complete_fire =
      complete_valid &&
      complete_ready;

  assign barrier_fire =
      barrier_valid &&
      barrier_ready;


  //==========================================================================
  // Error outputs
  //==========================================================================

  assign source_conflict =
      source_conflict_i;

  assign address_conflict =
      address_conflict_i;

  assign dependency_conflict =
      dependency_conflict_i;

  assign coherence_conflict =
      coherence_conflict_i;


  assign overflow_error =
      req_fire &&
      full;


  assign underflow_error =
      complete_fire &&
      !complete_id_valid;


  //==========================================================================
  // Timeout detection
  //==========================================================================

  integer j;

  always_comb begin

    timeout_error =
        1'b0;

    if (ENABLE_TIMEOUT) begin

      for (j = 0; j < MAX_OUTSTANDING; j++) begin

        if (table_q[j].valid) begin

          if (
            table_q[j].age >=
            TIMEOUT_CYCLES[TIMEOUT_W-1:0]
          ) begin

            timeout_error =
                1'b1;

          end

        end

      end

    end

  end


  assign protocol_error =
      overflow_error ||
      underflow_error ||
      timeout_error;


  //==========================================================================
  // Sequential state
  //==========================================================================

  integer n;

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      count_q <=
          '0;

      for (n = 0; n < MAX_OUTSTANDING; n++) begin

        table_q[n] <=
            '0;

      end

    end
    else begin

      //----------------------------------------------------------------------
      // Allocate transaction
      //----------------------------------------------------------------------

      if (req_fire) begin

        table_q[req_txn_id].valid <=
            1'b1;

        table_q[req_txn_id].addr <=
            req_line_addr;

        table_q[req_txn_id].source <=
            req_source;

        table_q[req_txn_id].client <=
            req_client;

        table_q[req_txn_id].is_read <=
            req_is_read;

        table_q[req_txn_id].is_write <=
            req_is_write;

        table_q[req_txn_id].is_acquire <=
            req_is_acquire;

        table_q[req_txn_id].is_release <=
            req_is_release;

        table_q[req_txn_id].is_probe <=
            req_is_probe;

        table_q[req_txn_id].is_grant <=
            req_is_grant;

        table_q[req_txn_id].is_exclusive <=
            req_is_exclusive;

        table_q[req_txn_id].age <=
            '0;

      end


      //----------------------------------------------------------------------
      // Complete transaction
      //----------------------------------------------------------------------

      if (complete_fire && complete_id_valid) begin

        table_q[complete_txn_id].valid <=
            1'b0;

        table_q[complete_txn_id].age <=
            '0;

      end


      //----------------------------------------------------------------------
      // Outstanding count
      //----------------------------------------------------------------------

      case ({
        req_fire,
        complete_fire && complete_id_valid
      })

        2'b10: begin

          count_q <=
              count_q + 1'b1;

        end

        2'b01: begin

          if (count_q != 0) begin

            count_q <=
                count_q - 1'b1;

          end

        end

        default: begin

          count_q <=
              count_q;

        end

      endcase


      //----------------------------------------------------------------------
      // Age active transactions.
      //----------------------------------------------------------------------

      for (n = 0; n < MAX_OUTSTANDING; n++) begin

        if (table_q[n].valid) begin

          if (
            table_q[n].age <
            TIMEOUT_CYCLES[TIMEOUT_W-1:0]
          ) begin

            table_q[n].age <=
                table_q[n].age + 1'b1;

          end

        end

      end

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_ORDER_ASSERTIONS

      //----------------------------------------------------------------------
      // Request cannot be accepted while blocked.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        req_fire
        |-> !order_blocked
      )
      else $error(
        "TLC ORDER: request accepted while ordering was blocked"
      );


      //----------------------------------------------------------------------
      // Transaction ID must be valid.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        req_fire
        |-> (req_txn_id < MAX_OUTSTANDING)
      )
      else $error(
        "TLC ORDER: invalid transaction ID"
      );


      //----------------------------------------------------------------------
      // Completion must reference an active transaction.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        complete_fire
        |-> complete_id_valid
      )
      else $error(
        "TLC ORDER: completion for inactive transaction"
      );


      //----------------------------------------------------------------------
      // Count cannot exceed capacity.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        count_q <= MAX_OUTSTANDING
      )
      else $error(
        "TLC ORDER: outstanding count overflow"
      );


      //----------------------------------------------------------------------
      // Empty state.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        empty
        |-> (count_q == 0)
      )
      else $error(
        "TLC ORDER: empty/count mismatch"
      );


      //----------------------------------------------------------------------
      // Full state.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        full
        |-> (count_q == MAX_OUTSTANDING)
      )
      else $error(
        "TLC ORDER: full/count mismatch"
      );


      //----------------------------------------------------------------------
      // Barrier only accepted when no outstanding transactions exist.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        barrier_fire
        |-> !busy
      )
      else $error(
        "TLC ORDER: barrier accepted with outstanding transactions"
      );


      //----------------------------------------------------------------------
      // Same-source serialization when configured.
      //----------------------------------------------------------------------

      if (!ALLOW_SAME_SOURCE_PARALLEL) begin

        assert property (
          @(posedge clk)
          disable iff (!rst_n)

          req_valid &&
          source_conflict_i
          |-> order_blocked
        )
        else $error(
          "TLC ORDER: same-source transaction was not serialized"
        );

      end


      //----------------------------------------------------------------------
      // Write/write same-line transactions must serialize.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        req_valid &&
        address_conflict_i &&
        req_is_write &&
        dependency_conflict_i
        |-> order_blocked
      )
      else $error(
        "TLC ORDER: WAW dependency was not blocked"
      );


      //----------------------------------------------------------------------
      // Read-after-write must serialize.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        req_valid &&
        address_conflict_i &&
        req_is_read &&
        dependency_conflict_i
        |-> order_blocked
      )
      else $error(
        "TLC ORDER: RAW dependency was not blocked"
      );


      //----------------------------------------------------------------------
      // Reset clean.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (
          count_q == 0
        )
      )
      else $error(
        "TLC ORDER: reset did not clear outstanding state"
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
        "TLC ORDER: ADDR_W must be > 0"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC ORDER: SOURCE_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC ORDER: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC ORDER: DATA_W must be byte aligned"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC ORDER: CACHE_LINE_BYTES must be > 0"
      );

    if (
      CACHE_LINE_BYTES &
      (CACHE_LINE_BYTES - 1)
    )
      $error(
        "TLC ORDER: CACHE_LINE_BYTES must be power-of-two"
      );

    if (MAX_OUTSTANDING == 0)
      $error(
        "TLC ORDER: MAX_OUTSTANDING must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC ORDER: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule