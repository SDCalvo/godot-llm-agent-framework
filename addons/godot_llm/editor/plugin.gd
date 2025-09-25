@tool
extends EditorPlugin

## Editor plugin for the `godot_llm` addon.
##
## Registers autoload singletons on enable and removes them on disable. This
## ensures projects that enable the plugin get `LLMManager`, `LLMToolRegistry`, and
## `LLMBoardManager` globally without manual setup.

const AUTOLOADS : Array[Dictionary] = [
    {"name": "LLMManager", "path": "res://addons/godot_llm/runtime/llm_manager/LLMManager.gd"},
    {"name": "LLMToolRegistry", "path": "res://addons/godot_llm/runtime/llm_tool_registry/LLMToolRegistry.gd"},
    {"name": "LLMBoardManager", "path": "res://addons/godot_llm/runtime/llm_board_manager/LLMBoardManager.gd"},
]

# Legacy autoload names/paths from early versions to clean up automatically.
const LEGACY_AUTOLOAD_NAMES := [
    "ToolRegistry",
    "BoardManager",
]

func _enter_tree() -> void:
    # Clean up legacy autoload names if present
    for legacy_name in LEGACY_AUTOLOAD_NAMES:
        if ProjectSettings.has_setting("autoload/" + legacy_name):
            remove_autoload_singleton(legacy_name)

    for autoload in AUTOLOADS:
        if not ProjectSettings.has_setting("autoload/" + autoload.name):
            add_autoload_singleton(autoload.name, autoload.path)

func _exit_tree() -> void:
    for autoload in AUTOLOADS:
        if ProjectSettings.has_setting("autoload/" + autoload.name):
            remove_autoload_singleton(autoload.name)