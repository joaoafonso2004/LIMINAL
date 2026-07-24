extends Node3D
## Interactive Retro CRT TV & VHS Cassette Player setup.
##
## Placed inside one of the rare Anchor Rooms. When the player collects the VHS
## Tape in the maze, they can approach the TV cabinet and press [E] to insert
## the tape. The TV turns on, streams video (.ogv format) onto the 3D screen,
## casts flickering CRT light into the room, and plays audio through 3D spatial
## sound. Fully synchronized in multiplayer!

signal vhs_state_changed(is_playing: bool)

const VIDEO_PATH_CUSTOM := "res://assets/video/vhs_tape.ogv"
const VIDEO_PATH_FALLBACK := "res://assets/video/END.ogv"
const SFX_INSERT_PATH := "res://assets/audio/sfx/environment/environment_tv_static_5s.ogg"

var _tv_screen_mesh: MeshInstance3D
var _tv_light: OmniLight3D
var _viewport: SubViewport
var _video_player: VideoStreamPlayer
var _is_playing := false
var _has_valid_stream := false
var _screen_material: StandardMaterial3D

func _ready() -> void:
	_build_tv_setup()

func _build_tv_setup() -> void:
	# 1. Base TV Cabinet/Table
	var cabinet := MeshInstance3D.new()
	var cab_mesh := BoxMesh.new()
	cab_mesh.size = Vector3(1.1, 0.75, 0.7)
	cabinet.mesh = cab_mesh
	var cab_mat := StandardMaterial3D.new()
	cab_mat.albedo_color = Color(0.2, 0.14, 0.09)
	cab_mat.roughness = 0.88
	cabinet.material_override = cab_mat
	cabinet.position = Vector3(0.0, 0.375, 0.0)
	add_child(cabinet)

	# 2. CRT TV Outer Shell Box
	var tv_box := MeshInstance3D.new()
	var tv_mesh := BoxMesh.new()
	tv_mesh.size = Vector3(0.75, 0.6, 0.55)
	tv_box.mesh = tv_mesh
	var tv_mat := StandardMaterial3D.new()
	tv_mat.albedo_color = Color(0.12, 0.12, 0.14)
	tv_mat.roughness = 0.65
	tv_box.material_override = tv_mat
	tv_box.position = Vector3(0.0, 1.05, 0.0)
	add_child(tv_box)

	# 3. VHS Deck Player Box (under the TV)
	var vhs_deck := MeshInstance3D.new()
	var deck_mesh := BoxMesh.new()
	deck_mesh.size = Vector3(0.68, 0.12, 0.45)
	vhs_deck.mesh = deck_mesh
	var deck_mat := StandardMaterial3D.new()
	deck_mat.albedo_color = Color(0.06, 0.06, 0.07)
	deck_mat.roughness = 0.5
	vhs_deck.material_override = deck_mat
	vhs_deck.position = Vector3(0.0, 0.81, 0.05)
	add_child(vhs_deck)

	# 4. VHS Slot Glow / LED Indicator
	var vhs_led := MeshInstance3D.new()
	var led_mesh := BoxMesh.new()
	led_mesh.size = Vector3(0.04, 0.04, 0.01)
	vhs_led.mesh = led_mesh
	var led_mat := StandardMaterial3D.new()
	led_mat.albedo_color = Color(0.1, 0.9, 0.2)
	led_mat.emission_enabled = true
	led_mat.emission = Color(0.1, 0.9, 0.2)
	led_mat.emission_energy_multiplier = 2.0
	vhs_led.material_override = led_mat
	vhs_led.position = Vector3(0.26, 0.81, 0.28)
	add_child(vhs_led)

	# 5. SubViewport for Video Stream Rendering
	_viewport = SubViewport.new()
	_viewport.name = "TVViewport"
	_viewport.size = Vector2i(640, 480)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	# 6. VideoStreamPlayer inside SubViewport
	_video_player = VideoStreamPlayer.new()
	_video_player.name = "VideoStream"
	_video_player.size = Vector2(640, 480)
	_video_player.expand = true
	_video_player.loop = true
	_viewport.add_child(_video_player)

	var target_stream_path := ""
	if ResourceLoader.exists(VIDEO_PATH_CUSTOM):
		target_stream_path = VIDEO_PATH_CUSTOM
	elif ResourceLoader.exists(VIDEO_PATH_FALLBACK):
		target_stream_path = VIDEO_PATH_FALLBACK

	if target_stream_path != "":
		var st := load(target_stream_path)
		if st is VideoStream:
			_video_player.stream = st
			_has_valid_stream = true

	# 7. CRT TV Glass Screen Mesh (Front facing +Z)
	_tv_screen_mesh = MeshInstance3D.new()
	var screen_quad := QuadMesh.new()
	screen_quad.size = Vector2(0.62, 0.46)
	_tv_screen_mesh.mesh = screen_quad
	_tv_screen_mesh.position = Vector3(0.0, 1.05, 0.28)
	add_child(_tv_screen_mesh)

	_screen_material = StandardMaterial3D.new()
	_screen_material.albedo_color = Color(0.02, 0.03, 0.04)
	_screen_material.roughness = 0.1
	_tv_screen_mesh.material_override = _screen_material

	# 8. CRT Lighting (casts screen glow into the anchor room)
	_tv_light = OmniLight3D.new()
	_tv_light.light_color = Color(0.3, 0.6, 1.0)
	_tv_light.omni_range = 9.0
	_tv_light.light_energy = 0.0
	_tv_light.position = Vector3(0.0, 1.05, 0.5)
	_tv_light.shadow_enabled = true
	add_child(_tv_light)

func _process(delta: float) -> void:
	if _is_playing and is_instance_valid(_tv_light):
		var t := Time.get_ticks_msec() / 1000.0
		var flicker := (sin(t * 8.0) * 0.3 + sin(t * 19.0) * 0.2 + 0.5) * 0.8 + 0.6
		_tv_light.light_energy = 2.4 * flicker

func can_interact(player_pos: Vector3) -> bool:
	return global_position.distance_to(player_pos) <= 3.2

func get_interact_prompt() -> String:
	if _is_playing:
		return "EJECT VHS TAPE"
	if has_node("/root/GameManager") and GameManager.cassette_found:
		return "INSERT VHS TAPE INTO PLAYER"
	return "VHS PLAYER (REQUIRES VHS TAPE)"

func interact() -> void:
	if _is_playing:
		set_playing(false)
		if has_node("/root/NetManager") and NetManager.is_multiplayer:
			NetManager.send("vhs_tv", {"play": false})
	else:
		if has_node("/root/GameManager") and GameManager.cassette_found:
			set_playing(true)
			if has_node("/root/NetManager") and NetManager.is_multiplayer:
				NetManager.send("vhs_tv", {"play": true})

func set_playing(play: bool) -> void:
	if _is_playing == play:
		return
	_is_playing = play
	vhs_state_changed.emit(play)

	if play:
		if is_instance_valid(_video_player) and _has_valid_stream:
			_video_player.play()
		var tex := _viewport.get_texture()
		_screen_material.albedo_texture = tex
		_screen_material.emission_enabled = true
		_screen_material.emission_texture = tex
		_screen_material.emission_energy_multiplier = 2.8
		if is_instance_valid(_tv_light):
			_tv_light.light_energy = 2.4
		if has_node("/root/AudioManager") and ResourceLoader.exists(SFX_INSERT_PATH):
			AudioManager.play_sfx_3d(self, load(SFX_INSERT_PATH), global_position, -2.0, 15.0)
	else:
		if is_instance_valid(_video_player):
			_video_player.stop()
		_screen_material.albedo_texture = null
		_screen_material.emission_enabled = false
		_screen_material.albedo_color = Color(0.02, 0.03, 0.04)
		if is_instance_valid(_tv_light):
			_tv_light.light_energy = 0.0
