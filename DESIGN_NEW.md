# Godot LLM Add-on - Design Document

## 🎯 Overview

A comprehensive LLM integration for Godot 4 featuring:

- **OpenAI Responses API** - Streaming & non-streaming
- **Real-Time Audio** - OpenAI STT + ElevenLabs TTS WebSocket streaming
- **Tool Calling** - Parallel execution, builder pattern
- **Agent System** - Multi-agent communication via email
- **Production-Ready** - Error handling, retries, race condition prevention

---

## 🏗️ Core Architecture

### **1. LLMManager** (Autoload)

**Central coordinator for all LLM operations**

- Auto-loads API keys from environment or `.env`
- Factory for creating agents
- Manages shared OpenAI wrapper instance

```gdscript
var agent = LLMManager.create_agent({
    "model": "gpt-4o-mini",
    "temperature": 0.7,
    "system_prompt": "You are a helpful assistant."
}, tools)
```

---

### **2. OpenAIWrapper** (Transport Layer)

**Production-grade OpenAI client with dual transport**

**Features:**

- HTTPRequest for non-streaming (`create_response`)
- HTTPClient for SSE streaming (`stream_response_start`)
- Retry logic with exponential backoff
- Tool call buffering and continuation handling

**Signals:**

- `stream_delta_text(stream_id, text)` - Text chunks
- `stream_tool_call(stream_id, call_id, name, args_delta)` - Tool args
- `stream_finished(stream_id, ok, final_text, usage)` - Complete

---

### **3. LLMAgent** (Agent Abstraction)

**High-level agent with message history and tool calling**

**Two modes:**

- `invoke(messages)` - Discrete (waits for complete response)
- `ainvoke(messages)` - Streaming (returns immediately, emits deltas)

**Features:**

- Automatic tool calling loops
- Parallel tool execution in threads
- Message history management
- Interruption/resumption support

```gdscript
var agent = LLMAgent.create(tools, {"model": "gpt-4o-mini"})
agent.delta.connect(func(id, text): print(text))
agent.finished.connect(func(id, ok, result): print("Done!"))
agent.ainvoke(Message.user_simple("Hello!"))
```

---

### **4. LLMToolRegistry** (Autoload)

**Fluent builder pattern for tool creation**

```gdscript
LLMToolRegistry.builder("get_weather") \
    .describe("Get current weather for a location") \
    .param("location", "string", "City name", true) \
    .handler(func(args): return {"temp": 72}) \
    .register()
```

**Features:**

- Thread-safe wrappers for node access
- Automatic JSON Schema generation
- Global tool registry
- Duplicate detection

---

## 🎤 Audio Services

### **OpenAI Speech-to-Text (STT)**

**Real-time transcription via WebSocket**

```gdscript
OpenAISTT.start_transcription()
OpenAISTT.transcription_complete.connect(func(text): print(text))
```

**Features:**

- Server-side VAD (Voice Activity Detection)
- Noise reduction (near_field/far_field)
- PCM audio streaming
- Configurable sensitivity

---

### **ElevenLabs Text-to-Speech (TTS)**

**WebSocket streaming for real-time audio playback**

#### **🎭 Modes**

| Mode          | Format | Use Case                         | Latency    | Quality |
| ------------- | ------ | -------------------------------- | ---------- | ------- |
| **BUFFERED**  | MP3    | Pre-recorded dialogue, cutscenes | ~2-3s      | Best    |
| **REAL_TIME** | PCM    | Live conversations, NPCs         | ~100-500ms | Perfect |

---

#### **📖 Usage: Standalone (No LLM)**

**Scenario 1: Simple One-Shot Speech (BUFFERED)**

```gdscript
# Setup
ElevenLabsWrapper.initialize("your_api_key", StreamingMode.BUFFERED)
await ElevenLabsWrapper.create_character_context("merchant", "voice_id")

# Speak complete sentence
ElevenLabsWrapper.speak_as_character("merchant", "Welcome to my shop, traveler!")

# Handle audio
var player = AudioStreamPlayer.new()
add_child(player)
ElevenLabsWrapper.audio_stream_ready.connect(func(stream, ctx):
    if ctx == "merchant":
        player.stream = stream  # AudioStreamMP3 ready to play
        player.play()
)

# Later cleanup
ElevenLabsWrapper.destroy_character_context("merchant")
```

**Scenario 2: Manual Streaming (REAL_TIME)**

```gdscript
# Setup
ElevenLabsWrapper.set_streaming_mode(StreamingMode.REAL_TIME)
await ElevenLabsWrapper.create_character_context("guard", "voice_id")

# Create player (handles queue management automatically)
var player = await ElevenLabsWrapper.create_realtime_player(self, "guard")

# Feed text chunks manually
ElevenLabsWrapper.feed_text_to_character("guard", "Halt! ")
await get_tree().create_timer(0.5).timeout
ElevenLabsWrapper.feed_text_to_character("guard", "State your business.")

# Signal when done feeding text
await ElevenLabsWrapper.finish_character_speech("guard")

# Wait for ALL audio to finish playing
var cleanup_done = false
ElevenLabsWrapper.playback_finished.connect(func(ctx):
    if ctx == "guard":
        player.cleanup()
        ElevenLabsWrapper.destroy_character_context("guard")
        cleanup_done = true
)

while not cleanup_done:
    await get_tree().create_timer(0.1).timeout
```

---

#### **🤖 Usage: With LLM Integration**

**Scenario 3: Stream LLM Output → TTS (Recommended)**

```gdscript
# 1. Initialize TTS
ElevenLabsWrapper.set_streaming_mode(StreamingMode.REAL_TIME)
await ElevenLabsWrapper.create_character_context("npc", "voice_id")
var tts_player = await ElevenLabsWrapper.create_realtime_player(self, "npc")

# 2. Create LLM agent
var agent = LLMManager.create_agent({
    "model": "gpt-4o-mini",
    "system_prompt": "You are a wise old wizard."
}, [])

# 3. Pipe LLM text deltas → TTS (automatic batching!)
agent.delta.connect(func(run_id, text_chunk):
    # Each LLM chunk gets fed to TTS
    # Wrapper batches them on punctuation for natural speech
    ElevenLabsWrapper.feed_text_to_character("npc", text_chunk)
)

# 4. When LLM finishes, close TTS stream
agent.finished.connect(func(run_id, ok, result):
    # Flush any remaining buffered text
    var buffer = ElevenLabsWrapper.character_contexts["npc"]["batch_buffer"]
    if buffer and buffer.length() > 0:
        ElevenLabsWrapper.feed_text_to_character("npc", "", true)  # flush

    # Send close signal and drain remaining audio
    await ElevenLabsWrapper.finish_character_speech("npc")
)

# 5. Cleanup when playback finishes
ElevenLabsWrapper.playback_finished.connect(func(ctx):
    if ctx == "npc":
        tts_player.cleanup()
        print("Safe to start next conversation")
)

# 6. Start conversation
agent.ainvoke(Message.user_simple("Tell me about magic"))
```

**Scenario 4: Full Voice Pipeline (STT → LLM → TTS)**

```gdscript
var npc_context = "wizard_npc"
var conversation_active = false

# Setup TTS
ElevenLabsWrapper.set_streaming_mode(StreamingMode.REAL_TIME)
await ElevenLabsWrapper.create_character_context(npc_context, "voice_id")
var tts_player = await ElevenLabsWrapper.create_realtime_player(self, npc_context)

# Setup LLM
var agent = LLMManager.create_agent({
    "model": "gpt-4o-mini",
    "system_prompt": "You are a wise wizard. Keep responses under 100 words."
}, [])

# Connect LLM → TTS
agent.delta.connect(func(id, text):
    ElevenLabsWrapper.feed_text_to_character(npc_context, text)
)

agent.finished.connect(func(id, ok, result):
    var buffer = ElevenLabsWrapper.character_contexts[npc_context]["batch_buffer"]
    if buffer.length() > 0:
        ElevenLabsWrapper.feed_text_to_character(npc_context, "", true)
    await ElevenLabsWrapper.finish_character_speech(npc_context)
)

# Setup STT → LLM pipeline
OpenAISTT.transcription_complete.connect(func(user_text):
    if not conversation_active:
        conversation_active = true
        print("Player: " + user_text)
        agent.ainvoke(Message.user_simple(user_text))
)

# TTS done → Ready for next turn
ElevenLabsWrapper.playback_finished.connect(func(ctx):
    if ctx == npc_context:
        conversation_active = false
        print("Wizard finished speaking - you can talk again")
)

# Start listening
func start_conversation():
    OpenAISTT.start_transcription()
    print("Speak to the wizard...")
```

---

#### **⚙️ Configuration**

**Change Voice Model:**

```gdscript
ElevenLabsWrapper.set_model("eleven_multilingual_v2")  # Supports 29 languages
```

**Available Models:**

- `eleven_turbo_v2` (default) - Fastest, lowest latency
- `eleven_multilingual_v2` - 29 languages
- `eleven_flash_v2` - Ultra-fast, lower quality
- `eleven_monolingual_v1` - English only, high quality

**Voice Settings:**

```gdscript
ElevenLabsWrapper.set_voice_settings(
    0.5,   # stability
    0.75,  # similarity_boost
    0.0,   # style
    true   # use_speaker_boost
)
```

---

#### **🔧 Technical Details**

**WebSocket Configuration:**

- **Buffer Size:** 16MB inbound/outbound (default 64KB causes errors)
- **Fix for:** "Message too big" WebSocket error (code 1009)
- **Source:** [pipecat-ai/pipecat#984](https://github.com/pipecat-ai/pipecat/pull/984)

**Text Batching (Python SDK `text_chunker`):**

- Accumulates text until punctuation: `.`, `,`, `?`, `!`, `;`, `:`, ` `
- Ensures sentences aren't cut mid-phrase
- Produces natural-sounding speech

**Audio Processing:**

- **Sample Rate:** 16kHz (PCM mode)
- **Buffer Length:** 8 seconds (128,000 frames)
- **Chunk Size:** ~20-55KB per chunk
- **Processing Rate:** ~1-2 seconds per chunk

**Drain Loop (Python SDK pattern):**

```python
# After sending {"text":""}, actively poll for remaining messages
while websocket.state == OPEN:
    poll_and_process_messages()
    if timeout_reached(2.0):
        break
```

**Signals:**

- `synthesis_completed(context_id)` - isFinal received from ElevenLabs
- **`playback_finished(context_id)`** - All audio played, **safe to cleanup**
- `audio_chunk_ready(data, context_id)` - Raw PCM/MP3 bytes
- `audio_stream_ready(stream, context_id)` - AudioStreamMP3 (BUFFERED only)
- `synthesis_error(context_id, error)` - Error occurred

**Critical:**  
⚠️ **Always wait for `playback_finished` before cleanup** - `synthesis_completed` only means ElevenLabs finished generating, NOT that audio finished playing!

---

## 📧 Multi-Agent Communication

### **LLMEmailManager** (Autoload)

**Email system for agent-to-agent communication**

**Tools (auto-registered globally):**

- `get_other_agents` - Discover available agents
- `send_email` - Send messages to other agents
- `read_emails` - Read received emails

**Features:**

- UUID-based agent identification
- Read tracking per recipient
- Automatic unread notifications in prompts
- Multi-recipient broadcast support

```gdscript
# Agent automatically gets email tools
var agent = LLMManager.create_agent({
    "model": "gpt-4o-mini",
    "system_prompt": "You are Alice."
}, LLMToolRegistry.get_all())  # Includes email tools

# Agent can use send_email tool to message other agents
```

---

## 🎮 Usage Examples

### **Simple Q&A**

```gdscript
var agent = LLMAgent.create([], {"model": "gpt-4o-mini"})
var result = await agent.invoke(Message.user_simple("What is 2+2?"))
print(result["text"])  # "4"
```

### **Streaming with Tools**

```gdscript
var tools = [weather_tool, calculator_tool]
var agent = LLMAgent.create(tools, {})
agent.delta.connect(func(id, text): $Label.text += text)
agent.ainvoke(Message.user_simple("What's the weather in Paris?"))
```

### **Real-Time Voice Interaction**

```gdscript
# Start listening
OpenAISTT.start_transcription()
OpenAISTT.transcription_complete.connect(func(text):
    # User spoke, send to LLM
    agent.ainvoke(Message.user_simple(text))
)

# Stream LLM response to TTS
ElevenLabsWrapper.set_streaming_mode(StreamingMode.REAL_TIME)
var player = await ElevenLabsWrapper.create_realtime_player(self, "npc_context")
agent.delta.connect(func(id, text):
    ElevenLabsWrapper.feed_text_to_character("npc_context", text)
)
agent.finished.connect(func(id, ok, result):
    await ElevenLabsWrapper.finish_character_speech("npc_context")
)
```

---

## 📋 Implementation Details

### **WebSocket Protocols**

#### **OpenAI Realtime API (STT)**

```json
// Session config
{
  "type": "session.update",
  "session": {
    "input_audio_format": "pcm16",
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5
    }
  }
}

// Send audio
{
  "type": "input_audio_buffer.append",
  "audio": "<base64_audio>"
}
```

#### **ElevenLabs TTS (stream-input)**

```json
// Handshake
{
  "text": " ",
  "try_trigger_generation": true,
  "voice_settings": {"stability": 0.5, "similarity_boost": 0.75},
  "xi_api_key": "<api_key>"
}

// Send text
{
  "text": "Hello world ",
  "try_trigger_generation": true
}

// Close (triggers final generation)
{
  "text": ""
}
```

**Response:**

```json
{
  "audio": "<base64_pcm_or_mp3>",
  "isFinal": false,
  "normalizedAlignment": {...},
  "alignment": {...}
}
```

---

## 🔑 Key Achievements

### **Solved: ElevenLabs "Message Too Big" Error**

**Problem:** WebSocket closed with code 1009 after first audio chunk  
**Root Cause:** Godot's default WebSocket buffer (64KB) couldn't handle large audio responses  
**Solution:** `ws.set_inbound_buffer_size(16 * 1024 * 1024)` - Matches Python pipecat-ai fix  
**Result:** ✅ Can now receive 55KB+ audio chunks without errors

### **Solved: Audio Cutting Off Early**

**Problem:** Audio stopped mid-sentence, chunks left in queue  
**Root Cause:** Test cleanup called too early (fixed timeout instead of signal-based)  
**Solution:** Added `playback_finished` signal that waits for:

1. All chunks to be processed
2. Audio buffer to drain (calculated dynamically)  
   **Result:** ✅ Complete audio playback every time

### **Solved: Text Batching for Natural Speech**

**Problem:** Sending individual words created choppy, unnatural speech  
**Root Cause:** Each word triggered separate audio generation  
**Solution:** Implemented Python SDK's `text_chunker` logic - batches on punctuation boundaries  
**Result:** ✅ Smooth, natural-sounding speech

---

## 📊 Performance Metrics

**Real-Time TTS:**

- **First audio chunk**: ~0.5-1.0s after first text sent
- **Latency**: ~100-500ms per chunk
- **Buffer**: 8 seconds (128,000 frames at 16kHz)
- **Processing rate**: ~1-2 seconds per chunk (55KB chunks)

**LLM Streaming:**

- **First token**: ~200-500ms
- **Tool execution**: Parallel (multiple tools simultaneously)
- **Stream management**: Handles 10+ concurrent streams

---

## 🛠️ Configuration

### **Required Environment Variables**

```bash
OPENAI_API_KEY=sk-...
ELEVENLABS_API_KEY=sk_...
```

### **Optional Settings**

```bash
OPENAI_MODEL=gpt-4o  # Default: gpt-4o-mini
```

### **ElevenLabs Models**

- `eleven_turbo_v2` (default) - Fastest, great quality
- `eleven_multilingual_v2` - 29 languages
- `eleven_flash_v2` - Ultra-fast
- `eleven_flash_v2_5` - Balanced

Set via: `ElevenLabsWrapper.set_model("eleven_multilingual_v2")`

---

## 🧪 Testing

### **TTS Test Suite** (`scenes/TTSTest.gd`)

Tests real-time LLM → TTS integration:

1. LLM generates text chunks
2. Chunks batched and sent to ElevenLabs
3. Audio plays in real-time as chunks arrive
4. All audio completes before cleanup

**Run via:** UI button in test scene

---

## 📁 Project Structure

```
addons/godot_llm/
├── runtime/
│   ├── llm_manager/          # LLMManager autoload
│   ├── openai_wrapper/       # OpenAI client
│   ├── llm_agent/            # Agent abstraction
│   ├── llm_tool_registry/    # Tool builder & registry
│   ├── llm_tool/             # Tool definition class
│   ├── message/              # Message builders
│   ├── llm_email_manager/    # Email system
│   └── audio_services/       # Audio integration
│       ├── openai_stt/       # Speech-to-text
│       └── elevenlabs_wrapper/ # Text-to-speech
└── plugin.gd                 # EditorPlugin

scenes/
├── TTSTest.gd                # TTS integration test
└── control.gd                # Main demo scene
```

---

## 🚀 Next Steps

**Potential Enhancements:**

1. Add more TTS voices/languages
2. Implement conversation interruption (stop mid-speech)
3. Add lip-sync support using alignment data
4. Create pre-built NPC templates
5. Add conversation memory/context management

---

## 📝 Notes

### **Design Principles**

1. **Signal-Based** - No polling, no arbitrary timeouts
2. **Thread-Safe** - Parallel tool execution without race conditions
3. **Production-Ready** - Comprehensive error handling
4. **Developer-Friendly** - Minimal boilerplate, fluent APIs
5. **Godot-Native** - Uses Godot idioms (signals, autoloads, nodes)

### **Known Limitations**

1. **Real-time TTS latency** - 1-2s per chunk due to buffer constraints
2. **WebSocket buffer size** - Must set 16MB (Godot default is 64KB)
3. **Audio format** - PCM only for real-time (MP3 requires complete file)

---

**Status:** ✅ **Complete and Production-Ready**  
**Last Updated:** October 2025
