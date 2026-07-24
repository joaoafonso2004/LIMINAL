extends Node
class_name BreathingAudioController
## Exclusive breathing state machine for the local player.
##
## All four streams use the dedicated Breathing bus, so they share the exact
## same 65 Hz high-pass, 10 kHz low-pass and 6:1 compressor chain configured by
## AudioManager. Only a state transition starts a different stream. The active
## loop is restarted solely if it genuinely ended while its state still holds.

enum BreathingState {
	NORMAL,
	SPRINT,
	HEAVY,
	EXHAUSTED,
}

const STREAM_PATHS := [
	"res://assets/audio/sfx/player/breathing_normal.mp3",
	"res://assets/audio/sfx/player/breathing_running.mp3",
	"res://assets/audio/sfx/player/breathing_heavy.mp3",
	"res://assets/audio/sfx/player/breathing_exhausted.mp3",
]
const PLAYER_NAMES := [
	"BreathingNormal",
	"BreathingSprint",
	"BreathingHeavy",
	"BreathingExhausted",
]
# Non-destructive loudness matching. Measured source loudness is approximately
# -49.8 / -40.6 / -29.3 / -26.3 LUFS respectively; these trims place every
# state near -26.5 LUFS before the shared close-mic compressor.
const STATE_VOLUMES_DB := [
	23.3,
	14.1,
	2.8,
	-0.2,
]
const SILENCE_DB := -60.0
const STOP_THRESHOLD_DB := -58.0
const CROSSFADE_DB_PER_SECOND := 100.0
const SPRINT_RECOVERY_SECONDS := 4.0
const HEAVY_SHOCK_HOLD_SECONDS := 8.0

var _players: Array[AudioStreamPlayer] = []
var _state := -1
var _muted := false
var _is_sprinting_now := false
var _sprint_recovery_remaining := 0.0
var _heavy_shock_remaining := 0.0


func _ready() -> void:
	for state_index in BreathingState.size():
		_players.append(_create_player(
			STREAM_PATHS[state_index], PLAYER_NAMES[state_index]))
	_change_state(BreathingState.NORMAL)


func update_conditions(
		delta: float,
		is_sprinting: bool,
		stamina_exhausted: bool,
		is_being_chased: bool,
		red_effect_active: bool,
		muted: bool = false) -> void:
	_muted = muted
	_is_sprinting_now = is_sprinting
	if is_sprinting:
		_sprint_recovery_remaining = SPRINT_RECOVERY_SECONDS
	else:
		_sprint_recovery_remaining = maxf(
			0.0, _sprint_recovery_remaining - maxf(delta, 0.0))
	var immediate_danger := is_being_chased or red_effect_active
	if immediate_danger:
		_heavy_shock_remaining = HEAVY_SHOCK_HOLD_SECONDS
	else:
		_heavy_shock_remaining = maxf(
			0.0, _heavy_shock_remaining - maxf(delta, 0.0))
	var wanted_state := _resolve_state(
		is_sprinting, stamina_exhausted, immediate_danger)
	if wanted_state != _state:
		_change_state(wanted_state)
	_update_crossfade(delta)


func get_state() -> int:
	return _state


func get_state_name() -> String:
	match _state:
		BreathingState.SPRINT:
			return "SPRINT"
		BreathingState.HEAVY:
			return "HEAVY"
		BreathingState.EXHAUSTED:
			return "EXHAUSTED"
		_:
			return "NORMAL"


func get_player_for_state(state: int) -> AudioStreamPlayer:
	if state < 0 or state >= _players.size():
		return null
	return _players[state]


func get_heavy_shock_remaining() -> float:
	return _heavy_shock_remaining


func get_sprint_recovery_remaining() -> float:
	return _sprint_recovery_remaining


func _resolve_state(
		is_sprinting: bool,
		stamina_exhausted: bool,
		immediate_danger: bool) -> int:
	# Exhaustion is a latch owned by the sprint system: it can only become true
	# after stamina reaches zero and clears once stamina has recovered.
	if stamina_exhausted:
		return BreathingState.EXHAUSTED
	# Both danger inputs resolve to one state, so simultaneous chase + red effect
	# can never create, duplicate or restart a second heavy-breathing loop.
	if immediate_danger or _heavy_shock_remaining > 0.0:
		return BreathingState.HEAVY
	if is_sprinting or _sprint_recovery_remaining > 0.0:
		return BreathingState.SPRINT
	return BreathingState.NORMAL


func _change_state(next_state: int) -> void:
	if next_state == _state:
		return
	_state = next_state
	if _muted:
		return
	var incoming := get_player_for_state(_state)
	if is_instance_valid(incoming) and not incoming.playing:
		incoming.play()


func _update_crossfade(delta: float) -> void:
	var step := CROSSFADE_DB_PER_SECOND * maxf(delta, 0.0)
	for state_index in _players.size():
		var player := _players[state_index]
		if not is_instance_valid(player):
			continue
		var target_db := _target_volume_db(state_index)
		var is_active := target_db > STOP_THRESHOLD_DB and not _muted
		if is_active and not player.playing:
			# Covers a non-looping/failed stream ending while the same state
			# persists. This is the only per-frame path allowed to call play().
			player.play()
		player.volume_db = move_toward(player.volume_db, target_db, step)
		if not is_active and player.playing \
				and player.volume_db <= STOP_THRESHOLD_DB:
			player.stop()
			player.volume_db = SILENCE_DB


func _target_volume_db(state_index: int) -> float:
	if _muted:
		return SILENCE_DB
	if _state != BreathingState.SPRINT:
		return float(STATE_VOLUMES_DB[state_index]) \
			if state_index == _state else SILENCE_DB
	# During post-run recovery, crossfade continuously from the running breaths
	# back to normal. Restarting sprint reverses the blend without restarting
	# the still-playing SPRINT stream.
	var sprint_mix := 1.0 if _is_sprinting_now else clampf(
		_sprint_recovery_remaining / SPRINT_RECOVERY_SECONDS, 0.0, 1.0)
	var normal_mix := sqrt(maxf(0.0, 1.0 - sprint_mix * sprint_mix))
	if state_index == BreathingState.SPRINT:
		return float(STATE_VOLUMES_DB[state_index]) \
			+ linear_to_db(maxf(sprint_mix, 0.001))
	if state_index == BreathingState.NORMAL:
		return float(STATE_VOLUMES_DB[state_index]) \
			+ linear_to_db(maxf(normal_mix, 0.001))
	return SILENCE_DB


func _create_player(path: String, player_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.bus = "Breathing"
	player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	player.volume_db = SILENCE_DB
	if not ResourceLoader.exists(path):
		push_warning("breathing state machine: missing " + path)
		add_child(player)
		return player
	var stream := load(path) as AudioStream
	if stream is AudioStreamMP3:
		var looped := (stream as AudioStreamMP3).duplicate() as AudioStreamMP3
		looped.loop = true
		stream = looped
	player.stream = stream
	add_child(player)
	return player
