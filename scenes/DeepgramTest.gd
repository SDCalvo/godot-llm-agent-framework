extends Window
## Test scene for Deepgram STT and VAD → STT → Agent integration
##
## Test Mode 1: Deepgram Only - Tests STT service in isolation
## Test Mode 2: Full Pipeline - Tests VAD → Deepgram → LLM Agent

# Autoload references
var deepgram: Node
var llm_manager: Node

#region Test Mode
enum TestMode {
	DEEPGRAM_ONLY,      ## Test Deepgram STT with simulated audio
	FULL_PIPELINE       ## Test VAD → Deepgram → Agent
}

var current_mode: TestMode = TestMode.DEEPGRAM_ONLY
#endregion

#region UI References
@onready var mode_label: Label = $Panel/VBox/ModePanel/ModeLabel
@onready var mode_toggle_btn: Button = $Panel/VBox/ModePanel/ModeToggleBtn

@onready var status_label: Label = $Panel/VBox/StatusPanel/StatusLabel
@onready var connect_btn: Button = $Panel/VBox/ControlPanel/ConnectBtn
@onready var disconnect_btn: Button = $Panel/VBox/ControlPanel/DisconnectBtn
@onready var test_audio_btn: Button = $Panel/VBox/ControlPanel/TestAudioBtn

@onready var interim_label: Label = $Panel/VBox/TranscriptPanel/InterimLabel
@onready var confidence_bar: ProgressBar = $Panel/VBox/TranscriptPanel/ConfidenceBar
@onready var confidence_label: Label = $Panel/VBox/TranscriptPanel/ConfidenceLabel

@onready var final_log: TextEdit = $Panel/VBox/FinalLogPanel/FinalLog
@onready var clear_log_btn: Button = $Panel/VBox/FinalLogPanel/ClearLogBtn

# VAD/Agent UI (only visible in FULL_PIPELINE mode)
@onready var vad_panel: PanelContainer = $Panel/VBox/VADPanel
@onready var vad_status_label: Label = $Panel/VBox/VADPanel/VBox/VADStatusLabel
@onready var vad_start_btn: Button = $Panel/VBox/VADPanel/VBox/VADControlPanel/VADStartBtn
@onready var vad_stop_btn: Button = $Panel/VBox/VADPanel/VBox/VADControlPanel/VADStopBtn
@onready var agent_response_label: Label = $Panel/VBox/VADPanel/VBox/AgentResponseLabel
#endregion

#region Services
var vad_manager: Node = null
var llm_agent: Node = null
#endregion

#region State
var is_vad_active: bool = false
var total_transcripts: int = 0
#endregion

func _ready() -> void:
	# Get autoload references
	deepgram = get_node("/root/DeepgramSTT")
	llm_manager = get_node("/root/LLMManager")
	
	# Setup window
	title = "Deepgram STT Test Suite"
	
	# Connect UI signals
	mode_toggle_btn.pressed.connect(_toggle_mode)
	connect_btn.pressed.connect(_connect_deepgram)
	disconnect_btn.pressed.connect(_disconnect_deepgram)
	test_audio_btn.pressed.connect(_send_test_audio)
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
	
	# Initial UI state
	_update_mode_ui()
	_update_connection_ui()
	_log_info("🎤 Deepgram STT Test Suite Ready")
	_log_info("📝 Set DEEPGRAM_API_KEY environment variable to test")

func _toggle_mode() -> void:
	if current_mode == TestMode.DEEPGRAM_ONLY:
		current_mode = TestMode.FULL_PIPELINE
		_setup_vad_and_agent()
	else:
		current_mode = TestMode.DEEPGRAM_ONLY
		_cleanup_vad_and_agent()
	
	_update_mode_ui()

func _update_mode_ui() -> void:
	if current_mode == TestMode.DEEPGRAM_ONLY:
		mode_label.text = "Mode: Deepgram Only (Simulated Audio)"
		mode_toggle_btn.text = "Switch to Full Pipeline"
		test_audio_btn.visible = true
		vad_panel.visible = false
	else:
		mode_label.text = "Mode: Full Pipeline (VAD → STT → Agent)"
		mode_toggle_btn.text = "Switch to Deepgram Only"
		test_audio_btn.visible = false
		vad_panel.visible = true

func _update_connection_ui() -> void:
	var state = deepgram.connection_state
	
	match state:
		0:  # DISCONNECTED
			status_label.text = "Status: Disconnected ⚫"
			status_label.add_theme_color_override("font_color", Color.GRAY)
			connect_btn.disabled = false
			disconnect_btn.disabled = true
			test_audio_btn.disabled = true
		
		1:  # CONNECTING
			status_label.text = "Status: Connecting... 🟡"
			status_label.add_theme_color_override("font_color", Color.YELLOW)
			connect_btn.disabled = true
			disconnect_btn.disabled = false
			test_audio_btn.disabled = true
		
		2:  # CONNECTED
			status_label.text = "Status: Connected ✅"
			status_label.add_theme_color_override("font_color", Color.GREEN)
			connect_btn.disabled = true
			disconnect_btn.disabled = false
			test_audio_btn.disabled = false
		
		3:  # ERROR
			status_label.text = "Status: Error ❌"
			status_label.add_theme_color_override("font_color", Color.RED)
			connect_btn.disabled = false
			disconnect_btn.disabled = true
			test_audio_btn.disabled = true

#region Deepgram Connection
func _connect_deepgram() -> void:
	_log_info("🔌 Connecting to Deepgram...")
	
	var api_key = OS.get_environment("DEEPGRAM_API_KEY")
	if api_key.is_empty():
		_log_error("❌ DEEPGRAM_API_KEY not set!")
		_log_error("Set it as an environment variable and restart Godot")
		return
	
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

#region Test Audio (Mode 1: Deepgram Only)
func _send_test_audio() -> void:
	_log_info("🎵 Sending test audio to Deepgram...")
	
	# Generate simulated PCM audio (1 second of sine wave at 440Hz)
	# This won't produce real speech, but will test the connection
	var sample_rate = 48000
	var duration = 1.0
	var frequency = 440.0
	var num_samples = int(sample_rate * duration)
	
	var pcm_data = PackedByteArray()
	pcm_data.resize(num_samples * 2)  # 16-bit = 2 bytes per sample
	
	for i in range(num_samples):
		var time = float(i) / sample_rate
		var sample = sin(2.0 * PI * frequency * time)
		var sample_int = int(clamp(sample * 32767.0, -32768.0, 32767.0))
		
		# Little-endian 16-bit
		pcm_data[i * 2] = sample_int & 0xFF
		pcm_data[i * 2 + 1] = (sample_int >> 8) & 0xFF
	
	deepgram.send_audio(pcm_data)
	_log_info("✅ Sent %d bytes of test audio" % pcm_data.size())
#endregion

#region VAD Setup (Mode 2: Full Pipeline)
func _setup_vad_and_agent() -> void:
	_log_info("🎤 Setting up VAD and Agent...")
	
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
	
	# Create LLM Agent
	llm_agent = llm_manager.create_agent({
		"model": "gpt-4o-mini",
		"system_prompt": "You are a helpful voice assistant. Keep responses concise (1-2 sentences)."
	}, [])
	
	# Connect agent signals
	llm_agent.finished.connect(_on_agent_finished)
	llm_agent.error.connect(_on_agent_error)
	
	vad_status_label.text = "VAD: Ready (Not Started)"
	vad_status_label.add_theme_color_override("font_color", Color.YELLOW)
	vad_start_btn.disabled = false
	vad_stop_btn.disabled = true
	
	_log_info("✅ VAD and Agent ready!")

func _cleanup_vad_and_agent() -> void:
	if is_vad_active:
		_stop_vad()
	
	if vad_manager:
		vad_manager.queue_free()
		vad_manager = null
	
	llm_agent = null
	
	_log_info("🧹 Cleaned up VAD and Agent")

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
	
	# If in full pipeline mode, send to agent
	if current_mode == TestMode.FULL_PIPELINE and llm_agent:
		_send_to_agent(text)
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

#region Agent Integration
func _send_to_agent(transcript: String) -> void:
	_log_info("🤖 Sending to agent: " + transcript)
	agent_response_label.text = "Agent: Thinking... 🤔"
	agent_response_label.add_theme_color_override("font_color", Color.YELLOW)
	
	# Create message
	var MessageClass = load("res://addons/godot_llm/runtime/llm_message/Message.gd")
	llm_agent.ainvoke([MessageClass.user_simple(transcript)])

func _on_agent_finished(_run_id: String, ok: bool, result: Dictionary) -> void:
	if ok:
		var response = result.get("content", "")
		_log_success("🤖 Agent: " + response)
		agent_response_label.text = "Agent: " + response
		agent_response_label.add_theme_color_override("font_color", Color.GREEN)
	else:
		var error_msg = result.get("error", "Unknown error")
		_log_error("🤖 Agent Error: " + error_msg)
		agent_response_label.text = "Agent: Error ❌"
		agent_response_label.add_theme_color_override("font_color", Color.RED)

func _on_agent_error(_run_id: String, error_dict: Dictionary) -> void:
	_log_error("🤖 Agent Error: " + str(error_dict))
	agent_response_label.text = "Agent: Error ❌"
	agent_response_label.add_theme_color_override("font_color", Color.RED)
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
	_cleanup_vad_and_agent()
#endregion

