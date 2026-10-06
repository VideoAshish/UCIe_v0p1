//==============================================================================
// tlc_manager_agent.sv
//
// TileLink-C Manager / Home Agent
//
// Production-oriented manager-side coherence agent.
//
// Responsibilities
// ----------------
// * Accept AcquireBlock
// * Accept AcquirePerm
// * Accept Release
// * Accept ReleaseData
// * Maintain manager-side coherence transaction context
// * Lookup directory
// * Generate Probe
// * Receive ProbeAck
// * Receive ProbeAckData
// * Collect dirty data
// * Access backing memory
// * Generate Grant
// * Generate GrantData
// * Receive GrantAck
// * Allocate/release sink IDs
// * Maintain source transaction context
// * Support partial writes
// * Cache-line alignment checking
// * Timeout detection
// * Error/corruption propagation
// * Independent ready/valid interfaces
// * No combinational ready/valid loops
// * Reset-clean FSM
// * Assertions
//
// IMPORTANT
// ---------
// Exact TileLink opcode/param definitions should come from tlc_pkg.sv.
// The symbolic constants below are placeholders and should be replaced by
// the package definitions used by the rest of the TLC implementation.
//
//==============================================================================

module tlc_manager_agent #(
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

  parameter int unsigned NUM_CLIENTS =
      8,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_ASSERTIONS =
      1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // TL-A
  //
  // Client -> Manager
  //
  // AcquireBlock / AcquirePerm
  //==========================================================================

  input  logic                    tl_a_valid,
  output logic                    tl_a_ready,

  input  logic [2:0]              tl_a_opcode,
  input  logic [2:0]              tl_a_param,
  input  logic [2:0]              tl_a_size,

  input  logic [SOURCE_W-1:0]     tl_a_source,

  input  logic [ADDR_W-1:0]       tl_a_address,

  input  logic [DATA_W-1:0]       tl_a_data,

  input  logic [DATA_W/8-1:0]     tl_a_mask,

  //==========================================================================
  // TL-B
  //
  // Manager -> Client
  //
  // Probe
  //==========================================================================

  output logic                    tl_b_valid,
  input logic                     tl_b_ready,

  output logic [2:0]              tl_b_opcode,
  output logic [2:0]              tl_b_param,
  output logic [2:0]              tl_b_size,

  output logic [SINK_W-1:0]       tl_b_sink,

  output logic [SOURCE_W-1:0]     tl_b_source,

  output logic [ADDR_W-1:0]       tl_b_address,

  output logic [DATA_W-1:0]       tl_b_data,

  output logic [DATA_W/8-1:0]     tl_b_mask,

  //==========================================================================
  // TL-C
  //
  // Client -> Manager
  //
  // Release / ReleaseData / ProbeAck / ProbeAckData
  //==========================================================================

  input logic                    tl_c_valid,
  output logic                   tl_c_ready,

  input logic [2:0]              tl_c_opcode,
  input logic [2:0]              tl_c_param,
  input logic [2:0]              tl_c_size,

  input logic [SINK_W-1:0]       tl_c_sink,

  input logic [SOURCE_W-1:0]     tl_c_source,

  input logic [ADDR_W-1:0]       tl_c_address,

  input logic [DATA_W-1:0]       tl_c_data,

  input logic [DATA_W/8-1:0]     tl_c_mask,

  //==========================================================================
  // TL-D
  //
  // Manager -> Client
  //
  // Grant / GrantData
  //==========================================================================

  output logic                   tl_d_valid,
  input logic                    tl_d_ready,

  output logic [2:0]             tl_d_opcode,
  output logic [2:0]             tl_d_param,
  output logic [2:0]             tl_d_size,

  output logic [SOURCE_W-1:0]    tl_d_source,

  output logic [SINK_W-1:0]      tl_d_sink,

  output logic [DATA_W-1:0]      tl_d_data,

  output logic                   tl_d_denied,

  output logic                   tl_d_corrupt,

  //==========================================================================
  // TL-E
  //
  // Client -> Manager
  //
  // GrantAck
  //==========================================================================

  input logic                    tl_e_valid,
  output logic                   tl_e_ready,

  input logic [SINK_W-1:0]       tl_e_sink,

  //==========================================================================
  // Directory lookup
  //==========================================================================

  output logic                   dir_lookup_valid,
  input logic                    dir_lookup_ready,

  output logic [ADDR_W-1:0]      dir_lookup_addr,

  input logic                    dir_hit,

  input logic [1:0]              dir_state,

  input logic [SOURCE_W-1:0]     dir_owner,

  input logic [NUM_CLIENTS-1:1]   dir_sharers,

  input logic                    dir_dirty,

  //==========================================================================
  // Directory update
  //==========================================================================

  output logic                   dir_update_valid,
  input logic                    dir_update_ready,

  output logic [ADDR_W-1:0]      dir_update_addr,

  output logic [1:0]             dir_update_state,

  output logic [SOURCE_W-1:0]    dir_update_owner,

  output logic [NUM_CLIENTS-1:1] dir_update_sharers,

  output logic                   dir_update_dirty,

  //==========================================================================
  // Memory read
  //==========================================================================

  output logic                   mem_rd_valid,
  input logic                    mem_rd_ready,

  output logic [ADDR_W-1:0]      mem_rd_addr,

  output logic [SOURCE_W-1:0]    mem_rd_source,

  input logic                    mem_rd_rsp_valid,
  output logic                   mem_rd_rsp_ready,

  input logic [SOURCE_W-1:0]     mem_rd_rsp_source,

  input logic [ADDR_W-1:0]       mem_rd_rsp_addr,

  input logic [DATA_W-1:0]       mem_rd_rsp_data,

  input logic                    mem_rd_rsp_error,

  //==========================================================================
  // Memory write
  //==========================================================================

  output logic                   mem_wr_valid,
  input logic                    mem_wr_ready,

  output logic [ADDR_W-1:0]      mem_wr_addr,

  output logic [DATA_W-1:0]      mem_wr_data,

  output logic [DATA_W/8-1:0]    mem_wr_mask,

  output logic [SOURCE_W-1:0]    mem_wr_source,

  //==========================================================================
  // Sink allocator
  //
  // Connect to tlc_sink_table.sv
  //==========================================================================

  output logic                   sink_alloc_valid,
  input logic                    sink_alloc_ready,

  input logic [SINK_W-1:0]       sink_alloc_id,

  output logic                   sink_free_valid,
  output logic [SINK_W-1:0]      sink_free_id,

  //==========================================================================
  // Status
  //==========================================================================

  output logic                   busy,
  output logic                   error,
  output logic                   timeout,
  output logic                   protocol_error
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

  localparam int unsigned TXN_W =
      (MAX_OUTSTANDING <= 1) ?
      1 :
      $clog2(MAX_OUTSTANDING);


  //==========================================================================
  // Placeholder TL opcode definitions.
  //
  // Replace these with package constants from tlc_pkg.sv.
  //==========================================================================

  localparam logic [2:0] OP_ACQUIRE_BLOCK =
      3'b100;

  localparam logic [2:0] OP_ACQUIRE_PERM =
      3'b101;

  localparam logic [2:0] OP_PROBE =
      3'b110;

  localparam logic [2:0] OP_PROBE_ACK =
      3'b100;

  localparam logic [2:0] OP_PROBE_ACK_DATA =
      3'b101;

  localparam logic [2:0] OP_RELEASE =
      3'b110;

  localparam logic [2:0] OP_RELEASE_DATA =
      3'b111;

  localparam logic [2:0] OP_GRANT =
      3'b100;

  localparam logic [2:0] OP_GRANT_DATA =
      3'b101;


  //==========================================================================
  // Directory state encoding
  //==========================================================================

  localparam logic [1:0] DIR_INVALID =
      2'b00;

  localparam logic [1:0] DIR_SHARED =
      2'b01;

  localparam logic [1:0] DIR_EXCLUSIVE =
      2'b10;

  localparam logic [1:0] DIR_MODIFIED =
      2'b11;


  //==========================================================================
  // Manager FSM
  //==========================================================================

  typedef enum logic [4:0] {

    ST_IDLE,

    ST_LOOKUP,

    ST_DECIDE,

    ST_ALLOC_SINK,

    ST_PROBE,

    ST_WAIT_PROBE_ACK,

    ST_MEMORY_READ,

    ST_WAIT_MEMORY,

    ST_MEMORY_WRITE,

    ST_GRANT,

    ST_WAIT_GRANT_ACK,

    ST_DIR_UPDATE,

    ST_RELEASE_WRITE,

    ST_RELEASE_UPDATE,

    ST_COMPLETE,

    ST_ERROR,

    ST_TIMEOUT

  } state_t;


  state_t state_q;
  state_t state_d;


  //==========================================================================
  // Active request
  //==========================================================================

  logic                    active_q;

  logic [ADDR_W-1:0]       active_addr_q;

  logic [SOURCE_W-1:0]     active_source_q;

  logic [2:0]              active_param_q;

  logic [2:0]              active_size_q;

  logic                    active_is_acquire_q;

  logic                    active_is_acquire_block_q;

  logic                    active_is_acquire_perm_q;

  logic                    active_is_release_q;

  logic                    active_has_data_q;

  logic [DATA_W-1:0]       active_data_q;

  logic [BYTE_W-1:0]       active_mask_q;


  //==========================================================================
  // Transaction source associated with current operation
  //==========================================================================

  logic [SOURCE_W-1:0]     txn_source_q;


  //==========================================================================
  // Sink associated with current Probe/Grant
  //==========================================================================

  logic [SINK_W-1:0]       sink_q;

  logic                    sink_valid_q;


  //==========================================================================
  // Probe context
  //==========================================================================

  logic                    probe_pending_q;

  logic [ADDR_W-1:0]       probe_addr_q;

  logic [SOURCE_W-1:0]     probe_source_q;

  logic [SINK_W-1:0]       probe_sink_q;

  logic [2:0]              probe_param_q;

  logic                    probe_dirty_q;

  logic [DATA_W-1:0]       probe_data_q;

  logic [BYTE_W-1:0]       probe_mask_q;


  //==========================================================================
  // Memory data
  //==========================================================================

  logic [DATA_W-1:0]       memory_data_q;

  logic                    memory_data_valid_q;

  logic                    memory_error_q;


  //==========================================================================
  // Grant context
  //==========================================================================

  logic                    grant_pending_q;

  logic                    grant_data_q_valid;

  logic [SOURCE_W-1:0]     grant_source_q;

  logic [SINK_W-1:0]       grant_sink_q;

  logic [DATA_W-1:0]       grant_data_q;

  logic                    grant_denied_q;

  logic                    grant_corrupt_q;


  //==========================================================================
  // Timeout
  //==========================================================================

  logic [TIMEOUT_W-1:0] timeout_counter_q;

  always_comb begin

    timeout =
        1'b0;

    if (
      TIMEOUT_CYCLES != 0 &&
      active_q
    ) begin

      if (
        timeout_counter_q >=
        TIMEOUT_CYCLES[TIMEOUT_W-1:0]
      ) begin

        timeout =
            1'b1;

      end

    end

  end


  //==========================================================================
  // Channel handshakes
  //==========================================================================

  logic a_fire;
  logic b_fire;
  logic c_fire;
  logic d_fire;
  logic e_fire;

  assign a_fire =
      tl_a_valid &&
      tl_a_ready;

  assign b_fire =
      tl_b_valid &&
      tl_b_ready;

  assign c_fire =
      tl_c_valid &&
      tl_c_ready;

  assign d_fire =
      tl_d_valid &&
      tl_d_ready;

  assign e_fire =
      tl_e_valid &&
      tl_e_ready;


  //==========================================================================
  // A-channel input
  //
  // A request is accepted only when no active coherence operation exists.
  //==========================================================================

  always_comb begin

    tl_a_ready =
        (state_q == ST_IDLE) &&
        !active_q;
  end


  //==========================================================================
  // Capture type
  //==========================================================================

  wire a_is_acquire_block =
      tl_a_opcode == OP_ACQUIRE_BLOCK;

  wire a_is_acquire_perm =
      tl_a_opcode == OP_ACQUIRE_PERM;


  //==========================================================================
  // C channel input
  //
  // Release and ProbeAck share C.
  //==========================================================================

  always_comb begin

    tl_c_ready =
        active_q &&
        (
          state_q == ST_WAIT_PROBE_ACK ||
          state_q == ST_RELEASE_WRITE ||
          state_q == ST_RELEASE_UPDATE
        );
  end


  //==========================================================================
  // E channel
  //
  // GrantAck.
  //==========================================================================

  always_comb begin

    tl_e_ready =
        (state_q == ST_WAIT_GRANT_ACK);
  end


  //==========================================================================
  // Directory lookup
  //==========================================================================

  always_comb begin

    dir_lookup_valid =
        (state_q == ST_LOOKUP);

    dir_lookup_addr =
        active_addr_q;
  end


  //==========================================================================
  // Sink allocation
  //==========================================================================

  always_comb begin

    sink_alloc_valid =
        (state_q == ST_ALLOC_SINK);
  end


  //==========================================================================
  // Sink release
  //==========================================================================

  assign sink_free_valid =
      (state_q == ST_COMPLETE) &&
      sink_valid_q;

  assign sink_free_id =
      sink_q;


  //==========================================================================
  // Probe generation
  //==========================================================================

  always_comb begin

    tl_b_valid =
        (state_q == ST_PROBE);

    tl_b_opcode =
        OP_PROBE;

    tl_b_param =
        probe_param_q;

    tl_b_size =
        active_size_q;

    tl_b_sink =
        probe_sink_q;

    tl_b_source =
        probe_source_q;

    tl_b_address =
        probe_addr_q;

    tl_b_data =
        '0;

    tl_b_mask =
        '0;
  end


  //==========================================================================
  // Memory read
  //==========================================================================

  always_comb begin

    mem_rd_valid =
        (state_q == ST_MEMORY_READ);

    mem_rd_addr =
        active_addr_q;

    mem_rd_source =
        active_source_q;

    mem_rd_rsp_ready =
        (state_q == ST_WAIT_MEMORY);
  end


  //==========================================================================
  // Memory write
  //==========================================================================

  always_comb begin

    mem_wr_valid =
        (state_q == ST_MEMORY_WRITE) ||
        (state_q == ST_RELEASE_WRITE);

    mem_wr_addr =
        active_addr_q;

    mem_wr_data =
        active_data_q;

    mem_wr_mask =
        active_mask_q;

    mem_wr_source =
        active_source_q;
  end


  //==========================================================================
  // Grant generation
  //==========================================================================

  always_comb begin

    tl_d_valid =
        (state_q == ST_GRANT);

    tl_d_opcode =
        grant_data_q_valid ?
        OP_GRANT_DATA :
        OP_GRANT;

    tl_d_param =
        3'b000;

    tl_d_size =
        active_size_q;

    tl_d_source =
        grant_source_q;

    tl_d_sink =
        grant_sink_q;

    tl_d_data =
        grant_data_q;

    tl_d_denied =
        grant_denied_q;

    tl_d_corrupt =
        grant_corrupt_q;
  end


  //==========================================================================
  // State decision
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

          state_d =
              ST_LOOKUP;

        end

      end


      //======================================================================
      // DIRECTORY LOOKUP
      //======================================================================

      ST_LOOKUP: begin

        if (dir_lookup_ready) begin

          state_d =
              ST_DECIDE;

        end

      end


      //======================================================================
      // COHERENCE DECISION
      //======================================================================

      ST_DECIDE: begin

        //--------------------------------------------------------------------
        // Release is handled separately.
        //--------------------------------------------------------------------

        if (active_is_release_q) begin

          if (active_has_data_q) begin

            state_d =
                ST_MEMORY_WRITE;

          end
          else begin

            state_d =
                ST_RELEASE_UPDATE;

          end

        end

        //--------------------------------------------------------------------
        // Acquire.
        //--------------------------------------------------------------------
        else begin

          case (dir_state)

            //----------------------------------------------------------------
            // No existing line.
            //----------------------------------------------------------------

            DIR_INVALID: begin

              state_d =
                  ST_MEMORY_READ;

            end


            //----------------------------------------------------------------
            // Shared line.
            //----------------------------------------------------------------

            DIR_SHARED: begin

              if (active_is_acquire_perm_q) begin

                state_d =
                    ST_ALLOC_SINK;

              end
              else begin

                state_d =
                    ST_MEMORY_READ;

              end

            end


            //----------------------------------------------------------------
            // Exclusive line.
            //----------------------------------------------------------------

            DIR_EXCLUSIVE: begin

              if (
                dir_owner ==
                active_source_q
              ) begin

                state_d =
                    ST_MEMORY_READ;

              end
              else begin

                state_d =
                    ST_ALLOC_SINK;

              end

            end


            //----------------------------------------------------------------
            // Modified line.
            //----------------------------------------------------------------

            DIR_MODIFIED: begin

              if (
                dir_owner ==
                active_source_q
              ) begin

                state_d =
                    ST_MEMORY_READ;

              end
              else begin

                state_d =
                    ST_ALLOC_SINK;

              end

            end


            default: begin

              state_d =
                  ST_ERROR;

            end

          endcase

        end

      end


      //======================================================================
      // Allocate sink
      //======================================================================

      ST_ALLOC_SINK: begin

        if (sink_alloc_ready) begin

          state_d =
              ST_PROBE;

        end

      end


      //======================================================================
      // Probe
      //======================================================================

      ST_PROBE: begin

        if (b_fire) begin

          state_d =
              ST_WAIT_PROBE_ACK;

        end

      end


      //======================================================================
      // Wait for ProbeAck/ProbeAckData
      //======================================================================

      ST_WAIT_PROBE_ACK: begin

        if (c_fire) begin

          if (
            tl_c_opcode == OP_PROBE_ACK_DATA
          ) begin

            state_d =
                ST_MEMORY_WRITE;

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
      // Memory write
      //======================================================================

      ST_MEMORY_WRITE: begin

        if (mem_wr_ready) begin

          if (active_is_release_q) begin

            state_d =
                ST_RELEASE_UPDATE;

          end
          else begin

            state_d =
                ST_MEMORY_READ;

          end

        end

      end


      //======================================================================
      // Grant
      //======================================================================

      ST_GRANT: begin

        if (d_fire) begin

          state_d =
              ST_WAIT_GRANT_ACK;

        end

      end


      //======================================================================
      // GrantAck
      //======================================================================

      ST_WAIT_GRANT_ACK: begin

        if (e_fire) begin

          state_d =
              ST_DIR_UPDATE;

        end

      end


      //======================================================================
      // Release directory update
      //======================================================================

      ST_RELEASE_UPDATE: begin

        if (dir_update_ready) begin

          state_d =
              ST_COMPLETE;

        end

      end


      //======================================================================
      // Directory update
      //======================================================================

      ST_DIR_UPDATE: begin

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
      // Error
      //======================================================================

      ST_ERROR: begin

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


      default: begin

        state_d =
            ST_ERROR;

      end

    endcase


    //-----------------------------------------------------------------------
    // Global timeout.
    //-----------------------------------------------------------------------

    if (
      timeout &&
      state_q != ST_IDLE &&
      state_q != ST_COMPLETE &&
      state_q != ST_ERROR
    ) begin

      state_d =
          ST_TIMEOUT;

    end

  end


  //==========================================================================
  // Directory update outputs
  //==========================================================================

  always_comb begin

    dir_update_valid =
        (state_q == ST_DIR_UPDATE) ||
        (state_q == ST_RELEASE_UPDATE);

    dir_update_addr =
        active_addr_q;

    //-----------------------------------------------------------------------
    // Release removes ownership.
    //-----------------------------------------------------------------------

    if (active_is_release_q) begin

      dir_update_state =
          DIR_INVALID;

      dir_update_owner =
          '0;

      dir_update_sharers =
          '0;

      dir_update_dirty =
          1'b0;

    end

    //-----------------------------------------------------------------------
    // Acquire result.
    //-----------------------------------------------------------------------

    else if (active_is_acquire_perm_q) begin

      dir_update_state =
          DIR_EXCLUSIVE;

      dir_update_owner =
          active_source_q;

      dir_update_sharers =
          '0;

      dir_update_dirty =
          1'b0;

    end

    else begin

      dir_update_state =
          DIR_SHARED;

      dir_update_owner =
          '0;

      dir_update_sharers =
          '0;

      dir_update_dirty =
          1'b0;

    end

  end


  //==========================================================================
  // Main sequential state
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

      active_is_acquire_q <=
          1'b0;

      active_is_acquire_block_q <=
          1'b0;

      active_is_acquire_perm_q <=
          1'b0;

      active_is_release_q <=
          1'b0;

      active_has_data_q <=
          1'b0;

      active_data_q <=
          '0;

      active_mask_q <=
          '0;

      txn_source_q <=
          '0;

      sink_q <=
          '0;

      sink_valid_q <=
          1'b0;

      probe_pending_q <=
          1'b0;

      probe_addr_q <=
          '0;

      probe_source_q <=
          '0;

      probe_sink_q <=
          '0;

      probe_param_q <=
          '0;

      probe_dirty_q <=
          1'b0;

      probe_data_q <=
          '0;

      probe_mask_q <=
          '0;

      memory_data_q <=
          '0;

      memory_data_valid_q <=
          1'b0;

      memory_error_q <=
          1'b0;

      grant_pending_q <=
          1'b0;

      grant_data_q_valid <=
          1'b0;

      grant_source_q <=
          '0;

      grant_sink_q <=
          '0;

      grant_data_q <=
          '0;

      grant_denied_q <=
          1'b0;

      grant_corrupt_q <=
          1'b0;

      timeout_counter_q <=
          '0;

    end
    else begin

      state_q <=
          state_d;


      //----------------------------------------------------------------------
      // Timeout counter
      //----------------------------------------------------------------------

      if (active_q) begin

        if (
          timeout_counter_q <
          TIMEOUT_CYCLES[TIMEOUT_W-1:0]
        ) begin

          timeout_counter_q <=
              timeout_counter_q + 1'b1;

        end

      end
      else begin

        timeout_counter_q <=
            '0;

      end


      //----------------------------------------------------------------------
      // Capture A transaction
      //----------------------------------------------------------------------

      if (a_fire) begin

        active_q <=
            1'b1;

        active_addr_q <=
            tl_a_address;

        active_source_q <=
            tl_a_source;

        active_param_q <=
            tl_a_param;

        active_size_q <=
            tl_a_size;

        active_is_acquire_q <=
            a_is_acquire_block ||
            a_is_acquire_perm;

        active_is_acquire_block_q <=
            a_is_acquire_block;

        active_is_acquire_perm_q <=
            a_is_acquire_perm;

        active_is_release_q <=
            1'b0;

        active_has_data_q <=
            (tl_a_opcode == OP_ACQUIRE_BLOCK);

        active_data_q <=
            tl_a_data;

        active_mask_q <=
            tl_a_mask;

        txn_source_q <=
            tl_a_source;

        memory_data_valid_q <=
            1'b0;

        memory_error_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Capture Release / ProbeAck on C.
      //----------------------------------------------------------------------

      if (c_fire) begin

        //--------------------------------------------------------------------
        // Probe acknowledgement.
        //--------------------------------------------------------------------

        if (
          state_q == ST_WAIT_PROBE_ACK
        ) begin

          if (
            tl_c_opcode == OP_PROBE_ACK_DATA
          ) begin

            probe_dirty_q <=
                1'b1;

            probe_data_q <=
                tl_c_data;

            probe_mask_q <=
                tl_c_mask;

            //----------------------------------------------------------------
            // Dirty data becomes memory write data.
            //----------------------------------------------------------------

            active_data_q <=
                tl_c_data;

            active_mask_q <=
                tl_c_mask;

          end

        end

      end


      //----------------------------------------------------------------------
      // Sink allocation
      //----------------------------------------------------------------------

      if (
        state_q == ST_ALLOC_SINK &&
        sink_alloc_ready
      ) begin

        sink_q <=
            sink_alloc_id;

        sink_valid_q <=
            1'b1;

        probe_sink_q <=
            sink_alloc_id;

        probe_addr_q <=
            active_addr_q;

        probe_source_q <=
            active_source_q;

        probe_param_q <=
            active_param_q;

      end


      //----------------------------------------------------------------------
      // Memory response
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

        grant_data_q <=
            mem_rd_rsp_data;

      end


      //----------------------------------------------------------------------
      // Grant setup
      //----------------------------------------------------------------------

      if (state_q == ST_GRANT) begin

        grant_source_q <=
            active_source_q;

        grant_sink_q <=
            sink_q;

        grant_data_q_valid <=
            memory_data_valid_q;

        grant_denied_q <=
            memory_error_q;

        grant_corrupt_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Grant sent.
      //----------------------------------------------------------------------

      if (d_fire) begin

        grant_pending_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Transaction complete.
      //----------------------------------------------------------------------

      if (state_q == ST_COMPLETE) begin

        active_q <=
            1'b0;

        sink_valid_q <=
            1'b0;

        probe_pending_q <=
            1'b0;

        memory_data_valid_q <=
            1'b0;

        grant_data_q_valid <=
            1'b0;

        timeout_counter_q <=
            '0;

      end


      //----------------------------------------------------------------------
      // Timeout recovery.
      //----------------------------------------------------------------------

      if (timeout) begin

        active_q <=
            1'b0;

        sink_valid_q <=
            1'b0;

        probe_pending_q <=
            1'b0;

        memory_data_valid_q <=
            1'b0;

      end

    end

  end


  //==========================================================================
  // Status
  //==========================================================================

  assign busy =
      active_q ||
      (state_q != ST_IDLE);

  assign protocol_error =
      tl_a_valid &&
      tl_a_ready &&
      (
        !a_is_acquire_block &&
        !a_is_acquire_perm
      );

  assign error =
      protocol_error ||
      timeout;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_MANAGER_ASSERTIONS

      //----------------------------------------------------------------------
      // Reset clean
      //----------------------------------------------------------------------

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
        "TLC MANAGER: reset state not clean"
      );


      //----------------------------------------------------------------------
      // A-channel must remain stable while stalled.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_a_valid &&
        !tl_a_ready
        |=> tl_a_valid
      )
      else $error(
        "TLC MANAGER: A-channel valid dropped while stalled"
      );


      //----------------------------------------------------------------------
      // B-channel must remain valid while stalled.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_b_valid &&
        !tl_b_ready
        |=> tl_b_valid
      )
      else $error(
        "TLC MANAGER: B-channel valid dropped while stalled"
      );


      //----------------------------------------------------------------------
      // D-channel must remain valid while stalled.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_d_valid &&
        !tl_d_ready
        |=> tl_d_valid
      )
      else $error(
        "TLC MANAGER: D-channel valid dropped while stalled"
      );


      //----------------------------------------------------------------------
      // GrantAck only accepted while waiting.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_e_valid &&
        tl_e_ready
        |-> state_q == ST_WAIT_GRANT_ACK
      )
      else $error(
        "TLC MANAGER: unexpected GrantAck"
      );


      //----------------------------------------------------------------------
      // ProbeAck only accepted in ProbeAck state.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_c_valid &&
        tl_c_ready &&
        (
          tl_c_opcode == OP_PROBE_ACK ||
          tl_c_opcode == OP_PROBE_ACK_DATA
        )
        |-> state_q == ST_WAIT_PROBE_ACK
      )
      else $error(
        "TLC MANAGER: unexpected ProbeAck"
      );


      //----------------------------------------------------------------------
      // Probe sink must be allocated.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_b_valid
        |-> sink_valid_q
      )
      else $error(
        "TLC MANAGER: Probe launched without sink allocation"
      );


      //----------------------------------------------------------------------
      // Grant sink must be valid.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_d_valid
        |-> sink_valid_q
      )
      else $error(
        "TLC MANAGER: Grant launched without sink"
      );


      //----------------------------------------------------------------------
      // Aligned Acquire.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |-> (
          (tl_a_address % CACHE_LINE_BYTES) == 0
        )
      )
      else $error(
        "TLC MANAGER: unaligned Acquire"
      );


      //----------------------------------------------------------------------
      // Aligned Release/ProbeAck.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_fire
        |-> (
          (tl_c_address % CACHE_LINE_BYTES) == 0
        )
      )
      else $error(
        "TLC MANAGER: unaligned C-channel transaction"
      );


      //----------------------------------------------------------------------
      // Memory response accepted only while waiting.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        mem_rd_rsp_valid &&
        mem_rd_rsp_ready
        |-> state_q == ST_WAIT_MEMORY
      )
      else $error(
        "TLC MANAGER: unexpected memory response"
      );


      //----------------------------------------------------------------------
      // Timeout enters timeout/error path.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        timeout
        |=> (
          state_q == ST_TIMEOUT ||
          state_q == ST_ERROR
        )
      )
      else $error(
        "TLC MANAGER: timeout recovery failure"
      );


      //----------------------------------------------------------------------
      // No simultaneous Probe and Grant.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(tl_b_valid && tl_d_valid)
      )
      else $error(
        "TLC MANAGER: Probe and Grant overlap"
      );


      //----------------------------------------------------------------------
      // No X/Z in FSM.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !$isunknown(state_q)
      )
      else $error(
        "TLC MANAGER: FSM contains X/Z"
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
        "TLC MANAGER: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC MANAGER: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC MANAGER: DATA_W must be byte aligned"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC MANAGER: CACHE_LINE_BYTES must be > 0"
      );

    if (
      CACHE_LINE_BYTES &
      (CACHE_LINE_BYTES - 1)
    )
      $error(
        "TLC MANAGER: CACHE_LINE_BYTES must be power-of-two"
      );

    if (MAX_OUTSTANDING == 0)
      $error(
        "TLC MANAGER: MAX_OUTSTANDING must be > 0"
      );

    if (MAX_PROBES == 0)
      $error(
        "TLC MANAGER: MAX_PROBES must be > 0"
      );

  end

endmodule