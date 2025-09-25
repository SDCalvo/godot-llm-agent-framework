extends Node

## LLMAgent
##
## Non‑autoload agent abstraction. Creates and runs LLM invocations using the
## configured `OpenAIWrapper`, handling tool‑calling loops for invoke/ainvoke.
## Emits debug/delta/finished signals so games can wire in HUDs or logs.
## Concrete logic will follow the design in `design.md`.

func _ready() -> void:
    pass


