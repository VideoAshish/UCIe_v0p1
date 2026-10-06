//==============================================================================
// tlc_top.sv
//
// Production-oriented TileLink-C top-level integration
//
// Channel topology
//
//        Client
//          |
//     +----+----+
//     |         |
//     A         D/E
//     |         |
//     v         ^
// +-------------------+
// |   TL-C Top        |
// |                   |
// | A Channel         |
// | B Channel         |
// | C Channel         |
// | D Channel         |
// | E Channel         |
// |                   |
// | Source Table      |
// | Sink Table        |
// | Txn Table         |
// | Directory         |
// | Permission Mgr    |
// | Probe Engine      |
// | Probe Tracker     |
// | Acquire Engine    |
// | Release Engine    |
// | Grant Engine      |
// | Memory Engine     |
// | Order Engine      |
// | Coherence Engine  |
// | Router/Crossbar   |
// | Error Handler     |
// +-------------------+
//
//==============================================================================

module tlc_top #(

  parameter int unsigned ADDR_W = 48,
  parameter int unsigned DATA_W = 256,
  parameter int unsigned SOURCE_W = 8,
  parameter int unsigned SINK_W = 6,

  parameter int unsigned CACHE_LINE_BYTES = DATA_W / 8,

  parameter int unsigned NUM_SOURCES =
      (1 << SOURCE_W),

  parameter int unsigned NUM_SINKS =
      (1 << SINK_W),

  parameter int unsigned MAX_OUTSTANDING = 256,

  parameter int unsigned MAX_PROBES = 256,

  parameter int unsigned FIFO_DEPTH = 4,

  parameter int unsigned TIMEOUT_CYCLES = 100000,

  parameter bit ENABLE_ASSERTIONS = 1'b1,

  parameter bit ENABLE_TIMEOUT = 1'b1,

  parameter bit ENABLE_ERROR_HANDLER = 1'b1

) (

  input  logic clk,
  input  logic rst_n,


  //==========================================================================
  // CLIENT A CHANNEL
  //==========================================================================

  input  logic a_valid,
  output logic a_ready,

  input  logic [2:0] a_opcode,
  input  logic [2:0] a_param,
  input  logic [2:0] a_size,

  input  logic [SOURCE_W-1:0]
      a_source,

  input  logic [ADDR_W-1:0]
      a_address,

  input  logic [DATA_W-1:0]
      a_data,

  input  logic [DATA_W/8-1:0]
      a_mask,


  //==========================================================================
  // CLIENT B CHANNEL
  //==========================================================================

  output logic b_valid,
  input  logic b_ready,

  output logic [2:0] b_opcode,
  output logic [2:0] b_param,
  output logic [2:0] b_size,

  output logic [SOURCE_W-1:0]
      b_source,

  output logic [SINK_W-1:0]
      b_sink,

  output logic [ADDR_W-1:0]
      b_address,

  output logic [DATA_W-1:0]
      b_data,

  output logic [DATA_W/8-1:0]
      b_mask,


  //==========================================================================
  // CLIENT C CHANNEL
  //==========================================================================

  input logic c_valid,
  output logic c_ready,

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
  // CLIENT D CHANNEL
  //==========================================================================

  output logic d_valid,
  input logic d_ready,

  output logic [2:0] d_opcode,
  output logic [2:0] d_param,
  output logic [2:0] d_size,

  output logic [SOURCE_W-1:0]
      d_source,

  output logic [SINK_W-1:0]
      d_sink,

  output logic [DATA_W-1:0]
      d_data,

  output logic d_denied,
  output logic d_corrupt,


  //==========================================================================
  // CLIENT E CHANNEL
  //==========================================================================

  input logic e_valid,
  output logic e_ready,

  input logic [SINK_W-1:0]
      e_sink,


  //==========================================================================
  // Memory interface
  //==========================================================================

  output logic mem_valid,
  input logic mem_ready,

  output logic mem_write,

  output logic [ADDR_W-1:0]
      mem_address,

  output logic [DATA_W-1:0]
      mem_wdata,

  output logic [DATA_W/8-1:0]
      mem_wmask,

  input logic mem_rvalid,

  input logic [DATA_W-1:0]
      mem_rdata,

  input logic mem_error,


  //==========================================================================
  // Error/status
  //==========================================================================

  output logic error_active,
  output logic fatal_error,
  output logic quarantine,

  output logic [31:0]
      error_status,

  output logic [31:0]
      first_error_code,

  output logic [ADDR_W-1:0]
      first_error_address,

  output logic [SOURCE_W-1:0]
      first_error_source,

  output logic [SINK_W-1:0]
      first_error_sink,

  output logic fatal_interrupt,
  output logic recoverable_interrupt

);


  //==========================================================================
  // Local parameters
  //==========================================================================

  localparam int unsigned BYTE_W =
      DATA_W / 8;

  localparam int unsigned SOURCE_COUNT_W =
      $clog2(MAX_OUTSTANDING + 1);

  localparam int unsigned PROBE_COUNT_W =
      $clog2(MAX_PROBES + 1);


  //==========================================================================
  // Internal A channel
  //==========================================================================

  logic int_a_valid;
  logic int_a_ready;

  logic [2:0] int_a_opcode;
  logic [2:0] int_a_param;
  logic [2:0] int_a_size;

  logic [SOURCE_W-1:0]
      int_a_source;

  logic [ADDR_W-1:0]
      int_a_address;

  logic [DATA_W-1:0]
      int_a_data;

  logic [BYTE_W-1:0]
      int_a_mask;


  //==========================================================================
  // Internal B channel
  //==========================================================================

  logic int_b_valid;
  logic int_b_ready;

  logic [2:0] int_b_opcode;
  logic [2:0] int_b_param;
  logic [2:0] int_b_size;

  logic [SOURCE_W-1:0]
      int_b_source;

  logic [SINK_W-1:0]
      int_b_sink;

  logic [ADDR_W-1:0]
      int_b_address;

  logic [DATA_W-1:0]
      int_b_data;

  logic [BYTE_W-1:0]
      int_b_mask;


  //==========================================================================
  // Internal C channel
  //==========================================================================

  logic int_c_valid;
  logic int_c_ready;

  logic [2:0] int_c_opcode;
  logic [2:0] int_c_param;
  logic [2:0] int_c_size;

  logic [SOURCE_W-1:0]
      int_c_source;

  logic [SINK_W-1:0]
      int_c_sink;

  logic [ADDR_W-1:0]
      int_c_address;

  logic [DATA_W-1:0]
      int_c_data;

  logic [BYTE_W-1:0]
      int_c_mask;


  //==========================================================================
  // Internal D channel
  //==========================================================================

  logic int_d_valid;
  logic int_d_ready;

  logic [2:0] int_d_opcode;
  logic [2:0] int_d_param;
  logic [2:0] int_d_size;

  logic [SOURCE_W-1:0]
      int_d_source;

  logic [SINK_W-1:0]
      int_d_sink;

  logic [DATA_W-1:0]
      int_d_data;

  logic int_d_denied;
  logic int_d_corrupt;


  //==========================================================================
  // Internal E channel
  //==========================================================================

  logic int_e_valid;
  logic int_e_ready;

  logic [SINK_W-1:0]
      int_e_sink;


  //==========================================================================
  // Transaction state
  //==========================================================================

  logic [NUM_SOURCES-1:0]
      source_active;

  logic [NUM_SOURCES-1:0]
      source_acquire;

  logic [NUM_SINKS-1:0]
      sink_active;

  logic [MAX_PROBES-1:0]
      probe_active;

  logic [SOURCE_COUNT_W-1:0]
      outstanding_count;


  //==========================================================================
  // Error signals
  //==========================================================================

  logic error_timeout;
  logic error_protocol;
  logic error_malformed;
  logic error_illegal_opcode;
  logic error_alignment;
  logic error_permission;

  logic error_source;
  logic error_sink;

  logic error_txn_overflow;
  logic error_txn_underflow;

  logic error_probe;
  logic error_grant;
  logic error_release;
  logic error_corrupt;

  logic error_overflow;
  logic error_underflow;


  logic source_table_error;
  logic sink_table_error;
  logic txn_table_error;
  logic probe_tracker_error;

  logic directory_error;
  logic coherence_error;
  logic arbitration_error;
  logic router_error;
  logic crossbar_error;


  //==========================================================================
  // Error context
  //==========================================================================

  logic [ADDR_W-1:0]
      error_address;

  logic [SOURCE_W-1:0]
      error_source;

  logic [SINK_W-1:0]
      error_sink;

  logic [2:0]
      error_opcode;

  logic [2:0]
      error_param;

  logic [2:0]
      error_size;


  logic poison_detected;
  logic denied_response;


  //==========================================================================
  // Quarantine / flush
  //==========================================================================

  logic flush_transactions;
  logic flush_probes;
  logic reset_coherence;

  logic request_recovery;


  //==========================================================================
  //--------------------------------------------------------------------------
  // A CHANNEL
  //--------------------------------------------------------------------------

  tlc_a_channel #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .CACHE_LINE_BYTES   (CACHE_LINE_BYTES),
    .FIFO_DEPTH         (FIFO_DEPTH)

  ) u_a_channel (

    .clk                (clk),
    .rst_n              (rst_n),

    .in_valid           (a_valid),
    .in_ready           (a_ready),

    .in_opcode          (a_opcode),
    .in_param           (a_param),
    .in_size            (a_size),
    .in_source          (a_source),
    .in_address         (a_address),
    .in_data            (a_data),
    .in_mask            (a_mask),

    .out_valid          (int_a_valid),
    .out_ready          (int_a_ready),

    .out_opcode         (int_a_opcode),
    .out_param          (int_a_param),
    .out_size           (int_a_size),
    .out_source         (int_a_source),
    .out_address        (int_a_address),
    .out_data           (int_a_data),
    .out_mask           (int_a_mask),

    .quarantine         (quarantine),
    .flush              (flush_transactions),

    .error_protocol     (error_protocol),
    .error_malformed    (error_malformed),
    .error_alignment    (error_alignment),
    .error_illegal_opcode(error_illegal_opcode)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // B CHANNEL
  //--------------------------------------------------------------------------

  tlc_b_channel #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W),
    .FIFO_DEPTH         (FIFO_DEPTH)

  ) u_b_channel (

    .clk                (clk),
    .rst_n              (rst_n),

    .in_valid           (int_b_valid),
    .in_ready           (int_b_ready),

    .in_opcode          (int_b_opcode),
    .in_param           (int_b_param),
    .in_size            (int_b_size),
    .in_source          (int_b_source),
    .in_sink            (int_b_sink),
    .in_address         (int_b_address),
    .in_data            (int_b_data),
    .in_mask            (int_b_mask),

    .out_valid          (b_valid),
    .out_ready          (b_ready),

    .out_opcode         (b_opcode),
    .out_param          (b_param),
    .out_size           (b_size),
    .out_source         (b_source),
    .out_sink           (b_sink),
    .out_address        (b_address),
    .out_data           (b_data),
    .out_mask           (b_mask),

    .quarantine         (quarantine),
    .flush              (flush_probes),

    .error_protocol     (error_protocol),
    .error_malformed    (error_malformed),
    .error_probe        (error_probe)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // C CHANNEL
  //--------------------------------------------------------------------------

  tlc_c_channel #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W),
    .FIFO_DEPTH         (FIFO_DEPTH)

  ) u_c_channel (

    .clk                (clk),
    .rst_n              (rst_n),

    .in_valid           (c_valid),
    .in_ready           (c_ready),

    .in_opcode          (c_opcode),
    .in_param           (c_param),
    .in_size            (c_size),
    .in_source          (c_source),
    .in_sink            (c_sink),
    .in_address         (c_address),
    .in_data            (c_data),
    .in_mask            (c_mask),

    .out_valid          (int_c_valid),
    .out_ready          (int_c_ready),

    .out_opcode         (int_c_opcode),
    .out_param          (int_c_param),
    .out_size           (int_c_size),
    .out_source         (int_c_source),
    .out_sink           (int_c_sink),
    .out_address        (int_c_address),
    .out_data           (int_c_data),
    .out_mask           (int_c_mask),

    .quarantine         (quarantine),
    .flush              (flush_transactions),

    .error_protocol     (error_protocol),
    .error_malformed    (error_malformed),
    .error_permission   (error_permission)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // D CHANNEL
  //--------------------------------------------------------------------------

  tlc_d_channel #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W),
    .FIFO_DEPTH         (FIFO_DEPTH)

  ) u_d_channel (

    .clk                (clk),
    .rst_n              (rst_n),

    .in_valid           (int_d_valid),
    .in_ready           (int_d_ready),

    .in_opcode          (int_d_opcode),
    .in_param           (int_d_param),
    .in_size            (int_d_size),
    .in_source          (int_d_source),
    .in_sink            (int_d_sink),
    .in_data            (int_d_data),
    .in_denied          (int_d_denied),
    .in_corrupt         (int_d_corrupt),

    .out_valid          (d_valid),
    .out_ready          (d_ready),

    .out_opcode         (d_opcode),
    .out_param          (d_param),
    .out_size           (d_size),
    .out_source         (d_source),
    .out_sink           (d_sink),
    .out_data           (d_data),
    .out_denied         (d_denied),
    .out_corrupt        (d_corrupt),

    .quarantine         (quarantine),
    .flush              (flush_transactions),

    .error_protocol     (error_protocol),
    .error_malformed    (error_malformed),
    .error_corrupt      (error_corrupt)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // E CHANNEL
  //--------------------------------------------------------------------------

  tlc_e_channel #(

    .SINK_W             (SINK_W),
    .FIFO_DEPTH         (FIFO_DEPTH)

  ) u_e_channel (

    .clk                (clk),
    .rst_n              (rst_n),

    .in_valid           (e_valid),
    .in_ready           (e_ready),

    .in_sink            (e_sink),

    .out_valid          (int_e_valid),
    .out_ready          (int_e_ready),

    .out_sink           (int_e_sink),

    .quarantine         (quarantine),
    .flush              (flush_transactions),

    .error_protocol     (error_protocol),
    .error_sink         (error_sink)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // SOURCE TABLE
  //--------------------------------------------------------------------------

  tlc_source_table #(

    .SOURCE_W           (SOURCE_W),
    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .MAX_OUTSTANDING    (MAX_OUTSTANDING)

  ) u_source_table (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),
    .a_opcode           (int_a_opcode),
    .a_source           (int_a_source),
    .a_address          (int_a_address),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),
    .d_source           (int_d_source),
    .d_opcode           (int_d_opcode),

    .source_active      (source_active),
    .source_acquire     (source_acquire),

    .error_source       (error_source),
    .error_overflow     (error_txn_overflow),
    .error_underflow    (error_txn_underflow)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // SINK TABLE
  //--------------------------------------------------------------------------

  tlc_sink_table #(

    .SINK_W             (SINK_W),
    .SOURCE_W           (SOURCE_W),
    .MAX_SINKS          (NUM_SINKS)

  ) u_sink_table (

    .clk                (clk),
    .rst_n              (rst_n),

    .grant_valid        (int_d_valid),
    .grant_ready        (int_d_ready),
    .grant_sink         (int_d_sink),

    .grantack_valid     (int_e_valid),
    .grantack_ready     (int_e_ready),
    .grantack_sink      (int_e_sink),

    .sink_active        (sink_active),

    .error_sink         (error_sink)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // TRANSACTION TABLE
  //--------------------------------------------------------------------------

  tlc_txn_table #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .MAX_ENTRIES        (MAX_OUTSTANDING)

  ) u_txn_table (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),
    .a_opcode           (int_a_opcode),
    .a_source           (int_a_source),
    .a_address          (int_a_address),
    .a_size             (int_a_size),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),
    .d_opcode           (int_d_opcode),
    .d_source           (int_d_source),

    .flush              (flush_transactions),

    .outstanding_count  (outstanding_count),

    .error_overflow     (error_txn_overflow),
    .error_underflow    (error_txn_underflow),
    .error_table        (txn_table_error)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // DIRECTORY
  //--------------------------------------------------------------------------

  tlc_directory #(

    .ADDR_W             (ADDR_W),
    .SOURCE_W           (SOURCE_W),
    .MAX_CLIENTS        (NUM_SOURCES)

  ) u_directory (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),
    .a_source           (int_a_source),
    .a_address          (int_a_address),
    .a_opcode           (int_a_opcode),

    .probe_valid        (int_b_valid),
    .probe_ready        (int_b_ready),

    .probe_source       (int_b_source),
    .probe_address      (int_b_address),

    .error_directory    (directory_error)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // PERMISSION MANAGER
  //--------------------------------------------------------------------------

  tlc_permission_mgr #(

    .SOURCE_W           (SOURCE_W),
    .ADDR_W             (ADDR_W)

  ) u_permission_mgr (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_opcode           (int_a_opcode),
    .a_param            (int_a_param),
    .a_source           (int_a_source),
    .a_address          (int_a_address),

    .c_valid            (int_c_valid),
    .c_opcode           (int_c_opcode),
    .c_param            (int_c_param),
    .c_source           (int_c_source),

    .error_permission   (error_permission)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // PROBE ENGINE
  //--------------------------------------------------------------------------

  tlc_probe_engine #(

    .ADDR_W             (ADDR_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W),
    .MAX_PROBES         (MAX_PROBES)

  ) u_probe_engine (

    .clk                (clk),
    .rst_n              (rst_n),

    .req_valid          (int_a_valid),
    .req_ready          (int_a_ready),

    .req_opcode         (int_a_opcode),
    .req_source         (int_a_source),
    .req_address        (int_a_address),

    .probe_valid        (int_b_valid),
    .probe_ready        (int_b_ready),

    .probe_source       (int_b_source),
    .probe_sink         (int_b_sink),
    .probe_address      (int_b_address),

    .flush              (flush_probes),

    .error_probe        (error_probe)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // PROBE TRACKER
  //--------------------------------------------------------------------------

  tlc_probe_tracker #(

    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W),
    .ADDR_W             (ADDR_W),
    .MAX_PROBES         (MAX_PROBES)

  ) u_probe_tracker (

    .clk                (clk),
    .rst_n              (rst_n),

    .probe_valid        (int_b_valid),
    .probe_ready        (int_b_ready),
    .probe_source       (int_b_source),
    .probe_sink         (int_b_sink),

    .ack_valid          (int_c_valid),
    .ack_ready          (int_c_ready),
    .ack_source         (int_c_source),
    .ack_sink           (int_c_sink),

    .probe_active       (probe_active),

    .flush              (flush_probes),

    .error_probe        (probe_tracker_error)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // ACQUIRE ENGINE
  //--------------------------------------------------------------------------

  tlc_acquire_engine #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W)

  ) u_acquire_engine (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),

    .a_opcode           (int_a_opcode),
    .a_param            (int_a_param),
    .a_size             (int_a_size),
    .a_source           (int_a_source),
    .a_address          (int_a_address),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),

    .d_opcode           (int_d_opcode),
    .d_source           (int_d_source),
    .d_sink             (int_d_sink),
    .d_data             (int_d_data),

    .error_grant        (error_grant)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // RELEASE ENGINE
  //--------------------------------------------------------------------------

  tlc_release_engine #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W)

  ) u_release_engine (

    .clk                (clk),
    .rst_n              (rst_n),

    .c_valid            (int_c_valid),
    .c_ready            (int_c_ready),

    .c_opcode           (int_c_opcode),
    .c_source           (int_c_source),
    .c_sink             (int_c_sink),
    .c_address          (int_c_address),
    .c_data             (int_c_data),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),

    .d_opcode           (int_d_opcode),
    .d_source           (int_d_source),

    .error_release      (error_release)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // GRANT ENGINE
  //--------------------------------------------------------------------------

  tlc_grant_engine #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W)

  ) u_grant_engine (

    .clk                (clk),
    .rst_n              (rst_n),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),

    .d_opcode           (int_d_opcode),
    .d_source           (int_d_source),
    .d_sink             (int_d_sink),
    .d_data             (int_d_data),

    .e_valid            (int_e_valid),
    .e_ready            (int_e_ready),
    .e_sink             (int_e_sink),

    .error_grant        (error_grant)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // MEMORY ENGINE
  //--------------------------------------------------------------------------

  tlc_memory_engine #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W)

  ) u_memory_engine (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),

    .a_opcode           (int_a_opcode),
    .a_size             (int_a_size),
    .a_source           (int_a_source),
    .a_address          (int_a_address),
    .a_data             (int_a_data),
    .a_mask             (int_a_mask),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),

    .d_opcode           (int_d_opcode),
    .d_source           (int_d_source),
    .d_data             (int_d_data),

    .mem_valid          (mem_valid),
    .mem_ready          (mem_ready),
    .mem_write          (mem_write),
    .mem_address        (mem_address),
    .mem_wdata          (mem_wdata),
    .mem_wmask          (mem_wmask),

    .mem_rvalid         (mem_rvalid),
    .mem_rdata          (mem_rdata),
    .mem_error          (mem_error),

    .error_timeout      (error_timeout),
    .error_corrupt      (error_corrupt)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // ORDER ENGINE
  //--------------------------------------------------------------------------

  tlc_order_engine #(

    .SOURCE_W           (SOURCE_W),
    .MAX_OUTSTANDING    (MAX_OUTSTANDING)

  ) u_order_engine (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),
    .a_source           (int_a_source),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),
    .d_source           (int_d_source),

    .outstanding_count  (outstanding_count),

    .error_protocol     (error_protocol)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // COHERENCE ENGINE
  //--------------------------------------------------------------------------

  tlc_coherence_engine #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W)

  ) u_coherence_engine (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),

    .a_opcode           (int_a_opcode),
    .a_param            (int_a_param),
    .a_source           (int_a_source),
    .a_address          (int_a_address),

    .b_valid            (int_b_valid),
    .b_ready            (int_b_ready),

    .b_opcode           (int_b_opcode),
    .b_source           (int_b_source),
    .b_sink             (int_b_sink),
    .b_address          (int_b_address),

    .c_valid            (int_c_valid),
    .c_ready            (int_c_ready),

    .c_opcode           (int_c_opcode),
    .c_source           (int_c_source),
    .c_sink             (int_c_sink),
    .c_address          (int_c_address),
    .c_data             (int_c_data),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),

    .d_opcode           (int_d_opcode),
    .d_source           (int_d_source),
    .d_sink             (int_d_sink),
    .d_data             (int_d_data),

    .e_valid            (int_e_valid),
    .e_ready            (int_e_ready),

    .e_sink             (int_e_sink),

    .reset_coherence    (reset_coherence),

    .error_coherence    (coherence_error)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // ROUTER
  //--------------------------------------------------------------------------

  tlc_router #(

    .ADDR_W             (ADDR_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W)

  ) u_router (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),

    .a_source           (int_a_source),
    .a_address          (int_a_address),

    .b_valid            (int_b_valid),
    .b_ready            (int_b_ready),

    .b_source           (int_b_source),
    .b_address          (int_b_address),

    .c_valid            (int_c_valid),
    .c_ready            (int_c_ready),

    .c_source           (int_c_source),
    .c_address          (int_c_address),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),

    .d_source           (int_d_source),

    .error_router       (router_error)

  );


  //==========================================================================
  //--------------------------------------------------------------------------
  // CROSSBAR
  //--------------------------------------------------------------------------

  tlc_crossbar #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W)

  ) u_crossbar (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),

    .b_valid            (int_b_valid),
    .b_ready            (int_b_ready),

    .c_valid            (int_c_valid),
    .c_ready            (int_c_ready),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),

    .e_valid            (int_e_valid),
    .e_ready            (int_e_ready),

    .error_crossbar     (crossbar_error)

  );


  //==========================================================================
  // ERROR HANDLER
  //==========================================================================

  tlc_error_handler #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W)

  ) u_error_handler (

    .clk                (clk),
    .rst_n              (rst_n),

    .error_timeout      (error_timeout),
    .error_protocol     (error_protocol),
    .error_malformed    (error_malformed),
    .error_illegal_opcode(error_illegal_opcode),
    .error_alignment    (error_alignment),
    .error_permission   (error_permission),

    .error_source       (error_source),
    .error_sink         (error_sink),

    .error_txn_overflow (error_txn_overflow),
    .error_txn_underflow(error_txn_underflow),

    .error_probe        (error_probe),
    .error_grant        (error_grant),
    .error_release      (error_release),
    .error_corrupt      (error_corrupt),

    .error_overflow     (error_overflow),
    .error_underflow    (error_underflow),

    .source_table_error (source_table_error),
    .sink_table_error   (sink_table_error),
    .txn_table_error    (txn_table_error),
    .probe_tracker_error(probe_tracker_error),

    .directory_error    (directory_error),
    .coherence_error    (coherence_error),
    .arbitration_error (arbitration_error),
    .router_error       (router_error),
    .crossbar_error     (crossbar_error),

    .error_address      (error_address),
    .error_source       (error_source),
    .error_sink         (error_sink),
    .error_opcode       (error_opcode),
    .error_param        (error_param),
    .error_size         (error_size),

    .poison_detected    (poison_detected),
    .denied_response    (denied_response),

    .clear_errors       (1'b0),
    .clear_counters     (1'b0),

    .enable_error_handler(
      ENABLE_ERROR_HANDLER
    ),

    .cfg_fatal_timeout  (1'b1),
    .cfg_fatal_protocol (1'b1),
    .cfg_fatal_malformed(1'b1),
    .cfg_fatal_opcode   (1'b1),
    .cfg_fatal_alignment(1'b0),
    .cfg_fatal_permission(1'b1),
    .cfg_fatal_source   (1'b1),
    .cfg_fatal_sink     (1'b1),
    .cfg_fatal_txn      (1'b1),
    .cfg_fatal_probe    (1'b1),
    .cfg_fatal_grant    (1'b1),
    .cfg_fatal_release  (1'b1),
    .cfg_fatal_corrupt  (1'b0),
    .cfg_fatal_overflow (1'b1),
    .cfg_fatal_underflow(1'b1),

    .error_active       (error_active),
    .fatal_error        (fatal_error),
    .quarantine         (quarantine),

    .recoverable_error  (),

    .error_status       (error_status),

    .first_error_code   (first_error_code),
    .first_error_address(first_error_address),
    .first_error_source (first_error_source),
    .first_error_sink   (first_error_sink),

    .first_error_opcode (),
    .first_error_param  (),
    .first_error_size   (),

    .last_error_code    (),
    .last_error_address (),
    .last_error_source  (),
    .last_error_sink    (),
    .last_error_opcode  (),
    .last_error_param   (),
    .last_error_size    (),

    .timeout_count      (),
    .protocol_count     (),
    .malformed_count    (),
    .illegal_opcode_count(),
    .alignment_count    (),
    .permission_count   (),
    .source_count       (),
    .sink_count         (),
    .txn_count          (),
    .probe_count        (),
    .grant_count        (),
    .release_count      (),
    .corrupt_count      (),
    .overflow_count     (),
    .underflow_count    (),

    .block_a            (),
    .block_b            (),
    .block_c            (),
    .block_d            (),
    .block_e            (),

    .flush_transactions (flush_transactions),
    .flush_probes       (flush_probes),
    .reset_coherence    (reset_coherence),

    .request_recovery   (request_recovery),

    .fatal_interrupt    (fatal_interrupt),
    .recoverable_interrupt(
      recoverable_interrupt
    )

  );


  //==========================================================================
  // ASSERTION LAYER
  //==========================================================================

generate

if (ENABLE_ASSERTIONS) begin : GEN_ASSERTIONS

  tlc_assertions #(

    .ADDR_W             (ADDR_W),
    .DATA_W             (DATA_W),
    .SOURCE_W           (SOURCE_W),
    .SINK_W             (SINK_W),
    .CACHE_LINE_BYTES   (CACHE_LINE_BYTES),
    .MAX_OUTSTANDING    (MAX_OUTSTANDING),
    .MAX_PROBES         (MAX_PROBES),
    .TIMEOUT_CYCLES     (TIMEOUT_CYCLES)

  ) u_assertions (

    .clk                (clk),
    .rst_n              (rst_n),

    .a_valid            (int_a_valid),
    .a_ready            (int_a_ready),
    .a_opcode           (int_a_opcode),
    .a_param            (int_a_param),
    .a_size             (int_a_size),
    .a_source           (int_a_source),
    .a_address          (int_a_address),
    .a_data             (int_a_data),
    .a_mask             (int_a_mask),

    .b_valid            (int_b_valid),
    .b_ready            (int_b_ready),
    .b_opcode           (int_b_opcode),
    .b_param            (int_b_param),
    .b_size             (int_b_size),
    .b_source           (int_b_source),
    .b_sink             (int_b_sink),
    .b_address          (int_b_address),
    .b_data             (int_b_data),
    .b_mask             (int_b_mask),

    .c_valid            (int_c_valid),
    .c_ready            (int_c_ready),
    .c_opcode           (int_c_opcode),
    .c_param            (int_c_param),
    .c_size             (int_c_size),
    .c_source           (int_c_source),
    .c_sink             (int_c_sink),
    .c_address          (int_c_address),
    .c_data             (int_c_data),
    .c_mask             (int_c_mask),

    .d_valid            (int_d_valid),
    .d_ready            (int_d_ready),
    .d_opcode           (int_d_opcode),
    .d_param            (int_d_param),
    .d_size             (int_d_size),
    .d_source           (int_d_source),
    .d_sink             (int_d_sink),
    .d_data             (int_d_data),
    .d_denied           (int_d_denied),
    .d_corrupt          (int_d_corrupt),

    .e_valid            (int_e_valid),
    .e_ready            (int_e_ready),
    .e_sink             (int_e_sink),

    .source_active      (source_active),
    .source_acquire     (source_acquire),

    .probe_active       (probe_active),
    .sink_active        (sink_active),

    .outstanding_count  (outstanding_count),

    .assertion_error    ()

  );

end

endgenerate


  //==========================================================================
  // Default error context
  //
  // A production implementation should replace this with an explicit
  // priority encoder from tlc_monitor.
  //==========================================================================

  always_comb begin

    error_address =
        int_a_address;

    error_source =
        int_a_source;

    error_sink =
        int_d_sink;

    error_opcode =
        int_a_opcode;

    error_param =
        int_a_param;

    error_size =
        int_a_size;

    poison_detected =
        int_d_corrupt;

    denied_response =
        int_d_denied;

  end


endmodule