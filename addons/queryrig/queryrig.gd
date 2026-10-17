extends Node

# QueryRig analytics SDK for Godot 4 — the reference implementation of the
# QueryRig engine SDK spec (docs/sdk-spec.md in the queryrig repo).
#
# Design contract, in order:
#  1. Telemetry behavior is a runtime decision — config file, env var, or the
#     remote gate. Never a rebuild.
#  2. Persist batches before sending; preserve identity for retries.
#     Caps, crashes before persistence, and disk failures can lose events.
#  3. Main-thread tracking validates and serializes; delivery I/O uses a worker.
#
# Usage (autoload "QueryRig", added by the editor plugin):
#   QueryRig.track("level_complete", {"level": 3, "duration_s": 82.5})

const SDK_VERSION := "0.2.0"

# Spec limits (server-enforced; we stay inside them when building batches).
const MAX_BATCH_EVENTS := 500
const FLUSH_MAX_BYTES := 200_000  # headroom under the 256 KB payload cap
const MEMORY_QUEUE_MAX := 10_000
const SESSION_GAP_MS := 30 * 60 * 1000
const GATE_POLL_S := 300.0
const BACKOFF_BASE_MS := 5_000
const BACKOFF_CAP_MS := 5 * 60 * 1000
const REJECTED_FILE_MAX_BYTES := 262_144

const _DEFAULTS := {
	"api_key": "",
	"endpoint": "",
	"enabled": "remote",  # true | false | "remote"
	"flush_interval_s": 5.0,
	"flush_max_events": 100,
	"disk_queue_max_bytes": 8 * 1024 * 1024,
	"sample_rate": 1.0,
	"gate_poll_interval_s": GATE_POLL_S,
}

var _DATA_DIR := "user://queryrig"
var _QUEUE_DIR := "user://queryrig/queue"

var _config: Dictionary = {}
var _booted := false
var _inert := true  # no api_key or hard-off: track() is a no-op, zero network

# Session state (main thread only).
var _session_id := ""
var _session_start_ms := 0
var _last_event_ms := 0
var _sampled_in := true
var _player_id := ""

# Memory queue (shared with worker thread; guard with _queue_mutex).
var _queue: Array = []
var _queue_mutex := Mutex.new()
var _dropped_overflow := 0

# Worker thread and its job box.
var _thread: Thread
var _jobs: Array = []
var _jobs_mutex := Mutex.new()
var _jobs_sem := Semaphore.new()
var _quitting := false

# Delivery state (worker thread writes, main thread reads; guarded).
var _state_mutex := Mutex.new()
var _gate_enabled := true  # last known remote-gate answer
var _dormant := false  # 401 or gate-off: drop new events, keep disk queue
# 403 from the edge (plain HTTP, wrong path): a misconfigured endpoint that no
# retry can fix. Delivery stops until restart; queued batches are kept.
var _edge_blocked := false
var _consecutive_failures := 0
var _next_drain_ms := 0

# Event uploads must outlast the Worker's 15s ClickHouse timeout plus R2 fallback.
const EVENT_HTTP_TIMEOUT_MS := 30_000
const CONFIG_HTTP_TIMEOUT_MS := 5_000
var _flush_timer: Timer
var _gate_timer: Timer
var _crypto := Crypto.new()
var _crypto_mutex := Mutex.new()


# ---------------------------------------------------------------- lifecycle

func _ready() -> void:
	if not _booted:
		init()


## Resolve config and start the SDK. Called automatically as an autoload;
## call directly with overrides for tests or manual setup. Safe to re-call.
func init(overrides: Dictionary = {}) -> void:
	if not _on_main_thread():
		push_error("QueryRig: init must run on the main thread")
		return
	if _booted:
		shutdown()
	if not _queue.is_empty():
		push_error("QueryRig: cannot reconfigure while old events could not be persisted")
		return
	_config = _resolve_config(overrides)
	_booted = true

	# NOTE: `enabled` is bool OR the String "remote"; GDScript errors on
	# String == bool comparisons, so always type-check before comparing.
	var enabled: Variant = _config["enabled"]
	if (enabled is bool and not enabled) or String(_config["api_key"]).is_empty():
		# Hard-off (or unconfigured): zero network calls, verifiable with a
		# packet capture. track() drops immediately.
		_inert = true
		return
	# A key needs its own project's endpoint, over HTTPS (spec §2.2). Without
	# one the SDK is just as inert, so a bad config never spins on retries.
	var problem := _endpoint_problem(String(_config["endpoint"]))
	if not problem.is_empty():
		push_error("QueryRig: %s; telemetry is off for this run" % problem)
		_inert = true
		return
	_inert = false
	_quitting = false
	_jobs.clear()
	_jobs_sem = Semaphore.new()
	_next_drain_ms = 0
	_consecutive_failures = 0
	_edge_blocked = false
	# Never transfer a legacy/unrelated queue to a newly configured project.
	var identity := (String(_config["endpoint"]).trim_suffix("/") + "\n" + String(_config["api_key"])).sha256_text()
	_DATA_DIR = "user://queryrig/" + identity
	_QUEUE_DIR = _DATA_DIR + "/queue"

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_QUEUE_DIR))
	_player_id = _default_player_id()
	_gate_enabled = _load_cached_gate() if enabled is String else true
	_dormant = not _gate_enabled

	_thread = Thread.new()
	_thread.start(_worker_loop)

	_flush_timer = Timer.new()
	_flush_timer.wait_time = maxf(0.1, float(_config["flush_interval_s"]))
	_flush_timer.autostart = true  # start() before the tree processes errors
	_flush_timer.timeout.connect(_on_flush_timer)
	add_child(_flush_timer)

	# Hard-on must still recover after a temporary authentication failure.
	_gate_timer = Timer.new()
	_gate_timer.wait_time = maxf(1.0, float(_config["gate_poll_interval_s"]))
	_gate_timer.autostart = true
	_gate_timer.timeout.connect(func() -> void: _post_job("gate"))
	add_child(_gate_timer)
	if enabled is String:
		_post_job("gate")

	_start_session()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			if not _inert:
				_post_job("flush")
		NOTIFICATION_WM_CLOSE_REQUEST:
			shutdown()


func _exit_tree() -> void:
	shutdown()


## Interrupt HTTP, persist pending events, and join the worker thread.
## Blocking local disk operations can still take time or fail.
func shutdown() -> void:
	if not _on_main_thread():
		push_error("QueryRig: shutdown must run on the main thread")
		return
	if _inert or not _booted or _quitting:
		_booted = false
		return
	_quitting = true
	_end_session()
	# Prioritize local persistence, not a backlog of network jobs.
	_jobs_mutex.lock()
	_jobs.clear()
	_jobs.append("quit")
	_jobs_mutex.unlock()
	_jobs_sem.post()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	for t in [_flush_timer, _gate_timer]:
		if t:
			t.queue_free()
	_flush_timer = null
	_gate_timer = null
	_booted = false
	_inert = true
	if not _queue.is_empty():
		push_warning("QueryRig: shutdown persistence failed; events remain memory-only")


# ---------------------------------------------------------------- public API

## Queue an event under a name on the main thread; no delivery I/O here.
##
## The name is sent as the `event_name` field, which is what the dashboard's
## query templates look for by default — it is a convention, not a requirement.
func track(event_name: String, props: Dictionary = {}) -> void:
	if not _on_main_thread():
		push_error("QueryRig: tracking must run on the main thread")
		return
	var fields := props.duplicate()
	fields["event_name"] = event_name
	track_fields(fields)


## Queue an event with no name — the fields are entirely yours.
##
## Nothing is reserved server-side: an event is any set of fields, and the only
## rule is that it carries at least one. Use this when the game already has its
## own vocabulary (`{"kind": "boss_defeated", ...}`) and point the dashboard's
## templates at that field instead of `event_name`.
func track_fields(props: Dictionary) -> void:
	if not _on_main_thread():
		push_error("QueryRig: tracking must run on the main thread")
		return
	if _inert or _quitting or not _collecting():
		return
	_maybe_rollover_session()
	_last_event_ms = _now_ms()
	if _sampled_in:
		if _valid_json(props):
			_enqueue(_stamp(props))
		else:
			push_warning("QueryRig: invalid event properties discarded")


## Override the default (device-derived) player id.
func set_player_id(id: String) -> void:
	if not _on_main_thread():
		push_error("QueryRig: set_player_id must run on the main thread")
		return
	_player_id = id


## Force an immediate flush (asynchronous — returns at once).
func flush() -> void:
	if not _inert:
		_post_job("flush")


## Re-check the remote gate now instead of waiting for the next poll
## (asynchronous). Useful after a connectivity change or from a debug menu.
func refresh_gate() -> void:
	if not _inert:
		_post_job("gate")


## Effective state, for game-side debug UI.
func is_enabled() -> bool:
	if _inert:
		return false
	_state_mutex.lock()
	var on := not _dormant and not _edge_blocked
	_state_mutex.unlock()
	return on


# ---------------------------------------------------------------- config

# Precedence (spec §2.1): built-in defaults < res://queryrig.json
# < user://queryrig.json < environment / command line.
func _resolve_config(overrides: Dictionary) -> Dictionary:
	var cfg := _DEFAULTS.duplicate()
	for path in ["res://queryrig.json", "user://queryrig.json"]:
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				for k in parsed:
					if cfg.has(k):  # unknown fields ignored (forward compat)
						cfg[k] = parsed[k]
	for pair in [["QUERYRIG_API_KEY", "api_key"], ["QUERYRIG_ENDPOINT", "endpoint"], ["QUERYRIG_ENABLED", "enabled"]]:
		if OS.has_environment(pair[0]):
			cfg[pair[1]] = OS.get_environment(pair[0])
	for arg in OS.get_cmdline_user_args():
		for pair in [["--queryrig-api-key=", "api_key"], ["--queryrig-endpoint=", "endpoint"], ["--queryrig-enabled=", "enabled"]]:
			if arg.begins_with(pair[0]):
				cfg[pair[1]] = arg.substr(pair[0].length())
	for k in overrides:
		cfg[k] = overrides[k]
	cfg["enabled"] = _parse_enabled(cfg["enabled"])
	return cfg


## Why `url` cannot be an ingest endpoint, or "" if it can: HTTPS to any host,
## or plain HTTP to a loopback address for local development.
static func _endpoint_problem(url: String) -> String:
	if url.strip_edges().is_empty():
		return "no endpoint configured (copy it from the project's Keys tab)"
	var u := _parse_url(url)
	if u.is_empty() or not (url.begins_with("https://") or url.begins_with("http://")):
		return "endpoint %s is not a URL" % url
	if u["scheme"] == "http" and not (String(u["host"]).to_lower() in ["127.0.0.1", "localhost", "[::1]", "::1"]):
		return "endpoint %s must use https://" % url
	return ""


static func _parse_enabled(v) -> Variant:
	if v is bool:
		return v
	var s := String(v).to_lower()
	if s in ["true", "1", "on", "yes"]:
		return true
	if s in ["false", "0", "off", "no"]:
		return false
	return "remote"


# ---------------------------------------------------------------- sessions

func _start_session() -> void:
	_session_id = _uuid4()
	_session_start_ms = _now_ms()
	_last_event_ms = _session_start_ms
	# Per-session sampling (spec §3.8): decide once so sampled-in sessions
	# are complete and funnels stay coherent.
	var rate := clampf(float(_config["sample_rate"]), 0.0, 1.0)
	_sampled_in = (hash(_session_id) & 0x7fffffff) % 10_000 < int(rate * 10_000)
	if _sampled_in and _collecting():
		_enqueue(_stamp({"event_name": "session_start"}))


func _end_session() -> void:
	if _session_id.is_empty() or not _sampled_in or not _collecting():
		return
	var duration := (_now_ms() - _session_start_ms) / 1000.0
	_enqueue(_stamp({"event_name": "session_end", "duration_s": duration}))


func _maybe_rollover_session() -> void:
	if _last_event_ms > 0 and _now_ms() - _last_event_ms > SESSION_GAP_MS:
		_start_session()


# ---------------------------------------------------------------- queueing

# Stamp everything at enqueue time (spec §3.3) so retries can't change the
# event. Explicit values in props win over SDK defaults.
#
# Values are sent as their natural JSON types; the server coerces every scalar
# to a string so each field has one predictable type to query. Never
# pre-stringify here — that would lose the distinction between "not sent" and
# "sent empty".
func _stamp(props: Dictionary) -> Dictionary:
	var ev := props.duplicate(true)
	if not ev.has("event_id"):
		ev["event_id"] = _uuid4()
	if not ev.has("timestamp"):
		ev["timestamp"] = _now_ms()
	if not ev.has("session_id"):
		ev["session_id"] = _session_id
	if not ev.has("player_id"):
		ev["player_id"] = _player_id
	if not ev.has("platform"):
		ev["platform"] = OS.get_name().to_lower()
	if not ev.has("build_version"):
		ev["build_version"] = str(ProjectSettings.get_setting("application/config/version", ""))
	return ev


func _enqueue(ev: Dictionary) -> void:
	if not _valid_json(ev):
		push_warning("QueryRig: invalid event discarded")
		return
	var line := JSON.stringify(ev)
	if line.to_utf8_buffer().size() + 2 > FLUSH_MAX_BYTES:
		push_warning("QueryRig: oversized event discarded")
		return
	var request_flush := false
	_queue_mutex.lock()
	_queue.append(line)  # immutable snapshot; no caller-owned nested objects
	while _queue.size() > MEMORY_QUEUE_MAX:  # drop OLDEST on overflow
		_queue.pop_front()
		_dropped_overflow += 1
	request_flush = _queue.size() >= int(_config["flush_max_events"])
	_queue_mutex.unlock()
	if request_flush:
		_post_job("flush")


func _on_flush_timer() -> void:
	_queue_mutex.lock()
	var pending := _queue.size()
	_queue_mutex.unlock()
	if pending > 0:
		_post_job("flush")
	else:
		_post_job("drain")  # idle intervals still trickle the disk queue


func _collecting() -> bool:
	var enabled: Variant = _config["enabled"]
	if enabled is bool:
		return enabled
	_state_mutex.lock()
	var on := _gate_enabled
	_state_mutex.unlock()
	return on


# ---------------------------------------------------------------- worker

func _post_job(job: String) -> void:
	_jobs_mutex.lock()
	if _quitting or _jobs.has(job):
		_jobs_mutex.unlock()
		return
	_jobs.append(job)
	_jobs_mutex.unlock()
	_jobs_sem.post()


func _worker_loop() -> void:
	while true:
		_jobs_sem.wait()
		_jobs_mutex.lock()
		var job = _jobs.pop_front() if not _jobs.is_empty() else null
		_jobs_mutex.unlock()
		match job:
			"quit":
				_do_flush()  # persist only; network is disabled while quitting
				break
			"flush":
				_do_flush()
			"drain":
				_drain_disk_one()
			"gate":
				_do_gate_check()


# Persist immutable events in spec-sized batches before any send attempt.
# Configured queue caps and storage failures remain limits on durability.
func _do_flush() -> void:
	_queue_mutex.lock()
	var events: Array = _queue
	_queue = []
	var dropped := _dropped_overflow
	_dropped_overflow = 0
	_queue_mutex.unlock()
	if dropped > 0:
		push_warning("QueryRig: memory queue overflowed; dropped %d oldest events" % dropped)
	if events.is_empty():
		_drain_disk_one()
		return

	var lines: Array[String] = []
	for line in events:
		lines.append(line)

	for batch in _split_batches(lines):
		if not _spill_to_disk(batch):
			_queue_mutex.lock()
			_queue = batch + _queue
			while _queue.size() > MEMORY_QUEUE_MAX:
				_queue.pop_front()
				_dropped_overflow += 1
			_queue_mutex.unlock()
	if not _quitting:
		_drain_disk_one()


static func _split_batches(lines: Array[String]) -> Array:
	var batches := []
	var current: Array[String] = []
	var bytes := 2
	for line in lines:
		var n := line.to_utf8_buffer().size() + 1
		if current.size() >= MAX_BATCH_EVENTS or (bytes + n > FLUSH_MAX_BYTES and not current.is_empty()):
			batches.append(current)
			current = []
			bytes = 2
		current.append(line)
		bytes += n
	if not current.is_empty():
		batches.append(current)
	return batches


# One batch -> one POST. Pure delivery attempt — the CALLER decides what to
# do with the lines, so a disk-drained batch is never re-spilled into a
# duplicate file. Returns "delivered" | "rejected" | "retryable" | "dormant".
func _send_batch(lines: Array[String]) -> String:
	_state_mutex.lock()
	var blocked := _dormant or _edge_blocked or _now_ms() < _next_drain_ms
	_state_mutex.unlock()
	if _quitting or blocked:
		return "retryable"
	var body := "[" + ",".join(lines) + "]"
	var res := _http(HTTPClient.METHOD_POST, String(_config["endpoint"]), body, EVENT_HTTP_TIMEOUT_MS)

	if res["ok"] and res["code"] == 200:
		var parsed = JSON.parse_string(String(res["body"]))
		if not parsed is Dictionary or not parsed.get("accepted") is float or not parsed.get("rejected") is float:
			_note_failure()
			return "retryable"
		if parsed["accepted"] < 0 or parsed["rejected"] < 0 or parsed["accepted"] + parsed["rejected"] != lines.size():
			_note_failure()
			return "retryable"
		_note_success()
		if parsed is Dictionary and int(parsed.get("rejected", 0)) > 0:
			push_warning("QueryRig: server rejected %d event(s): %s" % [
				int(parsed["rejected"]), JSON.stringify(parsed.get("results", []))])
		return "delivered"

	if res["ok"] and res["code"] == 401:
		# Key unknown/disabled: go dormant, keep events on disk, let the gate
		# poll decide when to wake up (spec §1 responses).
		_state_mutex.lock()
		_dormant = true
		_state_mutex.unlock()
		return "dormant"

	if res["ok"] and res["code"] == 403:
		# The edge refused the request before QueryRig saw it (spec §1): plain
		# HTTP or a path outside the ingest API. Resending cannot succeed, and
		# the events are valid, so keep them and stop until restart.
		_state_mutex.lock()
		var first := not _edge_blocked
		_edge_blocked = true
		_state_mutex.unlock()
		if first:
			push_error("QueryRig: %s refused the upload at the edge (HTTP 403). Check the endpoint on the project's Keys tab; queued events are kept and delivery is stopped until restart." % _config["endpoint"])
		return "dormant"

	if res["ok"] and (res["code"] == 400 or res["code"] == 413):
		# Non-retryable: integration bug. The caller keeps a capped record.
		push_warning("QueryRig: batch rejected with HTTP %d — dropped (see %s/rejected.ndjson)" % [res["code"], _DATA_DIR])
		return "rejected"

	# Network error (an unresolvable, DNS-blocked host included), timeout,
	# 5xx: retryable with backoff.
	_note_failure()
	return "retryable"


# ---------------------------------------------------------------- disk queue

func _spill_to_disk(lines: Array[String]) -> bool:
	var name := "%s/%d_%s.ndjson" % [_QUEUE_DIR, _now_ms(), _uuid4()]
	var f := FileAccess.open(name + ".tmp", FileAccess.WRITE)
	if not f:
		push_warning("QueryRig: cannot persist %d events; retaining in memory" % lines.size())
		return false
	f.store_string("\n".join(lines))
	f.flush()
	var error := f.get_error()
	f.close()
	if error != OK:
		return false
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(name + ".tmp"), ProjectSettings.globalize_path(name)) != OK:
		return false
	_enforce_disk_cap()
	return true


func _queue_files() -> PackedStringArray:
	var dir := DirAccess.open(_QUEUE_DIR)
	if not dir:
		return PackedStringArray()
	var files := PackedStringArray()
	for file in dir.get_files():
		if file.ends_with(".ndjson"):
			files.append(file)
	files.sort()  # timestamp-named => oldest first
	return files


func _enforce_disk_cap() -> void:
	var cap := int(_config["disk_queue_max_bytes"])
	var files := _queue_files()
	var total := 0
	var sizes := {}
	for file in files:
		var f := FileAccess.open(_QUEUE_DIR + "/" + file, FileAccess.READ)
		var sz := f.get_length() if f else 0
		if f:
			f.close()
		sizes[file] = sz
		total += sz
	var i := 0
	while total > cap and i < files.size():  # drop OLDEST first
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_QUEUE_DIR + "/" + files[i]))
		push_warning("QueryRig: disk cap evicted an oldest batch")
		total -= sizes[files[i]]
		i += 1


# Send at most one disk batch (spec §3.6: a trickle, not a burst), honoring
# the failure backoff. Original event_ids/timestamps ride along unchanged.
func _drain_disk_one() -> void:
	if _quitting:
		return
	_state_mutex.lock()
	var blocked := _dormant or _edge_blocked or _now_ms() < _next_drain_ms
	_state_mutex.unlock()
	if blocked:
		return
	var files := _queue_files()
	if files.is_empty():
		return
	var path := _QUEUE_DIR + "/" + files[0]
	var stored := FileAccess.open(path, FileAccess.READ)
	if not stored:
		return  # a read error is not an empty, acknowledged file
	var text := stored.get_as_text()
	if stored.get_error() not in [OK, ERR_FILE_EOF]:
		return
	stored.close()
	var lines: Array[String] = []
	for line in text.split("\n"):
		if not line.strip_edges().is_empty():
			lines.append(line)
	if lines.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	match _send_batch(lines):
		"delivered":
			# Delete only after success — a crash in between resends, and the
			# server dedupes on event_id (same contract as the server's own
			# R2 replay).
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		"rejected":
			_append_rejected(lines)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_:  # retryable (backoff set) or dormant: leave the file for later
			pass


func _append_rejected(lines: Array[String]) -> void:
	var path := _DATA_DIR + "/rejected.ndjson"
	if FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path).size() > REJECTED_FILE_MAX_BYTES:
		return  # capped, best-effort
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_string("\n".join(lines) + "\n")
		f.close()


func _note_success() -> void:
	_state_mutex.lock()
	_consecutive_failures = 0
	_next_drain_ms = 0
	_state_mutex.unlock()


func _note_failure() -> void:
	_state_mutex.lock()
	_consecutive_failures += 1
	var backoff: int = min(BACKOFF_BASE_MS * (1 << min(_consecutive_failures - 1, 10)), BACKOFF_CAP_MS)
	backoff += int(backoff * randf_range(-0.2, 0.2))  # jitter
	_next_drain_ms = _now_ms() + backoff
	_state_mutex.unlock()


# ---------------------------------------------------------------- remote gate

func _do_gate_check() -> void:
	_state_mutex.lock()
	var edge_blocked := _edge_blocked
	_state_mutex.unlock()
	if _quitting or edge_blocked:
		return
	var url := _origin(String(_config["endpoint"])) + "/v1/config"
	var res := _http(HTTPClient.METHOD_GET, url, "", CONFIG_HTTP_TIMEOUT_MS)
	var enabled: Variant = null
	if res["ok"] and res["code"] == 200:
		var parsed = JSON.parse_string(String(res["body"]))
		if parsed is Dictionary and parsed.has("enabled"):
			enabled = bool(parsed["enabled"])
	elif res["ok"] and res["code"] == 401:
		enabled = false
	# On fetch failure (offline, unresolvable host, 5xx, an edge 403) keep the
	# cached answer (spec §3.2): losing data over a flaky config fetch is worse
	# than sending. An edge 403 on events is what stops delivery.
	if enabled == null:
		return
	_save_cached_gate(enabled)
	_state_mutex.lock()
	_gate_enabled = enabled
	_dormant = not enabled
	_state_mutex.unlock()


func _load_cached_gate() -> bool:
	var f := FileAccess.open(_DATA_DIR + "/gate.json", FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary and parsed.has("enabled"):
			return bool(parsed["enabled"])
	return true  # first run: default enabled


func _save_cached_gate(enabled: bool) -> void:
	var f := FileAccess.open(_DATA_DIR + "/gate.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"enabled": enabled}))
		f.close()


# ---------------------------------------------------------------- HTTP

# Blocking request on the worker thread via HTTPClient (spec §3.9: no
# per-request HTTPRequest nodes, no main-thread I/O).
func _http(method: int, url: String, body: String, timeout_ms: int) -> Dictionary:
	var u := _parse_url(url)
	if u.is_empty():
		return {"ok": false, "code": 0, "body": ""}
	var client := HTTPClient.new()
	var tls: TLSOptions = TLSOptions.client() if u["scheme"] == "https" else null
	if client.connect_to_host(u["host"], u["port"], tls) != OK:
		return {"ok": false, "code": 0, "body": ""}
	var deadline := Time.get_ticks_msec() + timeout_ms

	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		if _quitting or Time.get_ticks_msec() > deadline:
			return {"ok": false, "code": 0, "body": ""}
		OS.delay_msec(5)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false, "code": 0, "body": ""}

	var headers := [
		"Content-Type: application/json",
		"Authorization: Bearer " + String(_config["api_key"]),
		"User-Agent: queryrig-godot/" + SDK_VERSION,
	]
	if client.request(method, u["path"], headers, body) != OK:
		return {"ok": false, "code": 0, "body": ""}
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if _quitting or Time.get_ticks_msec() > deadline:
			return {"ok": false, "code": 0, "body": ""}
		OS.delay_msec(5)
	if not client.has_response():
		return {"ok": false, "code": 0, "body": ""}

	var code := client.get_response_code()
	var buf := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		if _quitting or Time.get_ticks_msec() > deadline:
			return {"ok": false, "code": 0, "body": ""}
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			buf.append_array(chunk)
		elif Time.get_ticks_msec() > deadline:
			return {"ok": false, "code": 0, "body": ""}
		else:
			OS.delay_msec(2)
	client.close()
	return {"ok": true, "code": code, "body": buf.get_string_from_utf8()}


static func _parse_url(url: String) -> Dictionary:
	var scheme := "http"
	var rest := url
	if url.begins_with("https://"):
		scheme = "https"
		rest = url.substr(8)
	elif url.begins_with("http://"):
		rest = url.substr(7)
	elif url.is_empty():
		return {}
	var slash := rest.find("/")
	var hostport := rest if slash == -1 else rest.substr(0, slash)
	var path := "/" if slash == -1 else rest.substr(slash)
	var host := hostport
	var port := 443 if scheme == "https" else 80
	var colon := hostport.rfind(":")
	if colon != -1:
		host = hostport.substr(0, colon)
		port = int(hostport.substr(colon + 1))
	if host.is_empty():
		return {}
	return {"scheme": scheme, "host": host, "port": port, "path": path}


static func _origin(url: String) -> String:
	var u := _parse_url(url)
	if u.is_empty():
		return ""
	var default_port: int = 443 if u["scheme"] == "https" else 80
	var port_part: String = "" if u["port"] == default_port else ":%d" % u["port"]
	return "%s://%s%s" % [u["scheme"], u["host"], port_part]


# ---------------------------------------------------------------- utils

# The default player id is pseudonymous: a hash of the device id scoped to the
# project's ingest host, so the raw hardware id never leaves the device and two
# games on one machine cannot be linked by it. The host (not the key) is the
# scope, so rotating the key keeps every player's id.
func _default_player_id() -> String:
	var raw := OS.get_unique_id()
	if raw.is_empty():
		# Some platforms return "": persist a random device id instead. It lives
		# outside the endpoint/key namespace so a key rotation keeps it.
		var path := "user://queryrig/device_id"
		if FileAccess.file_exists(path):
			raw = FileAccess.get_file_as_string(path).strip_edges()
		if raw.is_empty():
			raw = _uuid4()
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://queryrig"))
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_string(raw)
				f.close()
	return _pseudonymous_player_id(raw, String(_config["endpoint"]))


static func _pseudonymous_player_id(raw: String, endpoint: String) -> String:
	var host := String(_parse_url(endpoint).get("host", "")).to_lower()
	return ("queryrig-player\n" + host + "\n" + raw).sha256_text().substr(0, 32)


func _uuid4() -> String:
	_crypto_mutex.lock()
	var b := _crypto.generate_random_bytes(16)
	_crypto_mutex.unlock()
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var hex := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]


static func _now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


static func _valid_json(value: Variant, depth: int = 0) -> bool:
	if depth >= 8 and (value is Dictionary or value is Array):
		return false  # also bounds cyclic containers
	if value is Dictionary:
		for key in value:
			if not key is String or not _valid_json(value[key], depth + 1):
				return false
		return true
	if value is Array:
		for item in value:
			if not _valid_json(item, depth + 1):
				return false
		return true
	if value is float:
		return is_finite(value)
	return value == null or value is String or value is bool or value is int


static func _on_main_thread() -> bool:
	return OS.get_thread_caller_id() == OS.get_main_thread_id()
