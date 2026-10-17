class_name NetUpnp
extends Node
## Opens the game port on the router through UPnP, so players on the internet can reach a
## listen server or a dedicated server behind a home router. Router discovery takes a few
## seconds, so it runs on a thread; `changed` reports the outcome. Net owns one ("Upnp") and
## closes the mapping when the session ends. Routers with UPnP off (or behind carrier-grade
## NAT) fail here: the port has to be forwarded by hand (UDP), as the lobby says.

signal changed(state: State, message: String)

enum State { OFF, WORKING, OPEN, FAILED }

const DESCRIPTION := "Project Long Colt"
const DISCOVER_TIMEOUT_MS := 2000

var state: State = State.OFF
var port: int = 0
## The router's public address once OPEN ("" if the router wouldn't say).
var external_address: String = ""
var message: String = ""

var _thread: Thread
var _upnp: UPNP
## Bumped by open() / close(): a discovery that finishes for an older generation is stale.
var _generation: int = 0


## Starts mapping UDP `game_port` to this machine. Safe to call again (re-maps).
func open(game_port: int) -> void:
	close()
	port = game_port
	_generation += 1
	_set_state(State.WORKING, "Opening UDP port %d on the router (UPnP)..." % port)
	_thread = Thread.new()
	_thread.start(_open_worker.bind(port, _generation))


## Removes the mapping (on a thread: the router may be slow to answer).
func close() -> void:
	_generation += 1
	if _thread != null:
		# A discovery still running finishes on its own; _finish undoes its mapping.
		_detach(_thread)
		_thread = null
	if state == State.OPEN and _upnp != null:
		var upnp := _upnp
		var mapped := port
		var closer := Thread.new()
		closer.start(func() -> void: upnp.delete_port_mapping(mapped, "UDP"))
		# Detached on purpose: leaving the game must not wait on the router.
		_detach(closer)
	_upnp = null
	external_address = ""
	if state != State.OFF:
		_set_state(State.OFF, "")


func _open_worker(game_port: int, generation: int) -> void:
	var upnp := UPNP.new()
	var fail := func(why: String) -> void:
		_finish.call_deferred(generation, game_port, null, "", why)
	var err := upnp.discover(DISCOVER_TIMEOUT_MS, 2, "InternetGatewayDevice")
	if err != UPNP.UPNP_RESULT_SUCCESS:
		fail.call("No UPnP router found (%s)" % _result_name(err))
		return
	var gateway := upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		fail.call("The router doesn't offer UPnP port mapping")
		return
	err = upnp.add_port_mapping(game_port, game_port, DESCRIPTION, "UDP", 0)
	if err != UPNP.UPNP_RESULT_SUCCESS:
		fail.call("The router refused the mapping (%s)" % _result_name(err))
		return
	_finish.call_deferred(generation, game_port, upnp, upnp.query_external_address(), "")


func _finish(
	generation: int, game_port: int, upnp: UPNP, external: String, failure: String
) -> void:
	if generation != _generation:
		# Closed (or reopened) while this worker ran: undo a mapping that arrived late.
		if upnp != null:
			var mapped := game_port
			var closer := Thread.new()
			closer.start(func() -> void: upnp.delete_port_mapping(mapped, "UDP"))
			_detach(closer)
		return
	_join_thread()
	if upnp == null:
		_set_state(State.FAILED, "%s. Forward UDP port %d on your router by hand." % [failure, port])
		return
	_upnp = upnp
	external_address = external
	var where := NetAddress.format(external, port) if external != "" else "port %d" % port
	_set_state(State.OPEN, "Open to the internet at %s" % where)


func _set_state(new_state: State, text: String) -> void:
	state = new_state
	message = text
	changed.emit(state, message)


func _join_thread() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null


## Keeps a fire-and-forget thread referenced until it ends, then joins it.
func _detach(thread: Thread) -> void:
	var poll := func() -> void:
		while thread.is_alive():
			await get_tree().process_frame
		thread.wait_to_finish()
	if is_inside_tree():
		poll.call()


func _exit_tree() -> void:
	_join_thread()


static func _result_name(code: int) -> String:
	return "UPnP error %d" % code
