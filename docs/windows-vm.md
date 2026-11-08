# Windows GPU VM on native Ubuntu

The repository implements host provisioning, domain generation, guarded GPU
handoff, Looking Glass launch and graceful shutdown. Native installation and
hardware acceptance have not been run from WSL. Do not treat a successful flake
build as proof this laptop's GPU resets or display wiring work.

## Intended topology

Ubuntu and its desktop stay on Intel. The RTX 4060 belongs either to Linux GPU
workloads or to Windows; PCI passthrough is exclusive. Looking Glass captures the
Windows display into shared memory and shows it in an Intel-rendered Linux window.
It does not permit Linux CUDA jobs to share the passed-through GPU.

Ubuntu owns QEMU/KVM, libvirt, OVMF, swtpm, NVIDIA kernel drivers and the system
virsh CLI. Home Manager supplies virt-manager and Looking Glass. The template
uses Q35, host CPU passthrough, Secure Boot capable UEFI with enrolled keys, TPM2,
VirtIO storage/network and a local SPICE console. Shared memory uses standard
`ivshmem-plain`; no custom KVMFR kernel module is required. This copies frames and
may perform worse at high resolutions than KVMFR's DMA path. Test actual latency
before deciding whether to add a separately managed KVMFR module.

## 1 Establish the native host

Enable firmware virtualization and VT-d/IOMMU. Boot native Ubuntu, keep dual boot,
and follow the complete migration guide's data-preservation steps. From Spawnkit:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- check --host laptop-ubuntu
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- plan --host laptop-ubuntu --ask-become-pass
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- apply --host laptop-ubuntu --ask-become-pass
```

This installs the driver/toolkit and VM host stack and declares IOMMU boot
parameters. The checked-in laptop profile initially has `gpu_handoff: false` and
`windows_vm: false`, because WSL cannot reveal the real PCI/IOMMU topology. No GPU
is bound to VFIO, no Windows domain is created, and no guest starts at boot.
Reboot, enroll MOK if required by Secure Boot, log in again for groups, and ensure
the desktop is on Intel. Run `host-config facts` (use the full Nix wrapper before
Home Manager is activated). Record native results in the migration log.

Inspect every NVIDIA function and its IOMMU group. Set the **real** function
addresses and original Linux drivers in `hosts/laptop-ubuntu/system.yml`, then
enable `gpu_handoff` and `windows_vm`. Example shape only, never copy blind:

```yaml
gpu_handoff: true
windows_vm: true
gpu_devices:
  - address: '0000:01:00.0'
    driver: nvidia
  - address: '0000:01:00.1'
    driver: snd_hda_intel
```

Include all non-bridge functions in each affected IOMMU group. If a group includes
a necessary host device, the design is not viable as configured: do not mask it
with an ACS override. A boot GPU is refused. Laptop MUX wiring, display outputs
and GPU reset capability require real checks. No automatic module blacklist,
force-reset, ROM dump or host display-manager shutdown is installed.

Check/build the changed home profile, commit/push, then deliberately reapply
`host-config apply --host laptop-ubuntu --ask-become-pass` with all guests shut
down. That installs the GPU policy/hooks and shared-memory permissions. The first
install of the hook file restarts the libvirt daemon so it discovers the hook;
later policy/settings changes do not, because the hook reads them on each call.
Either way the role refuses live guests. The Windows VM remains off until
explicitly requested.

## 2 Define and install Windows

Obtain a properly licensed Windows ISO and the upstream signed VirtIO driver ISO.
Stage them as regular, world-readable files beneath `/var/lib/libvirt/images/`.
The repository does not download license media or commit ISO images.

```bash
host-config vm-define --host laptop-ubuntu --ask-become-pass \
  --windows-iso /var/lib/libvirt/images/windows.iso \
  --virtio-iso /var/lib/libvirt/images/virtio-win.iso
host-config vm-start
host-config vm-console
```

The first definition creates a sparse 192 GiB qcow2 disk (12 GiB RAM/8 vCPUs by
default); adjust those tracked settings before defining it. It refuses existing
unmanaged domains/disks, changing the UUID, resizing/converting a disk implicitly,
or redefining a running guest. The stable UUID keeps libvirt's TPM/NVRAM identity.
Definition never enables autostart. A failed first definition may leave a new
empty disk; inspect it and the libvirt error before deliberately removing that
empty artifact and retrying. Never delete an existing Windows disk to resolve it.

### Unattended installation

`vm-install` creates and configures a new VM with no input in Windows:

```bash
host-config vm-install --host laptop-ubuntu --ask-become-pass --gui \
  --windows-iso /var/lib/libvirt/images/windows.iso \
  --virtio-iso /var/lib/libvirt/images/virtio-win.iso
```

1. `guest-media` renders an installation CD (placed beside the Windows ISO with
   sudo): `autounattend.xml` wipes disk 0, installs `windows_edition` with the
   generic install key, loads the VirtIO storage/network drivers, skips the online
   account requirement, names the computer `windows_computer_name`, sets
   `windows_timezone`, keeps Windows Update from delivering drivers (both the quality
   update policy and device installation's own driver search), pauses Windows Update
   for a week (Settings' "Pause updates", which then expires on its own) so the first
   cumulative update does not compete with setup, turns off AC sleep, hibernation and
   display blanking (an idle fresh guest slept after 15 minutes and the passed-through
   RTX bug-checked with DRIVER_POWER_STATE_FAILURE), and creates the
   local administrator `user` with **no password**, signed in automatically. The
   VM sits behind the Linux session lock, so Windows has no password and never locks.
2. The VM is defined with that third CD and started; Enter answers the CD loader's
   key prompt.
3. At first sign-in the VirtIO guest tools (QEMU guest agent, SPICE agent) install
   and `spawnkit\bootstrap.ps1` installs Microsoft's pinned Win32-OpenSSH server
   (10.4.0.0, SHA-256-checked; Windows Update's OpenSSH capability took hours on a
   fresh install busy with its first cumulative update) with PowerShell as its shell,
   the `windows_authorized_key` in `administrators_authorized_keys`, and firewall
   rule `Spawnkit-SSH` limited to the libvirt network in place of the installer's
   own rule.
4. Once SSH answers, `guest-apply` runs (below), then the unattended CD is ejected
   and deleted so it can never wipe the disk again.

It refuses an existing domain and starts only when nothing holds the RTX (`--gui`
offers to close holders). Activation follows the machine's license, not the install
key. For a Windows installed by other means, `guest-bootstrap` runs the same
bootstrap through the guest agent; `guest-media --output <iso>` renders the CD alone.

### Guest software

`guest-plan` (check mode with diff) and `guest-apply` configure Windows with the
`windows_guest` Ansible role over SSH, pinning the guest's ed25519 host key (read
through the guest agent) for that run. The role downloads pinned, SHA-256-verified
installers to `C:\ProgramData\spawnkit\cache` and installs the VirtIO guest tools,
WinFsp and the virtiofs service (when `windows_share` is set), Tailscale, Chrome,
Webex (per machine, started at sign-in by an HKLM Run value), Looking Glass's indirect display driver and NVIDIA's display driver 621.01
(driver package only, from `nvlti.inf`; when the RTX already runs another version
it stops and points to the procedure below). It sets `windows_timezone`, keeps
Windows Update from replacing drivers (`ExcludeWUDriversInQualityUpdate` and
`DriverSearching\SearchOrderConfig=0`; device installation ignores the policy),
because the driver it delivered (616.56) bug-checks the passed-through RTX, and
replacing it while loaded crashed a fresh install, removes any other NVIDIA display
package from the driver store, configures automatic sign-in,
sets the input languages to `windows_guest_input_languages` (English US
then Hebrew, switched by Win+Space or Alt+Shift; display language and format unchanged),
hides the lock screen and disables console lock, display blanking and AC sleep:
the Linux session lock protects the VM. Every task is idempotent; a converged guest
reports `changed=0`. Tailscale login and the Windows license remain manual.
Chrome, Webex and Tailscale update themselves; Google and Cisco replace the unversioned
Chrome and Webex MSIs on each release, so a fresh install fails its hash check until
the pin is refreshed.

Looking Glass's Windows side and the Nix client must come from the same upstream
commit. B7 is the last release and lacks many Wayland fixes, so both run master: the
client builds from the `spawnkit` branch of `skamensky/LookingGlass` (upstream
`cdba29f2` plus our fixes, which point PureSpice at the `spawnkit` branch of
`skamensky/PureSpice`), and the guest installs upstream's bleeding-edge build of
the indirect display driver (IDD) of that commit, pinned by hash and checked against
the `DisplayVersion` its installer registers under `WOW6432Node`
(`B7-829-gcdba29f2f6`). Master's IDD replaces the legacy host app: it is a virtual
monitor rendered on the first non-emulated adapter (the RTX; the laptop's panel is
wired only to Intel, so Windows has no other RTX output), streams frames over
IVSHMEM, and injects keyboard and mouse sent by the client over the same channel,
so SPICE carries only audio, clipboard and the fallback. The client resizes that
monitor to its window (`win:setGuestRes`, on by default; Escape+`=` requests it
again), and the IDD's tray icon makes it the only monitor. Its driver catalogs are
signed by the developer (HostFission) rather than attested by Microsoft, so the
role adds the setup's Authenticode signer to the machine TrustedPublisher store
before the silent install, which also installs the `LGIddHelper` service. To move
forward, rebase the fork branch onto the new upstream commit, update the client
`rev`/`hash` in `nix/modules/home/virtualization.nix`, and pin the matching driver
from `https://looking-glass.io/artifact/bleeding/idd` (its redirect is
content-addressed). After the PCI layout changes (for example removing VGA), Windows
re-enumerates the RTX and needs a minute to reinstall it; the IDD binds its render
adapter when its device starts, so restart the `Root\LGIdd` device (`pnputil
/restart-device`) if the client then shows no picture; the role does this after
installing an NVIDIA driver. The SPICE VGA console alone does
not establish a captured NVIDIA desktop.

The domain presents one socket of two-thread cores (`windows_vcpus` must be
even) because Windows Home uses only one CPU socket.

Verify Windows apps, sound, input and fullscreen behavior. Once GPU display works,
shut Windows down, set `windows_video: none`, clear installation ISO settings for
normal operation, and rerun `vm-define`. VGA can instead remain declared if the
tested guest display arrangement needs it. Firmware and TPM data are retained.

## 3 Daily lifecycle

```bash
host-config vm-view       # start if stopped, then launch Looking Glass
host-config vm-stop       # graceful shutdown, then wait for verified GPU return
host-config vm-pause      # freeze the guest (memory and the RTX stay with it); vm-resume continues it
host-config vm-restart    # ACPI restart; the RTX stays with Windows
host-config gpu-status    # root device/reservation inspection
host-config gpu-holders   # JSON: Linux programs holding the RTX, each with "closable"
host-config gpu-release --pid N [--pid M] [--force]   # SIGTERM (then SIGKILL) closable holders
```

The `--gui` checklist is a front end over `gpu-holders` and `gpu-release`; agents
call those directly, then `vm-start`. `/etc/sudoers.d/50-spawnkit-gpu-handoff`
lets the user run exactly the guard's `status`, `holders`, `detach-desktop`,
`attach-desktop` and `schedule-start` (the logout-deferred start unit) without a
password; `reclaim` and everything else still need sudo authentication.

The checklist is a Spawnkit dialog (`scripts/spawnkit-ui.py <dialog>`), QML on
Ubuntu's PySide6 and Kirigami, so it uses Plasma's own Qt and colour scheme. The
first line on stdin is the dialog's input; every further line is a message the
dialog receives, and each message it sends is one JSON line on stdout, so
`host-config` (`UiDialog`) keeps the window open and shows the closing live:
the chosen rows get a spinner, then a green mark; a program that ignores SIGTERM
turns the same window into the force-quit question; and when only the compositor
is left the window offers **Log out now** (`org.kde.Shutdown` over D-Bus). The
components in `scripts/spawnkit-ui/Spawnkit` give every Spawnkit applet one look:
a frameless floating card with a soft shadow (`DialogWindow`, draggable by its
header, Esc cancels, Return triggers the primary action), `Theme` tokens for
colour, spacing, radii and motion (durations follow Plasma's animation speed, so
reduced motion is honoured), `Button` (primary, danger, tonal, ghost, busy),
`ListRow` with an `IconTile` (app icon or a monogram), `Check`, `Chip`, `Steps`
(the path to Windows: close, log out, start), `Callout`, `SectionLabel`, `Spinner`
and `IconButton`. Type is Inter and Inter Display with IBM Plex Mono for command
lines; the accent is Spawnkit's indigo. New applets add a file to
`spawnkit-ui/dialogs` rather than using zenity or kdialog.

The desktop entries are **Windows**, **Windows (no RTX)** and **Windows
installation console**, installed in `~/.local/share/applications` because GNOME
Shell does not notice launchers added to the replaced profile directory until the
next login. Activation pins **Windows** (four-pane icon; the viewer's window groups
under it) to the dock and Plasma's panel, appended to the user's own pins. Its desktop
actions are **Open in a window**, **Start without the RTX**, **Pause**, **Resume**,
**Restart**, **Shut down** and **Force power off** (`vm-view --windowed`,
`vm-view --without-rtx`, `vm-pause`, `vm-resume`, `vm-restart`, `vm-stop` and
`vm-force-stop`, all `--notify`). In Plasma's
forked task manager a right click shows only those valid now: `spawnkit-badges`
lists them in the launcher's tag (off: open in a window, start without the RTX;
running: open in a window, pause, restart, shut down; paused: resume, shut down;
stopping while the domain still runs: force power off; none while starting). Pause freezes the guest with its memory and the
RTX and tags the icon "paused". Force power off cuts the guest like a held power
button, losing unsaved data, and the release hook still returns the RTX. `vm-stop`
resumes a paused guest before its graceful shutdown, whose progress the icon's
pulsing stopping tag shows (only a failure produces a notification).
The viewer opens fullscreen. Looking Glass B7 on Wayland requested fullscreen
before its first configure (upstream reworked this after B7; the workaround stays until re-tested), so KWin flags the window fullscreen at the default
1024x768; host-config re-enters fullscreen through a one-shot KWin script
(`scripts/lg-fullscreen.js`) for the first 15 s after each launch so the window fills
its output. Launch failures also produce a desktop
notification. The console entry opens the console; start first if the VM is off.
Closing Looking Glass leaves Windows running.

The domain's `memtune` hard limit caps the whole QEMU process at guest RAM plus
Looking Glass memory plus 2 GiB. QEMU once grew by about 170 MB/s while Looking Glass
flooded its SPICE connections; uncapped, that exhausted RAM and swap and the kernel
killed desktop apps. With the cap, only the guest dies, but it swaps guest memory
first, so Windows (and call audio) stutters before the kill.

The flood was one bogus pointer move: after a resize such as Insert+F, B7 could compute
a delta of about 2e9 px, and PureSpice splits every move into 127 px virtio-mouse
steps, so it sent a single 270 MB message (`Only wrote ... of the expected ... bytes`
in `~/.local/state/spawnkit/looking-glass.log`) whose millions of motion events QEMU
queued. Our PureSpice commit drops any move over 16384 px and logs
`Dropping an implausible ... px mouse motion`. The move's source: a resize that briefly
leaves a 0 px output rectangle makes the cursor scale infinite, the fractional
accumulator becomes NaN, and every later move converts to INT_MIN (the mouse goes
dead) until a capture toggle resets it. Our client commits keep the previous scale for a 0 px rectangle and reset
a non-finite accumulator, logging `Dropping a non-finite mouse motion`; they test the
float bits because the client builds with `-ffast-math`. The 0 px rectangle itself
comes from leaving full screen: KWin then configures the window as 0x0, which
xdg-shell means "choose your own size", and B7 adopted it literally, committing frames
unthrottled (about 900 a second: black flashing and a stalled desktop) until a real
configure arrived. A `WAYLAND_DEBUG=1` run showed it; upstream master (`b397b7c6`)
already keeps the previous size. To record a reproduction, run
`scripts/vm-trace.py` (QEMU memory, CPU and cgroup, SPICE socket queues, Looking
Glass log lines, twice a second) into `~/.local/state/spawnkit/vm-trace-*.jsonl`. Do not lower the guest's
`oom_score_adj` instead: that protects the runaway process and sacrifices the desktop.
`home-config` holds `$XDG_RUNTIME_DIR/home-config.lock` for its whole run so two
evaluations (about 4 GB each) never overlap.

**Windows (no RTX)** (`vm-view --without-rtx`, also accepted by `vm-start`) starts
Windows once from its definition minus the RTX functions and Looking Glass memory,
with a virtio display instead; the stored definition is unchanged. The RTX stays on
Ubuntu, the guard reserves nothing, and the view opens the SPICE console in
virt-manager because Looking Glass has nothing to capture. Expect basic graphics
only; shut down and start normally to get the RTX back. Without the
IVSHMEM device the IDD cannot open its transport, so Windows is expected to use the
virtio display alone; this has not been tested since the switch to the IDD. While Windows runs without the RTX, Ubuntu apps
such as Chrome's GPU process can open it, so a later normal start may ask to close
them. The picker lists and closes the program that owns a holder: a helper such as
Chrome's GPU process stands for its topmost ancestor running the same executable,
because the browser respawns a killed helper. While Windows runs, either launcher opens the viewer that matches how it was
started.

`vm-stop` requests an ACPI shutdown and waits
(default 300 s, `--timeout`) until the domain is `shut off` **and** the release
hook has cleared the reservation, which it only does after verifying the Linux
drivers and `nvidia-smi -L`. It never forces power-off; on timeout it reports
which of the two did not happen. A Windows installer without guest power handling
may need shutdown from inside Windows.

1. The launcher starts the dedicated NAT network if needed and detaches the RTX
   from the desktop seat (`gpu-guard.py detach-desktop`, a runtime udev rule under
   `/run`). If nothing still holds the RTX it asks libvirt to start the domain.
   With `--gui` (the desktop entry) and anything holding the RTX, a checklist
   groups every holder into ones Spawnkit closes and ones it cannot (`gpu-guard.py holders`), with how each releases the RTX and its command line:
   your own programs are checked and get SIGTERM, then a SIGKILL after 10 s once
   you confirm **Force quit** in the same window; the compositor and Xwayland need
   a logout, which the window offers once the rest has closed; a service or another
   user's process must be stopped by its owner (the `systemctl stop` command is
   shown, with a copy button, and the window says plainly that nothing has been
   closed). **Start without RTX** starts Windows without it instead (see below);
   Cancel, a crashed dialog or any later failure returns the RTX to the desktop.
   The NVIDIA services that keep the RTX open regardless of logins
   (`nvidia-powerd`, Dynamic Boost on laptops, and `nvidia-persistenced`) are
   stopped by the root guard with the detach and started again once the RTX is
   back on Linux, so they never appear as holders; the running ones are noted
   in `/run/spawnkit/gpu-services.json` meanwhile. Any other holder a logout
   cannot release refuses the start rather than waiting out the timeout, and a
   second launch while a start already waits for logout says so. If the desktop itself still holds it, the logout path
   below applies. Otherwise it schedules the root unit `spawnkit-windows-handoff`, which waits up
   to 15 minutes for the holders to exit (normally: you log out, which ends Xorg
   and the session's apps), then starts Windows; log back in and open Looking
   Glass. A timeout or failed start returns the RTX to the desktop seat. It never
   applies Ansible implicitly.
2. The root `prepare begin` hook validates the actual domain UUID/PCI functions,
   requires `managed='yes'`, checks IOMMU isolation and original drivers, and
   checks GPU/DRM/audio device users with `fuser`.
3. Busy jobs/containers/GUI apps cause refusal with PIDs and process names. Nothing
   is killed. Known non-job holders get specific advice: `nvidia-persistenced`
   and `nvidia-powerd` (only reachable when the VM is started by hand, since
   `host-config vm-view` stops them) name the service to stop; `gnome-shell`, `Xwayland` and
   `Xorg` mean the desktop itself opened the RTX (see laptop risks below).
   Explicitly finish/close that work or stop the named service, then retry.
   CPU-only containers can keep running.
4. An exclusive root reservation prevents another configured libvirt guest from
   taking the same functions. Shared memory is sized before the VM starts.
5. Libvirt detaches the managed PCI functions and reattaches them on release.
   The hook never calls `virsh` or any libvirt API, avoiding callback deadlocks.
6. `release end` verifies original drivers and `nvidia-smi -L` health, retrying
   briefly while the module settles. Failure leaves the reservation as an
   explicit recovery signal. Inspect libvirt
   journal output; the hook cannot veto a shutdown or guarantee kernel recovery.

Process checks reduce risk but cannot make a hardware handoff atomic with
unrelated root processes. Do not launch a new Linux GPU job during VM startup.
A driver can hang during PCI unbind/reset despite these checks. Keep console
access and reboot as a last resort; never remove a reservation while a VM is
alive. A stale reservation makes the next start fail with recovery instructions.
Confirm the guest is off, then run
`sudo /usr/local/libexec/spawnkit/gpu-guard.py reclaim`: it clears the reservation
only if every configured function is back on its declared driver and
`nvidia-smi -L` works. A reboot clears it too; neither touches Windows data.

## 4 Guest integration

The definition always carries a QEMU guest agent channel. After installing the
VirtIO guest tools (`virtio-win-guest-tools.exe` from the VirtIO ISO), Linux can run
PowerShell in Windows as SYSTEM without a password or network:

```bash
host-config vm-exec --command 'Get-Service sshd'
host-config vm-exec < script.ps1
```

The exit code and output streams are the guest command's. Use it for bootstrap
and recovery; routine automation can use SSH.

- **Stable address:** `windows_mac` pins the guest NIC and `windows_address`
  reserves it outside the dynamic DHCP range. Changing an existing reservation is
  applied live with `virsh net-update`. Ansible adds `Host <windows_name>` under
  `/etc/ssh/ssh_config.d/`, so `ssh windows` reaches the guest's OpenSSH server
  (Win32-OpenSSH from the bootstrap, PowerShell default shell, the Linux
  public key in `C:\ProgramData\ssh\administrators_authorized_keys`). From
  Windows, reach Linux through its declared SSH listener. Windows cannot run
  Tailscale SSH, so the firewall rule `Spawnkit-SSH-Tailnet` also admits the
  key-only OpenSSH server from the tailnet ranges for machines such as the
  personal agent VM.
- **Shared folder:** `windows_share` exports a host directory over virtiofs
  (shared memfd memory backing, tag `spawnkit-share`); Ansible creates it for the
  user. `guest-apply` sets `OverrideUid`/`OverrideGid` under
  `HKLM\SOFTWARE\VirtIO-FS` to the Linux user's IDs so created files belong to that
  user. It appears as drive `Z:`.
- **NVIDIA driver updates:** with 616.56 the passed-through RTX bug-checked
  (0x7E in `nvlddmkm.sys`) whenever the driver unloaded: on device disable, guest
  reboot, and inside NVIDIA's installer (exit 9). Each crash destroyed the domain
  and the RTX returned to Linux intact. To replace a driver that cannot unload,
  extract the package (`tar.exe -xf <driver>.exe -C <dir>`), stage the INF that
  names the GPU's `SUBSYS` (`pnputil /add-driver <dir>\Display.Driver\nvlti.inf`
  for the Legion), set `HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm` `Start`
  to 4, start the guest again, then `pnputil /add-driver ... /install`; the INF
  restores `Start` to 3. 621.01 (32.0.16.2101) shut down cleanly. Afterwards
  restart the `Root\LGIdd` device.
- **Stuck shutdown:** since the switch to the IDD (2026-11-05), both shutdowns
  observed hung with all vCPUs at 100% instead of taking 10 to 20 seconds. Each
  ended, by the normal guest power-off path, within 6 ms of an HMP `info registers
  -a`, which suggests a vCPU kick releases the guest; the cause is unknown. Sample a
  hang from the host without touching the vCPUs (`perf` on `kvm:kvm_exit`), because
  that query ends it.
- **Crash dumps:** the domain enables the host's Hyper-V enlightenments except
  crash notification. With it, Windows reported each bug check before writing its
  dump and libvirt destroyed the domain, leaving no evidence. Now Windows writes a
  small dump to `C:\Windows\Minidump`, logs event 1001 (BugCheck) and restarts
  itself; a driver that crashes at every boot therefore loops until `vm-stop`.
  Bug-check codes so far: 0x7E in `nvlddmkm.sys` when the driver was replaced while
  loaded, and 0x9F (DRIVER_POWER_STATE_FAILURE) when the idle guest went to sleep.
- **Clipboard:** the SPICE agent from the VirtIO guest tools carries clipboard
  through Looking Glass's SPICE connection while the viewer runs. Text and images
  copied in Windows reach the Ubuntu clipboard, so CopyQ keeps them in its history;
  images also go from Ubuntu to Windows.
- **Audio:** Looking Glass presents an emulated "Looking Glass USB Audio" device
  (speakers and microphone) through the domain's SPICE USB redirection channel
  (`redirdev type='spicevmc'`) and carries it to PipeWire. While that device is
  active the client leaves SPICE's classic playback and record channels closed, so
  without the channel Windows has no working audio at all. The ICH9 HDA device
  (`micro` codec: Speakers and a Microphone) remains as the classic path for
  `spice:usbAudio=no`. Windows apps must use the Looking Glass USB Audio
  endpoints. A viewer only sees a hot-plugged channel after it reconnects. Looking
  Glass tags its streams `media.role=Music`, which WirePlumber restores volume and
  mute by, so a saved muted Music state once silenced Windows; a WirePlumber rule
  (loaded when WirePlumber restarts) stops restoring Looking Glass streams. `vm-view` passes `audio:micDefault=allow`, so calls open the microphone
  without a prompt (Looking Glass still shows its recording indicator). The desktop
  launcher picks up launcher changes only after a Home Manager switch.
- **Keyboard and mouse:** while focused, Looking Glass grabs the keyboard
  (`input:grabKeyboardOnFocus`), so Alt+Tab and Super go to Windows. Insert is
  the escape key: tap it to toggle input capture, hold it with F to leave or re-enter fullscreen or Q
  to close the viewer (Windows keeps running). The guest role sets the pointer
  speed to `windows_guest_mouse_sensitivity` (6 of 20).
  The VM has virtio mouse and keyboard devices and no USB tablet, as Looking Glass
  requires.
- **Alt+Tab into the viewer (X11):** B7 dropped the pointer-enter event that arrives
  when a window is raised under the pointer during a grab (GNOME's Alt+Tab switcher
  sends it with the Ungrab mode). Master accepts that event (see gnif/LookingGlass#1350).
- **Input stall watchdog:** `vm-view` runs `scripts/lg-watchdog.py` beside the
  viewer as a safety net. While the viewer is focused, the pointer is over it and X
  sees input, its SPICE input channels must send; the main channel (the client's
  first socket) and any channel streaming while the user is idle (the microphone) do
  not count. After 1.5 s without traffic the watchdog silently restarts the viewer, appending the event to
  `~/.local/state/spawnkit/looking-glass-stalls.jsonl`; more than five restarts in a
  minute stops `vm-view`. The viewer's own log is
  `~/.local/state/spawnkit/looking-glass.log`.
- **Clipboard history:** CopyQ runs on both systems and Ctrl+` opens it on whichever
  one has the keyboard. Ubuntu's CopyQ saves new items within 10 s, and a user path
  unit copies its tabs to `~/Shared/.copyq` (`personal.desktop.copyqShare`). At each
  Windows sign-in the `Spawnkit CopyQ` scheduled task loads that copy from
  `Z:\.copyq` into Windows' CopyQ. Clips copied in Windows reach Ubuntu's CopyQ
  through the SPICE clipboard; Windows' own history is replaced at the next sign-in.
- **USB devices:** `windows_usb_devices` lists `{vendor, product}` IDs (0x-prefixed
  hex) libvirt hands to Windows at start (`startupPolicy='optional'`, so an absent
  device does not block boot). Linux loses them until the VM stops. The laptop
  passes its integrated camera (30c9:00ac).

## Laptop-specific risks (unverified on the Legion 5 16IRX9)

These decide feasibility and can only be measured natively; record each result
in the migration log.

- **Desktop holding the RTX.** With PRIME on-demand (`nvidia_prime` in the laptop
  profile) the desktop renders on Intel, but GNOME/mutter still opens the RTX's
  DRM node when it can drive outputs. If `vm-start` names `gnome-shell`, the
  handoff requires a session that does not use the RTX. Udev tags such as
  `mutter-device-ignore` are reported to be timing-sensitive and can break the
  session, so none is installed automatically; test any such rule manually with
  console access first.
  Under Xorg, Ubuntu's PRIME on-demand config adds the RTX as a GPU screen, and
  Xorg opens every seat0 DRM device through logind even with `AutoAddGPU off`
  (measured 2026-11-03: Xorg still held `/dev/dri/card2`), keeping it until the
  session ends. The Linux desktop therefore owns the RTX by default (render
  offload, RTX-wired outputs, CUDA), and starting Windows from a running X
  session means logging out once: the launcher moves the RTX's DRM nodes to a
  seat with no master device, so the next greeter/session and its ACLs never
  reach it. The release hook moves them back after verifying the GPU return;
  CUDA is available at once, and the X session regains render offload at the
  next login. The rule lives in `/run`, so a reboot also returns the RTX.

- **Display wiring.** On many Legion models the HDMI port is wired to the RTX
  and the internal panel to Intel (or a MUX switches it). A monitor on an RTX
  output disappears from Linux while Windows owns the GPU, and that output is a
  candidate for the guest display/dummy plug. Determine the wiring from `facts`,
  `/sys/class/drm` connectors and BIOS GPU mode; keep BIOS in Hybrid mode.
- **Laptop dGPU quirks.** Mobile NVIDIA GPUs may need the vBIOS exposed to the
  guest or an ACPI battery table before the Windows driver initializes (Code 43).
  No ROM file or ACPI table is shipped; add one only after native diagnosis.
- **Reset and power.** Confirm the RTX returns to `nvidia` over repeated cycles,
  including after Windows sleeps it, and that runtime power management still
  idles the dGPU on Linux afterwards.
- **Shared memory.** Standard `ivshmem-plain` is the low-maintenance default; the
  KVMFR module avoids a copy but needs an out-of-tree DKMS module that must follow
  every Ubuntu kernel and Secure Boot signing. Adopt it only if measured latency
  at the target resolution is unacceptable.

## Acceptance before replacing dual boot

- Baseline: native driver loads, Secure Boot policy is satisfied, Intel desktop
  survives normal NVIDIA Linux workloads and GPU containers.
- A running CUDA job/GPU container makes VM start fail without killing work.
- Windows boots with TPM/Secure Boot, uses RTX acceleration, and Looking Glass
  captures the desired display at acceptable resolution/latency.
- Multiple start/shutdown cycles return NVIDIA functions and Linux compute;
  shared-memory permissions and AppArmor confinement remain intact after reboot.
- If AppArmor denies shared memory, inspect the exact libvirt generated profile
  and installed Ubuntu policy; add a narrowly scoped tracked policy rule for the
  one shared-memory path. Never disable AppArmor or make QEMU unconfined.
- Back up the powered-off disk, domain XML, NVRAM and swtpm state together and test
  restoration. Check required USB devices and Windows applications.

Primary references: [libvirt hooks](https://libvirt.org/hooks.html),
[PCI host devices and shared memory XML](https://libvirt.org/formatdomain.html),
[Looking Glass shared memory](https://looking-glass.io/docs/B7/ivshmem_shm/),
[Looking Glass installation](https://looking-glass.io/docs/B7/install/),
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
