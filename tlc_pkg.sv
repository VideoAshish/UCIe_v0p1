//==============================================================================
// tlc_pkg.sv
//
// Production-oriented TileLink coherent (TL-C) package.
//
// Scope
//   - Parameter/configuration definitions
//   - Channel opcode definitions
//   - TL-C permission/param definitions
//   - Coherence state definitions
//   - Common transaction/state types
//   - Width/helper functions
//   - Opcode classification helpers
//   - Alignment / mask helpers
//
// Intended use
//   tlc_directory.sv
//   tlc_acquire_engine.sv
//   tlc_probe_engine.sv
//   tlc_probe_tracker.sv
//   tlc_release_engine.sv
//   tlc_grant_engine.sv
//   tlc_source_table.sv
//   tlc_sink_table.sv
//   tlc_monitor.sv
//
// Notes
//   * Parameters are package defaults. Individual modules should expose
//     parameters and use these values as defaults.
//   * TL-C channel fields are intentionally represented explicitly.
//   * No dynamic allocation or unsynthesizable data structures are used.
//==============================================================================

package tlc_pkg;

  //===========================================================================
  // Global defaults
  //===========================================================================

  parameter int unsigned TL_DEFAULT_ADDR_W          = 48;
  parameter int unsigned TL_DEFAULT_DATA_W          = 256;
  parameter int unsigned TL_DEFAULT_SOURCE_W        = 8;
  parameter int unsigned TL_DEFAULT_SINK_W          = 6;

  parameter int unsigned TL_DEFAULT_CACHE_LINE_BYTES = 64;

  parameter int unsigned TL_DEFAULT_CLIENTS         = 8;
  parameter int unsigned TL_DEFAULT_OUTSTANDING     = 64;

  parameter bit TL_ENABLE_ASSERTIONS                = 1'b1;
  parameter bit TL_ENABLE_TIMEOUTS                  = 1'b1;

  //===========================================================================
  // Generic width helpers
  //===========================================================================

  function automatic int unsigned max2(
    input int unsigned a,
    input int unsigned b
  );
    return (a > b) ? a : b;
  endfunction


  function automatic int unsigned clog2_safe(
    input int unsigned value
  );
    if (value <= 1)
      return 1;
    else
      return $clog2(value);
  endfunction


  function automatic bit is_power_of_two(
    input int unsigned value
  );
    return (value != 0) &&
           ((value & (value - 1)) == 0);
  endfunction


  function automatic int unsigned log2_pow2(
    input int unsigned value
  );
    if (!is_power_of_two(value))
      return 0;

    return $clog2(value);
  endfunction


  //===========================================================================
  // TL parameter widths
  //===========================================================================

  // TileLink size is encoded as log2(bytes).
  //
  // Example:
  //   size = 0 -> 1 byte
  //   size = 1 -> 2 bytes
  //   size = 2 -> 4 bytes
  //   size = 3 -> 8 bytes
  //   ...
  //
  function automatic int unsigned size_width(
    input int unsigned data_width
  );
    return clog2_safe((data_width / 8) + 1);
  endfunction


  //===========================================================================
  // Default derived types
  //===========================================================================

  localparam int unsigned TL_DEFAULT_BYTE_W =
      TL_DEFAULT_DATA_W / 8;

  localparam int unsigned TL_DEFAULT_SIZE_W =
      clog2_safe(TL_DEFAULT_BYTE_W + 1);

  typedef logic [TL_DEFAULT_ADDR_W-1:0]
      tl_addr_t;

  typedef logic [TL_DEFAULT_DATA_W-1:0]
      tl_data_t;

  typedef logic [TL_DEFAULT_BYTE_W-1:0]
      tl_mask_t;

  typedef logic [TL_DEFAULT_SOURCE_W-1:0]
      tl_source_t;

  typedef logic [TL_DEFAULT_SINK_W-1:0]
      tl_sink_t;

  typedef logic [TL_DEFAULT_SIZE_W-1:0]
      tl_size_t;


  //===========================================================================
  // Channel identifiers
  //===========================================================================

  typedef enum logic [2:0] {

    TL_CH_A = 3'd0,
    TL_CH_B = 3'd1,
    TL_CH_C = 3'd2,
    TL_CH_D = 3'd3,
    TL_CH_E = 3'd4

  } tl_channel_e;


  //===========================================================================
  // A-channel opcodes
  //
  // TL-UL operations occupy the lower opcode range.
  // TL-C adds AcquireBlock and AcquirePerm.
  //===========================================================================

  typedef enum logic [2:0] {

    TL_A_PUTFULL      = 3'd0,
    TL_A_PUTPARTIAL   = 3'd1,
    TL_A_ARITHMETIC   = 3'd2,
    TL_A_LOGICAL      = 3'd3,
    TL_A_GET          = 3'd4,
    TL_A_HINT         = 3'd5,
    TL_A_ACQUIREBLOCK = 3'd6,
    TL_A_ACQUIREPERM  = 3'd7

  } tl_a_opcode_e;


  //===========================================================================
  // B-channel opcodes
  //
  // B is manager -> client.
  //===========================================================================

  typedef enum logic [2:0] {

    TL_B_PUTFULL      = 3'd0,
    TL_B_PUTPARTIAL   = 3'd1,
    TL_B_ARITHMETIC   = 3'd2,
    TL_B_LOGICAL      = 3'd3,
    TL_B_GET          = 3'd4,
    TL_B_HINT         = 3'd5,
    TL_B_PROBE        = 3'd6,
    TL_B_RESERVED     = 3'd7

  } tl_b_opcode_e;


  //===========================================================================
  // C-channel opcodes
  //===========================================================================

  typedef enum logic [2:0] {

    TL_C_PROBEACK       = 3'd4,
    TL_C_PROBEACKDATA   = 3'd5,
    TL_C_RELEASE        = 3'd6,
    TL_C_RELEASEDATA    = 3'd7

  } tl_c_opcode_e;


  //===========================================================================
  // D-channel opcodes
  //===========================================================================

  typedef enum logic [2:0] {

    TL_D_ACCESSACK      = 3'd0,
    TL_D_ACCESSACKDATA  = 3'd1,
    TL_D_HINTACK        = 3'd2,

    TL_D_RESERVED3      = 3'd3,

    TL_D_GRANT          = 3'd4,
    TL_D_GRANTDATA      = 3'd5,
    TL_D_RELEASEACK     = 3'd6,

    TL_D_RESERVED7      = 3'd7

  } tl_d_opcode_e;


  //===========================================================================
  // E-channel opcode
  //===========================================================================

  typedef enum logic [2:0] {

    TL_E_GRANTACK       = 3'd0

  } tl_e_opcode_e;


  //===========================================================================
  // Acquire param
  //
  // grow:
  //
  //   00 = N
  //   01 = B
  //   10 = T
  //===========================================================================

  typedef enum logic [1:0] {

    TL_GROW_N = 2'b00,
    TL_GROW_B = 2'b01,
    TL_GROW_T = 2'b10

  } tl_grow_e;


  //===========================================================================
  // Probe param
  //
  // cap:
  //
  //   00 = N
  //   01 = B
  //   10 = T
  //===========================================================================

  typedef enum logic [1:0] {

    TL_CAP_N = 2'b00,
    TL_CAP_B = 2'b01,
    TL_CAP_T = 2'b10

  } tl_cap_e;


  //===========================================================================
  // Report permission
  //===========================================================================

  typedef enum logic [1:0] {

    TL_REPORT_T = 2'b00,
    TL_REPORT_B = 2'b01,
    TL_REPORT_N = 2'b10

  } tl_report_e;


  //===========================================================================
  // Release param
  //===========================================================================

  typedef enum logic [2:0] {

    TL_RELEASE_N = 3'b000,
    TL_RELEASE_B = 3'b001,
    TL_RELEASE_T = 3'b010

  } tl_release_e;


  //===========================================================================
  // Arithmetic operation
  //===========================================================================

  typedef enum logic [2:0] {

    TL_ARITH_MIN     = 3'd0,
    TL_ARITH_MAX     = 3'd1,
    TL_ARITH_MINU    = 3'd2,
    TL_ARITH_MAXU    = 3'd3,
    TL_ARITH_ADD     = 3'd4,
    TL_ARITH_RESERVED5 = 3'd5,
    TL_ARITH_RESERVED6 = 3'd6,
    TL_ARITH_RESERVED7 = 3'd7

  } tl_arithmetic_e;


  //===========================================================================
  // Logical operation
  //===========================================================================

  typedef enum logic [2:0] {

    TL_LOGIC_XOR     = 3'd0,
    TL_LOGIC_OR      = 3'd1,
    TL_LOGIC_AND     = 3'd2,
    TL_LOGIC_SWAP    = 3'd3,
    TL_LOGIC_RESERVED4 = 3'd4,
    TL_LOGIC_RESERVED5 = 3'd5,
    TL_LOGIC_RESERVED6 = 3'd6,
    TL_LOGIC_RESERVED7 = 3'd7

  } tl_logical_e;


  //===========================================================================
  // Directory coherence state
  //
  // This is an implementation-level state machine.
  //
  // I = Invalid
  // S = Shared
  // E = Exclusive
  // M = Modified
  //
  // TL-C itself describes permissions/transitions; a concrete cache/directory
  // implementation may use a richer internal state machine.
  //===========================================================================

  typedef enum logic [2:0] {

    TL_DIR_I = 3'd0,
    TL_DIR_S = 3'd1,
    TL_DIR_E = 3'd2,
    TL_DIR_M = 3'd3,

    // Transient states.
    TL_DIR_IS = 3'd4,
    TL_DIR_IM = 3'd5,
    TL_DIR_SM = 3'd6,
    TL_DIR_MI = 3'd7

  } tl_dir_state_e;


  //===========================================================================
  // Client permission state
  //===========================================================================

  typedef enum logic [1:0] {

    TL_PERM_NONE = 2'b00,
    TL_PERM_B    = 2'b01,
    TL_PERM_T    = 2'b10

  } tl_permission_e;


  //===========================================================================
  // Generic transaction state
  //===========================================================================

  typedef enum logic [3:0] {

    TL_TXN_FREE            = 4'd0,

    TL_TXN_A_RECEIVED      = 4'd1,
    TL_TXN_WAIT_PROBE      = 4'd2,
    TL_TXN_PROBE_ACTIVE    = 4'd3,
    TL_TXN_WAIT_RELEASE    = 4'd4,
    TL_TXN_WAIT_MEMORY     = 4'd5,
    TL_TXN_WAIT_GRANT      = 4'd6,
    TL_TXN_GRANT_SENT      = 4'd7,
    TL_TXN_WAIT_GRANTACK   = 4'd8,
    TL_TXN_COMPLETE        = 4'd9,

    TL_TXN_ERROR           = 4'd15

  } tl_txn_state_e;


  //===========================================================================
  // Error classes
  //===========================================================================

  typedef enum logic [4:0] {

    TL_ERR_NONE             = 5'd0,
    TL_ERR_ILLEGAL_OPCODE   = 5'd1,
    TL_ERR_BAD_SIZE         = 5'd2,
    TL_ERR_BAD_ALIGNMENT    = 5'd3,
    TL_ERR_BAD_MASK         = 5'd4,
    TL_ERR_BAD_SOURCE       = 5'd5,
    TL_ERR_BAD_SINK         = 5'd6,
    TL_ERR_SOURCE_OVERFLOW  = 5'd7,
    TL_ERR_SINK_OVERFLOW    = 5'd8,
    TL_ERR_TIMEOUT          = 5'd9,
    TL_ERR_PERMISSION       = 5'd10,
    TL_ERR_STATE            = 5'd11,
    TL_ERR_DUPLICATE        = 5'd12,
    TL_ERR_PROTOCOL         = 5'd13,
    TL_ERR_CORRUPT          = 5'd14,
    TL_ERR_INTERNAL         = 5'd15

  } tl_error_e;


  //===========================================================================
  // Generic TL-C transaction descriptor
  //===========================================================================

  typedef struct packed {

    logic [2:0] opcode;
    logic [2:0] param;

    logic [TL_DEFAULT_SIZE_W-1:0]
      size;

    logic [TL_DEFAULT_SOURCE_W-1:0]
      source;

    logic [TL_DEFAULT_SINK_W-1:0]
      sink;

    logic [TL_DEFAULT_ADDR_W-1:0]
      address;

    logic [TL_DEFAULT_DATA_W-1:0]
      data;

    logic [TL_DEFAULT_BYTE_W-1:0]
      mask;

    logic denied;
    logic corrupt;

  } tl_txn_t;


  //===========================================================================
  // Directory entry
  //===========================================================================

  typedef struct packed {

    logic valid;

    tl_dir_state_e state;

    logic [TL_DEFAULT_ADDR_W-1:0]
      address;

    logic [TL_DEFAULT_CLIENTS-1:0]
      sharers;

    logic [TL_DEFAULT_CLIENTS-1:0]
      probes_pending;

    logic [TL_DEFAULT_CLIENTS-1:0]
      probes_acked;

    logic [TL_DEFAULT_CLIENTS-1:0]
      dirty_owners;

    logic [$clog2(TL_DEFAULT_CLIENTS)-1:0]
      owner;

    logic dirty;

    logic pending;

  } tl_directory_entry_t;


  //===========================================================================
  // Opcode classification
  //===========================================================================

  function automatic bit is_a_opcode_valid(
    input logic [2:0] opcode
  );

    case (opcode)

      TL_A_PUTFULL,
      TL_A_PUTPARTIAL,
      TL_A_ARITHMETIC,
      TL_A_LOGICAL,
      TL_A_GET,
      TL_A_HINT,
      TL_A_ACQUIREBLOCK,
      TL_A_ACQUIREPERM:
        return 1'b1;

      default:
        return 1'b0;

    endcase

  endfunction


  function automatic bit is_b_opcode_valid(
    input logic [2:0] opcode
  );

    case (opcode)

      TL_B_PUTFULL,
      TL_B_PUTPARTIAL,
      TL_B_ARITHMETIC,
      TL_B_LOGICAL,
      TL_B_GET,
      TL_B_HINT,
      TL_B_PROBE:
        return 1'b1;

      default:
        return 1'b0;

    endcase

  endfunction


  function automatic bit is_c_opcode_valid(
    input logic [2:0] opcode
  );

    case (opcode)

      TL_C_PROBEACK,
      TL_C_PROBEACKDATA,
      TL_C_RELEASE,
      TL_C_RELEASEDATA:
        return 1'b1;

      default:
        return 1'b0;

    endcase

  endfunction


  function automatic bit is_d_opcode_valid(
    input logic [2:0] opcode
  );

    case (opcode)

      TL_D_ACCESSACK,
      TL_D_ACCESSACKDATA,
      TL_D_HINTACK,
      TL_D_GRANT,
      TL_D_GRANTDATA,
      TL_D_RELEASEACK:
        return 1'b1;

      default:
        return 1'b0;

    endcase

  endfunction


  function automatic bit is_e_opcode_valid(
    input logic [2:0] opcode
  );

    return opcode == TL_E_GRANTACK;

  endfunction


  //===========================================================================
  // Opcode classifiers
  //===========================================================================

  function automatic bit is_a_read(
    input logic [2:0] opcode
  );

    return opcode == TL_A_GET;

  endfunction


  function automatic bit is_a_write(
    input logic [2:0] opcode
  );

    return (opcode == TL_A_PUTFULL) ||
           (opcode == TL_A_PUTPARTIAL);

  endfunction


  function automatic bit is_a_atomic(
    input logic [2:0] opcode
  );

    return (opcode == TL_A_ARITHMETIC) ||
           (opcode == TL_A_LOGICAL);

  endfunction


  function automatic bit is_a_acquire(
    input logic [2:0] opcode
  );

    return (opcode == TL_A_ACQUIREBLOCK) ||
           (opcode == TL_A_ACQUIREPERM);

  endfunction


  function automatic bit is_c_probe_ack(
    input logic [2:0] opcode
  );

    return (opcode == TL_C_PROBEACK) ||
           (opcode == TL_C_PROBEACKDATA);

  endfunction


  function automatic bit is_c_release(
    input logic [2:0] opcode
  );

    return (opcode == TL_C_RELEASE) ||
           (opcode == TL_C_RELEASEDATA);

  endfunction


  function automatic bit is_d_data_response(
    input logic [2:0] opcode
  );

    return (opcode == TL_D_ACCESSACKDATA) ||
           (opcode == TL_D_GRANTDATA);

  endfunction


  function automatic bit is_d_grant(
    input logic [2:0] opcode
  );

    return (opcode == TL_D_GRANT) ||
           (opcode == TL_D_GRANTDATA);

  endfunction


  //===========================================================================
  // Cache-line helpers
  //===========================================================================

  function automatic logic [TL_DEFAULT_ADDR_W-1:0]
    line_base(
      input logic [TL_DEFAULT_ADDR_W-1:0] address
    );

    return address &
           ~(TL_DEFAULT_CACHE_LINE_BYTES - 1);

  endfunction


  function automatic logic
    address_aligned(
      input logic [TL_DEFAULT_ADDR_W-1:0] address,
      input logic [TL_DEFAULT_SIZE_W-1:0] size
    );

    logic [TL_DEFAULT_ADDR_W-1:0] alignment_mask;

    begin

      if (size >= TL_DEFAULT_ADDR_W) begin

        return 1'b0;

      end

      alignment_mask =
        ({{(TL_DEFAULT_ADDR_W-1){1'b0}},1'b1} << size) -
        1'b1;

      return (address & alignment_mask) == '0;

    end

  endfunction


  //===========================================================================
  // Full byte mask
  //===========================================================================

  function automatic logic [TL_DEFAULT_BYTE_W-1:0]
    full_byte_mask();

    return '1;

  endfunction


  //===========================================================================
  // Number of bytes represented by a TL size.
  //===========================================================================

  function automatic int unsigned
    size_to_bytes(
      input logic [TL_DEFAULT_SIZE_W-1:0] size
    );

    if (size >= 31)
      return 0;

    return (1 << size);

  endfunction


  //===========================================================================
  // Validate mask against address/size.
  //
  // Supports naturally aligned transfers within one data beat.
  //===========================================================================

  function automatic bit
    byte_mask_valid(
      input logic [TL_DEFAULT_ADDR_W-1:0] address,
      input logic [TL_DEFAULT_SIZE_W-1:0] size,
      input logic [TL_DEFAULT_BYTE_W-1:0] mask
    );

    int unsigned nbytes;
    int unsigned first_byte;

    logic [TL_DEFAULT_BYTE_W-1:0]
      expected_mask;

    begin

      expected_mask = '0;

      nbytes = size_to_bytes(size);

      if ((nbytes == 0) ||
          (nbytes > TL_DEFAULT_BYTE_W)) begin

        return 1'b0;

      end

      first_byte =
        address[$clog2(TL_DEFAULT_BYTE_W)-1:0];

      if ((first_byte + nbytes) >
          TL_DEFAULT_BYTE_W) begin

        return 1'b0;

      end

      for (int unsigned i = 0;
           i < TL_DEFAULT_BYTE_W;
           i++) begin

        if ((i >= first_byte) &&
            (i < first_byte + nbytes))

          expected_mask[i] = 1'b1;

      end

      return mask == expected_mask;

    end

  endfunction


  //===========================================================================
  // Permission helpers
  //===========================================================================

  function automatic bit
    permission_has_read(
      input tl_permission_e permission
    );

    return permission != TL_PERM_NONE;

  endfunction


  function automatic bit
    permission_has_write(
      input tl_permission_e permission
    );

    return permission == TL_PERM_T;

  endfunction


  function automatic bit
    permission_is_none(
      input tl_permission_e permission
    );

    return permission == TL_PERM_NONE;

  endfunction


  //===========================================================================
  // Directory-state helpers
  //===========================================================================

  function automatic bit
    directory_state_valid(
      input tl_dir_state_e state
    );

    return (state == TL_DIR_I) ||
           (state == TL_DIR_S) ||
           (state == TL_DIR_E) ||
           (state == TL_DIR_M) ||
           (state == TL_DIR_IS) ||
           (state == TL_DIR_IM) ||
           (state == TL_DIR_SM) ||
           (state == TL_DIR_MI);

  endfunction


  function automatic bit
    directory_state_stable(
      input tl_dir_state_e state
    );

    return (state == TL_DIR_I) ||
           (state == TL_DIR_S) ||
           (state == TL_DIR_E) ||
           (state == TL_DIR_M);

  endfunction


  function automatic bit
    directory_state_transient(
      input tl_dir_state_e state
    );

    return !directory_state_stable(state);

  endfunction


  function automatic bit
    directory_state_dirty(
      input tl_dir_state_e state
    );

    return (state == TL_DIR_M) ||
           (state == TL_DIR_IM) ||
           (state == TL_DIR_SM);

  endfunction


  //===========================================================================
  // Popcount helper
  //===========================================================================

  function automatic int unsigned
    popcount_clients(
      input logic [TL_DEFAULT_CLIENTS-1:0] vector
    );

    int unsigned count;

    begin

      count = 0;

      for (int unsigned i = 0;
           i < TL_DEFAULT_CLIENTS;
           i++) begin

        if (vector[i])
          count++;

      end

      return count;

    end

  endfunction


  //===========================================================================
  // One-hot client helper
  //===========================================================================

  function automatic logic [TL_DEFAULT_CLIENTS-1:0]
    client_onehot(
      input logic [$clog2(TL_DEFAULT_CLIENTS)-1:0] client
    );

    logic [TL_DEFAULT_CLIENTS-1:0] result;

    begin

      result = '0;

      if (client < TL_DEFAULT_CLIENTS)
        result[client] = 1'b1;

      return result;

    end

  endfunction


  //===========================================================================
  // Protocol response helpers
  //===========================================================================

  function automatic bit
    d_requires_sink(
      input logic [2:0] opcode
    );

    return (opcode == TL_D_GRANT) ||
           (opcode == TL_D_GRANTDATA);

  endfunction


  function automatic bit
    d_carries_data(
      input logic [2:0] opcode
    );

    return (opcode == TL_D_ACCESSACKDATA) ||
           (opcode == TL_D_GRANTDATA);

  endfunction


  function automatic bit
    c_carries_data(
      input logic [2:0] opcode
    );

    return (opcode == TL_C_PROBEACKDATA) ||
           (opcode == TL_C_RELEASEDATA);

  endfunction


  function automatic bit
    c_requires_source(
      input logic [2:0] opcode
    );

    return (opcode == TL_C_PROBEACK) ||
           (opcode == TL_C_PROBEACKDATA) ||
           (opcode == TL_C_RELEASE) ||
           (opcode == TL_C_RELEASEDATA);

  endfunction


  //===========================================================================
  // Protocol consistency helpers
  //===========================================================================

  function automatic bit
    a_opcode_requires_data(
      input logic [2:0] opcode
    );

    return (opcode == TL_A_PUTFULL) ||
           (opcode == TL_A_PUTPARTIAL) ||
           (opcode == TL_A_ARITHMETIC) ||
           (opcode == TL_A_LOGICAL);

  endfunction


  function automatic bit
    a_opcode_requires_full_mask(
      input logic [2:0] opcode
    );

    return opcode == TL_A_PUTFULL;

  endfunction


  function automatic bit
    a_opcode_is_hint(
      input logic [2:0] opcode
    );

    return opcode == TL_A_HINT;

  endfunction


  //===========================================================================
  // Timeout helper
  //
  // Used by transaction/probe engines.
  //===========================================================================

  function automatic bit
    timeout_expired(
      input logic [31:0] counter,
      input logic [31:0] timeout_cycles
    );

    return counter >= timeout_cycles;

  endfunction


  //===========================================================================
  // Debug string helpers
  //
  // Simulation/debug only. Keep synthesis disabled.
  //===========================================================================

`ifndef SYNTHESIS

  function automatic string
    a_opcode_name(
      input logic [2:0] opcode
    );

    case (opcode)

      TL_A_PUTFULL:
        return "PutFullData";

      TL_A_PUTPARTIAL:
        return "PutPartialData";

      TL_A_ARITHMETIC:
        return "ArithmeticData";

      TL_A_LOGICAL:
        return "LogicalData";

      TL_A_GET:
        return "Get";

      TL_A_HINT:
        return "Hint";

      TL_A_ACQUIREBLOCK:
        return "AcquireBlock";

      TL_A_ACQUIREPERM:
        return "AcquirePerm";

      default:
        return "A_RESERVED";

    endcase

  endfunction


  function automatic string
    c_opcode_name(
      input logic [2:0] opcode
    );

    case (opcode)

      TL_C_PROBEACK:
        return "ProbeAck";

      TL_C_PROBEACKDATA:
        return "ProbeAckData";

      TL_C_RELEASE:
        return "Release";

      TL_C_RELEASEDATA:
        return "ReleaseData";

      default:
        return "C_RESERVED";

    endcase

  endfunction


  function automatic string
    d_opcode_name(
      input logic [2:0] opcode
    );

    case (opcode)

      TL_D_ACCESSACK:
        return "AccessAck";

      TL_D_ACCESSACKDATA:
        return "AccessAckData";

      TL_D_HINTACK:
        return "HintAck";

      TL_D_GRANT:
        return "Grant";

      TL_D_GRANTDATA:
        return "GrantData";

      TL_D_RELEASEACK:
        return "ReleaseAck";

      default:
        return "D_RESERVED";

    endcase

  endfunction

`endif

endpackage