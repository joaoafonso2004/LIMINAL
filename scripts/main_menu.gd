# tesana:custom-main-menu
extends Control
## LIMINAL — main menu with solo + co-op lobby.
## This file opts OUT of the engine's menu provisioner (marker on line 1) so
## our ENTER button and multiplayer flow are never overwritten.

const GAME_WORLD_PATH: String = "res://scenes/game_world.tscn"

const BG_PATH: String = "res://assets/textures/backgrounds/menu_backrooms_blurred.png"
const MUSIC_PATH: String = "res://assets/audio/ambient/ambient.mp3"

const PAPER := Color(0.88, 0.86, 0.75, 1.0)
const MUTED := Color(0.52, 0.52, 0.46, 1.0)
const WALL_YELLOW := Color(0.78, 0.70, 0.48, 1.0)

var _font: Font = null
var _font_heavy: Font = null
var _default_focus: Button = null

var _main_col: VBoxContainer = null
var _mp_col: VBoxContainer = null
var _options: Control = null
var _status: Label = null
var _rules_preset: OptionButton = null
var _modifier_menu: MenuButton = null
var _custom_rules: Dictionary = {}


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_font = UIKit.utilitarian_font(350)
	_font_heavy = UIKit.utilitarian_font(800)

	_build_backdrop()
	_build_identity()
	_build_main_column()
	_build_mp_column()
	_start_audio()
	if is_instance_valid(_default_focus):
		_default_focus.grab_focus.call_deferred()

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
	bg.modulate = Color(0.84, 0.82, 0.74)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var scrim := ColorRect.new()
	scrim.color = Color(0.015, 0.016, 0.014, 0.24)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _build_identity() -> void:
	var title := Label.new()
	title.text = "LIMINAL"
	title.position = Vector2(66, 64)
	title.size = Vector2(390, 82)
	title.add_theme_font_override("font", _font_heavy)
	title.add_theme_font_size_override("font_size", 62)
	title.add_theme_color_override("font_color", WALL_YELLOW)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)

	var author := Label.new()
	author.text = "JOÃO AFONSO"
	author.anchor_top = 1.0
	author.anchor_bottom = 1.0
	author.offset_left = 70.0
	author.offset_right = 430.0
	author.offset_top = -74.0
	author.offset_bottom = -46.0
	author.add_theme_font_override("font", _font)
	author.add_theme_font_size_override("font_size", 13)
	author.add_theme_color_override("font_color", WALL_YELLOW.darkened(0.18))
	author.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(author)


func _make_art_button(label: String, w: float = 370.0) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(w, 58)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	UIKit.style_brutalist_button(b, 20)
	_style_main_menu_button(b)
	return b


func _menu_button_box(fill: Color, left_width: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = WALL_YELLOW
	box.border_width_left = left_width
	box.content_margin_left = 22.0
	box.content_margin_right = 18.0
	box.content_margin_top = 11.0
	box.content_margin_bottom = 11.0
	return box


func _style_main_menu_button(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _menu_button_box(Color.TRANSPARENT, 1))
	button.add_theme_stylebox_override("hover", _menu_button_box(WALL_YELLOW, 6))
	button.add_theme_stylebox_override("focus", _menu_button_box(WALL_YELLOW, 6))
	button.add_theme_stylebox_override("pressed", _menu_button_box(WALL_YELLOW, 6))
	button.add_theme_color_override("font_color", PAPER)
	button.add_theme_color_override("font_hover_color", Color(0.04, 0.04, 0.025))
	button.add_theme_color_override("font_focus_color", Color(0.04, 0.04, 0.025))
	button.add_theme_color_override("font_pressed_color", Color(0.04, 0.04, 0.025))


func _column() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_BEGIN
	vb.add_theme_constant_override("separation", 8)
	add_child(vb)
	vb.anchor_left = 0.0
	vb.anchor_top = 0.0
	vb.offset_left = 70.0
	vb.offset_right = 450.0
	vb.offset_top = 322.0
	vb.offset_bottom = 850.0
	return vb


func _build_main_column() -> void:
	_main_col = _column()

	var solo := _make_art_button("PLAY")
	solo.pressed.connect(_on_play_solo)
	_main_col.add_child(solo)
	_default_focus = solo

	var coop := _make_art_button("CO-OP")
	coop.pressed.connect(_on_show_mp)
	_main_col.add_child(coop)

	var options := _make_art_button("SETTINGS")
	options.pressed.connect(_on_show_options)
	_main_col.add_child(options)

	var quit := _make_art_button("QUIT")
	quit.pressed.connect(get_tree().quit)
	_main_col.add_child(quit)


func _build_mp_column() -> void:
	_mp_col = _column()
	_mp_col.visible = false
	_mp_col.offset_top = 244.0
	_mp_col.offset_bottom = 900.0
	_mp_col.add_theme_constant_override("separation", 8)
	_custom_rules = NetManager.default_rules() if has_node("/root/NetManager") else {}

	var rules_row := HBoxContainer.new()
	rules_row.alignment = BoxContainer.ALIGNMENT_CENTER
	rules_row.add_theme_constant_override("separation", 8)
	_mp_col.add_child(rules_row)
	_rules_preset = OptionButton.new()
	_rules_preset.custom_minimum_size = Vector2(181, 48)
	_rules_preset.add_item("NORMAL")
	_rules_preset.add_item("NIGHTMARE")
	_rules_preset.add_item("CUSTOM")
	_rules_preset.item_selected.connect(_on_rules_preset_selected)
	UIKit.style_brutalist_button(_rules_preset, 15)
	rules_row.add_child(_rules_preset)
	_modifier_menu = MenuButton.new()
	_modifier_menu.text = "MODIFIERS"
	_modifier_menu.custom_minimum_size = Vector2(181, 48)
	UIKit.style_brutalist_button(_modifier_menu, 15)
	rules_row.add_child(_modifier_menu)
	var popup := _modifier_menu.get_popup()
	for entry in [[0, "NO LOCKERS"], [1, "ONE LIFE"], [2, "SPAWN TOGETHER"], [3, "NO MIMIC"], [4, "NO SPRINT"], [5, "DARKER"]]:
		popup.add_check_item(entry[1], entry[0])
	popup.id_pressed.connect(_on_modifier_pressed)

	# Host row: pick how many descend together — the room starts when full,
	# so the host must choose the real group size (2, 3 or 4).
	var host_label := Label.new()
	host_label.text = "HOST"
	host_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	host_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host_label.add_theme_color_override("font_color", MUTED)
	host_label.add_theme_font_size_override("font_size", 13)
	if _font:
		host_label.add_theme_font_override("font", _font)
	_mp_col.add_child(host_label)

	var host_row := HBoxContainer.new()
	host_row.alignment = BoxContainer.ALIGNMENT_CENTER
	host_row.add_theme_constant_override("separation", 8)
	_mp_col.add_child(host_row)
	for n in [2, 3, 4]:
		var host_btn := _make_art_button(str(n), 118.0)
		host_btn.custom_minimum_size.y = 48.0
		host_btn.pressed.connect(_on_host.bind(n))
		host_row.add_child(host_btn)

	var join_row := HBoxContainer.new()
	join_row.alignment = BoxContainer.ALIGNMENT_CENTER
	join_row.add_theme_constant_override("separation", 8)
	_mp_col.add_child(join_row)

	var code_input := LineEdit.new()
	code_input.name = "CodeInput"
	code_input.placeholder_text = "CODE"
	code_input.alignment = HORIZONTAL_ALIGNMENT_LEFT
	code_input.max_length = 8
	code_input.custom_minimum_size = Vector2(174, 52)
	UIKit.style_brutalist_input(code_input, 19)
	join_row.add_child(code_input)

	var join := _make_art_button("JOIN", 188.0)
	join.custom_minimum_size.y = 52.0
	join.pressed.connect(_on_join.bind(code_input))
	join_row.add_child(join)

	_status = Label.new()
	_status.name = "Status"
	_status.text = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(460, 48)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.add_theme_color_override("font_color", PAPER)
	_status.add_theme_font_size_override("font_size", 15)
	if _font:
		_status.add_theme_font_override("font", _font)
	_mp_col.add_child(_status)

	var back := _make_art_button("BACK", 160.0)
	back.custom_minimum_size.y = 48.0
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
			_main_col.visible = true
			if is_instance_valid(_default_focus):
				_default_focus.grab_focus())
	_main_col.visible = false
	_options.visible = true


func _on_mp_back() -> void:
	if has_node("/root/NetManager"):
		NetManager.disconnect_from_room()
	_mp_col.visible = false
	_main_col.visible = true
	if is_instance_valid(_default_focus):
		_default_focus.grab_focus()


func _on_host(player_count: int) -> void:
	if not has_node("/root/NetManager"):
		return
	NetManager.is_multiplayer = true
	NetManager.configure_rules(_selected_rules())
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
	if not NetManager.all_players_joined.is_connected(_on_all_players_joined):
		NetManager.all_players_joined.connect(_on_all_players_joined, CONNECT_ONE_SHOT)


func _on_room_error(reason: String) -> void:
	NetManager.disconnect_from_room()
	_set_status(reason + "\nTry again — or descend alone.")


func _on_room_created(code: String) -> void:
	_set_status("Room code:  " + code + "\nWaiting for friends… (starts when the room is full)\nPlayers: 1 / " + str(NetManager.max_players))


func _on_player_joined(pid: int, total: int) -> void:
	if NetManager.is_host:
		if total > 1:
			_set_status("Room code:  " + NetManager.room_code + "\n[!] A new player joined the session!\nTotal players in session: " + str(total) + " / " + str(NetManager.max_players))
			# Play a nice pickup notification chime!
			if has_node("/root/AudioManager"):
				var chime = load("res://assets/audio/sfx/pickup/pickup_snus_pickup.mp3")
				AudioManager.play_sfx(chime, 0.0, 1.2)
		else:
			_set_status("Room code:  " + NetManager.room_code + "\nWaiting for friends… (starts when the room is full)\nTotal players: 1 / " + str(NetManager.max_players))
	else:
		_set_status("Joined room:  " + NetManager.room_code + "\nConnected to session! Total players: " + str(total) + " / " + str(NetManager.max_players))
		if has_node("/root/AudioManager"):
			var chime = load("res://assets/audio/sfx/pickup/pickup_snus_pickup.mp3")
			AudioManager.play_sfx(chime, -2.0, 1.0)


func _on_all_players_joined() -> void:
	_set_status("Everyone's in! Descending into the Backrooms…")
	if NetManager.is_host:
		NetManager.send("rules", {"rules": NetManager.run_rules})
	get_tree().create_timer(1.2).timeout.connect(_start_game)

func _on_rules_preset_selected(index: int) -> void:
	_custom_rules = NetManager.default_rules()
	if index == 1:
		_custom_rules["preset"] = "nightmare"
		_custom_rules["entity_speed"] = 1.14
		_custom_rules["darkness"] = 1.25
		_custom_rules["phone_traps"] = 0.55
		_custom_rules["revive_seconds"] = 22.0
	_update_modifier_checks()

func _on_modifier_pressed(id: int) -> void:
	if _custom_rules.is_empty():
		_custom_rules = NetManager.default_rules()
	match id:
		0: _custom_rules["lockers"] = not bool(_custom_rules.get("lockers", true))
		1: _custom_rules["one_life"] = not bool(_custom_rules.get("one_life", false))
		2: _custom_rules["separated_spawns"] = not bool(_custom_rules.get("separated_spawns", true))
		3: _custom_rules["mimic"] = not bool(_custom_rules.get("mimic", true))
		4: _custom_rules["sprint"] = not bool(_custom_rules.get("sprint", true))
		5: _custom_rules["darkness"] = 1.0 if float(_custom_rules.get("darkness", 1.0)) > 1.0 else 1.35
	_custom_rules["preset"] = "custom"
	_rules_preset.select(2)
	_update_modifier_checks()

func _update_modifier_checks() -> void:
	if not is_instance_valid(_modifier_menu):
		return
	var popup := _modifier_menu.get_popup()
	popup.set_item_checked(popup.get_item_index(0), not bool(_custom_rules.get("lockers", true)))
	popup.set_item_checked(popup.get_item_index(1), bool(_custom_rules.get("one_life", false)))
	popup.set_item_checked(popup.get_item_index(2), not bool(_custom_rules.get("separated_spawns", true)))
	popup.set_item_checked(popup.get_item_index(3), not bool(_custom_rules.get("mimic", true)))
	popup.set_item_checked(popup.get_item_index(4), not bool(_custom_rules.get("sprint", true)))
	popup.set_item_checked(popup.get_item_index(5), float(_custom_rules.get("darkness", 1.0)) > 1.0)

func _selected_rules() -> Dictionary:
	return _custom_rules.duplicate(true) if not _custom_rules.is_empty() else NetManager.default_rules()


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
