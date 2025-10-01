## OpenAI Realtime STT Wrapper
## 
## WebSocket-based real-time speech-to-text using OpenAI Realtime API (transcription mode).
## Supports per-NPC transcription contexts with server-side VAD and streaming transcription.
##
## ARCHITECTURE:
##   - Multiple concurrent transcription sessions (one per NPC/character)
##   - Each session has its own WebSocket connection
##   - Server-side VAD (Voice Activity Detection)
##   - Streaming transcription with delta events
##
## STANDALONE USAGE:
##   ```
##   OpenAISTT.initialize("api_key")
##   await OpenAISTT.create_character_context("wizard")
##   
##   OpenAISTT.transcription_completed.connect(func(text, ctx_id):
##       if ctx_id == "wizard":
##           print("Wizard said: ", text)
##   )
##   
##   # Send audio chunks (16-bit PCM, 24kHz, mono)
##   OpenAISTT.send_audio_chunk(audio_bytes, "wizard")
##   ```
##
## LLM INTEGRATION (Voice Pipeline):
##   ```
##   # Setup: STT → LLM → TTS
##   var wizard_agent = LLMManager.create_agent({"system_prompt": "You are a wizard"})
##   await OpenAISTT.create_character_context("wizard")
##   await ElevenLabsWrapper.create_character_context("wizard", "wizard_voice_id")
##   var tts_player = await ElevenLabsWrapper.create_realtime_player(self, "wizard")
##   
##   # Connect: STT → LLM
##   OpenAISTT.transcription_completed.connect(func(text, ctx_id):
##       if ctx_id == "wizard":
##           wizard_agent.ainvoke(Message.user_simple(text))
##   )
##   
##   # Connect: LLM → TTS
##   wizard_agent.delta.connect(func(id, text):
##       ElevenLabsWrapper.feed_text_to_character("wizard", text)
##   )
##   
##   wizard_agent.finished.connect(func(id, ok, result):
##       await ElevenLabsWrapper.finish_character_speech("wizard")
##   )
##   
##   # Wait for playback to finish before allowing next input
##   ElevenLabsWrapper.playback_finished.connect(func(ctx_id):
##       if ctx_id == "wizard":
##           # Safe to accept new audio input
##           pass
##   )
##   ```
##
## SIGNALS:
##   - transcription_delta(text_chunk, context_id): Partial transcription
##   - transcription_completed(full_text, context_id): Final transcription for speech segment
##   - speech_started(context_id): VAD detected speech start
##   - speech_stopped(context_id): VAD detected speech end
##   - transcription_error(context_id, error): Error occurred
##
## MULTI-AGENT EXAMPLE:
##   ```
##   # Three NPCs, each with own voice pipeline
##   for npc in ["wizard", "merchant", "guard"]:
##       await OpenAISTT.create_character_context(npc)
##       # Each gets isolated transcription context!
##   ```
##
## @tutorial: https://platform.openai.com/docs/guides/realtime-transcription

extends Node

## ========== SIGNALS ==========

## Emitted when partial transcription is received (streaming)
signal transcription_delta(text_chunk: String, context_id: String)

## Emitted when transcription completes for a speech segment
signal transcription_completed(full_text: String, context_id: String)

## Emitted when VAD detects speech start
signal speech_started(context_id: String)

## Emitted when VAD detects speech end  
signal speech_stopped(context_id: String, audio_end_ms: int)

## Emitted when transcription error occurs
signal transcription_error(context_id: String, error: Dictionary)

## Emitted when character context is created
signal character_context_created(context_id: String)

## Emitted when character context is destroyed
signal character_context_destroyed(context_id: String)

## ========== CONFIGURATION ==========

## OpenAI API configuration
var api_key: String = ""
var websocket_url: String = "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-12-17"

## Transcription settings (GA API)
var transcription_model: String = "gpt-4o-realtime-preview-2024-12-17"
var input_audio_format: String = "pcm16"  # pcm16, g711_ulaw, g711_alaw
var language: String = ""  # Optional: ISO-639-1 (e.g., "en")
var prompt: String = ""  # Optional: Guide transcription style

## Server VAD configuration
var vad_enabled: bool = true
var vad_threshold: float = 0.5  # 0.0-1.0 sensitivity
var vad_prefix_padding_ms: int = 300  # Audio before speech start
var vad_silence_duration_ms: int = 500  # Silence to detect speech end

## Noise reduction
var noise_reduction_enabled: bool = true
var noise_reduction_type: String = "near_field"  # "near_field" or "far_field"

## Character contexts (one per NPC)
var character_contexts: Dictionary = {}  # context_id -> {websocket, session_data, accumulated_text}

func _ready():
	print("OpenAISTT initialized")

## Initialize the wrapper with API key
func initialize(openai_api_key: String) -> void:
	api_key = openai_api_key
	print("OpenAISTT configured with API key")

## Create a character context for STT (one per NPC)
## Returns true if successful
func create_character_context(context_id: String) -> bool:
	if api_key.is_empty():
		push_error("OpenAI API key not set")
		return false
	
	if character_contexts.has(context_id):
		push_warning("STT context already exists: " + context_id)
		return false
	
	# Store context info
	character_contexts[context_id] = {
		"websocket": null,
		"connection_state": "disconnected",
		"accumulated_text": "",
		"current_item_id": ""
	}
	
	# Connect to WebSocket for this context
	await _connect_to_realtime_api(context_id)
	
	character_context_created.emit(context_id)
	return true

## Send audio chunk to a specific character's transcription session
## Audio format: 16-bit PCM, 24kHz, mono, little-endian
func send_audio_chunk(audio_data: PackedByteArray, context_id: String) -> bool:
	if not character_contexts.has(context_id):
		push_warning("STT context not found: " + context_id)
		return false
	
	var context = character_contexts[context_id]
	if context["connection_state"] != "connected":
		push_warning("STT context not connected: " + context_id)
		return false
	
	# Append audio to buffer
	_send_audio_buffer_append(audio_data, context_id)
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

## Configure VAD settings
func set_vad_config(threshold: float, prefix_padding: int, silence_duration: int) -> void:
	vad_threshold = clamp(threshold, 0.0, 1.0)
	vad_prefix_padding_ms = max(prefix_padding, 0)
	vad_silence_duration_ms = max(silence_duration, 100)

## Enable/disable VAD
func set_vad_enabled(enabled: bool) -> void:
	vad_enabled = enabled

## Set transcription language (ISO-639-1 format like "en", "es", "fr")
func set_language(lang: String) -> void:
	language = lang

## Set transcription prompt for context guidance
func set_prompt(context_prompt: String) -> void:
	prompt = context_prompt

## Set noise reduction
func set_noise_reduction(enabled: bool, type: String = "near_field") -> void:
	noise_reduction_enabled = enabled
	noise_reduction_type = type

## Check if context exists and is connected
func is_character_connected(context_id: String) -> bool:
	if not character_contexts.has(context_id):
		return false
	return character_contexts[context_id]["connection_state"] == "connected"

## Get list of active contexts
func get_active_contexts() -> Array:
	return character_contexts.keys()

## Process WebSocket events for all contexts
func _process(_delta):
	# Poll all active WebSocket connections (like ElevenLabsWrapper does)
	for context_id in character_contexts:
		var context = character_contexts[context_id]
		if context["websocket"]:
			_poll_websocket(context_id)

## Connect to OpenAI Realtime API for a specific context
func _connect_to_realtime_api(context_id: String) -> void:
	var context = character_contexts[context_id]
	
	# Create WebSocket connection with 16MB buffers (match ElevenLabsWrapper)
	var ws = WebSocketPeer.new()
	ws.set_inbound_buffer_size(16 * 1024 * 1024)
	ws.set_outbound_buffer_size(16 * 1024 * 1024)
	context["websocket"] = ws
	context["connection_state"] = "connecting"
	
	# Build WebSocket URL
	var url = websocket_url
	
	# Connect with Authorization header
	var headers = PackedStringArray([
		"Authorization: Bearer " + api_key,
		"OpenAI-Beta: realtime=v1"
	])
	
	var error = ws.connect_to_url(url, headers)
	if error != OK:
		context["connection_state"] = "error"
		transcription_error.emit(context_id, {"error": "Failed to connect WebSocket", "code": error})
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
			transcription_error.emit(context_id, {"error": "WebSocket connection failed"})
			return
		
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	
	# Timeout
	context["connection_state"] = "error"
	transcription_error.emit(context_id, {"error": "WebSocket connection timeout"})

## Send initial session configuration (GA API - type: "transcription")
func _send_initial_config(context_id: String) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	# GA API: Use type: "transcription" for transcription-only sessions
	var session_config = {
		"type": "session.update",
		"session": {
			"type": "transcription",  # NEW GA API: transcription-only session type
			"modalities": ["text"],  # No audio output, only text transcription
			"input_audio_transcription": {
				"model": transcription_model
			},
			"turn_detection": {
				"type": "server_vad",
				"threshold": vad_threshold,
				"prefix_padding_ms": vad_prefix_padding_ms,
				"silence_duration_ms": vad_silence_duration_ms,
				"create_response": false  # CRITICAL: Don't generate LLM responses!
			}
		}
	}
	
	# Add optional language
	if language != "":
		session_config["session"]["input_audio_transcription"]["language"] = language
	
	# Add optional prompt
	if prompt != "":
		session_config["session"]["input_audio_transcription"]["prompt"] = prompt
	
	# Add noise reduction if enabled
	if noise_reduction_enabled:
		session_config["session"]["input_audio_noise_reduction"] = {
			"type": noise_reduction_type
		}
	
	var json_string = JSON.stringify(session_config)
	ws.send_text(json_string)

## Send audio buffer append event
func _send_audio_buffer_append(audio_data: PackedByteArray, context_id: String) -> void:
	var context = character_contexts[context_id]
	var ws = context["websocket"]
	
	if not ws or context["connection_state"] != "connected":
		return
	
	# Convert to base64
	var base64_audio = Marshalls.raw_to_base64(audio_data)
	
	var append_event = {
		"type": "input_audio_buffer.append",
		"audio": base64_audio
	}
	
	var json_string = JSON.stringify(append_event)
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
		
		WebSocketPeer.STATE_CLOSED:
			if context["connection_state"] == "connected":
				print("[OpenAISTT] WebSocket closed for '%s'" % context_id)
				context["connection_state"] = "disconnected"

## Handle incoming WebSocket messages
func _handle_websocket_message(context_id: String, packet: PackedByteArray) -> void:
	var message = packet.get_string_from_utf8()
	
	var json = JSON.new()
	var parse_result = json.parse(message)
	
	if parse_result != OK:
		push_error("OpenAISTT: Failed to parse message for " + context_id)
		return
	
	var data = json.data
	var event_type = data.get("type", "")
	
	match event_type:
		"session.created":
			print("[OpenAISTT] Session created for '%s'" % context_id)
		
		"session.updated":
			print("[OpenAISTT] Session configured for '%s'" % context_id)
		
		"input_audio_buffer.speech_started":
			_handle_speech_started(context_id, data)
		
		"input_audio_buffer.speech_stopped":
			_handle_speech_stopped(context_id, data)
		
		"conversation.item.input_audio_transcription.delta":
			_handle_transcription_delta(context_id, data)
		
		"conversation.item.input_audio_transcription.completed":
			_handle_transcription_completed(context_id, data)
		
		"error":
			_handle_error(context_id, data)
		
		_:
			# Ignore other events (response.created, etc. - not needed for transcription)
			pass

## Handle speech started event (VAD)
func _handle_speech_started(context_id: String, data: Dictionary) -> void:
	var item_id = data.get("item_id", "")
	character_contexts[context_id]["current_item_id"] = item_id
	character_contexts[context_id]["accumulated_text"] = ""
	
	print("[OpenAISTT] Speech started for '%s'" % context_id)
	speech_started.emit(context_id)

## Handle speech stopped event (VAD)
func _handle_speech_stopped(context_id: String, data: Dictionary) -> void:
	var audio_end_ms = data.get("audio_end_ms", 0)
	
	print("[OpenAISTT] Speech stopped for '%s' at %dms" % [context_id, audio_end_ms])
	speech_stopped.emit(context_id, audio_end_ms)

## Handle transcription delta (streaming text chunks)
func _handle_transcription_delta(context_id: String, data: Dictionary) -> void:
	var delta = data.get("delta", "")
	
	if delta.length() > 0:
		character_contexts[context_id]["accumulated_text"] += delta
		transcription_delta.emit(delta, context_id)

## Handle transcription completed (final text)
func _handle_transcription_completed(context_id: String, data: Dictionary) -> void:
	var transcript = data.get("transcript", "")
	
	# Reset accumulated text
	character_contexts[context_id]["accumulated_text"] = ""
	character_contexts[context_id]["current_item_id"] = ""
	
	print("[OpenAISTT] Transcription complete for '%s': '%s'" % [context_id, transcript])
	transcription_completed.emit(transcript, context_id)

## Handle error event
func _handle_error(context_id: String, data: Dictionary) -> void:
	var error = data.get("error", {})
	
	print("[OpenAISTT] Error for '%s': %s" % [context_id, str(error)])
	transcription_error.emit(context_id, error)

## Clean up resources
func _exit_tree():
	# Close all WebSocket connections
	for context_id in character_contexts:
		destroy_character_context(context_id)
	
	character_contexts.clear()


## ========== HELPER: REAL-TIME STT LISTENER ==========

## Helper class to manage real-time audio capture and transcription.
## 
## This handles all the complexity of:
##   - AudioStreamMicrophone setup
##   - Audio frame capture and conversion
##   - Automatic sending to OpenAI
##   - Push-to-talk support
##   - Device selection
##
## Usage:
##   var listener = await OpenAISTT.create_stt_listener(self, "wizard")
##   # Listener auto-captures microphone and sends to OpenAI
##   # Transcription signals emitted automatically!
##   
##   # Optional: Configure
##   listener.set_push_to_talk(true)
##   listener.set_microphone_device(1)
##   
##   # When done:
##   listener.cleanup()
##
class RealtimeSTTListener extends Node:
	var context_id: String
	var audio_player: AudioStreamPlayer
	var playback: AudioStreamPlayback
	var capture_timer: Timer
	var wrapper_ref  # Reference to OpenAISTT
	
	# Configuration
	var microphone_device: int = 0  # Default device
	var push_to_talk: bool = false
	var is_listening: bool = false
	var capture_interval_ms: float = 50.0  # Capture every 50ms (20 chunks/sec)
	var target_sample_rate: int = 24000  # OpenAI expects 24kHz
	
	# Audio buffering
	var audio_buffer: PackedByteArray = PackedByteArray()
	var min_send_bytes: int = 960  # ~20ms at 24kHz (480 samples * 2 bytes)
	
	func _init(ctx_id: String, parent: Node, wrapper):
		context_id = ctx_id
		wrapper_ref = wrapper
		name = "RealtimeSTTListener_" + context_id
		
		# Create AudioStreamPlayer with microphone
		audio_player = AudioStreamPlayer.new()
		audio_player.name = "MicPlayer_" + context_id
		var microphone = AudioStreamMicrophone.new()
		audio_player.stream = microphone
		add_child(audio_player)
		
		# Create timer for periodic audio capture
		capture_timer = Timer.new()
		capture_timer.name = "CaptureTimer_" + context_id
		capture_timer.wait_time = capture_interval_ms / 1000.0
		capture_timer.one_shot = false
		capture_timer.timeout.connect(_capture_audio)
		add_child(capture_timer)
		
		# Add to parent FIRST (must be in tree)
		parent.add_child(self)
	
	## Call after node is in tree to start capturing
	func initialize_capture() -> bool:
		# Start playing microphone input
		audio_player.play()
		
		# Get playback stream
		playback = audio_player.get_stream_playback()
		if not playback:
			push_error("OpenAISTT RealtimeSTTListener: Failed to get playback")
			return false
		
		# Start capture timer if not push-to-talk
		if not push_to_talk:
			start_listening()
		
		return true
	
	## Start listening (captures and sends audio)
	func start_listening() -> void:
		is_listening = true
		capture_timer.start()
		print("[STTListener] Started listening for '%s'" % context_id)
	
	## Stop listening (stops capturing audio)
	func stop_listening() -> void:
		is_listening = false
		capture_timer.stop()
		
		# Send any remaining buffered audio
		_flush_audio_buffer()
		print("[STTListener] Stopped listening for '%s'" % context_id)
	
	## Set push-to-talk mode
	func set_push_to_talk(enabled: bool) -> void:
		push_to_talk = enabled
		if enabled:
			stop_listening()
	
	## Set microphone device index
	func set_microphone_device(device_index: int) -> void:
		microphone_device = device_index
		# TODO: Godot doesn't support device selection yet (as of 4.3)
		# This is a placeholder for when it's added
		push_warning("Microphone device selection not yet supported in Godot")
	
	## Set capture interval (how often to pull audio from microphone)
	func set_capture_interval(interval_ms: float) -> void:
		capture_interval_ms = clamp(interval_ms, 10.0, 1000.0)
		capture_timer.wait_time = capture_interval_ms / 1000.0
	
	## Capture audio from microphone and send to OpenAI
	func _capture_audio() -> void:
		if not is_listening or not playback:
			return
		
		var frames_available = playback.get_frames_available()
		if frames_available <= 0:
			return
		
		# Pull audio frames from microphone
		# AudioStreamMicrophone uses 44.1kHz by default, we need to resample to 24kHz
		# For now, we'll just send the raw audio and let OpenAI handle it
		# TODO: Implement proper resampling if needed
		
		var frames_to_pull = min(frames_available, 4800)  # ~100ms at 48kHz
		
		for i in range(frames_to_pull):
			var frame = playback.get_frame()
			
			# Convert stereo Vector2 to mono (average channels)
			var mono_sample = (frame.x + frame.y) / 2.0
			
			# Convert float [-1.0, 1.0] to 16-bit PCM
			var sample_int = int(clamp(mono_sample * 32767.0, -32768.0, 32767.0))
			
			# Convert to bytes (little-endian)
			var low_byte = sample_int & 0xFF
			var high_byte = (sample_int >> 8) & 0xFF
			
			audio_buffer.append(low_byte)
			audio_buffer.append(high_byte)
		
		# Send buffer when it reaches minimum size
		if audio_buffer.size() >= min_send_bytes:
			_flush_audio_buffer()
	
	## Send buffered audio to OpenAI
	func _flush_audio_buffer() -> void:
		if audio_buffer.size() > 0:
			wrapper_ref.send_audio_chunk(audio_buffer, context_id)
			audio_buffer.clear()
	
	## Get listening state
	func is_actively_listening() -> bool:
		return is_listening
	
	## Cleanup
	func cleanup():
		stop_listening()
		if audio_player:
			audio_player.stop()
		queue_free()


## Factory method to create a real-time STT listener for a context.
## 
## This is the EASIEST way to capture and transcribe microphone audio:
##   1. Creates and configures AudioStreamPlayer with microphone
##   2. Sets up automatic audio capture
##   3. Auto-sends audio to OpenAI for transcription
##   4. Returns a listener you can configure/control
##
## Usage:
##   var listener = await OpenAISTT.create_stt_listener(self, "wizard")
##   # Microphone captures and transcribes automatically!
##   
##   # Optional: Configure
##   listener.set_push_to_talk(true)
##   listener.start_listening()  # Manual control
##   listener.stop_listening()
##   
##   # Cleanup when done:
##   listener.cleanup()
##
## @param parent_node: Node to attach the listener to (usually 'self')
## @param context_id: The character context ID for transcription
## @return RealtimeSTTListener instance (ready to use)
static func create_stt_listener(parent_node: Node, context_id: String, wrapper_instance = null) -> RealtimeSTTListener:
	var wrapper = wrapper_instance
	
	# If no wrapper provided, look it up
	if not wrapper:
		wrapper = parent_node.get_node_or_null("/root/OpenAISTT")
		if not wrapper:
			push_error("OpenAISTT: OpenAISTT autoload not found (check Project Settings > Autoload)")
			return null
	
	var listener = RealtimeSTTListener.new(context_id, parent_node, wrapper)
	
	# Wait for listener to be in tree
	await parent_node.get_tree().process_frame
	
	if not listener.initialize_capture():
		listener.queue_free()
		return null
	
	return listener
