@tool
extends EditorPlugin

const AUTOLOADS : Array[Dictionary] = [
    {"name": "LLMManager", "path": "res://addons/godot_llm/runtime/llm_manager/LLMManager.gd"},
    {"name": "ToolRegistry", "path": "res://addons/godot_llm/runtime/tool_registry/ToolRegistry.gd"},
    {"name": "BoardManager", "path": "res://addons/godot_llm/runtime/board_manager/BoardManager.gd"},
]

func _enter_tree() -> void:
    for autoload in AUTOLOADS:
        if not ProjectSettings.has_setting("autoload/" + autoload.name):
            add_autoload_singleton(autoload.name, autoload.path)

func _exit_tree() -> void:
    for autoload in AUTOLOADS:
        if ProjectSettings.has_setting("autoload/" + autoload.name):
            remove_autoload_singleton(autoload.name)