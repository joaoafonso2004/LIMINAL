extends CanvasLayer
## Old-TV post-processing overlay for LIMINAL.
##
## A self-contained CanvasLayer whose fullscreen rect samples the rendered
## frame and replays it through a dying CRT: barrel curvature, chromatic
## aberration, scanlines + interlace, TV snow, VHS tracking tears, a rolling
## band, and a heavy vignette. `dread` (0..1) and `pulse` drive how sick the
## signal gets. Also owns the fade rect and ending text. No .tscn.

signal chase_vignette_changed(active: bool)

const FONT_PATH := "res://assets/fonts/special_elite.ttf"
const VCR_FONT_PATH := "res://assets/fonts/vcr_osd_mono.ttf"
const SHADER_PATH := "res://assets/shaders/post_crt_old_tv.gdshader"
const TV_STATIC_SHADER_PATH := "res://assets/shaders/tv_static.gdshader"
const TV_STATIC_AUDIO_PATH := "res://assets/audio/sfx/environment/tv_static_5s.ogg"
const VCR_START_DATETIME := {
	"year": 2004, "month": 1, "day": 2,
	"hour": 18, "minute": 0, "second": 0,
}
const VCR_MONTHS := [
	"JAN.", "FEB.", "MAR.", "APR.", "MAY.", "JUN.",
	"JUL.", "AUG.", "SEP.", "OCT.", "NOV.", "DEC.",
]

# --- Node refs ---
var _fx: ColorRect
var _fade: ColorRect
var _ending: Label
var _jumpscare: TextureRect
var _mat: ShaderMaterial
var _vcr_timestamp: Label
var _twitch_hiss: AudioStreamPlayer
var _jumpscare_tweens: Array[Tween] = []

# --- Dread state (target + current, smoothly approached) ---
var _dread_target := 0.0
var _dread_cur := 0.0

# --- Transient pulse: glitch spike that decays over time ---
var _pulse := 0.0
var _twitch_timer := 0.0
var _next_twitch := 0.0
var _twitch_offset := 0.0
var _vcr_elapsed_seconds := 0.0
var _vcr_update_accumulator := 0.0
var _lens_focus_blur := 0.0


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_next_twitch = randf_range(18.0, 42.0)

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

	# Camcorder timestamp: every run starts on the same recovered tape.
	_vcr_timestamp = Label.new()
	_vcr_timestamp.name = "VCRTimestamp"
	_vcr_timestamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_vcr_timestamp.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_vcr_timestamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vcr_timestamp.add_theme_font_size_override("font_size", 30)
	_vcr_timestamp.add_theme_color_override(
		"font_color", Color(0.94, 0.94, 0.87, 0.88))
	_vcr_timestamp.add_theme_color_override(
		"font_shadow_color", Color(0, 0, 0, 0.9))
	_vcr_timestamp.add_theme_color_override(
		"font_outline_color", Color(0.02, 0.02, 0.015, 0.9))
	_vcr_timestamp.add_theme_constant_override("shadow_offset_x", 2)
	_vcr_timestamp.add_theme_constant_override("shadow_offset_y", 2)
	_vcr_timestamp.add_theme_constant_override("outline_size", 2)
	if ResourceLoader.exists(VCR_FONT_PATH):
		var vcr_font := load(VCR_FONT_PATH) as Font
		if vcr_font != null:
			_vcr_timestamp.add_theme_font_override("font", vcr_font)
	else:
		push_warning("overlay: missing VCR timestamp font " + VCR_FONT_PATH)
	add_child(_vcr_timestamp)
	# Reference placement: ~10% from the left and ~12% above the lower edge.
	# Anchors keep that composition identical across 16:9 and 4:3 resolutions.
	_vcr_timestamp.anchor_left = 0.10
	_vcr_timestamp.anchor_right = 0.10
	_vcr_timestamp.anchor_top = 0.88
	_vcr_timestamp.anchor_bottom = 0.88
	_vcr_timestamp.offset_left = 0.0
	_vcr_timestamp.offset_right = 360.0
	_vcr_timestamp.offset_top = -94.0
	_vcr_timestamp.offset_bottom = 0.0
	_update_vcr_timestamp()

	_twitch_hiss = AudioStreamPlayer.new()
	_twitch_hiss.name = "SignalTwitchHiss"
	_twitch_hiss.bus = "SFX"
	_twitch_hiss.volume_db = -24.0
	if ResourceLoader.exists(TV_STATIC_AUDIO_PATH):
		_twitch_hiss.stream = load(TV_STATIC_AUDIO_PATH)
	add_child(_twitch_hiss)

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

	# --- Ending text label ---
	# This belongs to the overlay lifetime.  It used to be created from
	# set_chase_vignette(), which duplicated the label whenever chase state
	# changed and left ending screens unavailable until the first chase.
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
	_ending.offset_left = 80.0
	_ending.offset_right = -80.0

	_apply_shader_params()


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
	var changed := _chase_vignette_active != active
	_chase_vignette_active = active
	if not active and is_instance_valid(_chase_vignette):
		_chase_vignette.color.a = 0.0
	if changed:
		chase_vignette_changed.emit(active)


func _load_font() -> FontFile:
	if ResourceLoader.exists(FONT_PATH):
		var f := load(FONT_PATH)
		if f is FontFile:
			return f
	return null


func _process(delta: float) -> void:
	_vcr_elapsed_seconds += delta
	_vcr_update_accumulator += delta
	if _vcr_update_accumulator >= 1.0:
		_vcr_update_accumulator = fmod(_vcr_update_accumulator, 1.0)
		_update_vcr_timestamp()
	# Smoothly approach the dread target; decay the transient pulse (~0.8s).
	_dread_cur = lerpf(_dread_cur, clampf(_dread_target, 0.0, 1.0), clampf(delta * 3.0, 0.0, 1.0))
	if _pulse > 0.0:
		_pulse = maxf(0.0, _pulse - delta / 0.8)
	if _twitch_timer > 0.0:
		_twitch_timer = maxf(0.0, _twitch_timer - delta)
		_twitch_offset = sin(Time.get_ticks_msec() * 0.31) * 0.003
		if _twitch_timer <= 0.0:
			_twitch_offset = 0.0
			if is_instance_valid(_twitch_hiss):
				_twitch_hiss.stop()
	_next_twitch -= delta
	if _next_twitch <= 0.0:
		if not ("crt_filter" in Settings) or Settings.crt_filter:
			trigger_signal_twitch(randf_range(0.28, 0.52), randf_range(0.055, 0.11))
		_next_twitch = randf_range(18.0, 42.0) \
			* lerpf(1.0, 0.55, clampf(_dread_cur, 0.0, 1.0))

	if _chase_vignette_active:
		if _chase_vignette == null:
			setup_chase_vignette()
		var t := Time.get_ticks_msec() / 1000.0
		var pulse_a := (sin(t * 12.0) * 0.5 + 0.5) * 0.25 + 0.08
		_chase_vignette.color = Color(0.8, 0.02, 0.02, pulse_a)
	elif is_instance_valid(_chase_vignette):
		_chase_vignette.color.a = lerpf(_chase_vignette.color.a, 0.0, 6.0 * delta)

	_apply_shader_params()


func _update_vcr_timestamp() -> void:
	if not is_instance_valid(_vcr_timestamp):
		return
	var start_unix := Time.get_unix_time_from_datetime_dict(VCR_START_DATETIME)
	var recorded := Time.get_datetime_dict_from_unix_time(
		start_unix + floori(_vcr_elapsed_seconds))
	var month_index := clampi(int(recorded["month"]) - 1, 0, 11)
	_vcr_timestamp.text = "%02d:%02d\n%s %02d %04d" % [
		int(recorded["hour"]),
		int(recorded["minute"]),
		VCR_MONTHS[month_index],
		int(recorded["day"]),
		int(recorded["year"]),
	]


func _apply_shader_params() -> void:
	if _mat == null:
		return
	if "crt_filter" in Settings and not Settings.crt_filter:
		if _fx.material != null:
			_fx.material = null
	else:
		if _fx.material != _mat:
			_fx.material = _mat
		_mat.set_shader_parameter("dread", clampf(_dread_cur, 0.0, 1.0))
		_mat.set_shader_parameter("pulse", clampf(_pulse, 0.0, 1.0))
		_mat.set_shader_parameter("twitch", _twitch_offset)
		_mat.set_shader_parameter("focus_blur", _lens_focus_blur)


# --- Public API ---

## Set the dread level (0..1). Shader intensity smoothly approaches this.
func set_dread(v: float) -> void:
	_dread_target = clampf(v, 0.0, 1.0)


## Optical defocus supplied by the local player's physical zoom motor.
func set_lens_focus_blur(amount: float) -> void:
	_lens_focus_blur = clampf(amount, 0.0, 1.0)


## Briefly glitch the signal (tear + snow + aberration); decays over ~0.8s.
func pulse(strength: float = 1.0) -> void:
	_pulse = minf(_pulse + maxf(strength, 0.0) * 0.6, 1.0)


## Brief horizontal tape-head loss with a restrained static tick. It reuses the
## non-pixelating CRT shader and never changes the render resolution.
func trigger_signal_twitch(strength: float = 0.55, duration: float = 0.09) -> void:
	if _twitch_timer > 0.0:
		return
	_twitch_timer = clampf(duration, 0.04, 0.16)
	pulse(clampf(strength, 0.0, 1.0))
	if is_instance_valid(_twitch_hiss) and _twitch_hiss.stream != null:
		_twitch_hiss.volume_db = lerpf(
			-28.0, -19.0, clampf(strength, 0.0, 1.0))
		_twitch_hiss.play(randf_range(0.0, 2.5))


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


## Replace the entire signal with analogue snow for an exact duration. This is
## deliberately a separate full-strength effect rather than an exaggerated
## dread pulse, so gameplay CRT tuning remains untouched.
func play_tv_static(duration: float = 5.0) -> void:
	var static_rect := ColorRect.new()
	static_rect.name = "TVStatic"
	static_rect.color = Color.WHITE
	static_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(TV_STATIC_SHADER_PATH):
		var static_material := ShaderMaterial.new()
		static_material.shader = load(TV_STATIC_SHADER_PATH)
		static_rect.material = static_material
	add_child(static_rect)
	static_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var hiss := AudioStreamPlayer.new()
	if ResourceLoader.exists(TV_STATIC_AUDIO_PATH):
		hiss.stream = load(TV_STATIC_AUDIO_PATH)
		hiss.bus = "SFX"
		hiss.volume_db = -6.0
		add_child(hiss)
		hiss.play()

	await get_tree().create_timer(maxf(duration, 0.0)).timeout
	if is_instance_valid(hiss):
		hiss.stop()
		hiss.queue_free()
	if is_instance_valid(static_rect):
		static_rect.queue_free()


func trigger_jumpscare(auto_hide_after: float = 3.0) -> void:
	if not is_instance_valid(_jumpscare):
		return
	_kill_jumpscare_tweens()
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
	_jumpscare_tweens.append(tw)
	tw.set_parallel(true)
	tw.tween_property(_jumpscare, "scale", Vector2(1.3, 1.3), 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_jumpscare, "modulate", Color(1.3, 0.1, 0.1, 1.0), 0.2)
	
	# Violent high-frequency shake
	var shake_tw := create_tween()
	_jumpscare_tweens.append(shake_tw)
	shake_tw.set_loops(12)
	var shake_offset := 35.0
	shake_tw.tween_property(_jumpscare, "position", Vector2(randf_range(-shake_offset, shake_offset), randf_range(-shake_offset, shake_offset)), 0.05)
	
	# Settle after shaking — image stays on screen, tinted red until death menu covers it
	var tw2 := create_tween()
	_jumpscare_tweens.append(tw2)
	tw2.tween_interval(0.7)
	tw2.tween_property(_jumpscare, "position", Vector2.ZERO, 0.15)
	tw2.tween_property(_jumpscare, "modulate", Color(0.6, 0.0, 0.0, 1.0), 0.5)
	if auto_hide_after > 0.0:
		var hide_tw := create_tween()
		_jumpscare_tweens.append(hide_tw)
		var fade_duration := minf(0.25, auto_hide_after)
		hide_tw.tween_interval(maxf(0.0, auto_hide_after - fade_duration))
		hide_tw.tween_property(_jumpscare, "modulate:a", 0.0, fade_duration)
		hide_tw.tween_callback(func() -> void:
			if is_instance_valid(_jumpscare):
				_jumpscare.visible = false
				_jumpscare.position = Vector2.ZERO)


## Fade and hide the jumpscare when gameplay resumes after a revive.
func clear_jumpscare() -> void:
	if not is_instance_valid(_jumpscare):
		return
	_kill_jumpscare_tweens()
	if not _jumpscare.visible:
		return
	var tw := create_tween()
	_jumpscare_tweens.append(tw)
	tw.tween_property(_jumpscare, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func() -> void:
		if is_instance_valid(_jumpscare):
			_jumpscare.visible = false
			_jumpscare.position = Vector2.ZERO
		_jumpscare_tweens.clear())


func _kill_jumpscare_tweens() -> void:
	for tw in _jumpscare_tweens:
		if is_instance_valid(tw) and tw.is_running():
			tw.kill()
	_jumpscare_tweens.clear()
