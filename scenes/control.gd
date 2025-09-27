extends Control

const OpenAIWrapper = preload("res://addons/godot_llm/runtime/openai_wrapper/OpenAIWrapper.gd")
var LLMAgentClass: Script = load("res://addons/godot_llm/runtime/llm_agent/LLMAgent.gd")
const LLMToolClass = preload("res://addons/godot_llm/runtime/llm_tools/LLMTool.gd")
const MessageClass = preload("res://addons/godot_llm/runtime/llm_messages/LLMMessage.gd")

var btn: Button
var out: RichTextLabel

var wrapper: OpenAIWrapper
var stream_btn: Button
var stream_out: RichTextLabel
var current_stream_id: String = ""

# Agent test UI
var agent_invoke_btn: Button
var agent_out: RichTextLabel
var agent_stream_btn: Button
var agent_stream_out: RichTextLabel
var current_agent_run_id: String = ""

# Agent and tools
var agent: LLMAgent
var demo_tools: Array = []

# Debug panel nodes
var debug_text: TextEdit
var debug_copy_btn: Button

func _ready() -> void:
	print("TEST _ready begin")
	# Resolve UI nodes robustly regardless of whether they're under VBoxContainer or direct children
	btn = get_node_or_null("CallButton") as Button
	if btn == null:
		btn = get_node_or_null("VBoxContainer/CallButton") as Button
	out = get_node_or_null("Output") as RichTextLabel
	if out == null:
		out = get_node_or_null("VBoxContainer/Output") as RichTextLabel
	# Streaming UI nodes (search recursively to tolerate different containers)
	stream_btn = find_child("StreamCallButton", true, false) as Button
	stream_out = find_child("StreamOutput", true, false) as RichTextLabel
	# Agent UI nodes
	agent_invoke_btn = find_child("AgentInvokeButton", true, false) as Button
	agent_out = find_child("AgentOutput", true, false) as RichTextLabel
	agent_stream_btn = find_child("AgentStreamButton", true, false) as Button
	agent_stream_out = find_child("AgentStreamOutput", true, false) as RichTextLabel
	# Debug UI nodes
	debug_text = find_child("DebugTextEdit", true, false) as TextEdit
	debug_copy_btn = find_child("CopyButton", true, false) as Button
	print("TEST stream node lookup btn:", stream_btn != null, " out:", stream_out != null)
	print("TEST node lookup btn:", btn != null, " out:", out != null)
	if btn == null or out == null:
		push_error("Could not find CallButton/Output. Check node names/paths.")
		return
	wrapper = OpenAIWrapper.new()
	add_child(wrapper)
	print("TEST wrapper created and added as child:", wrapper != null)

	var key := OS.get_environment("OPENAI_API_KEY")
	if key == "":
		key = _load_env_key("OPENAI_API_KEY")
	if key == "":
		out.text = "Missing OPENAI_API_KEY (env or .env)."
		btn.disabled = true
		return
	print("TEST api key present:", key != "")
	wrapper.set_api_key(key)

	var model := OS.get_environment("OPENAI_MODEL")
	if model == "":
		model = _load_env_key("OPENAI_MODEL")
	if model != "":
		wrapper.set_default_model(model)
	print("TEST model set:", model)

	btn.pressed.connect(_on_call_openai)
	print("TEST button connection done")
	# Connect streaming signals once; filter by current_stream_id in handlers
	if stream_btn != null:
		stream_btn.pressed.connect(_on_stream_call)
		wrapper.stream_started.connect(_on_stream_started)
		wrapper.stream_delta_text.connect(_on_stream_delta)
		wrapper.stream_finished.connect(_on_stream_finished)
		wrapper.stream_error.connect(_on_stream_error)
		wrapper.stream_tool_call.connect(_on_stream_tool_call)
		wrapper.stream_tool_call_done.connect(_on_stream_tool_call_done)

	# Debug copy button
	if debug_copy_btn != null:
		debug_copy_btn.pressed.connect(func():
			if debug_text != null:
				DisplayServer.clipboard_set(debug_text.text)
		)

	# Setup demo tool and LLMAgent for sync/async tests
	if agent_invoke_btn != null:
		agent_invoke_btn.pressed.connect(_on_agent_invoke)
	if agent_stream_btn != null:
		agent_stream_btn.pressed.connect(_on_agent_stream)

	# Create a simple demo tool: echoes text uppercased
	var echo_tool := LLMToolClass.create_tool(
		"echo_upper",
		"Echo the provided text in uppercase.",
		{"type":"object","properties": {"text": {"type":"string"}}, "required": ["text"]},
		func(args: Dictionary):
			var txt := String(args.get("text", ""))
			return {"ok": true, "data": txt.to_upper()}
	)
	demo_tools = [echo_tool]

	# Build agent with optional model and a simple system prompt via LLMManager
	var hyper := {
		"model": model if model != "" else "gpt-4o-mini",
		"temperature": 0.2,
		"system_prompt": "You are a concise assistant for test harnesses.",
		"max_output_tokens": 256
	}
	var mgr = null
	if typeof(LLMManager) != TYPE_NIL:
		mgr = LLMManager
	if mgr != null and mgr.has_method("create_agent"):
		agent = mgr.create_agent(hyper, demo_tools)
	else:
		agent = LLMAgentClass.create(demo_tools, hyper)

	# Connect agent signals once; filter by current_agent_run_id
	if agent != null:
		agent.debug.connect(func(run_id: String, event: Dictionary):
			_append_debug({"source":"agent","type":"debug","run_id":run_id,"event":event})
		)
		agent.delta.connect(func(run_id: String, d: String):
			if run_id != current_agent_run_id or agent_stream_out == null:
				return
			agent_stream_out.append_text(d)
			_append_debug({"source":"agent","type":"delta","run_id":run_id,"delta":d})
		)
		agent.finished.connect(func(run_id: String, ok: bool, _result: Dictionary):
			if run_id != current_agent_run_id:
				return
			current_agent_run_id = ""
			if agent_stream_out != null:
				agent_stream_out.append_text("\n[done] ok=" + str(ok))
			_append_debug({"source":"agent","type":"finished","run_id":run_id,"ok":ok})
		)
		agent.error.connect(func(run_id: String, err: Dictionary):
			if run_id != current_agent_run_id:
				return
			current_agent_run_id = ""
			if agent_stream_out != null:
				agent_stream_out.text = "Agent stream error: " + JSON.stringify(err, "  ")
			_append_debug({"source":"agent","type":"error","run_id":run_id,"error":err})
		)

func _on_call_openai() -> void:
	print("TEST button pressed (wrapper invoke)")
	out.text = "Calling OpenAI..."
	_append_debug({"source":"wrapper","type":"invoke_start"})
	var messages := [
		wrapper.make_text_message("user", "Reply with a single playful greeting.")
	]
	var options := {
		"temperature": 0.2,
		"max_output_tokens": 256
	}
	print("TEST calling create_response")
	var result: Dictionary = await wrapper.create_response(messages, [], options)
	print("TEST got result status=", String(result.get("status", "")), " code=", int(result.get("http_code", -1)))
	print("TEST raw result: ", JSON.stringify(result.get("raw", {}), "  "))
	_append_debug({"source":"wrapper","type":"invoke_finished","status":String(result.get("status","")),"code":int(result.get("http_code",-1))})

	# Update UI with assistant text or show tool/error info
	match String(result.get("status", "")):
		"assistant":
			out.text = String(result.get("assistant_text", ""))
		"tool_calls":
			out.text = "Tool calls:\n" + JSON.stringify(result.get("tool_calls", []), "  ")
		"error":
			out.text = "Error:\n" + JSON.stringify(result.get("error", {}), "  ")
		_:
			out.text = "Unexpected result:\n" + JSON.stringify(result, "  ")

func _on_stream_call() -> void:
	if stream_out == null:
		return
	stream_out.text = "Streaming..."
	_append_debug({"source":"wrapper","type":"stream_start"})
	var messages := [
		wrapper.make_text_message("user", "Stream a short playful greeting, word by word.")
	]
	var options := {
		"model": "gpt-4o-mini",
		"temperature": 0.2
	}
	current_stream_id = wrapper.stream_response_start(messages, [], options)
	print("TEST stream started id=", current_stream_id)
	_append_debug({"source":"wrapper","type":"stream_started","id":current_stream_id})

func _on_stream_started(id: String, response_id: String) -> void:
	if id != current_stream_id:
		return
	print("TEST STREAM started response=", response_id)
	_append_debug({"source":"wrapper","type":"stream_started","id":id,"response_id":response_id})

func _on_stream_delta(id: String, delta: String) -> void:
	if id != current_stream_id or stream_out == null:
		return
	stream_out.append_text(delta)
	_append_debug({"source":"wrapper","type":"stream_delta","id":id,"delta":delta})

func _on_stream_finished(id: String, ok: bool, _final_text: String, _usage: Dictionary) -> void:
	if id != current_stream_id:
		return
	print("TEST STREAM finished ok=", ok)
	current_stream_id = ""
	_append_debug({"source":"wrapper","type":"stream_finished","id":id,"ok":ok})

func _on_stream_error(id: String, error: Dictionary) -> void:
	if id != current_stream_id:
		return
	if stream_out != null:
		stream_out.text = "Stream error: " + JSON.stringify(error, "  ")
	current_stream_id = ""

func _on_stream_tool_call(stream_id: String, tool_call_id: String, tool_name: String, arguments_json: String) -> void:
	print("SCENE _on_stream_tool_call — id=", stream_id, " call_id=", tool_call_id, " name=", tool_name, " args_json=", arguments_json)
	if stream_id != current_stream_id:
		return
	var json := JSON.new()
	var parse_err := json.parse(arguments_json)
	var parsed_value = null
	if parse_err == OK:
		parsed_value = json.data
	print("  parsed error=", parse_err, " result=", parsed_value)
	if parse_err != OK or typeof(parsed_value) != TYPE_DICTIONARY:
		print("  NOT valid JSON object — skipping submit")
		return
	# Do not submit here; wait for done signal
	_append_debug({"source":"wrapper","type":"stream_tool_call_partial","stream_id": stream_id, "tool_call_id": tool_call_id, "name": tool_name})

func _on_stream_tool_call_done(stream_id: String, tool_call_id: String, tool_name: String, arguments_json: String) -> void:
	print("SCENE _on_stream_tool_call_done — id=", stream_id, " call_id=", tool_call_id, " name=", tool_name, " args_json=", arguments_json)
	if stream_id != current_stream_id:
		return
	var json := JSON.new()
	var parse_err := json.parse(arguments_json)
	var parsed_value = null
	if parse_err == OK:
		parsed_value = json.data
	print("  DONE parsed error=", parse_err, " result=", parsed_value)
	if parse_err != OK or typeof(parsed_value) != TYPE_DICTIONARY:
		print("  DONE NOT valid JSON object — aborting submit")
		return
	var args: Dictionary = parsed_value
	var output_text := ""
	if tool_name == "echo_upper":
		var txt := String(args.get("text", ""))
		output_text = txt.to_upper()
	else:
		output_text = "ERROR_UNKNOWN_TOOL"
	if stream_out != null:
		stream_out.append_text("\n[tool " + tool_name + "] " + output_text)
	var output_payload := {
		"ok": true,
		"data": output_text
	}
	var output_json := JSON.stringify(output_payload)
	print("  submitting tool_outputs — call_id=", tool_call_id, " output_json=", output_json)
	var tool_outputs := [
		{"tool_call_id": tool_call_id, "output": output_json}
	]
	wrapper.stream_submit_tool_outputs(stream_id, tool_outputs)
	_append_debug({"source":"wrapper","type":"stream_tool_call_sent","stream_id": stream_id, "tool_call_id": tool_call_id, "output": output_json})

func _append_debug(event: Dictionary) -> void:
	if debug_text == null:
		return
	var line := JSON.stringify(event)
	debug_text.text += ("" if debug_text.text == "" else "\n") + line

func _on_agent_invoke() -> void:
	if agent_out == null or agent == null:
		return
	agent_out.text = "Agent invoking..."
	_append_debug({"source":"agent","type":"invoke_start"})
	var msgs := []
	msgs += Message.system_simple("You are a helpful assistant. After using any tools, you MUST provide a text response explaining what you did. Never end without a final explanation.")
	msgs += Message.user_simple("First say hello. Then use the echo_upper tool to uppercase 'hello tools'. Finally, explain what the tool returned and say goodbye.")
	var res: Dictionary = await agent.invoke(msgs)
	var ok := bool(res.get("ok", false))
	if ok:
		var text := String(res.get("text", ""))
		agent_out.text = text if text != "" else "<empty assistant text>"
		print("AGENT UI received text length=", text.length())
		if text == "" and res.has("raw"):
			print("AGENT UI raw: ", JSON.stringify(res["raw"], "  "))
		_append_debug({"source":"agent","type":"invoke_finished","ok":true})
	else:
		agent_out.text = "Agent error: " + JSON.stringify(res.get("error", res), "  ")
		_append_debug({"source":"agent","type":"invoke_finished","ok":false,"error":res.get("error", res)})

func _on_agent_stream() -> void:
	if agent_stream_out == null or agent == null:
		return
	agent_stream_out.text = "Agent streaming..."
	_append_debug({"source":"agent","type":"stream_start"})
	var msgs := []
	msgs += Message.system_simple("You are a helpful assistant. After using any tools, you MUST provide a text response explaining what you did. Never end without a final explanation.")
	msgs += Message.user_simple("First say hello. Then use the echo_upper tool to uppercase 'stream me'. Finally, explain what the tool returned and say goodbye.")
	var run_id: String = agent.ainvoke(msgs)
	current_agent_run_id = run_id
	_append_debug({"source":"agent","type":"stream_started","run_id":run_id})

func _load_env_key(_name: String) -> String:
	var path : String = ProjectSettings.globalize_path("res://.env")
	var f : FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var val : String = ""
	while not f.eof_reached():
		var line : String = f.get_line()
		if line.begins_with("#") or line.strip_edges() == "":
			continue
		var eq : int = line.find("=")
		if eq == -1:
			continue
		var k : String = line.substr(0, eq).strip_edges()
		var v : String = line.substr(eq + 1).strip_edges()
		if k == _name:
			val = v
			break
	f.close()
	return val
