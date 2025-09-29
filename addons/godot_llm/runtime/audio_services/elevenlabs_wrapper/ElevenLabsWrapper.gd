## ElevenLabs Text-to-Speech Wrapper
## 
## Provides streaming TTS functionality using ElevenLabs API
## Supports real-time text-to-speech conversion with chunked audio output
##
## @tutorial: https://elevenlabs.io/docs/api-reference/text-to-speech

extends Node

## Emitted when an audio chunk is ready for playback
signal audio_chunk_ready(audio_data: PackedByteArray, stream_id: String)

## Emitted when synthesis starts
signal synthesis_started(stream_id: String)

## Emitted when synthesis completes successfully
signal synthesis_completed(stream_id: String, total_audio_length: float)

## Emitted when synthesis encounters an error
signal synthesis_error(stream_id: String, error: Dictionary)

## Emitted when voice list is retrieved
signal voices_received(voices: Array)

## ElevenLabs API configuration
var api_key: String = ""
var api_base_url: String = "https://api.elevenlabs.io/v1"
var default_voice_id: String = "21m00Tcm4TlvDq8ikWAM"  # Default voice

## Voice settings
var voice_stability: float = 0.5
var voice_clarity: float = 0.75
var voice_style: float = 0.0
var voice_use_speaker_boost: bool = true

## Internal HTTP client for streaming requests
var http_client: HTTPClient
var active_streams: Dictionary = {}

func _ready():
	http_client = HTTPClient.new()
	# HTTPClient doesn't need to be added as child - it's used directly

## Initialize the wrapper with API key
func initialize(elevenlabs_api_key: String) -> void:
	api_key = elevenlabs_api_key
	print("ElevenLabsWrapper initialized")

## Start streaming text-to-speech synthesis
## Returns a unique stream_id for tracking this synthesis
func start_stream_synthesis(text: String, voice_id: String = "") -> String:
	if api_key.is_empty():
		push_error("ElevenLabs API key not set")
		return ""
	
	if voice_id.is_empty():
		voice_id = default_voice_id
	
	var stream_id = "tts_" + str(Time.get_unix_time_from_system()) + "_" + str(randi())
	
	# Store stream info
	active_streams[stream_id] = {
		"voice_id": voice_id,
		"text": text,
		"status": "starting"
	}
	
	# Start the synthesis process
	_start_synthesis_request(stream_id, text, voice_id)
	
	return stream_id

## Feed additional text to an active stream (for real-time streaming)
func feed_text_delta(text_chunk: String, stream_id: String) -> void:
	if not active_streams.has(stream_id):
		push_warning("Stream ID not found: " + stream_id)
		return
	
	# For now, we'll accumulate text and re-synthesize
	# In a full implementation, this would use ElevenLabs streaming API
	active_streams[stream_id]["text"] += text_chunk
	
	# TODO: Implement true streaming synthesis when ElevenLabs supports it

## Finish synthesis for a stream
func finish_stream_synthesis(stream_id: String) -> void:
	if not active_streams.has(stream_id):
		return
	
	active_streams[stream_id]["status"] = "finishing"
	# The synthesis will complete naturally

## Get available voices asynchronously
func get_available_voices_async() -> String:
	var request_id = "voices_" + str(Time.get_unix_time_from_system())
	_request_voices(request_id)
	return request_id

## Set voice parameters for synthesis
func set_voice_settings(stability: float, clarity: float, style: float = 0.0, use_speaker_boost: bool = true) -> void:
	voice_stability = clamp(stability, 0.0, 1.0)
	voice_clarity = clamp(clarity, 0.0, 1.0)
	voice_style = clamp(style, 0.0, 1.0)
	voice_use_speaker_boost = use_speaker_boost

## Set the default voice ID
func set_default_voice(voice_id: String) -> void:
	default_voice_id = voice_id

## Internal method to start synthesis HTTP request
func _start_synthesis_request(stream_id: String, text: String, voice_id: String) -> void:
	# This is a placeholder for the actual HTTP request implementation
	# In a real implementation, this would:
	# 1. Connect to ElevenLabs API
	# 2. Send POST request with text and voice settings
	# 3. Stream the audio response back in chunks
	
	synthesis_started.emit(stream_id)
	
	# Simulate synthesis completion for now
	call_deferred("_simulate_synthesis_completion", stream_id)

## Internal method to request voices
func _request_voices(request_id: String) -> void:
	# Placeholder for voices API request
	# Would fetch from: GET /v1/voices
	
	# Simulate voice list response
	var mock_voices = [
		{"voice_id": "21m00Tcm4TlvDq8ikWAM", "name": "Rachel", "category": "premade"},
		{"voice_id": "AZnzlk1XvdvUeBnXmlld", "name": "Domi", "category": "premade"},
		{"voice_id": "EXAVITQu4vr4xnSDxMaL", "name": "Bella", "category": "premade"}
	]
	
	call_deferred("_emit_voices_received", mock_voices)

## Simulate synthesis completion (temporary)
func _simulate_synthesis_completion(stream_id: String) -> void:
	# This simulates receiving audio chunks
	# In real implementation, this would be replaced by actual HTTP response handling
	
	var mock_audio_data = PackedByteArray()
	mock_audio_data.resize(1024)  # Simulate 1KB audio chunk
	
	# Emit a few audio chunks
	for i in range(3):
		await get_tree().create_timer(0.1).timeout
		audio_chunk_ready.emit(mock_audio_data, stream_id)
	
	# Complete the synthesis
	active_streams[stream_id]["status"] = "completed"
	synthesis_completed.emit(stream_id, 0.3)  # 0.3 seconds of audio

## Emit voices received signal
func _emit_voices_received(voices: Array) -> void:
	voices_received.emit(voices)

## Clean up resources
func _exit_tree():
	# HTTPClient doesn't need queue_free() - it's handled automatically
	http_client = null
	active_streams.clear()
