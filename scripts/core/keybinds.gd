class_name Keybinds
extends RefCounted
## Keyboard / mouse rebinding (static only). Each action in ACTIONS has SLOTS keyboard-or-mouse
## bindings (primary, secondary); controller bindings in project.godot are never touched.
## The project.godot input map is the default: capture_defaults() snapshots it once (Settings
## does this before applying the saved overrides), reset_all() goes back to it.
## Saved form (settings.cfg [keybinds], one key per action): an Array of SLOTS entries, each
## "" (unbound), "key:<physical keycode>" or "mouse:<button index>".

const SLOTS := 2
## Rebindable actions in menu order. Not listed: action_pause (Esc must always open the menu),
## the stick-only look actions, and weapon slots 3-5 (only two slots exist).
const ACTIONS: Array[Dictionary] = [
	{"action": "action_move_forward", "label": "Move forward"},
	{"action": "action_move_back", "label": "Move back"},
	{"action": "action_move_left", "label": "Strafe left"},
	{"action": "action_move_right", "label": "Strafe right"},
	{"action": "action_jump", "label": "Jump"},
	{"action": "action_crouch", "label": "Crouch"},
	{"action": "action_fire", "label": "Fire"},
	{"action": "action_alt_fire", "label": "Zoom / alt fire"},
	{"action": "action_melee", "label": "Melee"},
	{"action": "action_grenade_throw", "label": "Throw grenade"},
	{"action": "action_grenade_switch", "label": "Switch grenade"},
	{"action": "action_reload", "label": "Reload"},
	{"action": "action_interact", "label": "Interact / pick up"},
	{"action": "action_weapon_switch", "label": "Switch weapon"},
	{"action": "action_weapon_next", "label": "Next weapon"},
	{"action": "action_weapon_prev", "label": "Previous weapon"},
	{"action": "action_weapon_1", "label": "Weapon slot 1"},
	{"action": "action_weapon_2", "label": "Weapon slot 2"},
	{"action": "action_fire_select", "label": "Fire select"},
	{"action": "action_scoreboard", "label": "Scoreboard"},
	{"action": "action_camera_view", "label": "First / third person"},
	{"action": "action_camera_shoulder", "label": "Swap shoulder"},
	{"action": "action_fullscreen", "label": "Fullscreen"},
]
const MOUSE_NAMES := {
	MOUSE_BUTTON_LEFT: "Mouse Left",
	MOUSE_BUTTON_RIGHT: "Mouse Right",
	MOUSE_BUTTON_MIDDLE: "Mouse Middle",
	MOUSE_BUTTON_WHEEL_UP: "Wheel Up",
	MOUSE_BUTTON_WHEEL_DOWN: "Wheel Down",
	MOUSE_BUTTON_WHEEL_LEFT: "Wheel Left",
	MOUSE_BUTTON_WHEEL_RIGHT: "Wheel Right",
	MOUSE_BUTTON_XBUTTON1: "Mouse 4",
	MOUSE_BUTTON_XBUTTON2: "Mouse 5",
}

## action -> Array[String] of SLOTS codes, from project.godot.
static var _defaults: Dictionary = {}


## Snapshot the project.godot keyboard / mouse bindings (first call only).
static func capture_defaults() -> void:
	if not _defaults.is_empty():
		return
	for entry: Dictionary in ACTIONS:
		var action := str(entry.action)
		if InputMap.has_action(action):
			_defaults[action] = get_codes(action)


## The action's SLOTS keyboard / mouse bindings as codes ("" = unbound).
static func get_codes(action: String) -> Array[String]:
	var codes: Array[String] = []
	for event in InputMap.action_get_events(action):
		var code := event_to_code(event)
		if code != "" and codes.size() < SLOTS:
			codes.append(code)
	while codes.size() < SLOTS:
		codes.append("")
	return codes


## Replaces the action's keyboard / mouse bindings with codes; controller events stay.
static func set_codes(action: String, codes: Array) -> void:
	if not InputMap.has_action(action):
		return
	for event in InputMap.action_get_events(action):
		if event_to_code(event) != "":
			InputMap.action_erase_event(action, event)
	for code: Variant in codes:
		var event := code_to_event(str(code))
		if event != null:
			InputMap.action_add_event(action, event)


## Binds code to action's slot. The same input is removed from every other action (and from the
## other slot of this one) so one press never does two things. Returns the labels of the actions
## it was taken from.
static func bind(action: String, slot: int, code: String) -> Array[String]:
	var taken_from: Array[String] = []
	if code != "":
		for entry: Dictionary in ACTIONS:
			var other := str(entry.action)
			if not InputMap.has_action(other):
				continue
			var codes := get_codes(other)
			var index := codes.find(code)
			if index < 0 or (other == action and index == slot):
				continue
			codes[index] = ""
			set_codes(other, codes)
			if other != action:
				taken_from.append(str(entry.label))
	var mine := get_codes(action)
	mine[slot] = code
	set_codes(action, mine)
	return taken_from


static func reset_all() -> void:
	for action: String in _defaults:
		set_codes(action, _defaults[action])


## Saved overrides (action -> Array of codes) onto the input map. Unknown actions are skipped.
static func apply(saved: Dictionary) -> void:
	for action: Variant in saved:
		var codes: Variant = saved[action]
		if InputMap.has_action(str(action)) and codes is Array:
			set_codes(str(action), codes)


## Every listed action whose bindings differ from project.godot, for saving.
static func overrides() -> Dictionary:
	var out := {}
	for action: String in _defaults:
		var codes := get_codes(action)
		if codes != _defaults[action]:
			out[action] = codes
	return out


## "key:<physical>" / "mouse:<button>" for keyboard and mouse-button events, else "".
static func event_to_code(event: InputEvent) -> String:
	var key := event as InputEventKey
	if key != null:
		var physical := key.physical_keycode
		if physical == KEY_NONE:
			physical = key.keycode
		return "key:%d" % physical if physical != KEY_NONE else ""
	var mouse := event as InputEventMouseButton
	if mouse != null:
		return "mouse:%d" % mouse.button_index
	return ""


static func code_to_event(code: String) -> InputEvent:
	var parts := code.split(":")
	if parts.size() != 2 or not parts[1].is_valid_int():
		return null
	var value := parts[1].to_int()
	match parts[0]:
		"key":
			var key := InputEventKey.new()
			key.physical_keycode = value as Key
			return key
		"mouse":
			var mouse := InputEventMouseButton.new()
			mouse.button_index = value as MouseButton
			return mouse
	return null


## Readable name for the menu ("W", "Space", "Mouse 4"); "-" when unbound.
static func code_label(code: String) -> String:
	var event := code_to_event(code)
	var key := event as InputEventKey
	if key != null:
		var shown := DisplayServer.keyboard_get_keycode_from_physical(key.physical_keycode)
		if shown == KEY_NONE:
			shown = key.physical_keycode
		return OS.get_keycode_string(shown)
	var mouse := event as InputEventMouseButton
	if mouse != null:
		return MOUSE_NAMES.get(mouse.button_index, "Mouse %d" % mouse.button_index)
	return "-"
