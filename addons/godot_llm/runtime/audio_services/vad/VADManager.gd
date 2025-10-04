extends Node
class_name VADManager

## Voice Activity Detection Manager using TwoVoip's AI-powered RnNoise
##
## This class wraps TwoVoip's AudioEffectOpusChunked to provide robust VAD
## with AI-powered noise suppression. It detects when speech starts/ends
## and emits PCM audio chunks only when speech is detected.
##
## Usage:
##   var vad = VADManager.new()
##   vad.speech_detected.connect(_on_speech_detected)
##   vad.speech_started.connect(_on_speech_started)
##   vad.speech_ended.connect(_on_speech_ended)
##   vad.setup()
##   add_child(vad)

## Emitted when speech activity begins (after retroactive grace period)
signal speech_started()

## Emitted when speech activity ends (after grace period)
signal speech_ended()

## Emitted continuously while speech is active, contains PCM audio data
## @param pcm_data: PackedByteArray - 16-bit PCM audio, mono, 48kHz
signal speech_detected(pcm_data: PackedByteArray)

## Audio configuration constants
const SAMPLE_RATE = 48000  # Required by RnNoise
const MICROPHONE_BUS_NAME = "VAD_Microphone"

## VAD configuration (exported for tuning)
@export_range(0.0, 1.0, 0.01) var vad_threshold: float = 0.75  ## Speech probability threshold (75% default)
@export var grace_period_ms: int = 200  ## Milliseconds to wait before ending speech
@export var retroactive_grace_ms: int = 100  ## Milliseconds to capture before speech starts (adds latency!)
@export var enable_denoising: bool = true  ## Apply RnNoise denoising to output audio

## Internal state
var opuschunked: AudioEffectOpusChunked = null
var microphone_player: AudioStreamPlayer = null
var microphone_bus_idx: int = -1

var is_speech_active: bool = false
var silence_frame_count: int = 0
var grace_period_frames: int = 0

var is_setup: bool = false
var is_recording: bool = false

## Setup error codes
enum SetupError {
	OK = 0,
	MICROPHONE_INPUT_DISABLED = 1,
	FAILED_TO_CREATE_BUS = 2,
	FAILED_TO_ADD_EFFECT = 3,
	FAILED_TO_CREATE_PLAYER = 4,
}

func _ready():
	if not is_setup:
		push_warning("VADManager: setup() was not called before _ready(). Auto-setting up...")
		var result = setup()
		if result != SetupError.OK:
			push_error("VADManager: Auto-setup failed with error code: %d" % result)

func setup() -> SetupError:
	"""
	Sets up the VAD system: creates audio bus, microphone player, and OpusChunked effect.
	Must be called before starting recording.
	
	Returns SetupError enum value (OK = 0 on success)
	"""
	if is_setup:
		push_warning("VADManager: Already setup, skipping")
		return SetupError.OK
	
	# 1. Check if microphone input is enabled
	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		push_warning("VADManager: Microphone input is disabled! Attempting to enable it automatically...")
		ProjectSettings.set_setting("audio/driver/enable_input", true)
		
		# Try to save the setting
		var save_result = ProjectSettings.save()
		if save_result == OK:
			push_warning("VADManager: Microphone input enabled! Please RESTART Godot for changes to take effect.")
			push_error("VADManager: Setup failed - restart required after enabling microphone input")
		else:
			push_error("VADManager: Failed to save project settings. Please enable 'audio/driver/enable_input' manually in Project Settings")
		
		return SetupError.MICROPHONE_INPUT_DISABLED
	
	# 2. Check/set mix rate to 48kHz
	var current_mix_rate = ProjectSettings.get_setting("audio/driver/mix_rate", 44100)
	if current_mix_rate != SAMPLE_RATE:
		push_warning("VADManager: Mix rate is %d Hz but TwoVoip requires 48000 Hz. Attempting to override..." % current_mix_rate)
		ProjectSettings.set_setting("audio/driver/mix_rate", SAMPLE_RATE)
		# Note: This may not take effect until restart
	
	# 3. Create microphone audio bus
	microphone_bus_idx = AudioServer.get_bus_index(MICROPHONE_BUS_NAME)
	if microphone_bus_idx == -1:
		# Bus doesn't exist, create it
		microphone_bus_idx = AudioServer.bus_count
		AudioServer.add_bus(microphone_bus_idx)
		AudioServer.set_bus_name(microphone_bus_idx, MICROPHONE_BUS_NAME)
		AudioServer.set_bus_mute(microphone_bus_idx, true)  # Mute to prevent feedback loop
		print("VADManager: Created audio bus '%s' at index %d" % [MICROPHONE_BUS_NAME, microphone_bus_idx])
	else:
		print("VADManager: Using existing audio bus '%s' at index %d" % [MICROPHONE_BUS_NAME, microphone_bus_idx])
	
	# 4. Add AudioEffectOpusChunked to the bus
	opuschunked = AudioEffectOpusChunked.new()
	if not opuschunked:
		push_error("VADManager: Failed to create AudioEffectOpusChunked! Is TwoVoip plugin installed?")
		return SetupError.FAILED_TO_ADD_EFFECT
	
	# Configure OpusChunked effect
	# Properties available: audiosamplesize, prefixbyteslength, sample_rate, etc.
	# Most defaults should be fine for 48kHz operation
	
	AudioServer.add_bus_effect(microphone_bus_idx, opuschunked, 0)
	print("VADManager: Added AudioEffectOpusChunked to bus")
	
	# 5. Create AudioStreamPlayer with microphone input
	microphone_player = AudioStreamPlayer.new()
	microphone_player.stream = AudioStreamMicrophone.new()
	microphone_player.bus = MICROPHONE_BUS_NAME
	microphone_player.autoplay = false  # We'll start it manually
	add_child(microphone_player)
	print("VADManager: Created microphone player")
	
	# 6. Calculate grace period in frames
	# Each chunk is typically 960 samples at 48kHz = 20ms
	var chunk_duration_ms = 20  # TwoVoip default
	grace_period_frames = max(1, int(float(grace_period_ms) / float(chunk_duration_ms)))
	
	is_setup = true
	print("VADManager: Setup complete! VAD threshold: %.2f, Grace period: %d frames (%dms)" % [vad_threshold, grace_period_frames, grace_period_ms])
	
	return SetupError.OK

func start_recording():
	"""Starts recording and processing audio for VAD"""
	if not is_setup:
		push_error("VADManager: Cannot start recording before setup()")
		return
	
	if is_recording:
		push_warning("VADManager: Already recording")
		return
	
	# Start microphone playback (into the muted bus)
	microphone_player.play()
	is_recording = true
	is_speech_active = false
	silence_frame_count = 0
	
	print("VADManager: Recording started")

func stop_recording():
	"""Stops recording and resets VAD state"""
	if not is_recording:
		return
	
	microphone_player.stop()
	is_recording = false
	
	# Emit speech_ended if we were in the middle of speech
	if is_speech_active:
		is_speech_active = false
		speech_ended.emit()
	
	# Flush the opus encoder to reset state
	if opuschunked:
		opuschunked.flush_opus_encoder()
	
	print("VADManager: Recording stopped")

func _process(_delta):
	if not is_recording or not opuschunked:
		return
	
	# Process all available audio chunks
	while opuschunked.chunk_available():
		_process_audio_chunk()

func _process_audio_chunk():
	"""
	Processes a single audio chunk:
	1. Runs AI-powered VAD (denoise_resampled_chunk)
	2. Detects speech start/end with grace periods
	3. Extracts PCM audio and emits signal when speech is active
	"""
	
	# Use AI-powered VAD with RnNoise
	# This returns a float [0.0, 1.0] representing speech probability
	# It also denoises the audio chunk in-place
	var speech_probability: float = opuschunked.denoise_resampled_chunk()
	
	if speech_probability >= vad_threshold:
		# Speech detected!
		
		if not is_speech_active:
			# Speech just started!
			if retroactive_grace_ms > 0:
				# Undrop chunks to capture the beginning of speech
				# This adds latency but prevents cutting off word starts
				opuschunked.undrop_chunk()
			
			is_speech_active = true
			speech_started.emit()
			print("VADManager: Speech started (prob: %.2f)" % speech_probability)
		
		# Reset silence counter
		silence_frame_count = 0
		
		# Extract PCM audio and emit signal
		var pcm_data = _extract_pcm_from_chunk()
		if pcm_data.size() > 0:
			speech_detected.emit(pcm_data)
	
	else:
		# Silence/noise detected
		
		if is_speech_active:
			# We're in speech mode, count silence frames
			silence_frame_count += 1
			
			# Still emit audio during grace period to avoid cutting off words
			var pcm_data = _extract_pcm_from_chunk()
			if pcm_data.size() > 0:
				speech_detected.emit(pcm_data)
			
			if silence_frame_count >= grace_period_frames:
				# Grace period expired, speech ended
				is_speech_active = false
				speech_ended.emit()
				print("VADManager: Speech ended (prob: %.2f, silence frames: %d)" % [speech_probability, silence_frame_count])
				silence_frame_count = 0
	
	# Drop the chunk to advance to the next one
	opuschunked.drop_chunk()

func _extract_pcm_from_chunk() -> PackedByteArray:
	"""
	Extracts raw PCM audio from the current chunk as PackedByteArray.
	Format: 16-bit signed PCM, mono, 48kHz, little-endian
	
	This is the format Deepgram expects for streaming.
	"""
	
	# Get raw audio from TwoVoip as PackedVector2Array
	# Using resampled=true gives us 48kHz audio (required by RnNoise and perfect for Deepgram)
	# If denoise_resampled_chunk() was called, this returns DENOISED audio!
	var audio_frames: PackedVector2Array = opuschunked.read_chunk(true)
	
	if audio_frames.size() == 0:
		return PackedByteArray()
	
	# Convert PackedVector2Array to 16-bit PCM mono
	# Each Vector2 = (left_channel, right_channel) as floats in range [-1.0, 1.0]
	var pcm_bytes = PackedByteArray()
	pcm_bytes.resize(audio_frames.size() * 2)  # 2 bytes per sample (16-bit)
	
	for i in range(audio_frames.size()):
		var frame = audio_frames[i]
		
		# Convert stereo to mono (average left and right)
		var mono_sample = (frame.x + frame.y) / 2.0
		
		# Convert float [-1.0, 1.0] to 16-bit PCM [-32768, 32767]
		var sample_int = int(clamp(mono_sample * 32767.0, -32768.0, 32767.0))
		
		# Write as little-endian 16-bit
		pcm_bytes[i * 2] = sample_int & 0xFF          # Low byte
		pcm_bytes[i * 2 + 1] = (sample_int >> 8) & 0xFF  # High byte
	
	return pcm_bytes

func cleanup():
	"""Cleans up resources"""
	stop_recording()
	
	if microphone_player:
		microphone_player.queue_free()
		microphone_player = null
	
	if microphone_bus_idx != -1:
		# Note: We don't remove the bus as other systems might be using it
		# Just remove our effect
		if opuschunked:
			var effect_count = AudioServer.get_bus_effect_count(microphone_bus_idx)
			for i in range(effect_count):
				var effect = AudioServer.get_bus_effect(microphone_bus_idx, i)
				if effect == opuschunked:
					AudioServer.remove_bus_effect(microphone_bus_idx, i)
					break
	
	opuschunked = null
	is_setup = false
	
	print("VADManager: Cleanup complete")

func _exit_tree():
	cleanup()

## Utility functions for debugging

func get_current_speech_probability() -> float:
	"""Returns the most recent speech probability (for debugging/UI)"""
	if opuschunked and opuschunked.chunk_available():
		return opuschunked.denoise_resampled_chunk()
	return 0.0

func is_currently_recording() -> bool:
	"""Returns true if currently recording"""
	return is_recording

func is_speech_currently_active() -> bool:
	"""Returns true if speech is currently being detected"""
	return is_speech_active

