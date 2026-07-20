class_name UIKit
## Shared code-built styling for LIMINAL's menus. The asset-kit button art has
## the word "ENTER" baked into the texture, so buttons are styled here as flat
## dark panels with a gold border instead — any label reads cleanly.

const GOLD := Color(0.62, 0.54, 0.32)
const GOLD_BRIGHT := Color(0.85, 0.76, 0.47)
const INK := Color(0.055, 0.05, 0.035, 0.92)
const INK_HOVER := Color(0.1, 0.09, 0.06, 0.95)
const INK_PRESSED := Color(0.03, 0.028, 0.02, 0.96)

const TEXT := Color(0.93, 0.88, 0.66)
const TEXT_HOVER := Color(1.0, 0.97, 0.8)

# Corporate Liminal Brutalism palette. These helpers deliberately live beside
# the legacy horror buttons so gameplay prompts are not restyled by a menu-only
# polish pass.
const CORP_INK := Color(0.025, 0.028, 0.025, 1.0)
const CORP_INK_RAISED := Color(0.055, 0.058, 0.052, 1.0)
const CORP_PAPER := Color(0.88, 0.86, 0.75, 1.0)
const CORP_MUTED := Color(0.52, 0.52, 0.46, 1.0)
const CORP_SIGNAL := Color(0.78, 0.70, 0.48, 1.0)


static func _box(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 24.0
	sb.content_margin_right = 24.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


static func style_button(b: Button, font: Font = null, font_size: int = 24) -> void:
	b.add_theme_stylebox_override("normal", _box(INK, GOLD))
	b.add_theme_stylebox_override("hover", _box(INK_HOVER, GOLD_BRIGHT))
	b.add_theme_stylebox_override("pressed", _box(INK_PRESSED, GOLD))
	b.add_theme_stylebox_override("focus", _box(INK, GOLD_BRIGHT))
	b.add_theme_stylebox_override("disabled", _box(Color(0.05, 0.05, 0.04, 0.6), Color(0.3, 0.28, 0.2)))
	if font:
		b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", TEXT_HOVER)
	b.add_theme_color_override("font_pressed_color", TEXT)
	b.add_theme_color_override("font_focus_color", TEXT)


static func utilitarian_font(weight: int = 400) -> SystemFont:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Inter", "Helvetica Neue", "Arial", "Segoe UI"])
	font.font_weight = weight
	font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return font


static func _hard_box(fill: Color, left_rule: Color, left_width: int = 2) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = left_rule
	box.border_width_left = left_width
	box.content_margin_left = 22.0
	box.content_margin_right = 18.0
	box.content_margin_top = 11.0
	box.content_margin_bottom = 11.0
	return box


static func style_brutalist_button(button: Button, font_size: int = 20) -> void:
	var regular := utilitarian_font(350)
	var heavy := utilitarian_font(800)
	button.flat = false
	button.focus_mode = Control.FOCUS_ALL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Secondary screens use clean blocks without decorative guide rules. The
	# main menu deliberately reapplies its own narrow navigation markers.
	button.add_theme_stylebox_override("normal", _hard_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	button.add_theme_stylebox_override("hover", _hard_box(CORP_SIGNAL, CORP_SIGNAL, 0))
	button.add_theme_stylebox_override("focus", _hard_box(CORP_SIGNAL, CORP_SIGNAL, 0))
	button.add_theme_stylebox_override("pressed", _hard_box(CORP_SIGNAL, CORP_SIGNAL, 0))
	button.add_theme_stylebox_override("disabled", _hard_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	button.add_theme_font_override("font", regular)
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_color_override("font_color", CORP_PAPER)
	button.add_theme_color_override("font_hover_color", CORP_INK)
	button.add_theme_color_override("font_focus_color", CORP_INK)
	button.add_theme_color_override("font_pressed_color", CORP_INK)
	button.add_theme_color_override("font_disabled_color", Color(0.28, 0.29, 0.26))
	button.mouse_entered.connect(func() -> void:
		button.add_theme_font_override("font", heavy))
	button.mouse_exited.connect(func() -> void:
		if not button.has_focus():
			button.add_theme_font_override("font", regular))
	button.focus_entered.connect(func() -> void:
		button.add_theme_font_override("font", heavy))
	button.focus_exited.connect(func() -> void:
		if not button.is_hovered():
			button.add_theme_font_override("font", regular))


static func style_brutalist_input(input: LineEdit, font_size: int = 19) -> void:
	var normal := _hard_box(CORP_INK_RAISED, CORP_MUTED, 2)
	var focus := _hard_box(CORP_INK, CORP_SIGNAL, 5)
	input.add_theme_stylebox_override("normal", normal)
	input.add_theme_stylebox_override("focus", focus)
	input.add_theme_font_override("font", utilitarian_font(600))
	input.add_theme_font_size_override("font_size", font_size)
	input.add_theme_color_override("font_color", CORP_PAPER)
	input.add_theme_color_override("font_placeholder_color", CORP_MUTED)
	input.add_theme_color_override("caret_color", CORP_SIGNAL)
	input.add_theme_color_override("selection_color", Color(CORP_SIGNAL, 0.48))


static func style_brutalist_slider(slider: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.18, 0.19, 0.17)
	track.content_margin_top = 2.0
	track.content_margin_bottom = 2.0
	var filled := StyleBoxFlat.new()
	filled.bg_color = CORP_SIGNAL
	filled.content_margin_top = 2.0
	filled.content_margin_bottom = 2.0
	var grabber := GradientTexture1D.new()
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([CORP_SIGNAL, CORP_SIGNAL])
	grabber.gradient = gradient
	grabber.width = 10
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_icon_override("grabber", grabber)
	slider.add_theme_icon_override("grabber_highlight", grabber)
