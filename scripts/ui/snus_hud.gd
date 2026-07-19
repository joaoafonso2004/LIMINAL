extends CanvasLayer
## Minimal, mood-respecting snus counter. LIMINAL has no HUD, so this stays
## invisible and only fades in for a few seconds when the count changes or the
## exit opens — a whispered progress note, not a persistent overlay.

const FONT_PATH := "res://assets/fonts/special_elite.ttf"
const DIM := Color(0.72, 0.66, 0.42)

var _label: Label = null
var _fade_tween: Tween = null


func _ready() -> void:
	layer = 8
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", DIM)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("outline_size", 6)
	_label.add_theme_font_size_override("font_size", 26)
	if ResourceLoader.exists(FONT_PATH):
		_label.add_theme_font_override("font", load(FONT_PATH))
	root.add_child(_label)
	_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_label.offset_top = -110.0
	_label.offset_bottom = -60.0
	_label.modulate = Color(1, 1, 1, 0)


func set_count(collected: int, total: int) -> void:
	if not is_instance_valid(_label):
		return
	if collected >= total:
		return  # announce_exit handles the final beat
	_label.text = "snus  " + str(collected) + " / " + str(total)
	_flash(3.0)


func announce_exit() -> void:
	if not is_instance_valid(_label):
		return
	_label.text = "All found.  A way out has opened somewhere deep."
	_flash(6.0)


func show_phone_hint(dir_text: String, dist_m: int, hold: float = 8.0) -> void:
	if not is_instance_valid(_label):
		return
	_label.text = "TELEPHONE SIGNAL: NEAREST SNUS IS %d METERS %s" % [dist_m, dir_text]
	_flash(hold)


func _flash(hold: float) -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_label.modulate.a = 0.0
	_fade_tween = create_tween()
	_fade_tween.tween_property(_label, "modulate:a", 1.0, 0.6)
	_fade_tween.tween_interval(hold)
	_fade_tween.tween_property(_label, "modulate:a", 0.0, 1.4)
