extends Node3D
## Final objective controller. Override stations are chosen deterministically
## from the run seed, so co-op peers see the same randomized wall mounts.

signal terminal_activated(terminal_id: int)
signal extraction_ready
signal window_reset

const CELL := 4.0
const INTERACT_RANGE := 2.5
const HOLD_SECONDS := 4.0
const COOP_WINDOW_SECONDS := 45.0
const EMERGENCY_BUTTON_SCENE := preload("res://assets/props/items/emergency_button.glb")
const EMERGENCY_BUTTON_HEIGHT := 0.48
const LEVER_ANIMATION := &"Po_Bo|Level_Down"
const ACTIVATION_SFX := "res://assets/audio/sfx/pickup/pickup_escape_unlocked.mp3"

var _player: Node3D
var _maze: Node3D
var _is_mp := false
var _is_host := false
var _run_seed := 1
var _active := false
var _ready := false
var _stations: Array[Node3D] = []
var _armed: Dictionary = {}
var _hold_station := -1
var _hold_progress := 0.0
var _window_left := 0.0
var _progress_canvas: CanvasLayer
var _progress_bar: ProgressBar
var _progress_label: Label
var _visual_time := 0.0

func setup(player: Node3D, maze: Node3D, multiplayer: bool, host: bool, run_seed: int = 1) -> void:
	_player = player
	_maze = maze
	_is_mp = multiplayer
	_is_host = host
	_run_seed = maxi(1, run_seed)

func activate() -> void:
	if _active:
		return
	_active = true
	var cells := _choose_station_cells()
	for index in cells.size():
		_spawn_station(index, cells[index])

func is_active() -> bool:
	return _active

func is_ready() -> bool:
	return _ready

func _process(delta: float) -> void:
	_visual_time += delta
	for station in _stations:
		if not is_instance_valid(station) \
				or bool(station.get_meta("indicator_armed", false)):
			continue
		var material := station.get_meta(
			"status_material", null) as StandardMaterial3D
		var light := station.get_meta("status_light", null) as OmniLight3D
		var pulse := 0.5 + 0.5 * sin(_visual_time * 3.4)
		if material:
			material.emission_energy_multiplier = lerpf(1.1, 2.3, pulse)
		if light:
			light.light_energy = lerpf(0.09, 0.22, pulse)

func get_armed_count() -> int:
	return _armed.size()

func get_total_buttons() -> int:
	return 2 if _is_mp else 1

func get_window_left() -> float:
	return _window_left

func get_station_position(station_id: int) -> Vector3:
	if station_id < 0 or station_id >= _stations.size():
		return Vector3.ZERO
	var station := _stations[station_id]
	return station.global_position if is_instance_valid(station) else Vector3.ZERO

func get_nearest_unarmed_position(from: Vector3) -> Vector3:
	var nearest := Vector3.ZERO
	var best_distance := INF
	for station_id in _stations.size():
		if _armed.get(station_id, false):
			continue
		var station := _stations[station_id]
		if not is_instance_valid(station):
			continue
		var distance := from.distance_squared_to(station.global_position)
		if distance < best_distance:
			best_distance = distance
			nearest = station.global_position
	return nearest

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
	return "HOLD TO ACTIVATE EMERGENCY BUTTON %d  %.0f%%" % [station_id + 1, _hold_progress / HOLD_SECONDS * 100.0]

func tick_interaction(delta: float) -> bool:
	if not _active or _ready or not is_instance_valid(_player):
		_update_progress_hud(-1, false)
		return false
	_tick_window(delta)
	var station_id := _nearest_station(_player.global_position)
	if station_id < 0 or _armed.get(station_id, false):
		_hold_station = -1
		_hold_progress = maxf(0.0, _hold_progress - delta * 2.0)
		_update_progress_hud(station_id, false)
		return station_id >= 0
	if station_id != _hold_station:
		_hold_station = station_id
		_hold_progress = 0.0
	if Input.is_action_pressed("interact"):
		_hold_progress = minf(HOLD_SECONDS, _hold_progress + delta)
		_update_progress_hud(station_id, true)
		if _hold_progress >= HOLD_SECONDS:
			_arm(station_id, true)
		return true
	_hold_progress = maxf(0.0, _hold_progress - delta * 1.5)
	_update_progress_hud(station_id, true)
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
	_update_progress_hud(-1, false)
	_set_station_visual(station_id, true)
	_play_activation_feedback(station_id)
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
	_update_progress_hud(-1, false)
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

func _choose_station_cells() -> Array[Vector2i]:
	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x454D4552
	var anchor := Vector2i(8, -8)
	for _attempt in 320:
		var candidate := Vector2i(rng.randi_range(-12, 12), rng.randi_range(-12, 12))
		if maxi(abs(candidate.x), abs(candidate.y)) < 5:
			continue
		if not _cell_is_reachable(candidate):
			continue
		if _maze.has_method("wall_mount_near") and _maze.wall_mount_near(candidate, 1.2).is_empty():
			continue
		anchor = candidate
		break
	if not _is_mp:
		return [anchor]

	# The second co-op button is always in the same local cluster (roughly
	# 4-10 metres away through the corridors), rather than across the map.
	for _attempt in 240:
		var offset := Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		if offset == Vector2i.ZERO:
			continue
		var candidate := anchor + offset
		if candidate == anchor or not _cell_is_reachable(candidate):
			continue
		var path: Array = _maze.corridor_path(anchor, candidate, 80) if _maze.has_method("corridor_path") else [anchor, candidate]
		if path.is_empty() or path.size() > 6:
			continue
		if _maze.has_method("wall_mount_near"):
			var mount_a: Dictionary = _maze.wall_mount_near(anchor, 1.2)
			var mount_b: Dictionary = _maze.wall_mount_near(candidate, 1.2)
			if mount_b.is_empty():
				continue
			if not mount_a.is_empty():
				var mount_a_pos: Vector3 = mount_a["position"]
				var mount_b_pos: Vector3 = mount_b["position"]
				var mount_distance := mount_a_pos.distance_to(mount_b_pos)
				if mount_distance < 3.0 or mount_distance > 10.0:
					continue
		return [anchor, candidate]
	# Deterministic exhaustive fallback: still never overlap the two stations.
	var anchor_mount: Dictionary = _maze.wall_mount_near(anchor, 1.2) if _maze.has_method("wall_mount_near") else {}
	for radius in range(1, 5):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dy) != radius:
					continue
				var candidate := anchor + Vector2i(dx, dy)
				if not _cell_is_reachable(candidate):
					continue
				var path: Array = _maze.corridor_path(anchor, candidate, 120) if _maze.has_method("corridor_path") else [anchor, candidate]
				if path.is_empty() or path.size() > 8:
					continue
				if _maze.has_method("wall_mount_near"):
					var candidate_mount: Dictionary = _maze.wall_mount_near(candidate, 1.2)
					if candidate_mount.is_empty():
						continue
					if not anchor_mount.is_empty():
						var anchor_pos: Vector3 = anchor_mount["position"]
						var candidate_pos: Vector3 = candidate_mount["position"]
						var distance := anchor_pos.distance_to(candidate_pos)
						if distance < 3.0 or distance > 12.0:
							continue
				return [anchor, candidate]
	push_warning("Could not find a distinct nearby wall mount for the second emergency button")
	return [anchor, anchor + Vector2i(1, 0)]

func _spawn_station(station_id: int, cell: Vector2i) -> void:
	var root := Node3D.new()
	root.name = "ExtractionOverride_%d" % (station_id + 1)
	add_child(root)
	var mount: Dictionary = _maze.wall_mount_near(cell, 1.2) if _maze and _maze.has_method("wall_mount_near") else {}
	if mount.is_empty() and is_instance_valid(_maze) and _maze.has_method("wall_mount_near"):
		for r in range(1, 18):
			for dx in range(-r, r + 1):
				for dz in range(-r, r + 1):
					mount = _maze.wall_mount_near(cell + Vector2i(dx, dz), 1.2)
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
		root.position = Vector3(cell.x * CELL, 1.2, cell.y * CELL)

	var model := EMERGENCY_BUTTON_SCENE.instantiate() as Node3D
	if model:
		model.name = "EmergencyButtonModel"
		root.add_child(model)
		# Mounted as a clean vertical wall panel box.
		model.rotation_degrees = Vector3.ZERO
		ModelUtils.scale_to_height(model, EMERGENCY_BUTTON_HEIGHT)
		_center_model_on_mount(root, model)
		_add_station_collision(root, model)
		_set_lever_rest_pose(model)
	_add_status_indicator(root)
	_add_station_label(root, station_id)
	_stations.append(root)

func _model_bounds_in_root(root: Node3D, model: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if not mesh_instance or not mesh_instance.mesh:
			continue
		var relative := ModelUtils.relative_transform(root, mesh_instance)
		var transformed := relative * mesh_instance.mesh.get_aabb()
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
	root.set_meta("indicator_armed", false)

func _add_station_label(root: Node3D, station_id: int) -> void:
	var label := Label3D.new()
	label.name = "EmergencyOverrideLabel"
	label.text = "EMERGENCY OVERRIDE  %02d" % (station_id + 1)
	label.font_size = 30
	label.pixel_size = 0.0022
	label.position = Vector3(0.0, 0.34, 0.19)
	label.modulate = Color(0.9, 0.86, 0.68, 0.9)
	label.outline_size = 8
	label.outline_modulate = Color(0.03, 0.025, 0.015, 0.92)
	label.no_depth_test = false
	root.add_child(label)

func _play_activation_feedback(station_id: int) -> void:
	var station_position := get_station_position(station_id)
	if station_position == Vector3.ZERO or not has_node("/root/AudioManager") \
			or not ResourceLoader.exists(ACTIVATION_SFX):
		return
	AudioManager.play_sfx_3d(
		self, load(ACTIVATION_SFX), station_position,
		-1.5, 28.0, 0.82)

func _set_indicator_armed(station: Node3D, armed: bool) -> void:
	station.set_meta("indicator_armed", armed)
	var material := station.get_meta("status_material", null) as StandardMaterial3D
	var light := station.get_meta("status_light", null) as OmniLight3D
	var color := Color(0.04, 1.0, 0.16) if armed else Color(1.0, 0.04, 0.015)
	if material:
		material.albedo_color = color.darkened(0.2)
		material.emission = color
		material.emission_energy_multiplier = 1.9 if armed else 1.6
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

func _setup_progress_hud() -> void:
	if is_instance_valid(_progress_canvas):
		return
	_progress_canvas = CanvasLayer.new()
	_progress_canvas.layer = 32
	add_child(_progress_canvas)
	var panel := VBoxContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	panel.offset_left = -170.0
	panel.offset_right = 170.0
	panel.offset_top = -150.0
	panel.offset_bottom = -105.0
	panel.add_theme_constant_override("separation", 5)
	_progress_canvas.add_child(panel)
	_progress_label = Label.new()
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.add_theme_font_size_override("font_size", 16)
	_progress_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.78))
	panel.add_child(_progress_label)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = HOLD_SECONDS
	_progress_bar.show_percentage = true
	_progress_bar.custom_minimum_size = Vector2(340.0, 20.0)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.04, 0.035, 0.02, 0.92)
	background.set_corner_radius_all(4)
	_progress_bar.add_theme_stylebox_override("background", background)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.88, 0.13, 0.045, 1.0)
	fill.set_corner_radius_all(4)
	_progress_bar.add_theme_stylebox_override("fill", fill)
	panel.add_child(_progress_bar)
	panel.visible = false
	_progress_canvas.set_meta("panel", panel)
	_progress_canvas.set_meta("fill_style", fill)

func _update_progress_hud(station_id: int, visible: bool) -> void:
	var show_countdown := _is_mp and _window_left > 0.0 and not _ready
	if visible or show_countdown:
		_setup_progress_hud()
	if not is_instance_valid(_progress_canvas):
		return
	var panel := _progress_canvas.get_meta("panel", null) as Control
	if not panel:
		return
	panel.visible = visible or show_countdown
	if not panel.visible:
		return
	var fill := _progress_canvas.get_meta(
		"fill_style", null) as StyleBoxFlat
	if visible and station_id >= 0 and not _armed.get(station_id, false):
		_progress_bar.max_value = HOLD_SECONDS
		_progress_bar.value = _hold_progress
		_progress_label.text = "HOLDING EMERGENCY BUTTON %d" % (station_id + 1)
		if fill:
			fill.bg_color = Color(0.88, 0.13, 0.045, 1.0)
	else:
		_progress_bar.max_value = COOP_WINDOW_SECONDS
		_progress_bar.value = _window_left
		_progress_label.text = "SECOND EMERGENCY BUTTON — %02ds" % ceili(
			_window_left)
		if fill:
			var urgency := 1.0 - clampf(
				_window_left / COOP_WINDOW_SECONDS, 0.0, 1.0)
			fill.bg_color = Color(0.95, 0.62, 0.04).lerp(
				Color(1.0, 0.04, 0.015), urgency)
