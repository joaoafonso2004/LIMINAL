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
const VIEW_RADIUS: int = 6          # cells kept around the player
const FREE_RADIUS: int = 8          # cells beyond this are released (bumps salt)
# Real OmniLights only this close. 4 → up to ~50 live lights, inside the GL
# limit of 64; radius 6 created ~90+ and the renderer dropped lights per-mesh
# at random (the patchy floor/wall lighting). Cells beyond this still read:
# emissive panels + ambient light carry them.
const LIGHT_RADIUS: int = 4
# Look/layout knobs live in scripts/tuning.gd — edit there, not here.
const WALL_DENSITY: float = Tuning.WALL_DENSITY
const PILLAR_DENSITY: float = Tuning.PILLAR_DENSITY
const WALL_H: float = 3.0
const START_CLEAR: int = 1          # Chebyshev radius kept open around origin
const PANEL_ENERGY: float = Tuning.PANEL_ENERGY
const LIGHT_ENERGY: float = Tuning.LIGHT_ENERGY

# Directions: 0 = East (+X edge owned by cell), 1 = North (+Z edge owned by cell)
const DIR_E: int = 0
const DIR_N: int = 1

var _player: Node3D = null
var _cells: Dictionary = {}          # Vector2i -> Dictionary
var _salt: Dictionary = {}           # Vector2i -> int
var _cur_cell: Vector2i = Vector2i(999, 999)
var _flicker: float = 0.0            # 0 = steady, higher = more flicker/panic
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

# Exit state
var _exit_available: bool = false
var _exit_placed: bool = false
var _exit_area: Area3D = null
var _exit_cell: Vector2i = Vector2i.ZERO

# Prop scenes (anomalies / exit dressing)
var _chair_scene: PackedScene = null
var _phone_scene: PackedScene = null
var _exit_door_scene: PackedScene = null
var _office_door_scene: PackedScene = null
var _fixture_scene: PackedScene = null

var _anomaly_cells: Dictionary = {}   # Vector2i -> true
var _static_layout: bool = true       # layout is a pure function of cell coords

func setup(player: Node3D) -> void:
	_player = player

## The layout must be identical on every client (and every revisit), so the
## maze never rewrites behind anyone. Kept as a switch for future modes.
func set_static_layout(v: bool) -> void:
	_static_layout = v

func _ready() -> void:
	_build_materials()
	_load_props()

func _build_materials() -> void:
	# Dark sepia-brown grade — dirty tan walls sinking to black, hot warm panels.
	_wall_mat = _mk_mat("res://assets/textures/walls/backrooms_yellow_wallpaper.png", Vector3(2, 1, 1.5), 0.92, Color(0.76, 0.68, 0.5))
	_wall_dirty_mat = _mk_mat("res://assets/textures/walls/backrooms_yellow_wallpaper.png", Vector3(2, 1, 1.5), 0.88, Color(0.58, 0.53, 0.38))
	_wall_dark_mat = _mk_mat("res://assets/textures/walls/backrooms_yellow_wallpaper.png", Vector3(2, 1, 1.5), 0.90, Color(0.68, 0.60, 0.44))

	_floor_mat = _mk_mat("res://assets/textures/floors/backrooms_damp_carpet.png", Vector3(2, 2, 1), 0.98, Color(0.58, 0.54, 0.44))
	_linoleum_mat = _mk_mat("res://assets/textures/floors/backrooms_linoleum.png", Vector3(2, 2, 1), 0.75, Color(0.72, 0.68, 0.58))
	_ceil_mat = _mk_mat("res://assets/textures/surfaces/backrooms_ceiling_tiles.png", Vector3(2, 2, 1), 0.95, Color(0.62, 0.6, 0.52))
	_panel_mat = StandardMaterial3D.new()
	_panel_mat.albedo_color = Color(0.9, 0.82, 0.62)
	_panel_mat.emission_enabled = true
	_panel_mat.emission = Color(1.0, 0.88, 0.6)
	_panel_mat.emission_energy_multiplier = PANEL_ENERGY
	_panel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_exit_mat = StandardMaterial3D.new()
	_exit_mat.albedo_color = Color(0.85, 0.95, 0.98)
	_exit_mat.emission_enabled = true
	_exit_mat.emission = Color(0.75, 0.95, 1.0)
	_exit_mat.emission_energy_multiplier = 2.2
	_exit_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

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

func _load_scene(path: String) -> PackedScene:
	if ResourceLoader.exists(path):
		return load(path)
	return null

# ---------------------------------------------------------------------------
# Update loop
# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_time += delta
	if not is_instance_valid(_player):
		return
	var pc: Vector2i = _cell_of(_player.global_position)
	if pc != _cur_cell:
		_cur_cell = pc
		_stream(pc)
		_update_lights(pc)
		entered_cell.emit(pc)
		_check_anomaly(pc)
		_maybe_place_exit(pc)

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

	var h := _hash3(owner.x, owner.y, dir * 131 + _salt_of(owner) * 977)
	return h < WALL_DENSITY

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

	# Dynamic floor and wall variety based on cell hashes
	var fl_mat := _floor_mat
	var hash_floor := _hash3(c.x, c.y, 881)
	if hash_floor < 0.15: # 15% chance of linoleum
		fl_mat = _linoleum_mat
		
	var wl_mat := _wall_mat
	var hash_wall := _hash3(c.x, c.y, 992)
	if hash_wall < 0.12: # 12% chance of dirty wall
		wl_mat = _wall_dirty_mat
	elif hash_wall < 0.24: # 12% chance of dark wall
		wl_mat = _wall_dark_mat

	# Floor
	_add_box(root, body, Vector3(CELL, 0.1, CELL), Vector3(0, -0.05, 0), fl_mat, true)
	# Ceiling
	_add_box(root, body, Vector3(CELL, 0.1, CELL), Vector3(0, WALL_H + 0.05, 0), _ceil_mat, true)

	# Owned walls: East (+X) and North (+Z) — chunky slabs, like the reference.
	if _wall_present(c, DIR_E):
		_add_box(root, body, Vector3(0.35, WALL_H, CELL), Vector3(CELL * 0.5, WALL_H * 0.5, 0), wl_mat, true)
	if _wall_present(c, DIR_N):
		_add_box(root, body, Vector3(CELL, WALL_H, 0.35), Vector3(0, WALL_H * 0.5, CELL * 0.5), wl_mat, true)
	# Cap the far boundary so the fog edge isn't fully open where neighbors are missing.
	var west_owner := Vector2i(c.x - 1, c.y)
	if not _cells.has(west_owner) and _cheb(c) > START_CLEAR and _wall_present(west_owner, DIR_E):
		_add_box(root, body, Vector3(0.35, WALL_H, CELL), Vector3(-CELL * 0.5, WALL_H * 0.5, 0), wl_mat, false)
	var south_owner := Vector2i(c.x, c.y - 1)
	if not _cells.has(south_owner) and _cheb(c) > START_CLEAR and _wall_present(south_owner, DIR_N):
		_add_box(root, body, Vector3(CELL, WALL_H, 0.35), Vector3(0, WALL_H * 0.5, -CELL * 0.5), wl_mat, false)

	# Square pillar at this cell's +X/+Z corner: the open-plan halls of Level 0
	# are held up by a loose grid of wallpapered columns.
	if _cheb(c) > START_CLEAR and _hash3(c.x, c.y, 401) < PILLAR_DENSITY:
		_add_box(root, body, Vector3(0.7, WALL_H, 0.7), Vector3(CELL * 0.5, WALL_H * 0.5, CELL * 0.5), wl_mat, true)

	# How open is this cell? (count open edges)
	var open_edges := 0
	for nb in [Vector2i(c.x + 1, c.y), Vector2i(c.x - 1, c.y), Vector2i(c.x, c.y + 1), Vector2i(c.x, c.y - 1)]:
		if not _edge_between(c, nb):
			open_edges += 1

	# Not all fixtures burn alike: some run at barely half strength, giving
	# each pool its own character and leaving near-dark stretches between.
	var light_mult := lerpf(0.5, 1.0, _hash3(c.x, c.y, 77))
	var data := {
		"node": root, "light": null, "panel_mat": null,
		"dark": false, "anomaly": false, "exit": false,
		"base_energy": PANEL_ENERGY * light_mult, "light_mult": light_mult,
		"flick_seed": _hash3(c.x, c.y, 7),
	}

	# Ceiling light panel (visual) — sparse: roughly half the open cells are lit,
	# so real pools of darkness sit between the panels.
	var give_light := open_edges >= 1 and _hash3(c.x, c.y, 51) > Tuning.LIT_THRESHOLD
	var is_dark_zone := open_edges >= 2 and _hash3(c.x, c.y, 88) < Tuning.DARK_ZONE_CHANCE
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
	if open_edges >= 3 and _cheb(c) >= 3 and _hash3(c.x, c.y, 205) < Tuning.ANOMALY_CHANCE:
		_place_anomaly(root, c, data)

	_cells[c] = data

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

func _place_anomaly(root: Node3D, c: Vector2i, data: Dictionary) -> void:
	var kind := int(_hash3(c.x, c.y, 333) * 3.0) % 3
	var placed := false
	if kind == 0 and _chair_scene:
		var chair: Node3D = _chair_scene.instantiate()
		root.add_child(chair)
		ModelUtils.scale_to_height(chair, 0.62)
		ModelUtils.ground_model(chair, 0.0)
		chair.position += Vector3(1.1, 0, 1.1)
		chair.rotation.y = deg_to_rad(180)  # facing the wall — wrong
		placed = true
	elif kind == 1 and _phone_scene:
		var phone: Node3D = _phone_scene.instantiate()
		phone.set_meta("phone_anomaly", true)
		root.add_child(phone)
		ModelUtils.scale_to_height(phone, 0.13)
		phone.position = Vector3(-1.2, 0.02, -1.0)
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
	for c in _cells.keys():
		var d = _cells[c]
		var near: bool = abs(c.x - center.x) <= LIGHT_RADIUS and abs(c.y - center.y) <= LIGHT_RADIUS
		var wants: bool = near and not bool(d["dark"]) and d.get("panel_mat") != null
		if wants and d["light"] == null:
			# Short throw + hard falloff: each panel lights its own pool and the
			# corridor between panels stays in genuine penumbra.
			var lg := OmniLight3D.new()
			lg.light_color = Color(1.0, 0.88, 0.62)
			lg.light_energy = LIGHT_ENERGY
			lg.omni_range = Tuning.LIGHT_RANGE
			lg.omni_attenuation = Tuning.LIGHT_ATTENUATION
			lg.shadow_enabled = false
			lg.position = Vector3(0, WALL_H - 0.2, 0)
			d["node"].add_child(lg)
			d["light"] = lg
		elif not wants and d["light"] != null:
			if is_instance_valid(d["light"]):
				d["light"].queue_free()
			d["light"] = null

func _animate_lights(delta: float) -> void:
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
			var dist_to_fig := cell_pos.distance_to(fig.global_position)
			if dist_to_fig < 8.0:
				prox_flicker = clampf(1.0 - (dist_to_fig / 8.0), 0.0, 1.0)

		var seed_v: float = d["flick_seed"]
		var f := 1.0
		# rare but deep idle flicker, each light on its own phase (never all at once)
		var idle := 0.5 + 0.5 * sin(_time * (3.0 + seed_v * 6.0) + seed_v * 30.0)
		if idle > 0.965:
			f = 0.2
		
		var active_flicker := maxf(_flicker, prox_flicker)
		if active_flicker > 0.01:
			var strobe := sin(_time * (24.0 + seed_v * 20.0) + seed_v * 12.0)
			# Stronger flicker rate the closer the entity is
			if strobe > (1.0 - active_flicker * 1.35):
				f = randf_range(0.01, 0.15)

		(pmat as StandardMaterial3D).emission_energy_multiplier = float(d["base_energy"]) * f
		var lg = d["light"]
		if lg and is_instance_valid(lg):
			(lg as OmniLight3D).light_energy = LIGHT_ENERGY * f

func set_flicker(v: float) -> void:
	_flicker = clampf(v, 0.0, 1.0)

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

# The one true exit sits at a FIXED, deep cell so every co-op client agrees
# on where it is. It only spawns once the snus have unlocked it.
const EXIT_CELL := Vector2i(14, -16)

func _maybe_place_exit(_pc: Vector2i) -> void:
	if not _exit_available or _exit_placed:
		return
	_exit_cell = EXIT_CELL
	if not _cells.has(EXIT_CELL):
		_build_cell(EXIT_CELL)
	_spawn_exit_room(EXIT_CELL)
	_exit_placed = true
	# Point the way: a faint beacon glow visible through the fog toward the exit.
	exit_spawned.emit(world_center(EXIT_CELL))

func exit_world_pos() -> Vector3:
	return world_center(EXIT_CELL)

func _spawn_exit_room(c: Vector2i) -> void:
	var d = _cells.get(c)
	if d == null:
		return
	var root: Node3D = d["node"]
	# Cooler, brighter, quieter room. Recolor its panel and add a distinct light.
	if d.get("panel_mat"):
		var pm := d["panel_mat"] as StandardMaterial3D
		pm.emission = Color(0.8, 0.95, 1.0)
		pm.emission_energy_multiplier = 2.4
	d["base_energy"] = 2.4
	d["dark"] = false
	var lg := OmniLight3D.new()
	lg.light_color = Color(0.8, 0.95, 1.0)
	lg.light_energy = 2.4
	lg.omni_range = 9.0
	lg.shadow_enabled = false
	lg.position = Vector3(0, WALL_H - 0.2, 0)
	root.add_child(lg)
	d["light"] = lg
	d["exit"] = true

	# The one real door.
	var door_pos := Vector3(0, 0, 0)
	if _exit_door_scene:
		var door: Node3D = _exit_door_scene.instantiate()
		root.add_child(door)
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
		root.add_child(slab)

	# Trigger area at the doorway.
	var area := Area3D.new()
	area.collision_layer = 0
	area.collision_mask = 2  # detect player
	var acs := CollisionShape3D.new()
	var abox := BoxShape3D.new()
	abox.size = Vector3(2.0, 2.4, 1.2)
	acs.shape = abox
	acs.position = Vector3(0, 1.2, -1.5)
	area.add_child(acs)
	root.add_child(area)
	area.body_entered.connect(_on_exit_body_entered)
	_exit_area = area

	var wp: Vector3 = root.global_position + Vector3(0, 0, -1.6)
	exit_spawned.emit(wp)

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
