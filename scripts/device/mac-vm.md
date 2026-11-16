# Native macOS VM testing

Use an isolated Apple Silicon macOS guest for Mac field/input acceptance when the host desktop is unavailable. The recovered working runner is Tart 2.41.1, which uses Apple's Virtualization framework. Run headlessly, with host audio and clipboard sharing disabled; send screenshots and input through the guest's own VNC endpoint or SSH session.

## Current readiness and provenance

On 2026-11-16, the prior working Tart VM and its controls were absent from their old cache/tmp locations. The separate UTM `macOS.utm` entry has an empty sparse disk and is not an installed guest. This discovery is not a current VM boot or acceptance pass.

The 2026-11-13 guest ran macOS 26.6.2 with four CPUs and 6 GiB RAM, SSH and guest-only VNC. It supported native TextEdit acceptance. Its former paths were `~/Library/Caches/legato-vm-tart`, `/tmp/legato-tart-2.41.1` and `/tmp/legato-vm-control`; do not rely on them for reuse. The build-cache pruner can remove stale `legato-*` temporary directories.

The 2026-11-16 corrected app inspected at `/private/tmp/legato-iphone-bundle-mac/caret-uat/Legato.app` passed `codesign --verify --deep --strict`, with bundle ID `de.gruenwald.legato.mac` and the existing Apple Development identity. Its plist, launcher and debug dylib require macOS 26.0. This is artifact/signature evidence, not guest acceptance or proof that a later source revision is in that app. For each new candidate, record the source revision, build command, signing identity, and hashes alongside the staged app; never reuse an earlier copy merely because its filename matches.

## Storage and pins

Use durable, dedicated storage such as `~/Library/Application Support/LegatoTestVM`, or an explicitly selected external volume. Keep the runner, VM state, host-key file, controls, logs and evidence there. Do not put reusable VM state in `Library/Caches` or `/tmp`. Do not delete, reset or replace an existing guest to recreate this setup.

Pinned runner archive: [Tart 2.41.1](https://github.com/openai/tart/releases/tag/2.41.1), 22,959,557 bytes, SHA-256 `e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2`.

Pinned guest: `ghcr.io/cirruslabs/macos-tahoe-vanilla@sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640` (macOS 26.6.2 in the previous runtime).

Public OCI metadata checked on 2026-11-16:

| Image | Unique compressed blobs | Nonzero disk-chunk upper bound | Logical disk |
| --- | ---: | ---: | ---: |
| Pinned macOS 26.6.2 vanilla | 22.24 GiB | 28.57 GiB | 50,000,000,000 bytes |
| macOS 26.1 vanilla tag | 21.43 GiB | 28.57 GiB | 50,000,000,000 bytes |
| macOS 26.0 vanilla tag | 22.22 GiB | 30.07 GiB | 50,000,000,000 bytes |

Compressed size, sparse allocation and logical size are different. The chunk bound is not a measured installed allocation. The prior pinned-image pull took approximately 10 minutes 46 seconds; this is historical timing, not a current throughput estimate. Plan for approximately 40 GiB free before recreation and retain at least 8 GiB free during the pull and guest operation. Recheck actual APFS free space and monitor the owned pull; stop it if the reserve is threatened. The approximately 22 GiB available during the initial 2026-11-16 preflight was insufficient for this budget. Storage cleanup requires a separate exact proposal and approval; these instructions do not authorize deletion or stopping another test session. Sequoia 15 is incompatible with the current app.

## Recreate after storage is available

These commands describe the recovered workflow; they were not executed during the 2026-11-16 readiness check. Use an Apple Silicon host with macOS 26 or newer for `--net-host`. Confirm the chosen root is new or already owned by this workflow before writing into it.

```bash
set -euo pipefail
legato_vm_root="$HOME/Library/Application Support/LegatoTestVM"
export TART_HOME="$legato_vm_root/state"
export TART_NO_AUTO_PRUNE=1
mkdir -p "$legato_vm_root/runner/2.41.1" "$legato_vm_root/incoming" "$legato_vm_root/artifacts" "$TART_HOME"
curl -fL --output "$legato_vm_root/runner/2.41.1/tart.tar.gz" https://github.com/openai/tart/releases/download/2.41.1/tart.tar.gz
printf '%s  %s\n' e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2 "$legato_vm_root/runner/2.41.1/tart.tar.gz" | shasum -a 256 -c -
tar -xzf "$legato_vm_root/runner/2.41.1/tart.tar.gz" -C "$legato_vm_root/runner/2.41.1"
legato_tart="$legato_vm_root/runner/2.41.1/tart.app/Contents/MacOS/tart"
"$legato_tart" --version
"$legato_tart" list
```

Use the executable inside `tart.app`; the app bundle carries the runner's provisioning profile. The scoped `TART_HOME` separates this workflow's state. `TART_NO_AUTO_PRUNE` disables automatic reclamation; it does not make an undersized volume safe. Verify archive checksum success before extraction. If the intended VM name already exists, inspect it and reuse it rather than overwriting it.

```bash
"$legato_tart" clone ghcr.io/cirruslabs/macos-tahoe-vanilla@sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640 legato-mac-uat --concurrency 4
"$legato_tart" set legato-mac-uat --cpu 4 --memory 6144 --display 1440x900
"$legato_tart" run legato-mac-uat --no-graphics --no-audio --no-clipboard --vnc-experimental --net-host --dir "incoming:$legato_vm_root/incoming:ro" --dir "artifacts:$legato_vm_root/artifacts" > "$legato_vm_root/run.log" 2>&1
```

The run command stays in the foreground of its terminal/tool session. `--no-graphics` prevents a host viewer window; `--net-host` restricts the guest network to the host. The input share is read-only and the artifact share writable. Share only staged app, fixture and control files needed for the task; do not expose the home directory, personal accounts or host permission databases. A compiler is unnecessary when accepting an already built app. Guest builds require a separately verified compiler/SDK setup; the former shared-Xcode workaround is not part of this runtime-only workflow.

## Guest controls and prerequisites

Before acceptance, establish guest login, SSH access and a desktop session, then verify the actual guest OS. The published image has a test `admin` account; obtain its current test credentials from the [publisher's instructions](https://tart.run/quick-start/) or use a scoped guest key. Keep credentials out of committed files and public logs. Use a dedicated host-key file, not a blanket host-key-check bypass.

In a second terminal/tool session, restore the same root variables and runner path, then discover the address:

```bash
legato_vm_ip=$("$legato_tart" ip legato-mac-uat --wait 30)
ssh -o "UserKnownHostsFile=$legato_vm_root/known_hosts" "admin@$legato_vm_ip" /usr/bin/sw_vers
```

Read the guest VNC URL emitted into the private `run.log`. Confirm its host is exactly `127.0.0.1` before using it. A pinned `vncdotool==1.2.0` client previously provided screenshots and individual clicks/keys without opening a host viewer. Keep the endpoint password private. For example, with the endpoint's port and password supplied through private environment variables:

```bash
uv run --with vncdotool==1.2.0 vncdo --timeout 20 --server "127.0.0.1::$LEGATO_VM_VNC_PORT" --password "$LEGATO_VM_VNC_PASSWORD" capture "$legato_vm_root/artifacts/guest.png"
```

Verify that the screenshot belongs to the guest before sending input. Each UAT action must target that endpoint, or execute inside the verified guest SSH connection. Host `osascript`, host CGEvent injection and host Accessibility controls are outside this workflow.

The guest needs its own Accessibility authorization for Legato and whichever guest process sends native input/AppleEvents. Existing host grants do not transfer. Set up and verify those grants only inside the guest, using guest VNC when necessary. Never change host privacy settings to repair guest access. Missing login, permissions, transport or desktop access means blocked/untested, not passed.

## Stage the candidate and hand off

Copy the verified app and its provenance record into the host `incoming` directory. In the guest, that directory appears at `/Volumes/My Shared Files/incoming`. Copy the app into a guest-owned test directory before launch and verify its signature there. Keep the original bundle ID and signing identity and use separate guest bridge/data roots as described in the [internal harness](README.md). Native typing/cursor acceptance needs the real input observer active: launch the sole isolated guest copy with `-LegatoDisableHotkeys NO`, exactly once. Disabling hotkeys can also suppress input observation and cannot establish that behavior. This guest-only launch does not activate host hotkeys. Verify the bridge actually connects to the staged candidate. Offline fixtures require no microphone/provider call; microphone or real-provider behavior needs explicit authorization and separate evidence.

A fresh acceptance agent receives the running guest's SSH/control access, the app identity and plain-language user changes, limits and evidence destination. It explores one or two actions at a time and returns real field state plus guest screenshots and friction. A scripted replay is an integration check. This guide and the historical guest result do not replace current candidate acceptance.

After testing, end guest takes/probes, release input, and close only test-owned guest windows. Preserve the reusable guest disk and evidence. Once all guest users have released it, stop this owned VM with the same `TART_HOME` and runner:

```bash
"$legato_tart" stop legato-mac-uat
"$legato_tart" list
```

Record what remains running and retain the durable storage. Do not delete the VM as routine build-cache cleanup.
