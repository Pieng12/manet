You are working on the ResQMesh repository:

`https://github.com/Pieng12/manet.git`

Start from the latest `main` commit after P8:

`aad57a7cea7e86ec07589f76160e7f05c6a41adf`

or a newer commit if `main` has advanced.

This task is **P9 – Research / Experiment Monitor**.

P8 is considered the final BLE/background source-hardening baseline before physical testing. P9 must NOT redesign the BLE architecture or forwarding algorithm.

The goal of P9 is to make physical thesis experiments easier by adding a dedicated **Research Monitor / Experiment Monitor** page inside ResQMesh.

The page must help the researcher:

* create experiment sessions;
* create and number trials;
* select forwarding mode;
* define node role;
* monitor live BLE/relay state;
* see current packet information;
* see research metrics;
* see event timeline;
* distinguish duplicate/stale/ACK events;
* export data for thesis analysis;
* avoid manually reading raw logcat/SQLite for every trial.

The Research Monitor is a **research/debug feature**, not an end-user emergency screen.

---

# 1. DO NOT CHANGE THE RESQMESH PROTOCOL

P9 must preserve all protocol invariants from P8.

Do NOT modify the 17-byte BLE payload.

Current protocol must remain:

```text
Byte 0–1   : 0x52 0x4D ("RM")
Byte 2–5   : sender CRC32, big-endian
Byte 6–8   : compact timestamp uint24
Byte 9–11  : latitude
Byte 12–14 : longitude
Byte 15    : status
Byte 16    : flags + hop
```

Byte 16:

```text
0x80 = ACK
0x40 = fromServer
0x3F = hop count
```

Preserve:

* Manufacturer ID `0xFFFF`;
* exactly 17-byte protocol payload;
* hop saturation at 63;
* no hard hop TTL;
* no fixed relay-count termination;
* non-connectable BLE advertising;
* connectionless BLE;
* no pairing requirement;
* Controlled Epidemic Forwarding;
* Basic Flooding comparison mode;
* adaptive backoff;
* jitter;
* deduplication;
* stale-state rejection;
* ACK tombstones;
* persistent relay queue;
* Native BLE Inbox;
* P7/P8 headless WorkManager relay;
* current gateway architecture.

**Research metadata must be stored separately in SQLite and MUST NOT be added into the BLE payload.**

---

# 2. ADD A DEDICATED RESEARCH MONITOR PAGE

Create a dedicated page, for example:

```text
ResearchMonitorScreen
```

or:

```text
ExperimentMonitorScreen
```

Use a route such as:

```text
/research-monitor
```

The page should be accessible from the existing Relay/Debug/Monitor UI.

Do not make it the application's normal home screen.

A debug/research button is sufficient:

```text
Research Monitor
```

---

# 3. PAGE STRUCTURE

Make one Research Monitor page with internal tabs or segmented sections.

Recommended structure:

```text
RESEARCH MONITOR

[ LIVE ] [ METRICS ] [ TRIAL ] [ EVENTS ] [ SYSTEM ]
```

The page should remain usable on a normal Android phone.

Avoid showing dozens of raw values in one screen.

---

# 4. LIVE TAB

The LIVE tab must display the current experiment state.

Example:

```text
Experiment Session
EXP-2026-001

Trial
CTRL-H3-007

Trial Status
RUNNING

Forwarding Mode
CONTROLLED EPIDEMIC

Node Role
RELAY

Hop Target
3

Elapsed Time
00:01:28
```

Then show current packet:

```text
CURRENT PACKET

Sender CRC       : C6A299A9
Protocol Time    : E26F7D / decoded time
Status           : ACTIVE
Packet Type      : SOS
Hop In           : 1
Hop Out          : 2
RSSI             : -67 dBm
From Server      : No
Payload Identity : ...
Received At      : ...
Relay Queued At  : ...
Advertised At    : ...
```

If no packet is active:

```text
No current packet
```

Do not display fake/default data.

---

# 5. SYSTEM STATE ON LIVE / SYSTEM TAB

Expose useful diagnostic state already available in P8.

At minimum:

```text
Bluetooth Enabled
Native BLE Scanner
Native BLE Advertiser
Foreground Service
Scheduler State
Native Inbox Pending
Relay Queue Total
SOS Queue
ACK Queue
Earliest Next Eligible
Pending Relay Work
Forwarding Mode
Manufacturer ID Dart
Manufacturer ID Native
Manufacturer Match
Last Native Error
```

If possible also display:

```text
Headless Worker last state
Permission blocked state
```

Do not claim the Worker is active if this cannot be determined reliably.

Use `unknown` / `-` rather than guessing.

---

# 6. TRIAL MANAGEMENT

Add explicit experiment/trial management.

A researcher must be able to create:

```text
Experiment Session
```

and then multiple:

```text
Trials
```

For example:

```text
Session:
CEF-H3-2026-08-11

Trial:
CEF-H3-001
CEF-H3-002
...
CEF-H3-030
```

Add controls:

```text
START SESSION
END SESSION

START TRIAL
END TRIAL
INVALIDATE TRIAL
NEXT TRIAL
```

Do not automatically delete data when a trial is invalidated.

Instead mark:

```text
trial_status = INVALID
```

so the trial remains auditable.

---

# 7. EXPERIMENT CONFIGURATION

Before starting a session/trial allow the researcher to define:

```text
Experiment Name
Forwarding Mode
Node Role
Target Hop Count
Topology Label
Distance / Scenario Label
Notes
```

Forwarding mode must use the existing enum/config:

```text
basic_flooding
controlled_epidemic
```

Do not create a third forwarding algorithm.

Node roles:

```text
SOURCE
RELAY
DESTINATION
GATEWAY
OBSERVER
```

Topology examples may be free text:

```text
HP-A -> R1 -> R2 -> HP-B
```

or:

```text
Android -> ESP32 R1 -> Android
```

Distance/scenario examples:

```text
LOS-5M
LOS-10M
WALL-1
HOP-3
```

These are experiment metadata only.

---

# 8. DATABASE MODEL

Do not overload the BLE protocol.

Add SQLite research tables if the current `experiment_sessions` table is insufficient.

Prefer extending the existing experiment infrastructure instead of building an unrelated second logging system.

Recommended entities:

## experiment_sessions

Fields conceptually:

```text
id
name
started_at
ended_at
forwarding_mode
node_role
target_hop
topology_label
scenario_label
notes
status
app_version
device_model
android_version
```

## experiment_trials

Fields:

```text
id
session_id
trial_number
trial_code
started_at
ended_at
status
result
notes
```

Status examples:

```text
READY
RUNNING
COMPLETED
INVALID
FAILED
```

## experiment_events

Reuse current table where possible.

Every research event should be linkable to:

```text
session_id
trial_id
```

Do not break existing experiment event records.

Add a migration safely if schema changes are required.

---

# 9. EVENT TIMESTAMPS

The BLE protocol timestamp has one-second resolution and MUST NOT be used as the only timing source for sub-second research metrics.

Keep protocol timestamp for packet identity/state.

For research timing, store high-resolution local event timestamps separately.

At minimum:

```text
event_timestamp_ms
```

Prefer also recording monotonic elapsed time when practical:

```text
elapsed_realtime_ms
```

On Android, monotonic time should conceptually correspond to an elapsed-realtime clock.

Do NOT put these timestamps inside the 17-byte BLE payload.

---

# 10. IMPORTANT LATENCY RULE

Do not calculate fake cross-device millisecond latency from unrelated device clocks.

Distinguish:

## LOCAL LATENCY

Safe to calculate from events occurring on the same device.

Examples:

```text
RX -> STORED latency
RX -> RELAY_QUEUED latency
RX -> ADVERTISE_STARTED latency
ACK_RECEIVED -> LOCAL_RELAY_STOPPED latency
```

## CROSS-DEVICE / END-TO-END LATENCY

Only calculate when the experiment data contains valid source and destination timestamps from synchronized/merged logs.

For example:

```text
E2E latency =
destination_first_receive_timestamp
-
source_first_advertise_timestamp
```

If the page does not have synchronized source/destination evidence, show:

```text
E2E Latency: N/A
```

or:

```text
Requires synchronized peer logs
```

Never generate an E2E value from assumptions.

---

# 11. METRICS TAB

Create metric cards.

Metrics should include:

## 11.1 Delivery Success Ratio – DSR

Definition:

```text
DSR =
successful trials / valid completed trials × 100%
```

Do not automatically treat every local RX as a globally successful experiment unless this node is configured as DESTINATION or success has been explicitly recorded.

Display:

```text
Successful : 29
Valid Trial: 30
DSR        : 96.67 %
```

---

## 11.2 End-to-End Latency

When valid data is available:

```text
E2E Latency
Latest
Min
Mean
Median
Max
```

Use milliseconds internally.

Display seconds when appropriate.

Example:

```text
Median E2E
3.420 s
```

Do not report E2E if cross-device timing evidence is unavailable.

---

## 11.3 Local Relay Processing Latency

This one can be calculated reliably on a relay device:

```text
Relay Processing Latency =
BLE_ADVERTISE_STARTED
-
BLE_PACKET_RECEIVED
```

Also optionally:

```text
RX -> DB Stored
RX -> Relay Queued
Relay Queued -> Advertise Started
```

Display:

```text
RX → Relay Start
286 ms
```

This is different from E2E latency.

Keep the labels explicit.

---

# 12. HOP METRICS

Show:

```text
Hop In
Hop Out
Max Hop Observed
Mean Hop
```

Validate hop correctness:

```text
expectedHopOut = min(hopIn + 1, 63)
```

Display:

```text
Hop Validation
PASS
```

or:

```text
FAIL
Expected : 2
Actual   : 3
```

For:

```text
Hop In  = 63
Hop Out = 63
```

validation must be PASS.

Do not interpret repeated advertising sessions as additional hops.

---

# 13. DUPLICATE METRICS

Track:

```text
Unique Accepted
Duplicate Received
Stale Received
Invalid Received
ACK Suppressed
Total Logical/Raw Receive
```

Keep `duplicate` and `stale` separate.

P8 intentionally distinguishes them.

Recommended duplicate ratio:

```text
Duplicate Ratio =
duplicate receptions
/
(all accepted + duplicate receptions)
× 100%
```

If another denominator is chosen, document it in code/comments/UI help text and use it consistently.

Do not count stale packets as duplicates.

---

# 14. TRANSMISSION METRICS

Track:

```text
TX Attempt Count
TX Success Count
Relay Slot Count
```

Do not treat a failed advertising start as successful TX.

Transmission count should preferably be based on:

```text
BLE_ADVERTISE_STARTED
```

or the equivalent successful advertiser event.

Keep:

```text
BLE_ADVERTISE_REQUESTED
```

separate from successful transmission starts.

---

# 15. TRANSMISSION OVERHEAD

Provide a clearly defined metric.

Recommended:

```text
Transmission Overhead =
successful transmission starts
/
successful deliveries
```

For a single-node local page where global successful delivery is unknown, show:

```text
N/A
```

until experiment result data exists.

Do not invent successful delivery counts.

If logs from multiple nodes are eventually merged, this metric can represent experiment-wide overhead.

---

# 16. RSSI METRICS

Display:

```text
Current RSSI
Min RSSI
Mean RSSI
Median RSSI
Max RSSI
Sample Count
```

RSSI remains an observational metric.

Do NOT convert RSSI directly into meters.

Do not display:

```text
-70 dBm = 8 m
```

unless a separate calibrated research model is later implemented.

---

# 17. ACK METRICS

Display:

```text
ACK Received
ACK Accepted
ACK Duplicate
ACK Stale
ACK Invalid
```

Add:

```text
Local ACK Response Latency
```

if measurable locally.

For experiment-wide:

```text
ACK Termination Latency
```

define it carefully as:

```text
time when terminal ACK is generated/first observed
to
time when the target SOS relay is confirmed terminated
```

Only calculate when both events exist.

Do not treat normal CANCELLED SOS state and ACK packet as identical unless the existing protocol explicitly represents the event as ACK.

Preserve P8 semantics.

---

# 18. CURRENT TRIAL RESULT

At the end of a trial, allow result classification:

```text
SUCCESS
FAILED
INVALID
```

Optional failure reason:

```text
NO_DELIVERY
TIMEOUT
USER_ERROR
DEVICE_ERROR
BLUETOOTH_ERROR
OTHER
```

Do not delete failed trials.

They are research data.

---

# 19. TRIAL TIMEOUT

Allow an optional research timeout configured per session, for example:

```text
60 seconds
120 seconds
300 seconds
```

This timeout is ONLY for deciding experiment trial outcome.

It MUST NOT become:

* BLE packet TTL;
* forwarding TTL;
* relay queue TTL;
* ACK TTL.

This distinction is critical.

Example:

```text
Experiment trial timeout = 60 seconds
```

may mark:

```text
Trial result = FAILED / NO_DELIVERY
```

but the underlying ResQMesh forwarding protocol must not be changed by it.

---

# 20. EVENTS TAB

Create a live event timeline.

Example:

```text
14:31:01.120  SOS_CREATED
14:31:01.184  BLE_ADVERTISE_STARTED

14:31:02.782  BLE_PACKET_RECEIVED
                sender=C6A299A9
                status=ACTIVE
                hop=1
                RSSI=-67

14:31:02.816  BLE_PACKET_STORED

14:31:02.840  BLE_RELAY_QUEUED
                hop_out=2

14:31:03.104  BLE_RELAY_STARTED
                hop=2

14:31:05.220  BLE_PACKET_DUPLICATE

14:31:09.120  BLE_PACKET_STALE

14:31:12.700  ACK_RECEIVED
```

Provide filters:

```text
ALL
RX
TX
RELAY
DUPLICATE
STALE
ACK
ERROR
SYSTEM
```

Limit rendering so thousands of events do not freeze the UI.

Use pagination/lazy list/recent-event limit.

All events must remain stored/exportable even if only the latest subset is rendered.

---

# 21. EXPERIMENT EVENT FIELDS

Where feasible, research events should contain:

```text
session_id
trial_id

device_id
node_role

event_timestamp_ms
elapsed_realtime_ms

event_type

message_id
sender_crc
protocol_timestamp

packet_type
status

hop_in
hop_out

rssi

payload_hash

relay_count
duplicate_count

queue_size
sos_queue_size
ack_queue_size

forwarding_mode
```

Do not require every event to populate every field.

Use null when not applicable.

---

# 22. METRIC CALCULATION SERVICE

Do not calculate all research metrics directly in widget code.

Create a dedicated service, for example:

```text
ExperimentMetricsService
```

or:

```text
ResearchMetricsService
```

Responsibilities:

```text
load events for session/trial
calculate counts
calculate distributions
calculate latency
calculate DSR
calculate duplicate ratio
calculate RSSI statistics
calculate hop validation
calculate ACK statistics
calculate transmission metrics
```

The UI should consume a model such as:

```text
ExperimentMetrics
```

This makes the thesis calculations testable.

---

# 23. STATISTICAL SUMMARY

Implement reusable statistical helpers for numeric samples:

```text
count
min
max
mean
median
```

Optional:

```text
standard deviation
p95
```

Do not add p95 unless implemented correctly and tested.

Median calculation must work correctly for odd and even sample counts.

---

# 24. METRICS SCOPE

The UI must clearly label metric scope.

Possible scopes:

```text
CURRENT TRIAL
CURRENT SESSION
LOCAL DEVICE
```

Do not label a local-device metric as network-wide.

Example:

```text
Local TX Count
```

instead of simply:

```text
Total Network TX
```

unless peer data has genuinely been merged.

---

# 25. OPTIONAL PEER LOG IMPORT / AGGREGATION

If implementing this does not destabilize the task, add support for importing previously exported ResQMesh experiment JSON/CSV from another node.

This is OPTIONAL.

Do not block the main P9 task on it.

If implemented, imported data must be associated with:

```text
session_id
trial_id
device_id
node_role
```

Then the Research Monitor may calculate true cross-node values such as:

```text
E2E latency
total network TX
network transmission overhead
per-hop timeline
```

But only if matching trial data exists.

If peer import is not implemented, clearly show:

```text
Network-wide metrics require merged peer logs.
```

---

# 26. TRIAL CODE CONSISTENCY

Since BLE payload must not be changed, session/trial IDs are NOT transported inside the ResQMesh packet.

Therefore do not assume a receiving node automatically knows the remote trial ID.

For physical experiments, allow the researcher to configure matching:

```text
session code
trial number
```

manually on each participating Android research node.

Example:

```text
Session: CTRL-H3
Trial  : 007
```

This metadata is for log correlation only.

Do not encode it into the 17-byte BLE packet.

---

# 27. EXPORT

Existing CSV/JSON export should be extended to include research session/trial metadata.

Export at least:

```text
session
trial
events
metrics/raw fields
```

Prefer exporting RAW events rather than only calculated summary values.

Calculated metrics must always be reproducible from the raw experiment data.

Add buttons:

```text
EXPORT CURRENT TRIAL CSV
EXPORT SESSION CSV
EXPORT SESSION JSON
```

If the existing export architecture makes separate buttons impractical, a smaller set is acceptable, but trial/session identifiers must be included in exported records.

---

# 28. CSV FIELDS

Recommended CSV columns:

```text
session_id
session_name
trial_id
trial_number
trial_status

device_id
node_role

forwarding_mode
target_hop
topology_label
scenario_label

event_timestamp_ms
event_timestamp_iso
elapsed_realtime_ms

event_type

message_id
sender_crc
protocol_timestamp

packet_type
status

hop_in
hop_out

rssi

payload_hash

relay_count
duplicate_count

queue_size
sos_queue_size
ack_queue_size

detail
```

Use stable column names.

---

# 29. RESEARCH MONITOR UI EXAMPLE

Conceptually:

```text
┌───────────────────────────────────────┐
│ RESQMESH RESEARCH MONITOR             │
├───────────────────────────────────────┤
│ CTRL-H3                  RUNNING      │
│ Trial 07 / 30                         │
│ Controlled Epidemic | Relay | Hop 3  │
├───────────────────────────────────────┤
│ DSR           Relay Latency           │
│ 96.67%        286 ms                  │
│                                       │
│ Duplicate     TX Success              │
│ 18            24                      │
│                                       │
│ RSSI          Hop                     │
│ -67 dBm       IN 1 → OUT 2 ✓          │
├───────────────────────────────────────┤
│ CURRENT PACKET                        │
│ C6A299A9 | ACTIVE | SOS               │
│ hop 1 → 2 | RSSI -67 dBm              │
├───────────────────────────────────────┤
│ 14:31:02.782 PACKET_RECEIVED          │
│ 14:31:02.816 PACKET_STORED            │
│ 14:31:03.104 RELAY_STARTED            │
├───────────────────────────────────────┤
│ [ END TRIAL ]   [ INVALIDATE ]        │
└───────────────────────────────────────┘
```

Use the existing ResQMesh design language.

Do not introduce a visually unrelated UI framework.

---

# 30. RESEARCH MODE SAFETY

The Research Monitor may expose debug details such as:

```text
sender CRC
payload hash
RSSI
queue state
```

But avoid making these details prominent in the normal emergency user flow.

Research Monitor should only be reachable intentionally.

Do not expose internal test controls accidentally on the normal SOS screen.

---

# 31. PERFORMANCE

Experiment logging must not significantly disturb BLE timing.

Avoid:

* synchronous disk writes on the UI thread;
* excessive setState for every raw packet;
* rendering thousands of timeline rows;
* expensive metrics recalculation for every BLE advertisement.

Use:

* batched/reasonable UI refresh;
* asynchronous SQLite;
* cached metric summaries where useful;
* periodic live refresh such as 500 ms–2 s if appropriate.

Do not artificially delay BLE processing just for the monitor.

The research instrumentation must observe the system, not substantially change the system under test.

---

# 32. DUPLICATE LOGGING CAUTION

Persistent BLE advertising may create many duplicate receptions.

Do not create unbounded UI/log spam.

Raw duplicate statistics must remain accurate, but consider aggregating repeated exact duplicates into:

```text
duplicate_count
first_seen
last_seen
```

where the existing architecture permits.

Do not change logical deduplication semantics.

---

# 33. REQUIRED AUTOMATED TESTS

Add tests for the research metrics.

At minimum:

### Session/trial

1. create session;
2. create trial;
3. trial numbering increments correctly;
4. invalid trial remains stored;
5. events are associated with correct session/trial.

### Statistics

6. mean correct;
7. median odd count correct;
8. median even count correct;
9. min/max correct;
10. empty sample returns null/N/A safely.

### DSR

11. 29 successes / 30 valid trials = approximately 96.67%;
12. INVALID trials excluded from denominator.

### Duplicate

13. accepted + duplicate counts produce correct duplicate ratio;
14. stale events are NOT counted as duplicates.

### Hop

15. hop 0 → 1 PASS;
16. hop 1 → 2 PASS;
17. hop 63 → 63 PASS;
18. hop 1 → 3 FAIL.

### Latency

19. local `RX → RELAY_STARTED` latency calculated correctly;
20. missing event produces N/A;
21. E2E must not be fabricated without both source and destination evidence.

### RSSI

22. min/mean/median/max correct.

### ACK

23. duplicate ACK count separate;
24. stale ACK count separate;
25. ACK termination latency only calculated when required events exist.

### Transmission

26. `BLE_ADVERTISE_REQUESTED` is not automatically counted as successful TX;
27. `BLE_ADVERTISE_STARTED` counts as successful TX.

### Protocol regression

28. 17-byte protocol known vector still passes;
29. hop saturation remains 63;
30. Manufacturer ID remains `0xFFFF`.

---

# 34. DO NOT MAKE THESE MISTAKES

Do NOT:

* add trial ID into BLE payload;
* increase BLE payload beyond 17 bytes;
* replace protocol timestamp with millisecond timestamp;
* use RSSI as direct distance;
* treat relayCount as hop count;
* treat advertisement repetitions as additional hops;
* calculate E2E latency from unsynchronized clocks;
* classify stale packets as duplicate;
* count `BLE_ADVERTISE_REQUESTED` as successful TX;
* use experiment timeout as packet TTL;
* mark physical tests as PASS;
* create fake/default metrics when data is unavailable.

Use:

```text
N/A
Not enough data
Requires peer log
NOT RUN
```

where appropriate.

---

# 35. DOCUMENTATION

Add:

```text
docs/research_monitor.md
```

Document:

* purpose of the Research Monitor;
* meaning of every metric;
* exact formula;
* metric scope;
* limitations;
* timestamp limitations;
* clock synchronization warning;
* difference between protocol timestamp and experiment event time;
* local vs network-wide metrics;
* trial workflow;
* export workflow.

Include formulas such as:

```text
DSR =
successful valid trials
-----------------------
total valid trials
× 100%
```

```text
Duplicate Ratio =
duplicate receptions
------------------------------
accepted + duplicate receptions
× 100%
```

```text
Local Relay Processing Latency =
BLE_ADVERTISE_STARTED timestamp
-
BLE_PACKET_RECEIVED timestamp
```

```text
Hop Correctness:
hop_out = min(hop_in + 1, 63)
```

For Transmission Overhead, clearly document the selected denominator.

---

# 36. PHYSICAL TEST DOCUMENT

Do NOT mark scenarios A–K in:

`docs/p7_physical_background_validation.md`

as PASS.

You may update the document to mention that Research Monitor can now be used to collect evidence.

For example:

```text
Evidence can be collected using Research Monitor session/trial export.
```

But all physical test status remains:

```text
NOT RUN
```

until actual physical-device testing is performed.

---

# 37. REQUIRED FINAL CODEX REPORT

After implementation provide:

## A. Starting commit

Report the exact commit used.

## B. Changed files

List all changed/added files with short explanations.

## C. Database changes

Explain migrations and compatibility with existing installs.

## D. Research Monitor features

Report implemented:

```text
LIVE
METRICS
TRIAL
EVENTS
SYSTEM
```

and any intentionally omitted feature.

## E. Metrics implemented

Explicitly list:

* DSR
* local relay latency
* E2E latency status
* duplicate count/ratio
* stale count
* transmission count
* transmission overhead
* hop metrics
* RSSI statistics
* ACK metrics
* queue metrics

For each metric state whether it is:

```text
LOCAL
SESSION
NETWORK-WIDE
REQUIRES PEER LOG
```

## F. Tests

List each new test.

## G. Commands actually executed

Run and report real results:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
flutter build apk --debug \
  --dart-define=RESQMESH_MODE=offline \
  --dart-define=RESQMESH_FORWARDING_MODE=controlled_epidemic \
  --dart-define=RESQMESH_BLE_DEBUG_VISIBLE=true
```

Native Android tests:

```text
:app:testDebugUnitTest
```

Do not fabricate success.

## H. GitHub Actions

Only claim remote GitHub Actions PASS if an actual remote run is verifiable.

Otherwise:

```text
Remote GitHub Actions status not verified.
```

## I. Protocol invariants

Confirm that P9 did NOT change:

```text
17-byte payload
0xFFFF Manufacturer ID
52 4D header
CRC32 layout
uint24 timestamp
coordinate encoding
status byte
ACK/fromServer/hop bit layout
hop saturation 63
non-connectable advertising
Controlled Epidemic
Basic Flooding
ACK tombstone
persistent relay queue
no hard TTL
```

## J. Physical tests

Keep:

```text
Scenario A: NOT RUN
Scenario B: NOT RUN
Scenario C: NOT RUN
Scenario D: NOT RUN
Scenario E: NOT RUN
Scenario F: NOT RUN
Scenario G: NOT RUN
Scenario H: NOT RUN
Scenario I: NOT RUN
Scenario J: NOT RUN
Scenario K: NOT RUN
```

unless real physical-device evidence is separately supplied.

---

# 38. FINAL GOAL

After P9, the researcher should be able to do:

```text
Open Research Monitor
↓
Create Session
↓
Select:
Controlled Epidemic
Relay
Target Hop 3
↓
Start Trial 1
↓
Run physical experiment
↓
Watch:
RX
RSSI
hop
queue
relay
duplicates
stale
ACK
latency
↓
End Trial
↓
Mark SUCCESS / FAILED / INVALID
↓
Next Trial
↓
Repeat until 30 trials
↓
Export session CSV/JSON
```

The page should make thesis data collection easier while preserving the actual ResQMesh protocol and BLE behavior being studied.

P9 is an instrumentation/research usability task, not a routing redesign.
