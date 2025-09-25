extends RefCounted

class_name LLMTool

## LLMTool
##
## Minimal abstraction for a tool/function callable by the LLM.
##
## A tool consists of:
## - `name`: short identifier used by the model.
## - `description`: human-readable description to guide the model.
## - `schema`: JSON Schema (object) describing parameters the tool accepts.
## - `handler`: Callable that will be invoked with a Dictionary of arguments.
##
## Tools are converted to OpenAI Responses API tool schemas with
## [method to_openai_schema] and executed via [method execute].
##
## Example
## ```gdscript
## var tool := LLMTool.create_tool(
## 	"read_board",
## 	"Read messages from a board by id",
## 	{"type": "object", "properties": {"board_id": {"type": "string"}}, "required": ["board_id"]},
## 	func(args):
## 		return {"ok": true, "data": BoardManager.read(args.board_id)}
## )
## ToolRegistry.register(tool)
## ```

var name: String
var description: String
var schema: Dictionary
var handler: Callable

## Factory to create an LLMTool.
##
## [param name] Tool name (a-z, 0-9, underscores; keep short).
## [param description] Human-readable guidance for the model.
## [param schema] JSON Schema dictionary describing parameters.
## [param handler] Callable receiving a Dictionary of arguments.
## [return] New LLMTool instance.
static func create_tool(name: String, description: String, schema: Dictionary, handler: Callable) -> LLMTool:
    var t := LLMTool.new()
    t.name = name
    t.description = description
    t.schema = schema.duplicate(true)
    t.handler = handler
    return t

## Convert this tool into an OpenAI Responses API tool schema.
##
## [return] Dictionary with the expected tool format for `tools`.
func to_openai_schema() -> Dictionary:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": schema,
        }
    }

## Execute the tool's handler with validated arguments.
##
## [param args] Dictionary of arguments from the model.
## [return] Result envelope: { ok: true, data } or { ok: false, error }.
func execute(args: Dictionary) -> Dictionary:
    # Note: we do light checks. Full JSON Schema validation is out of scope here.
    if handler.is_null() or not handler.is_valid():
        return {"ok": false, "error": {"type": "tool_error", "message": "Invalid handler"}}
    var safe_args := args if args != null else {}
    var result: Variant = null
    # Protect against runtime errors in handlers
    result = handler.call(safe_args)
    if typeof(result) == TYPE_DICTIONARY and result.has("ok"):
        # Handler returned a normalized envelope; pass it through.
        return result
    # If handler returned a plain value, wrap it as ok=true data
    return {"ok": true, "data": result}


