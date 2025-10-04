extends Control

## Test script for VADManager - Tests speech detection without STT integration

@onready var vad_manager: VADManager = null
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var speech_prob_label: Label = $VBoxContainer/SpeechProbLabel
@onready var output_log: TextEdit = $VBoxContainer/OutputLog
@onready var start_btn: Button = $VBoxContainer/HBoxContainer/StartButton
@onready var stop_btn: Button = $VBoxContainer/HBoxContainer/StopButton
@onready var clear_btn: Button = $VBoxContainer/HBoxContainer/ClearButton

var total_speech_chunks: int = 0
var total_pcm_bytes: int = 0

func _ready():
	print("=== VAD Test Starting ===")
	
	# Create VADManager
	vad_manager = VADManager.new()
	add_child(vad_manager)
	
	# Connect signals
	vad_manager.speech_started.connect(_on_speech_started)
	vad_manager.speech_ended.connect(_on_speech_ended)
	vad_manager.speech_detected.connect(_on_speech_detected)
	
	# Setup VAD
	var setup_result = vad_manager.setup()
	if setup_result != VADManager.SetupError.OK:
		_log_error("VAD setup failed with error code: %d" % setup_result)
		_log_error("")
		_log_error("📋 HOW TO FIX:")
		_log_error("1. Go to: Project → Project Settings")
		_log_error("2. Navigate to: Audio → Driver")
		_log_error("3. Enable: 'Enable Input' checkbox")
		_log_error("4. Click 'Close'")
		_log_error("5. RESTART this scene (or Godot)")
		_log_error("")
		_log_error("The setting may have been auto-enabled - just restart!")
		status_label.text = "Status: SETUP FAILED - Enable Microphone & Restart ❌"
		status_label.add_theme_color_override("font_color", Color.RED)
		start_btn.disabled = true
		return
	
	_log("✅ VAD setup successful!")
	status_label.text = "Status: Ready"
	stop_btn.disabled = true
	
	# Connect buttons
	start_btn.pressed.connect(_on_start_pressed)
	stop_btn.pressed.connect(_on_stop_pressed)
	clear_btn.pressed.connect(_on_clear_pressed)

func _process(_delta):
	if vad_manager and vad_manager.is_currently_recording():
		# Update speech probability display
		var prob = vad_manager.get_current_speech_probability() if vad_manager.opuschunked and vad_manager.opuschunked.chunk_available() else 0.0
		speech_prob_label.text = "Speech Probability: %.2f%% (Threshold: %.0f%%)" % [prob * 100.0, vad_manager.vad_threshold * 100.0]
		
		# Color-code based on threshold
		if prob >= vad_manager.vad_threshold:
			speech_prob_label.add_theme_color_override("font_color", Color.GREEN)
		else:
			speech_prob_label.add_theme_color_override("font_color", Color.WHITE)

func _on_start_pressed():
	_log("🎤 Starting recording...")
	vad_manager.start_recording()
	status_label.text = "Status: Recording 🔴"
	status_label.add_theme_color_override("font_color", Color.ORANGE)
	start_btn.disabled = true
	stop_btn.disabled = false
	
	total_speech_chunks = 0
	total_pcm_bytes = 0

func _on_stop_pressed():
	_log("⏹️ Stopping recording...")
	vad_manager.stop_recording()
	status_label.text = "Status: Stopped"
	status_label.add_theme_color_override("font_color", Color.WHITE)
	start_btn.disabled = false
	stop_btn.disabled = true
	
	_log("📊 Session stats: %d speech chunks, %d total PCM bytes (%.2f KB)" % [total_speech_chunks, total_pcm_bytes, total_pcm_bytes / 1024.0])

func _on_clear_pressed():
	output_log.text = ""

func _on_speech_started():
	_log("🟢 SPEECH STARTED")
	status_label.text = "Status: Recording 🔴 | SPEECH DETECTED"
	status_label.add_theme_color_override("font_color", Color.GREEN)

func _on_speech_ended():
	_log("🔴 SPEECH ENDED")
	status_label.text = "Status: Recording 🔴 | Listening..."
	status_label.add_theme_color_override("font_color", Color.ORANGE)

func _on_speech_detected(pcm_data: PackedByteArray):
	total_speech_chunks += 1
	total_pcm_bytes += pcm_data.size()
	
	# Log every 50 chunks to avoid spam
	if total_speech_chunks % 50 == 0:
		_log("  📦 Speech chunk #%d (%d bytes, total: %.2f KB)" % [total_speech_chunks, pcm_data.size(), total_pcm_bytes / 1024.0])

func _log(message: String):
	print("[VADTest] " + message)
	output_log.text += message + "\n"
	# Auto-scroll to bottom
	output_log.scroll_vertical = int(output_log.get_line_count())

func _log_error(message: String):
	print("[VADTest ERROR] " + message)
	output_log.text += "[ERROR] " + message + "\n"
	output_log.scroll_vertical = int(output_log.get_line_count())

