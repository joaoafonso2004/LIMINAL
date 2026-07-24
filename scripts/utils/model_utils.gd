class_name ModelUtils

## Ground a model so its mesh bottom sits at the given y_offset in world space.
## y_offset=0 → flat ground. y_offset=terrain_height → terrain surface.
## Call AFTER adding the node to the scene tree and AFTER setting scale.
static func ground_model(node: Node3D, y_offset: float = 0.0) -> void:
	var min_y := INF
	for child in node.find_children("*", "MeshInstance3D"):
		var mi = child as MeshInstance3D
		if mi and mi.mesh:
			var aabb = mi.get_aabb()
			for corner_idx in 8:
				var corner = aabb.get_endpoint(corner_idx)
				var world_y = mi.to_global(corner).y
				if world_y < min_y:
					min_y = world_y
	if min_y != INF and abs(min_y) > 0.001:
		node.position.y -= min_y - y_offset

## Add box collision to a model using its AABB.
static func add_collision(node: Node3D, collision_layer: int = 1) -> void:
	var aabb = _get_combined_aabb(node)
	if aabb.size.length() == 0:
		return
	var static_body = StaticBody3D.new()
	static_body.collision_layer = collision_layer
	static_body.collision_mask = 0
	var col_shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = aabb.size
	col_shape.shape = box
	col_shape.position = aabb.get_center() - node.global_position if node.is_inside_tree() else aabb.get_center()
	static_body.add_child(col_shape)
	node.add_child(static_body)

## Add per-part convex hull collision for props and environment models.
const MAX_HULLS := 25
static func add_per_part_convex_collision(node: Node3D, collision_layer: int = 1) -> void:
	var meshes = node.find_children("*", "MeshInstance3D")
	var parts: Array[Dictionary] = []
	for child in meshes:
		var mi = child as MeshInstance3D
		if not mi or not mi.mesh:
			continue
		var aabb = mi.get_aabb()
		var vol = aabb.size.x * aabb.size.y * aabb.size.z
		parts.append({"mesh": mi, "volume": vol})
	parts.sort_custom(func(a, b): return a["volume"] > b["volume"])
	var filtered: Array[MeshInstance3D] = []
	for i in min(parts.size(), MAX_HULLS):
		filtered.append(parts[i]["mesh"])
	for mi in filtered:
		mi.create_convex_collision(true, true)
		for i in range(mi.get_child_count() - 1, -1, -1):
			if mi.get_child(i) is StaticBody3D:
				var sb = mi.get_child(i) as StaticBody3D
				sb.collision_layer = collision_layer
				sb.collision_mask = 0
				break

## Set animation loop modes on an AnimationPlayer.
static func set_animation_loops(anim_player: AnimationPlayer) -> void:
	var oneshot_anims = ["jump", "attack", "slash", "shoot", "hurt", "die", "death",
		"fall", "climb", "dive", "hit", "cast", "throw", "reload", "pick_up",
		"eat_start", "eat_end", "eaten_start", "eaten_death"]
	for anim_name in anim_player.get_animation_list():
		var anim = anim_player.get_animation(anim_name)
		if not anim:
			continue
		var lower_name = anim_name.to_lower()
		var is_oneshot = false
		for keyword in oneshot_anims:
			if keyword in lower_name:
				is_oneshot = true
				break
		if is_oneshot:
			anim.loop_mode = Animation.LOOP_NONE
		else:
			anim.loop_mode = Animation.LOOP_LINEAR

## Cyclic locomotion clips whose foot phase should carry across a blend, so a
## walk<->run switch does not scissor the legs (see play_locomotion).
const LOCO_CLIPS := [
	"walk", "walk_front", "walk_back", "walk_left", "walk_right", "run",
	"crouch_walk", "walk_crouch_front", "walk_crouch_back",
	"walk_crouch_left", "walk_crouch_right",
]
# Gait origins measured from the imported survivor clips. Front/left/right/run
# share a planted-foot phase; the backward downloads begin about 0.4 cycles later.
const SURVIVOR_LOCOMOTION_PHASES := {
	"walk": 0.0, "walk_front": 0.0, "walk_back": 0.42,
	"walk_left": 0.0, "walk_right": 0.0, "run": 0.0,
	"crouch_walk": 0.0, "walk_crouch_front": 0.0,
	"walk_crouch_back": 0.40, "walk_crouch_left": 0.0,
	"walk_crouch_right": 0.0,
}

const _LOW_POSE_CLIPS := ["downed", "crawl_down", "crawl", "dead"]
const _CROUCH_CLIPS := [
	"crouch_idle", "crouch_walk", "walk_crouch_front", "walk_crouch_back",
	"walk_crouch_left", "walk_crouch_right",
]
const _SMOOTH_PAIR_BLENDS := {
	# Entity execution: the source FBXs do not share identical boundary poses.
	"entity_attack>entity_eat_start": 0.20,
	"entity_eat_start>entity_eat_loop": 0.24,
	"entity_eat_loop>entity_eat_end": 0.12,
	# Paired victim clips use the same overlaps so both actors remain synchronized.
	"player_hit>player_eaten_start": 0.20,
	"player_eaten_start>player_eaten_loop": 0.24,
	"player_eaten_loop>player_eaten_death": 0.12,
	"player_eaten_death>downed": 0.16,
}


## Central transition profile for the runtime Mixamo libraries. Longer blends
## hide stance changes; attack entry remains short so contact never feels soft.
static func animation_blend_time(current: String, want: String) -> float:
	if current == "" or current == want:
		return 0.0
	var pair := current + ">" + want
	if _SMOOTH_PAIR_BLENDS.has(pair):
		return float(_SMOOTH_PAIR_BLENDS[pair])
	if want in ["entity_attack", "player_hit"]:
		return 0.14
	if current in LOCO_CLIPS and want in LOCO_CLIPS:
		var stance_changes := (current in _CROUCH_CLIPS) != (want in _CROUCH_CLIPS)
		return 0.30 if stance_changes else 0.26
	if (current in _CROUCH_CLIPS) != (want in _CROUCH_CLIPS):
		return 0.28
	if current in _LOW_POSE_CLIPS or want in _LOW_POSE_CLIPS:
		return 0.18
	if current in LOCO_CLIPS or want in LOCO_CLIPS:
		return 0.23
	return 0.20

## Pick a locomotion clip from movement expressed in the character's local
## space: X right/left, Y back/front (local Z). Forward/back always wins on a
## diagonal, matching keyboard W/S semantics requested by the player.
static func directional_walk_clip(local_move: Vector2, crouched: bool) -> String:
	if local_move.y < -0.12:
		return "walk_crouch_front" if crouched else "walk_front"
	if local_move.y > 0.12:
		return "walk_crouch_back" if crouched else "walk_back"
	if crouched:
		return "walk_crouch_right" if local_move.x >= 0.0 else "walk_crouch_left"
	return "walk_right" if local_move.x >= 0.0 else "walk_left"

## Play `want` on `anim_player`, preserving the normalized cycle phase when both
## the outgoing and incoming clips are cyclic locomotion. Blending unsynchronized
## walk/run cycles is what makes the limbs spin during a transition; matching the
## phase keeps the same foot forward so the crossfade stays smooth.
static func play_locomotion(anim_player: AnimationPlayer, want: String,
		current: String, blend: float = -1.0,
		phase_offsets: Dictionary = {}) -> void:
	if anim_player == null or not anim_player.has_animation(want):
		return
	var carry := current in LOCO_CLIPS and want in LOCO_CLIPS \
		and current != want and anim_player.has_animation(current)
	var phase := 0.0
	if carry:
		var cur_len: float = anim_player.get_animation(current).length
		if cur_len > 0.0:
			phase = fposmod(anim_player.current_animation_position / cur_len, 1.0)
			# Some Mixamo downloads start on the opposite planted foot. Convert the
			# outgoing clip into a shared gait phase, then into the target's phase.
			phase -= float(phase_offsets.get(current, 0.0))
			phase += float(phase_offsets.get(want, 0.0))
	var actual_blend := animation_blend_time(current, want) if blend < 0.0 else blend
	anim_player.play(want, actual_blend)
	if carry:
		var new_len: float = anim_player.get_animation(want).length
		anim_player.seek(fposmod(phase, 1.0) * new_len, false)

## Standing clips whose pelvis/root should stay at the upright rest orientation.
const _STANDING_CLIPS := [
	"idle", "walk", "walk_front", "walk_back", "walk_left", "walk_right", "run",
	"crouch_idle", "crouch_walk", "walk_crouch_front", "walk_crouch_back",
	"walk_crouch_left", "walk_crouch_right",
	"lean_left", "lean_right",
]
const _ROOT_BONE_NAMES := ["pelvis", "Pelvis", "Hips", "hips", "root", "Root"]

static func upright_standing_root(anim_player: AnimationPlayer) -> void:
	pass

static func orient_player_ground_root(anim_player: AnimationPlayer) -> void:
	pass

static func restore_generic_humanoid_root(anim_player: AnimationPlayer) -> void:
	pass

## Replace every key on a track with one constant key holding `value` at t=0.
static func _pin_track(anim: Animation, track_idx: int, value) -> void:
	for k in range(anim.track_get_key_count(track_idx) - 1, -1, -1):
		anim.track_remove_key(track_idx, k)
	anim.track_insert_key(track_idx, 0.0, value)

## Ground a skinned character by its ACTUAL posed skeleton rather than the static
## bind-pose mesh AABB. Removed root-motion / pelvis-position tracks can leave the
## animated standing pose floating above where the bind pose sat; measuring the
## live bone poses and planting the lowest one on the floor fixes that regardless.
## Call AFTER the model is in the tree and a resting clip is playing on anim_player.
static func ground_character_by_pose(model: Node3D, anim_player: AnimationPlayer, floor_offset: float = 0.02) -> void:
	if not is_instance_valid(model) or not model.is_inside_tree():
		return
	var skeletons := model.find_children("*", "Skeleton3D")
	if skeletons.is_empty():
		ground_model(model)
		return
	var skeleton := skeletons[0] as Skeleton3D
	# Force the current animation frame onto the skeleton, then flush bone globals.
	if is_instance_valid(anim_player) and anim_player.current_animation != "":
		anim_player.seek(anim_player.current_animation_position, true)
	if skeleton.has_method("force_update_all_bone_transforms"):
		skeleton.force_update_all_bone_transforms()
	var parent := model.get_parent() as Node3D
	var lowest := INF
	for i in range(skeleton.get_bone_count()):
		var world_pos: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(i).origin
		var y := parent.to_local(world_pos).y if is_instance_valid(parent) else world_pos.y
		if y < lowest:
			lowest = y
	if lowest == INF:
		ground_model(model)
		return
	# Guard against a wild measurement teleporting the mesh.
	var shift := lowest - floor_offset
	if absf(shift) > 4.0:
		ground_model(model)
		return
	model.position.y -= shift


## Return the pivot X/Z that places the animated pelvis exactly on its owning
## CharacterBody origin. Low Mixamo poses contain large horizontal root offsets;
## without this compensation, mouse yaw turns that offset into a visible orbit.
static func centered_pose_pivot_xz(pivot: Node3D, mesh_root: Node3D) -> Vector2:
	if not is_instance_valid(pivot) or not is_instance_valid(mesh_root):
		return Vector2.ZERO
	var skeletons := pivot.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		return Vector2(pivot.position.x, pivot.position.z)
	var skeleton := skeletons[0] as Skeleton3D
	for bone in range(skeleton.get_bone_count()):
		if canonical_bone(skeleton.get_bone_name(bone)) != "hips":
			continue
		var world_position := skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
		var local_position := mesh_root.to_local(world_position)
		var target := Vector2(
			pivot.position.x - local_position.x,
			pivot.position.z - local_position.z)
		if target.distance_to(Vector2(pivot.position.x, pivot.position.z)) <= 3.0:
			return target
		break
	return Vector2(pivot.position.x, pivot.position.z)

# ---------------------------------------------------------------------------
# HUMANOID ANIMATION RETARGETING
# The shared clip library was authored for the survivor / watcher skeletons
# (mixamo-style "Hips/Spine/LeftUpperArm" bone names). Driving a different rig
# — e.g. the entity.fbx, whose bones are lowercase "hips/spine/left_upper_arm"
# — needs the track paths remapped to that rig's actual bone names. We match by
# a canonical humanoid key so the exact spelling/side convention doesn't matter.
# ---------------------------------------------------------------------------

## Humanoid bones that come in left/right pairs and therefore carry a side tag.
const _SIDED_BONES := ["shoulder", "upperarm", "lowerarm", "hand", "upperleg", "lowerleg", "foot", "toes"]

## Which side ("l"/"r"/"") a bone name refers to, read before separators are
## stripped so "LeftHand", "hand_l" and "hand.L" all resolve the same way.
static func _bone_side(lower_name: String) -> String:
	if lower_name.find("left") != -1:
		return "l"
	if lower_name.find("right") != -1:
		return "r"
	# Infix side token: CC3 tags sides as "cc_base_l_thigh" / "cc_base_r_hand".
	for sep in ["_", ".", "-", " "]:
		if lower_name.find(sep + "l" + sep) != -1:
			return "l"
		if lower_name.find(sep + "r" + sep) != -1:
			return "r"
	for sep in ["_", ".", "-", " "]:
		if lower_name.ends_with(sep + "l"):
			return "l"
		if lower_name.ends_with(sep + "r"):
			return "r"
	return ""

## Collapse any humanoid bone name to a canonical token (e.g. "upperarm.l"), or
## "" if it is not a recognised humanoid bone. Central bones carry no side.
static func canonical_bone(raw: String) -> String:
	var lower := raw.to_lower().replace("mixamorig", "")
	var side := _bone_side(lower)
	var s := ""
	for i in range(lower.length()):
		var ch := lower[i]
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			s += ch
	s = s.replace("left", "").replace("right", "")
	# Auxiliary deform bones (CC3 twist/share correctives) must never absorb a
	# primary humanoid track, or a limb's rotation lands on its twist bone.
	if (s.find("twist") != -1 and s.find("neck") == -1) or s.find("share") != -1:
		return ""
	var core := ""
	if s.find("toe") != -1 or s.find("ball") != -1:
		core = "toes"
	elif s.find("foot") != -1 or s.find("ankle") != -1:
		core = "foot"
	elif s.find("thigh") != -1 or s.find("upleg") != -1 or s.find("upperleg") != -1:
		core = "upperleg"
	elif s.find("calf") != -1 or s.find("shin") != -1 or s.find("lowerleg") != -1 \
			or (s.find("leg") != -1 and s.find("up") == -1):
		core = "lowerleg"
	elif s.find("hand") != -1:
		core = "hand"
	elif s.find("forearm") != -1 or s.find("lowerarm") != -1:
		core = "lowerarm"
	elif s.find("upperarm") != -1 or s.find("uparm") != -1 \
			or (s.find("arm") != -1 and s.find("fore") == -1 and s.find("lower") == -1):
		core = "upperarm"
	elif s.find("clavicle") != -1 or s.find("shoulder") != -1:
		core = "shoulder"
	elif s.find("upperchest") != -1 or s.find("spine3") != -1 or s.find("spine03") != -1 \
			or s.find("spine2") != -1 or s.find("spine02") != -1:
		core = "upperchest"
	elif s.find("chest") != -1 or s.find("spine1") != -1 or s.find("spine01") != -1:
		core = "chest"
	elif s.find("waist") != -1 or s.find("spine") != -1:
		core = "spine"
	elif s.find("neck") != -1:
		core = "neck"
	elif s.find("head") != -1:
		core = "head"
	elif s.find("hip") != -1 or s.find("pelvis") != -1:
		core = "hips"
	if core == "":
		return ""
	if core in _SIDED_BONES and side != "":
		return core + "." + side
	return core

## Rebuild `src_lib` so its bone tracks target `skeleton` (reached via
## `skel_rel_path` from the AnimationPlayer's root). Returns
## {"lib": AnimationLibrary, "matched": int} — matched is how many distinct bones
## were mapped, so the caller can reject a total naming mismatch.
static func retarget_library(src_lib: AnimationLibrary, skeleton: Skeleton3D, skel_rel_path: String) -> Dictionary:
	var canon_to_bone := {}
	for i in range(skeleton.get_bone_count()):
		var canon := canonical_bone(skeleton.get_bone_name(i))
		if canon != "" and not canon_to_bone.has(canon):
			canon_to_bone[canon] = skeleton.get_bone_name(i)

	var out := AnimationLibrary.new()
	var matched := {}
	for anim_name in src_lib.get_animation_list():
		var src: Animation = src_lib.get_animation(anim_name)
		var dst := Animation.new()
		dst.length = src.length
		dst.loop_mode = src.loop_mode
		var seen := {}
		for ti in range(src.get_track_count()):
			var ttype := src.track_get_type(ti)
			if ttype != Animation.TYPE_POSITION_3D and ttype != Animation.TYPE_ROTATION_3D \
					and ttype != Animation.TYPE_SCALE_3D:
				continue
			var path := src.track_get_path(ti)
			if path.get_subname_count() == 0:
				continue
			var canon := canonical_bone(path.get_subname(0))
			if canon == "" or not canon_to_bone.has(canon):
				continue
			# The library holds the same bone under several naming conventions;
			# keep only the first (mixamo/GeneralSkeleton set carries the data).
			var dedupe_key := "%s|%d" % [canon, ttype]
			if seen.has(dedupe_key):
				continue
			seen[dedupe_key] = true
			matched[canon] = true
			var nt := dst.add_track(ttype)
			dst.track_set_path(nt, NodePath(skel_rel_path + ":" + String(canon_to_bone[canon])))
			dst.track_set_interpolation_type(nt, src.track_get_interpolation_type(ti))
			for k in range(src.track_get_key_count(ti)):
				dst.track_insert_key(nt, src.track_get_key_time(ti, k), src.track_get_key_value(ti, k))
		out.add_animation(anim_name, dst)
	return {"lib": out, "matched": matched.size()}

## The survivor's animation clips: gameplay clip name -> source FBX. Each FBX is a
## single Mixamo take (retargeted to the humanoid profile on import). The library
## is rebuilt at runtime because the baked survivor_body_animations.tres was tied
## to the old model and no longer exists.
const SURVIVOR_CLIP_SOURCES := {
	"idle": "res://assets/characters/survivor_body/idle.fbx",
	"walk": "res://assets/characters/survivor_body/walk.fbx",
	"walk_front": "res://assets/characters/survivor_body/walk_front.fbx",
	"walk_back": "res://assets/characters/survivor_body/walk_back.fbx",
	"walk_left": "res://assets/characters/survivor_body/walk_left.fbx",
	"walk_right": "res://assets/characters/survivor_body/walk_right.fbx",
	"walk_crouch_front": "res://assets/characters/survivor_body/walk_crouch_front.fbx",
	"walk_crouch_back": "res://assets/characters/survivor_body/walk_crouch_back.fbx",
	"walk_crouch_left": "res://assets/characters/survivor_body/walk_crouch_left.fbx",
	"walk_crouch_right": "res://assets/characters/survivor_body/walk_crouch_right.fbx",
	"run": "res://assets/characters/survivor_body/run.fbx",
	"crouch_idle": "res://assets/characters/survivor_body/crouch_idle.fbx",
	"crouch_walk": "res://assets/characters/survivor_body/crouch_walk.fbx",
	"crawl": "res://assets/characters/survivor_body/crawl.fbx",
	"crawl_chase": "res://assets/characters/survivor_body/crawl_chase.fbx",
	"crawl_down": "res://assets/characters/survivor_body/crawl_down.fbx",
	"downed": "res://assets/characters/survivor_body/downed.fbx",
	"player_hit": "res://assets/characters/survivor_body/player_hit.fbx",
	"player_eaten_start": "res://assets/characters/survivor_body/player_eaten_start.fbx",
	"player_eaten_loop": "res://assets/characters/survivor_body/player_eaten_loop.fbx",
	"player_eaten_death": "res://assets/characters/survivor_body/player_eaten_death.fbx",
	"dead": "res://assets/characters/survivor_body/dead.fbx",
	"revive": "res://assets/characters/survivor_body/revive.fbx",
	"revive_get_up": "res://assets/characters/survivor_body/revive_get_up.fbx",
	"standing_to_crouch": "res://assets/characters/survivor_body/standing_to_crouch.fbx",
	"crouch_to_standing": "res://assets/characters/survivor_body/crouch_to_standing.fbx",
	"lean_left": "res://assets/characters/survivor_body/lean_left.fbx",
	"lean_right": "res://assets/characters/survivor_body/lean_right.fbx",
	"player_slip_getup": "res://assets/characters/entity/player_slip_getup.fbx",
}

## Some Blender FBX exports contain the other actor's actions as extra takes.
## Select the take belonging to the player instead of relying on import order.
const SURVIVOR_CLIP_TAKES := {
	"player_eaten_start": "Armature|mixamo_com_001",
	"player_eaten_loop": "Armature|mixamo_com_004",
}

## The multi-take Mixamo files below bind their skeleton horizontally. Their
## animation delta is therefore "standing" relative to that horizontal rest;
## rotate the baked target globals so the victim keeps the authored floor pose.
static func _survivor_world_rotation_fix(clip_name: String) -> Quaternion:
	if clip_name == "player_eaten_start" or clip_name == "player_eaten_loop":
		return Quaternion(Vector3.RIGHT, -PI * 0.5)
	return Quaternion.IDENTITY

## Assemble an AnimationLibrary from separate imported animation scenes, keyed by
## the caller's clip name. Each scene holds one AnimationPlayer with one take.
static func build_animation_library_from_clips(sources: Dictionary, preferred_takes: Dictionary = {}) -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for clip_name in sources:
		var path: String = sources[clip_name]
		if not ResourceLoader.exists(path):
			continue
		var packed := ResourceLoader.load(path) as PackedScene
		if packed == null:
			continue
		var inst := packed.instantiate()
		var picked: Animation = null
		for node in inst.find_children("*", "AnimationPlayer"):
			var ap := node as AnimationPlayer
			var preferred := String(preferred_takes.get(clip_name, ""))
			if preferred != "" and ap.has_animation(preferred):
				picked = ap.get_animation(preferred)
				break
			for a in ap.get_animation_list():
				if a == "RESET":
					continue
				picked = ap.get_animation(a)
				break
			if picked != null:
				break
		if picked != null:
			lib.add_animation(clip_name, picked.duplicate(true))
		inst.free()
	return lib


## Bake separate Mixamo clips onto a target whose bone names and axes may be
## completely unrelated. `target_bones` maps canonical humanoid tokens to the
## target's real bone names. Reproducing GLOBAL orientation deltas is essential
## for generated rigs such as Bone/Bone.001; copying local rotations twists them.
static func build_global_library_from_clips(
		tgt_skel: Skeleton3D,
		rel_path: String,
		host: Node,
		sources: Dictionary,
		preferred_takes: Dictionary = {},
		target_bones: Dictionary = {},
		root_motion_yaw: float = 0.0) -> Dictionary:
	if tgt_skel == null:
		return {"lib": AnimationLibrary.new(), "matched": 0}
	var target_indices := {}
	if not target_bones.is_empty():
		for canonical in target_bones:
			var bone_index := tgt_skel.find_bone(String(target_bones[canonical]))
			if bone_index >= 0:
				target_indices[String(canonical)] = bone_index
	else:
		for bone_index in range(tgt_skel.get_bone_count()):
			var canonical := canonical_bone(tgt_skel.get_bone_name(bone_index))
			if canonical != "" and not target_indices.has(canonical):
				target_indices[canonical] = bone_index

	var target_count := tgt_skel.get_bone_count()
	var target_order := _bone_order(tgt_skel)
	var target_rest_global := _rest_global_rots(tgt_skel, target_order)
	var target_parent: Array[int] = []
	var target_rest_local: Array[Quaternion] = []
	var target_canonical: Array[String] = []
	target_canonical.resize(target_count)
	for bone_index in range(target_count):
		target_parent.append(tgt_skel.get_bone_parent(bone_index))
		target_rest_local.append(
			tgt_skel.get_bone_rest(bone_index).basis.get_rotation_quaternion())
		target_canonical[bone_index] = ""
	for canonical in target_indices:
		target_canonical[int(target_indices[canonical])] = String(canonical)

	var out := AnimationLibrary.new()
	var matched_bones := {}
	var root_motion_basis := Basis(Vector3.UP, root_motion_yaw)
	var coordinate_rotation := Quaternion(Vector3.UP, root_motion_yaw)
	var inverse_coordinate_rotation := coordinate_rotation.inverse()
	for clip_name in sources:
		var source_path := String(sources[clip_name])
		if not ResourceLoader.exists(source_path):
			continue
		var packed := ResourceLoader.load(source_path) as PackedScene
		if packed == null:
			continue
		var source_instance := packed.instantiate()
		if host != null:
			host.add_child(source_instance)
		var source_player: AnimationPlayer = null
		var source_skeleton: Skeleton3D = null
		for node in source_instance.find_children("*", "AnimationPlayer", true, false):
			source_player = node as AnimationPlayer
			break
		for node in source_instance.find_children("*", "Skeleton3D", true, false):
			source_skeleton = node as Skeleton3D
			break
		var source_clip := String(preferred_takes.get(clip_name, ""))
		if source_player != null and source_clip != "" \
				and not source_player.has_animation(source_clip):
			source_clip = ""
		if source_player != null and source_clip == "":
			for animation_name in source_player.get_animation_list():
				if animation_name != "RESET":
					source_clip = animation_name
					break
		if source_player == null or source_skeleton == null or source_clip == "":
			source_instance.free()
			continue

		var source_animation := source_player.get_animation(source_clip)
		var length := maxf(source_animation.length, 0.0001)
		source_player.play(source_clip)
		source_player.seek(0.0, true)
		source_skeleton.force_update_all_bone_transforms()
		var source_rest_global := _rest_global_rots(
			source_skeleton, _bone_order(source_skeleton))
		var source_indices := {}
		for bone_index in range(source_skeleton.get_bone_count()):
			var canonical := canonical_bone(source_skeleton.get_bone_name(bone_index))
			if canonical != "" and not source_indices.has(canonical):
				source_indices[canonical] = bone_index

		var destination := Animation.new()
		destination.length = length
		destination.loop_mode = source_animation.loop_mode
		var rotation_tracks := {}
		for canonical in target_indices:
			if not source_indices.has(canonical):
				continue
			var target_index := int(target_indices[canonical])
			var track := destination.add_track(Animation.TYPE_ROTATION_3D)
			destination.track_set_path(track, NodePath(
				rel_path + ":" + tgt_skel.get_bone_name(target_index)))
			rotation_tracks[target_index] = track
			matched_bones[canonical] = true

		var target_hips := int(target_indices.get("hips", -1))
		var source_hips := int(source_indices.get("hips", -1))
		var position_track := -1
		if target_hips >= 0 and source_hips >= 0:
			position_track = destination.add_track(Animation.TYPE_POSITION_3D)
			destination.track_set_path(position_track, NodePath(
				rel_path + ":" + tgt_skel.get_bone_name(target_hips)))

		var steps := int(ceil(length * 30.0)) + 1
		for sample_index in range(steps):
			var time := minf(float(sample_index) / 30.0, length)
			source_player.seek(time, true)
			source_skeleton.force_update_all_bone_transforms()
			var source_global := {}
			for canonical in source_indices:
				var source_index := int(source_indices[canonical])
				source_global[canonical] = source_skeleton.get_bone_global_pose(
					source_index).basis.get_rotation_quaternion()
			var target_global: Array[Quaternion] = []
			target_global.resize(target_count)
			for target_index in target_order:
				var canonical := target_canonical[target_index]
				var parent_index := target_parent[target_index]
				var parent_global := target_global[parent_index] \
					if parent_index >= 0 else Quaternion.IDENTITY
				if canonical != "" and source_global.has(canonical):
					var source_index := int(source_indices[canonical])
					var global_delta: Quaternion = source_global[canonical] \
						* (source_rest_global[source_index] as Quaternion).inverse()
					# Convert the change into the target rig's forward-axis convention.
					# The new Entity faces +X while the Mixamo source faces +Z.
					var converted_delta: Quaternion = coordinate_rotation \
						* global_delta * inverse_coordinate_rotation
					var desired_global: Quaternion = converted_delta \
						* (target_rest_global[target_index] as Quaternion)
					target_global[target_index] = desired_global
					if rotation_tracks.has(target_index):
						destination.track_insert_key(
							rotation_tracks[target_index], time,
							((parent_global as Quaternion).inverse() * desired_global).normalized())
				else:
					target_global[target_index] = (parent_global as Quaternion) \
						* target_rest_local[target_index]
			if position_track >= 0:
				var source_position := source_skeleton.get_bone_pose_position(source_hips)
				var source_rest_position := source_skeleton.get_bone_rest(source_hips).origin
				var target_rest_position := tgt_skel.get_bone_rest(target_hips).origin
				var motion_delta := root_motion_basis \
					* (source_position - source_rest_position)
				destination.track_insert_key(
					position_track, time, target_rest_position + motion_delta)
		out.add_animation(String(clip_name), destination)
		source_instance.free()
	return {"lib": out, "matched": matched_bones.size()}

## Bones ordered so every parent precedes its children (safe global accumulation
## even when the skeleton isn't stored in strict hierarchy order).
static func _bone_order(skel: Skeleton3D) -> Array:
	var order := []
	var added := {}
	var n := skel.get_bone_count()
	var guard := 0
	while order.size() < n and guard < n + 4:
		guard += 1
		for i in range(n):
			if added.has(i):
				continue
			var p := skel.get_bone_parent(i)
			if p == -1 or added.has(p):
				order.append(i)
				added[i] = true
	return order

## Per-bone GLOBAL rest rotations (skeleton space), indexed by bone.
static func _rest_global_rots(skel: Skeleton3D, order: Array) -> Array:
	var n := skel.get_bone_count()
	var g := []
	g.resize(n)
	for i in range(n):
		g[i] = Quaternion.IDENTITY
	for i in order:
		var lr: Quaternion = skel.get_bone_rest(i).basis.get_rotation_quaternion()
		var p := skel.get_bone_parent(i)
		g[i] = lr if p == -1 else ((g[p] as Quaternion) * lr)
	return g

## Retarget the survivor clips onto `tgt_skel` in GLOBAL space: reproduce each
## bone's global orientation CHANGE from the source onto the target. This handles
## the different bone-axis conventions between the Mixamo clips and the CC3 rig
## (a naive local copy twists the limbs). `host` is any in-tree node used to
## briefly evaluate the source animations via Godot's own sampler.
static func _bake_retargeted_library(tgt_skel: Skeleton3D, rel_path: String, host: Node) -> AnimationLibrary:
	var tn := tgt_skel.get_bone_count()
	var t_order := _bone_order(tgt_skel)
	var t_rest_global := _rest_global_rots(tgt_skel, t_order)
	var t_parent := []
	var t_rest_local := []
	var t_canon := []
	for i in range(tn):
		t_parent.append(tgt_skel.get_bone_parent(i))
		t_rest_local.append(tgt_skel.get_bone_rest(i).basis.get_rotation_quaternion())
		t_canon.append(canonical_bone(tgt_skel.get_bone_name(i)))
	var canon_to_tidx := {}
	for i in range(tn):
		var c: String = t_canon[i]
		if c != "" and not canon_to_tidx.has(c):
			canon_to_tidx[c] = i

	var out := AnimationLibrary.new()
	var fps := 30.0
	for clip_name in SURVIVOR_CLIP_SOURCES:
		var path: String = SURVIVOR_CLIP_SOURCES[clip_name]
		if not ResourceLoader.exists(path):
			continue
		var packed := ResourceLoader.load(path) as PackedScene
		if packed == null:
			continue
		var inst := packed.instantiate()
		if host != null:
			host.add_child(inst)
		var src_ap: AnimationPlayer = null
		var src_skel: Skeleton3D = null
		for node in inst.find_children("*", "AnimationPlayer"):
			src_ap = node as AnimationPlayer
			break
		for node in inst.find_children("*", "Skeleton3D"):
			src_skel = node as Skeleton3D
			break
		var src_clip := String(SURVIVOR_CLIP_TAKES.get(clip_name, ""))
		if src_ap != null and src_clip != "" and not src_ap.has_animation(src_clip):
			src_clip = ""
		if src_ap != null:
			if src_clip == "":
				for a in src_ap.get_animation_list():
					if a != "RESET":
						src_clip = a
						break
		if src_ap == null or src_skel == null or src_clip == "":
			inst.free()
			continue

		var src_anim := src_ap.get_animation(src_clip)
		var length: float = maxf(src_anim.length, 0.0001)
		var clip_world_fix := _survivor_world_rotation_fix(String(clip_name))
		# seek() only evaluates the AnimationPlayer's current animation.  The old
		# global-space baker discovered the clip but never made it current, so every
		# sample below read the source rig's unchanged rest pose and baked 17 static
		# T-pose clips. Select the take once before sampling its timeline.
		src_ap.play(src_clip)
		src_ap.seek(0.0, true)
		src_skel.force_update_all_bone_transforms()
		var s_rest_global := _rest_global_rots(src_skel, _bone_order(src_skel))
		var sn := src_skel.get_bone_count()
		var s_canon_to_idx := {}
		for i in range(sn):
			var c := canonical_bone(src_skel.get_bone_name(i))
			if c != "" and not s_canon_to_idx.has(c):
				s_canon_to_idx[c] = i

		var dst := Animation.new()
		dst.length = length
		dst.loop_mode = src_anim.loop_mode
		var rot_track := {}
		for c in canon_to_tidx:
			if s_canon_to_idx.has(c):
				var ti: int = canon_to_tidx[c]
				var tr := dst.add_track(Animation.TYPE_ROTATION_3D)
				dst.track_set_path(tr, NodePath(rel_path + ":" + tgt_skel.get_bone_name(ti)))
				rot_track[ti] = tr
		var hips_ti: int = canon_to_tidx.get("hips", -1)
		var hips_si: int = s_canon_to_idx.get("hips", -1)
		var pos_track := -1
		if hips_ti != -1 and hips_si != -1:
			pos_track = dst.add_track(Animation.TYPE_POSITION_3D)
			dst.track_set_path(pos_track, NodePath(rel_path + ":" + tgt_skel.get_bone_name(hips_ti)))

		var steps := int(ceil(length * fps)) + 1
		for s in range(steps):
			var t: float = minf(float(s) / fps, length)
			src_ap.seek(t, true)
			src_skel.force_update_all_bone_transforms()
			var s_glob := {}
			for c in s_canon_to_idx:
				var si: int = s_canon_to_idx[c]
				s_glob[c] = src_skel.get_bone_global_pose(si).basis.get_rotation_quaternion()
			var t_glob := []
			t_glob.resize(tn)
			for i in t_order:
				var c: String = t_canon[i]
				var par: int = t_parent[i]
				var par_glob: Quaternion = (t_glob[par] as Quaternion) if par != -1 else Quaternion.IDENTITY
				if c != "" and s_glob.has(c) and canon_to_tidx.get(c, -1) == i:
					var dg: Quaternion = (s_glob[c] as Quaternion) * (s_rest_global[s_canon_to_idx[c]] as Quaternion).inverse()
					var gat: Quaternion = clip_world_fix * dg * (t_rest_global[i] as Quaternion)
					t_glob[i] = gat
					if rot_track.has(i):
						dst.track_insert_key(rot_track[i], t, (par_glob.inverse() * gat).normalized())
				else:
					t_glob[i] = par_glob * (t_rest_local[i] as Quaternion)
			if pos_track != -1:
				var s_pos: Vector3 = src_skel.get_bone_pose_position(hips_si)
				var s_rp: Vector3 = src_skel.get_bone_rest(hips_si).origin
				var t_rp: Vector3 = tgt_skel.get_bone_rest(hips_ti).origin
				dst.track_insert_key(pos_track, t, t_rp + (s_pos - s_rp))
		out.add_animation(clip_name, dst)
		inst.free()
	return out

## Cache keyed by the AnimationPlayer-relative skeleton path (every survivor body
## shares the same rig, so the heavy bake only runs once).
static var _survivor_lib_cache := {}

## Build the survivor clip library retargeted (global-space) onto `skeleton`.
static func build_survivor_library_for(skeleton: Skeleton3D, skel_rel_path: String) -> AnimationLibrary:
	if skeleton == null:
		return build_animation_library_from_clips(SURVIVOR_CLIP_SOURCES, SURVIVOR_CLIP_TAKES)
	if _survivor_lib_cache.has(skel_rel_path):
		return _survivor_lib_cache[skel_rel_path]
	# During GameWorld._ready the SceneTree root is still attaching the scene and
	# rejects add_child(). The rig's already-live model parent is safe to use as
	# the temporary sampler host, so the bake also works on the real first spawn.
	var host: Node = skeleton.get_parent()
	var lib := _bake_retargeted_library(skeleton, skel_rel_path, host)
	_survivor_lib_cache[skel_rel_path] = lib
	return lib

## Returns the world-space height of a node's combined mesh AABB.
static func measure_height(node: Node3D) -> float:
	var min_y := INF
	var max_y := -INF
	for child in node.find_children("*", "MeshInstance3D"):
		var mi = child as MeshInstance3D
		if mi and mi.mesh:
			for corner_idx in 8:
				var corner = mi.get_aabb().get_endpoint(corner_idx)
				var world_y = mi.to_global(corner).y
				min_y = min(min_y, world_y)
				max_y = max(max_y, world_y)
	return max_y - min_y if min_y != INF else 0.0

## Scale a node so its world-space height matches target_meters.
static func scale_to_height(node: Node3D, target_meters: float) -> void:
	var current = measure_height(node)
	if current < 0.001:
		return
	var factor = target_meters / current
	node.scale *= factor

## Bundle the runtime fixups every character needs (scale, ground, materials).
static func setup_character_for_movement(node: Node3D, target_height: float = 1.8) -> void:
	scale_to_height(node, target_height)
	ground_model(node)
	fix_character_materials(node)

## CC3 (player.fbx) textures were carved from the FBX (its materials reference
## dead absolute paths, so Godot imports them untextured). We bind them at runtime
## by matching each surface's material name to <name>_Diffuse / <name>_Normal.
const CC3_TEX_DIR := "res://assets/characters/survivor_body/cc3_tex/"
const CC3_MATERIAL_NAMES: Array[String] = [
	"Std_Skin_Head", "Std_Skin_Body", "Std_Skin_Arm", "Std_Skin_Leg", "Std_Nails",
	"Std_Upper_Teeth", "Std_Lower_Teeth", "Std_Tongue",
	"Std_Eyelash", "Std_Cornea_L", "Std_Cornea_R", "Std_Eye_L", "Std_Eye_R",
	"Rocker_Jeans", "Plaid_Punk_Shirt", "White_gloves", "Loose_Biker_Boots",
	"Sunglasses", "Beard_Transparency",
]

static func _cc3_load_tex(base_name: String, suffix: String) -> Texture2D:
	for ext in [".jpg", ".png"]:
		var p: String = CC3_TEX_DIR + base_name + suffix + ext
		if not ResourceLoader.exists(p):
			continue
		# A source image may exist while Godot has marked its import invalid. Calling
		# load() in that state aborts the character's _ready() path; skip it and let
		# the existing neutral material fallback keep the player operational.
		var import_config := ConfigFile.new()
		if import_config.load(p + ".import") == OK \
				and not bool(import_config.get_value("remap", "valid", true)):
			continue
		var texture := ResourceLoader.load(p) as Texture2D
		if texture != null:
			return texture
	return null

## Which CC3 material a surface belongs to, matched from its material/mesh name.
static func _cc3_match_name(candidate: String) -> String:
	if candidate == "":
		return ""
	var c := candidate.to_lower()
	for base in CC3_MATERIAL_NAMES:
		if c == base.to_lower():
			return base
	for base in CC3_MATERIAL_NAMES:
		if c.find(base.to_lower()) != -1:
			return base
	return ""

## Bind the carved CC3 textures onto `model`'s materials. Returns bones untouched;
## purely cosmetic. No-op for non-CC3 models (nothing matches).
static func apply_cc3_textures(model: Node3D) -> int:
	var bound := 0
	for child in model.find_children("*", "MeshInstance3D"):
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for surface in range(mi.mesh.get_surface_count()):
			var orig: Material = mi.get_active_material(surface)
			var base := ""
			if orig != null and orig.resource_name != "":
				base = _cc3_match_name(orig.resource_name)
			if base == "":
				base = _cc3_match_name(String(mi.name))
			if base == "":
				continue
			var albedo := _cc3_load_tex(base, "_Diffuse")
			if albedo == null:
				continue
			var mat := StandardMaterial3D.new()
			mat.resource_name = base
			mat.albedo_texture = albedo
			mat.metallic = 0.0
			mat.roughness = 0.7
			var nrm := _cc3_load_tex(base, "_Normal")
			if nrm != null:
				mat.normal_enabled = true
				mat.normal_texture = nrm
			# Skin/eyes/lash read better double-sided; clothes are fine either way.
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED if base.begins_with("Std_") else BaseMaterial3D.CULL_BACK
			mi.set_surface_override_material(surface, mat)
			bound += 1
	return bound

## Override metallic 1.0 / missing materials with clean dielectric survivor material so character textures never render purple.
static func fix_character_materials(node: Node3D) -> void:
	for child in node.find_children("*", "MeshInstance3D"):
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		
		var surf_count := mi.mesh.get_surface_count() if mi.mesh else 1
		for surface in range(surf_count):
			var orig: Material = mi.get_active_material(surface)
			if orig == null and mi.mesh:
				orig = mi.mesh.surface_get_material(surface)

			var clean_mat := StandardMaterial3D.new()
			clean_mat.metallic = 0.0
			clean_mat.roughness = 0.8
			clean_mat.metallic_specular = 0.2
			clean_mat.albedo_color = Color(0.85, 0.78, 0.70) # Clean survivor beige/tan clothes fallback

			if orig is BaseMaterial3D and orig.albedo_texture != null:
				clean_mat.albedo_texture = orig.albedo_texture
				clean_mat.albedo_color = Color(1.0, 1.0, 1.0)

			mi.set_surface_override_material(surface, clean_mat)

## Apply orientation correction for Tripo models. Call ONLY if models face wrong.
static func fix_orientation(node: Node3D, angle_degrees: float = 180.0) -> void:
	node.rotation_degrees.y += angle_degrees

## Compute exact 3D transform of target relative to root using local node hierarchy.
static func relative_transform(root: Node3D, target: Node3D) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var curr: Node = target
	while curr != null and curr != root:
		if curr is Node3D:
			xform = (curr as Node3D).transform * xform
		curr = curr.get_parent()
	return xform

## Compute the combined AABB of all MeshInstance3D children.
static func _get_combined_aabb(node: Node3D) -> AABB:
	var combined := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D"):
		var mesh_instance = child as MeshInstance3D
		if mesh_instance and mesh_instance.mesh:
			var child_aabb = mesh_instance.mesh.get_aabb()
			var child_transform := relative_transform(node, mesh_instance)
			var transformed_aabb = child_transform * child_aabb
			if first:
				combined = transformed_aabb
				first = false
			else:
				combined = combined.merge(transformed_aabb)
	return combined

## Recursively apply self-illumination — last resort for missing normals.
static func apply_self_illumination(mesh_instance: MeshInstance3D, emission_energy: float = 0.3) -> StandardMaterial3D:
	var base_mat = mesh_instance.get_active_material(0)
	var emissive_mat = StandardMaterial3D.new()
	emissive_mat.emission_enabled = true
	emissive_mat.emission = Color(1.0, 1.0, 1.0)
	emissive_mat.emission_energy_multiplier = emission_energy
	if base_mat is StandardMaterial3D:
		var orig = base_mat as StandardMaterial3D
		emissive_mat.albedo_texture = orig.albedo_texture
		emissive_mat.albedo_color = orig.albedo_color
		emissive_mat.roughness = orig.roughness
		emissive_mat.metallic = orig.metallic
	emissive_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_instance.material_override = emissive_mat
	return emissive_mat

static func apply_self_illumination_to_all(node: Node3D, emission_energy: float = 0.3) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			apply_self_illumination(child, emission_energy)
		apply_self_illumination_to_all(child, emission_energy)

static func has_vertex_normals(mesh_instance: MeshInstance3D) -> bool:
	var mesh = mesh_instance.mesh
	if not mesh:
		return false
	if mesh.get_surface_count() > 0:
		var format = mesh.surface_get_format(0)
		return (format & ArrayMesh.ARRAY_FORMAT_NORMAL) != 0
	return false

static func generate_normals_for_all(node: Node3D) -> void:
	for child in node.find_children("*", "MeshInstance3D"):
		var mi = child as MeshInstance3D
		if not mi or not mi.mesh:
			continue
		var old_mesh = mi.mesh
		var new_mesh = ArrayMesh.new()
		for surface_idx in old_mesh.get_surface_count():
			var st = SurfaceTool.new()
			st.create_from(old_mesh, surface_idx)
			st.generate_normals()
			st.generate_tangents()
			st.commit(new_mesh)
			var mat = old_mesh.surface_get_material(surface_idx)
			if mat:
				new_mesh.surface_set_material(surface_idx, mat)
		mi.mesh = new_mesh
