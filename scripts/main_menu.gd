# tesana:custom-main-menu
extends Control
## LIMINAL — main menu with solo + co-op lobby.
## This file opts OUT of the engine's menu provisioner (marker on line 1) so
## our ENTER button and multiplayer flow are never overwritten.

const GAME_WORLD_PATH: String = "res://scenes/game_world.tscn"

const BG_PATH: String = "res://assets/textures/backgrounds/menu_void_corridor.png"
const WORDMARK_PATH: String = "res://assets/ui/wordmark_title.png"
const THEME_PATH: String = "res://assets/ui/theme.tres"
const FONT_PATH: String = "res://assets/fonts/special_elite.ttf"
const BTN_STYLE: String = "res://assets/ui/btn_main.tres"
const MUSIC_PATH: String = "res://assets/audio/music/music_exploration_liminal_dread_theme.mp3"

const DIM_YELLOW: Color = Color(0.72, 0.66, 0.42)

var _font: Font = null
var _btn_style: StyleBox = null
var _wordmark: TextureRect = null

var _main_col: VBoxContainer = null
var _mp_col: VBoxContainer = null
var _options: Control = null
var _status: Label = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if ResourceLoader.exists(THEME_PATH):
		theme = load(THEME_PATH)
	if ResourceLoader.exists(FONT_PATH):
		_font = load(FONT_PATH)
	if ResourceLoader.exists(BTN_STYLE):
		_btn_style = load(BTN_STYLE)

	_build_backdrop()
	_build_wordmark()
	_build_main_column()
	_build_mp_column()
	_start_audio()
	_start_wordmark_flicker()

	# Ensure a clean network slate whenever we return to the menu.
	if has_node("/root/NetManager"):
		NetManager.disconnect_from_room()


# ---------------------------------------------------------------------------
func _build_backdrop() -> void:
	var bg := TextureRect.new()
	bg.name = "Background"
	if ResourceLoader.exists(BG_PATH):
		bg.texture = load(BG_PATH)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.modulate = Color(0.8, 0.8, 0.8)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.38)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build_wordmark() -> void:
	_wordmark = TextureRect.new()
	_wordmark.name = "Wordmark"
	if ResourceLoader.exists(WORDMARK_PATH):
		_wordmark.texture = load(WORDMARK_PATH)
	_wordmark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_wordmark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_wordmark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_wordmark)
	_wordmark.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_wordmark.offset_left = -320.0
	_wordmark.offset_right = 320.0
	_wordmark.offset_top = 70.0
	_wordmark.offset_bottom = 290.0

	# Clean menu: the wordmark speaks for itself — no tagline.


func _make_art_button(label: String, w: float = 288.0) -> Button:
	# Uses the kit button art with baked chrome; label drawn on top in font.
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(w, 84)
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	if _btn_style:
		for st in ["normal", "hover", "pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(st, _btn_style)
	if _font:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", Color(0.93, 0.88, 0.66))
	b.add_theme_color_override("font_hover_color", Color(1, 0.97, 0.8))
	b.mouse_entered.connect(func(): b.modulate = Color(1.08, 1.08, 1.08))
	b.mouse_exited.connect(func(): b.modulate = Color(1, 1, 1))
	return b


func _column() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 16)
	add_child(vb)
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.offset_left = -240.0
	vb.offset_right = 240.0
	vb.offset_top = 30.0
	vb.offset_bottom = 330.0
	return vb


func _build_main_column() -> void:
	_main_col = _column()

	var solo := _make_art_button("ENTER")
	solo.pressed.connect(_on_play_solo)
	_main_col.add_child(solo)

	var coop := _make_art_button("CO-OP")
	coop.pressed.connect(_on_show_mp)
	_main_col.add_child(coop)

	var options := _make_art_button("OPTIONS")
	options.pressed.connect(_on_show_options)
	_main_col.add_child(options)


func _build_mp_column() -> void:
	_mp_col = _column()
	_mp_col.visible = false

	# Host row: pick how many descend together — the room starts when full,
	# so the host must choose the real group size (2, 3 or 4).
	var host_label := Label.new()
	host_label.text = "HOST"
	host_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	host_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host_label.add_theme_color_override("font_color", DIM_YELLOW)
	host_label.add_theme_font_size_override("font_size", 18)
	if _font:
		host_label.add_theme_font_override("font", _font)
	_mp_col.add_child(host_label)

	var host_row := HBoxContainer.new()
	host_row.alignment = BoxContainer.ALIGNMENT_CENTER
	host_row.add_theme_constant_override("separation", 8)
	_mp_col.add_child(host_row)
	for n in [2, 3, 4]:
		var host_btn := _make_art_button(str(n), 108.0)
		host_btn.pressed.connect(_on_host.bind(n))
		host_row.add_child(host_btn)

	var join_row := HBoxContainer.new()
	join_row.alignment = BoxContainer.ALIGNMENT_CENTER
	join_row.add_theme_constant_override("separation", 8)
	_mp_col.add_child(join_row)

	var code_input := LineEdit.new()
	code_input.name = "CodeInput"
	code_input.placeholder_text = "CODE"
	code_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_input.max_length = 8
	code_input.custom_minimum_size = Vector2(150, 60)
	if _font:
		code_input.add_theme_font_override("font", _font)
	code_input.add_theme_font_size_override("font_size", 26)
	join_row.add_child(code_input)

	var join := _make_art_button("JOIN", 160.0)
	join.pressed.connect(_on_join.bind(code_input))
	join_row.add_child(join)

	_status = Label.new()
	_status.name = "Status"
	_status.text = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(460, 60)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.add_theme_color_override("font_color", DIM_YELLOW)
	_status.add_theme_font_size_override("font_size", 18)
	if _font:
		_status.add_theme_font_override("font", _font)
	_mp_col.add_child(_status)

	var back := _make_art_button("BACK", 160.0)
	back.pressed.connect(_on_mp_back)
	_mp_col.add_child(back)


# ---------------------------------------------------------------------------
# Solo
# ---------------------------------------------------------------------------
func _on_play_solo() -> void:
	if has_node("/root/NetManager"):
		NetManager.is_multiplayer = false
	_start_game()


# ---------------------------------------------------------------------------
# Multiplayer
# ---------------------------------------------------------------------------
func _on_show_mp() -> void:
	if not has_node("/root/NetManager"):
		if _status:
			_status.text = "Online play is unavailable right now — you can still enter alone."
		return
	_main_col.visible = false
	_mp_col.visible = true


func _on_show_options() -> void:
	if _options == null:
		_options = load("res://scripts/ui/options_panel.gd").new()
		add_child(_options)
		_options.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_options.closed.connect(func():
			_options.visible = false
			_main_col.visible = true)
	_main_col.visible = false
	_options.visible = true


func _on_mp_back() -> void:
	if has_node("/root/NetManager"):
		NetManager.disconnect_from_room()
	_mp_col.visible = false
	_main_col.visible = true


func _on_host(player_count: int) -> void:
	if not has_node("/root/NetManager"):
		return
	NetManager.is_multiplayer = true
	_connect_lobby_signals()
	NetManager.create_room(player_count)
	_set_status("Creating a room for " + str(player_count) + "…")


func _connect_lobby_signals() -> void:
	if not NetManager.room_created.is_connected(_on_room_created):
		NetManager.room_created.connect(_on_room_created)
	if not NetManager.player_joined.is_connected(_on_player_joined):
		NetManager.player_joined.connect(_on_player_joined)
	if not NetManager.room_error.is_connected(_on_room_error):
		NetManager.room_error.connect(_on_room_error)
	if not NetManager.all_players_joined.is_connected(_start_game):
		NetManager.all_players_joined.connect(_start_game, CONNECT_ONE_SHOT)


func _on_room_error(reason: String) -> void:
	NetManager.disconnect_from_room()
	_set_status(reason + "\nTry again — or descend alone.")


func _on_room_created(code: String) -> void:
	_set_status("Room code:  " + code + "\nWaiting for friends… (starts when the room is full)")


func _on_player_joined(_pid: int, total: int) -> void:
	if total < NetManager.max_players:
		_set_status("Room code:  " + NetManager.room_code + "\n" + str(total) + " / " + str(NetManager.max_players) + " here… waiting for the rest.")
	else:
		_set_status("Everyone's in. Descending…")


func _on_join(code_input: LineEdit) -> void:
	if not has_node("/root/NetManager"):
		return
	var code := code_input.text.strip_edges().to_upper()
	if code.length() < 3:
		_set_status("Enter the room code your friend gave you.")
		return
	NetManager.is_multiplayer = true
	NetManager.is_host = false
	_connect_lobby_signals()
	NetManager.connect_to_room(code)
	_set_status("Joining room " + code + "…")


func _set_status(t: String) -> void:
	if is_instance_valid(_status):
		_status.text = t


# ---------------------------------------------------------------------------
func _start_game() -> void:
	if has_node("/root/LoadingScreen"):
		var ls := get_node("/root/LoadingScreen")
		if ls.has_method("preload_and_change_scene"):
			ls.preload_and_change_scene(GAME_WORLD_PATH, 1.8)
			return
	get_tree().change_scene_to_file(GAME_WORLD_PATH)


func _start_audio() -> void:
	if has_node("/root/AudioManager") and ResourceLoader.exists(MUSIC_PATH):
		var am := get_node("/root/AudioManager")
		if am.has_method("play_music"):
			am.play_music(load(MUSIC_PATH), -8.0, 2.0)


func _start_wordmark_flicker() -> void:
	if not is_instance_valid(_wordmark):
		return
	var tw := _wordmark.create_tween()
	tw.set_loops()
	tw.set_trans(Tween.TRANS_SINE)
	tw.set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_wordmark, "modulate:a", 0.75, 2.4)
	tw.tween_property(_wordmark, "modulate:a", 1.0, 2.4)
