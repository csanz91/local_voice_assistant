//! Pure pre-roll helpers, shared by firmware and host tests.

pub const SAMPLE_RATE: u16 = 16000;
pub const SECONDS: usize = 12;
pub const SAMPLE_CAPACITY: usize = SAMPLE_RATE * SECONDS;
pub const WAKE_LEAD_SAMPLES: usize = SAMPLE_RATE * 2;
/// A credit on the ordered data channel separates successive 64 KiB batches.
pub const BATCH_SAMPLES: usize = 32 * 1024;

pub fn writableSamples(mark: ?u64, written: u64, incoming: usize) usize {
    const wake = mark orelse return incoming;
    return @intCast(@min(incoming, SAMPLE_CAPACITY -| (written - wake)));
}

pub fn windowSamples(wake_mark: u64, total_written: u64, filled: usize) usize {
    if (total_written < wake_mark) return 0;
    const lead: u64 = @min(wake_mark, WAKE_LEAD_SAMPLES);
    const since_mark = total_written - wake_mark;
    return @intCast(@min(@as(u64, filled), since_mark + lead));
}

pub fn availableMs(sample_count: usize) u32 {
    return @intCast(sample_count * 1000 / SAMPLE_RATE);
}

pub fn startIndex(write_idx: usize, count: usize) usize {
    return (write_idx + SAMPLE_CAPACITY - (count % SAMPLE_CAPACITY)) % SAMPLE_CAPACITY;
}

pub const WindowState = struct {
    write_idx: usize = 0,
    filled: usize = 0,
    total_written: u64 = 0,
    wake_mark: u64 = 0,

    pub fn reset(self: *WindowState) void {
        self.* = .{};
    }

    pub fn noteSample(self: *WindowState) void {
        self.write_idx = (self.write_idx + 1) % SAMPLE_CAPACITY;
        if (self.filled < SAMPLE_CAPACITY) self.filled += 1;
        self.total_written += 1;
    }

    pub fn markWake(self: *WindowState) void {
        self.wake_mark = self.total_written;
    }

    pub fn windowSamples(self: WindowState) usize {
        return pre_roll_core.windowSamples(self.wake_mark, self.total_written, self.filled);
    }

    pub fn availableMs(self: WindowState) u32 {
        return pre_roll_core.availableMs(self.windowSamples());
    }

    pub fn startIndex(self: WindowState) usize {
        return pre_roll_core.startIndex(self.write_idx, self.windowSamples());
    }
};

const pre_roll_core = @This();
