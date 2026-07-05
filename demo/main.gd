extends Control

# Demo scene: buttons that fire spec-shaped game events, plus a status line.
# Point queryrig.json (or env vars) at a real project — or run the SDK
# conformance harness from the queryrig repo (`npm run sdk-harness`) and use
# the defaults in queryrig.example.json.

var _status: Label
var _sent := 0


func _ready() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(24, 24)
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var title := Label.new()
	title.text = "QueryRig SDK demo"
	box.add_child(title)

	_status = Label.new()
	box.add_child(_status)

	_add_button(box, "Complete a level", func() -> void:
		QueryRig.track("level_complete", {"level": randi_range(1, 20), "duration_s": randf_range(30.0, 300.0)}))
	_add_button(box, "Pick up an item", func() -> void:
		QueryRig.track("item_pickup", {"item": ["sword", "potion", "shield", "gem"].pick_random()}))
	_add_button(box, "Kill an enemy", func() -> void:
		QueryRig.track("enemy_killed", {"enemy": ["slime", "goblin", "dragon"].pick_random(), "weapon": "sword"}))
	_add_button(box, "Flush now", func() -> void: QueryRig.flush())

	_refresh()


func _add_button(parent: Node, text: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(func() -> void:
		handler.call()
		if text != "Flush now":
			_sent += 1
		_refresh())
	parent.add_child(b)


func _refresh() -> void:
	_status.text = "telemetry: %s   |   events tracked: %d" % [
		"on" if QueryRig.is_enabled() else "off", _sent]
