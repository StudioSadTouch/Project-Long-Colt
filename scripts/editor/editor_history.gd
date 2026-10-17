class_name EditorHistory
extends RefCounted
## Undo / redo for the level editor, as whole-level snapshots (LevelData dictionaries plus the
## selected uids). A level is a few hundred small entries, so a snapshot per edit is cheap and
## can't drift out of sync the way per-operation inverses can. The editor calls checkpoint()
## before every change; undo() / redo() hand back the state to restore.

const LIMIT := 100

var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []


## Records `state` (the level as it is before a change) and clears the redo stack.
func checkpoint(state: Dictionary, label: String) -> void:
	_undo.append({"state": state.duplicate(true), "label": label})
	if _undo.size() > LIMIT:
		_undo.pop_front()
	_redo.clear()


## The state to restore, given the current one (which goes on the redo stack); {} if none.
func undo(current: Dictionary) -> Dictionary:
	if _undo.is_empty():
		return {}
	var step: Dictionary = _undo.pop_back()
	_redo.append({"state": current.duplicate(true), "label": step.label})
	return step


func redo(current: Dictionary) -> Dictionary:
	if _redo.is_empty():
		return {}
	var step: Dictionary = _redo.pop_back()
	_undo.append({"state": current.duplicate(true), "label": step.label})
	return step


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func clear() -> void:
	_undo.clear()
	_redo.clear()
