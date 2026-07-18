extends Node
## Global run state for LIMINAL. Light coordinator — the world scene owns the
## moment-to-moment director logic; this holds cross-scene state + restart.

signal run_ended(reason: String)   # "exit" | "caught" | "secret"

var run_time: float = 0.0          # seconds since the run began
var look_back_count: int = 0       # how often the player turned to look behind
var is_running: bool = false
var last_ending: String = ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE

func _process(delta: float) -> void:
	if is_running:
		run_time += delta

func start_run() -> void:
	run_time = 0.0
	look_back_count = 0
	is_running = true
	last_ending = ""

func register_look_back() -> void:
	look_back_count += 1

func end_run(reason: String) -> void:
	if not is_running:
		return
	is_running = false
	last_ending = reason
	run_ended.emit(reason)

func restart() -> void:
	get_tree().paused = false
	is_running = false
	if has_node("/root/LoadingScreen"):
		var ls := get_node("/root/LoadingScreen")
		if ls.has_method("change_scene"):
			ls.change_scene("res://scenes/game_world.tscn", 0.8)
			return
	get_tree().change_scene_to_file("res://scenes/game_world.tscn")

func to_menu() -> void:
	get_tree().paused = false
	is_running = false
	if has_node("/root/LoadingScreen"):
		var ls := get_node("/root/LoadingScreen")
		if ls.has_method("change_scene"):
			ls.change_scene("res://scenes/main.tscn", 0.6)
			return
	get_tree().change_scene_to_file("res://scenes/main.tscn")
