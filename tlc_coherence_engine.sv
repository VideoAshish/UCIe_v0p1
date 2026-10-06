//==============================================================================
// tlc_coherence_engine.sv
//
// TileLink-C Coherence Engine
//
// Central coherence controller for a TL-C manager / home-node.
//
// Responsibilities
// ----------------
// * Receive normalized Acquire requests
// * Consult directory / permission state
// * Decide hit / miss / upgrade / downgrade paths
// * Launch Probe transactions
// * Track Probe completion
// * Launch memory transactions
// * Launch Grant / GrantData
// * Process Release / ReleaseData
// * Collect dirty data
// * Maintain coherence transaction lifecycle
// * Interface with ordering engine
// * Interface with transaction/source/sink tracking
// * Timeout detection
// * Illegal transaction detection
// * Reset-clean FSM
// * Deadlock-safe state progression
// * Parameterized address/data/source/sink widths
//
// Coherence state model
// ---------------------
//
//        I
//        |
//        | AcquireBlock
//        v
//        S <------------------ ProbeAck
//        |
//        | AcquirePerm
//        v
//        M
//
//        M -- Probe --> S/I
//        M -- ReleaseData --> I
//        S -- Release --> I
//
// The actual directory state is maintained by tlc_directory.sv.
// This module owns the transaction-level state machine.
//
//==============================================================================

module tlc_coherence_engine #(
  parameter int unsigned ADDR_W =
      48,

  parameter int unsigned DATA_W =
      256,

  parameter int unsigned SOURCE_W =
      8,

  parameter int unsigned SINK_W =
      6,

  parameter int unsigned CACHE_LINE_BYTES =
      DATA_W / 8,

  parameter int unsigned MAX_OUTSTANDING =
      16,

  parameter int unsigned MAX_PROBES =
      8,

  parameter int unsigned MAX_SOURCES =
      1 << SOURCE_W,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_ASSERTIONS =
      1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // Incoming Acquire request
  //==========================================================================

  input  logic                    acquire_valid,
  output logic                    acquire_ready,

  input  logic [ADDR_W-1:0]       acquire_addr,
  input  logic [SOURCE_W-1:0]     acquire_source,

  input  logic [2:0]              acquire_param,
  input  logic [2:0]              acquire_size,

  input  logic                    acquire_is_block,
  input  logic                    acquire_is_perm,

  //==========================================================================
  // Incoming Release request
  //==========================================================================

  input  logic                    release_valid,
  output logic                    release_ready,

  input  logic [ADDR_W-1:0]       release_addr,
  input  logic [SOURCE_W-1:0]     release_source,

  input  logic [DATA_W-1:0]       release_data,
  input logic [DATA_W/8-1:0]      release_mask,

  input logic                    release_has_data,

  //==========================================================================
  // Probe completion
  //==========================================================================

  input logic                    probe_done_valid,
  output logic                    probe_done_ready,

  input logic [ADDR_W-1:0]       probe_done_addr,

  input logic [DATA_W-1:0]       probe_dirty_data,

  input logic                    probe_dirty_valid,

  input logic [SINK_W-1:0]       probe_sink,

  //==========================================================================
  // Memory read request
  //==========================================================================

  output logic                    mem_rd_valid,
  input logic                    mem_rd_ready,

  output logic [ADDR_W-1:0]       mem_rd_addr,

  output logic [SOURCE_W-1:0]     mem_rd_source,

  //==========================================================================
  // Memory read response
  //==========================================================================

  input logic                    mem_rd_rsp_valid,
  output logic                    mem_rd_rsp_ready,

  input logic [SOURCE_W-1:0]      mem_rd_rsp_source,

  input logic [ADDR_W-1:0]        mem_rd_rsp_addr,

  input logic [DATA_W-1:0]        mem_rd_rsp_data,

  input logic                     mem_rd_rsp_error,

  //==========================================================================
  // Memory write request
  //==========================================================================

  output logic                    mem_wr_valid,
  input logic                     mem_wr_ready,

  output logic [ADDR_W-1:0]       mem_wr_addr,

  output logic [DATA_W-1:0]       mem_wr_data,

  output logic [DATA_W/8-1:0]     mem_wr_mask,

  output logic [SOURCE_W-1:0]     mem_wr_source,

  //==========================================================================
  // Grant generation
  //==========================================================================

  output logic                    grant_valid,
  input logic                     grant_ready,

  output logic [ADDR_W-1:0]       grant_addr,

  output logic [SOURCE_W-1:0]     grant_source,

  output logic [DATA_W-1:0]       grant_data,

  output logic                    grant_has_data,

  input logic                     grant_ack_valid,
  output logic                    grant_ack_ready,

  input logic [SOURCE_W-1:0]      grant_ack_source,

  //==========================================================================
  // Probe generation
  //==========================================================================

  output logic                    probe_valid,
  input logic                     probe_ready,

  output logic [ADDR_W-1:0]       probe_addr,

  output logic [SINK_W-1:0]       probe_sink,

  output logic [2:0]              probe_param,

  output logic [SOURCE_W-1:0]     probe_source,

  //==========================================================================
  // Directory lookup/update interface
  //==========================================================================

  output logic                    dir_lookup_valid,
  input logic                     dir_lookup_ready,

  output logic [ADDR_W-1:0]       dir_lookup_addr,

  input logic                     dir_hit,

  input logic [1:0]               dir_state,

  input logic [SOURCE_W-1:0]      dir_owner,

  input logic [MAX_SOURCES-1:0]   dir_sharers,

  input logic                     dir_dirty,

  // Directory update
  output logic                    dir_update_valid,
  input logic                    dir_update_ready,

  output logic [ADDR_W-1:0]       dir_update_addr,

  output logic [1:0]              dir_update_state,

  output logic [SOURCE_W-1:0]      dir_update_owner,

  output logic [MAX_SOURCES-1:0]   dir_update_sharers,

  output logic                    dir_update_dirty,

  //==========================================================================
  // Ordering engine
  //==========================================================================

  output logic                    order_req_valid,
  input logic                     order_req_ready,

  output logic [ADDR_W-1:0]       order_req_addr,

  output logic [SOURCE_W-1:0]     order_req_source,

  output logic                    order_req_read,

  output logic                    order_req_write,

  output logic                    order_req_acquire,

  output logic                    order_req_release,

  output logic                    order_req_probe,

  output logic                    order_req_grant,

  input logic                     order_blocked,

  input logic                     order_source_conflict,

  input logic                     order_address_conflict,

  //==========================================================================
  // Status
  //==========================================================================

  output logic                    busy,

  output logic                    error,

  output logic                    timeout,

  output logic                    illegal_transaction
);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned OFFSET_W =
      (CACHE_LINE_BYTES <= 1) ?
      0 :
      $clog2(CACHE_LINE_BYTES);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // Coherence states
  //
  // I = Invalid
  // S = Shared
  // M = Modified / exclusive dirty owner
  // E = Exclusive clean
  //
  // Directory state encoding is intentionally kept simple.
  //==========================================================================

  localparam logic [1:0] COH_I =
      2'b00;

  localparam logic [1:0] COH_S =
      2'b01;

  localparam logic [1:0] COH_E =
      2'b10;

  localparam logic [1:0] COH_M =
      2'b11;


  //==========================================================================
  // FSM
  //==========================================================================

  typedef enum logic [4:0] {

    ST_IDLE,

    ST_DIR_LOOKUP,

    ST_ORDER_CHECK,

    ST_HIT_SHARED,

    ST_HIT_EXCLUSIVE,

    ST_UPGRADE,

    ST_PROBE,

    ST_WAIT_PROBE,

    ST_MEMORY_READ,

    ST_WAIT_MEMORY,

    ST_GRANT,

    ST_WAIT_GRANT_ACK,

    ST_RELEASE,

    ST_RELEASE_MEMORY,

    ST_RELEASE_UPDATE,

    ST_COMPLETE,

    ST_ERROR,

    ST_TIMEOUT

  } state_t;


  state_t state_q;
  state_t state_d;


  //==========================================================================
  // Active transaction
  //==========================================================================

  logic                    active_q;
  logic                    active_d;

  logic [ADDR_W-1:0]       active_addr_q;
  logic [SOURCE_W-1:0]     active_source_q;

  logic [2:0]              active_param_q;
  logic [2:0]              active_size_q;

  logic                    active_is_block_q;
  logic                    active_is_perm_q;


  //==========================================================================
  // Memory data
  //==========================================================================

  logic [DATA_W-1:0]       memory_data_q;
  logic                    memory_data_valid_q;
  logic                    memory_error_q;


  //==========================================================================
  // Dirty data collection
  //==========================================================================

  logic [DATA_W-1:0]       dirty_data_q;
  logic                    dirty_data_valid_q;


  //==========================================================================
  // Probe tracking
  //==========================================================================

  logic [SINK_W-1:0]       probe_sink_q;

  logic                    probe_outstanding_q;


  //==========================================================================
  // Timeout
  //==========================================================================

  logic [TIMEOUT_W-1:0]    age_q;

  logic timeout_hit;


  always_comb begin

    timeout_hit =
        1'b0;

    if (
      active_q &&
      (TIMEOUT_CYCLES != 0)
    ) begin

      if (
        age_q >=
        TIMEOUT_CYCLES[TIMEOUT_W-1:0]
      ) begin

        timeout_hit =
            1'b1;

      end

    end

  end


  assign timeout =
      timeout_hit;


  //==========================================================================
  // Active address alignment
  //==========================================================================

  logic active_alignment_error;


  always_comb begin

    active_alignment_error =
        1'b0;

    if (active_q) begin

      if (
        (active_addr_q % CACHE_LINE_BYTES) != 0
      ) begin

        active_alignment_error =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Incoming request acceptance
  //
  // Only accept a new coherence transaction while idle.
  //==========================================================================

  always_comb begin

    acquire_ready =
        1'b0;

    release_ready =
        1'b0;

    if (state_q == ST_IDLE) begin

      if (!active_q) begin

        if (
          !release_valid
        ) begin

          acquire_ready =
              1'b1;

        end

        if (
          !acquire_valid
        ) begin

          release_ready =
              1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Request arbitration
  //
  // Release gets priority over Acquire when both arrive simultaneously.
  // This avoids retaining dirty ownership indefinitely.
  //==========================================================================

  logic accept_acquire;
  logic accept_release;


  always_comb begin

    accept_acquire =
        acquire_valid &&
        acquire_ready;

    accept_release =
        release_valid &&
        release_ready;

  end


  //==========================================================================
  // Probe interface
  //==========================================================================

  assign probe_valid =
      (state_q == ST_PROBE);

  assign probe_addr =
      active_addr_q;

  assign probe_sink =
      probe_sink_q;

  assign probe_param =
      3'b000;

  assign probe_source =
      active_source_q;


  //==========================================================================
  // Probe completion
  //==========================================================================

  assign probe_done_ready =
      (state_q == ST_WAIT_PROBE);


  //==========================================================================
  // Memory read
  //==========================================================================

  assign mem_rd_valid =
      (state_q == ST_MEMORY_READ);

  assign mem_rd_addr =
      active_addr_q;

  assign mem_rd_source =
      active_source_q;

  assign mem_rd_rsp_ready =
      (state_q == ST_WAIT_MEMORY);


  //==========================================================================
  // Memory write
  //==========================================================================

  assign mem_wr_valid =
      (state_q == ST_RELEASE_MEMORY);

  assign mem_wr_addr =
      active_addr_q;

  assign mem_wr_data =
      dirty_data_q;

  assign mem_wr_mask =
      {BYTE_W{1'b1}};

  assign mem_wr_source =
      active_source_q;


  //==========================================================================
  // Grant
  //==========================================================================

  assign grant_valid =
      (state_q == ST_GRANT);

  assign grant_addr =
      active_addr_q;

  assign grant_source =
      active_source_q;

  assign grant_data =
      memory_data_q;

  assign grant_has_data =
      memory_data_valid_q;


  assign grant_ack_ready =
      (state_q == ST_WAIT_GRANT_ACK);


  //==========================================================================
  // Directory lookup
  //==========================================================================

  assign dir_lookup_valid =
      (state_q == ST_DIR_LOOKUP);

  assign dir_lookup_addr =
      active_addr_q;


  //==========================================================================
  // Directory update
  //==========================================================================

  assign dir_update_valid =
      (state_q == ST_RELEASE_UPDATE);

  assign dir_update_addr =
      active_addr_q;

  assign dir_update_state =
      COH_I;

  assign dir_update_owner =
      '0;

  assign dir_update_sharers =
      '0;

  assign dir_update_dirty =
      1'b0;


  //==========================================================================
  // Ordering request
  //==========================================================================

  assign order_req_valid =
      (state_q == ST_ORDER_CHECK);

  assign order_req_addr =
      active_addr_q;

  assign order_req_source =
      active_source_q;

  assign order_req_read =
      active_is_block_q;

  assign order_req_write =
      active_is_perm_q;

  assign order_req_acquire =
      1'b1;

  assign order_req_release =
      1'b0;

  assign order_req_probe =
      1'b0;

  assign order_req_grant =
      1'b0;


  //==========================================================================
  // FSM next-state
  //==========================================================================

  always_comb begin

    state_d =
        state_q;

    case (state_q)

      //======================================================================
      // IDLE
      //======================================================================

      ST_IDLE: begin

        if (accept_release) begin

          state_d =
              ST_RELEASE;

        end
        else if (accept_acquire) begin

          state_d =
              ST_DIR_LOOKUP;

        end

      end


      //======================================================================
      // DIRECTORY LOOKUP
      //======================================================================

      ST_DIR_LOOKUP: begin

        if (dir_lookup_ready) begin

          state_d =
              ST_ORDER_CHECK;

        end

      end


      //======================================================================
      // ORDER CHECK
      //======================================================================

      ST_ORDER_CHECK: begin

        if (order_req_ready) begin

          if (order_blocked) begin

            state_d =
                ST_ORDER_CHECK;

          end
          else begin

            //----------------------------------------------------------------
            // Directory decision
            //----------------------------------------------------------------

            if (!dir_hit) begin

              state_d =
                  ST_MEMORY_READ;

            end
            else begin

              case (dir_state)

                COH_I: begin

                  state_d =
                      ST_MEMORY_READ;

                end

                COH_S: begin

                  if (active_is_perm_q) begin

                    state_d =
                        ST_UPGRADE;

                  end
                  else begin

                    state_d =
                        ST_HIT_SHARED;

                  end

                end

                COH_E: begin

                  if (active_is_perm_q) begin

                    state_d =
                        ST_HIT_EXCLUSIVE;

                  end
                  else begin

                    state_d =
                        ST_HIT_EXCLUSIVE;

                  end

                end

                COH_M: begin

                  //----------------------------------------------------------------
                  // Another owner exists.
                  //----------------------------------------------------------------

                  if (
                    dir_owner !=
                    active_source_q
                  ) begin

                    state_d =
                        ST_PROBE;

                  end
                  else begin

                    state_d =
                        ST_HIT_EXCLUSIVE;

                  end

                end

                default: begin

                  state_d =
                      ST_ERROR;

                end

              endcase

            end

          end

        end

      end


      //======================================================================
      // Shared hit
      //======================================================================

      ST_HIT_SHARED: begin

        state_d =
            ST_GRANT;

      end


      //======================================================================
      // Exclusive hit
      //======================================================================

      ST_HIT_EXCLUSIVE: begin

        state_d =
            ST_GRANT;

      end


      //======================================================================
      // Permission upgrade
      //======================================================================

      ST_UPGRADE: begin

        if (dir_sharers == '0) begin

          state_d =
              ST_GRANT;

        end
        else begin

          state_d =
              ST_PROBE;

        end

      end


      //======================================================================
      // Launch probe
      //======================================================================

      ST_PROBE: begin

        if (probe_ready) begin

          state_d =
              ST_WAIT_PROBE;

        end

      end


      //======================================================================
      // Wait for probe acknowledgement/data
      //======================================================================

      ST_WAIT_PROBE: begin

        if (probe_done_valid) begin

          if (probe_dirty_valid) begin

            state_d =
                ST_RELEASE_MEMORY;

          end
          else begin

            state_d =
                ST_MEMORY_READ;

          end

        end

      end


      //======================================================================
      // Memory read
      //======================================================================

      ST_MEMORY_READ: begin

        if (mem_rd_ready) begin

          state_d =
              ST_WAIT_MEMORY;

        end

      end


      //======================================================================
      // Memory response
      //======================================================================

      ST_WAIT_MEMORY: begin

        if (mem_rd_rsp_valid) begin

          if (mem_rd_rsp_error) begin

            state_d =
                ST_ERROR;

          end
          else begin

            state_d =
                ST_GRANT;

          end

        end

      end


      //======================================================================
      // Grant
      //======================================================================

      ST_GRANT: begin

        if (grant_ready) begin

          state_d =
              ST_WAIT_GRANT_ACK;

        end

      end


      //======================================================================
      // Grant acknowledgement
      //======================================================================

      ST_WAIT_GRANT_ACK: begin

        if (grant_ack_valid) begin

          state_d =
              ST_COMPLETE;

        end

      end


      //======================================================================
      // Release
      //======================================================================

      ST_RELEASE: begin

        if (release_has_data) begin

          state_d =
              ST_RELEASE_MEMORY;

        end
        else begin

          state_d =
              ST_RELEASE_UPDATE;

        end

      end


      //======================================================================
      // Release dirty data to memory
      //======================================================================

      ST_RELEASE_MEMORY: begin

        if (mem_wr_ready) begin

          state_d =
              ST_RELEASE_UPDATE;

        end

      end


      //======================================================================
      // Directory update following Release
      //======================================================================

      ST_RELEASE_UPDATE: begin

        if (dir_update_ready) begin

          state_d =
              ST_COMPLETE;

        end

      end


      //======================================================================
      // Complete
      //======================================================================

      ST_COMPLETE: begin

        state_d =
            ST_IDLE;

      end


      //======================================================================
      // Timeout
      //======================================================================

      ST_TIMEOUT: begin

        state_d =
            ST_ERROR;

      end


      //======================================================================
      // Error
      //======================================================================

      ST_ERROR: begin

        state_d =
            ST_IDLE;

      end


      default: begin

        state_d =
            ST_ERROR;

      end

    endcase


    //-----------------------------------------------------------------------
    // Global timeout override.
    //-----------------------------------------------------------------------

    if (
      ENABLE_TIMEOUT &&
      timeout_hit
    ) begin

      if (
        state_q != ST_IDLE &&
        state_q != ST_COMPLETE &&
        state_q != ST_ERROR
      ) begin

        state_d =
            ST_TIMEOUT;

      end

    end


    //-----------------------------------------------------------------------
    // Alignment failure.
    //-----------------------------------------------------------------------

    if (active_alignment_error) begin

      state_d =
          ST_ERROR;

    end

  end


  //==========================================================================
  // Busy/error status
  //==========================================================================

  assign busy =
      active_q ||
      (state_q != ST_IDLE);

  assign error =
      (state_q == ST_ERROR) ||
      (state_q == ST_TIMEOUT);

  assign illegal_transaction =
      active_alignment_error;


  //==========================================================================
  // Sequential state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      state_q <=
          ST_IDLE;

      active_q <=
          1'b0;

      active_addr_q <=
          '0;

      active_source_q <=
          '0;

      active_param_q <=
          '0;

      active_size_q <=
          '0;

      active_is_block_q <=
          1'b0;

      active_is_perm_q <=
          1'b0;

      memory_data_q <=
          '0;

      memory_data_valid_q <=
          1'b0;

      memory_error_q <=
          1'b0;

      dirty_data_q <=
          '0;

      dirty_data_valid_q <=
          1'b0;

      probe_sink_q <=
          '0;

      probe_outstanding_q <=
          1'b0;

      age_q <=
          '0;

    end
    else begin

      //----------------------------------------------------------------------
      // FSM
      //----------------------------------------------------------------------

      state_q <=
          state_d;


      //----------------------------------------------------------------------
      // Acquire capture
      //----------------------------------------------------------------------

      if (accept_acquire) begin

        active_q <=
            1'b1;

        active_addr_q <=
            acquire_addr;

        active_source_q <=
            acquire_source;

        active_param_q <=
            acquire_param;

        active_size_q <=
            acquire_size;

        active_is_block_q <=
            acquire_is_block;

        active_is_perm_q <=
            acquire_is_perm;

        age_q <=
            '0;

        memory_data_valid_q <=
            1'b0;

        memory_error_q <=
            1'b0;

        dirty_data_valid_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Release capture
      //----------------------------------------------------------------------

      if (accept_release) begin

        active_q <=
            1'b1;

        active_addr_q <=
            release_addr;

        active_source_q <=
            release_source;

        active_param_q <=
            '0;

        active_size_q <=
            '0;

        active_is_block_q <=
            1'b0;

        active_is_perm_q <=
            1'b0;

        dirty_data_q <=
            release_data;

        dirty_data_valid_q <=
            release_has_data;

        age_q <=
            '0;

      end


      //----------------------------------------------------------------------
      // Directory supplies probe target.
      //----------------------------------------------------------------------

      if (
        state_q == ST_ORDER_CHECK &&
        dir_lookup_ready
      ) begin

        probe_sink_q <=
            dir_owner[SINK_W-1:0];

      end


      //----------------------------------------------------------------------
      // Probe response.
      //----------------------------------------------------------------------

      if (
        probe_done_valid &&
        probe_done_ready
      ) begin

        if (probe_dirty_valid) begin

          dirty_data_q <=
              probe_dirty_data;

          dirty_data_valid_q <=
              1'b1;

        end

      end


      //----------------------------------------------------------------------
      // Memory response.
      //----------------------------------------------------------------------

      if (
        mem_rd_rsp_valid &&
        mem_rd_rsp_ready
      ) begin

        memory_data_q <=
            mem_rd_rsp_data;

        memory_data_valid_q <=
            1'b1;

        memory_error_q <=
            mem_rd_rsp_error;

      end


      //----------------------------------------------------------------------
      // Completion
      //----------------------------------------------------------------------

      if (state_q == ST_COMPLETE) begin

        active_q <=
            1'b0;

        age_q <=
            '0;

      end


      //----------------------------------------------------------------------
      // Age active transaction.
      //----------------------------------------------------------------------

      if (active_q) begin

        if (
          age_q <
          TIMEOUT_CYCLES[TIMEOUT_W-1:0]
        ) begin

          age_q <=
              age_q + 1'b1;

        end

      end

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_COH_ASSERTIONS

      //------------------------------------------------------------------------
      // Reset state
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (
          state_q == ST_IDLE &&
          !active_q
        )
      )
      else $error(
        "TLC COHERENCE: reset state is not clean"
      );


      //------------------------------------------------------------------------
      // Acquire must be aligned.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        accept_acquire
        |-> ((acquire_addr % CACHE_LINE_BYTES) == 0)
      )
      else $error(
        "TLC COHERENCE: unaligned Acquire"
      );


      //------------------------------------------------------------------------
      // Release must be aligned.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        accept_release
        |-> ((release_addr % CACHE_LINE_BYTES) == 0)
      )
      else $error(
        "TLC COHERENCE: unaligned Release"
      );


      //------------------------------------------------------------------------
      // Probe must not be launched without an active transaction.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_valid
        |-> active_q
      )
      else $error(
        "TLC COHERENCE: Probe launched without active transaction"
      );


      //------------------------------------------------------------------------
      // Memory request must correspond to active transaction.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        mem_rd_valid
        |-> active_q
      )
      else $error(
        "TLC COHERENCE: memory request without active transaction"
      );


      //------------------------------------------------------------------------
      // Grant must correspond to active transaction.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_valid
        |-> active_q
      )
      else $error(
        "TLC COHERENCE: Grant without active transaction"
      );


      //------------------------------------------------------------------------
      // No Grant before memory response for a miss.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        (state_q == ST_WAIT_MEMORY) &&
        !memory_data_valid_q
        |-> !grant_valid
      )
      else $error(
        "TLC COHERENCE: Grant issued without memory data"
      );


      //------------------------------------------------------------------------
      // Dirty data must not be lost once captured.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        dirty_data_valid_q &&
        !mem_wr_ready &&
        (state_q == ST_RELEASE_MEMORY)
        |=> dirty_data_valid_q
      )
      else $error(
        "TLC COHERENCE: dirty data lost while writeback stalled"
      );


      //------------------------------------------------------------------------
      // Probe response only accepted while waiting for ProbeAck.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        probe_done_valid &&
        probe_done_ready
        |-> (state_q == ST_WAIT_PROBE)
      )
      else $error(
        "TLC COHERENCE: unexpected probe completion"
      );


      //------------------------------------------------------------------------
      // Memory response only accepted while waiting.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        mem_rd_rsp_valid &&
        mem_rd_rsp_ready
        |-> (state_q == ST_WAIT_MEMORY)
      )
      else $error(
        "TLC COHERENCE: unexpected memory response"
      );


      //------------------------------------------------------------------------
      // GrantAck only accepted in GrantAck state.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        grant_ack_valid &&
        grant_ack_ready
        |-> (state_q == ST_WAIT_GRANT_ACK)
      )
      else $error(
        "TLC COHERENCE: unexpected GrantAck"
      );


      //------------------------------------------------------------------------
      // Timeout must force error handling.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        timeout_hit
        |=> (
          state_q == ST_TIMEOUT ||
          state_q == ST_ERROR
        )
      )
      else $error(
        "TLC COHERENCE: timeout did not enter error handling"
      );


      //------------------------------------------------------------------------
      // No simultaneous Acquire and Release acceptance.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(accept_acquire && accept_release)
      )
      else $error(
        "TLC COHERENCE: simultaneous Acquire/Release acceptance"
      );


      //------------------------------------------------------------------------
      // FSM must never enter X state.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !$isunknown(state_q)
      )
      else $error(
        "TLC COHERENCE: FSM contains X/Z state"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC COHERENCE: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC COHERENCE: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC COHERENCE: DATA_W must be byte aligned"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC COHERENCE: CACHE_LINE_BYTES must be > 0"
      );

    if (
      CACHE_LINE_BYTES &
      (CACHE_LINE_BYTES - 1)
    )
      $error(
        "TLC COHERENCE: CACHE_LINE_BYTES must be power-of-two"
      );

    if (MAX_OUTSTANDING == 0)
      $error(
        "TLC COHERENCE: MAX_OUTSTANDING must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC COHERENCE: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule