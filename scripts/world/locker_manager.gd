extends Node3D
## Places sealed lockers against real maze walls and exposes proximity checks.
## They are environmental storytelling props, not hiding spots.

const LOCKER_PATH := "res://assets/props/items/locker.glb"
const TOTAL_LOCKERS := 4
const CELL := 4.0
const INTERACT_RANGE := 2.2

var _player: Node3D = null
var _maze: Node3D = null
var _locker_scene: PackedScene = null
var _lockers: Array[Node3D] = []
var _spawned := false


func setup(player: Node3D, maze: Node3D) -> void:
	_player = player
	_maze = maze
	if is_node_ready() and _locker_scene:
		_spawn_all()


func _ready() -> void:
	if ResourceLoader.exists(LOCKER_PATH):
		_locker_scene = load(LOCKER_PATH)
	if is_instance_valid(_maze):
		_spawn_all()


func _spawn_all() -> void:
	if _spawned or not _locker_scene or not is_instance_valid(_maze):
		return
	_spawned = true
	var cells := _generate_spawn_cells()
	for i in cells.size():
		var cell: Vector2i = cells[i]
		_spawn_locker(i, cell)


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


func _spawn_locker(id: int, cell: Vector2i) -> void:
	if not _locker_scene or not is_instance_valid(_maze) or not _maze.has_method("wall_mount_near"):
		return
	var mount: Dictionary = _maze.wall_mount_near(cell, 0.0)
	# A missing wall is safer than another locker floating in open space.
	if mount.is_empty():
		return

	var root := Node3D.new()
	root.name = "Locker_" + str(id)
	add_child(root)
	root.global_position = Vector3(mount["position"])
	root.rotation.y = float(mount["rotation_y"])
	root.set_meta("wall_cell", mount["cell"])
	
	# Instantiate locker mesh model
	var model := _locker_scene.instantiate() as Node3D
	root.add_child(model)
	
	# The wall mount's local +Z points into the corridor. Move the model just
	# far enough forward that its back panel physically touches the wall face.
	ModelUtils.setup_character_for_movement(model, 2.15)
	var model_bounds := ModelUtils._get_combined_aabb(model)
	model.position.z += -model_bounds.position.z + 0.015
	
	# Match collision to the placed asset instead of leaving a large invisible
	# cube around it.
	var col_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = model_bounds.size
	col_shape.shape = box
	col_shape.position = model.position + model_bounds.get_center()
	
	var static_body := StaticBody3D.new()
	static_body.collision_layer = 1
	static_body.collision_mask = 0
	static_body.add_child(col_shape)
	root.add_child(static_body)
	
	_lockers.append(root)


func get_nearest_locker_in_range(from: Vector3) -> Node3D:
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


func inspect_nearest(from: Vector3) -> bool:
	return is_instance_valid(get_nearest_locker_in_range(from))
