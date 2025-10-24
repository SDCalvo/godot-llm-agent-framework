# Voice Assistant Integration Showcase - Design Document

## 🎯 Goal

Create a comprehensive demo scene showcasing the complete voice pipeline: **Microphone → VAD → Deepgram STT → LLM Agent → ElevenLabs TTS → Audio Output**, featuring an animated Weather Artist NPC that manipulates the game environment using tools.

---

## 🎬 User Experience Flow

1. **Test opens** → Services auto-initialize → NPC appears, pipeline status shown
2. **Player speaks**: "Make the sky purple"
3. **Pipeline activates** (visual feedback in real-time):
   - 🎤 **VAD** lights up (white) - detecting speech
   - 📝 **STT** lights up - streaming to Deepgram
   - 🤖 **LLM** lights up - agent processing request
   - 🔧 **Tools** lights up - `set_sky_color("purple")` executing
   - 🗣️ **TTS** lights up - NPC responding with voice
4. **Visual changes happen**: Sky smoothly transitions to purple
5. **NPC speaks**: Speech bubble appears with text + audio plays
6. **Pipeline returns to idle**: Listening for next command

### Advanced Test: Parallel Tool Execution

- **Player**: "Make it look romantic"
- **LLM thinks**: sunset colors + stars + evening lighting
- **Tools execute simultaneously**: All 3 tools called in parallel
- **Visual impact**: Sky, stars, and lighting all change at once!

### Interruption Test:

- **NPC is speaking** (long response)
- **Player speaks**: "Wait, make it night instead"
- **System**: Stops TTS immediately, clears queue, processes new request
- **Result**: Smooth interruption, no audio overlap

---

## 🏗️ Architecture

### Pipeline States

```
IDLE → VAD_LISTENING → STT_PROCESSING → LLM_THINKING → TOOL_EXECUTING → TTS_SPEAKING → IDLE
                ↑                                                                           |
                └───────────────────────────────────────────────────────────────────────────┘
                                    (or interrupted during TTS)
```

### Services Used

- **VADManager** (instance) - TwoVoip AI-powered voice detection
- **DeepgramSTT** (autoload) - Real-time speech-to-text
- **LLMAgent** (instance) - GPT-4o-mini with tools
- **ElevenLabsWrapper** (autoload) - Real-time text-to-speech
- **LLMToolRegistry** (autoload) - Tool registration

### Data Flow

```
Mic Audio (48kHz PCM)
  ↓ VADManager.speech_detected(pcm_data)
Deepgram STT
  ↓ DeepgramSTT.speech_ended(text, confidence)
LLM Agent
  ↓ LLMAgent.delta(text_chunk) → LLMAgent.debug(tool_calls) → LLMAgent.finished()
ElevenLabs TTS
  ↓ ElevenLabsWrapper.audio_chunk_ready(pcm) → playback_finished()
Speaker Output
```

---

## 🎨 UI Layout

### Split Screen (33% Debug | 67% Game)

```
┌─────────────────────────────────────────────────────────────────┐
│                    Voice Assistant Showcase                     │
├──────────────────┬──────────────────────────────────────────────┤
│ DEBUG PANEL      │ GAME WORLD                                   │
│ (33% width)      │ (67% width)                                  │
│                  │                                              │
│ Pipeline Status: │         ✨ ✨ ✨                             │
│ VAD → STT →      │                                              │
│ LLM → Tools →    │            [NPC Sprite]                      │
│ TTS              │          "Hello there!"                      │
│ (white=active)   │                                              │
│                  │                                              │
│ ─────────────    │                                              │
│ STT Transcript:  │     (Purple sky background)                  │
│ "Make sky        │                                              │
│  purple"         │                                              │
│                  │                                              │
│ LLM Output:      │                                              │
│ "I'll change..." │                                              │
│                  │                                              │
│ Tool Calls:      │                                              │
│ set_sky_color()  │                                              │
│ → purple         │                                              │
│                  │                                              │
│ [Clear Log]      │                                              │
└──────────────────┴──────────────────────────────────────────────┘
```

---

## 🔧 Weather Artist Tools

### Tool 1: `set_sky_color`

- **Purpose**: Change background color
- **Parameter**: `color_name` (string) - red, blue, purple, orange, sunset, night, morning
- **Effect**: Smooth color transition over 1 second
- **Return**: `{ok: true, color: "purple", message: "Sky changed to purple"}`

### Tool 2: `spawn_stars`

- **Purpose**: Add twinkling star particles
- **Parameter**: `count` (integer, 1-100) - number of stars
- **Effect**: Spawns stars with twinkle animation in upper 60% of sky
- **Return**: `{ok: true, stars_spawned: 20, message: "Spawned 20 stars"}`

### Tool 3: `set_time_of_day`

- **Purpose**: Change lighting overlay
- **Parameter**: `time` (string) - morning, noon, evening, night
- **Effect**: Smooth lighting tint transition over 1.5 seconds
- **Return**: `{ok: true, time_set: "night", message: "Time set to night"}`

### Why These Tools?

- ✅ **Visual Impact**: Immediate, dramatic changes
- ✅ **Related**: All contribute to atmospheric scene creation
- ✅ **Parallel-friendly**: Can be called together for compound effects
- ✅ **Easy to Test**: Simple voice commands ("make it red", "add stars")

---

## 📋 Implementation Steps

### Step 0: Add TTS Interruption Support ⏸️

**File**: `addons/godot_llm/runtime/audio_services/elevenlabs_wrapper/ElevenLabsWrapper.gd`

- Add `signal playback_interrupted(context_id: String)` after line 80 (after playback_finished signal)
- Add `interrupt()` method to `RealtimePCMPlayer` class after line 752 (before cleanup method)
  - Stops audio player: `audio_player.stop()`
  - Clears audio queue: `audio_queue.clear()`
  - Resets state flags: `is_prebuffered = false`, `synthesis_complete = false`
  - Emits signal via: `wrapper_ref.playback_interrupted.emit(context_id)`

### Step 1: Create Scene Files 📁

- `scenes/VoiceAssistantTest.tscn` - Main scene
- `scenes/VoiceAssistantTest.gd` - Main script

### Step 2: Build Scene Structure 🎨

**VoiceAssistantTest.tscn hierarchy:**

```
VoiceAssistantTest (Node2D) - Root scene node
│
├─ GameWorld (Node2D) - Actual game content (NOT in CanvasLayer)
│  ├─ Background (ColorRect) - Animated sky, fills right 67% of viewport
│  ├─ StarsContainer (Node2D) - Parent for star sprites
│  ├─ LightingOverlay (ColorRect) - Time-of-day tint overlay
│  └─ NPC (Node2D) - Positioned in center of GameWorld
│     ├─ Sprite2D - NPC visual (simple placeholder or animated)
│     ├─ SpeechBubble (Node2D, visible=false)
│     │  ├─ BubbleBackground (NinePatchRect or ColorRect)
│     │  └─ BubbleText (Label, autowrap_mode=3)
│     └─ AnimationPlayer (optional - for idle/talking states)
│
└─ DebugPanel (CanvasLayer) - UI overlay (like TestUI in Test.tscn)
   └─ Control (anchors_preset=15, left 33% via offset_right)
      └─ PanelContainer
         └─ VBoxContainer
            ├─ PipelineStatusPanel (VBoxContainer)
            │  ├─ Label "Pipeline Status:"
            │  └─ PipelineFlow (HBoxContainer)
            │     ├─ VADLabel (Label) "VAD"
            │     ├─ Label "→"
            │     ├─ STTLabel (Label) "STT"
            │     ├─ Label "→"
            │     ├─ LLMLabel (Label) "LLM"
            │     ├─ Label "→"
            │     ├─ ToolLabel (Label) "Tools"
            │     ├─ Label "→"
            │     └─ TTSLabel (Label) "TTS"
            ├─ HSeparator
            ├─ TranscriptPanel (VBoxContainer, size_flags_vertical=3)
            │  ├─ Label "STT Transcript:"
            │  └─ TranscriptLog (RichTextLabel)
            ├─ HSeparator
            ├─ LLMPanel (VBoxContainer, size_flags_vertical=3)
            │  ├─ Label "LLM Output:"
            │  └─ LLMLog (RichTextLabel)
            ├─ HSeparator
            ├─ ToolsPanel (VBoxContainer, size_flags_vertical=3)
            │  ├─ Label "Tool Calls & Results:"
            │  └─ ToolsLog (RichTextLabel)
            └─ ClearButton (Button)

**Key Points:**
- Root is Node2D (proper game scene pattern)
- GameWorld is NOT in CanvasLayer (actual game content)
- DebugPanel uses CanvasLayer for UI overlay
- Control anchoring handles the 33%/67% split via offset_right
```

### Step 3: Implement Core Script Structure 📝

- Import constants (`Message`, `VADManager`)
- Define `PipelineState` enum
- Declare service references
- Create `@onready` UI references

### Step 4: Implement Service Setup 🔌

**`_setup_services()` method:**

1. Create and setup VADManager instance
2. Initialize Deepgram with API key
3. Connect to Deepgram WebSocket
4. Setup ElevenLabs context with voice ID
5. Create realtime PCM player
6. Connect all signals

### Step 5: Register Weather Tools 🛠️

**`_register_weather_tools()` method:**

- Use `LLMToolRegistry.create()` builder pattern
- Use `thread_safe_node_handler(self, "method_name")`
- Implement tool handler methods that return Dictionary

### Step 6: Create Agent 🤖

**`_create_agent()` method:**

- Get tools from registry
- Create agent via `LLMManager.create_agent()`
- Set system prompt for Weather Artist personality
- Connect to `delta`, `finished`, `debug` signals

### Step 7: Implement Pipeline Handlers 🔄

**Event handlers for each stage:**

- `_on_vad_started()` - Handle interruption if needed
- `_on_vad_audio()` - Forward to Deepgram
- `_on_speech_ended()` - Send to LLM
- `_on_agent_delta()` - Stream to TTS + speech bubble
- `_on_agent_debug()` - Log tool calls
- `_on_agent_finished()` - Flush TTS buffer
- `_on_tts_finished()` - Return to listening

### Step 8: Implement Visual Effects 🎆

- `_animate_sky_color()` - Tween background color
- `_spawn_star_particles()` - Create twinkling sprites
- `_set_lighting()` - Tween overlay tint
- `_create_star_texture()` - Generate procedural star

### Step 9: Implement Debug Visualization 📊

- `_update_pipeline_state()` - Highlight active stages
- `_log_transcript()` - Log STT output with confidence
- `_log_llm_output()` - Append LLM text chunks
- `_log_tool_call()` - Log tool invocations
- `_log_tool_result()` - Log tool results

### Step 10: Implement Speech Bubble 💬

- `_append_to_speech_bubble()` - Accumulate text, show bubble
- `_hide_speech_bubble()` - Clear text, hide bubble

### Step 11: Add Test Button to Main Scene 🔘

**Files**: `scenes/Test.tscn` + `scenes/control.gd`

- Add "Voice Assistant" button to button grid
- Add handler to open test window
- Handle window lifecycle (create/destroy on close)

---

## 🧪 Test Scenarios

### Test 1: Single Tool Call

**Command**: "Make the sky purple"
**Expected**:

- Pipeline: VAD → STT → LLM → Tools → TTS
- Tool called: `set_sky_color("purple")`
- Visual: Sky transitions to purple
- NPC: "I've changed the sky to purple for you!"

### Test 2: Parallel Tool Execution

**Command**: "Make it look romantic"
**Expected**:

- LLM interprets: romantic = sunset + stars + evening
- Tools called: `set_sky_color("sunset")` + `spawn_stars(30)` + `set_time_of_day("evening")` **in parallel**
- Visual: All 3 effects happen simultaneously
- NPC: "I've created a romantic atmosphere with a sunset sky, stars, and evening lighting!"

### Test 3: Interruption

**Setup**: Say "Tell me a long story about weather"
**Action**: While NPC is talking, say "Stop, make it night"
**Expected**:

- TTS audio stops immediately
- Speech bubble disappears
- Pipeline processes new request
- Sky changes to night
- NPC responds to new command (not the story)

### Test 4: Complex Request

**Command**: "Make it look like early morning with just a few stars"
**Expected**:

- Tools: `set_sky_color("morning")` + `spawn_stars(5)` + `set_time_of_day("morning")`
- Visual: Warm morning colors + few stars + morning tint
- Demonstrates LLM's ability to interpret nuanced requests

---

## 🚧 Open Questions / Design Decisions

### 1. NPC Animation

- [ ] Should we use AnimatedSprite2D with states (idle, talking, thinking)?
- [ ] Or simple static sprite with scale/rotation tweens?
- [ ] Do we need a placeholder sprite or should we create one?

### 2. Speech Bubble Design

- [ ] Follow traditional game bubble (rounded, tail pointing to NPC)?
- [ ] Or modern UI panel (clean rectangle)?
- [ ] Font size and wrapping behavior?

### 3. Debug Panel Details

- [ ] Should pipeline arrows (→) also highlight with the active stage?
- [ ] Add audio level visualization for VAD?
- [ ] Show token usage / API costs?
- [ ] Add manual "Reset Sky" button?

### 4. Error Handling

- [ ] What if API keys are missing? Show error panel in scene?
- [ ] What if services fail to initialize? Graceful degradation?
- [ ] Should we add retry logic for failed connections?

### 5. Scene Lifecycle

- [ ] Should this be a Window (like current tests) or embedded in main scene?
- [ ] Auto-start listening on open, or require manual start button?
- [ ] What happens when window closes? Stop all services or keep running?

### 6. Additional Features?

- [ ] Add "Clear Stars" button to reset visual state?
- [ ] Add manual text input field (for testing without voice)?
- [ ] Record/save conversation history?
- [ ] Export transcript log to file?

---

## 📦 File Structure

### Files to Modify

- `addons/godot_llm/runtime/audio_services/elevenlabs_wrapper/ElevenLabsWrapper.gd`
  - Add `playback_interrupted` signal
  - Add `interrupt()` method to `RealtimePCMPlayer` class

### Files to Create

- `scenes/VoiceAssistantTest.tscn` - Main showcase scene
- `scenes/VoiceAssistantTest.gd` - Main script (~500-600 lines)
- `scenes/assets/npc_placeholder.png` (optional - simple sprite)

### Files to Update

- `scenes/Test.tscn` - Add button to grid
- `scenes/control.gd` - Add test handler

---

## 🔑 Key Implementation Patterns

### VADManager Usage

```gdscript
# Create instance (can also use class_name: VADManager.new())
vad_manager = preload("res://addons/godot_llm/runtime/audio_services/vad/VADManager.gd").new()
add_child(vad_manager)

# Connect signals BEFORE setup
vad_manager.speech_started.connect(_on_vad_started)
vad_manager.speech_detected.connect(_on_vad_audio)
vad_manager.speech_ended.connect(_on_vad_ended)

# Setup and check for errors
var result = vad_manager.setup()
if result != VADManager.SetupError.OK:
    push_error("VAD setup failed!")
    return

# Start recording
vad_manager.start_recording()
```

### Deepgram Usage

```gdscript
var deepgram = get_node("/root/DeepgramSTT")

# Initialize with options
deepgram.initialize(api_key, {
    "model": "nova-3",
    "interim_results": true,
    "smart_format": true,
    "endpointing": 300
})

# Connect signals
deepgram.speech_ended.connect(_on_speech_ended)
# Optional: deepgram.transcript_interim.connect(_on_interim) for real-time updates

# Connect (non-blocking, returns Error code)
var err = deepgram.connect_to_deepgram()
if err != OK:
    push_error("Failed to connect: " + error_string(err))
    return

# Connection happens asynchronously, wait for 'connected' signal if needed
```

### Tool Registration

```gdscript
LLMToolRegistry.create("tool_name")\
    .description("What it does")\
    .param("param_name", "type", "description")\
    .handler(LLMToolRegistry.thread_safe_node_handler(self, "_handler_method"))\
    .register()

func _handler_method(args: Dictionary) -> Dictionary:
    # Do work (runs on main thread via call_deferred)
    return {"ok": true, "result": "value"}
```

**Note:** Use backslash `\` for line continuation in builder pattern.

### Agent Creation

```gdscript
var tools = [
    LLMToolRegistry.get_by_name("tool1"),
    LLMToolRegistry.get_by_name("tool2")
]

var llm_manager = get_node("/root/LLMManager")
agent = llm_manager.create_agent({
    "model": "gpt-4o-mini",
    "system_prompt": "Personality and role"
}, tools)

# Connect signals
agent.delta.connect(_on_agent_delta)
agent.finished.connect(_on_agent_finished)
agent.debug.connect(_on_agent_debug)
```

### TTS Integration

```gdscript
# Setup (use autoload for wrapper methods, static for player creation)
var elevenlabs = get_node("/root/ElevenLabsWrapper")
await elevenlabs.create_character_context("npc", voice_id)
var player = await ElevenLabsWrapper.create_realtime_player(self, "npc")  # Static function!

# Stream LLM output
func _on_agent_delta(run_id: String, text: String):
    ElevenLabsWrapper.feed_text_to_character("npc", text)  # Use autoload directly

# Finish
func _on_agent_finished(run_id: String, ok: bool, result: Dictionary):
    # Flush buffer
    var buf = ElevenLabsWrapper.character_contexts["npc"]["batch_buffer"]
    if buf.length() > 0:
        ElevenLabsWrapper.feed_text_to_character("npc", "", true)
    await ElevenLabsWrapper.finish_character_speech("npc")
```

### Message Format

```gdscript
const Message = preload("res://addons/godot_llm/runtime/llm_messages/LLMMessage.gd")

# Returns Array (not Dictionary!)
agent.ainvoke(Message.user_simple("Hello"))

# Can also build message arrays:
var msgs = []
msgs += Message.system_simple("You are helpful")
msgs += Message.user_simple("Do something")
agent.ainvoke(msgs)
```

---

## 🎯 Success Criteria

✅ **Functional**:

- Voice input → text output working reliably
- LLM receives transcripts and responds
- Tools execute and affect game world
- TTS plays back smoothly
- Interruption works cleanly

✅ **Visual**:

- Pipeline status updates in real-time
- All 3 weather effects work (sky, stars, lighting)
- Speech bubble appears/disappears correctly
- Smooth animations and transitions

✅ **UX**:

- Low latency (<2 seconds total)
- No audio stuttering or gaps
- Clear visual feedback at each stage
- Graceful error handling

✅ **Demo Quality**:

- Impressive to watch (parallel tools!)
- Easy to understand (clear debug panel)
- Showcases addon capabilities
- Replicable by others

---

## 📝 Notes

- Tools are registered **locally in the test scene**, not globally
- Use `thread_safe_node_handler` for all node-accessing tools
- VADManager is an **instance**, not autoload (unlike other services)
- Message.user_simple() returns an **Array**, not Dictionary
- TTS buffer must be flushed before calling finish_character_speech()
- Interruption requires calling both `agent.interrupt()` AND `tts_player.interrupt()`

---

## 🚀 Next Steps

1. **Finalize design decisions** (answer open questions above)
2. **Create scene structure** in Godot editor or via code
3. **Implement VoiceAssistantTest.gd** following patterns
4. **Test each pipeline stage** individually
5. **Test full integration** with voice input
6. **Polish and iterate** based on results
7. **Document** for users to replicate

---

## 💡 Future Enhancements (Post-MVP)

- Add more complex tools (weather presets, mood-based scenes)
- Multi-NPC conversations (using email system)
- Save/load scene configurations
- Export conversation transcripts
- Add visual effects (particles for rain, snow, etc.)
- Voice selection UI (switch NPC voices)
- Language selection (test multi-language STT)
