extends SceneTree
## Server hosting pieces that don't need a second process: address parsing (IPs, domains,
## ports, IPv6), the dedicated server config (the shipped example, bad values falling back
## with warnings, teams-only rules fitting a team mode), the recent / favorite server lists,
## and the Multiplayer menu (port, UPnP, passwords, saved servers; a bad address never
## connects). The real server is checked by tests/dedicated_server_check.gd. Settings are
## changed in memory only. Run:
## flatpak run org.godotengine.Godot --headless --path "<project>" --script res://tests/server_hosting_self_test.gd

var _failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_addresses()
	_test_config()
	_test_saved_servers()
	await _test_menu()
	if _failed:
		print("SERVER_HOSTING_SELF_TEST FAIL")
		quit(1)
		return
	print("SERVER_HOSTING_SELF_TEST PASS")
	quit(0)


func _test_addresses() -> void:
	var cases := [
		["203.0.113.7", true, "203.0.113.7", 7777],
		["203.0.113.7:7800", true, "203.0.113.7", 7800],
		["longcolt.example.com", true, "longcolt.example.com", 7777],
		["  longcolt.example.com:9000 ", true, "longcolt.example.com", 9000],
		["[2001:db8::7]:7778", true, "2001:db8::7", 7778],
		["[::1]", true, "::1", 7777],
		["2001:db8::7", true, "2001:db8::7", 7777],
		["", false, "", 0],
		["host:", false, "", 0],
		["host:abc", false, "", 0],
		["host:70000", false, "", 0],
		[":7777", false, "", 0],
		["my host", false, "", 0],
		["[::1", false, "", 0],
	]
	for c: Array in cases:
		var parsed := NetAddress.parse(c[0], 7777)
		var ok: bool = parsed.ok == c[1] and (not c[1] or (parsed.host == c[2] and parsed.port == c[3]))
		_expect(ok, "address '%s' -> %s" % [c[0], parsed])
	_expect(NetAddress.format("2001:db8::7", 7778) == "[2001:db8::7]:7778", "IPv6 is bracketed")
	_expect(NetAddress.format("example.com", 7777) == "example.com:7777", "host:port format")


func _test_config() -> void:
	var example := ServerConfig.parse_text(ServerConfig.EXAMPLE)
	_expect(example.warnings.is_empty(), "the shipped example has no warnings (%s)" % [example.warnings])
	_expect(example.rotation.size() == 3, "the example rotates 3 matches")
	_expect(example.port == 7777 and example.password == "" and not example.upnp, "example defaults")
	_expect(example.rotation[1].rules == "ctf" and example.rotation[1].mode == "team_4v4", "CTF entry")
	_expect(is_equal_approx(example.rotation[0].time_limit, 900.0), "minutes become seconds")
	var shipped := FileAccess.get_file_as_string("res://tools/server/server.cfg.example")
	_expect(shipped == ServerConfig.EXAMPLE, "tools/server/server.cfg.example matches ServerConfig.EXAMPLE")
	var bad := ServerConfig.parse_text(
		"[server]\nport=99999\nname=\"\"\n[bots]\ndifficulty=\"Impossible\"\ncount=99\n"
		+ "[match_b]\nmap=\"nowhere\"\nrules=\"slayer\"\n"
		+ "[match_a]\nmap=\"zanzibar\"\nmode=\"ffa\"\nrules=\"ctf\"\ntime_limit_minutes=-3\n"
	)
	_expect(bad.port == 7777 and bad.server_name != "", "bad port and empty name fall back")
	_expect(bad.bot_difficulty == "Normal" and bad.bot_count == GameMode.MAX_PLAYERS_ANY - 1, "bot values clamp")
	_expect(bad.rotation.size() == 2 and bad.rotation[0].map == "zanzibar", "matches play in section order")
	_expect(bad.rotation[0].mode == GameModes.TEAM_FALLBACK, "CTF in FFA moves to a team mode")
	var coop := ServerConfig.parse_text("[match_1]\nmap=\"lockout\"\nmode=\"team_4v4\"\nrules=\"horde\"\n")
	_expect(coop.rotation[0].mode == GameModes.COOP_FALLBACK, "Horde in a team mode moves to FFA (one side)")
	_expect(bad.rotation[0].time_limit == 0.0, "negative time limits mean none")
	_expect(bad.rotation[1].map == MapList.DEFAULT_ID, "unknown map falls back")
	_expect(bad.warnings.size() >= 5, "every bad value is reported (%d)" % bad.warnings.size())
	var empty := ServerConfig.parse_text("[server]\nname=\"Solo\"\n")
	_expect(empty.rotation.size() == 1 and empty.server_name == "Solo", "no matches: one default match")
	var missing := ServerConfig.load_file("user://does_not_exist_%d.cfg" % Time.get_ticks_usec())
	_expect(missing.rotation.size() == 1 and not missing.warnings.is_empty(), "missing file: defaults")


func _test_saved_servers() -> void:
	var settings := root.get_node("Settings")
	var recent: Array = settings.get(&"recent_servers")
	var favorites: Array = settings.get(&"favorite_servers")
	recent.clear()
	favorites.clear()
	for i in 10:
		settings.call(&"remember_server", "10.0.0.%d:7777" % i)
	settings.call(&"remember_server", "10.0.0.5:7777")
	recent = settings.get(&"recent_servers")
	_expect(recent.size() == 8 and recent[0] == "10.0.0.5:7777", "recent: newest first, capped at 8")
	_expect(recent.count("10.0.0.5:7777") == 1, "recent: no duplicates")
	_expect(settings.call(&"toggle_favorite", "game.example.com:7777"), "favorite added")
	_expect(settings.call(&"is_favorite", "game.example.com:7777"), "is a favorite")
	_expect(not settings.call(&"toggle_favorite", "game.example.com:7777"), "favorite removed")


func _test_menu() -> void:
	var settings := root.get_node("Settings")
	(settings.get(&"favorite_servers") as Array).append("fav.example.com:7777")
	var menu := (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await process_frame
	var port_edit := menu.get(&"_port_edit") as LineEdit
	var upnp := menu.get(&"_upnp_toggle") as CheckButton
	var host_pw := menu.get(&"_host_password") as LineEdit
	var join_pw := menu.get(&"_join_password") as LineEdit
	var saved := menu.get(&"_saved") as ItemList
	_expect(port_edit != null and port_edit.text == str(settings.get(&"host_port")), "host port box")
	_expect(upnp != null and host_pw != null and host_pw.secret, "UPnP toggle and host password")
	_expect(join_pw != null and join_pw.secret, "join password box")
	_expect(saved != null and saved.item_count >= 1 and saved.get_item_text(0).contains("fav.example.com"), "favorites listed first")
	var ip_edit := menu.get(&"_ip_edit") as LineEdit
	ip_edit.text = "bad host:port"
	menu.call(&"_join_ip")
	var net := root.get_node("Net")
	_expect(not net.call(&"is_online"), "a bad address never connects")
	var status := menu.get(&"_status") as Label
	_expect(status.text.contains("NO SPACES"), "and says why (%s)" % status.text)
	port_edit.text = "0"
	menu.call(&"_host")
	_expect(not net.call(&"is_online") and status.text.contains("PORT"), "a bad port never hosts")
	menu.queue_free()
	await process_frame


func _expect(ok: bool, message: String) -> void:
	if ok:
		print("  ok   ", message)
	else:
		_failed = true
		print("  FAIL ", message)
