//! Pure mic gate state machine. Hardware code owns I2S; this owns decisions.

pub const SPEAK_HANGOVER_FRAMES: u32 = 20; // ~400ms at 20ms frames

pub const Gate = struct {
    muted: bool = false,
    full_duplex_active: bool = false,
    agent_speaking: bool = false,
    speak_hangover: u32 = 0,

    pub fn setMuted(self: *Gate, value: bool) void {
        self.muted = value;
    }

    pub fn setFullDuplex(self: *Gate, value: bool) void {
        self.full_duplex_active = value;
    }

    /// Returns true when this call starts a fresh speaking burst.
    pub fn setAgentSpeaking(self: *Gate, value: bool) bool {
        const fresh_burst = value and !self.agent_speaking;
        if (self.agent_speaking and !value) self.speak_hangover = SPEAK_HANGOVER_FRAMES;
        self.agent_speaking = value;
        return fresh_burst;
    }

    pub fn gatedByAgent(self: *Gate) bool {
        if (self.agent_speaking) return true;
        if (self.speak_hangover > 0) {
            self.speak_hangover -= 1;
            return true;
        }
        return false;
    }

    pub fn agentGateActive(self: *Gate) bool {
        return !self.full_duplex_active and self.gatedByAgent();
    }
};

pub fn channelLooksBad(peak: u32, mean: i32) bool {
    if (peak == 0) return true; // dead: not even room noise
    return @abs(mean) > 15000; // pinned: massive DC, audio crushed by softClip
}

/// Tracks actual remote speech separately from the local gate opened by wake.
/// Duplicate speaking snapshots cannot re-arm a wake within the same burst.
pub const WakeDetector = struct {
    speaking: bool = false,
    fired: bool = false,
    published: u32 = 0,
    /// Audio-task only: consume an atomic state/epoch published by main. Epoch
    /// changes retain a fresh burst even if quiet->speaking collapsed between
    /// capture frames. Bit1 explicitly resets all detector state for teardown.
    pub fn observePublished(self: *WakeDetector, value: u32) bool {
        if (value == self.published) return false;
        self.published = value;
        if (value & 2 != 0) {
            self.speaking = false;
            self.fired = false;
            return false;
        }
        const speaking = value & 1 != 0;
        if (speaking) self.speaking = false;
        return self.observe(speaking);
    }
    pub fn observe(self: *WakeDetector, speaking: bool) bool {
        const fresh = speaking and !self.speaking;
        if (fresh) self.fired = false;
        self.speaking = speaking;
        return fresh;
    }
    pub fn enabled(self: WakeDetector, muted: bool, agent_gated: bool) bool {
        return !muted and !self.fired and (self.speaking or agent_gated);
    }
    pub fn detected(self: *WakeDetector) void {
        self.fired = true;
    }
};

/// Publisher calculation used under CAS; one atomic u32 crosses to capture.
pub fn wakeObservation(current: u32, speaking: bool, reset: bool) u32 {
    if (!reset and (current & 1 != 0) == speaking) return current;
    const epoch = (current & ~@as(u32, 3)) +% 4;
    return epoch | (if (reset) @as(u32, 2) else @as(u32, @intFromBool(speaking)));
}
