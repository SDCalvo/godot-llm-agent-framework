extends Node

## LLMManager
##
## Autoloaded coordinator that configures the `OpenAIWrapper` and serves as a
## factory for agents. Reads API key and optional defaults from environment or
## `.env`, instantiates the wrapper, and exposes convenience creation APIs.
##
## Key features:
## - Automatic API key resolution from environment or .env file
## - Centralized OpenAI wrapper configuration
## - Agent factory with tool registry integration
## - Default model and parameter management
##
## Usage:
## ```gdscript
## # Create agent with tools from registry
## var agent = LLMManager.create_agent({"model": "gpt-4o-mini"}, LLMToolRegistry.get_all())
## 
## # Or create with specific tools
## var tools = [my_tool1, my_tool2]
## var agent = LLMManager.create_agent({"temperature": 0.7}, tools)
## ```

# LLMManager: central coordinator for model interactions and agent control.
# Autoloaded singleton (registered by the EditorPlugin).

const OpenAIWrapper = preload("res://addons/godot_llm/runtime/openai_wrapper/OpenAIWrapper.gd")

var _wrapper: OpenAIWrapper

func _ready() -> void:
    _init_from_env_or_dotenv()

func _init_from_env_or_dotenv() -> void:
    var key : String = OS.get_environment("OPENAI_API_KEY")
    if key == "":
        var env_key : String = _load_env_key("OPENAI_API_KEY")
        if env_key != "":
            key = env_key
    if key != "":
        _wrapper = OpenAIWrapper.new()
        add_child(_wrapper)
        _wrapper.set_api_key(key)
        # Optionally set model from .env as well
        var model : String = OS.get_environment("OPENAI_MODEL")
        if model == "":
            model = _load_env_key("OPENAI_MODEL")
        if model != "":
            _wrapper.set_default_model(model)

func _load_env_key(name: String) -> String:
    var env_path : String = ProjectSettings.globalize_path("res://.env")
    var f : FileAccess = FileAccess.open(env_path, FileAccess.READ)
    if f == null:
        return ""
    var result : String = ""
    while not f.eof_reached():
        var line : String = f.get_line()
        if line.begins_with("#") or line.strip_edges() == "":
            continue
        var idx : int = line.find("=")
        if idx == -1:
            continue
        var k : String = line.substr(0, idx).strip_edges()
        var v : String = line.substr(idx + 1).strip_edges()
        if k == name:
            result = v
            break
    f.close()
    return result

## Get the configured OpenAIWrapper instance (may be null if no key configured).
func get_wrapper() -> OpenAIWrapper:
    return _wrapper

## Set default request parameters for all calls.
func set_default_params(params: Dictionary) -> void:
    if _wrapper != null:
        _wrapper.set_default_params(params)

## Factory to create an agent with provided tools/hyper, using the shared wrapper.
func create_agent(hyper: Dictionary, tools: Array):
    var AgentClass = load("res://addons/godot_llm/runtime/llm_agent/LLMAgent.gd")
    var agent = AgentClass.create(tools, hyper)
    if _wrapper != null and agent != null and agent.has_method("set_wrapper"):
        agent.set_wrapper(_wrapper)
    return agent


