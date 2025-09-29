## Audio Manager for Real-Time Voice Processing
##
## Manages Godot audio I/O and coordinates the voice processing pipeline
## Integrates microphone input, VAD, and audio output for seamless voice interaction
##
## @tutorial: Real-time audio processing in Godot

extends Node

## Emitted when audio input chunk is captured
signal audio_input_chunk(audio_data: PackedByteArray)

## Emitted when a complete voice command is detected
signal voice_command_detected(audio_buffer: PackedByteArray)

## Emitted when playback finishes
signal playback_finished()

## Audio configuration
var sample_rate: int = 16000           ## Sample rate for audio processing
var channels: int = 1                  ## Mono audio
var chunk_duration_ms: int = 20        ## 20ms chunks for real-time processing
var input_device: String = ""          ## Audio input device
var output_device: String = ""         ## Audio output device

## Audio nodes
var audio_stream_microphone: AudioStreamMicrophone
var audio_stream_player: AudioStreamPlayer
var audio_effect_capture: AudioEffectCapture

## Voice processing integration (VAD handled by OpenAISTT via OpenAI Realtime API)
var voice_processing_enabled: bool = false

## Internal state
var is_capturing: bool = false
var is_voice_pipeline_active: bool = false
var capture_timer: Timer

## Audio buffers
var input_buffer: PackedByteArray
var playback_queue: Array[PackedByteArray] = []

func _ready():
	_setup_audio_nodes()
	_setup_capture_timer()
	print("AudioManager initialized")

## Setup audio nodes for input/output
func _setup_audio_nodes() -> void:
	# Setup microphone input
	audio_stream_microphone = AudioStreamMicrophone.new()
	
	# Setup audio player for output
	audio_stream_player = AudioStreamPlayer.new()
	add_child(audio_stream_player)
	audio_stream_player.finished.connect(_on_playback_finished)
	
	# Setup audio effect capture for real-time input
	audio_effect_capture = AudioEffectCapture.new()

# VAD functionality moved to OpenAISTT via OpenAI Realtime API

## Setup timer for audio chunk capture
func _setup_capture_timer() -> void:
	capture_timer = Timer.new()
	add_child(capture_timer)
	capture_timer.wait_time = float(chunk_duration_ms) / 1000.0
	capture_timer.timeout.connect(_on_capture_timer_timeout)

## Start the complete voice processing pipeline
func start_voice_pipeline() -> void:
	if is_voice_pipeline_active:
		return
	
	is_voice_pipeline_active = true
	voice_processing_enabled = true
	
	# Start audio capture
	start_audio_capture()
	
	# VAD detection handled by OpenAISTT via OpenAI Realtime API
	
	print("Voice pipeline started")

## Stop the voice processing pipeline
func stop_voice_pipeline() -> void:
	if not is_voice_pipeline_active:
		return
	
	is_voice_pipeline_active = false
	voice_processing_enabled = false
	
	# Stop components
	stop_audio_capture()
	# VAD stopping handled by OpenAISTT
	
	print("Voice pipeline stopped")

## Start audio capture from microphone
func start_audio_capture() -> bool:
	if is_capturing:
		return true
	
	# Setup microphone recording
	var recording = AudioStreamWAV.new()
	recording.format = AudioStreamWAV.FORMAT_16_BITS
	recording.mix_rate = sample_rate
	recording.stereo = (channels == 2)
	
	# Start recording (this is a simplified approach)
	# In a real implementation, you'd need to properly configure AudioServer
	is_capturing = true
	capture_timer.start()
	
	print("Audio capture started")
	return true

## Stop audio capture
func stop_audio_capture() -> void:
	if not is_capturing:
		return
	
	is_capturing = false
	capture_timer.stop()
	
	print("Audio capture stopped")

## Stream audio output (play audio chunks as they arrive)
func stream_audio_output(audio_data: PackedByteArray) -> void:
	if audio_data.size() == 0:
		return
	
	# Add to playback queue
	playback_queue.append(audio_data)
	
	# Start playback if not already playing
	if not audio_stream_player.playing:
		_play_next_audio_chunk()

## Voice detection now handled by OpenAISTT via OpenAI Realtime API
## These methods are deprecated - configure VAD through OpenAISTT instead

## Set audio input device
func set_audio_input_device(device: String) -> void:
	input_device = device
	# In a real implementation, configure AudioServer input device

## Set audio output device  
func set_audio_output_device(device: String) -> void:
	output_device = device
	# In a real implementation, configure AudioServer output device

## Get available input devices
func get_input_devices() -> Array:
	# In a real implementation, query AudioServer for available devices
	return ["Default Microphone", "USB Microphone"]

## Get available output devices
func get_output_devices() -> Array:
	# In a real implementation, query AudioServer for available devices
	return ["Default Speakers", "Headphones"]

## Internal: Handle capture timer timeout (simulate audio chunk capture)
func _on_capture_timer_timeout() -> void:
	if not is_capturing:
		return
	
	# Simulate capturing audio chunk
	# In a real implementation, this would capture from AudioEffectCapture
	var chunk_size = int(sample_rate * channels * (chunk_duration_ms / 1000.0) * 2)  # 16-bit samples
	var audio_chunk = PackedByteArray()
	audio_chunk.resize(chunk_size)
	
	# Fill with simulated audio data (silence for now)
	for i in range(chunk_size):
		audio_chunk[i] = 0
	
	# Emit the chunk
	audio_input_chunk.emit(audio_chunk)
	
	# VAD processing now handled by OpenAISTT via OpenAI Realtime API

## Internal: Handle speech started
func _on_speech_started() -> void:
	print("Speech detected - starting recording")

## Internal: Handle speech continuing
func _on_speech_continuing() -> void:
	# Optional: Update UI or provide feedback
	pass

## Internal: Handle speech ended
func _on_speech_ended(audio_buffer: PackedByteArray) -> void:
	print("Speech ended - processing ", audio_buffer.size(), " bytes")
	voice_command_detected.emit(audio_buffer)

## Internal: Play next audio chunk from queue
func _play_next_audio_chunk() -> void:
	if playback_queue.is_empty():
		return
	
	var audio_data = playback_queue.pop_front()
	
	# Convert PackedByteArray to AudioStream for playback
	# This is a simplified approach - real implementation would need proper audio format conversion
	var audio_stream = AudioStreamWAV.new()
	audio_stream.format = AudioStreamWAV.FORMAT_16_BITS
	audio_stream.mix_rate = sample_rate
	audio_stream.stereo = (channels == 2)
	audio_stream.data = audio_data
	
	audio_stream_player.stream = audio_stream
	audio_stream_player.play()

## Internal: Handle playback finished
func _on_playback_finished() -> void:
	playback_finished.emit()
	
	# Play next chunk if available
	if not playback_queue.is_empty():
		call_deferred("_play_next_audio_chunk")

## Get current pipeline status
func get_pipeline_status() -> Dictionary:
	return {
		"is_voice_pipeline_active": is_voice_pipeline_active,
		"is_capturing": is_capturing,
		"playback_queue_size": playback_queue.size(),
		"voice_processing_enabled": voice_processing_enabled
	}

## Clean up resources
func _exit_tree():
	stop_voice_pipeline()
	
	if capture_timer:
		capture_timer.queue_free()
	
	if audio_stream_player:
		audio_stream_player.queue_free()
	
	# VAD cleanup handled by OpenAISTT
