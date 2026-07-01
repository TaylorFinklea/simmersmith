// Phase 2.0 — Shared SSE event reader.
//
// A pure, synchronous, incremental Server-Sent-Events line parser. The per-vendor
// `streamWithTools` overrides (Phase 2a/2b/2c) feed it lines from a streaming HTTP
// body (e.g. `URLSession.AsyncBytes.lines`); it turns them into discrete `SSEEvent`s.
// No networking lives here — keeping it synchronous + pure makes it fixture-testable;
// the async byte reading lives in the vendor layer.

/// One parsed Server-Sent Event. `data` is the event's `data:` field line(s) joined
/// with "\n" (per the SSE spec); `event` is the `event:` field if the event carried one.
public struct SSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental SSE line parser. Feed lines one at a time (e.g. from
/// `URLSession.AsyncBytes.lines`); `push` returns a completed event when a BLANK line
/// dispatches the accumulated fields, else nil. Call `finish()` at end-of-stream to
/// flush a trailing event that had no closing blank line.
///
/// Framing (SSE spec): `field: value` or `field:value`; a leading single space after
/// the colon is stripped. `data:` lines accumulate (multiple join with "\n"); `event:`
/// sets the name; a line beginning with `:` is a comment (ignored); a BLANK line
/// dispatches the event IF it accumulated any `data` (else resets with nothing emitted).
/// Unknown fields are ignored. The parser does NOT special-case the OpenAI `[DONE]`
/// sentinel — it emits it like any other event; the vendor layer decides to stop on it.
public struct SSEParser {
    private var dataLines: [String] = []
    private var event: String? = nil

    public init() { }

    /// Push one line. Returns a dispatched `SSEEvent` when a blank line closes the
    /// accumulated fields, otherwise nil.
    public mutating func push(_ line: String) -> SSEEvent? {
        // Blank line → dispatch (if any data accumulated) then reset.
        if line.isEmpty {
            return dispatchAndReset()
        }
        // Comment / heartbeat.
        if line.hasPrefix(":") {
            return nil
        }
        // `field: value` (or `field:value`). Split on the FIRST colon only, so colons
        // inside the value are preserved.
        if let colon = line.firstIndex(of: ":") {
            let field = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            // Strip a single leading space after the colon (SSE framing).
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
            applyField(field, value)
        } else {
            // No colon: the whole line is a field name with an empty value (SSE spec).
            applyField(line, "")
        }
        return nil
    }

    /// Flush a pending event (data accumulated but no trailing blank line seen).
    /// nil if nothing pending.
    public mutating func finish() -> SSEEvent? {
        dispatchAndReset()
    }

    private mutating func applyField(_ field: String, _ value: String) {
        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            event = value
        default:
            break // unknown fields (id, retry, …) are ignored
        }
    }

    private mutating func dispatchAndReset() -> SSEEvent? {
        defer { dataLines.removeAll(); event = nil }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
    }
}

/// Byte-level companion to `SSEParser`: splits a raw byte stream into text lines on
/// LF (`\n`), stripping a trailing CR (`\r`), and — critically — PRESERVING empty lines.
///
/// SSE dispatches an event on the BLANK line, so the blank separators MUST reach
/// `SSEParser`. Foundation's `AsyncSequence.lines` (`AsyncLineSequence`) silently DROPS
/// empty lines, so driving `SSEParser` from a live `URLSession.bytes.lines` stream never
/// dispatches any event (every `data:` payload collapses into one field, invalid JSON at
/// flush) — the on-device streaming bug. `URLSessionTransport.lines(for:)` feeds bytes
/// through this splitter instead. Pure + synchronous → fixture-testable; the async byte
/// reading stays in the transport.
public struct SSELineSplitter {
    private var buffer: [UInt8] = []

    public init() { }

    /// Feed one byte. Returns a completed line (WITHOUT the terminator, a trailing `\r`
    /// stripped) when an LF is seen — including an empty string for a blank line — else nil.
    public mutating func push(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {           // not LF → accumulate
            buffer.append(byte)
            return nil
        }
        if buffer.last == 0x0D { buffer.removeLast() }  // strip a trailing CR ("\r\n")
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }

    /// Flush a trailing line that had no closing LF (e.g. a stream cut mid-line). nil when
    /// nothing is buffered.
    public mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        if buffer.last == 0x0D { buffer.removeLast() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}
