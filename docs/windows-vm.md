# Windows GPU passthrough on Ubuntu and responsibility for configuration

For this laptop, the useful target is an Ubuntu desktop running on Intel graphics, with the RTX 4060 available either to Linux applications or to a Windows VM at different times. Looking Glass can display Windows inside the Ubuntu desktop. Switching the RTX between operating systems is a hardware and driver operation that must happen only after its current users release it.

I recommend testing that handoff on native Ubuntu before making it part of everyday use. Home Manager should own the user tools and launcher. Ubuntu should own the privileged virtualization backend and kernel integration. Keep the configuration, templates and installation procedure together in the infrastructure repository so migration remains repeatable.

## What Looking Glass does

Looking Glass displays a Windows VM desktop in a Linux window or fullscreen, with keyboard and mouse interaction. In our proposed setup, Windows renders using its passed-through RTX; the Windows capture component transfers frames through shared memory, and the Linux client displays them using Intel graphics. It avoids the encode/network/decode path of ordinary video streaming. It does not arbitrate ownership of the RTX. [Looking Glass overview](https://looking-glass.io/), [capture and shared memory documentation](https://looking-glass.io/docs/B7-rc1/usage/).

The practical arrangement is:

```text
Windows apps → RTX rendering → shared memory → Looking Glass on Linux → Intel → screen
```

The host still needs a usable graphics device. Looking Glass's B7 requirements explicitly allow integrated graphics plus a discrete GPU, and recommend KVMFR/DMABUF for the host iGPU to reduce memory bandwidth overhead. Actual resolution and refresh rate need testing. [Looking Glass requirements](https://looking-glass.io/docs/B7/requirements/).

A Windows display must also exist for the selected capture method. The physical monitor, dummy plug or virtual display arrangement depends on the Looking Glass release and the laptop's display routing; choose and test that arrangement with matching Windows and Linux components.

## The main ways to allocate the GPU

These are architectural choices, rather than estimates of how many users choose each one.

| Arrangement | Linux use of RTX | Operational consequence |
| --- | --- | --- |
| Reserve the RTX for the guest by binding it to VFIO at boot | Unavailable, including while Windows is off | Avoids switching away from a live NVIDIA host driver. Good when Linux only needs Intel. |
| Give the RTX to Linux normally and hand it to Windows on demand | Available while the guest is off | Requires all host users to release it, successful detach, and successful return after shutdown. Best fit for alternating Linux GPU work and Windows. |
| Pass through the only desktop GPU | Host graphical session loses its graphics device | Requires releasing the graphical session and restoring it afterward. Adds disruption and recovery work. Our Intel GPU makes this unnecessary if it can drive the required host displays. |
| Use a supported shared GPU virtualization implementation | Depends on hardware and virtualization support | A different product capability from whole-device passthrough; not a supported sharing plan for this GeForce RTX 4060. |

VFIO assigns devices subject to IOMMU isolation groups. A group can include related GPU functions or other devices, so inspecting just the graphics function is insufficient. [Linux VFIO documentation](https://kernel.org/doc/html/latest/driver-api/vfio.html).

NVIDIA's GeForce passthrough FAQ describes one Windows VM and explicitly excludes SR-IOV. Its published support statement is from 2021 and is not certification of this laptop with Windows 11. The current supported vGPU hardware list does not include the GeForce RTX 4060. [GeForce passthrough FAQ](https://nvidia.custhelp.com/app/answers/detail/a_id/5173/), [supported vGPU hardware](https://docs.nvidia.com/vgpu/gpus-supported-by-vgpu.html).

## What happens if Linux is using the RTX

Whole-device passthrough is exclusive: Linux and the running Windows guest cannot use the same passed-through device simultaneously. Libvirt's `managed='yes'` setting handles detachment at guest start and reattachment at shutdown; it does not migrate running CUDA or graphics jobs to Intel. [Libvirt device management](https://www.libvirt.org/manpages/virsh.html#nodedev-detach).

There is no universal promise that starting the VM while the GPU is busy produces a quick, harmless error. Detachment can fail or block. A user-reported NVIDIA issue opened on September 19, 2026 reproduces an indefinite unbind hang with driver 595.99.02 after initiating removal while CUDA held the GPU. That is a specific report, not proof that every driver has the same bug. It is enough reason to avoid treating detachment itself as a busy check. [NVIDIA issue 1374](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1374).

Forcefully stopping the GPU users can terminate work and lose application state. Pausing a process does not release its GPU resources. An idle utilization reading also does not establish that the driver has no clients: a process can retain a context or open device without currently executing GPU work.

## Recommended handoff policy

This is the proposed behavior for our future launcher and host integration:

1. Keep the Linux desktop and Looking Glass on Intel. Explicitly launch selected Linux workloads on NVIDIA when Windows is off. NVIDIA documents PRIME render offload for this general arrangement; the desktop compositor must also be checked for unwanted RTX ownership. [NVIDIA PRIME documentation](https://download.nvidia.com/XFree86/Linux-x86_64/570.169/README/primerenderoffload.html).
2. Before VM start, acquire a handoff lock and prevent configured GPU services from restarting during the transition. Inspect NVIDIA processes and open device handles, including DRM render nodes, CUDA users, GPU containers, monitoring and background services.
3. If users remain, refuse startup and show the blocking processes or services. Do not silently kill them. Save or finish the work and close them deliberately.
4. Detach the complete required set of PCI functions, then start Windows. Use libvirt managed devices where suitable rather than duplicating its device management in scripts.
5. Keep the RTX unavailable to new Linux workloads while Windows owns it.
6. After Windows shuts down, restore the host driver and relevant services. Confirm GPU health and a small Linux GPU workload before reporting it available.

A shell launcher alone is insufficient because virt-manager and other libvirt clients could bypass it. Put the refusal check in a libvirt pre-start hook as well. Libvirt documents startup hooks that can abort guest start. Hooks must not call back into libvirt, because that can deadlock. Lifecycle coordination and driver work need carefully separated responsibilities. [Libvirt hooks](https://www.libvirt.org/hooks.html).

Open-file checks are a guard, not a proof against every concurrent process or kernel driver problem. The policy must coordinate known services, restrict concurrent starts, and verify actual device state. A timeout around a shell command cannot guarantee recovery from a driver blocked in the kernel.

## What must be tested on native Ubuntu

The current WSL session cannot establish the laptop's native passthrough feasibility. Test VT-d/IOMMU support and groups, GPU PCI functions, hybrid graphics mode, internal panel and external connector routing, Windows driver initialization, and repeated guest start/shutdown followed by Linux GPU use.

Also test the required Windows applications and peripherals, and laptop suspend/resume with the VM stopped. If a connector is driven by the RTX, it cannot simultaneously remain a Linux-driven output while that RTX belongs to Windows. A Looking Glass window can display Windows on an Intel-driven screen; it does not rewire physical ports.

Keep dual boot until these checks pass. If repeated handoff proves unreliable, reserving the RTX for the VM avoids dynamic switching, but gives up native Linux use of that GPU. The other practical choice is to retain Linux ownership and boot Windows for workloads that need it.

## What Nix should own on Ubuntu

| Component | Recommended owner |
| --- | --- |
| virt-manager, virt-viewer and libvirt client commands | Home Manager packages, connecting explicitly to `qemu:///system` |
| Looking Glass client, configuration and desktop launcher | Home Manager |
| VM templates, hardware identifiers, helper source and setup procedure | Tracked infrastructure repository, with host-specific values |
| QEMU backend, libvirt system daemon, OVMF firmware and swtpm | Ubuntu packages and host setup |
| KVM, VFIO, IOMMU boot settings and NVIDIA driver | Ubuntu kernel and host setup |
| AppArmor, device permissions, networking, privileged hooks and optional KVMFR module | Ubuntu host setup, with tracked source and installation steps |
| Windows disk, UEFI variable store, TPM state and user data | Mutable state with backups outside the Nix store |

Ubuntu documents QEMU and libvirt as host packages, while virt-manager acts as a client. Libvirt distinguishes the privileged system instance from per-user sessions. Installing a Nix client does not replace the system daemon or change which QEMU executable that daemon launches. [Ubuntu libvirt installation](https://ubuntu.com/server/docs/how-to/virtualisation/libvirt/), [virt-manager architecture](https://ubuntu.com/server/docs/how-to/virtualisation/virtual-machine-manager/), [libvirt daemon architecture](https://www.libvirt.org/daemons.html).

Nix can provide a QEMU executable on Ubuntu. It is not inherently incompatible. However, making Ubuntu's libvirt use that executable requires deliberate backend configuration and validation of service-user access, security profiles, helpers and firmware. Libvirt's security model includes per-VM AppArmor profiles and device access controls. Merely adding QEMU to the interactive shell's PATH does not configure these. For this workstation I recommend keeping that integrated backend together in Ubuntu. [Libvirt QEMU driver and security architecture](https://libvirt.org/drvqemu.html).

The repository can still be the source of truth for the overall setup: Home Manager builds the user environment, and a tracked host procedure installs the Ubuntu requirements and privileged configuration. This gives repeatable setup without claiming that a Home Manager build reconstructs the kernel, hardware isolation or Windows state. GPU identifiers and display routing will need reassessment on another machine.

This design is pending implementation and native hardware validation. No VM, GPU driver binding or persistent machine configuration was changed for this research.
