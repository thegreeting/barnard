# macOS lab runner

A headless macOS app that runs `BarnardEngine` on a real Bluetooth radio and
reports what it sees on stdout, one line at a time. It exists so the device lab
can use a Mac as a third real device alongside the phones: the orchestrator
backgrounds this process, greps its output for markers, and judges the run by
its exit code.

It is not a demo of the SDK. For that, see [`examples/ios-native`](../ios-native).

## Build and run

```sh
brew install xcodegen
./scripts/run.sh --event-code BND --role auto --timeout 120
```

`run.sh` generates the Xcode project, builds it, and execs the built binary
directly out of `BarnardLabRunner.app/Contents/MacOS/`. Build output goes to
stderr and to `build/build.log`, never to stdout, so the orchestrator's stdout
stays clean.

Set `SKIP_BUILD=1` to launch an already-built app. The lab host should build
once and then run many times that way, both for speed and because a rebuild
invalidates the Bluetooth grant (see below).

## Arguments

| Argument | Default | Meaning |
| --- | --- | --- |
| `--event-code <code>` | `BND` | Event to join. |
| `--role advertise\|scan\|auto` | `auto` | Whether to advertise, scan, or both. |
| `--relay on\|off` | `off` | Enable the spec 134 participant relay. |
| `--expect-peers <n>` | `1` | Distinct peers required before the run passes. |
| `--timeout <seconds>` | `120` | How long to run before giving up. |
| `--log <path>` | none | Also write the JSON event lines to this file. |

## Output

Every `BarnardEvent` is printed as one JSON object with a `type` field, along
with the engine's debug stream (`"type": "debug"`). stdout is line buffered, so
the lines appear as they happen even when the orchestrator redirects stdout to
a file.

Interleaved with the JSON are plain marker lines, which are what the
orchestrator greps for:

| Marker | When |
| --- | --- |
| `BARNARD_MACHOST_DISPLAY_ID=<hex>` | Once, as soon as the radio is active. This host's own display id. |
| `BARNARD_MACHOST_FOUND=<peerDisplayId>` | Once per distinct peer whose display id is read. |
| `BARNARD_MACHOST_ENVELOPE_V2=<receiverState>` | Every B005 v2 envelope receipt. |
| `BARNARD_MACHOST_RELAY=<decision>:<digest>` | Every spec 134 relay decision. |

`RESULT=PASS|FAIL|ERROR <detail>` is always the last line, on every exit path
including a signal and an argument error.

A peer's display id comes from a GATT read that finishes after the first
advertisement is seen, so `BARNARD_MACHOST_FOUND` usually follows a few
detection lines rather than the first one.

## Exit codes

| Code | Result line | Meaning |
| --- | --- | --- |
| 0 | `PASS` | At least `--expect-peers` distinct peers were found. |
| 1 | `ERROR` | Argument or build problem. The radio was never exercised. |
| 2 | `FAIL` | The radio worked but the rendezvous did not happen in time. Also the SIGTERM path (`RESULT=FAIL interrupted`). |
| 3 | `ERROR` | Bluetooth is denied, restricted, powered off, unsupported, or the one-time grant has not been made. |

The split matters for the lab: exit 2 is a real result about the radio, and
exit 3 is a host that needs attention.

## Bluetooth permission

The runner needs Bluetooth access, which macOS grants per app bundle after a
one-time prompt. Nothing here can answer that prompt, and nothing tries to.

1. Log into the lab host's desktop session, over screen sharing if it is
   headless, so a prompt can actually be displayed.
2. Run `./scripts/run.sh --timeout 30` once and approve the prompt.
3. Afterwards the grant lives under System Settings, Privacy & Security,
   Bluetooth, listed as `BarnardLabRunner`.

macOS keys that grant to the app's code signature. The project signs ad-hoc by
default so it builds anywhere, including CI with no keychain, but an ad-hoc
signature changes on every rebuild, which drops the grant and re-prompts. Two
ways around it on a lab host, either is fine:

- Build once and run with `SKIP_BUILD=1` from then on.
- Sign with a stable identity: `CODE_SIGN_IDENTITY="Apple Development: ..." ./scripts/run.sh`.

The app has no entitlements file and is therefore not sandboxed; a sandboxed
build would additionally need `com.apple.security.device.bluetooth`.

## The relay verifier is lab-only

`--relay on` installs `LabPermissiveRelayVerifier`, which reports
`REGISTRY_VERIFIED` for any envelope whose signature checks out. Spec 134 says
that answer may only come from an authenticated registry read, and this
verifier performs none. It exists so the lab can make the relay path fire
between two machines it owns, on an event it created. Do not copy it into a
product.

## CI

The `macos-lab-runner-example` job in `.github/workflows/native-sdk.yml` builds
this target on every change. It is build only: GitHub's macOS runners have no
Bluetooth radio, so nothing here is executed there.
