//==============================================================================
// tlc_c2c_bridge.sv
//
// TileLink-C <-> TileLink-C Clock/Domain Bridge
//
// Features
// --------
// * Fully parameterized address/data/source/sink widths
// * Independent A/B/C/D/E channel buffering
// * Ready/valid protocol preservation
// * No combinational ready/valid path between domains
// * Optional source-ID translation
// * Optional sink-ID translation
// * Independent ingress/egress skid buffering
// * Transaction metadata preservation
// * Probe metadata preservation
// * Grant metadata preservation
// * Release metadata preservation
// * Backpressure-safe operation
// * Flush/quarantine support
// * Error propagation
// * Overflow/underflow detection
// * Reset-clean state machines
// * Synthesis-friendly
//
// Architecture
// ------------
//
//             TL-C DOMAIN 0
//
//        A/B/C             D/E
//          |                ^
//          v                |
//    +---------------------------+
//    |       C2C BRIDGE          |
//    |                           |
//    | A FIFO <--------------> A |
//    | B FIFO <--------------> B |
//    | C FIFO <--------------> C |
//    | D FIFO <--------------> D |
//    | E FIFO <--------------> E |
//    |                           |
//    | Source/Sink translation   |
//    | Error/Quarantine          |
//    +---------------------------+
//          |                ^
//          v                |
//        A/B/C             D/E
//
//             TL-C DOMAIN 1
//
//==============================================================================

module tlc_c2c_bridge #(

  parameter int unsigned ADDR_W   = 48,
  parameter int unsigned DATA_W   = 256,
  parameter int unsigned SOURCE_W = 8,
  parameter int unsigned SINK_W   = 6,

  parameter int unsigned FIFO_DEPTH = 4,

  parameter bit ENABLE_SOURCE_TRANSLATION = 1'b0,
  parameter bit ENABLE_SINK_TRANSLATION   = 1'b0,

  parameter int unsigned SOURCE_BASE_0 = 0,
  parameter int unsigned SOURCE_BASE_1 = 0,

  parameter int unsigned SINK_BASE_0 = 0,
  parameter int unsigned SINK_BASE_1 = 0,

  parameter bit ENABLE_QUARANTINE = 1'b1

) (

  input  logic clk,
  input  logic rst_n,


  //==========================================================================
  // DOMAIN 0 - A
  //==========================================================================

  input  logic d0_a_valid,
  output logic d0_a_ready,

  input  logic [2:0] d0_a_opcode,
  input  logic [2:0] d0_a_param,
  input  logic [2:0] d0_a_size,

  input  logic [SOURCE_W-1:0]
      d0_a_source,

  input  logic [ADDR_W-1:0]
      d0_a_address,

  input  logic [DATA_W-1:0]
      d0_a_data,

  input logic [DATA_W/8-1:0]
      d0_a_mask,


  //==========================================================================
  // DOMAIN 0 - B
  //==========================================================================

  output logic d0_b_valid,
  input  logic d0_b_ready,

  output logic [2:0] d0_b_opcode,
  output logic [2:0] d0_b_param,
  output logic [2:0] d0_b_size,

  output logic [SOURCE_W-1:0]
      d0_b_source,

  output logic [SINK_W-1:0]
      d0_b_sink,

  output logic [ADDR_W-1:0]
      d0_b_address,

  output logic [DATA_W-1:0]
      d0_b_data,

  output logic [DATA_W/8-1:0]
      d0_b_mask,


  //==========================================================================
  // DOMAIN 0 - C
  //==========================================================================

  input logic d0_c_valid,
  output logic d0_c_ready,

  input logic [2:0] d0_c_opcode,
  input logic [2:0] d0_c_param,
  input logic [2:0] d0_c_size,

  input logic [SOURCE_W-1:0]
      d0_c_source,

  input logic [SINK_W-1:0]
      d0_c_sink,

  input logic [ADDR_W-1:0]
      d0_c_address,

  input logic [DATA_W-1:0]
      d0_c_data,

  input logic [DATA_W/8-1:0]
      d0_c_mask,


  //==========================================================================
  // DOMAIN 0 - D
  //==========================================================================

  output logic d0_d_valid,
  input logic d0_d_ready,

  output logic [2:0] d0_d_opcode,
  output logic [2:0] d0_d_param,
  output logic [2:0] d0_d_size,

  output logic [SOURCE_W-1:0]
      d0_d_source,

  output logic [SINK_W-1:0]
      d0_d_sink,

  output logic [DATA_W-1:0]
      d0_d_data,

  output logic d0_d_denied,
  output logic d0_d_corrupt,


  //==========================================================================
  // DOMAIN 0 - E
  //==========================================================================

  input logic d0_e_valid,
  output logic d0_e_ready,

  input logic [SINK_W-1:0]
      d0_e_sink,


  //==========================================================================
  // DOMAIN 1 - A
  //==========================================================================

  output logic d1_a_valid,
  input logic d1_a_ready,

  output logic [2:0] d1_a_opcode,
  output logic [2:0] d1_a_param,
  output logic [2:0] d1_a_size,

  output logic [SOURCE_W-1:0]
      d1_a_source,

  output logic [ADDR_W-1:0]
      d1_a_address,

  output logic [DATA_W-1:0]
      d1_a_data,

  output logic [DATA_W/8-1:0]
      d1_a_mask,


  //==========================================================================
  // DOMAIN 1 - B
  //==========================================================================

  input logic d1_b_valid,
  output logic d1_b_ready,

  input logic [2:0] d1_b_opcode,
  input logic [2:0] d1_b_param,
  input logic [2:0] d1_b_size,

  input logic [SOURCE_W-1:0]
      d1_b_source,

  input logic [SINK_W-1:0]
      d1_b_sink,

  input logic [ADDR_W-1:0]
      d1_b_address,

  input logic [DATA_W-1:0]
      d1_b_data,

  input logic [DATA_W/8-1:0]
      d1_b_mask,


  //==========================================================================
  // DOMAIN 1 - C
  //==========================================================================

  output logic d1_c_valid,
  input logic d1_c_ready,

  output logic [2:0] d1_c_opcode,
  output logic [2:0] d1_c_param,
  output logic [2:0] d1_c_size,

  output logic [SOURCE_W-1:0]
      d1_c_source,

  output logic [SINK_W-1:0]
      d1_c_sink,

  output logic [ADDR_W-1:0]
      d1_c_address,

  output logic [DATA_W-1:0]
      d1_c_data,

  output logic [DATA_W/8-1:0]
      d1_c_mask,


  //==========================================================================
  // DOMAIN 1 - D
  //==========================================================================

  input logic d1_d_valid,
  output logic d1_d_ready,

  input logic [2:0] d1_d_opcode,
  input logic [2:0] d1_d_param,
  input logic [2:0] d1_d_size,

  input logic [SOURCE_W-1:0]
      d1_d_source,

  input logic [SINK_W-1:0]
      d1_d_sink,

  input logic [DATA_W-1:0]
      d1_d_data,

  input logic d1_d_denied,
  input logic d1_d_corrupt,


  //==========================================================================
  // DOMAIN 1 - E
  //==========================================================================

  output logic d1_e_valid,
  input logic d1_e_ready,

  output logic [SINK_W-1:0]
      d1_e_sink,


  //==========================================================================
  // Error / fault control
  //==========================================================================

  input logic quarantine,

  input logic flush,

  output logic bridge_error,

  output logic overflow_error,

  output logic underflow_error

);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned PTR_W =
      (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);


  //==========================================================================
  // Payload widths
  //==========================================================================

  localparam int unsigned A_W =
      3 +
      3 +
      3 +
      SOURCE_W +
      ADDR_W +
      DATA_W +
      BYTE_W;

  localparam int unsigned B_W =
      3 +
      3 +
      3 +
      SOURCE_W +
      SINK_W +
      ADDR_W +
      DATA_W +
      BYTE_W;

  localparam int unsigned C_W =
      3 +
      3 +
      3 +
      SOURCE_W +
      SINK_W +
      ADDR_W +
      DATA_W +
      BYTE_W;

  localparam int unsigned D_W =
      3 +
      3 +
      3 +
      SOURCE_W +
      SINK_W +
      DATA_W +
      2;

  localparam int unsigned E_W =
      SINK_W;


  //==========================================================================
  // Payload structures
  //==========================================================================

  typedef struct packed {

    logic [2:0]
        opcode;

    logic [2:0]
        param;

    logic [2:0]
        size;

    logic [SOURCE_W-1:0]
        source;

    logic [ADDR_W-1:0]
        address;

    logic [DATA_W-1:0]
        data;

    logic [BYTE_W-1:0]
        mask;

  } a_payload_t;


  typedef struct packed {

    logic [2:0]
        opcode;

    logic [2:0]
        param;

    logic [2:0]
        size;

    logic [SOURCE_W-1:0]
        source;

    logic [SINK_W-1:0]
        sink;

    logic [ADDR_W-1:0]
        address;

    logic [DATA_W-1:0]
        data;

    logic [BYTE_W-1:0]
        mask;

  } b_payload_t;


  typedef struct packed {

    logic [2:0]
        opcode;

    logic [2:0]
        param;

    logic [2:0]
        size;

    logic [SOURCE_W-1:0]
        source;

    logic [SINK_W-1:0]
        sink;

    logic [ADDR_W-1:0]
        address;

    logic [DATA_W-1:0]
        data;

    logic [BYTE_W-1:0]
        mask;

  } c_payload_t;


  typedef struct packed {

    logic [2:0]
        opcode;

    logic [2:0]
        param;

    logic [2:0]
        size;

    logic [SOURCE_W-1:0]
        source;

    logic [SINK_W-1:0]
        sink;

    logic [DATA_W-1:0]
        data;

    logic denied;

    logic corrupt;

  } d_payload_t;


  typedef struct packed {

    logic [SINK_W-1:0]
        sink;

  } e_payload_t;


  //==========================================================================
  // FIFO storage
  //==========================================================================

  a_payload_t a_fifo [0:FIFO_DEPTH-1];
  b_payload_t b_fifo [0:FIFO_DEPTH-1];
  c_payload_t c_fifo [0:FIFO_DEPTH-1];
  d_payload_t d_fifo [0:FIFO_DEPTH-1];
  e_payload_t e_fifo [0:FIFO_DEPTH-1];


  logic [PTR_W-1:0]
      a_wr_ptr,
      a_rd_ptr;

  logic [PTR_W-1:0]
      b_wr_ptr,
      b_rd_ptr;

  logic [PTR_W-1:0]
      c_wr_ptr,
      c_rd_ptr;

  logic [PTR_W-1:0]
      d_wr_ptr,
      d_rd_ptr;

  logic [PTR_W-1:0]
      e_wr_ptr,
      e_rd_ptr;


  logic [PTR_W:0]
      a_count,
      b_count,
      c_count,
      d_count,
      e_count;


  //==========================================================================
  // Handshakes
  //==========================================================================

  logic a_in_fire;
  logic a_out_fire;

  logic b_in_fire;
  logic b_out_fire;

  logic c_in_fire;
  logic c_out_fire;

  logic d_in_fire;
  logic d_out_fire;

  logic e_in_fire;
  logic e_out_fire;


  assign a_in_fire =
      d0_a_valid &&
      d0_a_ready;

  assign a_out_fire =
      d1_a_valid &&
      d1_a_ready;


  assign b_in_fire =
      d1_b_valid &&
      d1_b_ready;

  assign b_out_fire =
      d0_b_valid &&
      d0_b_ready;


  assign c_in_fire =
      d0_c_valid &&
      d0_c_ready;

  assign c_out_fire =
      d1_c_valid &&
      d1_c_ready;


  assign d_in_fire =
      d1_d_valid &&
      d1_d_ready;

  assign d_out_fire =
      d0_d_valid &&
      d0_d_ready;


  assign e_in_fire =
      d0_e_valid &&
      d0_e_ready;

  assign e_out_fire =
      d1_e_valid &&
      d1_e_ready;


  //==========================================================================
  // Source translation
  //==========================================================================

  function automatic logic [SOURCE_W-1:0]
  translate_source_0_to_1(
    input logic [SOURCE_W-1:0] source
  );

    if (ENABLE_SOURCE_TRANSLATION)

      translate_source_0_to_1 =
          source +
          SOURCE_BASE_1 -
          SOURCE_BASE_0;

    else

      translate_source_0_to_1 =
          source;

  endfunction


  function automatic logic [SOURCE_W-1:0]
  translate_source_1_to_0(
    input logic [SOURCE_W-1:0] source
  );

    if (ENABLE_SOURCE_TRANSLATION)

      translate_source_1_to_0 =
          source +
          SOURCE_BASE_0 -
          SOURCE_BASE_1;

    else

      translate_source_1_to_0 =
          source;

  endfunction


  //==========================================================================
  // Sink translation
  //==========================================================================

  function automatic logic [SINK_W-1:0]
  translate_sink_0_to_1(
    input logic [SINK_W-1:0] sink
  );

    if (ENABLE_SINK_TRANSLATION)

      translate_sink_0_to_1 =
          sink +
          SINK_BASE_1 -
          SINK_BASE_0;

    else

      translate_sink_0_to_1 =
          sink;

  endfunction


  function automatic logic [SINK_W-1:0]
  translate_sink_1_to_0(
    input logic [SINK_W-1:0] sink
  );

    if (ENABLE_SINK_TRANSLATION)

      translate_sink_1_to_0 =
          sink +
          SINK_BASE_0 -
          SINK_BASE_1;

    else

      translate_sink_1_to_0 =
          sink;

  endfunction


  //==========================================================================
  // INPUT READY
  //
  // The bridge uses registered FIFO occupancy. There is no combinational
  // ready path from one TL-C domain to the opposite domain.
  //==========================================================================

  always_comb begin

    d0_a_ready =
        (a_count < FIFO_DEPTH) &&
        !quarantine &&
        !flush;

    d1_b_ready =
        (b_count < FIFO_DEPTH) &&
        !quarantine &&
        !flush;

    d0_c_ready =
        (c_count < FIFO_DEPTH) &&
        !quarantine &&
        !flush;

    d1_d_ready =
        (d_count < FIFO_DEPTH) &&
        !quarantine &&
        !flush;

    d0_e_ready =
        (e_count < FIFO_DEPTH) &&
        !quarantine &&
        !flush;

  end


  //==========================================================================
  // OUTPUT VALID
  //==========================================================================

  always_comb begin

    d1_a_valid =
        (a_count != 0) &&
        !quarantine &&
        !flush;

    d0_b_valid =
        (b_count != 0) &&
        !quarantine &&
        !flush;

    d1_c_valid =
        (c_count != 0) &&
        !quarantine &&
        !flush;

    d0_d_valid =
        (d_count != 0) &&
        !quarantine &&
        !flush;

    d1_e_valid =
        (e_count != 0) &&
        !quarantine &&
        !flush;

  end


  //==========================================================================
  // A channel FIFO
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      a_wr_ptr <= '0;
      a_rd_ptr <= '0;
      a_count  <= '0;

    end
    else if (flush) begin

      a_wr_ptr <= '0;
      a_rd_ptr <= '0;
      a_count  <= '0;

    end
    else begin

      if (a_in_fire) begin

        a_fifo[a_wr_ptr].opcode  <= d0_a_opcode;
        a_fifo[a_wr_ptr].param   <= d0_a_param;
        a_fifo[a_wr_ptr].size    <= d0_a_size;

        a_fifo[a_wr_ptr].source  <=
            translate_source_0_to_1(
              d0_a_source
            );

        a_fifo[a_wr_ptr].address <=
            d0_a_address;

        a_fifo[a_wr_ptr].data    <=
            d0_a_data;

        a_fifo[a_wr_ptr].mask    <=
            d0_a_mask;

        if (a_wr_ptr == FIFO_DEPTH-1)
          a_wr_ptr <= '0;
        else
          a_wr_ptr <= a_wr_ptr + 1'b1;

      end


      if (a_out_fire) begin

        if (a_rd_ptr == FIFO_DEPTH-1)
          a_rd_ptr <= '0;
        else
          a_rd_ptr <= a_rd_ptr + 1'b1;

      end


      case ({
        a_in_fire,
        a_out_fire
      })

        2'b10:
          a_count <= a_count + 1'b1;

        2'b01:
          a_count <= a_count - 1'b1;

        default:
          a_count <= a_count;

      endcase

    end

  end


  //==========================================================================
  // A channel output
  //==========================================================================

  always_comb begin

    d1_a_opcode  = a_fifo[a_rd_ptr].opcode;
    d1_a_param   = a_fifo[a_rd_ptr].param;
    d1_a_size    = a_fifo[a_rd_ptr].size;
    d1_a_source  = a_fifo[a_rd_ptr].source;
    d1_a_address = a_fifo[a_rd_ptr].address;
    d1_a_data    = a_fifo[a_rd_ptr].data;
    d1_a_mask    = a_fifo[a_rd_ptr].mask;

  end


  //==========================================================================
  // B channel FIFO
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      b_wr_ptr <= '0;
      b_rd_ptr <= '0;
      b_count  <= '0;

    end
    else if (flush) begin

      b_wr_ptr <= '0;
      b_rd_ptr <= '0;
      b_count  <= '0;

    end
    else begin

      if (b_in_fire) begin

        b_fifo[b_wr_ptr].opcode  <= d1_b_opcode;
        b_fifo[b_wr_ptr].param   <= d1_b_param;
        b_fifo[b_wr_ptr].size    <= d1_b_size;

        b_fifo[b_wr_ptr].source  <=
            translate_source_1_to_0(
              d1_b_source
            );

        b_fifo[b_wr_ptr].sink <=
            translate_sink_1_to_0(
              d1_b_sink
            );

        b_fifo[b_wr_ptr].address <=
            d1_b_address;

        b_fifo[b_wr_ptr].data <=
            d1_b_data;

        b_fifo[b_wr_ptr].mask <=
            d1_b_mask;

        if (b_wr_ptr == FIFO_DEPTH-1)
          b_wr_ptr <= '0;
        else
          b_wr_ptr <= b_wr_ptr + 1'b1;

      end


      if (b_out_fire) begin

        if (b_rd_ptr == FIFO_DEPTH-1)
          b_rd_ptr <= '0;
        else
          b_rd_ptr <= b_rd_ptr + 1'b1;

      end


      case ({
        b_in_fire,
        b_out_fire
      })

        2'b10:
          b_count <= b_count + 1'b1;

        2'b01:
          b_count <= b_count - 1'b1;

        default:
          b_count <= b_count;

      endcase

    end

  end


  always_comb begin

    d0_b_opcode  = b_fifo[b_rd_ptr].opcode;
    d0_b_param   = b_fifo[b_rd_ptr].param;
    d0_b_size    = b_fifo[b_rd_ptr].size;
    d0_b_source  = b_fifo[b_rd_ptr].source;
    d0_b_sink    = b_fifo[b_rd_ptr].sink;
    d0_b_address = b_fifo[b_rd_ptr].address;
    d0_b_data    = b_fifo[b_rd_ptr].data;
    d0_b_mask    = b_fifo[b_rd_ptr].mask;

  end


  //==========================================================================
  // C channel FIFO
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      c_wr_ptr <= '0;
      c_rd_ptr <= '0;
      c_count  <= '0;

    end
    else if (flush) begin

      c_wr_ptr <= '0;
      c_rd_ptr <= '0;
      c_count  <= '0;

    end
    else begin

      if (c_in_fire) begin

        c_fifo[c_wr_ptr].opcode <= d0_c_opcode;
        c_fifo[c_wr_ptr].param  <= d0_c_param;
        c_fifo[c_wr_ptr].size   <= d0_c_size;

        c_fifo[c_wr_ptr].source <=
            translate_source_0_to_1(
              d0_c_source
            );

        c_fifo[c_wr_ptr].sink <=
            translate_sink_0_to_1(
              d0_c_sink
            );

        c_fifo[c_wr_ptr].address <=
            d0_c_address;

        c_fifo[c_wr_ptr].data <=
            d0_c_data;

        c_fifo[c_wr_ptr].mask <=
            d0_c_mask;

        if (c_wr_ptr == FIFO_DEPTH-1)
          c_wr_ptr <= '0;
        else
          c_wr_ptr <= c_wr_ptr + 1'b1;

      end


      if (c_out_fire) begin

        if (c_rd_ptr == FIFO_DEPTH-1)
          c_rd_ptr <= '0;
        else
          c_rd_ptr <= c_rd_ptr + 1'b1;

      end


      case ({
        c_in_fire,
        c_out_fire
      })

        2'b10:
          c_count <= c_count + 1'b1;

        2'b01:
          c_count <= c_count - 1'b1;

        default:
          c_count <= c_count;

      endcase

    end

  end


  always_comb begin

    d1_c_opcode  = c_fifo[c_rd_ptr].opcode;
    d1_c_param   = c_fifo[c_rd_ptr].param;
    d1_c_size    = c_fifo[c_rd_ptr].size;
    d1_c_source  = c_fifo[c_rd_ptr].source;
    d1_c_sink    = c_fifo[c_rd_ptr].sink;
    d1_c_address = c_fifo[c_rd_ptr].address;
    d1_c_data    = c_fifo[c_rd_ptr].data;
    d1_c_mask    = c_fifo[c_rd_ptr].mask;

  end


  //==========================================================================
  // D channel FIFO
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      d_wr_ptr <= '0;
      d_rd_ptr <= '0;
      d_count  <= '0;

    end
    else if (flush) begin

      d_wr_ptr <= '0;
      d_rd_ptr <= '0;
      d_count  <= '0;

    end
    else begin

      if (d_in_fire) begin

        d_fifo[d_wr_ptr].opcode <= d1_d_opcode;
        d_fifo[d_wr_ptr].param  <= d1_d_param;
        d_fifo[d_wr_ptr].size   <= d1_d_size;

        d_fifo[d_wr_ptr].source <=
            translate_source_1_to_0(
              d1_d_source
            );

        d_fifo[d_wr_ptr].sink <=
            translate_sink_1_to_0(
              d1_d_sink
            );

        d_fifo[d_wr_ptr].data <=
            d1_d_data;

        d_fifo[d_wr_ptr].denied <=
            d1_d_denied;

        d_fifo[d_wr_ptr].corrupt <=
            d1_d_corrupt;

        if (d_wr_ptr == FIFO_DEPTH-1)
          d_wr_ptr <= '0;
        else
          d_wr_ptr <= d_wr_ptr + 1'b1;

      end


      if (d_out_fire) begin

        if (d_rd_ptr == FIFO_DEPTH-1)
          d_rd_ptr <= '0;
        else
          d_rd_ptr <= d_rd_ptr + 1'b1;

      end


      case ({
        d_in_fire,
        d_out_fire
      })

        2'b10:
          d_count <= d_count + 1'b1;

        2'b01:
          d_count <= d_count - 1'b1;

        default:
          d_count <= d_count;

      endcase

    end

  end


  always_comb begin

    d0_d_opcode  = d_fifo[d_rd_ptr].opcode;
    d0_d_param   = d_fifo[d_rd_ptr].param;
    d0_d_size    = d_fifo[d_rd_ptr].size;
    d0_d_source  = d_fifo[d_rd_ptr].source;
    d0_d_sink    = d_fifo[d_rd_ptr].sink;
    d0_d_data    = d_fifo[d_rd_ptr].data;
    d0_d_denied  = d_fifo[d_rd_ptr].denied;
    d0_d_corrupt = d_fifo[d_rd_ptr].corrupt;

  end


  //==========================================================================
  // E channel FIFO
  //==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      e_wr_ptr <= '0;
      e_rd_ptr <= '0;
      e_count  <= '0;

    end
    else if (flush) begin

      e_wr_ptr <= '0;
      e_rd_ptr <= '0;
      e_count  <= '0;

    end
    else begin

      if (e_in_fire) begin

        e_fifo[e_wr_ptr].sink <=
            translate_sink_0_to_1(
              d0_e_sink
            );

        if (e_wr_ptr == FIFO_DEPTH-1)
          e_wr_ptr <= '0;
        else
          e_wr_ptr <= e_wr_ptr + 1'b1;

      end


      if (e_out_fire) begin

        if (e_rd_ptr == FIFO_DEPTH-1)
          e_rd_ptr <= '0;
        else
          e_rd_ptr <= e_rd_ptr + 1'b1;

      end


      case ({
        e_in_fire,
        e_out_fire
      })

        2'b10:
          e_count <= e_count + 1'b1;

        2'b01:
          e_count <= e_count - 1'b1;

        default:
          e_count <= e_count;

      endcase

    end

  end


  always_comb begin

    d1_e_sink =
        e_fifo[e_rd_ptr].sink;

  end


  //==========================================================================
  // Error detection
  //==========================================================================

  always_comb begin

    overflow_error =
        (a_count > FIFO_DEPTH) ||
        (b_count > FIFO_DEPTH) ||
        (c_count > FIFO_DEPTH) ||
        (d_count > FIFO_DEPTH) ||
        (e_count > FIFO_DEPTH);


    underflow_error =
        (
          a_out_fire &&
          (a_count == 0)
        ) ||
        (
          b_out_fire &&
          (b_count == 0)
        ) ||
        (
          c_out_fire &&
          (c_count == 0)
        ) ||
        (
          d_out_fire &&
          (d_count == 0)
        ) ||
        (
          e_out_fire &&
          (e_count == 0)
        );


    bridge_error =
        overflow_error ||
        underflow_error;

  end


  //==========================================================================
  // Assertions
  //==========================================================================

`ifndef SYNTHESIS

  //---------------------------------------------------------------------------
  // FIFO count bounds
  //---------------------------------------------------------------------------

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    a_count <= FIFO_DEPTH
  )
  else
    $error(
      "TLC_C2C: A FIFO overflow"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    b_count <= FIFO_DEPTH
  )
  else
    $error(
      "TLC_C2C: B FIFO overflow"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    c_count <= FIFO_DEPTH
  )
  else
    $error(
      "TLC_C2C: C FIFO overflow"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d_count <= FIFO_DEPTH
  )
  else
    $error(
      "TLC_C2C: D FIFO overflow"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    e_count <= FIFO_DEPTH
  )
  else
    $error(
      "TLC_C2C: E FIFO overflow"
    );


  //---------------------------------------------------------------------------
  // Output stability under backpressure
  //---------------------------------------------------------------------------

  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d1_a_valid &&
    !d1_a_ready
    |=>

    $stable({
      d1_a_opcode,
      d1_a_param,
      d1_a_size,
      d1_a_source,
      d1_a_address,
      d1_a_data,
      d1_a_mask
    })
  )
  else
    $error(
      "TLC_C2C: A payload changed while stalled"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d0_b_valid &&
    !d0_b_ready
    |=>

    $stable({
      d0_b_opcode,
      d0_b_param,
      d0_b_size,
      d0_b_source,
      d0_b_sink,
      d0_b_address,
      d0_b_data,
      d0_b_mask
    })
  )
  else
    $error(
      "TLC_C2C: B payload changed while stalled"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d1_c_valid &&
    !d1_c_ready
    |=>

    $stable({
      d1_c_opcode,
      d1_c_param,
      d1_c_size,
      d1_c_source,
      d1_c_sink,
      d1_c_address,
      d1_c_data,
      d1_c_mask
    })
  )
  else
    $error(
      "TLC_C2C: C payload changed while stalled"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d0_d_valid &&
    !d0_d_ready
    |=>

    $stable({
      d0_d_opcode,
      d0_d_param,
      d0_d_size,
      d0_d_source,
      d0_d_sink,
      d0_d_data,
      d0_d_denied,
      d0_d_corrupt
    })
  )
  else
    $error(
      "TLC_C2C: D payload changed while stalled"
    );


  assert property (
    @(posedge clk)
    disable iff (!rst_n)

    d1_e_valid &&
    !d1_e_ready
    |=>

    $stable(d1_e_sink)
  )
  else
    $error(
      "TLC_C2C: E payload changed while stalled"
    );


  //---------------------------------------------------------------------------
  // Quarantine must stop new traffic.
  //---------------------------------------------------------------------------

  if (ENABLE_QUARANTINE) begin

    assert property (
      @(posedge clk)
      disable iff (!rst_n)

      quarantine
      |->
      !d0_a_ready &&
      !d1_b_ready &&
      !d0_c_ready &&
      !d1_d_ready &&
      !d0_e_ready
    )
    else
      $error(
        "TLC_C2C: quarantine did not block ingress"
      );

  end


`endif


  //==========================================================================
  // Parameter validation
  //==========================================================================

  initial begin

    if (DATA_W == 0)
      $error(
        "TLC_C2C: DATA_W must be > 0"
      );

    if ((DATA_W % 8) != 0)
      $error(
        "TLC_C2C: DATA_W must be byte aligned"
      );

    if (ADDR_W == 0)
      $error(
        "TLC_C2C: ADDR_W must be > 0"
      );

    if (SOURCE_W == 0)
      $error(
        "TLC_C2C: SOURCE_W must be > 0"
      );

    if (SINK_W == 0)
      $error(
        "TLC_C2C: SINK_W must be > 0"
      );

    if (FIFO_DEPTH < 2)
      $warning(
        "TLC_C2C: FIFO_DEPTH < 2; consider using at least 2 entries"
      );

  end

endmodule