extends CanvasLayer
## Minimal pause overlay. Owns ESC. Keeps the horror quiet — a thin dark
## panel, resume / back-to-menu. No score, no stats.

signal local_pause_changed(open: bool)

var _root: Control = null
var _dim: ColorRect = null
var _menu_vb: VBoxContainer = null
var _options: Control = null
var _paused := false
var _mission_label: Label = null
var _mission_text := "Find 5 Snus 0/5"
var _resume_button: Button = null

const INK := Color(0.025, 0.028, 0.025, 1.0)
const PAPER := Color(0.88, 0.86, 0.75, 1.0)
const MUTED := Color(0.52, 0.52, 0.46, 1.0)
const SIGNAL := Color(0.78, 0.70, 0.48, 1.0)

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

	_dim = ColorRect.new()
	_root.add_child(_dim)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color.WHITE
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var desaturate := Shader.new()
	desaturate.code = """
shader_type canvas_item;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
void fragment() {
	// A low mip level gives a restrained, stable blur without hiding the live
	// game. In co-op this texture is refreshed while the menu remains open.
	vec3 source = textureLod(screen_texture, SCREEN_UV, 1.35).rgb;
	float gray = dot(source, vec3(0.299, 0.587, 0.114));
	vec3 muted = mix(source, vec3(gray), 0.58);
	vec3 matte = muted * 0.34 + vec3(0.006, 0.007, 0.005);
	COLOR = vec4(matte, 1.0);
}
"""
	var shader_material := ShaderMaterial.new()
	shader_material.shader = desaturate
	_dim.material = shader_material

	var navigation_rail := ColorRect.new()
	navigation_rail.color = INK
	navigation_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(navigation_rail)
	navigation_rail.anchor_bottom = 1.0
	navigation_rail.offset_right = 520.0
	var title := Label.new()
	title.text = "PAUSED"
	title.position = Vector2(70, 104)
	title.size = Vector2(430, 74)
	_style_label(title, 48, PAPER, 800)
	_root.add_child(title)

	# Reliable objective memory without adding a permanent gameplay HUD.
	_mission_label = Label.new()
	_mission_label.text = _mission_text
	_mission_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mission_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mission_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_root.add_child(_mission_label)
	_mission_label.anchor_left = 1.0
	_mission_label.anchor_right = 1.0
	_mission_label.offset_left = -650.0
	_mission_label.offset_right = -72.0
	_mission_label.offset_top = 68.0
	_mission_label.offset_bottom = 108.0
	_style_label(_mission_label, 18, PAPER, 500)

	_menu_vb = VBoxContainer.new()
	_root.add_child(_menu_vb)
	_menu_vb.position = Vector2(70, 220)
	_menu_vb.size = Vector2(380, 420)
	_menu_vb.add_theme_constant_override("separation", 12)
	_menu_vb.alignment = BoxContainer.ALIGNMENT_BEGIN

	_resume_button = _pause_button("RESUME")
	_resume_button.pressed.connect(_toggle)
	_menu_vb.add_child(_resume_button)

	var options := _pause_button("SETTINGS")
	options.pressed.connect(_show_options)
	_menu_vb.add_child(options)

	var main_menu := _pause_button("MAIN MENU")
	main_menu.pressed.connect(_on_main_menu)
	_menu_vb.add_child(main_menu)

	var quit := _pause_button("QUIT")
	quit.pressed.connect(_on_quit_app)
	_menu_vb.add_child(quit)

func _pause_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(380, 58)
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UIKit.style_brutalist_button(button, 20)
	return button

func _style_label(label: Label, size: int, color: Color, weight: int) -> void:
	label.add_theme_font_override("font", UIKit.utilitarian_font(weight))
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_mission(text: String) -> void:
	_mission_text = text
	if is_instance_valid(_mission_label):
		_mission_label.text = text


func _show_options() -> void:
	if _options == null:
		_options = load("res://scripts/ui/options_panel.gd").new()
		_root.add_child(_options)
		_options.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_options.closed.connect(func():
			_options.visible = false
			_menu_vb.visible = true
			if is_instance_valid(_resume_button):
				_resume_button.grab_focus())
	_menu_vb.visible = false
	_options.visible = true

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		_toggle()
		get_viewport().set_input_as_handled()

func _toggle() -> void:
	_paused = not _paused
	visible = _paused
	var coop_menu_only := _is_coop_session()
	# A co-op pause is strictly local UI. The SceneTree must keep processing so
	# entities, teammates, revive windows, audio and network state stay alive.
	get_tree().paused = _paused and not coop_menu_only
	if coop_menu_only:
		local_pause_changed.emit(_paused)
	if _paused:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if is_instance_valid(_resume_button):
			_resume_button.grab_focus.call_deferred()
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		# Resuming with the options page open: settle back to the pause menu.
		if _options and _options.visible:
			_options.visible = false
			_menu_vb.visible = true
			if has_node("/root/Settings"):
				Settings.save_settings()

func _is_coop_session() -> bool:
	return has_node("/root/NetManager") and bool(NetManager.is_multiplayer)

func close_immediately() -> void:
	var release_local_controls := _paused and _is_coop_session()
	_paused = false
	visible = false
	get_tree().paused = false
	if release_local_controls:
		local_pause_changed.emit(false)

func _on_main_menu() -> void:
	close_immediately()
	if has_node("/root/GameManager"):
		GameManager.to_menu()
	else:
		get_tree().change_scene_to_file("res://scenes/main.tscn")

func _on_quit_app() -> void:
	close_immediately()
	get_tree().quit()
