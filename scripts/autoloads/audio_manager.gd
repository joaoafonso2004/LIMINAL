extends Node
## Central audio: music bed, pooled SFX, and positional 3D one-shots.
## Web-safe (STREAM playback, autoplay-gated). Never invent another audio system.

const MAX_SFX: int = 10

var music_player: AudioStreamPlayer
var sfx_players: Array[AudioStreamPlayer] = []

var _unlocked: bool = false
var _pending_music: AudioStream = null
var _pending_music_vol: float = -6.0
var _pending_music_fade: float = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.has_feature("web"):
		_unlocked = true
	_setup_buses()
	_create_players()

func _input(event: InputEvent) -> void:
	if _unlocked:
		return
	if event is InputEventMouseButton or event is InputEventKey or event is InputEventScreenTouch:
		_unlocked = true
		if _pending_music:
			_play_music_now(_pending_music, _pending_music_vol, _pending_music_fade)
			_pending_music = null

func _setup_buses() -> void:
	for bus_name in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")

func _create_players() -> void:
	music_player = AudioStreamPlayer.new()
	music_player.bus = "Music"
	music_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	add_child(music_player)
	for i in MAX_SFX:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		p.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		add_child(p)
		sfx_players.append(p)

func play_music(stream: AudioStream, volume_db: float = -6.0, fade_in: float = 0.0) -> void:
	return

func _play_music_now(stream: AudioStream, volume_db: float, fade_in: float = 0.0) -> void:
	return

func fade_out_music(dur: float = 1.5) -> void:
	if music_player and music_player.playing:
		var tw := create_tween()
		tw.tween_property(music_player, "volume_db", -40.0, dur)
		tw.tween_callback(music_player.stop)

func stop_music() -> void:
	if music_player:
		music_player.stop()

func set_music_volume(volume_db: float, dur: float = 0.5) -> void:
	if music_player:
		create_tween().tween_property(music_player, "volume_db", volume_db, dur)

func play_sfx(stream: AudioStream, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if stream == null:
		return
	for p in sfx_players:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = pitch
			p.play()
			return

## Spawn a transient positional 3D one-shot at a world point under `parent`.
func play_sfx_3d(parent: Node, stream: AudioStream, world_pos: Vector3, volume_db: float = 0.0, max_dist: float = 40.0, pitch: float = 1.0) -> void:
	if stream == null or not is_instance_valid(parent):
		return
	var p := AudioStreamPlayer3D.new()
	p.bus = "SFX"
	p.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	p.stream = stream
	p.volume_db = volume_db
	p.max_distance = max_dist
	p.unit_size = 6.0
	p.pitch_scale = pitch
	parent.add_child(p)
	p.global_position = world_pos
	p.play()
	p.finished.connect(p.queue_free)
