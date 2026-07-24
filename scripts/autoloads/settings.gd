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
var crt_filter := true             # mandatory visual identity; not user-toggleable
var voice_mode := 0            # 0: Push-to-talk, 1: Always speaking, 2: Off
var key_bindings: Dictionary = {
	"move_forward": KEY_W,
	"move_back": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"sprint": KEY_SHIFT,
	"crouch": KEY_CTRL,
	"interact": KEY_E,
	"callout": KEY_Q,
	"voice_ptt": KEY_V,
}


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
	# CRT is part of LIMINAL's visual identity. Ignore legacy configs that
	# stored `crt_filter=false` while the option was still exposed.
	crt_filter = true
	voice_mode = clampi(int(cf.get_value("voice", "mode", 0)), 0, 2)
	for action in key_bindings:
		key_bindings[action] = int(cf.get_value(
			"bindings", action, int(key_bindings[action])))


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cf.set_value("audio", "master", master_volume)
	cf.set_value("audio", "music", music_volume)
	cf.set_value("audio", "sfx", sfx_volume)
	cf.set_value("video", "fullscreen", fullscreen)
	cf.set_value("video", "window_mode", window_mode)
	cf.set_value("voice", "mode", voice_mode)
	for action in key_bindings:
		cf.set_value("bindings", action, int(key_bindings[action]))
	cf.save(PATH)


func apply_all() -> void:
	apply_audio()
	apply_fullscreen()
	apply_key_bindings()


func apply_audio() -> void:
	_apply_bus("Master", master_volume)
	_apply_bus("Music", music_volume)
	_apply_bus("SFX", sfx_volume)
	# Breathing is a child of SFX, so it inherits that slider once at unity gain.
	# Its mute still needs explicit restoration after the jumpscare bus blackout.
	var breathing_idx := AudioServer.get_bus_index("Breathing")
	if breathing_idx >= 0:
		AudioServer.set_bus_mute(breathing_idx, sfx_volume <= 0.001)
		AudioServer.set_bus_volume_db(breathing_idx, 0.0)


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


func apply_key_bindings() -> void:
	for action in key_bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		var input := event_from_binding_code(int(key_bindings[action]))
		if input != null:
			InputMap.action_add_event(action, input)


func rebind_action(action: String, binding_code: int, persist: bool = true) -> void:
	if not key_bindings.has(action) or binding_code == 0:
		return
	var old_key := int(key_bindings[action])
	# Keep every gameplay action reachable: assigning an occupied key or mouse
	# button swaps the two bindings instead of creating an ambiguous duplicate.
	for other_action in key_bindings:
		if other_action != action and int(key_bindings[other_action]) == binding_code:
			key_bindings[other_action] = old_key
			break
	key_bindings[action] = binding_code
	apply_key_bindings()
	if persist:
		save_settings()


func binding_text(action: String) -> String:
	return binding_text_from_code(int(key_bindings.get(action, KEY_NONE)))


## Keyboard codes remain positive for backwards compatibility with existing
## settings.cfg files. Mouse buttons use their negated MouseButton index.
func binding_code_from_event(event: InputEvent) -> int:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var code := key_event.physical_keycode \
			if key_event.physical_keycode != KEY_NONE else key_event.keycode
		return int(code)
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index != MOUSE_BUTTON_NONE:
			return -int(mouse_event.button_index)
	return 0


func event_from_binding_code(binding_code: int) -> InputEvent:
	if binding_code > 0:
		var key_event := InputEventKey.new()
		key_event.physical_keycode = binding_code
		return key_event
	if binding_code < 0:
		var mouse_event := InputEventMouseButton.new()
		mouse_event.button_index = -binding_code as MouseButton
		return mouse_event
	return null


func binding_text_from_code(binding_code: int) -> String:
	if binding_code >= 0:
		return OS.get_keycode_string(binding_code)
	match -binding_code:
		MOUSE_BUTTON_LEFT:
			return "LEFT MOUSE"
		MOUSE_BUTTON_RIGHT:
			return "RIGHT MOUSE"
		MOUSE_BUTTON_MIDDLE:
			return "MIDDLE MOUSE"
		MOUSE_BUTTON_WHEEL_UP:
			return "WHEEL UP"
		MOUSE_BUTTON_WHEEL_DOWN:
			return "WHEEL DOWN"
		MOUSE_BUTTON_WHEEL_LEFT:
			return "WHEEL LEFT"
		MOUSE_BUTTON_WHEEL_RIGHT:
			return "WHEEL RIGHT"
		MOUSE_BUTTON_XBUTTON1:
			return "MOUSE 4"
		MOUSE_BUTTON_XBUTTON2:
			return "MOUSE 5"
		_:
			return "MOUSE " + str(-binding_code)
