"""Disposable LiveKit compatibility probe for docs/SDK_COMPATIBILITY.md.

Requires a local isolated LiveKit server and test-only credentials supplied via
LIVEKIT_URL, LIVEKIT_API_KEY, and LIVEKIT_API_SECRET. It uses the installed
LiveKit Agents/RTC SDK as-is and makes no provider/model or home-service calls.
The harness publishes synthetic PCM tones only. Set PROBE_CASES to a
comma-separated subset of the case IDs listed in main(). It exits nonzero if a
case errors or any compatibility assertion fails.

Example (replace the placeholders with disposable server credentials):
  LIVEKIT_URL=ws://127.0.0.1:27880 \
  LIVEKIT_API_KEY=<test-key> LIVEKIT_API_SECRET=<test-secret> \
  /path/to/pinned-python docs/tools/sdk_compatibility_probe.py
"""

import asyncio, json, math, os, time, uuid
from array import array
import numpy as np
from livekit import api, rtc
from livekit.agents.voice import Agent, AgentSession
from livekit.agents import llm
from livekit.agents.voice.room_io import RoomOptions, AudioInputOptions
from livekit.rtc._proto.track_pb2 import AudioTrackFeature

URL = os.environ["LIVEKIT_URL"]
KEY = os.environ["LIVEKIT_API_KEY"]
SECRET = os.environ["LIVEKIT_API_SECRET"]
TOPIC_PRE = "lk.agent.pre-connect-audio-buffer"
START = time.monotonic()
ACTIVE_AUDIO_STREAMS = []
ACTIVE_AUDIO_TASKS = []

def now(): return time.monotonic() - START

def token(room, identity, kind="standard", *, can_update=False):
    grants = api.VideoGrants(
        room_join=True, room=room, can_publish=True, can_subscribe=True,
        can_publish_data=True, can_publish_sources=["microphone"],
        can_update_own_metadata=can_update,
    )
    return (api.AccessToken(KEY, SECRET).with_identity(identity).with_kind(kind)
            .with_ttl(__import__("datetime").timedelta(minutes=5))
            .with_grants(grants).to_jwt())

def mk_session(**kwargs):
    return AgentSession(
        vad=None, turn_handling={"turn_detection": None},
        aec_warmup_duration=None, user_away_timeout=None, **kwargs
    )

async def wait_for(pred, timeout=5.0, interval=.01, label="condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = pred()
        if value:
            return value
        await asyncio.sleep(interval)
    raise TimeoutError(f"waited {timeout}s for {label}")

def tone_frame(freq, rate, sample_count, start_sample=0, amp=5000):
    xs = array("h", (int(amp * math.sin(2*math.pi*freq*(start_sample+i)/rate)) for i in range(sample_count)))
    return rtc.AudioFrame(xs.tobytes(), rate, 1, sample_count)

def analyze(frame):
    x=np.frombuffer(frame.data,dtype="<i2").astype(np.float64)
    rms=float(np.sqrt(np.mean(x*x))) if len(x) else 0.0
    if len(x)<8 or rms<30: return frame.sample_rate, len(x), round(frame.duration,4), 0, round(rms)
    z=np.abs(np.fft.rfft(x))
    f=np.fft.rfftfreq(len(x),1/frame.sample_rate)
    idx=int(np.argmax(z[1:])+1)
    return frame.sample_rate, len(x), round(frame.duration,4), round(float(f[idx])), round(rms)

def instrument(sess):
    capture=[]
    orig=sess._activity.push_audio
    def wrapped(frame):
        capture.append((now(), *analyze(frame)))
        return orig(frame)
    sess._activity.push_audio=wrapped
    return capture

async def send_pre(participant, sid, freq=440, duration_s=.20, attrs=True):
    rate=16000; n=int(rate*duration_s)
    pcm=array("h",(int(2000*math.sin(2*math.pi*freq*i/rate)) for i in range(n))).tobytes()
    at={"trackId":sid,"sampleRate":str(rate),"channels":"1"} if attrs else {"trackId":sid}
    w=await participant.stream_bytes("sdk-probe",topic=TOPIC_PRE,total_size=len(pcm),attributes=at)
    await w.write(pcm); await w.aclose()
    return len(pcm)

async def send_live(source, freq=880, count=25, rate=48000):
    size=960
    for i in range(count):
        await source.capture_frame(tone_frame(freq,rate,size,i*size,amp=9000))
        await asyncio.sleep(.02)

async def setup_case(*, auto_subscribe=True, identities=("agent","device")):
    room_name="sdk-compat-"+uuid.uuid4().hex[:10]
    agent=rtc.Room()
    await agent.connect(URL,token(room_name,identities[0],"agent",can_update=True),
                        options=rtc.RoomOptions(auto_subscribe=auto_subscribe))
    clients={}
    for ident in identities[1:]:
        c=rtc.Room()
        await c.connect(URL,token(room_name,ident,"standard"))
        clients[ident]=c
    return room_name,agent,clients

async def cleanup(agent, clients, sess=None, sources=()):
    for stream in list(ACTIVE_AUDIO_STREAMS):
        try: await asyncio.wait_for(stream.aclose(), timeout=1)
        except Exception: pass
    ACTIVE_AUDIO_STREAMS.clear()
    if ACTIVE_AUDIO_TASKS:
        for task in ACTIVE_AUDIO_TASKS:
            if not task.done(): task.cancel()
        await asyncio.gather(*ACTIVE_AUDIO_TASKS, return_exceptions=True)
        ACTIVE_AUDIO_TASKS.clear()
    for source in sources:
        try: await source.aclose()
        except Exception: pass
    if sess:
        try: await sess.aclose()
        except Exception as e: print("cleanup_session_error",type(e).__name__)
    for c in clients.values():
        try: await c.disconnect()
        except Exception: pass
    try: await agent.disconnect()
    except Exception: pass

async def publish_mic(dev, label):
    src=rtc.AudioSource(48000,1)
    track=rtc.LocalAudioTrack.create_audio_track(label,src)
    pub=await dev.local_participant.publish_track(
        track,rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE,preconnect_buffer=True)
    )
    return src,pub

async def find_agent_publication(agent, identity, sid):
    def f():
        p=agent.remote_participants.get(identity)
        return p.track_publications.get(sid) if p else None
    return await wait_for(f,timeout=5,label="agent remote mic publication")

async def subscribe(agent, identity, sid):
    pub=await find_agent_publication(agent,identity,sid)
    pub.set_subscribed(True)
    await wait_for(lambda: pub.track is not None,timeout=5,label="manual track subscription")
    return pub

async def standard_preroll():
    room,agent,clients=await setup_case()
    dev=clients["device"]
    attr_events=[]; track_events=[]
    dev.on("participant_attributes_changed",
           lambda changed,part: attr_events.append((now(),part.identity,dict(changed),dict(part.attributes))))
    dev.on("track_published",
           lambda pub,part: track_events.append((now(),part.identity,pub.name,pub.sid)))
    sess=mk_session()
    states=[]
    sess.on("agent_state_changed",lambda ev: states.append((now(),ev.old_state,ev.new_state)))
    await sess.start(Agent(instructions="Synthetic compatibility probe"),room=agent,record=False,session_host=False)
    cap=instrument(sess)
    await wait_for(lambda: (dev.remote_participants.get("agent") and
                           dev.remote_participants["agent"].attributes.get("lk.agent.state")=="listening"),
                   timeout=4,label="published listening attribute")
    src,pub=await publish_mic(dev,"probe-mic")
    remote=await wait_for(lambda: next((p for p in agent.remote_participants.values() if p.identity=="device"),None),
                          timeout=4,label="agent sees device participant")
    await wait_for(lambda: pub.sid in [p.sid for p in remote.track_publications.values()],
                   timeout=4,label="agent sees mic track")
    feats=[AudioTrackFeature.Name(x) for x in pub.audio_features]
    pre_bytes=await send_pre(dev.local_participant,pub.sid)
    await send_live(src)
    await asyncio.sleep(.5)
    rp=dev.remote_participants.get("agent")
    result={"case":"standard_native_preroll","features":feats,"pre_bytes":pre_bytes,
            "capture_count":len(cap),"capture_prefix":cap[:12],
            "agent_attr":dict(rp.attributes) if rp else None,
            "attr_events":[x for x in attr_events if x[1]=="agent"],
            "local_states":states,"agent_output_track_events":[x for x in track_events if x[1]=="agent"]}
    await cleanup(agent,clients,sess,[src])
    return result

class DelayedAgent(Agent):
    def __init__(self,delay):
        super().__init__(instructions="Synthetic delayed startup; no provider calls")
        self.delay=delay
    async def on_enter(self):
        await asyncio.sleep(self.delay)

async def attach_age(delay):
    room,agent,clients=await setup_case(auto_subscribe=False)
    dev=clients["device"]
    events=[]
    dev.on("participant_attributes_changed",
           lambda changed,part: events.append((now(),part.identity,dict(changed),dict(part.attributes))))
    sess=mk_session()
    states=[]
    sess.on("agent_state_changed",lambda ev: states.append((now(),ev.old_state,ev.new_state)))
    await sess.start(Agent(instructions="Synthetic standard session"),room=agent,record=False,session_host=False)
    cap=instrument(sess)
    src,pub=await publish_mic(dev,"age-mic")
    # Complete the native byte stream before subscribing the actual mic track.
    remote=await wait_for(lambda:next((p for p in agent.remote_participants.values() if p.identity=="device"),None),
                          timeout=4,label="age-test device participant")
    remote_pub=await wait_for(lambda:remote.track_publications.get(pub.sid),timeout=4,label="age-test mic publication")
    nbytes=await send_pre(dev.local_participant,pub.sid)
    send_at=now()
    await asyncio.sleep(delay)
    remote_pub.set_subscribed(True)
    await wait_for(lambda:remote_pub.track is not None,timeout=4,label="age-test delayed mic attachment")
    await asyncio.sleep(.2)
    await send_live(src)
    if delay<1.0:
        await send_pre(dev.local_participant,pub.sid,freq=660)
        await asyncio.sleep(.1)
        await send_live(src,count=8)
    await asyncio.sleep(.4)
    result={"case":"preconnect_arrives_before_track_attachment","age_delay_s":delay,
            "pre_bytes":nbytes,"capture_prefix":cap[:12],
            "pre_tone_frames":sum(1 for row in cap if 400<=row[4]<=480 and row[5]>100),
            "live_tone_frames":sum(1 for row in cap if 800<=row[4]<=960 and row[5]>100),
            "repeat_pre_tone_frames":sum(1 for row in cap if 640<=row[4]<=680 and row[5]>100),
            "agent_attr_events":[x for x in events if x[1]=="agent"],"local_states":states}
    await cleanup(agent,clients,sess,[src])
    return result


async def preconnect_sent_before_roomio_registration():
    # Match room connect + mic subscription before session.start; send while no
    # native RoomIO byte-stream handler is registered yet.
    room,agent,clients=await setup_case(auto_subscribe=True)
    dev=clients["device"]
    src,pub=await publish_mic(dev,"pre-roomio-mic")
    remote=await wait_for(lambda:next((p for p in agent.remote_participants.values() if p.identity=="device"),None),
                          timeout=4,label="pre-RoomIO device participant")
    remote_pub=await wait_for(lambda:remote.track_publications.get(pub.sid),timeout=4,label="pre-RoomIO mic publication")
    await wait_for(lambda:remote_pub.track is not None,timeout=4,label="pre-RoomIO mic subscription")
    pre_bytes=await send_pre(dev.local_participant,pub.sid)
    sent_before_start=now()
    sess=mk_session(); states=[]
    sess.on("agent_state_changed",lambda ev:states.append((now(),ev.old_state,ev.new_state)))
    await sess.start(Agent(instructions="Synthetic registration-race probe"),room=agent,record=False,session_host=False)
    registered_after_start=now()
    cap=instrument(sess)
    # Stream >3 s so live frames still arrive after RoomIO's default wait times out.
    await send_live(src,count=180)
    await asyncio.sleep(.2)
    result={"case":"preroll_sent_before_roomio_registration",
            "pre_bytes":pre_bytes,"sent_before_session_start_s":round(sent_before_start,3),
            "session_started_and_handler_registered_s":round(registered_after_start,3),
            "registration_lag_s":round(registered_after_start-sent_before_start,3),
            "capture_prefix":cap[:12],
            "pre_tone_frames":sum(1 for row in cap if 400<=row[4]<=480 and row[5]>100),
            "live_tone_frames":sum(1 for row in cap if 800<=row[4]<=960 and row[5]>100),
            "local_states":states}
    await cleanup(agent,clients,sess,[src])
    return result


class DelayedRealtimeModel(llm.RealtimeModel):
    """Local framework test double; delays the awaited model-session update, with no network."""
    def __init__(self, delay_s):
        super().__init__(capabilities=llm.RealtimeCapabilities(
            message_truncation=False, turn_detection=False, user_transcription=False,
            auto_tool_reply_generation=False, audio_output=True, manual_function_calls=False,
            can_disable_turn_detection=True))
        self.delay_s=delay_s
        self.session_obj=None
        self.update_started_at=None
        self.update_finished_at=None
    def session(self, *, turn_detection_disabled=False):
        self.session_obj=DelayedRealtimeSession(self)
        return self.session_obj
    async def aclose(self): pass

class DelayedRealtimeSession(llm.RealtimeSession):
    def __init__(self, model):
        super().__init__(model)
        self._chat_ctx=llm.ChatContext()
        self._tools=llm.ToolContext([])
        self.audio=[]
        self._did_delay=False
    @property
    def chat_ctx(self): return self._chat_ctx
    @property
    def tools(self): return self._tools
    async def update_instructions(self,instructions):
        if not self._did_delay:
            self._did_delay=True
            self.realtime_model.update_started_at=now()
            await asyncio.sleep(self.realtime_model.delay_s)
            self.realtime_model.update_finished_at=now()
    async def update_chat_ctx(self,chat_ctx): self._chat_ctx=chat_ctx
    async def update_tools(self,tools): self._tools=llm.ToolContext(tools)
    def update_options(self,*,tool_choice=None): pass
    def push_audio(self,frame): self.audio.append((now(),*analyze(frame)))
    def push_video(self,frame): pass
    def generate_reply(self,*,instructions=None,tool_choice=None,tools=None):
        return asyncio.get_running_loop().create_future()
    def commit_audio(self): pass
    def clear_audio(self): pass
    def interrupt(self): pass
    def truncate(self,*,message_id,modalities,audio_end_ms,audio_transcript=None): pass
    async def aclose(self): pass

async def delayed_readiness(timeout=3.0, send_after_ready=True):
    # Match reliable agent order: room connected first; device mic published/subscribed first.
    room,agent,clients=await setup_case(auto_subscribe=True)
    dev=clients["device"]
    attr_events=[]; track_events=[]; native_wait=[]
    dev.on("participant_attributes_changed",
           lambda changed,part: attr_events.append((now(),part.identity,dict(changed),dict(part.attributes))))
    dev.on("track_published",
           lambda pub,part: track_events.append((now(),part.identity,pub.name,pub.sid)))
    src,pub=await publish_mic(dev,"delayed-mic")
    remote=await wait_for(lambda: next((p for p in agent.remote_participants.values() if p.identity=="device"),None),
                          timeout=4,label="device before session.start")
    remote_pub=await wait_for(lambda: remote.track_publications.get(pub.sid),timeout=4,label="early mic publication")
    await wait_for(lambda: remote_pub.track is not None,timeout=4,label="early mic subscription")
    model=DelayedRealtimeModel(4.25)
    sess=mk_session(llm=model)
    states=[]
    sess.on("agent_state_changed",lambda ev: states.append((now(),ev.old_state,ev.new_state)))
    from livekit.agents.voice.room_io._pre_connect_audio import PreConnectAudioHandler
    original_wait=PreConnectAudioHandler.wait_for_data
    async def observed_wait(self,track_id):
        native_wait.append({"started_at_s":round(now(),4),"track_id_seen":bool(track_id)})
        try:
            frames=await original_wait(self,track_id)
            native_wait[-1]["returned_at_s"]=round(now(),4)
            native_wait[-1]["frames_returned"]=len(frames)
            return frames
        except asyncio.TimeoutError:
            native_wait[-1]["timed_out_at_s"]=round(now(),4)
            raise
    PreConnectAudioHandler.wait_for_data=observed_wait
    start_task=asyncio.create_task(sess.start(Agent(instructions="Synthetic realtime compatibility probe"),room=agent,
                                              room_options=RoomOptions(audio_input=AudioInputOptions(pre_connect_audio_timeout=timeout)),
                                              record=False,session_host=False))
    result={}
    try:
        await wait_for(lambda:any(new=="listening" for _,old,new in states),timeout=8,label="delayed session listening")
        listen_at=next((t for t,old,new in states if new=="listening"),None)
        await start_task
        state_attr_at=next((t for t,ident,ch,attrs in attr_events
                            if ident=="agent" and ch.get("lk.agent.state")=="listening"),None)
        cap=instrument(sess)
        pre_bytes=await send_pre(dev.local_participant,pub.sid) if send_after_ready else None
        await send_live(src)
        await asyncio.sleep(.35)
        result={"case":"realtime_startup_native_wait","configured_timeout_s":timeout,
                "mic_track_published_before_session_start":True,"roomio_wait":native_wait,
                "fake_realtime_update_started_at_s":model.update_started_at,
                "fake_realtime_update_finished_at_s":model.update_finished_at,
                "realtime_session_audio_frames":len(model.session_obj.audio) if model.session_obj else 0,
                "realtime_capture_prefix":model.session_obj.audio[:12] if model.session_obj else [],
                "realtime_pre_tone_frames":sum(1 for row in (model.session_obj.audio if model.session_obj else []) if 400<=row[4]<=480 and row[5]>100),
                "realtime_live_tone_frames":sum(1 for row in (model.session_obj.audio if model.session_obj else []) if 800<=row[4]<=960 and row[5]>100),
                "listening_at_s":round(listen_at,3) if listen_at is not None else None,
                "state_attr_listening_at_s":round(state_attr_at,3) if state_attr_at is not None else None,
                "pre_sent_after_ready":bool(pre_bytes),"pre_bytes":pre_bytes,"capture_prefix":cap[:12],
                "pre_tone_frames":sum(1 for row in cap if 400<=row[4]<=480 and row[5]>100),
                "live_tone_frames":sum(1 for row in cap if 800<=row[4]<=960 and row[5]>100),
                "local_states":states,"agent_attr_events":[x for x in attr_events if x[1]=="agent"],
                "agent_output_track_events":[x for x in track_events if x[1]=="agent"]}
    finally:
        if not start_task.done():
            try: await start_task
            except Exception: pass
        PreConnectAudioHandler.wait_for_data=original_wait
        await cleanup(agent,clients,sess,[src])
    return result


async def output_track_triggered_preroll():
    # Signal on the standard RoomIO output publication while provider/session setup is pending.
    room,agent,clients=await setup_case(auto_subscribe=True)
    dev=clients["device"]; track_events=[]; attr_events=[]; native_wait=[]
    output_ready=asyncio.Event(); sent_at=[]
    dev.on("participant_attributes_changed",
           lambda changed,part:attr_events.append((now(),part.identity,dict(changed),dict(part.attributes))))
    def on_track_published(pub,participant):
        if participant.identity=="agent":
            track_events.append((now(),pub.name,pub.sid))
            if pub.name=="roomio_audio": output_ready.set()
    dev.on("track_published",on_track_published)
    src,pub=await publish_mic(dev,"early-ready-mic")
    remote=await wait_for(lambda:next((p for p in agent.remote_participants.values() if p.identity=="device"),None),
                          timeout=4,label="early-ready device participant")
    remote_pub=await wait_for(lambda:remote.track_publications.get(pub.sid),timeout=4,label="early-ready mic pub")
    await wait_for(lambda:remote_pub.track is not None,timeout=4,label="early-ready mic subscription")
    model=DelayedRealtimeModel(4.25); sess=mk_session(llm=model); states=[]
    sess.on("agent_state_changed",lambda ev:states.append((now(),ev.old_state,ev.new_state)))
    from livekit.agents.voice.room_io._pre_connect_audio import PreConnectAudioHandler
    original_wait=PreConnectAudioHandler.wait_for_data
    async def observed_wait(self,track_id):
        native_wait.append({"started_at_s":round(now(),4)})
        try:
            frames=await original_wait(self,track_id)
            native_wait[-1].update({"returned_at_s":round(now(),4),"frames_returned":len(frames)})
            return frames
        except asyncio.TimeoutError:
            native_wait[-1]["timed_out_at_s"]=round(now(),4)
            raise
    PreConnectAudioHandler.wait_for_data=observed_wait
    try:
        start_task=asyncio.create_task(sess.start(Agent(instructions="Synthetic early-track trigger"),
                                                  room=agent,record=False,session_host=False))
        await asyncio.wait_for(output_ready.wait(),timeout=3)
        trigger_at=now()
        pre_bytes=await send_pre(dev.local_participant,pub.sid)
        sent_at.append(now())
        await wait_for(lambda:any(new=="listening" for _,old,new in states),timeout=8,label="early-trigger session listening")
        listen_at=next(t for t,old,new in states if new=="listening")
        await start_task
        cap=instrument(sess)
        await send_live(src)
        await asyncio.sleep(.35)
        result={"case":"preroll_sent_on_standard_roomio_output_track",
                "output_track_events":track_events,"output_track_trigger_at_s":round(trigger_at,3),
                "native_wait":native_wait,"pre_send_at_s":round(sent_at[0],3),
                "fake_realtime_update_started_at_s":model.update_started_at,
                "fake_realtime_update_finished_at_s":model.update_finished_at,
                "listening_at_s":round(listen_at,3),"pre_bytes":pre_bytes,
                "pre_payload_ms":200,"payload_within_250ms_cap":pre_bytes<=8000,
                "capture_prefix":cap[:12],
                "pre_tone_frames":sum(1 for row in cap if 400<=row[4]<=480 and row[5]>100),
                "live_tone_frames":sum(1 for row in cap if 800<=row[4]<=960 and row[5]>100),
                "realtime_session_audio_frames":len(model.session_obj.audio) if model.session_obj else 0,
                "realtime_capture_prefix":model.session_obj.audio[:12] if model.session_obj else [],
                "realtime_pre_tone_frames":sum(1 for row in (model.session_obj.audio if model.session_obj else []) if 400<=row[4]<=480 and row[5]>100),
                "realtime_live_tone_frames":sum(1 for row in (model.session_obj.audio if model.session_obj else []) if 800<=row[4]<=960 and row[5]>100),
                "agent_attr_events":[x for x in attr_events if x[1]=="agent"],
                "local_states":states}
        return result
    finally:
        PreConnectAudioHandler.wait_for_data=original_wait
        if "start_task" in locals() and not start_task.done():
            try: await start_task
            except Exception: pass
        await cleanup(agent,clients,sess,[src])

async def delayed_readiness_track_after_ready():
    # Device connects with no mic track, waits for standard listening state, then publishes.
    room,agent,clients=await setup_case(auto_subscribe=True)
    dev=clients["device"]; events=[]; track_events=[]
    dev.on("participant_attributes_changed",
           lambda changed,part:events.append((now(),part.identity,dict(changed),dict(part.attributes))))
    dev.on("track_published",
           lambda pub,part:track_events.append((now(),part.identity,pub.name,pub.sid)))
    model=DelayedRealtimeModel(4.25)
    sess=mk_session(llm=model)
    states=[]
    sess.on("agent_state_changed",lambda ev:states.append((now(),ev.old_state,ev.new_state)))
    start_task=asyncio.create_task(sess.start(Agent(instructions="Synthetic realtime ready-first probe"),
                                              room=agent,record=False,session_host=False))
    await wait_for(lambda:(dev.remote_participants.get("agent") and
                           dev.remote_participants["agent"].attributes.get("lk.agent.state")=="listening"),
                   timeout=8,label="real listening attribute after fake model startup")
    await start_task
    ready_at=now()
    cap=instrument(sess)
    src,pub=await publish_mic(dev,"ready-mic")
    pre_bytes=await send_pre(dev.local_participant,pub.sid)
    remote=await wait_for(lambda:next((p for p in agent.remote_participants.values() if p.identity=="device"),None),
                          timeout=4,label="ready-first device participant")
    await wait_for(lambda:(remote.track_publications.get(pub.sid) and
                           remote.track_publications[pub.sid].track is not None),
                   timeout=4,label="ready-first mic attach")
    await send_live(src)
    await asyncio.sleep(.3)
    result={"case":"mic_published_after_real_listening_state",
            "listening_at_s":round(ready_at,3),"fake_realtime_update_started_at_s":model.update_started_at,
            "fake_realtime_update_finished_at_s":model.update_finished_at,
            "pre_bytes":pre_bytes,"pre_payload_ms":200,"payload_within_250ms_cap":pre_bytes<=8000,
            "features":[AudioTrackFeature.Name(x) for x in pub.audio_features],
            "capture_prefix":cap[:12],
            "pre_tone_frames":sum(1 for row in cap if 400<=row[4]<=480 and row[5]>100),
            "live_tone_frames":sum(1 for row in cap if 800<=row[4]<=960 and row[5]>100),
            "realtime_session_audio_frames":len(model.session_obj.audio) if model.session_obj else 0,
            "realtime_capture_prefix":model.session_obj.audio[:12] if model.session_obj else [],
            "realtime_pre_tone_frames":sum(1 for row in (model.session_obj.audio if model.session_obj else []) if 400<=row[4]<=480 and row[5]>100),
            "realtime_live_tone_frames":sum(1 for row in (model.session_obj.audio if model.session_obj else []) if 800<=row[4]<=960 and row[5]>100),
            "agent_attr_events":[x for x in events if x[1]=="agent"],"agent_output_track_events":[x for x in track_events if x[1]=="agent"],
            "local_states":states}
    await cleanup(agent,clients,sess,[src])
    return result

async def missing_metadata_fallback():
    room,agent,clients=await setup_case(auto_subscribe=False)
    dev=clients["device"]; sess=mk_session()
    cap_events=[]
    sess.on("agent_state_changed",lambda ev:cap_events.append((now(),ev.old_state,ev.new_state)))
    await sess.start(Agent(instructions="Synthetic missing-metadata fallback"),room=agent,record=False,session_host=False)
    cap=instrument(sess)
    src,pub=await publish_mic(dev,"missing-metadata-mic")
    nbytes=await send_pre(dev.local_participant,pub.sid,freq=440,attrs=False)
    await asyncio.sleep(.1)
    await subscribe(agent,"device",pub.sid)
    await send_live(src)
    await asyncio.sleep(.4)
    result={"case":"missing_preconnect_metadata_falls_back_to_live_audio","pre_bytes":nbytes,
            "required_attributes_omitted":True,"capture_prefix":cap[:12],
            "pre_tone_frames":sum(1 for row in cap if 400<=row[4]<=480 and row[5]>100),
            "live_tone_frames":sum(1 for row in cap if 800<=row[4]<=960 and row[5]>100),
            "local_states":cap_events}
    await cleanup(agent,clients,sess,[src])
    return result

async def send_data(participant,topic,payload):
    await participant.publish_data(json.dumps(payload),topic=topic,reliable=True)

async def interrupt_probe():
    room,agent,clients=await setup_case(identities=("agent","device","attacker"))
    dev,attacker=clients["device"],clients["attacker"]
    sess=mk_session()
    local_states=[]; device_attrs=[]; output_frames=[]; renderer_queue=[]
    device_reply_event=asyncio.Event(); renderer_ack_event=asyncio.Event()
    flush_events=[]; server_replies=[]; unauthorized_senders=[]
    server_reply_at=[]; renderer_ack_at=[]; queue_at_ack=[]
    speech_cancelled=asyncio.Event(); speech_finished=asyncio.Event(); cancel_at=[]; finish_at=[]
    linked_id=None
    sess.on("agent_state_changed",lambda ev:local_states.append((now(),ev.old_state,ev.new_state)))
    dev.on("participant_attributes_changed",
           lambda changed,part:device_attrs.append((now(),part.identity,dict(changed),dict(part.attributes))))
    # Attach the subscriber before the normal RoomIO publishes its output track.
    def on_track(track,pub,participant):
        if pub.name!="roomio_audio": return
        stream=rtc.AudioStream(track)
        ACTIVE_AUDIO_STREAMS.append(stream)
        async def consume():
            async for event in stream:
                output_frames.append((now(),analyze(event.frame)))
                renderer_queue.append(event.frame.duration)
        ACTIVE_AUDIO_TASKS.append(asyncio.create_task(consume()))
    dev.on("track_subscribed",on_track)

    async def handle_control_request(packet):
        nonlocal linked_id
        if packet.topic!="sdk.probe.interrupt": return
        if packet.participant is None or linked_id is None or packet.participant.identity!=linked_id:
            unauthorized_senders.append(packet.participant.identity if packet.participant else None)
            return
        try:
            future=sess.interrupt()  # force=False, so per-speech policy remains authoritative.
            await future
            queue_at_ack.append(float(audio_source.queued_duration))
            reply={"kind":"interrupt_ack","id":"wake-1"}
        except Exception as exc:
            reply={"kind":"interrupt_rejected","type":type(exc).__name__}
        await agent.local_participant.publish_data(
            json.dumps(reply),topic="sdk.probe.interrupt",reliable=True)

    agent.on("data_received",lambda packet:asyncio.create_task(handle_control_request(packet)))
    def on_device_data(packet):
        if packet.participant is None or packet.participant.identity!="agent": return
        try: value=json.loads(packet.data.decode())
        except Exception: return
        server_replies.append(value); server_reply_at.append(now())
        if value.get("kind") in ("interrupt_ack","interrupt_rejected"):
            device_reply_event.set()
        if value.get("kind")=="interrupt_ack":
            flush_events.append({"at_s":now(),"cleared_frames":len(renderer_queue)})
            renderer_queue.clear()  # deterministic stand-in for the device audio renderer flush
            async def ack_renderer():
                await dev.local_participant.publish_data(
                    json.dumps({"kind":"renderer_flushed","id":value.get("id")}),
                    topic="sdk.probe.renderer",reliable=True)
            asyncio.create_task(ack_renderer())
    dev.on("data_received",on_device_data)
    def on_renderer_ack(packet):
        if packet.topic=="sdk.probe.renderer":
            renderer_ack_at.append(now()); renderer_ack_event.set()
    agent.on("data_received",on_renderer_ack)

    await sess.start(Agent(instructions="Synthetic output only"),room=agent,
                     room_options=RoomOptions(participant_identity="device"),
                     record=False,session_host=False)
    linked=await wait_for(lambda:sess._room_io.linked_participant,timeout=3,label="RoomIO linked participant")
    linked_id=linked.identity
    audio_source=sess._room_io._audio_output._audio_source

    async def deterministic_audio():
        try:
            for i in range(500):
                yield tone_frame(660,48000,960,start_sample=i*960,amp=8000)
                await asyncio.sleep(.001)
        except asyncio.CancelledError:
            speech_cancelled.set(); cancel_at.append(now())
            raise
        finally:
            speech_finished.set(); finish_at.append(now())

    speech_handle=sess.say("synthetic deterministic output",audio=deterministic_audio(),
                                 allow_interruptions=True,add_to_chat_ctx=False)
    await wait_for(lambda:len(output_frames)>0,timeout=4,label="actual remote output audio")
    await asyncio.sleep(.15)
    await wait_for(lambda:audio_source.queued_duration>0.02,timeout=3,label="native RoomIO output queue is nonempty")
    queue_before_attack=float(audio_source.queued_duration)
    before_attack=len(output_frames)
    await send_data(attacker.local_participant,"sdk.probe.interrupt",{"kind":"wake","id":"spoofed"})
    await asyncio.sleep(.25)
    after_attack=len(output_frames)
    queue_after_unauthorized=float(audio_source.queued_duration)
    still_speaking_after_attack=after_attack>before_attack and not speech_cancelled.is_set() and not speech_finished.is_set()
    await send_data(dev.local_participant,"sdk.probe.interrupt",{"kind":"wake","id":"wake-1"})
    try: await asyncio.wait_for(device_reply_event.wait(),timeout=3)
    except TimeoutError: pass
    try: await asyncio.wait_for(renderer_ack_event.wait(),timeout=3)
    except TimeoutError: pass
    try: await asyncio.wait_for(speech_cancelled.wait(),timeout=3)
    except TimeoutError: pass
    await asyncio.sleep(.25)
    ack_at=flush_events[0]["at_s"] if flush_events else None
    tone_before_attack=sum(1 for _,a in output_frames[:before_attack] if 600<=a[3]<=720 and a[4]>100)
    tone_after_attack=sum(1 for _,a in output_frames[before_attack:after_attack] if 600<=a[3]<=720 and a[4]>100)
    tone_after_ack=sum(1 for t,a in output_frames if ack_at is not None and t>ack_at and 600<=a[3]<=720 and a[4]>100)
    tone_times=[t for t,a in output_frames if 600<=a[3]<=720 and a[4]>100]
    result={"case":"authorized_interrupt_cancel_and_renderer_flush",
            "linked_participant":linked_id,"unauthorized_senders":unauthorized_senders,
            "frames_before_unauthorized_request":before_attack,
            "frames_after_unauthorized_request":after_attack,
            "roomio_queue_before_unauthorized_ms":round(queue_before_attack*1000,1),
            "roomio_queue_after_unauthorized_ms":round(queue_after_unauthorized*1000,1),
            "unauthorized_request_left_speech_running":still_speaking_after_attack,
            "authorized_reply":server_replies,"device_received_server_reply":device_reply_event.is_set(),
            "device_sent_renderer_flush_ack":True if flush_events else False,
            "agent_received_renderer_ack":renderer_ack_event.is_set(),
            "renderer_flush":([{**flush_events[0],"at_s":round(ack_at,3)}] if flush_events else []),
            "tone_frames_before_unauthorized":tone_before_attack,
            "tone_frames_after_unauthorized":tone_after_attack,
            "tone_frames_after_renderer_flush_ack":tone_after_ack,
            "last_tone_frame_at_s":round(max(tone_times),3) if tone_times else None,
            "interrupt_cancel_at_s":round(cancel_at[0],3) if cancel_at else None,
            "server_reply_received_at_s":round(server_reply_at[0],3) if server_reply_at else None,
            "renderer_ack_received_at_s":round(renderer_ack_at[0],3) if renderer_ack_at else None,
            "renderer_ack_to_last_tone_ms":round((max(tone_times)-ack_at)*1000,1) if tone_times and ack_at is not None else None,
            "roomio_queue_after_interrupt_future_ms":round(queue_at_ack[0]*1000,1) if queue_at_ack else None,
            "speech_generator_cancelled":speech_cancelled.is_set(),
            "speech_generator_finished":speech_finished.is_set(),
            "session_states":local_states,
            "device_agent_attr_changes":[x for x in device_attrs if x[1]=="agent"],
            "speech_handle_type":type(speech_handle).__name__}
    await cleanup(agent,clients,sess)
    return result

async def noninterruptible_probe():
    room,agent,clients=await setup_case(identities=("agent","device"))
    dev=clients["device"]; sess=mk_session()
    output=0; first=asyncio.Event(); replies=[]; errors=[]
    cancelled=asyncio.Event(); finished=asyncio.Event(); cancel_at=[]; finish_at=[]
    def on_track(track,pub,participant):
        if pub.name!="roomio_audio": return
        stream=rtc.AudioStream(track)
        ACTIVE_AUDIO_STREAMS.append(stream)
        async def read():
            nonlocal output
            async for event in stream:
                output+=1; first.set()
        ACTIVE_AUDIO_TASKS.append(asyncio.create_task(read()))
    dev.on("track_subscribed",on_track)
    linked_id=None
    async def handle(packet):
        if packet.topic!="sdk.probe.interrupt" or packet.participant is None or linked_id is None or packet.participant.identity!=linked_id:
            return
        try:
            future=sess.interrupt()
            await future
            reply={"kind":"interrupt_ack"}
        except Exception as exc:
            errors.append(type(exc).__name__)
            reply={"kind":"interrupt_rejected","type":type(exc).__name__}
        await agent.local_participant.publish_data(json.dumps(reply),topic="sdk.probe.interrupt",reliable=True)
    agent.on("data_received",lambda p:asyncio.create_task(handle(p)))
    dev.on("data_received",lambda packet:replies.append(json.loads(packet.data.decode()))
           if packet.participant and packet.participant.identity=="agent" else None)
    await sess.start(Agent(instructions="Synthetic noninterruptible output"),room=agent,record=False,session_host=False)
    linked=await wait_for(lambda:sess._room_io.linked_participant,timeout=3)
    linked_id=linked.identity
    async def audio():
        try:
            for i in range(500):
                yield tone_frame(660,48000,960,start_sample=i*960,amp=8000)
                await asyncio.sleep(.02)
        except asyncio.CancelledError:
            cancelled.set(); cancel_at.append(now()); raise
        finally: finished.set(); finish_at.append(now())
    speech_handle=sess.say("noninterruptible synthetic speech",audio=audio(),allow_interruptions=False,add_to_chat_ctx=False)
    await asyncio.wait_for(first.wait(),timeout=4)
    await asyncio.sleep(.15)
    n0=output
    await send_data(dev.local_participant,"sdk.probe.interrupt",{"kind":"wake","id":"blocked"})
    await asyncio.sleep(.35)
    n1=output
    result={"case":"noninterruptible_policy_preserved","frames_before_request":n0,
            "frames_after_request":n1,"continued_after_request":n1>n0 and not cancelled.is_set(),
            "generator_cancelled_during_probe":cancelled.is_set(),"generator_finished_during_probe":finished.is_set(),
            "errors":errors,"replies":replies,"speech_handle_type":type(speech_handle).__name__}
    await cleanup(agent,clients,sess)
    return result

def annotate_assertions(result):
    case = result.get("case")
    if "error" in result:
        result["status"] = "inconclusive"
        result["assertions"] = {"probe_completed": False}
        return result
    a = {}
    if case == "standard_native_preroll":
        tones = result["capture_prefix"]
        pre = [r for r in tones if 420 <= r[4] <= 460 and r[5] > 100]
        live = [r for r in tones if 800 <= r[4] <= 960 and r[5] > 100]
        duration = sum(r[2] for r in pre) / 24000 if pre else 0
        a = {"feature_advertised": "TF_PRECONNECT_BUFFER" in result["features"],
             "native_input_received_preroll": bool(pre),
             "preroll_precedes_live_audio": bool(pre and live and pre[-1][0] < live[0][0]),
             "resampled_preroll_duration_approximately_200ms": abs(duration-.2) <= .01,
             "remote_client_observed_listening_state": result["agent_attr"].get("lk.agent.state") == "listening"}
    elif case == "preconnect_arrives_before_track_attachment":
        young = result["age_delay_s"] < 1
        a = {"live_audio_reached_roomio": result["live_tone_frames"] > 0,
             "young_buffer_accepted": result["pre_tone_frames"] > 0 if young else result["pre_tone_frames"] == 0,
             "old_buffer_expired": result["pre_tone_frames"] == 0 if not young else True,
             "duplicate_same_sid_not_reinjected": result["repeat_pre_tone_frames"] == 0 if young else True}
    elif case == "preroll_sent_before_roomio_registration":
        a = {"pre_was_sent_before_session_start": result["sent_before_session_start_s"] < result["session_started_and_handler_registered_s"],
             "preroll_not_replayed_after_registration": result["pre_tone_frames"] == 0,
             "live_audio_recovered_after_native_timeout": result["live_tone_frames"] > 0}
    elif case == "realtime_startup_native_wait":
        wait = result["roomio_wait"][0]
        if result["configured_timeout_s"] == 3.0:
            a = {"native_wait_expired_before_slow_model_update": bool(wait.get("timed_out_at_s") and wait["timed_out_at_s"] < result["fake_realtime_update_finished_at_s"]),
                 "late_preroll_not_injected": result["realtime_pre_tone_frames"] == 0,
                 "live_input_continued": result["realtime_live_tone_frames"] > 0}
        else:
            a = {"native_wait_returned_buffered_frames": wait.get("frames_returned", 0) > 0,
                 "preroll_reached_realtime_session": result["realtime_pre_tone_frames"] > 0,
                 "live_input_continued": result["realtime_live_tone_frames"] > 0}
    elif case == "preroll_sent_on_standard_roomio_output_track":
        wait = result["native_wait"][0]
        a = {"output_track_before_listening": result["output_track_trigger_at_s"] < result["listening_at_s"],
             "native_handler_accepted_buffer": wait.get("frames_returned", 0) > 0,
             "preroll_reached_realtime_session": result["realtime_pre_tone_frames"] > 0,
             "live_input_continued": result["realtime_live_tone_frames"] > 0,
             "payload_within_200ms_probe_cap": result["pre_bytes"] <= 6400}
    elif case == "mic_published_after_real_listening_state":
        a = {"feature_advertised": "TF_PRECONNECT_BUFFER" in result["features"],
             "preroll_reached_realtime_session": result["realtime_pre_tone_frames"] > 0,
             "live_input_continued": result["realtime_live_tone_frames"] > 0}
    elif case == "missing_preconnect_metadata_falls_back_to_live_audio":
        a = {"required_metadata_omitted": result["required_attributes_omitted"],
             "malformed_preroll_not_forwarded": result["pre_tone_frames"] == 0,
             "live_input_continued": result["live_tone_frames"] > 0}
    elif case == "authorized_interrupt_cancel_and_renderer_flush":
        a = {"linked_device_identity": result["linked_participant"] == "device",
             "unauthorized_sender_ignored": result["unauthorized_senders"] == ["attacker"] and result["unauthorized_request_left_speech_running"],
             "native_roomio_queue_was_nonempty": result["roomio_queue_before_unauthorized_ms"] > 0,
             "native_queue_remained_nonempty_after_unauthorized": result["roomio_queue_after_unauthorized_ms"] > 0,
             "allowed_speech_generator_cancelled": result["speech_generator_cancelled"],
             "native_roomio_queue_cleared_before_ack": result["roomio_queue_after_interrupt_future_ms"] == 0,
             "server_ack_received": result["device_received_server_reply"],
             "renderer_flushed_and_acknowledged": result["device_sent_renderer_flush_ack"] and result["agent_received_renderer_ack"],
             "agent_state_returned_to_listening": any(old == "speaking" and new == "listening" for _, old, new in result["session_states"]),
             "in_flight_audio_tail_measured": result["renderer_ack_to_last_tone_ms"] is not None}
    elif case == "noninterruptible_policy_preserved":
        a = {"speech_continued": result["continued_after_request"],
             "generator_not_cancelled": not result["generator_cancelled_during_probe"],
             "interrupt_rejected": any(x.get("kind") == "interrupt_rejected" for x in result["replies"])}
    else:
        a = {"known_case": False}
    result["assertions"] = a
    result["status"] = "pass" if a and all(a.values()) else "fail"
    return result


async def main():
    results=[]
    tests=[
        ("standard",standard_preroll),
        ("age_0_2",lambda:attach_age(.2)),
        ("age_1_2",lambda:attach_age(1.2)),
        ("pre_roomio_registration",preconnect_sent_before_roomio_registration),
        ("realtime_startup_default",lambda:delayed_readiness(timeout=3.0)),
        ("output_track_trigger",output_track_triggered_preroll),
        ("realtime_startup_extended",lambda:delayed_readiness(timeout=6.0)),
        ("track_after_ready",delayed_readiness_track_after_ready),
        ("missing_metadata_fallback",missing_metadata_fallback),
        ("interrupt",interrupt_probe),
        ("noninterruptible",noninterruptible_probe),
    ]
    selected=os.environ.get("PROBE_CASES")
    if selected:
        wanted=set(selected.split(","))
        tests=[(name,fn) for name,fn in tests if name in wanted]
    for name,fn in tests:
        try:
            value=annotate_assertions(await fn())
            results.append(value)
            print(json.dumps(value,sort_keys=True))
        except Exception as e:
            results.append({"case":name,"error":type(e).__name__,"detail":str(e)[:300]})
            print(json.dumps(results[-1],sort_keys=True))
    failed=[x for x in results if x.get("status") != "pass"]
    print("SUMMARY",json.dumps({"count":len(results),"failed":len(failed),"cases":[x.get("case") for x in failed]},sort_keys=True))
    if failed:
        raise SystemExit(1)

asyncio.run(main())
