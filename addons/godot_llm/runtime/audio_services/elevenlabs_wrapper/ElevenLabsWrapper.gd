## ElevenLabs Text-to-Speech Wrapper
## 
## WebSocket-based real-time and buffered TTS using ElevenLabs stream-input API.
## Supports both standalone usage and LLM integration with automatic text batching.
##
## MODES:
##   - BUFFERED (MP3): Collects all audio, plays when complete (~2-3s latency)
##   - REAL_TIME (PCM): Plays chunks as they arrive (~100-500ms latency)
##
## STANDALONE USAGE (No LLM):
##   ```
##   # One-shot speech (BUFFERED)
##   ElevenLabsWrapper.initialize("api_key", StreamingMode.BUFFERED)
##   await ElevenLabsWrapper.create_character_context("npc1", "voice_id")
##   ElevenLabsWrapper.speak_as_character("npc1", "Hello!")
##   ElevenLabsWrapper.audio_stream_ready.connect(func(stream, ctx):
##       player.stream = stream
##       player.play()
##   )
##
##   # Manual streaming (REAL_TIME)
##   ElevenLabsWrapper.set_streaming_mode(StreamingMode.REAL_TIME)
##   await ElevenLabsWrapper.create_character_context("npc1", "voice_id")
##   var player = await ElevenLabsWrapper.create_realtime_player(self, "npc1")
##   ElevenLabsWrapper.feed_text_to_character("npc1", "Hello there!")
##   await ElevenLabsWrapper.finish_character_speech("npc1")
##   # Wait for playback_finished signal before cleanup
##   ```
##
## LLM INTEGRATION:
##   ```
##   # Stream LLM output → TTS (REAL_TIME)
##   var player = await ElevenLabsWrapper.create_realtime_player(self, "npc1")
##   
##   agent.delta.connect(func(id, text):
##       ElevenLabsWrapper.feed_text_to_character("npc1", text)
##   )
##   
##   agent.finished.connect(func(id, ok, result):
##       # Flush remaining buffer
##       var buf = ElevenLabsWrapper.character_contexts["npc1"]["batch_buffer"]
##       if buf.length() > 0:
##           ElevenLabsWrapper.feed_text_to_character("npc1", "", true)
##       await ElevenLabsWrapper.finish_character_speech("npc1")
##   )
##   
##   ElevenLabsWrapper.playback_finished.connect(func(ctx):
##       player.cleanup()  # Safe to cleanup
##   )
##   
##   agent.ainvoke(Message.user_simple("Hello!"))
##   ```
##
## SIGNALS:
##   - synthesis_completed(context_id): ElevenLabs finished generating (isFinal)
##   - playback_finished(context_id): All audio played - SAFE TO CLEANUP
##   - audio_chunk_ready(data, context_id): Raw PCM/MP3 bytes
##   - audio_stream_ready(stream, context_id): AudioStreamMP3 (BUFFERED mode only)
##
## CRITICAL: Always wait for playback_finished before cleanup, NOT synthesis_completed!
##
## @tutorial: https://elevenlabs.io/docs/websockets

extends Node

## ========== SIGNALS ==========

## HIGH-LEVEL: Emitted when a ready-to-play AudioStream is available (BUFFERED mode only)
## User receives AudioStreamMP3 that can be directly assigned to AudioStreamPlayer
signal audio_stream_ready(stream: AudioStream, context_id: String)

## LOW-LEVEL: Emitted when raw audio chunk is received (BOTH modes)
## BUFFERED mode: MP3 bytes | REAL-TIME mode: PCM bytes
signal audio_chunk_ready(audio_data: PackedByteArray, context_id: String)

## Emitted when synthesis completes successfully (isFinal received from ElevenLabs)
signal synthesis_completed(context_id: String)

## Emitted when playback is completely finished (all chunks played, safe to cleanup)
signal playback_finished(context_id: String)

## Emitted when synthesis encounters an error
signal synthesis_error(context_id: String, error: Dictionary)

## Emitted when voice list is retrieved
signal voices_received(voices: Array)

## Emitted when character context is created
signal character_context_created(context_id: String, voice_id: String)

## Emitted when character context is destroyed
signal character_context_destroyed(context_id: String)

## ========== AUDIO PLAYBACK CONSTANTS ==========

## PCM audio sample rate (ElevenLabs uses 16kHz for PCM output)
const PCM_SAMPLE_RATE: int = 16000

## Recommended buffer length for real-time playback
## 8.0 seconds = 128000 frames at 16kHz (large buffer to handle chunk bursts)
const PCM_BUFFER_LENGTH: float = 8.0

## ElevenLabs API configuration
var api_key: String = ""
var model_id: String = "eleven_turbo_v2"  # Default model (eleven_turbo_v2, eleven_multilingual_v2, etc.)
var websocket_url: String = "wss://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream-input?model_id={model_id}&inactivity_timeout=180"
var default_voice_id: String = "21m00Tcm4TlvDq8ikWAM"  # Default voice
var inactivity_timeout: int = 180  # Max 180 seconds (default is 20)

## Streaming mode configuration
enum StreamingMode {
	BUFFERED,    ## Collect all chunks, play when complete (lower latency impact, smoother playback)
	REAL_TIME    ## Play chunks as they arrive (lowest latency, requires PCM format)
}
var streaming_mode: StreamingMode = StreamingMode.BUFFERED  ## Default to buffered mode

## Voice settings (applied to all contexts)
var voice_stability: float = 0.5
var voice_similarity_boost: float = 0.75
var voice_style: float = 0.0
var voice_use_speaker_boost: bool = true

## WebSocket connections and contexts
var websocket: WebSocketPeer
var connection_state: String = "disconnected"  # disconnected, connecting, connected, error
var character_contexts: Dictionary = {}  # context_id -> context_data
var voice_connections: Dictionary = {}   # voice_id -> websocket
var active_voice: String = ""

## Audio chunk collection (for BUFFERED mode to emit audio_stream_ready)
var collected_audio_chunks: Dictionary = {}  # context_id -> Array[PackedByteArray]

func _ready():
	websocket = WebSocketPeer.new()
	print("ElevenLabs: WebSocket client created for real-time streaming")

## Initialize the wrapper with API key
func initialize(elevenlabs_api_key: String, mode: StreamingMode = StreamingMode.BUFFERED) -> void:
	api_key = elevenlabs_api_key
	streaming_mode = mode
	var mode_str = "BUFFERED" if mode == StreamingMode.BUFFERED else "REAL_TIME"
	print("ElevenLabsWrapper initialized for real-time streaming (Mode: %s)" % mode_str)

## Set streaming mode (can be changed at runtime)
func set_streaming_mode(mode: StreamingMode) -> void:
	streaming_mode = mode
	var mode_str = "BUFFERED" if mode == StreamingMode.BUFFERED else "REAL_TIME"
	print("ElevenLabs: Streaming mode changed to %s" % mode_str)

## Set the ElevenLabs model to use
## Available models:
##   - "eleven_turbo_v2" (default) - Fastest, lowest latency, great quality
##   - "eleven_multilingual_v2" - Supports 29 languages
##   - "eleven_monolingual_v1" - English only, high quality
##   - "eleven_flash_v2" - Ultra-fast, lower quality
##   - "eleven_flash_v2_5" - Balanced speed/quality
func set_model(new_model_id: String) -> void:
	model_id = new_model_id
	print("ElevenLabs: Model changed to %s" % model_id)

## Get the output format based on streaming mode
func _get_output_format() -> String:
	if streaming_mode == StreamingMode.REAL_TIME:
		return "pcm_16000"  # PCM 16kHz - best quality, text chunking prevents "Message too big"
	else:
		return "mp3_44100_128"  # MP3 for buffered playback (default)

## Create a character context for a specific voice
## Returns the context_id for this character
func create_character_context(context_id: String, voice_id: String = "") -> bool:
	if api_key.is_empty():
		push_error("ElevenLabs API key not set")
		return false
	
	if voice_id.is_empty():
		voice_id = default_voice_id
	
	if character_contexts.has(context_id):
		push_warning("Context already exists: " + context_id)
		return false
	
	# Store context info
	character_contexts[context_id] = {
		"voice_id": voice_id,
		"websocket": null,
		"connection_state": "disconnected",
		"batch_buffer": "",  # Text batching (matches Python SDK text_chunker)
	}
	
	# Connect to WebSocket for this voice
	await _connect_to_voice(context_id, voice_id)
	
	character_context_created.emit(context_id, voice_id)
	return true

## Speak text as a specific character (complete utterance)
## Sends the text and automatically closes the input stream
func speak_as_character(context_id: String, text: String) -> bool:
	print("[ElevenLabs] >>> speak_as_character('%s', '%s')" % [context_id, text.substr(0, 50) + ("..." if text.length() > 50 else "")])
	
	if not character_contexts.has(context_id):
		print("[ElevenLabs] ❌ Context '%s' not found!" % context_id)
		push_error("Character context not found: " + context_id)
		return false
	
	var context = character_contexts[context_id]
	if context["connection_state"] != "connected":
		print("[ElevenLabs] ❌ Context '%s' not connected (state: %s)" % [context_id, context["connection_state"]])
		push_error("Character context not connected: " + context_id)
		return false
	
	# Send text to WebSocket for immediate synthesis
	print("[ElevenLabs] 📤 Sending text to '%s'..." % context_id)
	_send_text_to_context(context_id, text)
	
	# Automatically close the input stream for complete utterance
	print("[ElevenLabs] 🏁 Auto-closing input stream for '%s'" % context_id)
	_send_end_of_input(context_id)
	
	print("[ElevenLabs] ✅ speak_as_character complete for '%s'" % context_id)
	return true

## Send text chunk to character (for streaming text input)
## @param flush_immediately: If true, forces immediate audio generation (use for final chunk)
func feed_text_to_character(context_id: String, text_chunk: String, flush_immediately: bool = false) -> bool:
	if not character_contexts.has(context_id):
		push_warning("Character context not found: " + context_id)
		return false
	
	var context = character_contexts[context_id]
	
	# Python SDK approach: Text batching for REAL_TIME mode (matches text_chunker logic)
	if streaming_mode == StreamingMode.REAL_TIME:
		# Accumulate text and send on sentence boundaries (punctuation)
		context["batch_buffer"] += text_chunk
		
		# Check if we should send (sentence boundary or flush requested)
		var should_send = flush_immediately
		var splitters = [".", ",", "?", "!", ";", ":", " "]
		
		if not should_send:
			# Check if buffer ends with punctuation
			for splitter in splitters:
				if context["batch_buffer"].ends_with(splitter):
					should_send = true
					break
		
		if should_send and context["batch_buffer"].length() > 0:
			var text_to_send = context["batch_buffer"]
			# Ensure it ends with space (Python SDK does this)
			if not text_to_send.ends_with(" "):
				text_to_send += " "
			_send_text_to_context(context_id, text_to_send, flush_immediately)
			context["batch_buffer"] = ""
	else:
		# BUFFERED mode: Send text directly (no batching needed for MP3 generation)
		_send_text_to_context(context_id, text_chunk, flush_immediately)
	
	return true

## Finish speaking for a character (end the current speech)
## Python SDK: After sending {"text":""}, keep receiving until connection closes
func finish_character_speech(context_id: String) -> bool:
	if not character_contexts.has(context_id):
		return false
	
	# Send end-of-input signal to WebSocket
	_send_end_of_input(context_id)
	
	# Python SDK: DRAIN remaining messages after sending close signal
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	var max_drain_time = 2.0
	var drain_start = Time.get_ticks_msec()
	
	while ws and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.poll()
		
		# Process any remaining packets
		while ws.get_available_packet_count() > 0:
			var packet = ws.get_packet()
			_handle_websocket_message(context_id, packet)
		
		# Timeout check
		if (Time.get_ticks_msec() - drain_start) / 1000.0 > max_drain_time:
			break
		
		await Engine.get_main_loop().process_frame
	
	return true

## Destroy a character context
func destroy_character_context(context_id: String) -> void:
	if not character_contexts.has(context_id):
		return
	
	var context = character_contexts[context_id]
	if context["websocket"]:
		context["websocket"].close()
	
	character_contexts.erase(context_id)
	character_context_destroyed.emit(context_id)

## Get available voices asynchronously (kept for compatibility)
func get_available_voices_async() -> String:
	var request_id = "voices_" + str(Time.get_unix_time_from_system())
	_request_voices(request_id)
	return request_id

## Set voice parameters for synthesis (applies to all new contexts)
func set_voice_settings(stability: float, similarity_boost: float, style: float = 0.0, use_speaker_boost: bool = true) -> void:
	voice_stability = clamp(stability, 0.0, 1.0)
	voice_similarity_boost = clamp(similarity_boost, 0.0, 1.0)
	voice_style = clamp(style, 0.0, 1.0)
	voice_use_speaker_boost = use_speaker_boost

## Set the default voice ID
func set_default_voice(voice_id: String) -> void:
	default_voice_id = voice_id

## Check if the wrapper is properly initialized
func is_initialized() -> bool:
	return not api_key.is_empty()

## Get list of active character contexts
func get_active_contexts() -> Array:
	return character_contexts.keys()

## Check if a character context exists and is connected
func is_character_connected(context_id: String) -> bool:
	if not character_contexts.has(context_id):
		return false
	return character_contexts[context_id]["connection_state"] == "connected"

## Process WebSocket events for all contexts
func _process(_delta):
	# Poll all active WebSocket connections (matches Python SDK - poll for incoming messages)
	for context_id in character_contexts:
		var context = character_contexts[context_id]
		if context["websocket"]:
			_poll_websocket(context_id)

## Internal method to connect to WebSocket for a voice
func _connect_to_voice(context_id: String, voice_id: String) -> void:
	var context = character_contexts[context_id]
	
	# Create WebSocket connection with 16MB buffers (fix for "Message too big" error)
	var ws = WebSocketPeer.new()
	ws.set_inbound_buffer_size(16 * 1024 * 1024)  # 16MB
	ws.set_outbound_buffer_size(16 * 1024 * 1024)  # 16MB
	context["websocket"] = ws
	context["connection_state"] = "connecting"
	
	# Build WebSocket URL
	var url = websocket_url.replace("{voice_id}", voice_id).replace("{model_id}", model_id)
	var output_format = _get_output_format()
	url += "&output_format=" + output_format
	
	# Connect to WebSocket
	var error = ws.connect_to_url(url)
	if error != OK:
		context["connection_state"] = "error"
		synthesis_error.emit(context_id, {"error": "Failed to connect WebSocket", "code": error})
		return
	
	# Wait for connection
	var timeout = 10.0
	var elapsed = 0.0
	while elapsed < timeout:
		ws.poll()
		var state = ws.get_ready_state()
		
		if state == WebSocketPeer.STATE_OPEN:
			context["connection_state"] = "connected"
			_send_initial_config(context_id)
			return
		elif state == WebSocketPeer.STATE_CLOSED:
			context["connection_state"] = "error"
			synthesis_error.emit(context_id, {"error": "WebSocket connection failed"})
			return
		
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	
	# Timeout
	context["connection_state"] = "error"
	synthesis_error.emit(context_id, {"error": "WebSocket connection timeout"})

## Send initial configuration to WebSocket with API key authentication
func _send_initial_config(context_id: String) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	# First message MUST include text=" " (a space) per ElevenLabs WebSocket API spec
	# This initializes the connection with voice settings and API key
	var config_message = {
		"text": " ",  # REQUIRED: Initial text must be a blank space
		"try_trigger_generation": true,  # Python SDK uses this in handshake!
		"voice_settings": {
			"stability": voice_stability,
			"similarity_boost": voice_similarity_boost
		},
		"xi_api_key": api_key  # API key for authentication
	}
	
	# For REAL_TIME mode: Let ElevenLabs use default chunk schedule
	# Python SDK uses [50] but that creates large audio chunks that exceed WebSocket limits
	# Removing this lets ElevenLabs use optimized defaults to avoid "Message too big" errors
	# (Default schedule is adaptive and won't exceed WebSocket frame size)
	
	var json_string = JSON.stringify(config_message)
	ws.send_text(json_string)

## Send text to specific character context
## Python SDK NEVER uses flush:true - only try_trigger_generation:true
func _send_text_to_context(context_id: String, text: String, force_flush: bool = false) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	if not ws or context["connection_state"] != "connected":
		push_error("Context not connected: " + context_id)
		return
	
	# Build text message - Python SDK ALWAYS uses try_trigger_generation
	var text_message = {
		"text": text,
		"try_trigger_generation": true  # Always true, as per Python SDK
	}
	
	var json_string = JSON.stringify(text_message)
	ws.send_text(json_string)
	
	# Python SDK: Opportunistic receive after sending (non-blocking poll)
	ws.poll()
	if ws.get_available_packet_count() > 0:
		var packet = ws.get_packet()
		_handle_websocket_message(context_id, packet)

## Send end-of-input signal to character context
func _send_end_of_input(context_id: String) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	if not ws or context["connection_state"] != "connected":
		return
	
	var end_message = {"text": ""}
	var json_string = JSON.stringify(end_message)
	ws.send_text(json_string)

## Poll WebSocket for messages
func _poll_websocket(context_id: String) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	if not ws:
		return
	
	ws.poll()
	var state = ws.get_ready_state()
	
	match state:
		WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var packet = ws.get_packet()
				_handle_websocket_message(context_id, packet)
		
		WebSocketPeer.STATE_CLOSING:
			print("[ElevenLabs] ⚠️ WebSocket CLOSING for '%s' (code: %d, reason: %s)" % [
				context_id,
				ws.get_close_code(),
				ws.get_close_reason()
			])
		
		WebSocketPeer.STATE_CLOSED:
			if context["connection_state"] == "connected":
				# Connection closed - log details
				print("[ElevenLabs] 🔴 WebSocket CLOSED for '%s' (code: %d, reason: %s)" % [
					context_id,
					ws.get_close_code(),
					ws.get_close_reason()
				])
				context["connection_state"] = "disconnected"

## Handle WebSocket message from ElevenLabs
func _handle_websocket_message(context_id: String, packet: PackedByteArray) -> void:
	var packet_string = packet.get_string_from_utf8()
	
	if packet_string.begins_with("{"):
		# JSON message
		var json = JSON.new()
		var parse_result = json.parse(packet_string)
		
		if parse_result == OK:
			_handle_json_message(context_id, json.data)
	else:
		# Binary audio data
		_handle_audio_data(context_id, packet)

## Handle JSON message from WebSocket
func _handle_json_message(context_id: String, message: Dictionary) -> void:
	# Audio chunk
	if message.has("audio") and message["audio"] != null and message["audio"] != "":
		var audio_base64 = message["audio"]
		if typeof(audio_base64) == TYPE_STRING and audio_base64.length() > 0:
			var audio_bytes = Marshalls.base64_to_raw(audio_base64)
			_handle_audio_data(context_id, audio_bytes)
	
	# Synthesis complete
	if message.has("isFinal") and message["isFinal"]:
		# If BUFFERED mode, emit ready-to-play AudioStream
		if streaming_mode == StreamingMode.BUFFERED and collected_audio_chunks.has(context_id):
			var chunks = collected_audio_chunks[context_id]
			if chunks.size() > 0:
				var combined = PackedByteArray()
				for chunk in chunks:
					combined.append_array(chunk)
				
				var audio_stream = AudioStreamMP3.new()
				audio_stream.data = combined
				audio_stream_ready.emit(audio_stream, context_id)
			
			collected_audio_chunks.erase(context_id)
		
		synthesis_completed.emit(context_id)
	
	# Error handling
	if message.has("error"):
		print("[ElevenLabs] ERROR: %s" % str(message["error"]))
		synthesis_error.emit(context_id, message)

## Handle binary audio data
func _handle_audio_data(context_id: String, audio_data: PackedByteArray) -> void:
	if audio_data.size() > 0:
		# Always emit low-level chunk (for both modes)
		audio_chunk_ready.emit(audio_data, context_id)
		
		# If BUFFERED mode, collect chunks for audio_stream_ready signal
		if streaming_mode == StreamingMode.BUFFERED:
			if not collected_audio_chunks.has(context_id):
				collected_audio_chunks[context_id] = []
			collected_audio_chunks[context_id].append(audio_data)

## Internal method to request voices (simplified for HTTP)
func _request_voices(request_id: String) -> void:
	# For now, return mock voices until we implement HTTP voices API
	# Real implementation would use HTTPRequest for voices endpoint
	var mock_voices = [
		{"voice_id": "21m00Tcm4TlvDq8ikWAM", "name": "Rachel", "category": "premade"},
		{"voice_id": "AZnzlk1XvdvUeBnXmlld", "name": "Domi", "category": "premade"},
		{"voice_id": "EXAVITQu4vr4xnSDxMaL", "name": "Bella", "category": "premade"},
		{"voice_id": "pNInz6obpgDQGcFmaJgB", "name": "Adam", "category": "premade"},
		{"voice_id": "VR6AewLTigWG4xSOukaG", "name": "Arnold", "category": "premade"}
	]
	
	# Emit after a small delay to simulate API call
	call_deferred("_emit_voices_received", mock_voices)

## Emit voices received signal
func _emit_voices_received(voices: Array) -> void:
	voices_received.emit(voices)

## Clean up resources
func _exit_tree():
	# Close all WebSocket connections
	for context_id in character_contexts:
		destroy_character_context(context_id)
	
	if websocket:
		websocket.close()
	
	character_contexts.clear()
	voice_connections.clear()

## ========== HELPER FUNCTIONS FOR USER ==========

## Helper: Convert 16-bit PCM audio data to audio frames for AudioStreamGenerator
## 
## Use this for REAL-TIME mode to push PCM chunks to your AudioStreamGeneratorPlayback
## 
## Example:
##   var player = AudioStreamPlayer.new()
##   var gen = AudioStreamGenerator.new()
##   gen.mix_rate = ElevenLabsWrapper.PCM_SAMPLE_RATE
##   gen.buffer_length = ElevenLabsWrapper.PCM_BUFFER_LENGTH
##   player.stream = gen
##   player.play()
##   var playback = player.get_stream_playback()
##   
##   ElevenLabsWrapper.audio_chunk_ready.connect(func(pcm, ctx):
##       ElevenLabsWrapper.convert_pcm_to_frames(playback, pcm))
##
## @param playback: AudioStreamGeneratorPlayback object from your AudioStreamPlayer
## @param pcm_data: PCM audio data (16-bit signed integer, little-endian, mono)
static func convert_pcm_to_frames(playback: AudioStreamGeneratorPlayback, pcm_data: PackedByteArray) -> void:
	if not playback:
		push_error("ElevenLabs: Invalid AudioStreamGeneratorPlayback provided to convert_pcm_to_frames")
		return
	
	if pcm_data.is_empty():
		return
	
	# PCM is 16-bit (2 bytes per sample)
	var frame_count = int(pcm_data.size() / 2.0)
	
	for i in range(frame_count):
		var byte_index = i * 2
		
		# Read 16-bit signed integer (little-endian)
		var sample_int = pcm_data[byte_index] | (pcm_data[byte_index + 1] << 8)
		
		# Convert to signed 16-bit
		if sample_int >= 32768:
			sample_int -= 65536
		
		# Normalize to float [-1.0, 1.0]
		var sample_float = float(sample_int) / 32768.0
		
		# Push stereo frame (mono source, duplicate to both channels)
		playback.push_frame(Vector2(sample_float, sample_float))


## ========== HELPER: REAL-TIME PCM PLAYER ==========

## Helper class to manage real-time PCM playback with automatic queue management.
## 
## This handles all the complexity of:
##   - AudioStreamGenerator setup
##   - Queue management for smooth playback
##   - Timer-based queue processing
##   - Automatic cleanup
##
## Usage:
##   var player = ElevenLabsWrapper.create_realtime_player(parent_node, context_id)
##   # Player auto-connects to audio_chunk_ready signal
##   # Auto-plays and manages everything!
##   
##   # When done:
##   player.cleanup()
##
class RealtimePCMPlayer extends Node:
	var context_id: String
	var audio_player: AudioStreamPlayer
	var playback: AudioStreamGeneratorPlayback
	var audio_queue: Array[PackedByteArray] = []
	var queue_timer: Timer
	var wrapper_ref  # Reference to ElevenLabsWrapper (for signals)
	var prebuffer_threshold: int = 1
	var is_prebuffered: bool = false
	var synthesis_complete: bool = false
	var playback_start_time: float = 0.0
	
	func _init(ctx_id: String, parent: Node, wrapper):
		context_id = ctx_id
		wrapper_ref = wrapper
		name = "RealtimePCMPlayer_" + context_id
		
		# Create AudioStreamPlayer with generator
		audio_player = AudioStreamPlayer.new()
		audio_player.name = "Player_" + context_id
		var generator = AudioStreamGenerator.new()
		generator.mix_rate = PCM_SAMPLE_RATE  # 16kHz for PCM
		generator.buffer_length = PCM_BUFFER_LENGTH
		audio_player.stream = generator
		add_child(audio_player)
		
		# Create timer for queue processing
		queue_timer = Timer.new()
		queue_timer.name = "QueueTimer_" + context_id
		queue_timer.wait_time = 0.001  # 1ms
		queue_timer.one_shot = false
		queue_timer.timeout.connect(_process_queue)
		add_child(queue_timer)
		
		# Add to parent FIRST (must be in tree before play/start)
		parent.add_child(self)
	
	## Call after node is in tree to start playback
	func initialize_playback() -> bool:
		# Now that we're in the tree, start playback and timer
		audio_player.play()
		queue_timer.start()
		
		# Get playback stream
		playback = audio_player.get_stream_playback()
		if not playback:
			push_error("ElevenLabs RealtimePCMPlayer: Failed to get playback")
			return false
		
		# Connect to wrapper's audio and synthesis signals
		wrapper_ref.audio_chunk_ready.connect(_on_audio_chunk)
		wrapper_ref.synthesis_completed.connect(_on_synthesis_complete)
		return true
	
	func _on_synthesis_complete(ctx_id: String):
		if ctx_id != context_id:
			return
		
		synthesis_complete = true
		
		# If synthesis is done and we have chunks but haven't started playing, start now!
		if not is_prebuffered and not audio_queue.is_empty():
			is_prebuffered = true
			playback_start_time = Time.get_ticks_msec() / 1000.0
	
	func _on_audio_chunk(audio: PackedByteArray, ctx_id: String):
		if ctx_id != context_id:
			return
		
		audio_queue.append(audio)
		
		# Start playback immediately when first chunk arrives
		if not is_prebuffered and (audio_queue.size() >= prebuffer_threshold or synthesis_complete):
			is_prebuffered = true
			playback_start_time = Time.get_ticks_msec() / 1000.0
	
	func _process_queue():
		if not is_prebuffered or audio_queue.is_empty():
			return
		
		var chunks_processed_this_cycle = 0
		
		while not audio_queue.is_empty():
			var next_chunk = audio_queue[0]
			var frames_needed = int(next_chunk.size() / 2.0)  # PCM is 2 bytes per sample
			var frames_available = playback.get_frames_available()
			
			if frames_available >= frames_needed:
				var chunk = audio_queue.pop_front()
				ElevenLabsWrapper.convert_pcm_to_frames(playback, chunk)
				chunks_processed_this_cycle += 1
			else:
				break
		
		# Check if playback is complete (queue empty + synthesis done)
		if chunks_processed_this_cycle > 0 and audio_queue.is_empty() and synthesis_complete:
			# Calculate remaining audio in buffer and schedule completion signal
			var frames_remaining = (PCM_SAMPLE_RATE * PCM_BUFFER_LENGTH) - playback.get_frames_available()
			var seconds_remaining = float(frames_remaining) / float(PCM_SAMPLE_RATE)
			
			# Schedule playback_finished signal after buffer drains
			var completion_timer = get_tree().create_timer(seconds_remaining + 0.5)
			completion_timer.timeout.connect(func():
				wrapper_ref.playback_finished.emit(context_id)
			)
	
	func get_queue_size() -> int:
		return audio_queue.size()
	
	func is_queue_empty() -> bool:
		return audio_queue.is_empty()
	
	func cleanup():
		if wrapper_ref:
			if wrapper_ref.audio_chunk_ready.is_connected(_on_audio_chunk):
				wrapper_ref.audio_chunk_ready.disconnect(_on_audio_chunk)
			if wrapper_ref.synthesis_completed.is_connected(_on_synthesis_complete):
				wrapper_ref.synthesis_completed.disconnect(_on_synthesis_complete)
		queue_timer.stop()
		queue_free()


## Factory method to create a real-time PCM player for a context.
## 
## This is the EASIEST way to play real-time PCM audio:
##   1. Creates and configures AudioStreamPlayer
##   2. Sets up queue management
##   3. Auto-connects to audio_chunk_ready signal
##   4. Returns a player you can query/cleanup
##
## Usage (from instance method):
##   var player = await create_realtime_player(self, "my_context")
##   # Audio plays automatically as chunks arrive!
##
## Usage (from static context):
##   var wrapper = get_node("/root/ElevenLabsWrapper")  # Cache this!
##   var player = await ElevenLabsWrapper.create_realtime_player_with_wrapper(
##       self, "my_context", wrapper
##   )
##   
##   # Check queue status:
##   if player.is_queue_empty():
##       print("All audio played!")
##   
##   # Cleanup when done:
##   player.cleanup()
##
## @param parent_node: Node to attach the player to (usually 'self' in your script)
## @param context_id: The character context ID to play audio for
## @param wrapper_instance: Optional wrapper instance (defaults to autoload lookup)
## @return RealtimePCMPlayer instance (ready to use)
static func create_realtime_player(parent_node: Node, context_id: String, wrapper_instance = null) -> RealtimePCMPlayer:
	var wrapper = wrapper_instance
	
	# If no wrapper provided, look it up (less efficient, but convenient)
	if not wrapper:
		wrapper = parent_node.get_node_or_null("/root/ElevenLabsWrapper")
		if not wrapper:
			push_error("ElevenLabs: ElevenLabsWrapper autoload not found (check Project Settings > Autoload)")
			return null
	
	var player = RealtimePCMPlayer.new(context_id, parent_node, wrapper)
	
	# Wait for player to be in tree and playback to be ready
	await parent_node.get_tree().process_frame
	
	if not player.initialize_playback():
		player.queue_free()
		return null
	
	return player
