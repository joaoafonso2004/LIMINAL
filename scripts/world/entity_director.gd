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
## CX30 — fullscreen jumpscare for the caught client only. Carries the victim's
## own peer id and is NEVER sent over the network; a teammate keeps watching the
## replicated 3D execution instead.
signal victim_jumpscare(victim_id: int)
signal chase_started()
signal chase_ended()

const USE_NEW_ENTITY_MODEL := true
const USE_ENTITY_MODEL := false  # legacy entity.fbx fallback, kept for one-line revert
const NEW_ENTITY_PATH := "res://assets/characters/entity/new_entity.glb"
const ENTITY_PATH := "res://assets/characters/entity/entity.fbx"
const WATCHER_PATH := "res://assets/characters/watcher_silhouette/watcher_silhouette.glb"  # fallback silhouette
const ANIM_LIB := "res://assets/characters/watcher_silhouette/watcher_silhouette_animations.tres"
const ENTITY_ACTION_SOURCES := {
	"entity_attack": "res://assets/characters/survivor_body/entity_attack.fbx",
	"entity_eat_start": "res://assets/characters/survivor_body/entity_eat_start.fbx",
	"entity_eat_loop": "res://assets/characters/survivor_body/entity_eat_loop.fbx",
	"entity_eat_end": "res://assets/characters/survivor_body/entity_eat_end.fbx",
}
const ENTITY_ACTION_TAKES := {
	# This Blender export contains three actions; the last is the entity actor.
	"entity_eat_start": "Armature|mixamo_com_002",
}
const NEW_ENTITY_ANIMATION_SOURCES := {
	"idle": "res://assets/characters/entity/new_entity_idle.fbx",
	"walk": "res://assets/characters/entity/new_entity_walk.fbx",
	"run": "res://assets/characters/entity/new_entity_run.fbx",
	# CX33 — played while it has lost you and is still looking. Deliberately NOT
	# in the required-clip list below: if it fails to retarget the entity falls
	# back to idle rather than losing its whole animation library.
	"confused": "res://assets/characters/entity/new_entity_confused.fbx",
	# CX36 — the authored corner lean. Which shoulder leads depends on which side
	# of the wall it is hiding behind. Also optional: until these FBXs exist the
	# peek falls back to `idle` plus the procedural head/neck override.
	"peek_right": "res://assets/characters/entity/new_entity_peak_right_shoulder.fbx",
	"peek_left": "res://assets/characters/entity/new_entity_peak_left_shoulder.fbx",
	"entity_attack": "res://assets/characters/survivor_body/entity_attack.fbx",
	"entity_eat_start": "res://assets/characters/survivor_body/entity_eat_start.fbx",
	"entity_eat_loop": "res://assets/characters/survivor_body/entity_eat_loop.fbx",
	"entity_eat_end": "res://assets/characters/survivor_body/entity_eat_end.fbx",
}
# The GLB's armature uses only Bone/Bone.001 names. This verified hierarchy map
# lets global-space retargeting preserve its unusual axes and wooden left leg.
const NEW_ENTITY_BONE_MAP := {
	"hips": "Bone",
	"upperleg.r": "Bone.001", "lowerleg.r": "Bone.002",
	"foot.r": "Bone.003", "toes.r": "Bone.004",
	"upperleg.l": "Bone.005", "lowerleg.l": "Bone.006", "foot.l": "Bone.007",
	"chest": "Bone.010", "upperchest": "Bone.011",
	"neck": "Bone.012", "head": "Bone.013",
	"shoulder.l": "Bone.043", "upperarm.l": "Bone.044",
	"lowerarm.l": "Bone.045", "hand.l": "Bone.046",
	"shoulder.r": "Bone.056", "upperarm.r": "Bone.057",
	"lowerarm.r": "Bone.058", "hand.r": "Bone.059",
}
# 2.70 m bind height leaves just enough headroom for the tallest attack frame
# under the 3.0 m ceiling; a static 2.82 m body pierced it during the lunge.
const ENTITY_VISUAL_HEIGHT := 2.70
const NEW_ENTITY_MODEL_YAW := PI * 0.5
const NEW_ENTITY_ROOT_MOTION_YAW := PI * 0.5
const NEW_ENTITY_PEEK_HEAD_HEIGHT := 2.48
const LEGACY_PEEK_HEAD_HEIGHT := 1.60
const JUMP_ATTACK_SEEK_TIME := 27.0 / 30.0
# 110-degree total field of view = 55 degrees either side of its forward gaze.
const ENTITY_VISION_DOT := 0.574
## CX36 — short: the jumpscare clip's own scream has to land into near-silence,
## but a hard cut on the frame of the catch is audible as a glitch.
const CATCH_AUDIO_FADE := 0.35
## How densely the lean path is validated, and how far past the body the authored
## peek pushes the head. See `_apparition_lean_clear`.
const APPARITION_CLEARANCE_SAMPLES := 6
const APPARITION_HEAD_REACH := 0.95
const ENTITY_EYE_HEIGHT := 2.43
const LEGACY_ENTITY_EYE_HEIGHT := 1.60
# Measured from the retargeted leg poses: run begins on the opposite planted
# foot to walk. Half-cycle compensation prevents crossed legs during crossfade.
const NEW_ENTITY_LOCOMOTION_PHASES := {"walk": 0.0, "run": 0.5}
const ATTACK_PLAYER_DELAY := 17.0 / 30.0 # player_hit was trimmed from source frame 17; contact stays on frame 42
# Compress the full paired kill from roughly 8.8 s to roughly 5.5 s without
# removing any authored phase. Entity and victim always receive the same speed.
const EXECUTION_PLAYBACK_SPEED := 1.55

# All pacing/difficulty values live in scripts/tuning.gd — edit there, not here.
const PLAYER_SPEED := 2.4
const CHASE_SPEED := Tuning.CHASE_SPEED
const STALK_SPEED := Tuning.STALK_SPEED
const CATCH_DIST := Tuning.CATCH_DIST
const ENTITY_WALK_WORLD_SPEED := 1.45
const ENTITY_RUN_WORLD_SPEED := Tuning.CHASE_SPEED
const MIRROR_TELEPORT_DISTANCE := 4.0
const MIRROR_MAX_PREDICTION := 0.12
const EXECUTION_START_DISTANCE := 1.35
const EXECUTION_EAT_FORWARD_DISTANCE := 0.24
const EXECUTION_EAT_LATERAL_OFFSET := -0.20
const EXECUTION_EAT_ALIGN_TIME := 0.22
const EXECUTION_CAMERA_LEAD_IN := 0.32
const COOP_SHARED_CHASE_WARNING_RANGE := 14.0

var _player: Node3D = null
var _camera: Camera3D = null
var _maze = null

# runtime
var _watcher_scene: PackedScene = null       # the model actually spawned (entity, or watcher fallback)
var _anim_lib: AnimationLibrary = null        # source clips (survivor/watcher skeleton naming)
var _fig_anim_lib: AnimationLibrary = null    # clips retargeted onto _watcher_scene's skeleton
var _using_new_entity := false
var _rng := RandomNumberGenerator.new()

# current apparition
var _mode := "idle"                    # idle | peek | jump | chase | stalk
var _figure: Node3D = null
var _fig_anim: AnimationPlayer = null
var _replicated_execution_clip := ""
var _peek_recede := false
var _peek_timer := 0.0
var _peek_elapsed := 0.0
# corner-peek: the figure starts BEHIND a wall end and leans out
var _peek_corner := false
var _peek_from := Vector3.ZERO         # hidden position (behind cover)
var _peek_to := Vector3.ZERO           # exposed position (leaning out)
var _lean := 0.0                       # 0 hidden .. 1 fully out
var _lean_dir := 1.0                   # 1 leaning out, -1 sliding back
var _jump_prev_fov := 72.0             # camera fov to restore after the scare
var _is_stumbling := false
var _wet_floor_stumble_timer := 0.0

func slip_and_stumble(duration: float = 2.0) -> void:
	if _is_stumbling or _catch_in_progress:
		return
	_is_stumbling = true
	var actual_duration := duration
	
	if is_instance_valid(_fig_anim):
		var clips := ["entity_slip_getup", "slip_and_getup", "stumble_recover", "entity_stumble", "entity_slip", "stumble", "slip", "fall", "crawl"]
		var found_clip := ""
		for c in clips:
			if _fig_anim.has_animation(c):
				found_clip = c
				break
		if found_clip != "":
			_fig_anim.play(found_clip, 0.2)
			actual_duration = maxf(1.0, _fig_anim.get_animation(found_clip).length)
		elif is_instance_valid(_figure):
			_figure.rotation.x = deg_to_rad(40.0)
			_figure.position.y -= 0.5
	elif is_instance_valid(_figure):
		_figure.rotation.x = deg_to_rad(40.0)
		_figure.position.y -= 0.5
	
	_wet_floor_stumble_timer = actual_duration

	if has_node("/root/AudioManager"):
		var splash_sfx = load("res://assets/audio/sfx/environment/environment_light_flicker_buzz.mp3")
		AudioManager.play_sfx_3d(self, splash_sfx, _figure.global_position if is_instance_valid(_figure) else global_position, 2.0, 20.0)

	get_tree().create_timer(actual_duration).timeout.connect(func():
		_is_stumbling = false
		if is_instance_valid(_fig_anim):
			var getup_clips := ["entity_get_up", "entity_recover", "get_up", "idle", "walk"]
			for gc in getup_clips:
				if _fig_anim.has_animation(gc) and _fig_anim.current_animation != gc:
					_fig_anim.play(gc, 0.2)
					break
		if is_instance_valid(_figure):
			_figure.rotation.x = 0.0
	)

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
var _confused_timer := 0.0             # CX33: lost you mid-chase, still looking
var _chase_time := 0.0                 # seconds since the charge began
var _close_breath_cd := 0.0
var _stumble_timer := 0.0
var _stumble_duration := 0.0
var _chase_speed_mult := 1.0
var _roam_cooldown := 0.0              # idle is transitional; physical Entity keeps roaming
var _roam_path : Array = []
var _roam_target := Vector3.ZERO
var _roam_wait := 0.0
var _investigating_callout := false
var _roam_leg_time := 0.0              # time spent walking toward the current roam target (stuck guard)
const ROAM_LEG_TIMEOUT := 8.0          # give up an unreachable target and roam elsewhere
var _fleeing := false                  # sprinting away after a down before normal roam
var _revive_pressure_timer := -1.0
var _revive_pressure_position := Vector3.ZERO

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
var _local_targetable := true          # false while this client is down/dead
var _local_bleedout := false           # downed-but-revivable: entity flees + roams, doesn't despawn
var _net_fig_active := false           # another client's apparition is live
var _net_fig_watchdog := 0.0           # frees the slot if their scare fizzles
var _mp_personal_next := INF           # host rotates private scares fairly
var _mp_personal_cursor := 0
var _mp_personal_sequence := 0
var _queued_remote_scare := ""
var _queued_remote_scare_expires := 0.0
var _queued_remote_scare_retry_at := 0.0
var _owns_fig := false
var _fig_send_timer := 0.0
var _fig_snapshot_elapsed := 0.0
var _fig_last_sent_position := Vector3.ZERO
var _fig_last_sent_valid := false
var _mirror: Node3D = null
var _mirror_anim: AnimationPlayer = null
var _mirror_steps: AudioStreamPlayer3D = null
var _mirror_scream: AudioStreamPlayer3D = null
var _mirror_mode := ""
var _mirror_owner_id := -1
var _mirror_target_position := Vector3.ZERO
var _mirror_target_yaw := 0.0
var _mirror_net_velocity := Vector3.ZERO
var _mirror_snapshot_age := 0.0
var _mirror_has_target := false
## CX33b — seconds the chase has run with the Entity unable to see the player.
## Only a stuck valve; the chase normally ends via the memory hunt.
var _blind_hunt_time := 0.0
var _stalk_active := false
var _linger_timer := 0.0
var _stalk_path: Array = []
var _stalk_path_timer := 0.0
var _stalk_grace_timer := 0.0
var _stalk_moving := false
var _stalk_target_id := -999
var _remote_stalk_gaze: Dictionary = {}
var _stalk_gaze_send_timer := 0.0
var _last_stalk_gaze := false
var _stalk_remote_catch_until: Dictionary = {}
var _prox_muffle := false              # a figure is near but unseen → world muffled

# chase pathing / audio
var _chase_path: Array = []            # Vector2i waypoints along corridors
var _path_timer := 0.0
var _path_fail := 0.0                  # seconds spent with no route to the player
var _chase_steps: AudioStreamPlayer3D = null
var _chase_scream: AudioStreamPlayer3D = null
var _figure_collision_shape: CapsuleShape3D = null
var _apparition_collision_shape: CapsuleShape3D = null
## CX36 — true while an authored peek_left/peek_right clip is driving the lean,
## which disables the procedural head/neck stand-in.
var _peek_authored := false
var _peek_clip := ""
var _entity_step_prev_pos := Vector3.ZERO
var _entity_step_figure_id := 0
var _entity_step_stop_delay := 0.0
var _mirror_step_prev_pos := Vector3.ZERO
var _mirror_step_stop_delay := 0.0

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
var _catch_in_progress := false
## CX30 — set by the world while the victim's fullscreen clip owns the screen.
## Its embedded audio replaces the director's own catch scream.
var _victim_jumpscare_playing := false
var _execution_camera_active := false
var _execution_camera_phase := "attack"
var _execution_camera_side := 1.0
var _execution_camera_lateral := false
var _rule_speed_mult := 1.0
var _logged_mode := "idle"             # last mode reported to the debug log
var _event_hold_until := 0.0

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
	if _mp_host:
		_mp_personal_next = Tuning.PEEK_FIRST_SIGHTING + _rng.randf_range(-3.0, 5.0)

## Co-op life-cycle gate. A downed/dead player must never keep a locally-owned
## entity, receive a scare, or be caught again. The host can still direct the
## shared entity towards another living client while spectating.
func set_local_player_targetable(value: bool, bleedout: bool = false) -> void:
	if _local_targetable == value and (value or _local_bleedout == bleedout):
		return
	_local_targetable = value
	if value:
		_local_bleedout = false
		_catch_in_progress = false
		_victim_jumpscare_playing = false
		return
	_local_bleedout = bleedout
	# The host owns the final stalker for the whole room. Losing the host's local
	# survivor must not delete or demote that shared entity while teammates live.
	var keep_shared_stalk := _mp and _mp_host and _final_phase and _mode == "stalk"
	_queued_remote_scare = ""
	_queued_remote_scare_expires = 0.0
	_queued_remote_scare_retry_at = 0.0

	_stop_chase_loops()
	_chase_state = "pursue"
	# CX33 — a downed/dead local player must not leave the body frozen in
	# confused forever; nothing ticks that state on this client any more.
	if _mode == "confused":
		_confused_timer = 0.0
		_roam_with_current_figure()
	_chase_path = []
	if not keep_shared_stalk:
		_stalk_active = false
	_linger_timer = 0.0
	_prox_muffle = false
	_catch_in_progress = false
	_victim_jumpscare_playing = false
	request_flicker.emit(0.0)
	request_dread.emit(0.0)
	muffle.emit(false)
	var overlay := _get_overlay()
	if is_instance_valid(overlay) and overlay.has_method("set_chase_vignette"):
		overlay.set_chase_vignette(false)
	if is_instance_valid(_camera):
		_camera.fov = 72.0
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("silent")
	if keep_shared_stalk:
		_stalk_grace_timer = maxf(_stalk_grace_timer, Tuning.STALK_START_GRACE)
		return

	if bleedout:
		# Downed but revivable: DON'T despawn. Flee far and keep roaming — the entity
		# just ignores/can't catch us until a teammate revives us.
		_flee_and_roam()
	else:
		_remove_figure()
		_mode = "idle"
		_roam_path = []

func set_rule_modifiers(speed_multiplier: float) -> void:
	_rule_speed_mult = clampf(speed_multiplier, 0.75, 1.5)

func _now() -> float:
	return GameManager.run_time if has_node("/root/GameManager") else 0.0


func _physical_spawn_allowed() -> bool:
	return _now() >= Tuning.ENTITY_INITIAL_SPAWN_DELAY


func _entity_eye_height() -> float:
	return ENTITY_EYE_HEIGHT if _using_new_entity else LEGACY_ENTITY_EYE_HEIGHT

## Difficulty rises with the tins: 0.0 = untouched run, 1.0 = all collected.
func set_menace(v: float) -> void:
	_menace = clampf(v, 0.0, 1.0)

func calm_down(amount: float) -> void:
	_stress = maxf(0.0, _stress - maxf(amount, 0.0))

## Milestones need a short readable beat. This pauses only NEW scheduled
## scares; an active chase is never cancelled by picking up an objective.
func hold_new_events(seconds: float) -> void:
	_event_hold_until = maxf(_event_hold_until, _now() + maxf(seconds, 0.0))

## Loud actions do not spawn a chase from nothing, but an active physical
## entity can investigate them and reacquire a careless runner.
func investigate_noise(world_position: Vector3, audible_range: float, kind: String = "") -> void:
	# A host remains authority for the shared Entity even if its own survivor is
	# down; remote living players and their screams must still be perceived.
	if _ended or (not _local_targetable and not (_mp and _mp_host)):
		return
	if kind == "sprint":
		_add_stress(0.012)
		_sound_pressure = minf(1.0, _sound_pressure + 0.025)
	elif kind == "callout":
		_add_stress(0.02)
		_sound_pressure = minf(1.0, _sound_pressure + 0.06)
		# A shout in the dark rouses a dormant entity: it comes WANDERING toward
		# the sound (never a chase from nothing — the maze still has to lead it
		# into view). Only the director spawns/steers the shared figure; co-op
		# clients merely mirror whatever the host broadcasts.
		if _physical_spawn_allowed() and (not _mp or _mp_host) \
				and (_mode == "idle" or _mode == "roam") \
				and (is_instance_valid(_figure) or not _shared_chase_active()):
			_rouse_toward(world_position)
	if not is_instance_valid(_figure):
		return
	if not _entity_can_hear_noise(world_position, audible_range):
		return
	match _mode:
		"chase":
			_last_seen_pos = world_position
			if _chase_state == "search":
				_chase_state = "pursue"
				_search_timer = 0.0
		"roam":
			var direct_d := _figure.global_position.distance_to(world_position)
			# Normal walking does not redirect the wanderer unless sprinting, shouting or extremely close (< 3m).
			if kind in ["sprint", "callout", "breaker"] or direct_d < 3.0:
				var dest_cell := _cell_of(world_position)
				_roam_target = _maze.world_center(dest_cell) if (_maze and _maze.has_method("world_center")) else world_position
				if _maze and _maze.has_method("corridor_path"):
					_roam_path = _maze.corridor_path(_cell_of(_figure.global_position), dest_cell)
				_roam_wait = 0.0
				_roam_leg_time = 0.0


## Sound follows open corridors instead of travelling at full strength through
## walls. Direct sound uses Euclidean distance; obstructed sound pays corridor
## distance plus a small loss at every bend.
func _entity_can_hear_noise(world_position: Vector3, audible_range: float) -> bool:
	if not is_instance_valid(_figure) or audible_range <= 0.0:
		return false
	var ear := _figure.global_position + Vector3.UP * _entity_eye_height()
	var sound_point := world_position + Vector3.UP * 0.25
	var direct_distance := _figure.global_position.distance_to(world_position)
	if direct_distance > audible_range:
		return false
	if _ray_clear(ear, sound_point):
		return true
	if _maze == null or not _maze.has_method("corridor_path"):
		return direct_distance + 2.0 <= audible_range
	var path: Array = _maze.corridor_path(
		_cell_of(_figure.global_position), _cell_of(world_position))
	if path.is_empty():
		return false
	var corridor_distance := maxf(
		direct_distance, float(maxi(path.size() - 1, 0)) * 4.0)
	var turns := 0
	if path.size() >= 3:
		var previous_direction: Vector2i = path[1] - path[0]
		for path_index in range(2, path.size()):
			var direction: Vector2i = path[path_index] - path[path_index - 1]
			if direction != previous_direction:
				turns += 1
			previous_direction = direction
	var acoustic_distance := corridor_distance + 2.0 + float(turns) * 1.25
	return acoustic_distance <= audible_range

func _ready() -> void:
	_rng.randomize()
	if ResourceLoader.exists(ANIM_LIB):
		_anim_lib = load(ANIM_LIB)
	_fig_anim_lib = _anim_lib
	# Preferred pirate model. Its generic Bone.001 naming cannot use the legacy
	# name remapper, so locomotion and execution are baked in global space.
	if USE_NEW_ENTITY_MODEL and ResourceLoader.exists(NEW_ENTITY_PATH):
		var pirate := load(NEW_ENTITY_PATH) as PackedScene
		if pirate != null:
			var pirate_library := _retarget_new_entity(pirate)
			if pirate_library != null:
				_watcher_scene = pirate
				_fig_anim_lib = pirate_library
				_using_new_entity = true
	# Legacy entity model remains available as a reversible fallback.
	if _watcher_scene == null and USE_ENTITY_MODEL and ResourceLoader.exists(ENTITY_PATH):
		var ent := load(ENTITY_PATH) as PackedScene
		if ent != null:
			var retarget := _retarget_for_scene(ent, _anim_lib)
			if retarget != null:
				_watcher_scene = ent
				_fig_anim_lib = retarget
	if _watcher_scene == null and ResourceLoader.exists(WATCHER_PATH):
		_watcher_scene = load(WATCHER_PATH)
	# The new model already received locomotion + execution in one global bake.
	# Fallback models keep their old locomotion and receive only the action clips.
	if _watcher_scene != null and not _using_new_entity:
		var action_source := ModelUtils.build_animation_library_from_clips(
			ENTITY_ACTION_SOURCES, ENTITY_ACTION_TAKES)
		var action_retarget := _retarget_for_scene(_watcher_scene, action_source)
		if action_retarget != null:
			_fig_anim_lib = _fig_anim_lib.duplicate(true) if _fig_anim_lib != null else AnimationLibrary.new()
			for action_name in action_retarget.get_animation_list():
				if _fig_anim_lib.has_animation(action_name):
					_fig_anim_lib.remove_animation(action_name)
				_fig_anim_lib.add_animation(action_name, action_retarget.get_animation(action_name).duplicate(true))
	_load_sfx()
	# Stagger personal horror so co-op clients never receive it on one frame.
	_next_peek = Tuning.PEEK_FIRST_SIGHTING + _rng.randf_range(-5.0, 9.0)
	_next_jump = 999.0                                   # armed at JUMP_ARM_TIME
	_next_chase = 999.0                                  # armed at CHASE_ARM_TIME
	_next_sound = 25.0


func _retarget_new_entity(scene: PackedScene) -> AnimationLibrary:
	var probe := scene.instantiate() as Node3D
	if probe == null:
		return null
	var skeletons := probe.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		probe.free()
		return null
	var skeleton := skeletons[0] as Skeleton3D
	var rel_path := String(probe.get_path_to(skeleton))
	var result := ModelUtils.build_global_library_from_clips(
		skeleton, rel_path, self, NEW_ENTITY_ANIMATION_SOURCES,
		ENTITY_ACTION_TAKES, NEW_ENTITY_BONE_MAP, NEW_ENTITY_ROOT_MOTION_YAW)
	probe.free()
	var library := result.get("lib") as AnimationLibrary
	if int(result.get("matched", 0)) < 15 or library == null:
		push_warning("new_entity retarget rejected; keeping the proven watcher fallback")
		return null
	for required in ["idle", "walk", "run", "entity_attack", "entity_eat_start",
			"entity_eat_loop", "entity_eat_end"]:
		if not library.has_animation(required):
			push_warning("new_entity missing retargeted clip: " + required)
			return null
	return library

## Probe a candidate model's skeleton and rebuild the shared clips onto it.
## Returns null (keep the old silhouette) if it has no skeleton or too few bones
## match — better a working watcher than a T-posing entity.
func _retarget_for_scene(scene: PackedScene, src_lib: AnimationLibrary) -> AnimationLibrary:
	if src_lib == null:
		return null
	var probe := scene.instantiate()
	if probe == null:
		return null
	var skeletons := probe.find_children("*", "Skeleton3D")
	if skeletons.is_empty():
		probe.free()
		return null
	var skeleton := skeletons[0] as Skeleton3D
	var rel_path := String(probe.get_path_to(skeleton))
	var result := ModelUtils.retarget_library(src_lib, skeleton, rel_path)
	probe.free()
	if int(result.get("matched", 0)) < 6:
		return null
	return result.get("lib") as AnimationLibrary

func _load_sfx() -> void:
	var paths := {
		"jump": "res://assets/audio/sfx/enemy/enemy_jumpscare_scream.mp3",
		# CX32 — the chase now really uses the file its name promises. It used to
		# point at a juanjo take, so replacing this asset changed nothing.
		"chase_scream": "res://assets/audio/sfx/enemy/enemy_chase_distorted_scream.mp3",
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
	if not is_instance_valid(_player) or not is_instance_valid(_camera):
		return
	_tick_mirror_interpolation(delta)
	_ground_figure_pose(_figure)
	_ground_figure_pose(_mirror)
	if _execution_camera_active:
		_tick_execution_camera(delta)
	# Solo marks the run ended as soon as the catch starts. The paired animation
	# and cinematic camera must still finish, but no director AI should run.
	if _ended:
		if _catch_in_progress:
			_net_fig_tick(delta)
		return
	_update_shared_chase_warning()
	_tick_revive_pressure(delta)
	# Dead clients only render the shared figure pursuing living teammates. The
	# host additionally keeps the scheduler alive so it can pick another client,
	# but skips every camera/player-local scare and perception update.
	if _mp and not _local_targetable:
		# Even if the host is down/spectating, it remains the authority for the one
		# shared final stalker and keeps pursuing the remaining living teammates.
		if _mp_host and _final_phase and _mode == "stalk":
			_tick_stalk(delta)
			_tick_entity_steps(delta)
			_net_fig_tick(delta)
			return
		# Downed-but-revivable: keep the entity fleeing/roaming (it ignores us until
		# revived) instead of going dormant. Falls through to the dormant path if
		# there's no local figure to drive (pure mirroring client).
		if _local_bleedout and is_instance_valid(_figure):
			if _mp_host:
				_arm_schedules(_now())
			_tick_roam(delta)
			_tick_entity_steps(delta)
			_tick_mirror_steps(delta)
			_net_fig_tick(delta)
			return
		if _mp_host:
			var host_time := _now()
			_arm_schedules(host_time)
			_tick_persistent_roam(delta)
			# CX31 — a downed host still directs the run; living teammates must
			# keep receiving their private peeks and jumps.
			_tick_mp_personal_schedule(host_time)
			if _mode == "roam" and is_instance_valid(_figure):
				_tick_roam(delta)
				_tick_entity_steps(delta)
				_net_fig_tick(delta)
				return
			_tick_idle(host_time)
		_tick_mirror_steps(delta)
		_net_fig_tick(delta)
		return
	var t := 0.0
	var looks := 0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
		looks = GameManager.look_back_count
	_arm_schedules(t)
	_tick_persistent_roam(delta)
	if _mp and _mp_host:
		_tick_mp_personal_schedule(t)
	# CX34 — a queued scare no longer waits for the shared Entity to be idle. It
	# only waits for a gap in the hunt, which remote_scare() re-checks itself.
	if _mp and _queued_remote_scare != "":
		_consume_queued_remote_scare(t)
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
	# Do not let chase/stalk locomotion overwrite the paired execution clips.
	# Networking still ticks so every client sees the same entity phase.
	if _catch_in_progress or _replicated_execution_clip != "":
		_net_fig_tick(delta)
		return

	if _mode != _logged_mode:
		if Tuning.DEBUG_ENTITY_LOG and OS.is_debug_build():
			print("[entity] ", _logged_mode, " -> ", _mode, " @ ", snappedf(t, 0.1), "s")
		_logged_mode = _mode

	# A due jumpscare doesn't queue politely behind a watcher — it interrupts.
	# (It fires while walking, standing, mid-peek, mid-tail: whenever it's due.)
	if _apparition_mode in ["peek", "shadow"] and t >= _next_jump and _can_jump(t):
		_end_apparition()
		_begin_jump(t)

	# CX34 — apparitions live beside the shared Entity now, not instead of it.
	# They are private to this client, so they tick on their own clock while the
	# one shared body keeps roaming/chasing identically for the whole lobby.
	_tick_apparition(delta, t)

	match _mode:
		"chase":
			_tick_chase(delta)
		"confused":
			_tick_confused(delta)
		"stalk":
			_tick_stalk(delta)
		"roam":
			_tick_roam(delta)
		_:
			_tick_idle(t)

	_tick_entity_steps(delta)
	_tick_mirror_steps(delta)

	if _mp:
		_net_fig_tick(delta)

## CX34 — the private apparition state machine. Independent of `_mode`, so a
## peek can happen while the shared Entity roams somewhere else entirely.
func _tick_apparition(delta: float, t: float) -> void:
	match _apparition_mode:
		"peek":
			_tick_peek(delta)
		"shadow":
			_tick_shadow(delta)
		"jump":
			pass   # a fixed-length timer owns the jump; nothing may interrupt it
		_:
			_tick_apparition_schedule(t)


## Decide when this client gets its own peek/shadow/jump. Every player in the
## lobby runs this for themselves — that is what "client sided" means here: the
## events differ per player, but nobody is left out.
func _tick_apparition_schedule(t: float) -> void:
	if _ended or _final_phase or _catch_in_progress:
		return
	if not _local_targetable or t < Tuning.ENTITY_INITIAL_SPAWN_DELAY:
		return
	if t < _event_hold_until or _mode == "chase" or _mode == "confused":
		return
	# In co-op the host's round-robin decides WHOSE turn it is (see
	# _tick_mp_personal_schedule); clients never roll their own.
	if _mp:
		return
	if t >= _next_jump and _can_jump(t):
		_begin_jump(t)
	elif t >= _next_shadow:
		_begin_shadow()
	elif t >= _next_peek:
		_begin_peek()


func _arm_schedules(t: float) -> void:
	# Collected snus pull every arm time closer — progress wakes it up.
	var arm_scale := 1.0 - 0.5 * _menace
	if _next_jump > 900.0 and t >= Tuning.JUMP_ARM_TIME * arm_scale:
		_next_jump = t + _rng.randf_range(20.0, 70.0)
	if _next_chase > 900.0 and t >= Tuning.CHASE_ARM_TIME * arm_scale:
		_next_chase = t + _rng.randf_range(15.0, 60.0)
	if _next_shadow > 900000.0 and t >= Tuning.SHADOW_ARM_TIME * arm_scale:
		_next_shadow = t + _rng.randf_range(10.0, 60.0)

func _tick_mp_personal_schedule(t: float) -> void:
	if t < _mp_personal_next or _world == null or not _world.has_method("alive_player_ids"):
		return
	# CX34 — a hunting Entity still suppresses private scares, but a plain roam
	# does not: apparitions have their own body and never disturb the roamer.
	if _shared_slot_busy():
		_mp_personal_next = t + 3.0
		return
	var ids: Array = _world.alive_player_ids()
	if ids.is_empty() or not has_node("/root/NetManager"):
		_mp_personal_next = t + 5.0
		return
	ids.sort()
	var target := int(ids[_mp_personal_cursor % ids.size()])
	_mp_personal_cursor += 1
	var arm_scale := 1.0 - 0.5 * _menace
	var jump_is_armed := t >= Tuning.JUMP_ARM_TIME * arm_scale
	var kind := "jump" if jump_is_armed and _mp_personal_sequence % 4 == 3 else "peek"
	_mp_personal_sequence += 1
	if target == NetManager.local_player_id:
		remote_scare(kind)
	else:
		_world.net_send("scare", {"kind": kind, "target": target})
		# CX34 — the host's own `_next_peek` is only advanced by its own
		# `_end_apparition()`. Delegating left it stale in the past, so the
		# scheduler kept firing. Advance it here too.
		_next_peek = _dread_scaled_peek_gap()
		if kind == "jump":
			_last_jump_time = t
			_next_jump = t + _rng.randf_range(150.0, 260.0) * lerpf(1.0, 0.6, _menace)
	# One dispatch at a time, round-robin. This keeps each player's private
	# horror active without firing the same event on every screen at once.
	var base_gap := clampf(14.0 / float(ids.size()), 4.0, 9.0) / maxf(_rule_speed_mult, 0.1)
	_mp_personal_next = t + base_gap * lerpf(1.0, 0.45, _menace) * _rng.randf_range(0.85, 1.15)

func _consume_queued_remote_scare(t: float) -> void:
	if _queued_remote_scare == "":
		return
	if t < _queued_remote_scare_retry_at:
		return
	if t > _queued_remote_scare_expires:
		_queued_remote_scare = ""
		_queued_remote_scare_expires = 0.0
		_queued_remote_scare_retry_at = 0.0
		return
	var kind := _queued_remote_scare
	_queued_remote_scare = ""
	_queued_remote_scare_expires = 0.0
	_queued_remote_scare_retry_at = 0.0
	# CX34 — go back through remote_scare so the "Entity is hunting / already on
	# screen" guards are re-checked. It re-queues itself if the gap has closed
	# again; calling _start_personal_scare directly skipped every check.
	remote_scare(kind)

func _start_personal_scare(kind: String, t: float) -> void:
	match kind:
		"chase":
			_begin_chase()
		"jump":
			if _can_jump(t):
				_begin_jump(t)
			else:
				_begin_peek()
		"shadow":
			_begin_shadow()
		_:
			_begin_peek()

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
	_setup_entity_model(model)
	mesh_root.global_position = pos
	_style_entity_model(model, 0.55, false)
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
	if _mp:
		return  # co-op private scares are distributed by the fair host rotation
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
		_spawn_apparition(p)
		if _apparition == null:
			return
		_face_player(_apparition)
		_play_apparition_anim("ual1_Idle")
		_peek_corner = false
		_peek_style = "stare"
		_stare_timer = -1.0
		_peek_elapsed = 0.0
		_peek_witnessed = true
		_apparition_mode = "peek"
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
	var target := clampf(base + fear + _menace * 0.25, 0.0, 1.0)
	var lerp_spd := 0.6
	if _mode == "chase":
		target = 1.0
		lerp_spd = 5.0
	elif _mode == "stalk":
		target = maxf(target, 0.7)
	elif _apparition_mode == "shadow":
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
	# More frequent when the player keeps looking back (fear feeds the game) and
	# as SNUS piles up — the halls get busier and louder the deeper you're in.
	var fear_mult := 1.0 + clampf(float(looks) * 0.06, 0.0, 1.6) + _menace * 0.6
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
## Keep the physical Entity alive. `idle` is now only the hand-off state between
## a despawned chase/apparition and a fresh, hidden roam spawn.
func _tick_persistent_roam(delta: float) -> void:
	if _ended or _final_phase or _catch_in_progress:
		return
	if not _physical_spawn_allowed():
		return
	if _mp and not _mp_host:
		return
	if _mode != "idle" or _shared_chase_active():
		return
	_roam_cooldown = maxf(0.0, _roam_cooldown - delta)
	if _roam_cooldown <= 0.0:
		_begin_roam()


func _tick_idle(t: float) -> void:
	if t < Tuning.ENTITY_INITIAL_SPAWN_DELAY:
		return
	if t < _event_hold_until:
		return
	if _final_phase:
		if not _stalk_active and (not _mp or _mp_host):
			_begin_stalk()
		# Clients render the replicated final stalker and schedule no more personal
		# chases/peeks underneath it.
		return
	# A physical shared figure has priority over personal hallucinations.
	if _shared_chase_active():
		return
	# During the short network window after the last living player falls there
	# is nobody valid to receive an event. Never fall back to the dead host.
	if _mp and not _local_targetable and _world != null \
			and _world.has_method("alive_player_ids") and _world.alive_player_ids().is_empty():
		return
	# menace raises the chase cap too (2 → 5 with every tin in hand)
	if (not _mp or _mp_host) and t >= _next_chase \
			and _chase_done < Tuning.CHASE_MAX_PER_RUN + int(round(_menace * 3.0)):
		if _mp:
			if _dispatch_chase():
				_chase_done += 1
				_next_chase = t + _rng.randf_range(50.0, 110.0) * lerpf(1.0, 0.55, _menace)
		elif _local_targetable:
			_begin_chase()
			_chase_done += 1
			_next_chase = t + _rng.randf_range(50.0, 110.0) * lerpf(1.0, 0.55, _menace)
		return
	# CX34 — peeks/shadows/jumps moved to `_tick_apparition_schedule()`. They no
	# longer need the shared Entity to be idle, and gating them here (which the
	# persistent roam made unreachable) is what silently killed them.

var _chase_target_cursor := 0

## Co-op direction: pick a living player; if it isn't us, hand the scare to
## their client (their camera does the validation) and mirror what follows.
## Returns true when delegated — the local director stays idle.
func _dispatch_chase() -> bool:
	if not _mp or not _mp_host or _world == null or not _world.has_method("alive_player_ids"):
		return false
	if not has_node("/root/NetManager"):
		return false
	
	var ids: Array = _world.alive_player_ids()
	if ids.is_empty():
		return false
	ids.sort()
	_chase_target_cursor += 1
	var target: int = int(ids[_chase_target_cursor % ids.size()])
	if target == NetManager.local_player_id:
		if _local_targetable:
			_begin_chase()
		return true
	_world.net_send("scare", {"kind": "chase", "target": target})
	_net_fig_active = true   # held until their figoff arrives
	_mirror_mode = "chase"
	_net_fig_watchdog = 20.0
	return true

## Chase a SPECIFIC player — used when the roaming figure organically spots
## someone. Local chase if it's the host; otherwise handed to that player's
## client (which validates against their own camera) and the host mirrors it.
func _dispatch_chase_to(target_id: int) -> bool:
	if not _mp or not _mp_host or _world == null or not has_node("/root/NetManager"):
		return false
	if target_id == NetManager.local_player_id:
		if _local_targetable:
			_begin_chase()
			return true
		return false
	# The host-owned roaming figure and the delegated client chase are the SAME
	# physical Entity. Release and hide the host instance before handing authority
	# over, otherwise both bodies survive and enter the execution together.
	var handoff_position := Vector3.ZERO
	var handoff_rotation := 0.0
	var has_handoff := is_instance_valid(_figure)
	if has_handoff:
		handoff_position = _figure.global_position
		handoff_rotation = _figure.rotation.y
		_remove_figure()
		_mode = "idle"
		if _owns_fig:
			_world.net_send("figoff", {})
			_owns_fig = false
	_world.net_send("scare", {
		"kind": "chase",
		"target": target_id,
		"handoff": has_handoff,
		"x": handoff_position.x,
		"z": handoff_position.z,
		"ry": handoff_rotation,
	})
	_net_fig_active = true
	_mirror_mode = "chase"
	_net_fig_watchdog = 20.0
	return true

func _shared_chase_active() -> bool:
	# A replicated roam/flee is the same physical entity. It occupies the shared
	# slot too, otherwise the host can dispatch a second chase while it is visible.
	return _mp and _net_fig_active \
		and _mirror_mode in ["chase", "roam", "stalk", "confused"]


func _shared_physical_figure_present() -> bool:
	var owns_physical := is_instance_valid(_figure) \
		and _mode in ["chase", "roam", "stalk", "confused"]
	return owns_physical or _shared_chase_active()


## CX34 — the shared Entity is busy hunting; a private apparition on top of that
## would be noise. A plain roam no longer blocks anything: apparitions have their
## own body and never disturb the roamer.
func _shared_slot_busy() -> bool:
	var owns_busy := is_instance_valid(_figure) \
		and _mode in ["chase", "stalk", "confused"]
	var mirrors_busy := _mp and _net_fig_active \
		and _mirror_mode in ["chase", "stalk", "confused"]
	return owns_busy or mirrors_busy


## CX34 — an apparition must never share the screen with the shared Entity, or
## the player sees two of them. This is the only coupling left between the two.
func _shared_entity_on_screen() -> bool:
	if is_instance_valid(_figure) and _mode in ["chase", "roam", "stalk", "confused"] \
			and _in_view(_figure) and _has_los(_figure):
		return true
	if _mp and _net_fig_active and is_instance_valid(_mirror) \
			and _in_view(_mirror) and _has_los(_mirror):
		return true
	return false

## A trapped phone answered — the entity takes the call. Player-initiated,
## A trapped phone answered — the entity roars and charges straight towards the telephone!
func phone_chase(phone_pos: Vector3) -> void:
	if _ended or not _local_targetable or not _physical_spawn_allowed():
		return
	if _apparition_mode != "":
		_end_apparition()
	_mode = "chase"
	_chase_state = "windup"
	_windup_timer = 0.6
	_chase_done += 1
	_windup_spot = _find_chase_spawn()
	if _windup_spot == Vector3.INF:
		var eye := _camera.global_position if is_instance_valid(_camera) else _player.global_position
		_windup_spot = eye + Vector3(8.0, 0, 8.0)
	chase_started.emit()
	var ov_start := _get_overlay()
	if is_instance_valid(ov_start) and ov_start.has_method("set_chase_vignette"):
		ov_start.set_chase_vignette(true)
	request_flicker.emit(0.5)
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		AudioManager.play_sfx_3d(self, _sfx["chase_scream"], _windup_spot + Vector3(0, 1.5, 0), -3.0, 50.0, 0.9)

func phone_jumpscare() -> void:
	if _ended or not _local_targetable or _mode != "idle" \
			or not _physical_spawn_allowed():
		return
	_begin_jump(_now())

## A scare order from the host, realized with OUR camera and OUR maze rays.
func remote_scare(kind: String, data: Dictionary = {}) -> void:
	if _ended or not _local_targetable:
		return
	# CX34 — a private apparition no longer needs the shared Entity to step
	# aside; it has its own body. The only rule left is that both must never be
	# on this client's screen at the same time, and that a hunting Entity is
	# already scary enough without a hallucination on top.
	if kind != "chase":
		if _shared_slot_busy() or _shared_entity_on_screen():
			_queued_remote_scare = kind
			_queued_remote_scare_expires = _now() + 30.0
			_queued_remote_scare_retry_at = _now() + 1.0
			return
		if _apparition_mode != "":
			if kind == "jump":
				_end_apparition()   # a due jumpscare interrupts a watcher
			else:
				return              # already hallucinating; let it finish
		_start_personal_scare(kind, _now())
		return
	# Never materialize a second physical chase beside a replicated entity.
	if _shared_chase_active():
		# Ordered handoff from a host-owned roam: discard the old mirror, then this
		# client becomes authority. Other shared modes still reject duplicates.
		if _mirror_mode == "roam":
			mirror_off()
		else:
			return
	if _apparition_mode != "":
		_end_apparition()   # the real thing is coming; drop the hallucination
	if _mode == "roam":
		_end_roam()
	if _mode != "idle":
		if _queued_remote_scare == "" or kind == "jump":
			_queued_remote_scare = kind
			_queued_remote_scare_expires = _now() + 30.0
			_queued_remote_scare_retry_at = _now()
		return
	if kind == "chase":
		if bool(data.get("handoff", false)):
			_begin_handoff_chase(
				Vector3(float(data.get("x", 0.0)), 0.0, float(data.get("z", 0.0))),
				float(data.get("ry", 0.0)))
		else:
			_begin_chase()
	else:
		_start_personal_scare(kind, _now())

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
		_spawn_apparition(corner["hide"])
		if _apparition:
			_face_player(_apparition)
			var peek_dir: Vector3 = (corner["out"] - corner["hide"]).normalized()
			var right: Vector3 = _apparition.global_transform.basis.x
			# CX36 — lead with the shoulder on the side it actually leans towards.
			var leans_left := right.dot(peek_dir) < 0.0
			_peek_clip = ""
			if _using_new_entity:
				var wanted := "peek_left" if leans_left else "peek_right"
				_play_apparition_anim(wanted)
				# The procedural head/neck override only builds the peek when
				# there is no authored clip, otherwise the two fight each other.
				_peek_authored = _app_anim != null and _app_anim.has_animation(wanted)
				if _peek_authored:
					_peek_clip = wanted
					_app_anim.speed_scale = 1.0
			else:
				_peek_authored = false
				_play_apparition_anim("lean_left" if leans_left else "lean_right")
			_set_apparition_alpha(0.0)  # Start invisible — only the head peek reveals it
		_peek_corner = true
		_peek_from = corner["hide"]
		_peek_to = corner["out"]
		_lean = 0.0
		_lean_dir = 1.0
		_apparition_mode = "peek"
		_peek_recede = false
		_peek_witnessed = false
		_peek_loop_count = 0
		_peek_wait_timer = 0.0
		_stare_timer = -1.0
		_peek_elapsed = 0.0
		# most watchers hold your gaze a beat before slipping away;
		# some are gone the instant your eyes land on them
		_peek_style = "stealth"
		_peek_timer = _rng.randf_range(Tuning.PEEK_HOLD_MIN, Tuning.PEEK_HOLD_MAX)
		_wire_peek_skeleton()
		return
	# No arbitrary-wall fallback: if there is no genuine free wall end, wait
	# and try again instead of risking a figure intersecting a solid wall.
	_next_peek = _now() + 2.0
	if _mp and _local_targetable:
		_queued_remote_scare = "peek"
		_queued_remote_scare_retry_at = _now() + 2.0
		if _queued_remote_scare_expires <= _now():
			_queued_remote_scare_expires = _now() + 14.0


func _peek_head_height() -> float:
	return NEW_ENTITY_PEEK_HEAD_HEIGHT if _using_new_entity \
		else LEGACY_PEEK_HEAD_HEIGHT


func _is_behind_or_side_player(pos: Vector3) -> bool:
	if not is_instance_valid(_player):
		return true
	var eye := _camera.global_position if is_instance_valid(_camera) else _player.global_position
	var fwd := -_camera.global_transform.basis.z if is_instance_valid(_camera) else -_player.global_transform.basis.z
	var dir := (pos - eye).normalized()
	return fwd.dot(dir) < 0.35  # Behind or side/rear of camera view


## Pick a wall-end corner where cover geometry really works from the player's
## point of view: leaning out is visible, hiding is not. Prioritizes corners BEHIND or to the side/rear of player.
func _find_peek_corner() -> Dictionary:
	if _maze == null or not _maze.has_method("peek_corners") or not is_instance_valid(_player):
		return {}
	var eye: Vector3 = _camera.global_position if is_instance_valid(_camera) else (_player.global_position + Vector3.UP * 1.6)
	var cands: Array = _maze.peek_corners(_player.global_position, Tuning.PEEK_DIST_MIN, Tuning.PEEK_DIST_MAX)
	cands.shuffle()
	var head_height := _peek_head_height()
	
	# First pass: try corners BEHIND / REAR-SIDE of player camera (paranoia watcher)
	for cand in cands:
		var out_head: Vector3 = cand["out"] + Vector3.UP * head_height
		var hide_head: Vector3 = cand["hide"] + Vector3.UP * head_height
		if not _is_behind_or_side_player(out_head):
			continue
		if not _apparition_lean_clear(cand["hide"], cand["out"]):
			continue
		if not _ray_clear(eye, out_head):
			continue
		if _ray_clear(eye, hide_head):
			continue
		return cand

	# Fallback pass: any valid corner in maze
	for cand in cands:
		var out_head: Vector3 = cand["out"] + Vector3.UP * head_height
		var hide_head: Vector3 = cand["hide"] + Vector3.UP * head_height
		if not _apparition_lean_clear(cand["hide"], cand["out"]):
			continue
		if not _ray_clear(eye, out_head):
			continue
		if _ray_clear(eye, hide_head):
			continue
		return cand
	return {}

func _dread_scaled_peek_gap() -> float:
	var t := 0.0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
	var run_phase := clampf(t / Tuning.FINAL_PHASE_TIME, 0.0, 1.0)
	var base_gap := lerpf(Tuning.PEEK_GAP_EARLY, Tuning.PEEK_GAP_LATE, run_phase)
	var menace_scale := lerpf(1.0, 0.7, _menace)
	var recovery_scale := 1.0 + _stress * 0.35
	var gap := base_gap * menace_scale * recovery_scale * _rng.randf_range(0.85, 1.25)
	return t + maxf(11.0, gap)

func _tick_peek(delta: float) -> void:
	if not is_instance_valid(_apparition):
		_end_apparition()
		return
	_peek_timer -= delta
	_peek_elapsed += delta
	if _peek_elapsed >= Tuning.PEEK_HARD_TIMEOUT:
		_end_apparition()
		return

	var flat := _apparition.global_position - _player.global_position
	flat.y = 0.0
	if flat.length() <= Tuning.PEEK_VANISH_DIST:
		_end_apparition()
		return
	
	var looked := _player_looking_at(_apparition, 0.40) or _in_view(_apparition)
	var visible_now := _in_view(_apparition) and _has_los(_apparition)
	if visible_now:
		_peek_witnessed = true

	# Near but unseen → muffle
	var prox := flat.length() < Tuning.PEEK_MUFFLE_DIST and not visible_now
	if prox != _prox_muffle:
		_prox_muffle = prox
		muffle.emit(prox)

	# CX36 — the flicker stays (it is light, not voice) but the buzz is gone. A
	# peek is meant to be 100% silent: the whole point is that you are not warned,
	# you just notice it. Any sound gives the position away before the eyes do.
	if flat.length() < 12.0:
		request_flicker.emit(0.14)
	else:
		request_flicker.emit(0.0)

	# 100% SILENT UNCANNY PEEKING — No screech on gaze, pure psychological dread!
	# When player turns and makes eye contact: entity locks gaze for 0.45s before receding behind wall!
	if (visible_now or looked) and not _peek_recede:
		if _stare_timer < 0.0:
			_stare_timer = 0.48  # Uncanny eye-contact stare hold duration
			_add_stress(0.18)
			request_dread.emit(0.45) # Surge dread vignette when eye contact lands
			request_flicker.emit(0.18)
		if _stare_timer > 0.0:
			_stare_timer = maxf(0.0, _stare_timer - delta)
		if _stare_timer <= 0.0:
			_peek_recede = true
			_lean_dir = -1.0

	if _peek_corner:
		if not _peek_recede:
			# Leans out smoothly around corner (0.4s) - only half body / head & shoulder exposed
			_lean = clampf(_lean + _lean_dir * delta / 0.4, 0.0, 1.0)
			_apparition.global_position = _peek_from.lerp(_peek_to, _lean * 0.46)
			_face_player(_apparition)
			_set_apparition_alpha(clampf(_lean * 2.5, 0.0, 1.0))
		
		# Auto-recede after hold timer runs out
		if _peek_timer <= 0.0 and not _peek_recede:
			_peek_recede = true
			_lean_dir = -1.0

	if _peek_recede:
		if _peek_corner:
			_lean_dir = -1.0
			# Smooth stealthy duck back behind wall corner (0.32s)
			_lean = clampf(_lean + _lean_dir * delta / 0.32, 0.0, 1.0)
			_apparition.global_position = _peek_from.lerp(_peek_to, _lean * 0.46)
			_face_player(_apparition)
			# Stay visible while pulling back behind cover, then vanish
			var alpha_val := 1.0 if _lean > 0.08 else 0.0
			_set_apparition_alpha(alpha_val)
			
			if _lean <= 0.0:
				_end_apparition()
				return
		else:
			# Sprint backward very fast and fade
			var away: Vector3 = (_apparition.global_position - _player.global_position)
			away.y = 0
			if away.length() > 0.01:
				away = away.normalized()
				_apparition.global_position += away * 15.0 * delta
				_play_apparition_anim("ual1_Sprint")
			_fade_apparition(delta, 8.0)
			if not visible_now or _apparition_alpha() <= 0.02:
				_end_apparition()
				return
	else:
		_face_player(_apparition)

	if _peek_timer <= 0.0 and not _peek_corner:
		_end_apparition()
	elif _peek_timer <= -0.45:
		_end_apparition()
	# (bone poses are applied via skeleton_updated — post-animation — not here)

# CX36 — the peek/shadow sound emitters are gone. `_stare_breath()` and
# `_peek_reaction_sound()` already had no call sites (dead since the "100% SILENT
# UNCANNY PEEKING" pass), and `_proximity_buzz()` was the sound that was still
# actually playing. Apparitions are silent by design; only the light reacts.

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
	_spawn_apparition(spot["out"])
	if _apparition == null:
		_next_shadow = _now() + _rng.randf_range(20.0, 40.0)
		return
	_face_player(_apparition)
	_play_apparition_anim("ual1_Idle")
	_peek_from = spot["hide"]
	_peek_to = spot["out"]
	_lean = 1.0
	_apparition_mode = "shadow"
	_shadow_state = "watch"
	_shadow_hold = 0.0
	_shadow_timer = 0.0
	_shadow_reveals = 0
	_shadow_max_reveals = _rng.randi_range(2, 4)

func _tick_shadow(delta: float) -> void:
	if not is_instance_valid(_apparition):
		_end_apparition()
		return
	_shadow_timer += delta
	var flat := _apparition.global_position - _player.global_position
	flat.y = 0.0
	var dist := flat.length()
	if dist < Tuning.PEEK_VANISH_DIST:
		_end_apparition()   # hunted down — nothing there
		return
	if _shadow_timer > Tuning.SHADOW_MAX_TIME:
		_end_apparition()   # it never outstays; absence is also dread
		return
	# CX36 — flicker only. "Silence IS the tell" for the tail as well.
	if dist < 12.0:
		request_flicker.emit(0.12)
	else:
		request_flicker.emit(0.0)
	match _shadow_state:
		"watch":
			# exposed at the corner, motionless, eyes on your back
			_face_player(_apparition)
			if _in_view(_apparition) and _has_los(_apparition):
				_shadow_state = "hold"
				_shadow_hold = Tuning.SHADOW_REVEAL_HOLD
				_shadow_reveals += 1
				_add_stress(0.08)
			elif dist > 16.0:
				_relocate_shadow()   # keep the tail close while unseen
		"hold":
			# your eyes found it. It lets you KNOW you were being watched…
			_face_player(_apparition)
			_shadow_hold -= delta
			if _shadow_hold <= 0.0:
				_shadow_state = "hiding"
		"hiding":
			# …then slips behind the wall, quick as a caught thief.
			_lean = maxf(0.0, _lean - delta / 0.22)
			var k := _lean * _lean * (3.0 - 2.0 * _lean)
			_apparition.global_position = _peek_from.lerp(_peek_to, k)
			if _lean <= 0.0:
				if _shadow_reveals >= _shadow_max_reveals:
					_end_apparition()   # this time it does not come back
					return
				_shadow_state = "hidden"
				_shadow_wait = 0.6
		"hidden":
			# behind cover, waiting for your gaze to move off the corner
			var out_head := _peek_to + Vector3.UP * _peek_head_height()
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
	_apparition.global_position = spot["out"]
	_face_player(_apparition)
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
	var head_height := _peek_head_height()
	for cand in cands:
		var out_head: Vector3 = cand["out"] + Vector3.UP * head_height
		var hide_head: Vector3 = cand["hide"] + Vector3.UP * head_height
		# CX36 — same strict clearance as the peek; the tail steps out at corners
		# built by the newer map formations too.
		if not _apparition_lean_clear(cand["hide"], cand["out"]):
			continue
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
func _safe_jump_spawn_position(forward: Vector3) -> Vector3:
	var eye := _camera.global_position
	var max_distance := 2.5
	var hit := _ray_hit(eye, eye + forward * (max_distance + 0.35))
	if not hit.is_empty():
		max_distance = minf(
			max_distance, eye.distance_to(Vector3(hit["position"])) - 0.38)
	var distance := max_distance
	while distance >= 1.15:
		var candidate := _player.global_position + forward * distance
		candidate.y = 0.0
		# CX36 — the jumpscare fills the screen at arm's length, so any wall it
		# intersects is unmissable. Use the wide/tall apparition clearance.
		if _apparition_pose_clear(candidate):
			return candidate
		distance -= 0.2
	return Vector3.INF


func _begin_jump(t: float) -> void:
	# The new full-height Entity materializes in a physically clear camera lane,
	# strikes through the contact section of entity_attack, then is gone.
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)
	var fwd: Vector3 = -_camera.global_transform.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)
	var pos := _safe_jump_spawn_position(fwd)
	if pos == Vector3.INF:
		# A cramped corner is not permission to put the 2.7 m model through a
		# wall. Retry when the player's view has a safe full-body lane.
		_next_jump = t + 3.0
		return
	_spawn_apparition(pos)
	if _apparition:
		_face_player(_apparition)
		_set_apparition_alpha(1.0)
		if _using_new_entity and _app_anim != null \
				and _app_anim.has_animation("entity_attack"):
			_app_anim.speed_scale = 1.0
			_app_anim.play("entity_attack", 0.04)
			# Start shortly before authored frame-42 contact. The apparition
			# disappears exactly as the strike reaches the camera.
			_app_anim.seek(JUMP_ATTACK_SEEK_TIME, true)
		else:
			_play_apparition_anim("ual1_Idle")
		# Lunge toward the camera. The old sign was inverted and moved it away.
		var lunge_position := pos - fwd * 0.38
		if not _figure_pose_clear(lunge_position):
			lunge_position = pos
		var tw := create_tween()
		tw.tween_property(
			_apparition, "global_position", lunge_position,
			Tuning.JUMP_DURATION).set_trans(
				Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# mild zoom punch — frames the full body instead of tunneling into it
	if is_instance_valid(_camera):
		_jump_prev_fov = _camera.fov
		_camera.fov = 62.0
	_apparition_mode = "jump"
	jumpscare.emit()
	request_flicker.emit(0.75)
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
	_blind_hunt_time = 0.0
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
	request_flicker.emit(0.28)
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		# the howl arrives from the spawn direction, far and getting ready
		AudioManager.play_sfx_3d(self, _sfx["chase_scream"], spot + Vector3(0, 1.5, 0), -6.0, 45.0, 0.9)


## Continue the SAME roaming Entity on the remote player's authority. There is
## no second spawn search or wind-up: the body keeps its networked position and
## immediately reacts to the client it has just seen.
func _begin_handoff_chase(spot: Vector3, initial_yaw: float) -> void:
	_mode = "chase"
	_chase_state = "pursue"
	_chase_time = 0.0
	_blind_hunt_time = 0.0
	_chase_path = []
	_path_timer = 0.0
	_path_fail = 0.0
	_chase_done += 1
	chase_started.emit()
	var overlay := _get_overlay()
	if is_instance_valid(overlay) and overlay.has_method("set_chase_vignette"):
		overlay.set_chase_vignette(true)
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)
	_spawn_figure(spot, false)
	if not is_instance_valid(_figure):
		_end_chase(false)
		return
	_figure.rotation.y = initial_yaw
	_set_figure_alpha(1.0)
	_play_anim("run")
	_last_seen_pos = _player.global_position
	_has_seen_player_this_chase = true
	_stumble_timer = _rng.randf_range(3.8, 5.2)
	_stumble_duration = 0.0
	_chase_speed_mult = 1.0
	request_flicker.emit(0.65)
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("chase")
		if _sfx.has("chase_scream"):
			AudioManager.play_sfx(_sfx["chase_scream"], -2.0)
	_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)


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
	_play_anim("run")
	_chase_state = "pursue"
	_last_seen_pos = _player.global_position
	_has_seen_player_this_chase = false
	_stumble_timer = _rng.randf_range(3.8, 5.2)
	_stumble_duration = 0.0
	_chase_speed_mult = 1.0
	request_flicker.emit(0.65)
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		AudioManager.play_sfx(_sfx["chase_scream"], -2.0)
	# Looping positional layers ride on the figure: distance IS the mix.
	_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)

func _find_chase_spawn() -> Vector3:
	# NEVER materialize in plain sight — that reads as a cheap teleport. The
	# spot must be off-screen or occluded AND have a real corridor route to
	# the player, so the entity charges INTO view: heard first, then seen.
	var eye: Vector3 = _camera.global_position
	var pcell: Vector2i = _cell_of(_player.global_position)
	for _i in range(48):
		var ang := _rng.randf() * TAU
		var dist := _rng.randf_range(Tuning.CHASE_SPAWN_MIN, Tuning.CHASE_SPAWN_MAX)
		var p: Vector3 = _player.global_position + Vector3(cos(ang), 0, sin(ang)) * dist
		p.y = 0.0
		var head := p + Vector3(0, 1.5, 0)
		if _in_view_point(head) and _ray_clear(eye, head):
			continue  # the player would watch it pop into existence
		if _maze and _maze.has_method("corridor_path"):
			var route: Array = _maze.corridor_path(_cell_of(p), pcell)
			if route.size() < 2 or route.size() > 12:
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
		request_flicker.emit(0.28)
		if _windup_timer <= 0.0:
			_launch_chase()
		return
	if not is_instance_valid(_figure):
		_end_chase(false)
		return
	if _is_stumbling:
		_wet_floor_stumble_timer -= delta
		if _wet_floor_stumble_timer <= 0.0:
			_is_stumbling = false
		return

	# Check wet floor hazard slip during sprint chase
	for area in get_tree().get_nodes_in_group("wet_floor"):
		if is_instance_valid(area) and area.global_position.distance_to(_figure.global_position) < 2.4:
			slip_and_stumble(2.0)
			if _mp:
				NetManager.send("entity_slip", {"x": _figure.global_position.x, "y": _figure.global_position.y, "z": _figure.global_position.z})
			return

	_chase_time += delta
	var to: Vector3 = _player.global_position - _figure.global_position
	to.y = 0
	var d := to.length()
	if d <= maxf(CATCH_DIST, 2.4):
		_do_caught()
		return

	# Dynamic claustrophobic FOV tunnel vision during chase
	if is_instance_valid(_camera):
		_camera.fov = lerpf(_camera.fov, 58.0, 4.0 * delta)

	# Its eyes own perception: frontal cone plus an unobstructed eye-to-player ray.
	# A player behind it is memory/noise only, never supernatural LOS.
	_fig_sees = _entity_can_see_position(_camera.global_position)
	# CX35 — chase perception had NO distance limit, so a straight corridor let it
	# re-acquire from anywhere, resetting the memory point and the blind timer and
	# making the chase unbreakable.
	if d > Tuning.CHASE_SIGHT_RANGE:
		_fig_sees = false
	# Crouching stealth: a low, small target is much harder to track at range —
	# beyond 7 m a crouched player slips out of its perception entirely.
	var crouched: bool = bool(_player.is_crouching) if is_instance_valid(_player) and "is_crouching" in _player else false
	if _fig_sees and crouched and d > 7.0:
		_fig_sees = false
	# Locker mechanic: breathing is hearing, not sight. It updates the last heard
	# location but never grants vision through the door or behind the Entity.
	var heard_breath := _breathing_gives_away(d)
	if heard_breath:
		_last_seen_pos = _player.global_position
		if _chase_state == "search":
			_chase_state = "pursue"
			_search_timer = 0.0
	if _fig_sees:
		_last_seen_pos = _player.global_position
		_has_seen_player_this_chase = true

	# --- phase: search (it lost you; it stands where you were, listening) ---
	if _chase_state == "search":
		_search_timer -= delta
		request_flicker.emit(0.18)
		if _fig_sees and d < 14.0:
			# found you again — the sting, the steps, the sprint
			_chase_state = "pursue"
			_play_anim("ual1_Sprint")
			if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
				AudioManager.play_sfx(_sfx["chase_scream"], -3.0, 1.05)
			_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)
			_add_stress(0.15)
		elif _search_timer <= 0.0:
			# CX33 — it no longer dissolves here. It goes confused: still standing
			# in the corridor, still a threat, for CONFUSED_DURATION.
			_begin_confused()
		return

	# --- phase: pursue ---
	# Handle stumbling/lunging states
	if _stumble_duration > 0.0:
		_stumble_duration -= delta
		_chase_speed_mult = 0.55
		
		# Tilt torso forward and dip down
		if _figure.get_child_count() > 0:
			var model_node = _figure.get_child(0)
			model_node.rotation.x = lerpf(model_node.rotation.x, 0.58, 12.0 * delta)
			model_node.position.y = lerpf(model_node.position.y, -0.42, 12.0 * delta)
		
		if _stumble_duration <= 0.0:
			_stumble_timer = _rng.randf_range(4.2, 6.2)
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
			_stumble_duration = 0.28
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
			# CX33 — the howl recedes instead of being cut dead; the steps still
			# stop instantly, which is what makes the silence land.
			_fade_out_chase_audio()
			return

	# CX35 — this IS the escape. You cannot outrun 7.2 m/s, so staying out of its
	# eyes is the only way out. It keeps hunting your last known position while
	# this runs (CX33b's requirement); reaching that spot first hands over to
	# `search`, and either path ends in `confused` -> roam.
	if _fig_sees:
		_blind_hunt_time = maxf(
			0.0, _blind_hunt_time - delta * Tuning.CHASE_REACQUIRE_DECAY)
	else:
		_blind_hunt_time += delta
		if _blind_hunt_time >= Tuning.CHASE_BLIND_GIVE_UP:
			_begin_confused()
			return
	request_flicker.emit(0.48)

# ---------------------------------------------------------------------------
# CONFUSED — it lost you mid-chase and has not given up yet
# ---------------------------------------------------------------------------

## CX33 — replaces the old "instant dissolve" when a chase is broken. The body
## stays exactly where it is, the howl fades, and it spends
## `Tuning.CONFUSED_DURATION` looking around. Nothing is despawned, so hiding
## behind a wall two metres away no longer makes it blink out of existence — you
## have to stay in cover until it gives up and walks off.
func _begin_confused() -> void:
	if not is_instance_valid(_figure):
		_end_chase(true)
		return
	_fade_out_chase_audio()
	_mode = "confused"
	_confused_timer = Tuning.CONFUSED_DURATION
	_chase_state = "pursue"
	_blind_hunt_time = 0.0
	_fig_sees = false
	_play_anim("confused")
	chase_ended.emit()
	request_flicker.emit(0.0)
	request_dread.emit(0.45)   # still close, still wrong — just not hunting
	var overlay := _get_overlay()
	if is_instance_valid(overlay) and overlay.has_method("set_chase_vignette"):
		overlay.set_chase_vignette(false)
	if is_instance_valid(_camera):
		_camera.fov = 72.0
	if has_node("/root/AudioManager"):
		# Elevated, not panicking: it is still there, it just cannot see you.
		AudioManager.set_heartbeat_state("peek")
	if _prox_muffle:
		_prox_muffle = false
		muffle.emit(false)


func _tick_confused(delta: float) -> void:
	if not is_instance_valid(_figure):
		_mode = "idle"
		_roam_cooldown = 0.0
		return
	_confused_timer -= delta
	var to: Vector3 = _player.global_position - _figure.global_position
	to.y = 0.0
	var distance := to.length()
	if distance <= CATCH_DIST:
		_do_caught()
		return
	# Re-acquisition uses the same frontal eyes as everything else: stepping out
	# of cover inside the window puts it straight back on you.
	if _local_targetable and distance <= Tuning.CONFUSED_REACQUIRE_RANGE \
			and _entity_can_see_position(_camera.global_position):
		_resume_chase_from_confused()
		return
	if _confused_timer <= 0.0:
		_roam_with_current_figure()


## Straight back into the pursuit with the body already standing there — no
## wind-up, no respawn. It knows where you are now.
func _resume_chase_from_confused() -> void:
	_mode = "chase"
	_chase_state = "pursue"
	_blind_hunt_time = 0.0
	_search_timer = 0.0
	_last_seen_pos = _player.global_position
	_has_seen_player_this_chase = true
	_stumble_timer = _rng.randf_range(3.8, 5.2)
	_stumble_duration = 0.0
	_chase_speed_mult = 1.0
	_play_anim("ual1_Sprint")
	_face_player(_figure)
	chase_started.emit()
	request_flicker.emit(0.65)
	var overlay := _get_overlay()
	if is_instance_valid(overlay) and overlay.has_method("set_chase_vignette"):
		overlay.set_chase_vignette(true)
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("chase")
		if _sfx.has("chase_scream"):
			AudioManager.play_sfx(_sfx["chase_scream"], -3.0, 1.05)
	_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)
	_add_stress(0.15)


## Give up and wander off with the body that is already there. `_begin_roam()`
## would despawn and respawn it in a random cell, which reads as a teleport to a
## player hiding a few metres away — the exact thing this state exists to avoid.
func _roam_with_current_figure() -> void:
	if not is_instance_valid(_figure) or _maze == null:
		_mode = "idle"
		_roam_cooldown = 0.0
		return
	# CX34 — the shared Entity belongs to the HOST. A client only borrows it for
	# a delegated chase; when that chase dies it must hand the body back, or the
	# host can never move it again and the whole lobby stops getting scares.
	if _mp and not _mp_host:
		_end_roam()
		return
	_mode = "roam"
	_fleeing = false
	_investigating_callout = false
	_chase_state = "pursue"
	_confused_timer = 0.0
	_set_figure_alpha(1.0)
	_play_anim("walk")
	_pick_random_roam_leg()
	if _roam_path.size() >= 2:
		_face_target(_figure, _maze.world_center(_roam_path[1]))
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("silent")
	request_dread.emit(0.2)
	# The chase is genuinely over only now, so the pacing bookkeeping that used
	# to live in _end_chase() happens here instead of the moment cover was found.
	_add_stress(0.55)
	var t := _now()
	_next_chase = t + _rng.randf_range(60.0, 140.0) \
		* (1.0 + _stress) * lerpf(1.0, 0.55, _menace)
	_next_peek = maxf(_next_peek, t + 20.0)


func _stop_chase_loops() -> void:
	if is_instance_valid(_chase_steps):
		_chase_steps.queue_free()
	if is_instance_valid(_chase_scream):
		_chase_scream.queue_free()
	_chase_steps = null
	_chase_scream = null
	_stop_chase_scream()


## CX32 — the looping layers ride on the figure/mirror and die with them, but the
## opening sting is a pooled 2D one-shot and the wind-up howl is parented to this
## director. Neither was ever stopped. With the old 7 s take that went unnoticed;
## the new 28 s scream kept the corridor screaming long after the entity was gone.
func _stop_chase_scream() -> void:
	if not _sfx.has("chase_scream"):
		return
	var stream: AudioStream = _sfx["chase_scream"]
	if has_node("/root/AudioManager"):
		AudioManager.stop_sfx(stream)
	for child in get_children():
		var player := child as AudioStreamPlayer3D
		if player != null and player.stream == stream:
			player.stop()
			player.queue_free()


## CX33 — the same teardown, but heard. Losing the chase is now something the
## player hears happening (the howl receding) instead of an abrupt cut, and the
## fade covers the blend from the sprint into the confused pose.
func _fade_out_chase_audio(duration: float = Tuning.CHASE_AUDIO_FADE) -> void:
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		AudioManager.fade_out_sfx(_sfx["chase_scream"], duration)
	_fade_and_free_player(_chase_scream, duration)
	_fade_and_free_player(_chase_steps, duration)
	_chase_scream = null
	_chase_steps = null
	if not _sfx.has("chase_scream"):
		return
	# Positional wind-up howls hang off the director, not the figure.
	var stream: AudioStream = _sfx["chase_scream"]
	for child in get_children():
		var player := child as AudioStreamPlayer3D
		if player != null and player.stream == stream:
			_fade_and_free_player(player, duration)


func _fade_and_free_player(player: Node, duration: float) -> void:
	if not is_instance_valid(player):
		return
	var tween := create_tween()
	tween.tween_property(player, "volume_db", -60.0, maxf(duration, 0.05))
	tween.tween_callback(func() -> void:
		if is_instance_valid(player):
			player.queue_free())

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
	var direct_lane := _figure_lane_clear(_figure.global_position, goal)
	if direct_lane:
		# In an open room or straight corridor, chase the actual last-known point.
		# BFS cell centres are only a fallback for corners and blocked passages.
		_path_fail = 0.0
	elif _chase_path.size() >= 2:
		_path_fail = 0.0
		target = _maze.world_center(_chase_path[1])
		# path cell reached → advance
		var flat := target - _figure.global_position
		flat.y = 0
		if flat.length() < 0.5:
			_chase_path.pop_front()
			if _chase_path.size() >= 2:
				target = _maze.world_center(_chase_path[1])
		# Skip intermediate grid centres whenever the full entity has a safe,
		# unobstructed lane to a later waypoint.
		var furthest_lookahead := mini(_chase_path.size() - 1, 8)
		for path_index in range(furthest_lookahead, 0, -1):
			var candidate: Vector3 = _maze.world_center(_chase_path[path_index])
			if _figure_lane_clear(_figure.global_position, candidate):
				target = candidate
				break
	elif _chase_path.size() == 1:
		# Same cell can still contain a collidable prop or thin divider.
		_path_fail = 0.0
		target = goal if direct_lane else _figure.global_position
	else:
		# no route (sealed pocket): give it a few seconds, then let it dissolve
		_path_fail += delta
		if _path_fail > Tuning.CHASE_NO_ROUTE_TIMEOUT:
			_end_chase(true)
			return
	# Speed has moods: a burst from afar, a fraction of mercy up close (the
	# almost-caught margin players remember), and mounting urgency over time.
	# Speed rises gently with every SNUS grabbed: 4.15m/s base up to 4.85m/s at 5 tins!
	# Because the entity stumbles every ~2.5s, smart cornering ALWAYS allows escape.
	var base_spd := CHASE_SPEED + (_menace * 0.70)
	var speed := base_spd * _chase_speed_mult * _rule_speed_mult
	if dist_to_player > 8.0:
		speed *= 1.08
	elif dist_to_player < 3.0:
		speed *= 0.92
	speed += minf(_chase_time * 0.008, 0.12)
	_sync_entity_locomotion_speed("run", speed)
	speed *= _entity_stride_multiplier("run")
	var step_dir: Vector3 = target - _figure.global_position
	step_dir.y = 0
	if step_dir.length() > 0.01:
		var move_dist := speed * delta
		var wish_dir := step_dir.normalized()
		var next_pos := _figure.global_position + wish_dir * move_dist

		# Physics-safe wall collision check: if next step hits environment walls, try sliding along axes
		if not _figure_pose_clear(next_pos):
			var try_x := _figure.global_position + Vector3(wish_dir.x, 0, 0) * move_dist
			var try_z := _figure.global_position + Vector3(0, 0, wish_dir.z) * move_dist
			if _figure_pose_clear(try_x):
				next_pos = try_x
			elif _figure_pose_clear(try_z):
				next_pos = try_z
			else:
				next_pos = _figure.global_position # halt at wall surface

		_figure.global_position = next_pos
		# CX36 — turn at a bounded rate instead of snapping the yaw.
		if _fig_sees and dist_to_player < 4.0:
			_turn_towards(_figure, _player.global_position, delta,
				Tuning.ENTITY_TURN_RATE_CHASE)
		else:
			_turn_towards(_figure, _figure.global_position + step_dir, delta,
				Tuning.ENTITY_TURN_RATE_CHASE)

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
	# The sting and the wind-up howl are not children of the figure, so the cut
	# above never reached them. "Vanishes → total silence" depends on this.
	_stop_chase_scream()
	_mode = "idle"
	_roam_cooldown = 0.0
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
	if _ended or not _local_targetable or _catch_in_progress:
		return
	if is_instance_valid(_player) and _player.has_meta("is_hiding") and _player.get_meta("is_hiding"):
		return
	_catch_in_progress = true
	_victim_jumpscare_playing = false
	# CX36 — the chase howl is attached to the figure, which survives the catch to
	# perform the execution, so it used to keep playing right through the
	# jumpscare video. Fade it out so the clip's own audio owns the moment.
	_fade_out_chase_audio(CATCH_AUDIO_FADE)
	if has_node("/root/AudioManager"):
		AudioManager.set_heartbeat_state("silent")
	if is_instance_valid(_player) and _player.has_method("set_frozen"):
		_player.set_frozen(true, false)

	# In co-op, the entity catches one player then retreats — it doesn't end.
	var is_coop := _mp and _world != null

	if not is_coop:
		_ended = true

	# CX30 — _do_caught only ever runs on the caught client, so this hands the
	# victim's own screen over to the fullscreen clip while the paired 3D
	# animation below keeps running for everyone else. Nothing is broadcast.
	victim_jumpscare.emit(
		NetManager.local_player_id if has_node("/root/NetManager") else 0)

	request_flicker.emit(0.0)
	request_dread.emit(1.0)
	# The last thing you see: its face, one breath from yours — THEN black.
	if is_instance_valid(_figure) and is_instance_valid(_camera):
		var fwd: Vector3 = -_camera.global_transform.basis.z
		fwd.y = 0
		if fwd.length() > 0.01:
			fwd = fwd.normalized()
			var pos: Vector3 = _player.global_position + fwd * EXECUTION_START_DISTANCE
			pos.y = 0.0
			_figure.global_position = pos
			_face_player(_figure)
	_begin_execution_camera()
	# The clip carries its own scream; playing this one on top would double it.
	# When the video is missing, the original catch scream still fires.
	if has_node("/root/AudioManager") and _sfx.has("jump") \
			and not _victim_jumpscare_playing:
		AudioManager.play_sfx(_sfx["jump"], 6.0, 0.92)
	# Movement stays locked for the entire paired execution. The coroutine emits
	# caught only after player_eaten_death; GameWorld then enters downed/crawl.
	_start_execution_after_camera_move(is_coop)


func _start_execution_after_camera_move(is_coop: bool) -> void:
	await get_tree().create_timer(EXECUTION_CAMERA_LEAD_IN).timeout
	if not is_instance_valid(self) or not _catch_in_progress:
		return
	if is_instance_valid(_player) and _player.has_method("set_first_person_body_visible"):
		_player.set_first_person_body_visible(false)
	_run_execution_sequence(is_coop)


func _begin_execution_camera() -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_camera):
		return
	_execution_camera_phase = "attack"
	# The caught player never leaves first-person. This is also the clean handoff
	# point for the future jumpscare overlay; the teammate still watches the
	# replicated paired animation in-world.
	_execution_camera_active = false
	_camera.near = 0.05


func _execution_camera_clearance(side: float, lateral: bool) -> float:
	var frame := _execution_camera_frame(side, lateral)
	var focus: Vector3 = frame["focus"]
	var desired: Vector3 = frame["position"]
	var hit := _ray_hit(focus, desired)
	if hit.is_empty():
		return focus.distance_to(desired)
	return focus.distance_to(Vector3(hit["position"]))


func _execution_camera_frame(side: float, lateral: bool = false) -> Dictionary:
	var forward := -_player.global_transform.basis.z
	var right := _player.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.001 else Vector3.FORWARD
	right = right.normalized() if right.length_squared() > 0.001 else Vector3.RIGHT
	var focus := _player.global_position + Vector3.UP * 0.95 + forward * 0.42
	var desired := _player.global_position - forward * 2.35 \
		+ right * side * 1.35 + Vector3.UP * 1.48
	var target_fov := 61.0
	match _execution_camera_phase:
		"eat_start":
			focus = _player.global_position + Vector3.UP * 0.70 + forward * 0.20
			desired = _player.global_position - forward * 2.45 \
				+ right * side * 1.48 + Vector3.UP * 1.34
			target_fov = 60.0
		"eat_loop":
			focus = _player.global_position + Vector3.UP * 0.55 + forward * 0.14
			desired = _player.global_position - forward * 2.62 \
				+ right * side * 1.42 + Vector3.UP * 1.22
			target_fov = 59.0
		"eat_end":
			focus = _player.global_position + Vector3.UP * 0.43 + forward * 0.10
			desired = _player.global_position - forward * 2.78 \
				+ right * side * 1.24 + Vector3.UP * 1.10
			target_fov = 57.0
	if lateral:
		var lateral_height := 1.40
		var lateral_back := 0.48
		var lateral_distance := 2.28
		if _execution_camera_phase == "eat_loop":
			lateral_height = 1.18
			lateral_back = 0.62
			lateral_distance = 2.42
		elif _execution_camera_phase == "eat_end":
			lateral_height = 1.06
			lateral_back = 0.72
			lateral_distance = 2.48
		desired = _player.global_position - forward * lateral_back \
			+ right * side * lateral_distance + Vector3.UP * lateral_height
	return {"focus": focus, "position": desired, "fov": target_fov}


func _tick_execution_camera(delta: float) -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_camera):
		_execution_camera_active = false
		return
	var frame := _execution_camera_frame(
		_execution_camera_side, _execution_camera_lateral)
	var focus: Vector3 = frame["focus"]
	var desired: Vector3 = frame["position"]
	# Walls and procedural props with environment collision pull the camera in.
	var hit := _ray_hit(focus, desired)
	if not hit.is_empty():
		var ray_direction := (desired - focus).normalized()
		var hit_distance := focus.distance_to(Vector3(hit["position"]))
		desired = focus + ray_direction * maxf(hit_distance - 0.20, 0.08)
	var desired_basis := Transform3D().looking_at(focus - desired, Vector3.UP).basis
	var desired_transform := Transform3D(desired_basis, desired)
	var smooth := 1.0 - exp(-10.5 * delta)
	_camera.global_transform = _camera.global_transform.interpolate_with(
		desired_transform, smooth)
	_camera.fov = lerpf(_camera.fov, float(frame["fov"]), 1.0 - exp(-7.0 * delta))


func _entity_clip_length(clip_name: String, fallback: float) -> float:
	if _fig_anim != null and _fig_anim.has_animation(clip_name):
		return maxf(_fig_anim.get_animation(clip_name).length, 0.05)
	return fallback


func _player_clip_length(clip_name: String, fallback: float) -> float:
	if is_instance_valid(_player) and _player.has_method("animation_clip_length"):
		return maxf(float(_player.animation_clip_length(clip_name)), 0.05)
	return fallback


func _execution_duration(source_duration: float) -> float:
	return source_duration / EXECUTION_PLAYBACK_SPEED


func _play_entity_execution(clip_name: String) -> void:
	_replicated_execution_clip = clip_name
	if clip_name in ["entity_attack", "entity_eat_start", "entity_eat_loop", "entity_eat_end"]:
		_execution_camera_phase = clip_name.trim_prefix("entity_")
	if _fig_anim != null and _fig_anim.has_animation(clip_name):
		_fig_anim.speed_scale = EXECUTION_PLAYBACK_SPEED
		_fig_anim.play(clip_name, ModelUtils.animation_blend_time(
			_fig_anim.current_animation, clip_name))
	elif _mirror_anim != null and _mirror_anim.has_animation(clip_name):
		_mirror_anim.speed_scale = EXECUTION_PLAYBACK_SPEED
		_mirror_anim.play(clip_name, ModelUtils.animation_blend_time(
			_mirror_anim.current_animation, clip_name))
	if _mp and _world != null:
		_world.net_send("entity_execution", {
			"clip": clip_name,
			"speed": EXECUTION_PLAYBACK_SPEED,
		})


func play_network_execution_clip(
		clip_name: String, playback_speed: float = EXECUTION_PLAYBACK_SPEED) -> void:
	_replicated_execution_clip = clip_name
	if clip_name == "":
		if is_instance_valid(_mirror_anim):
			_mirror_anim.speed_scale = 1.0
		if is_instance_valid(_fig_anim):
			_fig_anim.speed_scale = 1.0
		return
	var safe_speed := clampf(playback_speed, 0.1, 4.0)
	# Network phases belong to the replicated figure. Never animate an unrelated
	# local apparition (the source of the second Entity during executions).
	if _mirror_anim != null and _mirror_anim.has_animation(clip_name):
		_mirror_anim.speed_scale = safe_speed
		_mirror_anim.play(clip_name, ModelUtils.animation_blend_time(
			_mirror_anim.current_animation, clip_name))
	elif _mp_host and _mode == "stalk" and _fig_anim != null \
			and _fig_anim.has_animation(clip_name):
		# Special case: the host owns the single final stalker while a remote
		# victim drives their paired player clips.
		_fig_anim.speed_scale = safe_speed
		_fig_anim.play(clip_name, ModelUtils.animation_blend_time(
			_fig_anim.current_animation, clip_name))


func _play_player_execution(clip_name: String) -> void:
	if is_instance_valid(_player) and _player.has_method("play_execution_clip"):
		_player.play_execution_clip(clip_name, -1.0, EXECUTION_PLAYBACK_SPEED)
	if _mp and _world != null:
		_world.net_send("execution", {
			"clip": clip_name,
			"speed": EXECUTION_PLAYBACK_SPEED,
		})


func _active_execution_figure() -> Node3D:
	if is_instance_valid(_figure):
		return _figure
	if is_instance_valid(_mirror):
		return _mirror
	return null


func _move_execution_figure(position: Vector3, yaw: float) -> void:
	var actor := _active_execution_figure()
	if not is_instance_valid(actor):
		return
	var tween := create_tween().set_parallel(true)
	tween.tween_property(actor, "global_position", position, EXECUTION_EAT_ALIGN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(actor, "rotation:y", yaw, EXECUTION_EAT_ALIGN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


## Attack/hit starts face-to-face at 1.35 m. Once the victim is on the floor,
## move the Entity over the authored belly/hips position for the eating clips.
func _align_entity_over_victim() -> void:
	if not is_instance_valid(_player):
		return
	var forward := -_player.global_transform.basis.z
	var right := _player.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	if forward.length_squared() < 0.001 or right.length_squared() < 0.001:
		return
	forward = forward.normalized()
	right = right.normalized()
	var target := _player.global_position \
		+ forward * EXECUTION_EAT_FORWARD_DISTANCE \
		+ right * EXECUTION_EAT_LATERAL_OFFSET
	target.y = 0.0
	# Keep both authored actors on opposite forward axes. Looking at the player's
	# root from this laterally compensated position would yaw the Entity sideways
	# and move its animated head away from the victim's abdomen.
	var player_yaw := _player.global_transform.basis.get_euler().y
	var yaw := wrapf(player_yaw + PI, -PI, PI)
	_move_execution_figure(target, yaw)
	if _mp and _world != null:
		_world.net_send("entity_eat_align", {
			"x": target.x, "y": target.y, "z": target.z, "ry": yaw,
		})


func apply_network_eat_alignment(data: Dictionary) -> void:
	var target := Vector3(
		float(data.get("x", 0.0)),
		float(data.get("y", 0.0)),
		float(data.get("z", 0.0)))
	_move_execution_figure(target, float(data.get("ry", 0.0)))


func _run_execution_sequence(is_coop: bool) -> void:
	# Attack: both contacts were authored on source frame 42. player_hit imported
	# without its 17-frame pre-roll, so delay it by exactly those 17 frames.
	_play_entity_execution("entity_attack")
	var attack_player_delay := _execution_duration(ATTACK_PLAYER_DELAY)
	await get_tree().create_timer(attack_player_delay).timeout
	if not is_instance_valid(self):
		return
	_play_player_execution("player_hit")
	var attack_total := maxf(
		_execution_duration(_entity_clip_length("entity_attack", 82.0 / 30.0)),
		attack_player_delay + _execution_duration(
			_player_clip_length("player_hit", 64.0 / 30.0)))
	var attack_overlap := ModelUtils.animation_blend_time(
		"entity_attack", "entity_eat_start")
	await get_tree().create_timer(maxf(
		0.05, attack_total - attack_player_delay - attack_overlap)).timeout
	if not is_instance_valid(self):
		return

	_play_entity_execution("entity_eat_start")
	_play_player_execution("player_eaten_start")
	_align_entity_over_victim()
	var start_total := maxf(
		_execution_duration(_entity_clip_length(
			"entity_eat_start", 73.0 / 30.0)),
		_execution_duration(_player_clip_length(
			"player_eaten_start", 75.0 / 30.0)))
	var start_overlap := ModelUtils.animation_blend_time(
		"entity_eat_start", "entity_eat_loop")
	await get_tree().create_timer(maxf(0.05, start_total - start_overlap)).timeout
	if not is_instance_valid(self):
		return

	_play_entity_execution("entity_eat_loop")
	_play_player_execution("player_eaten_loop")
	var loop_total := maxf(
		_execution_duration(_entity_clip_length(
			"entity_eat_loop", 74.0 / 30.0)),
		_execution_duration(_player_clip_length(
			"player_eaten_loop", 74.0 / 30.0)))
	var loop_overlap := ModelUtils.animation_blend_time(
		"entity_eat_loop", "entity_eat_end")
	await get_tree().create_timer(maxf(0.05, loop_total - loop_overlap)).timeout
	if not is_instance_valid(self):
		return

	_play_entity_execution("entity_eat_end")
	_play_player_execution("player_eaten_death")
	var end_total := maxf(
		_execution_duration(_entity_clip_length(
			"entity_eat_end", 49.0 / 30.0)),
		_execution_duration(_player_clip_length(
			"player_eaten_death", 49.0 / 30.0)))
	await get_tree().create_timer(end_total).timeout
	if not is_instance_valid(self):
		return

	_replicated_execution_clip = ""
	_execution_camera_active = false
	if is_instance_valid(_fig_anim):
		_fig_anim.speed_scale = 1.0
	if is_instance_valid(_mirror_anim):
		_mirror_anim.speed_scale = 1.0
	if _mp and _world != null:
		_world.net_send("entity_execution", {"clip": ""})
	caught.emit()
	# In co-op the same physical entity sprints away after the victim becomes
	# downed, leaving the normal revive-pressure system in charge.
	if is_coop and not (_mp_host and _final_phase and _mode == "stalk"):
		_stop_chase_loops()
		request_flicker.emit(0.0)
		request_dread.emit(0.0)
		_flee_and_roam()
		var ov := _get_overlay()
		if is_instance_valid(ov) and ov.has_method("set_chase_vignette"):
			ov.set_chase_vignette(false)
		if is_instance_valid(_camera):
			_camera.fov = 72.0
		if has_node("/root/AudioManager"):
			AudioManager.set_heartbeat_state("silent")
		_catch_in_progress = false
		_victim_jumpscare_playing = false
		var t := _now()
		_next_peek = t + _rng.randf_range(25.0, 40.0)
		_next_chase = t + _rng.randf_range(45.0, 90.0)

# ---------------------------------------------------------------------------
# STALK — final phase permanent slow follower
# ---------------------------------------------------------------------------
func _begin_stalk() -> void:
	if _mp and not _mp_host:
		return
	_stalk_active = true
	_mode = "stalk"
	_linger_timer = 0.0
	_stalk_path.clear()
	_stalk_path_timer = 0.0
	_stalk_grace_timer = maxf(_stalk_grace_timer, Tuning.STALK_START_GRACE)
	var target := _get_stalk_target()
	if target.is_empty():
		return
	var body := target["body"] as Node3D
	_spawn_figure(_find_stalk_spawn(body), false)
	if _figure:
		_set_figure_alpha(0.9)
		_play_anim("ual1_Idle")

## Host receives each teammate's camera verdict. A short expiry absorbs relay
## jitter without allowing a stale gaze to freeze the stalker forever.
func set_remote_stalk_gaze(player_id: int, observed: bool) -> void:
	if not _mp or not _mp_host or player_id < 0:
		return
	if observed:
		_remote_stalk_gaze[player_id] = _now() + Tuning.STALK_GAZE_TIMEOUT
	else:
		_remote_stalk_gaze.erase(player_id)


## CX30 — the world confirms the victim's fullscreen clip is actually running,
## so the director drops its own catch scream. Purely local state: this is only
## ever called on the machine that built the video layer.
func notify_victim_jumpscare_started() -> void:
	_victim_jumpscare_playing = true


func remote_stalk_caught() -> void:
	if not _mp or _mp_host or not _local_targetable or _catch_in_progress:
		return
	_do_caught()


func _tick_stalk(delta: float) -> void:
	if _mp and not _mp_host:
		return
	var target := _get_stalk_target()
	if target.is_empty():
		_stalk_moving = false
		_play_anim("ual1_Idle")
		return
	var target_id := int(target["id"])
	var target_body := target["body"] as Node3D
	if target_id != _stalk_target_id:
		_stalk_target_id = target_id
		_linger_timer = 0.0
		_stalk_path.clear()
		_stalk_path_timer = 0.0
	if not is_instance_valid(_figure):
		_begin_stalk()
		return
	var to_target := target_body.global_position - _figure.global_position
	to_target.y = 0.0
	var distance := to_target.length()
	_stalk_grace_timer = maxf(0.0, _stalk_grace_timer - delta)
	var observed := _stalk_is_observed()

	if _stalk_grace_timer > 0.0:
		_stalk_moving = false
		_linger_timer = 0.0
		_play_anim("ual1_Idle")
		request_dread.emit(0.15)
		request_flicker.emit(0.0)
		return

	if observed:
		# Any living teammate with unobstructed sight can hold the one shared
		# entity, allowing the other player to move and then swap roles.
		_stalk_moving = false
		_linger_timer = maxf(0.0, _linger_timer - delta * 3.0)
		_play_anim("ual1_Idle")
		_turn_towards(_figure, target_body.global_position, delta, Tuning.ENTITY_TURN_RATE_ROAM)
		request_dread.emit(0.55)
		request_flicker.emit(0.10)
		if randf() < 0.008 and has_node("/root/AudioManager") and _sfx.has("breath"):
			AudioManager.play_sfx_3d(self, _sfx["breath"], _figure.global_position, -2.0, 20.0, randf_range(0.85, 0.95))
	else:
		request_dread.emit(0.2)
		request_flicker.emit(0.0)
		if distance > Tuning.STALK_KEEP_DISTANCE and distance > 0.01:
			_stalk_move(delta, target_body.global_position, distance)
			_turn_towards(_figure, target_body.global_position, delta, Tuning.ENTITY_TURN_RATE_ROAM)
			_play_anim("ual1_Walk")
			_sync_entity_locomotion_speed(
				"walk", STALK_SPEED * _rule_speed_mult)
		else:
			_stalk_moving = false
			_play_anim("ual1_Idle")

	# Linger pressure is now local and legible: close, unseen, and stationary.
	var target_speed := _stalk_target_speed(target_body)
	if not observed and distance <= Tuning.STALK_DANGER_DISTANCE and target_speed < 0.4:
		_linger_timer += delta
	else:
		_linger_timer = maxf(0.0, _linger_timer - delta * 2.5)
	if not observed and distance <= CATCH_DIST:
		_stalk_kill(target_id)
		return
	if _linger_timer > Tuning.STALK_LINGER_KILL:
		_stalk_kill(target_id)


func _stalk_kill(target_id: int) -> void:
	if _mp and _mp_host and has_node("/root/NetManager") \
			and target_id != NetManager.local_player_id:
		var now := _now()
		if now < float(_stalk_remote_catch_until.get(target_id, 0.0)):
			return
		_stalk_remote_catch_until[target_id] = now + 3.0
		_linger_timer = 0.0
		_stalk_grace_timer = 1.5
		if _world != null:
			_world.net_send("stalk_caught", {"target": target_id})
		return
	if has_node("/root/AudioManager") and _sfx.has("heavy_steps"):
		AudioManager.play_sfx_3d(self, _sfx["heavy_steps"], _figure.global_position, 0.0, 36.0, 0.82)
	_do_caught()

func enter_final_phase() -> void:
	var was_final := _final_phase
	_final_phase = true
	_stalk_grace_timer = maxf(_stalk_grace_timer,
		Tuning.STALK_EXIT_GRACE if was_final else Tuning.STALK_START_GRACE)
	if _mp and not _mp_host:
		_stalk_active = true
		if _apparition_mode != "":
			_end_apparition()


func grant_stalk_grace(seconds: float) -> void:
	_stalk_grace_timer = maxf(_stalk_grace_timer, maxf(seconds, 0.0))


func _get_stalk_target() -> Dictionary:
	var best_body: Node3D = null
	var best_id := -1
	var best_distance := INF
	var origin := _figure.global_position if is_instance_valid(_figure) else _player.global_position
	if _local_targetable and is_instance_valid(_player):
		best_body = _player
		best_id = NetManager.local_player_id if _mp and has_node("/root/NetManager") else -1
		best_distance = origin.distance_to(_player.global_position)
	if _mp and _mp_host and _world != null and _world.has_method("living_remote_player_bodies"):
		var remotes: Dictionary = _world.living_remote_player_bodies()
		for pid in remotes:
			var body := remotes[pid] as Node3D
			if not is_instance_valid(body):
				continue
			var candidate_distance := origin.distance_to(body.global_position)
			if candidate_distance < best_distance:
				best_body = body
				best_id = int(pid)
				best_distance = candidate_distance
	return {} if best_body == null else {"id": best_id, "body": best_body}


func _stalk_is_observed() -> bool:
	var head := _figure.global_position + Vector3(0.0, 1.7, 0.0)
	if _local_targetable and _camera_observes_point(head, 0.26):
		return true
	var now := _now()
	var alive_ids: Array = _world.alive_player_ids() if _world != null and _world.has_method("alive_player_ids") else []
	for pid in _remote_stalk_gaze.keys():
		if float(_remote_stalk_gaze[pid]) < now:
			_remote_stalk_gaze.erase(pid)
		elif alive_ids.is_empty() or int(pid) in alive_ids:
			return true
	return false


func _stalk_target_speed(body: Node3D) -> float:
	if body == _player and body is CharacterBody3D:
		var local_body := body as CharacterBody3D
		return Vector2(local_body.velocity.x, local_body.velocity.z).length()
	var value = body.get("_speed_smooth")
	return float(value) if value != null else 0.0


func _find_stalk_spawn(target_body: Node3D) -> Vector3:
	var target_cell := _cell_of(target_body.global_position)
	var behind := target_body.global_transform.basis.z
	behind.y = 0.0
	behind = behind.normalized() if behind.length() > 0.01 else Vector3.BACK
	var offsets := [
		Vector2i(0, 3), Vector2i(3, 0), Vector2i(0, -3), Vector2i(-3, 0),
		Vector2i(2, 2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(-2, -2),
		Vector2i(0, 4), Vector2i(4, 0), Vector2i(0, -4), Vector2i(-4, 0),
	]
	var best: Vector3 = _maze.world_center(target_cell) + behind * Tuning.STALK_SPAWN_DISTANCE
	var best_score: float = -INF
	for offset in offsets:
		var candidate_cell: Vector2i = target_cell + offset
		var route: Array = _maze.corridor_path(candidate_cell, target_cell, 1200)
		if route.is_empty():
			continue
		var candidate: Vector3 = _maze.world_center(candidate_cell)
		if not _figure_pose_clear(candidate):
			continue
		var direction := candidate - target_body.global_position
		direction.y = 0.0
		var score := behind.dot(direction.normalized()) \
			- absf(direction.length() - Tuning.STALK_SPAWN_DISTANCE) * 0.03
		if score > best_score:
			best_score = score
			best = candidate
	best.y = 0.0
	return best


func _stalk_move(delta: float, target_position: Vector3, distance_to_target: float) -> void:
	_stalk_path_timer -= delta
	if _stalk_path_timer <= 0.0 and _maze and _maze.has_method("corridor_path"):
		_stalk_path_timer = Tuning.STALK_PATH_REFRESH
		_stalk_path = _maze.corridor_path(
			_cell_of(_figure.global_position), _cell_of(target_position), 1200)
	var waypoint := target_position
	if _stalk_path.size() >= 2:
		waypoint = _maze.world_center(_stalk_path[1])
		var to_waypoint := waypoint - _figure.global_position
		to_waypoint.y = 0.0
		if to_waypoint.length() < 0.45:
			_stalk_path.pop_front()
			if _stalk_path.size() >= 2:
				waypoint = _maze.world_center(_stalk_path[1])
	elif _stalk_path.is_empty() and _cell_of(_figure.global_position) != _cell_of(target_position):
		_stalk_moving = false
		return
	var step_dir := waypoint - _figure.global_position
	step_dir.y = 0.0
	if step_dir.length() <= 0.01:
		_stalk_moving = false
		return
	var speed := STALK_SPEED * _rule_speed_mult
	speed *= _entity_stride_multiplier("walk")
	var move_distance := minf(speed * delta,
		maxf(distance_to_target - Tuning.STALK_KEEP_DISTANCE, 0.0))
	var wish_dir := step_dir.normalized()
	var next_pos := _figure.global_position + wish_dir * move_distance
	if not _figure_pose_clear(next_pos):
		var try_x := _figure.global_position + Vector3(wish_dir.x, 0.0, 0.0) * move_distance
		var try_z := _figure.global_position + Vector3(0.0, 0.0, wish_dir.z) * move_distance
		if _figure_pose_clear(try_x):
			next_pos = try_x
		elif _figure_pose_clear(try_z):
			next_pos = try_z
		else:
			_stalk_moving = false
			return
	_figure.global_position = next_pos
	_stalk_moving = move_distance > 0.001

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
	_setup_entity_model(model)
	mesh_root.global_position = pos
	_style_entity_model(model, 1.0, true)
	# animation
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	if _fig_anim_lib:
		var lib = _fig_anim_lib.duplicate(true) as AnimationLibrary
		ap.add_animation_library("", lib)
		ModelUtils.set_animation_loops(ap)
		ModelUtils.restore_generic_humanoid_root(ap)
		if ap.has_animation("idle"):
			ap.play("idle")
			# Force the first frame onto the skeleton NOW, or the figure renders its
			# bind (T-)pose for a frame or two before the animation kicks in.
			ap.advance(0)
	_fig_anim = ap
	_figure = mesh_root
	_set_figure_alpha(1.0)
	_ground_figure_pose(_figure)


## CX34 — build a body for a private apparition. Identical model and animation
## setup to `_spawn_figure`, but it writes to the apparition slot so the shared
## Entity is untouched.
func _spawn_apparition(pos: Vector3) -> void:
	_remove_apparition()
	if _watcher_scene == null:
		return
	var mesh_root := Node3D.new()
	add_child(mesh_root)
	var model: Node3D = _watcher_scene.instantiate()
	mesh_root.add_child(model)
	_setup_entity_model(model)
	mesh_root.global_position = pos
	_style_entity_model(model, 1.0, false, Tuning.APPARITION_BRIGHTNESS)
	_app_silh_mats = _last_styled_materials
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	if _fig_anim_lib:
		var lib = _fig_anim_lib.duplicate(true) as AnimationLibrary
		ap.add_animation_library("", lib)
		ModelUtils.set_animation_loops(ap)
		ModelUtils.restore_generic_humanoid_root(ap)
		if ap.has_animation("idle"):
			ap.play("idle")
			ap.advance(0)
	_app_anim = ap
	_apparition = mesh_root
	_set_apparition_alpha(1.0)
	_ground_figure_pose(_apparition)


func _remove_apparition() -> void:
	if is_instance_valid(_apparition):
		_apparition.queue_free()
	_apparition = null
	_app_anim = null
	_app_silh_mats.clear()


func _set_apparition_alpha(a: float) -> void:
	if not is_instance_valid(_apparition):
		return
	for m in _app_silh_mats:
		if is_instance_valid(m):
			m.albedo_color.a = a


func _play_apparition_anim(name: String) -> void:
	_play_anim_on(_app_anim, name)


## Plant the currently animated humanoid pose on the corridor floor. Static mesh
## AABBs cannot ground crouch_idle or execution poses because skin deformation
## does not update those bounds.
func _ground_figure_pose(mesh_root: Node3D) -> void:
	if not is_instance_valid(mesh_root) or mesh_root.get_child_count() == 0:
		return
	# Figure rigs are immutable after spawn. Cache their hierarchy and humanoid
	# subset on the owning node instead of rediscovering/classifying every bone on
	# every physics frame. Pose sampling itself remains per-frame and unchanged.
	var cache: Dictionary = mesh_root.get_meta("_cx18_ground_pose_cache", {})
	if cache.is_empty():
		var model := mesh_root.get_child(0) as Node3D
		if model == null:
			return
		var skeletons := model.find_children("*", "Skeleton3D", true, false)
		if skeletons.is_empty():
			return
		var found_skeleton := skeletons[0] as Skeleton3D
		var bone_indices := PackedInt32Array()
		for bone in range(found_skeleton.get_bone_count()):
			if ModelUtils.canonical_bone(found_skeleton.get_bone_name(bone)) != "":
				bone_indices.append(bone)
		# Generated rigs may use only Bone.001-style names. All bones are safe for
		# lowest-point grounding when semantic classification is unavailable.
		if bone_indices.is_empty():
			for bone in range(found_skeleton.get_bone_count()):
				bone_indices.append(bone)
		cache = {
			"model": model,
			"skeleton": found_skeleton,
			"bones": bone_indices,
		}
		mesh_root.set_meta("_cx18_ground_pose_cache", cache)
	var model := cache.get("model") as Node3D
	var skeleton := cache.get("skeleton") as Skeleton3D
	var bones: PackedInt32Array = cache.get("bones", PackedInt32Array())
	if not is_instance_valid(model) or not is_instance_valid(skeleton):
		return
	var lowest := INF
	for bone in bones:
		var world_position := skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
		lowest = minf(lowest, mesh_root.to_local(world_position).y)
	if lowest == INF:
		return
	var target_y := model.position.y - lowest + 0.03
	if absf(target_y - model.position.y) <= 3.0:
		model.position.y = target_y

## Silhouette materials cached at spawn so the per-frame alpha fades don't walk
## the whole node tree with find_children() every call (hot path during peeks).
var _fig_silh_mats: Array[StandardMaterial3D] = []
## CX34 — apparitions (peek/shadow/jump) are private hallucinations. They get
## their own body so the ONE shared Entity is never despawned, moved or animated
## by them: it keeps roaming identically for every player in the lobby.
## "" | "peek" | "shadow" | "jump". Deliberately separate from `_mode`: the
## shared Entity can be roaming while this client hallucinates a watcher.
var _apparition_mode := ""
var _apparition: Node3D = null
var _app_anim: AnimationPlayer = null
var _app_silh_mats: Array[StandardMaterial3D] = []
var _last_styled_materials: Array[StandardMaterial3D] = []

func _setup_entity_model(model: Node3D) -> void:
	if _using_new_entity:
		# The pirate faces local +X; the director's look_at convention faces -Z.
		model.rotation.y = NEW_ENTITY_MODEL_YAW
	ModelUtils.setup_character_for_movement(model, ENTITY_VISUAL_HEIGHT)


## `brightness` scales the darkening. The shared Entity is meant to be a dim
## shape you meet up close under a lamp; an apparition is a silhouette 10 m away
## at an unlit corner, and at 0.42x albedo it read as a black blob with no
## readable features. CX36 lifts the apparition so the watcher is legible.
func _style_entity_model(model: Node3D, opacity: float, cache_for_figure: bool,
		brightness: float = 1.0) -> void:
	var materials: Array[StandardMaterial3D] = []
	if _using_new_entity:
		# Preserve the GLB textures so the peg leg, coat and face remain readable,
		# while keeping the character dark and dirty under fluorescent lighting.
		for child in model.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := child as MeshInstance3D
			if mesh_instance == null or mesh_instance.mesh == null:
				continue
			mesh_instance.material_override = null
			for surface in range(mesh_instance.mesh.get_surface_count()):
				var original := mesh_instance.get_active_material(surface)
				var material := original.duplicate(true) as StandardMaterial3D \
					if original is StandardMaterial3D else StandardMaterial3D.new()
				var color := material.albedo_color
				material.albedo_color = Color(
					minf(color.r * 0.95 * brightness, 1.0),
					minf(color.g * 0.95 * brightness, 1.0),
					minf(color.b * 0.95 * brightness, 1.0),
					opacity)
				material.roughness = maxf(material.roughness, 0.82)
				material.metallic = minf(material.metallic, 0.12)
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
				mesh_instance.set_surface_override_material(surface, material)
				materials.append(material)
	else:
		var grey := minf(0.02 * brightness, 1.0)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(grey, grey, grey, opacity)
		material.roughness = 1.0
		material.metallic = 0.0
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		for child in model.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := child as MeshInstance3D
			if mesh_instance != null:
				mesh_instance.material_override = material
		materials.append(material)
	if cache_for_figure:
		_fig_silh_mats = materials
	_last_styled_materials = materials

func _play_anim(name: String) -> void:
	_play_anim_on(_fig_anim, name)


## CX34 — the clip-name mapping is identical for the shared Entity and for a
## client's private apparition; only the AnimationPlayer differs.
func _play_anim_on(anim: AnimationPlayer, name: String) -> void:
	if anim == null:
		return
	var target_name := name
	if _using_new_entity:
		if target_name in ["ual1_Sprint", "run", "crawl_chase"]:
			target_name = "run"
		elif target_name in ["ual1_Walk", "walk", "crawl"]:
			target_name = "walk"
		elif target_name in ["peek_left", "peek_right"]:
			# CX36 — authored corner lean when the FBX is present, otherwise the
			# procedural head/neck override builds the peek from the idle pose.
			if not anim.has_animation(target_name):
				target_name = "idle"
		elif target_name in ["ual1_Idle", "idle", "crouch_idle", "lean_left", "lean_right"]:
			target_name = "idle"
		elif target_name == "confused" and not anim.has_animation("confused"):
			# CX33 — retarget failed: stand and look around rather than T-pose.
			target_name = "idle"
	else:
		# The legacy silhouette has no confused take of its own.
		if target_name == "confused":
			target_name = "ual1_Idle"
		if target_name == "ual1_Sprint" or target_name == "run":
			target_name = "crawl_chase" if anim.has_animation("crawl_chase") else "crawl"
		elif target_name == "ual1_Walk" or target_name == "walk":
			target_name = "crawl"
		elif target_name == "ual1_Idle" or target_name == "idle":
			target_name = "crouch_idle" if anim.has_animation("crouch_idle") else "idle"

	if anim.has_animation(target_name):
		if anim.current_animation != target_name:
			if target_name in ["idle", "walk", "run"]:
				anim.speed_scale = 1.0
			elif target_name == "crawl":
				anim.speed_scale = 1.0
			elif target_name == "crawl_chase":
				anim.speed_scale = 2.2
			ModelUtils.play_locomotion(
				anim, target_name, anim.current_animation, -1.0,
				NEW_ENTITY_LOCOMOTION_PHASES if _using_new_entity else {})


## Match playback to world speed, then let the authored step cycle shape actual
## displacement. The average multiplier is one, preserving chase balance.
func _sync_entity_locomotion_speed(animation_name: String, world_speed: float) -> void:
	if not _using_new_entity or _fig_anim == null \
			or _fig_anim.current_animation != animation_name:
		return
	var reference := ENTITY_RUN_WORLD_SPEED if animation_name == "run" \
		else ENTITY_WALK_WORLD_SPEED
	_fig_anim.speed_scale = clampf(
		world_speed / maxf(reference, 0.1), 0.72, 1.22)


func _entity_stride_multiplier(animation_name: String) -> float:
	if not _using_new_entity or _fig_anim == null \
			or _fig_anim.current_animation != animation_name:
		return 1.0
	var animation := _fig_anim.get_animation(animation_name)
	if animation == null or animation.length <= 0.001:
		return 1.0
	var phase := fposmod(
		_fig_anim.current_animation_position / animation.length, 1.0)
	if animation_name == "walk":
		# Asymmetric wooden-leg gait: long weighted plant, shorter push-off.
		return clampf(
			1.0 + sin(phase * TAU - 0.42) * 0.24
			+ sin(phase * TAU * 2.0 + 1.05) * 0.10,
			0.66, 1.34)
	if animation_name == "run":
		return 1.0 + sin(phase * TAU * 2.0 - 0.25) * 0.06
	return 1.0


func _face_player(fig: Node3D) -> void:
	if not is_instance_valid(fig) or not is_instance_valid(_player):
		return
	_face_target(fig, _player.global_position)


## Instant snap. Correct for PLACEMENT (spawning, positioning for the execution),
## where there is no previous heading to preserve.
func _face_target(fig: Node3D, target_position: Vector3) -> void:
	if not is_instance_valid(fig):
		return
	var look := target_position
	look.y = fig.global_position.y
	if fig.global_position.distance_to(look) > 0.05:
		fig.look_at(look, Vector3.UP)


## CX36 — locomotion facing. `look_at()` rewrites the yaw outright, so a new path
## waypoint at a corner produced a 180-degree spin inside a single frame. A body
## this size has to carry its momentum through the turn.
func _turn_towards(fig: Node3D, target_position: Vector3, delta: float,
		turn_rate: float) -> void:
	if not is_instance_valid(fig):
		return
	var flat := target_position - fig.global_position
	flat.y = 0.0
	if flat.length_squared() < 0.0025:
		return
	# Node3D forward is -Z, so this is the yaw look_at() would have produced.
	var desired := atan2(-flat.x, -flat.z)
	var difference := angle_difference(fig.rotation.y, desired)
	var max_step := maxf(turn_rate, 0.1) * delta
	if absf(difference) <= max_step:
		fig.rotation.y = desired
	else:
		fig.rotation.y = wrapf(
			fig.rotation.y + signf(difference) * max_step, -PI, PI)

func _set_figure_alpha(a: float) -> void:
	if not is_instance_valid(_figure):
		return
	for m in _fig_silh_mats:
		if is_instance_valid(m):
			m.albedo_color.a = a

func _figure_alpha() -> float:
	if not is_instance_valid(_figure):
		return 0.0
	for m in _fig_silh_mats:
		if is_instance_valid(m):
			return m.albedo_color.a
	return 1.0

func _fade_figure(delta: float, rate: float) -> void:
	_set_figure_alpha(maxf(0.0, _figure_alpha() - delta * rate))


func _apparition_alpha() -> float:
	if not is_instance_valid(_apparition):
		return 0.0
	for m in _app_silh_mats:
		if is_instance_valid(m):
			return m.albedo_color.a
	return 0.0


func _fade_apparition(delta: float, rate: float) -> void:
	_set_apparition_alpha(maxf(0.0, _apparition_alpha() - delta * rate))

func _remove_figure() -> void:
	if is_instance_valid(_figure):
		_figure.queue_free()
	_figure = null
	_fig_anim = null
	_fig_silh_mats.clear()

func _end_apparition() -> void:
	# A watcher nobody ever saw was wasted terror — retry sooner next time.
	if _apparition_mode == "peek":
		if _peek_witnessed:
			_unseen_streak = 0
		else:
			_unseen_streak = mini(_unseen_streak + 1, 3)
	elif _apparition_mode == "shadow":
		_next_shadow = _now() + _rng.randf_range(Tuning.SHADOW_GAP_MIN, Tuning.SHADOW_GAP_MAX) * (1.0 + _stress * 0.5) * lerpf(1.0, 0.55, _menace)
		if _shadow_reveals > 0:
			_add_stress(0.15)
	# CX34 — only the hallucination is torn down. The shared Entity is not
	# touched: `_mode` and `_roam_cooldown` stay exactly as they were, so it goes
	# on roaming/chasing identically for every player in the lobby.
	_remove_apparition()
	_apparition_mode = ""
	_prox_muffle = false
	_peek_corner = false
	_lean = 0.0
	_lean_dir = 1.0
	_peek_loop_count = 0
	_peek_wait_timer = 0.0
	_peek_elapsed = 0.0
	_stare_timer = -1.0
	muffle.emit(false)
	request_flicker.emit(0.0)   # proximity flicker dies with the apparition
	_next_peek = _dread_scaled_peek_gap()
	if has_node("/root/AudioManager") and _mode != "chase":
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
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.max_distance = 38.0
	p.unit_size = 5.0
	p.panning_strength = 1.6
	p.position = Vector3(0, 1.2, 0)
	parent.add_child(p)
	p.play()
	return p

## Movement-driven positional footsteps. They follow the figure and stop when
## its feet stop, including roaming and the final stalk phase.
func _tick_entity_steps(delta: float) -> void:
	var can_step := is_instance_valid(_figure) and _mode in ["chase", "stalk", "roam"]
	if not can_step:
		_stop_entity_steps()
		return

	var figure_id := _figure.get_instance_id()
	if figure_id != _entity_step_figure_id:
		_entity_step_figure_id = figure_id
		_entity_step_prev_pos = _figure.global_position
		_entity_step_stop_delay = 0.0
		return

	var distance_moved := _entity_step_prev_pos.distance_to(_figure.global_position)
	_entity_step_prev_pos = _figure.global_position
	var speed := distance_moved / maxf(delta, 0.001)
	var allowed_state := _mode != "chase" or _chase_state == "pursue"
	if speed > 0.15 and allowed_state:
		_entity_step_stop_delay = 0.14
		if not is_instance_valid(_chase_steps):
			_chase_steps = _attach_loop(_figure, _sfx.get("heavy_steps"), -5.0)
		if is_instance_valid(_chase_steps):
			var mode_volume := -5.0 if _mode == "chase" else (-8.0 if _mode == "roam" else -10.0)
			var mode_pitch := clampf(0.72 + speed * 0.085, 0.80, 1.18)
			_chase_steps.volume_db = mode_volume
			_chase_steps.pitch_scale = mode_pitch
	else:
		_entity_step_stop_delay = maxf(0.0, _entity_step_stop_delay - delta)
		if _entity_step_stop_delay <= 0.0:
			_stop_entity_steps()

func _stop_entity_steps() -> void:
	if is_instance_valid(_chase_steps):
		_chase_steps.queue_free()
	_chase_steps = null
	_entity_step_figure_id = 0
	_entity_step_stop_delay = 0.0

func _tick_mirror_steps(delta: float) -> void:
	if _mirror_step_stop_delay > 0.0:
		_mirror_step_stop_delay = maxf(0.0, _mirror_step_stop_delay - delta)
	if _mirror_step_stop_delay <= 0.0 and is_instance_valid(_mirror_steps):
		_mirror_steps.queue_free()
		_mirror_steps = null

# ---------------------------------------------------------------------------
# Co-op shared entity: whoever's client is realizing the current scare
# broadcasts the figure's truth at 10 Hz; every other client renders an
# identical mirror in the world. The final STALK is host-owned too: clients
# contribute only their LOS-qualified gaze state.
# ---------------------------------------------------------------------------
func _net_fig_tick(delta: float) -> void:
	if _world == null:
		return
	_fig_snapshot_elapsed += delta
	if _mp and not _mp_host and _final_phase and _mode != "chase" and _mode != "roam":
		_stalk_gaze_send_timer -= delta
		var sees_stalk := false
		if _mirror_mode == "stalk" and is_instance_valid(_mirror):
			sees_stalk = _camera_observes_point(
				_mirror.global_position + Vector3(0.0, 1.7, 0.0), 0.26)
		if sees_stalk != _last_stalk_gaze or _stalk_gaze_send_timer <= 0.0:
			_last_stalk_gaze = sees_stalk
			_stalk_gaze_send_timer = 0.15
			_world.net_send("stalk_gaze", {"seen": sees_stalk})
		return
	# a delegated scare that never materializes must not jam the director
	if _net_fig_active:
		_net_fig_watchdog -= delta
		if _net_fig_watchdog <= 0.0:
			mirror_off()
	# Only physical/shared modes are replicated. Camera-local horror belongs to
	# the player who rolled it.
	# CX33 — "confused" is a physical, shared state: the teammate must see the
	# same body standing in the same corridor, not a figure that blinked out.
	var have := is_instance_valid(_figure) \
		and _mode in ["chase", "roam", "stalk", "confused"]
	if have:
		_owns_fig = true
		_fig_send_timer -= delta
		if _fig_send_timer <= 0.0:
			_fig_send_timer = 0.1
			var snapshot_velocity := Vector3.ZERO
			if _fig_last_sent_valid and _fig_snapshot_elapsed > 0.001:
				snapshot_velocity = (
					_figure.global_position - _fig_last_sent_position
				) / _fig_snapshot_elapsed
			_fig_last_sent_position = _figure.global_position
			_fig_last_sent_valid = true
			_fig_snapshot_elapsed = 0.0
			var animation_phase := -1.0
			var animation_speed := 1.0
			if _fig_anim != null and _fig_anim.current_animation != "":
				var current_animation := _fig_anim.get_animation(
					_fig_anim.current_animation)
				if current_animation != null and current_animation.length > 0.001:
					animation_phase = fposmod(
						_fig_anim.current_animation_position
						/ current_animation.length, 1.0)
					animation_speed = _fig_anim.speed_scale
			_world.net_send("fig", {
				"m": _mode,
				"x": _figure.global_position.x,
				"z": _figure.global_position.z,
				"vx": snapshot_velocity.x,
				"vz": snapshot_velocity.z,
				"ry": _figure.rotation.y,
				"mv": false if _mode == "confused" \
					else (_stalk_moving if _mode == "stalk" else true),
				"a": _replicated_execution_clip,
				"ap": animation_phase,
				"as": animation_speed,
			})
	elif _owns_fig:
		_owns_fig = false
		_fig_last_sent_valid = false
		_fig_snapshot_elapsed = 0.0
		_world.net_send("figoff", {})

func mirror_update(d: Dictionary) -> void:
	var incoming_mode := str(d.get("m", "roam"))
	_mirror_owner_id = int(d.get("from", -1))
	if incoming_mode == "stalk":
		_final_phase = true
		_stalk_active = true
	if incoming_mode == "stalk" and _mode == "stalk" and is_instance_valid(_figure):
		_remove_figure()
		_mode = "idle"
	if incoming_mode == "chase" and _apparition_mode != "":
		_end_apparition()
	_net_fig_active = true
	_net_fig_watchdog = 10.0
	if _mirror == null or not is_instance_valid(_mirror):
		_spawn_mirror()
		if _mirror == null:
			return
	var p := Vector3(float(d.get("x", 0.0)), 0.0, float(d.get("z", 0.0)))
	var was_fresh: bool = bool(_mirror.get_meta("fresh", true))
	if was_fresh:
		_mirror.global_position = p
		_mirror.set_meta("fresh", false)
		_mirror_step_prev_pos = p
	_mirror_target_position = p
	_mirror_target_yaw = float(d.get("ry", 0.0))
	_mirror_net_velocity = Vector3(
		float(d.get("vx", 0.0)), 0.0, float(d.get("vz", 0.0)))
	_mirror_snapshot_age = 0.0
	_mirror_has_target = true
	if was_fresh:
		_mirror.rotation.y = _mirror_target_yaw
	var m := incoming_mode
	var mode_changed := m != _mirror_mode
	if mode_changed:
		_mirror_mode = m
		if m == "chase":
			_mirror_scream = _attach_loop(_mirror, _sfx.get("chase_scream"), -14.0)
		else:
			if is_instance_valid(_mirror_steps):
				_mirror_steps.queue_free()
			if is_instance_valid(_mirror_scream):
				_mirror_scream.queue_free()
			_mirror_steps = null
			_mirror_scream = null
	if _mirror_anim:
		var mirror_moving := bool(d.get("mv", true))
		var forced_anim := str(d.get("a", _replicated_execution_clip))
		var anim := forced_anim
		if anim == "":
			if _using_new_entity:
				if m == "chase":
					anim = "run"
				elif m == "confused":
					# CX33 — falls back to idle when the clip failed to retarget.
					anim = "confused" if _mirror_anim.has_animation("confused") else "idle"
				elif m == "roam" or mirror_moving:
					anim = "walk"
				else:
					anim = "idle"
			else:
				if m == "chase":
					anim = "crawl_chase"
				elif m == "confused":
					anim = "crouch_idle"
				elif m == "roam" or mirror_moving:
					anim = "crawl"
				else:
					anim = "crouch_idle"
		if _mirror_anim.has_animation(anim) and _mirror_anim.current_animation != anim:
			ModelUtils.play_locomotion(
				_mirror_anim, anim, _mirror_anim.current_animation, -1.0,
				NEW_ENTITY_LOCOMOTION_PHASES if _using_new_entity else {})
		if _mirror_anim.has_animation(anim):
			_mirror_anim.speed_scale = clampf(
				float(d.get("as", 1.0)), 0.72, 2.2)
			var received_phase := float(d.get("ap", -1.0))
			var clip := _mirror_anim.get_animation(anim)
			if received_phase >= 0.0 and clip != null and clip.length > 0.001:
				var local_phase := fposmod(
					_mirror_anim.current_animation_position / clip.length, 1.0)
				var phase_error := absf(
					fposmod(received_phase - local_phase + 0.5, 1.0) - 0.5)
				if was_fresh or mode_changed or phase_error > 0.22:
					_mirror_anim.seek(received_phase * clip.length, true)


func _tick_mirror_interpolation(delta: float) -> void:
	if not _mirror_has_target or not is_instance_valid(_mirror):
		return
	_mirror_snapshot_age += delta
	var prediction := minf(_mirror_snapshot_age, MIRROR_MAX_PREDICTION)
	var desired := _mirror_target_position + _mirror_net_velocity * prediction
	desired.y = 0.0
	if _mirror.global_position.distance_to(desired) > MIRROR_TELEPORT_DISTANCE:
		_mirror.global_position = desired
	else:
		_mirror.global_position = _mirror.global_position.lerp(
			desired, 1.0 - exp(-18.0 * delta))
	_mirror.rotation.y = lerp_angle(
		_mirror.rotation.y, _mirror_target_yaw, 1.0 - exp(-16.0 * delta))

	var moved := _mirror_step_prev_pos.distance_to(_mirror.global_position)
	_mirror_step_prev_pos = _mirror.global_position
	if moved > 0.002 and _mirror_mode in ["chase", "roam", "stalk"]:
		_mirror_step_stop_delay = 0.24
		if not is_instance_valid(_mirror_steps):
			_mirror_steps = _attach_loop(
				_mirror, _sfx.get("heavy_steps"),
				-7.0 if _mirror_mode == "chase" else -9.0)
		if is_instance_valid(_mirror_steps):
			_mirror_steps.pitch_scale = 1.08 \
				if _mirror_mode == "chase" else 0.92

func mirror_off() -> void:
	_net_fig_active = false
	_mirror_mode = ""
	_mirror_owner_id = -1
	_mirror_has_target = false
	_mirror_target_position = Vector3.ZERO
	_mirror_net_velocity = Vector3.ZERO
	_mirror_snapshot_age = 0.0
	_mirror_steps = null
	_mirror_scream = null
	_mirror_step_stop_delay = 0.0
	if is_instance_valid(_mirror):
		_mirror.queue_free()
	_mirror = null
	_mirror_anim = null
	_update_shared_chase_warning()


## The red chase vignette must not reveal which nearby survivor is the target.
## The pursued player always sees it; teammates see it too when they occupy the
## same unobstructed space as the chase owner.
func _update_shared_chase_warning() -> void:
	var show_warning := _local_targetable and _mode == "chase"
	if not show_warning and _local_targetable and _mp \
			and _mirror_mode == "chase" and _mirror_owner_id >= 0 \
			and _world != null and _world.has_method("remote_player_body"):
		var chased_player := _world.remote_player_body(_mirror_owner_id) as Node3D
		if is_instance_valid(chased_player):
			var distance := _player.global_position.distance_to(chased_player.global_position)
			if distance <= COOP_SHARED_CHASE_WARNING_RANGE:
				var from := _player.global_position + Vector3.UP * 1.2
				var to := chased_player.global_position + Vector3.UP * 1.2
				show_warning = _ray_clear(from, to)
	var overlay := _get_overlay()
	if is_instance_valid(overlay) and overlay.has_method("set_chase_vignette"):
		overlay.set_chase_vignette(show_warning)

func _spawn_mirror() -> void:
	if _watcher_scene == null:
		return
	var mesh_root := Node3D.new()
	add_child(mesh_root)
	var model: Node3D = _watcher_scene.instantiate()
	mesh_root.add_child(model)
	_setup_entity_model(model)
	_style_entity_model(model, 1.0, false)
	var ap := AnimationPlayer.new()
	model.add_child(ap)
	if _fig_anim_lib:
		ap.add_animation_library("", _fig_anim_lib.duplicate(true))
		ModelUtils.set_animation_loops(ap)
		ModelUtils.restore_generic_humanoid_root(ap)
		if ap.has_animation("idle"):
			ap.play("idle")
			ap.advance(0)   # apply the first frame now — no bind/T-pose flash on spawn
	_mirror = mesh_root
	_mirror_anim = ap
	_mirror.set_meta("fresh", true)
	_mirror_has_target = false

# ---------------------------------------------------------------------------
# Perception helpers
# ---------------------------------------------------------------------------
## CX31 — how far the Entity notices a target. Line of sight does the real
## gating (`_entity_can_see_position` still has to clear the ray and the cone);
## this only decides how far down a clear corridor it bothers to look. Crouching
## shortens that reach but never blinds it, and inside
## `ENTITY_CROUCH_NO_HELP_DIST` it is looking straight at you regardless.
func _entity_spot_range(crouched: bool, distance: float) -> float:
	if not crouched or distance <= Tuning.ENTITY_CROUCH_NO_HELP_DIST:
		return Tuning.ENTITY_SIGHT_RANGE
	return Tuning.ENTITY_SIGHT_RANGE_CROUCHED


func _entity_can_see_position(world_target: Vector3) -> bool:
	if not is_instance_valid(_figure):
		return false
	var eye := _figure.global_position + Vector3.UP * _entity_eye_height()
	var flat_to_target := world_target - eye
	flat_to_target.y = 0.0
	var dist := flat_to_target.length()
	if dist <= 0.0001:
		return true
	# Close proximity sensing: within 3.0 m, the Entity senses/sees any player.
	if dist <= 3.0:
		return true
	var gaze := -_figure.global_transform.basis.z
	gaze.y = 0.0
	if gaze.length_squared() <= 0.0001:
		return false
	if gaze.normalized().dot(flat_to_target.normalized()) < ENTITY_VISION_DOT:
		return false
	# Check head/camera point, chest (1.25m) and waist (0.6m) so crouching at corner walls never breaks vision
	if _ray_clear(eye, world_target):
		return true
	if is_instance_valid(_player):
		var p_pos := _player.global_position
		if _ray_clear(eye, p_pos + Vector3.UP * 1.25):
			return true
		if _ray_clear(eye, p_pos + Vector3.UP * 0.6):
			return true
	return false


## CX34 — the sample height for "is this body on screen". Apparitions are read at
## head height (only the head clears the corner); the shared Entity at torso.
func _body_view_point(node: Node3D) -> Vector3:
	if not is_instance_valid(node):
		return Vector3.ZERO
	var target_height := 1.7
	if node == _apparition and _apparition_mode in ["peek", "shadow"]:
		target_height = _peek_head_height()
	return node.global_position + Vector3.UP * target_height


func _get_scare_target_pos() -> Vector3:
	if is_instance_valid(_apparition):
		return _body_view_point(_apparition)
	if is_instance_valid(_figure):
		return _body_view_point(_figure)
	return Vector3.ZERO

## CX34 — this used to ignore `node` entirely and always sample the shared
## Entity. Now that apparitions have their own body, asking "is the peek on
## screen" has to actually test the peek.
func _in_view(node: Node3D) -> bool:
	if not is_instance_valid(node) or not is_instance_valid(_camera):
		return false
	var p := _body_view_point(node)
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


## A gaze only counts when the point is near the camera centre, inside the
## viewport, and connected to the camera by an unobstructed environment ray.
func _camera_observes_point(point: Vector3, tolerance: float) -> bool:
	if not is_instance_valid(_camera) or _camera.is_position_behind(point):
		return false
	var to_point := point - _camera.global_position
	if to_point.length_squared() < 0.0001:
		return true
	var forward := -_camera.global_transform.basis.z
	if forward.dot(to_point.normalized()) <= 1.0 - tolerance:
		return false
	return _in_view_point(point) and _ray_clear(_camera.global_position, point)

func _has_los(node: Node3D) -> bool:
	if not is_instance_valid(node) or not is_instance_valid(_camera):
		return false
	var p := _body_view_point(node)
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


## A centre LOS ray is insufficient for this 2.7 m body. Direct pursuit is
## allowed only when its full width is clear at leg, torso and head height.
func _figure_lane_clear(from: Vector3, to: Vector3) -> bool:
	var flat := to - from
	flat.y = 0.0
	if flat.length_squared() <= 0.0025:
		return _figure_pose_clear(to)
	var direction := flat.normalized()
	var side := Vector3(-direction.z, 0.0, direction.x) * 0.27
	for height in [0.32, 1.28, 2.35]:
		var vertical := Vector3.UP * float(height)
		if not _ray_clear(from + vertical, to + vertical):
			return false
	for lateral in [side, -side]:
		var offset: Vector3 = lateral + Vector3.UP * 1.28
		if not _ray_clear(from + offset, to + offset):
			return false
	return _figure_pose_clear(to)


func _figure_pose_clear(pos: Vector3) -> bool:
	if _figure_collision_shape == null:
		_figure_collision_shape = CapsuleShape3D.new()
		_figure_collision_shape.radius = 0.32
		_figure_collision_shape.height = 2.5
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _figure_collision_shape
	query.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0, 1.28, 0))
	query.collision_mask = 1
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var exclude_rids: Array[RID] = []
	if is_instance_valid(_player):
		exclude_rids.append(_player.get_rid())
	if _world != null and _world.has_method("living_remote_player_bodies"):
		var bodies: Array = _world.living_remote_player_bodies()
		for body in bodies:
			var b := body as Node3D
			if is_instance_valid(b):
				exclude_rids.append(b.get_rid())
	query.exclude = exclude_rids
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


## CX36 — a stricter clearance for apparition placement.
##
## `MazeManager.peek_corners()` derives corners from the ABSTRACT cell graph
## (`_wall_present` / `_corner_blocked` / the pillar hash). It knows nothing
## about the geometry added later by `_place_room_formation` (dark alcoves, room
## thresholds) or `_place_cell_dressing` (storage clusters, hanging fixtures,
## clipped furniture) — all of which are real colliders. The physics test on this
## side is therefore the ONLY thing standing between a peek and a solid wall, and
## the locomotion capsule (r 0.32, h 2.5) is far too generous for a 2.7 m body
## whose head slides almost a metre sideways to clear the corner.
func _apparition_pose_clear(pos: Vector3) -> bool:
	if _apparition_collision_shape == null:
		_apparition_collision_shape = CapsuleShape3D.new()
		# Radius 0.26m and height 2.20m centered at y = 1.35m (bottom at y = 0.25m, 25cm above floor)
		_apparition_collision_shape.radius = 0.26
		_apparition_collision_shape.height = 2.20
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _apparition_collision_shape
	query.transform = Transform3D(Basis.IDENTITY, pos + Vector3(0, 1.35, 0))
	query.collision_mask = 1
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


## The corner has to work for the WHOLE lean, not just the two endpoints: the
## body slides along `hide -> out` and the head leans further still. Every
## sampled position, and the head arc above it, must be in open air.
func _apparition_lean_clear(hide: Vector3, out: Vector3) -> bool:
	var head_height := _peek_head_height()
	if not _ray_clear(hide + Vector3.UP * 0.3, out + Vector3.UP * 0.3):
		return false
	if not _ray_clear(hide + Vector3.UP * 1.3, out + Vector3.UP * 1.3):
		return false
	if not _ray_clear(hide + Vector3.UP * head_height, out + Vector3.UP * head_height):
		return false
	return _apparition_pose_clear(hide) and _apparition_pose_clear(out)


func _apply_chase_contortions(delta: float) -> void:
	if not is_instance_valid(_apparition):
		return

	# Keep the animated model upright; locomotion itself is selected per model.
	if _apparition.get_child_count() > 0:
		var model_node := _apparition.get_child(0) as Node3D
		if model_node:
			model_node.rotation.x = lerpf(model_node.rotation.x, 0.0, 14.0 * delta)
			model_node.rotation.z = 0.0


func _apply_peek_bone_poses(skeleton: Skeleton3D, _delta: float) -> void:
	if not is_instance_valid(_apparition) or not _peek_corner:
		return
	# CX36 — with an authored shoulder-lean clip playing, this procedural override
	# would fight the animation instead of standing in for it.
	if _peek_authored:
		return

	# Determine lean direction relative to the figure's local space
	var out_dir := (_peek_to - _peek_from).normalized()
	var local_out_dir := _apparition.global_transform.basis.inverse() * out_dir
	var tilt_side := 1.0 if local_out_dir.x >= 0.0 else -1.0

	var t := Time.get_ticks_msec() / 1000.0
	var breath := sin(t * 2.5) * 0.015

	# Only the HEAD emerges past the corner edge. The body is pinned ~0.75 m
	# behind cover, so the slide must actually CLEAR that distance — 0.35 m
	# never made it past the wall (the "peeking wasn't working" bug). 0.95 m
	# of unnatural neck-stretch does, and reads horrifying.
	var head_idx := _entity_bone_index(skeleton, "head")
	if head_idx != -1:
		if _using_new_entity:
			var face_axis := _player.global_position - _figure.global_position
			face_axis.y = 0.0
			if face_axis.length_squared() > 0.001:
				_rotate_peek_bone_world(
					skeleton, head_idx, face_axis.normalized(),
					tilt_side * _lean * 0.42 + breath)
		else:
			# The legacy Mixamo rig has known local axes for the authored neck tilt.
			var head_roll := tilt_side * _lean * 0.55 + breath
			var head_fwd := _lean * 0.12
			var head_rot := Quaternion(Vector3.FORWARD, head_roll) \
				* Quaternion(Vector3.RIGHT, head_fwd)
			skeleton.set_bone_pose_rotation(head_idx, head_rot)
		# Translate in WORLD peek direction, converted into the bone parent's axes.
		# This also supports Bone.001 rigs whose local X is not character-left.
		var head_rest := skeleton.get_bone_rest(head_idx).origin
		var slide_skeleton := skeleton.global_transform.basis.inverse() \
			* (out_dir * _lean * 0.95)
		var head_parent := skeleton.get_bone_parent(head_idx)
		var head_slide := slide_skeleton
		if head_parent >= 0:
			head_slide = skeleton.get_bone_global_pose(head_parent).basis.inverse() \
				* slide_skeleton
		skeleton.set_bone_pose_position(head_idx, head_rest + head_slide)

	# Slight neck tilt to support the head lean (subtle, not full body)
	var neck_idx := _entity_bone_index(skeleton, "neck")
	if neck_idx != -1:
		if _using_new_entity:
			var neck_axis := _player.global_position - _figure.global_position
			neck_axis.y = 0.0
			if neck_axis.length_squared() > 0.001:
				_rotate_peek_bone_world(
					skeleton, neck_idx, neck_axis.normalized(),
					tilt_side * _lean * 0.20)
		else:
			var neck_roll := tilt_side * _lean * 0.25
			var neck_rot := Quaternion(Vector3.FORWARD, neck_roll) \
				* Quaternion(Vector3.UP, sin(t * 1.5) * 0.03)
			skeleton.set_bone_pose_rotation(neck_idx, neck_rot)

	# Head-only isolation: collapse limb chains (arms, legs, shoulders) so no
	# elbow or foot ever pokes past the wall edge. The trunk chain must stay —
	# zeroing Spine/Hips would collapse the Head with them (scale propagates).
	for i in range(skeleton.get_bone_count()):
		if _is_limb_bone(skeleton, i):
			skeleton.set_bone_pose_scale(i, Vector3.ZERO)


## Rotate a retargeted Bone.001 rig around a world-space axis without assuming
## Mixamo local axes. Called after AnimationPlayer evaluation, so idle breathing
## remains underneath the procedural corner lean.
func _rotate_peek_bone_world(
		skeleton: Skeleton3D, bone_idx: int,
		world_axis: Vector3, angle: float) -> void:
	var axis_in_skeleton := skeleton.global_transform.basis.inverse() * world_axis
	var parent_idx := skeleton.get_bone_parent(bone_idx)
	var axis_in_parent := axis_in_skeleton
	if parent_idx >= 0:
		axis_in_parent = skeleton.get_bone_global_pose(parent_idx).basis.inverse() \
			* axis_in_skeleton
	if axis_in_parent.length_squared() <= 0.0001:
		return
	var lean_rotation := Quaternion(axis_in_parent.normalized(), angle)
	skeleton.set_bone_pose_rotation(
		bone_idx, lean_rotation * skeleton.get_bone_pose_rotation(bone_idx))


func _is_limb_bone(skeleton: Skeleton3D, bone_idx: int) -> bool:
	var cur := bone_idx
	while cur != -1:
		if _entity_canonical_for_bone(skeleton, cur) in [
				"shoulder.l", "upperarm.l", "shoulder.r", "upperarm.r",
				"upperleg.l", "upperleg.r"]:
			return true
		cur = skeleton.get_bone_parent(cur)
	return false


func _entity_bone_index(skeleton: Skeleton3D, canonical: String) -> int:
	if _using_new_entity and NEW_ENTITY_BONE_MAP.has(canonical):
		return skeleton.find_bone(String(NEW_ENTITY_BONE_MAP[canonical]))
	for bone_index in range(skeleton.get_bone_count()):
		if ModelUtils.canonical_bone(skeleton.get_bone_name(bone_index)) == canonical:
			return bone_index
	return -1


func _entity_canonical_for_bone(skeleton: Skeleton3D, bone_index: int) -> String:
	var bone_name := skeleton.get_bone_name(bone_index)
	if _using_new_entity:
		for canonical in NEW_ENTITY_BONE_MAP:
			if String(NEW_ENTITY_BONE_MAP[canonical]) == bone_name:
				return String(canonical)
	return ModelUtils.canonical_bone(bone_name)

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
	if not is_instance_valid(_apparition):
		return
	var skeletons := _apparition.find_children("*", "Skeleton3D")
	if skeletons.is_empty():
		return
	var skeleton: Skeleton3D = skeletons[0]
	for conn in skeleton.skeleton_updated.get_connections():
		var c: Callable = conn["callable"]
		if c.get_object() == self and c.get_method() == "_on_peek_skeleton_updated":
			return
	skeleton.skeleton_updated.connect(_on_peek_skeleton_updated.bind(skeleton))


## A callout summons the wanderer. If nothing is roaming yet, spawn one (at an
## unseen maze cell, like a normal roam) and point it at the sound; if it is
## already roaming, just redirect it. The corridor path guarantees it approaches
## through the halls instead of teleporting into view.
func _rouse_toward(world_position: Vector3) -> void:
	if not _physical_spawn_allowed():
		return
	if not is_instance_valid(_figure):
		_begin_roam()
	if not is_instance_valid(_figure):
		return
	_mode = "roam"
	_investigating_callout = true
	var dest_cell := _cell_of(world_position)
	# Snap to the reachable cell center, not the raw scream point (see investigate_noise).
	_roam_target = _maze.world_center(dest_cell) if (_maze and _maze.has_method("world_center")) else world_position
	if _maze and _maze.has_method("corridor_path"):
		_roam_path = _maze.corridor_path(_cell_of(_figure.global_position), dest_cell)
	_roam_wait = 0.0
	_roam_leg_time = 0.0


## After downing a player: keep the figure, flee to the farthest reachable cell,
## then fall back into normal roaming. Never despawns.
func _flee_and_roam() -> void:
	if not is_instance_valid(_figure):
		_begin_roam()
		return
	_mode = "roam"
	_fleeing = true
	_investigating_callout = false
	_play_anim("run")
	var flee_cell := _find_far_flee_cell()
	if flee_cell != Vector2i(-1, -1) and _maze:
		_roam_target = _maze.world_center(flee_cell)
		_roam_path = _maze.corridor_path(_cell_of(_figure.global_position), flee_cell)
	_roam_wait = 0.0
	_roam_leg_time = 0.0


## The farthest open cell from the player — used to flee after a down.
func _find_far_flee_cell() -> Vector2i:
	if _maze == null or not _maze.has_method("open_cells") or not is_instance_valid(_player):
		return Vector2i(-1, -1)
	var cells: Array = _maze.open_cells()
	if cells.is_empty():
		return Vector2i(-1, -1)
	var from_cell := _cell_of(_figure.global_position) if is_instance_valid(_figure) else _cell_of(_player.global_position)
	var best := Vector2i(-1, -1)
	var best_score := -INF
	for c in cells:
		var d: float = _maze.world_center(c).distance_to(_player.global_position)
		if d < Tuning.FLEE_MIN_DISTANCE or d > Tuning.FLEE_MAX_DISTANCE:
			continue
		var path: Array = _maze.corridor_path(from_cell, c, 900)
		if path.is_empty():
			continue
		var score := d + minf(float(path.size()), 10.0) * 0.2
		if score > best_score:
			best_score = score
			best = c
	return best


func _begin_roam() -> void:
	if not _physical_spawn_allowed():
		_roam_cooldown = maxf(
			_roam_cooldown,
			Tuning.ENTITY_INITIAL_SPAWN_DELAY - _now())
		return
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
	_play_anim("crawl")
	_mode = "roam"
	_fleeing = false
	_investigating_callout = false
	# Spawn already committed to a roam route, never pre-rotated toward the
	# survivor. Its gaze follows the corridor it is actually walking through.
	_figure.rotation.y = _rng.randf_range(-PI, PI)
	_pick_random_roam_leg()
	if _roam_path.size() >= 2:
		_face_target(_figure, _maze.world_center(_roam_path[1]))


func _tick_roam(delta: float) -> void:
	if not is_instance_valid(_figure):
		_end_roam()
		return
		
	var d := _figure.global_position.distance_to(_player.global_position)
	var crouched: bool = bool(_player.is_crouching) if is_instance_valid(_player) and "is_crouching" in _player else false
	
	# Detection belongs exclusively to the Entity's frontal eyes.
	var entity_sees_player := _entity_can_see_position(_camera.global_position)
	var entity_spot_range := _entity_spot_range(crouched, d)
	
	# A scream is only a WORLD destination, never a pre-selected victim. Compare
	# every player the Entity can actually see and attack the closest visible one;
	# this also removes the old implicit host-first priority.
	var closest_distance := INF
	var closest_remote_id := -1
	var local_is_closest := false
	if _local_targetable and entity_sees_player and d < entity_spot_range:
		closest_distance = d
		local_is_closest = true
	if _mp and _mp_host and not _shared_chase_active() \
			and _world != null and _world.has_method("living_remote_player_bodies"):
		var remotes: Dictionary = _world.living_remote_player_bodies()
		for pid in remotes:
			var body := remotes[pid] as Node3D
			if not is_instance_valid(body):
				continue
			var to_body: Vector3 = body.global_position - _figure.global_position
			var rd := to_body.length()
			var remote_crouched := bool(body.network_is_crouching()) \
				if body.has_method("network_is_crouching") else false
			var remote_spot_range := _entity_spot_range(remote_crouched, rd)
			if rd > remote_spot_range or rd < 0.01 or rd >= closest_distance:
				continue
			if not _entity_can_see_position(
					body.global_position + Vector3.UP * 1.2):
				continue
			closest_distance = rd
			closest_remote_id = int(pid)
			local_is_closest = false
	if closest_distance < INF:
		_investigating_callout = false
		if local_is_closest:
			_trigger_roam_to_chase()
		elif closest_remote_id >= 0:
			_dispatch_chase_to(closest_remote_id)
		return

	_roam_move(delta, d)
	_apply_chase_contortions(delta)


func _roam_move(delta: float, dist_to_player: float) -> void:
	if not is_instance_valid(_figure):
		return
		
	if _roam_target == Vector3.ZERO or _figure.global_position.distance_to(_roam_target) < 0.6:
		_investigating_callout = false
		_roam_wait -= delta
		_play_anim("crouch_idle")
		if _roam_wait <= 0.0:
			_pick_random_roam_leg()
		return

	# Couldn't reach the target in time (stuck on geometry, or an off-grid scream
	# point) -- don't march in place forever; resume roaming somewhere reachable.
	_roam_leg_time += delta
	if _roam_leg_time > ROAM_LEG_TIMEOUT:
		_pick_random_roam_leg()
		return

	# Sprint away after a fresh down; use the normal roaming gait otherwise.
	_play_anim("crawl_chase" if _fleeing else "crawl")
	var target := _roam_target
	if _roam_path.is_empty() and _cell_of(_figure.global_position) != _cell_of(_roam_target):
		# No corridor route means no movement. Never fall back to a straight line
		# through walls.
		_pick_random_roam_leg()
		return
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
		var locomotion := "run" if _fleeing else "walk"
		var speed := Tuning.FLEE_SPEED if _fleeing else ENTITY_WALK_WORLD_SPEED
		_sync_entity_locomotion_speed(locomotion, speed)
		speed *= _entity_stride_multiplier(locomotion)
		var move_distance := minf(speed * delta, step_dir.length())
		var wish_dir := step_dir.normalized()
		var next_pos := _figure.global_position + wish_dir * move_distance
		if not _figure_pose_clear(next_pos):
			var try_x := _figure.global_position + Vector3(wish_dir.x, 0.0, 0.0) * move_distance
			var try_z := _figure.global_position + Vector3(0.0, 0.0, wish_dir.z) * move_distance
			if _figure_pose_clear(try_x):
				next_pos = try_x
			elif _figure_pose_clear(try_z):
				next_pos = try_z
			else:
				return
		_figure.global_position = next_pos
		# CX36 — the wanderer turns with weight; corners are no longer snapped.
		_turn_towards(_figure, _figure.global_position + step_dir, delta,
			Tuning.ENTITY_TURN_RATE_ROAM)


func _find_random_roam_cell() -> Vector2i:
	if _maze == null or not _maze.has_method("open_cells") or not is_instance_valid(_player):
		return Vector2i(-1, -1)
	var cells: Array = _maze.open_cells()
	if cells.size() == 0:
		return Vector2i(-1, -1)
	cells.shuffle()
	var best_far := Vector2i(-1, -1)
	var max_dist := 0.0
	for c in cells:
		var wpos: Vector3 = _maze.world_center(c)
		var d: float = wpos.distance_to(_player.global_position)
		if d >= 22.0 and d <= 48.0:
			return c
		if d > max_dist:
			max_dist = d
			best_far = c
	return best_far if best_far != Vector2i(-1, -1) else cells[0]


## Pick a fresh, reachable roam target and reset the stuck timer. Used both after
## reaching a target and after giving up on an unreachable one.
func _pick_random_roam_leg() -> void:
	_investigating_callout = false
	var completed_client_flee := _fleeing and _mp and not _mp_host and _local_bleedout
	_fleeing = false   # reached (or gave up) the flee spot -> back to normal roaming
	if completed_client_flee:
		# The caught player's client owned this chase. Remove it after it rounds a
		# corner so the host can take over without a second entity overlapping it.
		_end_roam()
		return
	var cell := _find_random_roam_cell()
	if cell != Vector2i(-1, -1) and _maze:
		_roam_target = _maze.world_center(cell)
		_roam_path = _maze.corridor_path(_cell_of(_figure.global_position), cell)
		_roam_wait = _rng.randf_range(1.5, 3.5)
	_roam_leg_time = 0.0


## Host-only rescue pacing. Survivors get a short window to begin the revive;
## then the one shared threat returns from outside body-camp range.
func schedule_revive_pressure(downed_position: Vector3) -> void:
	if not _mp or not _mp_host or _final_phase:
		return
	_revive_pressure_position = downed_position
	_revive_pressure_timer = Tuning.REVIVE_PRESSURE_DELAY


func _tick_revive_pressure(delta: float) -> void:
	if not _mp or not _mp_host or _revive_pressure_timer < 0.0:
		return
	_revive_pressure_timer = maxf(0.0, _revive_pressure_timer - delta)
	if _revive_pressure_timer > 0.0:
		return
	# Wait for the fleeing client's replicated entity to turn the corner and send
	# figoff. This authority hand-off guarantees that only one entity exists.
	if _shared_chase_active() or is_instance_valid(_figure) or _mode != "idle":
		return
	if _world != null and _world.has_method("alive_player_ids") and _world.alive_player_ids().is_empty():
		_revive_pressure_timer = -1.0
		return
	if _begin_revive_pressure_roam(_revive_pressure_position):
		_revive_pressure_timer = -1.0
	else:
		_revive_pressure_timer = 1.0


func _begin_revive_pressure_roam(downed_position: Vector3) -> bool:
	if _maze == null or not _maze.has_method("open_cells"):
		return false
	var downed_cell := _cell_of(downed_position)
	var candidates: Array = []
	for cell in _maze.open_cells():
		var position: Vector3 = _maze.world_center(cell)
		var distance := position.distance_to(downed_position)
		if distance < Tuning.REVIVE_PRESSURE_MIN_DISTANCE or distance > Tuning.REVIVE_PRESSURE_MAX_DISTANCE:
			continue
		var path: Array = _maze.corridor_path(cell, downed_cell, 900)
		if path.is_empty() or not _figure_pose_clear(position):
			continue
		# Never pop back into existence in the survivor's clear view.
		var head := position + Vector3(0.0, 1.5, 0.0)
		if _in_view_point(head) and _ray_clear(_camera.global_position, head):
			continue
		candidates.append({"cell": cell, "path": path})
	if candidates.is_empty():
		return false
	var selected: Dictionary = candidates[_rng.randi_range(0, candidates.size() - 1)]
	var spawn_cell: Vector2i = selected["cell"]
	_spawn_figure(_maze.world_center(spawn_cell), false)
	if not is_instance_valid(_figure):
		return false
	_set_figure_alpha(1.0)
	_mode = "roam"
	_fleeing = false
	_investigating_callout = false
	_roam_target = _maze.world_center(downed_cell)
	_roam_path = selected["path"]
	_roam_wait = 0.0
	_roam_leg_time = 0.0
	_play_anim("crawl")
	return true


## CX34 — the roaming Entity spotted you. This is now the ONLY way a chase starts
## in practice (the scheduled path in `_tick_idle` is unreachable while the roam
## is persistent), and it deliberately has NO cap or cooldown gate: being seen
## must always mean being chased. What was missing is the bookkeeping — without
## it `_chase_done` and `_next_chase` never moved, so every other system that
## paces itself off them (peek gaps, scheduled chases) worked from stale values.
func _trigger_roam_to_chase() -> void:
	var t := _now()
	_chase_done += 1
	_next_chase = t + _rng.randf_range(50.0, 110.0) * lerpf(1.0, 0.55, _menace)
	_investigating_callout = false
	_mode = "chase"
	_chase_state = "pursue"
	_last_seen_pos = _player.global_position
	_has_seen_player_this_chase = true
	_stumble_timer = _rng.randf_range(3.8, 5.2)
	_stumble_duration = 0.0
	_chase_speed_mult = 1.0
	request_flicker.emit(0.65)
	
	_play_anim("ual1_Sprint")
	
	if has_node("/root/AudioManager") and _sfx.has("chase_scream"):
		AudioManager.play_sfx(_sfx["chase_scream"], -2.0)
		
	_chase_scream = _attach_loop(_figure, _sfx.get("chase_scream"), -18.0)
	
	chase_started.emit()


func _end_roam() -> void:
	_remove_figure()
	_mode = "idle"
	_investigating_callout = false
	_roam_cooldown = 0.0
