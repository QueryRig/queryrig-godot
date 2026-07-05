# QueryRig SDK for Godot 4

Game analytics for [QueryRig](https://github.com/prhym/queryrig): batched,
durable event tracking with a runtime on/off switch. Reference implementation
of the QueryRig engine SDK spec (`docs/sdk-spec.md` in the queryrig repo).

- **Batched** — events queue in memory and flush every 5 s / 100 events, one
  HTTP request instead of dozens. `track()` costs sub-microseconds on the
  calling thread; all I/O runs on a worker thread.
- **Durable** — delivery failures spill to a disk queue (`user://queryrig/`)
  and replay with exponential backoff. Events carry client-generated
  `event_id`s, so retries are deduplicated server-side: crash-safe,
  duplicate-free, offline-tolerant.
- **Runtime-switchable** — telemetry on/off is never a rebuild: a
  `queryrig.json` next to the build, an env var, or the remote gate (flip the
  ingest key in the QueryRig dashboard and the installed fleet obeys within
  ~5 minutes).

## Install

1. Copy the `addons/queryrig/` folder from this repo into your project's own
   `addons/` folder (so you end up with `res://addons/queryrig/`).
2. In the top menu, open **Project → Project Settings…**, click the
   **Plugins** tab, find **QueryRig** in the list, and check its **Enable**
   box. Close the settings window.

That's it — no code. This registers `QueryRig` as a global object your whole
project can reach, and it starts itself automatically when the game runs.

## Use

Godot 4 doesn't ship a visual-scripting system, so there is one line of
GDScript to add per event you want to track — everything else (batching,
retries, sessions) is automatic. The fastest way to add that line without
writing a script from scratch:

1. Select the node you want to trigger tracking from (e.g. a `Button`).
2. In the editor's bottom-right dock, open the **Node** tab (next to
   **Inspector**) and double-click the signal you want — for a button,
   that's `pressed()`.
3. Click **Connect**. Godot creates a script (if the node doesn't have one
   yet) and jumps you straight to a new, empty function it wrote for you.
4. Add one line inside that function:

```gdscript
func _on_button_pressed() -> void:
	QueryRig.track("level_complete", {"level": 3, "duration_s": 82.5})
```

Everything past `QueryRig.track(` is yours to edit — first argument is the
event name, second is a dictionary of whatever details matter (or leave it
out entirely: `QueryRig.track("item_pickup")`).

Optional, for games with their own account/login system:

```gdscript
QueryRig.set_player_id(steam_id)   # defaults to a stable per-device id
```

`session_id`, `player_id`, `platform`, `build_version`, `timestamp`, and
`event_id` are stamped automatically (explicit values in the properties
dictionary win). `session_start` / `session_end` events are emitted for you,
with a 30-minute idle rollover.

## Configure

1. In your file manager (or the Godot editor's **FileSystem** dock), find
   `queryrig.example.json` next to `project.godot` and make a copy of it
   named `queryrig.json`, in that same folder.
2. Open `queryrig.json` in any text editor and fill in `api_key` and
   `endpoint` — both are shown on the **Keys** tab of your QueryRig project
   (the dashboard at your QueryRig site). Leave the quotes in place; only
   change what's between them.

```json
{
  "api_key": "qr_ingest_...",
  "endpoint": "https://ingest.example.com/v1/events",
  "enabled": "remote"
}
```

Resolution order: built-in defaults < `res://queryrig.json` <
`user://queryrig.json` < `QUERYRIG_API_KEY` / `QUERYRIG_ENDPOINT` /
`QUERYRIG_ENABLED` env vars (or `--queryrig-*=` user args). Promote the same
binary from dev to playtest by shipping a different `queryrig.json` — never by
rebuilding.

`enabled` is `true`, `false`, or `"remote"` (default):

| Value | Behavior |
|---|---|
| `false` | Hard off. Zero network calls — verifiable with a packet capture. |
| `true` | Send unconditionally. |
| `"remote"` | The server decides: the SDK polls `/v1/config` and obeys the ingest key's enabled state, so telemetry can be flipped after the build has shipped. |

Optional fields: `flush_interval_s` (5), `flush_max_events` (100),
`disk_queue_max_bytes` (8 MB), `sample_rate` (1.0, sampled per session so
funnels stay coherent).

## Demo

This repo is itself a Godot project: open it and run. The demo scene fires
spec-shaped events at whatever `queryrig.json` points to — for local
development, run the SDK harness from the queryrig repo (`npm run
sdk-harness`) and copy `queryrig.example.json` to `queryrig.json`.

## Conformance test

With the harness running:

```bash
godot --headless --path . -s res://test/conformance.gd
```

Exercises delivery + stamping, an outage (zero loss, zero duplicates after
disk-queue replay), the remote kill switch both directions, and hard-off
silence. Exit code 0 on pass.
