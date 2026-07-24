extends Node3D
## Scatters 5 snus tins across seeded, reachable sectors of the maze. Every
## co-op client gets the same cells, while a new run gets a new route. Collect
## all 5 and the way
## out unlocks. Pickup is proximity + E. In co-op, pickups are shared: picking
## one up broadcasts it and it vanishes for everyone.

signal count_changed(collected: int, total: int)
signal all_collected()

const TOTAL := 5
const CELL := 4.0                 # must match maze_manager CELL
const PICKUP_RANGE := 3.2
# Tins beyond the streamed-wall horizon (VIEW_RADIUS 6 cells ≈ 24 m) would
# float visibly in the unbuilt void — cap their visibility safely inside it.
const VISIBLE_RANGE := 34.0   # walls now stream to 48 m — keep tins inside that horizon
const SNUS_PATH := "res://assets/props/items/SNUS.glb"
const PICKUP_SFX := "res://assets/audio/sfx/pickup/pickup_snus_pickup.mp3"
const UNLOCK_SFX := "res://assets/audio/sfx/pickup/pickup_escape_unlocked.mp3"

var _players: Array[Node3D] = []      # local + remote bodies to test proximity against
var _local_player: Node3D = null
var _maze: Node3D = null
var _boxes: Dictionary = {}           # id:int -> Node3D
var _collected: Dictionary = {}       # id:int -> true
var _snus_scene: PackedScene = null
var _pickup_stream: AudioStream = null
var _unlock_stream: AudioStream = null
var _time := 0.0
var _spawned := false
var _spawn_cells: Array[Vector2i] = []
var _run_seed: int = 1


func setup(local_player: Node3D, maze: Node3D) -> void:
	_local_player = local_player
	_maze = maze
	if not _spawned:
		_spawn_all()

func set_run_seed(value: int) -> void:
	_run_seed = maxi(1, value)


func _ready() -> void:
	if ResourceLoader.exists(SNUS_PATH):
		_snus_scene = load(SNUS_PATH)
	if ResourceLoader.exists(PICKUP_SFX):
		_pickup_stream = load(PICKUP_SFX)
	if ResourceLoader.exists(UNLOCK_SFX):
		_unlock_stream = load(UNLOCK_SFX)


func register_player_body(body: Node3D) -> void:
	# Remote teammates can also collect; register their bodies for proximity.
	if body and not _players.has(body):
		_players.append(body)


const FORBIDDEN_CELLS: Array[Vector2i] = [
	Vector2i(-7, 7), Vector2i(9, 4), Vector2i(-11, -7),
	Vector2i(6, -11), Vector2i(1, 12), Vector2i(12, -3),
	Vector2i(-4, 13), Vector2i(-12, 3), Vector2i(14, -16),
]

func _generate_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x534E5553

	var sectors: Array[Rect2i] = [
		Rect2i(-16, 4, 13, 13), Rect2i(4, 4, 13, 13),
		Rect2i(-16, -16, 13, 13), Rect2i(4, -16, 13, 13),
		Rect2i(-14, -14, 29, 29),
	]

	for rect in sectors:
		var found := false
		for _attempt in 320:
			var x := rng.randi_range(rect.position.x, rect.position.x + rect.size.x - 1)
			var y := rng.randi_range(rect.position.y, rect.position.y + rect.size.y - 1)
			var c := Vector2i(x, y)
			if abs(x) <= 2 and abs(y) <= 2:
				continue
			if FORBIDDEN_CELLS.has(c):
				continue
			var too_close := false
			for existing in cells:
				if existing.distance_to(c) < 7.5:
					too_close = true
					break
			if too_close:
				continue
			if _maze and _maze.has_method("is_cell_open"):
				if not _maze.is_cell_open(c) or _maze.corridor_path(c, Vector2i.ZERO, 1400).is_empty():
					continue
			cells.append(c)
			found = true
			break

	if cells.size() < TOTAL:
		var safe: Array[Vector2i] = [
			Vector2i(-15, 15), Vector2i(15, 15), Vector2i(-15, -15),
			Vector2i(10, -15), Vector2i(0, 3)
		]
		for i in range(safe.size() - 1, 0, -1):
			var swap_index := rng.randi_range(0, i)
			var value := safe[i]
			safe[i] = safe[swap_index]
			safe[swap_index] = value
		cells = safe
	return cells


func _spawn_all() -> void:
	if _spawned:
		return
	_spawned = true
	_spawn_cells = _generate_spawn_cells()
	for i in _spawn_cells.size():
		var cell: Vector2i = _spawn_cells[i]
		var pos := Vector3(cell.x * CELL, 0.0, cell.y * CELL)
		_spawn_box(i, pos)


func _spawn_box(id: int, pos: Vector3) -> void:
	var root := Node3D.new()
	root.name = "Snus_" + str(id)
	add_child(root)
	root.global_position = pos

	if _snus_scene:
		var model: Node3D = _snus_scene.instantiate()
		root.add_child(model)
		# SNUS.glb is a disc standing on edge in source units. Scale it to a
		# 0.38m diameter, then lay it FLAT on the carpet like a dropped tin —
		# big enough that a walking player reads it without a hud marker.
		ModelUtils.scale_to_height(model, 0.38)
		model.rotation_degrees.x = 90.0
		ModelUtils.ground_model(model, 0.0)
		ModelUtils.generate_normals_for_all(model)
		_ensure_tin_material(model)
	else:
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.19
		cyl.bottom_radius = 0.19
		cyl.height = 0.07
		mi.mesh = cyl
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.5, 0.42, 0.28)
		mi.material_override = mat
		mi.position.y = 0.035
		root.add_child(mi)

	# The faintest halo, readable only up close — a tin in a dark room is
	# NOT visible from across the floor; the phone radar is how you hunt them.
	var glow := OmniLight3D.new()
	glow.name = "SnusGlow"
	glow.light_color = Color(1.0, 0.9, 0.55)
	glow.light_energy = 0.35
	glow.omni_range = 1.8
	glow.shadow_enabled = false
	glow.position = Vector3(0, 0.4, 0)
	root.add_child(glow)

	_boxes[id] = root


const LID_TEX := "res://assets/textures/props/snus_pablo_lid.png"

## SNUS.glb ships with no materials at all (mesh only) — without this it
## renders flat default-white. Dress bare meshes with the Pablo-style lid
## label, triplanar-projected (the mesh may carry no UVs); meshes that DO
## have a material are left untouched.
func _ensure_tin_material(model: Node3D) -> void:
	var tin: StandardMaterial3D = null
	for child in model.find_children("*", "MeshInstance3D"):
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		
		# If the mesh has an active material from the GLB, duplicate and override it
		# to set metallic=0.0 and roughness=0.85 (high metallic in a scene without reflection probes
		# renders pitch black because it reflects the black void outer bounds).
		var bare := true
		for s in mi.mesh.get_surface_count():
			var mat = mi.get_active_material(s)
			if mat is BaseMaterial3D:
				bare = false
				var unique_mat = mat.duplicate() as BaseMaterial3D
				unique_mat.metallic = 0.0
				unique_mat.roughness = 0.85
				mi.set_surface_override_material(s, unique_mat)
				
		if not bare:
			continue
			
		if tin == null:
			tin = StandardMaterial3D.new()
			tin.metallic = 0.0
			tin.roughness = 0.85
			if ResourceLoader.exists(LID_TEX):
				tin.albedo_texture = load(LID_TEX)
				# source mesh spans ~±1 unit → map the label once across it
				tin.uv1_triplanar = true
				tin.uv1_scale = Vector3(0.5, 0.5, 0.5)
				tin.uv1_offset = Vector3(0.5, 0.5, 0.5)
			else:
				tin.albedo_color = Color(0.16, 0.15, 0.13)
		mi.material_override = tin


var _last_snus_pickup_time := 0.0
var _hint_cooldown := 180.0   # 3 minutes without finding a Snus tin

func _process(delta: float) -> void:
	_time += delta
	# Slow spin only — the tin sits ON the floor, never floats. (The old bob
	# fought ground_model and made it hover.) Tins outside the built world
	# stay invisible so they never ghost through the unrendered dark.
	for id in _boxes:
		var b: Node3D = _boxes[id]
		if is_instance_valid(b):
			b.rotation.y += delta * 0.9
			if is_instance_valid(_local_player):
				b.visible = b.global_position.distance_squared_to( \
					_local_player.global_position) < VISIBLE_RANGE * VISIBLE_RANGE

	# 3-Minute Snus Hint System: If 180 seconds pass without collecting a Snus, give a compass hint!
	if _collected.size() < TOTAL:
		if _time - _last_snus_pickup_time >= _hint_cooldown:
			_last_snus_pickup_time = _time - 60.0  # reset to 60s so next hint arrives in 2 mins if still stuck
			_emit_snus_hint()

func _emit_snus_hint() -> void:
	if not is_instance_valid(_local_player):
		return
	var nearest_pos := Vector3.ZERO
	var best_d := 999999.0
	for id in _boxes:
		if _collected.has(id):
			continue
		var b: Node3D = _boxes[id]
		if not is_instance_valid(b):
			continue
		var d := _local_player.global_position.distance_to(b.global_position)
		if d < best_d:
			best_d = d
			nearest_pos = b.global_position

	if best_d > 900000.0:
		return

	var dir_name := _get_cardinal_direction(_local_player.global_position, nearest_pos)
	var hint_msg := "◇ HINT: A faint glint of tin echoes from the %s..." % dir_name

	var hud := get_node_or_null("/root/GameWorld/_snus_ui")
	if is_instance_valid(hud) and hud.has_method("announce"):
		hud.announce(hint_msg, 6.0)

	if has_node("/root/AudioManager") and ResourceLoader.exists(PICKUP_SFX):
		AudioManager.play_sfx(load(PICKUP_SFX), -6.0, 0.75)

func _get_cardinal_direction(from_pos: Vector3, to_pos: Vector3) -> String:
	var diff := to_pos - from_pos
	var angle := atan2(-diff.z, diff.x)
	var deg := rad_to_deg(angle)
	if deg < 0:
		deg += 360.0

	if deg >= 337.5 or deg < 22.5:
		return "EAST"
	elif deg >= 22.5 and deg < 67.5:
		return "NORTH-EAST"
	elif deg >= 67.5 and deg < 112.5:
		return "NORTH"
	elif deg >= 112.5 and deg < 157.5:
		return "NORTH-WEST"
	elif deg >= 157.5 and deg < 202.5:
		return "WEST"
	elif deg >= 202.5 and deg < 247.5:
		return "SOUTH-WEST"
	elif deg >= 247.5 and deg < 292.5:
		return "SOUTH"
	else:
		return "SOUTH-EAST"

func _nearest_uncollected(from: Vector3) -> int:
	var best := -1
	var best_d := PICKUP_RANGE
	for id in _boxes:
		if _collected.has(id):
			continue
		var b: Node3D = _boxes[id]
		if not is_instance_valid(b):
			continue
		var d := Vector3(b.global_position.x - from.x, 0.0, b.global_position.z - from.z).length()
		if d < best_d:
			best_d = d
			best = id
	return best


## The world interaction coordinator owns the E key so one press can never
## answer a phone, enter a locker, and collect a tin at the same time.
func collect_nearest(from: Vector3) -> bool:
	var id := _nearest_uncollected(from)
	if id < 0:
		return false
	var net_manager := get_node_or_null("/root/NetManager")
	if net_manager and bool(net_manager.get("is_multiplayer")) and not bool(net_manager.get("is_host")):
		net_manager.call("send", "snus_request", {"id": id})
		return true
	_do_collect(id, true)
	return true

func host_collect_id(id: int, collector_position: Vector3) -> bool:
	if _collected.has(id):
		return false
	var box: Node3D = _boxes.get(id)
	if not is_instance_valid(box):
		return false
	var flat_delta := Vector2(box.global_position.x - collector_position.x, box.global_position.z - collector_position.z)
	if flat_delta.length() > PICKUP_RANGE + 1.2:
		return false
	_do_collect(id, true)
	return true


func _do_collect(id: int, broadcast: bool) -> void:
	if _collected.has(id):
		return
	_last_snus_pickup_time = _time
	_collected[id] = true
	var b = _boxes.get(id)
	var pickup_position: Vector3 = b.global_position if b and is_instance_valid(b) else Vector3.ZERO
	if b and is_instance_valid(b):
		b.queue_free()
	_boxes.erase(id)

	var audio_manager := get_node_or_null("/root/AudioManager")
	if audio_manager and _pickup_stream:
		audio_manager.call("play_sfx_3d", self, _pickup_stream, pickup_position, -5.0, 18.0, 1.0)

	# Co-op: tell everyone this tin is gone.
	var net_manager := get_node_or_null("/root/NetManager")
	if broadcast and net_manager and bool(net_manager.get("is_multiplayer")):
		net_manager.call("send", "snus", {"id": id})

	var n := _collected.size()
	count_changed.emit(n, TOTAL)
	if n >= TOTAL:
		if audio_manager and _unlock_stream:
			audio_manager.call("play_sfx", _unlock_stream, -2.0)
		all_collected.emit()


# Called by the world when a network "snus" message arrives.
func remote_collect(id: int) -> void:
	_do_collect(id, false)


func get_collected() -> int:
	return _collected.size()

func get_spawn_cells() -> Array[Vector2i]:
	return _spawn_cells.duplicate()

func get_nearest_uncollected_pos(from: Vector3) -> Vector3:
	var best_pos := Vector3.ZERO
	var best_d := 999999.0
	for id in _boxes:
		if _collected.has(id):
			continue
		var b: Node3D = _boxes[id]
		if not is_instance_valid(b):
			continue
		# Compute 3D distance
		var d := from.distance_to(b.global_position)
		if d < best_d:
			best_d = d
			best_pos = b.global_position
	return best_pos


func is_snus_in_range(from: Vector3) -> bool:
	return _nearest_uncollected(from) >= 0
