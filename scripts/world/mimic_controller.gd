extends Node3D
## A personal hallucination that borrows a survivor body. It never sends a
## network puppet and never attacks invisibly: the tell is behavioural — it
## does not call back, stands too still, then tilts and disappears when read.

const REMOTE_SCRIPT := "res://scripts/world/remote_player.gd"

var _player: Node3D
var _camera: Camera3D
var _maze: Node3D
var _entity: Node3D
var _world: Node
var _rng := RandomNumberGenerator.new()
var _body: CharacterBody3D
var _cooldown := 140.0
var _life := 0.0
var _witnessed := 0.0
var _spawned := 0
var _revealing := false
var _progress_unlocked := false

func setup(player: Node3D, camera: Camera3D, maze: Node3D, entity: Node3D, world: Node) -> void:
	_player = player
	_camera = camera
	_maze = maze
	_entity = entity
	_world = world

func _ready() -> void:
	_rng.randomize()
	_cooldown = _rng.randf_range(Tuning.MIMIC_MIN_GAP, Tuning.MIMIC_MAX_GAP)

func set_progress_unlocked(value: bool) -> void:
	_progress_unlocked = value

func _process(delta: float) -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_camera):
		return
	if is_instance_valid(_body):
		_tick_active(delta)
		return
	if not _progress_unlocked or _spawned >= Tuning.MIMIC_MAX_PER_RUN or GameManager.run_time < Tuning.MIMIC_ARM_TIME:
		return
	if _world and "_local_is_down" in _world and _world._local_is_down:
		return
	if _entity and _entity.has_method("allows_mimic") and not _entity.allows_mimic():
		return
	_cooldown -= delta
	if _cooldown <= 0.0:
		_try_spawn()

func _try_spawn() -> void:
	_cooldown = _rng.randf_range(Tuning.MIMIC_MIN_GAP, Tuning.MIMIC_MAX_GAP)
	var forward: Vector3 = -_camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length() < 0.01:
		return
	forward = forward.normalized()
	for attempt in 10:
		var angle := _rng.randf_range(-0.52, 0.52)
		var distance := _rng.randf_range(Tuning.MIMIC_MIN_DISTANCE, Tuning.MIMIC_MAX_DISTANCE)
		var pos := _player.global_position + forward.rotated(Vector3.UP, angle) * distance
		pos.y = 0.1
		var cell := Vector2i(int(floor(pos.x / 4.0 + 0.5)), int(floor(pos.z / 4.0 + 0.5)))
		if _maze and _maze.has_method("is_cell_open") and not _maze.is_cell_open(cell):
			continue
		if not _ray_clear(_camera.global_position, pos + Vector3.UP * 1.4):
			continue
		_spawn_body(pos)
		return

func _spawn_body(pos: Vector3) -> void:
	_body = CharacterBody3D.new()
	_body.set_script(load(REMOTE_SCRIPT))
	_body.player_id = _pick_appearance_id()
	add_child(_body)
	_body.global_position = pos
	_body.look_at(Vector3(_player.global_position.x, pos.y, _player.global_position.z), Vector3.UP)
	_body.rotation.y += PI # the borrowed survivor initially faces away
	_body.set_meta("is_mimic", true)
	_life = 12.0
	_witnessed = 0.0
	_spawned += 1

func _pick_appearance_id() -> int:
	if _world and _world.has_method("living_remote_player_ids"):
		var ids: Array = _world.living_remote_player_ids()
		if not ids.is_empty():
			return int(ids[_rng.randi() % ids.size()])
	return 0

func _tick_active(delta: float) -> void:
	if _revealing:
		return
	_life -= delta
	var to_body := _body.global_position + Vector3.UP * 1.4 - _camera.global_position
	var distance := to_body.length()
	var direction := to_body.normalized()
	var seen := (-_camera.global_transform.basis.z).dot(direction) > 0.92 and _ray_clear(_camera.global_position, _body.global_position + Vector3.UP * 1.4)
	if seen:
		_witnessed += delta
	else:
		_witnessed = maxf(0.0, _witnessed - delta * 0.5)
	if distance < 5.0 or _witnessed >= Tuning.MIMIC_WITNESS_TIME:
		_reveal()
	elif _life <= 0.0:
		_clear_body()

func _reveal() -> void:
	_revealing = true
	if _world and _world.has_method("mimic_revealed"):
		_world.mimic_revealed(_body.global_position)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_body, "rotation:z", 0.48, 0.35).set_trans(Tween.TRANS_BACK)
	tween.tween_property(_body, "scale", Vector3(0.86, 1.15, 0.86), 0.35)
	tween.chain().tween_interval(0.2)
	tween.chain().tween_callback(_clear_body)

func _clear_body() -> void:
	if is_instance_valid(_body):
		_body.queue_free()
	_body = null
	_revealing = false

func _ray_clear(from: Vector3, to: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	query.exclude = [_player]
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()
