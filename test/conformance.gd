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
	_test_outage_no_loss()
	_test_remote_kill_switch()
	_test_hard_off_is_silent()

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
	_rig.flush()

	# 3 tracked + the automatic session_start.
	_check(_wait_for_rows(4), "delivery: 4 rows arrive after flush")
	var rows: Array = _req("GET", "/__harness/rows")["json"]
	var names := rows.map(func(r): return r["event_name"])
	_check("session_start" in names and "level_complete" in names, "delivery: session_start + tracked events present")

	var sessions := {}
	var ids := {}
	var stamped := true
	for r in rows:
		sessions[r["session_id"]] = true
		ids[r["event_id"]] = true
		stamped = stamped and not String(r["player_id"]).is_empty() and not String(r["platform"]).is_empty()
	_check(stamped, "stamping: player_id + platform set on every row")
	_check(sessions.size() == 1, "stamping: one session_id across the batch")
	_check(ids.size() == rows.size(), "stamping: event_ids unique")

	var lvl := {}
	for r in rows:
		if r["event_name"] == "level_complete":
			lvl = r
	var props: Dictionary = lvl.get("properties", {})
	_check(int(props.get("level", -1)) == 3 and is_equal_approx(float(props.get("duration_s", 0)), 82.5),
		"stamping: properties survive normalization")

	var reqs: Array = _req("GET", "/__harness/requests")["json"]
	_check(String(reqs[0]["userAgent"]).begins_with("queryrig-godot/"), "wire: User-Agent identifies the SDK")


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
