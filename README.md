# QueryRig SDK for Godot 4

Game analytics for [QueryRig](https://github.com/prhym/queryrig): batched,
durable event tracking with a runtime on/off switch. Reference implementation
of the QueryRig engine SDK spec (`docs/sdk-spec.md` in the queryrig repo).

- **Batched** — events queue in memory and flush every 5 s / 100 events, one
  HTTP request instead of dozens. `track()` validates, stamps, and serializes
  an immutable snapshot; delivery disk I/O and HTTP run on a worker thread.
- **Persistent retries** — batches are written to a scoped disk queue before
  sending and retained until acknowledged. Retries preserve event IDs and
  timestamps and honor exponential backoff. See the limits below.
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

The default player id is pseudonymous: a hash of the device id scoped to your
project's endpoint, so the raw hardware id never leaves the device and the
same machine has unrelated ids in different games. If you pass your own id,
prefer an opaque account id over a name or email address, and if your game is
played by children, send only pseudonymous ids (see the QueryRig terms).

`session_id`, `player_id`, `platform`, `build_version`, `timestamp`, and
`event_id` are stamped automatically (explicit values in the properties
dictionary win). `session_start` / `session_end` events are emitted for you,
with a 30-minute idle rollover.

### Your fields, your names

Nothing is reserved. Apart from `timestamp` and `event_id`, every field you
send is stored under the name you gave it — including `event_name`, which is
just the name the dashboard's query templates look for by default. If your
game already has its own vocabulary, send it and skip the event name entirely:

```gdscript
QueryRig.track_fields({"kind": "boss_defeated", "boss": "warden", "attempts": 4})
```

Then point the templates at `kind` instead of `event_name` (every template
takes the field name). Use `track()` when you have no reason not to — matching
the convention means charts work with no configuration.

Values are stored as text, so query them quoted (`properties.attempts = '4'`)
and cast when you need arithmetic (`toInt64OrNull(toString(properties.attempts))`).
Send natural types here — the conversion happens server-side.

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
  "endpoint": "https://3fa91c0e.qrig.net/v1/events",
  "enabled": "remote"
}
```

Every project has its own endpoint, `https://<ingest id>.qrig.net/v1/events`,
and it accepts only that project's key, so always copy the two together. The
endpoint must use `https://` (plain `http://` is allowed only for loopback
addresses, for local development). With a key but no usable endpoint, the SDK
logs one error at startup and stays off for that run.

Resolution order: built-in defaults < `res://queryrig.json` <
`user://queryrig.json` < `QUERYRIG_API_KEY` / `QUERYRIG_ENDPOINT` /
`QUERYRIG_ENABLED` env vars (or `--queryrig-*=` user args). Promote the same
binary from dev to playtest by shipping a different `queryrig.json` — never by
rebuilding.

`enabled` is `true`, `false`, or `"remote"` (default):

| Value | Behavior |
|---|---|
| `false` | Hard off. Zero network calls — verifiable with a packet capture. |
| `true` | Collect locally; authentication failures pause sending, with gate checks allowing recovery. |
| `"remote"` | The server decides: the SDK polls `/v1/config` and obeys the ingest key's enabled state, so telemetry can be flipped after the build has shipped. |

Optional fields: `flush_interval_s` (5), `flush_max_events` (100),
`disk_queue_max_bytes` (8 MB), `sample_rate` (1.0, sampled per session so
funnels stay coherent).

## Delivery limits and upgrading

Event uploads allow 30 seconds for a complete acknowledgement, leaving room
for the server's 15-second ClickHouse timeout and R2 fallback. Config checks
still time out after 5 seconds. A successful R2 acknowledgement completes the
batch; a timeout retains it for backoff/retry with the same IDs and timestamps.
Shutdown cancels outstanding uploads instead of waiting for the deadline.
This does not guarantee a response within 30 seconds on every network.

Call the SDK on Godot's main thread. Tracking validates and serializes JSON
immediately, so changing nested properties after the call cannot alter queued
events. Cycles, non-finite numbers, unsupported values, excessive depth, and
events exceeding 200 KB in UTF-8 are discarded individually with a warning.

Batches are written via temporary files and renamed before HTTP starts.
Shutdown interrupts HTTP and attempts to persist pending events even while
dormant; local disk operations can still block or fail. Events still in memory
can be lost on a crash before a flush. Memory (10,000 events) and disk (8 MB by
default) are capped and evict oldest entries. This is not an unlimited or
exactly-once delivery guarantee. Server retention still applies to offline events.

Queue and gate-cache paths are now `user://queryrig/<endpoint-and-key-fingerprint>/`.
Changing the endpoint **or key** isolates the old queue, including rotations
within the same project. Drain before rotating credentials. Old unscoped files
are left intact but are **not automatically replayed**; recover them only after
verifying the destination project. The backend must preserve historical
timestamps for retry-safe deduplication beyond seven days.

How the SDK reacts when it cannot deliver:

| What happens | SDK behavior |
|---|---|
| 401 (key unknown, disabled, or used on another project's endpoint) | Dormant: keeps queued events, re-checks the remote gate on its poll interval. |
| 403 from the edge (plain HTTP, or a path outside the ingest API) | Logs one error naming the endpoint and stops delivery until the game restarts. Queued events are kept. |
| Endpoint host does not resolve (the project is deleted, or paused while clients kept sending) | Treated as a network error: keeps events on disk and backs off (5 s doubling to 5 min). |

### Upgrading to 0.2.0

- `endpoint` is now required with `api_key` and must use `https://` off
  loopback. A config that relied on the old shared ingest host must switch to
  the project's own endpoint from the Keys tab.
- The default `player_id` is now a hash (see Use), so players tracked by
  0.1.0 with the default id get a new id after the upgrade. Ids you set with
  `set_player_id` are unchanged.
- Platforms without a device id keep their random fallback id across key
  rotations: it now lives at `user://queryrig/device_id`.

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

Exercises delivery + stamping (including the hashed player id), an outage
(zero loss, zero duplicates after disk-queue replay), an edge 403 treated as
permanent without losing the batch, an unresolvable host backed off as a
network error (live and at cold start), inert startup with a missing or
non-HTTPS endpoint, the remote kill switch both directions, and hard-off
silence. Exit code 0 on pass. To run it against an isolated harness, from the
queryrig repo: `node scripts/sdk-harness/run-client.mjs godot --headless
--path <this repo> -s res://test/conformance.gd`.

Local regressions without a server:
`godot --headless --path . -s res://test/regression.gd`.
