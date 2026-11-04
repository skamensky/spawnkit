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

Use virt-manager's SPICE VGA console for installation. If Windows cannot see its
VirtIO disk/network, load the matching Windows driver from the VirtIO ISO. Install
guest tools, NVIDIA's Windows driver and the Looking Glass Windows host component.
Use the release matching the Nix client's startup/help banner (currently **B7**);
host and client versions must match. The guest component captures Windows, while
the Linux client displays it. Windows must have an active display on the RTX: an
attached display/dummy adapter on an RTX-wired output, or a tested virtual display
driver, is necessary when the physical laptop panel is wired only to Intel. Looking
Glass's own indirect display driver removes the dummy plug but ships in builds
newer than stable B7, so adopting it also means packaging a matching Linux client;
treat that as a separate, measured change. The SPICE VGA console alone does not
establish a captured NVIDIA desktop.

The laptop uses the signed Virtual Display Driver
(`VirtualDrivers/Virtual-Display-Driver`, tested 25.7.23, hardware ID `Root\MttVDD`).
Its `C:\VirtualDisplayDriver\vdd_settings.xml` sets `<gpu><friendlyname>` to the
RTX adapter name and lists only the panel mode (2560x1600@60), so that mode is used.
Create the root device node, trust the catalog signer in the machine
TrustedPublisher store and run `pnputil /add-driver MttVDD.inf /install`; trusting
a publisher is a security change the owner performs. After the PCI layout
changes (for example removing VGA), Windows re-enumerates the RTX and needs a
minute to reinstall it; restart the virtual display device and the Looking Glass
service if capture then reports no output device.

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
host-config gpu-status    # root device/reservation inspection
```

The desktop entries are **Windows (Looking Glass)** and **Windows installation
console**. Launch failures also produce a desktop notification. The latter opens the console; start first if the VM is off. Closing
Looking Glass leaves Windows running. `vm-stop` requests an ACPI shutdown and waits
(default 300 s, `--timeout`) until the domain is `shut off` **and** the release
hook has cleared the reservation, which it only does after verifying the Linux
drivers and `nvidia-smi -L`. It never forces power-off; on timeout it reports
which of the two did not happen. A Windows installer without guest power handling
may need shutdown from inside Windows.

1. The launcher starts the dedicated NAT network if needed and detaches the RTX
   from the desktop seat (`gpu-guard.py detach-desktop`, a runtime udev rule under
   `/run`). If nothing still holds the RTX it asks libvirt to start the domain.
   Otherwise it schedules the root unit `spawnkit-windows-handoff`, which waits up
   to 15 minutes for the holders to exit (normally: you log out, which ends Xorg
   and the session's apps), then starts Windows; log back in and open Looking
   Glass. A timeout or failed start returns the RTX to the desktop seat. It never
   applies Ansible implicitly.
2. The root `prepare begin` hook validates the actual domain UUID/PCI functions,
   requires `managed='yes'`, checks IOMMU isolation and original drivers, and
   checks GPU/DRM/audio device users with `fuser`.
3. Busy jobs/containers/GUI apps cause refusal with PIDs and process names. Nothing
   is killed. Known non-job holders get specific advice: `nvidia-persistenced`
   and `nvidia-powerd` name the service to stop; `gnome-shell`, `Xwayland` and
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
  (Windows optional feature `OpenSSH.Server`, PowerShell default shell, the Linux
  public key in `C:\ProgramData\ssh\administrators_authorized_keys`). From
  Windows, reach Linux through its declared SSH listener.
- **Shared folder:** `windows_share` exports a host directory over virtiofs
  (shared memfd memory backing, tag `spawnkit-share`); Ansible creates it for the
  user. In Windows, install WinFsp, set DWORDs `OverrideUid`/`OverrideGid` under
  `HKLM\SOFTWARE\VirtIO-FS` to the Linux user's IDs so created files belong to that
  user, and set the `VirtioFsSvc` service to automatic. It appears as drive `Z:`.
- **Clipboard:** the SPICE agent (`spice-vdagent-x64` MSI from spice-space.org)
  carries clipboard through Looking Glass's SPICE connection.

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
