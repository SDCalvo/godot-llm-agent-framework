extends CanvasLayer

const OpenAIWrapper = preload("res://addons/godot_llm/runtime/openai_wrapper/OpenAIWrapper.gd")
var LLMAgentClass: Script = load("res://addons/godot_llm/runtime/llm_agent/LLMAgent.gd")
const LLMToolClass = preload("res://addons/godot_llm/runtime/llm_tools/LLMTool.gd")
const MessageClass = preload("res://addons/godot_llm/runtime/llm_messages/LLMMessage.gd")
const EmailSystemTest = preload("res://scenes/EmailSystemTest.gd")
const AsyncEmailTest = preload("res://scenes/AsyncEmailTest.gd")

# Core components
var wrapper: OpenAIWrapper
var agent: LLMAgent
var demo_tools: Array = []
var email_test: EmailSystemTest
var async_email_test: AsyncEmailTest

# UI references
var console_output: RichTextLabel
var clear_btn: Button
var copy_btn: Button

# Test buttons
var wrapper_call_btn: Button
var wrapper_stream_btn: Button
var agent_invoke_btn: Button
var agent_stream_btn: Button
var builder_tools_btn: Button
var spawn_entity_btn: Button
var calc_distance_btn: Button
var random_color_btn: Button
var email_test_btn: Button
var async_email_test_btn: Button

# State tracking
var current_stream_id: String = ""
var current_agent_run_id: String = ""

func _ready() -> void:
	log_info("🚀 LLM Test Suite Starting...")
	
	# Setup world elements
	_setup_world()
	
	# Get UI references
	_setup_ui_references()
	
	# Setup OpenAI wrapper
	_setup_wrapper()
	
	# Setup builder tools
	_setup_builder_tools()
	
	# Setup agent
	_setup_agent()
	
	# Setup audio services
	_setup_audio_services()
	
	# Setup email test
	_setup_email_test()
	
	# Connect all test buttons
	_connect_test_buttons()
	
	log_success("✅ Test suite ready! Use buttons to run tests.")

func _setup_ui_references() -> void:
	console_output = $UIContainer/OutputConsole/ConsoleContainer/ConsoleOutput
	clear_btn = $UIContainer/OutputConsole/ConsoleContainer/ConsoleControls/ClearBtn
	copy_btn = $UIContainer/OutputConsole/ConsoleContainer/ConsoleControls/CopyBtn
	
	wrapper_call_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/WrapperCallBtn"
	wrapper_stream_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/WrapperStreamBtn"
	agent_invoke_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/AgentInvokeBtn"
	agent_stream_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/AgentStreamBtn"
	builder_tools_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/BuilderToolsBtn"
	spawn_entity_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/SpawnEntityBtn"
	calc_distance_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/CalcDistanceBtn"
	random_color_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/RandomColorBtn"
	email_test_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/EmailTestBtn"
	async_email_test_btn = $"UIContainer/TestButtonsPanel/ButtonGrid/AsyncEmailTestBtn"
	
	# Connect console controls
	clear_btn.pressed.connect(func(): console_output.text = "")
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(console_output.get_parsed_text()))

func _setup_world() -> void:
	var grid_node = get_node("../World/Grid")
	if grid_node == null:
		return
	
	log_info("🌐 Setting up infinite grid...")
	
	# Create grid pattern
	var grid_size = 100
	var grid_extent = 2000
	
	for x in range(-grid_extent, grid_extent + 1, grid_size):
		var line = Line2D.new()
		line.add_point(Vector2(x, -grid_extent))
		line.add_point(Vector2(x, grid_extent))
		line.default_color = Color(0.3, 0.3, 0.3, 0.5)
		line.width = 1
		grid_node.add_child(line)
	
	for y in range(-grid_extent, grid_extent + 1, grid_size):
		var line = Line2D.new()
		line.add_point(Vector2(-grid_extent, y))
		line.add_point(Vector2(grid_extent, y))
		line.default_color = Color(0.3, 0.3, 0.3, 0.5)
		line.width = 1
		grid_node.add_child(line)

func _setup_wrapper() -> void:
	wrapper = OpenAIWrapper.new()
	add_child(wrapper)
	
	var key := OS.get_environment("OPENAI_API_KEY")
	if key == "":
		key = _load_env_key("OPENAI_API_KEY")
	if key == "":
		log_error("❌ Missing OPENAI_API_KEY (env or .env)")
		return
	
	wrapper.set_api_key(key)
	
	var model := OS.get_environment("OPENAI_MODEL")
	if model == "":
		model = _load_env_key("OPENAI_MODEL")
	if model != "":
		wrapper.set_default_model(model)
	
	# Connect streaming signals
	wrapper.stream_started.connect(_on_stream_started)
	wrapper.stream_delta_text.connect(_on_stream_delta)
	wrapper.stream_finished.connect(_on_stream_finished)
	wrapper.stream_error.connect(_on_stream_error)
	wrapper.stream_tool_call_done.connect(_on_stream_tool_call_done)
	
	log_success("✅ OpenAI Wrapper configured")

func _setup_builder_tools() -> void:
	log_info("🔧 Setting up builder pattern tools...")
	
	# Thread-safe tool registration using helper functions
	
	# Simple computational tools (naturally thread-safe)
	LLMToolRegistry.create("calculate_distance")\
		.description("Calculate distance between two 2D points")\
		.param("x1", "float", "X coordinate of first point")\
		.param("y1", "float", "Y coordinate of first point")\
		.param("x2", "float", "X coordinate of second point")\
		.param("y2", "float", "Y coordinate of second point")\
		.handler(LLMToolRegistry.simple_handler(calculate_distance))\
		.register()
	
	LLMToolRegistry.create("generate_random_color")\
		.description("Generate a random color with optional alpha")\
		.param("alpha", "float", "Alpha value for transparency", 1.0)\
		.handler(LLMToolRegistry.simple_handler(generate_random_color))\
		.register()
	
	# Node access tools (require thread-safe wrapper)
	LLMToolRegistry.create("get_world_info")\
		.description("Get information about the current game world")\
		.handler(LLMToolRegistry.thread_safe_node_handler(self, "get_world_info"))\
		.register()
	
	LLMToolRegistry.create("spawn_entity")\
		.description("Spawn a new entity in the game world")\
		.param("entity_type", "string", "Type of entity to spawn")\
		.param("position_x", "float", "X position", 0.0)\
		.param("position_y", "float", "Y position", 0.0)\
		.handler(LLMToolRegistry.thread_safe_node_handler(self, "spawn_entity_impl"))\
		.register()
	demo_tools = LLMToolRegistry.get_all()
	
	log_success("✅ Builder tools registered: " + str(demo_tools.size()) + " tools")

func _setup_agent() -> void:
	var hyper := {
		"model": "gpt-4o-mini",
		"temperature": 0.2,
		"system_prompt": "You are a helpful test assistant. After using tools, provide a text explanation.",
		"max_output_tokens": 256
	}
	
	var mgr = null
	if typeof(LLMManager) != TYPE_NIL:
		mgr = LLMManager
	if mgr != null and mgr.has_method("create_agent"):
		agent = mgr.create_agent(hyper, demo_tools)
	else:
		agent = LLMAgentClass.create(demo_tools, hyper)
	
	# Connect agent signals
	if agent != null:
		agent.delta.connect(func(run_id: String, delta: String):
			if run_id == current_agent_run_id:
				log_stream(delta))
		agent.finished.connect(func(run_id: String, ok: bool, _result: Dictionary):
			if run_id == current_agent_run_id:
				current_agent_run_id = ""
				log_success("✅ Agent finished: " + str(ok)))
		agent.error.connect(func(run_id: String, err: Dictionary):
			if run_id == current_agent_run_id:
				current_agent_run_id = ""
				log_error("❌ Agent error: " + JSON.stringify(err)))
	
	log_success("✅ Agent configured")

func _setup_audio_services() -> void:
	log_info("🎤 Setting up audio services...")
	
	# Setup OpenAI STT
	var openai_key := OS.get_environment("OPENAI_API_KEY")
	if openai_key == "":
		openai_key = _load_env_key("OPENAI_API_KEY")
	
	if openai_key != "":
		OpenAISTT.initialize(openai_key)
		log_success("✅ OpenAI STT configured")
	else:
		log_warning("⚠️ OpenAI STT not configured - missing OPENAI_API_KEY")
	
	# Setup ElevenLabs TTS
	var elevenlabs_key := OS.get_environment("ELEVENLABS_API_KEY")
	if elevenlabs_key == "":
		elevenlabs_key = _load_env_key("ELEVENLABS_API_KEY")
	
	if elevenlabs_key != "":
		ElevenLabsWrapper.initialize(elevenlabs_key)
		log_success("✅ ElevenLabs TTS configured")
	else:
		log_warning("⚠️ ElevenLabs TTS not configured - missing ELEVENLABS_API_KEY")
	
	# Setup Audio Manager
	# AudioManager doesn't need API keys - it handles local audio I/O
	log_success("✅ AudioManager ready")
	
	log_success("✅ Audio services initialized")

func _setup_email_test() -> void:
	email_test = EmailSystemTest.new()
	add_child(email_test)
	email_test.test_completed.connect(_on_email_test_completed)
	email_test.test_progress.connect(_on_email_test_progress)
	
	async_email_test = AsyncEmailTest.new()
	add_child(async_email_test)
	async_email_test.test_completed.connect(_on_async_email_test_completed)
	async_email_test.test_progress.connect(_on_async_email_test_progress)
	
	log_info("Email system tests initialized")

func _connect_test_buttons() -> void:
	wrapper_call_btn.pressed.connect(_test_wrapper_call)
	wrapper_stream_btn.pressed.connect(_test_wrapper_stream)
	agent_invoke_btn.pressed.connect(_test_agent_invoke)
	agent_stream_btn.pressed.connect(_test_agent_stream)
	builder_tools_btn.pressed.connect(_test_builder_tools)
	spawn_entity_btn.pressed.connect(_test_spawn_entity)
	calc_distance_btn.pressed.connect(_test_calc_distance)
	random_color_btn.pressed.connect(_test_random_color)
	email_test_btn.pressed.connect(_test_email_system)
	async_email_test_btn.pressed.connect(_test_async_email_system)

# =============================================================================
# TEST FUNCTIONS
# =============================================================================

func _test_wrapper_call() -> void:
	log_test("🔧 Testing Wrapper Direct Call...")
	var messages := [wrapper.make_text_message("user", "Reply with a short greeting.")]
	var options := {"temperature": 0.2, "max_output_tokens": 100}
	
	var result: Dictionary = await wrapper.create_response(messages, [], options)
	match String(result.get("status", "")):
		"assistant":
			log_success("✅ Wrapper call successful: " + String(result.get("assistant_text", "")))
		"error":
			log_error("❌ Wrapper error: " + JSON.stringify(result.get("error", {})))
		_:
			log_warning("⚠️ Unexpected result: " + String(result.get("status", "")))

func _test_wrapper_stream() -> void:
	log_test("🌊 Testing Wrapper Streaming...")
	var messages := [wrapper.make_text_message("user", "Stream a short greeting.")]
	var options := {"model": "gpt-4o-mini", "temperature": 0.2}
	current_stream_id = wrapper.stream_response_start(messages, [], options)

func _test_agent_invoke() -> void:
	log_test("🤖 Testing Agent Invoke...")
	var msgs := []
	msgs += Message.system_simple("You are helpful. After using tools, explain what you did.")
	msgs += Message.user_simple("Use spawn_entity to create a 'TestBot' at (100,100), then calculate distance from (0,0) to (100,100).")
	
	var res: Dictionary = await agent.invoke(msgs)
	if bool(res.get("ok", false)):
		log_success("✅ Agent invoke: " + String(res.get("text", "")))
	else:
		log_error("❌ Agent error: " + JSON.stringify(res.get("error", res)))

func _test_agent_stream() -> void:
	log_test("🌊🤖 Testing Agent Streaming...")
	var msgs := []
	msgs += Message.system_simple("You are a helpful assistant. ALWAYS provide a text response after using tools to explain what you accomplished.")
	msgs += Message.user_simple("Get world info, generate a random color, then spawn a 'StreamBot' at (200,200). After completing these tasks, write a summary of what you did.")
	current_agent_run_id = agent.ainvoke(msgs)

func _test_builder_tools() -> void:
	log_test("🔧 Testing Builder Tools Registration...")
	log_info("Registered tools:")
	for tool in LLMToolRegistry.get_all():
		log_info("  • " + tool.name + ": " + tool.description)

func _test_spawn_entity() -> void:
	log_test("👾 Testing Entity Spawning...")
	var result = spawn_entity_impl({"entity_type": "ManualTestEntity", "position_x": randf_range(-200, 200), "position_y": randf_range(-200, 200)})
	log_success("✅ " + result.message)

func _test_calc_distance() -> void:
	log_test("📏 Testing Distance Calculation...")
	var tool = LLMToolRegistry.get_by_name("calculate_distance")
	if tool:
		var result = tool.execute({"x1": 0, "y1": 0, "x2": 100, "y2": 100})
		log_success("✅ Distance: " + str(result.distance) + " units")
	else:
		log_error("❌ Distance tool not found")

func _test_random_color() -> void:
	log_test("🎨 Testing Random Color Generation...")
	var tool = LLMToolRegistry.get_by_name("generate_random_color")
	if tool:
		var result = tool.execute({"alpha": 0.8})
		log_success("✅ Color: " + result.hex + " (RGBA: " + str(result.color) + ")")
	else:
		log_error("❌ Color tool not found")

# =============================================================================
# SIGNAL HANDLERS
# =============================================================================

func _on_stream_started(id: String, response_id: String) -> void:
	if id == current_stream_id:
		log_info("📡 Stream started: " + response_id)

func _on_stream_delta(id: String, delta: String) -> void:
	if id == current_stream_id:
		log_stream(delta)

func _on_stream_finished(id: String, ok: bool, final_text: String, _usage: Dictionary) -> void:
	if id == current_stream_id:
		current_stream_id = ""
		log_success("✅ Stream finished: " + str(ok) + " (" + str(final_text.length()) + " chars)")

func _on_stream_error(id: String, error: Dictionary) -> void:
	if id == current_stream_id:
		current_stream_id = ""
		log_error("❌ Stream error: " + JSON.stringify(error))

func _on_stream_tool_call_done(stream_id: String, tool_call_id: String, tool_name: String, arguments_json: String) -> void:
	if stream_id != current_stream_id:
		return
	
	log_info("🔧 Tool call: " + tool_name)
	var args: Dictionary = JSON.parse_string(arguments_json)
	
	var output_text := "ERROR_UNKNOWN_TOOL"
	if tool_name == "echo_upper":
		var txt := String(args.get("text", ""))
		output_text = txt.to_upper()
	
	var tool_outputs := [{
		"tool_call_id": tool_call_id, 
		"output": JSON.stringify({"ok": true, "data": output_text})
	}]
	wrapper.stream_submit_tool_outputs(stream_id, tool_outputs)

# =============================================================================
# TOOL FUNCTIONS (for batch registration)
# =============================================================================

# =============================================================================
# SIMPLE TOOLS (no node access - naturally thread-safe)  
# =============================================================================

func calculate_distance(args: Dictionary) -> Dictionary:
	var x1 = float(args.get("x1", 0))
	var y1 = float(args.get("y1", 0))
	var x2 = float(args.get("x2", 0))
	var y2 = float(args.get("y2", 0))
	var distance = Vector2(x1, y1).distance_to(Vector2(x2, y2))
	return {"ok": true, "distance": distance, "message": "Distance calculated successfully"}

func generate_random_color(args: Dictionary) -> Dictionary:
	var alpha = float(args.get("alpha", 1.0))
	var color = Color(randf(), randf(), randf(), alpha)
	return {
		"ok": true, 
		"color": {
			"r": color.r,
			"g": color.g, 
			"b": color.b,
			"a": color.a
		},
		"hex": color.to_html(),
		"message": "Random color generated"
	}

# =============================================================================
# NODE ACCESS TOOLS (require main thread - use thread_safe_node_handler)
# =============================================================================

func get_world_info(args: Dictionary) -> Dictionary:
	# This version can access nodes safely
	var camera_pos = get_node("../Camera2D").global_position if get_node("../Camera2D") else Vector2.ZERO
	var entities_count = get_node("../World/Entities").get_child_count() if get_node("../World/Entities") else 0
	return {
		"ok": true,
		"world": {
			"name": "Test World",
			"time": Time.get_unix_time_from_system(),
			"entities": entities_count,
			"camera_position": {"x": camera_pos.x, "y": camera_pos.y}
		}
	}

func spawn_entity_impl(args: Dictionary) -> Dictionary:
	var entity_type := String(args.get("entity_type", "Entity"))
	var position_x := float(args.get("position_x", 0.0))
	var position_y := float(args.get("position_y", 0.0))
	
	var entities_node = get_node("../World/Entities")
	if entities_node:
		var entity = ColorRect.new()
		entity.size = Vector2(20, 20)
		entity.position = Vector2(position_x - 10, position_y - 10)
		entity.color = Color(randf(), randf(), randf())
		entities_node.add_child(entity)
		
		var label = Label.new()
		label.text = entity_type
		label.position = Vector2(0, -25)
		entity.add_child(label)
		
		log_success("✅ Entity spawned: " + entity_type)
		return {
			"ok": true,
			"entity_id": entity.get_instance_id(),
			"message": "Spawned " + entity_type + " at (" + str(position_x) + ", " + str(position_y) + ")"
		}
	else:
		return {"ok": false, "error": "Entities node not found"}

# =============================================================================
# LOGGING SYSTEM
# =============================================================================

func log_test(message: String) -> void:
	_log("[color=cyan][b]" + message + "[/b][/color]")

func log_success(message: String) -> void:
	_log("[color=green]" + message + "[/color]")

func log_error(message: String) -> void:
	_log("[color=red]" + message + "[/color]")

func log_warning(message: String) -> void:
	_log("[color=orange]" + message + "[/color]")

func log_info(message: String) -> void:
	_log("[color=white]" + message + "[/color]")

func log_stream(delta: String) -> void:
	console_output.append_text("[color=yellow]" + delta + "[/color]")

func _log(message: String) -> void:
	if console_output:
		console_output.append_text(message + "\n")

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

func _load_env_key(key_name: String) -> String:
	var path := ProjectSettings.globalize_path("res://.env")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var val := ""
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("#") or line.strip_edges() == "":
			continue
		var eq := line.find("=")
		if eq == -1:
			continue
		var k := line.substr(0, eq).strip_edges()
		var v := line.substr(eq + 1).strip_edges()
		if k == key_name:
			val = v
			break
	f.close()
	return val

# =============================================================================
# EMAIL SYSTEM TEST
# =============================================================================

func _test_email_system() -> void:
	log_test("📧 Starting Email System Test...")
	if email_test != null:
		await email_test.run_email_test(console_output)
	else:
		log_error("❌ Email test not initialized")

func _on_email_test_completed(success: bool, message: String) -> void:
	if success:
		log_success("✅ " + message)
	else:
		log_error("❌ " + message)

func _on_email_test_progress(phase: String, details: String) -> void:
	log_info("📧 " + phase + ": " + details)

func _test_async_email_system() -> void:
	log_test("🔄 Starting Async Email System Test...")
	if async_email_test != null:
		await async_email_test.run_async_email_test(console_output)
	else:
		log_error("❌ Async email test not initialized")

func _on_async_email_test_completed(success: bool, message: String) -> void:
	if success:
		log_success("✅ " + message)
	else:
		log_error("❌ " + message)

func _on_async_email_test_progress(phase: String, details: String) -> void:
	log_info("🔄 " + phase + ": " + details)
