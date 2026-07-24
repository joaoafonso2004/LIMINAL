extends SceneTree
var _done := false
func _process(_x: float) -> bool:
	if _done: return true
	_done = true
	_run()
	return false

func _run() -> void:
	var f: Array[String] = []
	var d := Node3D.new()
	d.set_script(load("res://scripts/world/entity_director.gd"))
	root.add_child(d)

	# os FBX carregam?
	for k in ["peek_right", "peek_left"]:
		var p: String = d.NEW_ENTITY_ANIMATION_SOURCES[k]
		if not ResourceLoader.exists(p):
			f.append(k + ": ficheiro nao importado")
		elif ResourceLoader.load(p) == null:
			f.append(k + ": nao carrega")
		else:
			print("%s importa OK" % k)

	# sobrevivem ao retargeting para o new_entity?
	var scene = ResourceLoader.load(d.NEW_ENTITY_PATH) if ResourceLoader.exists(d.NEW_ENTITY_PATH) else null
	if scene == null:
		f.append("new_entity.glb em falta")
	else:
		var lib = d._retarget_new_entity(scene)
		if not (lib is AnimationLibrary):
			f.append("a biblioteca da Entity nao foi construida")
		else:
			var names := []
			for n in lib.get_animation_list():
				names.append(String(n))
			names.sort()
			print("clips finais: ", names)
			for k in ["peek_right", "peek_left"]:
				if not (k in names):
					f.append(k + " NAO sobreviveu ao retargeting")
				else:
					var a: Animation = lib.get_animation(k)
					var tracks: int = a.get_track_count()
					print("  %s: %.2f s, %d tracks, loop=%s"
						% [k, a.length, tracks, a.loop_mode != Animation.LOOP_NONE])
					if a.length < 0.1:
						f.append(k + " ficou com duracao nula")
					if tracks < 6:
						f.append("%s so tem %d tracks: retarget quase vazio" % [k, tracks])
			# nao pode ter perdido nada
			for req in ["idle", "walk", "run", "confused", "entity_attack",
					"entity_eat_start", "entity_eat_loop", "entity_eat_end"]:
				if not (req in names):
					f.append("REGRESSAO: perdeu o clip " + req)
			# os dois ombros tem de ser realmente diferentes
			if ("peek_right" in names) and ("peek_left" in names):
				var r: Animation = lib.get_animation("peek_right")
				var l: Animation = lib.get_animation("peek_left")
				var differ := false
				if r.get_track_count() == l.get_track_count() and r.get_track_count() > 0:
					for ti in range(r.get_track_count()):
						if r.track_get_key_count(ti) > 0 and l.track_get_key_count(ti) > 0:
							var rv = r.track_get_key_value(ti, 0)
							var lv = l.track_get_key_value(ti, 0)
							if str(rv) != str(lv):
								differ = true
								break
				else:
					differ = true
				print("  ombros distintos entre si: ", differ)
				if not differ:
					f.append("peek_left e peek_right sao identicos")

	# o fallback deixa de ser usado agora que existem
	var src := FileAccess.get_file_as_string("res://scripts/world/entity_director.gd")
	if not src.contains("_peek_authored"):
		f.append("falta o gate do override procedimental")
	d.free()
	print("")
	if f.is_empty(): print("PEEK_CLIPS_OK")
	else:
		for x in f: printerr("PEEK_FAIL: " + x)
	quit(0 if f.is_empty() else 1)
