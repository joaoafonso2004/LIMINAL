extends Node3D
## LIMINAL world coordinator. Spawns the player, streaming maze, and entity
## director; owns the WorldEnvironment, ambient beds, endings, and the secret
## ending. No HUD — everything the player learns comes from sound and light.

const PLAYER_SCRIPT := "res://scripts/player/player_controller.gd"
const OVERLAY_SCRIPT := "res://scripts/ui/overlay.gd"

const HUM_PATH := "res://assets/audio/ambient/ambient_backrooms_office_fluorescent_hum_loop.mp3"
const HVAC_PATH := ""
# The menu theme, pitched way down, doubles as the deep dark room-tone drone
# (A24 Backrooms-ambience vibe) — unrecognizable at 0.72x and costs no new asset.
const DRONE_PATH := ""
const FINAL_MUSIC := "res://assets/audio/music/music_climax_final_exit_drone.mp3"

# Timings (seconds) — pacing knobs live in scripts/tuning.gd
const FINAL_PHASE_TIME := Tuning.FINAL_PHASE_TIME

var _player: CharacterBody3D = null
var _camera: Camera3D = null
var _maze: Node3D = null
var _entity: Node3D = null
var _overlay: CanvasLayer = null
var _pause: CanvasLayer = null

var _hum: AudioStreamPlayer = null
var _hvac: AudioStreamPlayer = null
var _drone: AudioStreamPlayer = null

var _ended := false
var _final_started := false
var _exit_enabled := false
var _muffled := false

# secret ending: stand still in an anomaly room for 60s
var _still_in_anomaly := 0.0
var _last_pos := Vector3.ZERO

# snus collection
var _snus: Node3D = null
var _snus_done := false

# co-op
var _is_mp := false
var _remote_players: Dictionary = {}   # player_id -> remote body
var _remote_down: Dictionary = {}      # player_id -> true (caught or disconnected)
var _local_is_down := false
var _snus_ui: CanvasLayer = null
var _distant_sound_timer := 20.0
var _phone_scare_cd := 0.0             # trapped phones can't chain-scare
var _radar_timer := 0.0
var _radar_ping_cd := 0.0
var _interact_prompt: Label = null
var _interact_canvas: CanvasLayer = null
var _lockers: Node3D = null

func _ready() -> void:
	_is_mp = has_node("/root/NetManager") and NetManager.is_multiplayer
	# The muffle low-pass lives on the global SFX bus — clear leftovers from a
	# previous run that ended mid-muffle, or the world stays underwater forever.
	var sfx_idx := AudioServer.get_bus_index("SFX")
	if sfx_idx >= 0:
		while AudioServer.get_bus_effect_count(sfx_idx) > 0:
			AudioServer.remove_bus_effect(sfx_idx, 0)
	_setup_environment()
	_spawn_player()
	_spawn_maze()
	_spawn_entity()
	_spawn_overlay()
	_spawn_pause()
	_spawn_snus()
	_spawn_snus_ui()
	_spawn_lockers()
	_setup_interact_prompt()
	_setup_ambient()
	if _is_mp:
		_setup_multiplayer()
	if has_node("/root/GameManager"):
		GameManager.start_run()
	_last_pos = _player.global_position if is_instance_valid(_player) else Vector3.ZERO

# ---------------------------------------------------------------------------
func _setup_environment() -> void:
	# Reference grade: near-black brown shadows, isolated hot panels blooming
	# warm orange, drained colour. The dark owns everything between the pools.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.011, 0.008)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.37, 0.27)
	env.ambient_light_energy = Tuning.AMBIENT_ENERGY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.9
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_strength = 1.05
	env.glow_bloom = 0.3
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true
	env.fog_light_color = Color(0.42, 0.37, 0.27)
	env.fog_light_energy = 0.6
	env.fog_density = Tuning.FOG_DENSITY
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_brightness = 0.97
	env.adjustment_contrast = 1.16
	env.adjustment_saturation = 0.68
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _spawn_player() -> void:
	_player = CharacterBody3D.new()
	_player.set_script(load(PLAYER_SCRIPT))
	_player.position = Vector3(0, 0.1, 0)
	add_child(_player)
	_camera = _player.get_camera() if _player.has_method("get_camera") else null
	if _player.has_signal("looked_back"):
		_player.looked_back.connect(_on_looked_back)

func _spawn_maze() -> void:
	_maze = Node3D.new()
	_maze.set_script(load("res://scripts/world/maze_manager.gd"))
	# The layout is ALWAYS static — multiplayer compatibility demands that every
	# client (and every return trip) sees the exact same maze.
	if _maze.has_method("set_static_layout"):
		_maze.set_static_layout(true)
	add_child(_maze)
	_maze.setup(_player)
	if _maze.has_signal("exit_reached"):
		_maze.exit_reached.connect(_on_exit_reached)

func _spawn_snus() -> void:
	_snus = Node3D.new()
	_snus.set_script(load("res://scripts/world/snus_manager.gd"))
	add_child(_snus)
	_snus.setup(_player, _maze)
	if _snus.has_signal("count_changed"):
		_snus.count_changed.connect(_on_snus_count)
	if _snus.has_signal("all_collected"):
		_snus.all_collected.connect(_on_snus_all)

func _spawn_entity() -> void:
	_entity = Node3D.new()
	_entity.set_script(load("res://scripts/world/entity_director.gd"))
	add_child(_entity)
	_entity.setup(_player, _camera, _maze)
	if _is_mp and _entity.has_method("setup_mp"):
		_entity.setup_mp(self, NetManager.is_host)
	_entity.request_dread.connect(_on_dread)
	_entity.request_flicker.connect(_on_flicker)
	_entity.jumpscare.connect(_on_jumpscare)
	_entity.muffle.connect(_on_muffle)
	_entity.caught.connect(_on_caught)
	_entity.chase_ended.connect(_on_chase_ended)

func _spawn_overlay() -> void:
	_overlay = load(OVERLAY_SCRIPT).new()
	add_child(_overlay)

func _spawn_pause() -> void:
	_pause = load("res://scripts/ui/pause_menu.gd").new()
	add_child(_pause)

const HUM_VOL := -12.0
const HVAC_VOL := -20.0
const DRONE_VOL := -16.0
const HUM_PITCH := 0.92                # darker, heavier mains hum
const HUM_PITCH_MUFFLED := 0.78        # drops further when something unseen is near
const DRONE_PITCH := 0.72              # menu theme slowed into a deep room-tone

var _amb_tween: Tween = null

func _setup_ambient() -> void:
	# Keep the game's ambient music playing seamlessly from the main menu!
	if has_node("/root/AudioManager"):
		AudioManager.play_music(load("res://assets/audio/ambient/ambient.mp3"), -8.0, 1.0)
	# The bed NEVER stops outside the post-jumpscare beat:
	# deep drone underneath, dark hum on top, HVAC breathing far away.
	_hum = _make_loop(HUM_PATH, HUM_VOL)
	if _hum:
		_hum.pitch_scale = HUM_PITCH
	_hvac = _make_loop(HVAC_PATH, HVAC_VOL)
	_drone = _make_loop(DRONE_PATH, DRONE_VOL)
	if _drone:
		_drone.pitch_scale = DRONE_PITCH

## Cut the ambient bed to near-silence, hold, then let it breathe back in.
func _duck_ambient(attack: float, hold: float, release: float) -> void:
	var layers: Array = []
	var vols: Array = []
	for pair in [[_hum, HUM_VOL], [_hvac, HVAC_VOL], [_drone, DRONE_VOL]]:
		if pair[0] != null:
			layers.append(pair[0])
			vols.append(pair[1])
	if layers.is_empty():
		return
	if _amb_tween and _amb_tween.is_valid():
		_amb_tween.kill()
	_amb_tween = create_tween()
	for i in layers.size():
		if i == 0:
			_amb_tween.tween_property(layers[i], "volume_db", -60.0, attack)
		else:
			_amb_tween.parallel().tween_property(layers[i], "volume_db", -60.0, attack)
	_amb_tween.tween_interval(hold)
	for i in layers.size():
		if i == 0:
			_amb_tween.tween_property(layers[i], "volume_db", vols[i], release)
		else:
			_amb_tween.parallel().tween_property(layers[i], "volume_db", vols[i], release)

func _make_loop(path: String, vol: float) -> AudioStreamPlayer:
	if not ResourceLoader.exists(path):
		return null
	var p := AudioStreamPlayer.new()
	p.stream = load(path)
	p.bus = "SFX"
	p.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	p.volume_db = vol
	p.autoplay = false
	add_child(p)
	# loop the stream if the importer didn't
	if p.stream is AudioStreamMP3:
		(p.stream as AudioStreamMP3).loop = true
	p.play()
	p.finished.connect(func(): if is_instance_valid(p): p.play())
	return p

# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	if _ended:
		return
	var t := 0.0
	if has_node("/root/GameManager"):
		t = GameManager.run_time
	# phase gates. The exit now opens only once all snus are found (see
	# _on_snus_all); the final stalker phase still arrives on the clock.
	if not _final_started and t >= FINAL_PHASE_TIME:
		_final_started = true
		if _entity and _entity.has_method("enter_final_phase"):
			_entity.enter_final_phase()
		# the final drone rises in the last stretch
		if has_node("/root/AudioManager") and ResourceLoader.exists(FINAL_MUSIC):
			AudioManager.play_music(load(FINAL_MUSIC), -16.0, 6.0)
			AudioManager.set_music_volume(-6.0, 45.0)
	_tick_secret(delta)
	_phone_scare_cd = maxf(0.0, _phone_scare_cd - delta)
	_tick_phone_interaction()
	_update_interact_prompt(delta)
	_tick_distant_laughs(delta)

	if _radar_timer > 0.0:
		_radar_timer -= delta
		_radar_ping_cd -= delta
		if _radar_ping_cd <= 0.0:
			_play_radar_ping()

func _tick_secret(delta: float) -> void:
	if not is_instance_valid(_player):
		return
	var moved := _player.global_position.distance_to(_last_pos)
	_last_pos = _player.global_position
	var in_anom: bool = _maze != null and _maze.has_method("player_in_anomaly") and bool(_maze.player_in_anomaly())
	if in_anom and moved < 0.03:
		_still_in_anomaly += delta
		if _still_in_anomaly >= 60.0:
			_trigger_secret_ending()
	else:
		_still_in_anomaly = maxf(0.0, _still_in_anomaly - delta * 2.0)

# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------
func _on_looked_back() -> void:
	# a soft distant creak rewards the nervous glance
	if has_node("/root/AudioManager"):
		var s := "res://assets/audio/sfx/environment/environment_hallway_rearrange_creak.mp3"
		if ResourceLoader.exists(s) and randf() < 0.5:
			AudioManager.play_sfx(load(s), -12.0)

func _on_dread(v: float) -> void:
	if _overlay and _overlay.has_method("set_dread"):
		_overlay.set_dread(v)

func _on_flicker(v: float) -> void:
	if _maze and _maze.has_method("set_flicker"):
		_maze.set_flicker(v)

func _on_jumpscare() -> void:
	if _overlay and _overlay.has_method("pulse"):
		_overlay.pulse(2.0)
	if _overlay and _overlay.has_method("flash"):
		_overlay.flash(Color(0, 0, 0, 0.6), 0.5)
	if _maze and _maze.has_method("set_flicker"):
		_maze.set_flicker(1.0)
	# the ONLY sanctioned absolute silence: right after the scream
	_duck_ambient(0.2, 2.4, 3.0)

func _on_chase_ended() -> void:
	# it vanished — hard cut, a beat of dead air, then the hum seeps back
	_duck_ambient(0.05, 1.2, 2.5)

func _on_muffle(active: bool) -> void:
	_muffled = active
	# the fluorescent hum drops in pitch when something unseen is close
	if _hum:
		_hum.pitch_scale = HUM_PITCH_MUFFLED if active else HUM_PITCH
	var idx := AudioServer.get_bus_index("SFX")
	if idx < 0:
		return
	# add/remove a low-pass to muffle the world when a vulto is near-but-unseen
	if active and AudioServer.get_bus_effect_count(idx) == 0:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 600.0
		AudioServer.add_bus_effect(idx, lp)
	elif not active and AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)

func _on_caught() -> void:
	if _is_mp:
		# In co-op, being caught takes only you out — tell the others and
		# spectate rather than restarting everyone's run.
		if has_node("/root/NetManager"):
			NetManager.send("down", {})
		_local_down()
		return
	_end_run("caught")

func _on_exit_reached() -> void:
	# Only a real escape if the snus unlocked it.
	if not _snus_done:
		return
	if _is_mp and has_node("/root/NetManager"):
		NetManager.send("escaped", {})
	_end_run("exit")

# ---------------------------------------------------------------------------
# Snus collection
# ---------------------------------------------------------------------------
func _on_snus_count(collected: int, total: int) -> void:
	if _snus_ui and _snus_ui.has_method("set_count"):
		_snus_ui.set_count(collected, total)
	# every tin taken makes it angrier — shared pickups, shared difficulty
	if _entity and _entity.has_method("set_menace"):
		_entity.set_menace(float(collected) / float(maxi(total, 1)))

func _on_snus_all() -> void:
	if _snus_done:
		return
	_snus_done = true
	_exit_enabled = true
	if _maze and _maze.has_method("enable_exit"):
		_maze.enable_exit()
	if _snus_ui and _snus_ui.has_method("announce_exit"):
		_snus_ui.announce_exit()

func _spawn_snus_ui() -> void:
	_snus_ui = load("res://scripts/ui/snus_hud.gd").new()
	add_child(_snus_ui)

# ---------------------------------------------------------------------------
# Co-op networking
# ---------------------------------------------------------------------------
func _setup_multiplayer() -> void:
	NetManager.message_received.connect(_on_net_message)
	NetManager.player_disconnected.connect(_on_player_disconnected)
	_spawn_remote_players()
	_start_position_broadcast()

func _spawn_remote_players() -> void:
	var rp_script := load("res://scripts/world/remote_player.gd")
	for pid in range(NetManager.max_players):
		if pid == NetManager.local_player_id:
			continue
		var rp := CharacterBody3D.new()
		rp.set_script(rp_script)
		rp.player_id = pid
		add_child(rp)
		rp.global_position = Vector3(0, 0.1, 0)
		_remote_players[pid] = rp
		# Remote teammates can also grab snus near them.
		if _snus and _snus.has_method("register_player_body"):
			_snus.register_player_body(rp)

func _start_position_broadcast() -> void:
	var timer := Timer.new()
	timer.wait_time = 0.05
	timer.autostart = true
	timer.timeout.connect(_broadcast_position)
	add_child(timer)

func _broadcast_position() -> void:
	if _ended or not is_instance_valid(_player):
		return
	NetManager.send("pos", {
		"x": _player.global_position.x,
		"y": _player.global_position.y,
		"z": _player.global_position.z,
		"ry": _player.rotation.y,
	})

func _on_net_message(type: String, msg: Dictionary, from_player: int) -> void:
	match type:
		"pos":
			var rp = _remote_players.get(from_player)
			if rp and is_instance_valid(rp) and rp.has_method("update_target"):
				rp.update_target(msg)
		"snus":
			if _snus and _snus.has_method("remote_collect"):
				_snus.remote_collect(int(msg.get("id", -1)))
		"down":
			var rp2 = _remote_players.get(from_player)
			if rp2 and is_instance_valid(rp2) and rp2.has_method("set_dead"):
				rp2.set_dead(true)
			_remote_down[from_player] = true
			_check_all_down()
		"escaped":
			# A teammate reached the exit — the whole team gets out.
			if not _ended:
				_end_run("exit")
		"secret":
			# A teammate stood too still in a wrong room — the team ends with them.
			if not _ended:
				_end_run("secret")
		"scare":
			# The host assigned US the next scare — our camera realizes it.
			if int(msg.get("target", -1)) == NetManager.local_player_id \
					and _entity and _entity.has_method("remote_scare"):
				_entity.remote_scare(str(msg.get("kind", "peek")))
		"fig":
			# A teammate's scare is live — render the same entity here.
			if _entity and _entity.has_method("mirror_update"):
				_entity.mirror_update(msg)
		"figoff":
			if _entity and _entity.has_method("mirror_off"):
				_entity.mirror_off()

func _on_player_disconnected(pid: int) -> void:
	var rp = _remote_players.get(pid)
	if rp and is_instance_valid(rp):
		if rp.has_method("set_dead"):
			rp.set_dead(true)
	# A player who left can no longer save the team.
	if pid >= 0:
		_remote_down[pid] = true
		_check_all_down()

func _local_down() -> void:
	# Local player caught in co-op: freeze + fade, but keep watching the team.
	_local_is_down = true
	if is_instance_valid(_camera):
		_camera.fov = 72.0   # undo the kill close-up zoom for spectating
	if is_instance_valid(_player) and _player.has_method("set_frozen"):
		_player.set_frozen(true)
	if _overlay and _overlay.has_method("fade_to"):
		_overlay.fade_to(Color(0, 0, 0, 0.72), 1.2)
	if _overlay and _overlay.has_method("show_ending"):
		_overlay.show_ending(
			"It found you.\n\nWait for the others…\nor for the dark.",
			Color(0, 0, 0, 0.82),
			Color(0.7, 0.66, 0.42))
	_check_all_down()

## Relay used by the shared-entity director (and any future networked system).
func net_send(type: String, data: Dictionary) -> void:
	if _is_mp and has_node("/root/NetManager"):
		NetManager.send(type, data)

## Players still standing — the host's scare director picks targets from this.
func alive_player_ids() -> Array:
	var ids: Array = []
	if not _local_is_down and has_node("/root/NetManager"):
		ids.append(NetManager.local_player_id)
	for pid in _remote_players.keys():
		if not _remote_down.has(pid):
			ids.append(int(pid))
	return ids

## Every client runs this on the same shared facts (down + disconnect events).
## When no one is left standing, the run ends for everyone — no eternal
## spectator softlock.
func _check_all_down() -> void:
	if _ended or not _is_mp or not _local_is_down:
		return
	for pid in _remote_players.keys():
		if not _remote_down.has(pid):
			return  # someone is still on their feet
	_end_run("caught")

# ---------------------------------------------------------------------------
# Endings
# ---------------------------------------------------------------------------
func _end_run(reason: String) -> void:
	if _ended:
		return
	_ended = true
	if is_instance_valid(_player) and _player.has_method("set_frozen"):
		_player.set_frozen(true)
	if has_node("/root/GameManager"):
		GameManager.end_run(reason)
	match reason:
		"caught":
			_ending_caught()
		"exit":
			_ending_exit()
		"secret":
			_ending_secret()

func _ending_caught() -> void:
	# hard cut to black + dead silence, the sentence, then the choice
	if _overlay and _overlay.has_method("fade_to"):
		_overlay.fade_to(Color(0, 0, 0, 1), 0.12)
	if _hum:
		_hum.stop()
	if _hvac:
		_hvac.stop()
	if _drone:
		_drone.stop()
	if has_node("/root/AudioManager"):
		AudioManager.fade_out_music(0.3)
	if _overlay and _overlay.has_method("show_ending"):
		_overlay.show_ending(
			"Ele encontrou-te primeiro.",
			Color(0, 0, 0),
			Color(0.7, 0.66, 0.42))
	await get_tree().create_timer(2.8).timeout
	_show_death_menu()

## Three doors out of the dark: try again, main menu, quit.
func _show_death_menu() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var layer := CanvasLayer.new()
	layer.layer = 30   # above the CRT filter and the ending text
	add_child(layer)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	layer.add_child(vb)
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.offset_top = 90.0
	vb.offset_bottom = 330.0
	vb.offset_left = -160.0
	vb.offset_right = 160.0

	var font: Font = null
	if ResourceLoader.exists("res://assets/fonts/special_elite.ttf"):
		font = load("res://assets/fonts/special_elite.ttf")

	var entries: Array = [
		["TRY AGAIN", func():
			if has_node("/root/GameManager"):
				GameManager.restart()],
		["MAIN MENU", func():
			if has_node("/root/GameManager"):
				GameManager.to_menu()],
	]
	if not OS.has_feature("web"):
		entries.append(["QUIT", func(): get_tree().quit()])

	for e in entries:
		var b := Button.new()
		b.text = e[0]
		b.custom_minimum_size = Vector2(280, 62)
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		UIKit.style_button(b, font, 24)
		b.pressed.connect(e[1])
		vb.add_child(b)

func _ending_exit() -> void:
	if has_node("/root/AudioManager"):
		AudioManager.fade_out_music(3.0)
	if _overlay and _overlay.has_method("show_ending"):
		_overlay.show_ending(
			"You left.\n\nBut did you count the figures?\nThey counted you.",
			Color(0.95, 0.95, 0.93, 1.0),
			Color(0.15, 0.14, 0.1))
	await get_tree().create_timer(9.0).timeout
	if has_node("/root/GameManager"):
		GameManager.to_menu()

func _trigger_secret_ending() -> void:
	# In co-op the whole team shares the ending — tell them before we go.
	if _is_mp and has_node("/root/NetManager"):
		NetManager.send("secret", {})
	_end_run("secret")

func _ending_secret() -> void:
	# all lights die but one far away; all sound stops
	if _maze and _maze.has_method("set_flicker"):
		_maze.set_flicker(0.0)
	if _hum: _hum.stop()
	if _hvac: _hvac.stop()
	if _drone: _drone.stop()
	if has_node("/root/AudioManager"):
		AudioManager.fade_out_music(2.0)
	if _overlay and _overlay.has_method("show_ending"):
		_overlay.show_ending(
			"Now you are the one\nwaiting at the corner.",
			Color(0, 0, 0, 1.0),
			Color(0.7, 0.66, 0.42))
	await get_tree().create_timer(9.0).timeout
	if has_node("/root/GameManager"):
		GameManager.to_menu()

func _tick_phone_interaction() -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_maze):
		return
	if Input.is_action_just_pressed("interact"):
		# 1. Check locker interaction
		if _lockers and _lockers.has_method("toggle_hide_in_locker"):
			if _lockers.toggle_hide_in_locker():
				return
				
		# 2. Check phone interaction
		var px := int(floor(_player.global_position.x / 4.0 + 0.5))
		var pz := int(floor(_player.global_position.z / 4.0 + 0.5))
		var pcell := Vector2i(px, pz)
		if _maze.has_method("get_phone_node_in_cell"):
			var phone = _maze.get_phone_node_in_cell(pcell)
			if is_instance_valid(phone):
				var dist = _player.global_position.distance_to(phone.global_position)
				if dist < 2.2:
					_interact_with_phone(phone)

## Answering a phone is a gamble. Every phone breathes at you — but what
## follows depends on WHICH phone it is (fixed per phone, same for every
## co-op client): some are radar phones (a red pulse marks the nearest tin
## for a few seconds — a bearing, not a map), some are trapped (the entity
## answers), and some just breathe and hang up.
func _phone_fate(phone: Node3D) -> String:
	var cx := int(floor(phone.global_position.x / 4.0 + 0.5))
	var cz := int(floor(phone.global_position.z / 4.0 + 0.5))
	var h := posmod(cx * 31 + cz * 17, 10)
	if h <= 3:
		return "radar"      # 40%
	elif h <= 6:
		return "scare"      # 30%
	return "silence"        # 30%

func _interact_with_phone(phone: Node3D) -> void:
	if phone.has_meta("interacting") and phone.get_meta("interacting"):
		return
	phone.set_meta("interacting", true)

	if not has_node("/root/AudioManager"):
		return
	var breath_stream = load("res://assets/audio/juanjo/juanjo_sound - Backrooms Entity 23.wav")
	var click_stream = load("res://assets/audio/sfx/environment/environment_light_flicker_buzz.mp3")
	var fate := _phone_fate(phone)

	# Receiver pick-up click, then the breathing — every phone breathes.
	AudioManager.play_sfx_3d(self, click_stream, phone.global_position, 0.0, 15.0, 1.2)
	get_tree().create_timer(0.15).timeout.connect(func():
		if not is_instance_valid(phone) or not has_node("/root/AudioManager"):
			return
		AudioManager.play_sfx_3d(self, breath_stream, phone.global_position, 8.0, 20.0, 0.85)
		if _overlay and _overlay.has_method("pulse"):
			_overlay.pulse(0.6)
		if _maze and _maze.has_method("set_flicker"):
			_maze.set_flicker(0.7)
			get_tree().create_timer(1.4).timeout.connect(func():
				if is_instance_valid(_maze) and _maze.has_method("set_flicker"):
					_maze.set_flicker(0.0)
			)

		match fate:
			"radar":
				# A brief red pulse through the walls: direction, not location.
				var nearest_pos := Vector3.ZERO
				if _snus and _snus.has_method("get_nearest_uncollected_pos"):
					nearest_pos = _snus.get_nearest_uncollected_pos(_player.global_position)
				if nearest_pos != Vector3.ZERO:
					_radar_timer = 16.0
					_radar_ping_cd = 0.05  # start pinging immediately!
					
					var beacon := OmniLight3D.new()
					beacon.light_color = Color(1.0, 0.15, 0.15)
					beacon.light_energy = 9.0
					beacon.omni_range = 35.0
					beacon.shadow_enabled = false
					add_child(beacon)
					beacon.global_position = nearest_pos
					get_tree().create_timer(3.5).timeout.connect(func():
						if is_instance_valid(beacon):
							beacon.queue_free()
					)
			"scare":
				# Wrong number. It was already on the line.
				if _phone_scare_cd <= 0.0:
					_phone_scare_cd = 60.0
					get_tree().create_timer(1.1).timeout.connect(func():
						if _entity and _entity.has_method("phone_jumpscare"):
							_entity.phone_jumpscare()
					)
			_:
				pass  # just the breathing, then the line goes dead

		get_tree().create_timer(1.8).timeout.connect(func():
			if is_instance_valid(phone):
				phone.set_meta("interacting", false)
		)
	)

func _tick_distant_laughs(delta: float) -> void:
	if not is_instance_valid(_player):
		return
	_distant_sound_timer -= delta
	if _distant_sound_timer <= 0.0:
		_distant_sound_timer = randf_range(20.0, 48.0)
		_play_distant_laugh()

func _play_distant_laugh() -> void:
	if not is_instance_valid(_player) or not has_node("/root/AudioManager"):
		return
	var idx := randi_range(1, 30)
	var path := "res://assets/audio/juanjo/juanjo_sound - Backrooms Entity %d.wav" % idx
	if not ResourceLoader.exists(path):
		return
	
	# Choose a random distant position (16 to 28 meters away)
	var ang := randf() * TAU
	var dist := randf_range(16.0, 28.0)
	var offset := Vector3(cos(ang), 0, sin(ang)) * dist
	var target_pos := _player.global_position + offset
	target_pos.y = 1.2
	
	var stream = load(path)
	var vol := randf_range(-14.0, -6.0)
	AudioManager.play_sfx_3d(self, stream, target_pos, vol, 40.0, randf_range(0.9, 1.1))
	
	# Trigger a faint light flicker in the direction of the distant noise
	if _maze and _maze.has_method("set_flicker"):
		_maze.set_flicker(0.3)
		get_tree().create_timer(0.6).timeout.connect(func():
			if is_instance_valid(_maze) and _maze.has_method("set_flicker"):
				_maze.set_flicker(0.0)
		)


func _play_radar_ping() -> void:
	if not is_instance_valid(_player) or not has_node("/root/AudioManager"):
		return
	var nearest_pos := Vector3.ZERO
	if _snus and _snus.has_method("get_nearest_uncollected_pos"):
		nearest_pos = _snus.get_nearest_uncollected_pos(_player.global_position)
	if nearest_pos == Vector3.ZERO:
		_radar_timer = 0.0  # no tins left, shut off radar
		return
	
	var dist := _player.global_position.distance_to(nearest_pos)
	
	# Faster ping rate the closer you are: from 1.8s (far) down to 0.38s (close)
	var closeness := clampf(1.0 - (dist / 28.0), 0.0, 1.0)
	_radar_ping_cd = lerpf(1.8, 0.38, closeness)
	
	# Higher pitch the closer you are!
	var pitch := lerpf(1.5, 2.4, closeness)
	# Muffled/quieter when crouching to stay stealthy
	var vol := -17.5
	if "is_crouching" in _player and _player.is_crouching:
		vol = -24.0
		pitch *= 0.8
	
	var ping_stream = load("res://assets/audio/sfx/pickup/pickup_snus_pickup.mp3")
	AudioManager.play_sfx(ping_stream, vol, pitch)


func _setup_interact_prompt() -> void:
	_interact_canvas = CanvasLayer.new()
	_interact_canvas.layer = 5   # below overlay
	add_child(_interact_canvas)
	
	_interact_prompt = Label.new()
	_interact_prompt.name = "InteractPrompt"
	_interact_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interact_prompt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	# Premium HUD typography & outline shadow
	_interact_prompt.text = "[E] INTERACT"
	_interact_prompt.add_theme_font_size_override("font_size", 18)
	_interact_prompt.add_theme_color_override("font_color", Color(0.96, 0.94, 0.88))
	_interact_prompt.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_interact_prompt.add_theme_constant_override("shadow_offset_x", 1)
	_interact_prompt.add_theme_constant_override("shadow_offset_y", 1)
	_interact_prompt.add_theme_constant_override("shadow_outline_size", 3)
	
	_interact_canvas.add_child(_interact_prompt)
	_interact_prompt.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	# Position it slightly above the screen bottom (around 120 pixels up)
	_interact_prompt.position.y -= 130.0
	
	# Start invisible
	_interact_prompt.modulate.a = 0.0


func _update_interact_prompt(delta: float) -> void:
	if not is_instance_valid(_player) or _interact_prompt == null:
		return
		
	var target_text := ""
	var in_range := false
	
	# 1. Check if player is already inside locker
	if _lockers and _lockers.has_method("is_player_inside") and _lockers.is_player_inside():
		target_text = "[E] LEAVE LOCKER"
		in_range = true
	
	# 2. Check SNUS proximity
	if not in_range and _snus and _snus.has_method("is_snus_in_range"):
		if _snus.is_snus_in_range(_player.global_position):
			target_text = "[E] GRAB SNUS"
			in_range = true
			
	# 3. Check Telephone proximity (if SNUS isn't already taking priority)
	if not in_range:
		var px := int(floor(_player.global_position.x / 4.0 + 0.5))
		var pz := int(floor(_player.global_position.z / 4.0 + 0.5))
		var pcell := Vector2i(px, pz)
		if _maze and _maze.has_method("get_phone_node_in_cell"):
			var phone = _maze.get_phone_node_in_cell(pcell)
			if is_instance_valid(phone):
				var dist = _player.global_position.distance_to(phone.global_position)
				if dist < 2.2:
					if not phone.has_meta("interacting") or not phone.get_meta("interacting"):
						target_text = "[E] ANSWER TELEPHONE"
						in_range = true
						
	# 4. Check Locker proximity
	if not in_range and _lockers and _lockers.has_method("get_nearest_locker_in_range"):
		var locker = _lockers.get_nearest_locker_in_range(_player.global_position)
		if is_instance_valid(locker):
			target_text = "[E] ENTER LOCKER"
			in_range = true
			
	# Respond instantly and smoothly fade
	if in_range:
		_interact_prompt.text = target_text
		_interact_prompt.modulate.a = lerpf(_interact_prompt.modulate.a, 1.0, 16.0 * delta)
	else:
		_interact_prompt.modulate.a = lerpf(_interact_prompt.modulate.a, 0.0, 16.0 * delta)
