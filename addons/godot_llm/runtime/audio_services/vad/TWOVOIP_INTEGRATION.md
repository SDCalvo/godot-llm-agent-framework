# TwoVoip Integration Guide

## Overview

This document describes how we integrate TwoVoip's AudioEffectOpusChunked for AI-powered Voice Activity Detection (VAD) and noise suppression in our LLM add-on.

## TwoVoip Architecture

TwoVoip provides three processing stages for microphone audio:

```
Raw Audio (44.1kHz) → Resampled (48kHz) → Denoised (48kHz + RnNoise)
     ↓                      ↓                       ↓
audiosamplebuffer    audioresampledbuffer    audiodenoisedbuffer
```

## Key API Methods

### Audio Processing

```gdscript
# Check if a chunk is available
opuschunked.chunk_available() -> bool

# Get raw audio frames (PackedVector2Array)
opuschunked.read_chunk(resampled: bool) -> PackedVector2Array
# - resampled=false: Returns 44.1kHz raw audio
# - resampled=true:  Returns 48kHz audio (denoised if denoise was called)

# AI-powered VAD with RnNoise denoising
opuschunked.denoise_resampled_chunk() -> float  # Returns speech probability [0.0, 1.0]

# Simple amplitude-based VAD
opuschunked.chunk_max(rms: bool, resampled: bool) -> float

# Advance to next chunk
opuschunked.drop_chunk()

# Roll back to previous chunk (for retroactive grace period)
opuschunked.undrop_chunk() -> bool

# Force resampling (called automatically by denoise_resampled_chunk)
opuschunked.resampled_current_chunk()

# Reset encoder state after gaps
opuschunked.resetencoder(clearbuffers: bool)
```

### Configuration Properties

```gdscript
# Input audio (from microphone)
opuschunked.audiosamplerate = 44100   # Input sample rate
opuschunked.audiosamplesize = 882     # Input chunk size (20ms @ 44.1kHz)

# Output audio (for RnNoise/Opus)
opuschunked.opussamplerate = 48000    # MUST be 48000 for RnNoise
opuschunked.opusframesize = 960       # 20ms @ 48kHz

# Buffer
opuschunked.ringbufferchunks = 50     # Number of chunks to buffer

# Opus encoding (if needed)
opuschunked.opusbitrate = 12000
opuschunked.opuscomplexity = 5
opuschunked.opusoptimizeforvoice = true
```

## Audio Format Conversion

### PackedVector2Array to PCM

TwoVoip returns audio as `PackedVector2Array` where each `Vector2` represents one stereo sample:
- `Vector2.x` = left channel (float, range [-1.0, 1.0])
- `Vector2.y` = right channel (float, range [-1.0, 1.0])

To convert to 16-bit PCM mono for Deepgram:

```gdscript
func convert_to_pcm_mono(frames: PackedVector2Array) -> PackedByteArray:
    var pcm = PackedByteArray()
    pcm.resize(frames.size() * 2)  # 2 bytes per sample
    
    for i in range(frames.size()):
        # Convert stereo to mono
        var mono = (frames[i].x + frames[i].y) / 2.0
        
        # Convert float [-1.0, 1.0] to int16 [-32768, 32767]
        var sample_int = int(clamp(mono * 32767.0, -32768.0, 32767.0))
        
        # Write little-endian
        pcm[i * 2] = sample_int & 0xFF
        pcm[i * 2 + 1] = (sample_int >> 8) & 0xFF
    
    return pcm
```

## VAD Implementation Pattern

### Recommended Flow

```gdscript
while opuschunked.chunk_available():
    # 1. Run AI-powered VAD + denoising
    var speech_prob = opuschunked.denoise_resampled_chunk()
    
    if speech_prob >= vad_threshold:
        if not is_speech_active:
            # Speech just started - roll back to capture beginning
            opuschunked.undrop_chunk()
            is_speech_active = true
        
        # 2. Get denoised 48kHz audio
        var frames = opuschunked.read_chunk(true)  # resampled=true
        
        # 3. Convert to PCM for Deepgram
        var pcm = convert_to_pcm_mono(frames)
        
        # 4. Stream to STT service
        stream_to_stt(pcm)
    else:
        # Handle silence with grace period
        silence_frames += 1
        if silence_frames > grace_period_frames:
            is_speech_active = false
    
    # 5. Advance to next chunk
    opuschunked.drop_chunk()
```

## Setup Requirements

### 1. Project Settings

```gdscript
# Enable microphone input (user must do this ONCE)
ProjectSettings.set_setting("audio/driver/enable_input", true)

# Set mix rate to 48kHz (recommended)
ProjectSettings.set_setting("audio/driver/mix_rate", 48000)
```

### 2. Audio Bus Creation

```gdscript
# Create dedicated microphone bus
var bus_idx = AudioServer.bus_count
AudioServer.add_bus(bus_idx)
AudioServer.set_bus_name(bus_idx, "VAD_Microphone")
AudioServer.set_bus_mute(bus_idx, true)  # Prevent feedback loop

# Add OpusChunked effect
var opuschunked = AudioEffectOpusChunked.new()
AudioServer.add_bus_effect(bus_idx, opuschunked, 0)
```

### 3. Microphone Player

```gdscript
# Create player with microphone stream
var player = AudioStreamPlayer.new()
player.stream = AudioStreamMicrophone.new()
player.bus = "VAD_Microphone"
player.autoplay = false  # Start manually

# Start recording
player.play()
```

## Integration with Deepgram

Deepgram WebSocket API requirements:
- **Sample Rate:** 48kHz ✅ (matches TwoVoip output!)
- **Format:** Linear PCM, 16-bit, little-endian ✅
- **Channels:** Mono preferred ✅
- **Encoding:** Raw bytes (not Opus) ✅

No resampling needed - TwoVoip's 48kHz output is perfect for Deepgram!

## Performance Notes

- **RnNoise Frame Size:** 480 samples (10ms @ 48kHz)
- **OpusChunked Frame Size:** 960 samples (20ms @ 48kHz) = 2 RnNoise frames
- **Processing:** Denoising happens per 10ms frame, VAD per 20ms chunk
- **Latency:** `retroactive_grace_ms` setting adds latency but captures word starts

## Common Pitfalls

1. **Sample Rate Mismatch:** RnNoise REQUIRES 48kHz. Set `opussamplerate = 48000`!
2. **Forgetting to Call `denoise_resampled_chunk()`:** Must call before `read_chunk(true)` to get denoised audio
3. **Not Muting the Bus:** Always mute the microphone bus to prevent feedback
4. **Buffer Overrun:** Call `drop_chunk()` regularly or buffer will overflow and discard chunks

## Example: Minimal Use Case

```gdscript
extends Node

var opuschunked: AudioEffectOpusChunked
var microphone_player: AudioStreamPlayer

func _ready():
    # Setup bus
    var bus_idx = AudioServer.get_bus_index("MicrophoneBus")
    if bus_idx == -1:
        bus_idx = AudioServer.bus_count
        AudioServer.add_bus(bus_idx)
        AudioServer.set_bus_name(bus_idx, "MicrophoneBus")
        AudioServer.set_bus_mute(bus_idx, true)
    
    # Add effect
    opuschunked = AudioEffectOpusChunked.new()
    AudioServer.add_bus_effect(bus_idx, opuschunked, 0)
    
    # Create player
    microphone_player = AudioStreamPlayer.new()
    microphone_player.stream = AudioStreamMicrophone.new()
    microphone_player.bus = "MicrophoneBus"
    add_child(microphone_player)
    microphone_player.play()

func _process(_delta):
    while opuschunked.chunk_available():
        # AI VAD
        var speech_prob = opuschunked.denoise_resampled_chunk()
        
        if speech_prob >= 0.75:
            # Get denoised audio
            var frames = opuschunked.read_chunk(true)
            var pcm = convert_to_pcm(frames)
            
            # Do something with PCM (e.g., stream to Deepgram)
            process_audio(pcm)
        
        opuschunked.drop_chunk()
```

## References

- TwoVoip GitHub: https://github.com/goatchurchprime/two-voip-godot-4
- RnNoise: https://jmvalin.ca/demo/rnnoise/
- Opus: https://opus-codec.org/
- Deepgram API: https://developers.deepgram.com/

