class_name EventManager
extends RefCounted
## Manages and binds the level's visual event graph (wires) connecting triggers to actions.

var connections: Array = []


func load_connections(arr: Array) -> void:
	connections.clear()
	for item in arr:
		if item is Dictionary:
			connections.append((item as Dictionary).duplicate(true))


func add_connection(source_uid: Variant, signal_name: String, target_uid: Variant, target_action: String, params: Dictionary = {}) -> bool:
	# Avoid duplicate identical connections
	for conn in connections:
		if str(conn.get("source_uid")) == str(source_uid) \
		and str(conn.get("signal_name")) == signal_name \
		and str(conn.get("target_uid")) == str(target_uid) \
		and str(conn.get("target_action")) == target_action:
			return false

	connections.append({
		"source_uid": str(source_uid),
		"signal_name": signal_name,
		"target_uid": str(target_uid),
		"target_action": target_action,
		"params": params,
	})
	return true


func remove_connection(index: int) -> void:
	if index >= 0 and index < connections.size():
		connections.remove_at(index)


func remove_connections_for_uid(uid_str: String) -> void:
	var i := connections.size() - 1
	while i >= 0:
		var conn: Dictionary = connections[i]
		if str(conn.get("source_uid")) == uid_str or str(conn.get("target_uid")) == uid_str:
			connections.remove_at(i)
		i -= 1


func clear() -> void:
	connections.clear()


func bind_graph(map_root: Node3D) -> void:
	for conn in connections:
		var s_id: String = str(conn.get("source_uid", ""))
		var sig: String = str(conn.get("signal_name", ""))
		var t_id: String = str(conn.get("target_uid", ""))
		var act: String = str(conn.get("target_action", ""))
		var params: Dictionary = conn.get("params", {})

		var source := find_node_by_uid(map_root, s_id)
		var target := find_node_by_uid(map_root, t_id)

		if source == null or target == null:
			continue

		if not source.has_signal(sig):
			push_warning("EventManager: source '%s' has no signal '%s'" % [s_id, sig])
			continue

		# Connect using a robust lambda wrapper capable of receiving any emitted arguments
		var callback := func(a0: Variant = null, a1: Variant = null):
			if not is_instance_valid(target):
				return
			if target.has_method(&"execute_action"):
				target.call(&"execute_action", act, params)
			elif target.has_method(StringName(act)):
				target.call(StringName(act))

		source.connect(sig, callback)


static func find_node_by_uid(root: Node, uid_str: String) -> Node:
	if root == null:
		return null
	if str(root.get_meta(&"uid", "")) == uid_str \
	or str(root.get_meta(&"node_uid", "")) == uid_str \
	or root.name == uid_str:
		return root

	for child in root.get_children():
		var found := find_node_by_uid(child, uid_str)
		if found != null:
			return found
	return null
