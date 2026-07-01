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
