@tool
extends SceneTree

const MIXAMO_TO_SURVIVOR := {
	"mixamorig_Hips": "Hips",
	"mixamorig_Spine": "Spine",
	"mixamorig_Spine1": "Chest",
	"mixamorig_Spine2": "UpperChest",
	"mixamorig_Neck": "Neck",
	"mixamorig_Head": "Head",
	"mixamorig_LeftShoulder": "LeftShoulder",
	"mixamorig_LeftArm": "LeftUpperArm",
	"mixamorig_LeftForeArm": "LeftLowerArm",
	"mixamorig_LeftHand": "LeftHand",
	"mixamorig_RightShoulder": "RightShoulder",
	"mixamorig_RightArm": "RightUpperArm",
	"mixamorig_RightForeArm": "RightLowerArm",
	"mixamorig_RightHand": "RightHand",
	"mixamorig_LeftUpLeg": "LeftUpperLeg",
	"mixamorig_LeftLeg": "LeftLowerLeg",
	"mixamorig_LeftFoot": "LeftFoot",
	"mixamorig_LeftToeBase": "LeftToes",
	"mixamorig_RightUpLeg": "RightUpperLeg",
	"mixamorig_RightLeg": "RightLowerLeg",
	"mixamorig_RightFoot": "RightFoot",
	"mixamorig_RightToeBase": "RightToes",
}

const SURVIVOR_TO_UNREAL := {
	"Hips": "pelvis",
	"Spine": "spine_01",
	"Chest": "spine_02",
	"UpperChest": "spine_03",
	"Neck": "neck_01",
	"Head": "head",
	"LeftShoulder": "clavicle_l",
	"LeftUpperArm": "upperarm_l",
	"LeftLowerArm": "lowerarm_l",
	"LeftHand": "hand_l",
	"RightShoulder": "clavicle_r",
	"RightUpperArm": "upperarm_r",
	"RightLowerArm": "lowerarm_r",
	"RightHand": "hand_r",
	"LeftUpperLeg": "thigh_l",
	"LeftLowerLeg": "calf_l",
	"LeftFoot": "foot_l",
	"LeftToes": "ball_l",
	"RightUpperLeg": "thigh_r",
	"RightLowerLeg": "calf_r",
	"RightFoot": "foot_r",
	"RightToes": "ball_r",
}

func _init():
	print("--- EXTRACTING ALL 14 ANIMATIONS DUAL-MAPPED TO GENERALSKELETON & SKELETON3D ---")
	var anim_lib := AnimationLibrary.new()
	var save_lib_path := "res://assets/characters/survivor_body/survivor_body_animations.tres"
	var watcher_lib_path := "res://assets/characters/watcher_silhouette/watcher_silhouette_animations.tres"

	var fbx_files := {
		"crawl": "res://assets/characters/survivor_body/crawl.fbx",
		"crawl_down": "res://assets/characters/survivor_body/crawl_down.fbx",
		"crawl_chase": "res://assets/characters/survivor_body/crawl_chase.fbx",
		"crouch_idle": "res://assets/characters/survivor_body/crouch_idle.fbx",
		"crouch_walk": "res://assets/characters/survivor_body/crouch_walk.fbx",
		"downed": "res://assets/characters/survivor_body/downed.fbx",
		"dead": "res://assets/characters/survivor_body/dead.fbx",
		"idle": "res://assets/characters/survivor_body/idle.fbx",
		"lean_left": "res://assets/characters/survivor_body/lean_left.fbx",
		"lean_right": "res://assets/characters/survivor_body/lean_right.fbx",
		"revive": "res://assets/characters/survivor_body/revive.fbx",
		"revive_get_up": "res://assets/characters/survivor_body/revive_get_up.fbx",
		"run": "res://assets/characters/survivor_body/run.fbx",
		"walk": "res://assets/characters/survivor_body/walk.fbx",
	}

	for key in fbx_files:
		var path: String = String(fbx_files[key])
		if not ResourceLoader.exists(path):
			continue
		var ps = load(path) as PackedScene
		if ps:
			var inst = ps.instantiate()
			var anim_players = inst.find_children("*", "AnimationPlayer")
			for ap in anim_players:
				var player = ap as AnimationPlayer
				var libs = player.get_animation_library_list()
				for lib_name in libs:
					var library = player.get_animation_library(lib_name)
					for anim_name in library.get_animation_list():
						var clip = library.get_animation(anim_name).duplicate(true) as Animation
						if key == "revive_get_up" or key == "dead":
							clip.loop_mode = Animation.LOOP_NONE
						elif key != "revive":
							clip.loop_mode = Animation.LOOP_LINEAR
						else:
							clip.loop_mode = Animation.LOOP_NONE

						# BUILD DUAL-TARGET TRACKS FOR BOTH GENERALSKELETON AND SKELETON3D
						var new_clip := Animation.new()
						new_clip.length = clip.length
						new_clip.loop_mode = clip.loop_mode

						for track_idx in range(clip.get_track_count()):
							var orig_path_str := str(clip.track_get_path(track_idx))
							var subname := ""
							if clip.track_get_path(track_idx).get_subname_count() > 0:
								subname = clip.track_get_path(track_idx).get_subname(0)
							elif ":" in orig_path_str:
								subname = orig_path_str.split(":")[-1]

							var mapped_subname := subname
							if MIXAMO_TO_SURVIVOR.has(subname):
								mapped_subname = MIXAMO_TO_SURVIVOR[subname]
							elif subname.begins_with("mixamorig_"):
								mapped_subname = subname.replace("mixamorig_", "")

							var unreal_subname := mapped_subname
							if SURVIVOR_TO_UNREAL.has(mapped_subname):
								unreal_subname = SURVIVOR_TO_UNREAL[mapped_subname]

							var property_suffix := ""
							if ":" in orig_path_str:
								var parts := orig_path_str.split(":")
								if parts.size() > 2:
									property_suffix = ":" + parts[2]

							var track_type := clip.track_get_type(track_idx)

							# Target 1: GeneralSkeleton
							var path1 := NodePath("GeneralSkeleton:" + mapped_subname + property_suffix)
							var t1_idx := new_clip.add_track(track_type)
							new_clip.track_set_path(t1_idx, path1)

							# Target 2: Skeleton3D (Unreal bones for player.fbx)
							var path2 := NodePath("Skeleton3D:" + unreal_subname + property_suffix)
							var t2_idx := new_clip.add_track(track_type)
							new_clip.track_set_path(t2_idx, path2)

							# Target 3: Game_engine/Skeleton3D (Nested Unreal bones for player.fbx)
							var path3 := NodePath("Game_engine/Skeleton3D:" + unreal_subname + property_suffix)
							var t3_idx := new_clip.add_track(track_type)
							new_clip.track_set_path(t3_idx, path3)

							# Copy keyframes
							for k in range(clip.track_get_key_count(track_idx)):
								var time := clip.track_get_key_time(track_idx, k)
								var val = clip.track_get_key_value(track_idx, k)

								var val3 = val
								if unreal_subname == "pelvis":
									if track_type == Animation.TYPE_POSITION_3D:
										var pos = val as Vector3
										if key == "downed" or key == "dead" or key == "crawl_down":
											pos.y = 0.42
											pos.x = 0.0
											pos.z = 0.0
										elif key == "revive" or key == "revive_get_up":
											pos.x = 0.0
											pos.z = 0.0
										val = pos
										val3 = pos
									elif track_type == Animation.TYPE_ROTATION_3D:
										if key in ["downed", "crawl_down", "crawl"]:
											var q = val as Quaternion
											val3 = q * Quaternion(Vector3.UP, deg_to_rad(-90))

								new_clip.track_insert_key(t1_idx, time, val)
								new_clip.track_insert_key(t2_idx, time, val)
								# For player.fbx Game_engine/Skeleton3D, do NOT insert position keyframe on pelvis for standing clips,
								# so the character stands 100% upright on their feet without lying flat on the floor!
								if not (unreal_subname == "pelvis" and track_type == Animation.TYPE_POSITION_3D and not (key in ["downed", "dead", "crawl_down", "revive", "revive_get_up"])):
									new_clip.track_insert_key(t3_idx, time, val3)

						var target_key: String = String(key)
						if anim_lib.has_animation(target_key):
							anim_lib.remove_animation(target_key)
						anim_lib.add_animation(target_key, new_clip)
						print("Dual-targeted '", target_key, "' (length: ", new_clip.length, "s)")
			inst.free()

	ResourceSaver.save(anim_lib, save_lib_path)
	print("Saved survivor_body_animations.tres: ", anim_lib.get_animation_list())

	var watcher_lib := anim_lib.duplicate(true) as AnimationLibrary
	ResourceSaver.save(watcher_lib, watcher_lib_path)
	print("Saved watcher_silhouette_animations.tres: ", watcher_lib.get_animation_list())
	quit()
