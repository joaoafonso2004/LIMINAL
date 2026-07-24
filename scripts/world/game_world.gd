extends Node3D
## LIMINAL world coordinator. Spawns the player, streaming maze, and entity
## director; owns the WorldEnvironment, ambient beds, endings, and the secret
## ending. No HUD — everything the player learns comes from sound and light.

const PLAYER_SCRIPT := "res://scripts/player/player_controller.gd"
const OVERLAY_SCRIPT := "res://scripts/ui/overlay.gd"
const REMOTE_PLAYER_SCRIPT := "res://scripts/world/remote_player.gd"

const HUM_PATH := "res://assets/audio/ambient/ambient_backrooms_office_fluorescent_hum_loop.mp3"
const VHS_BED_PATH := "res://assets/audio/sfx/environment/VHS_sound.mp3"
const HVAC_PATH := ""
# The menu theme, pitched way down, doubles as the deep dark room-tone drone
# (A24 Backrooms-ambience vibe) — unrecognizable at 0.72x and costs no new asset.
const DRONE_PATH := ""
const FINAL_MUSIC := "res://assets/audio/music/music_climax_final_exit_drone.mp3"
const ESCAPE_VIDEO := "res://assets/video/END.ogv"
const END_VIDEO_START_VOLUME_DB := -60.0
const END_VIDEO_TARGET_VOLUME_DB := -22.0
const END_VIDEO_AUDIO_FADE_SECONDS := 5.0

# CX30 — victim-only jumpscare. The clip is ~3.29 s, the 3D sequence ~5.48 s at
# 1.55x, so the layer stays black until `caught` arrives and downed is entered.
const JUMPSCARE_VIDEO_SCRIPT := "res://scripts/ui/jumpscare_video.gd"
const JUMPSCARE_DOWNED_FADE := 0.52
# Hard ceiling: if the director is freed mid-sequence and `caught` never lands,
# the black screen must never become a permanent soft-lock.
const JUMPSCARE_MAX_HOLD := 14.0

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
var _vhs_bed: AudioStreamPlayer = null

var _ended := false
var _final_started := false
var _exit_enabled := false
var _local_exit_transition := false
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
var _radar_pings_left := 0
var _interact_prompt: Label = null
var _interact_canvas: CanvasLayer = null
var _lockers: Node3D = null
var _content: Node3D = null
var _mimic: Node3D = null
var _extraction: Node3D = null
var _callout_cooldown := 0.0
var _callout_stream: AudioStream = null
var _content_interaction_active := false
var _extraction_interaction_active := false
var _receiving_shared_content := false
var _run_seed: int = 1
var _run_spawn_cells: Array[Vector2i] = []
var _last_safe_player_position := Vector3.ZERO
var _safe_position_ready := false
var _fall_recovery_cooldown := 0.0
const FALL_RECOVERY_Y := -3.0
# CX31 — how close you must be for the sealed exit door to speak up.
const EXIT_PROMPT_RANGE := 3.4

# CX08-COOP-GROUPED-SPAWN. Set false for production separated co-op spawns.
const TEST_FORCE_GROUPED_SPAWNS := false

var _downed_body_visual: Node3D = null
var _jumpscare_video: CanvasLayer = null
var _jumpscare_hold_timer := 0.0
var _crawl_blood_trail_timer := 0.0

func _ready() -> void:
	_is_mp = has_node("/root/NetManager") and NetManager.is_multiplayer
	_run_seed = NetManager.get_run_seed() if has_node("/root/NetManager") else 1
	# Audio buses are autoload state and survive scene changes. Restore the
	# dedicated breathing child bus before the solo/local player is constructed.
	if has_node("/root/Settings") and Settings.has_method("apply_audio"):
		Settings.apply_audio()
	# The muffle low-pass lives on the global SFX bus — clear leftovers from a
	# previous run that ended mid-muffle, or the world stays underwater forever.
	var sfx_idx := AudioServer.get_bus_index("SFX")
	if sfx_idx >= 0:
		for i in range(AudioServer.get_bus_effect_count(sfx_idx) - 1, -1, -1):
			if AudioServer.get_bus_effect(sfx_idx, i) is AudioEffectLowPassFilter:
				AudioServer.remove_bus_effect(sfx_idx, i)
	_setup_environment()
	_spawn_player()
	_spawn_maze()
	_apply_initial_spawn()
	_spawn_entity()
	_spawn_overlay()
	_spawn_pause()
	_spawn_snus()
	_spawn_snus_ui()
	add_to_group("game_world")
	_spawn_lockers()
	_spawn_world_content()
	_spawn_extraction()
	_setup_interact_prompt()
	_setup_ambient()
	if is_instance_valid(_player):
		_last_safe_player_position = _player.global_position
		_safe_position_ready = true
	if ResourceLoader.exists("res://assets/audio/sfx/enemy/enemy_jumpscare_scream.mp3"):
		_callout_stream = load("res://assets/audio/sfx/enemy/enemy_jumpscare_scream.mp3")
	if _is_mp:
		_setup_multiplayer()
	if has_node("/root/GameManager"):
		GameManager.start_run()
	_last_pos = _player.global_position if is_instance_valid(_player) else Vector3.ZERO
	_setup_intro_screen()


func _exit_tree() -> void:
	if has_node("/root/VoiceChat"):
		VoiceChat.clear_remote_players()


var _intro_canvas: CanvasLayer = null

func _setup_intro_screen() -> void:
	if is_instance_valid(_player) and _player.has_method("set_frozen"):
		_player.set_frozen(true)
	elif is_instance_valid(_player):
		_player.frozen = true
		
	_intro_canvas = CanvasLayer.new()
	_intro_canvas.layer = 50
	add_child(_intro_canvas)
	
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_intro_canvas.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.88)
	root.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(650, 420)
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -325.0
	panel.offset_right = 325.0
	panel.offset_top = -210.0
	panel.offset_bottom = 210.0
	
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.07, 0.06, 0.95)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.65, 0.52, 0.28, 0.8)
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	
	var vbox := VBoxContainer.new()
	panel.add_child(vbox)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 30
	vbox.offset_right = -30
	vbox.offset_top = 30
	vbox.offset_bottom = -30
	vbox.add_theme_constant_override("separation", 14)
	
	var title := Label.new()
	title.text = "LEVEL 0 — THE BACKROOMS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.96, 0.85, 0.45, 1.0))
	title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title)
	
	var author := Label.new()
	author.text = "Made by João Afonso"
	author.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	author.add_theme_color_override("font_color", Color(0.75, 0.65, 0.45, 0.85))
	author.add_theme_font_size_override("font_size", 17)
	vbox.add_child(author)
	
	var desc := Label.new()
	var sprint_key := Settings.binding_text("sprint") if has_node("/root/Settings") else "Shift"
	var crouch_key := Settings.binding_text("crouch") if has_node("/root/Settings") else "Ctrl"
	var interact_key := Settings.binding_text("interact") if has_node("/root/Settings") else "E"
	var callout_key := Settings.binding_text("callout") if has_node("/root/Settings") else "Q"
	var sprint_hint := "%s - Sprint" % sprint_key \
		if not _is_mp or bool(NetManager.rule("sprint", true)) \
		else "Sprint disabled by lobby"
	var coop_hint := ""
	if _is_mp:
		coop_hint = "\n%s - Scream so nearby teammates can find you" % callout_key
		var voice_key := Settings.binding_text("voice_ptt") \
			if has_node("/root/Settings") else "V"
		coop_hint += "\n%s - Proximity voice (push-to-talk)" % voice_key
		if _separated_spawns_enabled():
			coop_hint += "\nYou entered apart. Listen before you call out."
	var emergency_text := "Emergency Buttons" if _is_mp else "Emergency Button"
	desc.text = "OBJECTIVE:\nFind 5 Snus, locate the %s, then find the door.\n\nCONTROLS:\nMovement keys - Move | %s | %s - Crouch\n%s - Interact%s" % [emergency_text, sprint_hint, crouch_key, interact_key, coop_hint]
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", Color(0.85, 0.82, 0.72, 0.9))
	desc.add_theme_font_size_override("font_size", 16)
	vbox.add_child(desc)
	
	var btn := Button.new()
	btn.text = "ENTER THE MAZE"
	btn.custom_minimum_size = Vector2(240, 50)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.focus_mode = Control.FOCUS_NONE
	vbox.add_child(btn)
	
	btn.pressed.connect(_on_intro_start_pressed)

func _unhandled_input(event: InputEvent) -> void:
	if is_instance_valid(_intro_canvas):
		if event.is_pressed() and not event.is_echo():
			_on_intro_start_pressed()
			get_viewport().set_input_as_handled()
			return

func _on_intro_start_pressed() -> void:
	if not is_instance_valid(_intro_canvas):
		return
	if is_instance_valid(_player) and _player.has_method("set_frozen"):
		_player.set_frozen(false)
	elif is_instance_valid(_player):
		_player.frozen = false
		
	var tw := create_tween()
	var root: Control = _intro_canvas.get_child(0) as Control
	if root:
		tw.tween_property(root, "modulate:a", 0.0, 0.4)
		await tw.finished
	if is_instance_valid(_intro_canvas):
		_intro_canvas.queue_free()
	_intro_canvas = null
	_set_current_mission("Find 5 Snus 0/5", true)

# ---------------------------------------------------------------------------
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.008, 0.008, 0.005)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.38, 0.36, 0.22)
	var darkness_mult := 1.0
	if _is_mp and has_node("/root/NetManager"):
		darkness_mult = maxf(1.0, float(NetManager.rule("darkness", 1.0)))
	env.ambient_light_energy = Tuning.AMBIENT_ENERGY / darkness_mult
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.92 / lerpf(1.0, darkness_mult, 0.35)
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_strength = 1.0
	env.glow_bloom = 0.25
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true
	env.fog_light_color = Color(0.22, 0.22, 0.14)
	env.fog_light_energy = 0.38
	env.fog_density = Tuning.FOG_DENSITY
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.12
	env.adjustment_saturation = 0.92
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

func _spawn_player() -> void:
	_player = CharacterBody3D.new()
	_player.set_script(load(PLAYER_SCRIPT))
	
	_player.position = Vector3(0, 0.1, 0)
	add_child(_player)
	if _is_mp and "sprint_enabled" in _player:
		_player.sprint_enabled = bool(NetManager.rule("sprint", true))
	_camera = _player.get_camera() if _player.has_method("get_camera") else null
	if _player.has_signal("looked_back"):
		_player.looked_back.connect(_on_looked_back)
	if _player.has_signal("noise_emitted"):
		_player.noise_emitted.connect(_on_player_noise)

func _spawn_maze() -> void:
	_maze = Node3D.new()
	_maze.set_script(load("res://scripts/world/maze_manager.gd"))
	# The layout is ALWAYS static — multiplayer compatibility demands that every
	# client (and every return trip) sees the exact same maze.
	if _maze.has_method("set_static_layout"):
		_maze.set_static_layout(true)
	if _maze.has_method("set_run_seed"):
		_maze.set_run_seed(_run_seed)
	add_child(_maze)
	_maze.setup(_player)
	if _maze.has_signal("exit_reached"):
		_maze.exit_reached.connect(_on_exit_reached)

func _spawn_snus() -> void:
	_snus = Node3D.new()
	_snus.set_script(load("res://scripts/world/snus_manager.gd"))
	if _snus.has_method("set_run_seed"):
		_snus.set_run_seed(_run_seed)
	add_child(_snus)
	_snus.setup(_player, _maze)
	if _snus.has_signal("count_changed"):
		_snus.count_changed.connect(_on_snus_count)
	if _snus.has_signal("all_collected"):
		_snus.all_collected.connect(_on_snus_all)

func _spawn_lockers() -> void:
	if _is_mp and not bool(NetManager.rule("lockers", true)):
		return
	_lockers = Node3D.new()
	_lockers.set_script(load("res://scripts/world/locker_manager.gd"))
	add_child(_lockers)
	_lockers.setup(_player, _maze)

func _spawn_world_content() -> void:
	_content = Node3D.new()
	_content.set_script(load("res://scripts/world/world_content_manager.gd"))
	if _content.has_method("set_run_seed"):
		_content.set_run_seed(_run_seed)
	add_child(_content)
	_content.setup(_player, _maze)
	_content.cassette_collected.connect(_on_cassette_collected)
	_content.anomaly_entered.connect(_on_anomaly_sector_entered)
	_content.anomaly_left.connect(_on_anomaly_sector_left)

func _spawn_extraction() -> void:
	_extraction = Node3D.new()
	_extraction.set_script(load("res://scripts/world/extraction_manager.gd"))
	add_child(_extraction)
	_extraction.setup(_player, _maze, _is_mp, NetManager.is_host if _is_mp else false, _run_seed)
	_extraction.terminal_activated.connect(_on_extraction_terminal_activated)
	_extraction.extraction_ready.connect(_on_extraction_ready)
	_extraction.window_reset.connect(_on_extraction_window_reset)

func living_remote_player_ids() -> Array:
	return _living_remote_ids()

## Living (not-downed) remote player bodies, keyed by player_id. Lets the shared
## roaming entity perceive and hunt every teammate, not just the local player.
func living_remote_player_bodies() -> Dictionary:
	var out := {}
	for pid in _remote_players.keys():
		if _remote_down.has(pid):
			continue
		var rp = _remote_players[pid]
		if is_instance_valid(rp):
			out[pid] = rp
	return out


## Resolve the remote body that owns a replicated chase. The Entity director
## uses it only to share the warning vignette with nearby teammates.
func remote_player_body(player_id: int) -> Node3D:
	var body = _remote_players.get(player_id)
	return body as Node3D if is_instance_valid(body) else null

func _spawn_entity() -> void:
	_entity = Node3D.new()
	_entity.set_script(load("res://scripts/world/entity_director.gd"))
	add_child(_entity)
	_entity.setup(_player, _camera, _maze)
	if _is_mp and _entity.has_method("set_rule_modifiers"):
		_entity.set_rule_modifiers(float(NetManager.rule("entity_speed", 1.0)))
	if _is_mp and _entity.has_method("setup_mp"):
		_entity.setup_mp(self, NetManager.is_host)
	_entity.request_dread.connect(_on_dread)
	_entity.request_flicker.connect(_on_flicker)
	_entity.jumpscare.connect(_on_jumpscare)
	_entity.muffle.connect(_on_muffle)
	_entity.caught.connect(_on_caught)
	_entity.victim_jumpscare.connect(_on_victim_jumpscare)
	_entity.chase_started.connect(_on_chase_started)
	_entity.chase_ended.connect(_on_chase_ended)

func _spawn_overlay() -> void:
	_overlay = load(OVERLAY_SCRIPT).new()
	add_child(_overlay)
	if _overlay.has_signal("chase_vignette_changed"):
		_overlay.chase_vignette_changed.connect(_on_red_effect_changed)
	if is_instance_valid(_player) and _player.has_signal("lens_focus_changed") \
			and _overlay.has_method("set_lens_focus_blur"):
		_player.lens_focus_changed.connect(_overlay.set_lens_focus_blur)

func _spawn_pause() -> void:
	_pause = load("res://scripts/ui/pause_menu.gd").new()
	add_child(_pause)
	if _pause.has_signal("local_pause_changed"):
		_pause.connect("local_pause_changed", _on_local_pause_changed)
	if _pause.has_method("set_mission"):
		_pause.set_mission("Find 5 Snus 0/5")

func _on_local_pause_changed(open: bool) -> void:
	if is_instance_valid(_player) and _player.has_method("set_menu_input_blocked"):
		_player.set_menu_input_blocked(open)
	# Co-op can't freeze the world, so a paused player would still be hunted —
	# and could be caught while reading the menu with a free cursor. Make them
	# untargetable while the local menu is open (reuses the down/dead pathway).
	# Guard: never resurrect targeting for a player who is actually down.
	if _entity and _entity.has_method("set_local_player_targetable"):
		if open:
			_entity.set_local_player_targetable(false)
		elif not _local_is_down:
			_entity.set_local_player_targetable(true)

func _set_current_mission(text: String, show_now: bool = false) -> void:
	if _pause and _pause.has_method("set_mission"):
		_pause.set_mission(text)
	if show_now and _snus_ui and _snus_ui.has_method("announce"):
		_snus_ui.announce(text, 5.5)

const HUM_VOL := -12.0
const HVAC_VOL := -20.0
const DRONE_VOL := -16.0
const VHS_BED_VOL := -32.0
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
	# Barely audible transport noise gives the camera a physical tape presence.
	_vhs_bed = _make_loop(VHS_BED_PATH, VHS_BED_VOL)

## Cut the ambient bed to near-silence, hold, then let it breathe back in.
func _duck_ambient(attack: float, hold: float, release: float) -> void:
	var layers: Array = []
	var vols: Array = []
	for pair in [
		[_hum, HUM_VOL], [_hvac, HVAC_VOL], [_drone, DRONE_VOL],
		[_vhs_bed, VHS_BED_VOL],
	]:
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
		var mp3 := p.stream as AudioStreamMP3
		if not mp3.loop:
			var dup := mp3.duplicate() as AudioStreamMP3
			dup.loop = true
			p.stream = dup
	p.play()
	p.finished.connect(func(): if is_instance_valid(p): p.play())
	return p

# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	if _ended:
		return
	_tick_out_of_bounds_safety(delta)
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
	_tick_victim_jumpscare(delta)
	_tick_downed_and_revive(delta)
	_extraction_interaction_active = bool(_extraction.tick_interaction(delta)) if _extraction and _extraction.has_method("tick_interaction") else false
	_content_interaction_active = bool(_content.tick_interaction(delta)) if not _extraction_interaction_active and _content and _content.has_method("tick_interaction") else false
	_phone_scare_cd = maxf(0.0, _phone_scare_cd - delta)
	_tick_phone_interaction()
	_update_interact_prompt(delta)
	_tick_distant_laughs(delta)
	_tick_callout(delta)
	_tick_dead_spectator(delta)

	if _radar_timer > 0.0:
		_radar_timer -= delta
		_radar_ping_cd -= delta
		if _radar_ping_cd <= 0.0:
			_play_radar_ping()

func _tick_out_of_bounds_safety(delta: float) -> void:
	_fall_recovery_cooldown = maxf(0.0, _fall_recovery_cooldown - delta)
	if not is_instance_valid(_player) or _local_is_down:
		return
	if _player.global_position.y < FALL_RECOVERY_Y:
		if _safe_position_ready and _fall_recovery_cooldown <= 0.0:
			_player.global_position = _last_safe_player_position + Vector3.UP * 0.18
			_player.velocity = Vector3.ZERO
			_fall_recovery_cooldown = 1.0
			if _overlay and _overlay.has_method("flash"):
				_overlay.flash(Color(0.0, 0.0, 0.0, 0.9), 0.18)
		return
	if _player.is_on_floor() and _player.global_position.y > -0.45:
		_last_safe_player_position = _player.global_position
		_safe_position_ready = true

func _tick_downed_and_revive(delta: float) -> void:
	# 1. Downed local player countdown & spectate live teammate
	if _is_downed:
		_incoming_revive_timeout = maxf(0.0, _incoming_revive_timeout - delta)
		if _incoming_revive_timeout > 0.0:
			# Revive in progress: pause the rules-driven bleedout timer.
			_set_revive_progress(_incoming_revive_progress, true)
		else:
			_incoming_revive_progress = 0.0
			_set_revive_progress(0.0, false)
			_bleedout_timer -= delta

		# (Automatic screams removed: player now presses Q to scream on demand!)

		# Injured blood trail while crawling (every 3 seconds of movement)
		if is_instance_valid(_player):
			var crawl_spd := Vector2(_player.velocity.x, _player.velocity.z).length()
			if crawl_spd > 0.08:
				_crawl_blood_trail_timer += delta
				if _crawl_blood_trail_timer >= 3.0:
					_crawl_blood_trail_timer = 0.0
					_spawn_blood_decal(_player.global_position, "res://assets/textures/decals/blood_trail.png", Vector3(1.4, 2.0, 1.4))
					if _is_mp:
						NetManager.send("blood_decal", {"type": "trail", "x": _player.global_position.x, "y": _player.global_position.y, "z": _player.global_position.z})

		if is_instance_valid(_downed_status):
			if _incoming_revive_timeout > 0.0:
				_downed_status.text = "TEAMMATE IS REVIVING YOU... (%.1fs / 10.0s)" % _incoming_revive_progress
				_downed_status.add_theme_color_override("font_color", Color(0.2, 0.9, 0.3, 1.0))
			else:
				_downed_status.text = "DOWNED — %.1fs LEFT TO BLEED OUT" % maxf(0.0, _bleedout_timer)
				_downed_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))
		if is_instance_valid(_downed_bar):
			_downed_bar.value = maxf(0.0, _bleedout_timer)
			
		if _bleedout_timer <= 0.0:
			# Bleedout expired -> permanently dead and no longer revivable.
			_is_downed = false
			_local_is_down = true
			if is_instance_valid(_player):
				_player.is_downed = false
				if _player.has_method("set_frozen"):
					_player.set_frozen(true)
			NetManager.send("down", {})
			if is_instance_valid(_downed_canvas):
				_downed_canvas.queue_free()
				_downed_canvas = null
			_incoming_revive_progress = 0.0
			_incoming_revive_timeout = 0.0
			_enter_dead_spectator()
			_check_all_down()
			return

	# 2. Living player reviving downed teammate (Hold E for 10 seconds)
	if not _local_is_down and not _is_downed and _is_mp:
		var downed_rp = _get_nearest_downed_remote_player()
		if is_instance_valid(downed_rp):
			var dist := _player.global_position.distance_to(downed_rp.global_position)
			if dist < 2.5:
				var holding_e := Input.is_action_pressed("interact")
				if holding_e:
					_player.is_reviving = true
					_revive_hold_timer += delta
					_set_revive_progress(_revive_hold_timer, true)
					NetManager.send("reviving", {"target": downed_rp.player_id, "prog": _revive_hold_timer})
					if _interact_prompt:
						_interact_prompt.text = "HOLD TO REVIVE TEAMMATE (%.1fs / 10.0s)" % _revive_hold_timer
						_interact_prompt.visible = true
					if _revive_hold_timer >= 10.0:
						# REVIVED!
						_player.is_reviving = false
						_revive_hold_timer = 0.0
						_set_revive_progress(0.0, false)
						NetManager.send("revived", {"target": downed_rp.player_id})
						if downed_rp.has_method("set_downed"):
							downed_rp.set_downed(false)
						_remote_down.erase(downed_rp.player_id)
						_play_revive_spectacle(downed_rp.global_position)
				else:
					_player.is_reviving = false
					_revive_hold_timer = maxf(0.0, _revive_hold_timer - delta * 2.0)
					_set_revive_progress(_revive_hold_timer, _revive_hold_timer > 0.0)
					if _interact_prompt:
						_interact_prompt.text = "HOLD TO REVIVE TEAMMATE"
						_interact_prompt.visible = true
			else:
				_player.is_reviving = false
				_revive_hold_timer = 0.0
				_set_revive_progress(0.0, false)
		else:
			_player.is_reviving = false
			_revive_hold_timer = 0.0
			_set_revive_progress(0.0, false)
	else:
		if is_instance_valid(_player):
			_player.is_reviving = false
		_set_revive_progress(0.0, false)

func _get_living_remote_player() -> Node3D:
	for pid in _remote_players.keys():
		if not _remote_down.has(pid):
			var rp = _remote_players[pid]
			if is_instance_valid(rp):
				return rp
	return null

func _restore_local_player_camera() -> void:
	if is_instance_valid(_downed_body_visual):
		_downed_body_visual.queue_free()
	_downed_body_visual = null
	if is_instance_valid(_player):
		if _player.has_method("set_first_person_body_visible"):
			_player.set_first_person_body_visible(false)
		if _player.has_method("restore_first_person_camera"):
			_player.restore_first_person_camera()

func _get_nearest_downed_remote_player() -> Node3D:
	var best: Node3D = null
	var best_d := 999.0
	for pid in _remote_players.keys():
		var rp = _remote_players[pid]
		if is_instance_valid(rp) and "is_downed" in rp and rp.is_downed:
			var d = _player.global_position.distance_to(rp.global_position)
			if d < best_d:
				best_d = d
				best = rp
	return best

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

func _on_player_noise(world_position: Vector3, audible_range: float, kind: String) -> void:
	# The third signal is the point where the entity learns to distinguish a
	# sprint from the building's constant noise. Footsteps matter from the first
	# Entity spawn; progression never grants artificial deafness.
	if _is_mp and not NetManager.is_host:
		# The host owns a roaming Entity; forward the same footstep event instead
		# of applying it to a non-authoritative local mirror.
		NetManager.send("player_noise", {
			"x": world_position.x, "y": world_position.y, "z": world_position.z,
			"kind": kind,
		})
		return
	if _entity and _entity.has_method("investigate_noise"):
		_entity.investigate_noise(world_position, audible_range, kind)

func _tick_callout(delta: float) -> void:
	_callout_cooldown = maxf(0.0, _callout_cooldown - delta)
	if _ended or not is_instance_valid(_player):
		return
	if Input.is_action_just_pressed("callout") and _callout_cooldown <= 0.0:
		_callout_cooldown = 1.5 if _is_downed else Tuning.COOP_CALLOUT_COOLDOWN
		var pos := _player.global_position + Vector3.UP
		_play_callout(pos, NetManager.local_player_id if _is_mp else 0, _is_downed)
		if _is_mp:
			NetManager.send("callout", {"x": pos.x, "y": pos.y, "z": pos.z, "downed": _is_downed})
		if not _is_downed and (not _is_mp or NetManager.is_host) \
				and _entity and _entity.has_method("investigate_noise"):
			_entity.investigate_noise(pos, Tuning.COOP_CALLOUT_ENTITY_RANGE, "callout")

func _play_callout(world_position: Vector3, player_id: int, downed: bool = false) -> void:
	if _callout_stream == null or not has_node("/root/AudioManager"):
		return
	var is_local_scream := has_node("/root/NetManager") and player_id == NetManager.local_player_id
	var hearing_range := Tuning.COOP_DOWNED_CALLOUT_HEARING_RANGE if downed else Tuning.COOP_CALLOUT_HEARING_RANGE
	# The caller always hears their own voice. Remote screams are discarded
	# outside the same range used by the entity's hearing logic.
	if not is_local_scream and is_instance_valid(_player):
		if _player.global_position.distance_to(world_position) > hearing_range:
			return
	var voice_pitch := 0.96 + float(posmod(player_id, 4)) * 0.025
	AudioManager.play_sfx_3d(
		self, _callout_stream, world_position, Tuning.COOP_CALLOUT_VOLUME_DB,
		hearing_range, voice_pitch)

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

func _on_chase_started() -> void:
	if is_instance_valid(_player) and _player.has_method("set_being_chased"):
		_player.set_being_chased(true)


func _on_chase_ended() -> void:
	if is_instance_valid(_player) and _player.has_method("set_being_chased"):
		_player.set_being_chased(false)
	# it vanished — hard cut, a beat of dead air, then the hum seeps back
	_duck_ambient(0.05, 1.2, 2.5)

func _on_red_effect_changed(active: bool) -> void:
	if is_instance_valid(_player) and _player.has_method("set_red_effect_active"):
		_player.set_red_effect_active(active)


func _on_muffle(active: bool) -> void:
	_muffled = active
	# the fluorescent hum drops in pitch when something unseen is close
	if _hum:
		_hum.pitch_scale = HUM_PITCH_MUFFLED if active else HUM_PITCH
	var idx := AudioServer.get_bus_index("SFX")
	if idx < 0:
		return
	# add/remove a low-pass to muffle the world when a vulto is near-but-unseen
	var low_pass_index := -1
	for i in AudioServer.get_bus_effect_count(idx):
		if AudioServer.get_bus_effect(idx, i) is AudioEffectLowPassFilter:
			low_pass_index = i
			break
	if active and low_pass_index < 0:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 600.0
		AudioServer.add_bus_effect(idx, lp)
	elif not active and low_pass_index >= 0:
		AudioServer.remove_bus_effect(idx, low_pass_index)

func _on_caught() -> void:
	if is_instance_valid(_player) and _player.has_method("set_being_chased"):
		_player.set_being_chased(false)
	if _is_mp:
		# In co-op, being caught takes only you out — tell the others and
		# spectate rather than restarting everyone's run.
		_local_down()
		# CX30 — downed was entered underneath the jumpscare's black screen.
		# Only now is the world faded back in.
		_finish_victim_jumpscare()
		return
	_end_run("caught")

# ---------------------------------------------------------------------------
# CX30 — victim-only jumpscare video
# ---------------------------------------------------------------------------

## Built only on the client the Entity caught, and never replicated. The id
## carried by the signal must be this peer's, so a teammate can never end up
## with the layer: they keep watching the full 3D execution in-world.
func _on_victim_jumpscare(victim_id: int) -> void:
	if _ended or is_instance_valid(_jumpscare_video):
		return   # repeated catch events must not restart or stack the clip
	var local_id := NetManager.local_player_id if has_node("/root/NetManager") else 0
	if victim_id != local_id:
		return
	_jumpscare_video = load(JUMPSCARE_VIDEO_SCRIPT).new()
	_jumpscare_video.name = "VictimJumpscare"
	add_child(_jumpscare_video)
	_jumpscare_hold_timer = JUMPSCARE_MAX_HOLD
	# A missing or unreadable clip degrades to the same black screen with the
	# same timing, so the run never stalls on it.
	if bool(_jumpscare_video.start()) and _entity \
			and _entity.has_method("notify_victim_jumpscare_started"):
		_entity.notify_victim_jumpscare_started()

func _tick_victim_jumpscare(delta: float) -> void:
	if not is_instance_valid(_jumpscare_video):
		return
	_jumpscare_hold_timer -= delta
	if _jumpscare_hold_timer > 0.0:
		return
	push_warning("game_world: victim jumpscare timed out — releasing the screen")
	_release_victim_jumpscare(JUMPSCARE_DOWNED_FADE)

func _release_victim_jumpscare(fade_seconds: float) -> void:
	if is_instance_valid(_jumpscare_video):
		if _jumpscare_video.has_method("release"):
			_jumpscare_video.release(fade_seconds)
		else:
			_jumpscare_video.queue_free()
	_jumpscare_video = null

## Hand the screen back once the 3D sequence is over. The victim is already in
## `downed` (or spectating) underneath the black, so the fade can never reveal
## the Entity, a third-person frame, or a camera jump.
func _finish_victim_jumpscare() -> void:
	if not is_instance_valid(_jumpscare_video):
		return
	if not _is_downed:
		# One-life co-op: the spectator camera owns the view from here.
		_release_victim_jumpscare(JUMPSCARE_DOWNED_FADE)
		return
	if is_instance_valid(_player):
		if _player.has_method("stabilize_downed_camera"):
			_player.stabilize_downed_camera()
		# Movement stays locked across the fade; crawling is unlocked at the end.
		if _player.has_method("set_frozen"):
			_player.set_frozen(true, false)
	# Let the crawl pose and the planted camera settle before anything shows.
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_release_victim_jumpscare(JUMPSCARE_DOWNED_FADE)
	await get_tree().create_timer(JUMPSCARE_DOWNED_FADE).timeout
	if not is_inside_tree():
		return
	# Bleedout may have expired or a revive landed during the fade; only a still
	# downed player gets its controls back here.
	if _is_downed and is_instance_valid(_player) and _player.has_method("set_frozen"):
		_player.set_frozen(false)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_exit_reached() -> void:
	# The physical door is inert until the final override sequence is complete.
	if not _snus_done or not _exit_enabled:
		return
	_local_exit_transition = true
	if _is_mp and has_node("/root/NetManager"):
		NetManager.send("escaped", {})
	_end_run("exit")

# ---------------------------------------------------------------------------
func _on_snus_count(collected: int, total: int) -> void:
	_set_current_mission("Find 5 Snus %d/%d" % [collected, total])
	if _snus_ui and _snus_ui.has_method("set_count"):
		_snus_ui.set_count(collected, total)
	# every tin taken makes it angrier and faster — shared pickups, escalating danger!
	var menace := float(collected) / float(maxi(total, 1))
	if _entity and _entity.has_method("set_menace"):
		_entity.set_menace(menace)
	if collected <= 0:
		return
	if _entity and _entity.has_method("calm_down"):
		_entity.calm_down(0.18)
	if _entity and _entity.has_method("hold_new_events"):
		_entity.hold_new_events(Tuning.OBJECTIVE_EVENT_HOLD)

	# A restrained physical reaction gives the pickup weight without repeating
	# the same full-volume scream five times.
	if _maze and _maze.has_method("set_flicker"):
		_maze.set_flicker(0.22 + 0.05 * collected)
		get_tree().create_timer(0.65).timeout.connect(func():
			if is_instance_valid(_maze) and _maze.has_method("set_flicker"):
				_maze.set_flicker(0.0)
		)

func _on_snus_all() -> void:
	if _snus_done:
		return
	_snus_done = true
	_activate_extraction_objective(true)
	# Do not rely only on all five pickup packets arriving in order. The host
	# explicitly announces the next phase so every client activates its own
	# correctly positioned button models.
	if _is_mp and NetManager.is_host:
		NetManager.send("extract_activate", {})

func _activate_extraction_objective(show_now: bool) -> void:
	_snus_done = true
	if _extraction and _extraction.has_method("activate"):
		_extraction.activate()
	_update_emergency_mission(show_now)

func _update_emergency_mission(show_now: bool = false) -> void:
	if _extraction and _extraction.has_method("is_ready") and _extraction.is_ready():
		return
	var armed := int(_extraction.get_armed_count()) if _extraction and _extraction.has_method("get_armed_count") else 0
	var total := int(_extraction.get_total_buttons()) if _extraction and _extraction.has_method("get_total_buttons") else (2 if _is_mp else 1)
	var noun := "Emergency Buttons" if _is_mp else "Emergency Button"
	var mission := "Locate the %s %d/%d" % [noun, armed, total]
	if _is_mp and armed > 0 and _extraction.has_method("get_window_left"):
		mission += " — %.0fs" % float(_extraction.get_window_left())
	_set_current_mission(mission, show_now)

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
	var total_players := NetManager.connected_players if has_node("/root/NetManager") and NetManager.connected_players > 0 else NetManager.max_players
	for pid in range(total_players):
		if pid == NetManager.local_player_id:
			continue
		var rp := CharacterBody3D.new()
		rp.set_script(rp_script)
		rp.player_id = pid
		add_child(rp)
		rp.global_position = _run_spawn_position(pid)
		_remote_players[pid] = rp
		if has_node("/root/VoiceChat"):
			VoiceChat.register_remote_player(pid, rp)
		if _snus and _snus.has_method("register_player_body"):
			_snus.register_player_body(rp)

func _apply_initial_spawn() -> void:
	_prepare_run_spawn_cells()
	if not is_instance_valid(_player):
		return
	var pid := NetManager.local_player_id if _is_mp and has_node("/root/NetManager") else 0
	_player.global_position = _run_spawn_position(pid)


func _separated_spawns_enabled() -> bool:
	return _is_mp and not TEST_FORCE_GROUPED_SPAWNS \
		and bool(NetManager.rule("separated_spawns", true))

func _prepare_run_spawn_cells() -> void:
	if not _run_spawn_cells.is_empty() or not is_instance_valid(_maze):
		return
	var separated := _separated_spawns_enabled()
	var count := NetManager.max_players if separated else 1
	var rng := RandomNumberGenerator.new()
	rng.seed = _run_seed ^ 0x53504157
	var spawn_band_size := Tuning.COOP_SPAWN_MAX_CELLS - Tuning.COOP_SPAWN_MIN_CELLS + 1
	var sectors: Array[Rect2i] = [
		Rect2i(-Tuning.COOP_SPAWN_MAX_CELLS, -Tuning.COOP_SPAWN_MAX_CELLS, spawn_band_size, spawn_band_size),
		Rect2i(Tuning.COOP_SPAWN_MIN_CELLS, -Tuning.COOP_SPAWN_MAX_CELLS, spawn_band_size, spawn_band_size),
		Rect2i(-Tuning.COOP_SPAWN_MAX_CELLS, Tuning.COOP_SPAWN_MIN_CELLS, spawn_band_size, spawn_band_size),
		Rect2i(Tuning.COOP_SPAWN_MIN_CELLS, Tuning.COOP_SPAWN_MIN_CELLS, spawn_band_size, spawn_band_size),
	]
	for index in count:
		var selected := Vector2i.ZERO
		for _attempt in 300:
			var candidate: Vector2i
			if separated:
				var sector: Rect2i = sectors[index % sectors.size()]
				candidate = Vector2i(
					rng.randi_range(sector.position.x, sector.end.x - 1),
					rng.randi_range(sector.position.y, sector.end.y - 1))
			else:
				candidate = Vector2i(
					rng.randi_range(-Tuning.SOLO_SPAWN_MAX_CELLS, Tuning.SOLO_SPAWN_MAX_CELLS),
					rng.randi_range(-Tuning.SOLO_SPAWN_MAX_CELLS, Tuning.SOLO_SPAWN_MAX_CELLS))
				if maxi(abs(candidate.x), abs(candidate.y)) < Tuning.SOLO_SPAWN_MIN_CELLS:
					continue
			if not _maze.is_cell_open(candidate) or _maze.corridor_path(candidate, Vector2i.ZERO, 1400).is_empty():
				continue
			var far_enough := true
			for existing in _run_spawn_cells:
				if existing.distance_to(candidate) < Tuning.COOP_SPAWN_MIN_SEPARATION:
					far_enough = false
					break
			if not far_enough:
				continue
			selected = candidate
			break
		_run_spawn_cells.append(selected)

func _run_spawn_position(player_id: int) -> Vector3:
	if _run_spawn_cells.is_empty():
		return Vector3(float(player_id) * 1.4, 0.1, 0.0)
	# Separated spawns: each player starts in a different maze cell, so they must
	# use the scream (Q) to locate each other. Grouped fallback below if disabled.
	var separated := _separated_spawns_enabled()
	if separated:
		var cell: Vector2i = _run_spawn_cells[posmod(player_id, _run_spawn_cells.size())]
		return _maze.world_center(cell) + Vector3.UP * 0.1
	var grouped_offsets: Array[Vector3] = [
		Vector3.ZERO, Vector3(1.2, 0, 0), Vector3(-1.2, 0, 0), Vector3(0, 0, 1.2),
	]
	return _maze.world_center(_run_spawn_cells[0]) + grouped_offsets[posmod(player_id, grouped_offsets.size())] + Vector3.UP * 0.1

func _start_position_broadcast() -> void:
	var timer := Timer.new()
	timer.wait_time = 0.05
	timer.autostart = true
	timer.timeout.connect(_broadcast_position)
	add_child(timer)

func _broadcast_position() -> void:
	if _ended or not is_instance_valid(_player):
		return
	var animation_move := Vector2.ZERO
	if _player.has_method("get_animation_move_direction"):
		animation_move = _player.get_animation_move_direction()
	NetManager.send("pos", {
		"x": _player.global_position.x,
		"y": _player.global_position.y,
		"z": _player.global_position.z,
		"ry": _player.rotation.y,
		"pitch": _camera.rotation.x if is_instance_valid(_camera) else 0.0,
		"spr": bool(_player.is_sprinting) if "is_sprinting" in _player else false,
		"cr": bool(_player.is_crouching) if "is_crouching" in _player else false,
		"sl": bool(_player.get("_is_slipping")),
		"mx": animation_move.x,
		"mz": animation_move.y,
	})

var _is_downed := false
var _bleedout_timer := 0.0
var _revive_hold_timer := 0.0
var _spectate_index := 0
var _downed_canvas: CanvasLayer = null
var _downed_status: Label = null
var _downed_bar: ProgressBar = null
var _revive_canvas: CanvasLayer = null
var _revive_bar: ProgressBar = null
var _incoming_revive_progress := 0.0
var _incoming_revive_timeout := 0.0
var _dead_spectator := false
var _spectate_target_id := -1
var _spectator_canvas: CanvasLayer = null
var _spectator_label: Label = null
var _restart_votes: Dictionary = {}
var _try_again_button: Button = null

func _on_net_message(type: String, msg: Dictionary, from_player: int) -> void:
	if not is_inside_tree():
		return
	var sender_id := _resolve_sender_id(msg, from_player)
	match type:
		"pos":
			var rp = _remote_players.get(sender_id)
			if rp and is_instance_valid(rp) and rp.has_method("update_target"):
				rp.update_target(msg)
		"execution":
			var execution_player = _remote_players.get(sender_id)
			if execution_player and is_instance_valid(execution_player) \
					and execution_player.has_method("play_execution_clip"):
				execution_player.play_execution_clip(
					str(msg.get("clip", "")),
					-1.0,
					float(msg.get("speed", 1.0)))
		"entity_execution":
			if _entity and _entity.has_method("play_network_execution_clip"):
				_entity.play_network_execution_clip(
					str(msg.get("clip", "")),
					float(msg.get("speed", 1.0)))
		"entity_eat_align":
			if _entity and _entity.has_method("apply_network_eat_alignment"):
				_entity.apply_network_eat_alignment(msg)
		"snus_request":
			if NetManager.is_host and _snus and _snus.has_method("host_collect_id"):
				var collector = _remote_players.get(sender_id)
				if is_instance_valid(collector) and not _remote_down.has(sender_id):
					_snus.host_collect_id(int(msg.get("id", -1)), collector.global_position)
		"snus":
			if _snus and _snus.has_method("remote_collect"):
				_snus.remote_collect(int(msg.get("id", -1)))
		"game_over":
			if not _ended:
				_end_run(str(msg.get("reason", "caught")))
		"phone_request":
			if NetManager.is_host:
				var phone_collector = _remote_players.get(sender_id)
				var requested_cell := Vector2i(int(msg.get("cx", 0)), int(msg.get("cz", 0)))
				var requested_phone = _maze.get_phone_node_in_cell(requested_cell) if _maze else null
				if is_instance_valid(phone_collector) and not _remote_down.has(sender_id) \
						and is_instance_valid(requested_phone) \
						and phone_collector.global_position.distance_to(requested_phone.global_position) < 3.0:
					_activate_phone(requested_phone, sender_id, true)
		"phone_used":
			var phone_author := int(msg.get("from", from_player))
			if phone_author == 0:
				var used_cell := Vector2i(int(msg.get("cx", 0)), int(msg.get("cz", 0)))
				var used_phone = _maze.get_phone_node_in_cell(used_cell) if _maze else null
				if is_instance_valid(used_phone):
					_activate_phone(used_phone, int(msg.get("target", -1)), false)
		"cassette":
			if _content and _content.has_method("remote_collect_cassette"):
				_receiving_shared_content = true
				_content.remote_collect_cassette()
				_receiving_shared_content = false
		"vhs_tv":
			var is_play := bool(msg.get("play", false))
			var vhs_tv = find_child("VHSTV", true, false)
			if is_instance_valid(vhs_tv) and vhs_tv.has_method("set_playing"):
				vhs_tv.set_playing(is_play)
		"extract_terminal":
			if _extraction and _extraction.has_method("remote_activate"):
				var terminal_id := int(msg.get("id", -1))
				_extraction.remote_activate(terminal_id)
				if NetManager.is_host and sender_id != NetManager.local_player_id:
					_alert_entity_to_emergency_button(terminal_id)
				_update_emergency_mission(true)
		"extract_activate":
			if int(msg.get("from", from_player)) == 0:
				_activate_extraction_objective(true)
		"extract_reset":
			if _extraction and _extraction.has_method("remote_reset"):
				_extraction.remote_reset()
				_update_emergency_mission(false)
		"downed":
			var rp_d = _remote_players.get(sender_id)
			if rp_d and is_instance_valid(rp_d) and rp_d.has_method("set_downed"):
				rp_d.set_downed(true)
				_spawn_blood_decal(rp_d.global_position, "res://assets/textures/decals/blood_wall_end.png", Vector3(1.8, 2.0, 1.8))
				if NetManager.is_host and _entity and _entity.has_method("schedule_revive_pressure"):
					_entity.schedule_revive_pressure(rp_d.global_position)
			if sender_id >= 0:
				_remote_down[sender_id] = true
				if _dead_spectator and sender_id == _spectate_target_id:
					_cycle_spectator(1)
		"blood_decal":
			var pos_v := Vector3(float(msg.get("x", 0.0)), float(msg.get("y", 0.0)), float(msg.get("z", 0.0)))
			var type_str := str(msg.get("type", "trail"))
			var tex_path := "res://assets/textures/decals/blood_trail.png" if type_str == "trail" else "res://assets/textures/decals/blood_wall_end.png"
			var sz := Vector3(1.4, 2.0, 1.4) if type_str == "trail" else Vector3(1.8, 2.0, 1.8)
			_spawn_blood_decal(pos_v, tex_path, sz)
		"reviving":
			if int(msg.get("target", -1)) == NetManager.local_player_id and _is_downed:
				_incoming_revive_progress = clampf(float(msg.get("prog", 0.0)), 0.0, 10.0)
				_incoming_revive_timeout = 0.35
		"callout":
			if int(msg.get("from", from_player)) == NetManager.local_player_id:
				return
			var callout_position := Vector3(
				float(msg.get("x", 0.0)),
				float(msg.get("y", 0.0)),
				float(msg.get("z", 0.0)))
			var caller_is_downed := bool(msg.get("downed", false))
			_play_callout(callout_position, sender_id, caller_is_downed)
			if NetManager.is_host and not caller_is_downed \
					and _entity and _entity.has_method("investigate_noise"):
				_entity.investigate_noise(callout_position, Tuning.COOP_CALLOUT_ENTITY_RANGE, "callout")
		"player_noise":
			if NetManager.is_host and sender_id >= 0 and not _remote_down.has(sender_id) \
					and _entity and _entity.has_method("investigate_noise"):
				var noise_kind := str(msg.get("kind", "walk"))
				var allowed_ranges := {
					"walk": Tuning.NOISE_RANGE_WALK,
					"crouch": Tuning.NOISE_RANGE_CROUCH,
					"sprint": Tuning.NOISE_RANGE_SPRINT,
				}
				if allowed_ranges.has(noise_kind):
					var noise_position := Vector3(
						float(msg.get("x", 0.0)),
						float(msg.get("y", 0.0)),
						float(msg.get("z", 0.0)))
					_entity.investigate_noise(
						noise_position, float(allowed_ranges[noise_kind]), noise_kind)
		"vote_restart":
			var voter := _resolve_sender_id(msg, from_player)
			_restart_votes[voter] = true
			_update_restart_vote_ui()
			if _is_mp and NetManager.is_host:
				_check_all_voted_restart()
		"start_restart":
			if has_node("/root/GameManager"):
				GameManager.restart()
		"revived":
			var target_id := int(msg.get("target", -1))
			if target_id == NetManager.local_player_id:
				_on_local_revived()
			else:
				var rp_r = _remote_players.get(target_id)
				if rp_r and is_instance_valid(rp_r) and rp_r.has_method("set_downed"):
					rp_r.set_downed(false)
					_play_revive_spectacle(rp_r.global_position)
				_remote_down.erase(target_id)
		"down":
			var rp2 = _remote_players.get(sender_id)
			if rp2 and is_instance_valid(rp2) and rp2.has_method("set_dead"):
				rp2.set_dead(true)
			if sender_id >= 0:
				_remote_down[sender_id] = true
				if _dead_spectator and sender_id == _spectate_target_id:
					_cycle_spectator(1)
			_check_all_down()
		"escaped":
			if not _ended:
				_end_run("exit")
		"secret":
			if not _ended:
				_end_run("secret")
		"scare":
			if int(msg.get("target", -1)) == NetManager.local_player_id \
					and _entity and _entity.has_method("remote_scare"):
				_entity.remote_scare(str(msg.get("kind", "peek")), msg)
		"scare_all":
			if _entity and _entity.has_method("remote_scare"):
				_entity.remote_scare(str(msg.get("kind", "jump")), msg)
		"fig":
			# Some relay configurations echo broadcasts to their sender. Never create
			# a mirror of our own authoritative figure.
			if int(msg.get("from", -1)) != NetManager.local_player_id \
					and _entity and _entity.has_method("mirror_update"):
				_entity.mirror_update(msg)
		"figoff":
			if int(msg.get("from", -1)) != NetManager.local_player_id \
					and _entity and _entity.has_method("mirror_off"):
				_entity.mirror_off()
		"stalk_gaze":
			if NetManager.is_host and _entity and _entity.has_method("set_remote_stalk_gaze"):
				_entity.set_remote_stalk_gaze(sender_id, bool(msg.get("seen", false)))
		"stalk_caught":
			if sender_id == 0 and int(msg.get("target", -1)) == NetManager.local_player_id \
					and _entity and _entity.has_method("remote_stalk_caught"):
				_entity.remote_stalk_caught()
func _resolve_sender_id(msg: Dictionary, from_player: int) -> int:
	if _remote_players.has(from_player):
		return from_player
	var embedded_id := int(msg.get("from", -1))
	if _remote_players.has(embedded_id):
		return embedded_id
	return -1

func _on_player_disconnected(pid: int) -> void:
	if has_node("/root/VoiceChat"):
		VoiceChat.unregister_remote_player(pid)
	var rp = _remote_players.get(pid)
	if is_instance_valid(rp):
		rp.queue_free()
	_remote_players.erase(pid)
	if pid >= 0:
		_remote_down[pid] = true
		if _dead_spectator and pid == _spectate_target_id:
			_cycle_spectator(1)
		_check_all_down()

func _local_down() -> void:
	if _is_mp:
		_local_is_down = true
		if bool(NetManager.rule("one_life", false)):
			# Permadeath: the entity goes dormant for this (now dead) client.
			if _entity and _entity.has_method("set_local_player_targetable"):
				_entity.set_local_player_targetable(false)
			NetManager.send("down", {})
			if is_instance_valid(_player) and _player.has_method("set_frozen"):
				_player.set_frozen(true)
			_enter_dead_spectator()
			_check_all_down()
			return
		# Co-op: enter the rules-driven Downed Bleedout state (90 s on Normal)
		# where the player can crawl and scream.
		# The entity ignores us (no catch) but keeps roaming — it flees, doesn't despawn.
		if _entity and _entity.has_method("set_local_player_targetable"):
			_entity.set_local_player_targetable(false, true)
		_is_downed = true
		_bleedout_timer = float(NetManager.rule("revive_seconds", 90.0))
		_crawl_blood_trail_timer = 0.0
		NetManager.send("downed", {})
		if is_instance_valid(_player):
			if _player.has_method("set_downed_state"):
				_player.set_downed_state(true)
			else:
				_player.is_downed = true
			if _player.has_method("set_frozen"):
				_player.set_frozen(false)
		_spawn_blood_decal(_player.global_position, "res://assets/textures/decals/blood_wall_end.png", Vector3(1.8, 2.0, 1.8))
		NetManager.send("blood_decal", {"type": "wall_end", "x": _player.global_position.x, "y": _player.global_position.y, "z": _player.global_position.z})
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_setup_downed_hud()
		_check_all_down()

var _active_blood_decals: Array[Decal] = []

func _spawn_blood_decal(pos: Vector3, texture_path: String, size: Vector3 = Vector3(1.6, 2.0, 1.6)) -> void:
	if not ResourceLoader.exists(texture_path):
		return
	var tex = load(texture_path) as Texture2D
	if not tex:
		return
	var decal := Decal.new()
	decal.texture_albedo = tex
	decal.size = Vector3(size.x, 2.0, size.z)
	decal.global_position = pos + Vector3(0, 0.05, 0)
	decal.rotation.y = randf() * TAU
	decal.cull_mask = 1
	add_child(decal)
	_active_blood_decals.append(decal)
	if _active_blood_decals.size() > 12:
		var oldest: Decal = _active_blood_decals.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()

# CX34 — `_play_downed_scream()` removed. It was never called (the Q scream runs
# through `_tick_callout`, and `callout` is mapped to Q), and its `else` branch —
# reached only if the scream asset were missing — contained the singleplayer
# death sequence. Renaming that mp3 would have made screaming end the run.

func _setup_downed_hud() -> void:
	if is_instance_valid(_downed_canvas):
		return
	_downed_canvas = CanvasLayer.new()
	_downed_canvas.layer = 30
	add_child(_downed_canvas)
	
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_downed_canvas.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	var vbox := VBoxContainer.new()
	root.add_child(vbox)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	vbox.offset_bottom = -80
	vbox.add_theme_constant_override("separation", 8)
	
	_downed_status = Label.new()
	_downed_status.text = "DOWNED — %.1fs LEFT TO REVIVE" % _bleedout_timer
	_downed_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_downed_status.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))
	_downed_status.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_downed_status)
	
	_downed_bar = ProgressBar.new()
	_downed_bar.min_value = 0.0
	_downed_bar.max_value = _bleedout_timer
	_downed_bar.value = _bleedout_timer
	_downed_bar.show_percentage = false
	_downed_bar.custom_minimum_size = Vector2(360, 16)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.9, 0.2, 0.2, 1.0)
	fill.set_corner_radius_all(4)
	_downed_bar.add_theme_stylebox_override("fill", fill)
	vbox.add_child(_downed_bar)

func _setup_revive_progress() -> void:
	if is_instance_valid(_revive_canvas):
		return
	_revive_canvas = CanvasLayer.new()
	_revive_canvas.layer = 31
	add_child(_revive_canvas)

	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_revive_canvas.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_revive_bar = ProgressBar.new()
	_revive_bar.min_value = 0.0
	_revive_bar.max_value = 10.0
	_revive_bar.value = 0.0
	_revive_bar.show_percentage = true
	_revive_bar.custom_minimum_size = Vector2(360, 24)
	root.add_child(_revive_bar)
	_revive_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_revive_bar.offset_left = -180.0
	_revive_bar.offset_right = 180.0
	_revive_bar.offset_top = -135.0
	_revive_bar.offset_bottom = -111.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.03, 0.08, 0.04, 0.9)
	bg.set_corner_radius_all(5)
	_revive_bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.2, 0.9, 0.3, 1.0)
	fill.set_corner_radius_all(5)
	_revive_bar.add_theme_stylebox_override("fill", fill)

func _set_revive_progress(value: float, visible: bool) -> void:
	if visible:
		_setup_revive_progress()
	if is_instance_valid(_revive_bar):
		_revive_bar.value = clampf(value, 0.0, 10.0)
		_revive_bar.visible = visible

func _enter_dead_spectator() -> void:
	_dead_spectator = true
	if _overlay and _overlay.has_method("clear_jumpscare"):
		_overlay.clear_jumpscare()
	_setup_spectator_hud()
	_cycle_spectator(1)
	# CX30 — one-life, or a bleedout that expired while the clip was still up.
	_release_victim_jumpscare(JUMPSCARE_DOWNED_FADE)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _setup_spectator_hud() -> void:
	if is_instance_valid(_spectator_canvas):
		return
	_spectator_canvas = CanvasLayer.new()
	_spectator_canvas.layer = 40
	add_child(_spectator_canvas)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	panel.offset_left = -260.0
	panel.offset_right = 260.0
	panel.offset_top = -105.0
	panel.offset_bottom = -35.0
	_spectator_canvas.add_child(panel)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.02, 0.02, 0.025, 0.86)
	panel_style.border_color = Color(0.5, 0.45, 0.3, 0.65)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", panel_style)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)
	var previous := Button.new()
	previous.text = "◀ PREVIOUS"
	previous.focus_mode = Control.FOCUS_NONE
	previous.pressed.connect(_cycle_spectator.bind(-1))
	row.add_child(previous)
	_spectator_label = Label.new()
	_spectator_label.text = "SPECTATING"
	_spectator_label.custom_minimum_size = Vector2(170, 40)
	_spectator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spectator_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_spectator_label.add_theme_color_override("font_color", Color(0.86, 0.8, 0.6))
	row.add_child(_spectator_label)
	var next := Button.new()
	next.text = "NEXT ▶"
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(_cycle_spectator.bind(1))
	row.add_child(next)

func _living_remote_ids() -> Array[int]:
	var ids: Array[int] = []
	for raw_id in _remote_players.keys():
		var pid := int(raw_id)
		var rp = _remote_players.get(pid)
		if not _remote_down.has(pid) and is_instance_valid(rp):
			ids.append(pid)
	ids.sort()
	return ids

func _cycle_spectator(direction: int) -> void:
	var ids := _living_remote_ids()
	if ids.is_empty():
		_spectate_target_id = -1
		if is_instance_valid(_spectator_label):
			_spectator_label.text = "NO TEAMMATES ALIVE"
		return
	var current_index := ids.find(_spectate_target_id)
	if current_index < 0:
		current_index = 0 if direction >= 0 else ids.size() - 1
	else:
		current_index = posmod(current_index + direction, ids.size())
	_spectate_target_id = ids[current_index]
	if is_instance_valid(_spectator_label):
		_spectator_label.text = "SPECTATING PLAYER %02d" % (_spectate_target_id + 1)

func _tick_dead_spectator(delta: float) -> void:
	if not _dead_spectator or not is_instance_valid(_camera):
		return
	if Input.is_key_pressed(KEY_LEFT):
		if not get_meta("spectate_left_latched", false):
			set_meta("spectate_left_latched", true)
			_cycle_spectator(-1)
	else:
		set_meta("spectate_left_latched", false)
	if Input.is_key_pressed(KEY_RIGHT):
		if not get_meta("spectate_right_latched", false):
			set_meta("spectate_right_latched", true)
			_cycle_spectator(1)
	else:
		set_meta("spectate_right_latched", false)

	var target: Node3D = _remote_players.get(_spectate_target_id) as Node3D
	if not is_instance_valid(target) or _remote_down.has(_spectate_target_id):
		_cycle_spectator(1)
		target = _remote_players.get(_spectate_target_id) as Node3D
	if not is_instance_valid(target):
		return

	# Stream the maze around the teammate we're watching, not our downed body,
	# so they never walk into ungenerated void on the spectator screen.
	if _maze and _maze.has_method("set_stream_focus"):
		_maze.set_stream_focus(target.global_position)

	# Smooth 1st/3rd-person follow camera with wall raycast collision
	var spectate_mode_1st: bool = get_meta("spectate_first_person", false)
	if Input.is_physical_key_pressed(KEY_C):
		if not get_meta("spectate_c_latched", false):
			set_meta("spectate_c_latched", true)
			spectate_mode_1st = not spectate_mode_1st
			set_meta("spectate_first_person", spectate_mode_1st)
	else:
		set_meta("spectate_c_latched", false)

	var head_pos: Vector3 = target.global_position + Vector3.UP * 1.55
	if spectate_mode_1st:
		_camera.global_position = _camera.global_position.lerp(head_pos, clampf(delta * 16.0, 0.0, 1.0))
		var target_rot_y := target.rotation.y
		_camera.rotation.y = lerp_angle(_camera.rotation.y, target_rot_y, clampf(delta * 16.0, 0.0, 1.0))
		_camera.rotation.x = lerp_angle(_camera.rotation.x, 0.0, clampf(delta * 10.0, 0.0, 1.0))
		_camera.fov = 75.0
		_camera.near = 0.05
		return

	var cam_offset: Vector3 = (target.global_transform.basis.z * 1.25) + (target.global_transform.basis.x * 0.38) + (Vector3.UP * 0.25)
	var ideal_pos: Vector3 = head_pos + cam_offset

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(head_pos, ideal_pos, 1)
	var exclude_nodes: Array[RID] = []
	if target is CollisionObject3D:
		exclude_nodes.append((target as CollisionObject3D).get_rid())
	if is_instance_valid(_player) and _player is CollisionObject3D:
		exclude_nodes.append((_player as CollisionObject3D).get_rid())
	for child in target.find_children("*", "CollisionObject3D"):
		var co := child as CollisionObject3D
		if co:
			exclude_nodes.append(co.get_rid())
	query.exclude = exclude_nodes

	var hit := space.intersect_ray(query)
	var final_pos: Vector3 = ideal_pos
	if not hit.is_empty():
		var hit_pos: Vector3 = hit["position"]
		if hit_pos.distance_to(head_pos) > 0.35:
			final_pos = hit_pos - cam_offset.normalized() * 0.18
		else:
			final_pos = head_pos

	var desired_basis := Transform3D().looking_at(head_pos - final_pos, Vector3.UP).basis
	var desired := Transform3D(desired_basis, final_pos)
	_camera.global_transform = _camera.global_transform.interpolate_with(desired, clampf(delta * 14.0, 0.0, 1.0))
	_camera.fov = 75.0
	_camera.near = 0.05

func _on_local_revived() -> void:
	_is_downed = false
	_local_is_down = false
	_bleedout_timer = 0.0
	_incoming_revive_progress = 0.0
	_incoming_revive_timeout = 0.0
	_set_revive_progress(0.0, false)
	_dead_spectator = false
	_spectate_target_id = -1
	if _maze and _maze.has_method("clear_stream_focus"):
		_maze.clear_stream_focus()
	if is_instance_valid(_spectator_canvas):
		_spectator_canvas.queue_free()
		_spectator_canvas = null
	if is_instance_valid(_downed_canvas):
		_downed_canvas.queue_free()
		_downed_canvas = null
	_restore_local_player_camera()
	if is_instance_valid(_player):
		if _player.has_method("set_downed_state"):
			_player.set_downed_state(false)
		else:
			_player.is_downed = false
		if _player.has_method("set_frozen"):
			_player.set_frozen(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _entity and _entity.has_method("set_local_player_targetable"):
		_entity.set_local_player_targetable(true)
	if _overlay and _overlay.has_method("clear_jumpscare"):
		_overlay.clear_jumpscare()
	_release_victim_jumpscare(0.0)   # CX30 safety net; normally already gone
	if _overlay and _overlay.has_method("flash"):
		_overlay.flash(Color(0.2, 0.9, 0.3, 0.5), 1.0)
	if is_instance_valid(_player):
		_play_revive_spectacle(_player.global_position)
	_check_all_down()

func _play_revive_spectacle(world_position: Vector3) -> void:
	if has_node("/root/AudioManager"):
		var pulse_sound = load("res://assets/audio/sfx/pickup/pickup_escape_unlocked.mp3")
		AudioManager.play_sfx_3d(self, pulse_sound, world_position, -1.0, 18.0, 1.18)
	if _overlay and _overlay.has_method("pulse"):
		_overlay.pulse(1.25)

	var halo := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.42
	ring.outer_radius = 0.5
	halo.mesh = ring
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.22, 1.0, 0.48, 0.82)
	halo.material_override = material
	halo.global_position = world_position + Vector3.UP * 0.12
	halo.scale = Vector3.ONE * 0.25
	add_child(halo)

	var light := OmniLight3D.new()
	light.light_color = Color(0.18, 1.0, 0.42)
	light.light_energy = 7.0
	light.omni_range = 7.0
	light.shadow_enabled = false
	light.global_position = world_position + Vector3.UP
	add_child(light)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(halo, "scale", Vector3.ONE * 4.2, 1.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(halo, "transparency", 1.0, 1.1)
	tween.tween_property(light, "light_energy", 0.0, 1.1)
	tween.chain().tween_callback(func() -> void:
		if is_instance_valid(halo): halo.queue_free()
		if is_instance_valid(light): light.queue_free())

## Relay used by the shared-entity director (and any future networked system).
func net_send(type: String, data: Dictionary) -> void:
	if _is_mp and has_node("/root/NetManager"):
		NetManager.send(type, data)

## Players still standing — the host's scare director picks targets from this.
func alive_player_ids() -> Array:
	var ids: Array = []
	if not _local_is_down and not _is_downed and has_node("/root/NetManager"):
		ids.append(NetManager.local_player_id)
	var total_connected := NetManager.connected_players if has_node("/root/NetManager") and NetManager.connected_players > 0 else 1
	for pid in range(total_connected):
		if pid == NetManager.local_player_id:
			continue
		if not _remote_down.has(pid):
			ids.append(int(pid))
	return ids

## Every client runs this on the same shared facts (down + disconnect events).
## When no one is left standing, the run ends for everyone — no eternal spectator softlock.
func _check_all_down() -> void:
	if _ended:
		return
	if not _is_mp:
		if _is_downed or _local_is_down:
			_end_run("caught")
		return

	var total_connected := NetManager.connected_players if has_node("/root/NetManager") and NetManager.connected_players > 0 else 1
	var standing_count := 0

	# Local player standing?
	if not _is_downed and not _local_is_down:
		standing_count += 1

	# Remote connected players standing?
	for pid in range(total_connected):
		if pid == NetManager.local_player_id:
			continue
		if not _remote_down.has(pid):
			standing_count += 1

	# If 0 connected players are standing (everyone is downed or dead), end the run immediately!
	if standing_count <= 0:
		if _is_mp:
			NetManager.send("game_over", {"reason": "caught"})
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
	# CX30 — only the caught ending hands the black screen over deliberately.
	# Any other ending simply drops it.
	if reason != "caught":
		_release_victim_jumpscare(0.0)
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
	# CX30 — singleplayer keeps its existing ending. Slide the overlay's own
	# black underneath the jumpscare layer before removing it, so the hand-off
	# to the ending text has no seam and the Entity is never revealed.
	if is_instance_valid(_jumpscare_video):
		if _overlay and _overlay.has_method("fade_to"):
			_overlay.fade_to(Color(0, 0, 0, 1), 0.0)
		_release_victim_jumpscare(0.0)
	# Stop ambient loops immediately but let the jumpscare scream ring out
	if _hum:
		_hum.stop()
	if _hvac:
		_hvac.stop()
	if _drone:
		_drone.stop()
	# Let the scream play for 1 second before killing all audio
	await get_tree().create_timer(1.0).timeout
	if has_node("/root/AudioManager"):
		AudioManager.stop_all_sounds()
	if _overlay and _overlay.has_method("fade_to"):
		_overlay.fade_to(Color(0, 0, 0, 1), 0.3)
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
	layer.layer = 100   # above all CRT filters and overlays
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)

	# Mouse enforcement controller to keep cursor visible on click
	var mouse_fix := Control.new()
	mouse_fix.name = "MouseFix"
	var scr := GDScript.new()
	scr.source_code = "extends Control\nfunc _process(_delta: float) -> void:\n\tif Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:\n\t\tInput.mouse_mode = Input.MOUSE_MODE_VISIBLE\n"
	scr.reload()
	mouse_fix.set_script(scr)
	layer.add_child(mouse_fix)

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

	var try_again_text := "TRY AGAIN"
	if _is_mp and has_node("/root/NetManager"):
		var target_count := NetManager.connected_players if NetManager.connected_players > 0 else 1
		try_again_text = "TRY AGAIN (0/%d READY)" % target_count

	var entries: Array = [
		[try_again_text, _on_try_again_pressed],
		["MAIN MENU", func():
			if has_node("/root/GameManager"):
				GameManager.to_menu()],
	]
	if not OS.has_feature("web"):
		entries.append(["QUIT", func(): get_tree().quit()])

	for idx in entries.size():
		var e: Array = entries[idx]
		var b := Button.new()
		b.text = e[0]
		b.custom_minimum_size = Vector2(280, 62)
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		UIKit.style_button(b, font, 24)
		b.pressed.connect(e[1])
		vb.add_child(b)
		if idx == 0:
			_try_again_button = b
			_update_restart_vote_ui()

func _update_restart_vote_ui() -> void:
	if is_instance_valid(_try_again_button) and _is_mp:
		var target_count := NetManager.connected_players if has_node("/root/NetManager") and NetManager.connected_players > 0 else 1
		_try_again_button.text = "TRY AGAIN (%d/%d READY)" % [_restart_votes.size(), target_count]

func _check_all_voted_restart() -> void:
	if not _is_mp or not NetManager.is_host:
		return
	var target_count := NetManager.connected_players if has_node("/root/NetManager") and NetManager.connected_players > 0 else 1
	if _restart_votes.size() >= target_count:
		NetManager.send("start_restart", {})
		if has_node("/root/GameManager"):
			GameManager.restart()

func _on_try_again_pressed() -> void:
	if not _is_mp:
		if has_node("/root/GameManager"):
			GameManager.restart()
	else:
		var local_id := NetManager.local_player_id if has_node("/root/NetManager") else 0
		_restart_votes[local_id] = true
		NetManager.send("vote_restart", {})
		_update_restart_vote_ui()
		if NetManager.is_host:
			_check_all_voted_restart()

func _ending_exit() -> void:
	_prepare_exit_cinematic()
	if has_node("/root/AudioManager"):
		AudioManager.fade_out_music(0.9)
	if _local_exit_transition:
		if _overlay and _overlay.has_method("fade_to"):
			_overlay.fade_to(Color(0, 0, 0, 0), 0.15)
		await _play_exit_ingress()
		if _overlay and _overlay.has_method("fade_to"):
			_overlay.fade_to(Color(0, 0, 0, 1), 0.22)
		await get_tree().create_timer(0.25).timeout
	else:
		# A teammate crossed the shared co-op exit. Do not fly this client's
		# camera across the maze; close their image into the same dark threshold.
		if _overlay and _overlay.has_method("fade_to"):
			_overlay.fade_to(Color(0, 0, 0, 1), 0.45)
		await get_tree().create_timer(0.5).timeout
	if _hum: _hum.stop()
	if _hvac: _hvac.stop()
	if _drone: _drone.stop()
	await _play_escape_video_or_fallback()
	if _overlay and _overlay.has_method("play_tv_static"):
		await _overlay.play_tv_static(5.0)
	else:
		await get_tree().create_timer(5.0).timeout
	var amulet_line := ""
	if has_node("/root/GameManager") and GameManager.cassette_found:
		amulet_line = "\n\n◇  TAPE 01 — AMULET RECOVERED  ◇"
	if _overlay and _overlay.has_method("show_ending"):
		_overlay.show_ending(
			"YOU ESCAPED THE BACKROOMS" + amulet_line + "\n\n— CREDITS —\n\nCreated & Developed by\nJoão Afonso\n\nThank you for playing!",
			Color(0.04, 0.04, 0.05, 1.0),
			Color(0.95, 0.82, 0.45))
	await get_tree().create_timer(8.0).timeout
	if has_node("/root/GameManager"):
		GameManager.to_menu()

func _prepare_exit_cinematic() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if is_instance_valid(_pause):
		if _pause.has_method("close_immediately"):
			_pause.close_immediately()
		else:
			_pause.visible = false
		_pause.set_process_unhandled_input(false)
	if is_instance_valid(_interact_prompt):
		_interact_prompt.modulate.a = 0.0
	if is_instance_valid(_snus_ui):
		_snus_ui.visible = false
	if is_instance_valid(_player) and _player.has_method("set_first_person_body_visible"):
		_player.set_first_person_body_visible(false)
	if _overlay and _overlay.has_method("set_dread"):
		_overlay.set_dread(0.0)

func _play_exit_ingress() -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_maze) \
			or not _maze.has_method("exit_transition_view"):
		await get_tree().create_timer(0.35).timeout
		return
	var view: Dictionary = _maze.exit_transition_view()
	if view.is_empty():
		await get_tree().create_timer(0.35).timeout
		return

	var cinematic_camera := Camera3D.new()
	cinematic_camera.name = "ExitThresholdCamera"
	add_child(cinematic_camera)
	cinematic_camera.global_transform = _camera.global_transform
	cinematic_camera.fov = _camera.fov
	cinematic_camera.near = 0.04
	cinematic_camera.make_current()

	var end_position: Vector3 = view["camera"]
	var look_at_position: Vector3 = view["look_at"]
	var end_transform := Transform3D(cinematic_camera.global_basis, end_position)
	end_transform = end_transform.looking_at(look_at_position, Vector3.UP)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(cinematic_camera, "global_transform", end_transform, 0.78).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(cinematic_camera, "fov", 66.0, 0.78).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await tween.finished

func _play_escape_video_or_fallback() -> void:
	if not ResourceLoader.exists(ESCAPE_VIDEO):
		if _overlay and _overlay.has_method("flash"):
			_overlay.flash(Color(1.0, 0.94, 0.72, 1.0), 2.2)
		await get_tree().create_timer(2.4).timeout
		return
	var layer := CanvasLayer.new()
	layer.layer = 90
	add_child(layer)
	var background := ColorRect.new()
	background.color = Color.BLACK
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var video := VideoStreamPlayer.new()
	video.stream = load(ESCAPE_VIDEO)
	video.expand = true
	# Treat the film as part of the effects mix, so both master and SFX volume
	# settings apply. Its source is heavily mastered, hence the conservative cap.
	video.bus = "SFX"
	# Start effectively silent. The video's first sound should emerge from the
	# black threshold instead of cutting into the end of the door movement.
	video.volume_db = END_VIDEO_START_VOLUME_DB
	video.modulate.a = 0.0
	video.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(video)
	# END is 4:3. Fit it inside any viewport with black pillar/letterboxing so
	# the creator's framing is never stretched on a widescreen display.
	var viewport_size := get_viewport().get_visible_rect().size
	var target_size := Vector2(viewport_size.y * (4.0 / 3.0), viewport_size.y)
	if target_size.x > viewport_size.x:
		target_size = Vector2(viewport_size.x, viewport_size.x / (4.0 / 3.0))
	video.size = target_size
	video.position = (viewport_size - target_size) * 0.5
	video.play()
	# The film begins on an open door. Dissolving that frame over the camera's
	# final position makes both doorways read as one continuous threshold.
	background.modulate.a = 0.0
	var reveal := create_tween()
	reveal.set_parallel(true)
	reveal.tween_property(background, "modulate:a", 1.0, 0.32)
	reveal.tween_property(video, "modulate:a", 1.0, 0.32)
	reveal.tween_property(
		video,
		"volume_db",
		END_VIDEO_TARGET_VOLUME_DB,
		END_VIDEO_AUDIO_FADE_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await video.finished
	if is_instance_valid(layer):
		layer.queue_free()

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
	if not Input.is_action_just_pressed("interact") or _local_is_down:
		return
	if _content_interaction_active:
		return
	if _extraction_interaction_active:
		return

	# Revive owns the interaction key while a downed teammate is in reach.
	var downed_rp = _get_nearest_downed_remote_player() if _is_mp else null
	if is_instance_valid(downed_rp) and _player.global_position.distance_to(downed_rp.global_position) < 2.5:
		return

	# A visible pickup is more predictable than interacting through it.
	if _snus and _snus.has_method("collect_nearest") and _snus.collect_nearest(_player.global_position):
		return

	# Lockers are deliberately sealed. Inspecting one gives a short narrative
	# response but never moves, freezes, hides, or changes the player's collision.
	if _lockers and _lockers.has_method("inspect_nearest") and _lockers.inspect_nearest(_player.global_position):
		if _snus_ui and _snus_ui.has_method("announce"):
			_snus_ui.announce("Something's dead inside...", 3.2)
		return

	# Phones remain dead until the first tin is collected. This check belongs
	# after pickup handling or it also blocks the first SNUS itself.
	if _snus and _snus.get_collected() < 1:
		return

	var px := int(floor(_player.global_position.x / 4.0 + 0.5))
	var pz := int(floor(_player.global_position.z / 4.0 + 0.5))
	var pcell := Vector2i(px, pz)
	if _maze.has_method("get_phone_node_in_cell"):
		var phone = _maze.get_phone_node_in_cell(pcell)
		if is_instance_valid(phone) and _player.global_position.distance_to(phone.global_position) < 2.2:
			_interact_with_phone(phone)
			return

## Answering a phone is a gamble. Every phone breathes at you — but what
## follows depends on WHICH phone it is (fixed per phone, same for every
## co-op client): radar phones give four restrained directional pulses;
## trapped phones call the entity to the receiver.
func _phone_fate(phone: Node3D) -> String:
	var cx := int(floor(phone.global_position.x / 4.0 + 0.5))
	var cz := int(floor(phone.global_position.z / 4.0 + 0.5))
	var h := posmod(cx * 31 + cz * 17 + _run_seed * 13, 100)
	var trap_percent := Tuning.PHONE_TRAP_PERCENT
	if _is_mp and has_node("/root/NetManager"):
		trap_percent = float(NetManager.rule("phone_traps", trap_percent))
	if h < int(round(clampf(trap_percent, 0.0, 1.0) * 100.0)):
		return "trap"
	return "radar"

func _interact_with_phone(phone: Node3D) -> void:
	if phone.has_meta("used") and phone.get_meta("used"):
		return
	if phone.has_meta("interacting") and phone.get_meta("interacting"):
		return
	if _is_mp and not NetManager.is_host:
		phone.set_meta("interacting", true)
		var cell: Vector2i = phone.get_meta("phone_cell", Vector2i.ZERO)
		NetManager.send("phone_request", {"cx": cell.x, "cz": cell.y})
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(phone) and not bool(phone.get_meta("used", false)):
				phone.set_meta("interacting", false)
		)
		return
	var target_id := NetManager.local_player_id if _is_mp else 0
	_activate_phone(phone, target_id, _is_mp)

func _activate_phone(phone: Node3D, target_id: int, broadcast: bool) -> void:
	if phone.has_meta("used") and phone.get_meta("used"):
		return
	phone.set_meta("interacting", true)
	phone.set_meta("used", true)
	var cell: Vector2i = phone.get_meta("phone_cell", Vector2i.ZERO)
	if broadcast and _is_mp:
		NetManager.send("phone_used", {"cx": cell.x, "cz": cell.y, "target": target_id})

	if not has_node("/root/AudioManager"):
		return
	var click_stream = load("res://assets/audio/sfx/environment/environment_light_flicker_buzz.mp3")
	var fate := _phone_fate(phone)

	# One subdued receiver click. The old stack of breath + echo + rapid pings
	# made every telephone exhausting rather than unsettling.
	AudioManager.play_sfx_3d(self, click_stream, phone.global_position, -8.0, 12.0, randf_range(0.94, 1.04))
	get_tree().create_timer(0.3).timeout.connect(func():
		if not is_instance_valid(phone) or not has_node("/root/AudioManager"):
			return
		var is_target := not _is_mp or target_id == NetManager.local_player_id
		if fate == "trap":
			if is_target:
				var breath_stream = load("res://assets/audio/juanjo/juanjo_sound - Backrooms Entity 23.wav")
				AudioManager.play_sfx_3d(self, breath_stream, phone.global_position, -5.0, 16.0, 0.88)
				if _snus_ui and _snus_ui.has_method("announce"):
					_snus_ui.announce("THE LINE HEARD YOU", 4.0)
			# Only the host moves the shared Entity. The telephone is a loud
			# location to investigate, never a supernatural lock-on to whoever
			# picked up the receiver.
			if (not _is_mp or NetManager.is_host) and _phone_scare_cd <= 0.0:
				_phone_scare_cd = Tuning.PHONE_TRAP_COOLDOWN
				if _entity and _entity.has_method("investigate_noise"):
					_entity.investigate_noise(
						phone.global_position, 36.0, "phone")
		elif fate == "radar" and is_target:
			var guidance := _phone_guidance_target()
			if guidance.is_empty():
				if _snus_ui and _snus_ui.has_method("announce"):
					_snus_ui.announce("ONLY STATIC ANSWERS", 3.0)
			else:
				if _snus_ui and _snus_ui.has_method("announce"):
					_snus_ui.announce(
						"THE LINE POINTS TO %s — LISTEN" % guidance["label"],
						4.5)
				_radar_pings_left = Tuning.PHONE_RADAR_PINGS
				_radar_timer = Tuning.PHONE_RADAR_PING_MAX_GAP \
					* float(_radar_pings_left)
				_radar_ping_cd = 0.05

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


func _phone_guidance_target() -> Dictionary:
	if not is_instance_valid(_player):
		return {}
	if not _snus_done and _snus \
			and _snus.has_method("get_nearest_uncollected_pos"):
		var snus_position: Vector3 = _snus.get_nearest_uncollected_pos(
			_player.global_position)
		if snus_position != Vector3.ZERO:
			return {"position": snus_position, "label": "THE NEAREST TIN"}
	if _extraction and _extraction.has_method("is_ready") \
			and not _extraction.is_ready() \
			and _extraction.has_method("get_nearest_unarmed_position"):
		var button_position: Vector3 = _extraction.get_nearest_unarmed_position(
			_player.global_position)
		if button_position != Vector3.ZERO:
			return {
				"position": button_position,
				"label": "THE NEXT EMERGENCY BUTTON",
			}
	if _maze and _maze.has_method("exit_door_position"):
		var exit_position: Vector3 = _maze.exit_door_position()
		if exit_position != Vector3.ZERO:
			return {"position": exit_position, "label": "THE EXIT"}
	return {}


func _play_radar_ping() -> void:
	if not is_instance_valid(_player) or not has_node("/root/AudioManager"):
		return
	var guidance := _phone_guidance_target()
	var nearest_pos: Vector3 = guidance.get("position", Vector3.ZERO)
	if nearest_pos == Vector3.ZERO:
		_radar_timer = 0.0
		_radar_pings_left = 0
		return
	if _radar_pings_left <= 0:
		_radar_timer = 0.0
		return
	
	var dist := _player.global_position.distance_to(nearest_pos)
	
	# Four measured pulses: closer tins answer a little sooner, never machine-gun.
	var closeness := clampf(1.0 - (dist / 28.0), 0.0, 1.0)
	_radar_ping_cd = lerpf(Tuning.PHONE_RADAR_PING_MAX_GAP, Tuning.PHONE_RADAR_PING_MIN_GAP, closeness)
	_radar_pings_left -= 1
	
	# Higher pitch the closer you are!
	var pitch := lerpf(1.15, 1.65, closeness)
	# Muffled/quieter when crouching to stay stealthy
	var vol := -20.0
	if "is_crouching" in _player and _player.is_crouching:
		vol = -24.0
		pitch *= 0.8
	
	var ping_stream = load("res://assets/audio/sfx/pickup/pickup_snus_pickup.mp3")
	var direction := (nearest_pos - _player.global_position).normalized()
	var ping_pos := _player.global_position + direction * 6.0 + Vector3.UP
	AudioManager.play_sfx_3d(self, ping_stream, ping_pos, vol, 18.0, pitch)


func _setup_interact_prompt() -> void:
	_interact_canvas = CanvasLayer.new()
	_interact_canvas.layer = 5   # below overlay
	add_child(_interact_canvas)
	
	_interact_prompt = Label.new()
	_interact_prompt.name = "InteractPrompt"
	_interact_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interact_prompt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	# Premium HUD typography & outline shadow
	_interact_prompt.text = "INTERACT"
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
	# 1. Check SNUS proximity (HIGHEST PRIORITY)
	if not in_range and _snus and _snus.has_method("is_snus_in_range"):
		if _snus.is_snus_in_range(_player.global_position):
			target_text = "GRAB SNUS"
			in_range = true

	# 2. Check Extraction terminal
	if not in_range and _extraction and _extraction.has_method("prompt"):
		var extraction_prompt := str(_extraction.prompt(_player.global_position))
		if extraction_prompt != "":
			target_text = extraction_prompt
			in_range = true

	# 3. Optional world content (notes, pamphlets)
	if not in_range and _content and _content.has_method("prompt"):
		var content_prompt := str(_content.prompt(_player.global_position))
		if content_prompt != "":
			target_text = content_prompt
			in_range = true

	# 4. VHS TV Deck (Archive Shrine Anchor Room)
	if not in_range:
		var vhs_tv = find_child("VHSTV", true, false)
		if is_instance_valid(vhs_tv) and vhs_tv.has_method("can_interact"):
			if vhs_tv.can_interact(_player.global_position):
				target_text = vhs_tv.get_interact_prompt()
				in_range = true
				if Input.is_action_just_pressed("interact"):
					vhs_tv.interact()
			
	# 2. Check Telephone proximity (if SNUS isn't already taking priority)
	if not in_range:
		var px := int(floor(_player.global_position.x / 4.0 + 0.5))
		var pz := int(floor(_player.global_position.z / 4.0 + 0.5))
		var pcell := Vector2i(px, pz)
		if _maze and _maze.has_method("get_phone_node_in_cell"):
			var phone = _maze.get_phone_node_in_cell(pcell)
			if is_instance_valid(phone):
				var dist = _player.global_position.distance_to(phone.global_position)
				if dist < 2.2:
					if not phone.has_meta("used") or not phone.get_meta("used"):
						if not phone.has_meta("interacting") or not phone.get_meta("interacting"):
							if _snus and _snus.get_collected() < 1:
								target_text = "DEAD LINE — FIND A SIGNAL"
							else:
								target_text = "ANSWER TELEPHONE — RISK THE CALL"
							in_range = true
						
	# CX31 — the one real door. It now stands in the world from the first second,
	# so walking into it early has to say why it will not open instead of doing
	# nothing (which read as "this door is broken").
	if not in_range and _maze and _maze.has_method("is_exit_locked") \
			and _maze.is_exit_locked():
		var door_position: Vector3 = _maze.exit_door_position()
		if door_position != Vector3.ZERO \
				and _player.global_position.distance_to(door_position) < EXIT_PROMPT_RANGE:
			target_text = _exit_locked_text()
			in_range = true

	# 3. Check sealed locker proximity
	if not in_range and _lockers and _lockers.has_method("get_nearest_locker_in_range"):
		var locker = _lockers.get_nearest_locker_in_range(_player.global_position)
		if is_instance_valid(locker):
			target_text = "INSPECT LOCKER"
			in_range = true
			
	# Respond instantly and smoothly fade
	if in_range:
		_interact_prompt.text = target_text
		_interact_prompt.modulate.a = lerpf(_interact_prompt.modulate.a, 1.0, 16.0 * delta)
	else:
		_interact_prompt.modulate.a = lerpf(_interact_prompt.modulate.a, 0.0, 16.0 * delta)

## CX31 — what the sealed exit tells you, naming the objective that is actually
## blocking it rather than a generic refusal.
func _exit_locked_text() -> String:
	if not _snus_done:
		var collected := 0
		if _snus and _snus.has_method("get_collected"):
			collected = int(_snus.get_collected())
		return "STILL LOCKED — FIND THE SNUS (%d/5)" % collected
	if _extraction and _extraction.has_method("get_armed_count") \
			and _extraction.has_method("get_total_buttons"):
		return "STILL LOCKED — EMERGENCY BUTTONS (%d/%d)" % [
			int(_extraction.get_armed_count()), int(_extraction.get_total_buttons())]
	return "STILL LOCKED — ACTIVATE THE EMERGENCY BUTTONS"

func _on_cassette_collected() -> void:
	if _snus_ui and _snus_ui.has_method("announce"):
		_snus_ui.announce("TAPE 01 RECOVERED — IT WILL REMEMBER YOU", 5.0)
	if _overlay and _overlay.has_method("flash"):
		_overlay.flash(Color(0.8, 0.55, 0.18, 0.28), 0.8)
	if _is_mp and not _receiving_shared_content:
		NetManager.send("cassette", {})

func _on_extraction_terminal_activated(terminal_id: int) -> void:
	if _is_mp:
		NetManager.send("extract_terminal", {"id": terminal_id})
	if not _is_mp or NetManager.is_host:
		_alert_entity_to_emergency_button(terminal_id)
	if _snus_ui and _snus_ui.has_method("announce"):
		if _is_mp:
			_snus_ui.announce(
				"BUTTON %d ACTIVE — 45 SECONDS" % (terminal_id + 1), 4.5)
		else:
			_snus_ui.announce("EMERGENCY BUTTON ACTIVE", 4.0)
	if _overlay and _overlay.has_method("flash"):
		_overlay.flash(Color(0.12, 0.9, 0.32, 0.24), 0.45)
	_update_emergency_mission(true)

func _alert_entity_to_emergency_button(terminal_id: int) -> void:
	if not _extraction or not _extraction.has_method("get_station_position"):
		return
	var alarm_position: Vector3 = _extraction.get_station_position(terminal_id)
	if alarm_position == Vector3.ZERO:
		return
	if _entity and _entity.has_method("investigate_noise"):
		_entity.investigate_noise(alarm_position, 34.0, "alarm")
	if _maze and _maze.has_method("set_flicker"):
		_maze.set_flicker(0.55)
		get_tree().create_timer(0.9).timeout.connect(func() -> void:
			if is_instance_valid(_maze) and _maze.has_method("set_flicker"):
				_maze.set_flicker(0.0)
		)

func _on_extraction_window_reset() -> void:
	if _is_mp:
		NetManager.send("extract_reset", {})
	_update_emergency_mission(false)
	if _snus_ui and _snus_ui.has_method("announce"):
		_snus_ui.announce("THE EMERGENCY BUTTONS RESET — TRY AGAIN", 5.0)

func _on_extraction_ready() -> void:
	if _exit_enabled:
		return
	_exit_enabled = true
	_final_started = true
	if _maze and _maze.has_method("enable_exit"):
		_maze.enable_exit()
	if _entity and _entity.has_method("enter_final_phase"):
		_entity.enter_final_phase()
	if _entity and _entity.has_method("grant_stalk_grace"):
		_entity.grant_stalk_grace(Tuning.STALK_EXIT_GRACE)
	if has_node("/root/AudioManager") and ResourceLoader.exists(FINAL_MUSIC):
		AudioManager.play_music(load(FINAL_MUSIC), -10.0, 1.5)
		AudioManager.set_music_volume(-3.0, 12.0)
	if _snus_ui and _snus_ui.has_method("announce"):
		_snus_ui.announce("THE EXIT IS OPEN — RUN", 7.0)
	if _overlay and _overlay.has_method("pulse"):
		_overlay.pulse(1.8)
	_set_current_mission("Locate the door", true)

func _on_anomaly_sector_entered(kind: String, center: Vector2i) -> void:
	match kind:
		"dead_light":
			if _maze and _maze.has_method("set_zone_power"):
				_maze.set_zone_power(center, 1, false)
		"echo":
			get_tree().create_timer(0.65).timeout.connect(func() -> void:
				if has_node("/root/AudioManager") and is_instance_valid(_player):
					var echo = load("res://assets/audio/sfx/environment/environment_distant_footsteps_echo.mp3")
					AudioManager.play_sfx_3d(self, echo, _player.global_position - _player.global_transform.basis.z * 3.0, -10.0, 16.0, 0.72))
		"repetition":
			for beat in 3:
				get_tree().create_timer(0.35 + float(beat) * 0.72).timeout.connect(func() -> void:
					if has_node("/root/AudioManager") and is_instance_valid(_player):
						var repeated = load("res://assets/audio/sfx/environment/environment_distant_door_slam.mp3")
						AudioManager.play_sfx_3d(self, repeated, Vector3(center.x * 4.0, 1.0, center.y * 4.0), -13.0, 22.0, 0.82))
	if _overlay and _overlay.has_method("pulse"):
		_overlay.pulse(0.45)

func _on_anomaly_sector_left(kind: String, center: Vector2i) -> void:
	if kind == "dead_light" and _maze and _maze.has_method("set_zone_power"):
		_maze.set_zone_power(center, 1, true)
	if _overlay and _overlay.has_method("set_dread"):
		# The director will immediately resume ownership of the true dread value.
		_overlay.set_dread(0.0)
