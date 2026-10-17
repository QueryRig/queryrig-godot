extends SceneTree

# Headless conformance test (spec §7) — drives the SDK against the QueryRig
# SDK harness (queryrig repo: `npm run sdk-harness`, port 8788).
#
# Run:  godot --headless --path . -s res://test/conformance.gd
# Env:  QUERYRIG_TEST_HARNESS to point at a non-default harness.
#
# The test blocks the main thread on purpose: the SDK's worker thread runs
# regardless of frames, and flush/gate checks are requested explicitly, so no
# Timer ticks are needed.

var _harness := "http://127.0.0.1:8788"
var _failures := 0
var _rig: Node


func _initialize() -> void:
	if OS.has_environment("QUERYRIG_TEST_HARNESS"):
		_harness = OS.get_environment("QUERYRIG_TEST_HARNESS")

	var health := _req("GET", "/v1/health")
	if not health["ok"]:
		printerr("conformance: harness not reachable at %s — start it with `npm run sdk-harness` in the queryrig repo" % _harness)
		quit(2)
		return
	_req("POST", "/__harness/reset", "{}")

	_rig = load("res://addons/queryrig/queryrig.gd").new()
	root.add_child(_rig)

	_test_delivery_and_stamping()
	_test_slow_fallback()
	_test_outage_no_loss()
	_test_edge_forbidden_is_permanent()
	_test_unresolvable_host_backs_off()
	_test_remote_kill_switch()
	_test_upload_401_stops_collection()
	_test_shutdown_cancels_upload()
	_test_hard_off_is_silent()
	_test_bad_endpoint_is_inert()
	_test_blocked_host_cold_start()

	_rig.init({"enabled": false})  # quiet shutdown
	if _failures == 0:
		print("conformance: ALL PASS")
	quit(0 if _failures == 0 else 1)


# ------------------------------------------------------------------- tests

func _test_delivery_and_stamping() -> void:
	_rig.init({
		"api_key": "test-key",
		"endpoint": _harness + "/v1/events",
		"enabled": true,
		"flush_interval_s": 999,  # flushes are driven explicitly
		"gate_poll_interval_s": 999,
	})
	_rig.track("level_complete", {"level": 3, "duration_s": 82.5})
	_rig.track("item_pickup", {"item": "sword"})
	_rig.track("enemy_killed", {"enemy": "slime"})
	# No event_name at all: nothing is reserved, so an event is any set of
	# fields. Proves the server accepts the studio's own vocabulary.
	_rig.track_fields({"kind": "boss_defeated", "boss": "warden"})
	_rig.flush()

	# 4 tracked + the automatic session_start.
	_check(_wait_for_rows(5), "delivery: 5 rows arrive after flush")
	var rows: Array = _req("GET", "/__harness/rows")["json"]
	# Only timestamp/received_at/event_id (+ project_id) are columns; every
	# other field the SDK sends lands in `properties` under its own name.
	var names := rows.map(func(r): return r["properties"].get("event_name", ""))
	_check("session_start" in names and "level_complete" in names, "delivery: session_start + tracked events present")

	var sessions := {}
	var ids := {}
	var stamped := true
	var unnamed := {}
	for r in rows:
		var p: Dictionary = r["properties"]
		sessions[p["session_id"]] = true
		ids[r["event_id"]] = true
		stamped = stamped and not String(p["player_id"]).is_empty() and not String(p["platform"]).is_empty()
		if not p.has("event_name"):
			unnamed = p
	_check(stamped, "stamping: player_id + platform set on every row")
	var player := String(rows[0]["properties"]["player_id"])
	_check(player.length() == 32 and player != OS.get_unique_id(),
		"stamping: default player_id is a hash, not the raw device id")
	_check(sessions.size() == 1, "stamping: one session_id across the batch")
	_check(ids.size() == rows.size(), "stamping: event_ids unique")
	_check(unnamed.get("kind", "") == "boss_defeated" and unnamed.get("boss", "") == "warden",
		"fields: an event with no event_name is accepted and keeps its own fields")

	var props := {}
	for r in rows:
		if r["properties"].get("event_name", "") == "level_complete":
			props = r["properties"]
	# Every property scalar is stored as a string, whatever the client sent —
	# one type per path, so equality in a query always works.
	_check(String(props.get("level", "")) == "3" and String(props.get("duration_s", "")) == "82.5",
		"stamping: property values arrive as strings")

	var reqs: Array = _req("GET", "/__harness/requests")["json"]
	_check(String(reqs[0]["userAgent"]).begins_with("queryrig-godot/"), "wire: User-Agent identifies the SDK")


func _test_slow_fallback() -> void:
	# Let the preceding acknowledgement settle before measuring a new upload.
	OS.delay_msec(200)
	var before: int = _state()["rows"]
	var requests_before := _events_request_count()
	_req("POST", "/__harness/mode", '{"events":"slow-fallback"}')
	_rig.track("slow_fallback", {})
	_rig.flush()
	_check(_wait_for_rows(before + 1, 22.0), "fallback: a 16-second R2 acknowledgement arrives")
	OS.delay_msec(300)
	_rig.flush()  # would resend the persisted batch if the acknowledgement was lost
	OS.delay_msec(500)
	_check(_events_request_count() == requests_before + 1, "fallback: exactly one POST, no premature retry")
	_check(int(_rig.get("_consecutive_failures")) == 0, "fallback: slow success does not enter backoff")
	_req("POST", "/__harness/mode", '{"events":"ok"}')


func _test_outage_no_loss() -> void:
	var before: int = _state()["rows"]
	_req("POST", "/__harness/mode", '{"events":"unavailable"}')
	_rig.track("during_outage_1", {})
	_rig.track("during_outage_2", {})
	_rig.track("during_outage_3", {})
	_rig.flush()
	OS.delay_msec(1500)
	_check(_state()["rows"] == before, "outage: nothing stored while backend is down")

	_req("POST", "/__harness/mode", '{"events":"ok"}')
	OS.delay_msec(7000)  # ride out the first retry backoff (~5s + jitter)
	_rig.flush()  # empty queue -> drains one disk batch
	_check(_wait_for_rows(before + 3, 10.0), "outage: disk queue drains after recovery — zero loss")
	_check(int(_state()["duplicates"]) == 0, "outage: replay produced no duplicates")


func _hard_on_config() -> Dictionary:
	return {
		"api_key": "test-key",
		"endpoint": _harness + "/v1/events",
		"enabled": true,
		"flush_interval_s": 999,
		"gate_poll_interval_s": 999,
	}


func _queue_file_count() -> int:
	return DirAccess.get_files_at(String(_rig.get("_QUEUE_DIR"))).size()


func _test_edge_forbidden_is_permanent() -> void:
	# Edge 403 (plain HTTP or a path outside the ingest API): the SDK must stop
	# sending, keep the batch, and not retry until restart.
	_rig.init(_hard_on_config())
	_rig.flush()
	OS.delay_msec(300)
	var rows_before: int = _state()["rows"]
	_req("POST", "/__harness/mode", '{"events":"edge-forbidden"}')
	var before := _events_request_count()
	_rig.track("edge_refused", {})
	_rig.flush()
	_check(_wait_until(func(): return _events_request_count() == before + 1), "edge 403: the batch is attempted once")
	_check(_wait_until(func(): return not _rig.is_enabled()), "edge 403: the SDK reports itself off")
	OS.delay_msec(6000)  # longer than the first retry backoff would be
	_rig.flush()
	OS.delay_msec(500)
	_check(_events_request_count() == before + 1, "edge 403: no retry, even after the backoff window")
	_check(_queue_file_count() > 0, "edge 403: the refused batch is kept on disk")

	# A restart with the corrected endpoint (same here) delivers the kept batch.
	_req("POST", "/__harness/mode", '{"events":"ok"}')
	_rig.init(_hard_on_config())
	for i in range(4):
		_rig.flush()
		OS.delay_msec(300)
	_check(_wait_for_rows(rows_before + 1, 10.0), "edge 403: kept events arrive after a restart")
	_check(int(_state()["duplicates"]) == 0, "edge 403: no duplicates after the restart")


func _test_unresolvable_host_backs_off() -> void:
	# A DNS-blocked hostname is a network error: back off, keep, recover.
	_rig.init(_hard_on_config())
	_rig.flush()
	OS.delay_msec(300)
	var rows_before: int = _state()["rows"]
	var attempts_before: int = _state()["unreachableAttempts"]
	_req("POST", "/__harness/mode", '{"events":"unresolvable"}')
	_rig.track("while_unreachable", {})
	_rig.flush()
	_check(_wait_until(func(): return int(_state()["unreachableAttempts"]) > attempts_before), "unreachable: the batch is attempted")
	_rig.flush()
	_rig.flush()
	OS.delay_msec(1000)
	_check(int(_state()["unreachableAttempts"]) == attempts_before + 1, "unreachable: backoff holds further attempts")
	_check(int(_rig.get("_consecutive_failures")) >= 1 and _queue_file_count() > 0, "unreachable: counted as a failure, batch kept")
	_check(_rig.is_enabled(), "unreachable: not treated as a permanent refusal")

	_req("POST", "/__harness/mode", '{"events":"ok"}')
	OS.delay_msec(7000)  # ride out the first retry backoff (~5s + jitter)
	_rig.flush()
	_check(_wait_for_rows(rows_before + 1, 10.0), "unreachable: recovers by itself and delivers")


func _test_upload_401_stops_collection() -> void:
	# A key disabled between gate polls: the first upload's 401 must stop
	# collection at once in remote mode (spec §3.2), not at the next poll.
	_rig.init({
		"api_key": "test-key",
		"endpoint": _harness + "/v1/events",
		"enabled": "remote",
		"flush_interval_s": 999,
		"gate_poll_interval_s": 999,
	})
	_check(_wait_until(func(): return _rig.is_enabled(), 5.0), "upload 401: starts enabled")
	_req("POST", "/__harness/keys", '{"key":"test-key","disabled":true}')
	var before := _events_request_count()
	_rig.track("before_401", {})
	_rig.flush()
	_check(_wait_until(func(): return _events_request_count() > before and not _rig.is_enabled()),
		"upload 401: the refused upload turns the SDK off without a gate poll")
	var files := _queue_file_count()
	for i in range(3):
		_rig.track("after_401", {})
	_rig.flush()
	OS.delay_msec(500)
	_check((_rig.get("_queue") as Array).is_empty() and _queue_file_count() == files,
		"upload 401: new events are dropped, not queued")
	_check(_queue_file_count() > 0, "upload 401: the refused batch is kept on disk")

	_req("POST", "/__harness/keys", '{"key":"test-key","disabled":false}')
	_rig.refresh_gate()
	_check(_wait_until(func(): return _rig.is_enabled(), 5.0), "upload 401: re-enabling resumes collection")


func _test_remote_kill_switch() -> void:
	_rig.init({
		"api_key": "test-key",
		"endpoint": _harness + "/v1/events",
		"enabled": "remote",
		"flush_interval_s": 999,
		"gate_poll_interval_s": 999,
	})
	_check(_wait_until(func(): return _rig.is_enabled(), 5.0), "gate: starts enabled with a live key")

	_req("POST", "/__harness/keys", '{"key":"test-key","disabled":true}')
	_rig.refresh_gate()
	_check(_wait_until(func(): return not _rig.is_enabled(), 5.0), "gate: dashboard disable turns the SDK off")

	var events_before := _events_request_count()
	_rig.track("should_be_dropped", {})
	_rig.flush()
	OS.delay_msec(1000)
	_check(_events_request_count() == events_before, "gate: dormant SDK sends nothing")

	_req("POST", "/__harness/keys", '{"key":"test-key","disabled":false}')
	_rig.refresh_gate()
	_check(_wait_until(func(): return _rig.is_enabled(), 5.0), "gate: re-enable turns the SDK back on")


func _test_shutdown_cancels_upload() -> void:
	# Drain current data before hanging one known upload.
	_rig.flush()
	OS.delay_msec(300)
	_req("POST", "/__harness/mode", '{"events":"hang"}')
	var before := _events_request_count()
	_rig.track("shutdown_in_flight", {})
	_rig.flush()
	_check(_wait_until(func(): return _events_request_count() > before), "shutdown: upload is in flight")
	var started := Time.get_ticks_msec()
	_rig.shutdown()
	_check(Time.get_ticks_msec() - started < 2000, "shutdown: cancels upload without waiting 30 seconds")
	var files := DirAccess.get_files_at(String(_rig.get("_QUEUE_DIR")))
	_check(files.size() > 0, "shutdown: unacknowledged disk batch retained")
	_req("POST", "/__harness/mode", '{"events":"ok"}')


func _test_hard_off_is_silent() -> void:
	# init() first: it flushes the PREVIOUS instance's session_end before the
	# hard-off config takes effect. Reset after, so the log starts clean.
	_rig.init({
		"api_key": "test-key",
		"endpoint": _harness + "/v1/events",
		"enabled": false,
	})
	_req("POST", "/__harness/reset", "{}")
	_rig.track("never_sent", {})
	_rig.flush()
	OS.delay_msec(1000)
	_check(int(_state()["requests"]) == 0, "hard-off: zero network calls of any kind")


func _test_bad_endpoint_is_inert() -> void:
	# A key with no endpoint, or a non-HTTPS one off loopback, must be inert:
	# no requests, no retries (spec §2.2).
	for endpoint in ["", "http://ingest.example.com/v1/events", "ingest.example.com/v1/events"]:
		_rig.init({"api_key": "test-key", "endpoint": endpoint, "enabled": true})
		_req("POST", "/__harness/reset", "{}")
		_rig.track("never_sent", {})
		_rig.flush()
		OS.delay_msec(500)
		_check(bool(_rig.get("_inert")) and int(_state()["requests"]) == 0,
			"bad endpoint: inert with %s" % ("no endpoint" if endpoint.is_empty() else endpoint))
	_check(String(_rig._endpoint_problem("https://3fa91c0e.qrig.net/v1/events")).is_empty()
		and String(_rig._endpoint_problem(_harness + "/v1/events")).is_empty(),
		"bad endpoint: HTTPS and loopback HTTP are accepted")


func _test_blocked_host_cold_start() -> void:
	# Starting on a DNS-blocked hostname: the gate fetch fails, the cached (or
	# default) answer holds, and events queue on disk instead of being lost.
	var blocked := "https://blocked.invalid/v1/events"
	if OS.has_environment("QUERYRIG_TEST_UNRESOLVABLE_ENDPOINT"):
		blocked = OS.get_environment("QUERYRIG_TEST_UNRESOLVABLE_ENDPOINT")
	_rig.init({"api_key": "test-key", "endpoint": blocked, "enabled": "remote",
		"flush_interval_s": 999, "gate_poll_interval_s": 999})
	_rig.track("cold_start_blocked", {})
	_rig.flush()
	_check(_wait_until(func(): return _queue_file_count() > 0), "blocked host: events queue on disk")
	OS.delay_msec(1000)
	_check(not bool(_rig.get("_inert")) and _rig.is_enabled(), "blocked host: still enabled, waiting to retry")
	_check(_wait_until(func(): return int(_rig.get("_consecutive_failures")) >= 1), "blocked host: the failure backs off")
	_rig.shutdown()
	for file in DirAccess.get_files_at(String(_rig.get("_QUEUE_DIR"))):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(String(_rig.get("_QUEUE_DIR")) + "/" + file))


# ------------------------------------------------------------------ helpers

func _check(cond: bool, label: String) -> void:
	if cond:
		print("  PASS  " + label)
	else:
		printerr("  FAIL  " + label)
		_failures += 1


func _state() -> Dictionary:
	return _req("GET", "/__harness/state")["json"]


func _events_request_count() -> int:
	var reqs: Array = _req("GET", "/__harness/requests")["json"]
	return reqs.filter(func(r): return r["path"] == "/v1/events").size()


func _wait_for_rows(n: int, timeout_s := 5.0) -> bool:
	return _wait_until(func(): return int(_state()["rows"]) >= n, timeout_s)


func _wait_until(cond: Callable, timeout_s := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		OS.delay_msec(100)
	return cond.call()


# Minimal blocking HTTP for talking to the harness control API.
func _req(method: String, path: String, body := "") -> Dictionary:
	var u := _harness.trim_suffix("/")
	var scheme_split := u.split("://")
	var hostport := scheme_split[1].split(":")
	var host := hostport[0]
	var port := int(hostport[1]) if hostport.size() > 1 else 80
	var client := HTTPClient.new()
	if client.connect_to_host(host, port) != OK:
		return {"ok": false}
	var deadline := Time.get_ticks_msec() + 5000
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		if Time.get_ticks_msec() > deadline:
			return {"ok": false}
		OS.delay_msec(5)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false}
	var m := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	if client.request(m, path, ["Content-Type: application/json"], body) != OK:
		return {"ok": false}
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		OS.delay_msec(5)
	if not client.has_response():
		return {"ok": false}
	var buf := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			buf.append_array(chunk)
		else:
			OS.delay_msec(2)
	client.close()
	var text := buf.get_string_from_utf8()
	return {"ok": true, "code": client.get_response_code(), "json": JSON.parse_string(text), "body": text}
