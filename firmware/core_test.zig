const std = @import("std");

const aec = @import("main/core/aec_core.zig");
const decimator = @import("main/core/decimator.zig");
const gate = @import("main/core/mic_gate.zig");
const pcm = @import("main/xvf_pcm.zig");
const pre_roll = @import("main/core/pre_roll_core.zig");
const reducer = @import("main/core/session_reducer.zig");
const selector = @import("main/core/selector_core.zig");
const session = @import("main/core/session_core.zig");

fn rawSample(sample: i32) i32 {
    const scale: i32 = @as(i32, 1) << pcm.SHIFT;
    return sample * scale;
}

fn setStereoPairRaw(stereo: []i32, pair: usize, selected: i32, other: i32) void {
    const other_slot: usize = if (pcm.SLOT == 0) 1 else 0;
    stereo[pair * 2 + pcm.SLOT] = selected;
    stereo[pair * 2 + other_slot] = other;
}

fn setStereoPair(stereo: []i32, pair: usize, selected: i32, other: i32) void {
    setStereoPairRaw(stereo, pair, rawSample(selected), rawSample(other));
}

fn fillStereo(stereo: []i32, selected: i32, other: i32) void {
    for (0..stereo.len / 2) |i| {
        setStereoPair(stereo, i, selected, other);
    }
}

fn noteSamples(state: *pre_roll.WindowState, samples: usize) void {
    for (0..samples) |_| state.noteSample();
}

const PreRollReference = struct {
    write_idx: usize = 0,
    filled: usize = 0,
    total_written: u64 = 0,
    wake_mark: u64 = 0,

    fn note(self: *PreRollReference, samples: usize) void {
        self.write_idx = (self.write_idx + samples) % pre_roll.SAMPLE_CAPACITY;
        self.filled = @min(pre_roll.SAMPLE_CAPACITY, self.filled + samples);
        self.total_written += samples;
    }

    fn markWake(self: *PreRollReference) void {
        self.wake_mark = self.total_written;
    }

    fn windowSamples(self: PreRollReference) usize {
        if (self.total_written < self.wake_mark) return 0;
        const lead = @min(self.wake_mark, @as(u64, pre_roll.WAKE_LEAD_SAMPLES));
        const since_mark = self.total_written - self.wake_mark;
        const window: u64 = @min(@as(u64, self.filled), lead + since_mark);
        return @intCast(@min(window, @as(u64, pre_roll.SAMPLE_CAPACITY)));
    }

    fn startIndex(self: PreRollReference) usize {
        const count = self.windowSamples();
        return (self.write_idx + pre_roll.SAMPLE_CAPACITY - (count % pre_roll.SAMPLE_CAPACITY)) % pre_roll.SAMPLE_CAPACITY;
    }
};

const GateEvent = enum { speak_on, speak_off, tick, full_on, full_off, mute_on, mute_off };

const GateReference = struct {
    muted: bool = false,
    full_duplex_active: bool = false,
    agent_speaking: bool = false,
    speak_hangover: u32 = 0,

    fn apply(self: *GateReference, event: GateEvent) bool {
        return switch (event) {
            .speak_on => self.setAgentSpeaking(true),
            .speak_off => self.setAgentSpeaking(false),
            .tick => false,
            .full_on => blk: {
                self.full_duplex_active = true;
                break :blk false;
            },
            .full_off => blk: {
                self.full_duplex_active = false;
                break :blk false;
            },
            .mute_on => blk: {
                self.muted = true;
                break :blk false;
            },
            .mute_off => blk: {
                self.muted = false;
                break :blk false;
            },
        };
    }

    fn setAgentSpeaking(self: *GateReference, value: bool) bool {
        const fresh_burst = value and !self.agent_speaking;
        if (self.agent_speaking and !value) self.speak_hangover = gate.SPEAK_HANGOVER_FRAMES;
        self.agent_speaking = value;
        return fresh_burst;
    }

    fn gatedByAgent(self: *GateReference) bool {
        if (self.agent_speaking) return true;
        if (self.speak_hangover > 0) {
            self.speak_hangover -= 1;
            return true;
        }
        return false;
    }

    fn agentGateActive(self: *GateReference) bool {
        return !self.full_duplex_active and self.gatedByAgent();
    }
};

fn applyGateEvent(g: *gate.Gate, event: GateEvent) bool {
    return switch (event) {
        .speak_on => g.setAgentSpeaking(true),
        .speak_off => g.setAgentSpeaking(false),
        .tick => false,
        .full_on => blk: {
            g.setFullDuplex(true);
            break :blk false;
        },
        .full_off => blk: {
            g.setFullDuplex(false);
            break :blk false;
        },
        .mute_on => blk: {
            g.setMuted(true);
            break :blk false;
        },
        .mute_off => blk: {
            g.setMuted(false);
            break :blk false;
        },
    };
}

test "pcm softClip is linear below knee and bounded above it" {
    try std.testing.expectEqual(@as(i16, 0), pcm.softClip(0));
    try std.testing.expectEqual(@as(i16, 1234), pcm.softClip(1234));
    try std.testing.expectEqual(@as(i16, -1234), pcm.softClip(-1234));
    try std.testing.expectEqual(@as(i16, 24000), pcm.softClip(24000));
    try std.testing.expectEqual(@as(i16, -24000), pcm.softClip(-24000));

    const high = pcm.softClip(1_000_000);
    const low = pcm.softClip(-1_000_000);
    try std.testing.expect(high > 24000);
    try std.testing.expect(high <= std.math.maxInt(i16));
    try std.testing.expect(low < -24000);
    try std.testing.expect(low >= std.math.minInt(i16));
    try std.testing.expect(@as(i32, high) + @as(i32, low) >= -1);
    try std.testing.expect(@as(i32, high) + @as(i32, low) <= 1);
}

test "pcm convert applies configured shift before clipping" {
    const raw: i32 = 16_384 * (1 << pcm.SHIFT);
    try std.testing.expectEqual(@as(i16, 16_384), pcm.convert(raw));
    try std.testing.expectEqual(@as(i16, -16_384), pcm.convert(-raw));
}

test "pcm convert bounds raw i32 extremes" {
    const high = pcm.convert(std.math.maxInt(i32));
    const low = pcm.convert(std.math.minInt(i32));

    try std.testing.expect(high > 24000);
    try std.testing.expect(high <= std.math.maxInt(i16));
    try std.testing.expect(low < -24000);
    try std.testing.expect(low >= std.math.minInt(i16));
}

test "pre-roll window is anchored to wake mark" {
    const sr: usize = pre_roll.SAMPLE_RATE;
    const sr64: u64 = pre_roll.SAMPLE_RATE;
    const lead = pre_roll.WAKE_LEAD_SAMPLES;

    try std.testing.expectEqual(@as(usize, 0), pre_roll.windowSamples(0, 0, 0));
    try std.testing.expectEqual(sr, pre_roll.windowSamples(0, sr64, sr));
    try std.testing.expectEqual(sr, pre_roll.windowSamples(sr64 / 2, sr64, sr));
    try std.testing.expectEqual(lead + sr / 4, pre_roll.windowSamples(10 * sr64, 10 * sr64 + sr64 / 4, 11 * sr));
    // Network batches are independently bounded; the local ring sets the duration limit.
    try std.testing.expectEqual(3 * sr, pre_roll.windowSamples(10 * sr64, 11 * sr64, 11 * sr));
    try std.testing.expectEqual(pre_roll.SAMPLE_CAPACITY, pre_roll.windowSamples(10 * sr64, 30 * sr64, pre_roll.SAMPLE_CAPACITY));
}

test "pre-roll start index handles wrap and full ring" {
    try std.testing.expectEqual(@as(usize, 900), pre_roll.startIndex(1000, 100));

    const cap = pre_roll.SAMPLE_CAPACITY;
    try std.testing.expectEqual(@as(usize, cap - 20), pre_roll.startIndex(10, 30));
    try std.testing.expectEqual(@as(usize, 10), pre_roll.startIndex(10, cap));
}

test "pre-roll state tracks fill, wake and available duration" {
    var state = pre_roll.WindowState{};
    const sr: usize = pre_roll.SAMPLE_RATE;
    for (0..sr * 3) |_| state.noteSample();
    state.markWake();
    for (0..sr / 4) |_| state.noteSample();

    try std.testing.expectEqual(pre_roll.WAKE_LEAD_SAMPLES + sr / 4, state.windowSamples());
    try std.testing.expectEqual(@as(u32, 2250), state.availableMs());
}

test "pre-roll keeps wake anchored after long connect and ring wrap" {
    var state = pre_roll.WindowState{};
    const sr: usize = pre_roll.SAMPLE_RATE;

    noteSamples(&state, sr * 20);
    state.markWake();
    noteSamples(&state, sr * 8);

    try std.testing.expectEqual(10 * sr, state.windowSamples());
    try std.testing.expectEqual(@as(u32, 10_000), state.availableMs());
    try std.testing.expect(state.startIndex() < pre_roll.SAMPLE_CAPACITY);
}

test "pre-roll duration conversion floors partial milliseconds" {
    try std.testing.expectEqual(@as(u32, 0), pre_roll.availableMs(0));
    try std.testing.expectEqual(@as(u32, 0), pre_roll.availableMs(15));
    try std.testing.expectEqual(@as(u32, 999), pre_roll.availableMs(pre_roll.SAMPLE_RATE - 1));
    try std.testing.expectEqual(@as(u32, 1000), pre_roll.availableMs(pre_roll.SAMPLE_RATE));
    try std.testing.expectEqual(@as(u32, 12_000), pre_roll.availableMs(pre_roll.SAMPLE_CAPACITY));
}

test "pre-roll early wake only includes available lead" {
    var state = pre_roll.WindowState{};
    const sr: usize = pre_roll.SAMPLE_RATE;

    noteSamples(&state, sr);
    state.markWake();
    noteSamples(&state, sr / 4);

    try std.testing.expectEqual(sr + sr / 4, state.windowSamples());
    try std.testing.expectEqual(@as(usize, 0), state.startIndex());
    try std.testing.expectEqual(@as(u32, 1250), state.availableMs());
}

test "pre-roll late wake starts two seconds before wake mark" {
    var state = pre_roll.WindowState{};
    const sr: usize = pre_roll.SAMPLE_RATE;

    noteSamples(&state, sr * 5);
    state.markWake();
    noteSamples(&state, sr / 2);

    try std.testing.expectEqual(pre_roll.WAKE_LEAD_SAMPLES + sr / 2, state.windowSamples());
    try std.testing.expectEqual(sr * 3, state.startIndex());
}

test "pre-roll fill caps at ring capacity while write index keeps wrapping" {
    var state = pre_roll.WindowState{};

    noteSamples(&state, pre_roll.SAMPLE_CAPACITY + 123);

    try std.testing.expectEqual(pre_roll.SAMPLE_CAPACITY, state.filled);
    try std.testing.expectEqual(@as(usize, 123), state.write_idx);
    try std.testing.expectEqual(@as(u64, pre_roll.SAMPLE_CAPACITY + 123), state.total_written);
    try std.testing.expectEqual(@as(usize, 123), pre_roll.startIndex(state.write_idx, pre_roll.SAMPLE_CAPACITY));
}

test "pre-roll window invariants hold across timeline matrix" {
    const wake_marks = [_]u64{ 0, 1, 1000, pre_roll.WAKE_LEAD_SAMPLES - 1, pre_roll.WAKE_LEAD_SAMPLES, pre_roll.SAMPLE_CAPACITY * 2 };
    const deltas = [_]u64{ 0, 1, pre_roll.SAMPLE_RATE - 1, pre_roll.SAMPLE_RATE, pre_roll.WAKE_LEAD_SAMPLES, pre_roll.SAMPLE_CAPACITY * 2 };
    const filled_values = [_]usize{ 0, 1, 1000, pre_roll.WAKE_LEAD_SAMPLES, pre_roll.SAMPLE_CAPACITY };

    for (wake_marks) |wake_mark| {
        for (deltas) |delta| {
            for (filled_values) |filled| {
                const count = pre_roll.windowSamples(wake_mark, wake_mark + delta, filled);
                const lead = @min(wake_mark, @as(u64, pre_roll.WAKE_LEAD_SAMPLES));
                const uncapped: u64 = @min(@as(u64, filled), delta + lead);
                const expected: usize = @intCast(@min(uncapped, @as(u64, pre_roll.SAMPLE_CAPACITY)));

                try std.testing.expectEqual(expected, count);
                try std.testing.expect(count <= filled);
                try std.testing.expect(count <= pre_roll.SAMPLE_CAPACITY);
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 0), pre_roll.windowSamples(100, 99, pre_roll.SAMPLE_CAPACITY));
}

test "pre-roll state matches reference model across scripted sessions" {
    const Action = union(enum) {
        note: usize,
        wake,
        reset,
    };
    const script = [_]Action{
        .{ .note = 13 },
        .wake,
        .{ .note = pre_roll.SAMPLE_RATE / 2 },
        .{ .note = pre_roll.SAMPLE_RATE * 3 },
        .wake,
        .{ .note = pre_roll.SAMPLE_CAPACITY + 77 },
        .{ .note = 999 },
        .reset,
        .{ .note = @as(usize, pre_roll.SAMPLE_RATE) * 2 - 1 },
        .wake,
        .{ .note = @as(usize, pre_roll.SAMPLE_RATE) * 12 },
        .wake,
        .{ .note = 1 },
    };

    var state = pre_roll.WindowState{};
    var reference = PreRollReference{};

    for (script) |action| {
        switch (action) {
            .note => |samples| {
                noteSamples(&state, samples);
                reference.note(samples);
            },
            .wake => {
                state.markWake();
                reference.markWake();
            },
            .reset => {
                state.reset();
                reference = .{};
            },
        }

        try std.testing.expectEqual(reference.write_idx, state.write_idx);
        try std.testing.expectEqual(reference.filled, state.filled);
        try std.testing.expectEqual(reference.total_written, state.total_written);
        try std.testing.expectEqual(reference.wake_mark, state.wake_mark);
        try std.testing.expectEqual(reference.windowSamples(), state.windowSamples());
        try std.testing.expectEqual(reference.startIndex(), state.startIndex());
        try std.testing.expectEqual(pre_roll.availableMs(reference.windowSamples()), state.availableMs());
    }
}

test "mic gate half-duplex speaking and finite hangover" {
    var g = gate.Gate{};

    try std.testing.expect(g.setAgentSpeaking(true));
    try std.testing.expect(g.agentGateActive());
    try std.testing.expect(!g.setAgentSpeaking(true));

    try std.testing.expect(!g.setAgentSpeaking(false));
    for (0..gate.SPEAK_HANGOVER_FRAMES) |_| {
        try std.testing.expect(g.agentGateActive());
    }
    try std.testing.expect(!g.agentGateActive());
}

test "mic gate full-duplex bypasses agent gate but not mute" {
    var g = gate.Gate{};

    g.setFullDuplex(true);
    _ = g.setAgentSpeaking(true);
    try std.testing.expect(!g.agentGateActive());

    g.setMuted(true);
    try std.testing.expect(g.muted);
}

test "mic gate channel health classification catches dead and DC-pinned audio" {
    try std.testing.expect(gate.channelLooksBad(0, 0));
    try std.testing.expect(gate.channelLooksBad(400, 15001));
    try std.testing.expect(gate.channelLooksBad(400, -15001));
    try std.testing.expect(!gate.channelLooksBad(400, 15000));
    try std.testing.expect(!gate.channelLooksBad(400, -15000));
    try std.testing.expect(!gate.channelLooksBad(1400, 0));
}

test "mic gate repeated silence does not extend consumed hangover" {
    var g = gate.Gate{};

    try std.testing.expect(g.setAgentSpeaking(true));
    try std.testing.expect(!g.setAgentSpeaking(false));
    for (0..gate.SPEAK_HANGOVER_FRAMES) |_| {
        try std.testing.expect(g.agentGateActive());
    }

    try std.testing.expectEqual(@as(u32, 0), g.speak_hangover);
    try std.testing.expect(!g.agentGateActive());
    try std.testing.expect(!g.setAgentSpeaking(false));
    try std.testing.expect(!g.agentGateActive());
}

test "mic gate full-duplex preserves pending half-duplex hangover" {
    var g = gate.Gate{};

    _ = g.setAgentSpeaking(true);
    _ = g.setAgentSpeaking(false);
    try std.testing.expectEqual(gate.SPEAK_HANGOVER_FRAMES, g.speak_hangover);

    g.setFullDuplex(true);
    for (0..5) |_| {
        try std.testing.expect(!g.agentGateActive());
    }
    try std.testing.expectEqual(gate.SPEAK_HANGOVER_FRAMES, g.speak_hangover);

    g.setFullDuplex(false);
    try std.testing.expect(g.agentGateActive());
    try std.testing.expectEqual(gate.SPEAK_HANGOVER_FRAMES - 1, g.speak_hangover);
}

test "mic gate fresh bursts are reported after restart" {
    var g = gate.Gate{};

    try std.testing.expect(g.setAgentSpeaking(true));
    try std.testing.expect(!g.setAgentSpeaking(true));
    try std.testing.expect(!g.setAgentSpeaking(false));
    try std.testing.expect(g.setAgentSpeaking(true));
    try std.testing.expect(!g.setAgentSpeaking(true));
}

test "mic gate event table covers duplex mute and hangover interactions" {
    const Event = enum { speak_on, speak_off, tick, full_on, full_off, mute_on, mute_off };
    const Step = struct {
        event: Event,
        fresh: bool,
        active: bool,
        muted: bool,
        full: bool,
        hangover: u32,
    };
    const steps = [_]Step{
        .{ .event = .speak_on, .fresh = true, .active = true, .muted = false, .full = false, .hangover = 0 },
        .{ .event = .speak_off, .fresh = false, .active = true, .muted = false, .full = false, .hangover = gate.SPEAK_HANGOVER_FRAMES - 1 },
        .{ .event = .full_on, .fresh = false, .active = false, .muted = false, .full = true, .hangover = gate.SPEAK_HANGOVER_FRAMES - 1 },
        .{ .event = .tick, .fresh = false, .active = false, .muted = false, .full = true, .hangover = gate.SPEAK_HANGOVER_FRAMES - 1 },
        .{ .event = .mute_on, .fresh = false, .active = false, .muted = true, .full = true, .hangover = gate.SPEAK_HANGOVER_FRAMES - 1 },
        .{ .event = .full_off, .fresh = false, .active = true, .muted = true, .full = false, .hangover = gate.SPEAK_HANGOVER_FRAMES - 2 },
        .{ .event = .mute_off, .fresh = false, .active = true, .muted = false, .full = false, .hangover = gate.SPEAK_HANGOVER_FRAMES - 3 },
        .{ .event = .tick, .fresh = false, .active = true, .muted = false, .full = false, .hangover = gate.SPEAK_HANGOVER_FRAMES - 4 },
        .{ .event = .speak_on, .fresh = true, .active = true, .muted = false, .full = false, .hangover = gate.SPEAK_HANGOVER_FRAMES - 4 },
        .{ .event = .speak_off, .fresh = false, .active = true, .muted = false, .full = false, .hangover = gate.SPEAK_HANGOVER_FRAMES - 1 },
    };

    var g = gate.Gate{};
    for (steps) |step| {
        const fresh = switch (step.event) {
            .speak_on => g.setAgentSpeaking(true),
            .speak_off => g.setAgentSpeaking(false),
            .tick => false,
            .full_on => blk: {
                g.setFullDuplex(true);
                break :blk false;
            },
            .full_off => blk: {
                g.setFullDuplex(false);
                break :blk false;
            },
            .mute_on => blk: {
                g.setMuted(true);
                break :blk false;
            },
            .mute_off => blk: {
                g.setMuted(false);
                break :blk false;
            },
        };
        const active = g.agentGateActive();

        try std.testing.expectEqual(step.fresh, fresh);
        try std.testing.expectEqual(step.active, active);
        try std.testing.expectEqual(step.muted, g.muted);
        try std.testing.expectEqual(step.full, g.full_duplex_active);
        try std.testing.expectEqual(step.hangover, g.speak_hangover);
    }
}

test "mic gate matches reference model across generated event scripts" {
    const scripts = [_][16]GateEvent{
        .{
            .speak_on, .tick,     .speak_off, .tick,
            .full_on,  .tick,     .full_off,  .mute_on,
            .tick,     .mute_off, .speak_on,  .speak_off,
            .tick,     .tick,     .tick,      .tick,
        },
        .{
            .full_on,  .speak_on, .tick,      .speak_off,
            .tick,     .full_off, .tick,      .tick,
            .speak_on, .tick,     .speak_off, .mute_on,
            .mute_off, .tick,     .tick,      .tick,
        },
        .{
            .mute_on,  .speak_on,  .speak_off, .full_on,
            .mute_off, .tick,      .full_off,  .tick,
            .tick,     .tick,      .tick,      .tick,
            .speak_on, .speak_off, .full_on,   .full_off,
        },
        .{
            .speak_on,  .speak_off, .tick,    .tick,
            .speak_on,  .speak_off, .full_on, .tick,
            .full_off,  .tick,      .mute_on, .speak_on,
            .speak_off, .mute_off,  .tick,    .tick,
        },
    };

    for (scripts) |script| {
        var g = gate.Gate{};
        var expected = GateReference{};

        for (script) |event| {
            const fresh = applyGateEvent(&g, event);
            const expected_fresh = expected.apply(event);
            const active = g.agentGateActive();
            const expected_active = expected.agentGateActive();

            try std.testing.expectEqual(expected_fresh, fresh);
            try std.testing.expectEqual(expected_active, active);
            try std.testing.expectEqual(expected.muted, g.muted);
            try std.testing.expectEqual(expected.full_duplex_active, g.full_duplex_active);
            try std.testing.expectEqual(expected.agent_speaking, g.agent_speaking);
            try std.testing.expectEqual(expected.speak_hangover, g.speak_hangover);
        }
    }
}

test "decimator emits 160 samples for one 10ms 48k frame" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var out = [_]i16{0} ** decimator.SAMPLES_16K;

    for (0..decimator.PAIRS_48K) |i| {
        stereo[i * 2] = 1000 << pcm.SHIFT;
        stereo[i * 2 + 1] = 1000 << pcm.SHIFT;
    }

    const result = d.decimate(stereo[0..], out[0..]);
    try std.testing.expectEqual(@as(usize, decimator.SAMPLES_16K), result.samples);
    try std.testing.expect(result.peak > 0);
    try std.testing.expect(result.mean > 0);
}

test "decimator handles partial frames without overrunning output" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (123 * 2);
    var out = [_]i16{0} ** decimator.SAMPLES_16K;

    for (0..123) |i| {
        stereo[i * 2] = @as(i32, @intCast(i)) << pcm.SHIFT;
        stereo[i * 2 + 1] = @as(i32, @intCast(i)) << pcm.SHIFT;
    }

    const result = d.decimate(stereo[0..], out[0..]);
    try std.testing.expectEqual(@as(usize, 41), result.samples);
}

test "decimator can process 960-pair barge-in frames in safe chunks" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (960 * 2);
    var out = [_]i16{0} ** decimator.SAMPLES_16K;
    var emitted: usize = 0;
    var off: usize = 0;

    while (off < 960) {
        const pairs: usize = @min(decimator.PAIRS_48K, 960 - off);
        const result = d.decimate(stereo[off * 2 .. (off + pairs) * 2], out[0..]);
        emitted += result.samples;
        off += pairs;
    }

    try std.testing.expectEqual(@as(usize, 320), emitted);
}

test "decimator reset makes identical chunks deterministic" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var out_a = [_]i16{0} ** decimator.SAMPLES_16K;
    var out_b = [_]i16{0} ** decimator.SAMPLES_16K;

    for (0..decimator.PAIRS_48K) |i| {
        const v: i32 = if (i == 20) 20_000 << pcm.SHIFT else 0;
        stereo[i * 2] = v;
        stereo[i * 2 + 1] = v;
    }

    const a = d.decimate(stereo[0..], out_a[0..]);
    d.reset();
    const b = d.decimate(stereo[0..], out_b[0..]);

    try std.testing.expectEqual(a.samples, b.samples);
    try std.testing.expectEqual(a.peak, b.peak);
    try std.testing.expectEqual(a.mean, b.mean);
    try std.testing.expectEqualSlices(i16, out_a[0..a.samples], out_b[0..b.samples]);
}

test "decimator preserves phase across uneven streaming chunks" {
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    for (0..decimator.PAIRS_48K) |i| {
        const selected: i32 = @as(i32, @intCast((i * 37) % 20_000)) - 10_000;
        const other: i32 = 7_000 - @as(i32, @intCast((i * 19) % 14_000));
        setStereoPair(stereo[0..], i, selected, other);
    }

    var full = decimator.Decimator{};
    var chunked = decimator.Decimator{};
    var full_out = [_]i16{0} ** decimator.SAMPLES_16K;
    var chunked_out = [_]i16{0} ** decimator.SAMPLES_16K;
    var scratch = [_]i16{0} ** decimator.SAMPLES_16K;

    const full_result = full.decimate(stereo[0..], full_out[0..]);

    const chunks = [_]usize{ 1, 2, 17, 319, 4, 56, 81 };
    var off: usize = 0;
    var emitted: usize = 0;
    for (chunks) |pairs| {
        const result = chunked.decimate(stereo[off * 2 .. (off + pairs) * 2], scratch[0..]);
        std.mem.copyForwards(i16, chunked_out[emitted .. emitted + result.samples], scratch[0..result.samples]);
        emitted += result.samples;
        off += pairs;
    }

    try std.testing.expectEqual(decimator.PAIRS_48K, off);
    try std.testing.expectEqual(full_result.samples, emitted);
    try std.testing.expectEqualSlices(i16, full_out[0..full_result.samples], chunked_out[0..emitted]);
}

test "decimator chunking property holds across generated patterns" {
    const scripts = [_][9]usize{
        .{ 1, 2, 17, 319, 4, 56, 81, 479, 1 },
        .{ 160, 3, 5, 7, 11, 13, 17, 264, 480 },
        .{ 31, 47, 53, 59, 61, 67, 71, 91, 480 },
    };
    const patterns = [_]u8{ 0, 1, 2, 3 };

    for (patterns) |pattern| {
        var stereo = [_]i32{0} ** (960 * 2);
        for (0..960) |i| {
            const selected: i32 = switch (pattern) {
                0 => @as(i32, @intCast((i * 137) % 30_000)) - 15_000,
                1 => if (i % 2 == 0) 12_000 else -12_000,
                2 => if (i % 97 == 0) 18_000 else @as(i32, @intCast((i * 17) % 5000)) - 2500,
                else => if ((i / 16) % 2 == 0) @as(i32, @intCast(i % 16)) * 1000 else 15_000 - @as(i32, @intCast(i % 16)) * 1000,
            };
            const other = 10_000 - @as(i32, @intCast((i * 29) % 20_000));
            setStereoPair(stereo[0..], i, selected, other);
        }

        var reference_decim = decimator.Decimator{};
        var reference = [_]i16{0} ** 320;
        var scratch = [_]i16{0} ** decimator.SAMPLES_16K;
        var reference_emitted: usize = 0;
        for (0..2) |chunk| {
            const result = reference_decim.decimate(stereo[chunk * decimator.PAIRS_48K * 2 .. (chunk + 1) * decimator.PAIRS_48K * 2], scratch[0..]);
            std.mem.copyForwards(i16, reference[reference_emitted .. reference_emitted + result.samples], scratch[0..result.samples]);
            reference_emitted += result.samples;
        }
        try std.testing.expectEqual(@as(usize, 320), reference_emitted);

        for (scripts) |script| {
            var chunked_decim = decimator.Decimator{};
            var chunked = [_]i16{0} ** 320;
            var emitted: usize = 0;
            var off: usize = 0;
            for (script) |pairs| {
                const result = chunked_decim.decimate(stereo[off * 2 .. (off + pairs) * 2], scratch[0..]);
                std.mem.copyForwards(i16, chunked[emitted .. emitted + result.samples], scratch[0..result.samples]);
                emitted += result.samples;
                off += pairs;
            }

            try std.testing.expectEqual(@as(usize, 960), off);
            try std.testing.expectEqual(reference_emitted, emitted);
            try std.testing.expectEqualSlices(i16, reference[0..reference_emitted], chunked[0..emitted]);
        }
    }
}

test "decimator golden silence stays silent" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var out = [_]i16{123} ** decimator.SAMPLES_16K;

    const result = d.decimate(stereo[0..], out[0..]);

    try std.testing.expectEqual(@as(usize, decimator.SAMPLES_16K), result.samples);
    try std.testing.expectEqual(@as(i32, 0), result.peak);
    try std.testing.expectEqual(@as(i32, 0), result.mean);
    for (out[0..result.samples]) |sample| {
        try std.testing.expectEqual(@as(i16, 0), sample);
    }
}

test "decimator golden constant shows FIR warmup and unity gain" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var out = [_]i16{0} ** decimator.SAMPLES_16K;
    fillStereo(stereo[0..], 1000, -12000);

    const result = d.decimate(stereo[0..], out[0..]);

    try std.testing.expectEqual(@as(usize, decimator.SAMPLES_16K), result.samples);
    try std.testing.expectEqualSlices(i16, &[_]i16{ 2, -8, -19, 641, 1055, 994, 1000, 1000 }, out[0..8]);
    try std.testing.expectEqual(@as(i16, 1000), out[result.samples - 1]);
}

test "decimator golden impulse follows FIR taps at decimated positions" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var out = [_]i16{0} ** decimator.SAMPLES_16K;
    setStereoPair(stereo[0..], 0, 16000, -3000);

    const result = d.decimate(stereo[0..], out[0..]);

    try std.testing.expectEqual(@as(usize, decimator.SAMPLES_16K), result.samples);
    try std.testing.expectEqualSlices(i16, &[_]i16{ 44, -212, 590, 4514, 590, -212, 44, 0 }, out[0..8]);
}

test "decimator ignores unselected stereo slot" {
    var clean_decim = decimator.Decimator{};
    var noisy_decim = decimator.Decimator{};
    var clean = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var noisy = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var clean_out = [_]i16{0} ** decimator.SAMPLES_16K;
    var noisy_out = [_]i16{0} ** decimator.SAMPLES_16K;

    for (0..decimator.PAIRS_48K) |i| {
        const selected: i32 = @as(i32, @intCast((i * 23) % 8_000)) - 4_000;
        const unrelated: i32 = if (i % 2 == 0) 20_000 else -20_000;
        setStereoPair(clean[0..], i, selected, 0);
        setStereoPair(noisy[0..], i, selected, unrelated);
    }

    const clean_result = clean_decim.decimate(clean[0..], clean_out[0..]);
    const noisy_result = noisy_decim.decimate(noisy[0..], noisy_out[0..]);

    try std.testing.expectEqual(clean_result.samples, noisy_result.samples);
    try std.testing.expectEqual(clean_result.peak, noisy_result.peak);
    try std.testing.expectEqual(clean_result.mean, noisy_result.mean);
    try std.testing.expectEqualSlices(i16, clean_out[0..clean_result.samples], noisy_out[0..noisy_result.samples]);
}

test "decimator respects small output slices" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var out = [_]i16{-1234} ** 8;
    fillStereo(stereo[0..], 8000, -8000);

    const result = d.decimate(stereo[0..], out[0..3]);

    try std.testing.expectEqual(@as(usize, 3), result.samples);
    try std.testing.expect(result.peak > 0);
    try std.testing.expect(result.mean != 0);
    for (out[3..]) |sample| {
        try std.testing.expectEqual(@as(i16, -1234), sample);
    }
}

test "decimator output length matrix never writes past caller buffer" {
    const lengths = [_]usize{ 0, 1, 2, 159, 160 };

    for (lengths) |len| {
        var d = decimator.Decimator{};
        var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
        var out = [_]i16{-2222} ** decimator.SAMPLES_16K;
        fillStereo(stereo[0..], 6000, -6000);

        const result = d.decimate(stereo[0..], out[0..len]);

        try std.testing.expectEqual(len, result.samples);
        for (out[len..]) |sample| {
            try std.testing.expectEqual(@as(i16, -2222), sample);
        }
    }
}

test "decimator undersized output drops samples but preserves stream state" {
    const first_chunk = decimator.PAIRS_48K * 2;
    const second_chunk = first_chunk * 2;
    const lengths = [_]usize{ 0, 1, 2, 3, 159 };

    var stereo = [_]i32{0} ** second_chunk;
    for (0..decimator.PAIRS_48K * 2) |i| {
        const selected: i32 = @as(i32, @intCast((i * 41) % 24_000)) - 12_000;
        const other: i32 = @as(i32, @intCast((i * 17) % 18_000)) - 9_000;
        setStereoPair(stereo[0..], i, selected, other);
    }

    for (lengths) |first_len| {
        var reference_decim = decimator.Decimator{};
        var limited_decim = decimator.Decimator{};
        var reference_first = [_]i16{0} ** decimator.SAMPLES_16K;
        var reference_second = [_]i16{0} ** decimator.SAMPLES_16K;
        var limited_first = [_]i16{-999} ** decimator.SAMPLES_16K;
        var limited_second = [_]i16{0} ** decimator.SAMPLES_16K;

        const reference_first_result = reference_decim.decimate(stereo[0..first_chunk], reference_first[0..]);
        const reference_second_result = reference_decim.decimate(stereo[first_chunk..second_chunk], reference_second[0..]);
        const limited_first_result = limited_decim.decimate(stereo[0..first_chunk], limited_first[0..first_len]);
        const limited_second_result = limited_decim.decimate(stereo[first_chunk..second_chunk], limited_second[0..]);

        try std.testing.expectEqual(@as(usize, decimator.SAMPLES_16K), reference_first_result.samples);
        try std.testing.expectEqual(first_len, limited_first_result.samples);
        try std.testing.expectEqual(reference_second_result.samples, limited_second_result.samples);
        try std.testing.expectEqual(reference_second_result.peak, limited_second_result.peak);
        try std.testing.expectEqual(reference_second_result.mean, limited_second_result.mean);
        try std.testing.expectEqualSlices(i16, reference_second[0..reference_second_result.samples], limited_second[0..limited_second_result.samples]);
        for (limited_first[first_len..]) |sample| {
            try std.testing.expectEqual(@as(i16, -999), sample);
        }
    }
}

test "decimator saturated raw input keeps metrics bounded" {
    var d = decimator.Decimator{};
    var stereo = [_]i32{0} ** (decimator.PAIRS_48K * 2);
    var out = [_]i16{0} ** decimator.SAMPLES_16K;

    for (0..decimator.PAIRS_48K) |i| {
        const selected: i32 = if (i % 2 == 0) std.math.maxInt(i32) else std.math.minInt(i32);
        setStereoPairRaw(stereo[0..], i, selected, 0);
    }

    const result = d.decimate(stereo[0..], out[0..]);

    try std.testing.expectEqual(@as(usize, decimator.SAMPLES_16K), result.samples);
    try std.testing.expect(result.peak >= 0);
    try std.testing.expect(result.peak <= std.math.maxInt(i16));
    try std.testing.expect(result.mean >= std.math.minInt(i16));
    try std.testing.expect(result.mean <= std.math.maxInt(i16));
    for (out[0..result.samples]) |sample| {
        try std.testing.expect(sample >= std.math.minInt(i16));
        try std.testing.expect(sample <= std.math.maxInt(i16));
    }
}

test "aec scaled telemetry math never panics on bad floats" {
    try std.testing.expectEqual(@as(i32, -1), aec.scaled(null, 1000.0));
    try std.testing.expectEqual(@as(i32, -2), aec.scaled(std.math.nan(f32), 1000.0));
    try std.testing.expectEqual(std.math.maxInt(i32), aec.scaled(1.0e30, 1000.0));
    try std.testing.expectEqual(std.math.minInt(i32), aec.scaled(-1.0e30, 1000.0));
    try std.testing.expectEqual(std.math.maxInt(i32), aec.scaled(std.math.inf(f32), 1000.0));
    try std.testing.expectEqual(std.math.minInt(i32), aec.scaled(-std.math.inf(f32), 1000.0));
    try std.testing.expectEqual(@as(i32, 1234), aec.milli(1.234));
}

test "aec float comparisons reject NaN and honor epsilon" {
    try std.testing.expect(aec.floatsClose(1.0, 1.005, 0.01));
    try std.testing.expect(!aec.floatsClose(1.0, 1.02, 0.01));
    try std.testing.expect(!aec.floatsClose(std.math.nan(f32), 1.0, 0.01));
    try std.testing.expect(!aec.floatsClose(1.0, std.math.nan(f32), 0.01));
    try std.testing.expect(!aec.floatsClose(std.math.inf(f32), std.math.inf(f32), 0.0));
    try std.testing.expect(!aec.floatsClose(1.0, 1.0, -0.01));
}

test "aec command encoding is little-endian and stable" {
    const i32_req = aec.makeI32Write(33, 90, 0x11223344);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 33, 90, 4, 0x44, 0x33, 0x22, 0x11 }, i32_req[0..]);

    var f32_bytes: [4]u8 = undefined;
    aec.writeF32LE(&f32_bytes, 1.0);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x80, 0x3f }, f32_bytes[0..]);
    try std.testing.expect(aec.floatsClose(aec.readF32LE(&f32_bytes), 1.0, 0.0));

    const pair_req = aec.makeF32PairWrite(33, 81, 1.0, -2.0);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        33,   81,   8,
        0x00, 0x00, 0x80,
        0x3f, 0x00, 0x00,
        0x00, 0xc0,
    }, pair_req[0..]);
}

test "aec signed i32 little-endian round trips boundary values" {
    var bytes: [4]u8 = undefined;

    aec.writeI32LE(&bytes, -2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xfe, 0xff, 0xff, 0xff }, bytes[0..]);
    try std.testing.expectEqual(@as(i32, -2), aec.readI32LE(&bytes));

    aec.writeI32LE(&bytes, std.math.maxInt(i32));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), aec.readI32LE(&bytes));

    aec.writeI32LE(&bytes, std.math.minInt(i32));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), aec.readI32LE(&bytes));

    const req = aec.makeI32Write(7, 8, -2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 7, 8, 4, 0xfe, 0xff, 0xff, 0xff }, req[0..]);
}

test "aec float pair reader decodes little-endian command payloads" {
    const payload = [_]u8{
        0x00, 0x00, 0xc0, 0x3f,
        0x00, 0x00, 0x80, 0xbe,
    };
    const pair = aec.readF32PairLE(&payload);

    try std.testing.expect(aec.floatsClose(pair.first, 1.5, 0.0));
    try std.testing.expect(aec.floatsClose(pair.second, -0.25, 0.0));
}

test "session silence closes only after the min-active window with no activity" {
    // The watchdog boundary with zero activity is whichever gate opens LAST:
    // both the min-active window and the silence window must have elapsed.
    const boundary = @max(session.MIN_ACTIVE_TICKS, session.SILENCE_TICKS);
    var t = session.Timing{};
    t.tick = boundary - 1;
    try std.testing.expect(!t.silenceExpired());
    t.tick = boundary;
    try std.testing.expect(t.silenceExpired());
}

test "session voice activity resets the silence timer" {
    var t = session.Timing{};
    t.tick = session.MIN_ACTIVE_TICKS + 100;
    t.markVoiceActivity(); // spoke just now
    try std.testing.expect(!t.silenceExpired());
    t.tick += session.SILENCE_TICKS - 1;
    try std.testing.expect(!t.silenceExpired());
    t.tick += 1; // exactly SILENCE_TICKS of quiet
    try std.testing.expect(t.silenceExpired());
}

test "session agent-audio hangover holds then releases" {
    var t = session.Timing{};
    t.tick = 500;
    t.noteAgentAudio();
    try std.testing.expect(t.agentAudioActive());
    t.tick += session.AGENT_AUDIO_HANGOVER_TICKS - 1;
    try std.testing.expect(t.agentAudioActive());
    t.tick += 1; // hangover elapsed
    try std.testing.expect(!t.agentAudioActive());
}

test "session keepalive: the agent talking keeps the session alive (field bug)" {
    var t = session.Timing{};

    // Agent talks continuously, well past MIN_ACTIVE + SILENCE. With the AEC
    // cancelling the echo the mic reads silence, so ONLY the keepalive keeps the
    // session open. It must never close mid-reply.
    const talk_until: u32 = session.MIN_ACTIVE_TICKS + session.SILENCE_TICKS + 500;
    while (t.tick < talk_until) : (t.tick += 1) {
        t.noteAgentAudio();
        if (t.agentAudioActive()) t.markVoiceActivity(); // the keepalive
        try std.testing.expect(!t.silenceExpired());
    }

    // Agent stops. The keepalive holds through the hangover, then the silence
    // timer runs and the session finally closes — after, not before, real end.
    var closed_at: ?u32 = null;
    const stop_scan = talk_until + session.AGENT_AUDIO_HANGOVER_TICKS + session.SILENCE_TICKS + 50;
    while (t.tick < stop_scan) : (t.tick += 1) {
        if (t.agentAudioActive()) t.markVoiceActivity(); // hangover keepalive, no new audio
        if (t.silenceExpired() and closed_at == null) closed_at = t.tick;
    }
    try std.testing.expect(closed_at != null);
    try std.testing.expect(closed_at.? >= talk_until + session.SILENCE_TICKS);
}

test "session max duration is a hard cap" {
    var t = session.Timing{};
    t.tick = session.MAX_TICKS - 1;
    try std.testing.expect(!t.maxDurationReached());
    t.tick = session.MAX_TICKS;
    try std.testing.expect(t.maxDurationReached());
}

// ── Session reducer: event traces ────────────────────────────────────────────
// Each test is a replayable event sequence against the pure session state
// machine — the layer where every field bug so far actually lived. A field
// incident's event log should paste straight into a test like these.

/// Drive a fresh session to the live phase (connected, agent active, pre-roll
/// delivered) and return it. This is the common preamble of most traces.
fn liveSession() reducer.State {
    var st = reducer.State{};
    _ = st.step(.{ .agent_active = true });
    _ = st.step(.{ .mic_published = true });
    const a = st.step(.{ .tick = .{ .connection = .connected } });
    std.debug.assert(a.handoff);
    _ = st.step(.{ .preroll_sent = true });
    return st;
}

test "reducer stays out of the room until CONNECTED" {
    var st = reducer.State{};
    _ = st.step(.{ .agent_active = true });
    _ = st.step(.{ .mic_published = true });
    const a = st.step(.{ .tick = .{ .connection = .connecting } });

    try std.testing.expect(!a.ui_active);
    try std.testing.expect(!a.handoff);
    try std.testing.expect(st.phase == .connecting);
}

test "reducer handoff fires exactly once regardless of event order" {
    // Agent event first (it queued while livekit_room_connect was blocking):
    // the first CONNECTED tick lights the ring and hands off in one step.
    var st = reducer.State{};
    _ = st.step(.{ .agent_active = true });
    _ = st.step(.{ .mic_published = true });
    var a = st.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(a.ui_active);
    try std.testing.expect(a.handoff);
    _ = st.step(.{ .preroll_sent = true });
    a = st.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(!a.ui_active);
    try std.testing.expect(!a.handoff);

    // Connection first, agent later: ui_active on the first CONNECTED tick,
    // handoff only once the agent is active.
    var st2 = reducer.State{};
    a = st2.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(a.ui_active);
    try std.testing.expect(!a.handoff);
    _ = st2.step(.{ .agent_active = true });
    _ = st2.step(.{ .mic_published = true });
    a = st2.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(!a.ui_active);
    try std.testing.expect(a.handoff);

    // The agent bouncing later never re-fires the handoff.
    _ = st2.step(.{ .preroll_sent = true });
    _ = st2.step(.{ .agent_active = false });
    _ = st2.step(.{ .agent_active = true });
    _ = st2.step(.{ .mic_published = true });
    a = st2.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(!a.handoff);
}

test "reducer replays the endpointing close and stays terminal" {
    var st = liveSession();
    var a = st.step(.{ .agent_state = .speaking });
    try std.testing.expectEqual(@as(?bool, true), a.mic_gate);

    a = st.step(.{ .agent_state = .close });
    try std.testing.expectEqual(reducer.CloseReason.agent_close, st.phase.done);

    // Terminal: nothing after done produces actions or moves the phase.
    a = st.step(.{ .tick = .{ .connection = .connected, .barge_request = true } });
    try std.testing.expect(!a.publish_barge);
    a = st.step(.{ .agent_state = .speaking });
    try std.testing.expectEqual(@as(?bool, null), a.mic_gate);
    try std.testing.expectEqual(reducer.CloseReason.agent_close, st.phase.done);
}

test "reducer keepalive: speaker audio keeps the session open (field bug)" {
    var st = liveSession();

    // The agent talks (speaker peaks) while the AEC cancels the echo, so the
    // mic reads silence — well past MIN_ACTIVE + SILENCE. The session must
    // never close mid-reply: only the render-peak keepalive holds it open.
    const talk_until = session.MIN_ACTIVE_TICKS + session.SILENCE_TICKS + 500;
    while (st.timing.tick < talk_until) {
        _ = st.step(.{ .tick = .{ .connection = .connected, .render_peak = 2000 } });
        try std.testing.expect(st.phase == .live);
    }

    // Agent stops: the hangover holds briefly, then the full silence window
    // must elapse before the close — after the real end, never before.
    var steps: u32 = 0;
    while (st.phase != .done) : (steps += 1) {
        _ = st.step(.{ .tick = .{ .connection = .connected } });
    }
    try std.testing.expectEqual(reducer.CloseReason.silence, st.phase.done);
    try std.testing.expect(steps >= session.SILENCE_TICKS);
    try std.testing.expect(steps <= session.SILENCE_TICKS + session.AGENT_AUDIO_HANGOVER_TICKS);
}

test "reducer keepalive: the speaking data-channel state keeps the session open" {
    var st = liveSession();
    _ = st.step(.{ .agent_state = .speaking });

    const talk_until = session.MIN_ACTIVE_TICKS + session.SILENCE_TICKS + 500;
    while (st.timing.tick < talk_until) {
        _ = st.step(.{ .tick = .{ .connection = .connected } });
        try std.testing.expect(st.phase == .live);
    }

    const a = st.step(.{ .agent_state = .quiet });
    try std.testing.expectEqual(@as(?bool, false), a.mic_gate);

    // No hangover here (no render audio): the close comes exactly one silence
    // window after the last speaking tick.
    var steps: u32 = 0;
    while (st.phase != .done) : (steps += 1) {
        _ = st.step(.{ .tick = .{ .connection = .connected } });
    }
    try std.testing.expectEqual(reducer.CloseReason.silence, st.phase.done);
    try std.testing.expectEqual(session.SILENCE_TICKS, steps);
}

test "reducer interrupted flushes the render FIFO but is not user activity" {
    var st = liveSession();
    _ = st.step(.{ .agent_state = .speaking });
    for (0..10) |_| _ = st.step(.{ .tick = .{ .connection = .connected } });
    const last_voice = st.timing.last_voice_tick;

    const a = st.step(.{ .agent_state = .interrupted });

    try std.testing.expect(a.flush_render);
    try std.testing.expectEqual(@as(?bool, false), a.mic_gate);
    try std.testing.expect(!st.agent_speaking);
    // The silence timer keeps running from the agent's last audible tick.
    try std.testing.expectEqual(last_voice, st.timing.last_voice_tick);
}

test "reducer barge-in publishes the interrupt and counts as voice activity" {
    var st = liveSession();
    _ = st.step(.{ .agent_state = .speaking });

    const a = st.step(.{ .tick = .{ .connection = .connected, .barge_request = true } });

    try std.testing.expect(a.publish_barge);
    // mic_src already dropped its own gate at detection — no gate action.
    try std.testing.expectEqual(@as(?bool, null), a.mic_gate);
    try std.testing.expect(!st.agent_speaking);
    // The barge tick itself is voice activity (the user is about to talk).
    try std.testing.expectEqual(st.timing.tick - 1, st.timing.last_voice_tick);
}

test "native handoff requires local microphone SID and roomio track, never retries a partial stream" {
    var st = reducer.State{};
    _ = st.step(.{ .agent_active = true });
    var a = st.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(!a.handoff);
    _ = st.step(.{ .mic_published = true });
    a = st.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(a.handoff);
    _ = st.step(.{ .preroll_sent = false });
    try std.testing.expectEqual(reducer.Preroll.given_up, st.preroll);
    for (0..600) |_| {
        a = st.step(.{ .tick = .{ .connection = .connected } });
        try std.testing.expect(!a.handoff);
    }
}

test "reducer silence watchdog closes an agentless session at the boundary" {
    // The agent never joins (no handoff, no audio): the watchdog must still
    // close the session once both the min-active and silence gates open.
    var st = reducer.State{};
    var steps: u32 = 0;
    while (st.phase != .done) : (steps += 1) {
        _ = st.step(.{ .tick = .{ .connection = .connected } });
    }
    try std.testing.expectEqual(reducer.CloseReason.silence, st.phase.done);
    try std.testing.expectEqual(@max(session.MIN_ACTIVE_TICKS, session.SILENCE_TICKS) + 1, steps);
}

test "reducer disconnect wins over a simultaneous silence expiry" {
    var st = reducer.State{};
    st.timing.tick = @max(session.MIN_ACTIVE_TICKS, session.SILENCE_TICKS);
    _ = st.step(.{ .tick = .{ .connection = .ended } });
    try std.testing.expectEqual(reducer.CloseReason.disconnected, st.phase.done);
}

test "reducer max duration caps a conversation with constant voice" {
    var st = liveSession();
    while (st.phase != .done) {
        _ = st.step(.{ .tick = .{ .connection = .connected, .mic_level = reducer.VOICE_LEVEL } });
    }
    try std.testing.expectEqual(reducer.CloseReason.max_duration, st.phase.done);
    try std.testing.expectEqual(session.MAX_TICKS, st.timing.tick);
}

test "reducer aec diagnostics window fires on cadence and resets" {
    var st = liveSession();
    var logs: u32 = 0;
    var first: ?reducer.AecLog = null;
    while (st.timing.tick < reducer.AEC_LOG_PERIOD_TICKS * 2) {
        const a = st.step(.{
            .tick = .{
                .connection = .connected,
                .mic_level = reducer.VOICE_LEVEL,
                .render_peak = 500, // below AGENT_AUDIO_LEVEL: no keepalive
            },
        });
        if (a.log_aec) |win| {
            logs += 1;
            if (first == null) first = win;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), logs);
    try std.testing.expectEqual(@as(u32, 500), first.?.render_peak_window);
    try std.testing.expect(!first.?.keepalive);
}

// ── Boot profile selector ─────────────────────────────────────────────────────
// The mute button arrives as a LATCHED state (each press flips it), so a
// "press" is a state CHANGE between samples. See selector_core.zig.

fn feedSteady(t: *selector.Trigger, muted: bool, ticks: u32) bool {
    for (0..ticks) |_| {
        if (t.feed(muted)) return true;
    }
    return false;
}

test "selector trigger fires on a double tap inside the window" {
    var t = selector.Trigger{};
    try std.testing.expect(!feedSteady(&t, false, 5)); // settled unmuted
    try std.testing.expect(!t.feed(true)); // press 1 (edge)
    try std.testing.expect(!feedSteady(&t, true, 3));
    try std.testing.expect(t.feed(false)); // press 2 (edge) → trigger
}

test "selector trigger ignores a single press and a constant state" {
    var one = selector.Trigger{};
    _ = one.feed(false);
    try std.testing.expect(!one.feed(true)); // just one edge
    try std.testing.expect(!feedSteady(&one, true, selector.TRIGGER_WINDOW_MS / selector.TICK_MS));
    try std.testing.expect(one.expired());

    // A unit that simply boots muted: zero edges, never triggers.
    var muted_boot = selector.Trigger{};
    try std.testing.expect(!feedSteady(&muted_boot, true, selector.TRIGGER_WINDOW_MS / selector.TICK_MS));
    try std.testing.expect(muted_boot.expired());
}

test "selector presses rotate the selection with wraparound" {
    var s = selector.Selector{ .selected = 0, .count = 3 };
    var state = false;
    try std.testing.expectEqual(@as(?usize, null), s.feed(state)); // settle
    for ([_]usize{ 1, 2, 0, 1 }) |expected| {
        state = !state; // one press
        try std.testing.expectEqual(@as(?usize, null), s.feed(state));
        try std.testing.expectEqual(expected, s.selected);
    }
}

test "selector confirms after silence and a press resets the silence timer" {
    var s = selector.Selector{ .selected = 0, .count = 2 };
    _ = s.feed(false); // settle
    _ = s.feed(true); // press → selected 1
    const silence_ticks = selector.CONFIRM_SILENCE_MS / selector.TICK_MS;
    for (0..silence_ticks - 2) |_| {
        try std.testing.expectEqual(@as(?usize, null), s.feed(true));
    }
    _ = s.feed(false); // press near the deadline → selected 0, timer resets
    for (0..silence_ticks - 1) |_| {
        try std.testing.expectEqual(@as(?usize, null), s.feed(false));
    }
    try std.testing.expectEqual(@as(?usize, 0), s.feed(false)); // silence confirm
}

test "selector absolute timeout confirms even while the button keeps toggling" {
    var s = selector.Selector{ .selected = 0, .count = 2 };
    var state = false;
    var confirmed: ?usize = null;
    var ticks: u32 = 0;
    while (confirmed == null) : (ticks += 1) {
        state = !state; // pathological: a press every tick
        confirmed = s.feed(state);
        try std.testing.expect(ticks <= selector.SELECTOR_TIMEOUT_MS / selector.TICK_MS);
    }
}

// ── USB↔agent mic arbitration (modo convivencia) ─────────────────────────────

const arbiter_core = @import("main/core/arbiter_core.zig");

fn feedArb(a: *arbiter_core.Arbiter, capturing: bool, ticks: u32) ?arbiter_core.Transition {
    var last: ?arbiter_core.Transition = null;
    for (0..ticks) |_| {
        if (a.feed(capturing)) |t| last = t;
    }
    return last;
}

test "arbiter yields to USB only after sustained capture" {
    var a = arbiter_core.Arbiter{};
    // A single-tick blip (Sound Settings meter poking the stream) is ignored.
    try std.testing.expectEqual(@as(?arbiter_core.Transition, null), a.feed(true));
    try std.testing.expectEqual(@as(?arbiter_core.Transition, null), a.feed(false));
    try std.testing.expectEqual(arbiter_core.Owner.agent, a.owner);

    // Sustained capture crosses the yield threshold exactly once.
    const t = feedArb(&a, true, arbiter_core.YIELD_AFTER_MS / arbiter_core.TICK_MS);
    try std.testing.expectEqual(arbiter_core.Transition.grant_usb, t.?);
    try std.testing.expectEqual(arbiter_core.Owner.usb, a.owner);
    try std.testing.expectEqual(@as(?arbiter_core.Transition, null), a.feed(true));
}

test "arbiter returns to the agent only after a long capture silence" {
    var a = arbiter_core.Arbiter{};
    _ = feedArb(&a, true, arbiter_core.YIELD_AFTER_MS / arbiter_core.TICK_MS);

    const resume_ticks = arbiter_core.RESUME_AFTER_MS / arbiter_core.TICK_MS;
    // A short gap (call renegotiation) must not bounce ownership.
    try std.testing.expectEqual(@as(?arbiter_core.Transition, null), feedArb(&a, false, resume_ticks - 1));
    try std.testing.expectEqual(@as(?arbiter_core.Transition, null), a.feed(true));
    try std.testing.expectEqual(arbiter_core.Owner.usb, a.owner);

    // A full silence window hands the mic back.
    const t = feedArb(&a, false, resume_ticks);
    try std.testing.expectEqual(arbiter_core.Transition.revoke_usb, t.?);
    try std.testing.expectEqual(arbiter_core.Owner.agent, a.owner);
}

test "arbiter survives pathological flapping without livelock" {
    var a = arbiter_core.Arbiter{};
    var grants: u32 = 0;
    var revokes: u32 = 0;
    var capturing = false;
    for (0..10_000) |i| {
        if (i % 2 == 0) capturing = !capturing; // toggle every other tick
        switch (a.feed(capturing) orelse continue) {
            .grant_usb => grants += 1,
            .revoke_usb => revokes += 1,
        }
    }
    // Flapping faster than both hysteresis windows must never transition.
    try std.testing.expectEqual(@as(u32, 0), grants + revokes);
}

const device_voice = @import("main/core/device_voice.zig");
test "agent binding rejects missing, oversize and replacement identities" {
    var id = device_voice.Identity{};
    try std.testing.expect(!id.matches("agent"));
    try std.testing.expect(!id.bind(""));
    try std.testing.expect(!id.bind(&([_]u8{'a'} ** 128)));
    try std.testing.expect(id.bind("agent-1"));
    try std.testing.expect(id.bind("agent-1"));
    try std.testing.expect(!id.bind("agent-2"));
    try std.testing.expect(!id.matches("agent-2"));
}

test "accepted drain reopens after old RTP is quiet; the agent holds the next reply until resume" {
    var d = device_voice.Drain{};
    d.start();
    d.acknowledge(true);
    for (0..30) |_| try std.testing.expectEqual(device_voice.Drain.Action.none, d.tick(true));
    for (0..14) |_| try std.testing.expectEqual(device_voice.Drain.Action.none, d.tick(false));
    try std.testing.expectEqual(device_voice.Drain.Action.reopen, d.tick(false));
}

test "wake missing ACK or continuous stale output closes within bounded deadline" {
    for ([_]bool{ false, true }) |ack| {
        var d = device_voice.Drain{};
        d.start();
        if (ack) d.acknowledge(true);
        for (0..499) |_| try std.testing.expectEqual(device_voice.Drain.Action.none, d.tick(ack));
        try std.testing.expectEqual(device_voice.Drain.Action.close, d.tick(ack));
    }
}

test "wake rejection resumes policy-controlled speech after conservative local hold" {
    var d = device_voice.Drain{};
    d.start();
    d.acknowledge(false);
    for (0..24) |_| try std.testing.expectEqual(device_voice.Drain.Action.none, d.tick(true));
    try std.testing.expectEqual(device_voice.Drain.Action.reopen, d.tick(true));
    d.acknowledge(true); // late ACK after resolved request is inert
    try std.testing.expectEqual(device_voice.Drain.Action.none, d.tick(false));
}

test "callback session epochs reject teardown and previous rooms" {
    try std.testing.expect(!device_voice.currentSession(0, 1));
    try std.testing.expect(!device_voice.currentSession(2, 1));
    try std.testing.expect(device_voice.currentSession(2, 2));
}

test "wake drain deadline follows elapsed time under delayed ticks" {
    var d = device_voice.Drain{};
    d.start();
    try std.testing.expectEqual(device_voice.Drain.Action.close, d.advance(5000, false));
}

test "local wake immediately flushes renderer and opens mic before remote ACK" {
    var st = liveSession();
    _ = st.step(.{ .agent_state = .speaking });
    const action = st.step(.local_wake);
    try std.testing.expect(action.flush_render and action.publish_barge);
    try std.testing.expectEqual(@as(?bool, false), action.mic_gate);
}

test "wake detection operates during full duplex speech and half duplex tail, respects mute and once per burst" {
    var w = gate.WakeDetector{};
    try std.testing.expect(!w.enabled(false, false));
    try std.testing.expect(w.observe(true));
    try std.testing.expect(w.enabled(false, false)); // full duplex: mic ungated
    try std.testing.expect(!w.enabled(true, false));
    w.detected();
    try std.testing.expect(!w.enabled(false, false));
    try std.testing.expect(!w.observe(true)); // duplicate state is not a new burst
    try std.testing.expect(!w.enabled(false, true));
    _ = w.observe(false);
    try std.testing.expect(w.observe(true));
    try std.testing.expect(w.enabled(false, true));
    _ = w.observe(false);
    try std.testing.expect(w.enabled(false, true)); // existing half duplex hangover
}

test "callback mailbox preserves readiness after saturated queue loses every notification" {
    var mailbox = device_voice.Mailbox{};
    // Model a full notification queue: callbacks still publish, but no queue
    // items are consumed until all these callback notifications were dropped.
    for (0..1000) |_| mailbox.publish(.{ .agent_active = true });
    mailbox.publish(.{ .mic_published = true });
    const snapshot = mailbox.take();
    var st = reducer.State{};
    _ = st.step(.{ .agent_active = snapshot.agent_ready });
    _ = st.step(.{ .mic_published = snapshot.mic_ready });
    const actions = st.step(.{ .tick = .{ .connection = .connected } });
    try std.testing.expect(actions.handoff);
    const again = mailbox.take();
    try std.testing.expect(again.agent_ready and again.mic_ready);
    try std.testing.expect(!st.step(.{ .tick = .{ .connection = .connected } }).handoff);
}

test "callback mailbox latest quiet clears speaking gate despite saturated notifications" {
    var mailbox = device_voice.Mailbox{};
    var st = liveSession();
    _ = st.step(.{ .agent_state = .speaking });
    for (0..1000) |_| mailbox.publish(.{ .agent_state = .speaking });
    mailbox.publish(.{ .agent_state = .quiet });
    const snapshot = mailbox.take();
    const actions = st.step(.{ .agent_state = snapshot.state.? });
    try std.testing.expectEqual(@as(?bool, false), actions.mic_gate);
    try std.testing.expectEqual(reducer.AgentState.quiet, actions.ui_state.?);
    try std.testing.expectEqual(@as(?reducer.AgentState, null), mailbox.take().state);
}

test "callback mailbox latches wake once and retains matching ACK without queue delivery" {
    var mailbox = device_voice.Mailbox{};
    for (0..1000) |_| mailbox.publish(.{ .agent_active = true });
    mailbox.publish(.local_wake);
    var snapshot = mailbox.take();
    var st = liveSession();
    try std.testing.expect(snapshot.local_wake);
    const action = st.step(.local_wake);
    try std.testing.expect(action.flush_render and action.publish_barge);
    try std.testing.expect(!mailbox.take().local_wake); // no replay of prior wake
    var drain = device_voice.Drain{};
    drain.start();
    mailbox.publish(.{ .wake_result = .{ .sequence = 42, .outcome = .accepted } });
    for (0..1000) |_| mailbox.publish(.{ .agent_active = true });
    snapshot = mailbox.take();
    if (snapshot.accepted_sequence == 42) drain.acknowledge(true);
    try std.testing.expectEqual(device_voice.Drain.Action.reopen, drain.advance(250, false));
    // A new wake uses a fresh sequence; retained ACK42 cannot resolve request43.
    drain.start();
    snapshot = mailbox.take();
    if (snapshot.accepted_sequence == 43) drain.acknowledge(true);
    try std.testing.expectEqual(device_voice.Drain.Action.none, drain.advance(250, false));
    mailbox = .{}; // new room resets all latches after old callbacks stop
    snapshot = mailbox.take();
    try std.testing.expect(!snapshot.local_wake and !snapshot.agent_ready and !snapshot.mic_ready);
    try std.testing.expectEqual(@as(u32, 0), snapshot.accepted_sequence);
}

test "callback mailbox close is sticky and cannot be replaced by later speaking updates" {
    var mailbox = device_voice.Mailbox{};
    mailbox.publish(.{ .agent_state = .close });
    for (0..1000) |_| mailbox.publish(.{ .agent_state = .speaking });
    const snapshot = mailbox.take();
    try std.testing.expect(snapshot.close);
    var st = liveSession();
    _ = st.step(.{ .agent_state = .close }); // shell gives close priority
    try std.testing.expectEqual(reducer.CloseReason.agent_close, st.phase.done);
    try std.testing.expect(mailbox.take().close);
}

test "capture owns wake detector and epochs retain collapsed speaking changes and teardown reset" {
    var published: u32 = 0;
    var detector = gate.WakeDetector{};
    published = gate.wakeObservation(published, true, false);
    try std.testing.expect(detector.observePublished(published));
    detector.detected(); // wake races main publishing quiet then a new reply
    published = gate.wakeObservation(published, false, false);
    published = gate.wakeObservation(published, true, false);
    try std.testing.expect(detector.observePublished(published));
    try std.testing.expect(detector.enabled(false, false));
    detector.detected();
    const duplicate = gate.wakeObservation(published, true, false);
    try std.testing.expectEqual(published, duplicate);
    try std.testing.expect(!detector.observePublished(duplicate));
    try std.testing.expect(!detector.enabled(false, false));
    published = gate.wakeObservation(published, false, true);
    try std.testing.expect(!detector.observePublished(published));
    try std.testing.expect(!detector.enabled(false, false));
    try std.testing.expect(!detector.fired);
    published = gate.wakeObservation(published, true, false);
    try std.testing.expect(detector.observePublished(published));
    try std.testing.expect(detector.enabled(false, false));
}

test "first drain advance excludes pre-request blocked idle and uses the actual wake clock origin" {
    const previous_tick_us: i64 = 10_000;
    const request_started_us: i64 = 60_000_000; // long pre-roll/AEC work before wake
    var drain = device_voice.Drain{};
    drain.start();
    drain.acknowledge(false);
    const first_ms = device_voice.drainElapsedMs(previous_tick_us, request_started_us, request_started_us + 10_000);
    try std.testing.expectEqual(@as(u32, 10), first_ms);
    try std.testing.expectEqual(device_voice.Drain.Action.none, drain.advance(first_ms, false));
    try std.testing.expectEqual(@as(u32, 10), drain.elapsed_ms);
    const second_ms = device_voice.drainElapsedMs(request_started_us + 10_000, request_started_us, request_started_us + 249_000);
    try std.testing.expectEqual(device_voice.Drain.Action.none, drain.advance(second_ms, false));
    try std.testing.expectEqual(device_voice.Drain.Action.reopen, drain.advance(1, false));
    // A delay after the request starts is real elapsed time and retains timeout.
    drain.start();
    const delayed_ms = device_voice.drainElapsedMs(previous_tick_us, request_started_us, request_started_us + 5_000_000);
    try std.testing.expectEqual(device_voice.Drain.Action.close, drain.advance(delayed_ms, false));
}

test "startup retains the wake command while the native stream spans multiple batches" {
    const sr: usize = pre_roll.SAMPLE_RATE;
    for ([_]usize{ sr / 2, 2 * sr, 4 * sr, 8 * sr, 14 * sr }) |delay| {
        const wake: usize = 15 * sr;
        const retained = pre_roll.writableSamples(wake, wake, delay);
        const end = wake + retained;
        const start = end - pre_roll.windowSamples(wake, end, pre_roll.SAMPLE_CAPACITY);
        try std.testing.expect(start <= wake);
        try std.testing.expect(end >= wake + @min(delay, sr * 6));
        try std.testing.expectEqual(@min(delay, pre_roll.SAMPLE_CAPACITY), retained);
    }
    try std.testing.expect(pre_roll.BATCH_SAMPLES * 2 < 80_000);
}

test "initial speaking snapshot survives the connected tick" {
    var st = reducer.State{};
    _ = st.step(.{ .agent_state = .speaking });
    try std.testing.expect(!st.step(.{ .tick = .{ .connection = .connected } }).ui_active);
}

test "wake transport failures remain distinct from protected speech" {
    var mailbox = device_voice.Mailbox{};
    mailbox.publish(.{ .wake_result = .{ .sequence = 77, .outcome = .failed } });
    const snapshot = mailbox.take();
    try std.testing.expectEqual(@as(u32, 77), snapshot.failed_sequence);
    try std.testing.expectEqual(@as(u32, 0), snapshot.rejected_sequence);
}

test "speaker drain: waits the minimum even when the speaker is already silent" {
    try std.testing.expect(!session.speakerDrained(session.DRAIN_MIN_MS - session.DRAIN_STEP_MS, false));
    try std.testing.expect(session.speakerDrained(session.DRAIN_MIN_MS, false));
}

test "speaker drain: keeps waiting past the minimum while the agent's tail still plays" {
    try std.testing.expect(!session.speakerDrained(session.DRAIN_MIN_MS, true));
    try std.testing.expect(!session.speakerDrained(session.DRAIN_MAX_MS - session.DRAIN_STEP_MS, true));
}

test "speaker drain: gives up at the cap even if the speaker never goes quiet" {
    try std.testing.expect(session.speakerDrained(session.DRAIN_MAX_MS, true));
}
