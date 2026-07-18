extends Control
## Reusable options panel: mouse sensitivity, master/music/SFX volume,
## fullscreen. Reads and writes the Settings autoload; saves on every commit
## (slider release / toggle). Emits `closed` for the host menu to handle.
## Built entirely in code, styled to match the game's dim-yellow menus.

signal closed

const FONT_PATH := "res://assets/fonts/special_elite.ttf"
const DIM_YELLOW := Color(0.72, 0.66, 0.42)
const BRIGHT := Color(0.93, 0.88, 0.66)

var _font: Font = null


func _ready() -> void:
	if ResourceLoader.exists(FONT_PATH):
		_font = load(FONT_PATH)
	_build()


func _build() -> void:
	var vb := VBoxContainer.new()
	add_child(vb)
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(420, 0)

	var title := Label.new()
	title.text = "OPTIONS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style(title, 30, BRIGHT)
	vb.add_child(title)

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

	var fs := CheckButton.new()
	fs.text = "FULLSCREEN"
	fs.button_pressed = Settings.fullscreen
	fs.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style(fs, 20, DIM_YELLOW)
	fs.toggled.connect(func(on: bool):
		Settings.fullscreen = on
		Settings.apply_fullscreen()
		Settings.save_settings())
	vb.add_child(fs)

	var back := Button.new()
	back.text = "BACK"
	back.custom_minimum_size = Vector2(220, 56)
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back.focus_mode = Control.FOCUS_NONE
	_style(back, 24, BRIGHT)
	back.pressed.connect(func():
		Settings.save_settings()
		closed.emit())
	vb.add_child(back)


func _add_slider(parent: VBoxContainer, label_text: String, minv: float, maxv: float, step: float, getter: Callable, setter: Callable) -> void:
	var row_label := Label.new()
	row_label.text = label_text
	row_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style(row_label, 18, DIM_YELLOW)
	parent.add_child(row_label)

	var slider := HSlider.new()
	slider.min_value = minv
	slider.max_value = maxv
	slider.step = step
	slider.value = getter.call()
	slider.custom_minimum_size = Vector2(380, 24)
	slider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(func(v: float):
		setter.call(v)
		Settings.apply_all())
	slider.drag_ended.connect(func(_changed: bool):
		Settings.save_settings())
	parent.add_child(slider)


func _style(c: Control, size: int, col: Color) -> void:
	if _font:
		c.add_theme_font_override("font", _font)
	c.add_theme_font_size_override("font_size", size)
	c.add_theme_color_override("font_color", col)
