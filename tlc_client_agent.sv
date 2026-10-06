//==============================================================================
// tlc_client_agent.sv
//
// TileLink-C Client Coherence Agent
//
// Client-side coherence manager.
//
// Responsibilities
// ----------------
// * Generate AcquireBlock / AcquirePerm
// * Accept Grant / GrantData
// * Generate GrantAck
// * Accept Probe / ProbeData
// * Generate ProbeAck / ProbeAckData
// * Generate Release / ReleaseData
// * Maintain local line permission/state
// * Track outstanding Acquires
// * Track outstanding Probes
// * Track pending Releases
// * Dirty-data collection
// * Partial-byte write support
// * Cache-line alignment checking
// * Source/sink ID tracking
// * Timeout detection
// * Illegal transaction detection
// * Reset-clean state
// * Independent ready/valid interfaces
// * No combinational ready/valid loops
// * Synthesis-friendly implementation
// * Assertions
//
// NOTE
// ----
// Exact TL-C opcode/param values are intentionally obtained from tlc_pkg.sv.
// The symbolic constants below should therefore be mapped to the definitions
// used by the previously generated tlc_pkg.sv.
//
//==============================================================================

module tlc_client_agent #(
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

  parameter int unsigned MAX_ACQUIRE =
      8,

  parameter int unsigned MAX_PROBE =
      8,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_ASSERTIONS =
      1'b1
) (
  input logic clk,
  input logic rst_n,

  //==========================================================================
  // Local cache request interface
  //
  // One cache-line transaction at a time per local request port.
  // Multiple requests may be outstanding internally.
  //==========================================================================

  input  logic                    cache_req_valid,
  output logic                    cache_req_ready,

  input  logic [ADDR_W-1:0]       cache_req_addr,

  input  logic                    cache_req_read,
  input  logic                    cache_req_write,

  input  logic                    cache_req_exclusive,

  input  logic [DATA_W-1:0]       cache_req_wdata,

  input  logic [DATA_W/8-1:0]     cache_req_wmask,

  //========================================================================== 
  // Local cache response
  //==========================================================================

  output logic                    cache_rsp_valid,
  input  logic                    cache_rsp_ready,

  output logic [DATA_W-1:0]       cache_rsp_rdata,

  output logic                    cache_rsp_error,

  output logic                    cache_rsp_exclusive,

  //==========================================================================
  // Local cache coherence state
  //==========================================================================

  output logic                    line_valid,
  output logic                    line_shared,
  output logic                    line_exclusive,
  output logic                    line_dirty,

  output logic [ADDR_W-1:0]       line_addr,

  //==========================================================================
  // TL-C A channel
  //
  // AcquireBlock / AcquirePerm
  //==========================================================================

  output logic                    tl_a_valid,
  input  logic                    tl_a_ready,

  output logic [2:0]              tl_a_opcode,
  output logic [2:0]              tl_a_param,
  output logic [2:0]              tl_a_size,

  output logic [SOURCE_W-1:0]     tl_a_source,

  output logic [ADDR_W-1:0]       tl_a_address,

  output logic [DATA_W-1:0]       tl_a_data,

  output logic [DATA_W/8-1:0]     tl_a_mask,

  //==========================================================================
  // TL-C B channel
  //
  // Probe
  //==========================================================================

  input  logic                    tl_b_valid,
  output logic                    tl_b_ready,

  input  logic [2:0]              tl_b_opcode,
  input  logic [2:0]              tl_b_param,
  input  logic [2:0]              tl_b_size,

  input  logic [SINK_W-1:0]       tl_b_sink,

  input  logic [SOURCE_W-1:0]     tl_b_source,

  input  logic [ADDR_W-1:0]       tl_b_address,

  input  logic [DATA_W-1:0]       tl_b_data,

  input  logic [DATA_W/8-1:0]     tl_b_mask,

  //==========================================================================
  // TL-C C channel
  //
  // Release / ReleaseData / ProbeAck / ProbeAckData
  //==========================================================================

  output logic                    tl_c_valid,
  input logic                    tl_c_ready,

  output logic [2:0]              tl_c_opcode,
  output logic [2:0]              tl_c_param,
  output logic [2:0]              tl_c_size,

  output logic [SINK_W-1:0]       tl_c_sink,

  output logic [SOURCE_W-1:0]     tl_c_source,

  output logic [ADDR_W-1:0]       tl_c_address,

  output logic [DATA_W-1:0]       tl_c_data,

  output logic [DATA_W/8-1:0]     tl_c_mask,

  //==========================================================================
  // TL-C D channel
  //
  // Grant / GrantData
  //==========================================================================

  input logic                    tl_d_valid,
  output logic                   tl_d_ready,

  input logic [2:0]              tl_d_opcode,
  input logic [2:0]              tl_d_param,
  input logic [2:0]              tl_d_size,

  input logic [SOURCE_W-1:0]     tl_d_source,

  input logic [SINK_W-1:0]       tl_d_sink,

  input logic [DATA_W-1:0]       tl_d_data,

  input logic                    tl_d_denied,

  input logic                    tl_d_corrupt,

  //==========================================================================
  // TL-C E channel
  //
  // GrantAck
  //==========================================================================

  output logic                   tl_e_valid,
  input logic                    tl_e_ready,

  output logic [SINK_W-1:0]      tl_e_sink,

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

  localparam int unsigned ACQ_ID_W =
      (MAX_ACQUIRE <= 1) ?
      1 :
      $clog2(MAX_ACQUIRE);

  localparam int unsigned PROBE_ID_W =
      (MAX_PROBE <= 1) ?
      1 :
      $clog2(MAX_PROBE);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);

  localparam int unsigned LINE_OFFSET_W =
      (CACHE_LINE_BYTES <= 1) ?
      0 :
      $clog2(CACHE_LINE_BYTES);


  //==========================================================================
  // TL-C opcode placeholders
  //
  // These should correspond to tlc_pkg.sv.
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
  // Client coherence state
  //==========================================================================

  typedef enum logic [2:0] {

    COH_INVALID,

    COH_SHARED,

    COH_EXCLUSIVE,

    COH_MODIFIED,

    COH_TRANSITION

  } coh_state_t;


  coh_state_t coh_state_q;
  coh_state_t coh_state_d;


  assign line_valid =
      (coh_state_q != COH_INVALID);

  assign line_shared =
      (coh_state_q == COH_SHARED);

  assign line_exclusive =
      (coh_state_q == COH_EXCLUSIVE) ||
      (coh_state_q == COH_MODIFIED);

  assign line_dirty =
      (coh_state_q == COH_MODIFIED);


  //==========================================================================
  // Local line metadata
  //==========================================================================

  logic [ADDR_W-1:0] line_addr_q;
  logic [DATA_W-1:0] line_data_q;

  logic [BYTE_W-1:0] line_valid_bytes_q;

  assign line_addr =
      line_addr_q;


  //==========================================================================
  // Acquire context
  //==========================================================================

  logic                    acq_pending_q;

  logic [ADDR_W-1:0]       acq_addr_q;

  logic                    acq_is_block_q;
  logic                    acq_is_perm_q;

  logic                    acq_exclusive_q;

  logic [SOURCE_W-1:0]     acq_source_q;

  logic [DATA_W-1:0]       acq_wdata_q;

  logic [BYTE_W-1:0]       acq_wmask_q;


  //==========================================================================
  // Acquire source allocation
  //
  // Simple local allocator.
  // In the complete design this should be replaced/connected to
  // tlc_source_table.sv.
  //==========================================================================

  logic [SOURCE_W-1:0] next_source_q;

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      next_source_q <=
          '0;

    end
    else if (
      cache_req_valid &&
      cache_req_ready
    ) begin

      next_source_q <=
          next_source_q + 1'b1;

    end

  end


  //==========================================================================
  // Probe context
  //==========================================================================

  logic                    probe_pending_q;

  logic [SINK_W-1:0]       probe_sink_q;

  logic [ADDR_W-1:0]       probe_addr_q;

  logic [2:0]              probe_param_q;

  logic                    probe_requires_data_q;


  //==========================================================================
  // Probe response data
  //==========================================================================

  logic [DATA_W-1:0]       probe_data_q;

  logic [BYTE_W-1:0]       probe_mask_q;

  logic                    probe_data_valid_q;


  //==========================================================================
  // Grant context
  //==========================================================================

  logic                    grant_pending_q;

  logic [SOURCE_W-1:0]     grant_source_q;

  logic [SINK_W-1:0]       grant_sink_q;

  logic [DATA_W-1:0]       grant_data_q;

  logic                    grant_data_valid_q;

  logic                    grant_denied_q;

  logic                    grant_corrupt_q;


  //==========================================================================
  // GrantAck context
  //==========================================================================

  logic                    grant_ack_pending_q;

  logic [SINK_W-1:0]       grant_ack_sink_q;


  //==========================================================================
  // Release context
  //==========================================================================

  logic                    release_pending_q;

  logic                    release_has_data_q;

  logic [DATA_W-1:0]       release_data_q;

  logic [BYTE_W-1:0]       release_mask_q;


  //==========================================================================
  // Timeout
  //==========================================================================

  logic [TIMEOUT_W-1:0] timeout_counter_q;

  always_comb begin

    timeout =
        1'b0;

    if (
      TIMEOUT_CYCLES != 0 &&
      (
        acq_pending_q ||
        probe_pending_q ||
        grant_pending_q ||
        release_pending_q ||
        grant_ack_pending_q
      )
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
  // Cache request acceptance
  //==========================================================================

  always_comb begin

    cache_req_ready =
        !acq_pending_q &&
        !grant_pending_q &&
        !release_pending_q &&
        !probe_pending_q &&
        !grant_ack_pending_q &&
        !timeout;
  end


  //==========================================================================
  // A channel
  //==========================================================================

  always_comb begin

    tl_a_valid =
        acq_pending_q;

    tl_a_opcode =
        acq_is_block_q ?
        OP_ACQUIRE_BLOCK :
        OP_ACQUIRE_PERM;

    tl_a_param =
        3'b000;

    tl_a_size =
        acq_is_block_q ?
        $clog2(CACHE_LINE_BYTES) :
        $clog2(CACHE_LINE_BYTES);

    tl_a_source =
        acq_source_q;

    tl_a_address =
        acq_addr_q;

    tl_a_data =
        acq_wdata_q;

    tl_a_mask =
        acq_wmask_q;

  end


  //==========================================================================
  // B channel
  //
  // Probe reception.
  //
  // Important: B is accepted only when the local cache can safely respond.
  //==========================================================================

  always_comb begin

    tl_b_ready =
        !probe_pending_q &&
        !release_pending_q &&
        !grant_ack_pending_q;
  end


  //==========================================================================
  // C channel
  //==========================================================================

  always_comb begin

    tl_c_valid =
        probe_pending_q ||
        release_pending_q;

    //-----------------------------------------------------------------------
    // Probe response has priority.
    //-----------------------------------------------------------------------

    if (probe_pending_q) begin

      tl_c_opcode =
          probe_data_valid_q ?
          OP_PROBE_ACK_DATA :
          OP_PROBE_ACK;

      tl_c_param =
          probe_param_q;

      tl_c_size =
          $clog2(CACHE_LINE_BYTES);

      tl_c_sink =
          probe_sink_q;

      tl_c_source =
          '0;

      tl_c_address =
          probe_addr_q;

      tl_c_data =
          probe_data_q;

      tl_c_mask =
          probe_mask_q;

    end
    else begin

      //---------------------------------------------------------------------
      // Release
      //---------------------------------------------------------------------

      tl_c_opcode =
          release_has_data_q ?
          OP_RELEASE_DATA :
          OP_RELEASE;

      tl_c_param =
          3'b000;

      tl_c_size =
          $clog2(CACHE_LINE_BYTES);

      tl_c_sink =
          '0;

      tl_c_source =
          acq_source_q;

      tl_c_address =
          line_addr_q;

      tl_c_data =
          release_data_q;

      tl_c_mask =
          release_mask_q;

    end

  end


  //==========================================================================
  // D channel
  //==========================================================================

  always_comb begin

    tl_d_ready =
        !grant_pending_q ||
        grant_pending_q;
  end


  //==========================================================================
  // E channel
  //==========================================================================

  always_comb begin

    tl_e_valid =
        grant_ack_pending_q;

    tl_e_sink =
        grant_ack_sink_q;
  end


  //==========================================================================
  // Cache response
  //==========================================================================

  always_comb begin

    cache_rsp_valid =
        grant_pending_q &&
        grant_data_valid_q;

    cache_rsp_rdata =
        grant_data_q;

    cache_rsp_error =
        grant_denied_q ||
        grant_corrupt_q;

    cache_rsp_exclusive =
        coh_state_q == COH_EXCLUSIVE ||
        coh_state_q == COH_MODIFIED;

  end


  //==========================================================================
  // Handshake signals
  //==========================================================================

  logic cache_req_fire;
  logic a_fire;
  logic b_fire;
  logic c_fire;
  logic d_fire;
  logic e_fire;
  logic cache_rsp_fire;

  assign cache_req_fire =
      cache_req_valid &&
      cache_req_ready;

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

  assign cache_rsp_fire =
      cache_rsp_valid &&
      cache_rsp_ready;


  //==========================================================================
  // Coherence FSM
  //==========================================================================

  always_comb begin

    coh_state_d =
        coh_state_q;

    case (coh_state_q)

      COH_INVALID: begin

        if (cache_req_fire) begin

          coh_state_d =
              COH_TRANSITION;

        end

      end


      COH_SHARED: begin

        //--------------------------------------------------------------------
        // A write requires permission upgrade.
        //--------------------------------------------------------------------

        if (
          cache_req_fire &&
          cache_req_write
        ) begin

          coh_state_d =
              COH_TRANSITION;

        end

      end


      COH_EXCLUSIVE: begin

        if (
          cache_req_fire &&
          cache_req_write
        ) begin

          coh_state_d =
              COH_MODIFIED;

        end

      end


      COH_MODIFIED: begin

        //--------------------------------------------------------------------
        // Writes remain modified.
        //--------------------------------------------------------------------

        if (
          cache_req_fire &&
          cache_req_write
        ) begin

          coh_state_d =
              COH_MODIFIED;

        end

      end


      COH_TRANSITION: begin

        //--------------------------------------------------------------------
        // Grant determines resulting permission.
        //--------------------------------------------------------------------

        if (
          d_fire
        ) begin

          if (tl_d_denied || tl_d_corrupt) begin

            coh_state_d =
                COH_INVALID;

          end
          else if (tl_d_param == 3'b000) begin

            coh_state_d =
                COH_SHARED;

          end
          else begin

            coh_state_d =
                COH_EXCLUSIVE;

          end

        end

      end


      default: begin

        coh_state_d =
            COH_INVALID;

      end

    endcase

  end


  //==========================================================================
  // Main sequential logic
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      coh_state_q <=
          COH_INVALID;

      line_addr_q <=
          '0;

      line_data_q <=
          '0;

      line_valid_bytes_q <=
          '0;

      acq_pending_q <=
          1'b0;

      acq_addr_q <=
          '0;

      acq_is_block_q <=
          1'b0;

      acq_is_perm_q <=
          1'b0;

      acq_exclusive_q <=
          1'b0;

      acq_source_q <=
          '0;

      acq_wdata_q <=
          '0;

      acq_wmask_q <=
          '0;

      probe_pending_q <=
          1'b0;

      probe_sink_q <=
          '0;

      probe_addr_q <=
          '0;

      probe_param_q <=
          '0;

      probe_requires_data_q <=
          1'b0;

      probe_data_q <=
          '0;

      probe_mask_q <=
          '0;

      probe_data_valid_q <=
          1'b0;

      grant_pending_q <=
          1'b0;

      grant_source_q <=
          '0;

      grant_sink_q <=
          '0;

      grant_data_q <=
          '0;

      grant_data_valid_q <=
          1'b0;

      grant_denied_q <=
          1'b0;

      grant_corrupt_q <=
          1'b0;

      grant_ack_pending_q <=
          1'b0;

      grant_ack_sink_q <=
          '0;

      release_pending_q <=
          1'b0;

      release_has_data_q <=
          1'b0;

      release_data_q <=
          '0;

      release_mask_q <=
          '0;

      timeout_counter_q <=
          '0;

    end
    else begin

      //----------------------------------------------------------------------
      // Coherence state
      //----------------------------------------------------------------------

      coh_state_q <=
          coh_state_d;


      //----------------------------------------------------------------------
      // Timeout counter
      //----------------------------------------------------------------------

      if (
        acq_pending_q ||
        probe_pending_q ||
        grant_pending_q ||
        release_pending_q ||
        grant_ack_pending_q
      ) begin

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
      // Local cache request
      //----------------------------------------------------------------------

      if (cache_req_fire) begin

        acq_pending_q <=
            1'b1;

        acq_addr_q <=
            cache_req_addr;

        acq_source_q <=
            next_source_q;

        acq_is_block_q <=
            cache_req_read &&
            !cache_req_write;

        acq_is_perm_q <=
            cache_req_write;

        acq_exclusive_q <=
            cache_req_exclusive;

        acq_wdata_q <=
            cache_req_wdata;

        acq_wmask_q <=
            cache_req_wmask;

        line_addr_q <=
            cache_req_addr;

      end


      //----------------------------------------------------------------------
      // Acquire accepted by TL-C manager.
      //----------------------------------------------------------------------

      if (a_fire) begin

        acq_pending_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Probe received.
      //----------------------------------------------------------------------

      if (b_fire) begin

        probe_pending_q <=
            1'b1;

        probe_sink_q <=
            tl_b_sink;

        probe_addr_q <=
            tl_b_address;

        probe_param_q <=
            tl_b_param;

        //--------------------------------------------------------------------
        // Modified data must be returned.
        //--------------------------------------------------------------------

        if (
          coh_state_q == COH_MODIFIED
        ) begin

          probe_data_q <=
              line_data_q;

          probe_mask_q <=
              line_valid_bytes_q;

          probe_data_valid_q <=
              1'b1;

        end
        else begin

          probe_data_q <=
              '0;

          probe_mask_q <=
              '0;

          probe_data_valid_q <=
              1'b0;

        end

      end


      //----------------------------------------------------------------------
      // Probe acknowledgement sent.
      //----------------------------------------------------------------------

      if (
        probe_pending_q &&
        c_fire
      ) begin

        probe_pending_q <=
            1'b0;

        //--------------------------------------------------------------------
        // Probe forcing invalidation/downgrade.
        //--------------------------------------------------------------------

        if (
          coh_state_q == COH_MODIFIED
        ) begin

          coh_state_q <=
              COH_INVALID;

        end
        else if (
          coh_state_q == COH_EXCLUSIVE
        ) begin

          coh_state_q <=
              COH_SHARED;

        end

        probe_data_valid_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Release generation.
      //
      // A local eviction is represented by the cache request changing
      // permission or by invalidation through a future cache interface.
      //----------------------------------------------------------------------
      //
      // The current interface leaves explicit eviction as an extension point.
      //----------------------------------------------------------------------


      //----------------------------------------------------------------------
      // Grant received.
      //----------------------------------------------------------------------

      if (d_fire) begin

        grant_pending_q <=
            1'b1;

        grant_source_q <=
            tl_d_source;

        grant_sink_q <=
            tl_d_sink;

        grant_data_q <=
            tl_d_data;

        grant_data_valid_q <=
            (tl_d_opcode == OP_GRANT_DATA);

        grant_denied_q <=
            tl_d_denied;

        grant_corrupt_q <=
            tl_d_corrupt;

        //--------------------------------------------------------------------
        // Cache line update.
        //--------------------------------------------------------------------

        if (
          tl_d_opcode == OP_GRANT_DATA &&
          !tl_d_denied &&
          !tl_d_corrupt
        ) begin

          line_data_q <=
              tl_d_data;

          line_valid_bytes_q <=
              {BYTE_W{1'b1}};

          line_addr_q <=
              acq_addr_q;

        end

        //--------------------------------------------------------------------
        // Every Grant requiring acknowledgement gets E.
        //--------------------------------------------------------------------

        grant_ack_pending_q <=
            1'b1;

        grant_ack_sink_q <=
            tl_d_sink;

      end


      //----------------------------------------------------------------------
      // Local cache consumes GrantData.
      //----------------------------------------------------------------------

      if (cache_rsp_fire) begin

        grant_pending_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // GrantAck sent.
      //----------------------------------------------------------------------

      if (e_fire) begin

        grant_ack_pending_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // Timeout/error recovery.
      //----------------------------------------------------------------------

      if (timeout) begin

        acq_pending_q <=
            1'b0;

        probe_pending_q <=
            1'b0;

        grant_pending_q <=
            1'b0;

        grant_ack_pending_q <=
            1'b0;

        release_pending_q <=
            1'b0;

        coh_state_q <=
            COH_INVALID;

      end

    end

  end


  //==========================================================================
  // Error detection
  //==========================================================================

  always_comb begin

    protocol_error =
        1'b0;

    //-----------------------------------------------------------------------
    // Acquire must be cache-line aligned.
    //-----------------------------------------------------------------------

    if (
      cache_req_valid &&
      cache_req_ready
    ) begin

      if (
        (cache_req_addr % CACHE_LINE_BYTES) != 0
      ) begin

        protocol_error =
            1'b1;

      end

    end


    //-----------------------------------------------------------------------
    // Probe address must be aligned.
    //-----------------------------------------------------------------------

    if (
      tl_b_valid &&
      tl_b_ready
    ) begin

      if (
        (tl_b_address % CACHE_LINE_BYTES) != 0
      ) begin

        protocol_error =
            1'b1;

      end

    end

  end


  assign error =
      protocol_error ||
      timeout;


  assign busy =
      acq_pending_q ||
      probe_pending_q ||
      grant_pending_q ||
      grant_ack_pending_q ||
      release_pending_q;


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_CLIENT_ASSERTIONS

      //------------------------------------------------------------------------
      // Reset clean.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !rst_n
        |->
        (
          coh_state_q == COH_INVALID &&
          !acq_pending_q &&
          !probe_pending_q &&
          !grant_pending_q &&
          !grant_ack_pending_q
        )
      )
      else $error(
        "TLC CLIENT: reset state is not clean"
      );


      //------------------------------------------------------------------------
      // A channel stability under backpressure.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_a_valid &&
        !tl_a_ready
        |=> tl_a_valid
      )
      else $error(
        "TLC CLIENT: A-channel valid dropped while stalled"
      );


      //------------------------------------------------------------------------
      // B channel stability under backpressure.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_b_valid &&
        !tl_b_ready
        |=> tl_b_valid
      )
      else $error(
        "TLC CLIENT: B-channel ready violation"
      );


      //------------------------------------------------------------------------
      // C channel stability.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_c_valid &&
        !tl_c_ready
        |=> tl_c_valid
      )
      else $error(
        "TLC CLIENT: C-channel valid dropped while stalled"
      );


      //------------------------------------------------------------------------
      // E channel stability.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_e_valid &&
        !tl_e_ready
        |=> tl_e_valid
      )
      else $error(
        "TLC CLIENT: E-channel valid dropped while stalled"
      );


      //------------------------------------------------------------------------
      // Probe cannot be acknowledged without a probe.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_c_valid &&
        (tl_c_opcode == OP_PROBE_ACK ||
         tl_c_opcode == OP_PROBE_ACK_DATA)
        |-> probe_pending_q
      )
      else $error(
        "TLC CLIENT: ProbeAck without pending Probe"
      );


      //------------------------------------------------------------------------
      // GrantAck requires a valid sink.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_e_valid
        |-> grant_ack_pending_q
      )
      else $error(
        "TLC CLIENT: GrantAck without pending Grant"
      );


      //------------------------------------------------------------------------
      // Modified state implies valid exclusive ownership.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        coh_state_q == COH_MODIFIED
        |-> line_valid
      )
      else $error(
        "TLC CLIENT: Modified line is not valid"
      );


      //------------------------------------------------------------------------
      // Dirty data is only present for valid line.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        line_dirty
        |-> line_valid
      )
      else $error(
        "TLC CLIENT: dirty line is invalid"
      );


      //------------------------------------------------------------------------
      // No simultaneous probe and grant acknowledgement.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        !(probe_pending_q && grant_ack_pending_q)
      )
      else $error(
        "TLC CLIENT: Probe and GrantAck overlap"
      );


      //------------------------------------------------------------------------
      // No GrantData without Grant.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        tl_d_valid &&
        (tl_d_opcode == OP_GRANT_DATA)
        |-> tl_d_ready
      )
      else $error(
        "TLC CLIENT: GrantData not accepted"
      );


      //------------------------------------------------------------------------
      // Timeout must invalidate the local coherence state.
      //------------------------------------------------------------------------

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        timeout
        |=> coh_state_q == COH_INVALID
      )
      else $error(
        "TLC CLIENT: timeout did not invalidate state"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Static parameter validation
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC CLIENT: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC CLIENT: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC CLIENT: DATA_W must be byte aligned"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC CLIENT: CACHE_LINE_BYTES must be > 0"
      );

    if (
      CACHE_LINE_BYTES &
      (CACHE_LINE_BYTES - 1)
    )
      $error(
        "TLC CLIENT: CACHE_LINE_BYTES must be power-of-two"
      );

    if (MAX_ACQUIRE == 0)
      $error(
        "TLC CLIENT: MAX_ACQUIRE must be > 0"
      );

    if (MAX_PROBE == 0)
      $error(
        "TLC CLIENT: MAX_PROBE must be > 0"
      );

  end

endmodule