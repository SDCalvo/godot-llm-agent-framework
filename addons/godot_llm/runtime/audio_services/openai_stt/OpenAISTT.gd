## OpenAI Realtime Speech-to-Text Service
##
## Provides streaming STT functionality using OpenAI Realtime API
## Supports real-time audio transcription with built-in VAD and delta text output
##
## @tutorial: https://platform.openai.com/docs/guides/realtime

extends Node

## Emitted when a text chunk is transcribed (streaming mode)
signal transcription_delta(text_chunk: String, session_id: String)

## Emitted when transcription session starts
signal transcription_started(session_id: String)

## Emitted when transcription completes for a speech segment
signal transcription_completed(full_text: String, session_id: String)

## Emitted when transcription encounters an error
signal transcription_error(session_id: String, error: Dictionary)

## Emitted when speech starts (VAD)
signal speech_started(session_id: String)

## Emitted when speech stops (VAD) 
signal speech_stopped(session_id: String, audio_end_ms: int)

## OpenAI API configuration
var api_key: String = ""
var api_base_url: String = "wss://api.openai.com/v1/realtime"

## Transcription session settings
var transcription_model: String = "gpt-4o-transcribe"  # or "whisper-1" or "gpt-4o-mini-transcribe"
var language: String = ""  # ISO-639-1 format (e.g., "en", "es")
var prompt: String = ""    # Guide transcription context
var input_audio_format: String = "pcm16"  # pcm16, g711_ulaw, g711_alaw

## VAD configuration
var vad_enabled: bool = true
var vad_threshold: float = 0.5
var vad_prefix_padding_ms: int = 300
var vad_silence_duration_ms: int = 500

## Noise reduction
var noise_reduction_type: String = "near_field"  # "near_field", "far_field", or null

## WebSocket connection
var websocket: WebSocketPeer
var active_sessions: Dictionary = {}
var connection_state: String = "disconnected"  # disconnected, connecting, connected, error

func _ready():
	websocket = WebSocketPeer.new()
	print("OpenAISTT initialized")

## Initialize the service with OpenAI API key
func initialize(openai_api_key: String) -> void:
	api_key = openai_api_key
	print("OpenAISTT initialized with API key")

## Start a new transcription session
## Returns a unique session_id for tracking this session
func start_transcription_session() -> String:
	if api_key.is_empty():
		push_error("OpenAI API key not set")
		return ""
	
	var session_id = "stt_" + str(Time.get_unix_time_from_system()) + "_" + str(randi())
	
	# Store session info
	active_sessions[session_id] = {
		"status": "starting",
		"accumulated_text": ""
	}
	
	# Connect if not already connected
	if connection_state == "disconnected":
		_connect_to_realtime_api()
	
	# Configure transcription session
	_setup_transcription_session(session_id)
	
	transcription_started.emit(session_id)
	return session_id

## Send audio chunk to active transcription session
func send_audio_chunk(audio_data: PackedByteArray, session_id: String) -> void:
	if not active_sessions.has(session_id):
		push_warning("Session ID not found: " + session_id)
		return
	
	if connection_state != "connected":
		push_warning("WebSocket not connected")
		return
	
	# Send audio data via WebSocket
	_send_audio_buffer_append(audio_data, session_id)

## Finish transcription session
func finish_transcription_session(session_id: String) -> void:
	if not active_sessions.has(session_id):
		return
	
	active_sessions[session_id]["status"] = "finishing"
	
	# Send commit event to finalize current audio buffer
	_send_audio_buffer_commit(session_id)

## Set transcription model
func set_transcription_model(model: String) -> void:
	transcription_model = model

## Set language for transcription (ISO-639-1 format)
func set_language(lang: String) -> void:
	language = lang

## Set transcription prompt for context
func set_prompt(context_prompt: String) -> void:
	prompt = context_prompt

## Configure VAD settings
func set_vad_config(threshold: float, prefix_padding: int, silence_duration: int) -> void:
	vad_threshold = clamp(threshold, 0.0, 1.0)
	vad_prefix_padding_ms = max(prefix_padding, 0)
	vad_silence_duration_ms = max(silence_duration, 100)

## Enable/disable VAD
func set_vad_enabled(enabled: bool) -> void:
	vad_enabled = enabled

## Set noise reduction type
func set_noise_reduction(type: String) -> void:
	if type in ["near_field", "far_field", ""]:
		noise_reduction_type = type if type != "" else null

## Connect to OpenAI Realtime API via WebSocket
func _connect_to_realtime_api() -> void:
	connection_state = "connecting"
	
	var headers = PackedStringArray([
		"Authorization: Bearer " + api_key,
		"OpenAI-Beta: realtime=v1"
	])
	
	var error = websocket.connect_to_url(api_base_url, headers)
	if error != OK:
		push_error("Failed to connect to OpenAI Realtime API: " + str(error))
		connection_state = "error"
		return

## Process WebSocket events
func _process(_delta):
	if websocket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if connection_state == "connecting":
			connection_state = "connected"
			print("Connected to OpenAI Realtime API")
		
		# Process incoming messages
		while websocket.get_available_packet_count() > 0:
			var packet = websocket.get_packet()
			var message = packet.get_string_from_utf8()
			_handle_websocket_message(message)
	
	elif websocket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if connection_state != "disconnected":
			connection_state = "disconnected"
			print("Disconnected from OpenAI Realtime API")

## Setup transcription session configuration
func _setup_transcription_session(session_id: String) -> void:
	var session_config = {
		"type": "session.update",
		"session": {
			"input_audio_format": input_audio_format,
			"input_audio_transcription": {
				"model": transcription_model,
				"prompt": prompt,
				"language": language
			},
			"turn_detection": null if not vad_enabled else {
				"type": "server_vad",
				"threshold": vad_threshold,
				"prefix_padding_ms": vad_prefix_padding_ms,
				"silence_duration_ms": vad_silence_duration_ms
			},
			"input_audio_noise_reduction": null if noise_reduction_type == null else {
				"type": noise_reduction_type
			}
		}
	}
	
	_send_websocket_message(session_config)

## Send audio buffer append event
func _send_audio_buffer_append(audio_data: PackedByteArray, session_id: String) -> void:
	# Convert audio data to base64
	var base64_audio = Marshalls.raw_to_base64(audio_data)
	
	var append_event = {
		"type": "input_audio_buffer.append",
		"audio": base64_audio
	}
	
	_send_websocket_message(append_event)

## Send audio buffer commit event
func _send_audio_buffer_commit(session_id: String) -> void:
	var commit_event = {
		"type": "input_audio_buffer.commit"
	}
	
	_send_websocket_message(commit_event)

## Send message via WebSocket
func _send_websocket_message(message: Dictionary) -> void:
	if connection_state != "connected":
		push_warning("Cannot send message - WebSocket not connected")
		return
	
	var json_string = JSON.stringify(message)
	websocket.send_text(json_string)

## Handle incoming WebSocket messages
func _handle_websocket_message(message: String) -> void:
	var json = JSON.new()
	var parse_result = json.parse(message)
	
	if parse_result != OK:
		push_error("Failed to parse WebSocket message: " + message)
		return
	
	var data = json.data
	var event_type = data.get("type", "")
	
	match event_type:
		"input_audio_buffer.speech_started":
			_handle_speech_started(data)
		"input_audio_buffer.speech_stopped":
			_handle_speech_stopped(data)
		"conversation.item.input_audio_transcription.delta":
			_handle_transcription_delta(data)
		"conversation.item.input_audio_transcription.completed":
			_handle_transcription_completed(data)
		"error":
			_handle_error(data)
		_:
			# Handle other event types or ignore
			pass

## Handle speech started event
func _handle_speech_started(data: Dictionary) -> void:
	var session_id = _get_current_session_id()
	if session_id.is_empty():
		return
	
	print("OpenAI STT: Speech started")
	speech_started.emit(session_id)

## Handle speech stopped event
func _handle_speech_stopped(data: Dictionary) -> void:
	var session_id = _get_current_session_id()
	if session_id.is_empty():
		return
	
	var audio_end_ms = data.get("audio_end_ms", 0)
	print("OpenAI STT: Speech stopped at ", audio_end_ms, "ms")
	speech_stopped.emit(session_id, audio_end_ms)

## Handle transcription delta event
func _handle_transcription_delta(data: Dictionary) -> void:
	var session_id = _get_current_session_id()
	if session_id.is_empty():
		return
	
	var delta = data.get("delta", "")
	if delta.length() > 0:
		# Accumulate text
		active_sessions[session_id]["accumulated_text"] += delta
		transcription_delta.emit(delta, session_id)

## Handle transcription completed event
func _handle_transcription_completed(data: Dictionary) -> void:
	var session_id = _get_current_session_id()
	if session_id.is_empty():
		return
	
	var transcript = data.get("transcript", "")
	active_sessions[session_id]["status"] = "completed"
	transcription_completed.emit(transcript, session_id)

## Handle error event
func _handle_error(data: Dictionary) -> void:
	var session_id = _get_current_session_id()
	var error = data.get("error", {})
	
	push_error("OpenAI STT Error: " + str(error))
	
	if not session_id.is_empty():
		transcription_error.emit(session_id, error)

## Get current session ID (simplified - assumes single session for now)
func _get_current_session_id() -> String:
	for session_id in active_sessions.keys():
		if active_sessions[session_id]["status"] in ["starting", "active"]:
			return session_id
	return ""

## Get supported models
func get_supported_models() -> Array:
	return ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]

## Get supported audio formats
func get_supported_formats() -> Array:
	return ["pcm16", "g711_ulaw", "g711_alaw"]

## Get session status
func get_session_status(session_id: String) -> Dictionary:
	if active_sessions.has(session_id):
		return active_sessions[session_id].duplicate()
	return {}

## Clean up resources
func _exit_tree():
	if websocket and connection_state == "connected":
		websocket.close()
	active_sessions.clear()