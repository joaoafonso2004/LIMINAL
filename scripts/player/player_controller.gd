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
var _prev_bob_sin: float = 0.0

var _step_stream: AudioStream = null

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
	camera.near = 0.05
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


func _unhandled_input(event: InputEvent) -> void:
	# Click-to-recapture — pointer lock needs a user gesture on web.
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	if frozen:
		return

	# Mouse-look only while captured.
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotation.y -= motion.relative.x * mouse_sensitivity
		camera.rotation.x -= motion.relative.y * mouse_sensitivity
		camera.rotation.x = clampf(camera.rotation.x, -1.4, 1.4)


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
	var target := direction * speed
	if direction.length() > 0.001:
		velocity.x = move_toward(velocity.x, target.x, accel * delta)
		velocity.z = move_toward(velocity.z, target.z, accel * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, friction * delta)
		velocity.z = move_toward(velocity.z, 0.0, friction * delta)

	move_and_slide()

	_update_head_bob(delta)
	_update_look_back()


func _update_head_bob(delta: float) -> void:
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var walking := is_on_floor() and horizontal_speed > 0.3

	_idle_time += delta
	var idle_sway := sin(_idle_time * 1.3) * 0.006 + cos(_idle_time * 0.7) * 0.004

	if walking:
		_bob_time += delta * BOB_SPEED
		var bob_sin := sin(_bob_time)
		camera.position.y = EYE_HEIGHT + bob_sin * BOB_AMOUNT + idle_sway
		# Weight shift: half-frequency roll flips side on every stride —
		# a subtle left-right head tilt in step with the footfalls.
		camera.rotation.z = sin(_bob_time * 0.5) * STEP_TILT

		# A full stride: sine crosses its low point (from below-zero back up).
		if _prev_bob_sin <= 0.0 and bob_sin > 0.0:
			_play_footstep()
		_prev_bob_sin = bob_sin
	else:
		# Ease back to base eye height plus subtle idle sway and breathing roll.
		var base := EYE_HEIGHT + idle_sway
		camera.position.y = lerpf(camera.position.y, base, clampf(delta * 6.0, 0.0, 1.0))
		var idle_roll := sin(_idle_time * 0.9) * IDLE_TILT
		camera.rotation.z = lerpf(camera.rotation.z, idle_roll, clampf(delta * 4.0, 0.0, 1.0))
		_prev_bob_sin = 0.0


func _play_footstep() -> void:
	if _step_stream == null:
		return
	if has_node("/root/AudioManager"):
		AudioManager.play_sfx(_step_stream, -14.0, randf_range(0.9, 1.08))
		# Backrooms "wrong echo": a rare quieter delayed half-step.
		if randf() < 0.12:
			var t := get_tree().create_timer(randf_range(0.12, 0.22))
			t.timeout.connect(func() -> void:
				if is_instance_valid(self) and has_node("/root/AudioManager"):
					AudioManager.play_sfx(_step_stream, -20.0, randf_range(0.9, 1.05)))


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
