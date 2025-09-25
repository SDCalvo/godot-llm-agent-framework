extends Control

const OpenAIWrapper = preload("res://addons/godot_llm/runtime/openai_wrapper/OpenAIWrapper.gd")

var btn: Button
var out: RichTextLabel

var wrapper: OpenAIWrapper
var stream_btn: Button
var stream_out: RichTextLabel
var current_stream_id: String = ""

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

func _on_call_openai() -> void:
	print("TEST button pressed")
	out.text = "Calling OpenAI..."
	var messages := [
		wrapper.make_text_message("user", "Reply with a single playful greeting.")
	]
	var options := {
		"temperature": 0.2,
		"max_output_tokens": 64
	}
	print("TEST calling create_response")
	var result: Dictionary = await wrapper.create_response(messages, [], options)
	print("TEST got result status=", String(result.get("status", "")), " code=", int(result.get("http_code", -1)))
	print("TEST raw result: ", JSON.stringify(result.get("raw", {}), "  "))

func _on_stream_call() -> void:
	if stream_out == null:
		return
	stream_out.text = "Streaming..."
	var messages := [
		wrapper.make_text_message("user", "Stream a short playful greeting, word by word.")
	]
	var options := {
		"model": "gpt-4o-mini",
		"temperature": 0.2
	}
	current_stream_id = wrapper.stream_response_start(messages, [], options)
	print("TEST stream started id=", current_stream_id)

func _on_stream_started(id: String, response_id: String) -> void:
	if id != current_stream_id:
		return
	print("TEST STREAM started response=", response_id)

func _on_stream_delta(id: String, delta: String) -> void:
	if id != current_stream_id or stream_out == null:
		return
	stream_out.append_text(delta)

func _on_stream_finished(id: String, ok: bool, _final_text: String, _usage: Dictionary) -> void:
	if id != current_stream_id:
		return
	print("TEST STREAM finished ok=", ok)
	current_stream_id = ""

func _on_stream_error(id: String, error: Dictionary) -> void:
	if id != current_stream_id:
		return
	if stream_out != null:
		stream_out.text = "Stream error: " + JSON.stringify(error, "  ")
	current_stream_id = ""

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
