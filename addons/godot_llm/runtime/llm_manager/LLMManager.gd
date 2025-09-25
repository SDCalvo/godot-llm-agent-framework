extends Node

## LLMManager
##
## Autoloaded coordinator that configures the `OpenAIWrapper` and serves as a
## factory for agents. Reads API key and optional defaults from environment or
## `.env`, instantiates the wrapper, and exposes convenience creation APIs.

# LLMManager: central coordinator for model interactions and agent control.
# Autoloaded singleton (registered by the EditorPlugin).

const OpenAIWrapper = preload("res://addons/godot_llm/runtime/openai_wrapper/OpenAIWrapper.gd")
const LLMAgent = preload("res://addons/godot_llm/runtime/llm_agent/LLMAgent.gd")

func _ready() -> void:
    _init_from_env_or_dotenv()

func _init_from_env_or_dotenv() -> void:
    var key : String = OS.get_environment("OPENAI_API_KEY")
    if key == "":
        var env_key : String = _load_env_key("OPENAI_API_KEY")
        if env_key != "":
            key = env_key
    if key != "":
        var wrapper : OpenAIWrapper = OpenAIWrapper.new()
        add_child(wrapper)
        wrapper.set_api_key(key)
        # Optionally set model from .env as well
        var model : String = OS.get_environment("OPENAI_MODEL")
        if model == "":
            model = _load_env_key("OPENAI_MODEL")
        if model != "":
            wrapper.set_default_model(model)

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


