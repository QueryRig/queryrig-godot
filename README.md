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

Copy `addons/queryrig/` into your project and enable **QueryRig** in
Project Settings → Plugins (this registers the `QueryRig` autoload).

## Use

```gdscript
QueryRig.track("level_complete", {"level": 3, "duration_s": 82.5})
QueryRig.track("item_pickup", {"item": "sword"})
QueryRig.set_player_id(steam_id)   # optional; defaults to a stable device id
```

`session_id`, `player_id`, `platform`, `build_version`, `timestamp`, and
`event_id` are stamped automatically (explicit values in the properties
dictionary win). `session_start` / `session_end` events are emitted for you,
with a 30-minute idle rollover.

## Configure

Copy `queryrig.example.json` to `queryrig.json` in the project root (`res://`)
and set your ingest key and endpoint — both come from the Keys tab of your
QueryRig project:

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
