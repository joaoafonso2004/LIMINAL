extends Node
## WebSocket relay client (mp.tesana.ai). Do NOT build a custom server.
## Up to 4 players. Host (player 0) is authority for shared state.

signal message_received(type: String, data: Dictionary, from_player: int)
signal connected_to_room
signal room_created(code: String)
signal player_joined(player_id: int, total_players: int)
signal player_disconnected(player_id: int)
signal all_players_joined
signal room_error(reason: String)      # lobby HTTP failed or socket never opened

var is_multiplayer: bool = false
var is_host: bool = false
var room_code: String = ""
var max_players: int = 2
var local_player_id: int = 0
var connected_players: int = 0

var _ws: WebSocketPeer = null
var _ping_timer: float = 0.0
var _joined_ok: bool = false           # relay confirmed us with a "joined" message
const PING_INTERVAL: float = 5.0

const MP_RELAY_HOST: String = "mp.tesana.ai"

func get_server_base_url() -> String:
	# Desktop builds use the same public relay as web. A local dev relay can be
	# forced with the LIMINAL_RELAY env var (e.g. "ws://localhost:8000").
	var override := OS.get_environment("LIMINAL_RELAY")
	if override != "":
		return override
	return "wss://" + MP_RELAY_HOST

func create_room(player_count: int = 2) -> void:
	max_players = clamp(player_count, 2, 4)
	is_host = true
	local_player_id = 0
	var http = HTTPRequest.new()
	http.timeout = 10.0
	Engine.get_main_loop().root.add_child(http)
	http.request_completed.connect(func(result, code, _headers, body):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			room_error.emit("Could not reach the lobby server.")
			return
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json == null or not json.has("code"):
			room_error.emit("The lobby server gave a broken answer.")
			return
		room_code = json["code"]
		room_created.emit(room_code)
		connect_to_room(room_code)
	)
	var base = get_server_base_url().replace("ws://", "http://").replace("wss://", "https://")
	if http.request(base + "/lobby/create?max_players=" + str(max_players)) != OK:
		http.queue_free()
		room_error.emit("Could not reach the lobby server.")

func connect_to_room(code: String) -> void:
	room_code = code
	_joined_ok = false
	_ws = WebSocketPeer.new()
	if _ws.connect_to_url(get_server_base_url() + "/ws/room/" + code) != OK:
		_ws = null
		room_error.emit("Could not open a connection to the room.")

func disconnect_from_room() -> void:
	if _ws: _ws.close()
	_ws = null
	is_multiplayer = false
	is_host = false
	room_code = ""
	local_player_id = 0
	connected_players = 0
	max_players = 2

func send(type: String, data: Dictionary = {}) -> void:
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		data["t"] = type
		data["from"] = local_player_id
		_ws.send_text(JSON.stringify(data))

func _process(delta: float) -> void:
	if not _ws: return
	_ws.poll()
	var state = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		_ping_timer += delta
		if _ping_timer >= PING_INTERVAL:
			_ping_timer = 0.0
			send("ping")
		while _ws.get_available_packet_count() > 0:
			var msg = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
			if msg == null: continue
			var msg_type = msg.get("t", "")
			match msg_type:
				"joined":
					_joined_ok = true
					local_player_id = msg.get("player_id", 0)
					connected_players = msg.get("total", 1)
					player_joined.emit(local_player_id, connected_players)
					if connected_players >= max_players:
						all_players_joined.emit()
				"player_disconnected":
					var dc_id = msg.get("player_id", -1)
					player_disconnected.emit(dc_id)
				"pong": pass
				_:
					var from_player = msg.get("from", -1)
					message_received.emit(msg_type, msg, from_player)
	elif state == WebSocketPeer.STATE_CLOSED:
		if not _joined_ok:
			# The relay accepts the handshake then closes on a bad/full/expired
			# room (verified: close code 4000) — never confirmed = join failed.
			room_error.emit("Could not join that room — check the code and try again.")
		elif is_multiplayer:
			player_disconnected.emit(-1)
		_ws = null
