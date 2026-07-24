extends Node3D
## Optional, deterministic world content: one persistent cassette, physical
## notes, blood traces and anomalous sectors. It deliberately does not own the
## main SNUS/emergency-button/exit progression.

signal cassette_collected
signal anomaly_entered(kind: String, center: Vector2i)
signal anomaly_left(kind: String, center: Vector2i)

const CELL := 4.0
const CASSETTE_CELL := Vector2i(-4, 13)
const INTERACT_RANGE := 2.4
const HAND_FONT_PATH := "res://assets/fonts/caveat.ttf"
const BLOOD_TRAIL_TEXTURE: Texture2D = preload("res://assets/textures/decals/blood_trail.png")
const BLOOD_WALL_TEXTURE: Texture2D = preload("res://assets/textures/decals/blood_wall_end.png")
const BLOOD_VISIBLE_DISTANCE := 42.0
const BLOOD_TRAIL_CANDIDATES := [
	Vector2i(-11, 9), Vector2i(10, 7), Vector2i(-12, -8),
	Vector2i(8, -12), Vector2i(-13, 2), Vector2i(4, 13),
]
const ANOMALY_ZONES := [
	{"center": Vector2i(-10, 10), "kind": "echo"},
	{"center": Vector2i(10, 9), "kind": "dead_light"},
	{"center": Vector2i(-9, -10), "kind": "repetition"},
]
const PAMPHLET_LOCATIONS := [
	{"cell": Vector2i(-7, 7), "floor": false},
	{"cell": Vector2i(9, 4), "floor": true},
	{"cell": Vector2i(-11, -7), "floor": false},
	{"cell": Vector2i(6, -11), "floor": true},
	{"cell": Vector2i(1, 12), "floor": false},
	{"cell": Vector2i(12, -3), "floor": true},
	{"cell": Vector2i(-4, -12), "floor": false},
	{"cell": Vector2i(-13, 8), "floor": true},
	{"cell": Vector2i(8, 11), "floor": false},
	{"cell": Vector2i(11, -9), "floor": true},
]

const ADVICE_TEXTS := [
	"Don't let it see you",
	"It's faster than humans",
	"If the phone rings, don't answer if he is close",
	"Listen for heavy footsteps before rounding corners",
	"5 to escape",
	"It hates noise",
]

const ALL_PHOTOS := [
	"res://assets/images/foto_1.png",
	"res://assets/images/foto_2.png",
	"res://assets/images/foto_3.png",
	"res://assets/images/foto_4.png",
	"res://assets/images/foto_5.png",
]

var _player: Node3D
var _maze: Node3D
var _cassette: Node3D
var _active_anomaly := -1
var _pamphlets: Array[Node3D] = []
var _reading_note := false
var _read_canvas: CanvasLayer = null
var _handwriting: Font = null
var _run_seed := 1
var _blood_root: Node3D = null

func set_run_seed(value: int) -> void:
	_run_seed = maxi(1, value)

func setup(player: Node3D, maze: Node3D) -> void:
	_player = player
	_maze = maze
	_spawn_blood_trail()

func _ready() -> void:
	if ResourceLoader.exists(HAND_FONT_PATH):
		_handwriting = load(HAND_FONT_PATH)
	_spawn_pamphlets()
	if not has_node("/root/GameManager") or not GameManager.cassette_found:
		_spawn_cassette()

func _process(_delta: float) -> void:
	if is_instance_valid(_cassette):
		_cassette.rotation.y += 0.012
	if is_instance_valid(_blood_root) and is_instance_valid(_player):
		_blood_root.visible = _player.global_position.distance_squared_to( \
			_blood_root.global_position) <= BLOOD_VISIBLE_DISTANCE * BLOOD_VISIBLE_DISTANCE
	_tick_anomaly_zone()

func _world(cell: Vector2i) -> Vector3:
	return Vector3(cell.x * CELL, 0.0, cell.y * CELL)

## One strong environmental story beat per run. It is deliberately unsigned
## and non-interactive: the trail narrows into the intact wall and lets the
## player decide whether something crossed it or the corridor moved afterwards.
func _spawn_blood_trail() -> void:
	if is_instance_valid(_blood_root) or not is_instance_valid(_maze):
		return
	if not _maze.has_method("wall_mount_near"):
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x424C4F4F
	var mount: Dictionary = {}
	var first_index := rng.randi_range(0, BLOOD_TRAIL_CANDIDATES.size() - 1)
	for offset in BLOOD_TRAIL_CANDIDATES.size():
		var cell: Vector2i = BLOOD_TRAIL_CANDIDATES[(first_index + offset) % BLOOD_TRAIL_CANDIDATES.size()]
		mount = _maze.wall_mount_near(cell, 0.82)
		if not mount.is_empty():
			break
	if mount.is_empty():
		return

	_blood_root = Node3D.new()
	_blood_root.name = "BloodTrailOccurrence"
	add_child(_blood_root)
	var wall_position: Vector3 = mount["position"]
	_blood_root.global_position = Vector3(wall_position.x, 0.0, wall_position.z)
	_blood_root.rotation.y = float(mount["rotation_y"])
	_blood_root.set_meta("wall_cell", mount["cell"])
	_blood_root.set_meta("run_seed", _run_seed)

	# All four marks remain inside the wall's walkable cell. Their small lateral
	# offsets and overlaps read as one dragged trace without looking tiled.
	var floor_marks: Array[Dictionary] = [
		{"z": 0.52, "width": 1.12, "length": 1.08, "alpha": 0.86},
		{"z": 1.30, "width": 0.98, "length": 1.14, "alpha": 0.79},
		{"z": 2.12, "width": 0.86, "length": 1.18, "alpha": 0.71},
		{"z": 2.98, "width": 0.72, "length": 1.02, "alpha": 0.62},
	]
	for index in floor_marks.size():
		var spec: Dictionary = floor_marks[index]
		var mark := MeshInstance3D.new()
		mark.name = "FloorStain_%02d" % index
		var quad := QuadMesh.new()
		quad.size = Vector2(float(spec["width"]), float(spec["length"]))
		mark.mesh = quad
		mark.material_override = _blood_material(BLOOD_TRAIL_TEXTURE, float(spec["alpha"]))
		mark.position = Vector3(rng.randf_range(-0.10, 0.10), 0.008, float(spec["z"]))
		mark.rotation_degrees.x = -90.0
		mark.rotation.y = rng.randf_range(-0.09, 0.09)
		_configure_blood_surface(mark)
		_blood_root.add_child(mark)

	# A QuadMesh faces local +Z, which is also the guaranteed walkable side of
	# the chosen wall mount. Eight millimetres of separation prevents z-fighting.
	var wall_stain := MeshInstance3D.new()
	wall_stain.name = "WallEndStain"
	var wall_quad := QuadMesh.new()
	wall_quad.size = Vector2(1.90, 1.82)
	wall_stain.mesh = wall_quad
	wall_stain.material_override = _blood_material(BLOOD_WALL_TEXTURE, 0.82)
	wall_stain.position = Vector3(-0.04, 0.88, 0.008)
	wall_stain.rotation.z = deg_to_rad(rng.randf_range(-3.5, 3.5))
	_configure_blood_surface(wall_stain)
	_blood_root.add_child(wall_stain)
	_blood_root.visible = false

func _blood_material(texture: Texture2D, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = texture
	material.albedo_color = Color(0.72, 0.61, 0.54, alpha)
	material.roughness = 0.96
	material.cull_mode = BaseMaterial3D.CULL_BACK
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material

func _configure_blood_surface(surface: GeometryInstance3D) -> void:
	surface.visibility_range_end = BLOOD_VISIBLE_DISTANCE
	surface.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

func _spawn_cassette() -> void:
	_cassette = Node3D.new()
	_cassette.name = "UniqueCassette"
	add_child(_cassette)
	_cassette.global_position = _world(CASSETTE_CELL) + Vector3(0, 0.08, 0)
	var body := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.34, 0.08, 0.22)
	body.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.1, 0.07)
	mat.roughness = 0.85
	body.material_override = mat
	_cassette.add_child(body)
	var label := Label3D.new()
	label.text = "TAPE 01"
	label.font_size = 32
	label.pixel_size = 0.0025
	label.position = Vector3(0, 0.05, 0)
	label.rotation_degrees.x = -90.0
	label.modulate = Color(0.82, 0.72, 0.48)
	_cassette.add_child(label)
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.75, 0.55, 0.2)
	glow.light_energy = 0.8
	glow.omni_range = 1.4
	glow.shadow_enabled = false
	glow.position.y = 0.3
	_cassette.add_child(glow)

func _shuffle_with_rng(values: Array, rng: RandomNumberGenerator) -> void:
	# Array.shuffle() uses the process-global RNG.  That made co-op peers with
	# the same run seed select different notes and locations.
	for index in range(values.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var held = values[index]
		values[index] = values[swap_index]
		values[swap_index] = held


func _spawn_pamphlets() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x4E4F5445

	# 1. Pick 5 location candidates out of the available map locations
	var available_locations := PAMPHLET_LOCATIONS.duplicate()
	_shuffle_with_rng(available_locations, rng)
	var selected_locations: Array[Dictionary] = []
	for i in range(min(5, available_locations.size())):
		selected_locations.append(available_locations[i])

	# 2. Pick 2 distinct random photos out of the 5 available photos
	var available_photos := ALL_PHOTOS.duplicate()
	_shuffle_with_rng(available_photos, rng)
	var selected_photos: Array[String] = []
	for i in range(min(2, available_photos.size())):
		selected_photos.append(available_photos[i])

	# 3. Pick 3 distinct random texts out of the 6 advice texts
	var available_texts := ADVICE_TEXTS.duplicate()
	_shuffle_with_rng(available_texts, rng)
	var selected_texts: Array[String] = []
	for i in range(min(3, available_texts.size())):
		selected_texts.append(available_texts[i])

	# 4. Combine into 5 notes: 2 photos + 3 texts, then shuffle the assignment order
	var note_contents: Array[Dictionary] = []
	for p in selected_photos:
		note_contents.append({"image": p, "text": ""})
	for t in selected_texts:
		note_contents.append({"image": "", "text": t})
	_shuffle_with_rng(note_contents, rng)

	# 5. Instantiate 5 3D note props
	for index in selected_locations.size():
		var spec: Dictionary = selected_locations[index]
		var content: Dictionary = note_contents[index]

		var root := Node3D.new()
		root.name = "Pamphlet_%02d" % index
		add_child(root)

		var note_image: String = String(content["image"])
		var note_text: String = String(content["text"])

		root.set_meta("note_image", note_image)
		root.set_meta("note_text", note_text)

		if bool(spec["floor"]):
			root.global_position = _world(spec["cell"]) + Vector3(0, 0.003, 0)
			root.rotation_degrees.x = -90.0
			root.rotation_degrees.z = float(index * 37 % 70 - 35)
		else:
			var mount: Dictionary = _maze.wall_mount_near(spec["cell"], 1.3) if _maze and _maze.has_method("wall_mount_near") else {}
			if mount.is_empty():
				# A rare procedural wall mismatch must not silently reduce the
				# requested five notes.  Fall back to the floor of that same cell.
				root.global_position = _world(spec["cell"]) + Vector3(0, 0.003, 0)
				root.rotation_degrees.x = -90.0
				root.rotation_degrees.z = float(index * 37 % 70 - 35)
			else:
				root.global_position = mount["position"]
				root.rotation.y = float(mount["rotation_y"])

		var paper := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.68, 0.48)
		paper.mesh = quad
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.64, 0.59, 0.43)
		mat.roughness = 1.0
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

		if note_image != "" and ResourceLoader.exists(note_image):
			var tex = load(note_image) as Texture2D
			if tex:
				mat.albedo_texture = tex
				mat.albedo_color = Color(0.85, 0.85, 0.85)

		paper.material_override = mat
		root.add_child(paper)

		var words := Label3D.new()
		words.text = "[PHOTO]" if note_image != "" else "..."
		words.font_size = 52
		words.pixel_size = 0.0022
		words.modulate = Color(0.10, 0.075, 0.045)
		words.outline_size = 0
		words.position.z = 0.006
		if _handwriting:
			words.font = _handwriting
		root.add_child(words)
		_pamphlets.append(root)

func nearest_kind(from: Vector3) -> String:
	if _reading_note:
		return "pamphlet"
	if is_instance_valid(_cassette) and from.distance_to(_cassette.global_position) <= INTERACT_RANGE:
		return "cassette"
	if is_instance_valid(_nearest_pamphlet(from)):
		return "pamphlet"
	return ""

func prompt(from: Vector3) -> String:
	match nearest_kind(from):
		"cassette": return "TAKE THE CASSETTE"
		"pamphlet": return "CLOSE NOTE" if _reading_note else "OPEN NOTE"
	return ""

func tick_interaction(_delta: float) -> bool:
	if not is_instance_valid(_player):
		return false
	if _reading_note:
		if Input.is_action_just_pressed("interact"):
			_close_pamphlet()
		return true
	var kind := nearest_kind(_player.global_position)
	if kind == "cassette" and Input.is_action_just_pressed("interact"):
		_collect_cassette()
		return true
	if kind == "pamphlet" and Input.is_action_just_pressed("interact"):
		var pamphlet := _nearest_pamphlet(_player.global_position)
		if is_instance_valid(pamphlet):
			_open_pamphlet(pamphlet)
			return true
	return kind != ""

func _nearest_pamphlet(from: Vector3) -> Node3D:
	var best: Node3D = null
	var best_distance := INTERACT_RANGE
	for pamphlet in _pamphlets:
		if not is_instance_valid(pamphlet):
			continue
		var distance := from.distance_to(pamphlet.global_position)
		if distance < best_distance:
			best_distance = distance
			best = pamphlet
	return best

func _open_pamphlet(pamphlet: Node3D) -> void:
	if _reading_note or not is_instance_valid(pamphlet):
		return
	_reading_note = true
	if _player.has_method("set_frozen"):
		_player.set_frozen(true, false)
	elif "frozen" in _player:
		_player.frozen = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	_read_canvas = CanvasLayer.new()
	_read_canvas.layer = 40
	add_child(_read_canvas)
	var dim := ColorRect.new()
	dim.color = Color(0.015, 0.012, 0.008, 0.82)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_read_canvas.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var paper := PanelContainer.new()
	paper.custom_minimum_size = Vector2(760, 540)
	_read_canvas.add_child(paper)
	paper.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	paper.offset_left = -380.0
	paper.offset_right = 380.0
	paper.offset_top = -270.0
	paper.offset_bottom = 270.0
	var paper_style := StyleBoxFlat.new()
	paper_style.bg_color = Color(0.69, 0.63, 0.46, 1.0)
	paper_style.border_color = Color(0.26, 0.20, 0.12, 0.9)
	paper_style.set_border_width_all(3)
	paper_style.set_corner_radius_all(3)
	paper_style.shadow_color = Color(0, 0, 0, 0.65)
	paper_style.shadow_size = 18
	paper.add_theme_stylebox_override("panel", paper_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 34)
	margin.add_theme_constant_override("margin_right", 34)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 24)
	paper.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	var img_path: String = String(pamphlet.get_meta("note_image", ""))
	var text_content: String = String(pamphlet.get_meta("note_text", ""))

	if img_path != "" and ResourceLoader.exists(img_path):
		var tex = load(img_path) as Texture2D
		if tex:
			var img_rect := TextureRect.new()
			img_rect.texture = tex
			img_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			img_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			img_rect.custom_minimum_size = Vector2(680, 420)
			img_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
			img_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			column.add_child(img_rect)
	else:
		var note := Label.new()
		note.text = text_content
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.size_flags_vertical = Control.SIZE_EXPAND_FILL
		note.add_theme_font_size_override("font_size", 42)
		note.add_theme_color_override("font_color", Color(0.105, 0.075, 0.04))
		if _handwriting:
			note.add_theme_font_override("font", _handwriting)
		column.add_child(note)

	var hint := Label.new()
	hint.text = "PRESS E TO CLOSE"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.20, 0.15, 0.09, 0.72))
	if _handwriting:
		hint.add_theme_font_override("font", _handwriting)
	column.add_child(hint)

func _close_pamphlet() -> void:
	if not _reading_note:
		return
	_reading_note = false
	if is_instance_valid(_read_canvas):
		_read_canvas.queue_free()
	_read_canvas = null
	if is_instance_valid(_player) and _player.has_method("set_frozen"):
		_player.set_frozen(false)
	elif is_instance_valid(_player) and "frozen" in _player:
		_player.frozen = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _collect_cassette() -> void:
	if has_node("/root/GameManager"):
		GameManager.unlock_cassette()
	if is_instance_valid(_cassette):
		_cassette.queue_free()
	_cassette = null
	cassette_collected.emit()

func remote_collect_cassette() -> void:
	if not is_instance_valid(_cassette):
		return
	_collect_cassette()


func _tick_anomaly_zone() -> void:
	if not is_instance_valid(_player):
		return
	var cell := Vector2i(
		int(floor(_player.global_position.x / CELL + 0.5)),
		int(floor(_player.global_position.z / CELL + 0.5)))
	var found := -1
	for index in ANOMALY_ZONES.size():
		var center: Vector2i = ANOMALY_ZONES[index]["center"]
		if maxi(abs(cell.x - center.x), abs(cell.y - center.y)) <= 1:
			found = index
			break
	if found == _active_anomaly:
		return
	if _active_anomaly >= 0:
		var previous: Dictionary = ANOMALY_ZONES[_active_anomaly]
		anomaly_left.emit(str(previous["kind"]), previous["center"])
	_active_anomaly = found
	if found >= 0:
		var zone: Dictionary = ANOMALY_ZONES[found]
		anomaly_entered.emit(str(zone["kind"]), zone["center"])
