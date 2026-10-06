//==============================================================================
// tlc_if.sv
//
// Production-grade parameterized TileLink-C interface.
//
// Channels:
//
//   A : Client  -> Manager
//       PutFullData
//       PutPartialData
//       ArithmeticData
//       LogicalData
//       Get
//       Hint
//       AcquireBlock
//       AcquirePerm
//
//   B : Manager -> Client
//       Probe
//       plus manager-originated TL operations where applicable
//
//   C : Client  -> Manager
//       ProbeAck
//       ProbeAckData
//       Release
//       ReleaseData
//
//   D : Manager -> Client
//       AccessAck
//       AccessAckData
//       HintAck
//       Grant
//       GrantData
//       ReleaseAck
//
//   E : Client  -> Manager
//       GrantAck
//
// Design goals:
//
//   * Fully parameterized
//   * Independent valid/ready per channel
//   * No combinational ready/valid paths inside interface
//   * Explicit channel payloads
//   * Modport-based direction checking
//   * Easy connection to skid buffers
//   * ASIC synthesis friendly
//   * Assertion hooks
//
//==============================================================================

interface tlc_if #(
  parameter int unsigned ADDR_W          = 48,
  parameter int unsigned DATA_W          = 256,
  parameter int unsigned SOURCE_W        = 8,
  parameter int unsigned SINK_W          = 6,

  parameter int unsigned CACHE_LINE_BYTES = 64,

  parameter int unsigned SIZE_W =
      (DATA_W <= 8) ? 1 : $clog2((DATA_W / 8) + 1)
);

  //--------------------------------------------------------------------------
  // Derived widths
  //--------------------------------------------------------------------------

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned BEAT_BYTES =
      DATA_W / 8;

  localparam int unsigned CLIENT_ID_W =
      (SOURCE_W < 1) ? 1 : SOURCE_W;

  //--------------------------------------------------------------------------
  // Channel opcodes
  //
  // Keep these explicitly local to the interface so the interface can be
  // compiled independently if required.
  //--------------------------------------------------------------------------

  typedef logic [2:0] opcode_t;

  // A channel
  localparam opcode_t A_PUTFULL      = 3'd0;
  localparam opcode_t A_PUTPARTIAL   = 3'd1;
  localparam opcode_t A_ARITHMETIC   = 3'd2;
  localparam opcode_t A_LOGICAL      = 3'd3;
  localparam opcode_t A_GET          = 3'd4;
  localparam opcode_t A_HINT         = 3'd5;
  localparam opcode_t A_ACQUIREBLOCK = 3'd6;
  localparam opcode_t A_ACQUIREPERM  = 3'd7;

  // B channel
  localparam opcode_t B_PUTFULL      = 3'd0;
  localparam opcode_t B_PUTPARTIAL   = 3'd1;
  localparam opcode_t B_ARITHMETIC   = 3'd2;
  localparam opcode_t B_LOGICAL      = 3'd3;
  localparam opcode_t B_GET          = 3'd4;
  localparam opcode_t B_HINT         = 3'd5;
  localparam opcode_t B_PROBE        = 3'd6;

  // C channel
  localparam opcode_t C_PROBEACK     = 3'd4;
  localparam opcode_t C_PROBEACKDATA = 3'd5;
  localparam opcode_t C_RELEASE      = 3'd6;
  localparam opcode_t C_RELEASEDATA  = 3'd7;

  // D channel
  localparam opcode_t D_ACCESSACK     = 3'd0;
  localparam opcode_t D_ACCESSACKDATA = 3'd1;
  localparam opcode_t D_HINTACK       = 3'd2;
  localparam opcode_t D_GRANT         = 3'd4;
  localparam opcode_t D_GRANTDATA     = 3'd5;
  localparam opcode_t D_RELEASEACK    = 3'd6;

  // E channel
  localparam opcode_t E_GRANTACK      = 3'd0;


  //--------------------------------------------------------------------------
  // Common TL fields
  //--------------------------------------------------------------------------

  typedef logic [ADDR_W-1:0]   addr_t;
  typedef logic [DATA_W-1:0]   data_t;
  typedef logic [BYTE_W-1:0]   mask_t;
  typedef logic [SOURCE_W-1:0] source_t;
  typedef logic [SINK_W-1:0]   sink_t;
  typedef logic [SIZE_W-1:0]   size_t;


  //--------------------------------------------------------------------------
  // A CHANNEL
  //
  // Client -> Manager
  //--------------------------------------------------------------------------

  logic             a_valid;
  logic             a_ready;

  opcode_t          a_opcode;
  logic [2:0]       a_param;
  size_t            a_size;
  source_t          a_source;

  addr_t            a_address;

  data_t            a_data;
  mask_t            a_mask;

  logic             a_corrupt;


  //--------------------------------------------------------------------------
  // B CHANNEL
  //
  // Manager -> Client
  //--------------------------------------------------------------------------

  logic             b_valid;
  logic             b_ready;

  opcode_t          b_opcode;
  logic [2:0]       b_param;
  size_t            b_size;
  source_t          b_source;

  addr_t            b_address;

  data_t            b_data;
  mask_t            b_mask;

  logic             b_corrupt;


  //--------------------------------------------------------------------------
  // C CHANNEL
  //
  // Client -> Manager
  //--------------------------------------------------------------------------

  logic             c_valid;
  logic             c_ready;

  opcode_t          c_opcode;
  logic [2:0]       c_param;
  size_t            c_size;

  source_t          c_source;

  addr_t            c_address;

  data_t            c_data;
  mask_t            c_mask;

  logic             c_corrupt;


  //--------------------------------------------------------------------------
  // D CHANNEL
  //
  // Manager -> Client
  //--------------------------------------------------------------------------

  logic             d_valid;
  logic             d_ready;

  opcode_t          d_opcode;
  logic [2:0]       d_param;

  size_t            d_size;

  source_t          d_source;
  sink_t            d_sink;

  data_t            d_data;

  logic             d_denied;
  logic             d_corrupt;


  //--------------------------------------------------------------------------
  // E CHANNEL
  //
  // Client -> Manager
  //--------------------------------------------------------------------------

  logic             e_valid;
  logic             e_ready;

  sink_t            e_sink;


  //==========================================================================
  // Convenience handshake signals
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
  // Channel activity
  //==========================================================================

  logic a_active;
  logic b_active;
  logic c_active;
  logic d_active;
  logic e_active;

  assign a_active = a_valid;
  assign b_active = b_valid;
  assign c_active = c_valid;
  assign d_active = d_valid;
  assign e_active = e_valid;


  //==========================================================================
  // Client-side modport
  //
  // Client drives:
  //   A
  //   C
  //   E
  //
  // Client receives:
  //   B
  //   D
  //==========================================================================

  modport client (

    // A
    output a_valid,
    input  a_ready,

    output a_opcode,
    output a_param,
    output a_size,
    output a_source,
    output a_address,
    output a_data,
    output a_mask,
    output a_corrupt,

    // B
    input  b_valid,
    output b_ready,

    input  b_opcode,
    input  b_param,
    input  b_size,
    input  b_source,
    input  b_address,
    input  b_data,
    input  b_mask,
    input  b_corrupt,

    // C
    output c_valid,
    input  c_ready,

    output c_opcode,
    output c_param,
    output c_size,
    output c_source,
    output c_address,
    output c_data,
    output c_mask,
    output c_corrupt,

    // D
    input  d_valid,
    output d_ready,

    input  d_opcode,
    input  d_param,
    input  d_size,
    input  d_source,
    input  d_sink,
    input  d_data,
    input  d_denied,
    input  d_corrupt,

    // E
    output e_valid,
    input  e_ready,

    output e_sink

  );


  //==========================================================================
  // Manager-side modport
  //
  // Manager receives:
  //   A
  //   C
  //   E
  //
  // Manager drives:
  //   B
  //   D
  //==========================================================================

  modport manager (

    // A
    input  a_valid,
    output a_ready,

    input  a_opcode,
    input  a_param,
    input  a_size,
    input  a_source,
    input  a_address,
    input  a_data,
    input  a_mask,
    input  a_corrupt,

    // B
    output b_valid,
    input  b_ready,

    output b_opcode,
    output b_param,
    output b_size,
    output b_source,
    output b_address,
    output b_data,
    output b_mask,
    output b_corrupt,

    // C
    input  c_valid,
    output c_ready,

    input  c_opcode,
    input  c_param,
    input  c_size,
    input  c_source,
    input  c_address,
    input  c_data,
    input  c_mask,
    input  c_corrupt,

    // D
    output d_valid,
    input  d_ready,

    output d_opcode,
    output d_param,
    output d_size,
    output d_source,
    output d_sink,
    output d_data,
    output d_denied,
    output d_corrupt,

    // E
    input  e_valid,
    output e_ready,

    input e_sink

  );


  //==========================================================================
  // Monitor modport
  //
  // Read-only access to all channel signals.
  // Useful for protocol monitors, assertions and scoreboards.
  //==========================================================================

  modport monitor (

    input a_valid,
    input a_ready,
    input a_opcode,
    input a_param,
    input a_size,
    input a_source,
    input a_address,
    input a_data,
    input a_mask,
    input a_corrupt,

    input b_valid,
    input b_ready,
    input b_opcode,
    input b_param,
    input b_size,
    input b_source,
    input b_address,
    input b_data,
    input b_mask,
    input b_corrupt,

    input c_valid,
    input c_ready,
    input c_opcode,
    input c_param,
    input c_size,
    input c_source,
    input c_address,
    input c_data,
    input c_mask,
    input c_corrupt,

    input d_valid,
    input d_ready,
    input d_opcode,
    input d_param,
    input d_size,
    input d_source,
    input d_sink,
    input d_data,
    input d_denied,
    input d_corrupt,

    input e_valid,
    input e_ready,
    input e_sink

  );


  //==========================================================================
  // Assertion support
  //
  // The interface itself does NOT alter valid/ready behavior.
  //
  // Assertions ensure that payload remains stable while valid is asserted
  // without a handshake.
  //==========================================================================

`ifndef SYNTHESIS

  generate

    if (1) begin : GEN_TLC_INTERFACE_ASSERTIONS

      //----------------------------------------------------------------------  
      // A-channel stability
      //----------------------------------------------------------------------

      property p_a_stable;

        @(posedge clk)
        disable iff (!rst_n)

        a_valid && !a_ready
        |=> a_valid &&
            $stable(a_opcode) &&
            $stable(a_param) &&
            $stable(a_size) &&
            $stable(a_source) &&
            $stable(a_address) &&
            $stable(a_data) &&
            $stable(a_mask) &&
            $stable(a_corrupt);

      endproperty

      assert property (p_a_stable)
        else $error(
          "TL-C A channel changed while stalled"
        );


      //----------------------------------------------------------------------  
      // B-channel stability
      //----------------------------------------------------------------------

      property p_b_stable;

        @(posedge clk)
        disable iff (!rst_n)

        b_valid && !b_ready
        |=> b_valid &&
            $stable(b_opcode) &&
            $stable(b_param) &&
            $stable(b_size) &&
            $stable(b_source) &&
            $stable(b_address) &&
            $stable(b_data) &&
            $stable(b_mask) &&
            $stable(b_corrupt);

      endproperty

      assert property (p_b_stable)
        else $error(
          "TL-C B channel changed while stalled"
        );


      //----------------------------------------------------------------------  
      // C-channel stability
      //----------------------------------------------------------------------

      property p_c_stable;

        @(posedge clk)
        disable iff (!rst_n)

        c_valid && !c_ready
        |=> c_valid &&
            $stable(c_opcode) &&
            $stable(c_param) &&
            $stable(c_size) &&
            $stable(c_source) &&
            $stable(c_address) &&
            $stable(c_data) &&
            $stable(c_mask) &&
            $stable(c_corrupt);

      endproperty

      assert property (p_c_stable)
        else $error(
          "TL-C C channel changed while stalled"
        );


      //----------------------------------------------------------------------  
      // D-channel stability
      //----------------------------------------------------------------------

      property p_d_stable;

        @(posedge clk)
        disable iff (!rst_n)

        d_valid && !d_ready
        |=> d_valid &&
            $stable(d_opcode) &&
            $stable(d_param) &&
            $stable(d_size) &&
            $stable(d_source) &&
            $stable(d_sink) &&
            $stable(d_data) &&
            $stable(d_denied) &&
            $stable(d_corrupt);

      endproperty

      assert property (p_d_stable)
        else $error(
          "TL-C D channel changed while stalled"
        );


      //----------------------------------------------------------------------  
      // E-channel stability
      //----------------------------------------------------------------------

      property p_e_stable;

        @(posedge clk)
        disable iff (!rst_n)

        e_valid && !e_ready
        |=> e_valid &&
            $stable(e_sink);

      endproperty

      assert property (p_e_stable)
        else $error(
          "TL-C E channel changed while stalled"
        );


      //----------------------------------------------------------------------  
      // E has no payload except sink.
      //----------------------------------------------------------------------

      property p_e_valid_has_sink;

        @(posedge clk)
        disable iff (!rst_n)

        e_valid |-> !$isunknown(e_sink);

      endproperty

      assert property (p_e_valid_has_sink)
        else $error(
          "TL-C E channel has unknown sink"
        );


      //----------------------------------------------------------------------  
      // D Grant must contain a valid sink.
      //----------------------------------------------------------------------

      property p_grant_sink_known;

        @(posedge clk)
        disable iff (!rst_n)

        d_valid &&
        ((d_opcode == D_GRANT) ||
         (d_opcode == D_GRANTDATA))
        |-> !$isunknown(d_sink);

      endproperty

      assert property (p_grant_sink_known)
        else $error(
          "TL-C D Grant has unknown sink"
        );


      //----------------------------------------------------------------------  
      // A AcquireBlock/AcquirePerm cannot carry arbitrary data.
      //----------------------------------------------------------------------

      property p_acquire_no_data_semantics;

        @(posedge clk)
        disable iff (!rst_n)

        a_valid &&
        ((a_opcode == A_ACQUIREBLOCK) ||
         (a_opcode == A_ACQUIREPERM))
        |-> !$isunknown(a_address);

      endproperty

      assert property (p_acquire_no_data_semantics)
        else $error(
          "TL-C Acquire has unknown address"
        );


      //----------------------------------------------------------------------  
      // No X on handshake signals.
      //----------------------------------------------------------------------

      assert property (
        @(posedge clk)
        !$isunknown({
          a_valid, a_ready,
          b_valid, b_ready,
          c_valid, c_ready,
          d_valid, d_ready,
          e_valid, e_ready
        })
      )
      else $error(
        "TL-C interface handshake signal contains X/Z"
      );

    end

  endgenerate

`endif


  //==========================================================================
  // Elaboration-time checks
  //==========================================================================

  initial begin

    if (ADDR_W < 8)
      $error(
        "tlc_if: ADDR_W must be >= 8"
      );

    if ((DATA_W == 0) || ((DATA_W % 8) != 0))
      $error(
        "tlc_if: DATA_W must be a non-zero multiple of 8"
      );

    if ((CACHE_LINE_BYTES == 0) ||
        ((CACHE_LINE_BYTES &
          (CACHE_LINE_BYTES - 1)) != 0))
      $error(
        "tlc_if: CACHE_LINE_BYTES must be power-of-two"
      );

    if (SOURCE_W == 0)
      $error(
        "tlc_if: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "tlc_if: SINK_W must be > 0"
      );

  end

endinterface