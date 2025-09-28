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
## - Support for complex array parameters and nested objects
## - Built-in email communication system for multi-agent workflows
##
## ## Basic Tool Creation
##
## ### Simple Parameters
## ```gdscript
## # Basic tool with simple parameters
## LLMToolRegistry.create("calculate_distance")
##   .description("Calculate distance between two points")
##   .param("x1", "float", "First point X coordinate")
##   .param("y1", "float", "First point Y coordinate") 
##   .param("x2", "float", "Second point X coordinate")
##   .param("y2", "float", "Second point Y coordinate")
##   .handler(func(args): 
##     var dist = Vector2(args.x1, args.y1).distance_to(Vector2(args.x2, args.y2))
##     return {"distance": dist}
##   )
##   .register()
## ```
##
## ### Array Parameters
## ```gdscript
## # Array of simple types
## LLMToolRegistry.create("calculate_average")
##   .description("Calculate average of a list of numbers")
##   .array_param("numbers", "number", "List of numbers to average")
##   .param("precision", "integer", "Decimal places for result", 2)
##   .handler(func(args):
##     var numbers = args.get("numbers", [])
##     var sum = 0.0
##     for num in numbers: sum += num
##     var avg = sum / numbers.size() if numbers.size() > 0 else 0.0
##     return {"average": round(avg * pow(10, args.precision)) / pow(10, args.precision)}
##   )
##   .register()
##
## # Array of strings
## LLMToolRegistry.create("send_notifications")
##   .description("Send notifications to multiple users")
##   .array_param("user_ids", "string", "List of user IDs to notify")
##   .param("message", "string", "Notification message")
##   .param("priority", "string", "Notification priority", "normal")
##   .handler(func(args): return _handle_notifications(args))
##   .register()
## ```
##
## ### Array of Objects
## ```gdscript
## # Define object schema for inventory items
## var item_schema = {
##   "type": "object",
##   "properties": {
##     "name": {"type": "string", "description": "Item name"},
##     "quantity": {"type": "integer", "description": "Item quantity"},
##     "price": {"type": "number", "description": "Item price per unit"},
##     "category": {"type": "string", "description": "Item category"}
##   },
##   "required": ["name", "quantity"]
## }
##
## LLMToolRegistry.create("update_inventory")
##   .description("Update multiple inventory items")
##   .array_param("items", item_schema, "List of items to update")
##   .param("store_id", "string", "Store identifier")
##   .param("apply_immediately", "boolean", "Apply changes immediately", true)
##   .handler(func(args): return _handle_inventory_update(args))
##   .register()
## ```
##
## ### Complex Nested Objects
## ```gdscript
## # Shopping cart with nested product options
## var product_schema = {
##   "type": "object",
##   "properties": {
##     "product_id": {"type": "string", "description": "Product ID"},
##     "quantity": {"type": "integer", "description": "Quantity to order"},
##     "options": {
##       "type": "object",
##       "properties": {
##         "size": {"type": "string", "enum": ["S", "M", "L", "XL"]},
##         "color": {"type": "string", "description": "Product color"},
##         "engraving": {"type": "string", "description": "Custom engraving text"}
##       }
##     },
##     "gift_wrap": {"type": "boolean", "description": "Add gift wrapping"}
##   },
##   "required": ["product_id", "quantity"]
## }
##
## LLMToolRegistry.create("add_to_cart")
##   .description("Add products to shopping cart")
##   .array_param("products", product_schema, "Products to add")
##   .param("customer_id", "string", "Customer identifier")
##   .param("discount_code", "string", "Discount code to apply", "")
##   .param("delivery_priority", "string", "Delivery speed", "standard")
##   .handler(func(args): return _handle_add_to_cart(args))
##   .register()
## ```
##
## ### Mixed Type Arrays (Advanced)
## ```gdscript
## # Array that can contain different types
## var mixed_schema = {
##   "oneOf": [
##     {"type": "string"},
##     {"type": "number"},
##     {
##       "type": "object",
##       "properties": {
##         "type": {"type": "string"},
##         "value": {"type": "string"}
##       }
##     }
##   ]
## }
##
## LLMToolRegistry.create("process_mixed_data")
##   .description("Process array of mixed-type data")
##   .array_param("data", mixed_schema, "Mixed data array")
##   .param("output_format", "string", "Output format", "json")
##   .handler(func(args): return _handle_mixed_data(args))
##   .register()
## ```
##
## ## Node-Based Tools
## ```gdscript
## # Tools that need to interact with the scene tree
## LLMToolRegistry.create("spawn_entities")
##   .description("Spawn multiple entities in the world")
##   .array_param("entities", {
##     "type": "object",
##     "properties": {
##       "type": {"type": "string", "description": "Entity type"},
##       "position": {
##         "type": "object",
##         "properties": {
##           "x": {"type": "number"},
##           "y": {"type": "number"}
##         }
##       },
##       "properties": {"type": "object", "description": "Custom properties"}
##     },
##     "required": ["type", "position"]
##   }, "Entities to spawn")
##   .param("parent_node", "string", "Parent node path", "")
##   .handler(LLMToolRegistry.thread_safe_node_handler(func(args):
##     var results = []
##     for entity_data in args.get("entities", []):
##       var entity = _spawn_entity(entity_data)
##       results.append({"id": entity.get_instance_id(), "type": entity_data.type})
##     return {"spawned": results}
##   ))
##   .register()
## ```
##
## ## Built-in Email System
## The registry automatically provides email communication tools for multi-agent workflows:
## - `get_other_agents`: Discover available agents
## - `send_email`: Send messages to agents (supports multiple recipients)
## - `read_emails`: Read inbox with unread-first ordering
##
## Enable email for an agent:
## ```gdscript
## var agent = LLMManager.create_agent(hyper_params, tools, "Agent Name")
## agent.enable_email()  # Adds email tools and registers with email system
## ```

func _ready() -> void:
	# Register email tools globally when the registry initializes
	_register_email_tools()

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
	
	## Add a parameter that's an array with specific item schema
	## For simple types, pass a string: array_param("names", "string", "List of names")
	## For objects, pass a schema dict: array_param("items", {"type": "object", "properties": {...}}, "List of items")
	func array_param(name: String, item_schema: Variant, desc: String, default_value: Variant = null) -> ToolBuilder:
		_parameters[name] = {
			"type": "array",
			"item_schema": item_schema,  # Can be string or Dictionary
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
			
			# For arrays, we need to specify the items type for OpenAI API
			if json_type == "array":
				var item_schema = param_info.get("item_schema", "string")
				
				if typeof(item_schema) == TYPE_STRING:
					# Simple type like "string", "number", etc.
					var json_item_type = _map_type_to_json_schema(item_schema)
					prop["items"] = {"type": json_item_type}
				elif typeof(item_schema) == TYPE_DICTIONARY:
					# Full schema dictionary for complex objects
					prop["items"] = item_schema
				else:
					# Fallback to string
					prop["items"] = {"type": "string"}
			
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

# === EMAIL SYSTEM TOOLS ===

## Register email tools globally in the registry
func _register_email_tools() -> void:
	# Tool 1: Get other agents
	create("get_other_agents").description("Get list of other agents you can send emails to. Returns both agent names and unique IDs.").handler(func(args): return _handle_get_other_agents(args)).register()
	
	# Tool 2: Send email
	create("send_email").description("Send an email to one or more agents. You can use either agent names or unique IDs as recipients. If multiple agents have the same name, use their unique ID instead to avoid ambiguity.").array_param("recipients", "string", "List of agent names or IDs to send email to").param("subject", "string", "Email subject line").param("content", "string", "Email message content").handler(func(args): return _handle_send_email(args)).register()
	
	# Tool 3: Read emails
	create("read_emails").description("Read your emails. Shows unread emails first, then recent read emails.").param("limit", "integer", "Maximum number of emails to read", 10).param("unread_only", "boolean", "Only show unread emails", false).handler(func(args): return _handle_read_emails(args)).register()

## Handle get_other_agents tool call - needs to know which agent is calling
func _handle_get_other_agents(args: Dictionary) -> Dictionary:
	var calling_agent_id = _get_calling_agent_id()
	if calling_agent_id == "":
		return {"ok": false, "error": "Could not identify calling agent"}
	
	if not _is_email_enabled(calling_agent_id):
		return {"ok": false, "error": "Email not enabled for this agent"}
	
	var agents = LLMEmailManager.get_available_agents(calling_agent_id)
	return {"ok": true, "agents": agents}

## Handle send_email tool call
func _handle_send_email(args: Dictionary) -> Dictionary:
	var calling_agent_id = _get_calling_agent_id()
	if calling_agent_id == "":
		return {"ok": false, "error": "Could not identify calling agent"}
	
	if not _is_email_enabled(calling_agent_id):
		return {"ok": false, "error": "Email not enabled for this agent"}
	
	var recipients = args.get("recipients", [])
	var subject = args.get("subject", "")
	var content = args.get("content", "")
	
	if recipients.is_empty():
		return {"ok": false, "error": "No recipients specified"}
	
	# Resolve names to IDs if needed
	var resolved_recipients = _resolve_recipients(recipients, calling_agent_id)
	
	var result = LLMEmailManager.send_email(calling_agent_id, resolved_recipients, subject, content)
	return result

## Handle read_emails tool call
func _handle_read_emails(args: Dictionary) -> Dictionary:
	var calling_agent_id = _get_calling_agent_id()
	if calling_agent_id == "":
		return {"ok": false, "error": "Could not identify calling agent"}
	
	if not _is_email_enabled(calling_agent_id):
		return {"ok": false, "error": "Email not enabled for this agent"}
	
	var limit = args.get("limit", 10)
	var unread_only = args.get("unread_only", false)
	
	var result = LLMEmailManager.read_emails(calling_agent_id, limit, unread_only)
	return result

# === HELPER FUNCTIONS ===

## Get the ID of the agent that's currently calling this tool
## This is a bit tricky since tools are global - we need a way to track the calling agent
var _current_calling_agent: String = ""

## Set the current calling agent (called by LLMAgent before tool execution)
func set_calling_agent(agent_id: String) -> void:
	_current_calling_agent = agent_id

## Get the current calling agent ID
func _get_calling_agent_id() -> String:
	return _current_calling_agent

## Check if email is enabled for an agent
func _is_email_enabled(agent_id: String) -> bool:
	# We'll need to track this - for now assume it's enabled if agent is registered
	if typeof(LLMEmailManager) == TYPE_NIL:
		return false
	
	var agents = LLMEmailManager.get_available_agents("")
	for agent in agents:
		if agent.get("id", "") == agent_id:
			return true
	return false

## Resolve recipient names to IDs (handles both names and IDs)
func _resolve_recipients(recipients: Array, calling_agent_id: String) -> Array:
	var resolved = []
	var all_agents = LLMEmailManager.get_available_agents(calling_agent_id)
	
	for recipient in recipients:
		var recipient_str = str(recipient)
		var found = false
		
		# First try to find by exact ID match
		for agent in all_agents:
			if agent.get("id", "") == recipient_str:
				resolved.append(recipient_str)
				found = true
				break
		
		# If not found by ID, try to find by name
		if not found:
			var matches = []
			for agent in all_agents:
				if agent.get("name", "") == recipient_str:
					matches.append(agent.get("id", ""))
			
			if matches.size() == 1:
				# Single match - use it
				resolved.append(matches[0])
			elif matches.size() > 1:
				# Multiple matches - this is ambiguous, but we'll use the first one
				# The LLM should use IDs in this case based on the tool description
				resolved.append(matches[0])
				print("Warning: Multiple agents named '", recipient_str, "' - using first match")
			else:
				# No matches found
				print("Warning: No agent found with name or ID '", recipient_str, "'")
				resolved.append(recipient_str)  # Pass through as-is
	
	return resolved