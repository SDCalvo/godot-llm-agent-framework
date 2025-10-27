extends Window
## E2E Voice Pipeline Test
##
## Tests complete voice assistant pipeline:
## Microphone → VAD → Deepgram STT → LLM Agent → Tools → ElevenLabs TTS → Audio
##
## Simple "Shape Commander" - speak commands to spawn colored shapes

const MessageClass = preload("res://addons/godot_llm/runtime/llm_messages/LLMMessage.gd")
const ElevenLabsWrapperScript = preload("res://addons/godot_llm/runtime/audio_services/elevenlabs_wrapper/ElevenLabsWrapper.gd")
const LLMToolRegistryScript = preload("res://addons/godot_llm/runtime/llm_tool_registry/LLMToolRegistry.gd")

#region Pipeline State
enum PipelineState {
	IDLE,
	VAD_LISTENING,
	STT_PROCESSING,
	LLM_THINKING,
	TOOL_EXECUTING,
	TTS_SPEAKING
}

var current_state: PipelineState = PipelineState.IDLE
#endregion

#region Services
var deepgram: Node
var llm_manager: Node
var elevenlabs: Node
var vad_manager: Node  # VADManager instance
var agent: Node  # LLMAgent instance
var tts_player: Node  # RealtimePCMPlayer instance
#endregion

#region UI References - Debug Panel
@onready var vad_label: Label = $HBox/DebugPanel/VBox/PipelineStatus/VADLabel
@onready var stt_label: Label = $HBox/DebugPanel/VBox/PipelineStatus/STTLabel
@onready var llm_label: Label = $HBox/DebugPanel/VBox/PipelineStatus/LLMLabel
@onready var tool_label: Label = $HBox/DebugPanel/VBox/PipelineStatus/ToolLabel
@onready var tts_label: Label = $HBox/DebugPanel/VBox/PipelineStatus/TTSLabel

@onready var transcript_log: RichTextLabel = $HBox/DebugPanel/VBox/TranscriptPanel/TranscriptLog
@onready var llm_log: RichTextLabel = $HBox/DebugPanel/VBox/LLMPanel/LLMLog
@onready var tools_log: RichTextLabel = $HBox/DebugPanel/VBox/ToolsPanel/ToolsLog

@onready var clear_shapes_btn: Button = $HBox/DebugPanel/VBox/ButtonsPanel/ClearShapesBtn
@onready var clear_log_btn: Button = $HBox/DebugPanel/VBox/ButtonsPanel/ClearLogBtn
#endregion

#region UI References - Game World
@onready var shapes_container: Node2D = $HBox/GameWorld/SubViewportContainer/SubViewport/World/ShapesContainer
@onready var robot: Label = $HBox/GameWorld/SubViewportContainer/SubViewport/World/Robot
@onready var speech_bubble: PanelContainer = $HBox/GameWorld/SubViewportContainer/SubViewport/World/SpeechBubble
@onready var bubble_text: Label = $HBox/GameWorld/SubViewportContainer/SubViewport/World/SpeechBubble/BubbleText
#endregion

#region State
var current_bubble_text: String = ""
var last_deepgram_state: int = -1
var audio_chunks_sent: int = 0
#endregion

func _ready() -> void:
	print("=== E2E Voice Pipeline Test Starting ===")
	
	# Connect UI buttons
	clear_shapes_btn.pressed.connect(_clear_all_shapes)
	clear_log_btn.pressed.connect(_clear_logs)
	
	# Setup services
	await _setup_services()
	
	# Register tool
	_register_shape_tool()
	
	# Create agent
	_create_agent()
	
	# Start listening
	vad_manager.start_recording()
	_update_pipeline_state(PipelineState.VAD_LISTENING)
	
	print("=== E2E Test Ready - Speak to spawn shapes! ===")

#region Service Setup
func _setup_services() -> void:
	print("E2E: Setting up services...")
	
	# Get autoloads
	deepgram = get_node("/root/DeepgramSTT")
	llm_manager = get_node("/root/LLMManager")
	elevenlabs = get_node("/root/ElevenLabsWrapper")
	
	# 1. Setup VAD
	print("E2E: Setting up VAD...")
	vad_manager = preload("res://addons/godot_llm/runtime/audio_services/vad/VADManager.gd").new()
	
	# Connect signals
	vad_manager.speech_started.connect(_on_vad_started)
	vad_manager.speech_detected.connect(_on_vad_audio)
	vad_manager.speech_ended.connect(_on_vad_ended)
	
	# Add to tree (auto-calls setup in _ready)
	add_child(vad_manager)
	
	print("E2E: VAD configured with grace_period=%dms (matches Deepgram endpointing)" % vad_manager.grace_period_ms)
	
	# 2. Setup Deepgram
	print("E2E: Setting up Deepgram...")
	
	# Disconnect if already connected
	if deepgram.connection_state != 0:
		print("E2E: Disconnecting existing Deepgram connection...")
		deepgram.disconnect_from_deepgram()
		
		var wait_count = 0
		while deepgram.connection_state != 0 and wait_count < 50:
			await get_tree().create_timer(0.1).timeout
			wait_count += 1
	
	var deepgram_key = _load_env_key("DEEPGRAM_API_KEY")
	if deepgram_key.is_empty():
		push_error("E2E: DEEPGRAM_API_KEY not set!")
		return
	
	# Disconnect old signal handlers
	if deepgram.transcript_interim.is_connected(_on_transcript_interim):
		deepgram.transcript_interim.disconnect(_on_transcript_interim)
	if deepgram.transcript_final.is_connected(_on_transcript_final):
		deepgram.transcript_final.disconnect(_on_transcript_final)
	if deepgram.speech_ended.is_connected(_on_speech_ended):
		deepgram.speech_ended.disconnect(_on_speech_ended)
	
	# Connect signals
	deepgram.transcript_interim.connect(_on_transcript_interim)
	deepgram.transcript_final.connect(_on_transcript_final)
	deepgram.speech_ended.connect(_on_speech_ended)
	
	# Initialize
	deepgram.initialize(deepgram_key, {
		"model": "nova-3",
		"interim_results": true,
		"smart_format": true,
		"endpointing": 300
	})
	
	# Connect
	var err = deepgram.connect_to_deepgram()
	if err != OK:
		push_error("E2E: Failed to connect to Deepgram")
		return
	
	# Wait for connection
	while deepgram.connection_state != 2:
		await get_tree().create_timer(0.1).timeout
	
	print("E2E: Deepgram connected!")
	
	# 3. Setup TTS
	print("E2E: Setting up ElevenLabs...")
	
	# Set to REAL_TIME mode
	ElevenLabsWrapper.set_streaming_mode(ElevenLabsWrapper.StreamingMode.REAL_TIME)
	
	var voice_id = "EXAVITQu4vr4xnSDxMaL"  # Bella
	
	# Destroy if exists
	if ElevenLabsWrapper.character_contexts.has("npc"):
		ElevenLabsWrapper.destroy_character_context("npc")
	
	await ElevenLabsWrapper.create_character_context("npc", voice_id)
	tts_player = await ElevenLabsWrapperScript.create_realtime_player(self, "npc")
	
	print("E2E: All services ready!")
#endregion

#region Tool Registration
func _register_shape_tool() -> void:
	print("E2E: Registering spawn_shape tool...")
	
	LLMToolRegistry.create("spawn_shape")\
		.description("Spawn a colored shape at specific coordinates in the game world")\
		.param("shape_type", "string", "Shape type: circle, square, or triangle")\
		.param("x", "number", "X coordinate (0-720)")\
		.param("y", "number", "Y coordinate (0-700)")\
		.param("color", "string", "Color: red, blue, green, yellow, purple, orange")\
		.param("size", "number", "Size in pixels (default 30)", 30)\
		.handler(LLMToolRegistryScript.thread_safe_node_handler(self, "_tool_spawn_shape"))\
		.register()
#endregion

#region Agent Creation
func _create_agent() -> void:
	print("E2E: Creating agent...")
	
	var tools = [
		LLMToolRegistry.get_by_name("spawn_shape")
	]
	
	agent = llm_manager.create_agent({
		"model": "gpt-4o-mini",
		"system_prompt": "You are a helpful Shape Commander assistant. You can spawn colored shapes at coordinates. When the user asks you to create shapes, use the spawn_shape tool. Keep responses concise and friendly."
	}, tools)
	
	agent.delta.connect(_on_agent_delta)
	agent.finished.connect(_on_agent_finished)
	agent.debug.connect(_on_agent_debug)
	
	print("E2E: Agent ready!")
#endregion

#region Pipeline Event Handlers
func _on_vad_started() -> void:
	print("E2E: [VAD] Speech started")
	_update_pipeline_state(PipelineState.STT_PROCESSING)

func _on_vad_audio(pcm_data: PackedByteArray) -> void:
	# Log connection state changes
	if deepgram.connection_state != last_deepgram_state:
		print("E2E: [DEEPGRAM] Connection state changed: %d → %d" % [last_deepgram_state, deepgram.connection_state])
		last_deepgram_state = deepgram.connection_state
	
	# Only send if connected
	if deepgram.connection_state == 2:  # CONNECTED
		audio_chunks_sent += 1
		if audio_chunks_sent == 1 or audio_chunks_sent % 20 == 0:
			print("E2E: [VAD→STT] Sent %d audio chunks" % audio_chunks_sent)
		deepgram.send_audio(pcm_data)

func _on_vad_ended() -> void:
	print("E2E: [VAD] Speech ended, sending Finalize to Deepgram...")
	deepgram.send_finalize()
	audio_chunks_sent = 0

func _on_transcript_interim(text: String, confidence: float) -> void:
	print("E2E: [STT] Interim: '%s' (%.1f%%)" % [text, confidence * 100])

func _on_transcript_final(text: String, confidence: float, _words: Array) -> void:
	print("E2E: [STT→LLM] ✅ FINAL: '%s' (%.1f%%)" % [text, confidence * 100])
	_log_transcript(text, confidence)
	_update_pipeline_state(PipelineState.LLM_THINKING)
	
	# Send to LLM
	agent.ainvoke(MessageClass.user_simple(text))

func _on_speech_ended(text: String, confidence: float, _words: Array) -> void:
	print("E2E: [STT] Complete utterance: '%s'" % text)

func _on_agent_delta(_run_id, text_delta: String) -> void:
	# Stream to TTS
	ElevenLabsWrapper.feed_text_to_character("npc", text_delta)
	
	# Update speech bubble
	_append_to_speech_bubble(text_delta)
	
	# Log
	_log_llm_output(text_delta)

func _on_agent_debug(_run_id, event: Dictionary) -> void:
	var event_type = event.get("type", "")
	
	if event_type == "tool_calls":
		_update_pipeline_state(PipelineState.TOOL_EXECUTING)
		var calls = event.get("calls", [])
		for tool_call in calls:
			_log_tool_call(tool_call.get("name", ""), tool_call.get("arguments", {}))

func _on_agent_finished(_run_id, ok: bool, result: Dictionary) -> void:
	print("E2E: [LLM] Agent finished, ok=%s" % ok)
	
	if ok:
		# That's it. Just let TTS do its thing.
		# The player is already receiving chunks from _on_agent_delta
		pass
	else:
		_log_error("Agent error: " + str(result.get("error", "")))

func _on_synthesis_completed(context_id: String) -> void:
	if context_id == "npc":
		print("E2E: [TTS] Synthesis completed")

func _on_synthesis_error(context_id: String, error: Dictionary) -> void:
	if context_id == "npc":
		print("E2E: [TTS] ERROR: ", error)

func _on_tts_finished(context_id: String) -> void:
	if context_id == "npc":
		print("E2E: [TTS] Playback finished")
		_hide_speech_bubble()
		_update_pipeline_state(PipelineState.VAD_LISTENING)
#endregion

#region Tool Implementation
func _tool_spawn_shape(args: Dictionary) -> Dictionary:
	var shape_type = args.get("shape_type", "circle")
	var x = float(args.get("x", 360))
	var y = float(args.get("y", 350))
	var color_name = args.get("color", "blue")
	var shape_size = float(args.get("size", 30))
	
	var color = _parse_color(color_name)
	var shape_id = _create_shape(shape_type, Vector2(x, y), color, shape_size)
	
	var result = {
		"ok": true,
		"shape_id": shape_id,
		"message": "Created %s %s at position (%.0f, %.0f)" % [color_name, shape_type, x, y]
	}
	
	_log_tool_result("spawn_shape", result)
	
	return result
#endregion

#region Shape Creation
func _create_shape(_type: String, pos: Vector2, color: Color, shape_size: float) -> String:
	var shape = ColorRect.new()
	shape.size = Vector2(shape_size, shape_size)
	shape.position = pos - Vector2(shape_size/2, shape_size/2)
	shape.color = color
	shape.name = "Shape_" + str(shapes_container.get_child_count())
	shapes_container.add_child(shape)
	return shape.name

func _parse_color(color_name: String) -> Color:
	match color_name.to_lower():
		"red": return Color.RED
		"blue": return Color.BLUE
		"green": return Color.GREEN
		"yellow": return Color.YELLOW
		"purple": return Color.PURPLE
		"orange": return Color.ORANGE
		_: return Color.WHITE

func _clear_all_shapes() -> void:
	for child in shapes_container.get_children():
		child.queue_free()
#endregion

#region Speech Bubble
func _append_to_speech_bubble(text: String) -> void:
	current_bubble_text += text
	bubble_text.text = current_bubble_text
	speech_bubble.visible = true

func _hide_speech_bubble() -> void:
	speech_bubble.visible = false
	current_bubble_text = ""
	bubble_text.text = ""
#endregion

#region Pipeline Visualization
func _update_pipeline_state(new_state: PipelineState) -> void:
	current_state = new_state
	
	var grey = Color(0.5, 0.5, 0.5)
	var white = Color.WHITE
	
	# Reset all
	vad_label.modulate = grey
	stt_label.modulate = grey
	llm_label.modulate = grey
	tool_label.modulate = grey
	tts_label.modulate = grey
	
	# Highlight active
	match current_state:
		PipelineState.VAD_LISTENING:
			vad_label.modulate = white
		PipelineState.STT_PROCESSING:
			vad_label.modulate = white
			stt_label.modulate = white
		PipelineState.LLM_THINKING:
			llm_label.modulate = white
		PipelineState.TOOL_EXECUTING:
			llm_label.modulate = white
			tool_label.modulate = white
		PipelineState.TTS_SPEAKING:
			tts_label.modulate = white
#endregion

#region Debug Logging
func _log_transcript(text: String, confidence: float) -> void:
	transcript_log.append_text("[color=green]STT (%.1f%%):[/color] %s\n" % [confidence * 100, text])

func _log_llm_output(text: String) -> void:
	llm_log.append_text(text)

func _log_tool_call(tool_name: String, args: Dictionary) -> void:
	tools_log.append_text("[color=yellow]CALL:[/color] %s(%s)\n" % [tool_name, JSON.stringify(args)])

func _log_tool_result(tool_name: String, result: Dictionary) -> void:
	tools_log.append_text("[color=cyan]RESULT:[/color] %s → %s\n" % [tool_name, JSON.stringify(result)])

func _log_debug(msg: String) -> void:
	tools_log.append_text("[color=gray]%s[/color]\n" % msg)

func _log_error(msg: String) -> void:
	tools_log.append_text("[color=red]ERROR: %s[/color]\n" % msg)

func _clear_logs() -> void:
	transcript_log.clear()
	llm_log.clear()
	tools_log.clear()
#endregion

#region Utilities
func _load_env_key(key_name: String) -> String:
	var env_path = ProjectSettings.globalize_path("res://.env")
	var f = FileAccess.open(env_path, FileAccess.READ)
	if not f:
		return ""
	
	var result = ""
	while not f.eof_reached():
		var line = f.get_line()
		if line.begins_with("#") or line.strip_edges() == "":
			continue
		var idx = line.find("=")
		if idx == -1:
			continue
		var k = line.substr(0, idx).strip_edges()
		var v = line.substr(idx + 1).strip_edges()
		if k == key_name:
			result = v
			break
	f.close()
	return result
#endregion

#region Cleanup
func _exit_tree() -> void:
	print("E2E: Cleaning up...")
	
	if vad_manager:
		vad_manager.stop_recording()
		vad_manager.queue_free()
	
	if tts_player:
		tts_player.cleanup()
	
	print("E2E: Cleanup complete")
#endregion

