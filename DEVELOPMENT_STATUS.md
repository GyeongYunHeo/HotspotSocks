# Development Status

## Phase 0 — Project bootstrap

Status: IMPLEMENTED

- SwiftUI iOS 26.0 application project
- Network.framework and OSLog
- Local Network usage description
- Unit-test target and initial settings test

Build evidence (2026-09-14):

- Generic iOS device Debug build: PASS (`CODE_SIGNING_ALLOWED=NO`)
- Generic iOS Simulator Debug build-for-testing: PASS
- Unit test bundle compilation: PASS
- Unit test execution: NOT RUN (CoreSimulatorService unavailable in the build environment)

## Phase 1 — Personal Hotspot listener

Status: PASS ON PHYSICAL DEVICE

Implemented and verified:

- `NWListener` TCP echo server on configured port `9876`
- Listener reaches `ready`
- Android connects to iPhone through Personal Hotspot
- Android can establish a TCP connection to the iPhone hotspot gateway on port `9876`
- Client endpoint is correctly reported by the iPhone app
- TCP payload is received by the iPhone app
- Received payload is echoed back to the Android client
- Receive-after-send backpressure path is functioning
- 64 KiB receive chunk configuration active
- Start/Stop/status/port UI implemented

Physical-device evidence:

```text
Device: iPhone 14 Pro
OS: iOS 26.5
Android client: Physical Android device
Hotspot client IP: 172.20.10.2
Proxy port: 9876

Listener:
Echo listener ready on port 9876

Connection:
Accepted 68A04E6E-01D0-471E-BE62-A03E4D1AFFB6 from 172.20.10.2:44592

Traffic:
Echoing 6 bytes for 68A04E6E-01D0-471E-BE62-A03E4D1AFFB6
Echoing 5 bytes for 68A04E6E-01D0-471E-BE62-A03E4D1AFFB6

Result: PASS
```

Conclusion:

Personal Hotspot downstream clients can establish inbound TCP connections to an `NWListener` running inside the native iOS application.

Phase 1 feasibility gate is satisfied.

Proceed to Phase 2 — SOCKS5.

## Phase 2 — SOCKS5

Status: CORE FUNCTIONALITY PASS ON PHYSICAL DEVICE — FINAL EDGE-CASE VERIFICATION REMAINS

### Implemented

- Incremental SOCKS5 greeting and CONNECT request parser
- Fragmented and coalesced message handling
- NO AUTH method negotiation
- Unsupported authentication rejection with `05 FF`
- CONNECT parsing for IPv4, DOMAIN, and IPv6
- Network-byte-order port parsing
- Bounded incomplete-handshake buffer
- Explicit SOCKS5 session state machine
- Success reply only after upstream connection reaches `ready`
- Correct rejection reply for unsupported commands/address types
- Preservation of application payload coalesced after CONNECT
- Active session registry with 32-client limit
- Event-driven upstream connection and TCP relay
- Clean session shutdown/removal

### Build evidence

```text
Generic iOS Simulator Debug build-for-testing: PASS
Generic iOS device Debug build: PASS
Unit test bundle compilation: PASS

Unit test execution:
NOT RUN in the development environment because no usable
CoreSimulator/device test destination was available.
```

---

### Physical-device test environment

```text
Device: iPhone 14 Pro
OS: iOS 26.5

Client:
Physical Android device / Termux

Personal Hotspot client IP:
172.20.10.2

SOCKS5 server:
172.20.10.1:9876
```

Phase 1 Personal Hotspot inbound TCP connectivity had already been verified before SOCKS5 testing.

---

## Physical-device verification summary

### SOCKS5 transport and session

```text
[x] TCP client accepted through Personal Hotspot
[x] Independent Socks5Session created for each client
[x] Client connection reaches ready state
[x] Session state transitions operate correctly
[x] Session cleanup/removal after connection termination
```

Result:

```text
PASS
```

---

### SOCKS5 Greeting / authentication

Verified:

```text
[x] SOCKS5 greeting
[x] NO AUTH negotiation
[x] Server response 05 00
[x] Unsupported authentication rejection
[x] Server response 05 FF
[x] Fragmented greeting
```

Controlled NO AUTH request:

```text
05 01 00
```

Observed response:

```text
05 00
```

Result:

```text
PASS
```

Unsupported authentication request produced:

```text
05 FF
```

Result:

```text
PASS
```

Byte-wise fragmented greeting also produced a valid:

```text
05 00
```

response.

Result:

```text
PASS
```

---

## IPv4 CONNECT

A separately transmitted IPv4 CONNECT request was tested on the physical device.

Expected destination:

```text
1.1.1.1:443
```

The server correctly parsed and attempted the IPv4 destination.

Result:

```text
IPv4 CONNECT parsing: PASS
```

---

## DOMAIN CONNECT

An earlier physical-device defect caused a controlled request for:

```text
example.com:443
```

to be incorrectly decoded as:

```text
Host: empty
Port: 25455
```

The root cause was identified as non-zero `Data.startIndex` handling after `Data.removeFirst()`.

The parser was changed so that IPv4, DOMAIN and IPv6 address slices and port reads all translate protocol-relative offsets through the current buffer `startIndex`.

Following the parser fix, a real SOCKS5 hostname request was executed:

```bash
curl -v \
  --socks5-hostname 172.20.10.1:9876 \
  https://example.com/
```

Observed server path:

```text
Accepted client
client ready
greeting -> request
request -> connecting
connecting to example.com:443
connecting -> relaying
```

The destination was therefore correctly decoded as:

```text
example.com:443
```

Result:

```text
DOMAIN CONNECT parsing: PASS
DOMAIN upstream connection: PASS
```

---

## HTTPS / TLS relay

The following command was tested through the iPhone SOCKS5 server:

```bash
curl -v \
  --socks5-hostname 172.20.10.1:9876 \
  https://example.com/
```

Observed client-side results:

```text
SOCKS connection opened to example.com:443

TLSv1.3 handshake completed

Certificate:
CN=example.com

OpenSSL verification:
PASS

ALPN:
HTTP/2

HTTP response:
HTTP/2 200
```

The complete HTML response body was successfully received.

Verified path:

```text
Android
   ↓
Personal Hotspot
   ↓
iPhone NWListener
   ↓
SOCKS5 Greeting
   ↓
DOMAIN CONNECT example.com:443
   ↓
NWConnection upstream
   ↓
SOCKS CONNECT success
   ↓
Bidirectional TCP relay
   ↓
TLS 1.3
   ↓
HTTP/2
   ↓
example.com
```

Result:

```text
HTTPS traffic: PASS
TLS relay: PASS
HTTP/2 traffic: PASS
Bidirectional TCP relay: PASS
```

---

## Unsupported command handling

An unsupported SOCKS5 command was sent intentionally.

Observed client output:

```text
Greeting: 0500
Reply: 0507000100...
```

The significant reply bytes are:

```text
05 07
```

which indicate:

```text
SOCKS version 5
Command not supported
```

Observed server lifecycle:

```text
request -> closing
closing -> closed
Removed SOCKS5 session
```

Result:

```text
Unsupported command rejection: PASS
Error-path session cleanup: PASS
```

---

## IPv6 destination

IPv6 CONNECT acceptance was tested using a SOCKS5 request with:

```text
ATYP = 0x04
```

The server correctly decoded the IPv6 destination and port.

Result:

```text
IPv6 CONNECT acceptance: PASS
IPv6 destination parsing: PASS
```

A real IPv6 upstream relay test was also completed successfully.

Verified path:

```text
Android SOCKS5 client
   ↓
IPv6 CONNECT
   ↓
iPhone SOCKS5 parser
   ↓
IPv6 NWConnection upstream
   ↓
SOCKS success reply
   ↓
Bidirectional relay
   ↓
IPv6 destination
```

Result:

```text
IPv6 upstream CONNECT: PASS
IPv6 TCP relay: PASS
```

Therefore:

```text
IPv4 destination: PASS
DOMAIN destination: PASS
IPv6 destination: PASS
```

---

## Disconnect / cleanup handling

Multiple sequential HTTPS SOCKS sessions were tested.

Example lifecycle:

```text
connecting -> relaying
relaying -> closing
closing -> closed
Removed SOCKS5 session
```

After the first connection terminated, a subsequent SOCKS5 connection was accepted and relayed normally.

Verified:

```text
[x] Client disconnect detected
[x] Upstream termination handled
[x] Session transitions to closing
[x] Session transitions to closed
[x] Session removed from active registry
[x] Subsequent connection works normally
[x] No crash observed
[x] No stuck session observed
```

Result:

```text
Client/upstream disconnect handling: PASS
Session registry cleanup: PASS
```

Network.framework occasionally logs:

```text
is already cancelled, ignoring cancel
```

during cleanup.

This indicates duplicate/idempotent cancellation attempts but did not cause:

```text
- application crash
- stuck sessions
- registry leak
- subsequent connection failure
```

It is currently classified as:

```text
NON-BLOCKING CLEANUP ISSUE
```

and may be cleaned up in a later robustness pass.

---

## Multiple concurrent connections

A test with ten simultaneous curl clients was performed:

```bash
for i in $(seq 1 10); do
    curl -s \
      --socks5-hostname 172.20.10.1:9876 \
      https://example.com/ >/dev/null &
done

wait
```

Server evidence showed ten independent clients:

```text
10 Accepted connections
10 unique session UUIDs
10 client-ready states
10 greeting -> request transitions
10 request -> connecting transitions
10 connections to example.com:443
10 connecting -> relaying transitions
```

Therefore the following have been physically verified:

```text
Concurrent TCP accept: PASS
Concurrent SOCKS5 negotiation: PASS
Independent session allocation: PASS
Concurrent upstream connection creation: PASS
Concurrent relay startup: PASS
Failed-session cleanup: PASS
Application stability under 10 simultaneous sessions: PASS
```

Several sessions later produced:

```text
Network.NWError error 50 - Network is down
```

during the concurrent test.

Those sessions nevertheless transitioned correctly through:

```text
relaying -> closing
closing -> closed
Removed SOCKS5 session
```

with no application crash or session-registry corruption.

Current concurrent-test result:

```text
SOCKS5 concurrency architecture: PASS

10/10 successful end-to-end HTTP requests:
NOT YET CONFIRMED
```

The remaining concurrency acceptance test should record the exit code of all ten curl processes and confirm:

```text
10 successful
0 failed
```

before marking end-to-end concurrent traffic as fully PASS.

---

## Parser defects discovered during physical-device testing

Two parser defects were initially discovered.

### Defect 1 — DOMAIN indexing

Expected:

```text
example.com:443
```

Observed before fix:

```text
:25455
```

`25455 == 0x636F`, which corresponds to ASCII:

```text
co
```

from inside:

```text
example.com
```

Root cause:

```text
Incorrect absolute Data indexes after Data.removeFirst()
left the buffer with a non-zero startIndex.
```

### Defect 2 — Coalesced buffer indexing

A combined:

```text
Greeting + IPv4 CONNECT
```

intended for:

```text
1.1.1.1:443
```

was previously decoded as:

```text
1.0.1.1:257
```

The same non-zero `Data.startIndex` issue affected address and port reads after greeting bytes were consumed.

### Parser fix

Implemented:

```text
- IPv4 slices use offsets relative to buffer.startIndex
- DOMAIN slices use offsets relative to buffer.startIndex
- IPv6 slices use offsets relative to buffer.startIndex
- Port bytes use the same relative-offset helper
- Exact failing physical-device packets added as regression cases
```

Standalone regression execution after the fix:

```text
DOMAIN payload:
example.com:443 — PASS

Coalesced IPv4 payload:
1.1.1.1:443 — PASS
```

---

## Current Phase 2 acceptance matrix

```text
Personal Hotspot TCP accept              PASS
SOCKS5 session creation                  PASS
SOCKS5 Greeting                          PASS
NO AUTH negotiation                      PASS
NO AUTH reply 05 00                      PASS
Unsupported authentication 05 FF        PASS
Fragmented Greeting                      PASS

IPv4 CONNECT                             PASS
DOMAIN CONNECT                           PASS
IPv6 CONNECT                             PASS

Unsupported command reply 05 07         PASS

DOMAIN upstream CONNECT                  PASS
IPv6 upstream CONNECT                    PASS

HTTPS traffic                            PASS
TLS 1.3 relay                            PASS
HTTP/2 traffic                           PASS
Bidirectional TCP relay                  PASS

Client disconnect handling               PASS
Upstream disconnect handling             PASS
Session registry cleanup                 PASS

10 concurrent client acceptance          PASS
10 concurrent SOCKS5 negotiations        PASS
10 concurrent upstream/relay startup     PASS

10/10 concurrent end-to-end requests     NOT YET CONFIRMED

Coalesced Greeting + CONNECT
exact physical-device regression retest  NOT YET RECORDED
```

---

## Remaining Phase 2 verification

Only the following verification items remain before Phase 2 can be marked fully complete.

### 1. Coalesced exact-payload physical-device retest

Re-run:

```text
05 01 00
05 01 00 01
01 01 01 01
01 BB
```

Expected:

```text
Greeting reply:
05 00

Destination:
1.1.1.1:443
```

This has already passed standalone regression execution after the parser fix, but a post-fix physical-device result has not yet been recorded.

### 2. Concurrent 10/10 success confirmation

Run the concurrent test while recording each curl exit code.

Target result:

```text
Request 1  exit=0
Request 2  exit=0
Request 3  exit=0
...
Request 10 exit=0
```

Acceptance:

```text
10 successful
0 failed
```

---

## Phase 2 conclusion

Physical-device testing demonstrates that the SOCKS5 implementation can successfully perform:

```text
Android
   ↓
iPhone Personal Hotspot
   ↓
NWListener
   ↓
SOCKS5 Greeting / NO AUTH
   ↓
IPv4 / DOMAIN / IPv6 CONNECT
   ↓
NWConnection upstream
   ↓
Bidirectional TCP relay
   ↓
TLS / HTTPS / HTTP2
   ↓
Internet
```

Current overall Phase 2 status:

```text
SOCKS5 protocol core: PASS

IPv4: PASS
DOMAIN: PASS
IPv6: PASS

Upstream connection: PASS
HTTPS relay: PASS
Disconnect cleanup: PASS

Concurrent session handling: PASS
Concurrent 10/10 end-to-end success:
FINAL VERIFICATION REMAINS

Coalesced post-fix physical-device regression:
FINAL VERIFICATION REMAINS
```

Phase 2 should therefore remain:

```text
Status:
CORE FUNCTIONALITY PASS ON PHYSICAL DEVICE —
FINAL EDGE-CASE VERIFICATION REMAINS
```

Once the two remaining verification items pass, update the status to:

```text
Status: PASS ON PHYSICAL DEVICE
```

and proceed to the next implementation phase.

## Phase 3 — TCP relay

Status: PASS ON PHYSICAL DEVICE

### Implemented

- Event-driven bidirectional TCP relay
- 64 KiB maximum receive chunks
- Receive-after-send backpressure
- Session-scoped activity-rescheduled `DispatchSourceTimer`
- No polling loop
- Handshake receive activity refreshes the idle timeout
- Protocol send activity refreshes the idle timeout
- Upstream readiness refreshes the idle timeout
- Preserved initial payload activity refreshes the idle timeout
- Relay traffic in both directions refreshes the idle timeout
- Default idle timeout: 1,800 seconds (`AppSettings.idleTimeout`)
- Maximum concurrent session count and idle timeout validation at server start
- `Socks5Session` owns connection cancellation
- `RelayPipe` pumps traffic and reports directional completion/failure
- Independent upload/download relay lifecycle management
- Half-close propagation using final messages
- Idempotent per-direction completion
- Whole-relay completion only after both relay directions finish
- Session cleanup/removal after relay termination

### Build verification

```text
Generic iOS Simulator build-for-testing: PASS
Generic iOS device arm64 unsigned build: PASS
Swift source warnings: NONE
AppIntents metadata warning: PRESENT, NON-BLOCKING
XCTest execution: NOT RUN — CoreSimulator runtime unavailable in the development environment
```

---

### Physical-device test environment

```text
Device:
iPhone 14 Pro

OS:
iOS 26.5

Client:
Physical Android device / Termux

Personal Hotspot client IP:
172.20.10.2

SOCKS5 server:
172.20.10.1:9876
```

For idle-timeout testing, the configured timeout was temporarily reduced to a short test value.

Production default:

```text
idleTimeout = 1800 seconds
```

---

## Physical-device verification summary

### 1. Basic bidirectional relay regression

SOCKS5 HTTPS traffic was tested through the physical iPhone.

Verified path:

```text
Android
   ↓
Personal Hotspot
   ↓
iPhone NWListener
   ↓
SOCKS5
   ↓
NWConnection upstream
   ↓
Bidirectional TCP relay
   ↓
HTTPS / TLS
   ↓
Internet
```

Verified:

```text
SOCKS5 CONNECT                    PASS
Upstream connection               PASS
Bidirectional TCP relay           PASS
HTTPS traffic                     PASS
TLS traffic                       PASS
HTTP traffic                      PASS
Application stability             PASS
```

Result:

```text
PASS
```

---

### 2. Idle expiry

A SOCKS5 relay was established and intentionally left idle for longer than the configured test timeout.

Observed lifecycle:

```text
relaying
   ↓
no traffic for one timeout interval
   ↓
idle timeout
   ↓
closing
   ↓
closed
   ↓
Removed SOCKS5 session
```

Verified:

```text
Idle timer activation              PASS
Idle connection expiration         PASS
Session transition to closing      PASS
Session transition to closed       PASS
Session registry removal           PASS
No crash                           PASS
No stuck session                   PASS
```

Result:

```text
PASS
```

---

### 3. Activity refresh

A SOCKS5 relay was kept open while traffic was generated more frequently than the configured idle timeout.

The session remained active while traffic continued.

After traffic stopped, the session expired after one complete idle-timeout interval.

Verified:

```text
Traffic prevents idle expiry       PASS
Relay activity refreshes timeout   PASS
No false idle timeout              PASS
Idle expiry after activity stops   PASS
Session cleanup                    PASS
```

Result:

```text
PASS
```

---

### 4. Idle-timeout timing

The configured short physical-test timeout was compared with the observed expiration time.

Verified:

```text
Configured timeout honored         PASS
No premature expiration            PASS
No excessive expiration delay      PASS
```

Result:

```text
PASS
```

---

### 5. Client disconnect regression

The SOCKS client was disconnected while the relay was active.

Expected and observed lifecycle:

```text
relaying
   ↓
client disconnect
   ↓
closing
   ↓
closed
   ↓
Removed SOCKS5 session
```

Verified:

```text
Client disconnect detection        PASS
Relay shutdown                     PASS
Session cleanup                    PASS
Session registry removal           PASS
Idle timer cancellation            PASS
No delayed idle callback           PASS
No crash                           PASS
```

Result:

```text
PASS
```

---

### 6. Upstream disconnect regression

The upstream side was allowed to terminate the connection after completing its response.

The client received the expected response data and the session subsequently shut down cleanly.

Verified:

```text
Upstream termination detection     PASS
Remaining traffic delivery         PASS
Session shutdown                   PASS
Session registry cleanup           PASS
No crash                           PASS
```

Result:

```text
PASS
```

---

### 7. Half-close propagation

Initial half-close testing used `example.com:80`.

Those tests produced inconsistent results, including zero-byte responses.

Further analysis showed that the same request sent directly to resolved `example.com` IPv4 addresses could also produce zero-byte responses after `SHUT_WR`.

Therefore `example.com:80` was determined to be unsuitable as a deterministic half-close acceptance target.

Relay lifecycle handling was subsequently hardened with:

```text
- Independent upload and download states
- pumping / propagatingEOF / finished directional states
- Idempotent per-direction completion
- Whole-relay completion only after both directions finish
- Directional receive / EOF / completion logging
- No premature whole-session teardown when only one direction finishes
```

A deterministic TCP test server was introduced which waits for client EOF before generating its response.

Test server:

```text
Target:
172.20.10.4:18080

Behavior:
Receive request
→ wait for TCP EOF
→ generate HTTP response
→ close connection
```

SOCKS5 path:

```text
Android / Termux
   ↓
SOCKS5 172.20.10.1:9876
   ↓
iPhone HotspotSocks
   ↓
172.20.10.4:18080
```

The client sent a 66-byte HTTP request and then performed:

```text
shutdown(SHUT_WR)
```

The client continued reading after closing only its write direction.

Observed client result:

```text
=== Phase 3 deterministic half-close test ===
SOCKS5 proxy : 172.20.10.1:9876
Target       : 172.20.10.4:18080

[1] Connected to SOCKS5 proxy
[2] Greeting reply: 0500
[3] SOCKS CONNECT success -> 172.20.10.4:18080
[4] Sending 66 request bytes
[5] Client SHUT_WR performed
[6] Waiting for response after half-close...

======================================
RESULT
======================================
Received: 70 bytes

HTTP/1.1 200 OK
Content-Length: 12
Connection: close

received=66

======================================
ACCEPTANCE
======================================
Response bytes > 0 : PASS
HTTP/1.1 200 OK    : PASS
received= body     : PASS

FINAL RESULT: PASS
```

Observed deterministic upstream result:

```text
served 172.20.10.1:58536 after EOF; request=66 response=70
```

This proves the following complete sequence:

```text
Android sends 66-byte request
   ↓
iPhone relays request upstream
   ↓
Android performs SHUT_WR
   ↓
iPhone propagates write-side EOF upstream
   ↓
172.20.10.4 observes complete request + EOF
   ↓
172.20.10.4 generates 70-byte HTTP response after EOF
   ↓
iPhone keeps reverse relay active
   ↓
Android receives complete 70-byte response
```

Verified:

```text
SOCKS5 Greeting                         PASS
SOCKS5 CONNECT                          PASS

Client request before SHUT_WR           66 bytes
Client SHUT_WR                          PASS

Upstream received complete request      PASS
Upstream observed TCP EOF               PASS
Response generated only after EOF       PASS

Reverse relay after SHUT_WR             PASS
Client response received                70 bytes
HTTP/1.1 200 OK                         PASS
Response body received                  PASS
Response body contains received=66      PASS

Half-close propagation                  PASS
Half-close response preservation        PASS
Directional relay lifecycle             PASS
```

Result:

```text
PASS ON PHYSICAL DEVICE
```

Conclusion:

The client-to-upstream write direction can terminate independently while the upstream-to-client relay remains operational.

The deterministic upstream received the complete request and EOF before generating a response, and the complete response was subsequently relayed back through the iPhone to the Android client.

Half-close propagation is therefore accepted on the physical device.

---

### 8. Large relay / backpressure

A browser configured to use:

```text
SOCKS5 172.20.10.1:9876
```

was used to run a full `speedtest.net` test.

Both download and upload completed successfully.

Verified:

```text
Large downstream relay             PASS
Large upstream relay               PASS
64 KiB receive path                PASS
Receive-after-send backpressure    PASS
No relay stall                     PASS
No unexpected idle timeout         PASS
No application crash               PASS
```

Result:

```text
PASS
```

---

### 9. Sustained upload / download traffic

The browser-based Speedtest generated sustained bulk traffic in both relay directions.

Verified:

```text
Android -> iPhone -> Internet       PASS
Internet -> iPhone -> Android       PASS
Bulk upload traffic                 PASS
Bulk download traffic               PASS
Relay stability under load          PASS
```

Result:

```text
PASS
```

---

## Native Speedtest application stress test

The native Android Speedtest application was also tested through the SOCKS5 server.

### Initial test with 32-client limit

Configuration:

```text
maximumClients = 32
```

The native Speedtest application generated more parallel TCP connections than the configured session limit.

Observed:

```text
Rejected connection because the 32-client limit was reached
```

Subsequent streams produced errors including:

```text
Broken pipe
Connection reset by peer
Network is down
```

Result:

```text
FAIL — CONFIGURED SESSION LIMIT REACHED
```

This was determined to be a configured concurrency-limit issue rather than a relay-throughput failure.

### Retest with 128-client limit

The session limit was temporarily increased to:

```swift
var maximumClients: Int = 128
```

The native Speedtest workload was re-tested.

Verified:

```text
Native Speedtest download           PASS
Native Speedtest upload             PASS
High-concurrency SOCKS sessions     PASS
High-concurrency upstream relay     PASS
No client-limit rejection           PASS
Application remained stable         PASS
```

Result:

```text
HIGH-CONCURRENCY STRESS TEST: PASS WITH 128-CLIENT CONFIGURATION
```

Conclusion:

The initial Speedtest application failure was caused by the 32-session configuration limit.

With a 128-session test configuration, the high-concurrency native Speedtest workload completed successfully.

The final production value for `maximumClients` remains a tuning decision based on memory, thermal, and long-duration stability requirements.

Phase 11 follow-up decision (2026-09-15): the application default is now `128`. This value is based on the successful native Speedtest retest above, while retaining the existing bounded-session design and configurable upper choice of `256`.

Existing installations that still hold the former default value of `32` are migrated once to `128`. Non-32 customized values are preserved, and the user may select 32 again after the one-time migration.

---

### 10. Per-session idle-timeout isolation

Multiple SOCKS5 sessions were created simultaneously.

One session remained active with periodic traffic while another was intentionally left idle.

Observed:

```text
Active session
   ↓
traffic continues
   ↓
remains alive

Idle session
   ↓
no traffic
   ↓
idle timeout
   ↓
closed
```

Verified:

```text
Idle session expires independently       PASS
Active session remains alive             PASS
Per-session timers operate independently PASS
No cross-session cancellation            PASS
```

Result:

```text
PASS
```

---

### 11. Reconnection after idle expiry

After an idle session was removed, a new SOCKS5 connection was immediately created.

Observed:

```text
old session
   ↓
idle timeout
   ↓
closed
   ↓
removed

new client
   ↓
Accepted
   ↓
SOCKS5 handshake
   ↓
connecting
   ↓
relaying
```

Verified:

```text
Expired session removed             PASS
Listener remains ready              PASS
New client accepted                 PASS
New Socks5Session created           PASS
New upstream connection             PASS
New relay works                     PASS
```

Result:

```text
PASS
```

---

## Current Phase 3 physical-device acceptance matrix

```text
Basic bidirectional TCP relay              PASS
HTTPS / TLS traffic                        PASS

Idle expiry                                PASS
Activity-based timeout refresh             PASS
Idle-timeout timing                        PASS
Per-session timeout isolation              PASS
Idle timer cleanup                         PASS
Reconnect after idle expiry                PASS

Client disconnect handling                 PASS
Upstream disconnect handling               PASS
Session registry cleanup                   PASS

64 KiB receive-after-send backpressure     PASS
Large downstream relay                     PASS
Large upstream relay                       PASS

Browser Speedtest download                 PASS
Browser Speedtest upload                   PASS

Native Speedtest with 32-client limit      LIMIT REACHED
Native Speedtest with 128-client limit     PASS
High-concurrency bulk relay                PASS

Half-close write FIN propagation           PASS
Upstream EOF observation                   PASS
Response generation after EOF              PASS
Reverse relay after client SHUT_WR         PASS
Half-close response preservation           PASS
Deterministic half-close regression        PASS

Application crash during tests             NONE
Stuck session observed                     NONE
```

---

## Phase 3 conclusion

Physical-device testing confirms successful operation of:

```text
Event-driven TCP relay              PASS
Bidirectional relay                 PASS
Half-close propagation              PASS
Idle-timeout lifecycle              PASS
Activity-based timeout refresh      PASS
Disconnect cleanup                  PASS
Session timer isolation             PASS
Large-transfer backpressure         PASS
Bulk upstream traffic               PASS
Bulk downstream traffic             PASS
High-concurrency relay              PASS
Timeout recovery / reconnect        PASS
```

The original half-close investigation initially produced zero-byte responses when using `example.com:80`. Subsequent direct testing demonstrated that the public endpoint itself could return zero bytes after a client half-close, making it unsuitable as a deterministic acceptance target.

A deterministic upstream server at:

```text
172.20.10.4:18080
```

was therefore used for the final physical-device test.

The client sent 66 bytes, performed `SHUT_WR`, and remained able to receive data.

The upstream observed the complete 66-byte request and TCP EOF before generating a 70-byte response.

The complete 70-byte HTTP response was successfully relayed back to the Android client:

```text
HTTP/1.1 200 OK

received=66
```

This verifies that the client-to-upstream direction can terminate independently while the upstream-to-client direction remains active until its remaining data is delivered.

Final Phase 3 status:

```text
Status: PASS ON PHYSICAL DEVICE
```

Phase 3 acceptance is complete.

## Phase 4 — Domain / IPv4 / IPv6

Status: PASS ON PHYSICAL DEVICE

Phase 4 required address-family behavior was implemented during Phase 2 and already has physical-device evidence:

```text
IPv4 CONNECT and upstream relay       PASS
DOMAIN CONNECT and upstream relay     PASS
IPv6 CONNECT and upstream relay       PASS
HTTPS by domain                       PASS
```

The two remaining Phase 2 edge-case recording items do not invalidate the independently verified IPv4, domain, and IPv6 acceptance results. No duplicate Phase 4 implementation was required.

## Phase 5 — Cellular / system egress control

Status: PASS ON PHYSICAL DEVICE

### Implemented

- `EgressMode.systemDefault` using the unmodified system TCP routing policy
- `EgressMode.cellularOnly` using `requiredInterfaceType = .cellular`
- No silent fallback from Cellular Only to Wi-Fi, VPN, or another system route
- SOCKS5 `network unreachable` reply when Cellular Only has no usable cellular path
- Egress policy captured when the proxy starts and applied to every new upstream connection
- Egress mode included in upstream connection logs
- System path monitoring using `NWPathMonitor`
- Cellular path monitoring using `NWPathMonitor`
- Wi-Fi path monitoring using `NWPathMonitor`
- Active non-loopback IPv4/IPv6 interface address discovery
- UI egress picker
- Path availability display
- Active route display
- Proxy address display
- Egress selection locked while the listener is running
- Unit coverage for default mode and cellular interface policy

### Build verification

```text
Generic iOS Simulator build-for-testing: PASS
Unit-test bundle compilation: PASS
Generic physical iOS device build: PASS
XCTest execution: NOT RUN — CoreSimulator runtime unavailable
```

---

### Physical-device test environment

```text
Device:
iPhone 14 Pro

OS:
iOS 26.5

Client:
Physical Android device / Termux

Personal Hotspot SOCKS5 address:
172.20.10.1:9876
```

Phase 5 physical-device verification covered both normal routing and forced cellular egress behavior.

---

## Physical-device verification summary

### 1. System Default egress

The proxy was stopped, configured for:

```text
Egress Mode:
System Default
```

and restarted.

An Android client connected through SOCKS5 and requested a public-IP endpoint.

Example test:

```bash
curl -sS \
  --socks5-hostname 172.20.10.1:9876 \
  https://api.ipify.org
```

A normal HTTPS relay test was also performed.

Example:

```bash
curl -v \
  --socks5-hostname 172.20.10.1:9876 \
  https://example.com/
```

Verified:

```text
SOCKS5 CONNECT                         PASS
System Default upstream connection     PASS
Public-IP request                       PASS
HTTPS traffic                           PASS
Normal system routing policy            PASS
Application stability                   PASS
```

Result:

```text
PASS
```

Conclusion:

`System Default` correctly uses the iPhone's current normal system routing policy without forcing a specific interface.

---

### 2. Cellular Only egress

The proxy was stopped and the egress mode was changed to:

```text
Egress Mode:
Cellular Only
```

The proxy was then restarted.

Public-IP and HTTPS requests were repeated through the Android SOCKS5 client.

Verified:

```text
SOCKS5 CONNECT                         PASS
Cellular-only upstream creation        PASS
HTTPS traffic                           PASS
Public-IP request                       PASS
Cellular interface requirement         PASS
Cellular path detection                PASS
```

The upstream connection log confirmed that the forced cellular policy was active.

Expected/verified form:

```text
upstream ready via cellularOnly, cellular path: true
```

Result:

```text
PASS
```

Conclusion:

`requiredInterfaceType = .cellular` successfully forces new upstream SOCKS5 connections onto the cellular interface.

---

### 3. System Default / Cellular Only public-IP verification

Public-IP results were compared while switching between:

```text
System Default
```

and:

```text
Cellular Only
```

The observed routing behavior matched the selected egress policy.

Verified:

```text
System Default public-IP request       PASS
Cellular Only public-IP request        PASS
Selected egress reflected in route     PASS
Forced cellular route verification     PASS
```

Result:

```text
PASS
```

Conclusion:

The selected egress mode materially controls the upstream path rather than being a UI-only setting.

---

### 4. No silent fallback

The proxy was configured for:

```text
Cellular Only
```

and a test was performed with the cellular route made unavailable while another non-cellular system route remained available.

A new SOCKS5 CONNECT was then issued.

Expected behavior:

```text
Cellular unavailable
   ↓
Cellular Only policy remains enforced
   ↓
No Wi-Fi / VPN / system-route fallback
   ↓
SOCKS5 failure reply
```

The server correctly rejected the upstream request instead of silently using another available interface.

Verified SOCKS5 result:

```text
05 03
```

Meaning:

```text
Network unreachable
```

Verified:

```text
Cellular unavailable detection         PASS
SOCKS reply 05 03                      PASS
No fallback to Wi-Fi                   PASS
No fallback to VPN                     PASS
No fallback to system default          PASS
No unintended upstream connection      PASS
```

Result:

```text
PASS
```

Conclusion:

`Cellular Only` behaves as a strict routing policy.

When the required cellular path is unavailable, the connection fails rather than falling back to another interface.

---

### 5. Wi-Fi LAN no-fallback verification

Where disabling cellular affected Personal Hotspot availability, the iPhone and Android test client were placed on the same Wi-Fi LAN.

The Android client connected to the iPhone's displayed Wi-Fi proxy address and issued a new SOCKS5 CONNECT while:

```text
Egress Mode = Cellular Only
Cellular path = unavailable
Wi-Fi path = available
```

Expected:

```text
Android
   ↓ Wi-Fi LAN
iPhone SOCKS5 listener
   ↓
Cellular Only policy
   ↓
No cellular path
   ↓
05 03 Network unreachable
```

Observed behavior matched the expectation.

Verified:

```text
SOCKS5 listener reachable via Wi-Fi    PASS
Cellular Only policy retained          PASS
Wi-Fi upstream fallback blocked        PASS
SOCKS reply 05 03                      PASS
```

Result:

```text
PASS
```

Conclusion:

Using Wi-Fi for inbound access to the SOCKS5 listener does not permit the upstream connection to silently use Wi-Fi when Cellular Only is selected.

Inbound interface and upstream egress policy operate independently.

---

### 6. Direct SOCKS5 no-fallback reply verification

A raw SOCKS5 test was used to verify the exact server response when Cellular Only had no usable cellular path.

Test sequence:

```text
TCP connect to iPhone SOCKS5 listener
   ↓
SOCKS5 Greeting
   ↓
05 00
   ↓
SOCKS5 CONNECT
   ↓
Cellular path unavailable
   ↓
05 03
```

Verified:

```text
SOCKS5 Greeting                        PASS
NO AUTH response 05 00                 PASS
CONNECT attempted                      PASS
Cellular path unavailable              PASS
SOCKS reply 05 03                      PASS
No fallback connection established     PASS
```

Result:

```text
PASS
```

This confirms that the no-fallback behavior is visible at the SOCKS5 protocol layer and not inferred only from application-level HTTP failure.

---

### 7. Path / address UI verification

The application's path and address monitoring UI was tested while network availability changed.

Verified:

```text
System path status updates              PASS
Cellular availability updates           PASS
Wi-Fi availability updates              PASS
Active route display                    PASS
IPv4 address discovery                  PASS
IPv6 address discovery                  PASS
Proxy Addresses display                 PASS
Hotspot-reachable proxy address         PASS
Proxy port 9876 display                 PASS
Updates without listener restart        PASS
```

The Personal Hotspot SOCKS5 endpoint was correctly exposed to the client as:

```text
172.20.10.1:9876
```

when applicable.

Result:

```text
PASS
```

Conclusion:

Network path and interface-address changes are reflected by the UI without requiring the proxy listener to be restarted.

---

### 8. Egress mode lock while running

The egress selector lifecycle was tested.

Before the proxy started:

```text
Egress picker:
Editable
```

After the proxy started:

```text
Egress picker:
Locked
```

After the proxy stopped:

```text
Egress picker:
Editable again
```

Verified:

```text
Mode selectable while stopped          PASS
Mode locked while listener running     PASS
Running egress policy remains stable   PASS
Mode editable again after stop         PASS
```

Result:

```text
PASS
```

Conclusion:

The upstream routing policy cannot be changed underneath active listener operation.

A new egress policy is selected only after stopping the proxy and is captured again when the proxy is restarted.

---

## Current Phase 5 physical-device acceptance matrix

```text
System Default SOCKS relay                 PASS
System Default HTTPS                       PASS
System Default public-IP request           PASS
System routing policy                      PASS

Cellular Only SOCKS relay                  PASS
Cellular Only HTTPS                        PASS
Cellular Only public-IP request            PASS
requiredInterfaceType = cellular           PASS
Cellular path = true verification          PASS
Forced cellular egress                     PASS

Cellular unavailable handling              PASS
SOCKS network-unreachable reply 05 03      PASS
No fallback to Wi-Fi                       PASS
No fallback to VPN                         PASS
No fallback to system-default route        PASS

Wi-Fi LAN inbound / Cellular Only egress   PASS
Inbound/egress interface separation        PASS

System path monitoring                     PASS
Cellular path monitoring                   PASS
Wi-Fi path monitoring                      PASS
Active route display                       PASS
IPv4/IPv6 address discovery                PASS
Proxy address display                      PASS
Dynamic path UI update                     PASS

Egress picker editable while stopped       PASS
Egress picker locked while running         PASS
Egress picker restored after stop          PASS

Application crash during tests             NONE
Unexpected fallback observed               NONE
```

---

## Phase 5 conclusion

Physical-device testing confirms successful operation of both supported upstream routing modes:

```text
System Default     PASS
Cellular Only      PASS
```

`System Default` successfully uses the iPhone's ordinary system routing policy.

`Cellular Only` successfully applies:

```swift
requiredInterfaceType = .cellular
```

to upstream connections and uses the cellular path when available.

The forced-interface behavior was verified using real public-IP and HTTPS traffic through the Android SOCKS5 client.

The no-silent-fallback requirement was also physically verified.

When Cellular Only was selected and the cellular path was unavailable, the proxy returned:

```text
05 03
```

instead of using an available Wi-Fi, VPN, or system-default route.

Wi-Fi LAN testing additionally confirmed that the interface used by a client to reach the SOCKS5 listener does not override the configured upstream egress policy.

Path monitoring, interface-address discovery, active-route display, proxy-address display, and egress picker locking were also successfully verified on the physical device.

Final Phase 5 status:

```text
Status: PASS ON PHYSICAL DEVICE
```

Phase 5 acceptance is complete.

## Phase 6 — Background feasibility

Status: BASIC PHYSICAL-DEVICE USAGE PASS — LONG-DURATION VERIFICATION DEFERRED

Recorded physical-device evidence:

```text
Basic 30-minute real-world usage:          PASS
Long-duration 1-hour verification:         DEFERRED
Long-duration 2-hour verification:         DEFERRED
Low Power Mode:                            DEFERRED
Natural elevated thermal-state behavior:   DEFERRED
OS expiration behavior:                    DEFERRED
Extended locked-screen behavior:           DEFERRED
```

This is not a Phase 6 failure. The basic background mechanism is operational on the tested device, while long-duration reliability remains an ongoing validation item.

Implemented:

- iOS 26 `BGContinuedProcessingTask` experimental wrapper isolated from `ProxyCore`
- Explicit user-initiated submission from the Start Proxy action
- Immediate-run `.fail` submission strategy so queued execution is not mistaken for active protection
- Finite 30-minute, 1-hour, 2-hour, and 4-hour duration options; 2 hours remains the default
- Real elapsed-time progress reporting through `BGContinuedProcessingTask.progress`
- Live Activity title/subtitle updates with remaining time
- OS expiration and system cancellation handling
- Selected-duration completion handling
- User Stop, duration completion, and OS expiration converge on `ProxyServer.stop()`
- Background task completion occurs after the listener and sessions report stopped
- Scene phase, task lifecycle, elapsed time, submission failure, and expiration logging
- Background task status, elapsed time, remaining time, and progress UI
- Foreground proxy remains usable when BackgroundTasks is unavailable, including Simulator execution
- `BGTaskSchedulerPermittedIdentifiers` included and verified in the built application Info.plist
- Supported-duration unit coverage

Build verification:

```text
Generic iOS Simulator build-for-testing: PASS
Unit-test bundle compilation: PASS
Generic physical iOS device build: PASS
Built Info.plist permitted identifier: PASS
XCTest execution: NOT RUN — CoreSimulator runtime unavailable
```

Important feasibility boundary:

```text
BGContinuedProcessingTask != unlimited daemon execution
```

The implementation requests a finite user-visible task and reports real progress. The operating system may expire it earlier, the user may cancel it from system UI, and removing the app from the app switcher cancels running tasks without an expiration callback. These outcomes must not automatically be classified as proxy-core defects.

### Required Phase 6 physical-device tests

Use `BACKGROUND_TEST_RESULTS.md` for the full evidence record.

1. Start a 30-minute session in the foreground and confirm the task changes from `Submitted` to `Running`.
2. Confirm the system presents the continued-processing Live Activity and its remaining-time progress changes.
3. Move to the Home screen and test both an already-established SOCKS connection and a new SOCKS connection.
4. Lock the screen and repeat both existing-connection and new-connection checks.
5. Record traffic results at 15 and 30 minutes, then repeat with 1-hour and 2-hour selections.
6. Repeat representative traffic with Low Power Mode enabled and with elevated thermal state if naturally observable. Do not deliberately overheat the device.
7. Stop from the app and confirm listener/session cleanup followed by background task completion.
8. Cancel the task through system UI and confirm the expiration log, graceful proxy shutdown, and unsuccessful task completion.
9. Separately test removal from the app switcher; expect task cancellation without relying on an expiration callback.
10. Record device, OS, ingress network, egress mode, screen state, existing/new connection results, timestamps, and relevant logs.

Phase 6 remains partially accepted until the deferred duration and screen-state evidence is recorded. The implementation does not claim 24-hour or indefinite background operation.

## Updated phase numbering

The new UDP milestone is inserted before the previously planned Phase 7 work. Existing later phases move forward by one:

```text
Phase 7   SOCKS5 UDP ASSOCIATE / UDP Relay
Phase 8   UI + statistics + settings
Phase 9   Security / robustness
Phase 10  Performance / thermal optimization
Phase 11  User-friendly UI / UX redesign
Phase 12  Optional HTTP proxy
```

# Phase 7 — SOCKS5 UDP ASSOCIATE / UDP Relay

Status: CORE FUNCTIONALITY PASS ON PHYSICAL DEVICE — DOMAIN / IPv6 / IDLE-TIMEOUT VERIFICATION DEFERRED

## Goal

Add standards-compatible SOCKS5 `UDP ASSOCIATE` support to HotspotSocks while preserving the existing TCP `CONNECT` implementation.

The verified UDP traffic path is:

```text
Android / SOCKS5 client
        |
        | TCP control connection
        | SOCKS5 Greeting
        | UDP ASSOCIATE
        v
iPhone HotspotSocks
        |
        | UDP relay endpoint
        | SOCKS5 UDP header parsing
        v
Upstream UDP destination
        |
        | UDP response
        v
iPhone UDP relay
        |
        | SOCKS5 UDP response encapsulation
        v
Android / SOCKS5 client
```

The existing TCP SOCKS5 path continues to operate without regression.

---

## Implemented

- SOCKS5 `CMD 0x03` UDP ASSOCIATE parsing while preserving TCP CONNECT behavior
- UDP ASSOCIATE requests using the RFC unspecified client endpoint (`0.0.0.0:0` or `[::]:0`)
- Per-association ephemeral `NWListener` UDP relay endpoint
- Successful UDP ASSOCIATE reply containing the client-facing relay address and actual UDP listener port
- TCP control-connection lifetime monitoring
- UDP association cleanup when the owning TCP control connection closes
- Standalone RFC 1928 SOCKS5 UDP datagram parser
- SOCKS5 UDP response encoder
- IPv4, DOMAIN, and IPv6 UDP destination-header support
- Network-byte-order UDP port handling
- Zero-length payload handling
- Non-zero `Data.startIndex` safe parsing
- Safe rejection/drop of malformed UDP packets
- `FRAG = 0` support
- Safe drop and diagnostic logging for `FRAG != 0`
- First-client UDP endpoint learning
- TCP peer-address validation
- UDP association client isolation
- IPv4-mapped IPv6 client identity normalization
- Event-driven UDP receive/send handling
- Datagram-boundary preservation
- Per-destination upstream UDP connections
- 16-destination per-association bound
- 120-second destination-flow idle eviction
- Association-level configured idle timeout
- System Default UDP egress
- Cellular Only UDP egress
- No silent UDP fallback to Wi-Fi, VPN, or system-default routing
- Association cleanup on proxy shutdown
- Association cleanup during background-task shutdown
- Development-only deterministic UDP echo server
- Android/Termux SOCKS5 UDP test helper

SOCKS5 UDP fragmentation remains intentionally unsupported:

```text
FRAG = 0       SUPPORTED
FRAG != 0      NOT SUPPORTED — safely dropped
```

---

## Build verification

```text
Generic iOS Simulator build-for-testing: PASS
Unit-test bundle compilation:              PASS
Generic physical iOS device build:         PASS
Python physical-test helper syntax:        PASS
XCTest execution:                          NOT RUN — environment unavailable
```

Unit/parser test sources cover:

```text
UDP ASSOCIATE command parse               TEST SOURCE COMPILED
IPv4 UDP datagram parse                   TEST SOURCE COMPILED
DOMAIN UDP datagram parse                 TEST SOURCE COMPILED
IPv6 UDP datagram parse                   TEST SOURCE COMPILED
Network-byte-order UDP port               TEST SOURCE COMPILED
UDP response encapsulation                TEST SOURCE COMPILED
Truncated address headers                 TEST SOURCE COMPILED
Invalid RSV                               TEST SOURCE COMPILED
FRAG = 0                                  TEST SOURCE COMPILED
FRAG != 0                                 TEST SOURCE COMPILED
Zero-length payload                       TEST SOURCE COMPILED
65,535-byte parser boundary               TEST SOURCE COMPILED
Non-zero Data.startIndex regression       TEST SOURCE COMPILED
```

---

# Physical-device verification

## Test environment

```text
Device:
iPhone 14 Pro

OS:
iOS 26.5

Client:
Physical Android device / Termux

Personal Hotspot SOCKS5 address:
172.20.10.1:9876

Deterministic UDP echo target:
172.20.10.4:18081
```

Development/test Python utilities were used only for physical-device verification and are not part of the shipped iOS application.

---

## Test 1 — UDP ASSOCIATE negotiation

A SOCKS5 client established a TCP control connection and issued:

```text
CMD = 0x03 UDP ASSOCIATE
```

Verified:

```text
SOCKS5 Greeting                         PASS
NO AUTH negotiation                     PASS
UDP ASSOCIATE command                   PASS
UDP relay endpoint creation             PASS
Relay address returned                  PASS
Relay port returned                     PASS
Association enters relay state          PASS
```

Result:

```text
PASS
```

---

## Test 2 — Deterministic IPv4 UDP echo

A deterministic UDP echo server was run at:

```text
172.20.10.4:18081
```

The Android SOCKS5 UDP client sent:

```text
hotspot-socks-udp-test
```

through the iPhone UDP relay.

The response source was correctly reported as:

```text
172.20.10.4:18081
```

and the returned payload was:

```text
hotspot-socks-udp-test
```

Verified:

```text
IPv4 SOCKS5 UDP request parsing         PASS
IPv4 upstream UDP relay                 PASS
UDP payload preservation                PASS
Reverse UDP relay                       PASS
SOCKS5 UDP response encapsulation       PASS
Response source preservation            PASS
```

Result:

```text
PASS
```

---

## Test 3 — DOMAIN UDP destination

A deterministic DOMAIN-based physical relay target was not available in the current test environment.

The implementation and test sources contain DOMAIN UDP parsing support, but a physical end-to-end DOMAIN UDP relay test has not yet been recorded.

Current result:

```text
DOMAIN UDP parser implementation        IMPLEMENTED
DOMAIN UDP test source                  COMPILED
DOMAIN physical UDP relay               DEFERRED — TEST ENVIRONMENT NOT AVAILABLE
```

This item remains a future physical-device verification task.

---

## Test 4 — IPv6 UDP destination

IPv6 UDP parser and protocol support are implemented.

A suitable deterministic IPv6 upstream environment was not available for the physical-device test.

Current result:

```text
IPv6 UDP parser / encapsulation         IMPLEMENTED
IPv6 UDP test source                    COMPILED
IPv6 physical upstream relay            ENVIRONMENT NOT AVAILABLE
```

This is classified as an environment limitation rather than an implementation failure.

---

## Test 5 — DNS over SOCKS5 UDP

Explicit DNS queries were sent through SOCKS5 UDP ASSOCIATE.

The test path was:

```text
Android
   |
   | SOCKS5 TCP control
   | UDP ASSOCIATE
   v
iPhone HotspotSocks
   |
   | SOCKS5 UDP
   v
Public DNS resolver :53/UDP
   |
   | DNS response
   v
iPhone UDP relay
   |
   | SOCKS5 UDP encapsulation
   v
Android
```

Verified resolvers:

```text
Google DNS
8.8.8.8:53                         PASS

Quad9 DNS
9.9.9.9:53                         PASS

Cloudflare secondary DNS
1.0.0.1:53                         PASS
```

The DNS query:

```text
example.com A
```

successfully produced valid DNS responses through all three resolvers.

Verified:

```text
UDP ASSOCIATE                         PASS
Public UDP/53 upstream creation       PASS
DNS query forwarding                  PASS
DNS UDP response reception            PASS
SOCKS5 UDP response encapsulation     PASS
Valid DNS answer                      PASS
Multiple public resolver compatibility PASS
```

Result:

```text
DNS over SOCKS5 UDP                  PASS
```

### 1.1.1.1 observation

`1.1.1.1:53` did not return a DNS response on the tested path.

Observed server state included:

```text
UDP ASSOCIATE ready
client UDP endpoint learned
upstream 1.1.1.1:53 ready
systemDefault active
cellular path: true
```

No upstream DNS response was subsequently observed.

The SOCKS5 control session and UDP association then shut down normally without a crash or leak.

Because:

```text
8.8.8.8:53    PASS
9.9.9.9:53    PASS
1.0.0.1:53    PASS
```

under the same SOCKS5 UDP implementation, the isolated `1.1.1.1:53` failure is currently classified as:

```text
ENDPOINT / NETWORK-PATH-SPECIFIC OBSERVATION
```

rather than a proxy-core UDP failure.

---

## Test 6 — Multiple destinations in one association

A single UDP association was exercised with multiple upstream destinations.

Verified:

```text
Multiple destinations within one association     PASS
Independent destination-flow handling            PASS
Correct response routing                         PASS
Cross-destination payload mix-up                 NONE
Application crash                                NONE
```

Result:

```text
PASS
```

---

## Test 7 — Multiple concurrent UDP associations

Ten concurrent SOCKS5 UDP associations were created from Android / Termux.

All ten completed successfully.

Observed client results:

```text
udp-1   PASS
udp-2   PASS
udp-3   PASS
udp-4   PASS
udp-5   PASS
udp-6   PASS
udp-7   PASS
udp-8   PASS
udp-9   PASS
udp-10  PASS
```

Each association received a different iPhone UDP relay port.

Example relay endpoints included:

```text
172.20.10.1:51309
172.20.10.1:56233
172.20.10.1:56188
172.20.10.1:49164
172.20.10.1:61627
172.20.10.1:62415
172.20.10.1:51426
172.20.10.1:50579
172.20.10.1:58455
172.20.10.1:59147
```

Every association reported:

```text
response-source=172.20.10.4:18081
payload=hotspot-socks-udp-test
```

Verified:

```text
10 concurrent UDP associations         PASS
10/10 successful UDP exchanges         PASS
Independent UDP relay endpoints        PASS
Independent association state          PASS
Payload preservation                    PASS
Response-source integrity               PASS
Cross-association payload crossover     NONE
Session corruption                      NONE
Application crash                       NONE
```

Result:

```text
PASS
```

---

## Test 8 — Association lifetime

A dedicated physical-device test verified that a UDP association remains usable only while its owning TCP SOCKS5 control connection remains open.

Before closing the control connection:

```text
UDP ASSOCIATE success:
172.20.10.1:59204

Android UDP source:
0.0.0.0:53031

Payload:
before-control-close

Response source:
172.20.10.4:18081
```

Result before TCP control close:

```text
UDP relay                               PASS
Payload preservation                    PASS
```

The TCP SOCKS5 control connection was then closed.

After a short cleanup interval, the same Android UDP socket sent another SOCKS5 UDP datagram to the same old relay endpoint:

```text
172.20.10.1:59204
```

No response was received.

Verified:

```text
UDP works before TCP close              PASS
TCP control connection close            PASS
UDP association cleanup                 PASS
Old relay stops responding              PASS
Old association reusable                NO
Crash                                   NONE
```

Final result:

```text
TCP control close → UDP association cleanup    PASS
```

This confirms that UDP association lifetime is correctly bound to the owning SOCKS5 TCP control session.

---

## Test 9 — UDP idle timeout

A dedicated physical-device UDP idle-timeout test was not performed during this acceptance pass.

The implementation contains:

```text
120-second destination-flow idle eviction
association-level configured idle timeout
```

and the relevant test/build sources compile successfully.

Current result:

```text
UDP idle-timeout implementation         IMPLEMENTED
Destination-flow idle eviction          IMPLEMENTED
Physical-device idle-timeout test       DEFERRED
```

This item remains a later resource-lifecycle / robustness verification task.

---

## Test 10 — Cellular Only UDP egress

The proxy was configured for:

```text
Egress Mode = Cellular Only
```

Public UDP traffic was then sent through SOCKS5 UDP ASSOCIATE.

Verified:

```text
UDP ASSOCIATE                           PASS
Cellular-only UDP upstream creation     PASS
UDP request forwarding                  PASS
UDP response reception                  PASS
Cellular routing policy                 PASS
Cellular path verification              PASS
```

The UDP upstream used the required cellular path rather than another available interface.

Result:

```text
Cellular Only UDP egress                PASS
```

---

## Test 11 — No silent UDP fallback

The proxy was configured for:

```text
Egress Mode = Cellular Only
```

while the required cellular route was unavailable and a non-cellular route remained available.

UDP traffic was attempted through SOCKS5 UDP ASSOCIATE.

Verified:

```text
Required cellular path unavailable      PASS
Successful unintended UDP exchange      NONE
Wi-Fi fallback                          NONE
VPN fallback                            NONE
System-default fallback                 NONE
Required-interface policy retained      PASS
Application crash                       NONE
```

Unlike TCP CONNECT, SOCKS5 UDP has no per-datagram equivalent of the SOCKS5 `05 03` network-unreachable response.

No non-standard UDP error packet was generated.

Result:

```text
No silent UDP fallback                  PASS
```

This confirms that UDP follows the same strict egress-policy semantics as the previously verified TCP implementation.

---

## Test 12 — TCP CONNECT regression

After UDP ASSOCIATE support was implemented, the original SOCKS5 TCP CONNECT path was re-tested.

Command:

```bash
curl -v \
  --connect-timeout 10 \
  --max-time 30 \
  --socks5-hostname 172.20.10.1:9876 \
  https://example.com/ \
  -o /dev/null
```

Observed:

```text
SOCKS connection opened to example.com:443
TLSv1.3 handshake completed
Certificate hostname verification passed
OpenSSL verification result: 0
ALPN selected HTTP/2
HTTP/2 request completed
HTTP/2 200 received
Response body received
```

Verified:

```text
SOCKS5 CONNECT                          PASS
DOMAIN TCP destination                  PASS
TLS 1.3                                 PASS
Certificate verification                PASS
HTTP/2                                  PASS
HTTPS request                            PASS
HTTP response 200                        PASS
TCP relay after UDP implementation       PASS
```

Result:

```text
TCP regression                          PASS
```

No regression in the existing TCP SOCKS5 functionality was observed.

---

# Current Phase 7 physical-device acceptance matrix

```text
UDP ASSOCIATE negotiation                PASS
UDP relay endpoint creation              PASS

IPv4 UDP relay                           PASS
DOMAIN UDP physical relay                DEFERRED — TEST ENVIRONMENT NOT AVAILABLE
IPv6 UDP physical relay                  ENVIRONMENT NOT AVAILABLE

SOCKS5 UDP request parsing               PASS
SOCKS5 UDP response encapsulation        PASS
UDP payload preservation                 PASS
UDP response-source preservation         PASS

Deterministic IPv4 UDP echo              PASS
DNS over SOCKS5 UDP                      PASS

Google DNS 8.8.8.8                       PASS
Quad9 DNS 9.9.9.9                        PASS
Cloudflare DNS 1.0.0.1                   PASS
Cloudflare DNS 1.1.1.1                   ENDPOINT/PATH-SPECIFIC NO RESPONSE

Multiple destinations                    PASS
Multiple concurrent associations         PASS
10/10 concurrent UDP exchanges           PASS
Association isolation                    PASS
Association lifetime cleanup             PASS

UDP idle-timeout physical test           DEFERRED

System Default UDP egress                PASS
Cellular Only UDP egress                 PASS
No silent UDP fallback                   PASS

TCP CONNECT regression                   PASS
HTTPS regression                         PASS
TLS regression                           PASS
HTTP/2 regression                        PASS

Application crash during tests           NONE
Observed association leak                NONE
Observed session corruption              NONE
Observed payload crossover               NONE
```

---

# Phase 7 conclusion

Physical-device testing confirms successful operation of the core SOCKS5 UDP path:

```text
Android / Termux
        |
        | SOCKS5 TCP control
        | UDP ASSOCIATE
        v
iPhone HotspotSocks
        |
        | UDP relay
        | SOCKS5 UDP decode
        v
IPv4 / Internet UDP destination
        |
        | UDP response
        v
iPhone HotspotSocks
        |
        | SOCKS5 UDP response encode
        v
Android / Termux
```

The following core functionality has been physically verified:

```text
UDP ASSOCIATE                            PASS
IPv4 UDP relay                           PASS
SOCKS5 UDP encapsulation                 PASS
Deterministic UDP echo                   PASS
DNS over SOCKS5 UDP                      PASS
Multiple-destination handling            PASS
Concurrent association isolation         PASS
Association lifetime cleanup             PASS
System Default UDP egress                PASS
Cellular Only UDP egress                 PASS
No silent UDP fallback                   PASS
TCP CONNECT regression                   PASS
Application stability                    PASS
```

DNS-over-SOCKS5-UDP was verified successfully against three independent public resolver endpoints:

```text
8.8.8.8:53                              PASS
9.9.9.9:53                              PASS
1.0.0.1:53                              PASS
```

`1.1.1.1:53` reached the upstream-ready state but did not produce an observed DNS response on the tested path. Because other independent public resolvers passed under the same implementation, this is currently classified as an endpoint/network-path-specific observation rather than a HotspotSocks UDP relay defect.

Association lifetime was also physically verified. A UDP association successfully relayed traffic before its TCP control connection was closed, and the old UDP relay stopped responding after control-channel termination.

Ten concurrent UDP associations completed successfully with independent ephemeral relay ports and no payload crossover, crash, or session corruption.

Cellular Only UDP routing and the no-silent-fallback requirement were both physically verified.

The existing SOCKS5 TCP CONNECT path continues to function successfully after UDP support was introduced, including TLS 1.3, certificate verification, HTTP/2, and an HTTP 200 response.

The remaining physical-device verification items are:

```text
DOMAIN UDP end-to-end relay              DEFERRED — deterministic hostname environment unavailable
IPv6 UDP end-to-end relay                ENVIRONMENT NOT AVAILABLE
UDP idle-timeout behavior                DEFERRED — robustness verification
```

Therefore the current Phase 7 status is:

```text
Status:
CORE FUNCTIONALITY PASS ON PHYSICAL DEVICE —
DOMAIN / IPv6 / IDLE-TIMEOUT VERIFICATION DEFERRED
```

Phase 7 core functionality is accepted for continued development.

A future verification pass should complete the deferred DOMAIN UDP and idle-timeout tests when suitable deterministic test infrastructure is available.

IPv6 physical relay testing should be recorded separately when an IPv6-capable upstream environment is available.

---

# Important scope limitation

SOCKS5 UDP ASSOCIATE support does not transparently capture arbitrary UDP traffic generated by every tethered Android application.

Phase 7 verifies:

```text
standards-compatible SOCKS5 clients using UDP ASSOCIATE
```

Application-level UDP traffic requires the client or application to explicitly support SOCKS5 UDP ASSOCIATE.

Transparent forwarding of arbitrary Android TCP/UDP traffic would require a separate client-side VPN/TUN, tun2socks, or equivalent traffic-redirection layer.

---

# Protocol support after Phase 7

```text
SOCKS5 NO AUTH                  SUPPORTED
SOCKS5 CONNECT                  SUPPORTED
SOCKS5 UDP ASSOCIATE            SUPPORTED
SOCKS5 BIND                     NOT SUPPORTED
SOCKS5 UDP FRAG = 0             SUPPORTED
SOCKS5 UDP FRAG != 0            NOT SUPPORTED
```

---

# Phase 8 — UI + statistics + settings

Status: PASS ON PHYSICAL DEVICE

## Phase 7 gate assessment

```text
Core UDP functionality                 PASS ON PHYSICAL DEVICE
DOMAIN UDP relay                       DEFERRED — environment unavailable
IPv6 UDP relay                         DEFERRED — environment unavailable
UDP idle-timeout                       DEFERRED — Phase 9 robustness verification
Progression to Phase 8                 APPROVED
```

The deferred Phase 7 items do not block Phase 8. They remain explicitly tracked and must not be reported as physically verified.

---

## Implemented

- Main-screen status indicator
- Proxy endpoint list
- Route-state display
- Start / Stop controls
- Background-task state display
- Traffic-statistics summary
- Separate settings screen
- Listener-port configuration
- Maximum-client configuration
- Idle-timeout configuration
- Egress-mode configuration
- Private-network preference
- Background-duration configuration
- Settings lock while proxy is starting, running, or stopping
- JSON / UserDefaults settings persistence
- Safe fallback for invalid or incompatible persisted settings
- Start-time validation for listener port
- Start-time validation for maximum clients
- Start-time validation for finite positive idle timeout
- Start-time validation for supported background duration
- Thread-safe Active Clients counter
- Thread-safe Total Connections counter
- Thread-safe Upload byte counter
- Thread-safe Download byte counter
- Thread-safe Rejected Connections counter
- Server-start timestamp
- TCP CONNECT upload/download accounting
- Accounting of payload coalesced with a TCP CONNECT request
- SOCKS5 UDP ASSOCIATE upload/download accounting
- Per-server-run statistics reset
- Final statistics snapshot preserved after Stop
- Event-driven statistics publication
- UI update coalescing to at most one scheduled update per 500 ms burst
- No idle statistics polling timer
- Human-readable byte formatting

Scope note:

```text
allowPrivateNetworks is persisted and displayed in Phase 8.

Actual private-network access-policy enforcement belongs to Phase 9
and is not claimed as part of Phase 8 acceptance.
```

---

## Build verification

```text
Generic iOS Simulator build-for-testing: PASS
Unit-test bundle compilation:              PASS
Generic physical iOS device build:         PASS
XCTest execution:                          NOT RUN — CoreSimulator runtime unavailable
```

Compiled unit-test coverage:

```text
AppSettings defaults                       TEST SOURCE COMPILED
AppSettings validation                     TEST SOURCE COMPILED
AppSettings Codable round trip              TEST SOURCE COMPILED
Traffic connection counters                TEST SOURCE COMPILED
TCP/UDP byte-counter primitives             TEST SOURCE COMPILED
Counter underflow protection                TEST SOURCE COMPILED
Per-run statistics reset                    TEST SOURCE COMPILED
```

---

# Physical-device verification

## Test environment

```text
Device:
iPhone 14 Pro

OS:
iOS 26.5

Client:
Physical Android device / Termux

Personal Hotspot SOCKS5 endpoint:
172.20.10.1:9876

Deterministic UDP echo target:
172.20.10.4:18081
```

---

## Test 1 — Settings screen and persistence

The proxy was stopped and the Settings screen was opened.

Representative settings were changed, including:

```text
Listener Port
Maximum Clients
Idle Timeout
Egress Mode
Allow Private Networks
Background Duration
```

The application was then fully terminated and relaunched.

All modified settings persisted across application restart.

Verified:

```text
Settings screen available                  PASS
Listener Port persistence                  PASS
Maximum Clients persistence                PASS
Idle Timeout persistence                   PASS
Egress Mode persistence                    PASS
Allow Private Networks persistence         PASS
Background Duration persistence            PASS
Application relaunch with settings         PASS
```

Result:

```text
PASS
```

---

## Test 2 — Settings lifecycle lock

Settings were inspected while the proxy transitioned through its lifecycle.

When the proxy was stopped:

```text
Settings controls:
EDITABLE
```

When starting / running / stopping:

```text
Settings controls:
LOCKED
```

After the proxy fully stopped:

```text
Settings controls:
EDITABLE AGAIN
```

Verified:

```text
Settings editable while stopped            PASS
Settings locked while starting             PASS
Settings locked while running              PASS
Settings locked while stopping             PASS
Settings restored after Stop               PASS
Active configuration remains immutable     PASS
```

Result:

```text
PASS
```

---

## Test 3 — TCP statistics accounting

A TCP SOCKS5 CONNECT session was established through:

```text
172.20.10.1:9876
```

HTTPS traffic was generated through the proxy.

Verified during the active session:

```text
Active Clients                              1
Total Connections                           INCREASED
Upload                                      INCREASED
Download                                    INCREASED
```

The counters therefore reflected an actual TCP CONNECT relay session.

Verified:

```text
TCP connection accounting                   PASS
Active Clients increment                    PASS
Total Connections increment                 PASS
TCP Upload accounting                       PASS
TCP Download accounting                     PASS
Statistics UI update                        PASS
```

Result:

```text
PASS
```

---

## Test 4 — TCP disconnect statistics

The active TCP SOCKS5 client was closed.

Observed:

```text
Before close:
Active Clients = 1

After close:
Active Clients = 0
```

Historical per-run statistics remained visible.

Verified:

```text
Active Clients decrement                    PASS
Active Clients returns to zero              PASS
Total Connections retained                  PASS
Upload count retained                       PASS
Download count retained                     PASS
No counter underflow                        PASS
```

Result:

```text
PASS
```

---

## Test 5 — UDP statistics accounting

A SOCKS5 UDP ASSOCIATE session was established and the deterministic IPv4 UDP echo test was run against:

```text
172.20.10.4:18081
```

The deterministic payload was successfully relayed and returned.

Statistics changed in both traffic directions.

Verified:

```text
UDP ASSOCIATE                               PASS
Deterministic UDP echo                      PASS
UDP Upload accounting                       PASS
UDP Download accounting                     PASS
Upload counter increased                    PASS
Download counter increased                  PASS
```

Result:

```text
PASS
```

---

## Test 6 — Multiple concurrent sessions

Multiple SOCKS5 control sessions were opened concurrently.

The number shown in:

```text
Active Clients
```

matched the number of simultaneously open SOCKS5 TCP control sessions.

The count increased as sessions were opened and decreased as they closed.

After all test clients terminated:

```text
Active Clients = 0
```

Verified:

```text
Concurrent SOCKS sessions                   PASS
Active Clients accuracy                     PASS
Independent session accounting              PASS
Active count increment                      PASS
Active count decrement                      PASS
Active Clients returns to zero              PASS
No cross-session counter corruption         PASS
```

Result:

```text
PASS
```

---

## Test 7 — Maximum Clients / Rejected counter

`Maximum Clients` was temporarily reduced to a small test value.

Existing SOCKS5 sessions were held open until the configured client limit was reached.

Additional connection attempts were then made.

Observed:

```text
Active Clients did not exceed Maximum Clients.

Additional connection attempts were rejected.

Rejected increased.
```

Existing accepted sessions remained operational.

Verified:

```text
Maximum Clients enforcement                 PASS
Active Clients bounded by configured limit  PASS
Excess connection rejection                 PASS
Rejected counter increment                  PASS
Existing sessions unaffected                PASS
Application crash                           NONE
```

The intended Maximum Clients value was restored after the test.

Result:

```text
PASS
```

---

## Test 8 — Final statistics snapshot after Stop

TCP and UDP traffic was generated so that the per-run statistics contained non-zero values.

The proxy was then stopped.

Observed after Stop:

```text
Active Clients = 0
```

while the completed run's statistics remained visible.

Verified:

```text
Active Clients after Stop                   0
Total Connections preserved                 PASS
Upload preserved                            PASS
Download preserved                          PASS
Rejected preserved                          PASS
Started value preserved for completed run   PASS
Final statistics snapshot                   PASS
```

Result:

```text
PASS
```

---

## Test 9 — Per-run statistics reset on next Start

After verifying the final snapshot of the previous run, the proxy was started again.

A new server run reset the per-run counters.

Observed at the beginning of the new run:

```text
Active Clients       0
Total Connections    0
Upload               0 B
Download             0 B
Rejected             0
Started              NEW SERVER-RUN TIMESTAMP
```

New traffic subsequently incremented the counters from the new baseline.

Verified:

```text
Active Clients reset                        PASS
Total Connections reset                     PASS
Upload reset                                PASS
Download reset                              PASS
Rejected reset                              PASS
Started timestamp refreshed                 PASS
New-run traffic accounting                  PASS
```

Result:

```text
PASS
```

---

## Test 10 — Event-coalesced UI / no idle polling

The proxy was left running while traffic was idle.

The statistics UI remained stable and did not visibly refresh continuously.

Burst traffic was then generated using multiple concurrent SOCKS5 requests.

The interface remained responsive and converged to the correct final statistics values.

The app was also backgrounded and restored during the test.

No statistics-specific background polling loop or continuous UI-update behavior was observed.

Verified:

```text
Idle statistics UI stable                   PASS
No visible continuous polling               PASS
Burst traffic statistics update             PASS
UI remains responsive under burst traffic   PASS
Final counter values converge correctly     PASS
Background / foreground UI stability        PASS
Statistics polling loop observed            NONE
Application crash                           NONE
```

Result:

```text
PASS
```

This behavior is consistent with the Phase 8 design:

```text
Event-driven statistics publication
+
up to one scheduled UI update per 500 ms burst
+
no periodic idle statistics polling
```

---

## Test 11 — Start validation / readable failure

### Test 11-A — Invalid-setting validation

Invalid or unsupported configuration values were tested where allowed by the UI.

The application either prevented the invalid value from being entered or rejected proxy startup with a readable validation state.

Verified:

```text
Listener-port validation                    PASS
Maximum Clients validation                  PASS
Idle Timeout validation                     PASS
Supported Background Duration validation    PASS
Invalid configuration safely rejected       PASS
Readable validation behavior                PASS
Application crash                           NONE
```

Result:

```text
PASS
```

### Test 11-B — Actual busy-port bind failure

A deterministic condition in which another process occupied the intended iPhone listener port could not be reproduced in the current physical-device test environment.

Therefore:

```text
Actual busy-port bind failure:
NOT REPRODUCIBLE IN CURRENT TEST ENVIRONMENT
```

This is not classified as a Phase 8 failure.

The requirement was explicitly conditional on a reproducible unavailable/busy listener-port environment.

Start-time input validation and readable configuration failure behavior were physically verified independently.

---

## Test 12 — TCP and UDP regression

After Phase 8 statistics and settings integration, both TCP and UDP proxy functionality were re-tested.

### TCP CONNECT regression

A SOCKS5 HTTPS request was made through:

```text
172.20.10.1:9876
```

to:

```text
https://example.com/
```

Verified:

```text
SOCKS5 CONNECT                              PASS
HTTPS relay                                 PASS
TLS                                         PASS
HTTP response                               PASS
Statistics accounting active                PASS
```

### UDP ASSOCIATE regression

The deterministic SOCKS5 UDP echo test was repeated against:

```text
172.20.10.4:18081
```

Verified:

```text
UDP ASSOCIATE                               PASS
IPv4 UDP relay                              PASS
UDP response encapsulation                  PASS
Deterministic echo                          PASS
UDP statistics accounting                   PASS
```

Result:

```text
TCP CONNECT regression                      PASS
UDP ASSOCIATE regression                    PASS
```

No Phase 8 accounting or UI changes caused a relay regression.

---

# Current Phase 8 physical-device acceptance matrix

```text
Settings screen                             PASS
Settings persistence                        PASS
Settings locked while running               PASS

Listener Port persistence                   PASS
Maximum Clients persistence                 PASS
Idle Timeout persistence                    PASS
Egress Mode persistence                     PASS
Allow Private Networks persistence          PASS
Background Duration persistence             PASS

Start-time validation                       PASS
Readable validation failure                 PASS
Actual busy-port bind failure               NOT REPRODUCIBLE IN CURRENT TEST ENVIRONMENT

Active connection count                     PASS
Total connection count                      PASS

TCP upload bytes                            PASS
TCP download bytes                          PASS
UDP upload bytes                            PASS
UDP download bytes                          PASS

Rejected connection count                   PASS
Maximum Clients enforcement                 PASS

Final snapshot after Stop                   PASS
Counter reset on next Start                 PASS
Started timestamp reset                     PASS

Concurrent-session statistics               PASS
Counter lifecycle                           PASS
Counter underflow observed                  NONE

Event-coalesced UI behavior                 PASS
Idle polling observed                       NONE
Burst-traffic UI stability                  PASS
Background/foreground UI stability          PASS

TCP CONNECT regression                      PASS
HTTPS regression                            PASS
UDP ASSOCIATE regression                    PASS
Deterministic UDP echo regression           PASS

Application crash during tests              NONE
Observed statistics corruption              NONE
Observed relay regression                   NONE
```

---

# Phase 8 conclusion

Physical-device verification confirms successful operation of the Phase 8 UI, settings, and statistics layer.

The Settings implementation was verified to persist:

```text
Listener Port
Maximum Clients
Idle Timeout
Egress Mode
Allow Private Networks
Background Duration
```

across full application termination and relaunch.

Configuration controls correctly remain editable while the proxy is stopped and become locked throughout the starting, running, and stopping states.

This prevents active sessions from observing configuration changes during a server run.

Statistics were physically verified for both supported SOCKS5 relay types:

```text
TCP CONNECT            PASS
UDP ASSOCIATE          PASS
```

The following runtime counters were confirmed:

```text
Active Clients         PASS
Total Connections      PASS
Upload                 PASS
Download               PASS
Rejected               PASS
Started                PASS
```

TCP and UDP traffic both increment the appropriate byte counters.

Concurrent sessions correctly update Active Clients, and the count returns to zero as sessions terminate.

The configured Maximum Clients limit was enforced, excess connection attempts increased the Rejected counter, and existing sessions remained stable.

Per-run statistics lifecycle behavior was also verified:

```text
During run:
Counters update normally

After Stop:
Active Clients becomes 0
Final statistics remain visible

Next Start:
Per-run counters reset
Started receives a new server-run timestamp
```

The event-driven statistics UI remained stable during idle periods and burst traffic.

No continuously running idle statistics polling behavior was observed.

TCP CONNECT and UDP ASSOCIATE were both re-tested after the Phase 8 integration and showed no relay regression.

The only unexecuted subtest was:

```text
Actual unavailable/busy listener-port bind failure
```

because a deterministic competing listener on the iPhone could not be reproduced in the current physical-device environment.

This requirement is treated as:

```text
NOT REPRODUCIBLE IN CURRENT TEST ENVIRONMENT
```

rather than a failure.

Input validation and readable invalid-configuration handling were successfully verified separately.

Therefore the final Phase 8 status is:

```text
Status: PASS ON PHYSICAL DEVICE
```

Phase 8 acceptance is complete.

The project may proceed to:

```text
Phase 9 — Security / robustness
```

---

# Phase 9 — Security / robustness

Status: CORE SECURITY / ROBUSTNESS PASS ON PHYSICAL DEVICE — RESOLVED-PRIVATE-DOMAIN / UPSTREAM-DEADLINE VERIFICATION DEFERRED

## Phase 8 gate assessment

```text
UI / settings / statistics              PASS ON PHYSICAL DEVICE
Busy-port failure reproduction          ENVIRONMENT NOT AVAILABLE
Progression to Phase 9                   APPROVED
```

The unavailable Phase 8 busy-port setup was conditional and does not block Phase 9.

---

## Security boundary

HotspotSocks continues to use SOCKS5 `NO AUTH`.

The proxy is intended for trusted Personal Hotspot or local-network clients and is not intended to be directly exposed as a public Internet proxy.

Client admission is limited to local/private client endpoints.

Destination access policy is independent from client admission.

Destination behavior:

```text
Destination class                   Allow Private Networks OFF   ON

Public unicast                      ALLOW                        ALLOW

RFC 1918 / 100.64.0.0/10           BLOCK                        ALLOW
IPv6 unique-local fc00::/7          BLOCK                        ALLOW
IPv4/IPv6 link-local                BLOCK                        ALLOW

localhost / loopback                BLOCK                        BLOCK
Unspecified address                 BLOCK                        BLOCK
Multicast                           BLOCK                        BLOCK
```

Numeric IP strings supplied through SOCKS5 DOMAIN ATYP are reclassified as IP addresses before policy evaluation.

Therefore an input such as:

```text
ATYP = DOMAIN
HOST = 127.0.0.1
```

cannot bypass loopback restrictions.

`.localhost` remains permanently blocked.

TCP and UDP domain destinations are checked again after resolution through the ready upstream path before a TCP success reply or queued UDP payload is released.

---

## Implemented

- Dedicated `AccessPolicy` module
- IPv4 policy handling
- IPv6 policy handling
- IPv4-mapped IPv6 handling
- DOMAIN policy handling
- Local/client-network admission before SOCKS5 session allocation
- Default-deny private/link-local destination policy
- `Allow Private Networks` integration
- Always-block loopback destinations
- Always-block unspecified destinations
- Always-block multicast destinations
- Numeric-domain policy-bypass prevention
- `.localhost` blocking
- Post-resolution TCP destination policy recheck
- Post-resolution UDP destination policy recheck
- TCP policy rejection with SOCKS5 reply `05 02`
- UDP policy rejection by silent datagram drop
- UDP payload retention until upstream readiness and policy approval
- Per-destination pre-ready UDP queue bounded to 8 datagrams
- Per-destination pre-ready UDP queue bounded to 256 KiB
- Maximum 16 upstream UDP destinations per association
- Absolute 15-second SOCKS5 handshake deadline
- Handshake deadline not refreshed by trickle input
- 20-second TCP upstream connection deadline
- 20-second UDP upstream connection deadline
- Existing 512-byte incomplete-handshake bound retained
- Existing 64-KiB relay chunk bound retained
- Existing 65,535-byte UDP datagram bound retained
- Maximum-client bound retained
- TCP idle-timeout lifecycle retained
- UDP association idle-timeout lifecycle
- Malformed request rejection
- Unsupported authentication rejection
- Unsupported command rejection
- Unsupported ATYP rejection
- Oversized UDP rejection
- Zero UDP destination-port rejection
- Rejected-statistics accounting for malformed/authentication/policy denial
- More specific upstream-error SOCKS5 reply mapping
- Security-category OSLog events without payload logging
- Idempotent Stop / cleanup behavior
- Development-only Android / Termux security probe

---

## Build verification

```text
Generic iOS Simulator build-for-testing: PASS
Unit-test bundle compilation:              PASS
Generic physical iOS device build:         PASS
Python security-helper syntax:              PASS
XCTest execution:                          NOT RUN — CoreSimulator runtime unavailable
```

Compiled unit-test coverage:

```text
IPv4 loopback policy                       TEST SOURCE COMPILED
IPv6 loopback policy                       TEST SOURCE COMPILED
localhost / .localhost policy              TEST SOURCE COMPILED
RFC 1918 private ranges                    TEST SOURCE COMPILED
IPv4 link-local                            TEST SOURCE COMPILED
IPv6 link-local / unique-local             TEST SOURCE COMPILED
Public IPv4 / IPv6 / domain                TEST SOURCE COMPILED
Numeric-domain policy bypass prevention    TEST SOURCE COMPILED
Unspecified and multicast rejection        TEST SOURCE COMPILED
Local-client admission                     TEST SOURCE COMPILED
Upstream error-to-reply mapping             TEST SOURCE COMPILED
Oversized UDP datagram rejection           TEST SOURCE COMPILED
Zero UDP destination-port rejection        TEST SOURCE COMPILED
```

---

# Physical-device verification

## Test environment

```text
Device:
iPhone 14 Pro

OS:
iOS 26.5

Client:
Physical Android device / Termux

SOCKS5 endpoint:
172.20.10.1:9876

Deterministic private TCP target:
172.20.10.4:18080

Deterministic private UDP target:
172.20.10.4:18081
```

---

## Test 1 — Public TCP / UDP with Allow Private Networks OFF

The proxy was configured with:

```text
Allow Private Networks = OFF
```

Public TCP CONNECT traffic was tested using an HTTPS endpoint.

Public UDP was tested using DNS-over-SOCKS5-UDP.

Verified:

```text
Public TCP CONNECT                       PASS
Public HTTPS                             PASS
Public TLS                               PASS
Public DNS-over-UDP                      PASS
Public traffic unaffected by policy      PASS
Application crash                        NONE
```

Result:

```text
PASS
```

---

## Test 2 — Deterministic security probe

The development-only security helper was executed against the physical iPhone while:

```text
Allow Private Networks = OFF
```

The probe exercised:

```text
Unsupported authentication
Unsupported BIND
Unsupported ATYP
Unsupported SOCKS version
IPv4 loopback
Numeric-domain loopback
localhost
Private IPv4 policy denial
Absolute handshake deadline
```

Verified:

```text
Security-probe cases                     PASS
Policy-denial behavior                   PASS
Protocol rejection behavior              PASS
Absolute handshake deadline              PASS
Rejected statistic increased             PASS
Listener remained operational            PASS
Application crash                        NONE
```

Result:

```text
PASS
```

---

## Test 3 — Always-block destination classes

TCP CONNECT policy was physically verified against restricted destination classes.

Tested:

```text
127.0.0.1
localhost
DOMAIN "127.0.0.1"
::1
0.0.0.0
::
multicast destination
```

Applicable TCP policy rejections returned:

```text
05 02
```

meaning:

```text
Connection not allowed by ruleset
```

Verified:

```text
IPv4 loopback blocked                    PASS
IPv6 loopback blocked                    PASS
localhost blocked                        PASS
Numeric DOMAIN loopback blocked          PASS
IPv4 unspecified blocked                 PASS
IPv6 unspecified blocked                 PASS
Multicast blocked                        PASS
TCP policy reply 05 02                   PASS
Policy bypass observed                   NONE
Application crash                        NONE
```

Result:

```text
PASS
```

---

## Test 4 — Private LAN blocked with policy OFF

With:

```text
Allow Private Networks = OFF
```

the deterministic private LAN targets were tested.

TCP target:

```text
172.20.10.4:18080
```

UDP target:

```text
172.20.10.4:18081
```

Observed TCP behavior:

```text
SOCKS5 reply:
05 02
```

Observed UDP behavior:

```text
UDP response:
NONE

Private echo-server datagram:
NONE
```

Verified:

```text
Private IPv4 TCP blocked                 PASS
TCP policy reply 05 02                   PASS
Private IPv4 UDP blocked                 PASS
UDP policy silent drop                   PASS
No private TCP upstream reached          PASS
No private UDP upstream reached          PASS
Application crash                        NONE
```

Result:

```text
PASS
```

---

## Test 5 — Resolved private DOMAIN enforcement

A deterministic local hostname resolving to the private test server was not available in the current physical-device environment.

This test specifically requires a hostname that the iPhone resolves to a private destination such as:

```text
test-host.example
        ↓
172.20.10.4
```

and must verify that post-resolution policy blocks both TCP and UDP when:

```text
Allow Private Networks = OFF
```

Current result:

```text
Literal private-IP policy                PASS
Numeric-domain bypass prevention         PASS

Resolved private DOMAIN TCP              NOT TESTED
Resolved private DOMAIN UDP              NOT TESTED

Reason:
DETERMINISTIC DNS ENVIRONMENT NOT AVAILABLE
```

Classification:

```text
DEFERRED — ENVIRONMENT NOT AVAILABLE
```

No DNS-rebinding-resistant private-domain enforcement claim is made from literal-IP testing alone.

---

## Test 6 — Allow Private Networks ON

The proxy was stopped and configured with:

```text
Allow Private Networks = ON
```

The proxy was then restarted.

The deterministic private TCP and UDP targets were tested again.

Verified:

```text
Private TCP target allowed               PASS
Private UDP target allowed               PASS
Deterministic UDP echo                   PASS
Private-network setting applied          PASS
```

Always-block destination classes were re-tested while the setting was ON.

Verified:

```text
IPv4 loopback remains blocked            PASS
IPv6 loopback remains blocked            PASS
Unspecified remains blocked              PASS
Multicast remains blocked                PASS
```

Result:

```text
PASS
```

This confirms that `Allow Private Networks` permits trusted private/link-local destinations without disabling the permanent loopback/unspecified/multicast protections.

---

## Test 7 — Absolute SOCKS5 handshake deadline

An incomplete SOCKS5 greeting was held open.

Additional input was trickled before the configured deadline.

The connection still closed near the absolute:

```text
15-second
```

handshake deadline.

The trickle input did not extend the deadline.

Verified:

```text
Incomplete handshake accepted initially  PASS
Absolute handshake deadline active       PASS
Trickle input does not reset deadline    PASS
Connection closed near 15 seconds        PASS
Active Clients returns to 0              PASS
Session cleanup                          PASS
Listener remains operational             PASS
Application crash                        NONE
```

Result:

```text
PASS
```

---

## Test 8 — Malformed-input robustness

Malformed and unsupported SOCKS5 inputs were exercised.

Coverage included:

```text
Invalid RSV
Empty / invalid DOMAIN
Unsupported authentication
BIND
Unsupported ATYP
Truncated SOCKS messages
Non-zero UDP FRAG
Oversized UDP datagram
Random short inputs
```

The implementation rejected malformed inputs within configured bounds.

After malformed-input testing, normal SOCKS5 traffic continued to work.

Verified:

```text
Malformed RSV handling                   PASS
Invalid DOMAIN handling                  PASS
Unsupported authentication               PASS
Unsupported BIND                         PASS
Unsupported ATYP                         PASS
Truncated-message handling               PASS
FRAG != 0 handling                       PASS
Oversized UDP handling                   PASS
Random-short-input handling              PASS

Bounded malformed-input handling         PASS
Listener survives malformed clients      PASS
Normal subsequent connection             PASS

Application crash                        NONE
Stuck malformed session                  NONE
Listener loss                            NONE
```

Result:

```text
PASS
```

---

## Test 9 — TCP / UDP upstream connection deadline

The implementation contains an absolute:

```text
20-second
```

deadline for pending TCP and UDP upstream connection establishment.

A deterministic public endpoint that remained pending without producing an earlier operating-system or network error was not available in the current test environment.

Many candidate endpoints may instead fail immediately through:

```text
connection refused
network unreachable
host unreachable
carrier / firewall rejection
```

which does not provide deterministic evidence of the application's own 20-second deadline.

Current result:

```text
TCP upstream deadline implementation      IMPLEMENTED
UDP upstream deadline implementation      IMPLEMENTED

Physical deterministic TCP deadline       NOT TESTED
Physical deterministic UDP deadline       NOT TESTED

Reason:
NO DETERMINISTIC NON-RESPONSIVE UPSTREAM ENVIRONMENT
```

Classification:

```text
DEFERRED — ENVIRONMENT DEPENDENT
```

This is not classified as an observed implementation failure.

---

## Test 10 — TCP and UDP idle timeout

The configured idle timeout was tested on both TCP and UDP.

A completed TCP SOCKS5 CONNECT session was allowed to enter:

```text
connecting
→ relaying
```

and was then left without application traffic.

The session closed after the configured idle interval.

Verified TCP behavior:

```text
SOCKS5 CONNECT established               PASS
Relay state reached                      PASS
Idle session expiration                  PASS
Configured timeout honored               PASS
Active Clients returns to 0              PASS
Upstream TCP connection cleaned up       PASS
```

UDP idle behavior was also tested.

An active UDP ASSOCIATE session was left idle beyond the configured timeout.

After expiration:

```text
Active Clients = 0
```

and the old UDP relay endpoint no longer relayed packets.

Verified:

```text
UDP association established              PASS
UDP idle timeout                         PASS
Association cleanup                      PASS
Old relay endpoint no longer usable      PASS
Active Clients returns to 0              PASS
Stale UDP relay observed                 NONE
Application crash                        NONE
```

Result:

```text
TCP idle timeout                         PASS
UDP idle timeout                         PASS
```

This completes the UDP idle-timeout verification previously deferred from Phase 7.

---

## Test 11 — Resource-bound regression

### Maximum Clients

The configured Maximum Clients value was temporarily reduced and exceeded.

Verified:

```text
Maximum Clients bound enforced           PASS
Active Clients remains bounded           PASS
Excess clients rejected                  PASS
Rejected counter increased               PASS
Existing sessions remain operational     PASS
Application crash                        NONE
```

### UDP destination bound

More than 16 UDP destination flows were attempted within one SOCKS5 UDP association.

The per-association destination bound remained enforced.

Verified:

```text
16-destination bound retained            PASS
Unbounded flow creation                  NONE
Existing destination flows stable        PASS
Unrelated sessions remain operational    PASS
Application crash                        NONE
```

Result:

```text
PASS
```

---

## Test 12 — Stop / cleanup idempotence

Proxy Stop behavior was exercised during multiple lifecycle states.

Tested:

```text
Stop during incomplete SOCKS5 handshake
Stop during TCP upstream connect
Stop during active TCP relay
Stop during UDP association
Stop during burst traffic
```

In-flight client requests were allowed to fail as a consequence of the intentional Stop operation.

The acceptance target was server cleanup rather than successful client completion.

Verified:

```text
Stop during handshake                    PASS
Stop during TCP connect                  PASS
Stop during TCP relay                    PASS
Stop during UDP association              PASS
Stop during burst traffic                PASS

Active Clients after Stop                0
Session cleanup                          PASS
UDP association cleanup                  PASS
Stale UDP relay                          NONE
Repeated cleanup safety                  PASS
Proxy can Start again                    PASS

Application crash                        NONE
Stuck session                            NONE
Registry corruption                      NONE
```

Result:

```text
PASS
```

---

## Test 13 — Final security / robustness regression

Existing proxy functionality was re-tested after Phase 9 integration.

### Public TCP

Verified:

```text
SOCKS5 CONNECT                           PASS
HTTPS                                    PASS
TLS                                      PASS
HTTP response                            PASS
```

### Private UDP with Allow Private Networks ON

Verified:

```text
UDP ASSOCIATE                            PASS
Private IPv4 UDP relay                   PASS
Deterministic UDP echo                   PASS
```

### Cellular Only

Verified:

```text
Cellular Only TCP                        PASS
Cellular Only UDP                        PASS
Required cellular path                  PASS
```

### No silent fallback

With Cellular Only selected and cellular unavailable while a non-cellular route remained available:

```text
TCP unintended fallback                  NONE
UDP unintended fallback                  NONE
Wi-Fi fallback                           NONE
VPN fallback                             NONE
System-default fallback                  NONE
```

Result:

```text
TCP CONNECT regression                   PASS
UDP ASSOCIATE regression                 PASS
Cellular Only regression                 PASS
No silent fallback regression            PASS
Application crash                        NONE
```

---

# Current Phase 9 physical-device acceptance matrix

```text
Local-client admission                     PASS

Public TCP with policy OFF                  PASS
Public UDP with policy OFF                  PASS

Loopback always blocked                    PASS
Unspecified always blocked                 PASS
Multicast always blocked                   PASS

Private/link-local blocked when OFF         PASS
Private/link-local allowed when ON          PASS

Numeric-domain bypass blocked               PASS

Resolved private DOMAIN blocked             DEFERRED — DNS ENVIRONMENT NOT AVAILABLE

TCP policy reply 05 02                      PASS
UDP policy drop / no upstream               PASS

Malformed-input stability                  PASS
Unsupported authentication                  PASS
Unsupported command / BIND                  PASS
Unsupported ATYP                            PASS

Absolute handshake deadline                PASS
Trickle-input deadline bypass              BLOCKED

TCP upstream deadline                      DEFERRED — ENVIRONMENT DEPENDENT
UDP upstream deadline                      DEFERRED — ENVIRONMENT DEPENDENT

Maximum-client bound regression             PASS
UDP destination-flow bound                 PASS

TCP idle timeout                           PASS
UDP idle timeout                           PASS

Stop / cleanup idempotence                 PASS
Stale UDP relay after cleanup              NONE

TCP CONNECT regression                     PASS
HTTPS regression                           PASS
UDP ASSOCIATE regression                   PASS
Private UDP regression with policy ON      PASS
Cellular Only regression                   PASS
No silent fallback regression              PASS

Application crash                          NONE
Stuck session observed                     NONE
Session-registry corruption                NONE
Unbounded resource growth observed         NONE
```

---

# Phase 9 conclusion

Physical-device testing confirms successful operation of the core Phase 9 security and robustness controls.

The destination-policy matrix was physically verified for literal addresses.

With:

```text
Allow Private Networks = OFF
```

public Internet traffic remained functional while private destinations were blocked.

With:

```text
Allow Private Networks = ON
```

trusted private destinations became reachable.

The following destination classes remained blocked regardless of the setting:

```text
loopback
unspecified
multicast
```

Numeric-IP strings supplied through DOMAIN ATYP were also correctly reclassified and could not bypass the policy.

TCP policy denial was verified using:

```text
05 02
```

while UDP policy denial correctly used silent datagram dropping without creating a non-standard SOCKS5 UDP error response.

The absolute 15-second SOCKS5 handshake deadline was physically verified.

Trickle input did not extend the deadline.

Malformed and unsupported input testing did not cause:

```text
application crash
listener loss
stuck session
session-registry corruption
```

and normal SOCKS5 traffic remained functional afterward.

Resource limits were also physically verified:

```text
Maximum Clients                           PASS
16 UDP destinations per association      PASS
Bounded UDP pre-ready behavior            PASS
```

TCP and UDP idle-timeout cleanup were successfully verified.

The UDP idle-timeout result closes the resource-lifecycle verification that had previously remained deferred from Phase 7.

Stop / cleanup behavior was tested during handshake, TCP connection establishment, active TCP relay, UDP association, and burst traffic.

All tested states converged to clean shutdown with:

```text
Active Clients = 0
stale UDP relay = NONE
application crash = NONE
```

Existing TCP, UDP, Cellular Only, and no-silent-fallback functionality continued to operate after Phase 9 integration.

Two physical-device items remain environment-dependent.

### 1. Resolved private DOMAIN enforcement

A deterministic hostname resolving to a private test endpoint was not available.

Therefore:

```text
Resolved-private-domain enforcement:
DEFERRED — DETERMINISTIC DNS ENVIRONMENT NOT AVAILABLE
```

Literal-IP and numeric-domain policy enforcement passed, but DNS-rebinding-resistant enforcement is not claimed until a deterministic resolved-private-domain test is completed.

### 2. 20-second upstream connection deadline

A deterministic public endpoint that remains pending long enough to exercise the application's own TCP/UDP 20-second upstream deadline was not available.

Therefore:

```text
TCP upstream deadline:
DEFERRED — ENVIRONMENT DEPENDENT

UDP upstream deadline:
DEFERRED — ENVIRONMENT DEPENDENT
```

No failure of the implemented deadline mechanism was observed.

Accordingly, the current Phase 9 status is:

```text
Status:
CORE SECURITY / ROBUSTNESS PASS ON PHYSICAL DEVICE —
RESOLVED-PRIVATE-DOMAIN / UPSTREAM-DEADLINE VERIFICATION DEFERRED
```

The core Phase 9 security and robustness acceptance criteria are satisfied on the physical iPhone.

The remaining two items require specialized deterministic network environments and should remain explicitly tracked rather than inferred from other passing tests.

The project may proceed to:

```text
Phase 10 — Performance / thermal optimization
```

---

# Phase 10 — Performance / thermal optimization

## Status

**CORE PERFORMANCE / RESOURCE-STABILITY PASS ON PHYSICAL DEVICE — REMAINING EXTENDED VERIFICATION DEFERRED**

The core performance and resource-stability goals of Phase 10 have been validated on a physical iPhone 14 Pro running iOS 26.5.

The proxy demonstrated stable behavior under idle, shaped throughput, maximum-throughput, parallel TCP, and mixed TCP/UDP workloads without evidence of an idle busy loop, unbounded memory growth, CPU runaway, thermal degradation, or application crashes.

The remaining Phase 10 verification items are useful for extended validation but are not considered blockers for progressing to the next development phase.

---

## Completed physical-device validation

### Idle listener

- Listener remained active for more than 10 minutes.
- No continuous CPU busy loop was observed.
- CPU remained near idle for the majority of the measurement period.
- Memory remained bounded and did not progressively increase.
- Thermal state remained `Nominal`.
- No application crash occurred.

Result:

```text
Idle listener CPU behavior             PASS
Idle listener memory stability         PASS
Busy-loop evidence                     NONE
Thermal                                NOMINAL
Application crash                      NONE
```

---

### TCP / UDP idle timer-coalescing regression

Timer coalescing was verified without evidence that the configured idle lifetime was shortened.

TCP and UDP idle cleanup behavior remained functional after the Phase 10 timer scheduling optimizations.

Result:

```text
TCP idle timer-coalescing regression   PASS
UDP idle timer-coalescing regression   PASS
Premature timeout                      NONE OBSERVED
```

---

### Shaped throughput

#### 1 Mbps

Physical-device SOCKS5 relay testing successfully delivered approximately the requested shaping rate in both directions.

```text
1 Mbps Download                        PASS
1 Mbps Upload                          PASS
```

Representative results:

```text
Download: 1.01 Mbps
Upload:   1.00 Mbps
```

#### 10 Mbps

Three repeated runs were completed for both download and upload.

```text
10 Mbps Download average               ~10.00 Mbps
10 Mbps Upload average                 ~10.00 Mbps

Download stability                     PASS
Upload stability                       PASS
Memory bounded                         PASS
CPU runaway                            NONE
Thermal                                NOMINAL
```

Resource behavior remained stable at approximately:

```text
10 Mbps Download CPU average           ~12.6%
10 Mbps Upload CPU average             ~13.8%

Memory                                 ~63 MiB
```

No progressive memory growth was observed.

---

### Maximum available throughput

Five repeated measurements were completed in each direction.

#### Download

```text
Average                                ~318.31 Mbps
Minimum                                ~310.33 Mbps
Maximum                                ~328.61 Mbps
Coefficient of variation               ~2.11%
```

#### Upload

```text
Average                                ~304.90 Mbps
Minimum                                ~286.18 Mbps
Maximum                                ~318.52 Mbps
Coefficient of variation               ~4.45%
```

The process remained stable while relaying approximately 300+ Mbps.

Observed resource behavior:

```text
Maximum Download CPU average           ~31.8%
Maximum Upload CPU average             ~22.8%

Memory                                 ~63 MiB
CPU saturation                         NONE
Unbounded memory growth                NONE
Thermal                                NOMINAL
Application crash                      NONE
```

---

### Four parallel TCP streams

Four simultaneous TCP streams were tested in both directions.

Download and upload workloads were each repeated three times.

No progressive resource growth was observed between repetitions.

#### Download

```text
CPU average                            ~20.8%
CPU P95                                ~24.2%
Peak CPU                               ~30.5%

Memory                                 ~63–64 MiB
Progressive memory growth              NONE
```

#### Upload

```text
CPU average                            ~22.0%
CPU P95                                ~24.8%
Peak CPU                               ~27.3%

Memory                                 ~63–64 MiB
Progressive memory growth              NONE
```

Result:

```text
Four parallel TCP download             PASS
Four parallel TCP upload               PASS
Repeated-run stability                 PASS
Memory bounded                         PASS
Thread/resource growth                 NONE
Thermal                                NOMINAL
```

---

### Mixed TCP / UDP workload

A sustained TCP transfer was executed while UDP traffic was continuously generated through the SOCKS5 UDP association.

Observed resource behavior:

```text
CPU average                            ~28.4%
CPU P95                                ~43.6%
Peak CPU                               ~45.2%

Memory baseline                        ~63.2 MiB
Memory peak                            ~65.2 MiB

CPU saturation                         NONE
Unbounded memory growth                NONE OBSERVED
Thread explosion                       NONE
Port/resource explosion                NONE
Thermal                                NOMINAL
Application crash                      NONE
```

The temporary memory increase during simultaneous TCP/UDP activity remained bounded.

Result:

```text
Mixed TCP / UDP resource stability     PASS
```

---

## Phase 10 conclusions

The current Network.framework relay architecture remains stable under the measured workloads.

The existing event-driven backpressure design:

```text
receive
→ send
→ send completion
→ next receive
```

did not exhibit uncontrolled buffering or resource accumulation.

The Phase 10 low-risk optimizations therefore remain accepted:

- TCP idle-timer scheduling coalescing
- UDP association idle-timer scheduling coalescing
- UDP destination-flow cleanup scan coalescing
- Event-driven Network.framework backpressure
- Existing 64 KiB TCP relay chunks
- Bounded UDP flow and pending-datagram limits
- 500 ms UI statistics aggregation
- Notification-driven thermal monitoring

No additional speculative low-level optimization is currently justified by the physical-device measurements.

---

## Deferred Phase 10 verification

The following items remain useful but are deferred as future validation work and are not blockers for Phase 11.

### Egress comparison

```text
System Default / Cellular Only comparison     DEFERRED
Carrier-path performance comparison           DEFERRED
```

Cellular Only must continue to preserve the existing no-silent-fallback guarantee.

Private hotspot/LAN destinations are not expected to be reachable when the upstream connection is explicitly constrained to the cellular interface.

---

### Foreground / background transitions

```text
Foreground → Home                             DEFERRED
Short lock / unlock                           DEFERRED
Short accepted background-window validation   DEFERRED
```

Long-duration iOS background expiration remains a platform lifecycle issue and must be distinguished from proxy-core performance failures.

---

### Post-load recovery

Extended post-load observation remains deferred.

Future testing should verify:

```text
CPU returns toward idle baseline
Memory stabilizes after sustained load
Active Clients returns to 0
No stale TCP sessions
No stale UDP associations
```

Exact byte-for-byte memory return is not required because allocator and framework caching are expected.

---

### Thermal UI / logging validation

Instrument-level thermal measurements remained `Nominal` for all tested workloads.

Remaining verification:

```text
UI thermal-state display                      DEFERRED
performance-category OSLog verification       DEFERRED
Natural Fair state                            NOT OBSERVED
Natural Serious state                         NOT OBSERVED
Natural Critical state                        NOT OBSERVED
```

Serious or Critical thermal conditions must not be deliberately induced.

---

### Final regression sweep

A complete final Phase 10 regression sweep remains deferred:

```text
TCP HTTPS CONNECT                             DEFERRED
UDP ASSOCIATE / echo                          DEFERRED
TCP half-close                                DEFERRED
Access-policy OFF / ON                        DEFERRED
Maximum Clients                               DEFERRED
TCP / UDP idle cleanup                        DEFERRED
Cellular Only                                 DEFERRED
No silent fallback                            DEFERRED
```

These tests should be re-run before a production-release milestone.

---

### Phase 11.6 — Physical-device UX validation

Status:

```text
PASS ON PHYSICAL DEVICE
```

Physical-device UX validation was completed using the existing iPhone 14 Pro / iOS 26.5 test environment.

The redesigned user-facing workflow was exercised end-to-end using a physical Android SOCKS5 client.

Verified workflow:

```text
Launch
→ Start
→ Read proxy settings
→ Connect Android
→ Generate TCP / UDP traffic
→ Observe live statistics
→ Stop
```

The application state and normal operating workflow could be understood without examining Xcode logs or the Advanced / Diagnostics screen.

---

## Physical-device UX verification results

### 1. Initial application state

The application was launched from a fully stopped state.

Verified:

```text
Primary status                         꺼짐
Primary action                         프록시 시작
Primary action visually prominent      PASS
Developer-oriented state exposure      NONE ON PRIMARY WORKFLOW
```

The initial application state clearly communicated that the proxy was stopped and that the primary available action was to start it.

Result:

```text
PASS
```

---

### 2. User-facing network controls

The primary interface was reviewed without opening the Advanced / Diagnostics screen.

Verified user-facing controls:

```text
자동
셀룰러 전용
로컬 네트워크 접근
```

The controls and supporting descriptions were understandable from the primary interface.

Verified:

```text
Automatic mode explanation             PASS
Cellular-only explanation               PASS
Local-network-access explanation        PASS
No diagnostics required for basic use   PASS
```

Result:

```text
PASS
```

---

### 3. Start / Ready state transition

The proxy was started using the primary Start control.

Observed state sequence:

```text
꺼짐
  ↓
시작하는 중…
  ↓
연결 준비됨
```

Verified:

```text
Starting state visible                  PASS
Ready state visible                     PASS
Repeated Start protection               PASS
Listener startup                        PASS
Application stability                   PASS
```

Result:

```text
PASS
```

---

### 4. Detected proxy host and port

The primary connection information was inspected after the listener became ready.

The displayed SOCKS5 endpoint matched the actually detected Personal Hotspot-reachable address.

Representative physical-device endpoint:

```text
Host:
172.20.10.1

Port:
9876

Authentication:
None
```

Verified:

```text
Hotspot-reachable address displayed     PASS
Proxy port displayed                    PASS
Unrelated Wi-Fi address selected        NONE
Unrelated cellular address selected     NONE
Host / port easy to locate              PASS
```

Result:

```text
PASS
```

---

### 5. Connection-settings clipboard

The user-facing connection-settings copy action was tested.

The copied content contained the information required to configure a downstream SOCKS5 client.

Verified clipboard contents included:

```text
SOCKS5
Host
Port
No authentication
```

The user-facing copied information used Korean presentation text where applicable.

Verified:

```text
Connection-settings copy action         PASS
SOCKS5 type included                     PASS
Host included                            PASS
Port included                            PASS
Authentication information included     PASS
Korean user-facing copy                 PASS
```

Result:

```text
PASS
```

---

### 6. TCP HTTPS smoke regression

A physical Android client connected through the redesigned application and generated normal SOCKS5 TCP traffic.

Verified:

```text
SOCKS5 CONNECT                           PASS
HTTPS relay                              PASS
TLS traffic                              PASS
HTTP response                            PASS
Bidirectional TCP relay                  PASS
```

The Phase 11 presentation-layer changes did not introduce a TCP proxy regression.

Result:

```text
PASS
```

---

### 7. UDP ASSOCIATE smoke regression

A physical Android client performed a SOCKS5 UDP ASSOCIATE test using the existing deterministic UDP echo environment.

Verified:

```text
UDP ASSOCIATE                            PASS
UDP relay endpoint                       PASS
IPv4 UDP relay                           PASS
UDP response encapsulation               PASS
Echo response                            PASS
Payload preservation                     PASS
```

The Phase 11 UI / UX redesign did not introduce a UDP relay regression.

Result:

```text
PASS
```

---

### 8. Active-use status and statistics

TCP and UDP traffic were generated while observing the primary application interface.

The user-facing state changed appropriately when proxy traffic became active.

Observed state:

```text
연결 준비됨
  ↓
사용 중
```

Primary usage statistics responded to real proxy traffic.

Verified:

```text
Active proxy activity indication         PASS
Current connection count updates         PASS
Download counter updates                 PASS
Upload counter updates                   PASS
UI responsiveness                        PASS
Statistics convergence                   PASS
```

Result:

```text
PASS
```

---

### 9. Stop and resource cleanup

The proxy was stopped after active TCP / UDP traffic.

Observed state sequence:

```text
사용 중
  ↓
종료하는 중…
  ↓
꺼짐
```

Verified:

```text
Stopping state visible                   PASS
Stopped state visible                    PASS
Active connection count returns to zero  PASS
TCP session cleanup                      PASS
UDP association cleanup                  PASS
Stale TCP traffic                        NONE
Stale UDP traffic                        NONE
Application crash                        NONE
```

Result:

```text
PASS
```

---

### 10. Cellular-only no-fallback UX

`셀룰러 전용` was selected and tested with the required cellular route unavailable.

The application clearly communicated that cellular connectivity was unavailable and that traffic would not silently use another interface.

Verified:

```text
Cellular unavailable warning             PASS
Korean user-facing explanation           PASS
No fallback to Wi-Fi                     PASS
No fallback to VPN                       PASS
No fallback to system-default route      PASS
Existing no-silent-fallback guarantee    PRESERVED
```

Result:

```text
PASS
```

---

### 11. Advanced / Diagnostics screen

The dedicated Advanced / Diagnostics interface was opened and reviewed.

Developer and troubleshooting information remained available without cluttering the normal user workflow.

Verified availability of:

```text
Detected interface addresses
Routing / egress information
TCP session information
UDP association information
Proxy connection counters
Maximum concurrent-connection setting
Background-task state
Thermal state
Raw / recent diagnostic information
Diagnostic copy action
```

Verified:

```text
Advanced diagnostics available           PASS
Technical data removed from main flow    PASS
Diagnostic information preserved         PASS
Diagnostic copy                          PASS
```

Result:

```text
PASS
```

---

### 12. Settings lifecycle lock

Configuration controls were tested through the proxy lifecycle.

Observed:

```text
Proxy stopped
→ Settings editable

Starting / running / stopping
→ Settings locked

Proxy stopped again
→ Settings editable
```

Verified:

```text
Stopped-state editing                    PASS
Running-state settings lock              PASS
Stopping-state settings lock             PASS
Settings restored after Stop             PASS
Running egress policy stability          PASS
```

Result:

```text
PASS
```

---

### 13. Appearance and accessibility

The primary workflow was repeated under multiple user-interface configurations.

#### Light Mode

```text
Primary workflow                         PASS
Status readability                       PASS
Control visibility                       PASS
Host / port visibility                   PASS
Layout clipping                          NONE
```

#### Dark Mode

```text
Primary workflow                         PASS
Status readability                       PASS
Control visibility                       PASS
Host / port visibility                   PASS
Layout clipping                          NONE
```

#### Large Dynamic Type

```text
Primary controls reachable               PASS
Status readable                          PASS
Host / port reachable                    PASS
Critical text clipping                   NONE
Critical control clipping                NONE
```

#### VoiceOver

Major controls and status information were accessible through VoiceOver.

Verified representative elements:

```text
Proxy status                             PASS
Start / Stop                             PASS
Connection mode                          PASS
Local network access                     PASS
Proxy host                               PASS
Proxy port                               PASS
Connection-settings copy                 PASS
Advanced / Diagnostics                   PASS
```

Result:

```text
PASS
```

---

### 14. Maximum Clients default and preset UI

The Phase 11 concurrent-connection configuration was physically verified.

Default:

```text
128 (권장)
```

Available direct presets:

```text
32
64
96
128
192
256
```

Verified:

```text
Default value = 128                      PASS
Recommended indication                   PASS
Direct preset selection                  PASS
Repeated +/- interaction not required    PASS
Settings persistence                     PASS
```

Result:

```text
PASS
```

---

### 15. Native Speedtest regression at 128 clients

The physical Android native Speedtest application was exercised while HotspotSocks used the Phase 11 default:

```text
Maximum concurrent connections:
128
```

Verified:

```text
Native Speedtest download                PASS
Native Speedtest upload                  PASS
High-concurrency SOCKS sessions          PASS
Client-limit rejection                   NONE
Application crash                        NONE
```

This confirms that the new Phase 11 default remains suitable for the previously observed high-concurrency real-world workload.

Result:

```text
PASS
```

---

## Phase 11 physical-device acceptance matrix

```text
Korean primary workflow                    PASS
Start / Ready / Active / Stop states       PASS
Detected hotspot host and port             PASS
Connection-settings clipboard              PASS

TCP HTTPS smoke regression                 PASS
UDP ASSOCIATE smoke regression             PASS

Usage statistics                           PASS
Stop / resource cleanup                    PASS

Cellular-only no-fallback warning          PASS
No-silent-fallback behavior                PASS

Advanced diagnostics                       PASS
Settings lifecycle lock                    PASS

Light Mode                                 PASS
Dark Mode                                  PASS
Large Dynamic Type                         PASS
VoiceOver                                  PASS

Maximum Clients 128 default/preset UI      PASS
Native Speedtest at 128 clients            PASS

Existing security policy preserved         PASS
Existing TCP functionality preserved       PASS
Existing UDP functionality preserved       PASS

Application crash                          NONE
Stale TCP session                          NONE
Stale UDP association                      NONE
```

---

## Phase 11 acceptance criteria

All required Phase 11 acceptance criteria have now been physically verified.

```text
Main workflow understandable without networking expertise      PASS
User-facing copy uses Korean by default                        PASS
Start / Stop state immediately understandable                  PASS
Proxy host / port easy to find                                 PASS
Automatic / Cellular only behavior clearly explained           PASS
Local network access clearly explained                         PASS
Advanced details removed from primary workflow                 PASS

Existing TCP functionality preserved                           PASS
Existing UDP functionality preserved                           PASS
No-silent-fallback guarantee preserved                         PASS
Existing security policy preserved                             PASS
No regression in core proxy functionality                      PASS

Light Mode usable                                               PASS
Dark Mode usable                                                PASS
Dynamic Type verified                                           PASS
VoiceOver labels verified                                       PASS
```

Optional / supporting functionality:

```text
Diagnostic copy/export                                          PASS
First-run onboarding                                            OPTIONAL / NOT REQUIRED FOR ACCEPTANCE
```

---

## Phase 11 conclusion

The Phase 11 UI / UX redesign is accepted on the physical device.

The redesigned application successfully separates the normal user workflow from developer-oriented diagnostic information.

The primary workflow now provides a user-facing sequence of:

```text
꺼짐
  ↓
프록시 시작
  ↓
시작하는 중…
  ↓
연결 준비됨
  ↓
사용 중
  ↓
프록시 중지
  ↓
종료하는 중…
  ↓
꺼짐
```

without requiring the user to understand the underlying SOCKS5, Network.framework, routing, or session-state implementation.

At the same time, the Advanced / Diagnostics interface retains the technical information required for troubleshooting and development.

Physical-device regression testing confirms that the presentation-layer redesign did not alter the previously verified proxy-core behavior:

```text
TCP relay                                PRESERVED
UDP relay                                PRESERVED
Security policy                          PRESERVED
Cellular-only routing guarantee          PRESERVED
No-silent-fallback behavior              PRESERVED
Session cleanup                          PRESERVED
High-concurrency operation               PRESERVED
```

Final Phase 11 status:

```text
Status: PASS ON PHYSICAL DEVICE
```

Phase 11 acceptance is complete.

Proceed to:

```text
Phase 12 — Optional HTTP proxy
```

when development of the optional HTTP-proxy functionality is desired.

---

## Phase 11 non-goals

The following are not primary Phase 11 goals:

- HTTP proxy implementation
- Authentication system
- Custom VPN / Network Extension implementation
- TUN implementation
- Transparent proxying
- SOCKS protocol expansion beyond the existing supported features
- Major relay-core rewrite
- Speculative performance optimization
- Cloud account system

These should remain separate future phases.

---

# Phase 12 — Optional HTTP proxy

## Status

**HTTP PROXY CORE PHYSICAL TESTS 1–3 PASS —  
WPAD.DAT / PAC IMPLEMENTED / BUILD PASS —  
FINAL INTEGRATED PHYSICAL-DEVICE ACCEPTANCE PENDING**

Phase 11 has passed its physical-device acceptance matrix.

The previously deferred optional HTTP proxy has therefore been implemented as the Phase 12 milestone.

The SOCKS5 proxy remains the primary transport.

Initial physical-device validation of the HTTP proxy core has also been completed successfully through Test 3.

The `wpad.dat` / PAC functionality is now integrated. The remaining Phase 12 physical-device acceptance work should therefore be executed as one final pass covering the HTTP proxy, PAC configuration path, security policy, routing policy, statistics, lifecycle, and persistence behavior.

This deferment is a test-consolidation decision and is not caused by a known HTTP proxy failure.

---

## Scope and implementation

The HTTP proxy is disabled by default and uses a separate listener on port:

```text
9877
```

The primary SOCKS5 listener remains:

```text
9876
```

Enabling the HTTP proxy does not replace or reconfigure the primary SOCKS5 listener.

Implemented:

- Independent `HttpProxyServer` and `HttpProxySession` lifecycle
- Incremental HTTP request-header parsing with a 64 KiB limit
- `CONNECT host:port` for HTTPS and other TCP tunnels
- Absolute-form `http://host[:port]/path` forwarding
- IPv4, domain, and bracketed IPv6 authorities
- Preservation of bytes received with the initial request, including early TLS bytes after `CONNECT`
- Absolute-form to origin-form request-target rewriting
- Removal of `Proxy-Authorization`, `Proxy-Connection`, and client `Connection` headers
- One upstream origin connection per regular HTTP request using `Connection: close`
- Reuse of `UpstreamConnector`
- Reuse of `RelayPipe`
- Reuse of egress selection
- Reuse of idle timeout
- Reuse of traffic statistics
- Destination policy checks before connection
- Destination policy checks after DNS resolution
- No fallback when `셀룰러 전용` cannot obtain a cellular path
- One application-wide client limit shared by SOCKS5 and HTTP listeners
- Korean optional-feature settings
- Korean HTTP proxy connection guidance
- Korean HTTP proxy status and failure presentation
- HTTP proxy diagnostics
- HTTP proxy clipboard text
- Backward-compatible decoding of settings saved before Phase 12
- Validation preventing SOCKS5 and HTTP listeners from using the same port

---

## Explicit non-goals

The following remain outside the current Phase 12 HTTP-proxy scope:

- HTTP proxy authentication
- TLS interception
- Custom certificate installation
- Transparent proxying
- HTTP/2 proxy protocol support
- Reusing one client connection across multiple HTTP origins

`wpad.dat` / PAC distribution is no longer a Phase 12 non-goal and is promoted to an in-scope Phase 12 extension.

Unless separately implemented and physically verified, the project does **not** claim automatic WPAD discovery through mechanisms such as DHCP option 252 or DNS-based `wpad` discovery.

Serving or manually configuring a `wpad.dat` / PAC URL is considered separately from zero-configuration network-level WPAD discovery.

The Phase 12 extension now serves the PAC resource from the existing optional HTTP listener:

```text
http://<detected-iphone-address>:9877/wpad.dat
```

Implementation details:

- Exact origin-form `/wpad.dat` endpoint on the HTTP proxy listener
- `GET` and `HEAD` support, including cache-busting query strings
- `application/x-ns-proxy-autoconfig` content type
- Explicit content length, no-cache policy, and connection close
- Dynamic `PROXY <client-facing-iphone-address>:<http-port>` generation
- Advertised address derived from the accepted connection's local endpoint, with the UI-detected hotspot address as a safe fallback
- Host-value character validation before insertion into JavaScript
- No `DIRECT` fallback in the PAC result
- No SOCKS5 port advertisement
- No separate PAC listener or additional persisted port
- PAC resource delivery only while the optional HTTP listener is enabled and running
- All selected destination traffic continues through `HttpProxySession`; the PAC endpoint does not forward destinations itself

---

# Automated verification

```text
Generic physical iOS build-for-testing: PASS
Application target compilation:         PASS
Unit-test target compilation:           PASS
HTTP parser unit coverage added:         PASS
Native PAC parser/response smoke test:    PASS

XCTest execution:
BLOCKED — no suitable signed test destination connected
```

The available development runtime did not provide a usable signed iPhone or Simulator test destination.

This remains an execution-environment limitation rather than a compilation failure.

Compilation of both the application and unit-test bundle succeeds.

Parser coverage includes:

```text
Fragmented HTTP headers                         COVERED
Domain CONNECT authority                       COVERED
IPv4 CONNECT authority                         COVERED
Bracketed IPv6 CONNECT authority               COVERED
Coalesced CONNECT + early tunnel bytes          COVERED
Regular absolute-form HTTP request              COVERED
Absolute-form → origin-form rewrite             COVERED
HTTP request-body preservation                  COVERED
Proxy-header removal                            COVERED
Unsupported HTTPS absolute-form rejection       COVERED
Malformed authority rejection                   COVERED
Oversized request-header rejection              COVERED
GET /wpad.dat and HEAD /wpad.dat parsing         COVERED
PAC endpoint and port generation                 COVERED
IPv6 PAC endpoint formatting                     COVERED
PAC JavaScript injection rejection               COVERED
PAC response MIME/cache/content-length headers   COVERED
PAC output contains no DIRECT fallback           COVERED
```

---

# Physical-device verification

## Test environment

Representative Phase 12 physical-device environment:

```text
Device:
iPhone 14 Pro

OS:
iOS 26.5

Downstream client:
Physical Android device / Termux

Ingress:
iPhone Personal Hotspot

Primary SOCKS5 endpoint:
172.20.10.1:9876

Optional HTTP proxy endpoint:
172.20.10.1:9877
```

The actual iPhone address shown in **다른 기기 연결** should be used when the detected hotspot address differs.

Development-machine tests may supplement the physical results when the hotspot route is reachable, but they do not replace the physical Android/PC-over-Personal-Hotspot path.

---

# Completed Phase 12 physical-device verification

## Test 1 — SOCKS5 regression with HTTP proxy disabled

The optional HTTP proxy was disabled and the existing SOCKS5 functionality was re-tested before validating the new HTTP transport.

Representative TCP path:

```text
Android
   ↓
Personal Hotspot
   ↓
HotspotSocks SOCKS5 :9876
   ↓
SOCKS5 CONNECT
   ↓
HTTPS destination
```

The existing SOCKS5 UDP path was also re-tested using UDP ASSOCIATE.

Verified:

```text
SOCKS5 TCP CONNECT                       PASS
SOCKS5 HTTPS relay                       PASS
SOCKS5 UDP ASSOCIATE                     PASS
SOCKS5 UDP relay                         PASS

HTTP proxy disabled state                PASS
Existing SOCKS5 behavior preserved       PASS

Application crash                        NONE
```

Result:

```text
PASS ON PHYSICAL DEVICE
```

Conclusion:

The addition of the optional HTTP-proxy implementation does not interfere with the primary SOCKS5 TCP or UDP functionality while the HTTP feature is disabled.

SOCKS5 remains the primary HotspotSocks transport.

---

## Test 2 — Optional HTTP listener and UI state

The optional HTTP proxy was enabled from the application settings.

HotspotSocks was then started.

Expected listener layout:

```text
SOCKS5
172.20.10.1:9876

HTTP Proxy
172.20.10.1:9877
```

The HTTP listener started independently while the existing SOCKS5 listener remained operational.

Verified:

```text
SOCKS5 listener available                PASS
SOCKS5 port remains 9876                 PASS

HTTP listener creation                   PASS
HTTP default port 9877                   PASS
HTTP listener reaches running state      PASS

HTTP feature remains optional            PASS
HTTP enable does not replace SOCKS5      PASS
SOCKS5 remains primary transport         PASS

HTTP user-facing status                  PASS
Application stability                    PASS
```

Result:

```text
PASS ON PHYSICAL DEVICE
```

Conclusion:

The optional HTTP proxy operates independently from the primary SOCKS5 listener.

The application can expose both proxy protocols simultaneously without changing the SOCKS5 endpoint.

---

## Test 3 — HTTP absolute-form forwarding and HTTPS CONNECT

A physical downstream client connected to the optional HTTP proxy through the iPhone Personal Hotspot.

Representative tests:

```sh
curl -x http://172.20.10.1:9877 \
  --head \
  http://example.com/
```

and:

```sh
curl -x http://172.20.10.1:9877 \
  --head \
  https://example.com/
```

### Ordinary HTTP forwarding

The first request verifies ordinary forward-proxy operation.

Logical request path:

```text
Client
   ↓
GET http://example.com/... HTTP/1.1
   ↓
HotspotSocks HTTP Proxy
   ↓
absolute-form parsing
   ↓
destination extraction
   ↓
origin-form rewrite
   ↓
GET /... HTTP/1.1
Host: example.com
   ↓
HTTP origin
```

Verified:

```text
HTTP client connection                   PASS
Absolute-form request parsing            PASS
Destination host extraction              PASS
Destination port extraction              PASS
Origin connection                        PASS
Absolute-form → origin-form rewrite      PASS
HTTP response relay                      PASS
```

### HTTPS CONNECT

The second request verifies HTTPS tunneling through HTTP `CONNECT`.

Logical path:

```text
Android
   ↓
HTTP Proxy :9877
   ↓
CONNECT example.com:443
   ↓
Upstream TCP connection
   ↓
200 Connection Established
   ↓
TLS tunnel
   ↓
HTTPS destination
```

Verified:

```text
CONNECT host:port parsing                PASS
Upstream TCP connection                  PASS
CONNECT success response                 PASS
TLS tunnel establishment                 PASS
Bidirectional tunnel relay               PASS
HTTPS request                            PASS
HTTPS response                           PASS
```

Result:

```text
HTTP absolute-form forwarding            PASS
HTTPS CONNECT                            PASS
```

Final Test 3 result:

```text
PASS ON PHYSICAL DEVICE
```

Conclusion:

The Phase 12 HTTP proxy core is physically operational for both ordinary HTTP forwarding and HTTPS tunneling.

---

# Current Phase 12 physical-device test matrix

```text
Test 1
SOCKS5 TCP / UDP regression                         PASS

Test 2
HTTP listener / optional-feature UI                  PASS

Test 3
HTTP forwarding / HTTPS CONNECT                      PASS

Test 4
IPv4 / IPv6 HTTP destination                         DEFERRED

Test 5
HTTP traffic statistics                              DEFERRED

Test 6
Private / resolved destination policy                DEFERRED

Test 7
Cellular Only / no-silent-fallback                   DEFERRED

Test 8
Malformed / oversized request rejection              DEFERRED

Test 9
Concurrent HTTP + SOCKS5 / Stop cleanup              DEFERRED

Test 10
HTTP settings persistence / migration                DEFERRED
```

Additional Phase 12 extension:

```text
wpad.dat / PAC implementation                        IMPLEMENTED / BUILD PASS
wpad.dat direct retrieval                            NOT TESTED
PAC syntax / content                                 NOT TESTED
Client PAC application                               NOT TESTED
HTTP through PAC-selected proxy                      NOT TESTED
HTTPS CONNECT through PAC-selected proxy             NOT TESTED
PAC security-policy preservation                     NOT TESTED
PAC Cellular Only behavior                           NOT TESTED
Manual HTTP + PAC coexistence                        NOT TESTED
```

No failed Phase 12 physical-device acceptance item has been recorded at this stage.

---

# Phase 12 extension — wpad.dat / PAC support

## Scope decision

`wpad.dat` / Proxy Auto-Configuration support is promoted into Phase 12.

The goal is to reduce the amount of manual HTTP-proxy configuration required on compatible downstream clients.

The PAC layer must remain an optional configuration mechanism.

It must not replace or weaken:

```text
SOCKS5
HTTP forward proxy
Destination security policy
Local Network Access policy
Egress routing policy
Cellular Only no-fallback policy
Maximum concurrent-connection limit
Idle timeout
Traffic statistics
Session cleanup
```

---

## Terminology / implementation boundary

Phase 12 distinguishes between:

```text
PAC file distribution
```

and:

```text
full automatic WPAD discovery
```

A client that is explicitly configured with a URL such as:

```text
http://<iphone-address>:<pac-port-or-http-port>/wpad.dat
```

is using PAC configuration.

This alone does not prove automatic WPAD discovery.

Automatic discovery through mechanisms such as:

```text
DHCP option 252
DNS hostname discovery for "wpad"
```

must only be claimed if those mechanisms are separately implemented and physically verified.

The minimum Phase 12 goal is therefore:

```text
wpad.dat / PAC delivery
+
client PAC application
+
traffic through the PAC-selected HotspotSocks HTTP proxy
```

---

## WPAD / PAC logical path

Expected flow:

```text
Downstream client
        ↓
retrieve wpad.dat / PAC
        ↓
PAC FindProxyForURL(...)
        ↓
select HotspotSocks HTTP proxy
        ↓
iPhone HTTP Proxy :9877
        ↓
HTTP forwarding
or
HTTPS CONNECT
        ↓
Destination
```

The PAC file selects a proxy.

It does not itself perform the relay.

All actual upstream traffic must continue through the existing `HttpProxyServer` / `HttpProxySession` implementation.

---

# Planned WPAD / PAC physical-device tests

## WPAD Test A — wpad.dat availability

Verify that a downstream Personal Hotspot client can retrieve the PAC resource from the intended iPhone endpoint.

Representative logical request:

```text
GET /wpad.dat HTTP/1.1
Host: <iphone-address>
```

Acceptance:

```text
wpad.dat endpoint reachable              PASS / FAIL
HTTP response succeeds                   PASS / FAIL
PAC body returned                        PASS / FAIL
Response body non-empty                  PASS / FAIL
Application crash                        NONE / OBSERVED
```

The PAC-serving path must not create an unintended open forward-proxy bypass.

---

## WPAD Test B — PAC syntax and advertised proxy endpoint

Inspect the returned PAC content.

The PAC script should contain a valid:

```javascript
FindProxyForURL(url, host)
```

function.

When the policy selects HotspotSocks, it must return the correct HTTP proxy endpoint.

Representative expected concept:

```text
PROXY <iphone-address>:9877
```

Acceptance:

```text
FindProxyForURL present                  PASS / FAIL
PAC syntax valid                         PASS / FAIL
Correct iPhone proxy host                PASS / FAIL
Correct HTTP proxy port                  PASS / FAIL

SOCKS5 port accidentally advertised      NONE / OBSERVED
Invalid proxy endpoint                   NONE / OBSERVED
```

The generated PAC must not silently advertise an unrelated Wi-Fi, cellular, or VPN interface address as the client-facing proxy endpoint.

---

## WPAD Test C — Client PAC application

Configure a compatible physical downstream client to use the PAC file.

Verify that the client accepts the configuration.

Acceptance:

```text
Client loads PAC                         PASS / FAIL
PAC remains usable after retrieval       PASS / FAIL
HTTP destination selection               PASS / FAIL
HTTPS destination selection              PASS / FAIL
```

Where the client provides proxy diagnostics, confirm that traffic selected by the PAC actually points to HotspotSocks.

---

## WPAD Test D — HTTP traffic through PAC

Generate an ordinary HTTP request while the downstream client is using PAC configuration.

Expected path:

```text
Client
   ↓
PAC selects HotspotSocks
   ↓
HTTP Proxy :9877
   ↓
absolute-form HTTP forwarding
   ↓
Origin
```

Acceptance:

```text
PAC selects HTTP proxy                   PASS / FAIL
HTTP proxy receives connection           PASS / FAIL
HTTP forwarding succeeds                 PASS / FAIL
HTTP response succeeds                   PASS / FAIL
Statistics update                        PASS / FAIL
```

---

## WPAD Test E — HTTPS CONNECT through PAC

Generate an HTTPS request while the client is using PAC configuration.

Expected path:

```text
Client
   ↓
PAC selects HotspotSocks
   ↓
HTTP Proxy :9877
   ↓
CONNECT destination:443
   ↓
TLS tunnel
   ↓
HTTPS destination
```

Acceptance:

```text
PAC selects HTTP proxy                   PASS / FAIL
CONNECT received                         PASS / FAIL
Upstream connection succeeds             PASS / FAIL
TLS tunnel succeeds                      PASS / FAIL
HTTPS traffic succeeds                   PASS / FAIL
```

No TLS interception or certificate installation is expected.

---

## WPAD Test F — Manual HTTP / PAC coexistence

Both supported HTTP configuration methods must remain usable:

```text
Manual HTTP proxy configuration

and

PAC / wpad.dat configuration
```

Test both independently.

Acceptance:

```text
Manual HTTP configuration                PASS / FAIL
Manual HTTPS CONNECT                     PASS / FAIL

PAC HTTP configuration                   PASS / FAIL
PAC HTTPS CONNECT                        PASS / FAIL

One method breaks the other              NONE / OBSERVED
```

The PAC extension must not make existing manual proxy configuration unusable.

---

## WPAD Test G — Local Network Access policy

Use PAC-selected HTTP traffic to verify that PAC configuration cannot bypass the existing destination security policy.

### Local Network Access OFF

Request a deterministic private-network HTTP destination.

Expected:

```text
BLOCK
```

Representative expected HTTP result:

```text
403 Forbidden
```

### Local Network Access ON

Request an explicitly trusted private-network destination.

Expected:

```text
ALLOW
```

Permanent policy blocks remain in effect regardless of the setting:

```text
Loopback                                 BLOCK
Unspecified                              BLOCK
Multicast                                BLOCK
```

Acceptance:

```text
Private target / access OFF              BLOCK
Trusted private target / access ON       ALLOW

Loopback                                 BLOCK
Unspecified                              BLOCK
Multicast                                BLOCK

PAC security bypass observed             NONE
```

---

## WPAD Test H — Resolved-domain security policy

Use a domain name whose resolution can be checked against the existing post-DNS destination policy.

Required behavior:

```text
DOMAIN
   ↓
DNS resolution
   ↓
resolved address classification
   ↓
security policy
   ↓
ALLOW or BLOCK
```

PAC selection must not cause the post-resolution security check to be skipped.

Acceptance:

```text
Pre-connect policy applied               PASS / FAIL
Post-resolution policy applied           PASS / FAIL
Resolved prohibited address blocked      PASS / FAIL
```

If a deterministic resolved-private-domain environment remains unavailable, record:

```text
DEFERRED — DETERMINISTIC DNS TEST ENVIRONMENT NOT AVAILABLE
```

rather than reporting it as physically verified.

---

## WPAD Test I — Cellular Only with PAC

Configure:

```text
Egress Mode:
Cellular Only
```

Use PAC-selected HTTP and HTTPS traffic while cellular is available.

Acceptance:

```text
PAC-selected HTTP request                PASS / FAIL
PAC-selected HTTPS CONNECT               PASS / FAIL
Cellular upstream used                   PASS / FAIL
```

Then make the cellular upstream unavailable while another non-cellular route remains available.

Expected:

```text
Cellular unavailable
        ↓
Cellular Only remains enforced
        ↓
request fails
        ↓
NO Wi-Fi / VPN / System Default fallback
```

Acceptance:

```text
No fallback to Wi-Fi                     PASS / FAIL
No fallback to VPN                       PASS / FAIL
No fallback to System Default            PASS / FAIL
User-visible failure                     PASS / FAIL
```

The PAC layer must not alter the no-silent-fallback guarantee.

---

# Remaining original Phase 12 tests

The original Tests 4 through 10 will be executed together with the WPAD/PAC acceptance pass.

---

## Test 4 — IPv4 / IPv6 HTTP destination

### IPv4

Repeat an HTTPS `CONNECT` using a numeric IPv4 destination.

Acceptance:

```text
IPv4 authority parse                     PASS / FAIL
IPv4 upstream connection                 PASS / FAIL
CONNECT tunnel                           PASS / FAIL
```

### IPv6

If the active upstream environment provides a usable IPv6 destination, repeat with a bracketed IPv6 authority.

Example protocol form:

```text
CONNECT [IPv6-address]:443 HTTP/1.1
```

Acceptance:

```text
Bracketed IPv6 parse                     PASS / FAIL
IPv6 upstream connection                 PASS / FAIL
IPv6 CONNECT tunnel                      PASS / FAIL
```

If a suitable IPv6 environment is unavailable:

```text
IPv6 HTTP CONNECT:
DEFERRED — ENVIRONMENT NOT AVAILABLE
```

This must not be reported as physically verified.

---

## Test 5 — HTTP traffic statistics

Generate HTTP and HTTPS traffic through the optional HTTP proxy.

Verify that the shared application statistics respond to HTTP traffic.

Expected user-facing statistics include:

```text
현재 프록시 연결
누적 프록시 연결
다운로드
업로드
```

Acceptance:

```text
HTTP active connection increment         PASS / FAIL
HTTP total connection increment          PASS / FAIL
HTTP upload accounting                   PASS / FAIL
HTTP download accounting                 PASS / FAIL

Connection completes
   ↓
Current proxy connections returns to 0
```

Also repeat representative traffic through PAC and confirm the same accounting path is used.

---

## Test 6 — Private / resolved destination policy

With:

```text
로컬 네트워크 접근 = OFF
```

request a deterministic private-network HTTP target.

Expected:

```text
403 Forbidden
```

Then enable:

```text
로컬 네트워크 접근 = ON
```

and request an explicitly trusted private-network target.

Expected:

```text
connection succeeds
```

Permanent-deny destinations must remain blocked:

```text
Loopback                                 BLOCK
Unspecified                              BLOCK
Multicast                                BLOCK
```

Acceptance:

```text
Private destination / OFF                BLOCK
Trusted private destination / ON         ALLOW
Loopback                                 BLOCK
Unspecified                              BLOCK
Multicast                                BLOCK
Resolved-address policy                  PASS / DEFERRED
```

---

## Test 7 — Cellular Only / no-silent-fallback

Test both:

```text
Manual HTTP proxy
```

and:

```text
PAC-selected HTTP proxy
```

under:

```text
Egress Mode = Cellular Only
```

### Cellular available

Verify:

```text
HTTP request                             PASS
HTTPS CONNECT                            PASS
Cellular upstream                        PASS
```

### Cellular unavailable

Keep another non-cellular route available.

Verify:

```text
Request fails                            PASS
No Wi-Fi fallback                        PASS
No VPN fallback                          PASS
No System Default fallback               PASS
No unintended upstream connection        PASS
```

---

## Test 8 — Malformed / oversized request rejection

Send a malformed HTTP request.

Verify:

```text
Malformed request rejected               PASS / FAIL
Session cleaned up                       PASS / FAIL
Application crash                        NONE / OBSERVED
```

Then send an HTTP request header exceeding:

```text
64 KiB
```

Verify:

```text
Oversized header rejected                PASS / FAIL
Session cleaned up                       PASS / FAIL
Application remains responsive           PASS / FAIL
```

Immediately follow the malformed/oversized tests with a valid request.

Acceptance:

```text
Subsequent valid HTTP request            PASS / FAIL
Listener remains operational             PASS / FAIL
```

A malformed client must not break the entire HTTP listener.

---

## Test 9 — Concurrent HTTP + SOCKS5 / Stop cleanup

Generate several concurrent connections using both:

```text
HTTP proxy :9877
```

and:

```text
SOCKS5 :9876
```

Where practical, include at least:

```text
Manual HTTP client
PAC-configured HTTP client
SOCKS5 TCP client
SOCKS5 UDP client
```

during the overall regression pass.

Verify the shared application-wide connection limit remains bounded.

Then tap:

```text
프록시 종료
```

Expected:

```text
SOCKS5 listener stops
HTTP listener stops

SOCKS5 sessions close
UDP associations close
HTTP sessions close

Current proxy connections → 0
```

Acceptance:

```text
Concurrent SOCKS5                         PASS / FAIL
Concurrent HTTP                           PASS / FAIL
Manual HTTP + PAC coexistence             PASS / FAIL

Shared client limit                       PASS / FAIL

SOCKS5 listener cleanup                   PASS / FAIL
HTTP listener cleanup                     PASS / FAIL

Stale SOCKS5 session                      NONE / OBSERVED
Stale UDP association                     NONE / OBSERVED
Stale HTTP session                        NONE / OBSERVED

Application crash                         NONE / OBSERVED
```

After Stop, connections to both:

```text
:9876
:9877
```

must fail until the proxy is started again.

After restarting, both enabled services must operate normally again.

---

## Test 10 — Settings persistence / migration

Configure the optional HTTP proxy and restart the application.

Verify persistence of:

```text
HTTP proxy enabled state
HTTP proxy port
```

Default HTTP port:

```text
9877
```

Verify that the application prevents:

```text
SOCKS5 port == HTTP proxy port
```

Also verify backward-compatible migration from a settings payload created before Phase 12.

Expected legacy migration behavior:

```text
HTTP proxy enabled:
false

HTTP proxy port:
9877
```

Existing unrelated settings must remain preserved.

If PAC/WPAD-specific settings are persisted after implementation, verify their restart behavior as part of the same test.

Acceptance:

```text
HTTP enabled-state persistence            PASS / FAIL
HTTP port persistence                     PASS / FAIL
Same-port validation                      PASS / FAIL
Pre-Phase-12 migration                    PASS / FAIL

PAC/WPAD setting persistence              PASS / FAIL / NOT APPLICABLE

Existing settings preserved               PASS / FAIL
```

---

# Final integrated Phase 12 verification plan

After `wpad.dat` / PAC support is implemented, perform one final physical-device acceptance pass.

Recommended order:

```text
1.  SOCKS5 TCP smoke regression
2.  SOCKS5 UDP smoke regression

3.  Manual HTTP forwarding regression
4.  Manual HTTPS CONNECT regression

5.  wpad.dat retrieval
6.  PAC syntax / endpoint verification
7.  Client PAC application
8.  HTTP through PAC
9.  HTTPS CONNECT through PAC

10. IPv4 HTTP destination
11. IPv6 HTTP destination where available

12. Manual HTTP traffic statistics
13. PAC-selected traffic statistics

14. Local Network Access OFF
15. Local Network Access ON
16. Loopback rejection
17. Unspecified-address rejection
18. Multicast rejection
19. Post-DNS resolved-address policy

20. System Default HTTP routing

21. Cellular Only manual HTTP
22. Cellular Only PAC HTTP
23. Cellular unavailable / no fallback

24. Malformed HTTP request
25. >64 KiB request header
26. Valid request immediately after rejection

27. Concurrent SOCKS5 + HTTP
28. Manual HTTP + PAC coexistence

29. Stop cleanup
30. Restart / reconnect

31. HTTP enabled-state persistence
32. HTTP port persistence
33. Same-port validation
34. Legacy settings migration
35. PAC/WPAD settings persistence where applicable

36. Korean HTTP/PAC UI
37. Diagnostic information

38. Application crash check
39. Stale-session check
```

Development-machine verification may supplement this matrix but does not replace the physical downstream-client route through the iPhone.

---

# Phase 12 acceptance criteria

Phase 12 can be considered complete when all required criteria below are satisfied or an environment-dependent item is explicitly recorded as deferred with its reason and risk.

```text
SOCKS5 remains primary and regresses cleanly             REQUIRED

HTTP absolute-form forwarding succeeds                   PASS
HTTPS CONNECT succeeds                                   PASS

Manual HTTP proxy configuration works                    REQUIRED

wpad.dat / PAC delivery works                            REQUIRED
PAC syntax / advertised endpoint is valid                REQUIRED
PAC-selected HTTP traffic works                          REQUIRED
PAC-selected HTTPS CONNECT works                         REQUIRED

Private destination policy is preserved                  REQUIRED
Post-resolution destination policy is preserved          REQUIRED
Permanent destination blocks are preserved               REQUIRED

Cellular-only mode never silently falls back              REQUIRED

Malformed HTTP requests are safely rejected               REQUIRED
Oversized HTTP headers are safely rejected                REQUIRED
Valid traffic still works after rejection                 REQUIRED

HTTP + SOCKS5 coexist correctly                          REQUIRED
Manual HTTP + PAC clients coexist correctly              REQUIRED

Shared client limit remains bounded                       REQUIRED

Stop leaves no HTTP listener/session behind               REQUIRED
Stop leaves no SOCKS5 listener/session behind             REQUIRED
Restart restores enabled services correctly               REQUIRED

HTTP settings persist correctly                           REQUIRED
Legacy settings migrate safely                            REQUIRED

Korean optional-feature UI is understandable              REQUIRED

Application crash                                        NONE REQUIRED
Stale HTTP session                                       NONE REQUIRED
Stale SOCKS5 session                                     NONE REQUIRED
Stale UDP association                                    NONE REQUIRED
```

Environment-dependent IPv6 testing may be recorded as:

```text
DEFERRED — ENVIRONMENT NOT AVAILABLE
```

if a suitable IPv6 upstream cannot be provided.

Likewise, deterministic post-resolution private-domain testing may remain explicitly deferred if the required DNS test environment is unavailable.

Such items must not be reported as physically verified.

---

# Current Phase 12 acceptance matrix

```text
SOCKS5 remains primary                         PASS
SOCKS5 TCP regression                          PASS
SOCKS5 UDP regression                          PASS

HTTP optional listener                         PASS
HTTP absolute-form forwarding                  PASS
HTTPS CONNECT                                  PASS

IPv4 HTTP destination                          PENDING
IPv6 HTTP destination                          PENDING / ENVIRONMENT DEPENDENT

HTTP statistics                                PENDING

Private destination policy                     PENDING
Resolved destination policy                    PENDING

Cellular Only HTTP                             PENDING
No silent fallback                             PENDING

Malformed request rejection                    PENDING
Oversized-header rejection                     PENDING

Concurrent HTTP + SOCKS5                       PENDING
Stop / cleanup                                 PENDING

HTTP settings persistence                      PENDING
Legacy settings migration                      PENDING

wpad.dat implementation                        IMPLEMENTED / BUILD PASS
wpad.dat delivery                              NOT TESTED
PAC syntax                                     NOT TESTED
PAC client application                         NOT TESTED
HTTP through PAC                               NOT TESTED
HTTPS CONNECT through PAC                      NOT TESTED
PAC security-policy regression                 NOT TESTED
PAC Cellular Only regression                   NOT TESTED
Manual HTTP + PAC coexistence                  NOT TESTED

Application crash in completed tests           NONE
```

---

# Current Phase 12 conclusion

Physical-device testing completed so far confirms that:

```text
Existing SOCKS5 TCP functionality              PASS
Existing SOCKS5 UDP functionality              PASS

Optional HTTP listener                         PASS

HTTP absolute-form forwarding                  PASS
HTTPS CONNECT                                  PASS
```

The core optional HTTP-proxy implementation is therefore physically operational.

The addition of the HTTP proxy has not invalidated the existing SOCKS5 TCP or UDP paths during the completed regression tests.

The `wpad.dat` / PAC extension is implemented and build-verified. The HTTP proxy and PAC configuration path must now be validated together in the documented integrated physical-device acceptance pass.

Current final status:

```text
Status:

HTTP PROXY CORE PHYSICAL TESTS 1–3 PASS —
WPAD.DAT / PAC IMPLEMENTED / BUILD PASS —
FINAL INTEGRATED PHYSICAL-DEVICE ACCEPTANCE PENDING
```

Phase 12 must not yet be marked:

```text
PASS ON PHYSICAL DEVICE
```

until the required remaining HTTP and PAC/WPAD acceptance checks have either passed or any environment-dependent exceptions have been explicitly documented.
