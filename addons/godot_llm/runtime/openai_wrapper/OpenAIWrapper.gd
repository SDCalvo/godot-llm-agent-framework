extends Node

## OpenAIWrapper
##
## Transport-only client for OpenAI's Responses API in Godot 4.
## - Non‑streaming: uses `HTTPRequest` per call to avoid BUSY state.
## - Streaming: uses `HTTPClient` and parses Server-Sent Events (SSE).
##
## Do not use this class directly in most games; prefer `LLMManager` and
## `LLMAgent`, which configure and drive this wrapper. This wrapper:
## - Normalizes response payloads (assistant text, tool calls, usage).
## - Implements capped retries on 429/5xx with respect for Retry-After.
## - Emits streaming signals for deltas and lifecycle.

# OpenAIWrapper: non-autoload helper to perform OpenAI API requests via the Responses API.
# This implementation focuses on non-streaming requests using HTTPRequest and includes
# a normalized return shape plus basic retry/backoff for 429/5xx responses.

## Emitted when a streaming session starts.
##
## [param stream_id] Internal client id for this stream.
## [param response_id] OpenAI response id.
signal stream_started(stream_id: String, response_id: String)
## Emitted for each text delta during streaming.
##
## [param stream_id] Internal client id.
## [param text_delta] Incremental assistant text.
signal stream_delta_text(stream_id: String, text_delta: String)
## Emitted when the model streams tool-call arguments.
##
## [param stream_id] Internal client id.
## [param tool_call_id] Tool call identifier.
## [param name] Tool name.
## [param arguments_delta] Partial JSON arguments.
signal stream_tool_call(stream_id: String, tool_call_id: String, name: String, arguments_delta: String)
## Emitted when a tool call's arguments are fully received.
##
## [param stream_id] Internal client id.
## [param tool_call_id] Tool call identifier.
## [param name] Tool name.
## [param arguments_json] Complete JSON arguments string.
signal stream_tool_call_done(stream_id: String, tool_call_id: String, name: String, arguments_json: String)
## Emitted at the end of streaming.
##
## [param stream_id] Internal client id.
## [param ok] True if completed cleanly.
## [param final_text] Concatenated assistant text.
## [param usage] Token usage if provided.
signal stream_finished(stream_id: String, ok: bool, final_text: String, usage: Dictionary)
## Emitted on streaming error.
##
## [param stream_id] Internal client id.
## [param error] Error details.
signal stream_error(stream_id: String, error: Dictionary)

var _api_key: String = ""
var _base_url: String = "https://api.openai.com/v1"
var _default_model: String = ""
var _default_params: Dictionary = {}

# Streaming state map: stream_id -> { client, buffer, response_id, final_text, cancelled }
var _streams: Dictionary = {}

func _ready() -> void:
	# No persistent HTTPRequest; create per-call to avoid BUSY state
	pass

## Set the API key used for all requests.
##
## [param key] Secret key string (never logged).
func set_api_key(key: String) -> void:
	_api_key = key

## Set the API base URL (advanced use: proxies, self-hosted gateways).
func set_base_url(url: String) -> void:
	_base_url = url.rstrip("/")

## Set the default model to use when not provided per call.
func set_default_model(model: String) -> void:
	_default_model = model

## Set default request parameters (e.g., temperature, top_p).
func set_default_params(params: Dictionary) -> void:
	_default_params = params.duplicate(true)

# Helpers to build content messages for the Responses API
func make_text_message(role: String, text: String) -> Dictionary:
	return {
		"role": role,
		"content": [
			{"type": "input_text", "text": text}
		]
	}

func make_image_message(role: String, image_url: String, detail: String = "auto") -> Dictionary:
	return {
		"role": role,
		"content": [
			{"type": "input_image", "image_url": image_url, "detail": detail}
		]
	}

func make_audio_input(role: String, wav_data: PackedByteArray, format: String = "wav") -> Dictionary:
	return {
		"role": role,
		"content": [
			{"type": "input_audio", "audio": {"format": format, "data": Marshalls.raw_to_base64(wav_data)}}
		]
	}

# Core Responses API: create a response
## Create a non‑streaming response.
##
## [param messages] Array of OpenAI-ready message dicts.
## [param tools] Array of tool schema dicts (optional).
## [param options] Per-call overrides (model, temperature, etc.).
## [return] Normalized result dictionary (assistant/tool_calls/error).
func create_response(messages: Array, tools: Array = [], options: Dictionary = {}) -> Dictionary:
	var model := options.get("model", _default_model)
	var body: Dictionary = {
		"model": model,
		"input": messages
	}
	if tools.size() > 0:
		body["tools"] = tools
	# merge default params then per-call options (per-call wins)
	for k in _default_params.keys():
		body[k] = _default_params[k]
	for k in options.keys():
		if k != "model":
			body[k] = options[k]
	# Tools are expected in the correct, current format only:
	# [{ type: "function", name: String, description: String, parameters: Dictionary }]

	print("WRAPPER create_response start model=", model, " tools=", tools.size())
	var res := await _request_json(HTTPClient.METHOD_POST, "/responses", body)
	print("WRAPPER create_response done ok=", res.get("ok", false), " code=", res.get("code", -1))
	print("WRAPPER raw json: ", JSON.stringify(res.get("json", {}), "  "))
	if res.get("ok", false):
		return _normalize_response(res.get("json", {}), res.get("code", 0))
	return _error_result(res)

## Continue a response by submitting tool outputs.
##
## [param response_id] OpenAI response id to continue.
## [param tool_outputs] Array of {tool_call_id, output:String(JSON)} entries.
## [return] Normalized result.
func submit_tool_outputs(response_id: String, tool_outputs: Array, tools: Array = [], options: Dictionary = {}) -> Dictionary:
	# Continuation per Responses API: send previous_response_id and function_call_output items
	var model := options.get("model", _default_model)
	var input_items: Array = []
	for t in tool_outputs:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var call_id := String((t as Dictionary).get("tool_call_id", (t as Dictionary).get("id", "")))
		var out_text := String((t as Dictionary).get("output", ""))
		input_items.push_back({
			"type": "function_call_output",
			"call_id": call_id,
			"output": out_text
		})
	var body: Dictionary = {
		"model": model,
		"previous_response_id": response_id,
		"input": input_items
	}
	if tools.size() > 0:
		body["tools"] = tools
	var path := "/responses"
	print("WRAPPER submit_tool_outputs start response_id=", response_id, " outputs=", tool_outputs.size(), " model=", model)
	var res := await _request_json(HTTPClient.METHOD_POST, path, body)
	print("WRAPPER submit_tool_outputs done ok=", res.get("ok", false), " code=", res.get("code", -1))
	if res.get("ok", false):
		return _normalize_response(res.get("json", {}), res.get("code", 0))
	return _error_result(res)

# --- Streaming stubs (to implement later) ---
## Start a streaming response (SSE).
##
## [param messages] OpenAI-ready messages.
## [param tools] Tool schemas (optional).
## [param options] Per-call overrides; model is read like non‑streaming.
## [return] Internal stream id to correlate with emitted signals.
func stream_response_start(messages: Array, tools: Array = [], options: Dictionary = {}) -> String:
	var stream_id := str(Time.get_unix_time_from_system()) + "-" + str(randi())
	var model := options.get("model", _default_model)
	var body: Dictionary = {
		"model": model,
		"input": messages,
		"stream": true
	}
	if tools.size() > 0:
		body["tools"] = tools
	for k in _default_params.keys():
		body[k] = _default_params[k]
	for k in options.keys():
		if k != "model":
			body[k] = options[k]

	_streams[stream_id] = {
		"id": stream_id,
		"client": null,
		"buffer": "",
		"response_id": "",
		"final_text": "",
		"cancelled": false,
		"model": model,
		"fncalls": {},
		"replied": {},
		"continuation_pending": false,
	}
	_sse_loop(stream_id, "/responses", body)
	return stream_id

## For streamed sessions, submit tool outputs when tool calls occur.
## Best-effort; may fall back to a non-streaming continuation.
func stream_submit_tool_outputs(stream_id: String, tool_outputs: Array) -> void:
	# For now, submit via non-streaming continuation when we have a response_id
	if not _streams.has(stream_id):
		return
	var response_id: String = String(_streams[stream_id].get("response_id", ""))
	if response_id == "":
		return
	var model := String(_streams[stream_id].get("model", _default_model))

	# Build continuation inputs as function_call_output items
	var items: Array = []
	for t in tool_outputs:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var call_id := String((t as Dictionary).get("tool_call_id", (t as Dictionary).get("call_id", "")))
		var out_text := String((t as Dictionary).get("output", ""))
		if call_id == "":
			continue
		items.push_back({
			"type": "function_call_output",
			"call_id": call_id,
			"output": out_text
		})
	if items.is_empty():
		return

	var body: Dictionary = {
		"model": model,
		"previous_response_id": response_id,
		"input": items,
		"stream": true
	}
	# Continue the stream on the same UI stream_id by starting a new SSE loop
	print("WRAPPER stream_submit_tool_outputs — continuing stream, previous_response_id=", response_id, " items=", items.size())
	print("WRAPPER continuation body: ", JSON.stringify(body, "  "))
	# continuation_pending flag should already be set by the agent
	_sse_loop(stream_id, "/responses", body)

## Cancel a running streaming session.
func stream_cancel(stream_id: String) -> void:
	if not _streams.has(stream_id):
		return
	_streams[stream_id]["cancelled"] = true
	var client: HTTPClient = _streams[stream_id].get("client", null)
	if client != null:
		client.close()
	_streams.erase(stream_id)

# --- Internals ---
func _headers(accept_sse: bool = false) -> PackedStringArray:
	var headers := [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % _api_key,
	]
	if accept_sse:
		headers.push_back("Accept: text/event-stream")
	return PackedStringArray(headers)

func _sse_loop(stream_id: String, path: String, payload: Dictionary) -> void:
	await _sse_loop_async(stream_id, path, payload)

func _sse_loop_async(stream_id: String, path: String, payload: Dictionary) -> void:
	if not _streams.has(stream_id):
		print("WRAPPER _sse_loop_async: stream_id not found: ", stream_id)
		return
	
	if _is_cancelled(stream_id):
		print("WRAPPER _sse_loop_async: stream already cancelled: ", stream_id)
		return
	
	# Close any existing client for this stream to avoid conflicts
	var old_client: HTTPClient = _streams[stream_id].get("client", null)
	if old_client != null:
		old_client.close()
		print("WRAPPER closed old client for stream continuation")
	
	var info := _parse_base_url(_base_url)
	var host: String = info["host"]
	var port: int = int(info["port"])
	var tls: bool = bool(info["tls"])
	var base_path: String = info["base_path"]

	var client := HTTPClient.new()
	_streams[stream_id]["client"] = client
	print("WRAPPER continuation: connecting to ", host, ":", port, " tls=", tls)

	var tls_opts: TLSOptions = null
	if tls:
		tls_opts = TLSOptions.client()
	var err := client.connect_to_host(host, port, tls_opts)
	if err != OK:
		print("WRAPPER continuation: connect failed err=", err)
		emit_signal("stream_error", stream_id, {"type": "connect_error", "message": str(err)})
		_streams.erase(stream_id)
		return
	print("WRAPPER continuation: connect initiated")

	var connect_attempts := 0
	while client.get_status() == HTTPClient.STATUS_RESOLVING or client.get_status() == HTTPClient.STATUS_CONNECTING:
		client.poll()
		connect_attempts += 1
		if connect_attempts % 20 == 0:  # Log every second (20 * 0.05s)
			print("WRAPPER continuation: connecting... attempt ", connect_attempts, " status=", client.get_status())
		await get_tree().create_timer(0.05).timeout
		if _is_cancelled(stream_id):
			print("WRAPPER continuation: cancelled during connect")
			return

	print("WRAPPER continuation: connect completed with status=", client.get_status())
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		print("WRAPPER continuation: connect failed status=", client.get_status())
		emit_signal("stream_error", stream_id, {"type": "connect_failed", "status": client.get_status()})
		_streams.erase(stream_id)
		return

	var full_path := base_path + path
	var body := JSON.stringify(payload)
	print("WRAPPER continuation: sending request to ", full_path)
	print("WRAPPER continuation: request body len=", body.length())
	err = client.request(HTTPClient.METHOD_POST, full_path, _headers(true), body)
	if err != OK:
		print("WRAPPER continuation: request failed err=", err)
		emit_signal("stream_error", stream_id, {"type": "request_error", "message": str(err)})
		client.close()
		_streams.erase(stream_id)
		return
	print("WRAPPER continuation: request sent successfully")

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().create_timer(0.05).timeout
		if _is_cancelled(stream_id):
			client.close()
			return

	print("WRAPPER continuation: request status=", client.get_status())
	if client.get_status() != HTTPClient.STATUS_BODY:
		print("WRAPPER continuation: not in body status, got=", client.get_status())
		emit_signal("stream_error", stream_id, {"type": "http_error", "status": client.get_status()})
		client.close()
		_streams.erase(stream_id)
		return

	# Validate HTTP status and content-type (case-insensitive); only fail on non-200
	var http_code := client.get_response_code()
	var resp_hdrs := client.get_response_headers_as_dictionary()
	var ctype := ""
	for k in resp_hdrs.keys():
		if String(k).to_lower() == "content-type":
			ctype = String(resp_hdrs[k]).to_lower()
			break
	print("WRAPPER continuation SSE http=", http_code, " ctype=", ctype)
	if http_code != 200:
		var err_buf := ""
		while client.get_status() == HTTPClient.STATUS_BODY:
			client.poll()
			var ch := client.read_response_body_chunk()
			if ch.size() > 0:
				err_buf += ch.get_string_from_utf8()
			await get_tree().create_timer(0.02).timeout
		client.close()
		emit_signal("stream_error", stream_id, {"type":"http_error", "status": http_code, "content_type": ctype, "body": err_buf})
		_streams.erase(stream_id)
		return

	# Body loop with watchdog
	var last_bytes_time := Time.get_ticks_msec()
	var had_any_event := false
	var loop_count := 0
	print("WRAPPER continuation: entering body loop")
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		if chunk.size() > 0:
			var text := chunk.get_string_from_utf8()
			print("WRAPPER continuation SSE chunk len=", text.length())
			_process_sse_chunk(stream_id, text)
			last_bytes_time = Time.get_ticks_msec()
			had_any_event = true
		loop_count += 1
		if loop_count % 100 == 0:  # Log every 100 iterations
			print("WRAPPER continuation: body loop iteration ", loop_count, " status=", client.get_status())
		await get_tree().create_timer(0.03).timeout
		if _is_cancelled(stream_id):
			print("WRAPPER continuation: cancelled during body loop")
			client.close()
			return
		if Time.get_ticks_msec() - last_bytes_time > 30000:
			print("WRAPPER continuation: timeout after 30s")
			client.close()
			emit_signal("stream_error", stream_id, {"type":"timeout", "idle_ms": 30000})
			_streams.erase(stream_id)
			return

	client.close()
	print("WRAPPER continuation: client closed, had_any_event=", had_any_event)
	if _streams.has(stream_id):
		# If no terminal event arrived, finish gracefully with whatever text we have
		var final_text := String(_streams.get(stream_id, {}).get("final_text", ""))
		var has_continuation := bool(_streams[stream_id].get("continuation_pending", false))
		print("WRAPPER natural completion final_text_len=", final_text.length(), " continuation_pending=", has_continuation)
		if not has_continuation:
			# Clear continuation pending flag since we're finishing
			_streams[stream_id]["continuation_pending"] = false
			emit_signal("stream_finished", stream_id, true, final_text, {})
			_streams.erase(stream_id)
	return

func _process_sse_chunk(stream_id: String, text: String) -> void:
	print("WRAPPER process chunk stream=", stream_id, " text=", text)
	if not _streams.has(stream_id):
		print("WRAPPER process chunk: stream_id not found in _streams")
		return
	var state = _streams[stream_id]
	state["buffer"] = String(state.get("buffer", "")) + text
	var buffer: String = state["buffer"]
	buffer = buffer.replace("\r\n", "\n")
	var sep := "\n\n"
	var idx := buffer.find(sep)
	while idx != -1:
		var block := buffer.substr(0, idx)
		buffer = buffer.substr(idx + sep.length())
		_handle_sse_event(stream_id, block)
		idx = buffer.find(sep)
	state["buffer"] = buffer

func _handle_sse_event(stream_id: String, block: String) -> void:
	var data_lines: Array = []
	var lines := block.split("\n")
	for l in lines:
		if l.begins_with("data:"):
			var payload := l.substr(5).strip_edges()
			if payload == "[DONE]":
				var final_text := String(_streams.get(stream_id, {}).get("final_text", ""))
				var has_continuation := bool(_streams[stream_id].get("continuation_pending", false))
				print("WRAPPER [DONE] final_text_len=", final_text.length(), " continuation_pending=", has_continuation)
				if not has_continuation:
					emit_signal("stream_finished", stream_id, true, final_text, {})
					_streams.erase(stream_id)
				return
			data_lines.push_back(payload)
	if data_lines.size() == 0:
		return
	var json_text := String("\n").join(data_lines)
	print("WRAPPER SSE block json=", json_text)
	var obj := JSON.parse_string(json_text)
	if typeof(obj) != TYPE_DICTIONARY:
		return
	var event_type := String(obj.get("type", ""))
	print("WRAPPER SSE event type=", event_type)
	if event_type == "response.created":
		var rid := String(obj.get("response", {}).get("id", obj.get("id", "")))
		_streams[stream_id]["response_id"] = rid
		emit_signal("stream_started", stream_id, rid)
		return
	if event_type == "response.output_text.delta":
		print("WRAPPER handle output_text.delta obj=", JSON.stringify(obj, "  "))
		var delta_val: Variant = obj.get("delta", {})
		var delta_text := ""
		if typeof(delta_val) == TYPE_DICTIONARY:
			delta_text = String(delta_val.get("text", ""))
		elif typeof(delta_val) == TYPE_STRING:
			delta_text = String(delta_val)
		_streams[stream_id]["final_text"] = String(_streams[stream_id].get("final_text", "")) + delta_text
		emit_signal("stream_delta_text", stream_id, delta_text)
		print("WRAPPER SSE delta len=", delta_text.length())
		return
	if event_type == "response.text.delta":
		print("WRAPPER handle text.delta obj=", JSON.stringify(obj, "  "))
		var delta_val2: Variant = obj.get("delta", {})
		var delta_text_b := ""
		if typeof(delta_val2) == TYPE_DICTIONARY:
			delta_text_b = String(delta_val2.get("text", ""))
		elif typeof(delta_val2) == TYPE_STRING:
			delta_text_b = String(delta_val2)
		_streams[stream_id]["final_text"] = String(_streams[stream_id].get("final_text", "")) + delta_text_b
		emit_signal("stream_delta_text", stream_id, delta_text_b)
		print("WRAPPER SSE delta(len)=", delta_text_b.length())
		return
	# Buffer function-call argument deltas by item_id
	if event_type == "response.function_call_arguments.delta":
		print("WRAPPER handle func_args.delta obj=", JSON.stringify(obj, "  "))
		var item_id_fc := String(obj.get("item_id", ""))
		var delta_str := String(obj.get("delta", ""))
		if item_id_fc != "" and delta_str != "":
			var calls_fc: Dictionary = _streams[stream_id].get("fncalls", {})
			var rec_fc: Dictionary = calls_fc.get(item_id_fc, {})
			if rec_fc.is_empty():
				var call_lookup := String(obj.get("call_id", ""))
				if call_lookup != "":
					rec_fc = calls_fc.get(call_lookup, rec_fc)
			if rec_fc.is_empty():
				rec_fc = {
					"name": "",
					"buf": "",
					"call_id": String(obj.get("call_id", ""))
				}
			var existing_buf := String(rec_fc.get("buf", ""))
			rec_fc["buf"] = existing_buf + delta_str
			var name_fc := String(rec_fc.get("name", ""))
			var call_id_emit := String(rec_fc.get("call_id", ""))
			if call_id_emit == "":
				call_id_emit = item_id_fc
			rec_fc["call_id"] = call_id_emit
			calls_fc[item_id_fc] = rec_fc
			if call_id_emit != item_id_fc:
				calls_fc[call_id_emit] = rec_fc
			_streams[stream_id]["fncalls"] = calls_fc
			print("WRAPPER func_args.delta emit call_id=", call_id_emit, " name=", name_fc, " delta_len=", delta_str.length())
			emit_signal("stream_tool_call", stream_id, call_id_emit, name_fc, delta_str)
		return
	if event_type == "response.completed":
		var final_text2 := String(_streams[stream_id].get("final_text", ""))
		var has_continuation := bool(_streams[stream_id].get("continuation_pending", false))
		print("WRAPPER response.completed final_text_len=", final_text2.length(), " continuation_pending=", has_continuation)
		if not has_continuation:
			emit_signal("stream_finished", stream_id, true, final_text2, obj.get("usage", {}))
			_streams.erase(stream_id)
		return
	if event_type == "response.done":
		var final_text3 := String(_streams[stream_id].get("final_text", ""))
		var has_continuation2 := bool(_streams[stream_id].get("continuation_pending", false))
		print("WRAPPER response.done final_text_len=", final_text3.length(), " continuation_pending=", has_continuation2)
		if not has_continuation2:
			emit_signal("stream_finished", stream_id, true, final_text3, obj.get("usage", {}))
			_streams.erase(stream_id)
		return
	if event_type == "response.error":
		emit_signal("stream_error", stream_id, obj.get("error", obj))
		_streams.erase(stream_id)
		return
	# Optional lifecycle helpers to capture content in non-delta packets
	if event_type == "response.output_item.added":
		print("WRAPPER SSE item.added")
		print("WRAPPER item.added obj=", JSON.stringify(obj, "  "))
		var item: Variant = obj.get("item", {})
		if typeof(item) == TYPE_DICTIONARY and String(item.get("type", "")) == "function_call":
			var item_id := String(item.get("id", ""))
			var name_a := String(item.get("name", ""))
			var api_call_id := String(item.get("call_id", ""))
			var calls_a: Dictionary = _streams[stream_id].get("fncalls", {})
			var rec := {"name": name_a, "buf": "", "call_id": api_call_id}
			if item_id != "":
				calls_a[item_id] = rec
			if api_call_id != "":
				calls_a[api_call_id] = rec
			_streams[stream_id]["fncalls"] = calls_a
		return
	if event_type == "response.content_part.added":
		var content: Variant = obj.get("content", {})
		if typeof(content) == TYPE_DICTIONARY and String(content.get("type", "")) == "output_text":
			var txt := String(content.get("text", ""))
			if txt != "":
				_streams[stream_id]["final_text"] = String(_streams[stream_id].get("final_text", "")) + txt
				emit_signal("stream_delta_text", stream_id, txt)
				print("WRAPPER SSE content_part.added text len=", txt.length())
		return
	if event_type == "response.function_call_arguments.done":
		print("WRAPPER handle func_args.done obj=", JSON.stringify(obj, "  "))
		var item_id_d := String(obj.get("item_id", obj.get("id", "")))
		var call_id_d := String(obj.get("call_id", ""))
		var args_d := String(obj.get("arguments", ""))
		var calls_d: Dictionary = _streams[stream_id].get("fncalls", {})
		var rec2: Dictionary = calls_d.get(item_id_d, calls_d.get(call_id_d, {}))
		if rec2.is_empty():
			rec2 = {"name": "", "buf": "", "call_id": call_id_d}
		var name_d := String(rec2.get("name", ""))
		var api_call_id2 := String(rec2.get("call_id", call_id_d))
		# If no arguments on done, fall back to accumulated buffer
		if args_d == "":
			args_d = String(rec2.get("buf", ""))
		var final_args := args_d
		print("WRAPPER func_args.done item_id=", item_id_d, " raw_call_id=", call_id_d, " resolved_call_id=", api_call_id2, " name=", name_d, " final_args_len=", final_args.length())
		calls_d.erase(item_id_d)
		if call_id_d != "":
			calls_d.erase(call_id_d)
		_streams[stream_id]["fncalls"] = calls_d
		emit_signal("stream_tool_call", stream_id, api_call_id2, name_d, final_args)
		emit_signal("stream_tool_call_done", stream_id, api_call_id2, name_d, final_args)
		print("WRAPPER SSE func_args.done call_id=", api_call_id2, " name=", name_d, " args_len=", final_args.length())
		return

func _parse_base_url(base_url: String) -> Dictionary:
	var tls := base_url.begins_with("https://")
	var tmp := base_url
	if tls:
		tmp = tmp.substr(8)
	elif tmp.begins_with("http://"):
		tmp = tmp.substr(7)
	var slash := tmp.find("/")
	var hostport := tmp if slash == -1 else tmp.substr(0, slash)
	var base_path := "" if slash == -1 else "/" + tmp.substr(slash + 1)
	var colon := hostport.find(":")
	var host := hostport if colon == -1 else hostport.substr(0, colon)
	var port := 0
	if colon == -1:
		port = 443 if tls else 80
	else:
		port = int(hostport.substr(colon + 1))
	return {"host": host, "port": port, "tls": tls, "base_path": base_path}

func _is_cancelled(stream_id: String) -> bool:
	return not _streams.has(stream_id) or bool(_streams[stream_id].get("cancelled", false))

func _request_json(method: int, path: String, payload: Dictionary, max_retries: int = 2) -> Dictionary:
	var url := _base_url + path
	var body := JSON.stringify(payload)
	var attempt := 0
	while true:
		var http := HTTPRequest.new()
		http.use_threads = true
		http.timeout = 30.0
		add_child(http)
		var err := http.request(url, _headers(), method, body)
		print("WRAPPER request start url=", url, " err=", err)
		if err != OK:
			http.queue_free()
			return {"ok": false, "code": 0, "error": {"type": "request_error", "message": str(err)}}
		var result: Array = await http.request_completed
		http.queue_free()
		print("WRAPPER request_completed args size=", result.size())
		var http_result: int = result[0]
		var code: int = result[1]
		var resp_headers: PackedStringArray = result[2]
		var resp_body: PackedByteArray = result[3]

		if http_result != HTTPRequest.RESULT_SUCCESS:
			return {"ok": false, "code": code, "error": {"type": "transport_error", "message": str(http_result)}}

		var text := resp_body.get_string_from_utf8()
		var json := JSON.parse_string(text)
		var parsed: Dictionary = json if typeof(json) == TYPE_DICTIONARY else {}

		if code >= 200 and code < 300:
			return {"ok": true, "code": code, "json": parsed}

		# Retry on 429/5xx
		if code == 429 or code >= 500:
			if attempt >= max_retries:
				return {"ok": false, "code": code, "error": {"type": "http_error", "message": parsed.get("error", parsed)}}
			var delay := _retry_after_seconds(resp_headers)
			if delay <= 0.0:
				delay = pow(2.0, float(attempt)) # 1s, 2s, 4s
			await get_tree().create_timer(delay).timeout
			attempt += 1
			continue

		return {"ok": false, "code": code, "error": {"type": "http_error", "message": parsed.get("error", parsed)}}

	# Fallback return (should be unreachable)
	return {"ok": false, "code": 0, "error": {"type": "unknown", "message": "unreachable"}}

func _retry_after_seconds(headers: PackedStringArray) -> float:
	for h in headers:
		var lower := h.to_lower()
		if lower.begins_with("retry-after:"):
			var parts := lower.split(":", false, 1)
			if parts.size() == 2:
				var val := parts[1].strip_edges()
				var secs := float(val)
				if secs > 0.0:
					return secs
	return 0.0

func _normalize_response(parsed: Dictionary, code: int) -> Dictionary:
	var response_id := parsed.get("id", "")
	var model := parsed.get("model", "")
	var usage := parsed.get("usage", {})

	var assistant_text := ""
	if parsed.has("output_text"):
		assistant_text = String(parsed.get("output_text", ""))
	elif parsed.has("output") and typeof(parsed.get("output")) == TYPE_ARRAY:
		var outputs: Array = parsed.get("output")
		for item in outputs:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			# Case 1: content directly on item (array of pieces)
			if item.has("content") and typeof(item["content"]) == TYPE_ARRAY:
				for piece in item["content"]:
					if typeof(piece) == TYPE_DICTIONARY and piece.get("type", "") == "output_text":
						assistant_text += String(piece.get("text", ""))
			# Case 2: content under message.content (Responses API message objects)
			elif item.has("message") and typeof(item["message"]) == TYPE_DICTIONARY:
				var msg: Dictionary = item["message"]
				var msg_content = msg.get("content", [])
				if typeof(msg_content) == TYPE_ARRAY:
					for piece2 in msg_content:
						if typeof(piece2) == TYPE_DICTIONARY:
							var ptype := String(piece2.get("type", ""))
							if ptype == "output_text" or ptype == "text":
								assistant_text += String(piece2.get("text", ""))

	var tool_calls := []
	# Top-level tool_calls (if API provides it)
	if parsed.has("tool_calls"):
		tool_calls = parsed["tool_calls"]
	# Otherwise, scan output content for tool_call chunks
	if tool_calls.size() == 0 and parsed.has("output") and typeof(parsed.get("output")) == TYPE_ARRAY:
		var outputs2: Array = parsed.get("output")
		for item2 in outputs2:
			if typeof(item2) != TYPE_DICTIONARY:
				continue
			# Direct function_call shape
			var item_type := String(item2.get("type", ""))
			if item_type == "function_call":
				var call_fc: Dictionary = {
					"tool_call_id": item2.get("call_id", item2.get("id", "")),
					"name": item2.get("name", ""),
					"arguments": {}
				}
				var args_raw_fc: Variant = item2.get("arguments", {})
				if typeof(args_raw_fc) == TYPE_STRING:
					var parsed_args_fc = JSON.parse_string(String(args_raw_fc))
					if typeof(parsed_args_fc) == TYPE_DICTIONARY:
						call_fc["arguments"] = parsed_args_fc
					else:
						call_fc["arguments"] = {"_raw": args_raw_fc}
				elif typeof(args_raw_fc) == TYPE_DICTIONARY:
					call_fc["arguments"] = args_raw_fc
				else:
					call_fc["arguments"] = {"_raw": args_raw_fc}
				tool_calls.push_back(call_fc)
			var inspect_arrays: Array = []
			if item2.has("content") and typeof(item2["content"]) == TYPE_ARRAY:
				inspect_arrays.push_back(item2["content"])
			if item2.has("message") and typeof(item2["message"]) == TYPE_DICTIONARY and typeof(item2["message"].get("content", [])) == TYPE_ARRAY:
				inspect_arrays.push_back(item2["message"].get("content", []))
			for arr in inspect_arrays:
				for piece2 in (arr as Array):
					if typeof(piece2) != TYPE_DICTIONARY:
						continue
					if piece2.get("type", "") == "tool_call":
						var call: Dictionary = {
							"tool_call_id": piece2.get("call_id", piece2.get("id", piece2.get("tool_call_id", ""))),
							"call_id": piece2.get("call_id", ""),
							"name": piece2.get("name", ""),
							"arguments": {}
						}
						var args_raw: Variant = piece2.get("arguments", piece2.get("input", {}))
						if typeof(args_raw) == TYPE_STRING:
							var parsed_args = JSON.parse_string(String(args_raw))
							if typeof(parsed_args) == TYPE_DICTIONARY:
								call["arguments"] = parsed_args
							else:
								call["arguments"] = {"_raw": args_raw}
						elif typeof(args_raw) == TYPE_DICTIONARY:
							call["arguments"] = args_raw
						else:
							call["arguments"] = {"_raw": args_raw}
						tool_calls.push_back(call)

	# If any tool calls exist and no assistant text, mark as tool_calls; otherwise assistant
	var status := "tool_calls" if tool_calls.size() > 0 and assistant_text == "" else "assistant"
	return {
		"status": status,
		"assistant_text": assistant_text,
		"tool_calls": tool_calls,
		"response_id": response_id,
		"usage": usage,
		"model": model,
		"http_code": code,
		"raw": parsed,
	}

func _error_result(res: Dictionary) -> Dictionary:
	var err := res.get("error", {})
	return {
		"status": "error",
		"error": err,
		"http_code": res.get("code", 0),
	}
