godot_llm – Design Overview (v0)

Goals

- Ship only the LLM plumbing for Godot 4: simple to use, extensible, game-agnostic.
- Minimal, ergonomic APIs for messages, tools, and agents; great defaults; clear signals for debugging.

Runtime components

- Autoload singletons
  - LLMManager: shared config, factory for agents, central debug bus.
  - ToolRegistry: convenience holder for Tool instances (no enable/disable logic).
  - BoardManager: shared blackboard; world-agnostic messaging surface (optional for agents).
- Non‑autoload
  - OpenAIWrapper: transport only (Responses API). Non‑streaming + SSE streaming.
  - LLMAgent: single agent class with tool-calling loop (invoke/ainvoke).
  - Tool: user-defined function calls with JSON Schema.
  - LLMMessage: compact multimodal message builder.

Security / keys

- Keys are never hardcoded. Resolution order:
  1. Explicit set via API (LLMManager/Wrapper)
  2. Environment var OPENAI_API_KEY
  3. .env file at project root (git-ignored)
  4. EditorSettings (editor-only convenience; optional future dock)

Export inclusion

- LLMManager preloads non-autoload classes to guarantee they are exported.

OpenAIWrapper (transport)

- Config
  - set_api_key(key: String)
  - set_base_url(url: String)
  - set_default_model(model: String)
  - set_default_params(params: Dictionary)
- Helpers (build content pieces)
  - make_text_message(role, text)
  - make_image_message(role, image_url, detail="auto")
  - make_audio_input(role, wav_bytes, format="wav")
- Non‑streaming
  - create_response(messages: Array, tools: Array = [], options: Dictionary = {}) → Result
  - submit_tool_outputs(response_id: String, tool_outputs: Array) → Result
  - Result (normalized):
    {
    status: "assistant" | "tool_calls" | "error",
    assistant_text?: String,
    tool_calls?: Array, # [{tool_call_id, name, arguments}]
    response_id?: String,
    usage?: Dictionary,
    model?: String,
    http_code?: int,
    error?: Dictionary,
    raw?: Dictionary
    }
- Streaming (SSE via HTTPClient)
  - stream_response_start(messages, tools=[], options={}) → stream_id: String
  - stream_submit_tool_outputs(stream_id, tool_outputs) → void (best-effort; may fall back to non-streaming)
  - stream_cancel(stream_id) → void
  - Signals: stream_started(id, response_id), stream_delta_text(id, text), stream_tool_call(id, call_id, name, args_delta), stream_finished(id, ok, final_text, usage), stream_error(id, err)

Tool

- Factory
  - create_tool(name: String, description: String, schema: Dictionary, handler: Callable) → Tool
    - schema is plain Dictionary (JSON Schema-like). Conversion to OpenAI tool schema happens internally.
- Methods
  - to_openai_schema() → Dictionary
  - execute(args: Dictionary) → { ok: bool, data?: Variant, error?: Dictionary }
- Fields
  - name, description, schema, handler

ToolRegistry (autoload)

- Purpose: simple container for Tool instances.
- API
  - register(tool: Tool) → void
  - get_all() → Array[Tool]
  - get_schemas() → Array[Dictionary] # OpenAI-ready
  - clear() → void

LLMMessage (multimodal builder)

- One constructor, array out. Responses API supports multiple content items per message, so this typically returns a single item array.
- API
  - Message.new(role: String, text: Variant = null, images: Array = null, audio: Array = null, opts: Dictionary = {}) → Array[Message]
    - role: "user" | "assistant" | "system"
    - text: String or Array[String]
    - images: Array of urls or resources; we serialize to {type:"input_image", image_url:..., detail}
    - audio: Array of PackedByteArray/AudioStream; we base64 with {type:"input_audio", audio:{format,data}}
    - opts: {image_detail: "auto", audio_format: "wav"}
    - Returns: [{ role, content:[{type:"input_text"|"input_image"|"input_audio", ...}, ...] }] (or multiple if a splitting constraint appears later)
  - Message.user(...), Message.system(...): shorthands returning Array[Message]
  - to_openai(messages: Array[Message]) → Array[Dictionary] # passthrough

LLMAgent (user-facing, minimal surface)

- Factory
  - LLMManager.create_agent(hyper: Dictionary, tools: Array[Tool]) → LLMAgent
    - LLMManager owns/configures the OpenAIWrapper; agents get it internally.
    - Advanced/testing: LLMAgent.create(tools: Array[Tool], hyper: Dictionary, wrapper_override: OpenAIWrapper = null)
  - hyper keys (subset): model, temperature, max_output_tokens, max_steps=8, parallel_tool_calls=true, streaming=false, timeouts
- Calls
  - invoke(messages: Array[Message]) → { ok, text?, usage?, steps, tool_trace?: Array, error? }
  - ainvoke(messages: Array[Message]) → run_id: String # returns immediately; see signals
- Signals
  - debug(run_id: String, event: Dictionary) # request_started/tool_calls/tool_result/request_finished/stop
  - delta(run_id: String, text_delta: String)
  - finished(run_id: String, ok: bool, result: Dictionary)
  - error(run_id: String, err: Dictionary)
- Loop policy
  1. Call OpenAI with messages + tools.
  2. If tool_calls present: dispatch handlers (parallel if allowed), collect tool_outputs, continue via submit_tool_outputs.
  3. If no tool_calls: stop with assistant text.
  - Stops on: no_more_tools, max_steps, cancelled, http_error/rate_limited/tool_error.
  - Tracing: accumulate a compact tool_trace per step for debugging/insights.

LLMManager (autoload)

- Purpose: convenience glue + global debug bus.
- API
  - set_api_key, set_default_model, set_default_params
  - create_agent(hyper: Dictionary, tools: Array[Tool]) → LLMAgent
- Signals (broadcasted mirrors of agent events): agent_started/agent_delta/agent_finished/agent_error

BoardManager (autoload)

- Purpose: shared blackboard for agents (optional in the loop).
- Minimal API (subject to future expansion)
  - ensure_board(participants: Array) → board_id
  - post(board_id, message: Dictionary) → void
  - read(board_id, since_index:int=0) → Array[Dictionary]
  - get_my_boards(agent_id) → Array[board_id]
- Optional message tools we may ship later: read_board, post_message_to_board, get_my_boards

Error taxonomy

- http_error (code, message), request_error, transport_error, rate_limited (retry_after), tool_error (name, details), parse_error
- Result envelopes across layers uniformly use: { ok: true, ... } or { ok: false, type, message, details? }

Streaming semantics (ainvoke)

- Start with OpenAIWrapper.stream_response_start; forward deltas via LLMAgent.delta.
- When tool-calls are emitted mid-stream, emit debug(tool_calls), gather outputs, and continue via stream_submit_tool_outputs (fallback to non-streaming continuation if needed).
- Emit finished(run_id, ok, result) at completion/cancel.

Example usage (discrete)

```gdscript
var tool := Tool.create_tool(
    "read_board",
    "Read messages from a board",
    {"type":"object","properties":{"board_id":{"type":"string"}},"required":["board_id"]},
    func(args):
        var msgs = BoardManager.read(args.board_id)
        return {"ok": true, "data": msgs}
)

ToolRegistry.register(tool)

var agent = LLMManager.create_agent({"model":"gpt-4o-mini","temperature":0.2}, ToolRegistry.get_all())
var msgs = Message.user("Summarize the latest messages from board X.")
var result = await agent.invoke(msgs)
```

Example usage (streaming)

```gdscript
var agent = LLMManager.create_agent({"model":"gpt-4o-mini","temperature":0.2}, ToolRegistry.get_all())
var msgs = Message.user("Describe this image while I watch.", images:[image_url])
var run_id = agent.ainvoke(msgs)
agent.delta.connect(func(id, d): if id==run_id: label.append_text(d))
agent.finished.connect(func(id, ok, r): if id==run_id: print("done", ok))
```

Notes

- All APIs and names subject to refinement as we implement.
- Keep user surface minimal; advanced hooks exist via subclassing LLMAgent or providing custom Tool handlers.
