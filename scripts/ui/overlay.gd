extends CanvasLayer
## Old-TV post-processing overlay for LIMINAL.
##
## A self-contained CanvasLayer whose fullscreen rect samples the rendered
## frame and replays it through a dying CRT: barrel curvature, chromatic
## aberration, scanlines + interlace, TV snow, VHS tracking tears, a rolling
## band, and a heavy vignette. `dread` (0..1) and `pulse` drive how sick the
## signal gets. Also owns the fade rect and ending text. No .tscn.

const FONT_PATH := "res://assets/fonts/special_elite.ttf"
const SHADER_PATH := "res://assets/shaders/post_crt_old_tv.gdshader"

# --- Node refs ---
var _fx: ColorRect
var _fade: ColorRect
var _ending: Label
var _jumpscare: TextureRect
var _mat: ShaderMaterial

# --- Dread state (target + current, smoothly approached) ---
var _dread_target := 0.0
var _dread_cur := 0.0

# --- Transient pulse: glitch spike that decays over time ---
var _pulse := 0.0


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS

	# --- FX overlay rect ---
	_fx = ColorRect.new()
	_fx.name = "FX"
	_fx.color = Color(0, 0, 0, 0)   # invisible unless the CRT shader drives it
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fx)
	_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if ResourceLoader.exists(SHADER_PATH):
		_mat = ShaderMaterial.new()
		_mat.shader = load(SHADER_PATH)
		_fx.material = _mat
	else:
		push_warning("overlay: missing " + SHADER_PATH + " — running without the CRT filter")

	# --- Fade rect (fade-to-black / white) ---
	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = Color(0, 0, 0, 0)
	add_child(_fade)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# --- Jumpscare texture overlay ---
	_jumpscare = TextureRect.new()
	_jumpscare.name = "Jumpscare"
	_jumpscare.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_jumpscare.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_jumpscare.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_jumpscare.visible = false
	add_child(_jumpscare)
	_jumpscare.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


var _chase_vignette: ColorRect = null
var _chase_vignette_active := false

func setup_chase_vignette() -> void:
	if _chase_vignette != null:
		return
	_chase_vignette = ColorRect.new()
	_chase_vignette.name = "ChaseVignette"
	_chase_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chase_vignette.color = Color(0.8, 0.0, 0.0, 0.0)
	add_child(_chase_vignette)
	_chase_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_chase_vignette(active: bool) -> void:
	_chase_vignette_active = active
	if not active and is_instance_valid(_chase_vignette):
		_chase_vignette.color.a = 0.0

	# --- Ending text label ---
	_ending = Label.new()
	_ending.name = "EndingText"
	_ending.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ending.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ending.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_ending.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ending.add_theme_font_size_override("font_size", 40)
	var font := _load_font()
	if font != null:
		_ending.add_theme_font_override("font", font)
	_ending.visible = false
	_ending.modulate = Color(1, 1, 1, 0)
	add_child(_ending)
	_ending.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Give the text some breathing room from the edges.
	_ending.offset_left = 80.0
	_ending.offset_right = -80.0

	# Seed initial shader params.
	_apply_shader_params()


func _load_font() -> FontFile:
	if ResourceLoader.exists(FONT_PATH):
		var f := load(FONT_PATH)
		if f is FontFile:
			return f
	return null


func _process(delta: float) -> void:
	# Smoothly approach the dread target; decay the transient pulse (~0.8s).
	_dread_cur = lerpf(_dread_cur, clampf(_dread_target, 0.0, 1.0), clampf(delta * 3.0, 0.0, 1.0))
	if _pulse > 0.0:
		_pulse = maxf(0.0, _pulse - delta / 0.8)

	if _chase_vignette_active:
		if _chase_vignette == null:
			setup_chase_vignette()
		var t := Time.get_ticks_msec() / 1000.0
		var pulse_a := (sin(t * 12.0) * 0.5 + 0.5) * 0.25 + 0.08
		_chase_vignette.color = Color(0.8, 0.02, 0.02, pulse_a)
	elif is_instance_valid(_chase_vignette):
		_chase_vignette.color.a = lerpf(_chase_vignette.color.a, 0.0, 6.0 * delta)

	_apply_shader_params()


func _apply_shader_params() -> void:
	if _mat == null:
		return
	if "crt_filter" in Settings and not Settings.crt_filter:
		_fx.material = null
	else:
		_fx.material = _mat
		_mat.set_shader_parameter("dread", clampf(_dread_cur, 0.0, 1.0))
		_mat.set_shader_parameter("pulse", clampf(_pulse, 0.0, 1.0))


# --- Public API ---

## Set the dread level (0..1). Shader intensity smoothly approaches this.
func set_dread(v: float) -> void:
	_dread_target = clampf(v, 0.0, 1.0)


## Briefly glitch the signal (tear + snow + aberration); decays over ~0.8s.
func pulse(strength: float = 1.0) -> void:
	_pulse = minf(_pulse + maxf(strength, 0.0) * 0.6, 1.0)


## Tween the Fade rect (rgb + alpha) to `color` over `dur` seconds.
func fade_to(color: Color, dur: float) -> void:
	if not is_instance_valid(_fade):
		return
	var tw := create_tween()
	tw.tween_property(_fade, "color", color, maxf(dur, 0.0))


## Instantly set Fade to `color`, then fade its alpha to 0 over `dur`.
func flash(color: Color, dur: float) -> void:
	if not is_instance_valid(_fade):
		return
	_fade.color = color
	var target := Color(color.r, color.g, color.b, 0.0)
	var tw := create_tween()
	tw.tween_property(_fade, "color", target, maxf(dur, 0.01))


## Fade to `bg`, then reveal ending text in `text_color`.
func show_ending(text: String, bg: Color, text_color: Color = Color(0.85, 0.8, 0.62)) -> void:
	if not is_instance_valid(_fade) or not is_instance_valid(_ending):
		return
	var bg_full := Color(bg.r, bg.g, bg.b, 1.0)
	var tw := create_tween()
	tw.tween_property(_fade, "color", bg_full, 2.5)
	await tw.finished

	if not is_instance_valid(_ending):
		return
	_ending.text = text
	_ending.add_theme_color_override("font_color", text_color)
	_ending.modulate = Color(1, 1, 1, 0)
	_ending.visible = true
	var tw2 := create_tween()
	tw2.tween_property(_ending, "modulate:a", 1.0, 2.0)


## Hide the ending text and fade the Fade rect back to transparent.
func clear_ending() -> void:
	if is_instance_valid(_ending):
		var tw := create_tween()
		tw.tween_property(_ending, "modulate:a", 0.0, 0.5)
		tw.tween_callback(func():
			if is_instance_valid(_ending):
				_ending.visible = false)
	if is_instance_valid(_fade):
		var tw2 := create_tween()
		var clear_col := Color(_fade.color.r, _fade.color.g, _fade.color.b, 0.0)
		tw2.tween_property(_fade, "color", clear_col, 1.0)


func trigger_jumpscare() -> void:
	if not is_instance_valid(_jumpscare):
		return
	var img_path := "res://assets/characters/jumpscare.png"
	if ResourceLoader.exists(img_path):
		_jumpscare.texture = load(img_path)
	
	var vp_size := get_viewport().get_visible_rect().size
	_jumpscare.pivot_offset = vp_size / 2.0
	
	_jumpscare.scale = Vector2(0.7, 0.7)
	_jumpscare.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_jumpscare.visible = true
	_jumpscare.position = Vector2.ZERO
	
	# Trigger a massive VHS aberration signal glitch
	pulse(3.5)
	
	# Play a loud scream
	if has_node("/root/AudioManager"):
		var scream_path := "res://assets/audio/sfx/enemy/enemy_jumpscare_scream.mp3"
		if ResourceLoader.exists(scream_path):
			var scream_stream := load(scream_path) as AudioStream
			AudioManager.play_sfx(scream_stream, 6.0, 1.1)
	
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_jumpscare, "scale", Vector2(1.3, 1.3), 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_jumpscare, "modulate", Color(1.3, 0.1, 0.1, 1.0), 0.2)
	
	# Violent high-frequency shake
	var shake_tw := create_tween()
	shake_tw.set_loops(12)
	var shake_offset := 35.0
	shake_tw.tween_property(_jumpscare, "position", Vector2(randf_range(-shake_offset, shake_offset), randf_range(-shake_offset, shake_offset)), 0.05)
	
	# Settle after shaking — image stays on screen, tinted red until death menu covers it
	var tw2 := create_tween()
	tw2.tween_interval(0.7)
	tw2.tween_property(_jumpscare, "position", Vector2.ZERO, 0.15)
	tw2.tween_property(_jumpscare, "modulate", Color(0.6, 0.0, 0.0, 1.0), 0.5)

