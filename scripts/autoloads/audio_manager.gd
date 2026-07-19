extends Node
## Central audio: music bed, pooled SFX, and positional 3D one-shots.
## Web-safe (STREAM playback, autoplay-gated). Never invent another audio system.

const MAX_SFX: int = 10

var music_player: AudioStreamPlayer
var sfx_players: Array[AudioStreamPlayer] = []
var heartbeat_player: AudioStreamPlayer

var _unlocked: bool = false
var _pending_music: AudioStream = null
var _pending_music_vol: float = -6.0
var _pending_music_fade: float = 0.0

var _heartbeat_state := "silent"
var _heartbeat_tween: Tween

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.has_feature("web"):
		_unlocked = true
	_setup_buses()
	_create_players()
	_setup_limiter()

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
		
	# Setup heartbeat player
	heartbeat_player = AudioStreamPlayer.new()
	heartbeat_player.name = "HeartbeatPlayer"
	heartbeat_player.bus = "SFX"
	heartbeat_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	var hb_stream := load("res://assets/audio/sfx/player/heartbeat.wav") as AudioStreamWAV
	if hb_stream != null:
		hb_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		heartbeat_player.stream = hb_stream
	add_child(heartbeat_player)
	heartbeat_player.volume_db = -40.0

func play_music(stream: AudioStream, volume_db: float = -6.0, fade_in: float = 0.0) -> void:
	if stream == null:
		return
	if not _unlocked:
		_pending_music = stream
		_pending_music_vol = volume_db
		_pending_music_fade = fade_in
		return
	_play_music_now(stream, volume_db, fade_in)


func _play_music_now(stream: AudioStream, volume_db: float, fade_in: float = 0.0) -> void:
	if music_player == null:
		return
	if music_player.playing and music_player.stream == stream:
		return
		
	music_player.stream = stream
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
		
	if fade_in > 0.0:
		music_player.volume_db = -40.0
		music_player.play()
		var tw := create_tween()
		tw.tween_property(music_player, "volume_db", volume_db, fade_in)
	else:
		music_player.volume_db = volume_db
		music_player.play()

func fade_out_music(dur: float = 1.5) -> void:
	if music_player and music_player.playing:
		var tw := create_tween()
		tw.tween_property(music_player, "volume_db", -40.0, dur)
		tw.tween_callback(music_player.stop)

func stop_music() -> void:
	if music_player:
		music_player.stop()

func stop_all_sounds() -> void:
	stop_music()
	for p in sfx_players:
		if is_instance_valid(p):
			p.stop()
	# Kill heartbeat
	if is_instance_valid(heartbeat_player):
		heartbeat_player.stop()
		heartbeat_player.volume_db = -40.0
	_heartbeat_state = "silent"
	if _heartbeat_tween:
		_heartbeat_tween.kill()
		_heartbeat_tween = null
	if Engine.get_main_loop() is SceneTree:
		var tree := Engine.get_main_loop() as SceneTree
		if tree.root:
			_stop_players_recursive(tree.root)

func _stop_players_recursive(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer3D or node is AudioStreamPlayer2D:
		if node != music_player and not sfx_players.has(node) and node != heartbeat_player:
			node.stop()
			node.queue_free()
	for child in node.get_children():
		_stop_players_recursive(child)

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


func _setup_limiter() -> void:
	var master_idx := AudioServer.get_bus_index("Master")
	if master_idx >= 0:
		# Check if a limiter or compressor is already present
		var has_limiter := false
		for i in range(AudioServer.get_bus_effect_count(master_idx)):
			if AudioServer.get_bus_effect(master_idx, i) is AudioEffectLimiter:
				has_limiter = true
				break
		if not has_limiter:
			var limiter := AudioEffectLimiter.new()
			limiter.ceiling_db = -0.5
			limiter.threshold_db = -2.0
			limiter.soft_clip_db = 1.0
			AudioServer.add_bus_effect(master_idx, limiter)


func set_heartbeat_state(state: String) -> void:
	if _heartbeat_state == state:
		return
	_heartbeat_state = state
	
	if not is_instance_valid(heartbeat_player):
		return
		
	if _heartbeat_tween:
		_heartbeat_tween.kill()
	_heartbeat_tween = create_tween()
	_heartbeat_tween.set_parallel(true)
	
	match state:
		"silent":
			# Decelerate pitch scale back to normal (1.0) and fade volume gradually over 3.5s
			_heartbeat_tween.tween_property(heartbeat_player, "pitch_scale", 1.0, 3.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			_heartbeat_tween.tween_property(heartbeat_player, "volume_db", -40.0, 3.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			_heartbeat_tween.chain().tween_callback(heartbeat_player.stop)
		"peek":
			# Elevated heart rate (1.25x speed, warm volume)
			if not heartbeat_player.playing:
				heartbeat_player.volume_db = -40.0
				heartbeat_player.pitch_scale = 1.25
				heartbeat_player.play()
			_heartbeat_tween.tween_property(heartbeat_player, "volume_db", -2.0, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_heartbeat_tween.tween_property(heartbeat_player, "pitch_scale", 1.25, 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		"chase":
			# Intense adrenaline panic heart rate (1.55x speed, loud volume)
			if not heartbeat_player.playing:
				heartbeat_player.volume_db = -40.0
				heartbeat_player.pitch_scale = 1.55
				heartbeat_player.play()
			_heartbeat_tween.tween_property(heartbeat_player, "volume_db", 4.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_heartbeat_tween.tween_property(heartbeat_player, "pitch_scale", 1.55, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
