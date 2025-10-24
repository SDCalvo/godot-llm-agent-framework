extends Window
## VAD → Deepgram STT Test
##
## This test validates the speech-to-text pipeline:
## Microphone → VAD (TwoVoip) → Deepgram STT → Transcript Display
##
## For full voice assistant testing (STT → LLM → TTS), use a separate test scene.

# Autoload reference
var deepgram: Node

#region UI References
@onready var status_label: Label = $Panel/VBox/StatusPanel/StatusLabel
@onready var connect_btn: Button = $Panel/VBox/ControlPanel/ConnectBtn
@onready var disconnect_btn: Button = $Panel/VBox/ControlPanel/DisconnectBtn

@onready var vad_status_label: Label = $Panel/VBox/VADPanel/VBox/VADStatusLabel
@onready var vad_start_btn: Button = $Panel/VBox/VADPanel/VBox/VADControlPanel/VADStartBtn
@onready var vad_stop_btn: Button = $Panel/VBox/VADPanel/VBox/VADControlPanel/VADStopBtn

@onready var interim_label: Label = $Panel/VBox/TranscriptPanel/InterimLabel
@onready var confidence_bar: ProgressBar = $Panel/VBox/TranscriptPanel/ConfidenceBar
@onready var confidence_label: Label = $Panel/VBox/TranscriptPanel/ConfidenceLabel

@onready var final_log: TextEdit = $Panel/VBox/FinalLogPanel/FinalLog
@onready var clear_log_btn: Button = $Panel/VBox/FinalLogPanel/ClearLogBtn
#endregion

#region Services
var vad_manager: Node = null
#endregion

#region State
var is_vad_active: bool = false
var total_transcripts: int = 0
#endregion

func _ready() -> void:
	# Get autoload reference
	deepgram = get_node("/root/DeepgramSTT")
	
	# Setup window
	title = "VAD → Deepgram STT Test"
	
	# Connect UI signals
	connect_btn.pressed.connect(_connect_deepgram)
	disconnect_btn.pressed.connect(_disconnect_deepgram)
	clear_log_btn.pressed.connect(_clear_log)
	vad_start_btn.pressed.connect(_start_vad)
	vad_stop_btn.pressed.connect(_stop_vad)
	
	# Connect Deepgram signals
	deepgram.connected.connect(_on_deepgram_connected)
	deepgram.disconnected.connect(_on_deepgram_disconnected)
	deepgram.error.connect(_on_deepgram_error)
	deepgram.transcript_interim.connect(_on_transcript_interim)
	deepgram.transcript_final.connect(_on_transcript_final)
	deepgram.speech_ended.connect(_on_speech_ended)
	
	# Setup VAD
	_setup_vad()
	
	# Initial UI state
	_update_connection_ui()
	_log_info("🎤 VAD → Deepgram STT Test Ready")
	_log_info("📝 Step 1: Click 'Connect' to connect to Deepgram")
	_log_info("📝 Step 2: Click 'Start VAD' to begin listening")
	_log_info("📝 Step 3: Speak into your microphone!")

func _update_connection_ui() -> void:
	var state = deepgram.connection_state
	
	match state:
		0:  # DISCONNECTED
			status_label.text = "Status: Disconnected ⚫"
			status_label.add_theme_color_override("font_color", Color.GRAY)
			connect_btn.disabled = false
			disconnect_btn.disabled = true
			vad_start_btn.disabled = true
		
		1:  # CONNECTING
			status_label.text = "Status: Connecting... 🟡"
			status_label.add_theme_color_override("font_color", Color.YELLOW)
			connect_btn.disabled = true
			disconnect_btn.disabled = false
			vad_start_btn.disabled = true
		
		2:  # CONNECTED
			status_label.text = "Status: Connected ✅"
			status_label.add_theme_color_override("font_color", Color.GREEN)
			connect_btn.disabled = true
			disconnect_btn.disabled = false
			vad_start_btn.disabled = false
		
		3:  # ERROR
			status_label.text = "Status: Error ❌"
			status_label.add_theme_color_override("font_color", Color.RED)
			connect_btn.disabled = false
			disconnect_btn.disabled = true
			vad_start_btn.disabled = true

#region Deepgram Connection
func _connect_deepgram() -> void:
	_log_info("🔌 Connecting to Deepgram...")
	
	# Try environment variable first, then .env file
	var api_key = OS.get_environment("DEEPGRAM_API_KEY")
	if api_key.is_empty():
		api_key = _load_env_key("DEEPGRAM_API_KEY")
	
	if api_key.is_empty():
		_log_error("❌ DEEPGRAM_API_KEY not set!")
		_log_error("Add it to your .env file or set as environment variable")
		return
	
	_log_info("✅ API key loaded (length: %d)" % api_key.length())
	
	# Initialize Deepgram
	deepgram.initialize(api_key, {
		"model": "nova-3",
		"interim_results": true,
		"smart_format": true,
		"endpointing": 300
	})
	
	# Connect
	var err = deepgram.connect_to_deepgram()
	if err != OK:
		_log_error("❌ Failed to connect: " + error_string(err))
	
	_update_connection_ui()

func _disconnect_deepgram() -> void:
	_log_info("🔌 Disconnecting from Deepgram...")
	deepgram.disconnect_from_deepgram()
	_update_connection_ui()
#endregion

#region VAD Setup
func _setup_vad() -> void:
	_log_info("🎤 Setting up VAD (Voice Activity Detection)...")
	
	# Create VADManager
	vad_manager = preload("res://addons/godot_llm/runtime/audio_services/vad/VADManager.gd").new()
	add_child(vad_manager)
	
	# Connect VAD signals
	vad_manager.speech_started.connect(_on_vad_started)
	vad_manager.speech_detected.connect(_on_vad_audio)
	vad_manager.speech_ended.connect(_on_vad_ended)
	
	# Setup VAD
	var setup_result = vad_manager.setup()
	if setup_result != 0:
		_log_error("❌ VAD setup failed! Enable microphone input in Project Settings and restart.")
		vad_status_label.text = "VAD: Setup Failed ❌"
		vad_status_label.add_theme_color_override("font_color", Color.RED)
		vad_start_btn.disabled = true
		return
	
	vad_status_label.text = "VAD: Ready (Not Started)"
	vad_status_label.add_theme_color_override("font_color", Color.YELLOW)
	vad_start_btn.disabled = true  # Will be enabled after Deepgram connects
	vad_stop_btn.disabled = true
	
	_log_info("✅ VAD ready!")

func _cleanup_vad() -> void:
	if is_vad_active:
		_stop_vad()
	
	if vad_manager:
		vad_manager.queue_free()
		vad_manager = null
	
	_log_info("🧹 Cleaned up VAD")

func _start_vad() -> void:
	if not vad_manager:
		return
	
	vad_manager.start_recording()
	is_vad_active = true
	
	vad_status_label.text = "VAD: Listening... 🎤"
	vad_status_label.add_theme_color_override("font_color", Color.GREEN)
	vad_start_btn.disabled = true
	vad_stop_btn.disabled = false
	
	_log_info("🎤 VAD started - speak into your microphone!")

func _stop_vad() -> void:
	if not vad_manager:
		return
	
	vad_manager.stop_recording()
	is_vad_active = false
	
	vad_status_label.text = "VAD: Stopped"
	vad_status_label.add_theme_color_override("font_color", Color.YELLOW)
	vad_start_btn.disabled = false
	vad_stop_btn.disabled = true
	
	_log_info("⏹️ VAD stopped")
#endregion

#region Deepgram Signal Handlers
func _on_deepgram_connected() -> void:
	_log_success("✅ Connected to Deepgram!")
	_update_connection_ui()

func _on_deepgram_disconnected() -> void:
	_log_info("🔌 Disconnected from Deepgram")
	_update_connection_ui()

func _on_deepgram_error(error_msg: String) -> void:
	_log_error("❌ Deepgram Error: " + error_msg)
	_update_connection_ui()

func _on_transcript_interim(text: String, confidence: float) -> void:
	# Update interim display (real-time)
	interim_label.text = "💭 Interim: " + text
	interim_label.add_theme_color_override("font_color", Color.YELLOW)
	
	# Update confidence bar
	confidence_bar.value = confidence * 100
	confidence_label.text = "Confidence: %.1f%%" % (confidence * 100)
	
	# Color code confidence
	if confidence >= 0.9:
		confidence_bar.modulate = Color.GREEN
	elif confidence >= 0.75:
		confidence_bar.modulate = Color.YELLOW
	else:
		confidence_bar.modulate = Color.ORANGE

func _on_transcript_final(text: String, confidence: float, _words: Array) -> void:
	# Log final transcript (partial)
	_log_transcript("📝 Final (partial): " + text, confidence)

func _on_speech_ended(text: String, confidence: float, _words: Array) -> void:
	# This is the COMPLETE utterance - the key one!
	total_transcripts += 1
	
	# Clear interim display
	interim_label.text = "💭 Interim: (waiting for speech...)"
	interim_label.add_theme_color_override("font_color", Color.GRAY)
	
	# Log complete utterance
	_log_transcript("✅ COMPLETE (#%d): %s" % [total_transcripts, text], confidence)
	
	# Note: Agent integration will be added in a future test mode
#endregion

#region VAD Signal Handlers
func _on_vad_started() -> void:
	_log_info("🟢 Speech detected!")
	vad_status_label.text = "VAD: Speech Detected 🟢"

func _on_vad_audio(pcm_data: PackedByteArray) -> void:
	# Forward audio to Deepgram
	if deepgram.connection_state == 2:  # CONNECTED
		deepgram.send_audio(pcm_data)

func _on_vad_ended() -> void:
	_log_info("🔴 Speech ended")
	vad_status_label.text = "VAD: Listening... 🎤"
#endregion

#region Logging
func _log_info(msg: String) -> void:
	print(msg)
	final_log.text += msg + "\n"
	_scroll_to_bottom()

func _log_success(msg: String) -> void:
	print(msg)
	final_log.text += "[color=green]" + msg + "[/color]\n"
	_scroll_to_bottom()

func _log_error(msg: String) -> void:
	push_error(msg)
	final_log.text += "[color=red]" + msg + "[/color]\n"
	_scroll_to_bottom()

func _log_transcript(msg: String, confidence: float) -> void:
	var color = "green" if confidence >= 0.9 else ("yellow" if confidence >= 0.75 else "orange")
	final_log.text += "[color=%s]%s (conf: %.1f%%)[/color]\n" % [color, msg, confidence * 100]
	_scroll_to_bottom()

func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	final_log.scroll_vertical = INF

func _clear_log() -> void:
	final_log.text = ""
	total_transcripts = 0
#endregion

#region Cleanup
func _exit_tree() -> void:
	_cleanup_vad()
#endregion

#region Utilities
## Load API key from .env file (same logic as LLMManager)
func _load_env_key(key_name: String) -> String:
	var env_path: String = ProjectSettings.globalize_path("res://.env")
	var f: FileAccess = FileAccess.open(env_path, FileAccess.READ)
	if f == null:
		return ""
	
	var result: String = ""
	while not f.eof_reached():
		var line: String = f.get_line()
		# Skip comments and empty lines
		if line.begins_with("#") or line.strip_edges() == "":
			continue
		
		# Parse key=value
		var idx: int = line.find("=")
		if idx == -1:
			continue
		
		var k: String = line.substr(0, idx).strip_edges()
		var v: String = line.substr(idx + 1).strip_edges()
		
		if k == key_name:
			result = v
			break
	
	f.close()
	return result
#endregion
