extends CharacterBody3D
## LIMINAL — first-person Backrooms walker.
## Slow deliberate walking only: no run, no jump, no flashlight.
## Builds its own child nodes in code, so it can be attached to a bare
## CharacterBody3D with no .tscn dependency.

signal looked_back

@export var speed: float = 2.4            # slow walk, m/s
@export var gravity: float = 20.0
@export var mouse_sensitivity: float = 0.0022
@export var accel: float = 10.0
@export var friction: float = 12.0

var frozen: bool = false

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
var _current_eye_height: float = EYE_HEIGHT

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


func _unhandled_input(event: InputEvent) -> void:
	# Click-to-recapture — pointer lock needs a user gesture on web.
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	if frozen:
		return

	# Mouse-look only while captured. User multiplier from the options menu.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		var sens := mouse_sensitivity
		if has_node("/root/Settings"):
			sens *= Settings.mouse_sensitivity
		rotation.y -= motion.relative.x * sens
		_pitch = clampf(_pitch - motion.relative.y * sens, -1.4, 1.4)


func _physics_process(delta: float) -> void:
	if frozen:
		# Still settle to ground, but no input-driven movement or bob.
		if not is_on_floor():
			velocity.y -= gravity * delta
		else:
			velocity.y = 0.0
		velocity.x = move_toward(velocity.x, 0.0, friction * delta)
		velocity.z = move_toward(velocity.z, 0.0, friction * delta)
		move_and_slide()
		return

	# Crouching check (Ctrl or C key)
	var wants_crouch := Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_C)
	is_crouching = wants_crouch
	
	var target_speed := speed
	var target_eye_height := EYE_HEIGHT
	var target_mesh_scale_y := 1.0
	
	if is_crouching:
		target_speed = 1.15
		target_eye_height = 0.85
		target_mesh_scale_y = 0.62
		
	# Smoothly transition camera height
	_current_eye_height = lerpf(_current_eye_height, target_eye_height, 10.0 * delta)
	
	# Smoothly squash/stretch the first-person body mesh to simulate crouching
	if _mesh_root and is_instance_valid(_mesh_root):
		_mesh_root.scale.y = lerpf(_mesh_root.scale.y, target_mesh_scale_y, 10.0 * delta)

	# Gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Desired horizontal direction from input.
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
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


func _update_head_bob(delta: float) -> void:
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var walking := is_on_floor() and horizontal_speed > 0.3

	_idle_time += delta
	var idle_sway := sin(_idle_time * 1.3) * 0.006 + cos(_idle_time * 0.7) * 0.004

	if walking:
		# Scale step frequency with movement speed
		var speed_mult := clampf(horizontal_speed / speed, 0.5, 1.3)
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
		if is_crouching:
			vol = -26.0
			pitch = randf_range(0.68, 0.82) # even heavier/softer when crouching!
		else:
			vol = randf_range(-19.5, -16.5)
		
		AudioManager.play_sfx(_step_stream, vol, pitch)
		
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


func set_frozen(v: bool) -> void:
	frozen = v


func get_current_cell(cell_size: float) -> Vector2i:
	return Vector2i(floori(global_position.x / cell_size), floori(global_position.z / cell_size))


func _spawn_fp_body() -> void:
	var model_path := "res://assets/characters/survivor_body/survivor_body.glb"
	var anim_path := "res://assets/characters/survivor_body/survivor_body_animations.tres"
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
	
	# Scale and ground the character
	ModelUtils.setup_character_for_movement(model, 1.8)
	
	# Offset backward slightly so head/face stays behind the camera near plane
	_mesh_root.position = Vector3(0, 0, -0.16)
	
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
				var spine_idx := skeleton.find_bone("Spine")
				if spine_idx != -1:
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
									if bone_idx != -1 and is_descendant_of_spine(skeleton, bone_idx, spine_idx):
										anim.remove_track(track_idx)
			
			_anim_player.add_animation_library("", lib)
			ModelUtils.set_animation_loops(_anim_player)
			if _anim_player.has_animation("ual1_Idle"):
				_anim_player.play("ual1_Idle")
				_cur_clip = "ual1_Idle"


func _update_body_animation() -> void:
	if _anim_player == null:
		return
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var want: String = "ual1_Walk" if horizontal_speed > 0.3 and is_on_floor() and not frozen else "ual1_Idle"
	if want == _cur_clip:
		return
	if _anim_player.has_animation(want):
		_anim_player.play(want)
		_cur_clip = want


func is_descendant_of_spine(skeleton: Skeleton3D, bone_idx: int, spine_idx: int) -> bool:
	if bone_idx == spine_idx:
		return true
	var parent := skeleton.get_bone_parent(bone_idx)
	while parent != -1:
		if parent == spine_idx:
			return true
		parent = skeleton.get_bone_parent(parent)
	return false


func _hide_head() -> void:
	if _mesh_root == null or not is_instance_valid(_mesh_root):
		return
	var skeletons := _mesh_root.find_children("*", "Skeleton3D")
	if skeletons.size() > 0:
		var skeleton: Skeleton3D = skeletons[0]
		
		# Scale down all upper body bones (Spine, Chest, UpperChest, Neck, Head, shoulders, arms, hands)
		# individually to Vector3.ZERO. This hides the entire upper body in first-person, preventing any hollow mesh clipping,
		# while leaving the hips, legs, and feet fully visible when looking down.
		var spine_idx := skeleton.find_bone("Spine")
		if spine_idx != -1:
			for i in range(skeleton.get_bone_count()):
				if is_descendant_of_spine(skeleton, i, spine_idx):
					skeleton.set_bone_pose_scale(i, Vector3.ZERO)
