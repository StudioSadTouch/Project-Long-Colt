class_name NetAddress
extends RefCounted
## Server addresses as players type them: "host", "host:port", "203.0.113.7:7777",
## "longcolt.example.com:7777", "[2001:db8::7]:7777", or a bare IPv6 address. The host can be a
## domain name; ENet resolves it when connecting. A missing port means `default_port`.

const PORT_MIN := 1
const PORT_MAX := 65535


## {"ok": bool, "host": String, "port": int, "error": String}.
static func parse(text: String, default_port: int) -> Dictionary:
	var s := text.strip_edges()
	if s == "":
		return _fail("Enter an address")
	if s.contains(" "):
		return _fail("Addresses have no spaces")
	var host := s
	var port_text := ""
	var has_port := false
	if s.begins_with("["):
		# [IPv6]:port or [IPv6]
		var close := s.find("]")
		if close < 0:
			return _fail("Missing ] after the IPv6 address")
		host = s.substr(1, close - 1)
		var rest := s.substr(close + 1)
		if rest != "":
			if not rest.begins_with(":"):
				return _fail("Expected :port after ]")
			port_text = rest.substr(1)
			has_port = true
	elif s.count(":") == 1:
		var at := s.find(":")
		host = s.substr(0, at)
		port_text = s.substr(at + 1)
		has_port = true
	# Two or more colons without brackets: a bare IPv6 address, no port.
	if host == "":
		return _fail("Enter a host before the port")
	var port := default_port
	if has_port and port_text == "":
		return _fail("Enter a port after the colon")
	if has_port:
		if not port_text.is_valid_int():
			return _fail("The port must be a number")
		port = port_text.to_int()
		if port < PORT_MIN or port > PORT_MAX:
			return _fail("The port must be %d-%d" % [PORT_MIN, PORT_MAX])
	return {"ok": true, "host": host, "port": port, "error": ""}


## "host:port", bracketing IPv6 hosts.
static func format(host: String, port: int) -> String:
	if host.contains(":"):
		return "[%s]:%d" % [host, port]
	return "%s:%d" % [host, port]


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "host": "", "port": 0, "error": message}
