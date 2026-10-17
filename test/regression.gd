extends SceneTree

# Local deterministic tests: no network, and a unique disposable queue directory.
var failures := 0

func check(condition: bool, label: String) -> void:
	if condition:
		print("PASS " + label)
	else:
		failures += 1
		printerr("FAIL " + label)

func _initialize() -> void:
	var rig = load("res://addons/queryrig/queryrig.gd").new()
	rig._booted = true  # do not auto-initialize real telemetry
	rig._inert = false
	rig._config = rig._DEFAULTS.duplicate()
	rig._config["enabled"] = true
	rig._config["flush_max_events"] = 99999
	rig._config["sample_rate"] = 0.0
	rig._session_id = "old"
	rig._last_event_ms = rig._now_ms() - 31 * 60 * 1000
	rig._sampled_in = false
	root.add_child(rig)
	rig.track("idle-rollover")
	check(rig._session_id != "old" and rig._queue.is_empty(), "sampled-out sessions roll over without a leaked event")
	rig._sampled_in = true
	var nested := {"score": 1}
	rig.track_fields({"nested": nested})
	nested["score"] = 99
	check(JSON.parse_string(rig._queue[0])["nested"]["score"] == 1, "queued properties are immutable")
	var before: int = rig._queue.size()
	rig.track_fields({"number": NAN})
	check(rig._queue.size() == before, "invalid number does not discard neighbouring events")
	var cycle := {}
	cycle["cycle"] = cycle
	check(not rig._valid_json(cycle), "cyclic properties are rejected without recursion overflow")
	cycle.clear()
	var deep := {}
	var current := deep
	for i in range(7):
		var child := {}
		current["child"] = child
		current = child
	current["scalar"] = 1
	check(rig._valid_json(deep), "eight container levels accepted")
	current["child"] = {}
	check(not rig._valid_json(deep), "ninth empty container rejected")
	check(rig._endpoint_problem("https://3fa91c0e.qrig.net/v1/events").is_empty(), "https endpoint accepted")
	check(rig._endpoint_problem("http://127.0.0.1:8788/v1/events").is_empty(), "loopback http endpoint accepted")
	check(not rig._endpoint_problem("").is_empty(), "missing endpoint refused")
	check(not rig._endpoint_problem("http://3fa91c0e.qrig.net/v1/events").is_empty(), "plain http off loopback refused")
	check(not rig._endpoint_problem("3fa91c0e.qrig.net/v1/events").is_empty(), "endpoint without a scheme refused")
	var a: String = rig._pseudonymous_player_id("device-1", "https://3fa91c0e.qrig.net/v1/events")
	check(a.length() == 32 and a == rig._pseudonymous_player_id("device-1", "https://3FA91C0E.qrig.net/v1/events"), "player id hash is stable per project host")
	check(a != rig._pseudonymous_player_id("device-1", "https://0b7e44d2.qrig.net/v1/events") and not a.contains("device-1"), "player id differs across projects and hides the device id")
	var lines: Array[String] = []
	for i in range(500):
		lines.append(JSON.stringify({"text": "中".repeat(300)}))
	var batches: Array = rig._split_batches(lines)
	var count := 0
	for batch in batches:
		count += batch.size()
		check(("[" + ",".join(batch) + "]").to_utf8_buffer().size() <= rig.FLUSH_MAX_BYTES, "batch fits UTF-8 wire budget")
	check(count == lines.size(), "batch splitting preserves all events")
	rig._DATA_DIR = "user://queryrig/regression-" + rig._uuid4()
	rig._QUEUE_DIR = rig._DATA_DIR + "/queue"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(rig._QUEUE_DIR))
	rig._config["enabled"] = "remote"
	rig._gate_enabled = false
	rig._dormant = true
	rig._thread = Thread.new()
	rig._thread.start(rig._worker_loop)
	rig.shutdown()
	var files: PackedStringArray = rig._queue_files()
	check(files.size() == 1 and rig._queue.is_empty(), "dormant shutdown persists pending events")
	for file in files:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(rig._QUEUE_DIR + "/" + file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rig._QUEUE_DIR))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(rig._DATA_DIR))
	rig.free()
	quit(0 if failures == 0 else 1)
