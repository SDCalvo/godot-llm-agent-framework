extends Node

# OpenAIWrapper: non-autoload helper to perform OpenAI API requests via the Responses API.
# This implementation focuses on non-streaming requests using HTTPRequest and includes
# a normalized return shape plus basic retry/backoff for 429/5xx responses.

signal stream_started(stream_id: String, response_id: String)
signal stream_delta_text(stream_id: String, text_delta: String)
signal stream_tool_call(stream_id: String, tool_call_id: String, name: String, arguments_delta: String)
signal stream_finished(stream_id: String, ok: bool, final_text: String, usage: Dictionary)
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

func set_api_key(key: String) -> void:
	_api_key = key

func set_base_url(url: String) -> void:
	_base_url = url.rstrip("/")

func set_default_model(model: String) -> void:
	_default_model = model

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

	print("WRAPPER create_response start")
	var res := await _request_json(HTTPClient.METHOD_POST, "/responses", body)
	print("WRAPPER create_response done ok=", res.get("ok", false), " code=", res.get("code", -1))
	if res.get("ok", false):
		return _normalize_response(res.get("json", {}), res.get("code", 0))
	return _error_result(res)

# Continue a response by submitting tool outputs
func submit_tool_outputs(response_id: String, tool_outputs: Array) -> Dictionary:
	var body: Dictionary = {
		"tool_outputs": tool_outputs
	}
	var path := "/responses/%s" % response_id
	print("WRAPPER submit_tool_outputs start", response_id)
	var res := await _request_json(HTTPClient.METHOD_POST, path, body)
	print("WRAPPER submit_tool_outputs done ok=", res.get("ok", false), " code=", res.get("code", -1))
	if res.get("ok", false):
		return _normalize_response(res.get("json", {}), res.get("code", 0))
	return _error_result(res)

# --- Streaming stubs (to implement later) ---
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
	}
	_sse_loop(stream_id, "/responses", body)
	return stream_id

func stream_submit_tool_outputs(stream_id: String, tool_outputs: Array) -> void:
	# For now, submit via non-streaming continuation when we have a response_id
	if not _streams.has(stream_id):
		return
	var response_id: String = String(_streams[stream_id].get("response_id", ""))
	if response_id == "":
		return
	await submit_tool_outputs(response_id, tool_outputs)

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
		return
	var info := _parse_base_url(_base_url)
	var host: String = info["host"]
	var port: int = int(info["port"])
	var tls: bool = bool(info["tls"])
	var base_path: String = info["base_path"]

	var client := HTTPClient.new()
	_streams[stream_id]["client"] = client

	var tls_opts: TLSOptions = null
	if tls:
		tls_opts = TLSOptions.client()
	var err := client.connect_to_host(host, port, tls_opts)
	if err != OK:
		emit_signal("stream_error", stream_id, {"type": "connect_error", "message": str(err)})
		_streams.erase(stream_id)
		return

	while client.get_status() == HTTPClient.STATUS_RESOLVING or client.get_status() == HTTPClient.STATUS_CONNECTING:
		client.poll()
		await get_tree().create_timer(0.05).timeout
		if _is_cancelled(stream_id):
			return

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		emit_signal("stream_error", stream_id, {"type": "connect_failed", "status": client.get_status()})
		_streams.erase(stream_id)
		return

	var full_path := base_path + path
	var body := JSON.stringify(payload)
	err = client.request(HTTPClient.METHOD_POST, full_path, _headers(true), body)
	if err != OK:
		emit_signal("stream_error", stream_id, {"type": "request_error", "message": str(err)})
		client.close()
		_streams.erase(stream_id)
		return

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await get_tree().create_timer(0.05).timeout
		if _is_cancelled(stream_id):
			client.close()
			return

	if client.get_status() != HTTPClient.STATUS_BODY:
		emit_signal("stream_error", stream_id, {"type": "http_error", "status": client.get_status()})
		client.close()
		_streams.erase(stream_id)
		return

	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		if chunk.size() > 0:
			var text := chunk.get_string_from_utf8()
			_process_sse_chunk(stream_id, text)
		await get_tree().create_timer(0.03).timeout
		if _is_cancelled(stream_id):
			client.close()
			return

	client.close()
	var final_text: String = String(_streams.get(stream_id, {}).get("final_text", ""))
	emit_signal("stream_finished", stream_id, true, final_text, {})
	_streams.erase(stream_id)

func _process_sse_chunk(stream_id: String, text: String) -> void:
	if not _streams.has(stream_id):
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
				emit_signal("stream_finished", stream_id, true, final_text, {})
				_streams.erase(stream_id)
				return
			data_lines.push_back(payload)
	if data_lines.size() == 0:
		return
	var json_text := String("\n").join(data_lines)
	var obj := JSON.parse_string(json_text)
	if typeof(obj) != TYPE_DICTIONARY:
		return
	var event_type := String(obj.get("type", ""))
	if event_type == "response.created":
		var rid := String(obj.get("response", {}).get("id", obj.get("id", "")))
		_streams[stream_id]["response_id"] = rid
		emit_signal("stream_started", stream_id, rid)
		return
	if event_type == "response.output_text.delta":
		var delta_val: Variant = obj.get("delta", {})
		var delta_text := ""
		if typeof(delta_val) == TYPE_DICTIONARY:
			delta_text = String(delta_val.get("text", ""))
		elif typeof(delta_val) == TYPE_STRING:
			delta_text = String(delta_val)
		_streams[stream_id]["final_text"] = String(_streams[stream_id].get("final_text", "")) + delta_text
		emit_signal("stream_delta_text", stream_id, delta_text)
		return
	if event_type == "response.completed":
		var final_text2 := String(_streams[stream_id].get("final_text", ""))
		emit_signal("stream_finished", stream_id, true, final_text2, obj.get("usage", {}))
		_streams.erase(stream_id)
		return
	if event_type == "response.error":
		emit_signal("stream_error", stream_id, obj.get("error", obj))
		_streams.erase(stream_id)
		return
	# tool-call deltas
	if event_type.find("tool_call") != -1:
		var name := String(obj.get("name", ""))
		var call_id := String(obj.get("id", obj.get("tool_call_id", "")))
		var args_delta := String(obj.get("delta", {}).get("arguments", ""))
		emit_signal("stream_tool_call", stream_id, call_id, name, args_delta)

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
			if typeof(item) == TYPE_DICTIONARY and item.has("content") and typeof(item["content"]) == TYPE_ARRAY:
				for piece in item["content"]:
					if typeof(piece) == TYPE_DICTIONARY and piece.get("type", "") == "output_text":
						assistant_text += String(piece.get("text", ""))

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
			if not item2.has("content") or typeof(item2["content"]) != TYPE_ARRAY:
				continue
			for piece2 in item2["content"]:
				if typeof(piece2) != TYPE_DICTIONARY:
					continue
				if piece2.get("type", "") == "tool_call":
					var call: Dictionary = {
						"tool_call_id": piece2.get("id", piece2.get("tool_call_id", "")),
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

	var status := "tool_calls" if tool_calls.size() > 0 else "assistant"
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
