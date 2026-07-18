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

## Bundle the two runtime fixups every UniRig character needs.
static func setup_character_for_movement(node: Node3D, target_height: float = 1.8) -> void:
	scale_to_height(node, target_height)
	ground_model(node)

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
