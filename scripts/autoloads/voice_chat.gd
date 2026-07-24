extends Node
## Lightweight relay voice chat for co-op.
##
## The microphone is captured locally, downsampled to 12 kHz mono PCM16 and
## sent in small JSON/base64 packets through the existing room WebSocket.
## Received streams are played from AudioStreamPlayer3D nodes parented to the
## corresponding remote survivors, so walls/distance keep the voices spatial.

const CAPTURE_BUS := "VoiceCapture"
const SAMPLE_RATE := 12000.0
const PACKET_SECONDS := 0.04
const MAX_PACKET_BYTES := 4096
const VOICE_MAX_DISTANCE := 18.0
const ALWAYS_SPEAK_THRESHOLD := 0.008

var _capture_player: AudioStreamPlayer = null
var _capture_effect: AudioEffectCapture = null
var _send_accumulator := 0.0
var _voice_hangover := 0.0
var _speakers: Dictionary = {}       # player id -> AudioStreamPlayer3D
var _playbacks: Dictionary = {}      # player id -> AudioStreamGeneratorPlayback


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_capture()
	if has_node("/root/NetManager") \
			and not NetManager.message_received.is_connected(_on_net_message):
		NetManager.message_received.connect(_on_net_message)


func _setup_capture() -> void:
	var bus_index := AudioServer.get_bus_index(CAPTURE_BUS)
	if bus_index < 0:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, CAPTURE_BUS)
		AudioServer.set_bus_send(bus_index, "Master")
	while AudioServer.get_bus_effect_count(bus_index) > 0:
		AudioServer.remove_bus_effect(bus_index, 0)
	_capture_effect = AudioEffectCapture.new()
	_capture_effect.buffer_length = 0.25
	AudioServer.add_bus_effect(bus_index, _capture_effect, 0)
	# The capture effect still receives the signal while the bus output itself is
	# muted, preventing the local microphone from feeding back through speakers.
	AudioServer.set_bus_mute(bus_index, true)

func _process(delta: float) -> void:
	if not is_instance_valid(_capture_effect):
		return
	var voice_mode := int(Settings.voice_mode) if has_node("/root/Settings") else 0
	var active := has_node("/root/NetManager") and NetManager.is_multiplayer \
		and voice_mode != 2
	if active:
		_ensure_capture_player()
	elif is_instance_valid(_capture_player) and _capture_player.playing:
		_capture_player.stop()
	var available := _capture_effect.get_frames_available()
	if available <= 0:
		return
	if not active:
		_capture_effect.get_buffer(available)
		return
	_send_accumulator += delta
	if _send_accumulator < PACKET_SECONDS:
		return
	_send_accumulator = 0.0
	var source := _capture_effect.get_buffer(available)
	if source.is_empty() or not has_node("/root/NetManager") \
			or not NetManager.is_multiplayer:
		return

	var push_to_talk := voice_mode == 0
	if push_to_talk and not Input.is_action_pressed("voice_ptt"):
		return

	var mix_rate := maxf(AudioServer.get_mix_rate(), SAMPLE_RATE)
	var stride := maxi(1, int(round(mix_rate / SAMPLE_RATE)))
	var wanted_source_frames := int(mix_rate * PACKET_SECONDS)
	var start := maxi(0, source.size() - wanted_source_frames)
	var sample_count := int(ceil(float(source.size() - start) / float(stride)))
	if sample_count <= 0:
		return
	var packet := PackedByteArray()
	packet.resize(sample_count * 2)
	var rms_sum := 0.0
	var packet_index := 0
	for source_index in range(start, source.size(), stride):
		var frame: Vector2 = source[source_index]
		var mono := clampf((frame.x + frame.y) * 0.5, -1.0, 1.0)
		rms_sum += mono * mono
		packet.encode_s16(packet_index * 2, int(round(mono * 32767.0)))
		packet_index += 1
	packet.resize(packet_index * 2)
	if packet.is_empty() or packet.size() > MAX_PACKET_BYTES:
		return

	var rms := sqrt(rms_sum / maxf(float(packet_index), 1.0))
	if voice_mode == 1:
		if rms >= ALWAYS_SPEAK_THRESHOLD:
			_voice_hangover = 0.24
		else:
			_voice_hangover = maxf(0.0, _voice_hangover - delta)
			if _voice_hangover <= 0.0:
				return
	NetManager.send("voice", {"pcm": Marshalls.raw_to_base64(packet)})


func _ensure_capture_player() -> void:
	if not is_instance_valid(_capture_player):
		_capture_player = AudioStreamPlayer.new()
		_capture_player.name = "MicrophoneCapture"
		_capture_player.bus = CAPTURE_BUS
		_capture_player.stream = AudioStreamMicrophone.new()
		add_child(_capture_player)
	if not _capture_player.playing:
		_capture_player.play()


func register_remote_player(player_id: int, body: Node3D) -> void:
	unregister_remote_player(player_id)
	if not is_instance_valid(body):
		return
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = SAMPLE_RATE
	generator.buffer_length = 0.25
	var speaker := AudioStreamPlayer3D.new()
	speaker.name = "ProximityVoice_%d" % player_id
	speaker.stream = generator
	speaker.bus = "SFX"
	speaker.max_distance = VOICE_MAX_DISTANCE
	speaker.unit_size = 2.5
	speaker.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	body.add_child(speaker)
	speaker.play()
	var playback := speaker.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		speaker.queue_free()
		return
	_speakers[player_id] = speaker
	_playbacks[player_id] = playback


func unregister_remote_player(player_id: int) -> void:
	var speaker = _speakers.get(player_id)
	if is_instance_valid(speaker):
		speaker.queue_free()
	_speakers.erase(player_id)
	_playbacks.erase(player_id)


func clear_remote_players() -> void:
	for raw_id in _speakers.keys():
		unregister_remote_player(int(raw_id))


func _on_net_message(type: String, msg: Dictionary, from_player: int) -> void:
	if type != "voice" or from_player < 0 \
			or from_player == NetManager.local_player_id:
		return
	var playback = _playbacks.get(from_player) as AudioStreamGeneratorPlayback
	if playback == null:
		return
	var encoded := String(msg.get("pcm", ""))
	if encoded.is_empty() or encoded.length() > MAX_PACKET_BYTES * 2:
		return
	var packet := Marshalls.base64_to_raw(encoded)
	if packet.is_empty() or packet.size() > MAX_PACKET_BYTES \
			or packet.size() % 2 != 0:
		return
	var frames_available := playback.get_frames_available()
	var frame_count := mini(packet.size() / 2, frames_available)
	for index in frame_count:
		var mono := float(packet.decode_s16(index * 2)) / 32767.0
		playback.push_frame(Vector2(mono, mono))
