//! Pure GPT-Live data-channel classification (profile mode gpt_live).
//!
//! The LiveKit path gets the agent's state from the standard `lk.agent.state`
//! attribute. GPT-Live has no such state: it is full duplex, and the
//! `oai-events` channel only carries transcript deltas, delegation progress and
//! the session lifecycle. This module maps those events plus the speaker render
//! peak onto the reducer's existing AgentState vocabulary, so the LEDs and the
//! half-duplex gate keep working unchanged. No I/O; host-tested in core_test.zig.

const reducer = @import("session_reducer.zig");

pub const Kind = enum {
    /// session.started: the session is live; hand the mic over.
    started,
    /// session.output_transcript.delta: the assistant is producing speech.
    output_activity,
    /// session.input_transcript.delta: the user is being heard.
    input_activity,
    /// Delegation/backend progress: the assistant is working on something.
    backend_activity,
    /// session.closed: final event; the session is over.
    closed,
    /// error: logged; the server closes the session itself when fatal.
    failed,
    ignored,
};

/// The top-level `"type"` value of one JSON event, or null. Only depth-1 keys
/// count: nested objects (`response.event` carries an inner `type`) never
/// shadow the envelope, whatever the key order.
pub fn eventType(json: []const u8) ?[]const u8 {
    var depth: u32 = 0;
    var i: usize = 0;
    var expect_key = false;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            '{' => {
                depth += 1;
                expect_key = depth == 1;
            },
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            '[' => depth += 1,
            ']' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            ',' => expect_key = depth == 1,
            '"' => {
                const start = i + 1;
                const end = stringEnd(json, start) orelse return null;
                i = end;
                if (depth == 1 and expect_key) {
                    expect_key = false;
                    const key = json[start..end];
                    var j = skipSpace(json, end + 1);
                    if (j >= json.len or json[j] != ':') return null;
                    j = skipSpace(json, j + 1);
                    if (!eql(key, "type")) continue;
                    if (j >= json.len or json[j] != '"') return null;
                    const value_end = stringEnd(json, j + 1) orelse return null;
                    return json[j + 1 .. value_end];
                }
            },
            else => {},
        }
    }
    return null;
}

/// Index of the closing quote of a string whose contents start at `start`.
fn stringEnd(json: []const u8, start: usize) ?usize {
    var k = start;
    while (k < json.len) : (k += 1) {
        switch (json[k]) {
            '\\' => k += 1,
            '"' => return k,
            else => {},
        }
    }
    return null;
}

fn skipSpace(json: []const u8, from: usize) usize {
    var k = from;
    while (k < json.len and (json[k] == ' ' or json[k] == '\n' or json[k] == '\r' or json[k] == '\t')) k += 1;
    return k;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn startsWith(a: []const u8, prefix: []const u8) bool {
    return a.len >= prefix.len and eql(a[0..prefix.len], prefix);
}

pub fn classify(json: []const u8) Kind {
    const t = eventType(json) orelse return .ignored;
    if (eql(t, "session.started")) return .started;
    if (eql(t, "session.output_transcript.delta")) return .output_activity;
    if (eql(t, "session.input_transcript.delta")) return .input_activity;
    if (eql(t, "session.closed")) return .closed;
    if (eql(t, "error")) return .failed;
    if (eql(t, "response.event") or startsWith(t, "session.delegation.")) return .backend_activity;
    return .ignored;
}

/// Speaking/thinking/quiet from events plus the measured speaker output.
///
/// The render peak is the ground truth for "audio is coming out of the
/// speaker" (it drives the half-duplex gate); output transcript deltas start
/// speaking a little earlier. Speaking ends after HANGOVER_MS without either.
pub const Tracker = struct {
    pub const HANGOVER_MS: i64 = 700;

    speaking: bool = false,
    thinking: bool = false,
    last_output_ms: i64 = 0,

    pub fn onEvent(self: *Tracker, kind: Kind, now_ms: i64) ?reducer.AgentState {
        switch (kind) {
            .output_activity => return self.output(now_ms),
            .backend_activity => {
                if (self.speaking or self.thinking) return null;
                self.thinking = true;
                return .thinking;
            },
            .closed => return .close,
            else => return null,
        }
    }

    pub fn onTick(self: *Tracker, render_peak: u32, now_ms: i64) ?reducer.AgentState {
        if (render_peak >= reducer.AGENT_AUDIO_LEVEL) return self.output(now_ms);
        if (self.speaking and now_ms - self.last_output_ms >= HANGOVER_MS) {
            self.speaking = false;
            self.thinking = false;
            return .quiet;
        }
        return null;
    }

    fn output(self: *Tracker, now_ms: i64) ?reducer.AgentState {
        self.last_output_ms = now_ms;
        if (self.speaking) return null;
        self.speaking = true;
        self.thinking = false;
        return .speaking;
    }
};
