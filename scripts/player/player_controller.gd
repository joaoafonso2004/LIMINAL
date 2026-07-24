extends CharacterBody3D
## LIMINAL — first-person Backrooms walker.
## Deliberate walking with a short, noisy panic sprint. No jump or flashlight.
## Builds its own child nodes in code, so it can be attached to a bare
## CharacterBody3D with no .tscn dependency.

signal looked_back
signal noise_emitted(world_position: Vector3, audible_range: float, kind: String)
signal sprint_state_changed(active: bool, stamina_ratio: float)
signal lens_focus_changed(blur_amount: float)

@export var speed: float = Tuning.WALK_SPEED
@export var gravity: float = 20.0
@export var mouse_sensitivity: float = 0.0022
@export var accel: float = 10.0
@export var friction: float = 12.0

var frozen: bool = false
var menu_input_blocked: bool = false
var is_downed: bool = false

const EYE_HEIGHT: float = 1.55
const DOWNED_EYE_HEIGHT: float = 0.35   # carpet level while crawling
const BOB_SPEED: float = 7.0
const BOB_AMOUNT: float = 0.036
const STEP_TILT: float = 0.0095         # shoulder weight shift during each stride
const IDLE_TILT: float = 0.0018         # faint breathing roll when standing still
const STEP_SFX_PATH: String = "res://assets/audio/sfx/player/player_player_step_carpet.mp3"
const ZOOM_IN_SFX_PATH := "res://assets/audio/sfx/camera/zoom_in.mp3"
const ZOOM_OUT_SFX_PATH := "res://assets/audio/sfx/camera/zoom_out.mp3"
const BREATHING_CONTROLLER_SCRIPT := \
	"res://scripts/player/breathing_audio_controller.gd"
const ZOOM_MIN_FOV := 42.0
const ZOOM_MAX_FOV := 82.0
const ZOOM_STEP_FOV := 4.0
const ZOOM_FALLBACK_DURATION := 1.384
const FOCUS_HOLD_SECONDS := 0.30
const CAMERA_MOTION_IDLE := 0
const CAMERA_MOTION_WALK := 1
const CAMERA_MOTION_RUN := 2
const CAMERA_MOTION_CROUCH := 3

var camera: Camera3D

var _bob_time: float = 0.0
var _idle_time: float = 0.0
var _prev_bob_cos: float = 0.0
# Look pitch is the PLAYER's; the bob may only add a tiny offset on top.
# (Writing camera.rotation.x directly from the bob erased mouse pitch.)
var _pitch: float = 0.0
var _bob_pitch: float = 0.0
var _camera_motion_mode := CAMERA_MOTION_IDLE
var _camera_motion_intensity := 0.0
var _profile_bob_amount := BOB_AMOUNT
var _profile_sway_amount := BOB_AMOUNT * 0.61
var _profile_roll_amount := STEP_TILT
var _profile_pitch_amount := 0.0065
var _profile_micro_amount := 0.0023
var _profile_frequency_scale := 1.0
var _micro_noise := FastNoiseLite.new()
var _micro_noise_time := 0.0
var _heel_spring_position := 0.0
var _heel_spring_velocity := 0.0
var _turn_spring_position := 0.0
var _turn_spring_velocity := 0.0
var _was_walking := false
var _camera_motion_position := Vector3.ZERO
var _camera_motion_rotation := Vector3.ZERO
var _step_lateral_position := 0.0
var _step_lateral_velocity := 0.0
var _step_roll_position := 0.0
var _step_roll_velocity := 0.0
var _stride_frequency_variation := 1.0

var _step_stream: AudioStream = null
var _zoom_audio: AudioStreamPlayer = null
var _zoom_in_stream: AudioStream = null
var _zoom_out_stream: AudioStream = null
var _zoom_target_fov := 72.0
var _zoom_current_fov := 72.0
var _zoom_motion_start_fov := 72.0
var _zoom_motion_elapsed := 0.0
var _zoom_motion_duration := ZOOM_FALLBACK_DURATION
var _zoom_motion_active := false
var _locomotion_fov_offset := 0.0
var _zoom_focus_pending := false
var _zoom_was_moving := false
var _focus_hold_remaining := 0.0
var _focus_blur_amount := 0.0
var _breathing_audio: Node = null
var shake_intensity: float = 0.0

var _mesh_root: Node3D
var _anim_player: AnimationPlayer
var _cur_clip: String = ""
var _execution_clip: String = ""      # forced victim animation; movement stays locked until downed
var _fp_pivot: Node3D                  # the pivot holding the first-person body (for grounding)
var _stand_ground_offset: float = 0.0  # static pivot Y that grounds the standing pose
var _body_skeleton: Skeleton3D = null  # cached once; skeleton discovery is not frame work
var _ground_bone_indices := PackedInt32Array()
var _hips_bone_idx := -1
var is_crouching: bool = false
var is_sprinting: bool = false
var sprint_enabled: bool = true
var is_dead: bool = false
var is_reviving: bool = false
var sprint_seconds: float = Tuning.SPRINT_MAX_SECONDS
var _current_eye_height: float = EYE_HEIGHT
var _sprint_regen_delay: float = 0.0
var _sprint_exhausted: bool = false
var _last_sprint_active: bool = false
var _last_stamina_bucket: int = 10
var is_being_chased: bool = false
var red_effect_active: bool = false

# Look-back tracking.
var _facing_ref: float = 0.0
var _looked_latched: bool = false


func _ready() -> void:
	collision_layer = 2 # player
	collision_mask = 1 # environment

	# Camera first — built before anything that could fail.
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.position.y = EYE_HEIGHT
	# Safe near clip plane so standing close to walls doesn't clip through them
	camera.near = 0.08
	camera.fov = 72.0
	add_child(camera)
	camera.make_current()

	# One optimized, non-looping Perlin source sampled at unrelated offsets for
	# pitch/yaw/roll. No per-frame objects or random jitter.
	_micro_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_micro_noise.seed = int(Time.get_ticks_usec() & 0x7FFFFFFF)
	_micro_noise.frequency = 0.72
	_micro_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_micro_noise.fractal_octaves = 3
	_micro_noise.fractal_gain = 0.48

	# Collision capsule: bottom at body origin (y = 0).
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.7
	capsule.radius = 0.3
	var col := CollisionShape3D.new()
	col.shape = capsule
	col.position.y = 0.85   # half height
	add_child(col)

	# Footstep stream (guarded).
	if ResourceLoader.exists(STEP_SFX_PATH):
		var res := ResourceLoader.load(STEP_SFX_PATH)
		if res is AudioStream:
			_step_stream = res
	_setup_camera_zoom_audio()
	_setup_breathing_audio()

	_facing_ref = rotation.y
	_spawn_fp_body() # Esta linha cria o boneco na memória

var is_holding_breath: bool = false


func _unhandled_input(event: InputEvent) -> void:
	var is_hiding: bool = bool(get_meta("is_hiding", false))
	# Click-to-recapture — pointer lock needs a user gesture on web.
	if event is InputEventMouseButton and event.pressed:
		var mouse_button := event as InputEventMouseButton
		if not menu_input_blocked and (not frozen or is_hiding) \
				and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if not menu_input_blocked and not frozen \
				and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
				_adjust_camera_zoom(-ZOOM_STEP_FOV)
				return
			if mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_adjust_camera_zoom(ZOOM_STEP_FOV)
				return

	if (frozen or menu_input_blocked) and not is_hiding:
		return

	# Mouse-look only while captured. User multiplier from the options menu.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		var sens := mouse_sensitivity
		if has_node("/root/Settings"):
			sens *= Settings.mouse_sensitivity
		var yaw_delta := -motion.relative.x * sens
		rotation.y += yaw_delta
		# Neck/shoulder inertia: the body turns first and the handheld camera
		# follows on a damped spring instead of rolling in a fixed loop.
		_turn_spring_velocity += clampf(-yaw_delta * 5.2, -0.14, 0.14)
		_pitch = clampf(_pitch - motion.relative.y * sens, -1.2 if is_hiding else -1.4, 1.2 if is_hiding else 1.4)
		if is_hiding and is_instance_valid(camera):
			camera.rotation.x = _pitch


func _physics_process(delta: float) -> void:
	var is_hiding: bool = bool(get_meta("is_hiding", false))
	if is_hiding:
		_camera_motion_mode = CAMERA_MOTION_IDLE
		_camera_motion_intensity = lerpf(
			_camera_motion_intensity, 0.0, clampf(delta * 8.0, 0.0, 1.0))
		velocity = Vector3.ZERO
		camera.position.x = lerpf(camera.position.x, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		camera.position.y = lerpf(camera.position.y, EYE_HEIGHT, clampf(delta * 10.0, 0.0, 1.0))
		camera.rotation.x = _pitch
		camera.rotation.z = lerpf(camera.rotation.z, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		_update_camera_zoom(delta)
		# Hold breath while hiding in locker (Space or Right Mouse Button)
		is_holding_breath = Input.is_physical_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		_update_breathing_audio(delta)
		return
	else:
		is_holding_breath = false
	_update_breathing_audio(delta)

	if frozen or menu_input_blocked:
		_camera_motion_mode = CAMERA_MOTION_IDLE
		_camera_motion_intensity = lerpf(
			_camera_motion_intensity, 0.0, clampf(delta * 8.0, 0.0, 1.0))
		velocity = Vector3.ZERO
		# Execution clips keep animating while controls are locked. Their authored
		# vertical root motion still needs live floor correction every frame.
		if _execution_clip != "":
			_update_body_animation()
		return

	# Crouch is remappable from Settings.
	var wants_crouch := Input.is_action_pressed("crouch")
	is_crouching = wants_crouch

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	var is_trying_to_move := input_dir.length() > 0.1
	var is_pressing_forward := Input.is_action_pressed("move_forward") \
		and input_dir.y < -0.1
	_update_sprint(delta, is_trying_to_move, is_pressing_forward)
	_update_camera_zoom(delta)

	var target_speed := speed
	var target_eye_height := EYE_HEIGHT
	var target_mesh_scale_y := 1.0

	if _is_slipping:
		input_dir = Vector2.ZERO
		is_sprinting = false

	if is_downed:
		is_crouching = true
		is_sprinting = false
		target_speed = 0.85 # Slow crawling speed while downed
		target_eye_height = DOWNED_EYE_HEIGHT
		target_mesh_scale_y = 1.0
	elif is_crouching:
		target_speed = Tuning.CROUCH_SPEED
		target_eye_height = 0.85
		target_mesh_scale_y = 1.0
	elif is_sprinting:
		target_speed = Tuning.SPRINT_SPEED

	# Smoothly transition camera height
	_current_eye_height = lerpf(_current_eye_height, target_eye_height, 10.0 * delta)
	
	# Smoothly squash/stretch the first-person body mesh to simulate crouching
	if _mesh_root and is_instance_valid(_mesh_root):
		_mesh_root.scale.y = lerpf(_mesh_root.scale.y, target_mesh_scale_y, 10.0 * delta)

	# Gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Desired horizontal direction from input.
	var direction := transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)
	direction.y = 0.0
	if direction.length() > 0.001:
		direction = direction.normalized()

	# Weighted, unsettling gait: ramp toward target rather than snapping.
	var target := direction * target_speed
	if not _is_slipping:
		if direction.length() > 0.001:
			velocity.x = move_toward(velocity.x, target.x, accel * delta)
			velocity.z = move_toward(velocity.z, target.z, accel * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, friction * delta)
			velocity.z = move_toward(velocity.z, 0.0, friction * delta)

	_wet_floor_immunity = maxf(0.0, _wet_floor_immunity - delta)

	# The state flag can drop on the exact frame stamina reaches zero, while the
	# body is still physically travelling at running speed. Either condition is
	# enough to make the wet carpet dangerous.
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var running_on_floor := is_sprinting or horizontal_speed > speed * 1.22
	if running_on_floor and not _is_slipping and _wet_floor_immunity <= 0.0:
		for area in get_tree().get_nodes_in_group("wet_floor"):
			if _is_inside_wet_floor(area):
				slip_on_wet_floor(direction)
				break

	if _is_slipping:
		var progress := 1.0 - (_slip_timer / maxf(0.01, _slip_total_duration))

		if progress < 0.35:
			# Phase 1: Violent Slip & Fall Backwards (looking UP at ceiling lights!)
			var fall_p := progress / 0.35
			target_eye_height = lerpf(EYE_HEIGHT, 0.22, ease(fall_p, 2.2))

			# Pitch camera UP towards ceiling lights (-58 degrees) as player falls backward
			var target_pitch := deg_to_rad(-58.0 * fall_p)
			camera.rotation.x = lerpf(camera.rotation.x, target_pitch, 16.0 * delta)

			# VHS Camera sway / wobble as player loses balance
			var sway := sin(progress * 28.0) * deg_to_rad(16.0)
			camera.rotation.z = lerpf(camera.rotation.z, sway, 16.0 * delta)

			# Trigger carpet impact glitch & ceiling light flicker
			if fall_p >= 0.88 and not _slip_impact_done:
				_slip_impact_done = true
				_trigger_slip_impact_glitch()

		elif progress < 0.60:
			# Phase 2: Lying on Carpet Floor Looking Up at Lights
			target_eye_height = 0.22
			camera.rotation.x = lerpf(camera.rotation.x, deg_to_rad(-48.0), 8.0 * delta)
			camera.rotation.z = lerpf(camera.rotation.z, deg_to_rad(3.0 * sin(progress * 10.0)), 8.0 * delta)

		else:
			# Phase 3: Smooth Recovery — Pushing Off Carpet & Standing Back Up
			var rise_p := (progress - 0.60) / 0.40
			target_eye_height = lerpf(0.22, EYE_HEIGHT, ease(rise_p, 0.5))
			camera.rotation.x = lerpf(camera.rotation.x, 0.0, 8.0 * delta)
			camera.rotation.z = lerpf(camera.rotation.z, 0.0, 8.0 * delta)

		# This target used to be assigned after the normal eye-height update and
		# was therefore never applied. Slip exclusively owns the camera height.
		camera.position.y = lerpf(
			camera.position.y, target_eye_height, 1.0 - exp(-18.0 * delta))
		_current_eye_height = camera.position.y

		_slip_timer -= delta
		velocity.x = lerpf(velocity.x, 0.0, 4.0 * delta)
		velocity.z = lerpf(velocity.z, 0.0, 4.0 * delta)

		if _slip_timer <= 0.0:
			_is_slipping = false
			_slip_impact_done = false
			_wet_floor_immunity = 0.8
			camera.rotation.z = 0.0
			camera.rotation.x = _pitch
			if is_instance_valid(_anim_player):
				var getup_clips := ["player_get_up", "player_recover", "get_up", "idle"]
				for gc in getup_clips:
					if _anim_player.has_animation(gc) and _anim_player.current_animation != gc:
						_anim_player.play(gc, 0.2)
						break

	move_and_slide()
	if _is_slipping and not _slip_hit_wall:
		for collision_index in get_slide_collision_count():
			var collision := get_slide_collision(collision_index)
			if collision == null:
				continue
			var normal := collision.get_normal()
			# Floors keep the fall grounded; only a mostly-horizontal normal is
			# a wall/large prop. Stop the impulse instead of repeatedly pushing
			# the body (and first-person mesh) into that surface.
			if absf(normal.y) < 0.45:
				_slip_hit_wall = true
				velocity.x = 0.0
				velocity.z = 0.0
				break

	_update_head_bob(delta)
	_update_look_back()
	_update_body_animation()


func _setup_breathing_audio() -> void:
	if not ResourceLoader.exists(BREATHING_CONTROLLER_SCRIPT):
		push_warning("player: missing " + BREATHING_CONTROLLER_SCRIPT)
		return
	var controller_script := load(BREATHING_CONTROLLER_SCRIPT) as Script
	if controller_script == null:
		return
	_breathing_audio = controller_script.new()
	_breathing_audio.name = "BreathingAudioController"
	add_child(_breathing_audio)


func _setup_camera_zoom_audio() -> void:
	if ResourceLoader.exists(ZOOM_IN_SFX_PATH):
		_zoom_in_stream = load(ZOOM_IN_SFX_PATH) as AudioStream
	if ResourceLoader.exists(ZOOM_OUT_SFX_PATH):
		_zoom_out_stream = load(ZOOM_OUT_SFX_PATH) as AudioStream
	_zoom_audio = AudioStreamPlayer.new()
	_zoom_audio.name = "CameraZoomMotor"
	_zoom_audio.bus = "SFX"
	_zoom_audio.volume_db = -7.0
	add_child(_zoom_audio)


func _adjust_camera_zoom(fov_delta: float) -> void:
	var previous_target := _zoom_target_fov
	_zoom_target_fov = clampf(
		_zoom_target_fov + fov_delta, ZOOM_MIN_FOV, ZOOM_MAX_FOV)
	if is_equal_approx(previous_target, _zoom_target_fov):
		return
	_zoom_focus_pending = true
	_zoom_was_moving = true
	_focus_hold_remaining = 0.0
	_zoom_motion_start_fov = _zoom_current_fov
	_zoom_motion_elapsed = 0.0
	_zoom_motion_duration = _play_camera_zoom_motor(fov_delta < 0.0)
	_zoom_motion_active = true


func _play_camera_zoom_motor(zooming_in: bool) -> float:
	if not is_instance_valid(_zoom_audio):
		return ZOOM_FALLBACK_DURATION
	var wanted_stream := _zoom_in_stream if zooming_in else _zoom_out_stream
	if wanted_stream == null:
		return ZOOM_FALLBACK_DURATION
	var stream_duration := wanted_stream.get_length()
	if stream_duration <= 0.0:
		stream_duration = ZOOM_FALLBACK_DURATION
	# Repeated wheel notches in the same direction extend the lens target without
	# restarting its motor sample. The new target uses precisely the sound time
	# remaining before its mechanical click. Reversing direction swaps motors.
	if _zoom_audio.stream != wanted_stream:
		_zoom_audio.stream = wanted_stream
		_zoom_audio.play()
		return stream_duration
	elif not _zoom_audio.playing:
		_zoom_audio.play()
		return stream_duration
	return maxf(stream_duration - _zoom_audio.get_playback_position(), 0.08)


func _update_camera_zoom(delta: float) -> void:
	if not is_instance_valid(camera):
		return
	if _zoom_motion_active:
		_zoom_motion_elapsed = minf(
			_zoom_motion_elapsed + delta, _zoom_motion_duration)
		var progress := clampf(
			_zoom_motion_elapsed / maxf(_zoom_motion_duration, 0.001), 0.0, 1.0)
		# Smootherstep models the motor accelerating, travelling and braking. It
		# reaches its endpoint exactly as the MP3's final mechanical click plays.
		var motor_curve := progress * progress * progress \
			* (progress * (progress * 6.0 - 15.0) + 10.0)
		_zoom_current_fov = lerpf(
			_zoom_motion_start_fov, _zoom_target_fov, motor_curve)
		if progress >= 1.0:
			_zoom_current_fov = _zoom_target_fov
			_zoom_motion_active = false
			if _zoom_focus_pending and _zoom_was_moving:
				_zoom_was_moving = false
				_focus_hold_remaining = FOCUS_HOLD_SECONDS

	var locomotion_fov_target := 6.0 if is_sprinting \
		else (-2.0 if _sprint_exhausted else 0.0)
	_locomotion_fov_offset = lerpf(
		_locomotion_fov_offset,
		locomotion_fov_target,
		1.0 - exp(-5.0 * delta))
	camera.fov = clampf(
		_zoom_current_fov + _locomotion_fov_offset,
		ZOOM_MIN_FOV,
		ZOOM_MAX_FOV + 6.0)

	var target_blur := 0.0
	if _zoom_focus_pending and _zoom_motion_active:
		# Slight optical softness while glass elements are physically moving.
		target_blur = 0.07

	if _focus_hold_remaining > 0.0:
		_focus_hold_remaining = maxf(0.0, _focus_hold_remaining - delta)
		# A short autofocus hunt: hold briefly, then recover smoothly.
		if _focus_hold_remaining > 0.18:
			target_blur = 0.46
		else:
			target_blur = 0.46 * (_focus_hold_remaining / 0.18)
		if _focus_hold_remaining <= 0.0:
			_zoom_focus_pending = false

	_focus_blur_amount = lerpf(
		_focus_blur_amount, target_blur, 1.0 - exp(-18.0 * delta))
	if target_blur <= 0.0 and _focus_blur_amount < 0.001:
		_focus_blur_amount = 0.0
	lens_focus_changed.emit(_focus_blur_amount)


func _update_breathing_audio(delta: float) -> void:
	if not is_instance_valid(_breathing_audio) \
			or not _breathing_audio.has_method("update_conditions"):
		return
	_breathing_audio.update_conditions(
		delta,
		is_sprinting,
		_sprint_exhausted,
		is_being_chased,
		red_effect_active,
		is_holding_breath or is_dead)


var _is_slipping := false
var _slip_impact_done := false
var _slip_timer := 0.0
var _slip_total_duration := 1.2
var _slip_dir := Vector3.ZERO
var _wet_floor_immunity := 0.0
var _slip_hit_wall := false

func _trigger_slip_impact_glitch() -> void:
	if has_node("/root/AudioManager"):
		if ResourceLoader.exists(STEP_SFX_PATH):
			AudioManager.play_sfx(load(STEP_SFX_PATH), -5.0, 0.64)

	var tree := get_tree()
	if tree:
		var world = tree.get_first_node_in_group("game_world")
		if is_instance_valid(world):
			if world.has_method("_on_flicker"):
				world._on_flicker(1.0)
			if world.has_method("_on_jumpscare"):
				world._on_jumpscare()

func slip_on_wet_floor(dir: Vector3) -> void:
	if _is_slipping or is_downed or is_crouching or frozen:
		return
	_is_slipping = true
	_slip_impact_done = false
	_slip_hit_wall = false
	_slip_total_duration = 1.4
	_slip_dir = dir.normalized() * 7.5
	if dir.length() < 0.1:
		_slip_dir = -transform.basis.z * 7.5
	# CharacterBody3D performs a swept collision during move_and_slide(). This
	# short preflight also prevents a full-strength impulse when the player is
	# already standing almost against a wall.
	var probe_motion := Vector3(_slip_dir.x, 0.0, _slip_dir.z).normalized() * 0.55
	# `recovery_as_collision=false` prevents ordinary floor contact from being
	# mistaken for a wall and reducing every slip to 12% strength.
	if test_move(global_transform, probe_motion, null, 0.001, false, 4):
		_slip_dir *= 0.12
		_slip_hit_wall = true
	# The previous implementation calculated this impulse but never applied it,
	# so the player only tilted in place instead of actually sliding.
	velocity.x = _slip_dir.x
	velocity.z = _slip_dir.z
	if has_node("/root/AudioManager"):
		if ResourceLoader.exists(STEP_SFX_PATH):
			AudioManager.play_sfx(load(STEP_SFX_PATH), -9.0, 0.82)

	if is_instance_valid(_anim_player):
		var slip_clips := ["player_slip_getup", "slip_and_getup", "stumble_recover", "player_slip", "player_stumble", "stumble", "slip"]
		for sc in slip_clips:
			if _anim_player.has_animation(sc):
				_anim_player.play(sc, 0.15)
				_slip_total_duration = maxf(1.0, _anim_player.get_animation(sc).length)
				break
	_slip_timer = _slip_total_duration


func _is_inside_wet_floor(area: Node) -> bool:
	if not is_instance_valid(area) or not area is Node3D:
		return false
	var wet_floor := area as Node3D
	var radius := maxf(float(wet_floor.get_meta("wet_floor_radius", 1.55)), 0.1)
	var offset := wet_floor.global_position - global_position
	# Horizontal distance matches the cylinder footprint and is independent of
	# small grounding/animation differences on the Y axis.
	return Vector2(offset.x, offset.z).length_squared() <= radius * radius


func _update_sprint(delta: float, is_trying_to_move: bool, is_pressing_forward: bool) -> void:
	var wants_sprint := sprint_enabled and Input.is_action_pressed("sprint")
	var can_sprint := not is_crouching and not _sprint_exhausted and sprint_seconds > 0.0
	is_sprinting = wants_sprint and is_trying_to_move and is_pressing_forward and can_sprint

	if is_sprinting:
		sprint_seconds = maxf(0.0, sprint_seconds - delta)
		_sprint_regen_delay = Tuning.SPRINT_REGEN_DELAY
		if sprint_seconds <= 0.0:
			is_sprinting = false
			_sprint_exhausted = true
			if has_node("/root/AudioManager"):
				var heartbeat_path := "res://assets/audio/sfx/player/heartbeat.wav"
				if ResourceLoader.exists(heartbeat_path):
					AudioManager.play_sfx(load(heartbeat_path), -8.0, 1.12)
	else:
		_sprint_regen_delay = maxf(0.0, _sprint_regen_delay - delta)
		if _sprint_regen_delay <= 0.0:
			var regen_per_second := Tuning.SPRINT_MAX_SECONDS / Tuning.SPRINT_REGEN_SECONDS
			sprint_seconds = minf(Tuning.SPRINT_MAX_SECONDS, sprint_seconds + regen_per_second * delta)
		if _sprint_exhausted and sprint_seconds >= Tuning.SPRINT_MAX_SECONDS * Tuning.SPRINT_EXHAUST_RECOVERY:
			_sprint_exhausted = false

	var stamina_ratio := sprint_seconds / Tuning.SPRINT_MAX_SECONDS
	var stamina_bucket := int(floor(stamina_ratio * 10.0))
	if is_sprinting != _last_sprint_active or stamina_bucket != _last_stamina_bucket:
		_last_sprint_active = is_sprinting
		_last_stamina_bucket = stamina_bucket
		sprint_state_changed.emit(is_sprinting, stamina_ratio)


func _update_head_bob(delta: float) -> void:
	# Slip owns the local camera transform while its fall/recovery phases run.
	# Letting headbob write afterwards erased the fall pitch and caused flicker.
	if _is_slipping:
		_was_walking = false
		return
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var walking := is_on_floor() and horizontal_speed > 0.3

	_idle_time += delta
	var idle_sway := sin(_idle_time * 1.3) * 0.006 + cos(_idle_time * 0.7) * 0.004

	# Downed/crawl stays fully first-person. Keeping this as one stable local
	# transform prevents the old world-space orbit and the body camera from
	# fighting each other, and avoids clipping through the local skinned mesh.
	if is_downed:
		_was_walking = false
		_camera_motion_mode = CAMERA_MOTION_IDLE
		_camera_motion_intensity = lerpf(
			_camera_motion_intensity, 0.0, clampf(delta * 12.0, 0.0, 1.0))
		_heel_spring_position = lerpf(
			_heel_spring_position, 0.0, clampf(delta * 14.0, 0.0, 1.0))
		_heel_spring_velocity = lerpf(
			_heel_spring_velocity, 0.0, clampf(delta * 14.0, 0.0, 1.0))
		_turn_spring_position = lerpf(
			_turn_spring_position, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		_turn_spring_velocity = lerpf(
			_turn_spring_velocity, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		_step_lateral_position = 0.0
		_step_lateral_velocity = 0.0
		_step_roll_position = 0.0
		_step_roll_velocity = 0.0
		_stride_frequency_variation = 1.0
		_bob_pitch = lerpf(_bob_pitch, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		shake_intensity = lerpf(shake_intensity, 0.0, clampf(delta * 16.0, 0.0, 1.0))
		var crawl_sway := sin(_idle_time * 1.7) * 0.003 \
			* clampf(horizontal_speed / 0.85, 0.0, 1.0)
		camera.position = camera.position.lerp(
			Vector3(crawl_sway, _current_eye_height, 0.0),
			1.0 - exp(-12.0 * delta))
		camera.rotation = Vector3(_pitch, 0.0, 0.0)
		return

	# Profile targets: transitions are blended so changing walk/run/crouch never
	# snaps the camera. Downed keeps the previous neutral crawl behaviour.
	var target_mode := CAMERA_MOTION_IDLE
	var target_bob := BOB_AMOUNT
	var target_sway := BOB_AMOUNT * 0.61
	var target_roll := STEP_TILT
	var target_pitch := 0.0065
	var target_micro := 0.0023
	var target_frequency := 1.0
	var reference_speed := speed
	if walking and not is_downed:
		if is_sprinting:
			target_mode = CAMERA_MOTION_RUN
			target_bob = 0.056
			target_sway = 0.035
			target_roll = 0.016
			target_pitch = 0.011
			target_micro = 0.0055
			target_frequency = 1.04
			reference_speed = Tuning.SPRINT_SPEED
		elif is_crouching:
			target_mode = CAMERA_MOTION_CROUCH
			target_bob = 0.018
			target_sway = 0.012
			target_roll = 0.004
			target_pitch = 0.003
			target_micro = 0.0017
			target_frequency = 0.88
			reference_speed = Tuning.CROUCH_SPEED
		else:
			target_mode = CAMERA_MOTION_WALK
			reference_speed = speed
	elif walking and is_downed:
		reference_speed = 0.85

	_camera_motion_mode = target_mode
	var raw_intensity := clampf(horizontal_speed / maxf(reference_speed, 0.1), 0.0, 1.0) \
		if walking and not is_downed else 0.0
	# Velocity only controls the weight of the locomotion layer. Idle breathing,
	# look inertia and step motion remain independent, so pressing a movement key
	# never replaces the transform currently visible on screen.
	_camera_motion_intensity = lerpf(
		_camera_motion_intensity, raw_intensity, 1.0 - exp(-5.5 * delta))
	var profile_blend := clampf(delta * 7.5, 0.0, 1.0)
	_profile_bob_amount = lerpf(_profile_bob_amount, target_bob, profile_blend)
	_profile_sway_amount = lerpf(_profile_sway_amount, target_sway, profile_blend)
	_profile_roll_amount = lerpf(_profile_roll_amount, target_roll, profile_blend)
	_profile_pitch_amount = lerpf(_profile_pitch_amount, target_pitch, profile_blend)
	_profile_micro_amount = lerpf(_profile_micro_amount, target_micro, profile_blend)
	_profile_frequency_scale = lerpf(
		_profile_frequency_scale, target_frequency, profile_blend)

	_tick_camera_springs(delta)
	_micro_noise_time += delta * (2.0 + _camera_motion_intensity * 2.8)
	var micro_x := _micro_noise.get_noise_1d(_micro_noise_time + 17.0) \
		* _profile_micro_amount
	var micro_y := _micro_noise.get_noise_1d(_micro_noise_time + 113.0) \
		* _profile_micro_amount * 0.65
	var micro_z := _micro_noise.get_noise_1d(_micro_noise_time + 251.0) \
		* _profile_micro_amount * 0.42
	var micro_pitch := _micro_noise.get_noise_1d(_micro_noise_time + 397.0) \
		* _profile_micro_amount * 0.30
	var micro_yaw := _micro_noise.get_noise_1d(_micro_noise_time + 541.0) \
		* _profile_micro_amount * 0.34
	var micro_roll := _micro_noise.get_noise_1d(_micro_noise_time + 719.0) \
		* _profile_micro_amount * 0.38

	if walking:
		# Scale step frequency with movement speed
		var speed_mult := clampf(horizontal_speed / speed, 0.5, 1.8)
		_bob_time += delta * BOB_SPEED * speed_mult \
			* _profile_frequency_scale * _stride_frequency_variation

	# Infinitesimal Lissajous figure-8. Its phase remains continuous while the
	# locomotion weight fades in/out. Slow noise warps the visual phase and
	# amplitude without affecting heel-strike detection, so the gait never loops
	# as an identical mechanical side-to-side cycle.
	var phase_warp := _micro_noise.get_noise_1d(
		_micro_noise_time * 0.19 + 997.0) * 0.13
	var organic_phase := _bob_time + phase_warp
	var stride_amplitude := 1.0 + _micro_noise.get_noise_1d(
		_micro_noise_time * 0.13 + 1297.0) * 0.12
	var lissajous_x: float = sin(organic_phase)
	var lissajous_y: float = sin(organic_phase * 2.0 + PI * 0.5)
	var phase_cos: float = cos(_bob_time)
	var vertical_dip: float = (lissajous_y - 1.0) * 0.5 \
		* _profile_bob_amount * stride_amplitude
	var horizontal_sway: float = lissajous_x \
		* _profile_sway_amount * stride_amplitude

	if walking:
		# Do not treat the first moving frame as a heel strike. Previously
		# `_prev_bob_cos = 0` matched either sign and injected a visible micro-drop
		# at the exact instant W was pressed.
		if _was_walking and ((_prev_bob_cos >= 0.0 and phase_cos < 0.0) \
				or (_prev_bob_cos <= 0.0 and phase_cos > 0.0)):
			var heel_impulse := 0.17
			if target_mode == CAMERA_MOTION_RUN:
				heel_impulse = 0.30
			elif target_mode == CAMERA_MOTION_CROUCH:
				heel_impulse = 0.075
			heel_impulse *= randf_range(0.86, 1.16)
			_heel_spring_velocity -= heel_impulse
			var foot_side := 1.0 if sin(_bob_time) >= 0.0 else -1.0
			_step_lateral_velocity += foot_side * randf_range(0.14, 0.22)
			_step_roll_velocity += foot_side * randf_range(0.10, 0.17)
			_stride_frequency_variation = randf_range(0.91, 1.09)
			_play_footstep()
		_prev_bob_cos = phase_cos
	else:
		_prev_bob_cos = 0.0
		_stride_frequency_variation = lerpf(
			_stride_frequency_variation, 1.0, 1.0 - exp(-3.0 * delta))

	var movement_weight := _camera_motion_intensity
	var idle_weight := 1.0 - movement_weight * 0.76
	var idle_sway_x := sin(_idle_time * 0.8) * 0.008
	var idle_sway_y := cos(_idle_time * 1.4) * 0.006
	var target_bob_pitch := vertical_dip \
		/ maxf(_profile_bob_amount, 0.001) * _profile_pitch_amount \
		* movement_weight
	_bob_pitch = lerpf(
		_bob_pitch, target_bob_pitch, 1.0 - exp(-8.0 * delta))

	var target_motion_position := Vector3(
		idle_sway_x * idle_weight + horizontal_sway * movement_weight \
			+ _step_lateral_position * movement_weight + micro_x,
		(idle_sway + idle_sway_y) * idle_weight \
			+ vertical_dip * movement_weight + _heel_spring_position + micro_y,
		micro_z)
	var target_motion_rotation := Vector3(
		_bob_pitch + micro_pitch,
		micro_yaw - _turn_spring_position * 0.34,
		sin(_idle_time * 0.9) * IDLE_TILT * idle_weight \
			- lissajous_x * _profile_roll_amount * movement_weight \
			+ _step_roll_position * movement_weight \
			+ micro_roll + _turn_spring_position)

	# A final inertial filter absorbs any remaining difference between profiles.
	# Mouse pitch itself is deliberately excluded so looking remains immediate.
	_camera_motion_position = _camera_motion_position.lerp(
		target_motion_position, 1.0 - exp(-12.0 * delta))
	_camera_motion_rotation = _camera_motion_rotation.lerp(
		target_motion_rotation, 1.0 - exp(-14.0 * delta))
	camera.position = Vector3(0.0, _current_eye_height, 0.0) \
		+ _camera_motion_position
	camera.rotation = Vector3(_pitch, 0.0, 0.0) \
		+ _camera_motion_rotation
	_was_walking = walking

	# Apply dynamic camera shake (e.g. from nearby sprinting entity)
	if shake_intensity > 0.001:
		camera.position.x += randf_range(-1.0, 1.0) * shake_intensity * 0.15
		camera.position.y += randf_range(-1.0, 1.0) * shake_intensity * 0.15
		camera.position.z += randf_range(-1.0, 1.0) * shake_intensity * 0.1
		camera.rotation.x += randf_range(-1.0, 1.0) * shake_intensity * 0.012
		camera.rotation.y += randf_range(-1.0, 1.0) * shake_intensity * 0.012
		camera.rotation.z += randf_range(-1.0, 1.0) * shake_intensity * 0.012
		
		# Decay shake intensity
		shake_intensity = lerpf(shake_intensity, 0.0, 8.0 * delta)


func _tick_camera_springs(delta: float) -> void:
	# Semi-implicit integration is stable at variable frame rates and cheaper than
	# Tween allocation. Values are metres for heel drop and radians for turn sway.
	var dt := minf(delta, 1.0 / 30.0)
	var heel_acceleration := -190.0 * _heel_spring_position \
		- 24.0 * _heel_spring_velocity
	_heel_spring_velocity += heel_acceleration * dt
	_heel_spring_position += _heel_spring_velocity * dt
	_heel_spring_position = clampf(_heel_spring_position, -0.028, 0.012)

	var turn_acceleration := -70.0 * _turn_spring_position \
		- 12.0 * _turn_spring_velocity
	_turn_spring_velocity += turn_acceleration * dt
	_turn_spring_position += _turn_spring_velocity * dt
	_turn_spring_position = clampf(_turn_spring_position, -0.055, 0.055)

	var lateral_acceleration := -150.0 * _step_lateral_position \
		- 21.0 * _step_lateral_velocity
	_step_lateral_velocity += lateral_acceleration * dt
	_step_lateral_position += _step_lateral_velocity * dt
	_step_lateral_position = clampf(_step_lateral_position, -0.012, 0.012)

	var step_roll_acceleration := -135.0 * _step_roll_position \
		- 20.0 * _step_roll_velocity
	_step_roll_velocity += step_roll_acceleration * dt
	_step_roll_position += _step_roll_velocity * dt
	_step_roll_position = clampf(_step_roll_position, -0.014, 0.014)


func _play_footstep() -> void:
	if _step_stream == null:
		return
	if has_node("/root/AudioManager"):
		# Lower pitch (0.75 - 0.92) makes footsteps sound like soft, damp, heavy thuds on old carpet
		var pitch := randf_range(0.75, 0.92)
		var vol := -18.5
		var audible_range := Tuning.NOISE_RANGE_WALK
		var kind := "walk"
		if is_crouching:
			vol = -26.0
			pitch = randf_range(0.68, 0.82) # even heavier/softer when crouching!
			audible_range = Tuning.NOISE_RANGE_CROUCH
			kind = "crouch"
		elif is_sprinting:
			vol = randf_range(-12.5, -9.5)
			pitch = randf_range(0.92, 1.08)
			audible_range = Tuning.NOISE_RANGE_SPRINT
			kind = "sprint"
		else:
			vol = randf_range(-19.5, -16.5)
		
		AudioManager.play_sfx(_step_stream, vol, pitch)
		if audible_range > 0.0:
			noise_emitted.emit(global_position, audible_range, kind)
		
		# Backrooms "wrong echo": a rare quieter delayed half-step.
		if randf() < 0.12:
			var t := get_tree().create_timer(randf_range(0.12, 0.22))
			t.timeout.connect(func() -> void:
				if is_instance_valid(self) and has_node("/root/AudioManager"):
					var echo_pitch := pitch * randf_range(0.9, 1.05)
					var echo_vol := vol - 6.0
					AudioManager.play_sfx(_step_stream, echo_vol, echo_pitch))


func _update_look_back() -> void:
	var delta_yaw: float = absf(angle_difference(_facing_ref, rotation.y))
	if not _looked_latched and delta_yaw > deg_to_rad(150.0):
		_looked_latched = true
		if has_node("/root/GameManager"):
			GameManager.register_look_back()
		looked_back.emit()
	elif delta_yaw < deg_to_rad(60.0):
		# Faced forward again — re-arm and re-anchor the reference heading.
		_looked_latched = false
		_facing_ref = rotation.y


# --- Public API ---

func get_camera() -> Camera3D:
	return camera


## Read by this client's fullscreen found-footage overlay. These values never
## affect movement, collision or replication.
func get_camera_motion_mode() -> int:
	return _camera_motion_mode


func get_camera_motion_intensity() -> float:
	return _camera_motion_intensity


func set_frozen(v: bool, release_mouse: bool = true) -> void:
	frozen = v
	if v and release_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Co-op menus block only this client's controls. The world, entity, network
## replication and every gameplay timer continue processing normally.
func set_menu_input_blocked(v: bool) -> void:
	menu_input_blocked = v
	if v:
		velocity = Vector3.ZERO


func set_being_chased(active: bool) -> void:
	is_being_chased = active


func set_red_effect_active(active: bool) -> void:
	red_effect_active = active


## CX30 — plant the camera at crawl height with every handheld impulse cleared.
## Called under the jumpscare's black screen, before a single frame of `downed`
## is revealed, so the fade back in cannot show the drop from eye height, a
## leftover bob/sway, or the shake left over from the execution.
func stabilize_downed_camera() -> void:
	if not is_instance_valid(camera):
		return
	_current_eye_height = DOWNED_EYE_HEIGHT
	_camera_motion_mode = CAMERA_MOTION_IDLE
	_camera_motion_intensity = 0.0
	_camera_motion_position = Vector3.ZERO
	_camera_motion_rotation = Vector3.ZERO
	_was_walking = false
	_bob_time = 0.0
	_prev_bob_cos = 0.0
	_bob_pitch = 0.0
	_heel_spring_position = 0.0
	_heel_spring_velocity = 0.0
	_turn_spring_position = 0.0
	_turn_spring_velocity = 0.0
	_step_lateral_position = 0.0
	_step_lateral_velocity = 0.0
	_step_roll_position = 0.0
	_step_roll_velocity = 0.0
	_stride_frequency_variation = 1.0
	shake_intensity = 0.0
	camera.position = Vector3(0.0, DOWNED_EYE_HEIGHT, 0.0)
	camera.rotation = Vector3(_pitch, 0.0, 0.0)
	_zoom_current_fov = _zoom_target_fov
	_zoom_motion_start_fov = _zoom_target_fov
	_zoom_motion_active = false
	_locomotion_fov_offset = 0.0
	_zoom_focus_pending = false
	_focus_hold_remaining = 0.0
	_focus_blur_amount = 0.0
	if is_instance_valid(_zoom_audio):
		_zoom_audio.stop()
	lens_focus_changed.emit(0.0)
	camera.fov = _zoom_target_fov
	# The execution pulled the near plane in to 0.05; put it back before the
	# world becomes visible again.
	camera.near = 0.08


## Restore the camera after a co-op downed/spectator view.
func restore_first_person_camera() -> void:
	if not is_instance_valid(camera):
		return
	_camera_motion_position = Vector3.ZERO
	_camera_motion_rotation = Vector3.ZERO
	_was_walking = false
	camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	camera.rotation = Vector3(_pitch, 0.0, 0.0)
	_zoom_current_fov = _zoom_target_fov
	_zoom_motion_start_fov = _zoom_target_fov
	_zoom_motion_active = false
	_locomotion_fov_offset = 0.0
	camera.fov = _zoom_target_fov
	camera.near = 0.08


func set_first_person_body_visible(value: bool) -> void:
	if is_instance_valid(_mesh_root):
		_mesh_root.visible = value


## Force one clip from the entity execution sequence. The controller remains
## frozen until set_downed_state(true) clears the sequence after eaten_death.
func play_execution_clip(
		clip_name: String, blend: float = -1.0, playback_speed: float = 1.0) -> bool:
	if _anim_player == null or not _anim_player.has_animation(clip_name):
		return false
	if is_instance_valid(_mesh_root):
		# The teammate sees the replicated body. The victim remains first-person,
		# so rendering its own full body here would intersect the near plane.
		_mesh_root.visible = false
	frozen = true
	velocity = Vector3.ZERO
	is_sprinting = false
	_execution_clip = clip_name
	_anim_player.speed_scale = clampf(playback_speed, 0.1, 4.0)
	var actual_blend := ModelUtils.animation_blend_time(_cur_clip, clip_name) \
		if blend < 0.0 else blend
	_anim_player.play(clip_name, actual_blend)
	_cur_clip = clip_name
	return true


func animation_clip_length(clip_name: String) -> float:
	if _anim_player == null or not _anim_player.has_animation(clip_name):
		return 0.0
	return _anim_player.get_animation(clip_name).length


func get_current_cell(cell_size: float) -> Vector2i:
	return Vector2i(floori(global_position.x / cell_size), floori(global_position.z / cell_size))


## Horizontal velocity expressed in character-local space. X is right/left and
## Y mirrors local Z (negative = W/forward, positive = S/back).
func get_animation_move_direction() -> Vector2:
	var world_move := Vector3(velocity.x, 0.0, velocity.z)
	if world_move.length_squared() <= 0.0001:
		return Vector2.ZERO
	var local_move := global_transform.basis.inverse() * world_move
	return Vector2(local_move.x, local_move.z).normalized()


func _spawn_fp_body() -> void:
	var model_path := "res://assets/characters/survivor_body/player.fbx"
	if not ResourceLoader.exists(model_path):
		return
	
	_mesh_root = Node3D.new()
	_mesh_root.name = "FirstPersonBody"
	add_child(_mesh_root)

	# Criar o Pivot para isolar o modelo FBX e as animações
	var pivot := Node3D.new()
	pivot.name = "Pivot"
	_mesh_root.add_child(pivot)
	
	var packed := load(model_path) as PackedScene
	if packed == null:
		return
	var model := packed.instantiate() as Node3D
	pivot.add_child(model)
	
	# Normais de segurança
	var meshes := model.find_children("*", "MeshInstance3D")
	if meshes.size() > 0:
		var first := meshes[0] as MeshInstance3D
		if first != null and not ModelUtils.has_vertex_normals(first):
			ModelUtils.generate_normals_for_all(model)
			
	# Ligar as texturas CC3 (extraídas do FBX) aos materiais.
	var _bound := ModelUtils.apply_cc3_textures(model)
	print("[DBG] texturas CC3 ligadas: ", _bound, " superfícies")

	# AnimationPlayer dentro do modelo
	_anim_player = AnimationPlayer.new()
	model.add_child(_anim_player)
	
	var skeleton: Skeleton3D = null
	for n in model.find_children("*", "Skeleton3D"):
		skeleton = n as Skeleton3D
		break
	if skeleton != null:
		_body_skeleton = skeleton
		_cache_body_bones()
		var rel_path := String(model.get_path_to(skeleton))
		var lib := ModelUtils.build_survivor_library_for(skeleton, rel_path)
		_anim_player.add_animation_library("", lib)
		ModelUtils.set_animation_loops(_anim_player)

		print("Animações reais no modelo: ", _anim_player.get_animation_list())

		if _anim_player.has_animation("idle"):
			_anim_player.play("idle")
			_cur_clip = "idle"

		# Avançar o frame para forçar o esqueleto a assumir a pose inicial
		_anim_player.advance(0)



	# Escala/altura no PIVOT. O CC3 (player.fbx) importa de pé e em metros, por isso
	# NÃO leva o tilt -90° X que o modelo Mixamo antigo precisava. O facing (180° Y)
	# fica no `model` abaixo — a validar visualmente no primeiro run.
	ModelUtils.scale_to_height(pivot, 1.8)
	pivot.rotation_degrees = Vector3(0.0, 0.0, 0.0)

	# Assentar no chão de forma limpa
	var local_aabb := ModelUtils._get_combined_aabb(pivot)
	pivot.position = Vector3(0, -local_aabb.position.y, 0)
	_fp_pivot = pivot
	_stand_ground_offset = pivot.position.y

	# O MeshRoot fica no eixo físico; o Pivot compensa abaixo o root motion de cada pose baixa.
	_mesh_root.position = Vector3.ZERO

	# ... (quando configuras a rotação do modelo)
	if is_instance_valid(model):
		model.rotation_degrees = Vector3(0.0, 180.0, 0.0)
	_mesh_root.visible = is_downed

func _update_body_animation() -> void:
	if _mesh_root != null and is_instance_valid(_mesh_root):
		# Local camera remains first-person throughout execution and bleedout.
		# RemotePlayer owns the body that the teammate sees.
		_mesh_root.visible = false
	if _anim_player == null:
		return
	# Lying clips (downed/crawl/fall/dead) must sit on the floor. Ground by the
	# posed skeleton's actual lowest bone so it works whether the clip is authored
	# on the floor or floating — no fixed drop that over/under-shoots. No per-frame
	# seek (that caused camera jitter); smoothed so pose noise never shows.
	if _fp_pivot != null and is_instance_valid(_fp_pivot):
		var execution_on_floor := _execution_clip in [
			"player_eaten_start", "player_eaten_loop", "player_eaten_death"]
		var low_pose := is_downed or is_dead or execution_on_floor or _is_slipping
		var target_y: float = _grounded_pivot_y() if low_pose else _stand_ground_offset
		# Lying poses must reach the carpet on the same frame. Standing corrections
		# remain smoothed to avoid visible foot jitter.
		if low_pose:
			_fp_pivot.position.y = target_y
		else:
			_fp_pivot.position.y = target_y if target_y > _fp_pivot.position.y else lerpf(_fp_pivot.position.y, target_y, 0.2)
		# CharacterBody motion owns X/Z. Imported low poses may translate the hips
		# almost a metre, which makes the visible body orbit when mouse yaw changes.
		var lock_low_pose := _execution_clip == "" and (is_downed or is_crouching)
		if lock_low_pose:
			var centered := _centered_pose_pivot_xz()
			_fp_pivot.position.x = centered.x
			_fp_pivot.position.z = centered.y
		else:
			_fp_pivot.position.x = lerpf(_fp_pivot.position.x, 0.0, 0.25)
			_fp_pivot.position.z = lerpf(_fp_pivot.position.z, 0.0, 0.25)
	# Execution phases are advanced by EntityDirector. Even when a one-shot ends,
	# hold its final pose instead of returning to idle between paired clips.
	if _execution_clip != "":
		return
	if _is_slipping:
		if _anim_player.has_animation("player_slip_getup") \
				and _anim_player.current_animation != "player_slip_getup":
			_anim_player.play("player_slip_getup", 0.12)
		_cur_clip = "player_slip_getup"
		return
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var want := "idle"
	if is_dead:
		want = "dead"
		_anim_player.speed_scale = 1.0
	elif is_downed:
		# A downed player is always on the floor; don't gate the crawl on
		# is_on_floor() (it flickers and leaves the blend stuck half-way between
		# downed and crawl_down, which reads as "body frozen, one leg twitching").
		want = "crawl_down" if horizontal_speed > 0.12 else "downed"
		_anim_player.speed_scale = 1.0
	elif is_reviving:
		want = "revive"
		_anim_player.speed_scale = 1.0
	elif is_crouching:
		if horizontal_speed > 0.3 and is_on_floor() and not frozen:
			var crouch_directional := ModelUtils.directional_walk_clip(get_animation_move_direction(), true)
			want = crouch_directional if _anim_player.has_animation(crouch_directional) else "crouch_walk"
		else:
			want = "crouch_idle"
		_anim_player.speed_scale = 1.0
	elif horizontal_speed > 0.3 and is_on_floor() and not frozen:
		if is_sprinting:
			want = "run"
		else:
			var directional := ModelUtils.directional_walk_clip(get_animation_move_direction(), false)
			want = directional if _anim_player.has_animation(directional) else "walk"
		_anim_player.speed_scale = 1.0
	else:
		want = "idle"
		_anim_player.speed_scale = 1.0

	if want == _cur_clip:
		return

	if _anim_player.has_animation(want):
		ModelUtils.play_locomotion(
			_anim_player, want, _cur_clip, -1.0,
			ModelUtils.SURVIVOR_LOCOMOTION_PHASES)
		_cur_clip = want
	elif want == "crawl_down" and _anim_player.has_animation("crawl"):
		_anim_player.play("crawl", ModelUtils.animation_blend_time(_cur_clip, "crawl"))
		_cur_clip = "crawl"
	elif _anim_player.has_animation("ual1_Idle"):
		_anim_player.play("ual1_Idle")
		_cur_clip = "ual1_Idle"


func set_downed_state(value: bool) -> void:
	is_downed = value
	is_reviving = false
	is_crouching = value
	velocity = Vector3.ZERO
	_execution_clip = ""
	if is_instance_valid(_anim_player):
		_anim_player.speed_scale = 1.0
	if value:
		# eaten_death has completed; the revivable victim now rests in downed and
		# may move, at which point normal logic selects crawl_down.
		frozen = false
	else:
		frozen = false
	_update_body_animation()


## The pivot.y that plants the CURRENT posed body's lowest bone on the floor
## (floor ≈ mesh_root Y=0), regardless of how the clip was authored. Returns the
## current pivot.y unchanged if the measurement looks wild.
func _grounded_pivot_y() -> float:
	if _fp_pivot == null or _mesh_root == null or not is_instance_valid(_body_skeleton):
		return _stand_ground_offset
	var lowest := INF
	for i in _ground_bone_indices:
		var wp: Vector3 = _body_skeleton.global_transform \
			* _body_skeleton.get_bone_global_pose(i).origin
		var ly := _mesh_root.to_local(wp).y
		if ly < lowest:
			lowest = ly
	if lowest == INF:
		return _fp_pivot.position.y
	var target := _fp_pivot.position.y - lowest + 0.05
	# Reject a wild measurement rather than teleport the body.
	if absf(target - _fp_pivot.position.y) > 3.0:
		return _fp_pivot.position.y
	return target


## Cache the humanoid subset once. Bone names and hierarchy do not change while
## the model is alive; only their poses do.
var _head_bone_idx := -1

func _cache_body_bones() -> void:
	_ground_bone_indices.clear()
	_hips_bone_idx = -1
	_head_bone_idx = -1
	if not is_instance_valid(_body_skeleton):
		return
	for i in range(_body_skeleton.get_bone_count()):
		var canonical := ModelUtils.canonical_bone(_body_skeleton.get_bone_name(i))
		if canonical == "":
			continue
		_ground_bone_indices.append(i)
		if canonical == "hips" and _hips_bone_idx < 0:
			_hips_bone_idx = i
		if (canonical == "head" or canonical == "neck") and _head_bone_idx < 0:
			_head_bone_idx = i

func _get_animated_head_height() -> float:
	if is_instance_valid(_body_skeleton) and _head_bone_idx >= 0:
		var bone_world_pos := _body_skeleton.global_transform * _body_skeleton.get_bone_global_pose(_head_bone_idx).origin
		var rel_y := bone_world_pos.y - global_position.y
		return clampf(rel_y, 0.20, EYE_HEIGHT)
	elif is_instance_valid(_body_skeleton) and _hips_bone_idx >= 0:
		var hips_world_pos := _body_skeleton.global_transform * _body_skeleton.get_bone_global_pose(_hips_bone_idx).origin
		var rel_y := hips_world_pos.y - global_position.y + 0.55
		return clampf(rel_y, 0.20, EYE_HEIGHT)
	return -1.0


func _centered_pose_pivot_xz() -> Vector2:
	if not is_instance_valid(_body_skeleton) or _hips_bone_idx < 0:
		return Vector2(_fp_pivot.position.x, _fp_pivot.position.z)
	var world_position := _body_skeleton.global_transform \
		* _body_skeleton.get_bone_global_pose(_hips_bone_idx).origin
	var local_position := _mesh_root.to_local(world_position)
	var current := Vector2(_fp_pivot.position.x, _fp_pivot.position.z)
	var target := current - Vector2(local_position.x, local_position.z)
	return target if target.distance_to(current) <= 3.0 else current


func is_bone_to_collapse(_skeleton: Skeleton3D, _bone_idx: int) -> bool:
	# DISABLED. The first-person body is hidden as a whole while standing
	# (_mesh_root.visible = is_downed), so collapsing the upper-body bones served
	# no purpose — and it permanently wrecked their rest pose (scale 0.0001, no
	# rotation) plus stripped their tracks, which left the body split and broken
	# the moment it became visible while downed. Keeping the full rig intact.
	return false


func _update_bone_collapse() -> void:
	if _mesh_root == null or not is_instance_valid(_mesh_root):
		return
	var skeletons := _mesh_root.find_children("*", "Skeleton3D")
	if skeletons.size() > 0:
		var skeleton: Skeleton3D = skeletons[0]
		var should_collapse := not is_downed
		for i in range(skeleton.get_bone_count()):
			if is_bone_to_collapse(skeleton, i):
				var scale_val := Vector3(0.0001, 0.0001, 0.0001) if should_collapse else Vector3.ONE
				skeleton.set_bone_pose_scale(i, scale_val)


func _hide_head() -> void:
	_update_bone_collapse()
