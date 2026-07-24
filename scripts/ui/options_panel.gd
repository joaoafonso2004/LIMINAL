extends Control
## Reusable options panel: mouse sensitivity, master/music/SFX volume,
## fullscreen. Reads and writes the Settings autoload; saves on every commit
## (slider release / toggle). Emits `closed` for the host menu to handle.
## Built entirely in code, using the same matte corporate language as the
## main and pause menu language.

signal closed

const INK := Color(0.025, 0.028, 0.025, 1.0)
const PAPER := Color(0.88, 0.86, 0.75, 1.0)
const MUTED := Color(0.52, 0.52, 0.46, 1.0)
const SIGNAL := Color(0.78, 0.70, 0.48, 1.0)

var _font: Font = null
var _binding_buttons: Dictionary = {}
var _awaiting_action := ""


func _ready() -> void:
	_font = UIKit.utilitarian_font(400)
	_build()


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.005, 0.006, 0.005, 0.72)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var rail := ColorRect.new()
	rail.color = INK
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rail)
	rail.anchor_bottom = 1.0
	rail.offset_right = 520.0
	var title := Label.new()
	title.text = "SETTINGS"
	title.position = Vector2(70, 84)
	title.size = Vector2(390, 70)
	_style(title, 44, PAPER, 800)
	add_child(title)

	var scroll := ScrollContainer.new()
	add_child(scroll)
	scroll.anchor_bottom = 1.0
	scroll.offset_left = 70.0
	scroll.offset_right = 470.0
	scroll.offset_top = 170.0
	scroll.offset_bottom = -42.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vb := VBoxContainer.new()
	scroll.add_child(vb)
	vb.custom_minimum_size = Vector2(380, 0)
	vb.alignment = BoxContainer.ALIGNMENT_BEGIN
	vb.add_theme_constant_override("separation", 12)

	_add_slider(vb, "MOUSE SENSITIVITY", 0.2, 3.0, 0.05,
		func(): return Settings.mouse_sensitivity,
		func(v): Settings.mouse_sensitivity = v)
	_add_slider(vb, "MASTER VOLUME", 0.0, 1.0, 0.05,
		func(): return Settings.master_volume,
		func(v): Settings.master_volume = v)
	_add_slider(vb, "MUSIC", 0.0, 1.0, 0.05,
		func(): return Settings.music_volume,
		func(v): Settings.music_volume = v)
	_add_slider(vb, "SFX", 0.0, 1.0, 0.05,
		func(): return Settings.sfx_volume,
		func(v): Settings.sfx_volume = v)

	var mode_btn := Button.new()
	var mode_names := ["FULLSCREEN", "WINDOWED", "MAXIMIZED WINDOW"]
	mode_btn.text = "DISPLAY: %s" % mode_names[posmod(Settings.window_mode, mode_names.size())]
	mode_btn.custom_minimum_size = Vector2(380, 48)
	mode_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UIKit.style_brutalist_button(mode_btn, 17)
	mode_btn.pressed.connect(func():
		Settings.window_mode = posmod(Settings.window_mode + 1, mode_names.size())
		Settings.fullscreen = (Settings.window_mode == 0)
		mode_btn.text = "DISPLAY: %s" % mode_names[Settings.window_mode]
		Settings.apply_fullscreen()
		Settings.save_settings())
	vb.add_child(mode_btn)

	var voice := OptionButton.new()
	voice.add_item("VOICE: PUSH-TO-TALK")
	voice.add_item("VOICE: ALWAYS SPEAKING")
	voice.add_item("VOICE: OFF")
	voice.select(Settings.voice_mode)
	voice.custom_minimum_size = Vector2(380, 48)
	UIKit.style_brutalist_button(voice, 17)
	voice.item_selected.connect(func(index: int):
		Settings.voice_mode = clampi(index, 0, 2)
		Settings.save_settings())
	vb.add_child(voice)

	var bindings_title := Label.new()
	bindings_title.text = "KEY / MOUSE BINDINGS"
	_style(bindings_title, 13, MUTED, 500)
	vb.add_child(bindings_title)
	for spec in [
		["move_forward", "MOVE FORWARD"],
		["move_back", "MOVE BACK"],
		["move_left", "MOVE LEFT"],
		["move_right", "MOVE RIGHT"],
		["sprint", "SPRINT"],
		["crouch", "CROUCH"],
		["interact", "INTERACT"],
		["callout", "SCREAM"],
		["voice_ptt", "VOICE PTT"],
	]:
		_add_binding_row(vb, String(spec[0]), String(spec[1]))

	var action_gap := Control.new()
	action_gap.custom_minimum_size.y = 18.0
	action_gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(action_gap)

	var back := Button.new()
	back.text = "BACK"
	back.custom_minimum_size = Vector2(380, 54)
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UIKit.style_brutalist_button(back, 18)
	back.pressed.connect(func():
		Settings.save_settings()
		closed.emit())
	vb.add_child(back)


func _add_binding_row(
		parent: VBoxContainer, action: String, display_name: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(380, 38)
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var label := Label.new()
	label.text = display_name
	label.custom_minimum_size = Vector2(215, 38)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style(label, 13, PAPER, 500)
	row.add_child(label)
	var button := Button.new()
	button.text = Settings.binding_text(action)
	button.custom_minimum_size = Vector2(145, 38)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIKit.style_brutalist_button(button, 14)
	button.pressed.connect(func():
		_awaiting_action = action
		button.text = "KEY OR MOUSE...")
	row.add_child(button)
	_binding_buttons[action] = button


func _input(event: InputEvent) -> void:
	if _awaiting_action.is_empty() or not visible:
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		if key_event.physical_keycode == KEY_ESCAPE \
				or key_event.keycode == KEY_ESCAPE:
			_refresh_binding_buttons()
			_awaiting_action = ""
			get_viewport().set_input_as_handled()
			return
	elif event is InputEventMouseButton:
		if not (event as InputEventMouseButton).pressed:
			return
	else:
		return
	var binding_code := Settings.binding_code_from_event(event)
	if binding_code == 0:
		return
	Settings.rebind_action(_awaiting_action, binding_code)
	_awaiting_action = ""
	_refresh_binding_buttons()
	get_viewport().set_input_as_handled()


func _refresh_binding_buttons() -> void:
	for action in _binding_buttons:
		var button = _binding_buttons[action]
		if is_instance_valid(button):
			button.text = Settings.binding_text(String(action))


func _add_slider(parent: VBoxContainer, label_text: String, minv: float, maxv: float, step: float, getter: Callable, setter: Callable) -> void:
	var row_label := Label.new()
	row_label.text = label_text
	row_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style(row_label, 13, MUTED, 500)
	parent.add_child(row_label)

	var slider := HSlider.new()
	slider.min_value = minv
	slider.max_value = maxv
	slider.step = step
	slider.value = getter.call()
	slider.custom_minimum_size = Vector2(380, 28)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	slider.focus_mode = Control.FOCUS_ALL
	UIKit.style_brutalist_slider(slider)
	slider.value_changed.connect(func(v: float):
		setter.call(v)
		Settings.apply_all())
	slider.drag_ended.connect(func(_changed: bool):
		Settings.save_settings())
	parent.add_child(slider)


func _style(c: Control, size: int, col: Color, weight: int = 400) -> void:
	if _font:
		c.add_theme_font_override("font", UIKit.utilitarian_font(weight))
	c.add_theme_font_size_override("font_size", size)
	c.add_theme_color_override("font_color", col)
