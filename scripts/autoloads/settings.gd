extends Node
## Persistent user settings (user://settings.cfg): mouse sensitivity, audio
## volumes, fullscreen. Applied on boot; every change is applied live and
## saved by the options panel. Registered AFTER AudioManager so the Music/SFX
## buses already exist when volumes are applied.

const PATH := "user://settings.cfg"

var mouse_sensitivity := 1.0   # multiplier over the player's base sensitivity
var master_volume := 1.0       # 0..1 linear
var music_volume := 1.0
var sfx_volume := 1.0
var fullscreen := false
var window_mode: int = 1       # 0: Fullscreen, 1: Windowed, 2: Maximized
var crt_filter := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()
	apply_all()


func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return  # first run — defaults stand
	mouse_sensitivity = clampf(float(cf.get_value("input", "mouse_sensitivity", 1.0)), 0.2, 3.0)
	master_volume = clampf(float(cf.get_value("audio", "master", 1.0)), 0.0, 1.0)
	music_volume = clampf(float(cf.get_value("audio", "music", 1.0)), 0.0, 1.0)
	sfx_volume = clampf(float(cf.get_value("audio", "sfx", 1.0)), 0.0, 1.0)
	fullscreen = bool(cf.get_value("video", "fullscreen", false))
	window_mode = int(cf.get_value("video", "window_mode", 1 if not fullscreen else 0))
	crt_filter = bool(cf.get_value("video", "crt_filter", true))


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cf.set_value("audio", "master", master_volume)
	cf.set_value("audio", "music", music_volume)
	cf.set_value("audio", "sfx", sfx_volume)
	cf.set_value("video", "fullscreen", fullscreen)
	cf.set_value("video", "window_mode", window_mode)
	cf.set_value("video", "crt_filter", crt_filter)
	cf.save(PATH)


func apply_all() -> void:
	_apply_bus("Master", master_volume)
	_apply_bus("Music", music_volume)
	_apply_bus("SFX", sfx_volume)
	apply_fullscreen()


func _apply_bus(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.001)))


func apply_fullscreen() -> void:
	if window_mode == 0:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	elif window_mode == 2:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	else:
		# Actual Windowed Mode: Centered window with title bar & borders
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		
		var screen_id := DisplayServer.window_get_current_screen()
		var screen_size := DisplayServer.screen_get_size(screen_id)
		var target_w := 1280
		var target_h := 720
		if screen_size.x >= 2560 and screen_size.y >= 1440:
			target_w = 1600
			target_h = 900
		elif screen_size.x >= 1920 and screen_size.y >= 1080:
			target_w = 1440
			target_h = 810

		DisplayServer.window_set_size(Vector2i(target_w, target_h))
		var screen_pos := DisplayServer.screen_get_position(screen_id)
		var center_pos := screen_pos + (screen_size - Vector2i(target_w, target_h)) / 2
		DisplayServer.window_set_position(center_pos)
