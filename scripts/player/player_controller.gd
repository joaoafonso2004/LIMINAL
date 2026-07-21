extends CharacterBody3D
## LIMINAL — first-person Backrooms walker.
## Deliberate walking with a short, noisy panic sprint. No jump or flashlight.
## Builds its own child nodes in code, so it can be attached to a bare
## CharacterBody3D with no .tscn dependency.

signal looked_back
signal noise_emitted(world_position: Vector3, audible_range: float, kind: String)
signal sprint_state_changed(active: bool, stamina_ratio: float)

@export var speed: float = Tuning.WALK_SPEED
@export var gravity: float = 20.0
@export var mouse_sensitivity: float = 0.0022
@export var accel: float = 10.0
@export var friction: float = 12.0

var frozen: bool = false
var menu_input_blocked: bool = false
var is_downed: bool = false

const EYE_HEIGHT: float = 1.55
const BOB_SPEED: float = 7.0
const BOB_AMOUNT: float = 0.035
const STEP_TILT: float = 0.008          # rad (~0.45°) — camera rolls to alternate sides each stride
const IDLE_TILT: float = 0.0022         # faint breathing roll when standing still
const STEP_SFX_PATH: String = "res://assets/audio/sfx/player/player_player_step_carpet.mp3"

var camera: Camera3D

var _bob_time: float = 0.0
var _idle_time: float = 0.0
var _prev_bob_cos: float = 0.0
# Look pitch is the PLAYER's; the bob may only add a tiny offset on top.
# (Writing camera.rotation.x directly from the bob erased mouse pitch.)
var _pitch: float = 0.0
var _bob_pitch: float = 0.0

var _step_stream: AudioStream = null
var shake_intensity: float = 0.0

var _mesh_root: Node3D
var _anim_player: AnimationPlayer
var _cur_clip: String = ""
var is_crouching: bool = false
var is_sprinting: bool = false
var is_downed: bool = false
var is_dead: bool = false
var is_reviving: bool = false
var sprint_seconds: float = Tuning.SPRINT_MAX_SECONDS
var _current_eye_height: float = EYE_HEIGHT
var _sprint_regen_delay: float = 0.0
var _sprint_exhausted: bool = false
var _last_sprint_active: bool = false
var _last_stamina_bucket: int = 10

# Look-back tracking.
var _facing_ref: float = 0.0
var _looked_latched: bool = false


func _ready() -> void:
	collision_layer = 2   # player
	collision_mask = 1    # environment

	# Camera first — built before anything that could fail.
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.position.y = EYE_HEIGHT
	# Safe near clip plane so standing close to walls doesn't clip through them
	camera.near = 0.08
	camera.fov = 72.0
	add_child(camera)
	camera.make_current()

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

	_facing_ref = rotation.y
	_spawn_fp_body()


var is_holding_breath: bool = false


func _unhandled_input(event: InputEvent) -> void:
	var is_hiding: bool = bool(get_meta("is_hiding", false))
	# Click-to-recapture — pointer lock needs a user gesture on web.
	if event is InputEventMouseButton and event.pressed:
		if not menu_input_blocked and (not frozen or is_hiding) and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	if (frozen or menu_input_blocked) and not is_hiding:
		return

	# Mouse-look only while captured. User multiplier from the options menu.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		var sens := mouse_sensitivity
		if has_node("/root/Settings"):
			sens *= Settings.mouse_sensitivity
		rotation.y -= motion.relative.x * sens
		_pitch = clampf(_pitch - motion.relative.y * sens, -1.2 if is_hiding else -1.4, 1.2 if is_hiding else 1.4)
		if is_hiding and is_instance_valid(camera):
			camera.rotation.x = _pitch


func _physics_process(delta: float) -> void:
	var is_hiding: bool = bool(get_meta("is_hiding", false))
	if is_hiding:
		velocity = Vector3.ZERO
		camera.position.x = lerpf(camera.position.x, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		camera.position.y = lerpf(camera.position.y, EYE_HEIGHT, clampf(delta * 10.0, 0.0, 1.0))
		camera.rotation.x = _pitch
		camera.rotation.z = lerpf(camera.rotation.z, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		# Hold breath while hiding in locker (Space or Right Mouse Button)
		is_holding_breath = Input.is_physical_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		return
	else:
		is_holding_breath = false

	if frozen or menu_input_blocked:
		velocity = Vector3.ZERO
		return

	# Crouching check (Ctrl or C key)
	var wants_crouch := Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_C)
	is_crouching = wants_crouch

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var is_trying_to_move := input_dir.length() > 0.1
	_update_sprint(delta, is_trying_to_move)
	var target_fov := 78.0 if is_sprinting else (70.0 if _sprint_exhausted else 72.0)
	camera.fov = lerpf(camera.fov, target_fov, clampf(delta * 5.0, 0.0, 1.0))

	var target_speed := speed
	var target_eye_height := EYE_HEIGHT
	var target_mesh_scale_y := 1.0

	if is_downed:
		is_crouching = true
		is_sprinting = false
		target_speed = 0.85 # Slow crawling speed while downed
		target_eye_height = 0.35 # Carpet level camera
		target_mesh_scale_y = 0.38
	elif is_crouching:
		target_speed = Tuning.CROUCH_SPEED
		target_eye_height = 0.85
		target_mesh_scale_y = 0.62
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
	if direction.length() > 0.001:
		velocity.x = move_toward(velocity.x, target.x, accel * delta)
		velocity.z = move_toward(velocity.z, target.z, accel * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, friction * delta)
		velocity.z = move_toward(velocity.z, 0.0, friction * delta)

	move_and_slide()

	_update_head_bob(delta)
	_update_look_back()
	_update_body_animation()
	_hide_head()


func _update_sprint(delta: float, is_trying_to_move: bool) -> void:
	var wants_sprint := sprint_enabled and Input.is_action_pressed("sprint")
	var can_sprint := not is_crouching and not _sprint_exhausted and sprint_seconds > 0.0
	is_sprinting = wants_sprint and is_trying_to_move and can_sprint

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
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var walking := is_on_floor() and horizontal_speed > 0.3

	_idle_time += delta
	var idle_sway := sin(_idle_time * 1.3) * 0.006 + cos(_idle_time * 0.7) * 0.004

	if walking:
		# Scale step frequency with movement speed
		var speed_mult := clampf(horizontal_speed / speed, 0.5, 1.8)
		_bob_time += delta * BOB_SPEED * speed_mult
		
		var bob_sin: float = sin(_bob_time)
		var bob_cos: float = cos(_bob_time)
		
		# Vertical dip: double-frequency absolute sine creates the heel-strike bounce
		var vertical_dip: float = -absf(bob_sin) * BOB_AMOUNT
		
		# Horizontal sway: single-frequency weight shift
		var horizontal_sway: float = bob_cos * (BOB_AMOUNT * 0.45)
		
		camera.position.y = _current_eye_height + vertical_dip + idle_sway
		camera.position.x = horizontal_sway
		
		# Rotate Z (roll) for side-to-side sway and tilt camera down slightly on heel strikes
		camera.rotation.z = -bob_sin * STEP_TILT
		_bob_pitch = lerpf(_bob_pitch, -absf(bob_sin) * 0.006, clampf(8.0 * delta, 0.0, 1.0))

		# Trigger footstep at the bottom of the dip (where cos crosses zero)
		if (_prev_bob_cos >= 0.0 and bob_cos < 0.0) or (_prev_bob_cos <= 0.0 and bob_cos > 0.0):
			_play_footstep()
		_prev_bob_cos = bob_cos
	else:
		# Premium figure-8 breathing sway in 3D space when idle
		var idle_sway_x := sin(_idle_time * 0.8) * 0.008
		var idle_sway_y := cos(_idle_time * 1.4) * 0.006
		var base := _current_eye_height + idle_sway + idle_sway_y
		camera.position.y = lerpf(camera.position.y, base, clampf(delta * 6.0, 0.0, 1.0))
		camera.position.x = lerpf(camera.position.x, idle_sway_x, clampf(delta * 6.0, 0.0, 1.0))

		var idle_roll := sin(_idle_time * 0.9) * IDLE_TILT
		camera.rotation.z = lerpf(camera.rotation.z, idle_roll, clampf(delta * 4.0, 0.0, 1.0))
		_bob_pitch = lerpf(_bob_pitch, 0.0, clampf(delta * 6.0, 0.0, 1.0))
		_prev_bob_cos = 0.0

	# Player pitch rules; the bob is only ever a whisper on top of it.
	camera.rotation.x = _pitch + _bob_pitch

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


## Restore the camera after a co-op downed/spectator view.
func restore_first_person_camera() -> void:
	if not is_instance_valid(camera):
		return
	camera.position = Vector3(0.0, EYE_HEIGHT, 0.0)
	camera.rotation = Vector3(_pitch, 0.0, 0.0)
	camera.fov = 72.0


func set_first_person_body_visible(value: bool) -> void:
	if is_instance_valid(_mesh_root):
		_mesh_root.visible = value


func get_current_cell(cell_size: float) -> Vector2i:
	return Vector2i(floori(global_position.x / cell_size), floori(global_position.z / cell_size))


func _spawn_fp_body() -> void:
	var model_path := "res://assets/characters/survivor_body/player.fbx"
	var anim_path := "res://assets/characters/survivor_body/survivor_body_animations.tres"
	if not ResourceLoader.exists(model_path):
		model_path = "res://assets/characters/survivor_body/survivor_body.glb"
		if not ResourceLoader.exists(model_path):
			return
	
	_mesh_root = Node3D.new()
	_mesh_root.name = "FirstPersonBody"
	add_child(_mesh_root)
	
	var packed := load(model_path) as PackedScene
	if packed == null:
		return
	var model := packed.instantiate() as Node3D
	_mesh_root.add_child(model)
	
	# Scale the character
	ModelUtils.scale_to_height(model, 1.8)
	
	# Ground the model locally relative to _mesh_root (so feet bottom is at local Y=0 of player capsule)
	var local_aabb := ModelUtils._get_combined_aabb(model)
	model.position = Vector3(0, -local_aabb.position.y, 0)
	
	# Offset the body mesh backward slightly so the legs are positioned naturally under the player
	_mesh_root.position = Vector3(0, 0, 0.08)
	
	# Guard against dark mesh from missing normals
	var meshes := model.find_children("*", "MeshInstance3D")
	if meshes.size() > 0:
		var first := meshes[0] as MeshInstance3D
		if first != null and not ModelUtils.has_vertex_normals(first):
			ModelUtils.generate_normals_for_all(model)
			
	# Setup AnimationPlayer
	_anim_player = AnimationPlayer.new()
	model.add_child(_anim_player)
	
	if ResourceLoader.exists(anim_path):
		var lib := load(anim_path) as AnimationLibrary
		if lib != null:
			# Make a deep copy of the library to avoid hiding remote player heads in co-op!
			lib = lib.duplicate(true)
			var skeletons := model.find_children("*", "Skeleton3D")
			if skeletons.size() > 0:
				var skeleton: Skeleton3D = skeletons[0]
				# Permanently scale down rest poses of upper body bones so they are completely hidden
				# and never reset to scale 1.0 by the animation engine!
				for i in range(skeleton.get_bone_count()):
					if is_bone_to_collapse(skeleton, i):
						var rest := skeleton.get_bone_rest(i)
						rest.basis = Basis.from_scale(Vector3(0.0001, 0.0001, 0.0001))
						skeleton.set_bone_rest(i, rest)
						skeleton.set_bone_pose_scale(i, Vector3(0.0001, 0.0001, 0.0001))
						
				for anim_name in lib.get_animation_list():
					var anim := lib.get_animation(anim_name)
					if anim != null:
						for track_idx in range(anim.get_track_count() - 1, -1, -1):
							var path := anim.track_get_path(track_idx)
							var bone_name := ""
							if path.get_subname_count() > 0:
								bone_name = path.get_subname(0)
							elif ":" in str(path):
								bone_name = str(path).split(":")[-1]
								
							if bone_name != "":
								var bone_idx := skeleton.find_bone(bone_name)
								if bone_idx != -1 and is_bone_to_collapse(skeleton, bone_idx):
									anim.remove_track(track_idx)
			
			_anim_player.add_animation_library("", lib)
			ModelUtils.set_animation_loops(_anim_player)
			if _anim_player.has_animation("idle"):
				_anim_player.play("idle")
				_cur_clip = "idle"
			elif _anim_player.has_animation("ual1_Idle"):
				_anim_player.play("ual1_Idle")
				_cur_clip = "ual1_Idle"

	# Hide first-person body in 1st person mode so mesh polygons never clip or block the camera lens!
	_mesh_root.visible = is_downed


func _update_body_animation() -> void:
	if _mesh_root != null and is_instance_valid(_mesh_root):
		_mesh_root.visible = is_downed
	_update_bone_collapse()
	if _anim_player == null:
		return
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var want := "idle"
	if is_dead:
		want = "dead"
		_anim_player.speed_scale = 1.0
	elif is_downed:
		want = "crawl_down" if horizontal_speed > 0.08 and is_on_floor() else "downed"
		_anim_player.speed_scale = 1.0
	elif is_reviving:
		want = "revive"
		_anim_player.speed_scale = 1.0
	elif is_crouching:
		want = "crouch_walk" if horizontal_speed > 0.3 and is_on_floor() and not frozen else "crouch_idle"
		_anim_player.speed_scale = 1.0
	elif horizontal_speed > 0.3 and is_on_floor() and not frozen:
		want = "run" if is_sprinting else "walk"
		_anim_player.speed_scale = 1.0
	else:
		want = "idle"
		_anim_player.speed_scale = 1.0

	if want == _cur_clip:
		return

	if _anim_player.has_animation(want):
		_anim_player.play(want, 0.2)
		_cur_clip = want
	elif want == "crawl_down" and _anim_player.has_animation("crawl"):
		_anim_player.play("crawl", 0.2)
		_cur_clip = "crawl"
	elif _anim_player.has_animation("ual1_Idle"):
		_anim_player.play("ual1_Idle")
		_cur_clip = "ual1_Idle"


func is_bone_to_collapse(skeleton: Skeleton3D, bone_idx: int) -> bool:
	var collapse_names := [
		"Spine", "Spine1", "Spine2", "Chest", "UpperChest", "Neck", "Head",
		"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
		"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
		# Unreal-style bone names (player.fbx)
		"spine_01", "spine_02", "spine_03", "neck_01", "head",
		"clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
		"clavicle_r", "upperarm_r", "lowerarm_r", "hand_r"
	]
	var cur := bone_idx
	while cur != -1:
		var bname := skeleton.get_bone_name(cur)
		if collapse_names.has(bname):
			return true
		cur = skeleton.get_bone_parent(cur)
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
