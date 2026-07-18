extends CanvasLayer
## Minimal pause overlay. Owns ESC. Keeps the horror quiet — a thin dark
## panel, resume / back-to-menu. No score, no stats.

var _root: Control = null
var _dim: ColorRect = null
var _menu_vb: VBoxContainer = null
var _options: Control = null
var _paused := false

func _ready() -> void:
	layer = 25
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	visible = false

func _build() -> void:
	_root = Control.new()
	add_child(_root)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	if ResourceLoader.exists("res://assets/ui/theme.tres"):
		_root.theme = load("res://assets/ui/theme.tres")

	_dim = ColorRect.new()
	_root.add_child(_dim)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.02, 0.02, 0.015, 0.82)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_menu_vb = VBoxContainer.new()
	_root.add_child(_menu_vb)
	_menu_vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_menu_vb.add_theme_constant_override("separation", 22)
	_menu_vb.alignment = BoxContainer.ALIGNMENT_CENTER

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_apply_font(title, 44, Color(0.78, 0.72, 0.46))
	_menu_vb.add_child(title)

	var resume := Button.new()
	resume.text = "Resume"
	resume.custom_minimum_size = Vector2(240, 60)
	_apply_font(resume, 26, Color(0.85, 0.8, 0.6))
	resume.pressed.connect(_toggle)
	_menu_vb.add_child(resume)

	var options := Button.new()
	options.text = "Options"
	options.custom_minimum_size = Vector2(240, 60)
	_apply_font(options, 22, Color(0.7, 0.66, 0.45))
	options.pressed.connect(_show_options)
	_menu_vb.add_child(options)

	var quit := Button.new()
	quit.text = "Leave (give up)"
	quit.custom_minimum_size = Vector2(240, 60)
	_apply_font(quit, 22, Color(0.7, 0.66, 0.45))
	quit.pressed.connect(_on_quit)
	_menu_vb.add_child(quit)


func _show_options() -> void:
	if _options == null:
		_options = load("res://scripts/ui/options_panel.gd").new()
		_root.add_child(_options)
		_options.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_options.closed.connect(func():
			_options.visible = false
			_menu_vb.visible = true)
	_menu_vb.visible = false
	_options.visible = true

func _apply_font(c: Control, size: int, col: Color) -> void:
	if ResourceLoader.exists("res://assets/fonts/special_elite.ttf"):
		c.add_theme_font_override("font", load("res://assets/fonts/special_elite.ttf"))
	c.add_theme_font_size_override("font_size", size)
	c.add_theme_color_override("font_color", col)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		_toggle()
		get_viewport().set_input_as_handled()

func _toggle() -> void:
	_paused = not _paused
	visible = _paused
	get_tree().paused = _paused
	if _paused:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		# Resuming with the options page open: settle back to the pause menu.
		if _options and _options.visible:
			_options.visible = false
			_menu_vb.visible = true
			if has_node("/root/Settings"):
				Settings.save_settings()

func _on_quit() -> void:
	_paused = false
	visible = false
	get_tree().paused = false
	if has_node("/root/GameManager"):
		GameManager.to_menu()
	else:
		get_tree().change_scene_to_file("res://scenes/main.tscn")
