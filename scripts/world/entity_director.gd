extends Node3D
## The vultos. Governs every appearance of the shadowy figures under the
## GOLDEN RULE: a vulto is NEVER seen from the front or up close for long.
##
## Modes:
##   PEEK   — a silhouette leans out from a distant corner, recedes when
##            looked at directly, vanishes if you snap the camera away.
##   JUMP   — rare, dry: a figure snaps VERY close for < 1s with a short
##            scream, then is gone. No death screen.
##   CHASE  — from minute 8: a figure with clear line of sight starts RUNNING
##            at you through the corridors (never through walls) with heavy
##            steps + a distorted scream that swells as it closes in. Break
##            line of sight for 2s and it vanishes instantly, total silence.
##            If it touches you: game over.
##   STALK  — final phase near the exit: a slow permanent follower; linger
##            too long or hit a dead end and the lights die → game over.
##
## The director paces itself off GameManager.run_time and the player's
## look_back_count (fear feeds the game).

signal request_dread(v: float)         # 0..1 atmosphere intensity
signal request_flicker(v: float)       # 0..1 light strobe
signal jumpscare()                     # fire the scream + pulse
signal muffle(active: bool)            # underwater/low-pass when vulto near-but-unseen
signal caught()                        # game over — entity touched player
signal chase_started()
signal chase_ended()

const WATCHER_PATH := "res://assets/characters/watcher_silhouette/watcher_silhouette.glb"
const ANIM_LIB := "res://assets/characters/watcher_silhouette/watcher_silhouette_animations.tres"

# All pacing/difficulty values live in scripts/tuning.gd — edit there, not here.
const PLAYER_SPEED := 2.4
const CHASE_SPEED := Tuning.CHASE_SPEED
const STALK_SPEED := Tuning.STALK_SPEED
const CATCH_DIST := Tuning.CATCH_DIST
const LOS_LOSE_TIME := Tuning.LOS_LOSE_TIME

var _player: Node3D = null
var _camera: Camera3D = null
var _maze = null

# runtime
var _watcher_scene: PackedScene = null
var _anim_lib: AnimationLibrary = null
var _rng := RandomNumberGenerator.new()

# current apparition
var _mode := "idle"                    # idle | peek | jump | chase | stalk
var _figure: Node3D = null
var _fig_anim: AnimationPlayer = null
var _peek_recede := false
var _peek_timer := 0.0
var _los_lost := 0.0
var _stalk_active := false
var _linger_timer := 0.0               # time player has stood still in stalk phase
var _prox_muffle := false              # a figure is near but unseen → world muffled

# chase pathing / audio
var _chase_path: Array = []            # Vector2i waypoints along corridors
var _path_timer := 0.0
var _path_fail := 0.0                  # seconds spent with no route to the player
var _chase_steps: AudioStreamPlayer3D = null
var _chase_scream: AudioStreamPlayer3D = null

# scheduling
var _next_peek := 0.0
var _next_jump := 0.0
var _last_jump_time := -999.0
var _jump_count := 0
var _chase_done := 0
var _next_chase := 0.0
var _sound_pressure := 0.0             # random ambient events scale with this
var _next_sound := 0.0
var _dread := 0.0
var _final_phase := false
var _ended := false
var _logged_mode := "idle"             # last mode reported to the debug log

# sfx streams
var _sfx: Dictionary = {}

func setup(player: Node3D, camera: Camera3D, maze) -> void:
	_player = player
	_camera = camera
	_maze = maze

func _ready() -> void:
	_rng.randomize()
	if ResourceLoader.exists(WATCHER_PATH):
		_watcher_scene = load(WATCHER_PATH)
	if ResourceLoader.exists(ANIM_LIB):
		_anim_lib = load(ANIM_LIB)
	_load_sfx()
	_next_peek = Tuning.PEEK_FIRST_SIGHTING + _rng.randf_range(-15.0, 30.0)
	_next_jump = 999.0                                   # armed at JUMP_ARM_TIME
	_next_chase = 999.0                                  # armed at CHASE_ARM_TIME
	_next_sound = 25.0

func _load_sfx() -> void:
	var paths := {
		"jump": "res://assets/audio/sfx/enemy/enemy_jumpscare_scream.mp3",
		"chase_scream": "res://assets/audio/sfx/enemy/enemy_chase_distorted_scream.mp3",
		"heavy_steps": "res://assets/audio/sfx/enemy/enemy_entity_heavy_steps.mp3",
		"breath": "res://assets/audio/sfx/enemy/enemy_close_breath.mp3",
		"phone": "res://assets/audio/sfx/environment/environment_phone_ring_twice.mp3",
		"door": "res://assets/audio/sfx/environment/environment_distant_door_slam.mp3",
		"ceiling": "res://assets/audio/sfx/environment/environment_ceiling_drag.mp3",
		"footsteps_echo": "res://assets/audio/sfx/environment/environment_distant_footsteps_echo.mp3",
		"creak": "res://assets/audio/sfx/environment/environment_hallway_rearrange_creak.mp3",
		"flicker": "res://assets/audio/sfx/environment/environment_light_flicker_buzz.mp3",
	}
	for k in paths:
		if ResourceLoader.exists(paths[k]):
			_sfx[k] = load(paths[k])

# ---------------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _ended or not is_instance_valid(_player) or not is_instance_valid(_camera):
		return
	var t := 0.0
	var looks := 0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
		looks = GameManager.look_back_count
	_arm_schedules(t)
	_update_dread(t, looks, delta)
	_update_random_sounds(t, looks, delta)

	if _mode != _logged_mode:
		if Tuning.DEBUG_ENTITY_LOG and OS.is_debug_build():
			print("[entity] ", _logged_mode, " -> ", _mode, " @ ", snappedf(t, 0.1), "s")
		_logged_mode = _mode

	match _mode:
		"peek":
			_tick_peek(delta)
		"chase":
			_tick_chase(delta)
		"stalk":
			_tick_stalk(delta)
		_:
			_tick_idle(t)

func _arm_schedules(t: float) -> void:
	if _next_jump > 900.0 and t >= Tuning.JUMP_ARM_TIME:
		_next_jump = t + _rng.randf_range(20.0, 70.0)
	if _next_chase > 900.0 and t >= Tuning.CHASE_ARM_TIME:
		_next_chase = t + _rng.randf_range(15.0, 60.0)

## False-security window: the seconds before a scheduled jumpscare go quiet —
## fewer sounds, lower dread — so the scare lands out of calm, not chaos.
func _in_pre_jump_calm(t: float) -> bool:
	return _next_jump < 900.0 and t > _next_jump - Tuning.PRE_JUMP_CALM_WINDOW and t < _next_jump and _mode == "idle"

func _update_dread(t: float, looks: int, delta: float) -> void:
	# Base dread rises slowly over ~12 min, plus the player's own fear (look-backs).
	var base := clampf(t / 720.0, 0.0, 0.75)
	var fear := clampf(float(looks) * 0.02, 0.0, 0.25)
	var target := clampf(base + fear, 0.0, 1.0)
	if _mode == "chase":
		target = 1.0
	elif _mode == "stalk":
		target = maxf(target, 0.7)
	elif _in_pre_jump_calm(t):
		target *= 0.45
	if _prox_muffle:
		target = minf(1.0, target + 0.25)
	_dread = lerpf(_dread, target, delta * 0.6)
	request_dread.emit(_dread)

func _update_random_sounds(t: float, looks: int, delta: float) -> void:
	if _mode == "chase":
		return
	_next_sound -= delta
	if _in_pre_jump_calm(t):
		return  # hold the silence before the scare
	# more frequent when the player keeps looking back (fear feeds the game)
	var fear_mult := 1.0 + clampf(float(looks) * 0.06, 0.0, 1.6)
	if _next_sound <= 0.0:
		_play_random_distant_sound(t)
		_next_sound = _rng.randf_range(Tuning.SOUND_GAP_MIN, Tuning.SOUND_GAP_MAX) / fear_mult

func _play_random_distant_sound(t: float) -> void:
	if not has_node("/root/AudioManager"):
		return
	var pool := ["door", "footsteps_echo", "ceiling", "creak", "phone"]
	# close breath: at most once per run, only after a few minutes
	if t > 240.0 and _rng.randf() < 0.08 and not get_meta("breathed", false):
		set_meta("breathed", true)
		if _sfx.has("breath"):
			AudioManager.play_sfx(_sfx["breath"], -6.0)
		return
	var key: String = pool[_rng.randi() % pool.size()]
	if _sfx.has(key):
		# distant + muffled: spawn at a point away from the player
		var ang := _rng.randf() * TAU
		var pos: Vector3 = _player.global_position + Vector3(cos(ang), 0, sin(ang)) * _rng.randf_range(14.0, 26.0)
		AudioManager.play_sfx_3d(self, _sfx[key], pos, -8.0, 45.0, _rng.randf_range(0.9, 1.05))

# ---------------------------------------------------------------------------
# IDLE — decide when to summon
# ---------------------------------------------------------------------------
func _tick_idle(t: float) -> void:
	if _final_phase and not _stalk_active:
		_begin_stalk()
		return
	if t >= _next_chase and _chase_done < Tuning.CHASE_MAX_PER_RUN:
		_begin_chase()
		return
	if t >= _next_jump and _can_jump(t):
		_begin_jump(t)
		return
	if t >= _next_peek:
		_begin_peek()
		return

func _can_jump(t: float) -> bool:
	if _jump_count >= Tuning.JUMP_MAX_PER_RUN:
		return false
	if t - _last_jump_time < Tuning.JUMP_MIN_GAP:
		return false
	return true

# ---------------------------------------------------------------------------
# PEEK — silhouette at a distant corner, recedes when looked at
# ---------------------------------------------------------------------------
func _begin_peek() -> void:
	var spot := _find_peek_spot()
	if spot == Vector3.INF:
		_next_peek = _dread_scaled_peek_gap()  # try again later
		return
	_spawn_figure(spot, false)
	if _figure:
		_face_player(_figure)
		_play_anim("ual1_Idle")
	_mode = "peek"
	_peek_recede = false
	_peek_timer = _rng.randf_range(6.0, 11.0)

func _dread_scaled_peek_gap() -> float:
	var t := 0.0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
	# peeks get more frequent as the run goes on
	var gap := lerpf(Tuning.PEEK_GAP_EARLY, Tuning.PEEK_GAP_LATE, clampf(t / 600.0, 0.0, 1.0))
	return (0.0 if not has_node("/root/GameManager") else GameManager.run_time) + gap * _rng.randf_range(0.7, 1.3)

func _tick_peek(delta: float) -> void:
	if not is_instance_valid(_figure):
		_end_apparition()
		return
	_peek_timer -= delta

	# NEVER seen up close: gone before the player can reach it.
	var flat := _figure.global_position - _player.global_position
	flat.y = 0.0
	if flat.length() < Tuning.PEEK_VANISH_DIST:
		_end_apparition()
		return

	var looked := _player_looking_at(_figure, 0.22)
	var visible_now := _in_view(_figure) and _has_los(_figure)

	# Near but unseen → the hum drops and the world goes muffled.
	var prox := flat.length() < Tuning.PEEK_MUFFLE_DIST and not visible_now
	if prox != _prox_muffle:
		_prox_muffle = prox
		muffle.emit(prox)

	if looked:
		# recede slowly backward from the player and start to fade
		_peek_recede = true
		var away: Vector3 = (_figure.global_position - _player.global_position)
		away.y = 0
		if away.length() > 0.01:
			away = away.normalized()
			_figure.global_position += away * (PLAYER_SPEED * 0.75) * delta
			_play_anim("ual1_Walk")
		_fade_figure(delta, 1.6)
		if _figure_alpha() <= 0.05:
			_end_apparition()
			return
	else:
		# It WATCHES: quietly tracks the player while unobserved.
		_face_player(_figure)
		# If it was visible and the player snapped away, vanish instantly —
		# going back to look for it must find nothing.
		if _peek_recede and not visible_now:
			_end_apparition()
			return

	if _peek_timer <= 0.0 and not looked:
		# time out — slip back around the corner
		_end_apparition()

func _find_peek_spot() -> Vector3:
	# A valid peek spot must be (a) currently OFF-screen, so it "appears" when
	# the player turns, and (b) on a clear sightline from the player's eye —
	# otherwise it spawns behind maze walls and is never seen at all.
	var eye: Vector3 = _camera.global_position
	for _i in range(14):
		var ang := _rng.randf() * TAU
		var dist := _rng.randf_range(Tuning.PEEK_DIST_MIN, Tuning.PEEK_DIST_MAX)
		var p: Vector3 = _player.global_position + Vector3(cos(ang), 0, sin(ang)) * dist
		p.y = 0.0
		var head := p + Vector3(0, 1.6, 0)
		if _in_view_point(head):
			continue
		if not _ray_clear(eye, head):
			continue
		return p
	return Vector3.INF

# ---------------------------------------------------------------------------
# JUMP — dry, < 1s, very close, then gone. No death.
# ---------------------------------------------------------------------------
func _begin_jump(t: float) -> void:
	# Spawn IN FRONT of the camera, very close, for a flash — a jumpscare the
	# player can't see is just a loud noise. Ray-checked so it never clips a wall.
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)
	var fwd: Vector3 = -_camera.global_transform.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)
	var eye: Vector3 = _camera.global_position
	var want := 2.1
	var hit := _ray_hit(eye, eye + fwd * (want + 0.4))
	if not hit.is_empty():
		want = maxf(0.9, eye.distance_to(hit["position"]) - 0.5)
	var pos: Vector3 = _player.global_position + fwd * want
	pos.y = 0.0
	_spawn_figure(pos, true)
	if _figure:
		_face_player(_figure)
		_set_figure_alpha(1.0)
		_play_anim("ual1_Idle")
	_mode = "jump"
	jumpscare.emit()
	if has_node("/root/AudioManager") and _sfx.has("jump"):
		AudioManager.play_sfx(_sfx["jump"], -3.0)
	_last_jump_time = t
	_jump_count += 1
	# yank it away after < 1s, then a forced calm — nothing may interrupt
	get_tree().create_timer(Tuning.JUMP_DURATION).timeout.connect(func():
		if is_instance_valid(self):
			_end_apparition()
			_next_peek = t + _rng.randf_range(Tuning.JUMP_CALM_MIN, Tuning.JUMP_CALM_MAX)
			_next_jump = t + _rng.randf_range(150.0, 260.0)
			_next_chase = maxf(_next_chase, t + 60.0))

# ---------------------------------------------------------------------------
# CHASE — runs at the player; lose LOS for 2s and it's gone
# ---------------------------------------------------------------------------
func _begin_chase() -> void:
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)
	var spot := _find_chase_spawn()
	if spot == Vector3.INF:
		_next_chase = (0.0 if not has_node("/root/GameManager") else GameManager.run_time) + _rng.randf_range(8.0, 20.0)
		return
	_spawn_figure(spot, false)
	if not _figure:
		return
	_set_figure_alpha(1.0)
	_face_player(_figure)
	_play_anim("ual1_Sprint")
	_mode = "chase"
	_los_lost = 0.0
	_chase_path = []
	_path_timer = 0.0
	_path_fail = 0.0
	_chase_done += 1
	chase_started.emit()
	request_flicker.emit(1.0)
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		AudioManager.play_sfx(_sfx["chase_scream"], -2.0)
	# Looping positional layers ride on the figure: distance IS the mix.
	_chase_steps = _attach_loop(_figure, _sfx.get("heavy_steps"), -4.0)
	_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)

func _find_chase_spawn() -> Vector3:
	# A spot the player can actually SEE down a corridor, 8-14m out — the
	# reveal is the scare, and a clear sightline means a clear starting route.
	var eye: Vector3 = _camera.global_position
	for _i in range(16):
		var ang := _rng.randf() * TAU
		var dist := _rng.randf_range(9.0, 14.0)
		var p: Vector3 = _player.global_position + Vector3(cos(ang), 0, sin(ang)) * dist
		p.y = 0.0
		if _ray_clear(eye, p + Vector3(0, 1.5, 0)):
			return p
	# fallback: right behind the player, close enough to matter
	var behind: Vector3 = _player.global_transform.basis.z
	behind.y = 0
	if behind.length() < 0.01:
		return Vector3.INF
	var bp: Vector3 = _player.global_position + behind.normalized() * 6.0
	bp.y = 0.0
	return bp

func _tick_chase(delta: float) -> void:
	if not is_instance_valid(_figure):
		_end_chase(false)
		return
	var to: Vector3 = _player.global_position - _figure.global_position
	to.y = 0
	var d := to.length()
	if d <= CATCH_DIST:
		_do_caught()
		return
	_chase_move(delta, d)
	# the scream layer swells as it closes in; steps quicken
	var closeness := clampf(1.0 - (d - CATCH_DIST) / 14.0, 0.0, 1.0)
	if is_instance_valid(_chase_scream):
		_chase_scream.volume_db = lerpf(-20.0, -4.0, closeness)
	if is_instance_valid(_chase_steps):
		_chase_steps.pitch_scale = lerpf(1.0, 1.18, closeness)
	# line of sight: 2s broken and it is gone, instantly
	var seen := _in_view(_figure) and _has_los(_figure)
	if seen:
		_los_lost = 0.0
	else:
		_los_lost += delta
		if _los_lost >= LOS_LOSE_TIME:
			_end_chase(true)
			return
	request_flicker.emit(1.0)

## Corridor-bound pursuit: follow BFS waypoints through the maze so the figure
## never phases through walls — cornering well is how the player escapes.
func _chase_move(delta: float, dist_to_player: float) -> void:
	_path_timer -= delta
	if _path_timer <= 0.0 and _maze and _maze.has_method("corridor_path"):
		_path_timer = Tuning.CHASE_PATH_REFRESH
		var from_cell: Vector2i = _cell_of(_figure.global_position)
		var to_cell: Vector2i = _cell_of(_player.global_position)
		_chase_path = _maze.corridor_path(from_cell, to_cell)
	var target: Vector3 = _player.global_position
	if _chase_path.size() >= 2:
		_path_fail = 0.0
		target = _maze.world_center(_chase_path[1])
		# path cell reached → advance
		var flat := target - _figure.global_position
		flat.y = 0
		if flat.length() < 0.5:
			_chase_path.pop_front()
			if _chase_path.size() >= 2:
				target = _maze.world_center(_chase_path[1])
	elif _chase_path.size() == 1 or dist_to_player < 3.0:
		# same cell as the player: go straight in
		_path_fail = 0.0
		target = _player.global_position
	else:
		# no route (sealed pocket): give it a few seconds, then let it dissolve
		_path_fail += delta
		if _path_fail > Tuning.CHASE_NO_ROUTE_TIMEOUT:
			_end_chase(true)
			return
	var step_dir: Vector3 = target - _figure.global_position
	step_dir.y = 0
	if step_dir.length() > 0.01:
		_figure.global_position += step_dir.normalized() * CHASE_SPEED * delta
		if dist_to_player < 4.0:
			_face_player(_figure)
		else:
			var face: Vector3 = _figure.global_position + step_dir
			face.y = _figure.global_position.y
			if _figure.global_position.distance_to(face) > 0.05:
				_figure.look_at(face, Vector3.UP)

func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / 4.0 + 0.5)), int(floor(p.z / 4.0 + 0.5)))

func _end_chase(vanished: bool) -> void:
	_chase_steps = null
	_chase_scream = null
	_chase_path = []
	_remove_figure()   # audio players are children of the figure → instant cut
	_mode = "idle"
	chase_ended.emit()
	request_flicker.emit(0.0)
	var t := 0.0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
	_next_chase = t + _rng.randf_range(60.0, 140.0)
	_next_peek = maxf(_next_peek, t + 20.0)

func _do_caught() -> void:
	if _ended:
		return
	_ended = true
	request_flicker.emit(0.0)
	caught.emit()

# ---------------------------------------------------------------------------
# STALK — final phase permanent slow follower
# ---------------------------------------------------------------------------
func _begin_stalk() -> void:
	_stalk_active = true
	var behind: Vector3 = _player.global_transform.basis.z
	behind.y = 0
	if behind.length() < 0.01:
		behind = Vector3(0, 0, 1)
	behind = behind.normalized()
	var pos: Vector3 = _player.global_position + behind * 8.0
	pos.y = 0.0
	_spawn_figure(pos, false)
	if _figure:
		_set_figure_alpha(0.9)
		_play_anim("ual1_Walk")
	_mode = "stalk"
	_linger_timer = 0.0

func _tick_stalk(delta: float) -> void:
	if not is_instance_valid(_figure):
		_begin_stalk()
		return
	var to: Vector3 = _player.global_position - _figure.global_position
	to.y = 0
	var d := to.length()
	# always keeps a slow distance; never quite catches unless player stalls
	if d > Tuning.STALK_KEEP_DISTANCE and d > 0.01:
		_figure.global_position += to.normalized() * STALK_SPEED * delta
		_face_player(_figure)
	# measure player stillness
	var pv := 0.0
	if _player is CharacterBody3D:
		pv = Vector3(_player.velocity.x, 0, _player.velocity.z).length()
	if pv < 0.4:
		_linger_timer += delta
	else:
		_linger_timer = maxf(0.0, _linger_timer - delta * 1.5)
	if _linger_timer > Tuning.STALK_LINGER_KILL:
		_stalk_kill()

func _stalk_kill() -> void:
	if _ended:
		return
	_ended = true
	request_flicker.emit(0.0)
	request_dread.emit(1.0)
	# a step behind, lights out, then caught
	if has_node("/root/AudioManager") and _sfx.has("heavy_steps"):
		AudioManager.play_sfx(_sfx["heavy_steps"], 0.0)
	caught.emit()

func enter_final_phase() -> void:
	_final_phase = true

# ---------------------------------------------------------------------------
# Figure helpers
# ---------------------------------------------------------------------------
func _spawn_figure(pos: Vector3, _instant: bool) -> void:
	_remove_figure()
	if _watcher_scene == null:
		return
	var mesh_root := Node3D.new()
	add_child(mesh_root)
	var model: Node3D = _watcher_scene.instantiate()
	mesh_root.add_child(model)
	ModelUtils.setup_character_for_movement(model, 2.35)   # too-tall, thin
	mesh_root.global_position = pos
	# darken to a pure silhouette
	_blacken(model)
	# animation
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	if _anim_lib:
		ap.add_animation_library("", _anim_lib)
		ModelUtils.set_animation_loops(ap)
	_fig_anim = ap
	_figure = mesh_root
	_set_figure_alpha(1.0)

func _blacken(model: Node3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.02, 0.02, 0.025)
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for child in model.find_children("*", "MeshInstance3D"):
		var mi := child as MeshInstance3D
		if mi:
			mi.material_override = mat
			mi.set_meta("silh_mat", mat)

func _play_anim(name: String) -> void:
	if _fig_anim and _fig_anim.has_animation(name):
		_fig_anim.play(name)

func _face_player(fig: Node3D) -> void:
	if not is_instance_valid(fig) or not is_instance_valid(_player):
		return
	var look: Vector3 = _player.global_position
	look.y = fig.global_position.y
	if fig.global_position.distance_to(look) > 0.05:
		fig.look_at(look, Vector3.UP)

func _set_figure_alpha(a: float) -> void:
	if not is_instance_valid(_figure):
		return
	for child in _figure.find_children("*", "MeshInstance3D"):
		var mi := child as MeshInstance3D
		if mi and mi.has_meta("silh_mat"):
			var m := mi.get_meta("silh_mat") as StandardMaterial3D
			m.albedo_color.a = a

func _figure_alpha() -> float:
	if not is_instance_valid(_figure):
		return 0.0
	for child in _figure.find_children("*", "MeshInstance3D"):
		var mi := child as MeshInstance3D
		if mi and mi.has_meta("silh_mat"):
			return (mi.get_meta("silh_mat") as StandardMaterial3D).albedo_color.a
	return 1.0

func _fade_figure(delta: float, rate: float) -> void:
	_set_figure_alpha(maxf(0.0, _figure_alpha() - delta * rate))

func _remove_figure() -> void:
	if is_instance_valid(_figure):
		_figure.queue_free()
	_figure = null
	_fig_anim = null

func _end_apparition() -> void:
	_remove_figure()
	_mode = "idle"
	_prox_muffle = false
	muffle.emit(false)
	_next_peek = _dread_scaled_peek_gap()

## Looping positional one-figure audio layer (dies with the figure).
func _attach_loop(parent: Node3D, stream, vol: float) -> AudioStreamPlayer3D:
	if parent == null or stream == null or not is_instance_valid(parent):
		return null
	var s: AudioStream = (stream as AudioStream).duplicate()
	if s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	p.bus = "SFX"
	p.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	p.volume_db = vol
	p.max_distance = 34.0
	p.unit_size = 7.0
	p.position = Vector3(0, 1.2, 0)
	parent.add_child(p)
	p.play()
	return p

# ---------------------------------------------------------------------------
# Perception helpers
# ---------------------------------------------------------------------------
func _in_view(node: Node3D) -> bool:
	if not is_instance_valid(node) or not is_instance_valid(_camera):
		return false
	return _in_view_point(node.global_position + Vector3(0, 1.4, 0))

func _in_view_point(p: Vector3) -> bool:
	if not is_instance_valid(_camera):
		return false
	if _camera.is_position_behind(p):
		return false
	var sp := _camera.unproject_position(p)
	var vp := _camera.get_viewport().get_visible_rect().size
	return sp.x >= 0 and sp.x <= vp.x and sp.y >= 0 and sp.y <= vp.y

func _player_looking_at(node: Node3D, tol: float) -> bool:
	# true if the figure is near screen-center (player is directly regarding it)
	if not is_instance_valid(node) or not is_instance_valid(_camera):
		return false
	var p: Vector3 = node.global_position + Vector3(0, 1.4, 0)
	if _camera.is_position_behind(p):
		return false
	var to: Vector3 = (p - _camera.global_position).normalized()
	var fwd: Vector3 = -_camera.global_transform.basis.z
	return fwd.dot(to) > (1.0 - tol)

func _has_los(node: Node3D) -> bool:
	if not is_instance_valid(node) or not is_instance_valid(_camera):
		return false
	return _ray_clear(_camera.global_position, node.global_position + Vector3(0, 1.2, 0))

func _ray_hit(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1   # environment only
	return space.intersect_ray(q)

func _ray_clear(from: Vector3, to: Vector3) -> bool:
	return _ray_hit(from, to).is_empty()
