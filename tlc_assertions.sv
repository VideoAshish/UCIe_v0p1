//==============================================================================
// tlc_assertions.sv
//
// TileLink-C Protocol Assertion Module
//
// Purpose:
//   Formal / simulation protocol checker for the five TL-C channels.
//
// Channels:
//   A - Request
//   B - Probe
//   C - ProbeAck / Release
//   D - Response / Grant
//   E - GrantAck
//
// Checks:
//   * Reset cleanliness
//   * Ready/valid stability
//   * Opcode legality
//   * Size legality
//   * Address alignment
//   * Byte-mask legality
//   * Source reuse protection
//   * D-response source matching
//   * E-channel sink matching
//   * Acquire -> Grant ordering
//   * Probe -> ProbeAck ordering
//   * Release -> ReleaseAck ordering
//   * Grant -> GrantAck ordering
//   * Outstanding transaction bounds
//   * Channel payload stability while stalled
//   * No X/Z control signals during active operation
//   * Timeout detection
//
// NOTE:
//   This module is passive and must NEVER drive TL-C signals.
//
//==============================================================================

module tlc_assertions #(

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
      256,

  parameter int unsigned MAX_PROBES =
      256,

  parameter int unsigned TIMEOUT_CYCLES =
      100000,

  parameter bit ENABLE_X_CHECK =
      1'b1,

  parameter bit ENABLE_TIMEOUT =
      1'b1,

  parameter bit ENABLE_PROTOCOL_ASSERTIONS =
      1'b1

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

  input logic [SOURCE_W-1:0]
      a_source,

  input logic [ADDR_W-1:0]
      a_address,

  input logic [DATA_W-1:0]
      a_data,

  input logic [DATA_W/8-1:0]
      a_mask,


  //==========================================================================
  // B channel
  //==========================================================================

  input logic b_valid,
  input logic b_ready,

  input logic [2:0] b_opcode,
  input logic [2:0] b_param,
  input logic [2:0] b_size,

  input logic [SOURCE_W-1:0]
      b_source,

  input logic [SINK_W-1:0]
      b_sink,

  input logic [ADDR_W-1:0]
      b_address,

  input logic [DATA_W-1:0]
      b_data,

  input logic [DATA_W/8-1:0]
      b_mask,


  //==========================================================================
  // C channel
  //==========================================================================

  input logic c_valid,
  input logic c_ready,

  input logic [2:0] c_opcode,
  input logic [2:0] c_param,
  input logic [2:0] c_size,

  input logic [SOURCE_W-1:0]
      c_source,

  input logic [SINK_W-1:0]
      c_sink,

  input logic [ADDR_W-1:0]
      c_address,

  input logic [DATA_W-1:0]
      c_data,

  input logic [DATA_W/8-1:0]
      c_mask,


  //==========================================================================
  // D channel
  //==========================================================================

  input logic d_valid,
  input logic d_ready,

  input logic [2:0] d_opcode,
  input logic [2:0] d_param,
  input logic [2:0] d_size,

  input logic [SOURCE_W-1:0]
      d_source,

  input logic [SINK_W-1:0]
      d_sink,

  input logic [DATA_W-1:0]
      d_data,

  input logic d_denied,
  input logic d_corrupt,


  //==========================================================================
  // E channel
  //==========================================================================

  input logic e_valid,
  input logic e_ready,

  input logic [SINK_W-1:0]
      e_sink,


  //==========================================================================
  // Optional protocol-state information
  //
  // These inputs allow the assertion layer to verify global protocol state
  // rather than only local channel syntax.
  //==========================================================================

  input logic [MAX_OUTSTANDING-1:0]
      source_active,

  input logic [MAX_OUTSTANDING-1:0]
      source_acquire,

  input logic [MAX_PROBES-1:0]
      probe_active,

  input logic [MAX_PROBES-1:0]
      sink_active,


  input logic [$clog2(MAX_OUTSTANDING+1)-1:0]
      outstanding_count,


  //==========================================================================
  // Optional status
  //==========================================================================

  output logic assertion_error

);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned SIZE_W =
      $clog2(CACHE_LINE_BYTES + 1);

  localparam int unsigned TIMEOUT_W =
      (TIMEOUT_CYCLES <= 1) ?
      1 :
      $clog2(TIMEOUT_CYCLES + 1);


  //==========================================================================
  // Handshake definitions
  //==========================================================================

  logic a_fire;
  logic b_fire;
  logic c_fire;
  logic d_fire;
  logic e_fire;

  assign a_fire =
      a_valid && a_ready;

  assign b_fire =
      b_valid && b_ready;

  assign c_fire =
      c_valid && c_ready;

  assign d_fire =
      d_valid && d_ready;

  assign e_fire =
      e_valid && e_ready;


  //==========================================================================
  // Opcode definitions
  //
  // These values are aligned with the TL opcode encoding used by the
  // preceding tlc_monitor implementation.
  //==========================================================================

  localparam logic [2:0]
      A_PUTFULL =
          3'd0;

  localparam logic [2:0]
      A_PUTPARTIAL =
          3'd1;

  localparam logic [2:0]
      A_ARITH =
          3'd2;

  localparam logic [2:0]
      A_LOGICAL =
          3'd3;

  localparam logic [2:0]
      A_GET =
          3'd4;

  localparam logic [2:0]
      A_HINT =
          3'd5;

  localparam logic [2:0]
      A_ACQUIRE_BLOCK =
          3'd6;

  localparam logic [2:0]
      A_ACQUIRE_PERM =
          3'd7;


  localparam logic [2:0]
      B_PROBE_ACK =
          3'd0;

  localparam logic [2:0]
      B_PROBE_ACK_DATA =
          3'd1;


  localparam logic [2:0]
      C_PROBE_ACK =
          3'd0;

  localparam logic [2:0]
      C_PROBE_ACK_DATA =
          3'd1;

  localparam logic [2:0]
      C_RELEASE =
          3'd2;

  localparam logic [2:0]
      C_RELEASE_DATA =
          3'd3;


  localparam logic [2:0]
      D_ACCESS_ACK =
          3'd0;

  localparam logic [2:0]
      D_ACCESS_ACK_DATA =
          3'd1;

  localparam logic [2:0]
      D_HINT_ACK =
          3'd2;

  localparam logic [2:0]
      D_GRANT =
          3'd4;

  localparam logic [2:0]
      D_GRANT_DATA =
          3'd5;

  localparam logic [2:0]
      D_RELEASE_ACK =
          3'd6;


  //==========================================================================
  // Opcode legality functions
  //==========================================================================

  function automatic logic
  a_opcode_legal(
    input logic [2:0] opcode
  );

    case (opcode)

      A_PUTFULL,
      A_PUTPARTIAL,
      A_ARITH,
      A_LOGICAL,
      A_GET,
      A_HINT,
      A_ACQUIRE_BLOCK,
      A_ACQUIRE_PERM:

        a_opcode_legal = 1'b1;

      default:

        a_opcode_legal = 1'b0;

    endcase

  endfunction


  function automatic logic
  b_opcode_legal(
    input logic [2:0] opcode
  );

    // B is implementation-specific in many TL-C systems.
    // Only legal Probe operations should appear here.

    case (opcode)

      3'd6,
      3'd7:

        b_opcode_legal = 1'b1;

      default:

        b_opcode_legal = 1'b0;

    endcase

  endfunction


  function automatic logic
  c_opcode_legal(
    input logic [2:0] opcode
  );

    case (opcode)

      C_PROBE_ACK,
      C_PROBE_ACK_DATA,
      C_RELEASE,
      C_RELEASE_DATA:

        c_opcode_legal = 1'b1;

      default:

        c_opcode_legal = 1'b0;

    endcase

  endfunction


  function automatic logic
  d_opcode_legal(
    input logic [2:0] opcode
  );

    case (opcode)

      D_ACCESS_ACK,
      D_ACCESS_ACK_DATA,
      D_HINT_ACK,
      D_GRANT,
      D_GRANT_DATA,
      D_RELEASE_ACK:

        d_opcode_legal = 1'b1;

      default:

        d_opcode_legal = 1'b0;

    endcase

  endfunction


  //==========================================================================
  // Size checking
  //==========================================================================

  function automatic logic
  size_legal(
    input logic [2:0] size
  );

    size_legal =
        ((1 << size) <= CACHE_LINE_BYTES);

  endfunction


  //==========================================================================
  // Alignment checking
  //==========================================================================

  function automatic logic
  address_aligned(
    input logic [ADDR_W-1:0] address,
    input logic [2:0] size
  );

    logic [ADDR_W-1:0] alignment_mask;

    begin

      alignment_mask =
          '0;

      if (size < ADDR_W)

        alignment_mask =
            ({{(ADDR_W-1){1'b0}},1'b1} << size) -
            1'b1;

      address_aligned =
          ((address & alignment_mask) == '0);

    end

  endfunction


  //==========================================================================
  // Byte mask checker
  //==========================================================================

  function automatic logic
  partial_mask_legal(
    input logic [2:0] opcode,
    input logic [2:0] size,
    input logic [BYTE_W-1:0] mask
  );

    logic [BYTE_W-1:0]
        expected_mask;

    begin

      expected_mask =
          '0;

      if ((1 << size) >= BYTE_W)

        expected_mask =
            {BYTE_W{1'b1}};

      else

        expected_mask =
            (({{(BYTE_W-1){1'b0}},1'b1}
              << (1 << size)) - 1'b1);


      case (opcode)

        A_PUTFULL:

          partial_mask_legal =
              mask == expected_mask;


        A_PUTPARTIAL:

          partial_mask_legal =
              mask != '0;


        default:

          partial_mask_legal =
              1'b1;

      endcase

    end

  endfunction


  //==========================================================================
  //==========================================================================
  // A CHANNEL ASSERTIONS
  //==========================================================================

`ifndef SYNTHESIS

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_A_ASSERTIONS


  //--------------------------------------------------------------------------
  // A valid must remain asserted during backpressure.
  //--------------------------------------------------------------------------

  ap_a_valid_stable:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_valid && !a_ready
    |->
    $stable(a_valid)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C A: VALID changed while READY low"
    );
  end


  //--------------------------------------------------------------------------
  // A payload must remain stable while stalled.
  //--------------------------------------------------------------------------

  ap_a_payload_stable:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_valid && !a_ready
    |=>

    $stable(a_opcode) &&
    $stable(a_param) &&
    $stable(a_size) &&
    $stable(a_source) &&
    $stable(a_address) &&
    $stable(a_data) &&
    $stable(a_mask)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C A: payload changed while stalled"
    );
  end


  //--------------------------------------------------------------------------
  // Legal opcode.
  //--------------------------------------------------------------------------

  ap_a_opcode:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_fire
    |->
    a_opcode_legal(a_opcode)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C A: illegal opcode %0d",
      a_opcode
    );
  end


  //--------------------------------------------------------------------------
  // Legal size.
  //--------------------------------------------------------------------------

  ap_a_size:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_fire
    |->
    size_legal(a_size)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C A: illegal size %0d",
      a_size
    );
  end


  //--------------------------------------------------------------------------
  // Alignment.
  //--------------------------------------------------------------------------

  ap_a_alignment:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_fire
    |->
    address_aligned(
      a_address,
      a_size
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C A: unaligned address %h",
      a_address
    );
  end


  //--------------------------------------------------------------------------
  // Source must not be reused while active.
  //--------------------------------------------------------------------------

  ap_source_not_reused:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_fire
    |->
    !source_active[a_source]
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C A: source ID reused: %0d",
      a_source
    );
  end


  //--------------------------------------------------------------------------
  // Outstanding count bound.
  //--------------------------------------------------------------------------

  ap_outstanding_bound:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    outstanding_count <= MAX_OUTSTANDING
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C: outstanding count overflow"
    );
  end


end

endgenerate


  //==========================================================================
  // B CHANNEL ASSERTIONS
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_B_ASSERTIONS


  ap_b_valid_stable:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    b_valid && !b_ready
    |=>

    $stable(b_valid) &&
    $stable(b_opcode) &&
    $stable(b_param) &&
    $stable(b_size) &&
    $stable(b_source) &&
    $stable(b_sink) &&
    $stable(b_address) &&
    $stable(b_data) &&
    $stable(b_mask)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C B: payload changed while stalled"
    );
  end


  ap_b_opcode:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    b_fire
    |->
    b_opcode_legal(b_opcode)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C B: illegal opcode"
    );
  end


  ap_b_size:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    b_fire
    |->
    size_legal(b_size)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C B: illegal size"
    );
  end


  ap_b_alignment:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    b_fire
    |->
    address_aligned(
      b_address,
      b_size
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C B: unaligned probe address"
    );
  end


end

endgenerate


  //==========================================================================
  // C CHANNEL ASSERTIONS
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_C_ASSERTIONS


  ap_c_valid_stable:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    c_valid && !c_ready
    |=>

    $stable(c_valid) &&
    $stable(c_opcode) &&
    $stable(c_param) &&
    $stable(c_size) &&
    $stable(c_source) &&
    $stable(c_sink) &&
    $stable(c_address) &&
    $stable(c_data) &&
    $stable(c_mask)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C C: payload changed while stalled"
    );
  end


  ap_c_opcode:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    c_fire
    |->
    c_opcode_legal(c_opcode)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C C: illegal opcode"
    );
  end


  ap_c_size:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    c_fire
    |->
    size_legal(c_size)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C C: illegal size"
    );
  end


  ap_c_alignment:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    c_fire
    |->
    address_aligned(
      c_address,
      c_size
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C C: unaligned address"
    );
  end


end

endgenerate


  //==========================================================================
  // D CHANNEL ASSERTIONS
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_D_ASSERTIONS


  ap_d_valid_stable:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d_valid && !d_ready
    |=>

    $stable(d_valid) &&
    $stable(d_opcode) &&
    $stable(d_param) &&
    $stable(d_size) &&
    $stable(d_source) &&
    $stable(d_sink) &&
    $stable(d_data) &&
    $stable(d_denied) &&
    $stable(d_corrupt)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C D: payload changed while stalled"
    );
  end


  ap_d_opcode:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d_fire
    |->
    d_opcode_legal(d_opcode)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C D: illegal opcode"
    );
  end


  ap_d_size:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d_fire
    |->
    size_legal(d_size)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C D: illegal size"
    );
  end


  //--------------------------------------------------------------------------
  // Every D response must have an active source.
  //--------------------------------------------------------------------------

  ap_d_source_match:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d_fire
    |->
    source_active[d_source]
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C D: response for inactive source %0d",
      d_source
    );
  end


end

endgenerate


  //==========================================================================
  // E CHANNEL ASSERTIONS
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_E_ASSERTIONS


  ap_e_valid_stable:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    e_valid && !e_ready
    |=>

    $stable(e_valid) &&
    $stable(e_sink)
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C E: sink changed while stalled"
    );
  end


  //--------------------------------------------------------------------------
  // E must correspond to an active sink.
  //--------------------------------------------------------------------------

  ap_e_sink_match:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    e_fire
    |->
    sink_active[e_sink]
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C E: GrantAck for inactive sink %0d",
      e_sink
    );
  end


end

endgenerate


  //==========================================================================
  // ACQUIRE / GRANT RELATIONSHIP
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_ACQUIRE_ASSERTIONS


  //--------------------------------------------------------------------------
  // AcquireBlock / AcquirePerm must eventually produce Grant or GrantData.
  //
  // This is a bounded liveness assertion.
  //--------------------------------------------------------------------------

  ap_acquire_grant:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_fire &&
    (
      a_opcode == A_ACQUIRE_BLOCK ||
      a_opcode == A_ACQUIRE_PERM
    )

    |->
    ##[1:TIMEOUT_CYCLES]

    (
      d_valid &&
      d_ready &&
      d_source == $past(
        a_source,
        1
      ) &&
      (
        d_opcode == D_GRANT ||
        d_opcode == D_GRANT_DATA
      )
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C: Acquire did not receive Grant within timeout"
    );
  end


end

endgenerate


  //==========================================================================
  // RELEASE RELATIONSHIP
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_RELEASE_ASSERTIONS


  ap_release_ack:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    c_fire &&
    (
      c_opcode == C_RELEASE ||
      c_opcode == C_RELEASE_DATA
    )

    |->
    ##[1:TIMEOUT_CYCLES]

    (
      d_valid &&
      d_ready &&
      d_source == $past(
        c_source,
        1
      ) &&
      d_opcode == D_RELEASE_ACK
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C: Release did not receive ReleaseAck"
    );
  end


end

endgenerate


  //==========================================================================
  // GRANT -> GRANTACK
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_GRANT_ACK_ASSERTIONS


  ap_grant_ack:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d_fire &&
    (
      d_opcode == D_GRANT ||
      d_opcode == D_GRANT_DATA
    )

    |->
    ##[1:TIMEOUT_CYCLES]

    (
      e_valid &&
      e_ready &&
      e_sink == $past(
        d_sink,
        1
      )
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C: Grant was not followed by GrantAck"
    );
  end


end

endgenerate


  //==========================================================================
  // PROBE -> PROBEACK
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_PROBE_ASSERTIONS


  ap_probe_ack:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    b_fire &&
    (
      b_opcode == 3'd6 ||
      b_opcode == 3'd7
    )

    |->
    ##[1:TIMEOUT_CYCLES]

    (
      c_valid &&
      c_ready &&
      c_source == $past(
        b_source,
        1
      ) &&
      (
        c_opcode == C_PROBE_ACK ||
        c_opcode == C_PROBE_ACK_DATA
      )
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C: Probe did not receive ProbeAck"
    );
  end


end

endgenerate


  //==========================================================================
  // PARTIAL WRITE MASK
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_MASK_ASSERTIONS


  ap_a_mask:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_fire &&
    (
      a_opcode == A_PUTFULL ||
      a_opcode == A_PUTPARTIAL
    )

    |->
    partial_mask_legal(
      a_opcode,
      a_size,
      a_mask
    )
  )
  else begin
    assertion_error <= 1'b1;
    $error(
      "TL-C A: invalid byte mask"
    );
  end


end

endgenerate


  //==========================================================================
  // X / Z CHECKING
  //==========================================================================

generate

if (ENABLE_X_CHECK) begin : GEN_X_ASSERTIONS


  ap_a_no_x:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_valid
    |->
    !$isunknown({
      a_opcode,
      a_param,
      a_size,
      a_source,
      a_address,
      a_data,
      a_mask
    })
  )
  else $error(
    "TL-C A: X/Z detected"
  );


  ap_b_no_x:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    b_valid
    |->
    !$isunknown({
      b_opcode,
      b_param,
      b_size,
      b_source,
      b_sink,
      b_address,
      b_data,
      b_mask
    })
  )
  else $error(
    "TL-C B: X/Z detected"
  );


  ap_c_no_x:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    c_valid
    |->
    !$isunknown({
      c_opcode,
      c_param,
      c_size,
      c_source,
      c_sink,
      c_address,
      c_data,
      c_mask
    })
  )
  else $error(
    "TL-C C: X/Z detected"
  );


  ap_d_no_x:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d_valid
    |->
    !$isunknown({
      d_opcode,
      d_param,
      d_size,
      d_source,
      d_sink,
      d_data,
      d_denied,
      d_corrupt
    })
  )
  else $error(
    "TL-C D: X/Z detected"
  );


  ap_e_no_x:

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    e_valid
    |->
    !$isunknown(e_sink)
  )
  else $error(
    "TL-C E: X/Z detected"
  );


end

endgenerate


  //==========================================================================
  // RESET CLEANLINESS
  //==========================================================================

generate

if (ENABLE_PROTOCOL_ASSERTIONS) begin : GEN_RESET_ASSERTIONS


  ap_reset_outstanding:

  assert property (
    !rst_n
    |->
    outstanding_count == '0
  )
  else $error(
    "TL-C: outstanding state not reset"
  );


  ap_reset_sources:

  assert property (
    !rst_n
    |->
    source_active == '0
  )
  else $error(
    "TL-C: source table not reset"
  );


  ap_reset_sinks:

  assert property (
    !rst_n
    |->
    sink_active == '0
  )
  else $error(
    "TL-C: sink table not reset"
  );


end

endgenerate


`endif


  //==========================================================================
  // Assertion status
  //
  // assertion_error is intended for simulation/formal status aggregation.
  // It is sticky until reset.
  //==========================================================================

`ifndef SYNTHESIS

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n)

      assertion_error <=
          1'b0;

  end

`else

  always_comb begin
    assertion_error = 1'b0;
  end

`endif


  //==========================================================================
  // Static parameter validation
  //==========================================================================

  initial begin

    if (DATA_W == 0)

      $error(
        "TLC_ASSERTIONS: DATA_W must be > 0"
      );


    if ((DATA_W % 8) != 0)

      $error(
        "TLC_ASSERTIONS: DATA_W must be byte aligned"
      );


    if (SOURCE_W == 0)

      $error(
        "TLC_ASSERTIONS: SOURCE_W must be > 0"
      );


    if (SINK_W == 0)

      $error(
        "TLC_ASSERTIONS: SINK_W must be > 0"
      );


    if (CACHE_LINE_BYTES == 0)

      $error(
        "TLC_ASSERTIONS: CACHE_LINE_BYTES must be > 0"
      );


    if (MAX_OUTSTANDING == 0)

      $error(
        "TLC_ASSERTIONS: MAX_OUTSTANDING must be > 0"
      );


    if (MAX_PROBES == 0)

      $error(
        "TLC_ASSERTIONS: MAX_PROBES must be > 0"
      );


    if (TIMEOUT_CYCLES == 0)

      $error(
        "TLC_ASSERTIONS: TIMEOUT_CYCLES must be > 0"
      );

  end

endmodule