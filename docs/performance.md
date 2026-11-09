# Performance and background operation

Online readings target a configurable five-second visible-panel and thirty-second hidden-panel start-to-start cadence by default. Settings apply immediately and persist. A single loop subtracts round duration from its next wait, wakes on visibility changes, and drops missed periods without overlapping rounds. Slow devices may extend the actual cadence. Slow properties retain their sixty-second eligibility gate. Verified curtains join the same read-only round, pausing per device on errors across restarts until explicit manual recovery; generic curtain probes remain blocked. See [polling and log history](device-polling-and-log-history.md). Device controls, verified readback, the 240 ms panel/page animations, pairing identity and the user's Keep Mac Awake preference retain their existing behavior.

## Offline probes

`LANMiotAPI` owns one independent probe scheduler and one timer for the earliest retry. Startup probes run immediately with at most eight in flight; later background retries allow four. Manual retries take priority over queued work and join an existing probe for the same device.

After a failed authenticated probe round:

```text
n = min(14, previous failures + 1)
nominal seconds = min(86,400, 20 × 2^(n − 1))
delay seconds = clamp(nominal × random(0.9 ... 1.1), 20, 86,400)
```

UDP retransmissions inside a round do not increment the failure count. Any authenticated success clears it. Backoff stays in memory; restarting the app probes every device again. Opening a panel or reading HomeKit state does not reset it.

The five-minute LAN discovery runs only when configuration contains no protected curtain. Configured curtains keep the legacy broadcast/probe paths blocked. Each known offline responder can receive one early authenticated verification per discovery round. A failed early verification advances the existing failure count; a broadcast response alone cannot establish an authenticated connection. Changing IP, token or model creates a new generation, cancels obsolete work and rejects late results. An already-sent UDP datagram cannot be recalled.

## Publication and HomeKit

The controller retains complete read/contact timestamps but publishes semantic revisions only when structure, values or availability change. Hidden views do not observe timestamp-only refreshes; reopening sends one observation update. Model/specification/language templates retain parsed specs, converted core specs and capability indexes, and are pruned when configuration changes.

HomeKit observes structure/value revisions instead of the entire reading dictionary. It rebuilds plans only after structural changes, indexes characteristics by IID, suppresses unchanged value/status writes and avoids unchanged defaults writes. Write acknowledgments and momentary-button resets still force notifications. Reserved AID/IID ledgers remain persistent so hiding/restoring devices preserves their identities.

The menu-bar panel creates its hosting view on first open. A quick reopen reuses it; after the exit animation completes and the panel stays hidden for 30 seconds, a single cancellable deadline detaches the hosting view and native field editor. `PanelSession` keeps only the route, measured sizes, scroll offsets, manual-add fields, uncommitted numeric drafts and disclosure expansion values. Device polling, pairing and HomeKit stay owned by `AppModel`. Removed devices prune their saved UI values, and a newer open invalidates an old eviction even if its completion arrives late. Reopening lays the recreated view out while the window is transparent, before the existing 240 ms entrance animation.

Display timelines have no future entries while hidden. Optional transition diagnostics lazily construct payloads and retain only the latest 2,000 events. Diagnostic file I/O runs on a utility queue; each export stream holds only one in-flight write and its latest pending replacement.

This follows Apple's guidance to [discard unused view objects and references](https://developer.apple.com/documentation/xcode/making-changes-to-reduce-memory-use). `NSWindow.orderOut` [hides a window without releasing it](https://developer.apple.com/documentation/appkit/nswindow/orderout%28_%3A%29); hiding alone is not memory eviction. Use [Allocations generations and memory graphs](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use) to distinguish retained view content from framework caches and allocator slack. A nil content view and fewer live allocations do not guarantee an equal immediate drop in physical footprint.

## Measurement

Run the same Release configuration, network and device set before/after. Keep panel visibility and tracing overhead consistent, allow startup to settle, then capture cumulative CPU, interrupt/idle wakeups and physical footprint:

```sh
python3 scripts/measure_process.py --pid PID --duration 300 --output /tmp/mijialan-process.jsonl
```

Subtract cumulative counters between samples. The script converts Mach ticks using the host's timebase and reports the kernel's energy estimate when available. RSS and physical footprint differ; use footprint for the memory comparison. Energy estimates are not battery-life measurements. Instruments Power Profiler currently rejects macOS recording on this host; Time Profiler/System Trace remain available. Network instrument connection samples can miss short-lived BSD UDP sockets; do not treat their sparse rows as complete packet counts. System Trace `sendto` calls show sends attempted, including failures before a packet reaches Wi-Fi.

For retained UI state, warm the routes first, exercise 100 panel open/close cycles and page round trips, then check memory again after 30 minutes hidden. Compare the warmed baseline and check for sustained growth. Control latency has an opt-in benchmark using actual miIO encoding and verified readback over a controlled 20 ms transport:

```sh
MIJIALAN_RUN_PERFORMANCE_BENCHMARKS=1 swift test -c release --filter ControlLatencyBenchmarks
swift test --filter 'MijiaLANTests|MijiaHomeKitBridgeTests'
swift test -c release --filter PanelMemoryTests
```

HAP request/body tracing is disabled in normal runs. `MIJIALAN_HAP_TRACE=1` explicitly enables verbose debugging; dynamic log text remains private. No benchmark changes physical device settings automatically.

Build into a staging bundle with `MIJIALAN_APP_OUTPUT`, verify its signature, retain the old app, quit the old process normally, then install and launch through `/usr/bin/open`. Do not leave the long-running app attached to a terminal execution session. Use `/tmp` for opt-in diagnostic exports: writing them to a removable volume can block on volume access. macOS may require the user to approve Keychain access again when an ad-hoc-signed executable changes; do not count that waiting period as idle operation or a successful bridge start.
