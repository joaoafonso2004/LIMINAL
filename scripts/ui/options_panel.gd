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

	var vb := VBoxContainer.new()
	add_child(vb)
	vb.position = Vector2(70, 180)
	vb.size = Vector2(380, 700)
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

	var crt := CheckButton.new()
	crt.text = "CRT FILTER"
	crt.button_pressed = Settings.crt_filter
	crt.custom_minimum_size = Vector2(380, 48)
	crt.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UIKit.style_brutalist_button(crt, 17)
	crt.toggled.connect(func(on: bool):
		Settings.crt_filter = on
		Settings.save_settings())
	vb.add_child(crt)

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
