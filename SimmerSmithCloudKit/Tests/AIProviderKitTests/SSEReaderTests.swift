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

// MARK: - SSELineSplitter (byte → line, preserving blank lines)

/// Split a whole byte string via `SSELineSplitter`, then flush. Mirrors how
/// `URLSessionTransport.lines(for:)` drives it over `URLSession.bytes`.
private func splitLines(_ s: String) -> [String] {
    var splitter = SSELineSplitter()
    var out: [String] = []
    for byte in Array(s.utf8) {
        if let line = splitter.push(byte) { out.append(line) }
    }
    if let last = splitter.finish() { out.append(last) }
    return out
}

@Test("SSELineSplitter PRESERVES blank lines (the SSE dispatch separators)")
func splitterPreservesBlankLines() {
    // This is the on-device bug's regression guard: `AsyncLineSequence` (bytes.lines)
    // drops these empty strings, so SSE events never dispatch. The splitter must keep them.
    #expect(splitLines("data: a\n\ndata: b\n\n") == ["data: a", "", "data: b", ""])
}

@Test("SSELineSplitter strips a trailing CR from CRLF terminators")
func splitterHandlesCRLF() {
    #expect(splitLines("a\r\nb\r\n\r\n") == ["a", "b", ""])
}

@Test("SSELineSplitter flushes a trailing line with no closing newline")
func splitterFlushesTrailing() {
    #expect(splitLines("data: last") == ["data: last"])
    var splitter = SSELineSplitter()
    #expect(splitter.push(UInt8(ascii: "x")) == nil)
    #expect(splitter.finish() == "x")
    #expect(splitter.finish() == nil)
}

@Test("bytes → SSELineSplitter → SSEParser dispatches events (the real-transport path)")
func splitterFeedsParser() {
    // End-to-end proof of the production framing: raw SSE bytes through the splitter
    // then the parser yield the discrete events — the exact path the mock-transport
    // fixtures never exercised (they replay pre-split lines that already keep blanks).
    let raw = "event: content_block_delta\ndata: {\"t\":\"Hel\"}\n\ndata: {\"t\":\"lo\"}\n\ndata: [DONE]\n\n"
    var parser = SSEParser()
    var events: [SSEEvent] = []
    for line in splitLines(raw) {
        if let evt = parser.push(line) { events.append(evt) }
    }
    if let evt = parser.finish() { events.append(evt) }
    #expect(events == [
        SSEEvent(event: "content_block_delta", data: "{\"t\":\"Hel\"}"),
        SSEEvent(event: nil, data: "{\"t\":\"lo\"}"),
        SSEEvent(event: nil, data: "[DONE]"),
    ])
}
