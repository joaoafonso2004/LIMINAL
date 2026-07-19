extends Node3D
## Scatters 5 snus tins across the maze at FIXED cell centers (deterministic,
## so every co-op client agrees on where they are). Collect all 5 and the way
## out unlocks. Pickup is proximity + E. In co-op, pickups are shared: picking
## one up broadcasts it and it vanishes for everyone.

signal count_changed(collected: int, total: int)
signal all_collected()

const TOTAL := 5
const CELL := 4.0                 # must match maze_manager CELL
const PICKUP_RANGE := 2.2
# Tins beyond the streamed-wall horizon (VIEW_RADIUS 6 cells ≈ 24 m) would
# float visibly in the unbuilt void — cap their visibility safely inside it.
const VISIBLE_RANGE := 18.0
const SNUS_PATH := "res://assets/props/items/SNUS.glb"
const PICKUP_SFX := "res://assets/audio/sfx/pickup/pickup_snus_pickup.mp3"
const UNLOCK_SFX := "res://assets/audio/sfx/pickup/pickup_escape_unlocked.mp3"

# Fixed spawn cells, spread wide around the origin start room. Cell centers are
# always open floor, so tins never bury in a wall.
const SPAWN_CELLS := [
	Vector2i(9, 2), Vector2i(-3, 10), Vector2i(-11, -4),
	Vector2i(6, -12), Vector2i(-9, 7),
]

var _players: Array[Node3D] = []      # local + remote bodies to test proximity against
var _local_player: Node3D = null
var _maze: Node3D = null
var _boxes: Dictionary = {}           # id:int -> Node3D
var _collected: Dictionary = {}       # id:int -> true
var _snus_scene: PackedScene = null
var _pickup_stream: AudioStream = null
var _unlock_stream: AudioStream = null
var _time := 0.0


func setup(local_player: Node3D, maze: Node3D) -> void:
	_local_player = local_player
	_maze = maze


func _ready() -> void:
	if ResourceLoader.exists(SNUS_PATH):
		_snus_scene = load(SNUS_PATH)
	if ResourceLoader.exists(PICKUP_SFX):
		_pickup_stream = load(PICKUP_SFX)
	if ResourceLoader.exists(UNLOCK_SFX):
		_unlock_stream = load(UNLOCK_SFX)
	_spawn_all()


func register_player_body(body: Node3D) -> void:
	# Remote teammates can also collect; register their bodies for proximity.
	if body and not _players.has(body):
		_players.append(body)


func _generate_spawn_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var rng := RandomNumberGenerator.new()
	
	# Determine seed from NetManager room code or randomize for single player
	var seed_val := 0
	if has_node("/root/NetManager") and NetManager.is_multiplayer and NetManager.room_code != "":
		for byte in NetManager.room_code.to_utf8_buffer():
			seed_val = (seed_val * 33 + byte) & 0xFFFFFFFF
		rng.seed = seed_val
	else:
		rng.randomize()
		
	# 5 Sectors: NW, NE, SW, SE, and Center/Outer
	var sectors := [
		[Rect2i(-14, 4, 11, 11), "NW"],
		[Rect2i(4, 4, 11, 11), "NE"],
		[Rect2i(-14, -14, 11, 11), "SW"],
		[Rect2i(4, -14, 11, 11), "SE"],
		[Rect2i(-13, -13, 26, 26), "Outer"]
	]
	
	for sec in sectors:
		var rect: Rect2i = sec[0]
		var found := false
		var attempts := 0
		while not found and attempts < 400:
			attempts += 1
			var x := rng.randi_range(rect.position.x, rect.position.x + rect.size.x - 1)
			var y := rng.randi_range(rect.position.y, rect.position.y + rect.size.y - 1)
			var c := Vector2i(x, y)
			
			# Avoid starting room (radius 3)
			if abs(x) <= 3 and abs(y) <= 3:
				continue
				
			# Avoid exit cell neighborhood
			if c.distance_squared_to(Vector2i(14, -16)) < 9:
				continue
				
			# Verify distance from all existing cells (min 9 cells / 36 meters)
			var too_close := false
			for existing in cells:
				if existing.distance_to(c) < 9.0:
					too_close = true
					break
			if too_close:
				continue
				
			# Verify it's an open cell in the maze layout
			if _maze and _maze.has_method("is_cell_open"):
				if not _maze.is_cell_open(c):
					continue
					
			cells.append(c)
			found = true
			
	# Fallback if generation failed
	if cells.size() < TOTAL:
		cells = [
			Vector2i(10, 8), Vector2i(-9, 10), Vector2i(-11, -8),
			Vector2i(8, -12), Vector2i(-8, 3)
		]
	return cells


func _spawn_all() -> void:
	var spawn_cells := _generate_spawn_cells()
	for i in spawn_cells.size():
		var cell: Vector2i = spawn_cells[i]
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
				b.visible = b.global_position.distance_to(_local_player.global_position) < VISIBLE_RANGE

	# Local proximity pickup on E.
	if is_instance_valid(_local_player) and Input.is_action_just_pressed("interact"):
		var pid := _nearest_uncollected(_local_player.global_position)
		if pid >= 0:
			_do_collect(pid, true)


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


func _do_collect(id: int, broadcast: bool) -> void:
	if _collected.has(id):
		return
	_collected[id] = true
	var b = _boxes.get(id)
	if b and is_instance_valid(b):
		b.queue_free()
	_boxes.erase(id)

	if has_node("/root/AudioManager") and _pickup_stream:
		AudioManager.play_sfx(_pickup_stream, -4.0)

	# Co-op: tell everyone this tin is gone.
	if broadcast and has_node("/root/NetManager") and NetManager.is_multiplayer:
		NetManager.send("snus", {"id": id})

	var n := _collected.size()
	count_changed.emit(n, TOTAL)
	if n >= TOTAL:
		if has_node("/root/AudioManager") and _unlock_stream:
			AudioManager.play_sfx(_unlock_stream, -2.0)
		all_collected.emit()


# Called by the world when a network "snus" message arrives.
func remote_collect(id: int) -> void:
	_do_collect(id, false)


func get_collected() -> int:
	return _collected.size()

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

