extends Node

## LLMToolRegistry
##
## Autoloaded container for `LLMTool` instances registered by the game. Provides
## simple lookup utilities and schema extraction for passing into the LLM. This
## registry does not handle enable/disable; agents receive a fixed tool set at
## creation time.
##
## Key features:
## - Global tool registration and storage
## - Automatic duplicate name handling (replaces existing)
## - Schema extraction for agent tool configuration
## - Simple API for game-wide tool availability
## - Builder pattern for easy tool creation
##
## Usage:
## ```gdscript
## # Simple computational tools (no nodes - naturally thread-safe)
## LLMToolRegistry.create("calculate_distance")\
##     .description("Calculate distance between points")\
##     .param("x1", "float", "First X coordinate")\
##     .param("y1", "float", "First Y coordinate")\
##     .handler(LLMToolRegistry.simple_handler(my_calculation_function))\
##     .register()
##
## # Tools that need node access (automatically thread-safe)
## LLMToolRegistry.create("spawn_entity")\
##     .description("Spawn a game entity")\
##     .param("type", "string", "Entity type")\
##     .handler(LLMToolRegistry.thread_safe_node_handler(self, "spawn_entity_impl"))\
##     .register()
##
## # Your implementation functions
## func my_calculation_function(args: Dictionary) -> Dictionary:
##     return {"ok": true, "result": args.x1 + args.y1}
##
## func spawn_entity_impl(args: Dictionary) -> Dictionary:
##     get_node("World").add_child(create_entity(args.type))  # Safe!
##     return {"ok": true, "spawned": args.type}
## ```

func _ready() -> void:
	pass

var _tools: Array[LLMTool] = []

## Tool builder class for fluent tool creation
class ToolBuilder:
	var _name: String
	var _description: String = ""
	var _parameters: Dictionary = {}
	var _returns: String = "object"
	var _handler: Callable
	var _registry: LLMToolRegistry
	
	func _init(name: String, registry: LLMToolRegistry):
		_name = name
		_registry = registry
	
	## Set the tool description
	func description(desc: String) -> ToolBuilder:
		_description = desc
		return self
	
	## Add a parameter to the tool schema
	func param(name: String, type: String, desc: String, default_value: Variant = null) -> ToolBuilder:
		_parameters[name] = {
			"type": type,
			"description": desc
		}
		if default_value != null:
			_parameters[name]["default"] = default_value
		return self
	
	## Set the return type description
	func returns(type: String) -> ToolBuilder:
		_returns = type
		return self
	
	## Set the function handler
	func handler(callable: Callable) -> ToolBuilder:
		_handler = callable
		return self
	
	## Convert GDScript/friendly types to valid JSON Schema types
	func _map_type_to_json_schema(type: String) -> String:
		match type.to_lower():
			"float", "double":
				return "number"
			"int", "integer":
				return "integer"  
			"bool", "boolean":
				return "boolean"
			"str", "string":
				return "string"
			"array", "list":
				return "array"
			"dict", "dictionary", "object":
				return "object"
			_:
				# Default to string for unknown types
				return "string"
	
	## Build and register the tool
	func register() -> LLMTool:
		# Create JSON Schema from parameters
		var schema = {
			"type": "object",
			"properties": {},
			"required": []
		}
		
		for param_name in _parameters:
			var param_info = _parameters[param_name]
			var json_type = _map_type_to_json_schema(param_info.get("type", "string"))
			var prop = {
				"type": json_type,
				"description": param_info.get("description", "")
			}
			schema.properties[param_name] = prop
			
			# Add to required if no default value
			if not param_info.has("default"):
				schema.required.append(param_name)
		
		# Create the tool
		var tool = LLMTool.create_tool(_name, _description, schema, _handler)
		_registry.register(tool)
		return tool

## Create a new tool using the builder pattern
func create(name: String) -> ToolBuilder:
	return ToolBuilder.new(name, self)

## Creates a thread-safe tool handler that defers node operations automatically.
## 
## Usage for tools that need node access:
## ```gdscript
## func setup_tools():
##     LLMToolRegistry.create("spawn_entity")
##         .description("Spawn an entity")
##         .param("type", "string", "Entity type")
##         .handler(LLMToolRegistry.thread_safe_node_handler(self, "_spawn_entity_impl"))
##         .register()
##
## func _spawn_entity_impl(args: Dictionary) -> Dictionary:
##     # This runs safely on main thread
##     var entity = preload("res://Entity.tscn").instantiate()
##     get_node("World").add_child(entity)
##     return {"ok": true, "entity_id": entity.get_instance_id()}
## ```
static func thread_safe_node_handler(target: Object, method_name: String) -> Callable:
	return func(args: Dictionary) -> Dictionary:
		# Always defer node operations and return immediately with success
		# The actual visual changes happen asynchronously
		target.call_deferred(method_name, args)
		return {"ok": true, "message": "Operation queued for main thread execution"}

## Creates a simple handler for tools that don't need node access (thread-safe by default).
##
## Usage for computational tools:
## ```gdscript 
## func setup_tools():
##     LLMToolRegistry.create("calculate")
##         .handler(LLMToolRegistry.simple_handler(func(args): 
##             return {"result": args.x + args.y}))
##         .register()
## ```
static func simple_handler(handler_func: Callable) -> Callable:
	return func(args: Dictionary) -> Dictionary:
		var result = handler_func.call(args)
		return result if typeof(result) == TYPE_DICTIONARY and result.has("ok") else {"ok": true, "data": result}

## Register multiple tools from a class with predefined schemas
##
## [param tool_instance] Instance containing the tool functions
## [param definitions] Dictionary mapping function names to their schemas
func register_class_with_definitions(tool_instance: Object, definitions: Dictionary) -> void:
	for func_name in definitions:
		var def = definitions[func_name]
		
		# Handle simple string definitions (just description)
		if typeof(def) == TYPE_STRING:
			def = {"description": def}
		
		# Create callable from instance and function name
		var callable = Callable(tool_instance, func_name)
		if not callable.is_valid():
			push_warning("LLMToolRegistry: Function '%s' not found in provided instance" % func_name)
			continue
		
		# Extract definition components
		var description = def.get("description", "")
		var parameters = def.get("parameters", {})
		var param_descriptions = def.get("param_descriptions", {})
		
		# Build tool using builder pattern
		var builder = create(func_name).description(description).handler(callable)
		
		# Add parameters (the type mapping happens in ToolBuilder.register())
		for param_name in parameters:
			var param_info = parameters[param_name]
			var param_type = param_info.get("type", "string")
			var param_desc = param_info.get("description", param_descriptions.get(param_name, ""))
			var default_value = param_info.get("default", null)
			builder.param(param_name, param_type, param_desc, default_value)
		
		# Register the tool
		builder.register()

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