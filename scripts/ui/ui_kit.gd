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
