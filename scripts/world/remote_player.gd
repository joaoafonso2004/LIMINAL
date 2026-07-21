extends CharacterBody3D
## A networked puppet body for another player. Never reads input — its
## transform is driven entirely by network messages via update_target().

signal footstep_emitted(world_position: Vector3, audible_range: float, kind: String)

const MODEL_PATH := "res://assets/characters/survivor_body/survivor_body.glb"
const ANIM_PATH := "res://assets/characters/survivor_body/survivor_body_animations.tres"
const STEP_PATH := "res://assets/audio/sfx/player/player_player_step_carpet.mp3"

const LERP_WEIGHT := 12.0
const WALK_THRESHOLD := 0.6

@export var player_id: int = -1

var _mesh_root: Node3D
var _anim_player: AnimationPlayer
var _cur_clip: String = ""

# Networked smoothing state.
var _target_pos: Vector3
var _target_rot_y: float
var _target_pitch: float = 0.0
var _current_pitch: float = 0.0
var _prev_actual_pos: Vector3
var _speed_smooth: float
var _got_first: bool = false
var _net_sprinting := false
var _net_crouching := false
var _step_distance := 0.0
var _step_stream: AudioStream = null

const PLAYER_TINTS := [
	Color(0.95, 0.76, 0.34),
	Color(0.38, 0.72, 1.0),
	Color(0.48, 0.92, 0.48),
	Color(0.95, 0.46, 0.66),
]


var is_downed := false
var is_reviving := false

func _ready() -> void:
	collision_layer = 4
	collision_mask = 0
	set_meta("player_id", player_id)
	if ResourceLoader.exists(STEP_PATH):
		_step_stream = load(STEP_PATH)

	# Harmless capsule collider for completeness (mask=0, so it never blocks).
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.7
	capsule.radius = 0.3
	col.shape = capsule
	col.position.y = 0.85
	add_child(col)

	_mesh_root = Node3D.new()
	_mesh_root.name = "MeshRoot"
	add_child(_mesh_root)

	var model: Node3D = _load_model()
	if model != null:
		_mesh_root.add_child(model)
		_setup_model(model)
	else:
		_build_fallback_body()


## Mark remote player as downed (collapsed to floor) or revived.
func set_downed(v: bool) -> void:
	is_downed = v
	if is_instance_valid(_mesh_root):
		_mesh_root.position = Vector3.ZERO
		_mesh_root.rotation = Vector3.ZERO
		_mesh_root.scale = Vector3.ONE
		if v:
			if is_instance_valid(_anim_player) and _anim_player.has_animation("downed"):
				_anim_player.play("downed", 0.25)
				_cur_clip = "downed"
		else:
			if is_instance_valid(_anim_player) and _anim_player.has_animation("revive_get_up"):
				_anim_player.play("revive_get_up", 0.2)
				_cur_clip = "revive_get_up"
			elif is_instance_valid(_anim_player) and _anim_player.has_animation("idle"):
				_anim_player.play("idle", 0.2)
				_cur_clip = "idle"


## Load and instance the survivor GLB, or null if unavailable.
func _load_model() -> Node3D:
	if not ResourceLoader.exists(MODEL_PATH):
		return null
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate() as Node3D
	return instance


## Configure a successfully-loaded model: scale, normals, animation.
func _setup_model(model: Node3D) -> void:
	ModelUtils.setup_character_for_movement(model, 1.8)
	_apply_player_tint(model)

	# Guard against a dark mesh from missing vertex normals.
	var meshes := model.find_children("*", "MeshInstance3D")
	if meshes.size() > 0:
		var first := meshes[0] as MeshInstance3D
		if first != null and not ModelUtils.has_vertex_normals(first):
			ModelUtils.generate_normals_for_all(model)

	_anim_player = AnimationPlayer.new()
	model.add_child(_anim_player)

	if ResourceLoader.exists(ANIM_PATH):
		var lib := load(ANIM_PATH) as AnimationLibrary
		if lib != null:
			_anim_player.add_animation_library("", lib)
			ModelUtils.set_animation_loops(_anim_player)
			if _anim_player.has_animation("idle"):
				_anim_player.play("idle")
				_cur_clip = "idle"
			elif _anim_player.has_animation("ual1_Idle"):
				_anim_player.play("ual1_Idle")
				_cur_clip = "ual1_Idle"


func _apply_player_tint(model: Node3D) -> void:
	ModelUtils.fix_character_materials(model)
	var tint: Color = PLAYER_TINTS[posmod(player_id, PLAYER_TINTS.size())]
	_setup_overhead_tag(tint)
	set_meta("player_tint", tint)


func _setup_overhead_tag(tint: Color) -> void:
	if has_node("OverheadTag"):
		return
	var label := Label3D.new()
	label.name = "OverheadTag"
	label.text = "P%02d" % (player_id + 1)
	label.font_size = 32
	label.pixel_size = 0.003
	label.position = Vector3(0, 2.05, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = tint
	label.outline_render_priority = 10
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0, 0.9)
	add_child(label)


## Build a dim capsule so a body is always visible even without the GLB.
func _build_fallback_body() -> void:
	var mi := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.height = 1.7
	mesh.radius = 0.3
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	var tint: Color = PLAYER_TINTS[posmod(player_id, PLAYER_TINTS.size())]
	mat.albedo_color = Color(0.85, 0.82, 0.75) # Natural beige clothes fallback
	mat.metallic = 0.0
	mat.roughness = 0.8
	mat.emission_enabled = false
	mi.material_override = mat
	mi.position.y = 0.85
	_mesh_root.add_child(mi)
	_setup_overhead_tag(tint)


## Apply a network transform update. Snaps on the first update.
func update_target(msg: Dictionary) -> void:
	_target_pos = Vector3(
		float(msg.get("x", 0.0)),
		float(msg.get("y", 0.0)),
		float(msg.get("z", 0.0)))
	_target_rot_y = float(msg.get("ry", 0.0))
	_target_pitch = clampf(float(msg.get("pitch", 0.0)), -1.3, 1.3)
	_net_sprinting = bool(msg.get("spr", false))
	_net_crouching = bool(msg.get("cr", false))

	if not _got_first:
		_got_first = true
		global_position = _target_pos
		rotation.y = _target_rot_y
		_current_pitch = _target_pitch
		_prev_actual_pos = _target_pos


## Teammate fully dead: collapse body to the floor (visible, not hidden).
func set_dead(v: bool) -> void:
	if _mesh_root == null:
		return
	if v:
		if is_instance_valid(_anim_player) and _anim_player.has_animation("dead"):
			_anim_player.play("dead", 0.3)
			_cur_clip = "dead"
		else:
			var tw := create_tween()
			tw.tween_property(_mesh_root, "rotation:x", -PI * 0.5, 0.5)
	else:
		var tw := create_tween()
		tw.tween_property(_mesh_root, "rotation:x", 0.0, 0.35)


func _process(delta: float) -> void:
	if not _got_first:
		return

	var w: float = clamp(LERP_WEIGHT * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, w)
	rotation.y = lerp_angle(rotation.y, _target_rot_y, w)
	_current_pitch = lerpf(_current_pitch, _target_pitch, 12.0 * delta)
	_apply_head_pitch()

	var moved: float = (global_position - _prev_actual_pos).length() / maxf(delta, 0.001)
	var frame_distance := global_position.distance_to(_prev_actual_pos)
	_prev_actual_pos = global_position
	_speed_smooth = lerp(_speed_smooth, moved, 10.0 * delta)
	if _speed_smooth > WALK_THRESHOLD and not is_downed:
		_step_distance += frame_distance
		var stride := 1.05 if _net_sprinting else (1.65 if _net_crouching else 1.35)
		if _step_distance >= stride:
			_step_distance = 0.0
			_play_remote_step()

	_tick_crouch_posture(delta)
	_update_animation()


func _apply_head_pitch() -> void:
	if _mesh_root == null or not is_instance_valid(_mesh_root):
		return
	var skeletons := _mesh_root.find_children("*", "Skeleton3D")
	if skeletons.size() == 0:
		return
	var skeleton: Skeleton3D = skeletons[0]
	var head_idx := skeleton.find_bone("Head")
	if head_idx == -1:
		head_idx = skeleton.find_bone("Neck")
	if head_idx != -1:
		# Pitch head up/down following remote player's camera pitch angle
		var q := Quaternion(Vector3.RIGHT, _current_pitch)
		skeleton.set_bone_pose_rotation(head_idx, q)


func _tick_crouch_posture(delta: float) -> void:
	if _mesh_root == null:
		return
	var target_y := 0.0
	var target_scale := Vector3.ONE
	var target_rot_x := 0.0
	if not is_downed and _net_crouching:
		target_y = -0.45
		target_scale = Vector3(1.08, 0.72, 1.08)
		target_rot_x = 0.22

	var lerp_speed := 14.0 * delta
	_mesh_root.position.y = lerpf(_mesh_root.position.y, target_y, lerp_speed)
	_mesh_root.scale = _mesh_root.scale.lerp(target_scale, lerp_speed)
	_mesh_root.rotation.x = lerpf(_mesh_root.rotation.x, target_rot_x, lerp_speed)


func _update_animation() -> void:
	if _anim_player == null:
		return

	var want := "idle"
	if is_downed:
		want = "crawl_down" if _speed_smooth > WALK_THRESHOLD else "downed"
		_anim_player.speed_scale = 1.0
	elif is_reviving:
		want = "revive"
		_anim_player.speed_scale = 1.0
	elif _net_crouching:
		want = "crouch_walk" if _speed_smooth > WALK_THRESHOLD else "crouch_idle"
		_anim_player.speed_scale = 1.0
	elif _speed_smooth > WALK_THRESHOLD:
		want = "run" if _net_sprinting else "walk"
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
	elif _anim_player.has_animation("ual1_Walk") and _speed_smooth > WALK_THRESHOLD:
		_anim_player.play("ual1_Walk", 0.2)
		_cur_clip = "ual1_Walk"


func _play_remote_step() -> void:
	if _step_stream == null or not has_node("/root/AudioManager"):
		return
	var volume := -18.0
	var pitch := randf_range(0.78, 0.94)
	var audible_range := Tuning.NOISE_RANGE_WALK
	var kind := "walk"
	if _net_sprinting:
		volume = -10.0
		pitch = randf_range(0.94, 1.08)
		audible_range = Tuning.NOISE_RANGE_SPRINT
		kind = "sprint"
	elif _net_crouching:
		volume = -27.0
		pitch = randf_range(0.68, 0.82)
		audible_range = Tuning.NOISE_RANGE_CROUCH
		kind = "crouch"
	AudioManager.play_sfx_3d(self, _step_stream, global_position, volume, 30.0, pitch)
	footstep_emitted.emit(global_position, audible_range, kind)
