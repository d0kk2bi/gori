module Gori::Proxy::WS
  # RFC 6455 opcodes.
  OP_CONT  = 0x0_u8
  OP_TEXT  = 0x1_u8
  OP_BIN   = 0x2_u8
  OP_CLOSE = 0x8_u8
  OP_PING  = 0x9_u8
  OP_PONG  = 0xA_u8

  # Upper bound on a single frame we will buffer for byte-exact forward + capture.
  # A larger (or hostile) advertised length aborts the direction rather than
  # overflowing `len.to_i` (Int32) or allocating unbounded memory.
  MAX_FRAME = 16_u64 * 1024 * 1024

  # The RSV1..RSV3 nibble of the first header octet (RFC 6455 §5.2), shifted down so
  # RSV1 = 4, RSV2 = 2, RSV3 = 1. Parsing used to read `b0 & 0x80` and `b0 & 0x0f` and
  # nothing between them, so the three extension bits existed nowhere above the socket:
  # a `permessage-deflate` frame and a plain one produced identical capture rows, and an
  # operator probing §5.2 ("what does this server do with RSV1 on a socket that negotiated
  # no extension?") had no way to see the answer, let alone send the question.
  RSV_MASK  = 0x70_u8
  RSV_SHIFT =       4

  # The frame-header facts a WebSocket MESSAGE carries beside its payload — everything
  # `ws_messages` could not say before V7, in one value so a capture row, a repeater
  # session row and a send instruction all speak the same shape.
  #
  # Capture fills these in from the wire. `fin` is the LAST frame's FIN (0 means the
  # message ended without one: a §5.4 violation, a teardown mid-fragment), `rsv` is the
  # FIRST frame's RSV nibble (§5.2 puts an extension's flags there), `frames` is how many
  # frames the message spanned — the only way to tell a two-fragment message from the
  # single frame its reassembled row otherwise looks exactly like — and `masked`/`mask_key`
  # are the first frame's, which is how an UNMASKED client frame (§5.1 violation, and the
  # most common WebSocket hardening probe) becomes visible at all.
  #
  # `declared_len` is the one field capture can never produce: a frame whose length header
  # disagrees with its payload is not readable back, because the reader believes the header.
  # It exists only on the SEND side and must therefore be persisted, not derived.
  #
  # Every field defaults to what gori has always done, so a `Shape.new` send is byte-for-byte
  # the frame the encoder emitted before this struct existed. `masked` is NILABLE for the
  # same reason: a pre-V7 row genuinely does not know, and "mask with a fresh key" (the send
  # default) is a different statement from "the wire said masked".
  record Shape,
    fin : Bool = true,
    rsv : Int32 = 0,
    masked : Bool? = nil,
    mask_key : Bytes? = nil,
    frames : Int32 = 1,
    declared_len : Int32? = nil do
    DEFAULT = new

    # Nothing here departs from the encoder's own defaults, so a sender can take the
    # untouched path. `frames` is capture-only metadata and deliberately not consulted.
    def default? : Bool
      fin && rsv == 0 && masked.nil? && mask_key.nil? && declared_len.nil?
    end
  end

  # A parsed WebSocket frame. `payload` is unmasked (for capture); `raw` is the
  # exact wire bytes (for byte-faithful forwarding, P7).
  struct Frame
    getter? fin : Bool
    getter opcode : UInt8
    getter payload : Bytes
    getter raw : Bytes
    getter rsv : UInt8
    getter? masked : Bool
    getter mask_key : Bytes?

    def initialize(@fin : Bool, @opcode : UInt8, @payload : Bytes, @raw : Bytes,
                   @rsv : UInt8 = 0_u8, @masked : Bool = false, @mask_key : Bytes? = nil)
    end

    def data? : Bool
      opcode == OP_TEXT || opcode == OP_BIN || opcode == OP_CONT
    end

    def close? : Bool
      opcode == OP_CLOSE
    end

    # This frame as a one-frame message shape — what capture records for a control frame,
    # which has no reassembly to accumulate across.
    def shape : Shape
      Shape.new(fin: fin?, rsv: rsv.to_i, masked: masked?, mask_key: mask_key, frames: 1)
    end
  end

  # A parsed frame header (no payload). `bytes` are the exact header wire octets
  # (2..14, incl. the mask key when masked) for byte-faithful forwarding; `len` is
  # the advertised payload length (UNbounded — the caller decides whether to buffer
  # it, `read_body`, or stream it past the cap, `stream_payload`).
  struct Header
    getter? fin : Bool
    getter opcode : UInt8
    getter? masked : Bool
    getter len : UInt64
    getter bytes : Bytes
    getter rsv : UInt8

    def initialize(@fin : Bool, @opcode : UInt8, @masked : Bool, @len : UInt64, @bytes : Bytes,
                   @rsv : UInt8 = 0_u8)
    end

    def data? : Bool
      opcode == OP_TEXT || opcode == OP_BIN || opcode == OP_CONT
    end

    def close? : Bool
      opcode == OP_CLOSE
    end

    # The 4-byte masking key (a view into `bytes`), or empty when unmasked.
    def mask_key : Bytes
      masked? ? bytes[bytes.size - 4, 4] : Bytes.empty
    end

    # This header as a one-frame message shape (what capture records for a control
    # frame, and the seed for a data message's first frame).
    def shape(frames : Int32 = 1) : Shape
      Shape.new(fin: fin?, rsv: rsv.to_i, masked: masked?,
        mask_key: masked? ? mask_key.dup : nil, frames: frames)
    end
  end

  # Reads only a frame header (RFC 6455 §5.2). Returns nil on EOF / truncated
  # header. Does NOT bound `len` — a big advertised length is the caller's call
  # (buffer up to the cap, or stream past it for byte-exact forwarding).
  def self.read_header(io : IO) : Header?
    hdr = uninitialized UInt8[14]
    hs = hdr.to_slice
    return nil unless io.read_fully?(hs[0, 2])
    b0 = hs[0]
    b1 = hs[1]
    fin = (b0 & 0x80_u8) != 0
    rsv = (b0 & RSV_MASK) >> RSV_SHIFT
    opcode = b0 & 0x0f_u8
    masked = (b1 & 0x80_u8) != 0
    len = (b1 & 0x7f_u8).to_u64
    hlen = 2

    if len == 126
      return nil unless io.read_fully?(hs[2, 2])
      len = (hs[2].to_u64 << 8) | hs[3].to_u64
      hlen = 4
    elsif len == 127
      return nil unless io.read_fully?(hs[2, 8])
      len = 0_u64
      (2...10).each { |i| len = (len << 8) | hs[i].to_u64 }
      hlen = 10
    end

    if masked
      return nil unless io.read_fully?(hs[hlen, 4])
      hlen += 4
    end
    Header.new(fin, opcode, masked, len, hs[0, hlen].dup, rsv)
  end

  # Reads a header-plus-payload frame from `io`, buffering the whole payload.
  # Returns nil on EOF / truncated frame, or when the advertised length exceeds
  # MAX_FRAME (so `n.to_i` can't overflow and one frame can't OOM us). The relay
  # streams oversized frames instead (see `stream_payload`); this buffered form is
  # for the WS repeater engine and per-frame capture.
  def self.read_frame(io : IO) : Frame?
    h = read_header(io) || return nil
    return nil if h.len > MAX_FRAME # oversized — caller must stream, not buffer
    read_body(io, h)
  end

  # Reads the payload for an already-read `Header` into ONE wire buffer
  # (header + payload) reused as `raw` for byte-exact forwarding, unmasking a copy
  # for `payload`. The caller MUST have checked `h.len <= MAX_FRAME`.
  def self.read_body(io : IO, h : Header) : Frame?
    hlen = h.bytes.size
    n = h.len.to_i
    buf = Bytes.new(hlen + n)
    h.bytes.copy_to(buf[0, hlen])
    if n > 0
      return nil unless io.read_fully?(buf[hlen, n])
    end

    payload =
      if h.masked?
        unmasked = Bytes.new(n) # separate buffer; keep `raw` masked for byte-exact relay
        unmask(buf[hlen, n], h.mask_key, unmasked) if n > 0
        unmasked
      else
        buf[hlen, n] # zero-copy view into the wire buffer (already unmasked)
      end

    Frame.new(h.fin?, h.opcode, payload, buf, h.rsv, h.masked?,
      h.masked? ? h.mask_key.dup : nil)
  end

  # Unmask `src` into `dst` (RFC 6455 §5.3: `dst[i] = src[i] ^ key[i % 4]`). Every
  # client→server frame is masked, so this runs over the whole payload of every WS upload —
  # the byte-at-a-time loop was the dominant WS-capture CPU cost. The mask period is 4 and
  # aligned to payload offset 0, so a 32-bit word XOR is byte-identical to the scalar form:
  # load 4 src bytes and the 4 key bytes as words in the SAME native order, XOR, store — the
  # result's byte layout is `[s0^k0, s1^k1, s2^k2, s3^k3]` on either endianness. A ≤3-byte
  # tail finishes scalar. `dst` must be exactly `src.size`. Only the CAPTURE copy is unmasked;
  # `raw`/forward bytes stay masked (byte-exact, P7).
  def self.unmask(src : Bytes, key : Bytes, dst : Bytes) : Nil
    n = src.size
    sp = src.to_unsafe
    dp = dst.to_unsafe
    key32 = key.to_unsafe.as(UInt32*).value # the 4 key bytes as one native-order word
    i = 0
    while i + 4 <= n
      (dp + i).as(UInt32*).value = (sp + i).as(UInt32*).value ^ key32
      i += 4
    end
    kp = key.to_unsafe
    while i < n
      dp[i] = sp[i] ^ kp[i & 3]
      i += 1
    end
  end

  # Copies exactly `len` payload bytes from `src` to `dst` in bounded chunks,
  # WITHOUT buffering the whole frame — so the relay can forward a frame larger
  # than MAX_FRAME byte-exact (P7) instead of aborting the tunnel. Returns false if
  # the peer died mid-payload (truncated frame). `scratch` is a reused copy buffer.
  def self.stream_payload(src : IO, dst : IO, len : UInt64, scratch : Bytes) : Bool
    left = len
    while left > 0
      want = left < scratch.size ? left.to_i : scratch.size
      read = src.read(scratch[0, want])
      return false if read == 0 # truncated mid-payload
      dst.write(scratch[0, read])
      left -= read
    end
    true
  end

  # Encodes one frame for sending. Client→server frames MUST be masked (RFC 6455
  # §5.3) with a fresh random 32-bit key; server→client frames are unmasked. Used
  # by the WS repeater engine (the live relay only forwards `raw` bytes verbatim, so
  # it never needs to build a frame). Control frames (close/ping/pong) carry ≤125
  # bytes and so always take the short length path.
  #
  # Every keyword defaults to what this method has always emitted, so an untouched call is
  # byte-identical. The four that are new exist because the repeater could express exactly
  # one frame shape — TEXT/BIN, FIN=1, RSV=0, masked with a fresh key, length equal to the
  # payload — and every WebSocket test that is not "does the app echo my string" lives
  # outside it:
  #
  #   * `rsv` — §5.2. Setting RSV1 on a socket that negotiated no extension is the
  #     extension-confusion / decompression-bomb probe, and there was no parameter for it.
  #   * `mask_key` — a repeated or all-zero masking key. §5.3 wants it unpredictable; a
  #     server that caches on it, or an intermediary that assumes it varies, is testable
  #     only if the operator picks the bytes.
  #   * `mask: false` — a client frame with no mask at all. §5.1 says the server MUST fail
  #     the connection; whether it does is the single most common hardening question, and
  #     the flag existed but nothing above it could reach it.
  #   * `declared_len` — the length HEADER, decoupled from the payload actually written.
  #     A receiver believes the header, so this shape can never be captured off a wire and
  #     can only ever be authored. Under-declaring truncates the frame from the receiver's
  #     point of view and leaves the remainder to be parsed as the next header; over-
  #     declaring makes it wait for bytes that are not coming. Both are framing tests.
  #
  # Nothing here is validated. A control frame over 125 bytes, an RSV bit on a socket with
  # no extension, a length that lies: those are the payloads, and a send path that refuses
  # them is a send path that cannot ask the question (P0/P7).
  def self.encode(opcode : UInt8, payload : Bytes, *, mask : Bool = true, fin : Bool = true,
                  rsv : Int32 = 0, mask_key : Bytes? = nil, declared_len : Int32? = nil) : Bytes
    n = payload.size
    # The header advertises `declared_len`; the body is always the payload as handed in.
    adv = declared_len || n
    io = IO::Memory.new(n + 14)
    io.write_byte((fin ? 0x80_u8 : 0_u8) |
                  ((rsv.to_u8! << RSV_SHIFT) & RSV_MASK) |
                  (opcode & 0x0f_u8))
    mb = mask ? 0x80_u8 : 0_u8
    if adv < 126
      io.write_byte(mb | adv.to_u8)
    elsif adv <= 0xFFFF
      io.write_byte(mb | 126_u8)
      io.write_byte((adv >> 8).to_u8!)
      io.write_byte(adv.to_u8!)
    else
      io.write_byte(mb | 127_u8)
      len = adv.to_u64
      (0..7).each { |i| io.write_byte((len >> (56 - i * 8)).to_u8!) }
    end
    if mask
      # A key the operator chose, else a fresh random one. Short/long input is folded to
      # exactly 4 bytes rather than refused — `mask_key: Bytes[0]` means "all-zero key", the
      # degenerate case worth testing, and demanding they spell out four zeroes helps nobody.
      key = mask_key ? fixed_key(mask_key) : Random::Secure.random_bytes(4)
      io.write(key)
      n.times { |i| io.write_byte(payload[i] ^ key[i & 3]) }
    else
      io.write(payload)
    end
    io.to_slice
  end

  # Exactly 4 bytes from whatever the operator supplied: zero-padded when short, truncated
  # when long. An empty slice is an all-zero key.
  private def self.fixed_key(key : Bytes) : Bytes
    return key if key.size == 4
    fixed = Bytes.new(4) # `out` is a Crystal keyword, hence the name
    key[0, {key.size, 4}.min].copy_to(fixed) unless key.empty?
    fixed
  end

  # `encode` driven by a `Shape`. `masked` nil means "the caller's own default" — which is
  # `mask`, i.e. what the direction requires — so a pre-V7 row and a fresh `Shape.new` both
  # keep today's behaviour.
  def self.encode(opcode : UInt8, payload : Bytes, shape : Shape, *, mask : Bool = true) : Bytes
    m = shape.masked
    encode(opcode, payload, mask: m.nil? ? mask : m,
      fin: shape.fin, rsv: shape.rsv, mask_key: shape.mask_key,
      declared_len: shape.declared_len)
  end
end
