//==============================================================================
// tlc_error_handler.sv
//
// TileLink-C Error Handler / Fault Containment Unit
//
// Features
// --------
// * Sticky error detection
// * First-error capture
// * Error classification
// * Per-error counters
// * Configurable fatal/non-fatal policy
// * Transaction timeout handling
// * Protocol error handling
// * Illegal opcode handling
// * Malformed transaction handling
// * Alignment error handling
// * Permission error handling
// * Source/sink allocation errors
// * Transaction-table overflow/underflow
// * Probe tracking errors
// * Grant/Release protocol errors
// * Poison/corrupt response detection
// * Protocol quarantine request
// * Optional channel blocking
// * Error syndrome capture
// * Error address/source/sink/opcode capture
// * Software-clearable sticky status
// * Synthesis-friendly implementation
//
// IMPORTANT
// ---------
// This module does not directly modify TL-C channel payloads.
// It generates quarantine/error-control signals for the upper-level
// TL-C controller.
//
//==============================================================================

module tlc_error_handler #(

  parameter int unsigned ADDR_W   = 48,
  parameter int unsigned DATA_W   = 256,
  parameter int unsigned SOURCE_W = 8,
  parameter int unsigned SINK_W   = 6,

  parameter int unsigned COUNTER_W = 32,

  parameter bit FATAL_TIMEOUT       = 1'b1,
  parameter bit FATAL_PROTOCOL      = 1'b1,
  parameter bit FATAL_MALFORMED     = 1'b1,
  parameter bit FATAL_ILLEGAL_OP    = 1'b1,
  parameter bit FATAL_ALIGNMENT     = 1'b0,
  parameter bit FATAL_PERMISSION    = 1'b1,
  parameter bit FATAL_SOURCE        = 1'b1,
  parameter bit FATAL_SINK          = 1'b1,
  parameter bit FATAL_TXN_TABLE    = 1'b1,
  parameter bit FATAL_PROBE        = 1'b1,
  parameter bit FATAL_GRANT        = 1'b1,
  parameter bit FATAL_RELEASE      = 1'b1,
  parameter bit FATAL_CORRUPT      = 1'b0,
  parameter bit FATAL_OVERFLOW     = 1'b1,
  parameter bit FATAL_UNDERFLOW    = 1'b1

) (

  input logic clk,
  input logic rst_n,


  //==========================================================================
  // Error inputs
  //==========================================================================

  input logic error_timeout,

  input logic error_protocol,

  input logic error_malformed,

  input logic error_illegal_opcode,

  input logic error_alignment,

  input logic error_permission,

  input logic error_source,

  input logic error_sink,

  input logic error_txn_overflow,

  input logic error_txn_underflow,

  input logic error_probe,

  input logic error_grant,

  input logic error_release,

  input logic error_corrupt,

  input logic error_overflow,

  input logic error_underflow,


  //==========================================================================
  // Additional subsystem errors
  //==========================================================================

  input logic source_table_error,

  input logic sink_table_error,

  input logic txn_table_error,

  input logic probe_tracker_error,

  input logic directory_error,

  input logic coherence_error,

  input logic arbitration_error,

  input logic router_error,

  input logic crossbar_error,


  //==========================================================================
  // Transaction context
  //==========================================================================

  input logic [ADDR_W-1:0]
      error_address,

  input logic [SOURCE_W-1:0]
      error_source,

  input logic [SINK_W-1:0]
      error_sink,

  input logic [2:0]
      error_opcode,

  input logic [2:0]
      error_param,

  input logic [2:0]
      error_size,


  //==========================================================================
  // Optional poisoned/corrupt transaction information
  //==========================================================================

  input logic poison_detected,

  input logic denied_response,


  //==========================================================================
  // Control
  //==========================================================================

  input logic clear_errors,

  input logic clear_counters,

  input logic enable_error_handler,


  //==========================================================================
  // Configuration
  //
  // Runtime fatal policy overrides.
  //==========================================================================

  input logic cfg_fatal_timeout,

  input logic cfg_fatal_protocol,

  input logic cfg_fatal_malformed,

  input logic cfg_fatal_opcode,

  input logic cfg_fatal_alignment,

  input logic cfg_fatal_permission,

  input logic cfg_fatal_source,

  input logic cfg_fatal_sink,

  input logic cfg_fatal_txn,

  input logic cfg_fatal_probe,

  input logic cfg_fatal_grant,

  input logic cfg_fatal_release,

  input logic cfg_fatal_corrupt,

  input logic cfg_fatal_overflow,

  input logic cfg_fatal_underflow,


  //==========================================================================
  // Sticky status
  //==========================================================================

  output logic error_active,

  output logic fatal_error,

  output logic quarantine,

  output logic recoverable_error,


  output logic [31:0]
      error_status,


  //==========================================================================
  // First-error capture
  //==========================================================================

  output logic [31:0]
      first_error_code,

  output logic [ADDR_W-1:0]
      first_error_address,

  output logic [SOURCE_W-1:0]
      first_error_source,

  output logic [SINK_W-1:0]
      first_error_sink,

  output logic [2:0]
      first_error_opcode,

  output logic [2:0]
      first_error_param,

  output logic [2:0]
      first_error_size,


  //==========================================================================
  // Latest-error capture
  //==========================================================================

  output logic [31:0]
      last_error_code,

  output logic [ADDR_W-1:0]
      last_error_address,

  output logic [SOURCE_W-1:0]
      last_error_source,

  output logic [SINK_W-1:0]
      last_error_sink,

  output logic [2:0]
      last_error_opcode,

  output logic [2:0]
      last_error_param,

  output logic [2:0]
      last_error_size,


  //==========================================================================
  // Error counters
  //==========================================================================

  output logic [COUNTER_W-1:0]
      timeout_count,

  output logic [COUNTER_W-1:0]
      protocol_count,

  output logic [COUNTER_W-1:0]
      malformed_count,

  output logic [COUNTER_W-1:0]
      illegal_opcode_count,

  output logic [COUNTER_W-1:0]
      alignment_count,

  output logic [COUNTER_W-1:0]
      permission_count,

  output logic [COUNTER_W-1:0]
      source_count,

  output logic [COUNTER_W-1:0]
      sink_count,

  output logic [COUNTER_W-1:0]
      txn_count,

  output logic [COUNTER_W-1:0]
      probe_count,

  output logic [COUNTER_W-1:0]
      grant_count,

  output logic [COUNTER_W-1:0]
      release_count,

  output logic [COUNTER_W-1:0]
      corrupt_count,

  output logic [COUNTER_W-1:0]
      overflow_count,

  output logic [COUNTER_W-1:0]
      underflow_count,


  //==========================================================================
  // Fault containment outputs
  //==========================================================================

  output logic block_a,

  output logic block_b,

  output logic block_c,

  output logic block_d,

  output logic block_e,

  output logic flush_transactions,

  output logic flush_probes,

  output logic reset_coherence,

  output logic request_recovery,

  output logic fatal_interrupt,

  output logic recoverable_interrupt

);


  //==========================================================================
  // Error encoding
  //==========================================================================

  localparam logic [31:0]
      ERR_NONE =
          32'h0000_0000;

  localparam logic [31:0]
      ERR_TIMEOUT =
          32'h0000_0001;

  localparam logic [31:0]
      ERR_PROTOCOL =
          32'h0000_0002;

  localparam logic [31:0]
      ERR_MALFORMED =
          32'h0000_0004;

  localparam logic [31:0]
      ERR_ILLEGAL_OPCODE =
          32'h0000_0008;

  localparam logic [31:0]
      ERR_ALIGNMENT =
          32'h0000_0010;

  localparam logic [31:0]
      ERR_PERMISSION =
          32'h0000_0020;

  localparam logic [31:0]
      ERR_SOURCE =
          32'h0000_0040;

  localparam logic [31:0]
      ERR_SINK =
          32'h0000_0080;

  localparam logic [31:0]
      ERR_TXN =
          32'h0000_0100;

  localparam logic [31:0]
      ERR_PROBE =
          32'h0000_0200;

  localparam logic [31:0]
      ERR_GRANT =
          32'h0000_0400;

  localparam logic [31:0]
      ERR_RELEASE =
          32'h0000_0800;

  localparam logic [31:0]
      ERR_CORRUPT =
          32'h0000_1000;

  localparam logic [31:0]
      ERR_OVERFLOW =
          32'h0000_2000;

  localparam logic [31:0]
      ERR_UNDERFLOW =
          32'h0000_4000;


  //==========================================================================
  // Internal error vectors
  //==========================================================================

  logic [31:0]
      error_vector;

  logic [31:0]
      fatal_vector;

  logic [31:0]
      recoverable_vector;


  //==========================================================================
  // Build error vector
  //==========================================================================

  always_comb begin

    error_vector =
        '0;

    if (error_timeout)
      error_vector |= ERR_TIMEOUT;

    if (error_protocol)
      error_vector |= ERR_PROTOCOL;

    if (error_malformed)
      error_vector |= ERR_MALFORMED;

    if (error_illegal_opcode)
      error_vector |= ERR_ILLEGAL_OPCODE;

    if (error_alignment)
      error_vector |= ERR_ALIGNMENT;

    if (error_permission)
      error_vector |= ERR_PERMISSION;

    if (
      error_source ||
      source_table_error
    )
      error_vector |= ERR_SOURCE;

    if (
      error_sink ||
      sink_table_error
    )
      error_vector |= ERR_SINK;

    if (
      error_txn_overflow ||
      error_txn_underflow ||
      txn_table_error
    )
      error_vector |= ERR_TXN;

    if (
      error_probe ||
      probe_tracker_error
    )
      error_vector |= ERR_PROBE;

    if (
      error_grant ||
      coherence_error
    )
      error_vector |= ERR_GRANT;

    if (
      error_release
    )
      error_vector |= ERR_RELEASE;

    if (
      error_corrupt ||
      poison_detected
    )
      error_vector |= ERR_CORRUPT;

    if (
      error_overflow ||
      arbitration_error ||
      router_error ||
      crossbar_error
    )
      error_vector |= ERR_OVERFLOW;

    if (
      error_underflow ||
      directory_error
    )
      error_vector |= ERR_UNDERFLOW;

  end


  //==========================================================================
  // Runtime fatal classification
  //==========================================================================

  always_comb begin

    fatal_vector =
        '0;

    recoverable_vector =
        '0;


    //-----------------------------------------------------------------------
    // Timeout
    //-----------------------------------------------------------------------

    if (error_vector & ERR_TIMEOUT) begin

      if (cfg_fatal_timeout)
        fatal_vector |= ERR_TIMEOUT;
      else
        recoverable_vector |= ERR_TIMEOUT;

    end


    //-----------------------------------------------------------------------
    // Protocol
    //-----------------------------------------------------------------------

    if (error_vector & ERR_PROTOCOL) begin

      if (cfg_fatal_protocol)
        fatal_vector |= ERR_PROTOCOL;
      else
        recoverable_vector |= ERR_PROTOCOL;

    end


    //-----------------------------------------------------------------------
    // Malformed
    //-----------------------------------------------------------------------

    if (error_vector & ERR_MALFORMED) begin

      if (cfg_fatal_malformed)
        fatal_vector |= ERR_MALFORMED;
      else
        recoverable_vector |= ERR_MALFORMED;

    end


    //-----------------------------------------------------------------------
    // Illegal opcode
    //-----------------------------------------------------------------------

    if (error_vector & ERR_ILLEGAL_OPCODE) begin

      if (cfg_fatal_opcode)
        fatal_vector |= ERR_ILLEGAL_OPCODE;
      else
        recoverable_vector |= ERR_ILLEGAL_OPCODE;

    end


    //-----------------------------------------------------------------------
    // Alignment
    //-----------------------------------------------------------------------

    if (error_vector & ERR_ALIGNMENT) begin

      if (cfg_fatal_alignment)
        fatal_vector |= ERR_ALIGNMENT;
      else
        recoverable_vector |= ERR_ALIGNMENT;

    end


    //-----------------------------------------------------------------------
    // Permission
    //-----------------------------------------------------------------------

    if (error_vector & ERR_PERMISSION) begin

      if (cfg_fatal_permission)
        fatal_vector |= ERR_PERMISSION;
      else
        recoverable_vector |= ERR_PERMISSION;

    end


    //-----------------------------------------------------------------------
    // Source
    //-----------------------------------------------------------------------

    if (error_vector & ERR_SOURCE) begin

      if (cfg_fatal_source)
        fatal_vector |= ERR_SOURCE;
      else
        recoverable_vector |= ERR_SOURCE;

    end


    //-----------------------------------------------------------------------
    // Sink
    //-----------------------------------------------------------------------

    if (error_vector & ERR_SINK) begin

      if (cfg_fatal_sink)
        fatal_vector |= ERR_SINK;
      else
        recoverable_vector |= ERR_SINK;

    end


    //-----------------------------------------------------------------------
    // Transaction table
    //-----------------------------------------------------------------------

    if (error_vector & ERR_TXN) begin

      if (cfg_fatal_txn)
        fatal_vector |= ERR_TXN;
      else
        recoverable_vector |= ERR_TXN;

    end


    //-----------------------------------------------------------------------
    // Probe
    //-----------------------------------------------------------------------

    if (error_vector & ERR_PROBE) begin

      if (cfg_fatal_probe)
        fatal_vector |= ERR_PROBE;
      else
        recoverable_vector |= ERR_PROBE;

    end


    //-----------------------------------------------------------------------
    // Grant
    //-----------------------------------------------------------------------

    if (error_vector & ERR_GRANT) begin

      if (cfg_fatal_grant)
        fatal_vector |= ERR_GRANT;
      else
        recoverable_vector |= ERR_GRANT;

    end


    //-----------------------------------------------------------------------
    // Release
    //-----------------------------------------------------------------------

    if (error_vector & ERR_RELEASE) begin

      if (cfg_fatal_release)
        fatal_vector |= ERR_RELEASE;
      else
        recoverable_vector |= ERR_RELEASE;

    end


    //-----------------------------------------------------------------------
    // Corrupt
    //-----------------------------------------------------------------------

    if (error_vector & ERR_CORRUPT) begin

      if (cfg_fatal_corrupt)
        fatal_vector |= ERR_CORRUPT;
      else
        recoverable_vector |= ERR_CORRUPT;

    end


    //-----------------------------------------------------------------------
    // Overflow
    //-----------------------------------------------------------------------

    if (error_vector & ERR_OVERFLOW) begin

      if (cfg_fatal_overflow)
        fatal_vector |= ERR_OVERFLOW;
      else
        recoverable_vector |= ERR_OVERFLOW;

    end


    //-----------------------------------------------------------------------
    // Underflow
    //-----------------------------------------------------------------------

    if (error_vector & ERR_UNDERFLOW) begin

      if (cfg_fatal_underflow)
        fatal_vector |= ERR_UNDERFLOW;
      else
        recoverable_vector |= ERR_UNDERFLOW;

    end

  end


  //==========================================================================
  // Sticky error state
  //==========================================================================

  logic first_error_valid_q;

  logic fatal_error_q;

  logic recoverable_error_q;

  logic quarantine_q;


  assign fatal_error =
      fatal_error_q;

  assign recoverable_error =
      recoverable_error_q;

  assign quarantine =
      quarantine_q;


  assign error_active =
      |error_status;


  //==========================================================================
  // Main error state
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      error_status <=
          '0;

      first_error_valid_q <=
          1'b0;

      first_error_code <=
          ERR_NONE;

      first_error_address <=
          '0;

      first_error_source <=
          '0;

      first_error_sink <=
          '0;

      first_error_opcode <=
          '0;

      first_error_param <=
          '0;

      first_error_size <=
          '0;


      last_error_code <=
          ERR_NONE;

      last_error_address <=
          '0;

      last_error_source <=
          '0;

      last_error_sink <=
          '0;

      last_error_opcode <=
          '0;

      last_error_param <=
          '0;

      last_error_size <=
          '0;


      fatal_error_q <=
          1'b0;

      recoverable_error_q <=
          1'b0;

      quarantine_q <=
          1'b0;

    end
    else begin

      //----------------------------------------------------------------------
      // Clear sticky state
      //----------------------------------------------------------------------

      if (clear_errors) begin

        error_status <=
            '0;

        first_error_valid_q <=
            1'b0;

        fatal_error_q <=
            1'b0;

        recoverable_error_q <=
            1'b0;

        quarantine_q <=
            1'b0;

      end


      //----------------------------------------------------------------------
      // New error
      //----------------------------------------------------------------------

      if (
        enable_error_handler &&
        (error_vector != ERR_NONE)
      ) begin

        //--------------------------------------------------------------------
        // Sticky status
        //--------------------------------------------------------------------

        error_status <=
            error_status | error_vector;


        //--------------------------------------------------------------------
        // Latest error
        //
        // Priority is encoded from MSB to LSB.
        //--------------------------------------------------------------------

        if (error_vector & ERR_UNDERFLOW)

          last_error_code <=
              ERR_UNDERFLOW;

        else if (error_vector & ERR_OVERFLOW)

          last_error_code <=
              ERR_OVERFLOW;

        else if (error_vector & ERR_CORRUPT)

          last_error_code <=
              ERR_CORRUPT;

        else if (error_vector & ERR_RELEASE)

          last_error_code <=
              ERR_RELEASE;

        else if (error_vector & ERR_GRANT)

          last_error_code <=
              ERR_GRANT;

        else if (error_vector & ERR_PROBE)

          last_error_code <=
              ERR_PROBE;

        else if (error_vector & ERR_TXN)

          last_error_code <=
              ERR_TXN;

        else if (error_vector & ERR_SINK)

          last_error_code <=
              ERR_SINK;

        else if (error_vector & ERR_SOURCE)

          last_error_code <=
              ERR_SOURCE;

        else if (error_vector & ERR_PERMISSION)

          last_error_code <=
              ERR_PERMISSION;

        else if (error_vector & ERR_ALIGNMENT)

          last_error_code <=
              ERR_ALIGNMENT;

        else if (error_vector & ERR_ILLEGAL_OPCODE)

          last_error_code <=
              ERR_ILLEGAL_OPCODE;

        else if (error_vector & ERR_MALFORMED)

          last_error_code <=
              ERR_MALFORMED;

        else if (error_vector & ERR_PROTOCOL)

          last_error_code <=
              ERR_PROTOCOL;

        else

          last_error_code <=
              ERR_TIMEOUT;


        //--------------------------------------------------------------------
        // Latest error context
        //--------------------------------------------------------------------

        last_error_address <=
            error_address;

        last_error_source <=
            error_source;

        last_error_sink <=
            error_sink;

        last_error_opcode <=
            error_opcode;

        last_error_param <=
            error_param;

        last_error_size <=
            error_size;


        //--------------------------------------------------------------------
        // First error capture
        //--------------------------------------------------------------------

        if (!first_error_valid_q) begin

          first_error_valid_q <=
              1'b1;

          first_error_code <=
              error_vector;

          first_error_address <=
              error_address;

          first_error_source <=
              error_source;

          first_error_sink <=
              error_sink;

          first_error_opcode <=
              error_opcode;

          first_error_param <=
              error_param;

          first_error_size <=
              error_size;

        end


        //--------------------------------------------------------------------
        // Fatal/recoverable classification
        //--------------------------------------------------------------------

        if (fatal_vector != '0)

          fatal_error_q <=
              1'b1;

        if (recoverable_vector != '0)

          recoverable_error_q <=
              1'b1;


        //--------------------------------------------------------------------
        // Quarantine
        //--------------------------------------------------------------------

        if (fatal_vector != '0)

          quarantine_q <=
              1'b1;

      end

    end

  end


  //==========================================================================
  // Error counters
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      timeout_count       <= '0;
      protocol_count      <= '0;
      malformed_count     <= '0;
      illegal_opcode_count<= '0;
      alignment_count     <= '0;
      permission_count    <= '0;
      source_count        <= '0;
      sink_count          <= '0;
      txn_count           <= '0;
      probe_count         <= '0;
      grant_count         <= '0;
      release_count       <= '0;
      corrupt_count       <= '0;
      overflow_count      <= '0;
      underflow_count     <= '0;
    end
    else begin

      if (clear_counters) begin

        timeout_count        <= '0;
        protocol_count       <= '0;
        malformed_count      <= '0;
        illegal_opcode_count <= '0;
        alignment_count      <= '0;
        permission_count     <= '0;
        source_count         <= '0;
        sink_count           <= '0;
        txn_count            <= '0;
        probe_count          <= '0;
        grant_count          <= '0;
        release_count        <= '0;
        corrupt_count        <= '0;
        overflow_count       <= '0;
        underflow_count      <= '0;

      end
      else if (enable_error_handler) begin

        if (error_timeout)
          timeout_count <=
              timeout_count + 1'b1;

        if (error_protocol)
          protocol_count <=
              protocol_count + 1'b1;

        if (error_malformed)
          malformed_count <=
              malformed_count + 1'b1;

        if (error_illegal_opcode)
          illegal_opcode_count <=
              illegal_opcode_count + 1'b1;

        if (error_alignment)
          alignment_count <=
              alignment_count + 1'b1;

        if (error_permission)
          permission_count <=
              permission_count + 1'b1;

        if (
          error_source ||
          source_table_error
        )
          source_count <=
              source_count + 1'b1;

        if (
          error_sink ||
          sink_table_error
        )
          sink_count <=
              sink_count + 1'b1;

        if (
          error_txn_overflow ||
          error_txn_underflow ||
          txn_table_error
        )
          txn_count <=
              txn_count + 1'b1;

        if (
          error_probe ||
          probe_tracker_error
        )
          probe_count <=
              probe_count + 1'b1;

        if (
          error_grant ||
          coherence_error
        )
          grant_count <=
              grant_count + 1'b1;

        if (error_release)
          release_count <=
              release_count + 1'b1;

        if (
          error_corrupt ||
          poison_detected
        )
          corrupt_count <=
              corrupt_count + 1'b1;

        if (
          error_overflow ||
          arbitration_error ||
          router_error ||
          crossbar_error
        )
          overflow_count <=
              overflow_count + 1'b1;

        if (
          error_underflow ||
          directory_error
        )
          underflow_count <=
              underflow_count + 1'b1;

      end

    end

  end


  //==========================================================================
  // Fault containment policy
  //==========================================================================

  always_comb begin

    block_a =
        1'b0;

    block_b =
        1'b0;

    block_c =
        1'b0;

    block_d =
        1'b0;

    block_e =
        1'b0;

    flush_transactions =
        1'b0;

    flush_probes =
        1'b0;

    reset_coherence =
        1'b0;

    request_recovery =
        1'b0;

    fatal_interrupt =
        1'b0;

    recoverable_interrupt =
        1'b0;


    //-----------------------------------------------------------------------
    // Fatal error containment
    //-----------------------------------------------------------------------

    if (fatal_error_q) begin

      block_a =
          1'b1;

      block_b =
          1'b1;

      block_c =
          1'b1;

      block_d =
          1'b1;

      block_e =
          1'b1;

      flush_transactions =
          1'b1;

      flush_probes =
          1'b1;

      reset_coherence =
          1'b1;

      request_recovery =
          1'b1;

      fatal_interrupt =
          1'b1;

    end
    else if (recoverable_error_q) begin

      recoverable_interrupt =
          1'b1;

      request_recovery =
          1'b1;

    end

  end


  //==========================================================================
  // Runtime parameter checks
  //==========================================================================

  initial begin

    if (ADDR_W == 0)
      $error(
        "TLC_ERROR_HANDLER: ADDR_W must be > 0"
      );

    if (DATA_W == 0)
      $error(
        "TLC_ERROR_HANDLER: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC_ERROR_HANDLER: DATA_W must be byte aligned"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC_ERROR_HANDLER: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC_ERROR_HANDLER: SINK_W must be > 0"
      );

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  // Fatal error must eventually imply quarantine.

  property p_fatal_quarantine;

    @(posedge clk)
    disable iff (!rst_n)

    fatal_error_q
    |-> quarantine_q;

  endproperty


  assert property (p_fatal_quarantine)
  else
    $error(
      "TLC_ERROR_HANDLER: fatal error without quarantine"
    );


  // Error status must remain sticky until clear/reset.

  property p_error_sticky;

    @(posedge clk)
    disable iff (!rst_n)

    error_status != '0 &&
    !clear_errors
    |->
    error_status != '0;

  endproperty


  assert property (p_error_sticky)
  else
    $error(
      "TLC_ERROR_HANDLER: error status lost without clear"
    );


  // Fatal interrupt must only occur for a fatal error.

  property p_fatal_interrupt;

    @(posedge clk)

    fatal_interrupt
    |-> fatal_error_q;

  endproperty


  assert property (p_fatal_interrupt)
  else
    $error(
      "TLC_ERROR_HANDLER: fatal interrupt without fatal state"
    );


  // Quarantine implies recovery request.

  property p_quarantine_recovery;

    @(posedge clk)

    quarantine_q
    |-> request_recovery;

  endproperty


  assert property (p_quarantine_recovery)
  else
    $error(
      "TLC_ERROR_HANDLER: quarantine without recovery request"
    );


  // Error handler disabled must not create a new error.

  property p_disabled_no_capture;

    @(posedge clk)

    !enable_error_handler
    |=> $stable(error_status);

  endproperty


  assert property (p_disabled_no_capture)
  else
    $error(
      "TLC_ERROR_HANDLER: status changed while disabled"
    );


`endif


endmodule