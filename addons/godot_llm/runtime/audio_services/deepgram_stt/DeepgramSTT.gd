extends Node
## Real-time Speech-to-Text service using Deepgram's WebSocket API
##
## This autoloaded singleton manages a persistent WebSocket connection to Deepgram
## for real-time speech-to-text transcription. It accepts PCM audio data (typically
## from VADManager) and emits signals with transcription results.
##
## @tutorial(Deepgram API): https://developers.deepgram.com/docs/getting-started-with-live-streaming-audio
## @tutorial(Research Doc): res://addons/godot_llm/runtime/audio_services/deepgram_stt/DEEPGRAM_RESEARCH.md

## Connection states
enum ConnectionState {
	DISCONNECTED,  ## Not connected to Deepgram
	CONNECTING,    ## WebSocket handshake in progress
	CONNECTED,     ## Connected and ready to send/receive
	ERROR          ## Connection error, will attempt reconnect
}

#region Signals

## Emitted when connection to Deepgram is established
signal connected()

## Emitted when connection to Deepgram is closed
signal disconnected()

## Emitted when a connection or processing error occurs
## @param error_message: Description of the error
signal error(error_message: String)

## Emitted when interim transcript is received (is_final=false)
## These are preliminary results that may change as more audio is processed
## @param text: The transcribed text
## @param confidence: Confidence score (0.0 to 1.0)
signal transcript_interim(text: String, confidence: float)

## Emitted when final transcript is received (is_final=true, speech_final=false)
## This is a finalized transcript for a segment, but more segments may follow
## @param text: The transcribed text
## @param confidence: Confidence score (0.0 to 1.0)
## @param words: Array of word dictionaries with timing and confidence
signal transcript_final(text: String, confidence: float, words: Array)

## Emitted when speech naturally ends via endpointing (speech_final=true)
## This contains the COMPLETE utterance (all is_final segments concatenated)
## @param text: The complete transcribed utterance
## @param confidence: Confidence score (0.0 to 1.0)
## @param words: Array of word dictionaries with timing and confidence
signal speech_ended(text: String, confidence: float, words: Array)

## Emitted when UtteranceEnd message is received (requires utterance_end_ms parameter)
## @param last_word_end: Timestamp when the last word ended
signal utterance_ended(last_word_end: float)

## Emitted when SpeechStarted message is received (requires vad_events=true parameter)
## @param timestamp: Timestamp when speech was detected
signal speech_started_event(timestamp: float)

#endregion

#region Configuration

## Deepgram API key
var api_key: String = ""

## Deepgram model to use (default: nova-3 - most accurate, lowest latency)
var model: String = "nova-3"

## Audio encoding format (must match VAD output)
var encoding: String = "linear16"

## Audio sample rate in Hz (must match VAD output)
var sample_rate: int = 48000

## Number of audio channels (1 = mono, 2 = stereo)
var channels: int = 1

## Enable smart formatting (punctuation, capitalization, number formatting)
var smart_format: bool = true

## Enable interim results (preliminary transcripts)
var interim_results: bool = true

## Endpointing timeout in milliseconds (default: 300ms)
## Detects end of speech after this much silence
var endpointing: int = 300

## Enable VAD events (SpeechStarted messages)
## Not needed if you have local VAD, but useful for debugging
var vad_events: bool = false

## Utterance end detection in milliseconds (optional, requires interim_results)
## Set to 0 to disable
var utterance_end_ms: int = 0

#endregion

#region Internal State

## Current connection state
var connection_state: ConnectionState = ConnectionState.DISCONNECTED

## WebSocket client
var websocket: WebSocketPeer = null

## KeepAlive timer (send every 8 seconds during silence)
var keepalive_timer: float = 0.0
const KEEPALIVE_INTERVAL: float = 8.0

## Reconnection logic
var reconnect_timer: float = 0.0
var reconnect_attempts: int = 0
const MAX_RECONNECT_ATTEMPTS: int = 5
const RECONNECT_BACKOFF_BASE: float = 1.0  # Start with 1 second

## Audio buffer for reconnection (max 10 seconds at 48kHz, 16-bit, mono)
var audio_buffer: PackedByteArray = PackedByteArray()
const MAX_BUFFER_SIZE: int = 48000 * 2 * 10  # 10 seconds of audio

## Track when we last sent audio (for KeepAlive logic)
var last_audio_send_time: float = 0.0

## Accumulate transcript parts until speech_final=true
var current_utterance_parts: Array[String] = []

## Track if we're currently processing speech
var is_processing_speech: bool = false

#endregion

#region Initialization

func _ready() -> void:
	set_process(false)  # Only process when connected

## Initialize the service with API key and optional configuration
## @param deepgram_api_key: Your Deepgram API key
## @param options: Optional dictionary to override default settings
func initialize(deepgram_api_key: String, options: Dictionary = {}) -> void:
	api_key = deepgram_api_key
	
	# Apply optional configuration
	if options.has("model"):
		model = options.model
	if options.has("encoding"):
		encoding = options.encoding
	if options.has("sample_rate"):
		sample_rate = options.sample_rate
	if options.has("channels"):
		channels = options.channels
	if options.has("smart_format"):
		smart_format = options.smart_format
	if options.has("interim_results"):
		interim_results = options.interim_results
	if options.has("endpointing"):
		endpointing = options.endpointing
	if options.has("vad_events"):
		vad_events = options.vad_events
	if options.has("utterance_end_ms"):
		utterance_end_ms = options.utterance_end_ms
	
	print("DeepgramSTT: Initialized with model=%s, sample_rate=%d" % [model, sample_rate])

#endregion

#region Connection Management

## Connect to Deepgram's WebSocket API
## Returns OK on success, or an error code on failure
func connect_to_deepgram() -> Error:
	if connection_state != ConnectionState.DISCONNECTED:
		push_warning("DeepgramSTT: Already connected or connecting")
		return ERR_ALREADY_IN_USE
	
	if api_key.is_empty():
		push_error("DeepgramSTT: API key not set. Call initialize() first.")
		error.emit("API key not set")
		return ERR_UNCONFIGURED
	
	# Build WebSocket URL with parameters
	var url = "wss://api.deepgram.com/v1/listen"
	url += "?model=" + model
	url += "&encoding=" + encoding
	url += "&sample_rate=" + str(sample_rate)
	url += "&channels=" + str(channels)
	url += "&smart_format=" + ("true" if smart_format else "false")
	url += "&interim_results=" + ("true" if interim_results else "false")
	url += "&endpointing=" + str(endpointing)
	
	if vad_events:
		url += "&vad_events=true"
	
	if utterance_end_ms > 0 and interim_results:
		url += "&utterance_end_ms=" + str(utterance_end_ms)
	
	# Note: WebSocketPeer in Godot 4.x doesn't support custom headers
	# So we pass the API key as a query parameter instead
	# Deepgram supports both header and query param authentication
	url += "&token=" + api_key
	
	# Create WebSocket and connect
	websocket = WebSocketPeer.new()
	var tls_options = TLSOptions.client()
	var err = websocket.connect_to_url(url, tls_options)
	
	if err != OK:
		push_error("DeepgramSTT: Failed to connect: " + error_string(err))
		connection_state = ConnectionState.ERROR
		error.emit("Failed to initiate connection: " + error_string(err))
		return err
	
	connection_state = ConnectionState.CONNECTING
	set_process(true)
	
	print("DeepgramSTT: Connecting to Deepgram...")
	return OK

## Disconnect from Deepgram gracefully
func disconnect_from_deepgram() -> void:
	if connection_state == ConnectionState.DISCONNECTED:
		return
	
	# Send CloseStream message if connected
	if connection_state == ConnectionState.CONNECTED:
		send_close_stream()
	
	# Close WebSocket
	if websocket:
		websocket.close()
	
	_cleanup_connection()
	print("DeepgramSTT: Disconnected")

## Clean up connection resources
func _cleanup_connection() -> void:
	connection_state = ConnectionState.DISCONNECTED
	websocket = null
	keepalive_timer = 0.0
	last_audio_send_time = 0.0
	current_utterance_parts.clear()
	is_processing_speech = false
	set_process(false)
	disconnected.emit()

#endregion

#region Audio Sending

## Send PCM audio data to Deepgram
## @param pcm_data: Raw PCM audio bytes (16-bit, little-endian, matching sample_rate and channels)
func send_audio(pcm_data: PackedByteArray) -> void:
	# Validate audio data
	if pcm_data.size() == 0:
		push_warning("DeepgramSTT: Attempted to send empty audio data")
		return
	
	# If not connected, buffer the audio for reconnection
	if connection_state != ConnectionState.CONNECTED:
		_buffer_audio(pcm_data)
		return
	
	# Send as binary WebSocket frame
	var err = websocket.send(pcm_data)
	if err != OK:
		push_error("DeepgramSTT: Failed to send audio: " + error_string(err))
		error.emit("Failed to send audio: " + error_string(err))
		return
	
	# Track send time for KeepAlive logic
	last_audio_send_time = Time.get_ticks_msec() / 1000.0
	keepalive_timer = 0.0  # Reset KeepAlive timer

## Buffer audio during disconnection (max 10 seconds)
func _buffer_audio(pcm_data: PackedByteArray) -> void:
	audio_buffer.append_array(pcm_data)
	
	# Drop oldest data if buffer exceeds max size
	if audio_buffer.size() > MAX_BUFFER_SIZE:
		var excess = audio_buffer.size() - MAX_BUFFER_SIZE
		audio_buffer = audio_buffer.slice(excess)
		push_warning("DeepgramSTT: Audio buffer full, dropping %d bytes" % excess)

## Send buffered audio after reconnection
func _flush_audio_buffer() -> void:
	if audio_buffer.size() == 0:
		return
	
	print("DeepgramSTT: Flushing %d bytes of buffered audio" % audio_buffer.size())
	send_audio(audio_buffer)
	audio_buffer.clear()

#endregion

#region Control Messages

## Send KeepAlive message to prevent timeout
func send_keepalive() -> void:
	if connection_state != ConnectionState.CONNECTED:
		return
	
	var msg = JSON.stringify({"type": "KeepAlive"})
	var err = websocket.send_text(msg)
	
	if err != OK:
		push_error("DeepgramSTT: Failed to send KeepAlive: " + error_string(err))
	else:
		keepalive_timer = 0.0

## Send Finalize message to flush buffered audio
## @param channel: Optional channel to finalize (-1 = all channels)
func send_finalize(channel: int = -1) -> void:
	if connection_state != ConnectionState.CONNECTED:
		return
	
	var msg = {"type": "Finalize"}
	if channel >= 0:
		msg["channel"] = channel
	
	var err = websocket.send_text(JSON.stringify(msg))
	if err != OK:
		push_error("DeepgramSTT: Failed to send Finalize: " + error_string(err))

## Send CloseStream message to gracefully close connection
func send_close_stream() -> void:
	if connection_state != ConnectionState.CONNECTED:
		return
	
	var msg = JSON.stringify({"type": "CloseStream"})
	var err = websocket.send_text(msg)
	
	if err != OK:
		push_error("DeepgramSTT: Failed to send CloseStream: " + error_string(err))

#endregion

#region Message Processing

func _process(delta: float) -> void:
	if not websocket:
		return
	
	# Poll WebSocket
	websocket.poll()
	var state = websocket.get_ready_state()
	
	# Handle connection state changes
	match state:
		WebSocketPeer.STATE_OPEN:
			if connection_state == ConnectionState.CONNECTING:
				_on_connection_established()
			elif connection_state == ConnectionState.CONNECTED:
				_process_connected(delta)
		
		WebSocketPeer.STATE_CLOSING:
			pass  # Connection is closing, wait for STATE_CLOSED
		
		WebSocketPeer.STATE_CLOSED:
			_on_connection_closed()

## Called when WebSocket connection is established
func _on_connection_established() -> void:
	connection_state = ConnectionState.CONNECTED
	reconnect_attempts = 0
	reconnect_timer = 0.0
	
	print("DeepgramSTT: Connected successfully!")
	connected.emit()
	
	# Flush any buffered audio
	_flush_audio_buffer()

## Called when WebSocket connection is closed
func _on_connection_closed() -> void:
	var close_code = websocket.get_close_code()
	var close_reason = websocket.get_close_reason()
	
	print("DeepgramSTT: Connection closed (code: %d, reason: %s)" % [close_code, close_reason])
	
	# Handle specific error codes
	match close_code:
		1008:  # DATA-0000: Invalid audio data
			push_error("DeepgramSTT: Invalid audio data. Check encoding parameters.")
			error.emit("Invalid audio data (1008)")
		1011:  # NET-0000 or NET-0001: Timeout
			push_warning("DeepgramSTT: Connection timeout. Reconnecting...")
			_attempt_reconnect()
			return
		_:
			if close_code != 1000:  # 1000 = normal closure
				push_warning("DeepgramSTT: Unexpected closure: %s" % close_reason)
	
	_cleanup_connection()

## Process connected state (check for messages and KeepAlive)
func _process_connected(delta: float) -> void:
	# Process incoming messages
	while websocket.get_available_packet_count() > 0:
		var packet = websocket.get_packet()
		var is_string = websocket.was_string_packet()
		
		if is_string:
			var json_string = packet.get_string_from_utf8()
			_parse_message(json_string)
	
	# Handle KeepAlive timer
	var current_time = Time.get_ticks_msec() / 1000.0
	var time_since_last_audio = current_time - last_audio_send_time
	
	# Send KeepAlive if we haven't sent audio recently
	if time_since_last_audio > KEEPALIVE_INTERVAL:
		keepalive_timer += delta
		if keepalive_timer >= KEEPALIVE_INTERVAL:
			send_keepalive()

## Parse JSON message from Deepgram
func _parse_message(json_string: String) -> void:
	var json = JSON.new()
	var parse_error = json.parse(json_string)
	
	if parse_error != OK:
		push_error("DeepgramSTT: Failed to parse JSON: " + json_string)
		return
	
	var data = json.get_data()
	if not data is Dictionary:
		push_error("DeepgramSTT: Invalid message format")
		return
	
	var msg_type = data.get("type", "")
	
	match msg_type:
		"Results":
			_handle_results(data)
		"UtteranceEnd":
			_handle_utterance_end(data)
		"SpeechStarted":
			_handle_speech_started(data)
		"Metadata":
			_handle_metadata(data)
		_:
			push_warning("DeepgramSTT: Unknown message type: " + msg_type)

## Handle Results message (transcript)
func _handle_results(data: Dictionary) -> void:
	var is_final = data.get("is_final", false)
	var speech_final = data.get("speech_final", false)
	
	var channel = data.get("channel", {})
	var alternatives = channel.get("alternatives", [])
	
	if alternatives.size() == 0:
		return
	
	var alt = alternatives[0]
	var transcript = alt.get("transcript", "")
	var confidence = alt.get("confidence", 0.0)
	var words = alt.get("words", [])
	
	# Skip empty transcripts
	if transcript.length() == 0:
		return
	
	# Emit interim results
	if not is_final:
		transcript_interim.emit(transcript, confidence)
		return
	
	# Handle final results
	if is_final:
		# Accumulate transcript parts
		current_utterance_parts.append(transcript)
		
		# If speech_final, emit complete utterance
		if speech_final:
			var full_transcript = " ".join(current_utterance_parts)
			speech_ended.emit(full_transcript, confidence, words)
			current_utterance_parts.clear()
			is_processing_speech = false
		else:
			# Partial final result
			transcript_final.emit(transcript, confidence, words)
			is_processing_speech = true

## Handle UtteranceEnd message
func _handle_utterance_end(data: Dictionary) -> void:
	var last_word_end = data.get("last_word_end", 0.0)
	utterance_ended.emit(last_word_end)

## Handle SpeechStarted message
func _handle_speech_started(data: Dictionary) -> void:
	var timestamp = data.get("timestamp", 0.0)
	speech_started_event.emit(timestamp)
	is_processing_speech = true

## Handle Metadata message
func _handle_metadata(data: Dictionary) -> void:
	var request_id = data.get("request_id", "")
	print("DeepgramSTT: Metadata received (request_id: %s)" % request_id)

#endregion

#region Reconnection Logic

## Attempt to reconnect with exponential backoff
func _attempt_reconnect() -> void:
	if reconnect_attempts >= MAX_RECONNECT_ATTEMPTS:
		push_error("DeepgramSTT: Max reconnection attempts reached. Giving up.")
		error.emit("Max reconnection attempts reached")
		_cleanup_connection()
		return
	
	connection_state = ConnectionState.ERROR
	reconnect_attempts += 1
	
	# Calculate backoff time: 1s, 2s, 4s, 8s, 16s (capped at 30s)
	var backoff_time = min(RECONNECT_BACKOFF_BASE * pow(2, reconnect_attempts - 1), 30.0)
	
	print("DeepgramSTT: Reconnecting in %.1f seconds (attempt %d/%d)..." % [backoff_time, reconnect_attempts, MAX_RECONNECT_ATTEMPTS])
	
	await get_tree().create_timer(backoff_time).timeout
	
	# Try to reconnect
	if connection_state == ConnectionState.ERROR:
		connect_to_deepgram()

#endregion

#region Cleanup

func _exit_tree() -> void:
	disconnect_from_deepgram()

#endregion

