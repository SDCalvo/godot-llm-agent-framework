extends Node
class_name LLMAgent

## LLMAgent
##
## Non‑autoload agent abstraction. Runs LLM turns using the configured
## `OpenAIWrapper`, handling tool‑calling loops for both `invoke` (discrete)
## and `ainvoke` (streaming). Tool handlers execute in parallel threads.
##
## Key behaviors
## - First turn: you call `invoke(messages)` or `ainvoke(messages)`.
##   - The agent validates messages and enforces exactly one system message at
##     index 0 (if present). If invalid (multiple system messages or system not
##     at index 0), the agent returns an error.
##   - If `hyper.system_prompt` or `system_prompt` is set and no system message
##     is provided, the agent prepends one automatically.
## - Continuations: within a single turn, only tool outputs are submitted via
##   `submit_tool_outputs(response_id, ...)`. We do not resend messages.
## - Interruption: call `interrupt()` to cancel the current run. Then
##   `resume()`/`stream_resume()` to start a new turn with the internal
##   `message_history`, or use `interrupt_with_invoke(messages)` /
##   `interrupt_with_ainvoke(messages)` to cancel, append messages, and start a
##   new turn immediately.
##
## Construction
## - Via LLMManager (recommended): LLMManager.create_agent(hyper, tools)
## - Direct: LLMAgent.create(tools, hyper)
##   - `hyper` may include: { model, temperature, system_prompt }
##
## Examples
## ```gdscript
## var agent := LLMAgent.create([], {"model":"gpt-4o-mini", "system_prompt":"You are a merchant."})
## var res := await agent.invoke(Message.user_simple("Greet the player."))
## res = await agent.interrupt_with_invoke(Message.user_simple("Change topic: prices?"))
## var run_id := agent.ainvoke(Message.user_simple("Stream a greeting."))
## agent.delta.connect(func(id, d): if id==run_id: $Output.append_text(d))
## ```

signal debug(run_id: String, event: Dictionary)
signal delta(run_id: String, text_delta: String)
signal finished(run_id: String, ok: bool, result: Dictionary)
signal error(run_id: String, err: Dictionary)

const OpenAIWrapperClass = preload("res://addons/godot_llm/runtime/openai_wrapper/OpenAIWrapper.gd")

var wrapper: OpenAIWrapperClass
var tools: Array = []               # Array[LLMTool]
var tools_by_name: Dictionary = {}  # name -> LLMTool
var hyper: Dictionary = {}
var message_history: Array = []     # Conversation history we maintain between turns
var _interrupted: bool = false
var _current_stream_id: String = ""
var system_prompt: String = ""

func _ready() -> void:
	pass

## Factory. Prefer using LLMManager.create_agent in most cases.
static func create(tools_in: Array, hyper_in: Dictionary = {}) -> LLMAgent:
	var agent: LLMAgent = LLMAgent.new()
	agent._init_agent(tools_in, hyper_in)
	return agent

func _init_agent(tools_in: Array, hyper_in: Dictionary) -> void:
	tools = tools_in if tools_in != null else []
	hyper = hyper_in if hyper_in != null else {}
	tools_by_name.clear()
	for t in tools:
		if t != null and t.name != "":
			tools_by_name[t.name] = t

	# Prefer autoload global (no absolute paths). If not available, expect wrapper
	# to be injected via set_wrapper() by the creator (e.g., LLMManager.create_agent).
	if wrapper == null and typeof(LLMManager) != TYPE_NIL and LLMManager.has_method("get_wrapper"):
		var w0: OpenAIWrapperClass = LLMManager.get_wrapper()
		if w0 != null:
			wrapper = w0

	# Optional system prompt from hyper
	if hyper.has("system_prompt"):
		system_prompt = String(hyper["system_prompt"]) 

## Explicitly set wrapper (used when created via LLMManager)
func set_wrapper(w: OpenAIWrapperClass) -> void:
	wrapper = w

## Conversation history helpers
func set_history(messages: Array) -> void:
	message_history = messages if messages != null else []

func add_messages(messages: Array) -> void:
	if messages == null:
		return
	for m in messages:
		message_history.append(m)

func set_system_prompt(text: String) -> void:
	system_prompt = text

## Get a deep copy of the current message history
func get_history() -> Array:
	return message_history.duplicate(true)

## Clear the message history (does not change system_prompt)
func clear_history() -> void:
	message_history.clear()

## Append a user message using the Message helper
func append_user(texts: Array[String] = [], images: Array[String] = [], audios: Array[PackedByteArray] = [], opts: Dictionary = {}) -> void:
	var msgs := Message.user(texts, images, audios, opts)
	for m in msgs:
		message_history.append(m)

## Append an assistant message (text-only convenience)
func append_assistant(texts: Array[String] = []) -> void:
	var msgs := Message.assistant(texts, [], [])
	for m in msgs:
		message_history.append(m)

## Remove and return the last message, or null if empty
func pop_last() -> Variant:
	if message_history.is_empty():
		return null
	return message_history.pop_back()

## Replace history with validation: single system at index 0 only
func replace_history(messages: Array) -> void:
	if messages == null:
		message_history.clear()
		return
	# Count/validate
	var sys_count := 0
	for m in messages:
		if typeof(m) == TYPE_DICTIONARY and String(m.get("role", "")) == "system":
			sys_count += 1
	if sys_count > 1:
		push_error("LLMAgent: replace_history failed: multiple system messages.")
		return
	if sys_count == 1 and not (messages.size() > 0 and String(messages[0].get("role", "")) == "system"):
		push_error("LLMAgent: replace_history failed: system message must be first.")
		return
	message_history = messages
	if sys_count == 1:
		var sys0: Dictionary = messages[0]
		var content: Array = sys0.get("content", [])
		for part in content:
			if typeof(part) == TYPE_DICTIONARY and part.get("type", "") == "input_text":
				system_prompt = String(part.get("text", ""))
				break

## Interrupt the current run (streaming or non‑streaming). Caller may then
## append new messages and start a fresh invoke/ainvoke.
func interrupt() -> void:
	_interrupted = true
	if _current_stream_id != "":
		wrapper.stream_cancel(_current_stream_id)
		_disconnect_stream()

func interrupt_with_new_messages(messages: Array) -> void:
	interrupt()
	add_messages(messages)

## Run a non‑streaming call with tool loop until completion.
## messages: Array of OpenAI-ready messages (use Message.user/system/... helpers).
func invoke(messages: Array) -> Dictionary:
	var run_id := str(Time.get_unix_time_from_system()) + "-" + str(randi())
	var options := _request_options()
	var step := 0
	var schemas := _tool_schemas()
	_interrupted = false
	print("AGENT invoke start run_id=", run_id, " tools=", tools.size())

	# Build and validate first-turn messages (enforce single system at index 0)
	var prep := _prepare_first_turn(messages)
	if not bool(prep.get("ok", false)):
		var err := prep.get("error", {"type":"invalid_messages"})
		emit_signal("error", run_id, err)
		return {"ok": false, "error": err}
	var turn_messages: Array = prep.get("messages", [])

	var res: Dictionary = {}
	var have_pending := false
	while true:
		if not have_pending:
			emit_signal("debug", run_id, {"type":"request_started", "step": step, "tool_count": schemas.size()})
			print("AGENT request step=", step, " sending tools=", schemas.size())
			res = await wrapper.create_response(turn_messages, schemas, options)
			emit_signal("debug", run_id, {"type":"request_finished", "step": step, "status": res.get("status", ""), "http_code": res.get("http_code", -1), "usage": res.get("usage", {})})
			print("AGENT response step=", step, " status=", String(res.get("status", "")), " code=", int(res.get("http_code", -1)))
		have_pending = false

		if _interrupted:
			return {"ok": false, "error": {"type": "interrupted"}}

		var status := String(res.get("status", "error"))
		if status == "error":
			var err := res.get("error", res)
			emit_signal("error", run_id, err)
			return {"ok": false, "error": err}

		if status == "assistant":
			var out := {
				"ok": true,
				"text": String(res.get("assistant_text", "")),
				"usage": res.get("usage", {}),
				"steps": step + 1
			}
			emit_signal("finished", run_id, true, out)
			print("AGENT finished run_id=", run_id, " steps=", out["steps"], " textLen=", String(out["text"]).length())
			return out # Exit the loop when assistant text is returned, that means no more tool calls are emitted by the model so this is the final result

		# tool_calls branch
		var tool_calls: Array = res.get("tool_calls", [])
		emit_signal("debug", run_id, {"type":"tool_calls", "step": step, "calls": tool_calls})
		print("AGENT tool_calls count=", tool_calls.size())

		# Execute tool handlers in parallel threads and collect outputs
		var threads: Array = []
		for call in tool_calls:
			var th := Thread.new()
			threads.append(th)
			th.start(Callable(self, "_execute_tool_call").bind(call))

		var tool_outputs: Array = []
		for th in threads:
			var out = th.wait_to_finish()
			tool_outputs.append(out)
		emit_signal("debug", run_id, {"type":"tool_results", "step": step, "outputs": tool_outputs})
		print("AGENT tool_results outputs=", tool_outputs.size())

		var cont: Dictionary = await wrapper.submit_tool_outputs(String(res.get("response_id", "")), tool_outputs, schemas, options)
		print("AGENT submitted tool outputs; continuing")
		if _interrupted:
			return {"ok": false, "error": {"type": "interrupted"}}
		# For continuation, avoid issuing a new create_response; evaluate returned result next loop
		step += 1
		res = cont
		have_pending = true
		continue
	return {"ok": false, "error": {"type": "internal", "message": "unreachable"}}

## Start a streaming run. Returns a run_id immediately.
func ainvoke(messages: Array) -> String:
	var run_id := str(Time.get_unix_time_from_system()) + "-" + str(randi())
	var options := _request_options()
	var schemas := _tool_schemas()
	_interrupted = false
	print("AGENT stream start run_id=", run_id, " tools=", tools.size())

	# Build and validate first-turn messages (streaming)
	var prep := _prepare_first_turn(messages)
	if not bool(prep.get("ok", false)):
		emit_signal("error", run_id, prep.get("error", {"type":"invalid_messages"}))
		return ""
	var start_messages: Array = prep.get("messages", [])

	var stream_id := wrapper.stream_response_start(start_messages, schemas, options)
	_current_stream_id = stream_id
	var acc: Dictionary = {"args": {}}  # call_id -> accumulated args string

	# Local handlers filtered by stream_id
	var on_started = func(id: String, response_id: String):
		if id != stream_id: return
		emit_signal("debug", run_id, {"type":"request_started", "response_id": response_id})
		print("AGENT stream started response_id=", response_id)

	var on_delta = func(id: String, d: String):
		if id != stream_id: return
		emit_signal("delta", run_id, d)
		print("AGENT delta len=", String(d).length())

	var on_tool = func(id: String, call_id: String, name: String, args_delta: String):
		if id != stream_id: return
		var cur := String(acc["args"].get(call_id, "")) + String(args_delta)
		acc["args"][call_id] = cur
		print("AGENT stream tool delta call_id=", call_id, " len=", String(args_delta).length())
		emit_signal("debug", run_id, {"type":"tool_delta", "name": name, "call_id": call_id})

	var on_tool_done = func(id: String, call_id: String, name: String, args_json: String):
		if id != stream_id: return
		# IMMEDIATELY set continuation_pending to prevent stream cleanup
		if wrapper._streams.has(id):
			wrapper._streams[id]["continuation_pending"] = true
			print("AGENT set continuation_pending=true for stream=", id)
		var cur_full := String(acc["args"].get(call_id, ""))
		if cur_full == "":
			cur_full = args_json
		var payload := args_json if args_json != "" else cur_full
		var json := JSON.new()
		var err := json.parse(payload)
		var parsed_value: Variant = null
		if err == OK:
			parsed_value = json.data
		else:
			var parsed_via_helper: Variant = JSON.parse_string(payload)
			if typeof(parsed_via_helper) == TYPE_DICTIONARY:
				parsed_value = parsed_via_helper
				err = OK
		print("AGENT stream tool done call_id=", call_id, " parse_err=", err, " payload=", payload)
		if err == OK and typeof(parsed_value) == TYPE_DICTIONARY:
			acc["args"].erase(call_id)
			var tool_result := _execute_tool_call({"tool_call_id": call_id, "name": name, "arguments": parsed_value})
			print("AGENT stream submitting tool result call_id=", call_id, " result=", JSON.stringify(tool_result))
			# Submit the tool result back to continue the conversation - defer to next frame to avoid race condition
			call_deferred("_submit_tool_result_deferred", id, [tool_result])
			emit_signal("debug", run_id, {"type":"tool_executed", "call_id": call_id, "name": name})
		else:
			print("AGENT stream tool done invalid JSON call_id=", call_id)

	var on_finished = func(id: String, ok: bool, final_text: String, usage: Dictionary):
		if id != stream_id: return
		emit_signal("finished", run_id, ok, {"ok": ok, "text": final_text, "usage": usage})
		_disconnect_stream()
		print("AGENT stream finished ok=", ok, " textLen=", String(final_text).length())

	var on_error = func(id: String, err: Dictionary):
		if id != stream_id: return
		emit_signal("error", run_id, err)
		_disconnect_stream()
		print("AGENT stream error=", JSON.stringify(err))

	# Connect
	wrapper.stream_started.connect(on_started)
	wrapper.stream_delta_text.connect(on_delta)
	wrapper.stream_tool_call.connect(on_tool)
	wrapper.stream_tool_call_done.connect(on_tool_done)
	wrapper.stream_finished.connect(on_finished)
	wrapper.stream_error.connect(on_error)

	# Store disconnectors so we can clean up
	_stream_connections = [on_started, on_delta, on_tool, on_tool_done, on_finished, on_error]

	return run_id

var _stream_connections: Array = []

func _disconnect_stream() -> void:
	# Godot 4 allows disconnect with Callable
	for c in _stream_connections:
		if wrapper.stream_started.is_connected(c):
			wrapper.stream_started.disconnect(c)
		if wrapper.stream_delta_text.is_connected(c):
			wrapper.stream_delta_text.disconnect(c)
		if wrapper.stream_tool_call.is_connected(c):
			wrapper.stream_tool_call.disconnect(c)
		if wrapper.stream_tool_call_done.is_connected(c):
			wrapper.stream_tool_call_done.disconnect(c)
		if wrapper.stream_finished.is_connected(c):
			wrapper.stream_finished.disconnect(c)
		if wrapper.stream_error.is_connected(c):
			wrapper.stream_error.disconnect(c)
	_stream_connections.clear()
	_current_stream_id = ""

## Build request options by filtering internal keys not understood by the API
func _request_options() -> Dictionary:
	var opts := hyper.duplicate(true)
	# Internal-only keys
	if opts.has("system_prompt"):
		opts.erase("system_prompt")
	return opts

## Convenience: resume with current history (non‑streaming)
func resume() -> Dictionary:
	return await invoke([])

## Convenience: resume streaming with current history
func stream_resume() -> String:
	return ainvoke([])

## Convenience: interrupt, append messages, invoke immediately (non‑streaming)
func interrupt_with_invoke(messages: Array) -> Dictionary:
	interrupt()
	add_messages(messages)
	return await invoke([])

## Convenience: interrupt, append messages, stream immediately
func interrupt_with_ainvoke(messages: Array) -> String:
	interrupt()
	add_messages(messages)
	return ainvoke([])

func _tool_schemas() -> Array:
	var schemas: Array = []
	for t in tools:
		if t != null:
			schemas.append(t.to_openai_schema())
	return schemas

func _execute_tool_call(call: Dictionary) -> Dictionary:
	var call_id := String(call.get("tool_call_id", call.get("id", "")))
	var name := String(call.get("name", ""))
	var args := call.get("arguments", {})
	var tool = tools_by_name.get(name, null)
	if tool == null:
		return {"tool_call_id": call_id, "output": JSON.stringify({"ok": false, "error": {"type": "unknown_tool", "name": name}})}
	var result: Dictionary = tool.execute(args)
	return {"tool_call_id": call_id, "output": JSON.stringify(result)}

## Internal: build first-turn messages from provided messages or history and
## enforce single system prompt at index 0. If messages includes a system
## message, it must be the first and will override agent.system_prompt.
## Returns { ok, messages? | error }.
func _prepare_first_turn(messages: Array) -> Dictionary:
	var base: Array = []
	if messages != null and messages.size() > 0:
		base = messages
		message_history = messages
	else:
		base = message_history

	# Count system messages and position
	var system_count := 0
	var first_role := ""
	if base.size() > 0:
		var first: Variant = base[0]
		if typeof(first) == TYPE_DICTIONARY:
			first_role = String((first as Dictionary).get("role", ""))

	for m in base:
		if typeof(m) == TYPE_DICTIONARY and String(m.get("role", "")) == "system":
			system_count += 1

	if system_count > 1:
		return {"ok": false, "error": {"type": "invalid_messages", "message": "Multiple system messages found. Only one allowed at index 0."}}

	if system_count == 1 and first_role != "system":
		return {"ok": false, "error": {"type": "invalid_messages", "message": "System message must be first in history."}}

	var final_msgs: Array = []
	if system_count == 1:
		# Override agent.system_prompt based on the first message content
		var sys0: Dictionary = base[0]
		var content: Array = sys0.get("content", [])
		# Extract text from the first input_text piece
		for part in content:
			if typeof(part) == TYPE_DICTIONARY and part.get("type", "") == "input_text":
				system_prompt = String(part.get("text", ""))
				break
	if system_prompt != "":
		final_msgs += Message.system_simple(system_prompt)

	# Append the rest, skipping any system messages (we already emitted one)
	var start_idx := 0
	if system_count == 1:
		start_idx = 1
	for i in range(start_idx, base.size()):
		var m = base[i]
		if typeof(m) == TYPE_DICTIONARY and String(m.get("role", "")) == "system":
			continue
		final_msgs.append(m)

	return {"ok": true, "messages": final_msgs}

## Deferred tool result submission to avoid race conditions
func _submit_tool_result_deferred(stream_id: String, tool_results: Array) -> void:
	print("AGENT deferred tool submission stream_id=", stream_id, " results=", tool_results.size())
	wrapper.stream_submit_tool_outputs(stream_id, tool_results)
