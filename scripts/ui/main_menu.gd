extends Control

## LIMINAL — main menu (first / boot scene).
## Built procedurally for .tscn reliability: main_menu.tscn is just a root
## Control with this script attached; the whole tree is assembled in _ready().

const GAME_WORLD_PATH: String = "res://scenes/game_world.tscn"

const BG_PATH: String = "res://assets/textures/backgrounds/menu_void_corridor.png"
const WORDMARK_PATH: String = "res://assets/ui/wordmark_title.png"
const THEME_PATH: String = "res://assets/ui/theme.tres"
const FONT_PATH: String = "res://assets/fonts/special_elite.ttf"
const MUSIC_PATH: String = "res://assets/audio/music/music_exploration_liminal_dread_theme.mp3"
const HUM_PATH: String = "res://assets/audio/ambient/ambient_backrooms_office_fluorescent_hum_loop.mp3"

const DIM_YELLOW: Color = Color(0.72, 0.66, 0.42)

var _wordmark: TextureRect
var _play_button: Button


func _ready() -> void:
	# Mouse is always visible on the menu (gameplay grabs it later on Play).
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var ui_theme := load(THEME_PATH)
	if ui_theme:
		theme = ui_theme

	_build_ui()
	_start_audio()
	_start_wordmark_flicker()


func _build_ui() -> void:
	var font := load(FONT_PATH)

	# Full-screen corridor backdrop.
	var background := TextureRect.new()
	background.name = "Background"
	background.texture = load(BG_PATH)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.modulate = Color(0.8, 0.8, 0.8)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Darkening scrim to deepen the mood and keep text readable.
	var scrim := ColorRect.new()
	scrim.name = "Scrim"
	scrim.color = Color(0, 0, 0, 0.35)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Game title art — anchored top-center, upper third.
	_wordmark = TextureRect.new()
	_wordmark.name = "Wordmark"
	_wordmark.texture = load(WORDMARK_PATH)
	_wordmark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_wordmark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_wordmark.custom_minimum_size = Vector2(620, 210)
	_wordmark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_wordmark)
	_wordmark.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	# Push it down into the upper third and center the 620px width.
	_wordmark.offset_left = -310.0
	_wordmark.offset_right = 310.0
	_wordmark.offset_top = 90.0
	_wordmark.offset_bottom = 300.0

	# Tagline, just under the wordmark.
	var tagline := Label.new()
	tagline.name = "Tagline"
	tagline.text = "You woke somewhere that should not be."
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tagline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tagline.add_theme_color_override("font_color", DIM_YELLOW)
	tagline.add_theme_font_size_override("font_size", 20)
	if font:
		tagline.add_theme_font_override("font", font)
	add_child(tagline)
	tagline.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	tagline.offset_left = -400.0
	tagline.offset_right = 400.0
	tagline.offset_top = 312.0
	tagline.offset_bottom = 342.0

	# Lower-middle menu column.
	var menu := VBoxContainer.new()
	menu.name = "Menu"
	menu.alignment = BoxContainer.ALIGNMENT_CENTER
	menu.add_theme_constant_override("separation", 20)
	add_child(menu)
	menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	menu.offset_left = -180.0
	menu.offset_right = 180.0
	menu.offset_top = 40.0
	menu.offset_bottom = 260.0

	# Play button — art baked into the theme (label reads "ENTER").
	_play_button = Button.new()
	_play_button.name = "PlayButton"
	_play_button.text = ""
	_play_button.custom_minimum_size = Vector2(288, 96)
	_play_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_play_button.focus_mode = Control.FOCUS_ALL
	menu.add_child(_play_button)

	_play_button.pressed.connect(_on_play_pressed)
	_play_button.mouse_entered.connect(_on_play_hover)
	_play_button.mouse_exited.connect(_on_play_unhover)

	# Control hint below the button.
	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "WASD to move  ·  Mouse to look  ·  There is a way out."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_OFF
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_color_override("font_color", DIM_YELLOW)
	hint.add_theme_font_size_override("font_size", 18)
	if font:
		hint.add_theme_font_override("font", font)
	menu.add_child(hint)


func _start_audio() -> void:
	if has_node("/root/AudioManager"):
		var am := get_node("/root/AudioManager")
		if am.has_method("play_music"):
			am.play_music(load(MUSIC_PATH), -8.0, 2.0)


func _start_wordmark_flicker() -> void:
	if not is_instance_valid(_wordmark):
		return
	# Faint breathing/flicker on the title. Tween is created ON the wordmark
	# so it dies with the node rather than outliving it.
	var tw := _wordmark.create_tween()
	tw.set_loops()
	tw.set_trans(Tween.TRANS_SINE)
	tw.set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_wordmark, "modulate:a", 0.75, 2.4)
	tw.tween_property(_wordmark, "modulate:a", 1.0, 2.4)


func _on_play_pressed() -> void:
	if has_node("/root/LoadingScreen"):
		var ls := get_node("/root/LoadingScreen")
		if ls.has_method("preload_and_change_scene"):
			ls.preload_and_change_scene(GAME_WORLD_PATH, 1.8)
			return
	# Fallback if the LoadingScreen autoload is unavailable.
	get_tree().change_scene_to_file(GAME_WORLD_PATH)


func _on_play_hover() -> void:
	if is_instance_valid(_play_button):
		_play_button.modulate = Color(0.85, 0.85, 0.85)


func _on_play_unhover() -> void:
	if is_instance_valid(_play_button):
		_play_button.modulate = Color(1, 1, 1)
