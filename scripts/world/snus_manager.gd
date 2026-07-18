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
const SNUS_PATH := "res://assets/props/items/snus_box.glb"
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
var _boxes: Dictionary = {}           # id:int -> Node3D
var _collected: Dictionary = {}       # id:int -> true
var _snus_scene: PackedScene = null
var _pickup_stream: AudioStream = null
var _unlock_stream: AudioStream = null
var _time := 0.0


func setup(local_player: Node3D) -> void:
	_local_player = local_player


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


func _spawn_all() -> void:
	for i in SPAWN_CELLS.size():
		var cell: Vector2i = SPAWN_CELLS[i]
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
		ModelUtils.scale_to_height(model, 0.12)
		ModelUtils.ground_model(model, 0.0)
		# lift onto a subtle pedestal-of-nothing at ankle height so it reads
		root.position.y = 0.15
	else:
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.09
		cyl.bottom_radius = 0.09
		cyl.height = 0.05
		mi.mesh = cyl
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.5, 0.42, 0.28)
		mi.material_override = mat
		root.add_child(mi)
		root.position.y = 0.2

	# A soft glow so the tin is findable in the gloom without a HUD marker.
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.9, 0.55)
	glow.light_energy = 0.9
	glow.omni_range = 3.2
	glow.shadow_enabled = false
	glow.position = Vector3(0, 0.4, 0)
	root.add_child(glow)

	_boxes[id] = root


func _process(delta: float) -> void:
	_time += delta
	# gentle bob + spin so tins catch the eye
	for id in _boxes:
		var b: Node3D = _boxes[id]
		if is_instance_valid(b):
			b.rotation.y += delta * 1.2
			for c in b.get_children():
				if c is Node3D and not (c is OmniLight3D):
					(c as Node3D).position.y = 0.02 * sin(_time * 2.0 + float(id))

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
