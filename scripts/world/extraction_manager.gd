extends Node3D
## Final objective controller. Solo runs have one long manual override near the
## exit. Co-op runs have two override stations 24 metres apart; both must be
## armed inside the same 45-second window, but one survivor may operate both.

signal terminal_activated(terminal_id: int)
signal extraction_ready
signal window_reset

const CELL := 4.0
const INTERACT_RANGE := 2.5
const HOLD_SECONDS := 6.0
const COOP_WINDOW_SECONDS := 45.0
const SOLO_CELL := Vector2i(11, -14)
const COOP_CELLS := [Vector2i(7, -12), Vector2i(13, -12)]
const EMERGENCY_BUTTON_SCENE := preload("res://assets/props/items/emergency_button.glb")
const EMERGENCY_BUTTON_HEIGHT := 0.72
const LEVER_ANIMATION := &"Po_Bo|Level_Down"

var _player: Node3D
var _maze: Node3D
var _is_mp := false
var _is_host := false
var _active := false
var _ready := false
var _stations: Array[Node3D] = []
var _armed: Dictionary = {}
var _hold_station := -1
var _hold_progress := 0.0
var _window_left := 0.0

func setup(player: Node3D, maze: Node3D, multiplayer: bool, host: bool) -> void:
	_player = player
	_maze = maze
	_is_mp = multiplayer
	_is_host = host

func activate() -> void:
	if _active:
		return
	_active = true
	var cells: Array = COOP_CELLS if _is_mp else [SOLO_CELL]
	for index in cells.size():
		_spawn_station(index, _resolve_open_cell(cells[index]))

func is_active() -> bool:
	return _active

func is_ready() -> bool:
	return _ready

func get_armed_count() -> int:
	return _armed.size()

func get_total_buttons() -> int:
	return 2 if _is_mp else 1

func prompt(from: Vector3) -> String:
	if not _active or _ready:
		return ""
	var station_id := _nearest_station(from)
	if station_id < 0:
		return ""
	if _armed.get(station_id, false):
		if _is_mp and _window_left > 0.0:
			return "EMERGENCY BUTTON %d ACTIVE — %.0fs TO FIND THE OTHER" % [station_id + 1, _window_left]
		return "EMERGENCY BUTTON ACTIVE"
	return "HOLD [E] ACTIVATE EMERGENCY BUTTON %d  %.0f%%" % [station_id + 1, _hold_progress / HOLD_SECONDS * 100.0]

func tick_interaction(delta: float) -> bool:
	if not _active or _ready or not is_instance_valid(_player):
		return false
	_tick_window(delta)
	var station_id := _nearest_station(_player.global_position)
	if station_id < 0 or _armed.get(station_id, false):
		_hold_station = -1
		_hold_progress = maxf(0.0, _hold_progress - delta * 2.0)
		return station_id >= 0
	if station_id != _hold_station:
		_hold_station = station_id
		_hold_progress = 0.0
	if Input.is_action_pressed("interact"):
		_hold_progress = minf(HOLD_SECONDS, _hold_progress + delta)
		if _hold_progress >= HOLD_SECONDS:
			_arm(station_id, true)
		return true
	_hold_progress = maxf(0.0, _hold_progress - delta * 1.5)
	return true

func remote_activate(terminal_id: int) -> void:
	_arm(terminal_id, false)

func remote_reset() -> void:
	_reset_window(false)

func _tick_window(delta: float) -> void:
	if not _is_mp or _window_left <= 0.0 or _ready:
		return
	_window_left = maxf(0.0, _window_left - delta)
	if _window_left <= 0.0 and (_is_host or not _is_mp):
		_reset_window(true)

func _arm(station_id: int, relay: bool) -> void:
	if station_id < 0 or station_id >= _stations.size() or _armed.get(station_id, false):
		return
	_armed[station_id] = true
	_hold_progress = 0.0
	_hold_station = -1
	_set_station_visual(station_id, true)
	if _is_mp and _window_left <= 0.0:
		_window_left = COOP_WINDOW_SECONDS
	if relay:
		terminal_activated.emit(station_id)
	if _armed.size() >= _stations.size():
		_ready = true
		_window_left = 0.0
		extraction_ready.emit()

func _reset_window(relay: bool) -> void:
	if _ready:
		return
	for index in _stations.size():
		if _armed.get(index, false):
			_set_station_visual(index, false)
	_armed.clear()
	_window_left = 0.0
	_hold_progress = 0.0
	_hold_station = -1
	if relay:
		window_reset.emit()

func _nearest_station(from: Vector3) -> int:
	var best := -1
	var best_distance := INTERACT_RANGE
	for index in _stations.size():
		var station := _stations[index]
		if not is_instance_valid(station):
			continue
		var distance := from.distance_to(station.global_position)
		if distance <= best_distance:
			best_distance = distance
			best = index
	return best

func _resolve_open_cell(requested: Vector2i) -> Vector2i:
	if not _maze or not _maze.has_method("is_cell_open"):
		return requested
	if _cell_is_reachable(requested):
		return requested
	for radius in range(1, 5):
		for x in range(-radius, radius + 1):
			for y in range(-radius, radius + 1):
				var candidate := requested + Vector2i(x, y)
				if _cell_is_reachable(candidate):
					return candidate
	return requested

func _cell_is_reachable(cell: Vector2i) -> bool:
	if not _maze.is_cell_open(cell):
		return false
	if _maze.has_method("corridor_path"):
		return not _maze.corridor_path(cell, Vector2i.ZERO).is_empty()
	return true

func _spawn_station(station_id: int, cell: Vector2i) -> void:
	var root := Node3D.new()
	root.name = "ExtractionOverride_%d" % (station_id + 1)
	add_child(root)
	var mount: Dictionary = _maze.wall_mount_near(cell, 1.25) if _maze and _maze.has_method("wall_mount_near") else {}
	if mount.is_empty() and is_instance_valid(_maze) and _maze.has_method("wall_mount_near"):
		for r in range(1, 18):
			for dx in range(-r, r + 1):
				for dz in range(-r, r + 1):
					mount = _maze.wall_mount_near(cell + Vector2i(dx, dz), 1.25)
					if not mount.is_empty():
						break
				if not mount.is_empty():
					break
			if not mount.is_empty():
				break

	if not mount.is_empty():
		root.global_position = mount["position"]
		root.rotation.y = float(mount["rotation_y"])
	else:
		root.position = Vector3(cell.x * CELL, 1.25, cell.y * CELL)

	var model := EMERGENCY_BUTTON_SCENE.instantiate() as Node3D
	if model:
		model.name = "EmergencyButtonModel"
		root.add_child(model)
		# Mounted as a clean vertical wall panel box.
		model.rotation_degrees = Vector3.ZERO
		ModelUtils.scale_to_height(model, 0.62)
		_center_model_on_mount(root, model)
		_add_station_collision(root, model)
		_set_lever_rest_pose(model)
	_add_status_indicator(root)
	_stations.append(root)

func _model_bounds_in_root(root: Node3D, model: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if not mesh_instance or not mesh_instance.mesh:
			continue
		var relative := root.global_transform.affine_inverse() * mesh_instance.global_transform
		var transformed := relative * mesh_instance.get_aabb()
		bounds = transformed if first else bounds.merge(transformed)
		first = false
	return bounds

func _center_model_on_mount(root: Node3D, model: Node3D) -> void:
	var bounds := _model_bounds_in_root(root, model)
	if bounds.size.length_squared() <= 0.0001:
		return
	model.position -= bounds.get_center()
	# `wall_mount_near()` places the station origin on the visible wall face and
	# local +Z points into the corridor. Keep the complete casing in front of
	# that face instead of burying half of it inside the wall.
	model.position.z += bounds.size.z * 0.5 + 0.004

func _add_station_collision(root: Node3D, model: Node3D) -> void:
	var bounds := _model_bounds_in_root(root, model)
	if bounds.size.length_squared() <= 0.0001:
		return
	var body := StaticBody3D.new()
	body.name = "EmergencyButtonCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape_node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(
		maxf(bounds.size.x, 0.28),
		maxf(bounds.size.y, 0.55),
		maxf(bounds.size.z, 0.14))
	shape_node.shape = shape
	shape_node.position = bounds.get_center()
	body.add_child(shape_node)
	root.add_child(body)

func _add_status_indicator(root: Node3D) -> void:
	var lamp := MeshInstance3D.new()
	lamp.name = "StatusLamp"
	var sphere := SphereMesh.new()
	sphere.radius = 0.022
	sphere.height = 0.044
	lamp.mesh = sphere
	lamp.position = Vector3(0.0, 0.24, 0.18)
	lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.72, 0.035, 0.02)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.015, 0.005)
	material.emission_energy_multiplier = 1.6
	lamp.material_override = material
	root.add_child(lamp)
	var light := OmniLight3D.new()
	light.name = "StatusGlow"
	light.light_color = Color(1.0, 0.04, 0.015)
	light.light_energy = 0.14
	light.omni_range = 2.6
	light.shadow_enabled = false
	light.position = lamp.position + Vector3(0.0, 0.0, 0.08)
	root.add_child(light)
	root.set_meta("status_material", material)
	root.set_meta("status_light", light)

func _set_indicator_armed(station: Node3D, armed: bool) -> void:
	var material := station.get_meta("status_material", null) as StandardMaterial3D
	var light := station.get_meta("status_light", null) as OmniLight3D
	var color := Color(0.04, 1.0, 0.16) if armed else Color(1.0, 0.04, 0.015)
	if material:
		material.albedo_color = color.darkened(0.2)
		material.emission = color
	if light:
		light.light_color = color
		light.light_energy = 0.28 if armed else 0.14

func _set_station_visual(station_id: int, armed: bool) -> void:
	if station_id < 0 or station_id >= _stations.size():
		return
	var station := _stations[station_id]
	_set_indicator_armed(station, armed)
	var model := station.get_node_or_null("EmergencyButtonModel") as Node3D
	if not model:
		return
	var animation_player := _find_lever_animation_player(model)
	if not animation_player:
		return
	if armed:
		animation_player.play(LEVER_ANIMATION, 0.12)
	else:
		animation_player.stop()
		animation_player.play(LEVER_ANIMATION, 0.12, -1.0, true)

func _set_lever_rest_pose(model: Node3D) -> void:
	var animation_player := _find_lever_animation_player(model)
	if not animation_player:
		push_warning("Emergency button asset has no '%s' animation" % LEVER_ANIMATION)
		return
	animation_player.play(LEVER_ANIMATION)
	animation_player.seek(0.0, true)
	animation_player.pause()

func _find_lever_animation_player(model: Node3D) -> AnimationPlayer:
	for child in model.find_children("*", "AnimationPlayer", true, false):
		var animation_player := child as AnimationPlayer
		if animation_player and animation_player.has_animation(LEVER_ANIMATION):
			return animation_player
	return null
