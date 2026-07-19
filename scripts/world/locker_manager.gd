extends Node3D
## Handles locker placement, static collision generation, proximity checks, and the player hide state.

const LOCKER_PATH := "res://assets/props/items/locker.glb"
const TOTAL_LOCKERS := 4
const CELL := 4.0
const INTERACT_RANGE := 2.2

var _player: Node3D = null
var _maze: Node3D = null
var _locker_scene: PackedScene = null
var _lockers: Array[Node3D] = []
var _is_hidden := false
var _inside_locker_node: Node3D = null
var _player_original_pos := Vector3.ZERO

signal player_hide_state_changed(is_hidden: bool)


func setup(player: Node3D, maze: Node3D) -> void:
	_player = player
	_maze = maze


func _ready() -> void:
	if ResourceLoader.exists(LOCKER_PATH):
		_locker_scene = load(LOCKER_PATH)
	_spawn_all()


func _spawn_all() -> void:
	var cells := _generate_spawn_cells()
	for i in cells.size():
		var cell: Vector2i = cells[i]
		var pos := Vector3(cell.x * CELL, 0.0, cell.y * CELL)
		_spawn_locker(i, pos)


func _generate_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var rng := RandomNumberGenerator.new()
	
	var seed_val := 777
	if has_node("/root/NetManager") and NetManager.is_multiplayer and NetManager.room_code != "":
		for byte in NetManager.room_code.to_utf8_buffer():
			seed_val = (seed_val * 33 + byte) & 0xFFFFFFFF
		rng.seed = seed_val
	else:
		rng.randomize()
		
	var attempts := 0
	while cells.size() < TOTAL_LOCKERS and attempts < 1500:
		attempts += 1
		var x := rng.randi_range(-14, 14)
		var y := rng.randi_range(-14, 14)
		var c := Vector2i(x, y)
		
		# Avoid starting room (radius 3)
		if abs(x) <= 3 and abs(y) <= 3:
			continue
		# Avoid duplicate entries
		if cells.has(c):
			continue
		# Avoid exit
		if c.distance_squared_to(Vector2i(14, -16)) < 9:
			continue
			
		if _maze and _maze.has_method("is_cell_open"):
			if not _maze.is_cell_open(c):
				continue
		cells.append(c)
		
	if cells.size() < TOTAL_LOCKERS:
		cells = [
			Vector2i(5, 5), Vector2i(-5, 5), Vector2i(-5, -5), Vector2i(5, -5)
		]
	return cells


func _spawn_locker(id: int, pos: Vector3) -> void:
	if not _locker_scene:
		return
	
	var root := Node3D.new()
	root.name = "Locker_" + str(id)
	add_child(root)
	root.global_position = pos
	
	# Instantiate locker mesh model
	var model = _locker_scene.instantiate()
	root.add_child(model)
	
	# Setup model: scale it to match player height
	var model_utils = load("res://scripts/utils/model_utils.gd")
	if model_utils:
		model_utils.setup_character_for_movement(model, 2.15)
	
	# Rotate locker randomly to face one of the open walls
	var rng := RandomNumberGenerator.new()
	rng.seed = id * 123 + 456
	var angle := rng.randi_range(0, 3) * 90.0
	model.rotation_degrees.y = angle
	
	# Add static collision so the player doesn't walk straight through it
	var col_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.1, 2.2, 1.1)
	col_shape.shape = box
	col_shape.position.y = 1.1
	
	var static_body := StaticBody3D.new()
	static_body.collision_layer = 1
	static_body.collision_mask = 0
	static_body.add_child(col_shape)
	root.add_child(static_body)
	
	_lockers.append(root)


func get_nearest_locker_in_range(from: Vector3) -> Node3D:
	if _is_hidden and is_instance_valid(_inside_locker_node):
		# If already inside, return it so the prompt knows we can leave it
		return _inside_locker_node
		
	var best: Node3D = null
	var best_d := INTERACT_RANGE
	for l in _lockers:
		if not is_instance_valid(l):
			continue
		var dist := from.distance_to(l.global_position)
		if dist < best_d:
			best_d = dist
			best = l
	return best


func is_player_inside() -> bool:
	return _is_hidden


func _set_locker_door_visible(locker_node: Node3D, vis: bool) -> void:
	if not is_instance_valid(locker_node):
		return
	for child in locker_node.find_children("*", "MeshInstance3D"):
		var n := child.name.to_lower()
		if "door" in n or "gate" in n or "front" in n or "panel" in n:
			child.visible = vis


func toggle_hide_in_locker() -> bool:
	if not is_instance_valid(_player):
		return false
		
	var nearest = get_nearest_locker_in_range(_player.global_position)
	if not is_instance_valid(nearest):
		return false
		
	if _is_hidden:
		# Exit locker
		_is_hidden = false
		_set_locker_door_visible(nearest, true)
		_player.global_position = _player_original_pos
		if _player.has_method("set_frozen"):
			_player.set_frozen(false)
		else:
			_player.frozen = false
		
		# Re-enable collision
		_player.collision_layer = 2
		_player.collision_mask = 1
		
		_player.set_meta("is_hiding", false)
		_inside_locker_node = null
		player_hide_state_changed.emit(false)
	else:
		# Enter locker
		_is_hidden = true
		_inside_locker_node = nearest
		_player_original_pos = _player.global_position
		_set_locker_door_visible(nearest, false)
		
		# Move player directly inside the locker node position & face door
		_player.global_position = nearest.global_position
		if nearest.get_child_count() > 0:
			_player.rotation.y = nearest.get_child(0).rotation.y
		
		if _player.has_method("set_frozen"):
			_player.set_frozen(true)
		else:
			_player.frozen = true
		
		# Disable collision so entity can't touch player and player doesn't collide with locker
		_player.collision_layer = 0
		_player.collision_mask = 0
		
		_player.set_meta("is_hiding", true)
		player_hide_state_changed.emit(true)
		
	return true