extends Node3D
## The Backrooms Level-0 floor. A streaming grid of cells around the player:
## open-plan halls held up by square pillars, broken by sparse wall slabs, lit
## by spaced fluorescent panels. The layout is STATIC — a pure function of cell
## coordinates — so every co-op client and every return trip sees the same
## rooms. Emits signals the world glue uses to drive fear, anomalies, and the
## single real exit.

signal entered_cell(cell: Vector2i)
signal anomaly_state_changed(in_anomaly: bool)
signal exit_spawned(world_pos: Vector3)
signal exit_reached()

const CELL: float = 4.0
const VIEW_RADIUS: int = 12         # cells kept around the player (48 m — no void at corridor ends)
const FREE_RADIUS: int = 14         # cells beyond this are released (bumps salt)
# Compatibility renderer has a hard 64-light budget. Reserve twelve for SNUS,
# props, extraction and short-lived effects. The maze share is a stable 360-degree
# pool around the player; camera rotation never changes which lamps are powered.
const MAX_STREAMED_LIGHTS: int = 52
# Look/layout knobs live in scripts/tuning.gd — edit there, not here.
const WALL_DENSITY: float = Tuning.WALL_DENSITY
const WALL_DENSITY_HALL: float = Tuning.WALL_DENSITY_HALL
const WALL_DENSITY_ROOM: float = Tuning.WALL_DENSITY_ROOM
const REGION_SIZE: int = Tuning.REGION_SIZE
const ROOM_ZONE_BIAS: float = Tuning.ROOM_ZONE_BIAS
const PILLAR_DENSITY: float = Tuning.PILLAR_DENSITY
const WALL_H: float = 3.0
const WALL_HALF_THICKNESS: float = 0.175
const WALL_MOUNT_GAP: float = 0.002
const START_CLEAR: int = 1          # Chebyshev radius kept open around origin
const PANEL_ENERGY: float = Tuning.PANEL_ENERGY
const LIGHT_ENERGY: float = Tuning.LIGHT_ENERGY
const DARK_ALCOVE_CHANCE: float = Tuning.DARK_ALCOVE_CHANCE
const ROOM_THRESHOLD_CHANCE: float = Tuning.ROOM_THRESHOLD_CHANCE
const MAP_DRESSING_CHANCE: float = Tuning.MAP_DRESSING_CHANCE

# Directions: 0 = East (+X edge owned by cell), 1 = North (+Z edge owned by cell)
const DIR_E: int = 0
const DIR_N: int = 1
const DIR_W: int = 2
const DIR_S: int = 3

var _player: Node3D = null
var _cells: Dictionary = {}          # Vector2i -> Dictionary
var _salt: Dictionary = {}           # Vector2i -> int
var _cur_cell: Vector2i = Vector2i(999, 999)
var _flicker: float = 0.0            # 0 = steady, higher = more flicker/panic
var _flicker_target: float = 0.0
var _time: float = 0.0

# Materials (built once)
var _wall_mat: StandardMaterial3D
var _wall_dirty_mat: StandardMaterial3D
var _wall_dark_mat: StandardMaterial3D
var _floor_mat: StandardMaterial3D
var _linoleum_mat: StandardMaterial3D
var _ceil_mat: StandardMaterial3D
var _panel_mat: StandardMaterial3D
var _exit_mat: StandardMaterial3D
var _void_mat: StandardMaterial3D
var _floor_dark_mat: StandardMaterial3D
var _alcove_wall_mat: StandardMaterial3D
var _alcove_ceil_mat: StandardMaterial3D
var _cardboard_mat: StandardMaterial3D
var _office_metal_mat: StandardMaterial3D
var _puddle_mat: StandardMaterial3D

# Exit state
var _exit_available: bool = false
var _exit_seal: StaticBody3D = null
var _exit_placed: bool = false
var _exit_area: Area3D = null
var _exit_cell: Vector2i = Vector2i.ZERO
var _exit_door_base := Vector3.ZERO
var _exit_forward := Vector3.FORWARD

# Prop scenes (anomalies / exit dressing)
var _chair_scene: PackedScene = null
var _phone_scene: PackedScene = null
var _exit_door_scene: PackedScene = null
var _office_door_scene: PackedScene = null
var _fixture_scene: PackedScene = null
var _wet_floor_scene: PackedScene = null

var _anomaly_cells: Dictionary = {}   # Vector2i -> true
var _powered_zones: Array[Dictionary] = []
var _static_layout: bool = true       # layout is a pure function of cell coords
var _run_seed: int = 1
var _phone_cells: Dictionary = {}
var _anchor_rooms: Dictionary = {}         # Vector2i -> Dictionary
var _anchor_archways: Dictionary = {}      # String "x,y,dir" -> bool

func setup(player: Node3D) -> void:
	_player = player

## The layout must be identical on every client (and every revisit), so the
## maze never rewrites behind anyone. Kept as a switch for future modes.
func set_static_layout(v: bool) -> void:
	_static_layout = v

func set_run_seed(value: int) -> void:
	_run_seed = maxi(1, value)
	_select_exit_cell()
	_prepare_phone_cells()
	_prepare_anchor_rooms()

func _ready() -> void:
	_build_materials()
	_load_props()
	if _exit_cell == Vector2i.ZERO:
		_select_exit_cell()
	if _phone_cells.is_empty():
		_prepare_phone_cells()
	if _anchor_rooms.is_empty():
		_prepare_anchor_rooms()

func _prepare_anchor_rooms() -> void:
	_anchor_rooms.clear()
	_anchor_archways.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x414E4348
	
	var specs := [
		{"kind": "red_room", "min_x": 4, "max_x": 10, "min_y": 4, "max_y": 10},
		{"kind": "flooded_lounge", "min_x": -10, "max_x": -4, "min_y": 4, "max_y": 10},
		{"kind": "archive_shrine", "min_x": 4, "max_x": 10, "min_y": -10, "max_y": -4},
	]
	
	for spec in specs:
		var ox := rng.randi_range(int(spec["min_x"]), int(spec["max_x"]))
		var oy := rng.randi_range(int(spec["min_y"]), int(spec["max_y"]))
		var origin := Vector2i(ox, oy)
		
		for dx in range(2):
			for dy in range(2):
				var c := origin + Vector2i(dx, dy)
				_anchor_rooms[c] = {
					"kind": spec["kind"],
					"origin": origin,
					"local_offset": Vector2i(dx, dy),
				}
		
		var outer_edges := [
			[origin + Vector2i(0, 0), DIR_W],
			[origin + Vector2i(0, 1), DIR_W],
			[origin + Vector2i(1, 0), DIR_E],
			[origin + Vector2i(1, 1), DIR_E],
			[origin + Vector2i(0, 0), DIR_S],
			[origin + Vector2i(1, 0), DIR_S],
			[origin + Vector2i(0, 1), DIR_N],
			[origin + Vector2i(1, 1), DIR_N],
		]
		
		var pick1: Array = outer_edges[rng.randi() % outer_edges.size()]
		var pick2: Array = outer_edges[rng.randi() % outer_edges.size()]
		_mark_archway(pick1[0], int(pick1[1]))
		_mark_archway(pick2[0], int(pick2[1]))

func _mark_archway(c: Vector2i, dir: int) -> void:
	if dir == DIR_W:
		c = Vector2i(c.x - 1, c.y)
		dir = DIR_E
	elif dir == DIR_S:
		c = Vector2i(c.x, c.y - 1)
		dir = DIR_N
	_anchor_archways["%d,%d,%d" % [c.x, c.y, dir]] = true

## Guaranteed phones, spread across the map and shared by seed. Walls remain
## static, so randomized content cannot desynchronize collision in co-op.
func _prepare_phone_cells() -> void:
	_phone_cells.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x50484F4E
	var sectors: Array[Rect2i] = [
		Rect2i(-15, -15, 15, 15), Rect2i(1, -15, 15, 15),
		Rect2i(-15, 1, 15, 15), Rect2i(1, 1, 15, 15),
		Rect2i(-10, -10, 21, 21), Rect2i(-15, -15, 31, 31),
	]
	for sector in sectors:
		var chosen := Vector2i(999, 999)
		for _attempt in 240:
			var candidate := Vector2i(
				rng.randi_range(sector.position.x, sector.end.x - 1),
				rng.randi_range(sector.position.y, sector.end.y - 1))
			if _cheb(candidate) < 3 or candidate.distance_squared_to(_exit_cell) < 9:
				continue
			if not is_cell_open(candidate) or corridor_path(candidate, Vector2i.ZERO, 1400).is_empty():
				continue
			var spread_ok := true
			for existing in _phone_cells.keys():
				if Vector2(existing).distance_to(Vector2(candidate)) < 5.0:
					spread_ok = false
					break
			if not spread_ok:
				continue
			chosen = candidate
			break
		if chosen.x != 999:
			_phone_cells[chosen] = true
		if _phone_cells.size() >= Tuning.PHONE_COUNT:
			break

func get_phone_cells() -> Array:
	return _phone_cells.keys()

func _build_materials() -> void:
	# Preserve the wallpaper's native fluorescent yellow instead of multiplying
	# it into orange/sepia. Variants stay close enough to avoid colour seams.
	_wall_mat = _mk_mat("res://assets/textures/walls/backrooms_yellow_wallpaper.png", Vector3(2, 1, 1.5), 0.92, Color(0.84, 0.84, 0.76))
	_wall_dirty_mat = _mk_mat("res://assets/textures/walls/backrooms_yellow_wallpaper.png", Vector3(2, 1, 1.5), 0.90, Color(0.72, 0.72, 0.64))
	_wall_dark_mat = _mk_mat("res://assets/textures/walls/backrooms_yellow_wallpaper.png", Vector3(2, 1, 1.5), 0.92, Color(0.78, 0.78, 0.69))

	# Cleaner commercial carpet: aged and faintly damp without baked-in mud
	# blotches. The neutral tint keeps its khaki-yellow fibres intact.
	_floor_mat = _mk_mat("res://assets/textures/floors/backrooms_carpet_clean.png", Vector3(2, 2, 1), 0.98, Color(0.82, 0.82, 0.72))
	_linoleum_mat = _mk_mat("res://assets/textures/floors/backrooms_linoleum.png", Vector3(2, 2, 1), 0.78, Color(0.82, 0.81, 0.68))
	_ceil_mat = _mk_mat("res://assets/textures/surfaces/backrooms_ceiling_tiles.png", Vector3(2, 2, 1), 0.95, Color(0.68, 0.68, 0.61))
	_panel_mat = StandardMaterial3D.new()
	_panel_mat.albedo_color = Color(0.92, 0.91, 0.78)
	_panel_mat.emission_enabled = true
	_panel_mat.emission = Color(1.0, 0.97, 0.80)
	_panel_mat.emission_energy_multiplier = PANEL_ENERGY
	_panel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_exit_mat = StandardMaterial3D.new()
	_exit_mat.albedo_color = Color(0.85, 0.95, 0.98)
	_exit_mat.emission_enabled = true
	_exit_mat.emission = Color(0.75, 0.95, 1.0)
	_exit_mat.emission_energy_multiplier = 2.2
	_exit_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_void_mat = StandardMaterial3D.new()
	_void_mat.albedo_color = Color(0.002, 0.002, 0.001)
	_void_mat.roughness = 1.0
	_void_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_void_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_floor_dark_mat = _mk_mat("res://assets/textures/floors/backrooms_carpet_clean.png", Vector3(2, 2, 1), 1.0, Color(0.19, 0.18, 0.14))
	# CX31 — the alcove interior used to be `_void_mat`: unshaded near-black
	# planes that read as a hole punched through the level, with a razor edge
	# where the lit yellow wall stopped. These are the SAME wallpaper/ceiling
	# surfaces as everywhere else, only very dark, so the one dim lamp inside
	# falls off across them and the recess reads as an unlit room.
	_alcove_wall_mat = _mk_mat("res://assets/textures/walls/backrooms_yellow_wallpaper.png", Vector3(2, 1, 1.5), 0.96, Color(0.115, 0.112, 0.086))
	_alcove_ceil_mat = _mk_mat("res://assets/textures/surfaces/backrooms_ceiling_tiles.png", Vector3(2, 2, 1), 0.98, Color(0.085, 0.084, 0.074))
	_cardboard_mat = StandardMaterial3D.new()
	_cardboard_mat.albedo_color = Color(0.34, 0.25, 0.14)
	_cardboard_mat.roughness = 0.96
	_office_metal_mat = StandardMaterial3D.new()
	_office_metal_mat.albedo_color = Color(0.23, 0.24, 0.20)
	_office_metal_mat.roughness = 0.82
	_puddle_mat = StandardMaterial3D.new()
	_puddle_mat.albedo_color = Color(0.08, 0.10, 0.065, 0.42)
	_puddle_mat.roughness = 0.22
	_puddle_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

func _mk_mat(path: String, uv: Vector3, rough: float, tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if ResourceLoader.exists(path):
		m.albedo_texture = load(path)
	m.uv1_scale = uv
	m.roughness = rough
	m.metallic = 0.0
	m.albedo_color = tint
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return m

func _load_props() -> void:
	_chair_scene = _load_scene("res://assets/props/furniture/broken_office_chair.glb")
	_phone_scene = _load_scene("res://assets/props/decorations/desk_phone_offhook.glb")
	_exit_door_scene = _load_scene("res://assets/props/decorations/exit_door_real.glb")
	_office_door_scene = _load_scene("res://assets/props/decorations/office_door_closed.glb")
	_fixture_scene = _load_scene("res://assets/props/decorations/fluorescent_tube_fixture.glb")
	_wet_floor_scene = _load_scene("res://assets/props/decorations/wet_floor_sign.glb")

func _load_scene(path: String) -> PackedScene:
	if ResourceLoader.exists(path):
		return load(path)
	return null

# ---------------------------------------------------------------------------
# Update loop
# ---------------------------------------------------------------------------
## While a downed player spectates a teammate, stream around THAT teammate so the
## map keeps generating ahead of them instead of only around the motionless body.
var _stream_focus_active := false
var _stream_focus_pos := Vector3.ZERO

func set_stream_focus(pos: Vector3) -> void:
	_stream_focus_active = true
	_stream_focus_pos = pos

func clear_stream_focus() -> void:
	_stream_focus_active = false

func _physics_process(delta: float) -> void:
	_time += delta
	if not is_instance_valid(_player) and not _stream_focus_active:
		return
	var focus: Vector3 = _stream_focus_pos if _stream_focus_active else _player.global_position
	var pc: Vector2i = _cell_of(focus)
	var cell_changed := pc != _cur_cell
	if cell_changed:
		_cur_cell = pc
		_stream(pc)
		entered_cell.emit(pc)
		_check_anomaly(pc)
		_maybe_place_exit(pc)

	# Light membership is spatial and camera-independent. It only changes when the
	# player crosses a cell, so looking around can never switch a lamp on or off.
	if cell_changed:
		_update_lights(pc)

func _process(delta: float) -> void:
	_animate_lights(delta)

func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / CELL + 0.5)), int(floor(p.z / CELL + 0.5)))

func world_center(c: Vector2i) -> Vector3:
	return Vector3(c.x * CELL, 0.0, c.y * CELL)

# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------
func _stream(center: Vector2i) -> void:
	# Build in-range cells
	for dx in range(-VIEW_RADIUS, VIEW_RADIUS + 1):
		for dz in range(-VIEW_RADIUS, VIEW_RADIUS + 1):
			var c := Vector2i(center.x + dx, center.y + dz)
			if abs(c.x) <= 16 and abs(c.y) <= 16:
				if not _cells.has(c):
					_build_cell(c)
	# Free out-of-range cells (bump salt so they regenerate differently)
	var to_free: Array = []
	for c in _cells.keys():
		if _exit_placed and c == _exit_cell:
			continue
		if abs(c.x - center.x) > FREE_RADIUS or abs(c.y - center.y) > FREE_RADIUS:
			to_free.append(c)
	for c in to_free:
		_free_cell(c)

func _salt_of(c: Vector2i) -> int:
	return _salt.get(c, 0)

func _wall_present(owner: Vector2i, dir: int) -> bool:
	# Carve an open starting room around the origin.
	var nb: Vector2i = owner + (Vector2i(1, 0) if dir == DIR_E else Vector2i(0, 1))
	if _cheb(owner) <= START_CLEAR and _cheb(nb) <= START_CLEAR:
		return false

	# Enforce hard boundaries between -16 and 16 (map is limited by solid walls)
	if abs(owner.x) > 16 or abs(owner.y) > 16 or abs(nb.x) > 16 or abs(nb.y) > 16:
		return true

	# Carve internal walls between cells of the SAME Anchor Room
	if _anchor_rooms.has(owner) and _anchor_rooms.has(nb):
		var info_a: Dictionary = _anchor_rooms[owner]
		var info_b: Dictionary = _anchor_rooms[nb]
		if info_a["origin"] == info_b["origin"]:
			return false

	# Carve open high archway entrances on Anchor Room perimeters
	if _anchor_archways.has("%d,%d,%d" % [owner.x, owner.y, dir]):
		return false

	var h := _hash3(owner.x, owner.y, dir * 131 + _salt_of(owner) * 977)
	return h < _local_wall_density(owner)

## Wall density for the region this cell sits in. A low-frequency field carves
## the map into room clusters (dense) and open pillared halls (sparse), giving
## the "randomly segmented" Level 0 feel instead of a uniform openness. Pure
## function of coords, so every co-op client agrees.
func _local_wall_density(owner: Vector2i) -> float:
	var rx := int(floor(float(owner.x) / float(REGION_SIZE)))
	var ry := int(floor(float(owner.y) / float(REGION_SIZE)))
	var field := _hash3(rx, ry, 909)
	if field >= ROOM_ZONE_BIAS:
		return WALL_DENSITY_HALL            # open pillared hall
	# room cluster: ramp from hall density at the zone edge up to full ROOM
	# density in the deepest room regions, so enclosure varies room to room.
	var intensity := 1.0 - field / maxf(ROOM_ZONE_BIAS, 0.001)
	return lerpf(WALL_DENSITY_HALL, WALL_DENSITY_ROOM, intensity)

## True where this cell sits in an open "hall" region (used to cluster pillars).
func _is_hall_region(c: Vector2i) -> bool:
	var rx := int(floor(float(c.x) / float(REGION_SIZE)))
	var ry := int(floor(float(c.y) / float(REGION_SIZE)))
	return _hash3(rx, ry, 909) >= ROOM_ZONE_BIAS

func _cheb(c: Vector2i) -> int:
	return max(abs(c.x), abs(c.y))

func _edge_between(a: Vector2i, b: Vector2i) -> bool:
	# Returns true if a wall stands between adjacent cells a and b.
	if b.x == a.x + 1 and b.y == a.y:
		return _wall_present(a, DIR_E)
	if b.x == a.x - 1 and b.y == a.y:
		return _wall_present(b, DIR_E)
	if b.y == a.y + 1 and b.x == a.x:
		return _wall_present(a, DIR_N)
	if b.y == a.y - 1 and b.x == a.x:
		return _wall_present(b, DIR_N)
	return true

func _hash3(x: int, y: int, s: int) -> float:
	var n: int = x * 374761393 + y * 668265263 + s * 2147483647
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0xFFFFFF) / float(0xFFFFFF)

func _build_cell(c: Vector2i) -> void:
	var root := Node3D.new()
	root.position = world_center(c)
	add_child(root)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	root.add_child(body)

	# Keep adjacent modular wall pieces in the same colour family. Strong
	# per-cell tints created visible seams that looked like mismatched assets.
	var fl_mat := _floor_mat
	var wl_mat := _wall_mat

	# Anchor Room custom theme materials
	if _anchor_rooms.has(c):
		var ainfo: Dictionary = _anchor_rooms[c]
		var akind: String = ainfo["kind"]
		if akind == "red_room":
			fl_mat = _linoleum_mat
			wl_mat = _wall_dirty_mat
		elif akind == "flooded_lounge":
			fl_mat = _floor_dark_mat
			wl_mat = _wall_dark_mat
		elif akind == "archive_shrine":
			fl_mat = _floor_dark_mat
			wl_mat = _alcove_wall_mat

	# Floor
	_add_box(root, body, Vector3(CELL, 0.1, CELL), Vector3(0, -0.05, 0), fl_mat, true)
	# Ceiling
	_add_box(root, body, Vector3(CELL, 0.1, CELL), Vector3(0, WALL_H + 0.05, 0), _ceil_mat, true)

	# Owned walls: East (+X) and North (+Z) — chunky slabs, like the reference.
	if _wall_present(c, DIR_E):
		_add_box(root, body, Vector3(0.35, WALL_H, CELL), Vector3(CELL * 0.5, WALL_H * 0.5, 0), wl_mat, true)
	if _wall_present(c, DIR_N):
		_add_box(root, body, Vector3(CELL, WALL_H, 0.35), Vector3(0, WALL_H * 0.5, CELL * 0.5), wl_mat, true)

	# High Open Archway Entrances for Anchor Rooms (no door barrier, 2.6m clearance)
	var key_e := "%d,%d,%d" % [c.x, c.y, DIR_E]
	var key_n := "%d,%d,%d" % [c.x, c.y, DIR_N]
	if _anchor_archways.has(key_e):
		_add_box(root, body, Vector3(0.35, 0.45, CELL), Vector3(CELL * 0.5, 2.775, 0), wl_mat, true)
	if _anchor_archways.has(key_n):
		_add_box(root, body, Vector3(CELL, 0.45, 0.35), Vector3(0, 2.775, CELL * 0.5), wl_mat, true)
	# Cap the far boundary so the fog edge isn't fully open where neighbors are
	# missing. These caps MUST collide: without a hitbox the player walks
	# straight through the fog-edge slab and falls out of the world. When the
	# neighbour streams in it builds an identical wall at the same spot, so the
	# overlap is harmless (same mesh, same collision).
	var west_owner := Vector2i(c.x - 1, c.y)
	if not _cells.has(west_owner) and _cheb(c) > START_CLEAR and _wall_present(west_owner, DIR_E):
		_add_box(root, body, Vector3(0.35, WALL_H, CELL), Vector3(-CELL * 0.5, WALL_H * 0.5, 0), wl_mat, true)
	var south_owner := Vector2i(c.x, c.y - 1)
	if not _cells.has(south_owner) and _cheb(c) > START_CLEAR and _wall_present(south_owner, DIR_N):
		_add_box(root, body, Vector3(CELL, WALL_H, 0.35), Vector3(0, WALL_H * 0.5, -CELL * 0.5), wl_mat, true)

	# Square pillar at this cell's +X/+Z corner: the open halls of Level 0 are
	# held up by loose grids of wallpapered columns. Concentrate them in the
	# open "hall" regions (denser room clusters have walls instead), so pillars
	# read as grouped grids rather than scattered evenly.
	var pillar_chance := PILLAR_DENSITY * (1.6 if _is_hall_region(c) else 0.35)
	if _cheb(c) > START_CLEAR and _hash3(c.x, c.y, 401) < pillar_chance:
		_add_box(root, body, Vector3(0.7, WALL_H, 0.7), Vector3(CELL * 0.5, WALL_H * 0.5, CELL * 0.5), wl_mat, true)

	# How open is this cell? (count open edges)
	var open_edges := 0
	for nb in [Vector2i(c.x + 1, c.y), Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y - 1)]:
		if not _edge_between(c, nb):
			open_edges += 1
	var open_directions := _open_directions(c)
	var reserved_cell := _cheb(c) < 3 or _phone_cells.has(c) or c == _exit_cell
	var formation := ""
	if not reserved_cell:
		formation = _place_room_formation(root, c, open_directions)

	# Not all fixtures burn alike: some run at barely half strength, giving
	# each pool its own character and leaving near-dark stretches between.
	var light_mult := lerpf(0.5, 1.0, _hash3(c.x, c.y, 77))
	var data := {
		"node": root, "light": null, "panel_mat": null,
		"dark": false, "anomaly": false, "exit": false,
		"formation": formation,
		"base_energy": PANEL_ENERGY * light_mult, "light_mult": light_mult,
		"flick_seed": _hash3(c.x, c.y, 7),
	}

	# Ceiling light panel (visual) — sparse: roughly half the open cells are lit,
	# so real pools of darkness sit between the panels.
	var give_light := open_edges >= 1 and _hash3(c.x, c.y, 51) > Tuning.LIT_THRESHOLD
	var is_dark_zone := formation == "dark_alcove" \
		or (open_edges >= 2 and _hash3(c.x, c.y, 88) < Tuning.DARK_ZONE_CHANCE)
	if is_dark_zone:
		give_light = false
		data["dark"] = true
	if give_light:
		# Wide rectangular fluorescent panel, flush with the tile grid.
		var pmat: StandardMaterial3D = _panel_mat.duplicate()
		var panel := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(1.9, 0.06, 0.9)
		panel.mesh = pm
		panel.material_override = pmat
		panel.position = Vector3(0, WALL_H - 0.06, 0)
		root.add_child(panel)
		data["panel_mat"] = pmat

	# Anomalies — only in open "room" cells, rare, and not too close to start.
	# (Open-plan cells almost all have 3+ open edges now, so keep the odds low.)
	if _phone_cells.has(c):
		_place_phone(root, c, data)
	if not _phone_cells.has(c) and open_edges >= 3 and _cheb(c) >= 3 and _hash3(c.x, c.y, 205) < Tuning.ANOMALY_CHANCE:
		_place_anomaly(root, c, data)
	if _anchor_rooms.has(c):
		var ainfo: Dictionary = _anchor_rooms[c]
		if ainfo["local_offset"] == Vector2i(0, 0):
			_place_anchor_room_landmark(root, body, ainfo["kind"])

	_cells[c] = data
	_apply_power_override(c, data)

func _apply_power_override(cell: Vector2i, data: Dictionary) -> void:
	for zone in _powered_zones:
		var center: Vector2i = zone["center"]
		if maxi(abs(cell.x - center.x), abs(cell.y - center.y)) > int(zone["radius"]):
			continue
		var enabled := bool(zone["enabled"])
		var pmat = data.get("panel_mat")
		if pmat is StandardMaterial3D:
			(pmat as StandardMaterial3D).emission_energy_multiplier = PANEL_ENERGY if enabled else 0.0
		var light = data.get("light")
		if light is OmniLight3D:
			(light as OmniLight3D).light_energy = LIGHT_ENERGY if enabled else 0.0

func _place_anchor_room_landmark(root: Node3D, body: StaticBody3D, kind: String) -> void:
	if kind == "red_room":
		var red_light := OmniLight3D.new()
		red_light.color = Color(1.0, 0.14, 0.04)
		red_light.omni_range = 14.0
		red_light.energy = 3.2
		red_light.position = Vector3(CELL * 0.5, 2.6, CELL * 0.5)
		red_light.shadow_enabled = true
		root.add_child(red_light)

		_add_box(root, body, Vector3(3.8, 0.02, 3.8), Vector3(CELL * 0.5, 0.01, CELL * 0.5), _puddle_mat, false)

		if is_instance_valid(_chair_scene):
			var chair = _chair_scene.instantiate()
			chair.position = Vector3(CELL * 0.4, 0.25, CELL * 0.4)
			chair.rotation = Vector3(1.2, 0.6, 0.7)
			root.add_child(chair)

	elif kind == "flooded_lounge":
		_add_box(root, body, Vector3(3.8, 0.02, 3.8), Vector3(CELL * 0.5, 0.01, CELL * 0.5), _puddle_mat, false)

		var cyan_panel := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(2.4, 0.06, 1.2)
		cyan_panel.mesh = pm
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = Color(0.18, 0.8, 0.96)
		cmat.emission_enabled = true
		cmat.emission = Color(0.12, 0.85, 1.0)
		cmat.emission_energy_multiplier = 3.2
		cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cyan_panel.material_override = cmat
		cyan_panel.position = Vector3(CELL * 0.5, WALL_H - 0.06, CELL * 0.5)
		root.add_child(cyan_panel)

		var cyan_light := OmniLight3D.new()
		cyan_light.color = Color(0.18, 0.8, 1.0)
		cyan_light.omni_range = 12.0
		cyan_light.energy = 2.5
		cyan_light.position = Vector3(CELL * 0.5, 2.5, CELL * 0.5)
		root.add_child(cyan_light)

		if is_instance_valid(_wet_floor_scene):
			var sign_node = _wet_floor_scene.instantiate()
			sign_node.position = Vector3(CELL * 0.5, 0.0, CELL * 0.5)
			root.add_child(sign_node)

	elif kind == "archive_shrine":
		var amber_light := OmniLight3D.new()
		amber_light.color = Color(0.98, 0.62, 0.2)
		amber_light.omni_range = 12.0
		amber_light.energy = 2.8
		amber_light.position = Vector3(CELL * 0.5, 2.6, CELL * 0.5)
		amber_light.shadow_enabled = true
		root.add_child(amber_light)

		# Spawn VHS TV & Player Deck in the Archive Shrine Anchor Room
		var vhs_script := load("res://scripts/world/vhs_tv_controller.gd")
		if vhs_script != null:
			var vhs_tv := Node3D.new()
			vhs_tv.set_script(vhs_script)
			vhs_tv.name = "VHSTV"
			vhs_tv.position = Vector3(CELL * 0.5, 0.0, CELL * 0.5)
			root.add_child(vhs_tv)

		if is_instance_valid(_chair_scene):
			for i in 3:
				var chair = _chair_scene.instantiate()
				var angle := float(i) * TAU / 3.0
				chair.position = Vector3(CELL * 0.5 + cos(angle) * 1.5, 0.0, CELL * 0.5 + sin(angle) * 1.5)
				chair.rotation.y = angle + PI
				root.add_child(chair)

func _add_box(root: Node3D, body: StaticBody3D, size: Vector3, pos: Vector3, mat: StandardMaterial3D, collide: bool) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	root.add_child(mi)
	if collide:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		cs.position = pos
		body.add_child(cs)


func _add_box_collider(body: StaticBody3D, size: Vector3, pos: Vector3) -> void:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position = pos
	body.add_child(collision)


# ---------------------------------------------------------------------------
# Procedural room formations and environmental dressing
# ---------------------------------------------------------------------------
## Dressing varies with the run seed but remains deterministic for every co-op
## peer. It never changes maze edges: corridor pathfinding and objectives keep
## the exact same walkable graph.
func _decor_hash(c: Vector2i, salt: int) -> float:
	return _hash3(c.x, c.y, salt + posmod(_run_seed, 100000) * 37)


func _neighbor_in_direction(c: Vector2i, direction: int) -> Vector2i:
	match direction:
		DIR_E:
			return c + Vector2i(1, 0)
		DIR_N:
			return c + Vector2i(0, 1)
		DIR_W:
			return c + Vector2i(-1, 0)
		_:
			return c + Vector2i(0, -1)


func _open_directions(c: Vector2i) -> Array[int]:
	var directions: Array[int] = []
	for direction in [DIR_E, DIR_N, DIR_W, DIR_S]:
		if not _edge_between(c, _neighbor_in_direction(c, direction)):
			directions.append(direction)
	return directions


func _closed_directions(c: Vector2i) -> Array[int]:
	var directions: Array[int] = []
	for direction in [DIR_E, DIR_N, DIR_W, DIR_S]:
		if _edge_between(c, _neighbor_in_direction(c, direction)):
			directions.append(direction)
	return directions


## Rotation that maps local +Z to the selected cell edge.
func _direction_yaw(direction: int) -> float:
	match direction:
		DIR_E:
			return PI * 0.5
		DIR_N:
			return 0.0
		DIR_W:
			return -PI * 0.5
		_:
			return PI


func _new_structure(root: Node3D, name: String, direction: int) -> Dictionary:
	var structure := Node3D.new()
	structure.name = name
	structure.rotation.y = _direction_yaw(direction)
	root.add_child(structure)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	structure.add_child(body)
	return {"root": structure, "body": body}


## Adds architecture only where the existing graph already supports it. A
## one-exit cell becomes a real enterable dark pocket; open rooms sometimes get
## an asymmetric portal/threshold while retaining a 2.4 m central opening.
func _place_room_formation(root: Node3D, c: Vector2i, open_directions: Array[int]) -> String:
	if open_directions.size() == 1 \
			and _decor_hash(c, 1201) < DARK_ALCOVE_CHANCE:
		_build_dark_alcove(root, c, open_directions[0])
		return "dark_alcove"
	if open_directions.size() >= 2 \
			and _decor_hash(c, 1202) < ROOM_THRESHOLD_CHANCE:
		var pick := mini(
			int(_decor_hash(c, 1203) * open_directions.size()),
			open_directions.size() - 1)
		_build_room_threshold(root, c, open_directions[pick])
		return "room_threshold"
	return ""


func _build_dark_alcove(root: Node3D, c: Vector2i, opening_direction: int) -> void:
	var parts := _new_structure(root, "DarkAlcove_%d_%d" % [c.x, c.y], opening_direction)
	var structure := parts["root"] as Node3D
	var body := parts["body"] as StaticBody3D
	# Chunky entrance walls create a narrow black mouth without blocking the
	# centreline used by players, SNUS and the Entity.
	_add_box(structure, body, Vector3(0.72, 2.30, 1.05), Vector3(-1.64, 1.15, 1.47), _wall_dark_mat, true)
	_add_box(structure, body, Vector3(0.72, 2.30, 1.05), Vector3(1.64, 1.15, 1.47), _wall_dark_mat, true)
	# Bottom at 2.64 m: clears the Entity's 2.5 m navigation capsule as well as
	# the player's 1.7 m body capsule.
	_add_box(structure, body, Vector3(CELL, 0.36, 0.58), Vector3(0.0, 2.82, 1.72), _wall_dark_mat, true)
	# CX31 — real (very dark) wallpaper, ceiling tiles and carpet instead of the
	# old unshaded void planes. Side returns close the recess so it stops reading
	# as a flat black rectangle floating on a lit wall.
	_add_box(structure, body, Vector3(3.25, 0.018, 3.15), Vector3(0.0, 0.012, -0.22), _floor_dark_mat, false)
	_add_box(structure, body, Vector3(3.35, 2.48, 0.035), Vector3(0.0, 1.24, -1.805), _alcove_wall_mat, false)
	_add_box(structure, body, Vector3(0.035, 2.48, 3.15), Vector3(-1.66, 1.24, -0.22), _alcove_wall_mat, false)
	_add_box(structure, body, Vector3(0.035, 2.48, 3.15), Vector3(1.66, 1.24, -0.22), _alcove_wall_mat, false)
	_add_box(structure, body, Vector3(3.35, 0.025, 2.75), Vector3(0.0, 2.955, -0.33), _alcove_ceil_mat, false)
	# One failed, nearly-dead fixture. Without it the recess has no light source
	# at all, which is why the darkness looked like a rendering error rather than
	# a room whose lamp gave up. Shadows stay off: this is fill, not a lamp.
	var ember := OmniLight3D.new()
	ember.name = "AlcoveEmber"
	ember.light_color = Color(0.86, 0.83, 0.62)
	ember.light_energy = 0.34
	ember.omni_range = 4.6
	ember.omni_attenuation = 1.6
	ember.shadow_enabled = false
	ember.position = Vector3(0.0, 2.42, -0.55)
	structure.add_child(ember)


func _build_room_threshold(root: Node3D, c: Vector2i, opening_direction: int) -> void:
	var parts := _new_structure(root, "RoomThreshold_%d_%d" % [c.x, c.y], opening_direction)
	var structure := parts["root"] as Node3D
	var body := parts["body"] as StaticBody3D
	var flip := -1.0 if _decor_hash(c, 1210) < 0.5 else 1.0
	# One wing projects further than the other, breaking the repeated square-cell
	# silhouette while a generous central route remains unobstructed.
	_add_box(structure, body, Vector3(0.68, 2.36, 1.55), Vector3(1.66 * flip, 1.18, 1.22), _wall_dirty_mat, true)
	_add_box(structure, body, Vector3(0.68, 2.36, 0.70), Vector3(-1.66 * flip, 1.18, 1.64), _wall_mat, true)
	_add_box(structure, body, Vector3(CELL, 0.36, 0.52), Vector3(0.0, 2.82, 1.73), _wall_mat, true)


## Root on a real wall, with local +Z pointing into the walkable cell.
func _wall_dressing_root(root: Node3D, direction: int, name: String) -> Node3D:
	var cluster := Node3D.new()
	cluster.name = name
	match direction:
		DIR_E:
			cluster.position = Vector3(1.79, 0.0, 0.0)
			cluster.rotation.y = -PI * 0.5
		DIR_N:
			cluster.position = Vector3(0.0, 0.0, 1.79)
			cluster.rotation.y = PI
		DIR_W:
			cluster.position = Vector3(-1.79, 0.0, 0.0)
			cluster.rotation.y = PI * 0.5
		DIR_S:
			cluster.position = Vector3(0.0, 0.0, -1.79)
			cluster.rotation.y = 0.0
	root.add_child(cluster)
	return cluster


func _place_cell_dressing(root: Node3D, c: Vector2i, formation: String) -> void:
	if _decor_hash(c, 1301) >= MAP_DRESSING_CHANCE:
		return
	var closed := _closed_directions(c)
	var kind := int(_decor_hash(c, 1302) * 6.0) % 6
	# Keep the black recess visually legible: only a lone chair or maintenance
	# trace may appear inside it, never a bright cabinet/door cluster.
	if formation == "dark_alcove":
		kind = 1 if _decor_hash(c, 1303) < 0.62 else 2
	match kind:
		0:
			if closed.is_empty():
				_spawn_chair_vignette(root, c)
			else:
				_spawn_storage_cluster(root, c, closed)
		1:
			_spawn_chair_vignette(root, c)
		2:
			_spawn_maintenance_trace(root, c)
		3:
			# CX31 — the sealed office door used to live here. The level now
			# contains exactly ONE door and it is the exit, so a decorative one
			# that never opens can no longer be mistaken for the way out.
			_spawn_hanging_fixture(root, c)
		4:
			_spawn_hanging_fixture(root, c)
		_:
			if closed.is_empty():
				_spawn_chair_vignette(root, c)
			else:
				_spawn_clipped_furniture(root, c, closed)


func _pick_direction(c: Vector2i, directions: Array[int], salt: int) -> int:
	var index := mini(int(_decor_hash(c, salt) * directions.size()), directions.size() - 1)
	return directions[index]


## Corners stay clear of every centre-to-edge route used by corridor_path.
func _safe_corner_position(c: Vector2i, salt: int, distance: float = 1.22) -> Vector3:
	var corner := int(_decor_hash(c, salt) * 4.0) % 4
	return Vector3(
		distance if corner in [0, 1] else -distance,
		0.0,
		distance if corner in [0, 2] else -distance)


func _spawn_storage_cluster(root: Node3D, c: Vector2i, closed: Array[int]) -> void:
	var direction := _pick_direction(c, closed, 1310)
	var cluster := _wall_dressing_root(root, direction, "AbandonedStorage")
	var body := StaticBody3D.new()
	body.name = "StorageCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	cluster.add_child(body)
	var flip := -1.0 if _decor_hash(c, 1311) < 0.5 else 1.0
	_add_box(cluster, body, Vector3(0.58, 1.34, 0.46), Vector3(-0.52 * flip, 0.67, 0.25), _office_metal_mat, true)
	# Drawer seams turn the plain cabinet block into readable office furniture.
	for drawer in range(3):
		_add_box(cluster, body, Vector3(0.48, 0.018, 0.025), Vector3(-0.52 * flip, 0.36 + drawer * 0.33, 0.493), _void_mat, false)
	_add_box(cluster, body, Vector3(0.63, 0.42, 0.52), Vector3(0.43 * flip, 0.21, 0.30), _cardboard_mat, true)
	_add_box(cluster, body, Vector3(0.42, 0.34, 0.40), Vector3(0.70 * flip, 0.59, 0.25), _cardboard_mat, true)


func _spawn_chair_vignette(root: Node3D, c: Vector2i) -> void:
	var angle := _decor_hash(c, 1320) * TAU
	var position := _safe_corner_position(c, 1322)
	if _chair_scene != null:
		var chair := _chair_scene.instantiate() as Node3D
		chair.name = "AbandonedChair"
		root.add_child(chair)
		ModelUtils.scale_to_height(chair, 0.72)
		ModelUtils.ground_model(chair, 0.0)
		chair.position += position
		chair.rotation.y = angle + PI + _decor_hash(c, 1321) * 0.7
	# Simple physical proxy: the imported broken chair now blocks movement and
	# environment LOS without expensive per-mesh convex collision.
	var body := StaticBody3D.new()
	body.name = "ChairVignetteCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	root.add_child(body)
	_add_box_collider(body, Vector3(0.64, 0.72, 0.64), position + Vector3.UP * 0.36)
	# The carton is physical too, but sits deeper in the same safe corner.
	var inward_x := -signf(position.x) * 0.38
	var carton_position := position + Vector3(inward_x, 0.15, 0.02 * signf(position.z))
	_add_box(root, body, Vector3(0.43, 0.30, 0.38), carton_position, _cardboard_mat, true)


func _spawn_maintenance_trace(root: Node3D, c: Vector2i) -> void:
	var angle := _decor_hash(c, 1330) * TAU
	var position := _safe_corner_position(c, 1332, 1.18)
	var puddle := MeshInstance3D.new()
	puddle.name = "OldCeilingLeak"
	var puddle_mesh := CylinderMesh.new()
	puddle_mesh.top_radius = 1.75
	puddle_mesh.bottom_radius = 1.55
	puddle_mesh.height = 0.012
	puddle.mesh = puddle_mesh
	puddle.material_override = _puddle_mat
	puddle.position = position + Vector3(0.12, 0.008, -0.08)
	puddle.scale = Vector3(1.3, 1.0, 1.3)
	puddle.rotation.y = angle
	root.add_child(puddle)

	# Area3D trigger for player & entity slipping physics
	var slip_area := Area3D.new()
	slip_area.name = "WetFloorHazardArea"
	slip_area.add_to_group("wet_floor")
	slip_area.set_meta("is_wet_floor", true)
	slip_area.position = puddle.position
	var slip_col := CollisionShape3D.new()
	var slip_shape := CylinderShape3D.new()
	slip_shape.radius = 2.0
	slip_shape.height = 1.2
	slip_col.shape = slip_shape
	slip_area.add_child(slip_col)
	root.add_child(slip_area)

	if _wet_floor_scene != null:
		var sign := _wet_floor_scene.instantiate() as Node3D
		sign.name = "ForgottenWetFloorSign"
		root.add_child(sign)
		ModelUtils.scale_to_height(sign, 0.68)
		ModelUtils.ground_model(sign, 0.0)
		var sign_position := position + Vector3(-0.18 * signf(position.x), 0.0, -0.12 * signf(position.z))
		sign.position += sign_position
		sign.rotation.y = angle + _decor_hash(c, 1331) * 1.1
		var sign_body := StaticBody3D.new()
		sign_body.name = "WetFloorSignCollision"
		sign_body.collision_layer = 1
		sign_body.collision_mask = 0
		root.add_child(sign_body)
		_add_box_collider(sign_body, Vector3(0.42, 0.68, 0.34), sign_position + Vector3.UP * 0.34)


## Film-inspired "noclip" furniture: familiar office chairs intersect one
## another and the wall at implausible angles. It stays non-colliding and tight
## to the perimeter so the visual oddity cannot trap either player or Entity.
func _spawn_clipped_furniture(root: Node3D, c: Vector2i, closed: Array[int]) -> void:
	var direction := _pick_direction(c, closed, 1345)
	var cluster := _wall_dressing_root(root, direction, "ClippedFurniturePile")
	var pile_body := StaticBody3D.new()
	pile_body.name = "ClippedFurnitureCollision"
	pile_body.collision_layer = 1
	pile_body.collision_mask = 0
	cluster.add_child(pile_body)
	_add_box_collider(pile_body, Vector3(1.34, 1.72, 0.74), Vector3(0.0, 0.86, 0.30))
	if _chair_scene == null:
		_add_box(cluster, pile_body, Vector3(1.25, 0.58, 0.72), Vector3(0.0, 0.29, 0.28), _cardboard_mat, false)
		return
	var poses: Array[Dictionary] = [
		{"p": Vector3(-0.48, 0.02, 0.22), "r": Vector3(0.0, -18.0, -9.0)},
		{"p": Vector3(0.28, 0.38, 0.12), "r": Vector3(22.0, 31.0, 67.0)},
		{"p": Vector3(0.05, 0.92, -0.04), "r": Vector3(-12.0, -42.0, -34.0)},
	]
	for index in range(poses.size()):
		var chair := _chair_scene.instantiate() as Node3D
		chair.name = "ClippedChair_%d" % index
		cluster.add_child(chair)
		ModelUtils.scale_to_height(chair, 0.68)
		ModelUtils.ground_model(chair, 0.0)
		chair.position += Vector3(poses[index]["p"])
		chair.rotation_degrees = Vector3(poses[index]["r"])


func _spawn_hanging_fixture(root: Node3D, c: Vector2i) -> void:
	var fixture := Node3D.new()
	fixture.name = "CrookedFluorescent"
	fixture.position = Vector3(
		lerpf(-0.75, 0.75, _decor_hash(c, 1350)),
		2.78,
		lerpf(-0.75, 0.75, _decor_hash(c, 1351)))
	fixture.rotation.y = _decor_hash(c, 1352) * TAU
	fixture.rotation.z = lerpf(-0.16, 0.16, _decor_hash(c, 1353))
	root.add_child(fixture)
	var dummy_body := StaticBody3D.new()
	dummy_body.name = "HangingFixtureCollision"
	dummy_body.collision_layer = 1
	dummy_body.collision_mask = 0
	fixture.add_child(dummy_body)
	_add_box(fixture, dummy_body, Vector3(1.75, 0.075, 0.32), Vector3.ZERO, _office_metal_mat, true)
	_add_box(fixture, dummy_body, Vector3(1.48, 0.025, 0.18), Vector3(0.0, -0.05, 0.0), _panel_mat, false)
	# One end hangs lower on a short black cable.
	_add_box(fixture, dummy_body, Vector3(0.018, 0.34, 0.018), Vector3(-0.72, 0.20, 0.0), _void_mat, false)

func _place_anomaly(root: Node3D, c: Vector2i, data: Dictionary) -> void:
	var kind := int(_hash3(c.x, c.y, 333) * 2.0) % 2
	var placed := false
	if kind == 0 and _chair_scene:
		var chair: Node3D = _chair_scene.instantiate()
		root.add_child(chair)
		ModelUtils.scale_to_height(chair, 0.62)
		ModelUtils.ground_model(chair, 0.0)
		chair.position += Vector3(1.1, 0, 1.1)
		chair.rotation.y = deg_to_rad(180)  # facing the wall — wrong
		placed = true
	else:
		# "a zone where light doesn't reach the floor" — kill the panel, keep it a room
		data["dark"] = true
		if data.get("panel_mat"):
			(data["panel_mat"] as StandardMaterial3D).emission_energy_multiplier = 0.0
		placed = true
	if placed:
		data["anomaly"] = true
		_anomaly_cells[c] = true

func _place_phone(root: Node3D, c: Vector2i, data: Dictionary) -> void:
	if _phone_scene == null:
		return
	var phone: Node3D = _phone_scene.instantiate()
	phone.set_meta("phone_anomaly", true)
	phone.set_meta("phone_cell", c)
	root.add_child(phone)
	ModelUtils.scale_to_height(phone, 0.13)
	phone.position = Vector3(-1.2, 0.02, -1.0)
	phone.rotation.y = _hash3(c.x, c.y, _run_seed & 0x7FFF) * TAU
	data["anomaly"] = true
	_anomaly_cells[c] = true

func _free_cell(c: Vector2i) -> void:
	if c == _exit_cell and _exit_placed:
		return  # keep the exit alive once spawned
	var d = _cells.get(c)
	if d and is_instance_valid(d["node"]):
		d["node"].queue_free()
	_cells.erase(c)
	_anomaly_cells.erase(c)
	# Bump salt so this region regenerates differently if revisited — but NOT
	# in co-op, where the layout must stay identical for every player.
	if not _static_layout:
		_salt[c] = _salt_of(c) + 1

# ---------------------------------------------------------------------------
# Lighting
# ---------------------------------------------------------------------------
func _update_lights(center: Vector2i) -> void:
	# CX34 — the exit room is exempt from the light budget so the beacon can
	# never be culled. That was free while the exit only existed for the last
	# minute of a run; since CX31 it is built at run start, so its lamp is
	# switched off while the player is nowhere near it.
	_update_exit_light_presence(center)
	var candidates: Array[Dictionary] = []
	for c in _cells.keys():
		var d: Dictionary = _cells[c]
		if bool(d["exit"]) or bool(d["dark"]) or d.get("panel_mat") == null:
			continue
		var offset := Vector2(float(c.x - center.x), float(c.y - center.y))
		var distance_sq: float = offset.length_squared()
		candidates.append({"cell": c, "distance_sq": distance_sq})

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var distance_a := float(a["distance_sq"])
		var distance_b := float(b["distance_sq"])
		if not is_equal_approx(distance_a, distance_b):
			return distance_a < distance_b
		# Stable tie-break prevents Dictionary iteration order from swapping equal
		# distance lamps between clients or repeated updates.
		var cell_a: Vector2i = a["cell"]
		var cell_b: Vector2i = b["cell"]
		return cell_a.x < cell_b.x if cell_a.x != cell_b.x else cell_a.y < cell_b.y
	)
	var active_cells: Dictionary = {}
	for index in mini(candidates.size(), MAX_STREAMED_LIGHTS):
		active_cells[candidates[index]["cell"]] = true

	# First detach lights leaving the budget so a quick 180-degree turn cannot
	# temporarily exceed the renderer limit before queue_free runs.
	for c in _cells.keys():
		var d: Dictionary = _cells[c]
		if bool(d["exit"]) or active_cells.has(c) or d["light"] == null:
			continue
		if is_instance_valid(d["light"]):
			var old_light := d["light"] as OmniLight3D
			if old_light.get_parent() != null:
				old_light.get_parent().remove_child(old_light)
			old_light.queue_free()
		d["light"] = null

	for c in active_cells.keys():
		var d: Dictionary = _cells[c]
		var wants := not bool(d["dark"]) and d.get("panel_mat") != null
		if wants and d["light"] == null:
			# Short throw + hard falloff: each panel lights its own pool and the
			# corridor between panels stays in genuine penumbra.
			var lg := OmniLight3D.new()
			lg.light_color = Color(1.0, 0.96, 0.78)
			lg.light_energy = LIGHT_ENERGY
			lg.omni_range = Tuning.LIGHT_RANGE
			lg.omni_attenuation = Tuning.LIGHT_ATTENUATION
			lg.shadow_enabled = false
			lg.position = Vector3(0, WALL_H - 0.2, 0)
			d["node"].add_child(lg)
			d["light"] = lg

func _animate_lights(delta: float) -> void:
	var flicker_speed := 2.2 if _flicker_target > _flicker else 0.9
	_flicker = move_toward(_flicker, _flicker_target, delta * flicker_speed)
	# Retrieve the active entity figure node if it exists
	var fig: Node3D = get_node_or_null("../Figure")

	# Flicker scales with panic. Each lit cell flickers on its own phase.
	for c in _cells.keys():
		var d = _cells[c]
		var pmat = d.get("panel_mat")
		if pmat == null or bool(d["exit"]):
			continue  # the exit beacon never flickers
		
		# Proximity flicker: lights within 8.0 meters of the stalking/chasing entity flicker dynamically!
		var prox_flicker := 0.0
		if is_instance_valid(fig):
			var cell_pos := Vector3(c.x * 4.0, 1.8, c.y * 4.0)
			var distance_sq := cell_pos.distance_squared_to(fig.global_position)
			if distance_sq < 64.0:
				var dist_to_fig := sqrt(distance_sq)
				prox_flicker = clampf(1.0 - (dist_to_fig / 8.0), 0.0, 1.0)

		var seed_v: float = d["flick_seed"]
		var f := 1.0
		# Rare idle ballast dip: slow, shallow and unique to each fixture.
		var idle := 0.5 + 0.5 * sin(_time * (0.35 + seed_v * 0.3) + seed_v * 41.0)
		var idle_flutter := 0.5 + 0.5 * sin(_time * (4.0 + seed_v * 2.0) + seed_v * 17.0)
		if idle > 0.992 and idle_flutter > 0.88:
			f = 0.68
		
		var active_flicker := maxf(_flicker, prox_flicker)
		if active_flicker > 0.01:
			# Uneven low-frequency pulses instead of a repetitive high-Hz strobe.
			var envelope := 0.5 + 0.5 * sin(_time * (0.7 + seed_v * 0.55) + seed_v * 23.0)
			var flutter := 0.5 + 0.5 * sin(_time * (4.2 + seed_v * 3.1) + seed_v * 11.0)
			var pulse := smoothstep(0.72, 0.98, flutter) * lerpf(0.45, 1.0, envelope)
			var floor_energy := lerpf(0.72, 0.34 + seed_v * 0.18, active_flicker)
			f = minf(f, lerpf(1.0, floor_energy, pulse * active_flicker))

		(pmat as StandardMaterial3D).emission_energy_multiplier = float(d["base_energy"]) * f
		var lg = d["light"]
		if lg and is_instance_valid(lg):
			(lg as OmniLight3D).light_energy = LIGHT_ENERGY * f

func set_flicker(v: float) -> void:
	_flicker_target = clampf(v, 0.0, 1.0)

func set_zone_power(center: Vector2i, radius: int, enabled: bool) -> void:
	_powered_zones.append({"center": center, "radius": radius, "enabled": enabled})
	for c in _cells.keys():
		if maxi(abs(c.x - center.x), abs(c.y - center.y)) > radius:
			continue
		var data: Dictionary = _cells[c]
		var pmat = data.get("panel_mat")
		if pmat is StandardMaterial3D:
			(pmat as StandardMaterial3D).emission_energy_multiplier = PANEL_ENERGY if enabled else 0.0
		var light = data.get("light")
		if light is OmniLight3D:
			(light as OmniLight3D).light_energy = LIGHT_ENERGY if enabled else 0.0

# ---------------------------------------------------------------------------
# Anomalies / secret ending helpers
# ---------------------------------------------------------------------------
func _check_anomaly(pc: Vector2i) -> void:
	anomaly_state_changed.emit(_anomaly_cells.has(pc))

func player_in_anomaly() -> bool:
	return _anomaly_cells.has(_cur_cell)

func open_cells() -> Array:
	return _cells.keys()

func is_cell_open(c: Vector2i) -> bool:
	if _cheb(c) <= START_CLEAR:
		return true
	var walls := 0
	if _wall_present(c, DIR_E): walls += 1
	if _wall_present(c, DIR_N): walls += 1
	if _wall_present(c + Vector2i(-1, 0), DIR_E): walls += 1
	if _wall_present(c + Vector2i(0, -1), DIR_N): walls += 1
	return walls < 4

## Finds a real wall face near a requested cell and returns a transform whose
## local +Z points into the walkable space. World props use this instead of
## guessing that a wall exists at a hard-coded offset.
func wall_mount_near(preferred: Vector2i, height: float = 1.3) -> Dictionary:
	for radius in range(0, 4):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if radius > 0 and abs(dx) != radius and abs(dz) != radius:
					continue
				var c := preferred + Vector2i(dx, dz)
				if not is_cell_open(c):
					continue
				var center := world_center(c)
				var mounts: Array[Dictionary] = []
				# Place the mount 2 mm off the visible face: close enough to read as
				# attached, but not coplanar (which would cause z-fighting).
				var inset := WALL_HALF_THICKNESS + WALL_MOUNT_GAP
				if _wall_present(c, DIR_E):
					mounts.append({"position": center + Vector3(CELL * 0.5 - inset, height, 0.0), "rotation_y": -PI * 0.5, "cell": c})
				if _wall_present(c, DIR_N):
					mounts.append({"position": center + Vector3(0.0, height, CELL * 0.5 - inset), "rotation_y": PI, "cell": c})
				if _wall_present(c + Vector2i(-1, 0), DIR_E):
					mounts.append({"position": center + Vector3(-CELL * 0.5 + inset, height, 0.0), "rotation_y": PI * 0.5, "cell": c})
				if _wall_present(c + Vector2i(0, -1), DIR_N):
					mounts.append({"position": center + Vector3(0.0, height, -CELL * 0.5 + inset), "rotation_y": 0.0, "cell": c})
				if not mounts.is_empty():
					var pick := mini(int(_hash3(c.x, c.y, 606) * mounts.size()), mounts.size() - 1)
					return mounts[pick]
	return {}

## Wall-end corners near `center` where a figure can lurk behind cover and
## lean out. Each entry: {"out": exposed spot just past the wall end,
## "hide": fully covered spot behind the wall}. Only FREE corners qualify —
## wall ends where no colinear wall continues, no perpendicular wall joins,
## and no pillar sits on the junction (leaning "around" a connected wall
## would clip straight through geometry). Callers must still ray-validate
## (out visible / hide occluded) against the actual player position.
func peek_corners(center: Vector3, min_d: float, max_d: float) -> Array:
	var results: Array = []
	var cc := _cell_of(center)
	var r := int(ceil(max_d / CELL)) + 1
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			if results.size() >= 40:
				return results
			var c := Vector2i(cc.x + dx, cc.y + dz)
			# East wall: plane x = cx*4+2, runs along Z.
			if _wall_present(c, DIR_E):
				var wx := c.x * CELL + CELL * 0.5
				for endsign in [-1, 1]:
					if _wall_present(Vector2i(c.x, c.y + endsign), DIR_E):
						continue  # wall continues — not a free corner
					var junction := Vector2i(c.x, c.y) if endsign == 1 else Vector2i(c.x, c.y - 1)
					if _corner_blocked(junction, DIR_E):
						continue  # a perpendicular wall or pillar joins here
					var ez := c.y * CELL + float(endsign) * CELL * 0.5
					for side in [-1, 1]:
						var out := Vector3(wx + side * 0.6, 0.0, ez + endsign * 0.4)
						var hide := Vector3(wx + side * 0.6, 0.0, ez - endsign * 0.75)
						var d := Vector2(out.x - center.x, out.z - center.z).length()
						if d >= min_d and d <= max_d:
							results.append({"out": out, "hide": hide})
			# North wall: plane z = cz*4+2, runs along X.
			if _wall_present(c, DIR_N):
				var wz := c.y * CELL + CELL * 0.5
				for endsign in [-1, 1]:
					if _wall_present(Vector2i(c.x + endsign, c.y), DIR_N):
						continue
					var junction2 := Vector2i(c.x, c.y) if endsign == 1 else Vector2i(c.x - 1, c.y)
					if _corner_blocked(junction2, DIR_N):
						continue
					var ex := c.x * CELL + float(endsign) * CELL * 0.5
					for side in [-1, 1]:
						var out := Vector3(ex + endsign * 0.4, 0.0, wz + side * 0.6)
						var hide := Vector3(ex - endsign * 0.75, 0.0, wz + side * 0.6)
						var d := Vector2(out.x - center.x, out.z - center.z).length()
						if d >= min_d and d <= max_d:
							results.append({"out": out, "hide": hide})
	return results

## Is the (+X,+Z) corner junction of cell `k` occupied by anything besides the
## wall we're peeking around? `our_dir` is the axis of OUR wall: only walls
## PERPENDICULAR to it (and pillars) block the corner.
func _corner_blocked(k: Vector2i, our_dir: int) -> bool:
	# pillar placement mirrors _build_cell exactly
	if _cheb(k) > START_CLEAR and _hash3(k.x, k.y, 401) < PILLAR_DENSITY:
		return true
	if our_dir == DIR_E:
		return _wall_present(k, DIR_N) or _wall_present(Vector2i(k.x + 1, k.y), DIR_N)
	return _wall_present(k, DIR_E) or _wall_present(Vector2i(k.x, k.y + 1), DIR_E)

func get_phone_node_in_cell(cell: Vector2i) -> Node3D:
	var d = _cells.get(cell)
	if d and is_instance_valid(d.get("node")):
		for child in d["node"].get_children():
			if child.has_meta("phone_anomaly"):
				return child
	return null

# ---------------------------------------------------------------------------
# The single real exit
# ---------------------------------------------------------------------------
func enable_exit() -> void:
	_exit_available = true
	# Do not wait for the player to cross another cell boundary: the mission and
	# the physical door become active on the exact same frame.
	_maybe_place_exit(_cur_cell)
	_unseal_exit()


## CX31 — the one real door now stands in the world from the first second, so it
## can be found early and answer "still locked". This seal is what actually keeps
## the player in until both objectives are done.
func _seal_exit(portal_root: Node3D) -> void:
	if _exit_available or is_instance_valid(_exit_seal):
		return
	var seal := StaticBody3D.new()
	seal.name = "ExitSeal"
	seal.collision_layer = 1
	seal.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CELL, WALL_H, 0.4)
	shape.shape = box
	shape.position = Vector3(0.0, WALL_H * 0.5, -1.62)
	seal.add_child(shape)
	portal_root.add_child(seal)
	_exit_seal = seal


func _unseal_exit() -> void:
	if is_instance_valid(_exit_seal):
		_exit_seal.queue_free()
	_exit_seal = null
	# The room goes from "lit but shut" to the full beacon on override.
	var d = _cells.get(_exit_cell)
	if d == null:
		return
	d["base_energy"] = 2.4
	if d.get("panel_mat") is StandardMaterial3D:
		(d["panel_mat"] as StandardMaterial3D).emission_energy_multiplier = 2.4
	var light = d.get("light")
	if light is OmniLight3D:
		(light as OmniLight3D).light_energy = 2.4


## True while the door exists but the emergency override has not been completed.
## The exit lamp only draws while the player is within streaming range of it.
## Its emissive panel stays on, so the room still reads as the beacon on arrival.
func _update_exit_light_presence(center: Vector2i) -> void:
	if not _exit_placed:
		return
	var d = _cells.get(_exit_cell)
	if d == null:
		return
	var light = d.get("light")
	if not (light is OmniLight3D):
		return
	var near_exit := maxi(
		absi(_exit_cell.x - center.x), absi(_exit_cell.y - center.y)) <= VIEW_RADIUS
	(light as OmniLight3D).visible = near_exit


func is_exit_locked() -> bool:
	return _exit_placed and not _exit_available


## Where the door leaf actually is, for the proximity prompt. Zero until placed.
func exit_door_position() -> Vector3:
	return _exit_door_base if _exit_placed else Vector3.ZERO

func _select_exit_cell() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x45584954
	var candidates: Array[Vector2i] = []
	# A real exit belongs on an outside wall. Randomize between the north and
	# south edges and along each edge while keeping a corridor path from spawn.
	for edge_y in [-16, 16]:
		for x in range(-14, 15):
			var candidate := Vector2i(x, edge_y)
			if not is_cell_open(candidate):
				continue
			if corridor_path(candidate, Vector2i.ZERO, 1800).is_empty():
				continue
			candidates.append(candidate)
	if candidates.is_empty():
		_exit_cell = Vector2i(rng.randi_range(-12, 12), -16)
	else:
		_exit_cell = candidates[rng.randi_range(0, candidates.size() - 1)]

func _maybe_place_exit(_pc: Vector2i) -> void:
	# CX31 — no longer gated on `_exit_available`. The door is built with the run
	# and simply stays sealed; `enable_exit()` only removes the seal.
	if _exit_placed:
		return
	if _exit_cell == Vector2i.ZERO:
		_select_exit_cell()
	if not _cells.has(_exit_cell):
		_build_cell(_exit_cell)
	_spawn_exit_room(_exit_cell)
	_exit_placed = true

func exit_world_pos() -> Vector3:
	return _exit_door_base if _exit_placed else world_center(_exit_cell)

func _spawn_exit_room(c: Vector2i) -> void:
	var d = _cells.get(c)
	if d == null:
		return
	var root: Node3D = d["node"]
	# Cooler, brighter, quieter room. Recolor its panel and add a distinct light.
	# CX31 — while the door is still sealed the room is lit but muted; the
	# override brightens it, so "THE EXIT IS OPEN" still lands as a change.
	if d.get("panel_mat"):
		var pm := d["panel_mat"] as StandardMaterial3D
		pm.emission = Color(0.8, 0.95, 1.0)
		pm.emission_energy_multiplier = 2.4 if _exit_available else 1.1
	d["base_energy"] = 2.4 if _exit_available else 1.1
	d["dark"] = false
	var lg := OmniLight3D.new()
	lg.light_color = Color(0.8, 0.95, 1.0)
	lg.light_energy = 2.4 if _exit_available else 1.1
	lg.omni_range = 9.0
	lg.shadow_enabled = false
	lg.position = Vector3(0, WALL_H - 0.2, 0)
	root.add_child(lg)
	d["light"] = lg
	d["exit"] = true
	var outward_z := -1 if c.y < 0 else 1
	_carve_exit_opening(root, outward_z)
	var portal_root := Node3D.new()
	portal_root.name = "ExitPortal"
	portal_root.rotation.y = 0.0 if outward_z < 0 else PI
	root.add_child(portal_root)
	_add_exit_void(portal_root)

	# The one real door.
	if _exit_door_scene:
		var door: Node3D = _exit_door_scene.instantiate()
		portal_root.add_child(door)
		ModelUtils.scale_to_height(door, 2.3)
		ModelUtils.ground_model(door, 0.0)
		door.position += Vector3(0, 0, -1.6)
	else:
		# Fallback: a bright emissive slab so the exit is always visible.
		var slab := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.4, 2.2, 0.2)
		slab.mesh = bm
		slab.material_override = _exit_mat
		slab.position = Vector3(0, 1.1, -1.6)
		portal_root.add_child(slab)

	# Trigger area at the doorway.
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 2  # detect player
	var acs := CollisionShape3D.new()
	var abox := BoxShape3D.new()
	abox.size = Vector3(1.45, 2.4, 0.4)
	acs.shape = abox
	# The capsule reaches this only after its camera has crossed the door plane.
	acs.position = Vector3(0, 1.2, -2.35)
	area.add_child(acs)
	portal_root.add_child(area)
	area.body_entered.connect(_on_exit_body_entered)
	_exit_area = area
	_seal_exit(portal_root)

	_exit_door_base = portal_root.to_global(Vector3(0, 0, -1.6))
	_exit_forward = (portal_root.global_basis * Vector3.FORWARD).normalized()
	exit_spawned.emit(_exit_door_base)

## Replace the solid boundary wall and its collision with a collidable doorway
## frame. Removing only the mesh leaves an invisible wall across the exit.
func _carve_exit_opening(root: Node3D, outward_z: int) -> void:
	var wall_material: Material = _wall_mat
	var boundary_z := float(outward_z) * CELL * 0.5
	for child in root.get_children():
		var wall := child as MeshInstance3D
		if not wall or not wall.mesh is BoxMesh:
			continue
		var wall_size := (wall.mesh as BoxMesh).size
		if absf(wall.position.z - boundary_z) < 0.01 \
				and is_equal_approx(wall_size.x, CELL) \
				and is_equal_approx(wall_size.y, WALL_H):
			if wall.material_override:
				wall_material = wall.material_override
			wall.visible = false
			wall.queue_free()
			break
	for child in root.get_children():
		var wall_body := child as StaticBody3D
		if not wall_body:
			continue
		for shape_child in wall_body.get_children():
			var collision := shape_child as CollisionShape3D
			if not collision or not collision.shape is BoxShape3D:
				continue
			var wall_size := (collision.shape as BoxShape3D).size
			if absf(collision.position.z - boundary_z) < 0.01 \
					and is_equal_approx(wall_size.x, CELL) \
					and is_equal_approx(wall_size.y, WALL_H):
				collision.disabled = true
				collision.queue_free()
				break

	const OPENING_WIDTH := 1.55
	const OPENING_HEIGHT := 2.35
	var side_width := (CELL - OPENING_WIDTH) * 0.5
	var side_offset := OPENING_WIDTH * 0.5 + side_width * 0.5
	_add_exit_wall_piece(root, Vector3(side_width, WALL_H, 0.35), Vector3(-side_offset, WALL_H * 0.5, boundary_z), wall_material)
	_add_exit_wall_piece(root, Vector3(side_width, WALL_H, 0.35), Vector3(side_offset, WALL_H * 0.5, boundary_z), wall_material)
	var header_height := WALL_H - OPENING_HEIGHT
	_add_exit_wall_piece(root, Vector3(OPENING_WIDTH, header_height, 0.35), Vector3(0.0, OPENING_HEIGHT + header_height * 0.5, boundary_z), wall_material)

func _add_exit_wall_piece(root: Node3D, size: Vector3, position: Vector3, material: Material) -> void:
	var piece := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	piece.mesh = mesh
	piece.material_override = material
	piece.position = position
	root.add_child(piece)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position = position
	body.add_child(collision)
	root.add_child(body)

## A double-sided, unlit black volume immediately beyond the threshold hides
## the streamed maze while the ending camera travels through the doorway.
func _add_exit_void(root: Node3D) -> void:
	var void_mesh := MeshInstance3D.new()
	void_mesh.name = "ExitVoid"
	var box := BoxMesh.new()
	box.size = Vector3(1.45, 2.3, 1.8)
	void_mesh.mesh = box
	void_mesh.position = Vector3(0.0, 1.15, -2.85)
	var black := StandardMaterial3D.new()
	black.albedo_color = Color.BLACK
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.cull_mode = BaseMaterial3D.CULL_DISABLED
	void_mesh.material_override = black
	root.add_child(void_mesh)

## Camera endpoint for the seamless game-to-video threshold transition.
func exit_transition_view() -> Dictionary:
	if not _exit_placed:
		return {}
	var forward := _exit_forward
	var up := global_basis.y.normalized()
	return {
		"camera": _exit_door_base + up * 1.55 + forward * 0.78,
		"look_at": _exit_door_base + up * 1.48 + forward * 2.8,
	}

func _on_exit_body_entered(body: Node) -> void:
	if body == _player or (body.get_parent() == _player):
		exit_reached.emit()

func get_current_cell() -> Vector2i:
	return _cur_cell

# ---------------------------------------------------------------------------
# Corridor pathfinding (used by the entity so it never phases through walls).
# Works on unbuilt cells too — the layout is a pure function of coords + salt.
# ---------------------------------------------------------------------------
func corridor_path(from_cell: Vector2i, to_cell: Vector2i, max_expand: int = 600) -> Array:
	if from_cell == to_cell:
		return [to_cell]
	var prev := {from_cell: from_cell}
	var queue: Array = [from_cell]
	var qi := 0
	while qi < queue.size() and queue.size() < max_expand:
		var c: Vector2i = queue[qi]
		qi += 1
		for nb in [Vector2i(c.x + 1, c.y), Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y - 1)]:
			if prev.has(nb) or _edge_between(c, nb):
				continue
			prev[nb] = c
			if nb == to_cell:
				var path: Array = [nb]
				var cur: Vector2i = nb
				while cur != from_cell:
					cur = prev[cur]
					path.push_front(cur)
				return path
			queue.append(nb)
	return []
