extends CanvasLayer
## LIMINAL — CX30 victim-only jumpscare video.
##
## The client the Entity catches replaces its own first-person view with
## `jumpscare.ogv`. Nothing here is replicated: the teammate never builds this
## layer and keeps watching the full paired 3D execution in-world.
##
## The clip (~3.29 s) is shorter than the 3D sequence (~5.48 s at 1.55x), so the
## layer holds a black screen once the video reports `finished` and only gives
## the screen back when GameWorld releases it, already inside `downed`.

const VIDEO_PATH := "res://assets/video/jumpscare.ogv"
## Above every HUD CanvasLayer (overlay 10, downed 30, revive 31, spectator 40)
## and still below the death menu (100), which must stay clickable.
const CANVAS_LAYER := 90
## jumpscare.ogv is 1440x1080. Used until the stream reports its real size.
const FALLBACK_ASPECT := 4.0 / 3.0
## Pure black before the first frame, so the cut away from the 3D camera never
## shows a single rendered frame of the Entity.
const BLACK_FLASH_SECONDS := 0.10
const REVEAL_SECONDS := 0.07
const VOLUME_DB := -3.0

signal clip_finished()

var _backdrop: ColorRect = null
var _video: VideoStreamPlayer = null
var _started := false
var _released := false
var _video_aspect := FALLBACK_ASPECT
var _layout_size := Vector2.ZERO
var _reveal_tween: Tween = null
var _release_tween: Tween = null


func _ready() -> void:
	layer = CANVAS_LAYER
	# The pause menu must freeze the clip together with the 3D sequence running
	# underneath it, so this layer deliberately inherits the tree pause mode.
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = Color(0.0, 0.0, 0.0, 1.0)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)


## Build and start the clip. Returns false when the asset is missing or the
## decoder refuses it; the caller then keeps the identical black-screen timing
## rather than leaving the player stuck or suddenly back in the world.
func start() -> bool:
	if _started:
		return is_instance_valid(_video)
	_started = true
	set_process(true)
	if not ResourceLoader.exists(VIDEO_PATH):
		push_warning("jumpscare_video: missing " + VIDEO_PATH + " — holding black")
		return false
	var stream := load(VIDEO_PATH)
	if stream == null:
		push_warning("jumpscare_video: could not load " + VIDEO_PATH + " — holding black")
		return false

	_video = VideoStreamPlayer.new()
	_video.name = "Clip"
	_video.stream = stream
	# The rect built by _layout_video already carries the clip's aspect ratio,
	# so expanding into it scales without ever stretching the picture.
	_video.expand = true
	_ensure_jumpscare_bus()
	_video.bus = "Jumpscare"
	_video.volume_db = VOLUME_DB
	_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_video.modulate.a = 0.0
	add_child(_video)
	_layout_video(true)
	_video.finished.connect(_on_clip_finished)
	
	# Mute all in-game audio buses (Music, SFX, 3D world sounds) during the jumpscare video
	_mute_game_buses(true)
	_video.play()

	# The embedded audio starts under the black flash; the picture is revealed
	# a few frames later, which is what hides the camera hand-off.
	_reveal_tween = create_tween()
	_reveal_tween.tween_interval(BLACK_FLASH_SECONDS)
	_reveal_tween.tween_property(_video, "modulate:a", 1.0, REVEAL_SECONDS)
	return true


func _process(_delta: float) -> void:
	if _released or not is_instance_valid(_video):
		return
	# The stream only reports its real size once a frame has been decoded. The
	# 4:3 fallback keeps the very first frames correctly proportioned meanwhile.
	var texture := _video.get_video_texture()
	if texture != null:
		var texture_size := Vector2(texture.get_size())
		if texture_size.x > 0.0 and texture_size.y > 0.0:
			var aspect := texture_size.x / texture_size.y
			if not is_equal_approx(aspect, _video_aspect):
				_video_aspect = aspect
				_layout_video(true)
	_layout_video()


## Fit the clip inside the viewport with black bars instead of deforming it.
func _layout_video(force: bool = false) -> void:
	if not is_instance_valid(_video):
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if not force and viewport_size.is_equal_approx(_layout_size):
		return
	_layout_size = viewport_size
	var target := Vector2(viewport_size.y * _video_aspect, viewport_size.y)
	if target.x > viewport_size.x:
		target = Vector2(viewport_size.x, viewport_size.x / _video_aspect)
	_video.size = target
	_video.position = (viewport_size - target) * 0.5


func _on_clip_finished() -> void:
	# The 3D execution outlasts the clip. Hiding the player leaves the black
	# backdrop up instead of revealing the Entity still eating underneath.
	if is_instance_valid(_video):
		_video.visible = false
	set_process(false)
	clip_finished.emit()


## True while the layer still owns the screen.
func is_holding() -> bool:
	return not _released


## Fade the black away and free the layer. Idempotent; `0.0` removes it on the
## spot, which is how singleplayer hands over to the existing ending screen.
func release(fade_seconds: float = 0.5) -> void:
	if _released:
		return
	_released = true
	set_process(false)
	_kill_tween(_reveal_tween)
	_reveal_tween = null
	_mute_game_buses(false)
	if is_instance_valid(_video):
		_video.stop()
		_video.visible = false
	if fade_seconds <= 0.0 or not is_instance_valid(_backdrop):
		queue_free()
		return
	_release_tween = create_tween()
	_release_tween.tween_property(_backdrop, "color:a", 0.0, fade_seconds)
	_release_tween.tween_callback(queue_free)


func _kill_tween(tween: Tween) -> void:
	if is_instance_valid(tween) and tween.is_running():
		tween.kill()


func _ensure_jumpscare_bus() -> void:
	if AudioServer.get_bus_index("Jumpscare") == -1:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, "Jumpscare")
		AudioServer.set_bus_send(idx, "Master")


func _mute_game_buses(mute: bool) -> void:
	if mute:
		for b in range(AudioServer.bus_count):
			var bname := AudioServer.get_bus_name(b)
			if bname != "Master" and bname != "Jumpscare":
				AudioServer.set_bus_mute(b, true)
	else:
		if has_node("/root/Settings"):
			get_node("/root/Settings").apply_all()
		else:
			for b in range(AudioServer.bus_count):
				var bname := AudioServer.get_bus_name(b)
				if bname != "Master" and bname != "Jumpscare":
					AudioServer.set_bus_mute(b, false)


func _exit_tree() -> void:
	_kill_tween(_reveal_tween)
	_kill_tween(_release_tween)
	_reveal_tween = null
	_release_tween = null
	_mute_game_buses(false)
	if is_instance_valid(_video):
		_video.stop()
