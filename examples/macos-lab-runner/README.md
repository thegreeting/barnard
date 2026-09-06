# macOS lab runner

A headless macOS app that runs `BarnardEngine` on a real Bluetooth radio and
reports what it sees on stdout, one line at a time. It exists so the device lab
can use a Mac as a third real device alongside the phones: the orchestrator
backgrounds this process, greps its output for markers, and judges the run by
its exit code.

It is not a demo of the SDK. For that, see [`examples/ios-native`](../ios-native).

## Build and run

Requires macOS 12 or newer and a Swift toolchain. Nothing else: no XcodeGen, no
Homebrew, no Xcode project.

```sh
./scripts/run.sh --event-code BND --role auto --timeout 120
```

`run.sh` calls `scripts/bundle.sh`, which runs `swift build -c release`,
assembles `build/LabRunner.app` around the binary, writes its `Info.plist`, and
codesigns it. It then execs the binary out of `LabRunner.app/Contents/MacOS/`.
Build output goes to stderr, never to stdout, so the orchestrator's stdout
stays clean.

`--build-only` bundles and stops. `SKIP_BUILD=1` launches an already-bundled
app.

The `.app` wrapper is what gives the process a bundle identity, which is what
macOS attaches the Bluetooth grant to. A bare executable would be treated as a
different, unnamed thing on every run.

## Arguments

| Argument | Default | Meaning |
| --- | --- | --- |
| `--event-code <code>` | `BND` | Event to join. |
| `--role advertise\|scan\|auto` | `auto` | Whether to advertise, scan, or both. |
| `--relay on\|off` | `off` | Enable the spec 134 participant relay. |
| `--expect-peers <n>` | `1` | Distinct peers required before the run passes. `0` turns the run into a hold: stay on the radio for the whole timeout and pass, which is what this host does while the phones look for it. |
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
including a signal and an argument error. The one exception is `--help`, which
prints usage and exits 0: asking how to run the thing is not a run.

A peer's display id comes from a GATT read that finishes after the first
advertisement is seen, so `BARNARD_MACHOST_FOUND` usually follows a few
detection lines rather than the first one.

## Exit codes

| Code | Result line | Meaning |
| --- | --- | --- |
| 0 | `PASS` | At least `--expect-peers` distinct peers were found. |
| 1 | `ERROR` | Argument or build problem. The radio was never exercised. Also the SIGTERM path, which prints `RESULT=FAIL interrupted`: an interrupted run produced no verdict about the radio. |
| 2 | `FAIL` | The radio worked but the rendezvous did not happen in time. |
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
   Bluetooth, listed as `LabRunner`.

macOS keys that grant to the app's code signature, not just to its bundle id.
`bundle.sh` signs ad-hoc by default so the runner builds anywhere, including CI
with no keychain, but an ad-hoc signature changes on every rebuild, which drops
the grant and re-prompts. Set `CODESIGN_IDENTITY` to a stable identity and the
grant survives rebuilds:

```sh
CODESIGN_IDENTITY="Apple Development: ..." ./scripts/run.sh
```

The orchestrator passes `CODESIGN_IDENTITY`. Building once and then running
with `SKIP_BUILD=1` also keeps an ad-hoc grant alive, since nothing is
re-signed.

A paid developer account is not required for a stable identity. A self-signed
code-signing certificate made in Keychain Access, trusted on that machine only,
is enough to keep the grant across rebuilds, and its name is what goes in
`CODESIGN_IDENTITY`. That is optional lab-host setup, not part of building the
runner.

The app has no entitlements and is therefore not sandboxed; a sandboxed build
would additionally need `com.apple.security.device.bluetooth`.

## The relay verifier is lab-only

`--relay on` installs `LabPermissiveRelayVerifier`, which reports
`REGISTRY_VERIFIED` for any envelope whose signature checks out. Spec 134 says
that answer may only come from an authenticated registry read, and this
verifier performs none. It exists so the lab can make the relay path fire
between two machines it owns, on an event it created. Do not copy it into a
product.

## CI

The `macos-lab-runner-example` job in `.github/workflows/native-sdk.yml` runs
`swift build` here on every change. It is build only: GitHub's macOS runners
have no Bluetooth radio, so nothing here is executed there.
