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
# corner-peek: the figure starts BEHIND a wall end and leans out
var _peek_corner := false
var _peek_from := Vector3.ZERO         # hidden position (behind cover)
var _peek_to := Vector3.ZERO           # exposed position (leaning out)
var _lean := 0.0                       # 0 hidden .. 1 fully out
var _lean_dir := 1.0                   # 1 leaning out, -1 sliding back
var _jump_prev_fov := 72.0             # camera fov to restore after the scare

# "being watched" layer
var _peek_style := "stare"             # stare: holds your gaze a beat, THEN slips
									   # away | skittish: gone the instant you look
var _stare_timer := -1.0               # -1 = stare not started yet
var _peek_witnessed := false           # did this apparition ever enter the view?
var _peek_loop_count := 0
var _peek_wait_timer := 0.0
var _unseen_streak := 0                # peeks the player never saw → retry sooner
var _last_lookback := 0                # GameManager.look_back_count already handled
var _lookback_cd := 0.0                # cooldown for the turn-around reveal

# chase phases: heard first, then seen; loses you, searches, re-acquires
var _chase_state := "pursue"           # windup | pursue | search
var _windup_timer := 0.0
var _windup_spot := Vector3.ZERO
var _last_seen_pos := Vector3.ZERO     # where the entity last had the player
var _fig_sees := false                 # entity→player line of sight
var _has_seen_player_this_chase := false
var _search_timer := 0.0
var _chase_time := 0.0                 # seconds since the charge began
var _close_breath_cd := 0.0
var _stumble_timer := 0.0
var _stumble_duration := 0.0
var _chase_speed_mult := 1.0
var _roam_cooldown := 15.0
var _roam_path : Array = []
var _roam_target := Vector3.ZERO
var _roam_wait := 0.0

# director-lite: recent-intensity meter paces the next event
var _stress := 0.0

# menace: every snus taken tightens the screws — shorter gaps, higher caps.
# 0.0 (none) .. 1.0 (all five). Fed by game_world on every shared pickup.
var _menace := 0.0

# shadow: the silent tail. While the player isn't looking it stands EXPOSED
# at a wall corner (free — they can't see it); the moment their gaze lands on
# it, it holds half a second — seen looking — then slips behind the wall.
var _next_shadow := 999999.0
var _shadow_state := "watch"           # watch | hold | hiding | hidden
var _shadow_hold := 0.0
var _shadow_wait := 0.0
var _shadow_timer := 0.0
var _shadow_reveals := 0
var _shadow_max_reveals := 3

# co-op shared entity: host schedules and picks targets; the target client
# realizes the scare with its own camera; everyone else renders a mirror.
var _mp := false
var _mp_host := false
var _world = null                      # game_world (net relay + alive players)
var _net_fig_active := false           # another client's apparition is live
var _net_fig_watchdog := 0.0           # frees the slot if their scare fizzles
var _owns_fig := false
var _fig_send_timer := 0.0
var _mirror: Node3D = null
var _mirror_anim: AnimationPlayer = null
var _mirror_steps: AudioStreamPlayer3D = null
var _mirror_scream: AudioStreamPlayer3D = null
var _mirror_mode := ""
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

## Co-op: the entity is ONE and the same for everyone. The host directs.
func setup_mp(world, host: bool) -> void:
	_world = world
	_mp = true
	_mp_host = host

func _now() -> float:
	return GameManager.run_time if has_node("/root/GameManager") else 0.0

## Difficulty rises with the tins: 0.0 = untouched run, 1.0 = all collected.
func set_menace(v: float) -> void:
	_menace = clampf(v, 0.0, 1.0)

func _ready() -> void:
	_rng.randomize()
	if ResourceLoader.exists(WATCHER_PATH):
		_watcher_scene = load(WATCHER_PATH)
	if ResourceLoader.exists(ANIM_LIB):
		_anim_lib = load(ANIM_LIB)
	_load_sfx()
	_next_peek = 1.0
	_next_jump = 999.0                                   # armed at JUMP_ARM_TIME
	_next_chase = 999.0                                  # armed at CHASE_ARM_TIME
	_next_sound = 25.0

func _load_sfx() -> void:
	var paths := {
		"jump": "res://assets/audio/sfx/enemy/enemy_jumpscare_scream.mp3",
		"chase_scream": "res://assets/audio/juanjo/juanjo_sound - Backrooms Entity 9.wav",
		"heavy_steps": "res://assets/audio/sfx/enemy/enemy_entity_heavy_steps.mp3",
		"breath": "res://assets/audio/juanjo/juanjo_sound - Backrooms Entity 23.wav",
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
	# crouching calms the body: stress bleeds off ~2.5x faster while low
	var stress_decay := 0.01
	if is_instance_valid(_player) and "is_crouching" in _player and _player.is_crouching:
		stress_decay = 0.025
	_stress = maxf(0.0, _stress - delta * stress_decay)
	_lookback_cd = maxf(0.0, _lookback_cd - delta)
	_close_breath_cd = maxf(0.0, _close_breath_cd - delta)
	_maybe_lookback_reveal(t, looks)
	_tick_hallucination(delta)

	if _mode != _logged_mode:
		if Tuning.DEBUG_ENTITY_LOG and OS.is_debug_build():
			print("[entity] ", _logged_mode, " -> ", _mode, " @ ", snappedf(t, 0.1), "s")
		_logged_mode = _mode

	# A due jumpscare doesn't queue politely behind a watcher — it interrupts.
	# (It fires while walking, standing, mid-peek, mid-tail: whenever it's due.)
	if (_mode == "peek" or _mode == "shadow") and t >= _next_jump and _can_jump(t):
		if not _mp or (_mp_host and not _net_fig_active):
			_end_apparition()
			_begin_jump(t)

	match _mode:
		"peek":
			_tick_peek(delta)
		"shadow":
			_tick_shadow(delta)
		"chase":
			_tick_chase(delta)
		"stalk":
			_tick_stalk(delta)
		"roam":
			_tick_roam(delta)
		_:
			_tick_idle(t)
			if not _mp or _mp_host:
				_roam_cooldown = maxf(0.0, _roam_cooldown - delta)
				if _roam_cooldown <= 0.0:
					_begin_roam()

	if _mp:
		_net_fig_tick(delta)

func _arm_schedules(t: float) -> void:
	# Collected snus pull every arm time closer — progress wakes it up.
	var arm_scale := 1.0 - 0.5 * _menace
	if _next_jump > 900.0 and t >= Tuning.JUMP_ARM_TIME * arm_scale:
		_next_jump = t + _rng.randf_range(20.0, 70.0)
	if _next_chase > 900.0 and t >= Tuning.CHASE_ARM_TIME * arm_scale:
		_next_chase = t + _rng.randf_range(15.0, 60.0)
	if _next_shadow > 900000.0 and t >= Tuning.SHADOW_ARM_TIME * arm_scale:
		_next_shadow = t + _rng.randf_range(10.0, 60.0)

func _add_stress(v: float) -> void:
	_stress = clampf(_stress + v, 0.0, 1.0)

# ---------------------------------------------------------------------------
# CORNER-EYE PARANOIA — at high stress the mind starts making things up:
# a black silhouette at the EDGE of the view for ~0.3s, gone the instant the
# player turns to face it. Never solid, never in the way, never real.
# ---------------------------------------------------------------------------
var _halluc: Node3D = null
var _halluc_life := 0.0
var _halluc_cd := 20.0

func _tick_hallucination(delta: float) -> void:
	if is_instance_valid(_halluc):
		_halluc_life -= delta
		# facing it kills it instantly — there was never anything there
		var to: Vector3 = (_halluc.global_position + Vector3(0, 1.4, 0) - _camera.global_position).normalized()
		var fwd: Vector3 = -_camera.global_transform.basis.z
		if fwd.dot(to) > 0.92 or _halluc_life <= 0.0:
			_halluc.queue_free()
			_halluc = null
		return
	if _mode != "idle" or _stress < 0.35 or _watcher_scene == null:
		return
	_halluc_cd -= delta
	if _halluc_cd > 0.0:
		return
	_halluc_cd = _rng.randf_range(8.0, 22.0) * (1.5 - _stress)
	# spawn at the EDGE of vision: 28-40° off the camera forward, 5-9 m out
	var fwd2: Vector3 = -_camera.global_transform.basis.z
	fwd2.y = 0
	if fwd2.length() < 0.01:
		return
	fwd2 = fwd2.normalized()
	var side := 1.0 if _rng.randf() < 0.5 else -1.0
	var dir := fwd2.rotated(Vector3.UP, side * _rng.randf_range(0.5, 0.7))
	var pos: Vector3 = _player.global_position + dir * _rng.randf_range(5.0, 9.0)
	pos.y = 0.0
	if not _ray_clear(_camera.global_position, pos + Vector3(0, 1.5, 0)):
		return
	var mesh_root := Node3D.new()
	add_child(mesh_root)
	var model: Node3D = _watcher_scene.instantiate()
	mesh_root.add_child(model)
	ModelUtils.setup_character_for_movement(model, 2.85)
	mesh_root.global_position = pos
	_blacken(model)
	# half-there: darker than the world, lighter than real
	for child in model.find_children("*", "MeshInstance3D"):
		var mi := child as MeshInstance3D
		if mi and mi.has_meta("silh_mat"):
			(mi.get_meta("silh_mat") as StandardMaterial3D).albedo_color.a = 0.55
	_halluc = mesh_root
	_halluc_life = 0.3

## The cruellest trick in the book: sometimes when the player whips around to
## check behind them, something IS there — mid-distance, plainly visible,
## already staring. Rate-limited hard so it never becomes predictable.
func _maybe_lookback_reveal(t: float, looks: int) -> void:
	if looks == _last_lookback:
		return
	_last_lookback = looks
	if _mode != "idle" or t < 120.0 or _lookback_cd > 0.0 or _ended:
		return
	if _mp and (not _mp_host or _net_fig_active):
		return  # co-op: the host's schedule owns the entity
	if _rng.randf() > 0.3:
		return
	var eye: Vector3 = _camera.global_position
	var fwd: Vector3 = -_camera.global_transform.basis.z
	fwd.y = 0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()
	for _i in range(6):
		var dist := _rng.randf_range(8.0, 13.0)
		var dir := fwd.rotated(Vector3.UP, _rng.randf_range(-0.35, 0.35))
		var p: Vector3 = _player.global_position + dir * dist
		p.y = 0.0
		if not _ray_clear(eye, p + Vector3(0, 1.6, 0)):
			continue
		_spawn_figure(p, true)
		if _figure == null:
			return
		_face_player(_figure)
		_play_anim("ual1_Idle")
		_peek_corner = false
		_peek_style = "stare"
		_stare_timer = -1.0
		_peek_witnessed = true
		_mode = "peek"
		_peek_recede = false
		_peek_timer = _rng.randf_range(2.5, 4.0)
		_lookback_cd = _rng.randf_range(50.0, 100.0)
		_add_stress(0.2)
		return

## False-security window: the seconds before a scheduled jumpscare go quiet —
## fewer sounds, lower dread — so the scare lands out of calm, not chaos.
func _in_pre_jump_calm(t: float) -> bool:
	return _next_jump < 900.0 and t > _next_jump - Tuning.PRE_JUMP_CALM_WINDOW and t < _next_jump and _mode == "idle"

func _update_dread(t: float, looks: int, delta: float) -> void:
	# Base dread rises slowly over ~12 min, plus the player's own fear (look-backs).
	var base := clampf(t / 720.0, 0.0, 0.75)
	var fear := clampf(float(looks) * 0.02, 0.0, 0.25)
	var target := clampf(base + fear + _menace * 0.15, 0.0, 1.0)
	var lerp_spd := 0.6
	if _mode == "chase":
		target = 1.0
		lerp_spd = 5.0
	elif _mode == "stalk":
		target = maxf(target, 0.7)
	elif _mode == "shadow":
		target = maxf(target, 0.4)   # subliminal: something feels wrong
	elif _in_pre_jump_calm(t):
		target *= 0.45
	if _prox_muffle:
		target = minf(1.0, target + 0.25)
	_dread = lerpf(_dread, target, delta * lerp_spd)
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
	# Co-op: only the host schedules, and never while a teammate's scare runs.
	if _mp and (not _mp_host or _net_fig_active):
		return
	# menace raises the chase cap too (2 → 5 with every tin in hand)
	if t >= _next_chase and _chase_done < Tuning.CHASE_MAX_PER_RUN + int(round(_menace * 3.0)):
		if _dispatch("chase"):
			_chase_done += 1
			_next_chase = t + _rng.randf_range(60.0, 140.0) * lerpf(1.0, 0.55, _menace)
		else:
			_begin_chase()
		return
	if t >= _next_jump and _can_jump(t):
		if _dispatch("jump"):
			_last_jump_time = t
			_jump_count += 1
			_next_jump = t + _rng.randf_range(150.0, 260.0)
		else:
			_begin_jump(t)
		return
	if t >= _next_shadow:
		if _dispatch("shadow"):
			_next_shadow = t + _rng.randf_range(Tuning.SHADOW_GAP_MIN, Tuning.SHADOW_GAP_MAX)
		else:
			_begin_shadow()
		return
	if t >= _next_peek:
		if _dispatch("peek"):
			_next_peek = t + _rng.randf_range(Tuning.PEEK_GAP_EARLY * 0.5, Tuning.PEEK_GAP_EARLY)
		else:
			_begin_peek()
		return

## Co-op direction: pick a living player; if it isn't us, hand the scare to
## their client (their camera does the validation) and mirror what follows.
## Returns true when delegated — the local director stays idle.
func _dispatch(kind: String) -> bool:
	if not _mp or not _mp_host or _world == null or not _world.has_method("alive_player_ids"):
		return false
	if not has_node("/root/NetManager"):
		return false
	
	if kind == "jump":
		_world.net_send("scare_all", {"kind": "jump"})
		_begin_jump(_now())
		return true
		
	var ids: Array = _world.alive_player_ids()
	if ids.is_empty():
		return false
	var target: int = int(ids[_rng.randi() % ids.size()])
	if target == NetManager.local_player_id:
		return false
	_world.net_send("scare", {"kind": kind, "target": target})
	_net_fig_active = true   # held until their figoff arrives
	_net_fig_watchdog = 20.0
	return true

## A trapped phone answered — the entity takes the call. Player-initiated,
## so it bypasses the schedule but not the state machine.
func phone_jumpscare() -> void:
	if _ended or _mode != "idle":
		return
	_begin_jump(_now())

## A scare order from the host, realized with OUR camera and OUR maze rays.
func remote_scare(kind: String) -> void:
	if _ended or _mode != "idle":
		return
	match kind:
		"chase":
			_begin_chase()
		"jump":
			_begin_jump(_now())
		"shadow":
			_begin_shadow()
		_:
			_begin_peek()

func _can_jump(t: float) -> bool:
	# menace raises the per-run cap (3 → 5) and shrinks the mandatory gap
	if _jump_count >= Tuning.JUMP_MAX_PER_RUN + int(round(_menace * 2.0)):
		return false
	if t - _last_jump_time < Tuning.JUMP_MIN_GAP * lerpf(1.0, 0.6, _menace):
		return false
	return true

# ---------------------------------------------------------------------------
# PEEK — silhouette at a distant corner, recedes when looked at
# ---------------------------------------------------------------------------
func _begin_peek() -> void:
	# Preferred: a REAL corner — spawn hidden behind a wall end, lean out.
	var corner := _find_peek_corner()
	if not corner.is_empty():
		_spawn_figure(corner["hide"], false)
		if _figure:
			_face_player(_figure)
			_play_anim("ual1_Idle")
			_set_figure_alpha(0.0)  # Start invisible — only the head peek reveals it
		_peek_corner = true
		_peek_from = corner["hide"]
		_peek_to = corner["out"]
		_lean = 0.0
		_lean_dir = 1.0
		_mode = "peek"
		_peek_recede = false
		_peek_witnessed = false
		_peek_loop_count = 0
		_peek_wait_timer = 0.0
		_stare_timer = -1.0
		# most watchers hold your gaze a beat before slipping away;
		# some are gone the instant your eyes land on them
		_peek_style = "skittish" if _rng.randf() < 0.25 else "stare"
		_peek_timer = _rng.randf_range(6.0, 11.0)
		_wire_peek_skeleton()
		return
	# Fallback: open spot near a wall (no free corner in range right now).
	var spot := _find_peek_spot()
	if spot.is_empty():
		var t := 0.0
		if has_node("/root/GameManager"):
			t = GameManager.run_time
		_next_peek = t + 2.0  # retry very soon (2.0s) instead of waiting full gap!
		return
	_spawn_figure(spot["hide"], false)
	if _figure:
		_face_player(_figure)
		_play_anim("ual1_Idle")
		_set_figure_alpha(0.0)  # Start invisible
	_peek_corner = true
	_peek_from = spot["hide"]
	_peek_to = spot["out"]
	_lean = 0.0
	_lean_dir = 1.0
	_mode = "peek"
	_peek_recede = false
	_peek_witnessed = false
	_peek_loop_count = 0
	_peek_wait_timer = 0.0
	_stare_timer = -1.0
	_peek_style = "skittish" if _rng.randf() < 0.25 else "stare"
	_peek_timer = _rng.randf_range(6.0, 11.0)
	_wire_peek_skeleton()

## Pick a wall-end corner where cover geometry really works from the player's
## point of view: leaning out is visible, hiding is not.
func _find_peek_corner() -> Dictionary:
	if _maze == null or not _maze.has_method("peek_corners"):
		return {}
	var eye: Vector3 = _camera.global_position
	var cands: Array = _maze.peek_corners(_player.global_position, Tuning.PEEK_DIST_MIN, Tuning.PEEK_DIST_MAX)
	cands.shuffle()
	for cand in cands:
		var out_head: Vector3 = cand["out"] + Vector3(0, 1.6, 0)
		var hide_head: Vector3 = cand["hide"] + Vector3(0, 1.6, 0)
		if not _ray_clear(eye, out_head):
			continue  # leaning out must actually reveal it
		if _ray_clear(eye, hide_head):
			continue  # the cover must actually cover it
		return cand
	return {}

func _dread_scaled_peek_gap() -> float:
	var t := 0.0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
	return t + 1.0

func _tick_peek(delta: float) -> void:
	if not is_instance_valid(_figure):
		_end_apparition()
		return
	_peek_timer -= delta

	var flat := _figure.global_position - _player.global_position
	flat.y = 0.0
	
	# If player gets too close to the cover (5.5m), vanish instantly!
	var too_close := flat.length() < 5.5
	if too_close:
		_end_apparition()
		return

	# Handle Peek-a-boo wait state (invisible behind cover)
	if _peek_wait_timer > 0.0:
		_peek_wait_timer -= delta
		_figure.global_position = _peek_from
		_set_figure_alpha(0.0)
		
		if _peek_wait_timer <= 0.0:
			_lean_dir = 1.0
		return

	# NEVER seen up close: gone before the player can reach it.
	if flat.length() < Tuning.PEEK_VANISH_DIST:
		_end_apparition()
		return

	var looked := _player_looking_at(_figure, 0.40) or _in_view(_figure)
	var visible_now := _in_view(_figure) and _has_los(_figure)
	if visible_now:
		_peek_witnessed = true

	# Near but unseen → muffle
	var prox := flat.length() < Tuning.PEEK_MUFFLE_DIST and not visible_now
	if prox != _prox_muffle:
		_prox_muffle = prox
		muffle.emit(prox)

	# Monster this close makes the electrics sick: violent-ish panel flicker
	# + buzzing whenever it lurks within 12 m (peeking or hidden).
	if flat.length() < 12.0:
		request_flicker.emit(0.35)
		_proximity_buzz(delta)
	else:
		request_flicker.emit(0.0)

	# Trigger recede as soon as player looks or sees the entity!
	if (visible_now or looked) and not _peek_recede:
		if _stare_timer < 0.0:
			_stare_timer = 0.12  # quick eye-contact reaction duration
			_add_stress(0.12)
			_peek_reaction_sound(flat.length())
			if has_node("/root/AudioManager"):
				AudioManager.set_heartbeat_state("peek")
		if _stare_timer > 0.0:
			_stare_timer = maxf(0.0, _stare_timer - delta)
		if _stare_timer <= 0.0:
			_peek_recede = true
			_lean_dir = -1.0

	if _peek_corner:
		if not _peek_recede:
			# leans out slowly (0.5s)
			_lean = clampf(_lean + _lean_dir * delta / 0.5, 0.0, 1.0)
			_figure.global_position = _peek_from.lerp(_peek_to, _lean * 0.75)
			_face_player(_figure)
			_set_figure_alpha(clampf(_lean * 2.0, 0.0, 1.0))
		
		# Auto-recede after 2.0 seconds if player doesn't look
		if _peek_timer <= 0.0 and not _peek_recede:
			_peek_recede = true
			_lean_dir = -1.0

	if _peek_recede:
		if _peek_corner:
			_lean_dir = -1.0
			# Smooth stealthy duck back behind wall (0.35s sweet spot)
			_lean = clampf(_lean + _lean_dir * delta / 0.35, 0.0, 1.0)
			_figure.global_position = _peek_from.lerp(_peek_to, _lean * 0.75)
			_face_player(_figure)
			# Stay visible while pulling back behind cover, then fade out
			var alpha_val := 1.0 if _lean > 0.1 else 0.0
			_set_figure_alpha(alpha_val)
			
			if _lean <= 0.0:
				_end_apparition()
				return
		else:
			# Sprint backward very fast and fade
			var away: Vector3 = (_figure.global_position - _player.global_position)
			away.y = 0
			if away.length() > 0.01:
				away = away.normalized()
				_figure.global_position += away * 15.0 * delta
				_play_anim("ual1_Sprint")
			_fade_figure(delta, 8.0)
			if not visible_now or _figure_alpha() <= 0.02:
				_end_apparition()
				return
	else:
		_face_player(_figure)

	if _peek_timer <= 0.0 and not _peek_corner:
		_end_apparition()
	# (bone poses are applied via skeleton_updated — post-animation — not here)

## A breath you can localize: it comes from where the thing stands.
func _stare_breath(dist: float) -> void:
	if dist > 14.0 or not has_node("/root/AudioManager") or not _sfx.has("breath"):
		return
	if is_instance_valid(_figure):
		AudioManager.play_sfx_3d(self, _sfx["breath"], _figure.global_position + Vector3(0, 1.5, 0), -4.0, 26.0, _rng.randf_range(0.92, 1.02))

# 10-sound peek reaction pool (whispers/groans from the juanjo pack) — a
# different voice with drifting pitch on every eye contact, never the same twice.
const PEEK_SOUND_POOL := [1, 3, 5, 10, 11, 13, 15, 17, 21, 25]
var _peek_pool_streams: Array = []
var _buzz_cd := 0.0

func _peek_reaction_sound(dist: float) -> void:
	if dist > 15.0 or not has_node("/root/AudioManager"):
		return
	if _peek_pool_streams.is_empty():
		for idx in PEEK_SOUND_POOL:
			var p := "res://assets/audio/juanjo/juanjo_sound - Backrooms Entity %d.wav" % idx
			if ResourceLoader.exists(p):
				_peek_pool_streams.append(load(p))
	if _peek_pool_streams.is_empty() or not is_instance_valid(_figure):
		return
	var stream: AudioStream = _peek_pool_streams[_rng.randi() % _peek_pool_streams.size()]
	AudioManager.play_sfx_3d(self, stream, _figure.global_position + Vector3(0, 1.6, 0), -5.0, 26.0, _rng.randf_range(0.85, 1.15))

## Electrical buzz whenever the thing lurks close — the fixtures feel it too.
func _proximity_buzz(delta: float) -> void:
	_buzz_cd -= delta
	if _buzz_cd > 0.0 or not has_node("/root/AudioManager") or not _sfx.has("flicker"):
		return
	_buzz_cd = _rng.randf_range(3.5, 6.5)
	if is_instance_valid(_figure):
		AudioManager.play_sfx_3d(self, _sfx["flicker"], _figure.global_position + Vector3(0, 2.6, 0), -8.0, 20.0, _rng.randf_range(0.95, 1.1))

func _find_peek_spot() -> Dictionary:
	# A valid peek spot must be (a) currently OFF-screen, so it "appears" when
	# the player turns, and (b) on a clear sightline from the player's eye —
	# otherwise it spawns behind maze walls and is never seen at all.
	var eye: Vector3 = _camera.global_position
	# Try up to 150 times to find a perfect peeking corner/wall spot
	for _i in range(150):
		var ang := _rng.randf() * TAU
		var dist := _rng.randf_range(Tuning.PEEK_DIST_MIN, Tuning.PEEK_DIST_MAX)
		var p: Vector3 = _player.global_position + Vector3(cos(ang), 0, sin(ang)) * dist
		p.y = 0.0
		var head := p + Vector3(0, 1.6, 0)
		if _in_view_point(head):
			continue
		
		# Wall check: find a wall near the candidate position
		var wall_dir := Vector3.ZERO
		for dir in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
			var hit := _ray_hit(head, head + dir * 1.5)
			if not hit.is_empty():
				wall_dir = dir
				break
				
		if wall_dir == Vector3.ZERO:
			continue
			
		# Construct hide and out positions along the wall direction
		var hide_pos := p + wall_dir * 0.7
		var out_pos := p - wall_dir * 0.4
		
		# Verify sightlines: leaning out must be visible, hiding must be covered
		if not _ray_clear(eye, out_pos + Vector3(0, 1.6, 0)):
			continue
		if _ray_clear(eye, hide_pos + Vector3(0, 1.6, 0)):
			continue
			
		return {
			"hide": hide_pos,
			"out": out_pos
		}
	return {}

# ---------------------------------------------------------------------------
# SHADOW — the silent tail. It follows from wall cover, standing EXPOSED at a
# corner whenever the player isn't looking (free — they can't see it), so any
# time they whip around it is ALREADY there, watching. Their gaze lands: it
# holds half a second — long enough to be seen looking — then slips behind
# the wall. No footsteps, no hum change. Silence IS the tell.
# ---------------------------------------------------------------------------
func _begin_shadow() -> void:
	var spot := _find_shadow_corner(true)
	if spot.is_empty():
		_next_shadow = _now() + _rng.randf_range(20.0, 40.0)
		return
	_spawn_figure(spot["out"], false)
	if _figure == null:
		_next_shadow = _now() + _rng.randf_range(20.0, 40.0)
		return
	_face_player(_figure)
	_play_anim("ual1_Idle")
	_peek_from = spot["hide"]
	_peek_to = spot["out"]
	_lean = 1.0
	_mode = "shadow"
	_shadow_state = "watch"
	_shadow_hold = 0.0
	_shadow_timer = 0.0
	_shadow_reveals = 0
	_shadow_max_reveals = _rng.randi_range(2, 4)

func _tick_shadow(delta: float) -> void:
	if not is_instance_valid(_figure):
		_end_apparition()
		return
	_shadow_timer += delta
	var flat := _figure.global_position - _player.global_position
	flat.y = 0.0
	var dist := flat.length()
	if dist < Tuning.PEEK_VANISH_DIST:
		_end_apparition()   # hunted down — nothing there
		return
	if _shadow_timer > Tuning.SHADOW_MAX_TIME:
		_end_apparition()   # it never outstays; absence is also dread
		return
	# the fixtures feel it too — flicker + buzz while it tails within 12 m
	if dist < 12.0:
		request_flicker.emit(0.3)
		_proximity_buzz(delta)
	else:
		request_flicker.emit(0.0)
	match _shadow_state:
		"watch":
			# exposed at the corner, motionless, eyes on your back
			_face_player(_figure)
			if _in_view(_figure) and _has_los(_figure):
				_shadow_state = "hold"
				_shadow_hold = Tuning.SHADOW_REVEAL_HOLD
				_shadow_reveals += 1
				_add_stress(0.08)
			elif dist > 16.0:
				_relocate_shadow()   # keep the tail close while unseen
		"hold":
			# your eyes found it. It lets you KNOW you were being watched…
			_face_player(_figure)
			_shadow_hold -= delta
			if _shadow_hold <= 0.0:
				_shadow_state = "hiding"
		"hiding":
			# …then slips behind the wall, quick as a caught thief.
			_lean = maxf(0.0, _lean - delta / 0.22)
			var k := _lean * _lean * (3.0 - 2.0 * _lean)
			_figure.global_position = _peek_from.lerp(_peek_to, k)
			if _lean <= 0.0:
				if _shadow_reveals >= _shadow_max_reveals:
					_end_apparition()   # this time it does not come back
					return
				_shadow_state = "hidden"
				_shadow_wait = 0.6
		"hidden":
			# behind cover, waiting for your gaze to move off the corner
			var out_head := _peek_to + Vector3(0, 1.6, 0)
			if _in_view_point(out_head) and _ray_clear(_camera.global_position, out_head):
				_shadow_wait = 0.6   # corner still being watched — stay put
			else:
				_shadow_wait -= delta
				if _shadow_wait <= 0.0:
					_relocate_shadow()

## Slide the tail (while nothing is watching) to a fresh corner near the
## player. Relocation only ever happens fully unseen.
func _relocate_shadow() -> void:
	var spot := _find_shadow_corner(false)
	if spot.is_empty():
		return  # no safe corner right now — hold this one
	_peek_from = spot["hide"]
	_peek_to = spot["out"]
	_lean = 1.0
	_figure.global_position = spot["out"]
	_face_player(_figure)
	_shadow_state = "watch"

## A tail corner must be: unseen RIGHT NOW (it appears there invisibly),
## seeable when the player turns (clear ray, outside the current frustum),
## and genuinely covered on its hide side. Prefers the player's back.
func _find_shadow_corner(prefer_behind: bool) -> Dictionary:
	if _maze == null or not _maze.has_method("peek_corners"):
		return {}
	var eye: Vector3 = _camera.global_position
	var fwd: Vector3 = -_camera.global_transform.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)
	var cands: Array = _maze.peek_corners(_player.global_position, 6.0, 14.0)
	cands.shuffle()
	var fallback := {}
	for cand in cands:
		var out_head: Vector3 = cand["out"] + Vector3(0, 1.6, 0)
		var hide_head: Vector3 = cand["hide"] + Vector3(0, 1.6, 0)
		if _in_view_point(out_head) and _ray_clear(eye, out_head):
			continue  # inside the current view — appearing would be witnessed
		if not _ray_clear(eye, out_head):
			continue  # can never be seen from where the player stands
		if _ray_clear(eye, hide_head):
			continue  # the cover does not cover
		var to_c: Vector3 = cand["out"] - _player.global_position
		to_c.y = 0
		if prefer_behind and to_c.length() > 0.01 and to_c.normalized().dot(fwd) > 0.15:
			if fallback.is_empty():
				fallback = cand
			continue
		return cand
	return fallback

# ---------------------------------------------------------------------------
# JUMP — dry, < 1s, very close, then gone. No death.
# ---------------------------------------------------------------------------
func _begin_jump(t: float) -> void:
	# The face fills the screen: figure almost touching the camera + a hard
	# FOV zoom punch, gone in half a second. Ray-checked so it never clips.
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)
	var fwd: Vector3 = -_camera.global_transform.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)
	var eye: Vector3 = _camera.global_position
	# 2.5 m out: the player sees the WHOLE towering silhouette — head, torso,
	# arms, legs — not a faceful of chest. Ray-checked so it never clips.
	var want := 2.5
	var hit := _ray_hit(eye, eye + fwd * (want + 0.35))
	if not hit.is_empty():
		want = maxf(0.9, eye.distance_to(hit["position"]) - 0.3)
	var pos: Vector3 = _player.global_position + fwd * want
	pos.y = 0.0
	_spawn_figure(pos, true)
	if _figure:
		_face_player(_figure)
		_set_figure_alpha(1.0)
		_play_anim("ual1_Idle")
		# creep even closer during the flash
		var tw := create_tween()
		tw.tween_property(_figure, "global_position", pos + fwd * 0.3, Tuning.JUMP_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# mild zoom punch — frames the full body instead of tunneling into it
	if is_instance_valid(_camera):
		_jump_prev_fov = _camera.fov
		_camera.fov = 62.0
	_mode = "jump"
	jumpscare.emit()
	request_flicker.emit(1.0)
	_add_stress(0.5)
	if has_node("/root/AudioManager") and _sfx.has("jump"):
		# never the exact same scream twice — pitch drift keeps it raw
		AudioManager.play_sfx(_sfx["jump"], 0.0, _rng.randf_range(0.92, 1.06))
	_last_jump_time = t
	_jump_count += 1
	# yank it away fast, then a forced calm — nothing may interrupt
	get_tree().create_timer(Tuning.JUMP_DURATION).timeout.connect(func():
		if is_instance_valid(self):
			if is_instance_valid(_camera):
				_camera.fov = _jump_prev_fov
			_end_apparition()
			request_flicker.emit(0.0)
			_next_peek = t + _rng.randf_range(Tuning.JUMP_CALM_MIN, Tuning.JUMP_CALM_MAX)
			_next_jump = t + _rng.randf_range(150.0, 260.0) * lerpf(1.0, 0.6, _menace)
			_next_chase = maxf(_next_chase, t + 60.0))

# ---------------------------------------------------------------------------
# CHASE — runs at the player; lose LOS for 2s and it's gone
# ---------------------------------------------------------------------------
func _begin_chase() -> void:
	# THE WINDUP: horror is anticipation. Before anything charges, the world
	# turns wrong — lights gutter, the hum drops underwater, and a howl rolls
	# in FROM THE DIRECTION it will come from. ~2 seconds of "oh no". Then it
	# comes.
	var spot := _find_chase_spawn()
	if spot == Vector3.INF:
		_next_chase = (0.0 if not has_node("/root/GameManager") else GameManager.run_time) + _rng.randf_range(8.0, 20.0)
		return
	_mode = "chase"
	_chase_state = "windup"
	_windup_timer = 2.2
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("chase")
	_windup_spot = spot
	_chase_time = 0.0
	_los_lost = 0.0
	_chase_path = []
	_path_timer = 0.0
	_path_fail = 0.0
	_chase_done += 1
	chase_started.emit()
	var ov_start := _get_overlay()
	if is_instance_valid(ov_start) and ov_start.has_method("set_chase_vignette"):
		ov_start.set_chase_vignette(true)
	if not _prox_muffle:
		_prox_muffle = true
		muffle.emit(true)          # the hum sinks — something is coming
	request_flicker.emit(0.55)
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		# the howl arrives from the spawn direction, far and getting ready
		AudioManager.play_sfx_3d(self, _sfx["chase_scream"], spot + Vector3(0, 1.5, 0), -6.0, 45.0, 0.9)

func _launch_chase() -> void:
	# Windup over: drop the muffle, spawn it (re-validated), full charge.
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)
	var spot := _windup_spot
	var head := spot + Vector3(0, 1.5, 0)
	if _in_view_point(head) and _ray_clear(_camera.global_position, head):
		# player turned toward the old spot — try once for a fresh unseen one
		var fresh := _find_chase_spawn()
		if fresh != Vector3.INF:
			spot = fresh
	_spawn_figure(spot, false)
	if not _figure:
		_end_chase(false)
		return
	_set_figure_alpha(1.0)
	_face_player(_figure)
	_play_anim("ual1_Sprint")
	_chase_state = "pursue"
	_last_seen_pos = _player.global_position
	_has_seen_player_this_chase = false
	_stumble_timer = _rng.randf_range(1.5, 2.5)
	_stumble_duration = 0.0
	_chase_speed_mult = 1.0
	request_flicker.emit(1.0)
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		AudioManager.play_sfx(_sfx["chase_scream"], -2.0)
	# Looping positional layers ride on the figure: distance IS the mix.
	_chase_steps = _attach_loop(_figure, _sfx.get("heavy_steps"), -4.0)
	_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)

func _find_chase_spawn() -> Vector3:
	# NEVER materialize in plain sight — that reads as a cheap teleport. The
	# spot must be off-screen or occluded AND have a real corridor route to
	# the player, so the entity charges INTO view: heard first, then seen.
	var eye: Vector3 = _camera.global_position
	var pcell: Vector2i = _cell_of(_player.global_position)
	for _i in range(24):
		var ang := _rng.randf() * TAU
		var dist := _rng.randf_range(9.0, 14.0)
		var p: Vector3 = _player.global_position + Vector3(cos(ang), 0, sin(ang)) * dist
		p.y = 0.0
		var head := p + Vector3(0, 1.5, 0)
		if _in_view_point(head) and _ray_clear(eye, head):
			continue  # the player would watch it pop into existence
		if _maze and _maze.has_method("corridor_path"):
			var route: Array = _maze.corridor_path(_cell_of(p), pcell)
			if route.size() < 2 or route.size() > 10:
				continue  # unreachable pocket, or too far through the maze
		return p
	return Vector3.INF  # caller reschedules a new attempt shortly

func _get_overlay() -> Node:
	if _world != null and "_overlay" in _world and is_instance_valid(_world._overlay):
		return _world._overlay
	var tree := get_tree()
	if tree != null and tree.root != null:
		return tree.root.find_child("Overlay", true, false)
	return null

func _breathing_gives_away(d: float) -> bool:
	if not is_instance_valid(_player):
		return false
	var hiding: bool = bool(_player.get_meta("is_hiding", false)) if _player.has_meta("is_hiding") else false
	if not hiding or d > 5.0:
		return false
	# Holding breath (Space / RMB) suppresses nervous breathing alert!
	var holding: bool = bool(_player.is_holding_breath) if "is_holding_breath" in _player else false
	return not holding

func _tick_chase(delta: float) -> void:
	# --- phase: windup (no figure yet, the world just turned hostile) ---
	if _chase_state == "windup":
		_windup_timer -= delta
		request_flicker.emit(0.55)
		if _windup_timer <= 0.0:
			_launch_chase()
		return
	if not is_instance_valid(_figure):
		_end_chase(false)
		return
	_chase_time += delta
	var to: Vector3 = _player.global_position - _figure.global_position
	to.y = 0
	var d := to.length()
	if d <= CATCH_DIST:
		_do_caught()
		return

	# Dynamic claustrophobic FOV tunnel vision during chase
	if is_instance_valid(_camera):
		_camera.fov = lerpf(_camera.fov, 58.0, 4.0 * delta)

	# does IT see YOU? (entity-eye ray, not the camera) — feeds its memory
	_fig_sees = _ray_clear(_figure.global_position + Vector3(0, 1.6, 0), _camera.global_position)
	# Crouching stealth: a low, small target is much harder to track at range —
	# beyond 7 m a crouched player slips out of its perception entirely.
	var crouched: bool = bool(_player.is_crouching) if is_instance_valid(_player) and "is_crouching" in _player else false
	if _fig_sees and crouched and d > 7.0:
		_fig_sees = false
	# Locker mechanic: a hidden player is invisible (the door blocks the ray) —
	# but nervous breathing within 5 m gives them away unless they HOLD it.
	if _breathing_gives_away(d):
		_fig_sees = true
	if _fig_sees:
		_last_seen_pos = _player.global_position
		_has_seen_player_this_chase = true
	else:
		# If the entity has already seen the player but loses line of sight (e.g. player crosses a corner),
		# it instantly disappears!
		if _has_seen_player_this_chase:
			_end_chase(true)
			return

	# --- phase: search (it lost you; it stands where you were, listening) ---
	if _chase_state == "search":
		_search_timer -= delta
		request_flicker.emit(0.4)
		if _fig_sees and d < 14.0:
			# found you again — the sting, the steps, the sprint
			_chase_state = "pursue"
			_play_anim("ual1_Sprint")
			if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
				AudioManager.play_sfx(_sfx["chase_scream"], -3.0, 1.05)
			_chase_steps = _attach_loop(_figure, _sfx.get("heavy_steps"), -4.0)
			_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)
			_add_stress(0.15)
		elif _search_timer <= 0.0:
			_end_chase(true)   # gives up — instant dissolve, dead air
		return

	# --- phase: pursue ---
	# Handle stumbling/lunging states
	if _stumble_duration > 0.0:
		_stumble_duration -= delta
		_chase_speed_mult = 0.20  # slow down significantly as it stumbles
		
		# Tilt torso forward and dip down
		if _figure.get_child_count() > 0:
			var model_node = _figure.get_child(0)
			model_node.rotation.x = lerpf(model_node.rotation.x, 0.58, 12.0 * delta)
			model_node.position.y = lerpf(model_node.position.y, -0.42, 12.0 * delta)
		
		if _stumble_duration <= 0.0:
			_stumble_timer = _rng.randf_range(2.1, 3.3)
	else:
		_stumble_timer -= delta
		
		# Restore upright pose
		if _figure.get_child_count() > 0:
			var model_node = _figure.get_child(0)
			model_node.rotation.x = lerpf(model_node.rotation.x, 0.0, 10.0 * delta)
			model_node.position.y = lerpf(model_node.position.y, 0.0, 10.0 * delta)
		
		# Lunge speed boost for 0.8 seconds after a stumble!
		if _stumble_timer > 1.3 and _stumble_timer < 2.1:
			_chase_speed_mult = 1.32  # sprint burst lunge!
		else:
			_chase_speed_mult = 1.0
			
		if _stumble_timer <= 0.0:
			_stumble_duration = 0.45
			# Horrifying random screech from the juanjo sound folder
			if has_node("/root/AudioManager"):
				var idx := _rng.randi_range(2, 9) # pick screaming files
				var s_stream = load("res://assets/audio/juanjo/juanjo_sound - Backrooms Entity %d.wav" % idx)
				if s_stream:
					AudioManager.play_sfx_3d(self, s_stream, _figure.global_position, 6.0, 25.0, _rng.randf_range(0.9, 1.15))

	_chase_move(delta, d)
	_apply_chase_contortions(delta)

	# the scream layer swells as it closes in; steps quicken
	var closeness := clampf(1.0 - (d - CATCH_DIST) / 14.0, 0.0, 1.0)
	if is_instance_valid(_chase_scream):
		_chase_scream.volume_db = lerpf(-20.0, -4.0, closeness)
	if is_instance_valid(_chase_steps):
		_chase_steps.pitch_scale = lerpf(1.0, 1.18, closeness)
	# breath on your neck when it is almost on you
	if d < 4.0 and _close_breath_cd <= 0.0 and _sfx.has("breath") and has_node("/root/AudioManager"):
		_close_breath_cd = 3.0
		AudioManager.play_sfx_3d(self, _sfx["breath"], _figure.global_position + Vector3(0, 1.6, 0), -2.0, 20.0, 1.05)

	# Apply dynamic camera shake — and a violent adrenaline burst inside 2.5 m
	if is_instance_valid(_player) and "shake_intensity" in _player:
		var shake := closeness * 0.22
		if d < 2.5:
			shake = 0.85
		_player.shake_intensity = maxf(_player.shake_intensity, shake)

	# Memory model: while it can't see you, it runs to where it LAST saw you.
	# Reaching that spot without re-acquiring = it stops and searches (steps go
	# silent — the scariest sound in the game is them stopping).
	if not _fig_sees:
		var to_mem := _last_seen_pos - _figure.global_position
		to_mem.y = 0
		if to_mem.length() < 0.8:
			_chase_state = "search"
			_search_timer = _rng.randf_range(1.1, 1.6)
			_play_anim("ual1_Idle")
			_stop_chase_loops()   # sudden silence
			return

	# player-side rule stays absolute: sight broken long enough = it never was
	var seen := _in_view(_figure) and _has_los(_figure)
	if seen:
		_los_lost = 0.0
	else:
		_los_lost += delta
		if _los_lost >= LOS_LOSE_TIME + 2.0:   # memory buys it a little time
			_end_chase(true)
			return
	request_flicker.emit(1.0)

func _stop_chase_loops() -> void:
	if is_instance_valid(_chase_steps):
		_chase_steps.queue_free()
	if is_instance_valid(_chase_scream):
		_chase_scream.queue_free()
	_chase_steps = null
	_chase_scream = null

## Corridor-bound pursuit: follow BFS waypoints through the maze so the figure
## never phases through walls — cornering well is how the player escapes. It
## hunts what it KNOWS (last seen position), not the player's true location.
func _chase_move(delta: float, dist_to_player: float) -> void:
	var goal: Vector3 = _player.global_position if _fig_sees else _last_seen_pos
	_path_timer -= delta
	if _path_timer <= 0.0 and _maze and _maze.has_method("corridor_path"):
		_path_timer = Tuning.CHASE_PATH_REFRESH
		var from_cell: Vector2i = _cell_of(_figure.global_position)
		var to_cell: Vector2i = _cell_of(goal)
		_chase_path = _maze.corridor_path(from_cell, to_cell)
	var target: Vector3 = goal
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
		# same cell as the goal: go straight in
		_path_fail = 0.0
		target = goal
	else:
		# no route (sealed pocket): give it a few seconds, then let it dissolve
		_path_fail += delta
		if _path_fail > Tuning.CHASE_NO_ROUTE_TIMEOUT:
			_end_chase(true)
			return
	# Speed has moods: a burst from afar, a fraction of mercy up close (the
	# almost-caught margin players remember), and mounting urgency over time.
	var speed := CHASE_SPEED * _chase_speed_mult
	if dist_to_player > 8.0:
		speed *= 1.1
	elif dist_to_player < 3.0:
		speed *= 0.93
	speed += minf(_chase_time * 0.01, 0.15)
	var step_dir: Vector3 = target - _figure.global_position
	step_dir.y = 0
	if step_dir.length() > 0.01:
		_figure.global_position += step_dir.normalized() * speed * delta
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
	_chase_state = "pursue"
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)
	_remove_figure()   # audio players are children of the figure → instant cut
	_mode = "idle"
	_roam_cooldown = _rng.randf_range(20.0, 35.0) * lerpf(1.0, 0.6, _menace)
	chase_ended.emit()
	request_flicker.emit(0.0)
	var ov_end := _get_overlay()
	if is_instance_valid(ov_end) and ov_end.has_method("set_chase_vignette"):
		ov_end.set_chase_vignette(false)
	if is_instance_valid(_camera):
		_camera.fov = 72.0
	_add_stress(0.55)
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("silent")
	var t := 0.0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
	# the director backs off after intensity (stress) but the tins in the
	# players' pockets keep dragging the next hunt closer (menace)
	_next_chase = t + _rng.randf_range(60.0, 140.0) * (1.0 + _stress) * lerpf(1.0, 0.55, _menace)
	_next_peek = maxf(_next_peek, t + 20.0)

func _do_caught() -> void:
	if _ended:
		return
	if is_instance_valid(_player) and _player.has_meta("is_hiding") and _player.get_meta("is_hiding"):
		return
	_ended = true
	request_flicker.emit(0.0)
	request_dread.emit(1.0)
	# The last thing you see: its face, one breath from yours — THEN black.
	if is_instance_valid(_figure) and is_instance_valid(_camera):
		var fwd: Vector3 = -_camera.global_transform.basis.z
		fwd.y = 0
		if fwd.length() > 0.01:
			fwd = fwd.normalized()
			var pos: Vector3 = _player.global_position + fwd * 0.7
			pos.y = 0.0
			_figure.global_position = pos
			_face_player(_figure)
		_camera.fov = 46.0
	if has_node("/root/AudioManager") and _sfx.has("jump"):
		AudioManager.play_sfx(_sfx["jump"], 6.0, 0.92)
	get_tree().create_timer(0.28).timeout.connect(func():
		if is_instance_valid(self):
			caught.emit())

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
	
	var looked := _player_looking_at(_figure, 0.26)
	if looked:
		# Freeze like a statue when looked at directly!
		_play_anim("ual1_Idle")
		_face_player(_figure)
		# Screen distortion and heavy dread!
		request_dread.emit(0.8)
		request_flicker.emit(0.4)
		# Rare whispering while looking at it
		if randf() < 0.008 and has_node("/root/AudioManager") and _sfx.has("breath"):
			AudioManager.play_sfx_3d(self, _sfx["breath"], _figure.global_position, -2.0, 20.0, randf_range(0.85, 0.95))
	else:
		# Sneak/move fast when player is not looking!
		request_dread.emit(0.2)
		request_flicker.emit(0.0)
		if d > 2.2 and d > 0.01:
			var creep_speed := 2.45
			if is_instance_valid(_player) and "is_crouching" in _player and _player.is_crouching:
				creep_speed = 1.1  # creep much slower when player is crouching!
			_figure.global_position += to.normalized() * creep_speed * delta
			_face_player(_figure)
			_play_anim("ual1_Walk")
		else:
			_play_anim("ual1_Idle")

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
	# a step behind, lights out — same face-first cinematic as the chase catch
	if has_node("/root/AudioManager") and _sfx.has("heavy_steps"):
		AudioManager.play_sfx(_sfx["heavy_steps"], 0.0)
	_do_caught()

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
	ModelUtils.setup_character_for_movement(model, 2.85)   # towers unnaturally, near the ceiling
	mesh_root.global_position = pos
	# darken to a pure silhouette
	_blacken(model)
	# animation
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	if _anim_lib:
		var lib = _anim_lib.duplicate(true) as AnimationLibrary
		for anim_name in lib.get_animation_list():
			var anim := lib.get_animation(anim_name)
			if anim != null:
				for track_idx in range(anim.get_track_count() - 1, -1, -1):
					var path_str := str(anim.track_get_path(track_idx))
					var is_arm_track := (":LeftUpperArm" in path_str or ":leftupperarm" in path_str or
						":RightUpperArm" in path_str or ":rightupperarm" in path_str or
						":LeftShoulder" in path_str or ":leftshoulder" in path_str or
						":RightShoulder" in path_str or ":rightshoulder" in path_str)
					var is_spine_track := (":Spine" in path_str or ":spine" in path_str or
						":Neck" in path_str or ":neck" in path_str)
					
					if is_spine_track or (is_arm_track and _mode == "chase"):
						anim.remove_track(track_idx)
		ap.add_animation_library("", lib)
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
	# A watcher nobody ever saw was wasted terror — retry sooner next time.
	if _mode == "peek":
		if _peek_witnessed:
			_unseen_streak = 0
		else:
			_unseen_streak = mini(_unseen_streak + 1, 3)
	elif _mode == "shadow":
		_next_shadow = _now() + _rng.randf_range(Tuning.SHADOW_GAP_MIN, Tuning.SHADOW_GAP_MAX) * (1.0 + _stress * 0.5) * lerpf(1.0, 0.55, _menace)
		if _shadow_reveals > 0:
			_add_stress(0.15)
	_remove_figure()
	_mode = "idle"
	_roam_cooldown = _rng.randf_range(20.0, 35.0) * lerpf(1.0, 0.6, _menace)
	_prox_muffle = false
	_peek_corner = false
	_lean = 0.0
	_lean_dir = 1.0
	_peek_loop_count = 0
	_peek_wait_timer = 0.0
	_stare_timer = -1.0
	muffle.emit(false)
	request_flicker.emit(0.0)   # proximity flicker dies with the apparition
	_next_peek = _dread_scaled_peek_gap()
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("silent")

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
# Co-op shared entity: whoever's client is realizing the current scare
# broadcasts the figure's truth at 10 Hz; every other client renders an
# identical mirror in the world (with the chase audio riding on it). The
# per-player STALK is deliberately not mirrored.
# ---------------------------------------------------------------------------
func _net_fig_tick(delta: float) -> void:
	if _world == null:
		return
	# a delegated scare that never materializes must not jam the director
	if _net_fig_active:
		_net_fig_watchdog -= delta
		if _net_fig_watchdog <= 0.0:
			mirror_off()
	var have := is_instance_valid(_figure) and _mode != "stalk" and _mode != "jump"
	if have:
		_owns_fig = true
		_fig_send_timer -= delta
		if _fig_send_timer <= 0.0:
			_fig_send_timer = 0.1
			_world.net_send("fig", {
				"m": _mode,
				"x": _figure.global_position.x,
				"z": _figure.global_position.z,
				"ry": _figure.rotation.y,
			})
	elif _owns_fig:
		_owns_fig = false
		_world.net_send("figoff", {})

func mirror_update(d: Dictionary) -> void:
	_net_fig_active = true
	_net_fig_watchdog = 10.0
	if _mirror == null or not is_instance_valid(_mirror):
		_spawn_mirror()
		if _mirror == null:
			return
	var p := Vector3(float(d.get("x", 0.0)), 0.0, float(d.get("z", 0.0)))
	if _mirror.get_meta("fresh", true):
		_mirror.global_position = p
		_mirror.set_meta("fresh", false)
	else:
		_mirror.global_position = _mirror.global_position.lerp(p, 0.35)
	_mirror.rotation.y = float(d.get("ry", 0.0))
	var m := str(d.get("m", "peek"))
	if m != _mirror_mode:
		_mirror_mode = m
		if _mirror_anim:
			var anim := "ual1_Sprint" if m == "chase" else "ual1_Idle"
			if _mirror_anim.has_animation(anim):
				_mirror_anim.play(anim)
		if m == "chase":
			_mirror_steps = _attach_loop(_mirror, _sfx.get("heavy_steps"), -6.0)
			_mirror_scream = _attach_loop(_mirror, _sfx.get("chase_scream"), -14.0)
		else:
			if is_instance_valid(_mirror_steps):
				_mirror_steps.queue_free()
			if is_instance_valid(_mirror_scream):
				_mirror_scream.queue_free()
			_mirror_steps = null
			_mirror_scream = null

func mirror_off() -> void:
	_net_fig_active = false
	_mirror_mode = ""
	_mirror_steps = null
	_mirror_scream = null
	if is_instance_valid(_mirror):
		_mirror.queue_free()
	_mirror = null
	_mirror_anim = null

func _spawn_mirror() -> void:
	if _watcher_scene == null:
		return
	var mesh_root := Node3D.new()
	add_child(mesh_root)
	var model: Node3D = _watcher_scene.instantiate()
	mesh_root.add_child(model)
	ModelUtils.setup_character_for_movement(model, 2.85)
	_blacken(model)
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	if _anim_lib:
		ap.add_animation_library("", _anim_lib)
		ModelUtils.set_animation_loops(ap)
	_mirror = mesh_root
	_mirror_anim = ap
	_mirror.set_meta("fresh", true)

# ---------------------------------------------------------------------------
# Perception helpers
# ---------------------------------------------------------------------------
func _get_scare_target_pos() -> Vector3:
	if is_instance_valid(_figure):
		return _figure.global_position + Vector3(0, 1.7, 0)
	return Vector3.ZERO

func _in_view(node: Node3D) -> bool:
	if not is_instance_valid(node) or not is_instance_valid(_camera):
		return false
	var p := _get_scare_target_pos()
	if p == Vector3.ZERO:
		return false
	return _in_view_point(p)

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
	var p := _get_scare_target_pos()
	if p == Vector3.ZERO:
		return false
	if _camera.is_position_behind(p):
		return false
	var to: Vector3 = (p - _camera.global_position).normalized()
	var fwd: Vector3 = -_camera.global_transform.basis.z
	return fwd.dot(to) > (1.0 - tol)

func _has_los(node: Node3D) -> bool:
	if not is_instance_valid(node) or not is_instance_valid(_camera):
		return false
	var p := _get_scare_target_pos()
	if p == Vector3.ZERO:
		return false
	return _ray_clear(_camera.global_position, p)

func _ray_hit(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1   # environment only
	return space.intersect_ray(q)

func _ray_clear(from: Vector3, to: Vector3) -> bool:
	return _ray_hit(from, to).is_empty()


func _apply_chase_contortions(delta: float) -> void:
	if not is_instance_valid(_figure):
		return
	var skeletons = _figure.find_children("*", "Skeleton3D")
	if skeletons.size() == 0:
		return
	var skeleton: Skeleton3D = skeletons[0]
	
	var t := Time.get_ticks_msec() / 1000.0
	
	# High frequency twitching
	var twitch_wave := sin(t * 36.0)
	var twist_wave := cos(t * 26.0)
	
	# Spine twist (body twitching / contorting)
	var spine_idx := skeleton.find_bone("Spine")
	if spine_idx != -1:
		var rot := Quaternion(Vector3.UP, twist_wave * 0.42) * Quaternion(Vector3.RIGHT, twitch_wave * 0.15)
		skeleton.set_bone_pose_rotation(spine_idx, rot)
		
	# Neck tilt (head snapping sideways and back)
	var neck_idx := skeleton.find_bone("Neck")
	if neck_idx != -1:
		var rot := Quaternion(Vector3.FORWARD, twitch_wave * 0.58) * Quaternion(Vector3.UP, twist_wave * 0.25)
		skeleton.set_bone_pose_rotation(neck_idx, rot)
		
	# Left Arm dislocation
	var l_arm_idx := skeleton.find_bone("LeftUpperArm")
	if l_arm_idx != -1:
		var rot := Quaternion(Vector3.BACK, 1.25 + twitch_wave * 0.55) * Quaternion(Vector3.UP, twist_wave * 0.7)
		skeleton.set_bone_pose_rotation(l_arm_idx, rot)
	# Right Arm dislocation
	var r_arm_idx := skeleton.find_bone("RightUpperArm")
	if r_arm_idx != -1:
		var rot := Quaternion(Vector3.FORWARD, -1.25 + twist_wave * 0.55) * Quaternion(Vector3.UP, twitch_wave * 0.7)
		skeleton.set_bone_pose_rotation(r_arm_idx, rot)


func _apply_peek_bone_poses(skeleton: Skeleton3D, _delta: float) -> void:
	if not is_instance_valid(_figure) or not _peek_corner:
		return

	# Determine lean direction relative to the figure's local space
	var out_dir := (_peek_to - _peek_from).normalized()
	var local_out_dir := _figure.global_transform.basis.inverse() * out_dir
	var tilt_side := 1.0 if local_out_dir.x >= 0.0 else -1.0

	var t := Time.get_ticks_msec() / 1000.0
	var breath := sin(t * 2.5) * 0.015

	# Only the HEAD emerges past the corner edge. The body is pinned ~0.75 m
	# behind cover, so the slide must actually CLEAR that distance — 0.35 m
	# never made it past the wall (the "peeking wasn't working" bug). 0.95 m
	# of unnatural neck-stretch does, and reads horrifying.
	var head_idx := skeleton.find_bone("Head")
	if head_idx != -1:
		# Tilt sideways (roll) + slight forward lean (curiosity)
		var head_roll := tilt_side * _lean * 0.55 + breath
		var head_fwd := _lean * 0.12
		var head_rot := Quaternion(Vector3.FORWARD, head_roll) * Quaternion(Vector3.RIGHT, head_fwd)
		skeleton.set_bone_pose_rotation(head_idx, head_rot)
		# Slide the head bone sideways to actually peek past the wall edge
		var head_rest := skeleton.get_bone_rest(head_idx).origin
		var head_slide := Vector3(tilt_side * _lean * 0.95, 0.0, 0.0)
		skeleton.set_bone_pose_position(head_idx, head_rest + head_slide)

	# Slight neck tilt to support the head lean (subtle, not full body)
	var neck_idx := skeleton.find_bone("Neck")
	if neck_idx != -1:
		var neck_roll := tilt_side * _lean * 0.25
		var neck_rot := Quaternion(Vector3.FORWARD, neck_roll) * Quaternion(Vector3.UP, sin(t * 1.5) * 0.03)
		skeleton.set_bone_pose_rotation(neck_idx, neck_rot)

	# Head-only isolation: collapse limb chains (arms, legs, shoulders) so no
	# elbow or foot ever pokes past the wall edge. The trunk chain must stay —
	# zeroing Spine/Hips would collapse the Head with them (scale propagates).
	for i in range(skeleton.get_bone_count()):
		if _is_limb_bone(skeleton, i):
			skeleton.set_bone_pose_scale(i, Vector3.ZERO)

func _is_limb_bone(skeleton: Skeleton3D, bone_idx: int) -> bool:
	var limb_roots := ["LeftShoulder", "LeftUpperArm", "RightShoulder", "RightUpperArm",
		"LeftUpLeg", "RightUpLeg", "LeftUpperLeg", "RightUpperLeg"]
	var cur := bone_idx
	while cur != -1:
		if limb_roots.has(skeleton.get_bone_name(cur)):
			return true
		cur = skeleton.get_bone_parent(cur)
	return false

## Bone overrides must land AFTER animation evaluation or the AnimationPlayer
## simply overwrites them the same frame (why the lean never showed). The
## skeleton_updated signal fires post-evaluation; the guard stops re-entry.
var _peek_skel_busy := false
func _on_peek_skeleton_updated(skeleton: Skeleton3D) -> void:
	if _peek_skel_busy or _mode != "peek" or not is_instance_valid(skeleton):
		return
	_peek_skel_busy = true
	_apply_peek_bone_poses(skeleton, 0.0)
	_peek_skel_busy = false

func _wire_peek_skeleton() -> void:
	if not is_instance_valid(_figure):
		return
	var skeletons := _figure.find_children("*", "Skeleton3D")
	if skeletons.is_empty():
		return
	var skeleton: Skeleton3D = skeletons[0]
	if not skeleton.skeleton_updated.is_connected(_on_peek_skeleton_updated.bind(skeleton)):
		skeleton.skeleton_updated.connect(_on_peek_skeleton_updated.bind(skeleton))


func _begin_roam() -> void:
	if _figure:
		_remove_figure()
	
	var cell := _find_random_roam_cell()
	if cell == Vector2i(-1, -1):
		_roam_cooldown = 5.0
		return
		
	var spot = _maze.world_center(cell)
	_spawn_figure(spot, false)
	if not _figure:
		_roam_cooldown = 5.0
		return
		
	_set_figure_alpha(1.0)
	_face_player(_figure)
	_play_anim("ual1_Walk")
	_mode = "roam"
	_roam_target = spot
	_roam_path = []
	_roam_wait = 0.0


func _tick_roam(delta: float) -> void:
	if not is_instance_valid(_figure):
		_end_roam()
		return
		
	var d := _figure.global_position.distance_to(_player.global_position)
	
	# Detection check: entity spots player
	var entity_sees_player := _ray_clear(_figure.global_position + Vector3(0, 1.5, 0), _camera.global_position)
	var entity_spot_range := 11.0
	if "is_crouching" in _player and _player.is_crouching:
		entity_spot_range = 5.5
		
	# Detection check: player spots entity
	var player_sees_entity := _player_looking_at(_figure, 0.25) and _has_los(_figure)
	var player_spot_range := 15.0
	
	if (entity_sees_player and d < entity_spot_range) or (player_sees_entity and d < player_spot_range):
		_trigger_roam_to_chase()
		return
		
	_roam_move(delta, d)
	_apply_chase_contortions(delta)


func _roam_move(delta: float, dist_to_player: float) -> void:
	if not is_instance_valid(_figure):
		return
		
	if _roam_target == Vector3.ZERO or _figure.global_position.distance_to(_roam_target) < 0.6:
		_roam_wait -= delta
		_play_anim("ual1_Idle")
		if _roam_wait <= 0.0:
			var cell := _find_random_roam_cell()
			if cell != Vector2i(-1, -1) and _maze:
				_roam_target = _maze.world_center(cell)
				_roam_path = _maze.corridor_path(_cell_of(_figure.global_position), cell)
				_roam_wait = _rng.randf_range(1.5, 3.5)
		return
		
	_play_anim("ual1_Walk")
	var target := _roam_target
	if _roam_path.size() >= 2:
		target = _maze.world_center(_roam_path[1])
		var flat := target - _figure.global_position
		flat.y = 0
		if flat.length() < 0.5:
			_roam_path.pop_front()
			if _roam_path.size() >= 2:
				target = _maze.world_center(_roam_path[1])
				
	var step_dir := target - _figure.global_position
	step_dir.y = 0
	if step_dir.length() > 0.01:
		_figure.global_position += step_dir.normalized() * 1.2 * delta
		var face := _figure.global_position + step_dir
		face.y = _figure.global_position.y
		if _figure.global_position.distance_to(face) > 0.05:
			_figure.look_at(face, Vector3.UP)


func _find_random_roam_cell() -> Vector2i:
	if _maze == null or not _maze.has_method("open_cells"):
		return Vector2i(-1, -1)
	var cells: Array = _maze.open_cells()
	if cells.size() == 0:
		return Vector2i(-1, -1)
	cells.shuffle()
	for c in cells:
		var wpos = _maze.world_center(c)
		var d = wpos.distance_to(_player.global_position)
		if d > 12.0 and d < 32.0:
			return c
	return cells[0]


func _trigger_roam_to_chase() -> void:
	_mode = "chase"
	_chase_state = "pursue"
	_last_seen_pos = _player.global_position
	_has_seen_player_this_chase = true
	_stumble_timer = _rng.randf_range(1.5, 2.5)
	_stumble_duration = 0.0
	_chase_speed_mult = 1.0
	request_flicker.emit(1.0)
	
	_play_anim("ual1_Sprint")
	
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		AudioManager.play_sfx(_sfx["chase_scream"], -2.0)
		
	_chase_steps = _attach_loop(_figure, _sfx.get("heavy_steps"), -4.0)
	_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)
	
	chase_started.emit()


func _end_roam() -> void:
	_remove_figure()
	_mode = "idle"
	_roam_cooldown = _rng.randf_range(20.0, 35.0) * lerpf(1.0, 0.6, _menace)
