extends Node

## LLMToolRegistry
##
## Autoloaded container for `LLMTool` instances registered by the game. Provides
## simple lookup utilities and schema extraction for passing into the LLM. This
## registry does not handle enable/disable; agents receive a fixed tool set at
## creation time.

func _ready() -> void:
    pass

var _tools: Array[LLMTool] = []

## Register a tool instance.
##
## [param tool] LLMTool to add to the registry.
func register(tool: LLMTool) -> void:
    if tool == null:
        return
    # Avoid duplicate names; replace existing by name
    var idx := _index_of_name(tool.name)
    if idx >= 0:
        _tools[idx] = tool
    else:
        _tools.append(tool)

## Remove all tools from the registry.
func clear() -> void:
    _tools.clear()

## Get all registered tools.
##
## [return] Array[LLMTool]
func get_all() -> Array[LLMTool]:
    return _tools.duplicate()

## Get OpenAI tool schemas for all registered tools.
##
## [return] Array[Dictionary]
func get_schemas() -> Array:
    var res: Array = []
    for t in _tools:
        res.append(t.to_openai_schema())
    return res

## Find a tool by its name. Returns null if not found.
func get_by_name(name: String) -> LLMTool:
    var idx := _index_of_name(name)
    return _tools[idx] if idx >= 0 else null

func _index_of_name(name: String) -> int:
    for i in _tools.size():
        if _tools[i].name == name:
            return i
    return -1


