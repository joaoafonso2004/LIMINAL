extends CharacterBody3D
## A networked puppet body for another player. Never reads input — its
## transform is driven entirely by network messages via update_target().

const MODEL_PATH := "res://assets/characters/survivor_body/survivor_body.glb"
const ANIM_PATH := "res://assets/characters/survivor_body/survivor_body_animations.tres"

const LERP_WEIGHT := 12.0
const WALK_THRESHOLD := 0.6

@export var player_id: int = -1

var _mesh_root: Node3D
var _anim_player: AnimationPlayer
var _cur_clip: String = ""

# Networked smoothing state.
var _target_pos: Vector3
var _target_rot_y: float
var _prev_actual_pos: Vector3
var _speed_smooth: float
var _got_first: bool = false


var is_downed := false
var _revive_beacon: Label3D = null

func _ready() -> void:
	collision_layer = 4
	collision_mask = 0

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

	# 3D Revive Beacon above downed teammate's head
	_revive_beacon = Label3D.new()
	_revive_beacon.text = "[+] NEED REVIVE"
	_revive_beacon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_revive_beacon.no_depth_test = true
	_revive_beacon.position = Vector3(0, 2.25, 0)
	_revive_beacon.modulate = Color(1.0, 0.25, 0.25, 1.0)
	_revive_beacon.outline_modulate = Color(0, 0, 0, 1.0)
	_revive_beacon.font_size = 28
	_revive_beacon.visible = false
	add_child(_revive_beacon)

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
		var tw := create_tween()
		if v:
			tw.tween_property(_mesh_root, "rotation:x", -PI * 0.45, 0.35)
		else:
			tw.tween_property(_mesh_root, "rotation:x", 0.0, 0.35)
	if is_instance_valid(_revive_beacon):
		_revive_beacon.visible = v


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
			if _anim_player.has_animation("ual1_Idle"):
				_anim_player.play("ual1_Idle")
				_cur_clip = "ual1_Idle"


## Build a dim capsule so a body is always visible even without the GLB.
func _build_fallback_body() -> void:
	var mi := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.height = 1.7
	mesh.radius = 0.3
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.2, 0.2)
	mi.material_override = mat
	mi.position.y = 0.85
	_mesh_root.add_child(mi)


## Apply a network transform update. Snaps on the first update.
func update_target(msg: Dictionary) -> void:
	_target_pos = Vector3(
		float(msg.get("x", 0.0)),
		float(msg.get("y", 0.0)),
		float(msg.get("z", 0.0)))
	_target_rot_y = float(msg.get("ry", 0.0))

	if not _got_first:
		_got_first = true
		global_position = _target_pos
		rotation.y = _target_rot_y
		_prev_actual_pos = _target_pos


## Hide/show the body (used when a teammate is caught).
func set_dead(v: bool) -> void:
	if _mesh_root != null:
		_mesh_root.visible = not v


func _process(delta: float) -> void:
	if not _got_first:
		return

	var w: float = clamp(LERP_WEIGHT * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, w)
	rotation.y = lerp_angle(rotation.y, _target_rot_y, w)

	var moved: float = (global_position - _prev_actual_pos).length() / maxf(delta, 0.001)
	_prev_actual_pos = global_position
	_speed_smooth = lerp(_speed_smooth, moved, 10.0 * delta)

	_update_animation()


func _update_animation() -> void:
	if _anim_player == null:
		return
	var want: String = "ual1_Walk" if _speed_smooth > WALK_THRESHOLD else "ual1_Idle"
	if want == _cur_clip:
		return
	if _anim_player.has_animation(want):
		_anim_player.play(want)
		_cur_clip = want
