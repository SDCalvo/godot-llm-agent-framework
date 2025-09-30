## ElevenLabs Text-to-Speech Wrapper
## 
## Provides REAL-TIME streaming TTS functionality using ElevenLabs WebSocket API
## Supports multiple character contexts and real-time text-to-speech conversion
##
## USAGE:
##   # Optional: Change model (default is eleven_turbo_v2)
##   ElevenLabsWrapper.set_model("eleven_multilingual_v2")
##   
##   # Optional: Change streaming mode (default is BUFFERED)
##   ElevenLabsWrapper.set_streaming_mode(ElevenLabsWrapper.StreamingMode.REAL_TIME)
##   
##   # Create context and speak
##   ElevenLabsWrapper.create_character_context("character1", "voice_id")
##   ElevenLabsWrapper.speak_as_character("character1", "Hello world!")
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

## Emitted when synthesis starts for a context
signal synthesis_started(context_id: String)

## Emitted when synthesis completes successfully
signal synthesis_completed(context_id: String)

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
## 4.0 seconds = 64000 frames (large buffer for smooth prebuffered playback)
const PCM_BUFFER_LENGTH: float = 4.0

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

## Text batching configuration (for smoother, more natural speech)
var enable_text_batching: bool = true  ## Automatically batch text chunks for natural phrasing
var text_batch_min_chars: int = 20     ## Minimum characters before considering flush
var text_batch_max_chars: int = 50     ## Maximum characters before forced flush
var text_batch_timeout_ms: int = 500   ## Max time to wait before flushing medium-sized buffer

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

## Rubberband keepalive configuration (adaptive intervals)
const KEEPALIVE_INITIAL_INTERVAL = 30.0  # Start at 30s after first idle period
const KEEPALIVE_MAX_INTERVAL = 150.0     # Max interval (stop at 150s, let timeout at 180s)
const KEEPALIVE_MULTIPLIER = 1.5         # Each keepalive extends interval by 50%

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
		return "pcm_16000"  # PCM for real-time chunk playback
	else:
		return "mp3_44100_128"  # MP3 for buffered playback (default)

## Create a character context for a specific voice
## Returns the context_id for this character
func create_character_context(context_id: String, voice_id: String = "") -> bool:
	print("[ElevenLabs] >>> create_character_context('%s', '%s')" % [context_id, voice_id])
	
	if api_key.is_empty():
		print("[ElevenLabs] ❌ API key not set!")
		push_error("ElevenLabs API key not set")
		return false
	
	if voice_id.is_empty():
		voice_id = default_voice_id
		print("[ElevenLabs] 📝 Using default voice: %s" % voice_id)
	
	if character_contexts.has(context_id):
		print("[ElevenLabs] ⚠️ Context '%s' already exists!" % context_id)
		push_warning("Context already exists: " + context_id)
		return false
	
	# Store context info
	print("[ElevenLabs] 📦 Creating context data for '%s'..." % context_id)
	character_contexts[context_id] = {
		"voice_id": voice_id,
		"websocket": null,
		"connection_state": "disconnected",
		"text_buffer": "",
		"is_speaking": false,
		"last_activity": Time.get_ticks_msec(),  # Track last message sent
		"next_keepalive_interval": KEEPALIVE_INITIAL_INTERVAL,  # Rubberband: current interval
		"time_since_last_keepalive": 0.0,  # Accumulated time for next keepalive
		# Text batching state
		"batch_buffer": "",  # Accumulated text for batching
		"batch_last_flush": Time.get_ticks_msec()  # Last time we flushed batch
	}
	
	# Connect to WebSocket for this voice
	print("[ElevenLabs] 🔌 Connecting to WebSocket for '%s'..." % context_id)
	await _connect_to_voice(context_id, voice_id)
	
	print("[ElevenLabs] ✅ Context '%s' created successfully (voice: %s)" % [context_id, voice_id])
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
	print("[ElevenLabs] >>> feed_text_to_character('%s', '%s', flush=%s)" % [context_id, text_chunk, flush_immediately])
	
	if not character_contexts.has(context_id):
		print("[ElevenLabs] ⚠️ Context '%s' not found!" % context_id)
		push_warning("Character context not found: " + context_id)
		return false
	
	var context = character_contexts[context_id]
	
	# Python SDK approach: Smart batching for REAL_TIME (text_chunker logic)
	# Accumulate text and send on sentence boundaries (punctuation)
	if streaming_mode == StreamingMode.REAL_TIME:
		# Accumulate text in buffer
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
			print("[ElevenLabs] 📤 [REAL_TIME] Sending batched text: '%s'" % text_to_send)
			_send_text_to_context(context_id, text_to_send, flush_immediately)
			context["batch_buffer"] = ""
		else:
			print("[ElevenLabs] 🔄 [REAL_TIME] Buffering: '%s' (%d chars)" % [text_chunk, context["batch_buffer"].length()])
	elif enable_text_batching and not flush_immediately:
		# BUFFERED: Accumulate text for smoother MP3 generation
		context["batch_buffer"] += text_chunk
		var buffer_len = context["batch_buffer"].length()
		print("[ElevenLabs] 🔄 [BUFFERED] Buffering text (%d chars)..." % buffer_len)
	else:
		# BUFFERED final flush or batching disabled
		if flush_immediately and enable_text_batching and context["batch_buffer"].length() > 0:
			print("[ElevenLabs] 📦 Final batch flush: '%s'" % context["batch_buffer"])
			_send_text_to_context(context_id, context["batch_buffer"] + text_chunk, true)
			context["batch_buffer"] = ""
		else:
			print("[ElevenLabs] 📤 Sending chunk to '%s'..." % context_id)
			_send_text_to_context(context_id, text_chunk, flush_immediately)
	
	return true

## Finish speaking for a character (end the current speech)
## Python SDK: After sending {"text":""}, keep receiving until connection closes
func finish_character_speech(context_id: String) -> bool:
	print("[ElevenLabs] >>> finish_character_speech('%s')" % context_id)
	
	if not character_contexts.has(context_id):
		print("[ElevenLabs] ⚠️ Context '%s' not found!" % context_id)
		return false
	
	# Send end-of-input signal to WebSocket
	print("[ElevenLabs] 🏁 Finishing speech for '%s'..." % context_id)
	_send_end_of_input(context_id)
	
	# Python SDK: DRAIN remaining messages after sending close signal
	# Keep polling until connection closes or we timeout
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	var max_drain_time = 2.0  # 2 seconds max to drain
	var drain_start = Time.get_ticks_msec()
	
	print("[ElevenLabs] 🚰 Draining final messages for '%s'..." % context_id)
	while ws and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.poll()
		
		# Process any remaining packets
		while ws.get_available_packet_count() > 0:
			var packet = ws.get_packet()
			_handle_websocket_message(context_id, packet)
		
		# Timeout check
		if (Time.get_ticks_msec() - drain_start) / 1000.0 > max_drain_time:
			print("[ElevenLabs] ⏱️ Drain timeout for '%s' after 2s" % context_id)
			break
		
		await Engine.get_main_loop().process_frame
	
	print("[ElevenLabs] ✅ Drain complete for '%s'" % context_id)
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

## Configure text batching behavior
## @param enabled: Enable/disable automatic text batching
## @param min_chars: Minimum characters before considering flush (default: 20)
## @param max_chars: Maximum characters before forced flush (default: 50)
## @param timeout_ms: Max time to wait before flushing (default: 500ms)
func set_text_batching(enabled: bool, min_chars: int = 20, max_chars: int = 50, timeout_ms: int = 500) -> void:
	enable_text_batching = enabled
	text_batch_min_chars = min_chars
	text_batch_max_chars = max_chars
	text_batch_timeout_ms = timeout_ms
	var status = "enabled" if enabled else "disabled"
	print("ElevenLabs: Text batching %s (min:%d, max:%d, timeout:%dms)" % [status, min_chars, max_chars, timeout_ms])

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
func _process(delta):
	# Poll all active WebSocket connections
	for context_id in character_contexts:
		var context = character_contexts[context_id]
		if context["websocket"]:
			_poll_websocket(context_id)
			
			# Rubberband keepalive: Adaptive interval that increases with each keepalive
			if context["connection_state"] == "connected":
				var time_since_activity = (Time.get_ticks_msec() - context["last_activity"]) / 1000.0
				
				# Only start keepalive after initial interval has passed
				if time_since_activity >= KEEPALIVE_INITIAL_INTERVAL:
					context["time_since_last_keepalive"] += delta
					
					# Time to send keepalive?
					if context["time_since_last_keepalive"] >= context["next_keepalive_interval"]:
						# Check if we've hit the max interval (give up point)
						if context["next_keepalive_interval"] < KEEPALIVE_MAX_INTERVAL:
							_send_keepalive(context_id)
							
							# Rubberband: Increase interval for next keepalive
							context["next_keepalive_interval"] = min(
								context["next_keepalive_interval"] * KEEPALIVE_MULTIPLIER,
								KEEPALIVE_MAX_INTERVAL
							)
							context["time_since_last_keepalive"] = 0.0
						# else: Max interval reached, stop sending keepalives (let it timeout)

## Internal method to connect to WebSocket for a voice
func _connect_to_voice(context_id: String, voice_id: String) -> void:
	print("[ElevenLabs] >>> _connect_to_voice('%s', '%s')" % [context_id, voice_id])
	var context = character_contexts[context_id]
	
	# Create WebSocket connection for this context
	var ws = WebSocketPeer.new()
	context["websocket"] = ws
	context["connection_state"] = "connecting"
	print("[ElevenLabs] 🔌 WebSocket peer created, state: connecting")
	
	# Build WebSocket URL with voice, model, and output format (NO API key in URL)
	var url = websocket_url.replace("{voice_id}", voice_id).replace("{model_id}", model_id)
	var output_format = _get_output_format()
	url += "&output_format=" + output_format
	
	var format_str = "MP3" if streaming_mode == StreamingMode.BUFFERED else "PCM"
	print("[ElevenLabs] 🌐 Connecting to: %s" % url)
	print("[ElevenLabs] 🎵 Output format: %s (%s mode)" % [output_format, format_str])
	
	# Connect to WebSocket
	var error = ws.connect_to_url(url)
	if error != OK:
		print("[ElevenLabs] ❌ Failed to connect WebSocket for '%s': %s" % [context_id, error])
		context["connection_state"] = "error"
		synthesis_error.emit(context_id, {"error": "Failed to connect WebSocket", "code": error})
		return
	
	print("[ElevenLabs] ⏳ Waiting for WebSocket connection...")
	
	# Wait for connection
	var timeout = 10.0
	var elapsed = 0.0
	while elapsed < timeout:
		ws.poll()
		var state = ws.get_ready_state()
		
		if state == WebSocketPeer.STATE_OPEN:
			context["connection_state"] = "connected"
			print("[ElevenLabs] ✅ WebSocket connected for '%s'!" % context_id)
			
			# Send initial configuration
			print("[ElevenLabs] 📤 Sending initial handshake...")
			_send_initial_config(context_id)
			return
		elif state == WebSocketPeer.STATE_CLOSED:
			print("[ElevenLabs] ❌ WebSocket closed unexpectedly while connecting '%s'" % context_id)
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
	
	# For REAL_TIME mode: use minimal chunk schedule for low latency (Python SDK uses [50])
	if streaming_mode == StreamingMode.REAL_TIME:
		config_message["generation_config"] = {
			"chunk_length_schedule": [50]  # Much smaller than default [120,160,250,290]
		}
	
	var json_string = JSON.stringify(config_message)
	print("ElevenLabs: Sending initial handshake: ", json_string)
	ws.send_text(json_string)
	print("ElevenLabs: Sent initial handshake for context ", context_id)

## Send text to specific character context
## Python SDK NEVER uses flush:true - only try_trigger_generation:true
func _send_text_to_context(context_id: String, text: String, force_flush: bool = false) -> void:
	print("[ElevenLabs] >>> _send_text_to_context('%s', '%s')\" % [context_id, text.substr(0, 30) + (\"...\" if text.length() > 30 else \"\")])")
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	if not ws or context["connection_state"] != "connected":
		print("[ElevenLabs] ❌ Context '%s' not connected! (state: %s)" % [context_id, context["connection_state"]])
		push_error("Context not connected: " + context_id)
		return
	
	# Build text message - Python SDK ALWAYS uses try_trigger_generation
	var text_message = {
		"text": text,
		"try_trigger_generation": true  # Always true, as per Python SDK
	}
	
	var json_string = JSON.stringify(text_message)
	print("[ElevenLabs] 📤 Sending text message to '%s': %s" % [context_id, json_string])
	ws.send_text(json_string)
	
	# Mark as speaking and RESET rubberband keepalive (activity detected!)
	context["is_speaking"] = true
	context["last_activity"] = Time.get_ticks_msec()
	
	# Rubberband reset: New text = reset to initial interval
	print("[ElevenLabs] 🔄 Rubberband reset for '%s' (new text activity)" % context_id)
	context["next_keepalive_interval"] = KEEPALIVE_INITIAL_INTERVAL
	context["time_since_last_keepalive"] = 0.0
	
	synthesis_started.emit(context_id)
	
	# Python SDK: Opportunistic receive after sending (non-blocking)
	# Try to get early audio chunks immediately to reduce latency
	ws.poll()
	if ws.get_available_packet_count() > 0:
		var packet = ws.get_packet()
		_handle_websocket_message(context_id, packet)
		print("[ElevenLabs] 🎯 Opportunistic receive: got early audio chunk!")
	
	print("ElevenLabs: Sent text to context ", context_id, ": '", text, "'")

## Send end-of-input signal to character context
func _send_end_of_input(context_id: String) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	if not ws or context["connection_state"] != "connected":
		return
	
	var end_message = {
		"text": ""
	}
	
	var json_string = JSON.stringify(end_message)
	ws.send_text(json_string)
	
	print("ElevenLabs: Sent end-of-input for context ", context_id)

## Send keepalive message to prevent inactivity timeout
## Sends a space character " " (NOT empty string which would close the connection)
func _send_keepalive(context_id: String) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	if not ws or context["connection_state"] != "connected":
		return
	
	# Send a space character to keep connection alive
	# DO NOT send "" (empty string) - that closes the connection!
	var keepalive_message = {
		"text": " "
	}
	
	var json_string = JSON.stringify(keepalive_message)
	ws.send_text(json_string)
	
	# Note: We DON'T update last_activity here (only actual text resets rubberband)
	# The rubberband interval is managed in _process()
	
	# Only log keepalive in verbose mode (comment out for cleaner logs)
	# print("ElevenLabs: Sent keepalive for context ", context_id, " (interval: ", context["next_keepalive_interval"], "s)")

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
		
		WebSocketPeer.STATE_CLOSED:
			if context["connection_state"] == "connected":
				# Connection closed (expected after finish_character_speech)
				print("ElevenLabs: ✓ Context ", context_id, " closed")
				context["connection_state"] = "disconnected"

## Handle WebSocket message from ElevenLabs
func _handle_websocket_message(context_id: String, packet: PackedByteArray) -> void:
	var context = character_contexts[context_id]
	
	# Check if this is JSON (text) or binary (audio) data
	var packet_string = packet.get_string_from_utf8()
	
	print("[ElevenLabs] 🔍 RAW MESSAGE for '%s': size=%d bytes, starts_with_brace=%s" % [
		context_id, 
		packet.size(), 
		packet_string.begins_with("{")
	])
	
	if packet_string.begins_with("{"):
		# JSON message
		print("[ElevenLabs] 📨 Received JSON for context '%s' (%d bytes)" % [context_id, packet.size()])
		print("[ElevenLabs] 📄 JSON CONTENT: %s" % packet_string.substr(0, 500))  # First 500 chars
		
		var json = JSON.new()
		var parse_result = json.parse(packet_string)
		
		if parse_result == OK:
			var message = json.data
			var keys = message.keys() if message is Dictionary else []
			print("[ElevenLabs] 📋 JSON keys: %s" % str(keys))
			
			# Log key fields
			if message.has("isFinal"):
				print("[ElevenLabs] 🏁 isFinal: %s" % str(message["isFinal"]))
			if message.has("audio"):
				var audio_val = message["audio"]
				if audio_val == null:
					print("[ElevenLabs] 🔇 audio: NULL")
				elif audio_val == "":
					print("[ElevenLabs] 🔇 audio: EMPTY STRING")
				else:
					print("[ElevenLabs] 🎵 audio: base64 string (%d chars)" % str(audio_val).length())
			
			_handle_json_message(context_id, message)
		else:
			print("[ElevenLabs] ❌ Failed to parse JSON message for context '%s'" % context_id)
	else:
		# Binary audio data
		print("[ElevenLabs] 🔊 Received BINARY audio for context '%s' (%d bytes)" % [context_id, packet.size()])
		_handle_audio_data(context_id, packet)

## Handle JSON message from WebSocket
func _handle_json_message(context_id: String, message: Dictionary) -> void:
	print("[ElevenLabs] 🔧 _handle_json_message called for '%s'" % context_id)
	
	# Check for authentication success
	if message.has("message") and message["message"] == "Authentication successful":
		print("[ElevenLabs] ✅ Authentication successful for '%s'" % context_id)
		return
	
	if message.has("audio") and message["audio"] != null and message["audio"] != "":
		print("[ElevenLabs] 🎵 Audio field present and non-empty")
		# Audio data in base64 (MP3) or raw bytes (PCM)
		var audio_base64 = message["audio"]
		if typeof(audio_base64) == TYPE_STRING and audio_base64.length() > 0:
			print("[ElevenLabs] 🔓 Decoding base64 audio (%d chars)..." % audio_base64.length())
			# Decode base64 to raw bytes
			var audio_bytes = Marshalls.base64_to_raw(audio_base64)
			var format = "MP3" if streaming_mode == StreamingMode.BUFFERED else "PCM"
			print("[ElevenLabs] 🎵 Audio chunk received for '%s': %d bytes (%s)" % [context_id, audio_bytes.size(), format])
			print("[ElevenLabs] 📤 Calling _handle_audio_data...")
			_handle_audio_data(context_id, audio_bytes)
		else:
			print("[ElevenLabs] ⚠️ Audio field is not a valid string or is empty")
	else:
		print("[ElevenLabs] 🔇 No audio in this message (audio=%s)" % str(message.get("audio", "NOT_PRESENT")))
	
	if message.has("isFinal") and message["isFinal"]:
		# Speech generation completed
		print("[ElevenLabs] 🏁 isFinal received for '%s' - synthesis complete!" % context_id)
		var context = character_contexts[context_id]
		context["is_speaking"] = false
		
		# If BUFFERED mode, emit ready-to-play AudioStream
		if streaming_mode == StreamingMode.BUFFERED and collected_audio_chunks.has(context_id):
			var chunks = collected_audio_chunks[context_id]
			print("[ElevenLabs] 📦 Processing %d buffered chunks for '%s'..." % [chunks.size(), context_id])
			if chunks.size() > 0:
				# Combine all MP3 chunks into one buffer
				var combined = PackedByteArray()
				for chunk in chunks:
					combined.append_array(chunk)
				
				print("[ElevenLabs] 🔗 Combined %d chunks into %d bytes (MP3)" % [chunks.size(), combined.size()])
				
				# Create AudioStreamMP3 from combined data
				var audio_stream = AudioStreamMP3.new()
				audio_stream.data = combined
				
				# Emit high-level signal with ready-to-play stream
				print("[ElevenLabs] ✅ Emitting audio_stream_ready for '%s'" % context_id)
				audio_stream_ready.emit(audio_stream, context_id)
			
			# Clear collected chunks
			collected_audio_chunks.erase(context_id)
		
		print("[ElevenLabs] ✅ Emitting synthesis_completed for '%s'" % context_id)
		synthesis_completed.emit(context_id)
	
	if message.has("error"):
		# Error message
		print("[ElevenLabs] ❌ ERROR for context '%s': %s" % [context_id, str(message["error"])])
		synthesis_error.emit(context_id, message)
	
	# Log unknown messages for debugging
	if not message.has("audio") and not message.has("isFinal") and not message.has("error") and not (message.has("message") and message["message"] == "Authentication successful"):
		print("ElevenLabs: ⚠️ Unknown message for context ", context_id, ": ", message)

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
	var prebuffer_threshold: int = 1  # Start playback immediately when first chunk arrives (handles both single and multi-chunk responses)
	var is_prebuffered: bool = false  # Track if we've started playing
	var synthesis_complete: bool = false  # Track if synthesis is done (to handle 1-chunk cases)
	
	func _init(ctx_id: String, parent: Node, wrapper):
		context_id = ctx_id
		wrapper_ref = wrapper
		name = "RealtimePCMPlayer_" + context_id
		
		# Create AudioStreamPlayer with generator
		audio_player = AudioStreamPlayer.new()
		audio_player.name = "Player_" + context_id
		var generator = AudioStreamGenerator.new()
		generator.mix_rate = PCM_SAMPLE_RATE
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
		print("[RealtimePCMPlayer] 🏁 Synthesis complete signal received for '%s' (my context: '%s')" % [ctx_id, context_id])
		
		if ctx_id != context_id:
			print("[RealtimePCMPlayer] ❌ Context mismatch - ignoring")
			return
		
		synthesis_complete = true
		print("[RealtimePCMPlayer] 📊 State: is_prebuffered=%s, queue_size=%d" % [is_prebuffered, audio_queue.size()])
		
		# If synthesis is done and we have chunks but haven't started playing, start now!
		if not is_prebuffered and not audio_queue.is_empty():
			print("[RealtimePCMPlayer] 🎬 Synthesis complete with %d chunk(s) - starting playback immediately!" % audio_queue.size())
			is_prebuffered = true
		elif is_prebuffered:
			print("[RealtimePCMPlayer] ✅ Already playing, continuing...")
		else:
			print("[RealtimePCMPlayer] ⚠️ No chunks to play!")
	
	func _on_audio_chunk(audio: PackedByteArray, ctx_id: String):
		if ctx_id != context_id:
			return
		
		print("[RealtimePCMPlayer] 📥 Chunk received for '%s' (%d bytes), queue size: %d -> %d" % [context_id, audio.size(), audio_queue.size(), audio_queue.size() + 1])
		
		# Always queue chunks (for prebuffering strategy)
		audio_queue.append(audio)
		
		# Check if this is the LAST chunk (isFinal already received)
		# This happens when synthesis completes quickly with only 1-2 chunks
		if not is_prebuffered and synthesis_complete:
			print("[RealtimePCMPlayer] 🎬 Last chunk received (synthesis already complete) - starting playback immediately!")
			is_prebuffered = true
			return
		
		# Start playback once we have enough chunks prebuffered
		if not is_prebuffered and audio_queue.size() >= prebuffer_threshold:
			print("[RealtimePCMPlayer] 🎬 Prebuffer threshold reached (%d chunks) - starting playback!" % prebuffer_threshold)
			is_prebuffered = true
		elif not is_prebuffered:
			print("[RealtimePCMPlayer] ⏳ Waiting for more chunks... (%d/%d)" % [audio_queue.size(), prebuffer_threshold])
	
	func _process_queue():
		# Don't process until we've reached prebuffer threshold
		if not is_prebuffered:
			if not audio_queue.is_empty():
				print("[RealtimePCMPlayer] ⏸️ Queue has %d chunks but not prebuffered yet" % audio_queue.size())
			return
		
		if audio_queue.is_empty():
			return
		
		var chunks_processed = 0
		while not audio_queue.is_empty():
			var next_chunk = audio_queue[0]
			var frames_needed = int(next_chunk.size() / 2.0)
			var frames_available = playback.get_frames_available()
			
			if frames_available >= frames_needed:
				var chunk = audio_queue.pop_front()
				ElevenLabsWrapper.convert_pcm_to_frames(playback, chunk)
				chunks_processed += 1
			else:
				# Only log if queue is stuck (not just waiting for buffer space)
				if chunks_processed == 0 and audio_queue.size() > 5:
					print("[RealtimePCMPlayer] ⚠️ Buffer full: need %d, have %d (queue: %d)" % [frames_needed, frames_available, audio_queue.size()])
				break
		
		if chunks_processed > 0:
			print("[RealtimePCMPlayer] ✅ Processed %d chunk(s), %d remaining" % [chunks_processed, audio_queue.size()])
	
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
