# 🤖 Godot LLM Add-on

> **A production-ready LLM integration for Godot 4 with streaming responses, tool calling, multi-agent communication, and voice pipeline components.**

[![Godot 4.5+](https://img.shields.io/badge/Godot-4.5%2B-blue)](https://godotengine.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Status](https://img.shields.io/badge/status-beta-yellow)]()
[![Asset Library](https://img.shields.io/badge/Asset%20Library-pending-orange)]()

> **📦 Asset Library Status:** This plugin will be published to the Godot Asset Library once the Deepgram STT integration is complete. For now, install manually via the instructions below.

---

## ✨ Features

- ✅ **OpenAI API Integration** - Streaming & non-streaming responses
- ✅ **Tool Calling** - Parallel execution with thread safety
- ✅ **Multi-Agent System** - Email-based agent communication
- ✅ **Voice Activity Detection** - AI-powered speech detection with noise cancellation
- ✅ **Text-to-Speech** - ElevenLabs streaming integration
- ⏳ **Speech-to-Text** - Deepgram integration (in progress)

---

## 📦 Installation

### Step 1: Install Plugin

1. Download or clone this repository
2. Copy `addons/godot_llm` to your project's `addons/` directory
3. Enable: `Project → Project Settings → Plugins → Godot LLM → Enable`
4. Restart Godot

### Step 2: Configure API Keys

Create a `.env` file in your project root:

```env
OPENAI_API_KEY=sk-...
ELEVENLABS_API_KEY=...
DEEPGRAM_API_KEY=...  # For STT (coming soon)
```

**Alternative:** Set environment variables before launching Godot:

```bash
# Windows (PowerShell)
$env:OPENAI_API_KEY="sk-..."
godot

# Linux/Mac
export OPENAI_API_KEY="sk-..."
godot
```

**⚠️ Add `.env` to your `.gitignore`!**

### Step 3: Voice Pipeline Setup (Optional)

For Voice Activity Detection:

1. Install [TwoVoip](https://godotengine.org/asset-library/asset/3427) from Godot Asset Library
2. Enable microphone: `Project Settings → Audio → Driver → Enable Input` ✅
3. Set mix rate (recommended): `Project Settings → Audio → Driver → Mix Rate` = `48000`
4. Restart Godot

---

## 🧠 1. LLM Integration

### OpenAI Wrapper - Low-Level API Client

Direct access to OpenAI's API with streaming support.

```gdscript
extends Node

var wrapper: OpenAIWrapper

func _ready():
    wrapper = OpenAIWrapper.new()
    add_child(wrapper)

    # Connect streaming signals
    wrapper.stream_delta_text.connect(_on_text_chunk)
    wrapper.stream_finished.connect(_on_complete)

    # Create messages
    var messages = [
        wrapper.make_text_message("system", "You are a helpful assistant."),
        wrapper.make_text_message("user", "What is 2+2?")
    ]

    # Non-streaming request
    var result = await wrapper.create_response(messages, [], {})
    print(result["assistant_text"])

    # Streaming request
    var stream_id = wrapper.stream_response_start(messages, [], {})

func _on_text_chunk(stream_id: String, text: String):
    print(text, end="")  # Print each chunk

func _on_complete(stream_id: String, ok: bool, final_text: String, usage: Dictionary):
    print("\nTokens used: ", usage)
```

**Signals:**

- `stream_delta_text(stream_id, text)` - Text chunks
- `stream_tool_call(stream_id, call_id, name, args_delta)` - Tool call deltas
- `stream_finished(stream_id, ok, final_text, usage)` - Completion

---

### LLMAgent - High-Level Agent Abstraction

Manages conversation history, tool calling loops, and provides both sync/async modes.

**Creating an Agent:**

```gdscript
extends Node

var agent: LLMAgent

func _ready():
    # Create agent with LLMManager
    agent = LLMManager.create_agent({
        "model": "gpt-4o-mini",
        "temperature": 0.7,
        "max_output_tokens": 1000,
        "system_prompt": "You are a helpful assistant."
    }, [])  # Empty tools array for now

    add_child(agent)
```

**Hyper Parameters:**

| Parameter           | Type   | Description                    | Default  |
| ------------------- | ------ | ------------------------------ | -------- |
| `model`             | String | Model ID (e.g., "gpt-4o-mini") | Required |
| `temperature`       | Float  | Randomness (0.0-2.0)           | 1.0      |
| `max_output_tokens` | Int    | Response length limit          | None     |
| `system_prompt`     | String | Agent personality/instructions | None     |

**Invoke (Synchronous) - Waits for complete response:**

```gdscript
func ask_question(question: String):
    var messages = [Message.user_simple(question)]
    var result = await agent.invoke(messages)

    if result.get("ok"):
        print("Response: ", result["text"])
        print("Tokens: ", result.get("usage", {}))
    else:
        print("Error: ", result.get("error"))
```

**AInvoke (Asynchronous) - Streaming with signals:**

```gdscript
func _ready():
    agent = LLMManager.create_agent({"model": "gpt-4o-mini"}, [])
    add_child(agent)

    # Connect signals
    agent.delta.connect(_on_text_chunk)
    agent.finished.connect(_on_complete)
    agent.error.connect(_on_error)

    # Start streaming
    var run_id = agent.ainvoke([Message.user_simple("Tell me a story")])

func _on_text_chunk(run_id: String, text: String):
    $Label.text += text  # Append each chunk

func _on_complete(run_id: String, ok: bool, result: Dictionary):
    if ok:
        print("Complete! Tokens: ", result.get("usage", {}))

func _on_error(run_id: String, error_dict: Dictionary):
    print("Error: ", error_dict)
```

**Agent Signals:**

- `delta(run_id, text)` - Text chunks during streaming
- `finished(run_id, ok, result)` - Agent run complete
- `error(run_id, error_dict)` - Error occurred
- `debug(run_id, event)` - Debug events (tool calls, request lifecycle)

**Message Builders:**

Use the `Message` class (imported globally) to build messages:

```gdscript
# User message
Message.user_simple("Hello!")

# Assistant message (for conversation history)
Message.assistant_simple("Hi there!")

# System message (overrides system_prompt for this turn)
Message.system_simple("You are now a pirate.")

# Multimodal message (text + image)
var image = load("res://screenshot.png")
var base64_img = Message.image_to_base64(image, "png")  # Helper function!
Message.user(["Describe this image"], [base64_img])

# Or use image URL directly
Message.user(["Describe this"], ["https://example.com/image.png"])
```

---

## 🛠️ 2. Tool Calling

Tools let the LLM call GDScript functions. Execution happens in parallel for multiple tools.

### Registering Tools - Builder Pattern

```gdscript
extends Node

func _ready():
    # Simple tool - runs in background thread
    LLMToolRegistry.create("get_time") \
        .description("Get current time") \
        .handler(func(args):
            return {"time": Time.get_time_string_from_system()}
        ) \
        .register()

    # Tool with parameters
    LLMToolRegistry.create("calculate") \
        .description("Perform mathematical calculation") \
        .param("expression", "string", "Math expression to evaluate") \
        .handler(func(args):
            var expr = Expression.new()
            var error = expr.parse(args["expression"])
            if error == OK:
                return {"result": expr.execute()}
            else:
                return {"error": "Invalid expression"}
        ) \
        .register()

    # Create agent with tools
    var tools = LLMToolRegistry.get_all()
    var agent = LLMManager.create_agent({"model": "gpt-4o-mini"}, tools)

    # Agent will automatically call tools as needed
    var result = await agent.invoke([
        Message.user_simple("What time is it? Also calculate 15 * 23.")
    ])
    print(result["text"])
```

**Tool Handler Types:**

1. **`.handler(callable)`** - Runs in background thread (use for I/O, calculations)

**Optional Helper Wrappers:**

```gdscript
# Simple handler - auto-wraps return values
LLMToolRegistry.create("add") \
    .handler(LLMToolRegistry.simple_handler(func(args):
        return args["a"] + args["b"]  # Auto-wrapped to {"ok": true, "data": result}
    )) \
    .register()

# Thread-safe node handler - defers to main thread
LLMToolRegistry.create("spawn") \
    .handler(LLMToolRegistry.thread_safe_node_handler(self, "spawn_method")) \
    .register()

func spawn_method(args: Dictionary):
    # This runs on main thread - safe for node operations
    var entity = preload("res://entity.tscn").instantiate()
    add_child(entity)
```

**Tool Registry API:**

```gdscript
# Get all registered tools
var tools = LLMToolRegistry.get_all()

# Clear all tools
LLMToolRegistry.clear()
```

---

## 📧 3. Multi-Agent Communication

Built-in email system for agents to communicate asynchronously.

### Sending Emails

```gdscript
# Send email from one agent to another (recipients is an Array)
LLMEmailManager.send_email(
    "agent_1",           # From
    ["agent_2"],         # To (Array of recipient IDs)
    "Meeting Request",   # Subject
    "Can we meet at 3pm?"  # Body
)

# Send to multiple recipients
LLMEmailManager.send_email(
    "agent_1",
    ["agent_2", "agent_3", "agent_4"],
    "Team Meeting",
    "Meeting at 3pm today"
)
```

### Checking Inbox

```gdscript
# Read emails for an agent
var result = LLMEmailManager.read_emails("agent_2")
var emails = result["emails"]  # Get emails array from result

for email in emails:
    print("From: ", email["from"])
    print("To: ", email["to"])  # Array of recipients
    print("Subject: ", email["subject"])
    print("Content: ", email["content"])
    print("Timestamp: ", email["timestamp"])

# Read only unread emails
var unread_result = LLMEmailManager.read_emails("agent_2", 10, true)
```

### Email-Based Tool

The email system is automatically registered as a tool that agents can use:

```gdscript
var agent = LLMManager.create_agent({
    "model": "gpt-4o-mini",
    "system_prompt": "You are Agent 1. You can email Agent 2 using the send_email tool."
}, LLMToolRegistry.get_all())

# Agent can now send emails autonomously
var result = await agent.invoke([
    Message.user_simple("Send an email to Agent 2 asking about the project status")
])
```

**Email Tool Schema:**

- **Name:** `send_email`
- **Parameters:**
  - `to` (string, required) - Recipient agent ID
  - `subject` (string, required) - Email subject
  - `content` (string, required) - Email body

---

## 🎤 4. Voice Activity Detection (VAD)

AI-powered speech detection with RnNoise noise cancellation. Detects when speech starts/ends and outputs clean PCM audio.

**Prerequisites:**

- [TwoVoip plugin](https://godotengine.org/asset-library/asset/3427) installed
- Microphone enabled in Project Settings

### Basic Usage

```gdscript
extends Node

var vad_manager: VADManager

func _ready():
    # Create VAD
    vad_manager = VADManager.new()
    add_child(vad_manager)

    # Connect signals
    vad_manager.speech_started.connect(_on_speech_started)
    vad_manager.speech_ended.connect(_on_speech_ended)
    vad_manager.speech_detected.connect(_on_audio_chunk)

    # Setup
    var result = vad_manager.setup()
    if result == VADManager.SetupError.OK:
        vad_manager.start_recording()
    else:
        print("Setup failed: ", result)

func _on_speech_started():
    print("🎤 Speech started")

func _on_speech_ended():
    print("🔴 Speech ended")

func _on_audio_chunk(pcm_data: PackedByteArray):
    # pcm_data = 16-bit PCM, mono, 48kHz, little-endian
    # Ready to stream to STT service
    print("Audio chunk: %d bytes" % pcm_data.size())
```

### Configuration

```gdscript
vad_manager.vad_threshold = 0.75          # Speech probability (0.0-1.0)
vad_manager.grace_period_ms = 200         # Silence before ending (ms)
vad_manager.retroactive_grace_ms = 100    # Capture before speech starts (ms)
vad_manager.enable_denoising = true       # AI noise cancellation
```

**VAD Signals:**

- `speech_started()` - Speech activity begins
- `speech_ended()` - Speech activity ends (after grace period)
- `speech_detected(pcm_data: PackedByteArray)` - Audio chunks during speech

**Audio Format:** 48kHz, 16-bit PCM, mono, little-endian (perfect for Deepgram!)

**Features:**

- ✅ AI-powered VAD (RnNoise algorithm)
- ✅ Noise cancellation (works with fans, background noise)
- ✅ Configurable threshold and grace periods
- ✅ Automatic microphone setup
- ✅ No false positives from silence

---

## 🔊 5. Text-to-Speech (ElevenLabs)

Real-time streaming TTS with WebSocket. Supports multiple concurrent voices (multi-NPC).

### Basic Usage

```gdscript
extends Node

func _ready():
    # Initialize wrapper
    ElevenLabsWrapper.initialize("YOUR_ELEVENLABS_API_KEY")

    # Set model (applies to all contexts)
    ElevenLabsWrapper.set_model("eleven_turbo_v2_5")  # Or "eleven_multilingual_v2"

    # Connect signals
    ElevenLabsWrapper.character_context_created.connect(_on_context_created)
    ElevenLabsWrapper.synthesis_completed.connect(_on_synthesis_complete)
    ElevenLabsWrapper.playback_finished.connect(_on_playback_finished)
    ElevenLabsWrapper.synthesis_error.connect(_on_error)

    # Create character context with voice
    await ElevenLabsWrapper.create_character_context("npc_1", "YOUR_VOICE_ID")

    # Speak
    ElevenLabsWrapper.speak_as_character("npc_1", "Hello! Welcome to the game.")

func _on_context_created(context_id: String, voice_id: String):
    print("Context created: ", context_id)

func _on_synthesis_complete(context_id: String):
    print("Synthesis complete: ", context_id)

func _on_playback_finished(context_id: String):
    print("Playback finished: ", context_id)

func _on_error(context_id: String, error: Dictionary):
    print("Error: ", error)
```

### Multi-NPC Support (Context IDs)

The TTS system uses **context IDs** to manage multiple NPCs speaking independently:

```gdscript
# Create contexts for multiple NPCs with different voices
await ElevenLabsWrapper.create_character_context("merchant", "voice_id_1")
await ElevenLabsWrapper.create_character_context("guard", "voice_id_2")

# Multiple NPCs can speak simultaneously without conflicts
ElevenLabsWrapper.speak_as_character("merchant", "Welcome to my shop!")
ElevenLabsWrapper.speak_as_character("guard", "Halt! Who goes there?")

# Check if context is active
if ElevenLabsWrapper.is_character_connected("guard"):
    print("Guard context is active")

# Destroy context when done
ElevenLabsWrapper.destroy_character_context("merchant")
```

**Context IDs** are unique identifiers (strings) that separate:

- WebSocket connections (one per NPC)
- Audio playback streams (NPCs can talk over each other)
- Signals (know which NPC finished speaking)

### Manual Audio Handling (Data-Driven)

For full control, handle audio data yourself without helper nodes:

```gdscript
# Initialize in REAL_TIME mode
ElevenLabsWrapper.initialize("API_KEY", ElevenLabsWrapper.StreamingMode.REAL_TIME)
await ElevenLabsWrapper.create_character_context("npc", "voice_id")

# Create your own AudioStreamPlayer
var player = AudioStreamPlayer.new()
var generator = AudioStreamGenerator.new()
generator.mix_rate = 16000  # ElevenLabs PCM sample rate
player.stream = generator
add_child(player)
player.play()
var playback = player.get_stream_playback()

# Connect to audio_chunk_ready signal (data-driven!)
ElevenLabsWrapper.audio_chunk_ready.connect(func(pcm_data: PackedByteArray, ctx: String):
    if ctx == "npc":
        # Handle PCM data yourself
        ElevenLabsWrapper.convert_pcm_to_frames(playback, pcm_data)
)

# Speak
ElevenLabsWrapper.speak_as_character("npc", "Hello!")
```

**ElevenLabs API:**

- `initialize(api_key, mode)` - Setup wrapper (BUFFERED or REAL_TIME mode)
- `set_model(model_id)` - Set TTS model for all contexts
- `create_character_context(context_id, voice_id)` - Create voice context
- `speak_as_character(context_id, text)` - One-shot TTS (auto-opens and closes)
- `feed_text_to_character(context_id, text, flush)` - Stream text chunks to TTS
- `finish_character_speech(context_id)` - Close TTS stream and finalize
- `is_character_connected(context_id) -> bool` - Check if context exists
- `destroy_character_context(context_id)` - Cleanup context
- `create_realtime_player(parent, context_id)` - Helper to create audio player (optional)
- `convert_pcm_to_frames(playback, pcm_data)` - Static helper for manual PCM playback

**Signals:**

- `audio_chunk_ready(pcm_data, context_id)` - Raw PCM/MP3 bytes (data-driven)
- `audio_stream_ready(stream, context_id)` - Ready AudioStreamMP3 (BUFFERED mode only)
- `character_context_created(context_id, voice_id)` - Context created successfully
- `synthesis_completed(context_id)` - Audio generation complete
- `playback_finished(context_id)` - Playback complete (safe to cleanup)
- `synthesis_error(context_id, error)` - Error occurred

**Models:**

- `eleven_turbo_v2_5` - Fastest, lowest latency
- `eleven_multilingual_v2` - Supports multiple languages

---

## 🎯 6. Speech-to-Text (Deepgram) - Coming Soon

**Status:** ⏳ In Development

Deepgram STT integration is planned to complete the voice pipeline:

```
Microphone → VAD → Deepgram STT → LLM → ElevenLabs TTS → Speakers
```

**Why Deepgram:**

- 14x cheaper than OpenAI Realtime API
- Lower latency (<300ms)
- No charge for silence (unlike OpenAI which charges for noise)
- Perfect match with TwoVoip's 48kHz PCM output

**Planned API:**

```gdscript
# Coming soon!
var deepgram = DeepgramSTT.new()
deepgram.transcription_received.connect(_on_transcript)
deepgram.stream_audio(pcm_data)  # From VAD
```

---

## 📋 Complete Examples

### Example 1: Simple Q&A

```gdscript
extends Node

func _ready():
    var agent = LLMManager.create_agent({"model": "gpt-4o-mini"}, [])
    var result = await agent.invoke([Message.user_simple("What is 2+2?")])
    print(result["text"])
```

### Example 2: Streaming Response

```gdscript
extends Node

@onready var label = $Label

func _ready():
    var agent = LLMManager.create_agent({"model": "gpt-4o-mini"}, [])
    agent.delta.connect(func(id, text): label.text += text)
    agent.ainvoke([Message.user_simple("Tell me a story")])
```

### Example 3: Tool Calling

```gdscript
extends Node

func _ready():
    # Register tool
    LLMToolRegistry.create("get_weather") \
        .description("Get current weather") \
        .param("city", "string", "City name") \
        .handler(func(args): return {"temp": 72, "city": args["city"]}) \
        .register()

    # Create agent with tools
    var agent = LLMManager.create_agent({"model": "gpt-4o-mini"}, LLMToolRegistry.get_all())
    var result = await agent.invoke([Message.user_simple("What's the weather in Paris?")])
    print(result["text"])
```

### Example 4: Voice Input (VAD)

```gdscript
extends Node

var vad: VADManager
var audio_buffer = PackedByteArray()

func _ready():
    vad = VADManager.new()
    add_child(vad)
    vad.speech_detected.connect(func(pcm): audio_buffer.append_array(pcm))
    vad.speech_ended.connect(_on_speech_complete)
    vad.setup()
    vad.start_recording()

func _on_speech_complete():
    print("Captured %d bytes of audio" % audio_buffer.size())
    # TODO: Send to STT service
    audio_buffer.clear()
```

### Example 5: Voice Output (TTS)

```gdscript
extends Node

var agent: LLMAgent

func _ready():
    # Initialize TTS
    ElevenLabsWrapper.initialize("ELEVENLABS_API_KEY")
    await ElevenLabsWrapper.create_character_context("agent", "VOICE_ID")

    # Create agent
    agent = LLMManager.create_agent({"model": "gpt-4o-mini"}, [])
    agent.finished.connect(_on_response_complete)
    agent.ainvoke([Message.user_simple("Say hello")])

func _on_response_complete(run_id: String, ok: bool, result: Dictionary):
    if ok:
        ElevenLabsWrapper.speak_as_character("agent", result["text"])
```

### Example 6: Complete Voice Pipeline (Multi-NPC)

Full end-to-end: Voice Input → VAD → STT (coming soon) → LLM → TTS → Voice Output

**Two approaches for audio playback:**

- **Option A (Helper):** Use `create_realtime_player()` - Automatic node creation
- **Option B (Manual):** Connect to `audio_chunk_ready` signal - Full control

This example shows **Option A** (easier). See ElevenLabsWrapper docs for Option B.

```gdscript
extends Node

# Multi-NPC support using context IDs
var npcs = {
    "merchant": {
        "agent": null,
        "voice_id": "voice_id_1",
        "audio_buffer": PackedByteArray(),
        "player": null  # RealtimePCMPlayer for this NPC
    },
    "guard": {
        "agent": null,
        "voice_id": "voice_id_2",
        "audio_buffer": PackedByteArray(),
        "player": null  # RealtimePCMPlayer for this NPC
    }
}

var vad: VADManager
var current_speaker: String = ""  # Which NPC is currently being spoken to

func _ready():
    # Setup VAD (shared for all NPCs)
    vad = VADManager.new()
    add_child(vad)

    # VAD Signals:
    vad.speech_started.connect(_on_vad_started)       # Signal: speech_started()
    vad.speech_detected.connect(_on_audio_chunk)      # Signal: speech_detected(pcm_data: PackedByteArray)
    vad.speech_ended.connect(_on_speech_ended)        # Signal: speech_ended()

    vad.setup()

    # Initialize TTS in REAL_TIME mode for streaming LLM → TTS
    ElevenLabsWrapper.initialize("ELEVENLABS_API_KEY", ElevenLabsWrapper.StreamingMode.REAL_TIME)

    # TTS Global Signals:
    ElevenLabsWrapper.synthesis_completed.connect(_on_synthesis_done)  # Signal: synthesis_completed(context_id: String)
    ElevenLabsWrapper.playback_finished.connect(_on_playback_done)     # Signal: playback_finished(context_id: String)
    ElevenLabsWrapper.synthesis_error.connect(_on_tts_error)          # Signal: synthesis_error(context_id: String, error: Dictionary)

    # Setup each NPC
    for npc_id in npcs.keys():
        var npc = npcs[npc_id]

        # Create agent for this NPC
        npc["agent"] = LLMManager.create_agent({
            "model": "gpt-4o-mini",
            "system_prompt": "You are %s." % npc_id
        }, [])

        # Create TTS context for this NPC
        await ElevenLabsWrapper.create_character_context(npc_id, npc["voice_id"])

        # Create real-time audio player for this NPC (REQUIRED for REAL_TIME mode)
        var player = await ElevenLabsWrapper.create_realtime_player(self, npc_id)
        npc["player"] = player

        # Agent Signals (captured with closure for npc_id):
        npc["agent"].delta.connect(func(run_id: String, text: String):
            # Signal: delta(run_id: String, text: String)
            # Stream LLM text chunks to TTS in real-time
            print("[%s] LLM chunk: %s" % [npc_id, text])
            ElevenLabsWrapper.feed_text_to_character(npc_id, text)
        )

        npc["agent"].finished.connect(func(run_id: String, ok: bool, result: Dictionary):
            # Signal: finished(run_id: String, ok: bool, result: Dictionary)
            if ok:
                print("[%s] LLM complete, finishing TTS..." % npc_id)

                # Flush any remaining buffered text
                var buffer = ElevenLabsWrapper.character_contexts[npc_id]["batch_buffer"]
                if buffer.length() > 0:
                    ElevenLabsWrapper.feed_text_to_character(npc_id, "", true)  # flush=true

                # Close the TTS stream
                await ElevenLabsWrapper.finish_character_speech(npc_id)
            else:
                print("[%s] Error: %s" % [npc_id, result.get("error")])
        )

        npc["agent"].error.connect(func(run_id: String, error_dict: Dictionary):
            # Signal: error(run_id: String, error_dict: Dictionary)
            print("[%s] LLM Error: %s" % [npc_id, error_dict])
        )

    # Start listening
    vad.start_recording()
    current_speaker = "merchant"  # Default NPC to talk to

func _on_vad_started():
    # Called when speech is first detected
    print("🎤 Player started speaking")

func _on_synthesis_done(context_id: String):
    # Called when ElevenLabs finishes generating audio
    print("[%s] Audio synthesis complete" % context_id)

func _on_playback_done(context_id: String):
    # Called when audio playback finishes (safe to cleanup)
    print("[%s] Finished speaking" % context_id)

func _on_tts_error(context_id: String, error: Dictionary):
    # Called on TTS error
    print("[%s] TTS Error: %s" % [context_id, error])

func _on_audio_chunk(pcm_data: PackedByteArray):
    # Collect audio for the current NPC being spoken to
    npcs[current_speaker]["audio_buffer"].append_array(pcm_data)

func _on_speech_ended():
    var audio = npcs[current_speaker]["audio_buffer"]

    if audio.size() > 0:
        # TODO: Send to Deepgram STT (coming soon!)
        # For now, simulating transcription:
        # var transcript = await deepgram.transcribe(audio)

        var simulated_transcript = "[Player spoke %d bytes of audio]" % audio.size()
        print("Transcribed: ", simulated_transcript)

        # Send to current NPC's agent
        npcs[current_speaker]["agent"].ainvoke([
            Message.user_simple(simulated_transcript)
        ])

        # Clear buffer
        npcs[current_speaker]["audio_buffer"].clear()

func switch_npc(npc_id: String):
    # Switch which NPC the player is talking to
    if npcs.has(npc_id):
        current_speaker = npc_id
        print("Now talking to: ", npc_id)
```

**Signal Flow Breakdown:**

```
Player Speaks:
  1. VAD.speech_started() → "🎤 Player started speaking"
  2. VAD.speech_detected(pcm_data) → Accumulate in audio_buffer [continuous]
  3. VAD.speech_ended() → Process complete audio

Speech Processing:
  4. [TODO: Deepgram STT] → transcript = await deepgram.transcribe(audio_buffer)
  5. Agent.ainvoke([Message.user_simple(transcript)])

LLM Streams Response → TTS (Real-Time):
  6. Agent.delta(run_id, text) → feed_text_to_character(npc_id, text) [continuous]
  7. Agent.finished(run_id, ok, result) → Flush buffer & finish_character_speech()

NPC Speaks:
  8. ElevenLabsWrapper.synthesis_completed(context_id) → Audio generation done
  9. ElevenLabsWrapper.playback_finished(context_id) → NPC finished speaking
```

**Key Concepts:**

- **Context IDs**: Each NPC has a unique ID ("merchant", "guard", etc.)
- **Separate Agents**: Each NPC has its own LLMAgent with its own personality
- **Separate TTS Contexts**: Each NPC uses `create_character_context()` with different voice
- **Shared VAD**: One VAD detects all speech, `current_speaker` determines which NPC hears it
- **Audio Buffers**: Each NPC has its own audio buffer for STT processing
- **Multi-Session**: Multiple NPCs can speak simultaneously without conflicts

**Signal Parameters:**

- `speech_detected(pcm_data: PackedByteArray)` - 48kHz, 16-bit PCM mono audio chunks
- `delta(run_id: String, text: String)` - LLM text chunks as they stream in
- `finished(run_id: String, ok: bool, result: Dictionary)` - Complete LLM response
  - `result["text"]` - Full response text
  - `result["usage"]` - Token usage stats
- `synthesis_completed(context_id: String)` - Which NPC finished audio generation
- `playback_finished(context_id: String)` - Which NPC finished speaking (safe to cleanup)
- `error(run_id: String, error_dict: Dictionary)` - LLM or network errors

---

## 🏗️ Architecture

```
addons/godot_llm/
├── runtime/
│   ├── llm_manager/           # Agent factory, API key loading
│   ├── openai_wrapper/        # OpenAI API client (HTTP + SSE)
│   ├── llm_agent/             # High-level agent with tools
│   ├── llm_tool_registry/     # Tool builder and registry
│   ├── llm_tools/             # Tool definition class
│   ├── llm_messages/          # Message builders
│   ├── llm_email_manager/     # Multi-agent email system
│   └── audio_services/
│       ├── vad/               # Voice Activity Detection (TwoVoip wrapper)
│       ├── elevenlabs_wrapper/# Text-to-Speech (ElevenLabs)
│       └── audio_manager/     # Audio coordination
└── editor/
    └── plugin.gd              # Editor plugin entry point
```

**Autoloads (Global Singletons):**

- `LLMManager` - Create agents, load API keys
- `LLMToolRegistry` - Register and lookup tools
- `LLMEmailManager` - Agent email system
- `AudioManager` - Audio coordination
- `ElevenLabsWrapper` - TTS service

---

## 🧪 Testing

Run the comprehensive test suite:

1. Open `scenes/Test.tscn` in Godot
2. Press F5 to run the scene
3. Use the test buttons in the UI:
   - **Wrapper Call** - Test non-streaming OpenAI API
   - **Wrapper Stream** - Test streaming OpenAI API
   - **Agent Invoke** - Test agent sync mode
   - **Agent Stream** - Test agent streaming mode
   - **Builder Tools** - Test tool registration
   - **Spawn Entity** / **Calc Distance** / **Random Color** - Test specific tools
   - **Email Test** - Test email system
   - **Async Email Test** - Test async email processing
   - **TTS Test** - Test ElevenLabs text-to-speech
   - **VAD Test** - Test voice activity detection

All tests output to the console at the bottom of the screen.

---

## 🚧 Roadmap

### ✅ Completed

- [x] OpenAI API integration (streaming + non-streaming)
- [x] Tool calling with parallel execution
- [x] Agent abstraction (sync + async)
- [x] Tool builder pattern
- [x] Multi-agent email system
- [x] Voice Activity Detection (AI-powered)
- [x] Text-to-Speech (ElevenLabs)

### 🚧 In Progress

- [ ] **Deepgram STT integration** - Complete voice pipeline
- [ ] **Documentation improvements** - More examples

### 📋 Planned

- [ ] More TTS providers (Azure, Google)
- [ ] Local LLM support (Ollama, LlamaCPP)
- [ ] Vision API (image understanding)
- [ ] Conversation memory/context management
- [ ] Pre-built components (chat UI, voice controls)

---

## 📊 Performance

**Benchmarks (typical usage):**

- **LLM First Token:** ~100-200ms (from OpenAI)
- **Tool Execution:** Varies by tool complexity
- **TTS Latency:**
  - BUFFERED: ~2-3s (waits for complete audio)
  - REAL_TIME: ~100-500ms (streams as generated)
- **VAD Detection:** <5ms per 20ms chunk (negligible)
- **VAD CPU Usage:** <1% (AI-powered RnNoise)
- **Memory:** ~50MB plugin + audio buffers (varies by usage)

---

## ⚠️ Known Limitations

1. **TTS Latency:**
   - BUFFERED mode: ~2-3s (collects all audio before playing)
   - REAL_TIME mode: ~100-500ms (streams chunks as they arrive)
2. **Microphone Setup:** Requires one-time manual enable in Project Settings + restart
3. **WebSocket Buffers:** ElevenLabs requires 16MB buffer size (auto-configured in code)

---

## 📝 License

MIT License - see [LICENSE](LICENSE)

---

## 🙏 Acknowledgments

- **OpenAI** - GPT models and API
- **ElevenLabs** - High-quality TTS
- **TwoVoip** - Godot VAD/RnNoise plugin
- **Deepgram** - Cost-effective STT
- **Godot Community** - Amazing game engine

---

**Made with ❤️ for the Godot community**

_Star ⭐ this repo if you find it useful!_
