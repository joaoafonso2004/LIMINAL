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
		"fall", "climb", "dive", "hit", "cast", "throw", "reload", "pick_up"]
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
const LOCO_CLIPS := ["walk", "run", "crouch_walk"]

## Play `want` on `anim_player`, preserving the normalized cycle phase when both
## the outgoing and incoming clips are cyclic locomotion. Blending unsynchronized
## walk/run cycles is what makes the limbs spin during a transition; matching the
## phase keeps the same foot forward so the crossfade stays smooth.
static func play_locomotion(anim_player: AnimationPlayer, want: String, current: String, blend: float = 0.18) -> void:
	if anim_player == null or not anim_player.has_animation(want):
		return
	var carry := current in LOCO_CLIPS and want in LOCO_CLIPS \
		and current != want and anim_player.has_animation(current)
	var phase := 0.0
	if carry:
		var cur_len: float = anim_player.get_animation(current).length
		if cur_len > 0.0:
			phase = fposmod(anim_player.current_animation_position / cur_len, 1.0)
	anim_player.play(want, blend)
	if carry:
		var new_len: float = anim_player.get_animation(want).length
		anim_player.seek(phase * new_len, false)

## Standing clips whose pelvis/root should stay at the upright rest orientation.
const _STANDING_CLIPS := ["idle", "walk", "run", "crouch_idle", "crouch_walk", "lean_left", "lean_right"]
const _ROOT_BONE_NAMES := ["pelvis", "Pelvis", "Hips", "hips", "root", "Root"]

## The imported clips were authored for the survivor/mixamo pelvis frame; on the
## player.fbx rig that frame lays the body on its side. The correct pose is the
## clip's pelvis rotation composed ONTO the rig's rest (rest * key), which keeps
## the pelvis animating (crouch/downed/crawl all lower and turn correctly) from an
## upright base instead of a sideways one. For the standing clips we also pin the
## pelvis POSITION to its rest so a crawl->idle transition snaps back upright
## instead of leaving the hips stuck low. Call after the library is on `anim_player`.
static func upright_standing_root(anim_player: AnimationPlayer) -> void:
	if anim_player == null:
		return
	var model := anim_player.get_parent()
	if model == null:
		return
	var skeletons := model.find_children("*", "Skeleton3D")
	if skeletons.is_empty():
		return
	var skeleton := skeletons[0] as Skeleton3D
	var root_idx := -1
	for bone_name in _ROOT_BONE_NAMES:
		root_idx = skeleton.find_bone(bone_name)
		if root_idx != -1:
			break
	if root_idx == -1:
		return
	var rest := skeleton.get_bone_rest(root_idx)
	var rest_pos := rest.origin
	var rest_rot := rest.basis.get_rotation_quaternion()
	for clip_name in anim_player.get_animation_list():
		var is_standing := clip_name in _STANDING_CLIPS
		var anim: Animation = anim_player.get_animation(clip_name)
		for ti in range(anim.get_track_count()):
			var path := anim.track_get_path(ti)
			if path.get_subname_count() == 0 or not (String(path.get_subname(0)) in _ROOT_BONE_NAMES):
				continue
			var ttype := anim.track_get_type(ti)
			if ttype == Animation.TYPE_ROTATION_3D:
				# Re-frame every pelvis key onto the rig's rest orientation.
				for k in range(anim.track_get_key_count(ti)):
					var key_rot: Quaternion = anim.track_get_key_value(ti, k)
					anim.track_set_key_value(ti, k, rest_rot * key_rot)
			elif ttype == Animation.TYPE_POSITION_3D and is_standing:
				_pin_track(anim, ti, rest_pos)

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
	elif s.find("upperchest") != -1 or s.find("spine3") != -1 or s.find("spine03") != -1:
		core = "upperchest"
	elif s.find("chest") != -1 or s.find("spine2") != -1 or s.find("spine02") != -1:
		core = "chest"
	elif s.find("spine") != -1:
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

## Compute the combined AABB of all MeshInstance3D children.
static func _get_combined_aabb(node: Node3D) -> AABB:
	var combined := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D"):
		var mesh_instance = child as MeshInstance3D
		if mesh_instance and mesh_instance.mesh:
			var child_aabb = mesh_instance.mesh.get_aabb()
			var child_transform = node.global_transform.inverse() * mesh_instance.global_transform
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
