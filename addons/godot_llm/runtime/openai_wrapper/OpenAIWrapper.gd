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
    return ""

func stream_submit_tool_outputs(stream_id: String, tool_outputs: Array) -> void:
    pass

func stream_cancel(stream_id: String) -> void:
    pass

# --- Internals ---
func _headers() -> PackedStringArray:
    var headers := [
        "Content-Type: application/json",
        "Authorization: Bearer %s" % _api_key,
    ]
    return PackedStringArray(headers)

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


