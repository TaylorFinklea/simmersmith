import Testing
@testable import AIProviderKit

// Phase 2.0 — shared SSE event reader. A pure, synchronous, line-at-a-time parser
// that the per-vendor `streamWithTools` overrides (Phase 2a/2b/2c) will drive to turn
// a streaming HTTP body into discrete SSE events. No networking here — fixture-driven.

/// Drives the parser by pushing each line and collecting dispatched events, then
/// flushes a trailing event via `finish()`. Mirrors how a vendor layer will consume
/// `URLSession.AsyncBytes.lines` (push per line, finish at end-of-stream).
private func collect(_ lines: [String]) -> [SSEEvent] {
    var parser = SSEParser()
    var out: [SSEEvent] = []
    for line in lines {
        if let evt = parser.push(line) { out.append(evt) }
    }
    if let evt = parser.finish() { out.append(evt) }
    return out
}

@Test("two events separated by blank lines")
func twoEvents() {
    let lines = ["data: hello", "", "data: world", ""]
    #expect(collect(lines) == [
        SSEEvent(event: nil, data: "hello"),
        SSEEvent(event: nil, data: "world"),
    ])
}

@Test("multi-line data joins with newline")
func multiLineData() {
    #expect(collect(["data: a", "data: b", ""]) == [SSEEvent(event: nil, data: "a\nb")])
}

@Test("event field names the dispatched event")
func namedEvent() {
    #expect(collect(["event: delta", "data: x", ""]) == [SSEEvent(event: "delta", data: "x")])
}

@Test("comment / heartbeat lines are ignored")
func commentIgnored() {
    #expect(collect([": keep-alive", "", "data: x", ""]) == [SSEEvent(event: nil, data: "x")])
}

@Test("[DONE] sentinel is an ordinary data event")
func doneSentinel() {
    #expect(collect(["data: [DONE]", ""]) == [SSEEvent(event: nil, data: "[DONE]")])
}

@Test("a trailing event with no closing blank line is flushed by finish()")
func trailingFlush() {
    var parser = SSEParser()
    #expect(parser.push("data: last") == nil)
    #expect(parser.finish() == SSEEvent(event: nil, data: "last"))
    #expect(parser.finish() == nil)
}

@Test("data:x (no space) and data: x (one space) both yield x")
func colonSpacing() {
    #expect(collect(["data:x", ""]) == [SSEEvent(event: nil, data: "x")])
    #expect(collect(["data: x", ""]) == [SSEEvent(event: nil, data: "x")])
}
