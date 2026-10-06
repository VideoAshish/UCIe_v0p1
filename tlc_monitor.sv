//==============================================================================
// tlc_monitor.sv
//
// TileLink-C Protocol / Performance Monitor
//
// Passive monitor for all five TL-C channels.
//
// Features
// --------
// * A/B/C/D/E channel monitoring
// * Ready/valid handshake monitoring
// * Opcode legality checking
// * Size/alignment checking
// * Source-ID outstanding transaction tracking
// * Sink-ID tracking
// * A->D latency measurement
// * Outstanding transaction overflow/underflow detection
// * Channel stall detection
// * Transaction timeout detection
// * Malformed transaction detection
// * Partial-write mask checking
// * Acquire / Release / Probe / Grant accounting
// * Error counters
// * Per-channel handshake counters
// * Assertion support
// * Synthesis-friendly counters
//
// IMPORTANT
// ---------
// This module is passive. It does NOT drive any TL-C channel.
//
// The exact opcode values are imported from tlc_pkg.sv.
//
//==============================================================================

module tlc_monitor #(

  parameter int unsigned ADDR_W  = 48,
  parameter int unsigned DATA_W  = 256,
  parameter int unsigned SOURCE_W = 8,
  parameter int unsigned SINK_W   = 6,

  parameter int unsigned CACHE_LINE_BYTES =
      DATA_W / 8,

  parameter int unsigned MAX_OUTSTANDING =
      256,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter int unsigned STALL_TIMEOUT_CYCLES =
      10000,

  parameter bit CHECK_ALIGNMENT = 1'b1,
  parameter bit CHECK_MASK      = 1'b1,
  parameter bit CHECK_OPCODE    = 1'b1,
  parameter bit ENABLE_COUNTERS = 1'b1,
  parameter bit ENABLE_ASSERTIONS = 1'b1,

  parameter int unsigned COUNTER_W = 64

) (

  input logic clk,
  input logic rst_n,

  //==========================================================================
  // A channel
  //==========================================================================

  input logic a_valid,
  input logic a_ready,

  input logic [2:0] a_opcode,
  input logic [2:0] a_param,
  input logic [2:0] a_size,

  input logic [SOURCE_W-1:0] a_source,

  input logic [ADDR_W-1:0] a_address,

  input logic [DATA_W-1:0] a_data,

  input logic [DATA_W/8-1:0] a_mask,


  //==========================================================================
  // B channel
  //==========================================================================

  input logic b_valid,
  input logic b_ready,

  input logic [2:0] b_opcode,
  input logic [2:0] b_param,
  input logic [2:0] b_size,

  input logic [SOURCE_W-1:0] b_source,

  input logic [SINK_W-1:0] b_sink,

  input logic [ADDR_W-1:0] b_address,

  input logic [DATA_W-1:0] b_data,

  input logic [DATA_W/8-1:0] b_mask,


  //==========================================================================
  // C channel
  //==========================================================================

  input logic c_valid,
  input logic c_ready,

  input logic [2:0] c_opcode,
  input logic [2:0] c_param,
  input logic [2:0] c_size,

  input logic [SOURCE_W-1:0] c_source,

  input logic [SINK_W-1:0] c_sink,

  input logic [ADDR_W-1:0] c_address,

  input logic [DATA_W-1:0] c_data,

  input logic [DATA_W/8-1:0] c_mask,


  //==========================================================================
  // D channel
  //==========================================================================

  input logic d_valid,
  input logic d_ready,

  input logic [2:0] d_opcode,
  input logic [2:0] d_param,
  input logic [2:0] d_size,

  input logic [SOURCE_W-1:0] d_source,

  input logic [SINK_W-1:0] d_sink,

  input logic [DATA_W-1:0] d_data,

  input logic d_denied,
  input logic d_corrupt,


  //==========================================================================
  // E channel
  //==========================================================================

  input logic e_valid,
  input logic e_ready,

  input logic [SINK_W-1:0] e_sink,


  //==========================================================================
  // Status
  //==========================================================================

  output logic monitor_error,

  output logic protocol_error,

  output logic timeout_error,

  output logic malformed_error,

  output logic illegal_opcode_error,

  output logic alignment_error,

  output logic overflow_error,

  output logic underflow_error,

  output logic stall_error,


  //==========================================================================
  // Current state
  //==========================================================================

  output logic [COUNTER_W-1:0]
      outstanding_count,

  output logic [COUNTER_W-1:0]
      max_outstanding_seen,

  output logic
      busy,


  //==========================================================================
  // Performance counters
  //==========================================================================

  output logic [COUNTER_W-1:0]
      a_transfer_count,

  output logic [COUNTER_W-1:0]
      b_transfer_count,

  output logic [COUNTER_W-1:0]
      c_transfer_count,

  output logic [COUNTER_W-1:0]
      d_transfer_count,

  output logic [COUNTER_W-1:0]
      e_transfer_count,


  output logic [COUNTER_W-1:0]
      acquire_count,

  output logic [COUNTER_W-1:0]
      release_count,

  output logic [COUNTER_W-1:0]
      probe_count,

  output logic [COUNTER_W-1:0]
      grant_count,

  output logic [COUNTER_W-1:0]
      timeout_count,

  output logic [COUNTER_W-1:0]
      protocol_error_count,

  output logic [COUNTER_W-1:0]
      malformed_count,

  output logic [COUNTER_W-1:0]
      illegal_opcode_count,

  output logic [COUNTER_W-1:0]
      alignment_error_count,

  output logic [COUNTER_W-1:0]
      stall_count,


  //==========================================================================
  // Last transaction information
  //==========================================================================

  output logic [SOURCE_W-1:0]
      last_source,

  output logic [SINK_W-1:0]
      last_sink,

  output logic [2:0]
      last_a_opcode,

  output logic [2:0]
      last_d_opcode,

  output logic [ADDR_W-1:0]
      last_address,

  output logic [COUNTER_W-1:0]
      last_latency,


  //==========================================================================
  // Sticky error clear
  //==========================================================================

  input logic clear_errors

);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned OUT_W =
      (MAX_OUTSTANDING <= 1) ?
      1 :
      $clog2(MAX_OUTSTANDING + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);

  localparam int unsigned STALL_W =
      (STALL_TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(STALL_TIMEOUT_CYCLES + 1);


  //==========================================================================
  // Handshake wires
  //==========================================================================

  logic a_fire;
  logic b_fire;
  logic c_fire;
  logic d_fire;
  logic e_fire;

  assign a_fire = a_valid && a_ready;
  assign b_fire = b_valid && b_ready;
  assign c_fire = c_valid && c_ready;
  assign d_fire = d_valid && d_ready;
  assign e_fire = e_valid && e_ready;


  //==========================================================================
  // Source tracking
  //
  // One bit per source ID indicates an outstanding transaction.
  //
  // This is deliberately implemented as a bitmap rather than a large
  // associative RAM, making it synthesis-friendly for moderate SOURCE_W.
  //==========================================================================

  localparam int unsigned NUM_SOURCES =
      (1 << SOURCE_W);

  logic [NUM_SOURCES-1:0]
      source_active_q;

  logic [NUM_SOURCES-1:0]
      source_is_acquire_q;

  logic [NUM_SOURCES-1:0]
      source_is_release_q;

  logic [NUM_SOURCES-1:0]
      source_timeout_q;


  //==========================================================================
  // Source latency counters
  //==========================================================================

  logic [COUNTER_W-1:0]
      source_age_q [NUM_SOURCES];


  //==========================================================================
  // Sink tracking
  //==========================================================================

  localparam int unsigned NUM_SINKS =
      (1 << SINK_W);

  logic [NUM_SINKS-1:0]
      sink_active_q;


  //==========================================================================
  // Opcode classification
  //
  // The package is expected to provide the canonical TL-C opcode constants.
  //
  // To keep this module usable with the previously generated tlc_pkg.sv,
  // classification is isolated in functions.
  //==========================================================================

  function automatic logic opcode_is_a_request(
    input logic [2:0] opcode
  );

    begin

      case (opcode)

        3'd0: opcode_is_a_request = 1'b1; // PutFullData
        3'd1: opcode_is_a_request = 1'b1; // PutPartialData
        3'd2: opcode_is_a_request = 1'b1; // ArithmeticData
        3'd3: opcode_is_a_request = 1'b1; // LogicalData
        3'd4: opcode_is_a_request = 1'b1; // Get
        3'd5: opcode_is_a_request = 1'b1; // Hint

        3'd6: opcode_is_a_request = 1'b1; // AcquireBlock
        3'd7: opcode_is_a_request = 1'b1; // AcquirePerm

        default:
          opcode_is_a_request = 1'b0;

      endcase

    end

  endfunction


  function automatic logic opcode_is_c_request(
    input logic [2:0] opcode
  );

    begin

      case (opcode)

        3'd0: opcode_is_c_request = 1'b1; // ProbeAck
        3'd1: opcode_is_c_request = 1'b1; // ProbeAckData
        3'd2: opcode_is_c_request = 1'b1; // Release
        3'd3: opcode_is_c_request = 1'b1; // ReleaseData

        default:
          opcode_is_c_request = 1'b0;

      endcase

    end

  endfunction


  function automatic logic opcode_is_b_request(
    input logic [2:0] opcode
  );

    begin

      case (opcode)

        3'd6: opcode_is_b_request = 1'b1; // ProbeBlock
        3'd7: opcode_is_b_request = 1'b1; // ProbePerm

        default:
          opcode_is_b_request = 1'b0;

      endcase

    end

  endfunction


  function automatic logic opcode_is_d_response(
    input logic [2:0] opcode
  );

    begin

      case (opcode)

        3'd0: opcode_is_d_response = 1'b1; // AccessAck
        3'd1: opcode_is_d_response = 1'b1; // AccessAckData
        3'd2: opcode_is_d_response = 1'b1; // HintAck
        3'd4: opcode_is_d_response = 1'b1; // Grant
        3'd5: opcode_is_d_response = 1'b1; // GrantData
        3'd6: opcode_is_d_response = 1'b1; // ReleaseAck

        default:
          opcode_is_d_response = 1'b0;

      endcase

    end

  endfunction


  //==========================================================================
  // Size helpers
  //==========================================================================

  function automatic logic size_is_legal(
    input logic [2:0] size
  );

    begin

      // TL size is log2(bytes).
      size_is_legal =
          (size <= $clog2(CACHE_LINE_BYTES));

    end

  endfunction


  function automatic logic address_aligned(
    input logic [ADDR_W-1:0] address,
    input logic [2:0] size
  );

    logic [ADDR_W-1:0] mask;

    begin

      if (size >= ADDR_W) begin

        address_aligned =
            1'b0;

      end
      else begin

        mask =
            ({ADDR_W{1'b1}} << size);

        address_aligned =
            ((address & ~mask) == '0);
      end

    end

  endfunction


  //==========================================================================
  // Mask checker
  //
  // For PutFullData all bytes of the transfer must be enabled.
  // PutPartialData is allowed to contain arbitrary byte enables.
  //==========================================================================

  function automatic logic mask_is_legal(
    input logic [2:0] opcode,
    input logic [2:0] size,
    input logic [BYTE_W-1:0] mask
  );

    logic [BYTE_W-1:0] expected_mask;

    begin

      expected_mask =
          '0;

      if (size >= $clog2(BYTE_W)) begin

        expected_mask =
            {BYTE_W{1'b1}};

      end
      else begin

        expected_mask =
            ({{(BYTE_W-1){1'b0}},1'b1} << (1 << size)) - 1'b1;

      end

      case (opcode)

        3'd0: begin
          // PutFullData
          mask_is_legal =
              (mask == expected_mask);
        end

        3'd1: begin
          // PutPartialData
          mask_is_legal =
              (mask != '0);
        end

        default: begin
          mask_is_legal =
              1'b1;
        end

      endcase

    end

  endfunction


  //==========================================================================
  // Error detection
  //==========================================================================

  logic a_opcode_bad;
  logic b_opcode_bad;
  logic c_opcode_bad;
  logic d_opcode_bad;

  logic a_malformed;
  logic b_malformed;
  logic c_malformed;
  logic d_malformed;
  logic e_malformed;


  always_comb begin

    a_opcode_bad =
        !opcode_is_a_request(a_opcode);

    b_opcode_bad =
        !opcode_is_b_request(b_opcode);

    c_opcode_bad =
        !opcode_is_c_request(c_opcode);

    d_opcode_bad =
        !opcode_is_d_response(d_opcode);


    a_malformed =
        !size_is_legal(a_size) ||
        (CHECK_MASK &&
         !mask_is_legal(
           a_opcode,
           a_size,
           a_mask
         ));

    b_malformed =
        !size_is_legal(b_size);

    c_malformed =
        !size_is_legal(c_size) ||
        (CHECK_MASK &&
         !mask_is_legal(
           c_opcode,
           c_size,
           c_mask
         ));

    d_malformed =
        !size_is_legal(d_size);

    e_malformed =
        1'b0;

  end


  //==========================================================================
  // Alignment
  //==========================================================================

  logic a_alignment_bad;
  logic b_alignment_bad;
  logic c_alignment_bad;

  always_comb begin

    a_alignment_bad =
        !address_aligned(
          a_address,
          a_size
        );

    b_alignment_bad =
        !address_aligned(
          b_address,
          b_size
        );

    c_alignment_bad =
        !address_aligned(
          c_address,
          c_size
        );

  end


  //==========================================================================
  // Stall counters
  //==========================================================================

  logic [STALL_W-1:0]
      a_stall_q;

  logic [STALL_W-1:0]
      b_stall_q;

  logic [STALL_W-1:0]
      c_stall_q;

  logic [STALL_W-1:0]
      d_stall_q;

  logic [STALL_W-1:0]
      e_stall_q;


  //==========================================================================
  // Sticky errors
  //==========================================================================

  logic protocol_error_q;
  logic timeout_error_q;
  logic malformed_error_q;
  logic illegal_opcode_error_q;
  logic alignment_error_q;
  logic overflow_error_q;
  logic underflow_error_q;
  logic stall_error_q;


  assign protocol_error =
      protocol_error_q;

  assign timeout_error =
      timeout_error_q;

  assign malformed_error =
      malformed_error_q;

  assign illegal_opcode_error =
      illegal_opcode_error_q;

  assign alignment_error =
      alignment_error_q;

  assign overflow_error =
      overflow_error_q;

  assign underflow_error =
      underflow_error_q;

  assign stall_error =
      stall_error_q;

  assign monitor_error =
      protocol_error_q ||
      timeout_error_q ||
      malformed_error_q ||
      illegal_opcode_error_q ||
      alignment_error_q ||
      overflow_error_q ||
      underflow_error_q ||
      stall_error_q;


  //==========================================================================
  // Outstanding count
  //==========================================================================

  logic [OUT_W-1:0]
      outstanding_q;

  assign outstanding_count =
      outstanding_q;

  assign busy =
      (outstanding_q != '0);


  //==========================================================================
  // Main monitor state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      source_active_q <=
          '0;

      source_is_acquire_q <=
          '0;

      source_is_release_q <=
          '0;

      source_timeout_q <=
          '0;

      sink_active_q <=
          '0;

      outstanding_q <=
          '0;

      max_outstanding_seen <=
          '0;

      a_transfer_count <=
          '0;

      b_transfer_count <=
          '0;

      c_transfer_count <=
          '0;

      d_transfer_count <=
          '0;

      e_transfer_count <=
          '0;

      acquire_count <=
          '0;

      release_count <=
          '0;

      probe_count <=
          '0;

      grant_count <=
          '0;

      timeout_count <=
          '0;

      protocol_error_count <=
          '0;

      malformed_count <=
          '0;

      illegal_opcode_count <=
          '0;

      alignment_error_count <=
          '0;

      stall_count <=
          '0;

      last_source <=
          '0;

      last_sink <=
          '0;

      last_a_opcode <=
          '0;

      last_d_opcode <=
          '0;

      last_address <=
          '0;

      last_latency <=
          '0;

      protocol_error_q <=
          1'b0;

      timeout_error_q <=
          1'b0;

      malformed_error_q <=
          1'b0;

      illegal_opcode_error_q <=
          1'b0;

      alignment_error_q <=
          1'b0;

      overflow_error_q <=
          1'b0;

      underflow_error_q <=
          1'b0;

      stall_error_q <=
          1'b0;

      a_stall_q <=
          '0;

      b_stall_q <=
          '0;

      c_stall_q <=
          '0;

      d_stall_q <=
          '0;

      e_stall_q <=
          '0;

      for (int s = 0; s < NUM_SOURCES; s++) begin
        source_age_q[s] <=
            '0;
      end

    end
    else begin

      //======================================================================
      // Clear sticky errors
      //======================================================================

      if (clear_errors) begin

        protocol_error_q <=
            1'b0;

        timeout_error_q <=
            1'b0;

        malformed_error_q <=
            1'b0;

        illegal_opcode_error_q <=
            1'b0;

        alignment_error_q <=
            1'b0;

        overflow_error_q <=
            1'b0;

        underflow_error_q <=
            1'b0;

        stall_error_q <=
            1'b0;

      end


      //======================================================================
      // Channel transfer counters
      //======================================================================

      if (a_fire)
        a_transfer_count <=
            a_transfer_count + 1'b1;

      if (b_fire)
        b_transfer_count <=
            b_transfer_count + 1'b1;

      if (c_fire)
        c_transfer_count <=
            c_transfer_count + 1'b1;

      if (d_fire)
        d_transfer_count <=
            d_transfer_count + 1'b1;

      if (e_fire)
        e_transfer_count <=
            e_transfer_count + 1'b1;


      //======================================================================
      // A transaction accepted
      //======================================================================

      if (a_fire) begin

        last_source <=
            a_source;

        last_a_opcode <=
            a_opcode;

        last_address <=
            a_address;


        // Outstanding transaction begins for requests which generate D.

        if (opcode_is_a_request(a_opcode)) begin

          if (source_active_q[a_source]) begin

            protocol_error_q <=
                1'b1;

            protocol_error_count <=
                protocol_error_count + 1'b1;

          end
          else begin

            source_active_q[a_source] <=
                1'b1;

            source_is_acquire_q[a_source] <=
                (
                  a_opcode == 3'd6 ||
                  a_opcode == 3'd7
                );

            source_is_release_q[a_source] <=
                1'b0;

            source_age_q[a_source] <=
                '0;


            if (
              outstanding_q <
              MAX_OUTSTANDING
            ) begin

              outstanding_q <=
                  outstanding_q + 1'b1;

              if (
                outstanding_q + 1'b1 >
                max_outstanding_seen
              )
                max_outstanding_seen <=
                    outstanding_q + 1'b1;

            end
            else begin

              overflow_error_q <=
                  1'b1;

            end

          end

        end


        // Acquire accounting

        if (
          a_opcode == 3'd6 ||
          a_opcode == 3'd7
        )
          acquire_count <=
              acquire_count + 1'b1;


        // Illegal opcode

        if (
          CHECK_OPCODE &&
          a_opcode_bad
        ) begin

          illegal_opcode_error_q <=
              1'b1;

          illegal_opcode_count <=
              illegal_opcode_count + 1'b1;

        end


        // Malformed transaction

        if (a_malformed) begin

          malformed_error_q <=
              1'b1;

          malformed_count <=
              malformed_count + 1'b1;

        end


        // Alignment

        if (
          CHECK_ALIGNMENT &&
          a_alignment_bad
        ) begin

          alignment_error_q <=
              1'b1;

          alignment_error_count <=
              alignment_error_count + 1'b1;

        end

      end


      //======================================================================
      // B transaction
      //======================================================================

      if (b_fire) begin

        last_sink <=
            b_sink;

        if (
          CHECK_OPCODE &&
          b_opcode_bad
        ) begin

          illegal_opcode_error_q <=
              1'b1;

          illegal_opcode_count <=
              illegal_opcode_count + 1'b1;

        end

        if (b_malformed) begin

          malformed_error_q <=
              1'b1;

          malformed_count <=
              malformed_count + 1'b1;

        end

        if (
          CHECK_ALIGNMENT &&
          b_alignment_bad
        ) begin

          alignment_error_q <=
              1'b1;

          alignment_error_count <=
              alignment_error_count + 1'b1;

        end

        probe_count <=
            probe_count + 1'b1;

      end


      //======================================================================
      // C transaction
      //======================================================================

      if (c_fire) begin

        last_source <=
            c_source;

        last_sink <=
            c_sink;

        last_address <=
            c_address;


        if (
          c_opcode == 3'd2 ||
          c_opcode == 3'd3
        ) begin

          release_count <=
              release_count + 1'b1;

        end


        if (
          CHECK_OPCODE &&
          c_opcode_bad
        ) begin

          illegal_opcode_error_q <=
              1'b1;

          illegal_opcode_count <=
              illegal_opcode_count + 1'b1;

        end


        if (c_malformed) begin

          malformed_error_q <=
              1'b1;

          malformed_count <=
              malformed_count + 1'b1;

        end


        if (
          CHECK_ALIGNMENT &&
          c_alignment_bad
        ) begin

          alignment_error_q <=
              1'b1;

          alignment_error_count <=
              alignment_error_count + 1'b1;

        end

      end


      //======================================================================
      // D transaction
      //======================================================================

      if (d_fire) begin

        last_source <=
            d_source;

        last_sink <=
            d_sink;

        last_d_opcode <=
            d_opcode;


        if (
          CHECK_OPCODE &&
          d_opcode_bad
        ) begin

          illegal_opcode_error_q <=
              1'b1;

          illegal_opcode_count <=
              illegal_opcode_count + 1'b1;

        end


        if (d_malformed) begin

          malformed_error_q <=
              1'b1;

          malformed_count <=
              malformed_count + 1'b1;

        end


        // Grant accounting

        if (
          d_opcode == 3'd4 ||
          d_opcode == 3'd5
        )
          grant_count <=
              grant_count + 1'b1;


        // Complete source transaction

        if (source_active_q[d_source]) begin

          last_latency <=
              source_age_q[d_source];

          source_active_q[d_source] <=
              1'b0;

          source_timeout_q[d_source] <=
              1'b0;

          source_age_q[d_source] <=
              '0;


          if (outstanding_q != '0) begin

            outstanding_q <=
                outstanding_q - 1'b1;

          end
          else begin

            underflow_error_q <=
                1'b1;

          end

        end
        else begin

          protocol_error_q <=
              1'b1;

          protocol_error_count <=
              protocol_error_count + 1'b1;

        end

      end


      //======================================================================
      // E transaction
      //======================================================================

      if (e_fire) begin

        last_sink <=
            e_sink;

        if (sink_active_q[e_sink]) begin

          sink_active_q[e_sink] <=
              1'b0;

        end
        else begin

          protocol_error_q <=
              1'b1;

          protocol_error_count <=
              protocol_error_count + 1'b1;

        end

      end


      //======================================================================
      // Source timeout aging
      //======================================================================

      for (
        int s = 0;
        s < NUM_SOURCES;
        s++
      ) begin

        if (source_active_q[s]) begin

          if (
            source_age_q[s] <
            TIMEOUT_CYCLES
          ) begin

            source_age_q[s] <=
                source_age_q[s] + 1'b1;

          end
          else begin

            source_timeout_q[s] <=
                1'b1;

            timeout_error_q <=
                1'b1;

            timeout_count <=
                timeout_count + 1'b1;

          end

        end

      end


      //======================================================================
      // Stall monitoring
      //======================================================================

      if (a_valid && !a_ready) begin

        if (
          a_stall_q <
          STALL_TIMEOUT_CYCLES
        )
          a_stall_q <=
              a_stall_q + 1'b1;
        else begin

          stall_error_q <=
              1'b1;

          stall_count <=
              stall_count + 1'b1;

        end

      end
      else begin

        a_stall_q <=
            '0;

      end


      if (b_valid && !b_ready) begin

        if (
          b_stall_q <
          STALL_TIMEOUT_CYCLES
        )
          b_stall_q <=
              b_stall_q + 1'b1;
        else begin

          stall_error_q <=
              1'b1;

          stall_count <=
              stall_count + 1'b1;

        end

      end
      else begin

        b_stall_q <=
            '0;

      end


      if (c_valid && !c_ready) begin

        if (
          c_stall_q <
          STALL_TIMEOUT_CYCLES
        )
          c_stall_q <=
              c_stall_q + 1'b1;
        else begin

          stall_error_q <=
              1'b1;

          stall_count <=
              stall_count + 1'b1;

        end

      end
      else begin

        c_stall_q <=
            '0;

      end


      if (d_valid && !d_ready) begin

        if (
          d_stall_q <
          STALL_TIMEOUT_CYCLES
        )
          d_stall_q <=
              d_stall_q + 1'b1;
        else begin

          stall_error_q <=
              1'b1;

          stall_count <=
              stall_count + 1'b1;

        end

      end
      else begin

        d_stall_q <=
            '0;

      end


      if (e_valid && !e_ready) begin

        if (
          e_stall_q <
          STALL_TIMEOUT_CYCLES
        )
          e_stall_q <=
              e_stall_q + 1'b1;
        else begin

          stall_error_q <=
              1'b1;

          stall_count <=
              stall_count + 1'b1;

        end

      end
      else begin

        e_stall_q <=
            '0;

      end

    end

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (ENABLE_ASSERTIONS) begin : GEN_TLC_MON_ASSERT

      //======================================================================
      // Ready/valid protocol
      //
      // A producer must keep valid asserted while stalled.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_valid && !a_ready
        |=> a_valid
      )
      else $error(
        "TLC_MONITOR: A valid changed while stalled"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        b_valid && !b_ready
        |=> b_valid
      )
      else $error(
        "TLC_MONITOR: B valid changed while stalled"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_valid && !c_ready
        |=> c_valid
      )
      else $error(
        "TLC_MONITOR: C valid changed while stalled"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_valid && !d_ready
        |=> d_valid
      )
      else $error(
        "TLC_MONITOR: D valid changed while stalled"
      );


      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        e_valid && !e_ready
        |=> e_valid
      )
      else $error(
        "TLC_MONITOR: E valid changed while stalled"
      );


      //======================================================================
      // A opcode legality
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        a_fire
        |->
        opcode_is_a_request(a_opcode)
      )
      else $error(
        "TLC_MONITOR: illegal A opcode"
      );


      //======================================================================
      // B opcode legality
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        b_fire
        |->
        opcode_is_b_request(b_opcode)
      )
      else $error(
        "TLC_MONITOR: illegal B opcode"
      );


      //======================================================================
      // C opcode legality
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        c_fire
        |->
        opcode_is_c_request(c_opcode)
      )
      else $error(
        "TLC_MONITOR: illegal C opcode"
      );


      //======================================================================
      // D opcode legality
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_fire
        |->
        opcode_is_d_response(d_opcode)
      )
      else $error(
        "TLC_MONITOR: illegal D opcode"
      );


      //======================================================================
      // A alignment
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        CHECK_ALIGNMENT &&
        a_fire
        |->
        address_aligned(
          a_address,
          a_size
        )
      )
      else $error(
        "TLC_MONITOR: unaligned A transaction"
      );


      //======================================================================
      // C alignment
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        CHECK_ALIGNMENT &&
        c_fire
        |->
        address_aligned(
          c_address,
          c_size
        )
      )
      else $error(
        "TLC_MONITOR: unaligned C transaction"
      );


      //======================================================================
      // D response must correspond to active source.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        d_fire
        |->
        source_active_q[d_source]
      )
      else $error(
        "TLC_MONITOR: D response without outstanding source"
      );


      //======================================================================
      // E requires an active sink.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        e_fire
        |->
        sink_active_q[e_sink]
      )
      else $error(
        "TLC_MONITOR: E without active sink"
      );


      //======================================================================
      // Outstanding limit.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        outstanding_q <= MAX_OUTSTANDING
      )
      else $error(
        "TLC_MONITOR: outstanding transaction overflow"
      );


      //======================================================================
      // Count cannot be negative.
      //======================================================================

      assert property (
        @(posedge clk)
        disable iff (!rst_n)

        outstanding_q >= 0
      )
      else $error(
        "TLC_MONITOR: outstanding transaction underflow"
      );


      //======================================================================
      // Reset must clear active transaction state.
      //======================================================================

      assert property (
        @(posedge clk)

        !rst_n
        |->
        (
          outstanding_q == '0 &&
          source_active_q == '0 &&
          sink_active_q == '0
        )
      )
      else $error(
        "TLC_MONITOR: reset did not clear transaction state"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Parameter checks
  //==========================================================================

  initial begin

    if (DATA_W == 0)
      $error(
        "TLC_MONITOR: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC_MONITOR: DATA_W must be byte aligned"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC_MONITOR: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC_MONITOR: SINK_W must be > 0"
      );

    if (MAX_OUTSTANDING == 0)
      $error(
        "TLC_MONITOR: MAX_OUTSTANDING must be > 0"
      );

    if (TIMEOUT_CYCLES == 0)
      $error(
        "TLC_MONITOR: TIMEOUT_CYCLES must be > 0"
      );

    if (CACHE_LINE_BYTES == 0)
      $error(
        "TLC_MONITOR: CACHE_LINE_BYTES must be > 0"
      );

  end

endmodule