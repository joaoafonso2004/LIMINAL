extends CharacterBody3D
## A networked puppet body for another player. Never reads input — its
## transform is driven entirely by network messages via update_target().

signal footstep_emitted(world_position: Vector3, audible_range: float, kind: String)

const MODEL_PATH := "res://assets/characters/survivor_body/player.fbx"
const STEP_PATH := "res://assets/audio/sfx/player/player_player_step_carpet.mp3"

const LERP_WEIGHT := 12.0
const WALK_THRESHOLD := 0.6

@export var player_id: int = -1

var _mesh_root: Node3D
var _pivot: Node3D                      # holds the model (used to re-ground lying poses)
var _stand_ground_y: float = 0.0       # static pivot Y that grounds the standing pose
var _anim_player: AnimationPlayer
var _cur_clip: String = ""
var _execution_clip := ""              # replicated victim sequence before downed
var _body_skeleton: Skeleton3D = null
var _ground_bone_indices := PackedInt32Array()
var _hips_bone_idx := -1
var _head_bone_idx := -1

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
var _net_move_direction := Vector2.ZERO
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
		# Encapsular o modelo remoto no Pivot
		var pivot := Node3D.new()
		pivot.name = "Pivot"
		_mesh_root.add_child(pivot)
		pivot.add_child(model)
		_pivot = pivot
		_setup_model(pivot, model)
	else:
		_build_fallback_body()


## Mark remote player as downed (collapsed to floor) or revived.
func set_downed(v: bool) -> void:
	is_downed = v
	_execution_clip = ""
	if is_instance_valid(_anim_player):
		_anim_player.speed_scale = 1.0
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


## Display a teammate's synchronized victim animation while their own client
## remains authoritative over the sequence timing.
func play_execution_clip(
		clip_name: String, blend: float = -1.0, playback_speed: float = 1.0) -> bool:
	if _anim_player == null or not _anim_player.has_animation(clip_name):
		return false
	_execution_clip = clip_name
	_anim_player.speed_scale = clampf(playback_speed, 0.1, 4.0)
	var actual_blend := ModelUtils.animation_blend_time(_cur_clip, clip_name) \
		if blend < 0.0 else blend
	_anim_player.play(clip_name, actual_blend)
	_cur_clip = clip_name
	return true


## Host-side Entity perception must apply the same crouch detection range to a
## replicated survivor that the local controller receives.
func network_is_crouching() -> bool:
	return _net_crouching


## Load and instance the survivor GLB, or null if unavailable.
func _load_model() -> Node3D:
	var path := MODEL_PATH
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate() as Node3D
	return instance


## Configure a successfully-loaded model: scale, normals, animation.
func _setup_model(pivot: Node3D, model: Node3D) -> void:
	_apply_player_tint(model)

	# 1. Aplicar a correção do Mixamo estritamente na malha/modelo,
	# mantendo o Pivot e os eixos verticais do motor intactos (resolve o afundar no chão).
	model.rotation_degrees = Vector3(0.0, 180.0, 0.0)

	var meshes := model.find_children("*", "MeshInstance3D")
	if meshes.size() > 0:
		var first := meshes[0] as MeshInstance3D
		if first != null and not ModelUtils.has_vertex_normals(first):
			ModelUtils.generate_normals_for_all(model)

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

		if _anim_player.has_animation("idle"):
			_anim_player.play("idle")
			_cur_clip = "idle"

		_anim_player.advance(0)

	# 2. Escala e grounding limpos aplicados no Pivot (agora com o Y perfeitamente vertical)
	ModelUtils.scale_to_height(pivot, 1.8)
	ModelUtils.ground_character_by_pose(pivot, _anim_player)
	_stand_ground_y = pivot.position.y


func _apply_player_tint(model: Node3D) -> void:
	ModelUtils.apply_cc3_textures(model)
	var tint: Color = PLAYER_TINTS[posmod(player_id, PLAYER_TINTS.size())]
	_setup_overhead_tag(tint)
	set_meta("player_tint", tint)


func _setup_overhead_tag(_tint: Color) -> void:
	pass


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


## The pivot.y that plants the current posed body's lowest bone on the floor
## (floor ≈ mesh_root Y=0), regardless of clip authoring. Keeps current on a
## wild measurement.
func _grounded_pivot_y() -> float:
	if _pivot == null or _mesh_root == null or not is_instance_valid(_body_skeleton):
		return _stand_ground_y
	var lowest := INF
	for i in _ground_bone_indices:
		var wp: Vector3 = _body_skeleton.global_transform \
			* _body_skeleton.get_bone_global_pose(i).origin
		var ly := _mesh_root.to_local(wp).y
		if ly < lowest:
			lowest = ly
	if lowest == INF:
		return _pivot.position.y
	var target := _pivot.position.y - lowest + 0.05
	if absf(target - _pivot.position.y) > 3.0:
		return _pivot.position.y
	return target


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
	# Preserve the exact lookup order used before CX18; caching must not start
	# driving a different bone on rigs with auxiliary head/neck joints.
	for head_name in ["Head", "head", "Neck", "neck_01"]:
		_head_bone_idx = _body_skeleton.find_bone(head_name)
		if _head_bone_idx >= 0:
			break


func _centered_pose_pivot_xz() -> Vector2:
	if not is_instance_valid(_body_skeleton) or _hips_bone_idx < 0:
		return Vector2(_pivot.position.x, _pivot.position.z)
	var world_position := _body_skeleton.global_transform \
		* _body_skeleton.get_bone_global_pose(_hips_bone_idx).origin
	var local_position := _mesh_root.to_local(world_position)
	var current := Vector2(_pivot.position.x, _pivot.position.z)
	var target := current - Vector2(local_position.x, local_position.z)
	return target if target.distance_to(current) <= 3.0 else current


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
	_net_move_direction = Vector2(float(msg.get("mx", 0.0)), float(msg.get("mz", -1.0))).normalized()

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
	if _mesh_root == null or not is_instance_valid(_mesh_root) \
			or not is_instance_valid(_body_skeleton) or _head_bone_idx < 0:
		return
	# Layer the look pitch ONTO the bone's rest orientation. Writing a raw
	# Quaternion(RIGHT, pitch) wiped the head's correct base pose and could
	# snap it hard; composing with the rest keeps the head where it belongs.
	var rest_q := _body_skeleton.get_bone_rest(_head_bone_idx).basis.get_rotation_quaternion()
	var pitch := clampf(_current_pitch, -0.7, 0.7)
	_body_skeleton.set_bone_pose_rotation(
		_head_bone_idx, rest_q * Quaternion(Vector3.RIGHT, pitch))


func _tick_crouch_posture(delta: float) -> void:
	if _mesh_root == null:
		return
	# The crouch_idle/crouch_walk clips now do the crouching. The old vertical
	# squash + lower here double-crouched the body and, being a non-uniform scale
	# on a skinned mesh, twisted the legs into the floor — so keep the body neutral.
	var lerp_speed := 14.0 * delta
	_mesh_root.position.y = lerpf(_mesh_root.position.y, 0.0, lerp_speed)
	_mesh_root.scale = _mesh_root.scale.lerp(Vector3.ONE, lerp_speed)
	_mesh_root.rotation.x = lerpf(_mesh_root.rotation.x, 0.0, lerp_speed)


func _update_animation() -> void:
	if _anim_player == null:
		return
	# Ground EVERY pose (standing, crouch, lying) by the posed skeleton's actual
	# lowest bone so the visible body never floats or clips — smoothed.
	if _pivot != null and is_instance_valid(_pivot):
		var target_y := _grounded_pivot_y()
		var snap_low_pose := is_downed or _execution_clip != "" \
			or (_net_crouching and _speed_smooth <= WALK_THRESHOLD)
		if snap_low_pose:
			_pivot.position.y = target_y
		else:
			_pivot.position.y = target_y if target_y > _pivot.position.y else lerpf(_pivot.position.y, target_y, 0.2)
		# Keep low poses centred on the replicated CharacterBody. Otherwise their
		# Mixamo hips offset rotates in a circle whenever network yaw changes.
		var lock_low_pose := _execution_clip == "" and (is_downed or _net_crouching)
		if lock_low_pose:
			var centered := _centered_pose_pivot_xz()
			_pivot.position.x = centered.x
			_pivot.position.z = centered.y
		else:
			_pivot.position.x = lerpf(_pivot.position.x, 0.0, 0.25)
			_pivot.position.z = lerpf(_pivot.position.z, 0.0, 0.25)
	# The next replicated execution phase (or set_downed) releases this hold.
	if _execution_clip != "":
		return

	var want := "idle"
	if is_downed:
		want = "crawl_down" if _speed_smooth > WALK_THRESHOLD else "downed"
		_anim_player.speed_scale = 1.0
	elif is_reviving:
		want = "revive"
		_anim_player.speed_scale = 1.0
	elif _net_crouching:
		if _speed_smooth > WALK_THRESHOLD:
			var crouch_directional := ModelUtils.directional_walk_clip(_net_move_direction, true)
			want = crouch_directional if _anim_player.has_animation(crouch_directional) else "crouch_walk"
		else:
			want = "crouch_idle"
		_anim_player.speed_scale = 1.0
	elif _speed_smooth > WALK_THRESHOLD:
		if _net_sprinting:
			want = "run"
		else:
			var directional := ModelUtils.directional_walk_clip(_net_move_direction, false)
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
