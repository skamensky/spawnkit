# TopLap123: WSL + Windows → native Ubuntu (agent runbook)

Written 2026-10-14 by surveying WSL (Ubuntu 24.04.2) and the Windows host. **This file is for the agent doing the migration.** Shmuel will hand it to you; work through it in order.

---

## 0. Agent brief: read this first

### Goal
Move everything that matters from **WSL Ubuntu** (a 313 GB `ext4.vhdx` on C:) and **Windows** (`C:\Users\shmuel`) into the **native Ubuntu install that already exists on partition 5** of the same SSD. Preserve paths so that agent sessions, git worktrees and tools keep working. Windows stays as a dual-boot fallback until Shmuel decides to delete it.

### Canonical guide and private migration bundle

The maintained guide is `docs/ubuntu-migration.md` in
`~/repos/skamensky/spawnkit`. This Git repository owns reusable
configuration and the migration procedure. The separate bundle below holds
private inventories, migration scripts, exports, checkpoints and execution logs;
those must not be committed. Offline copies of this guide travel in the bundle,
but edit the repository copy and refresh those exports before hand-off.

| Environment | Path |
|---|---|
| WSL | `~/tmp/ubuntu-migration/` (`docs/`, `inventory/`, `scripts/`) |
| Windows | `C:\Users\shmuel\Downloads\ubuntu-migration\` (a copy) |
| Native Ubuntu, before the WSL disk is mounted | `/mnt/win/Users/shmuel/Downloads/ubuntu-migration/`. First thing on native: copy it to `~/tmp/ubuntu-migration/` |

### Find out where you are
```bash
uname -r | grep -qi microsoft && echo WSL || echo NATIVE
```
- **WSL** → you're in Phase A (preparation).
- **NATIVE** → check `~/tmp/ubuntu-migration/MIGRATION-LOG.md` (or the copy in Windows Downloads) to see which phases are done, then continue.

### Rules
1. **Log everything** in `~/tmp/ubuntu-migration/MIGRATION-LOG.md`: each step, its result, what you copied, what you skipped and why. Before the reboot to native, copy the log into the Windows Downloads bundle so it travels.
2. **Never write to the old disks.** Mount C: (`/mnt/win`) and the WSL image (`/mnt/wsl-old`) **read-only**. They're the only fallback.
3. **Keep paths identical:** username `shmuel`, uid 1000, `/home/shmuel/...`. Codex/Claude transcripts, Claude project dirs (`~/.claude/projects/-home-shmuel-…`) and git worktrees store absolute paths.
4. **Secrets:** follow Shmuel's `personal-secrets` skill. Never print secret values in chat or logs. Don't carry the plaintext `export TOKEN=…` lines over (§A2).
5. **Stop and ask Shmuel** before you:
   - delete anything
   - push to a remote for the first time or create a new GitHub repo
   - run something in a Windows admin shell
   - touch partitions or the BIOS
   - overwrite an existing file in the native home
6. **Shmuel does these himself:**
   - typing sudo passwords. Ask him to run `sudo` commands, or to approve them, if you can't
   - OAuth logins (Codex, Claude, gcloud, gh, Tailscale if re-authenticating)
   - Chrome Sync
   - BIOS
   - Windows admin PowerShell
7. Shell commands follow Shmuel's RTK convention (`rtk <cmd>`) once `rtk` is installed on native.

### Machine facts
| | |
|---|---|
| Hardware | Lenovo Legion 5 16IRX9 (83DG), i9-14900HX, 32 GB RAM, RTX 4060 Laptop + Intel UHD (hybrid), Realtek 8852CE Wi-Fi 6E (`rtw89`) |
| Disk | one 1 TB NVMe, GPT: p1 EFI · p2 MSR · **p3 = C: NTFS 470 GB (98 % full)** · p4 recovery 2 GB · **p5 = native Ubuntu 481 GB** |
| C: | **not encrypted** (`manage-bde`: Fully Decrypted, Protection Off, 2026-10-14) |
| WSL disk | `C:\Users\shmuel\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\LocalState\ext4.vhdx` (313 GB file, 193 GB used) |
| WSL network | Tailscale node `toplap123` = **100.86.106.55**; sshd listens **only on that IP, port 2222**, key auth only |

### Phases
| Phase | Where | Summary |
|---|---|---|
| **A. Prepare** | WSL + Windows | push code, fix secrets, checkpoint in-flight agent work, snapshots, Windows exports |
| **B. Hand-off** | Windows | `powercfg /h off`, `wsl --shutdown`, Restart into Ubuntu |
| **C. Mount + copy** | native | mount C: and the vhdx read-only, rsync everything listed |
| **D. Set up** | native | drivers, packages, tools, dotfiles, agent tooling |
| **E. Resume + verify** | native | resume in-flight threads, run the verification checklist |
| **F. Decommission** | native, weeks later | only on Shmuel's explicit go-ahead |

---

## Phase A — Prepare (in WSL / Windows)

### A1. 🔴 Code that exists only on this laptop
From `inventory/repos-status.txt`. "NO-REMOTE" means this laptop holds the only copy.

| Repo | State | Action |
|---|---|---|
| `skamensky/bank-records-automation` | **723 unpushed commits, no remote**, 1.8 GB | ask Shmuel → create private GitHub repo → push |
| `skamensky/h3-lora-lab` | 9 unpushed, no remote | same |
| `skamensky/arnona-bot` | 1 unpushed + 9 dirty, no remote | commit + same |
| `image-training` (5.1 G), `sleep-tracker` (2.5 G), `learn-ml`, `web-terminal-experiment`, `tarflix`, `flight-data`, `automate-takeout` | dirty, no remote | ask: private repo, or rely on the rsync in Phase C |
| `SkylineCapital/supa-crm` + worktrees | **31 unpushed commits, 10 stashes**, `supa-crm-lead-preprocessing` dirty (3) | push branches; turn stashes into branches (`git stash branch`) after asking |
| `region-corteza` (98 dirty, 1 unpushed), `formql` (37), `polymarket-arbitrage` (41, 1 unpushed), `family-desk` (6, 8 unpushed), `google-automation`, `my-supa`, `postgres-formula-compiler` (1 stash), `safe-phone`, `shmutils`, `personal-agent-customizations`, `pgmeta` | dirty / unpushed | commit + push where Shmuel agrees |

Pushing is a safety net. Phase C still rsyncs **all of `~/repos`**, because large repos carry git-ignored data, `.env` files and models.

**Done when:** `repos-status.txt` has been regenerated (command in A4) and every NO-REMOTE / unpushed entry is either pushed or explicitly accepted by Shmuel as "rsync only".

### A2. 🔴 Plaintext secrets
Legacy shell startup files export plaintext credentials for several services. These plaintext exports are not imported by Home Manager. Load the `personal-secrets` skill and:
1. store each value in the official store, unless it's already there
2. replace the `export` lines with loads from the store
3. recommend rotation to Shmuel

Other credential material: put it in the store, or plan to re-authenticate on native. Don't treat it as ordinary files.
Cloud CLI, OAuth, registry and tunnel credential files under the home directory (inventoried privately, not here).

**Done when:** the relevant credentials have documented store/runtime mappings, and all three shell files have no plaintext credential exports. Use a name-only inspection; never print matching credential lines into chat or logs.

### A3. 🔴 In-flight agent work (Codex + Claude)
Several Codex threads were **mid-task** when this was written: their last event was `task_started` with no `task_complete`. Nothing may be lost.

1. **Snapshot.** Regenerate right before hand-off:
   ```bash
   python3 ~/tmp/ubuntu-migration/scripts/in_flight_agent_work.py --days 14 > ~/tmp/ubuntu-migration/inventory/in-flight-agent-work.md
   python3 ~/tmp/ubuntu-migration/scripts/in_flight_agent_work.py --days 30 --home /mnt/c/Users/shmuel > ~/tmp/ubuntu-migration/inventory/in-flight-agent-work-windows.md
   ```
   For each recent thread it lists the name, cwd, last user request, last agent message, and whether the last turn finished. This covers Codex threads (including archived ones), Claude desktop sessions and Claude CLI transcripts. On native, use `--root /mnt/wsl-old` to read the old disk.

2. **Unfinished at the 2026-10-14 snapshot:**
   | Codex thread | Where it stopped | Code location |
   |---|---|---|
   | **supa-gcp-alerts** | Claude audit done (17 findings addressed); agent was checking the gist for private incident details **before publishing** | cwd `~` |
   | **declarative-schemas** | Claude security review done (SQL execution bypasses, ownership, policy ordering); **fixes, regression tests and PR update not yet done** | `supa-crm/.worktrees/supa-crm-declarative-schema-poc`, branch `agent/declarative-schema-poc` |
   | **lead import** | historical reprocessing of headerless rows **was running**; uncertain tabs flagged for review | `supa-crm-lead-preprocessing` (3 dirty), branch `codex/lead-import-preprocessing`; the local Supabase stack `s-lead-preprocess` is running in Docker |

3. **Checkpoint.** These threads drove **Claude in tmux windows with bypass permissions**.
   - Run `tmux ls`, and capture each pane: `tmux capture-pane -p -S - -t <target> > ~/tmp/ubuntu-migration/tmux/<name>.txt`.
   - Ask Shmuel to have each unfinished thread do two things: (a) commit its WIP to its branch, and push it where allowed; (b) write a "where I stopped / next step" note into the thread.
   - Record the notes in the log.
4. **Local Supabase (`s-lead-preprocess`).** If the lead-import data matters, run `supabase db dump --local` (data + schema) from `supa-crm-lead-preprocessing` into `~/tmp/ubuntu-migration/db/`. Docker volumes are **not** copied.

**Done when:** the snapshot is regenerated, the tmux captures are saved, and every unfinished thread has a WIP commit and a note (or Shmuel says to skip it).

### A4. Inventories
Already in `inventory/`: `apt-user-installed.txt`, `apt-sources.list.d/`, `snap.txt`, `npm-global.txt`, `vscode-extensions.txt`, `docker-images.txt`, `custom-binaries.txt`, `windows-apps.txt`, `repos-status.txt`, `in-flight-agent-work*.md`. Regenerate the repo status right before hand-off:
```bash
cd ~/repos; for g in $(find . -maxdepth 3 -name .git -prune | sed 's|/.git$||'); do (cd "$g"; echo "$g | dirty=$(git status --porcelain | wc -l) unpushed=$(git log --branches --not --remotes --oneline | wc -l) stash=$(git stash list | wc -l) | $(git remote get-url origin 2>/dev/null || echo NO-REMOTE)"); done > ~/tmp/ubuntu-migration/inventory/repos-status.txt
```

### A5. Windows-side items that can't simply be copied (Shmuel acts; agent tracks)
- **Chrome (Windows):** 7 profiles (Default, Profile, 1, 2, 3, 4, 6). DPAPI-encrypted, so they can't be moved as files. Each profile must be **signed into Chrome Sync with passwords on**; note which account each profile uses.
- **Brave:** 1 profile, so turn on Brave Sync.
- **Firefox:** 2 profiles, which are portable and get copied in Phase C.
- **Wi-Fi:** 26 profiles. Optional: `netsh wlan export profile key=clear folder=<dir>`. The output has plaintext keys, so keep it out of chat and logs.
- **Unsaved notes:** Notepad++ backup tabs (copied in Phase C). The 3 Windows Notepad tabs are binary TabState files: open them in Notepad and save them as `.txt` to Downloads.
- **`Documents\dd.accdb`** (Access): export it to CSV/SQLite while Windows still works.
- **Logi Options+** button mappings (screenshot); **Wispr Flow** dictionary/snippets (likely no Linux client).
- **BIOS:** update through Lenovo Vantage now (harder later).

### A6. Refresh the bundle in Windows Downloads
First export the current canonical guide, then sync the private bundle:
```bash
cp ~/repos/skamensky/spawnkit/docs/ubuntu-migration.md ~/tmp/ubuntu-migration/docs/migration-plan.md
rsync -a ~/tmp/ubuntu-migration/ /mnt/c/Users/shmuel/Downloads/ubuntu-migration/
```

---

## Phase B — Hand-off (Windows, Shmuel)
In **admin PowerShell**:
```powershell
powercfg /h off     # turns off hibernation + Fast Startup so Linux can mount C: (also frees ~12 GB hiberfil.sys)
wsl --shutdown      # cleanly closes the WSL disk
```
Then **Restart** (not Shut down) and boot Ubuntu.
If `powercfg /h off` was skipped, always leave Windows via **Restart**. A normal Shut down leaves C: flagged as hibernated, and Linux will then mount it read-only or refuse.

---

## Phase C — Mount + copy (native Ubuntu)

### C0. Check the native install first
```bash
id                         # must be shmuel, uid=1000, gid=1000. If not, stop and ask
lsb_release -a; uname -r
df -h /                    # need ~120 GB free for what follows
ls -la ~                   # see what's already there
```
If the native home already has dotfiles or data, copy them first to `~/native-pre-migration/` (`.bashrc`, `.profile`, `.ssh`, `.config`, `.gitconfig`). Don't overwrite anything without asking.

### C1. Mount read-only
```bash
lsblk -f                                       # C: = nvme0n1p3 (ntfs, "Windows-SSD")
sudo mkdir -p /mnt/win /mnt/wsl-old
sudo mount -t ntfs3 -o ro,uid=1000,gid=1000 /dev/nvme0n1p3 /mnt/win

# get the bundle + log onto native disk
mkdir -p ~/tmp && rsync -a /mnt/win/Users/shmuel/Downloads/ubuntu-migration/ ~/tmp/ubuntu-migration/

# WSL disk image
sudo apt install -y qemu-utils
sudo modprobe nbd max_part=8
sudo qemu-nbd --read-only -f vhdx -c /dev/nbd0 \
  /mnt/win/Users/shmuel/AppData/Local/Packages/CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc/LocalState/ext4.vhdx
sudo mount -o ro /dev/nbd0 /mnt/wsl-old || sudo mount -o ro,noload /dev/nbd0 /mnt/wsl-old
ls /mnt/wsl-old/home/shmuel                    # sanity check
```
- `ntfs3` refuses rw if Windows is hibernated. Never force it.
- Never mount `/mnt/wsl-old` rw. `ro,noload` skips replaying the journal and is safe.
- Don't click "Windows-SSD" in GNOME Files during this phase; that mounts it read-write.

### C2. Copy from WSL
WSL uid 1000 matches native uid 1000, so ownership carries over. Use `-aHAX`. Log each command and its exit code.
```bash
S=/mnt/wsl-old/home/shmuel
X="--exclude node_modules --exclude .venv --exclude venv --exclude target --exclude __pycache__ --exclude .next --exclude .turbo"

# code (all of it; deps are rebuilt in Phase D)
rsync -aHAX --info=progress2 $X $S/repos/ ~/repos/

# worktrees and work dirs outside ~/repos (keep identical paths)
rsync -aHAX $X $S/Documents/ ~/Documents/          # includes Documents/Codex/2026-09-29/spa/work/review-policy-drift worktree
rsync -aHAX $S/Downloads/ ~/Downloads/
rsync -aHAX $X $S/tmp/ ~/tmp/ --exclude '/supa-crm/' --exclude '/ubuntu-migration/'   # tmp/supa-crm = 50 GB generated runs: ask before copying
rsync -aHAX $S/{770-scene,garmin-analysis,gmail-insurance-2025,linear-cycles-report,linear-ticket-triage,scripts,supabase,bin} ~/
rsync -aHAX $S/*.pdf ~/Documents/pension-regulations/   # 13 Hebrew Altshuler Shaham PDFs from ~ root

# app data
rsync -aHAX $S/.local/share/{family-desk,arnona-bot,claude,rtk,keyrings} ~/.local/share/
rsync -aHAX $S/.local/bin/ ~/.local/bin/           # check for wrappers pointing at WSL paths in Phase D
rsync -aHAX $S/.automation/ ~/.automation/
rsync -aHAX $S/.family_photos/ ~/.family_photos/

# shell + tools config (WSL-isms get fixed in D4)
rsync -aHAX $S/{.gitconfig,.tmux.conf,.bashrc,.profile,.mybashrc,.mybashrc.sh,.bash_completion.d,.bash_history,.python_history} ~/
rsync -aHAX $S/.config/{shell,btop,gws,go,Cursor,Kiro,Codex} ~/.config/
rsync -aHAX $S/.ssh/ ~/.ssh/ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_* ~/.ssh/region-corteza ~/.ssh/google_compute_engine

# browser profiles used by automation (cookies need the keyrings copied above)
rsync -aHAX $S/.config/google-chrome* ~/.config/

# optional, ask: Android emulator image (1.8 GB)
# rsync -aHAX $S/.android/ ~/.android/
```

### C3. Copy agent state (Codex + Claude)
Stop Codex and Claude on native first, if they're installed and running.
```bash
# Codex: transcripts, index, sqlite state (with -wal/-shm), config, memories, artifacts
rsync -aHAX $S/.codex/ ~/.codex/ \
  --exclude packages/ --exclude cache/ --exclude tmp/ --exclude 'thread-writer-locks/' --exclude 'mcp-oauth-locks/' \
  --exclude ipc/ --exclude 'app-server-*' --exclude shell_snapshots/ --exclude auth.json

# Claude Code: transcripts (projects/), history, memory, settings, file-history
rsync -aHAX $S/.claude/ ~/.claude/ --exclude cache/ --exclude debug/ --exclude shell-snapshots/ --exclude session-env/
rsync -aHAX $S/.claude.json ~/

# Claude desktop app: Code-tab sessions, titles, worktree registry, scratch workspaces
rsync -aHAX $S/.config/Claude/{claude-code-sessions,git-worktrees.json,claude_desktop_config.json,config.json,scratch-workspaces} ~/.config/Claude/
```
- `~/.codex/skills`, `~/.claude/skills` and the instruction files are **symlinks** into `~/repos/skamensky/personal-agent-customizations`. They resolve once `~/repos` is in place; `setup-assistant` (Phase D) re-links them.
- `auth.json` is excluded on purpose: Shmuel re-authenticates.
- Retention: `~/.codex/sessions` is 7.4 GB. Apply Shmuel's generated-run retention policy only **after** Phase E confirms everything resumed.

### C4. Copy system identity (keeps the same tailnet IP + SSH host key)
The phone, the VM and `personal-agent-customizations/docs/remote-access.md` point at **100.86.106.55:2222**.
```bash
sudo systemctl stop tailscaled 2>/dev/null
sudo mkdir -p /var/lib/tailscale
sudo cp -a /mnt/wsl-old/var/lib/tailscale/tailscaled.state /var/lib/tailscale/
sudo cp -a /mnt/wsl-old/etc/ssh/ssh_host_* /etc/ssh/
sudo cp -a /mnt/wsl-old/home/shmuel/.ssh/authorized_keys ~/.ssh/ 2>/dev/null   # if not already copied with ~/.ssh
```
Copy only identities. Do **not** copy `sshd_config` or `sshd_config.d/`: the
Ansible `ssh` role (D2) owns the listener (`100.86.106.55:2222`, key-only) through
`/etc/ssh/sshd_config.d/00-spawnkit.conf` and refuses conflicting leftover
listeners. Record any non-default WSL sshd setting you find with
`diff /mnt/wsl-old/etc/ssh/sshd_config /etc/ssh/sshd_config` and add it to the role
instead of copying it.
Never run the WSL and native nodes at the same time with the same state. WSL is shut down, so this is fine. If Shmuel boots Windows and WSL later, `wsl --unregister` is **not** your call; flag the conflict instead.

### C5. Copy from Windows
```bash
W=/mnt/win/Users/shmuel
mkdir -p ~/windows-import
rsync -a --info=progress2 $W/Downloads/ ~/windows-import/Downloads/ --exclude /emergency-space-reserve-5GB.bin --exclude /ubuntu-migration/
rsync -a $W/{Documents,Desktop,Pictures,Videos,DataGripProjects} ~/windows-import/
rsync -a $W/*.{png,pdf,cs,ps1,html} ~/windows-import/home-root/
rsync -a $W/AppData/Roaming/Notepad++/backup/ ~/windows-import/notepadpp-unsaved/
rsync -a $W/AppData/Roaming/Mozilla/Firefox/Profiles/ ~/windows-import/firefox-profiles/
rsync -a $W/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json ~/windows-import/windows-terminal-settings.json
rsync -a $W/{.ssh,.aws,.gitconfig} ~/windows-import/dotfiles/            # diff against WSL copies; keep unique keys only
rsync -a $W/.codex/ ~/archive/windows-codex/ --exclude packages/ --exclude auth.json   # Windows Codex app history, read-only reference (cwds are C:\…)
rsync -a $W/.claude/ ~/archive/windows-claude/

# Ditto clipboard history → migrated to CopyQ in D6. Windows is off, so Ditto isn't running and the file is consistent.
mkdir -p ~/windows-import/ditto && rsync -a --info=progress2 $W/AppData/Roaming/Ditto/Ditto.db ~/windows-import/ditto/
sqlite3 "file:$HOME/windows-import/ditto/Ditto.db?mode=ro" "PRAGMA quick_check; SELECT count(*) FROM Main;"   # expect "ok" and ≈17.8k+
```
Skip: OneDrive and Music (empty), `scoop`, `tmp`, the Tor Browser folder on Desktop (reinstall it instead).

### C6. Verify the copy, then unmount
```bash
du -sh ~/repos ~/.codex ~/.claude ~/windows-import
diff <(cd /mnt/wsl-old/home/shmuel/repos && find . -name .git -prune -o -type f -print | grep -vE 'node_modules|\.venv|/target/|__pycache__' | sort) \
     <(cd ~/repos && find . -name .git -prune -o -type f -print | grep -vE 'node_modules|\.venv|/target/|__pycache__' | sort) | head
sudo umount /mnt/wsl-old && sudo qemu-nbd -d /dev/nbd0 && sudo umount /mnt/win
```
**Done when:** the diff is empty apart from the excludes, and the sizes are logged.

### Deliberately left behind (rebuildable)
`~/tmp/supa-crm` (50 GB, unless Shmuel says otherwise), `.cache`, `.npm`, `.nvm`, `.rustup`, `.cargo`, `.gradle`, `.bun`, `go/pkg`, `snap/`, `.vscode-server`, `.cursor-server`, `.antigravity-server`, `.insightface` (models re-download), `~/node_modules`, `root-env/`, `.codex/packages`, Docker images and volumes (71 of 74 volumes are dangling).

---

## Phase D — Set up (native)

### D1. Hardware checks
No manual driver or package installs here: the NVIDIA driver, PRIME on-demand
mode and Solaar (with its udev rules) come from the Ansible run in D2.
The laptop profile pins `nvidia-driver-580` (550 is retired and Ubuntu's 550
package now pulls in 580) and `desktop_session: wayland`. It pinned `x11` until
the 26.04 upgrade, whose GNOME 50 has no Xorg session; the setting now only
removes `WaylandEnable=false` from GDM. It takes effect at the next login.
```bash
mokutil --sb-state        # Secure Boot state decides whether D2 asks for MOK enrollment
lspci -nnk | grep -A3 -Ei 'vga|3d|audio'
```
- BIOS GPU mode: **Hybrid**, not dGPU-only (Shmuel).
- **LenovoLegionLinux** gives you power modes, fan curves and battery conservation (60 % cap), replacing Vantage/Legion Arena.
- Test suspend/resume, Wi-Fi 6E, the external monitor, the webcam and audio. Dolby has no Linux equivalent; EasyEffects is the closest.

### D2. Privileged Ubuntu host setup (first)

Home Manager owns the user environment. Implemented Ansible roles own Ubuntu
packages/services, NVIDIA drivers and Container Toolkit, Docker, Tailscale, SSH,
QEMU/libvirt/OVMF/swtpm, IOMMU and GPU hooks. Ubuntu's Docker/Tailscale packages
include their clients, so the native Home Manager profile omits duplicate copies.
Headless profiles explicitly opt into `personal.clients.gcloud` and client-only
`personal.clients.docker` when needed; a local daemon instead belongs in Ansible.

**First startup begins with an explicit Ansible run, before Home Manager.**
Install multi-user Nix with the upstream installer if it is absent, establish
GitHub SSH access with the migrated keys or Shmuel's login (never put keys or
credentials into the flake), and clone spawnkit only if it is missing. Then, from
the checkout:

```bash
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- inventory --host laptop-ubuntu
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- check --host laptop-ubuntu
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- plan --host laptop-ubuntu --ask-become-pass
nix --extra-experimental-features 'nix-command flakes' run .#host-config -- apply --host laptop-ubuntu --ask-become-pass
```

Read `ansible/README.md` for preview limits and `docs/architecture.md` for managed
paths. Selection uses `hosts/registry.json`; defaults and machine overrides live
in `hosts/<profile>/system.yml`. Reboot after driver/IOMMU changes, perform MOK
enrollment if prompted, and log in again for group membership. Ansible never
runs implicitly from Home Manager or on every boot. Successful host apply creates
root-owned `/etc/spawnkit/enabled`; absence means the machine is not enrolled.
This editing WSL environment remains unmarked. No manual sentinel creation.

First-time personal-machine setup also enables Tailscale SSH. Complete the
owner's tailnet login, then run `sudo tailscale set --ssh` or rerun host apply;
the Tailscale Ansible role enables it on authenticated hosts. Use a local console
or a verified LAN/IAP/alternate-port route when first enabling it because it
reroutes tailnet port 22 and can disconnect OpenSSH sessions. Verify a fresh
`tailscale ssh` command with automatic host verification. An additional browser
check is a separate tailnet-policy setting; enabling the server alone does not
remove it. Android, iOS/iPadOS and Windows need separate SSH servers.

Native automation is implemented and offline tested, but native apply/hardware
acceptance have not been performed. Initial laptop settings enable Docker,
Tailscale, key-only SSH on `100.86.106.55:2222`, NVIDIA with PRIME on-demand,
Solaar and the VM host stack, without GPU transfer. sshd may bind the tailnet
address before tailscaled assigns it at boot (`ip_nonlocal_bind`), so the listener
survives reboots; verify phone SSH after the first reboot. The role leaves Ubuntu's
`ssh.socket` activation before changing listeners and then checks that sshd
listens only on the declared addresses. Collect `host-config facts` after reboot, record real PCI
functions/IOMMU groups, then follow `docs/windows-vm.md` for GPU policy and explicit
VM provisioning. Do not use the synthetic test PCI addresses on this computer.

User daemons remain Home Manager `systemd.user` declarations. Ubuntu supplies the
system units; roles configure them. Libvirt sockets may activate on demand.
No custom GPU-transfer daemon runs at boot; IOMMU kernel prerequisites and the
shared-memory tmpfiles rule do not detach the RTX.

### D2a. Declarative user environment with Home Manager

The approved target is **Ubuntu + Nix/Home Manager**, with **mise owning development
Python/Node versions and uv owning Python environments/dependencies**. Do not replay
the old APT inventory or reinstall these tools through npm/pip/APT in parallel.

The infrastructure repository is `git@github.com:skamensky/spawnkit.git`, checked
out at `~/repos/skamensky/spawnkit`. It has one shared flake.lock, reusable modules,
WSL/native laptop profiles, an agent-VM profile and a minimal unknown-host default.
This guide is the complete migration reference. The repository README maps the
subsystems; `nix/README.md` contains Home Manager setup details.

1. Complete D2 first (Nix, the checkout and the host apply); reboot if it
   installed the driver or IOMMU settings.
2. Preserve the existing checkout and its local changes; the wrappers use the
   checkout containing the current directory.
3. From the checkout, inspect and build before activating:
   ```bash
   nix --extra-experimental-features 'nix-command flakes' run .#home-config -- select
   nix --extra-experimental-features 'nix-command flakes' run .#home-config -- check
   nix --extra-experimental-features 'nix-command flakes' run .#home-config -- build
   nix --extra-experimental-features 'nix-command flakes' run .#home-config -- repos --dry-run
   ```
   If the native machine has a different hostname, `--host laptop-ubuntu` selects
   that profile explicitly; unknown names otherwise receive the minimal default.
4. Before `switch`, compare and preserve old `.bashrc`, `.profile`, `.gitconfig`,
   tmux configuration and assistant links. Existing unmanaged files are a deliberate
   activation stop, not a reason to force an overwrite. Login shells put the Home
   Manager profile first and the mise shims before `~/.local/bin`, so migrated
   copies of node, python, uv, claude, codex or rtk do not shadow managed tools
   (the isolated activation test plants such copies). Delete those stale copies
   once the managed versions work; anything else in `~/.local/bin` still
   overrides `/usr/bin` as on stock Ubuntu.
   A fresh Ubuntu user has the stock `/etc/skel` `.bashrc` and `.profile`; the
   first switch stops on them too. Compare them with `/etc/skel` and move them
   aside (for example `*.pre-spawnkit`) only when they are unmodified copies.
5. Activate with the same wrapper and `-- switch` only after these migration
   conflicts have been resolved with Shmuel. Activation clones missing declared
   repositories at pinned commits, installs assistant symlinks and the locked mise
   runtimes. It never resets or pulls existing repositories. Cloning needs this
   user's GitHub SSH access from D2 (GitHub's host keys are pinned, so no prompt
   appears); without it every missing repository is reported in one error, the
   existing checkouts are kept, and the switch can simply be rerun.
6. Log out/in so GUI processes inherit the managed session environment.

APT remains responsible for Ubuntu drivers, system daemons and native build
libraries. For example, Docker Engine, NVIDIA Container Toolkit, Tailscale/SSH
services and libvirt are host setup; Home Manager's client packages do not install
or configure those services. The native build toolchain (`build-essential`,
`pkg-config`, common `-dev` libraries; cmake/ninja on the laptop) is in the host
profile's `base_packages`/`host_packages`, so source builds link against Ubuntu's
glibc. Add other project-specific `-dev` libraries there too. Add user packages through the appropriate
Home Manager module, build/check the flake, then commit and push.

### D3. Graphics, assistants and language tools

- The native laptop profile declares Firefox, Chrome on x86_64, VS Code, CopyQ,
  ONLYOFFICE 10 on x86_64 (the default for Word, Excel, PowerPoint, OpenDocument, RTF
  and CSV files; PDFs stay in Chrome. It bundles its own Qt and runs through XWayland.
  It reads fonts only from its sandbox, not fontconfig, so it gets copies of the profile's
  document fonts (about 0.9 GB); otherwise Hebrew draws as empty boxes. It comes from the
  flake's `nixpkgs-unstable` input until `nixos-unstable` reaches 10.0),
  xclip (wl-clipboard when `personal.desktop.session` is wayland) and a CopyQ user service (Solaar is an Ubuntu package because it
  needs system udev rules). It uses Home Manager's
  `/run/opengl-driver` integration, so individual GUI packages do not need nixGL
  wrappers. Follow the activation warning's exact sudo setup command.
- On native Ubuntu, determine the running NVIDIA driver version and the matching
  upstream installer hash. Declare them through `personal.desktop.nvidia` in the
  native host module, `hosts/laptop-ubuntu/home.nix`. **Never infer those values from WSL or the Windows driver.**
  The initial profile supports Intel/Mesa; NVIDIA offloading needs this hardware
  configuration and native verification.
- Nix installs mise and uv; mise installs the declared Python and Node versions
  from the tracked runtime lockfile. Do not install nvm or a second development
  Python owner. Verify `python --version`, `node --version` and `uv run` from both
  a terminal and a noninteractive agent.
- `AGENTS.md`, assistant settings and per-skill symlinks point to the canonical
  personal-agent-customizations checkout. The **setup-assistant skill now uses
  Home Manager** and discovers skill directories from the canonical assistant
  checkout; no duplicate skills manifest is maintained here. Do not run the old imperative symlink helper over managed links.
- Existing worktrees, unpushed commits and repositories without remotes still come
  from Phase C. Bootstrap only fills missing repositories; it is not a backup.
- Shmuel authenticates Claude/Codex, gh, gcloud and Tailscale as required. Credentials
  and browser/agent state remain separate from Nix configuration.
- Restore editor extensions as needed, and rebuild project dependencies using
  their existing language package managers and lockfiles. A Nix tools shell can
  coexist with mise, but do not inject Nix glibc/shared libraries into mise Python
  or assume native extension compatibility. Use the tested toolchain boundary in
  `docs/workflows.md` section 9; Google automation has its own scoped Go/CGO flake.

Windows GPU passthrough is a separate native feasibility task (KVM/libvirt/VFIO).
Keep Ubuntu's desktop on Intel. The RTX is exclusive to either Linux workloads
or the running Windows guest; Looking Glass displays Windows inside the Intel
Linux desktop using shared memory. It does not share GPU ownership.

Use Ubuntu's QEMU/libvirt backend with a Windows VM definition tracked as a
repository template. Home Manager provides virt-manager, the Looking Glass
client and a launcher. Libvirt pre-start/cleanup hooks perform GPU handoff only
when starting/stopping Windows. Before detaching, reject startup if any Linux
application, service or container holds the GPU. Do not kill work automatically;
detaching a busy GPU can hang. Hooks must not call back into libvirt.

Do not bind the RTX to VFIO as part of ordinary Home Manager activation. Verify
native IOMMU groups, related PCI functions, display routing, Windows applications,
and repeated GPU return to Linux first. Keep VM disks, virtual TPM state and UEFI
variables outside Git/Nix, with consistent backups. Preserve dual boot until the
required applications and peripherals work. The detailed design and source links
are in `docs/windows-vm.md`; native acceptance remains unverified until those checks succeed.

### D4. Review old shell configuration before Home Manager adoption

The Home Manager modules implement the target shell and tmux settings. Use this
table to audit old files and migration conflicts; make persistent changes in
`spawnkit`, rather than editing the generated home files.
| File | Now | Change to |
|---|---|---|
| `~/.tmux.conf` | `copy-pipe-and-cancel "clip.exe"` | `"wl-copy"` on the laptop (Wayland), `"xclip -selection clipboard"` on an X11 profile |
| `~/.bashrc` ~L148–155 | `alias powershell='powershell.exe'`; ChatGPT launcher with `WAYLAND_DISPLAY=/mnt/wslg/...` | delete |
| `~/.mybashrc` | Claude desktop launcher with `/mnt/wslg` | delete |
| `~/.mybashrc.sh` | `alias wslpath=...`; commented `/mnt/c` PATH/WINHOME lines | delete |
| `~/.mybashrc.sh` | plaintext `export` secrets | should already be gone (A2); verify |
| `~/bin/clipimg` | PowerShell clipboard-image grab | rewrite with `wl-paste --type image/png` (Wayland) or `xclip -selection clipboard -t image/png -o` (X11) |
| `/etc/wsl.conf` | — | not needed on native |
| `~/.ssh/config` | `thinkpad` 10.100.102.7, `phone` over tailnet, `corteza`, `myserver` via cloudflared | keep; test each |
| anything | other references to `/mnt/c`, `.exe`, `wslg` | `grep -rnE '/mnt/c|\.exe\b|wslg' ~/.bashrc ~/.mybashrc* ~/.profile ~/.config/shell ~/bin ~/.local/bin` and fix them |

### D5. Windows apps → Linux equivalents
✅ native build · 🔁 replacement · 🌐 web · ❌ drop. Install the ✅/🔁 ones Shmuel wants; ask, don't assume.

| Windows app | On Ubuntu |
|---|---|
| Chrome, Brave, Firefox, Edge | ✅ |
| VS Code, Cursor, Kiro, Antigravity | ✅ .deb / AppImage |
| JetBrains Toolbox → IntelliJ Ultimate, DataGrip | ✅ (Settings Sync) |
| WezTerm / Windows Terminal | ✅ WezTerm, or Ghostty / GNOME Console |
| Claude desktop, ChatGPT desktop | ✅ (apt repos already in inventory) |
| Codex app | Codex CLI ✅; also check whether a Linux desktop build exists now |
| Docker | ✅ docker-ce |
| WhatsApp Desktop | 🌐 web.whatsapp.com PWA (+ `wacli` on the VM) |
| Element, Zoom, Webex, TeamViewer, Dropbox, ExpressVPN | ✅ |
| Citrix Workspace (+ VDI plugins) | ✅ Linux .deb. **Test early**, since it's needed for work |
| Windows 365 | 🌐 windows365.microsoft.com |
| Microsoft 365, OneNote | 🌐; LibreOffice ✅ |
| Adobe Acrobat | 🔁 Okular / Xournal++ |
| Notepad++ | 🔁 VS Code / Kate |
| Everything | 🔁 FSearch |
| WizTree | 🔁 ncdu / Baobab / QDirStat |
| Ditto | 🔁 **CopyQ, with full history migrated (D6)** |
| AutoHotkey (`mine.ahk` = 2004Scape mining macro) | 🔁 xdotool/ydotool; only if Shmuel wants it |
| Wispr Flow | ❓ likely no Linux client → whisper-based dictation (nerd-dictation, Speech Note) |
| Logi Options+ | 🔁 Solaar |
| OBS | ✅ Home Manager `programs.obs-studio`; finish the PPA removal (below) |
| Shotcut, Krita, VLC, qBittorrent, LibreOffice, Wireshark, balenaEtcher, 7-Zip (p7zip) | ✅ |
| K-Lite | 🔁 `ubuntu-restricted-extras` |
| Tor Browser | ✅ `torbrowser-launcher` |
| Visual Studio 2022, Windows SDK, MSYS2, scoop, gsudo, .NET/VC++ runtimes | ❌ (`dotnet-sdk` only if needed) |
| NVIDIA App, Dolby, Intel XTU, Lenovo Vantage/Now/AvatarMaster, Legion Arena, Nahimic, Copilot, Npcap, USBPcap, WinFsp, TMOG | ❌ |
| `dd.accdb` | 🔁 `mdbtools` / LibreOffice Base, or the CSV export from A5 |

**OBS in Spawnkit (2026-11-04).** OBS 32.2.2 now comes from Home Manager's
`programs.obs-studio` in `desktop.nix`; scenes and settings in
`~/.config/obs-studio` are untouched. It encodes through `/run/opengl-driver`:
its log shows FFmpeg VAAPI H.264/HEVC and QuickSync on the Intel iGPU. Remaining:

- [x] NVENC with the Windows VM shut down: `obs-nvenc-test` reports NVENC 13.0 on the
  Ada RTX (2026-11-04). nixpkgs leaves the driver path off that probe, so
  `desktop.nix` adds it, and OBS builds from source. While the VM runs, the RTX is
  on `vfio-pci` and OBS logs `NVENC not supported`.
- [ ] After `do-release-upgrade`: `sudo apt purge obs-studio` and delete the
  obsproject PPA source, so only the Nix OBS remains (the app menu shows both
  until then) and the next upgrade has no foreign package.
- [ ] The scene's "Audio Capture Device (ALSA)" source fails to open `default`
  under Nix's ALSA, which cannot load Ubuntu's PipeWire ALSA plugin. Desktop
  Audio and Mic/Aux (PulseAudio capture) work; drop the ALSA source unless it
  captures something they do not.
- [ ] Virtual camera: add `v4l2loopback-dkms` through Ansible only if wanted.

### D6. Migrate Ditto clipboard history → CopyQ
Ditto (Windows) holds **17,820 clips from 2025-01-20 to 2026-10-15**: 16.9k text (958 with Hebrew), 9k with HTML, 39 RTF, 96 copied-file lists, and **783 images stored as raw bitmaps (3.4 GB of the 3.9 GB DB)**. There are no Ditto groups, pinned clips or shortcuts, so it's a flat history.

The converter is `scripts/ditto_to_copyq.py`, **tested 2026-10-15 end-to-end** on a snapshot of the real DB against CopyQ 7.1 in an isolated session. All 17,819 non-empty clips imported, and the per-tab counts were verified.
```bash
copyq version                                    # installed by Home Manager; verify it is on PATH
systemctl --user status copyq.service             # managed by the native desktop profile; avoid duplicate autostart
uv run --script ~/tmp/ubuntu-migration/scripts/ditto_to_copyq.py export \
  --db ~/windows-import/ditto/Ditto.db --out ~/windows-import/ditto/export      # ~80 s; 3.9 GB → ~560 MB
copyq source ~/windows-import/ditto/export/import-into-copyq.js               # ~45 s; prints "verified per tab"
```
What it does:
- **Mapping:** UTF-16 text → `text/plain`; CF_HTML → `text/html`; RTF → `text/rtf`; bitmap → `image/png`; copied files → the list of their original Windows paths as text. Each item also carries `application/x-ditto-meta` `{id, date}`.
- **Tabs:** CopyQ caps a tab at **10,000 items**, so a single "Ditto" tab silently drops about 7k clips (found during testing). The script splits text into half-year tabs `Ditto/2025-H1` (5,100), `Ditto/2025-H2` (7,506), `Ditto/2026-H1` (2,689) and `Ditto/2026-H2` (1,752), plus `Ditto/images` (772). Newest clips are on top. It falls back to quarter or month tabs automatically if a period grows past 9,000.
- **`maxitems` is global:** the import raises it to the largest tab (~7.5k), which means the live clipboard tab also keeps that much history. **Don't lower it later**, or CopyQ trims the imported tabs. Tell Shmuel about this trade-off.
- **Memory:** CopyQ loads tabs into memory. Expect about 465 MB of tab files, most of it `Ditto/images` (292 MB). If that's too heavy, Shmuel can delete `Ditto/images` in CopyQ and keep the PNGs in `export/clips/` instead.
- **Re-runnable:** it replaces any existing `Ditto*` tabs. Ditto keeps growing until Windows is retired, so re-copy `Ditto.db` and re-run both commands to pick up newer clips.
- **Privacy:** clipboard history likely contains passwords and tokens. Keep `Ditto.db` and `export/` out of git, gists and chat. Once Shmuel confirms CopyQ has everything, ask whether to delete `~/windows-import/ditto/` (keep the original on C: until Phase F).

---

### D7. IN PROGRESS: KDE Plasma 6 trial (after the 26.04 upgrade)

Decided 2026-11-04. GNOME looks wrong to Shmuel; he wants a modern, sleek, fast
desktop with one taskbar at the bottom and nothing at the top, good fractional
scaling (the panel is 2560x1600 at 13.5", about 190 DPI), normal floating windows
(no keyboard-driven tiling) and room to try themes. Defaults matter less than
themeability; config may be harder than dconf as long as it can be declared.
KDE Plasma 6 on **Wayland** fits; X11 was ruled out because fractional scaling
there is a workaround on every desktop. Plasma 5.27 (all that 24.04 ships) was
rejected in favor of upgrading Ubuntu: 26.04 (`resolute`) ships Plasma 6.6.6.
GNOME stays installed, so the session is chosen at login and the trial is reversible.

- **Packages (done 2026-11-04):** `plasma: true` in the laptop profile installs
  `kde-plasma-desktop`, `kde-spectacle` and `qt-style-kvantum` without Recommends,
  which would pull in SDDM and take over from GDM. The recommended parts a working
  desktop needs are listed explicitly (added 2026-11-04, after the brightness keys did
  nothing): PowerDevil, volume, network, KScreen, Bluetooth, System Settings, the KDE
  portal, KIO extras and the GTK style module. `kubuntu-desktop` is avoided for
  the same reason and for its whole Kubuntu app set. GDM stays the display manager.
- **Session (default since 2026-11-04):** the laptop already runs `desktop_session: wayland` (GNOME 50 has
  no Xorg session), so Plasma's Wayland session appears in GDM as soon as it is
  installed. `default_session: plasma` makes it the session GDM preselects (and
  autologin starts) through AccountsService; GNOME stays one click away under the
  gear after choosing the user. Set live with `busctl`; the next `host-config apply`
  enforces it.
- **GPU handoff:** measured 2026-11-04 with the NVIDIA driver bound: the RTX has
  its own connectors (`card2`: DP-3, DP-4, HDMI-A-5, eDP-2), so some external
  port may be wired to it. Restricting KWin with `KWIN_DRM_DEVICES` would leave
  such a port dark, so Plasma is not restricted. Like GNOME on Wayland (where
  `gnome-shell` and `Xwayland` hold the RTX), it releases the RTX through the
  launcher's logout handoff: the RTX leaves the desktop seat and Windows starts
  once you log out. Revisit `KWIN_DRM_DEVICES` only if no external port uses the RTX.
- **Screenshots:** Spectacle on Print in Plasma, with the same
  workflow: drag a region, nothing happens until Enter, then copy to the clipboard
  and close; no save dialog. GNOME keeps its own screenshot UI on Print.
- **Declarative config (done 2026-11-04):** the `plasma-manager` flake input and
  `nix/modules/home/plasma.nix` (`personal.desktop.plasma`) declare the Spectacle
  shortcut and settings and install the theme candidates. A user copy of Claude's
  launcher without its desktop actions keeps search to one Claude result (Claude
  rewrites only an entry that carries its `X-Claude-Generated` marker);
  set the display scale (start at 150%) in System Settings → Display, since KWin
  keeps it per output. `overrideConfig` stays off during the trial so changes
  made in System Settings survive activation. Pin the final panel, scale and
  theme in `plasma.nix` afterwards.
- **Pinned look and panel (done 2026-11-04):** `plasma.nix` declares Layan's
  colours, Plasma style and window decoration with a `LayanGlass` Kvantum theme
  (Layan Dark with 15% see-through windows and 10% menus, blurred by KWin), the
  Layan wallpaper, Fluent-dark icons and the Fluent (Windows 11) cursors packaged
  from the Fluent icon theme's source. Inactive windows show at 92% opacity. One
  translucent bottom panel holds the launcher, the task manager (file manager,
  browser, WhatsApp and the Windows launcher pinned) and, on the right, only three widgets:
  `tech.shmuel.battery` (visible only while on battery), `tech.shmuel.language`
  (the current layout, hidden with one; a click switches between two, opens a menu
  with three or more, and the wheel steps through them; Meta+Space also switches),
  `tech.shmuel.stats` (a live gauge whose hand follows CPU use and whose colour runs
  green through orange to red, opening on click a Spawnkit-styled card of
  processor, integrated and discrete graphics, memory, swap and root-disk use with
  temperatures. Numbers and bars ease to each reading over the roughly one-second
  poll, and the processor row unfolds into a map of physical cores (performance and
  efficiency cores apart, a bar per hardware thread) whose cores name their threads'
  load and clock when pointed at. Pointing at the integrated graphics row offers a
  hide button, persisted in the widget's `hideIntegratedGpu` setting, with a Show
  link to bring it back. It polls the `spawnkit-stats` JSON CLI (which also
  reports each thread under `cpu.threads`) only while open, since
  ksystemstats reports 0% for the Intel iGPU and would wake the sleeping RTX; while
  closed, the gauge polls `spawnkit-stats load`, which reads only `/proc/stat`.
  The card ends with up to five processes using at least 1% CPU (`spawnkit-stats --top N`), each
  with an End button on hover, and an All processes link that opens a process
  window, named Task Manager in the task bar by a KWin `desktopfile` rule since it
  otherwise shares plasmashell's identity: apps grouped by their systemd unit (`app-<desktop id>` scopes take the
  desktop entry's name and icon, QEMU guests become "Virtual machine NAME", services
  and sessions keep their unit name), sortable by name, CPU, memory, PID or user (root first),
  searchable by name or command, or flattened to All processes. CPU shows whole
  percents with a decimal only under 1%; the Granular toggle, persisted in
  `granularProcesses`, puts a decimal on every figure. Rows re-rank at
  most every 2 seconds and hold still while pointed at. End sends SIGTERM to the
  process or the whole group and waits 3 seconds; if anything survives the button
  becomes Force kill (SIGKILL). Processes the desktop session needs (plasmashell,
  kwin, systemd, dbus and similar) ask for End anyway first, and other users'
  processes show a lock and report permission denied. Right-clicking a row in the
  window or the card's list copies `spawnkit-stats details --text` for it, or for
  every process in a group, opening with `--view` and `--row` context (the machine,
  time, view and row) so an agent reading the paste knows where it came from. Both views are thin layers
  over `spawnkit-stats processes [--sort cpu|memory|name|user] [--flat]` and
  `spawnkit-stats signal --term|--kill [--wait S] PID:START...`, which signals
  through a pidfd after checking the start time, so a reused PID is never hit, and
  exits nonzero unless every target exited;
  2026-11-05: renders live data, core map, hidden integrated graphics, busiest
  processes and the process window under `plasmawindowed`; the signal CLI ended a
  test process and refused PID 1), `tech.shmuel.clock` and
  notifications. Both small widgets use Plasma's full
  representation: without one the panel never shows them. A running KWin keeps the
  old layout list when Home Manager rewrites `kxkbrc`; a relogin or
  `kwriteconfig6 --notify` on that file loads the new one. No XKB toggle option is
  set, since GNOME's `grp:win_space_toggle` would make Meta+Space switch twice. There is no system tray, so applications'
  tray icons (CopyQ, Claude) do not appear; volume and network have no indicator.
  Ctrl+` toggles CopyQ through a plasma-manager command (GNOME binds it in
  `desktop.nix`). KWin matches the typed symbol, and the Hebrew layout types `;` on
  that key, so Ctrl+; is bound too (2026-11-05: injected keypresses toggle CopyQ on
  both layouts). A new global shortcut needs a relogin, or a live kglobalaccel
  `setShortcut` call with flags 6. The Start button's icon, `spawnkit-start`, is a
  penguin on a rounded Layan-coloured tile, since Fluent's Windows logo read as
  another window button. CopyQ runs as a native Wayland client under Plasma (KWin
  offers data control); the GNOME session's XWayland workaround missed Wayland copies
  such as Spectacle screenshots (2026-11-05: an image copied with `wl-copy` reached
  CopyQ). KWallet is disabled and `kde-portals.conf` routes the Secret portal to
  GNOME Keyring, which GDM unlocks at login. Before that, each Chrome secret request
  opened a KDE Wallet prompt, and a new Chrome profile hung on a blank page.
  Widgets are locked (`immutability=2` with `plasma/allow_configure_when_locked`
  off), so a task's right-click menu has no configure entries. The panel's task
  manager is `tech.shmuel.taskmanager`, a fork of Plasma's icon-only task manager
  whose right-click menu offers only Pin/Unpin and Close, plus the launcher's desktop
  actions that its `spawnkit-badges` tag lists for the current state (the Windows
  launcher's power actions; see `docs/windows-vm.md`). Its window tooltips ignore a
  media player with no track, which upstream counts as matching every title (Chrome's
  idle player hid all its titles and previews), and name each Chrome window's profile
  through `spawnkit-badges chrome-profile TITLE`. Chrome exposes the profile nowhere in
  a window, so that command looks for the title among each open profile's saved tabs
  and prints nothing if no single profile has it. A group's tooltips drop the app
  name and keep the title and subtext to one line each, so previews align without
  reserved blank lines. Its QML is compiled into
  a C++ plugin, so the `plasma_taskmanager` host role (Plasma hosts only) downloads
  the matching plasma-desktop tarball (sha256-pinned), builds the applet with
  `taskmanager.patch` against Ubuntu's -dev packages under
  `/var/cache/spawnkit/plasma-taskmanager`, and installs it into Qt's plugin
  directory. The role asserts the installed plasma-desktop version; after an Ubuntu
  Plasma upgrade, update `plasma_desktop_version` and its sha256 in the role's
  defaults, refresh the patch and rerun `host-config apply` (2026-11-05: built and
  installed for 6.6.6; the panel loads it with no QML errors).
  WhatsApp is pinned to the panel. Its launcher opens web.whatsapp.com in a
  dedicated Chrome profile (`~/.local/share/spawnkit/whatsapp-chrome`, logged in
  once by QR code) with DevTools on 127.0.0.1:9333. The `spawnkit-badges` user
  service reads the unread count from the page and publishes it through the Unity
  launcher API, and the task manager draws that count on the icon's corner.
  `spawnkit-badges set APP N` and `list` drive it by hand (2026-11-05: a set count
  showed on the WhatsApp icon).
  The fork also draws a pill under a launcher's icon from the service's `Tags`
  D-Bus property (`spawnkit-badges tags` prints it as JSON). While the Windows VM
  runs (`virsh domstate` of `windows_name` in `/etc/spawnkit/windows.json`), its
  pinned icon reads a green "RTX" when the first `gpu_devices` address is bound to
  vfio-pci and a grey "no RTX" otherwise; with the VM off there is no pill
  (2026-11-05: both pills rendered from injected tags, and a shut-off VM gave no
  tag; not yet observed through a real VM start). While Windows boots or shuts down
  the pill turns amber and pulses ("starting"/"stopping"), an amber arc circles the
  icon (clockwise starting, the other way stopping) and the icon is grey, fading back
  to colour once Windows runs. `host-config vm-start`/`vm-view` and `vm-stop` publish
  their phase in `$XDG_RUNTIME_DIR/spawnkit/windows-phase.json` (with their pid, so a
  killed run leaves no stale phase); after that the service polls every second:
  a running domain whose QEMU guest agent has not yet answered is starting, one
  whose agent went quiet (a shutdown from inside Windows) is stopping, and a shut-off
  domain still holding `/run/spawnkit/gpu-owner.json` is stopping until the RTX is
  back. The arc needs Ubuntu's `qml6-module-qtquick-shapes` and `-effects`, which
  the role installs (2026-11-05: the pill, arc directions and pulse rendered from the
  patched QML offscreen with `qmltestrunner`; the live RTX tag read "RTX"; the
  transitions are not yet observed through a real VM start/stop).
  KDE Connect (the `kdeconnect` package in the base role's Plasma list) stands in for
  Windows' Phone Link: install the KDE Connect Android app, keep the phone on the same
  network or tailnet, and pair from the panel's `org.kde.kdeconnect` widget (hidden
  until a phone connects) or `kdeconnect-cli --pair -d ID`. Texts go through the
  KDE Connect SMS app, the widget or `kdeconnect-cli --send-sms TEXT --destination
  NUMBER -d ID`. `kdeconnect-cli --share tel:NUMBER -d ID` opens the phone's dialer
  with the number; the call itself, and its audio, stay on the phone, and the laptop
  shows call notifications and pauses media (2026-11-05: an SMS to Shmuel's own number
  and the dialer both verified on the Redmi Note 12 Pro+, after granting the app's
  SMS and phone permissions).
  The phone's app notifications never pop up and stay out of Plasma's history:
  `kdeconnect.notifyrc` gives its `Event/notification` no action, and the KDE
  Connect widget lists the phone's current notifications for a look when wanted.
  Calls, pairing requests and low battery still pop up. Plasma's "N notifications
  were received while Do Not Disturb was active" summary is off
  (`libnotificationmanager.notifyrc`, `Event/inhibitionSummary`).
  Running daemons cache these settings, so every activation sends KNotifications'
  `/Config org.kde.knotification.reparseConfiguration` signal for each component
  (2026-11-05: kdeconnectd kept popping phone notifications until it reread them).
  The launcher, `tech.shmuel.kickoff`, is Plasma 6.6.6's Kickoff reduced to the
  search field, a list of recently used applications and files shown until you
  type, and one Power menu holding every session and power action; it has no
  favourites, application tree, places or header buttons (2026-11-05: the open menu
  showed recent apps and folders, and Power). It is pinned to Ubuntu's Plasma
  version, so rebuild it from the new tarball after a Plasma upgrade. Applications
  are found by `spawnkit-search`, a user service that KRunner and the menu query
  over D-Bus (runner `tech.shmuel.apps`); `krunnerrc` turns off Plasma's own
  application runner and its Software Center results, and lists the new one as the favourite, so applications lead
  every result list. It scores an app by how the query matches its name (whole name,
  prefix, word prefix, initials, letters from a word start, substring, then
  keywords and command), prefers shorter names on ties, and learns: apps launched
  after typing a query, or one it extends or shortens, rank higher, and frequent
  recent launches a little. Launches go through `kstart` and are recorded with the
  activity manager, which keeps the recent list current. `spawnkit-search query
  TEXT` prints the ranking as JSON, `launch` and `history` the rest; learning lives
  in `~/.local/state/spawnkit/search.json`. Right-clicking an application, file or
  folder in the menu offers Properties, and an application also Executable
  Properties, the real file its `Exec` line runs; `spawnkit-search properties
  [--executable] TARGET` is the same action, opening the file manager's dialog.
  Baloo indexes file names only, so search finds files; it ships disabled here, and
  a first login after enabling it indexes the home folder in the background. Beyond
  Baloo's own filters (hidden folders, `.git`, `node_modules`, virtualenvs), it skips
  generated data, caches and third-party trees: `~/native-pre-migration`, `~/go/pkg`,
  vcpkg, family-desk's generated `records` (its `library` stays), image-training's
  review output, region-corteza's `tmp`, the Windows clipboard export and Firefox
  profiles, plus any `*.worktrees`, `build`, `tmp_claude` or `playwright-report`
  folder. (2026-11-08: these were 350,000 of 447,000 indexed files.) Setting the
  filters replaces Baloo's default list, so the module repeats it. Files indexed
  before an exclusion stay listed until `balooctl6 purge` rebuilds the index. Nix Qt 6 apps (CopyQ, OBS, Ladybird) are
  wrapped by `plasma-qt.nix` with Plasma's platform theme, Kvantum and Breeze, since
  Nix Qt loads only its own plugins and would otherwise draw with Fusion and default
  fonts; apps bundling their own Qt (Zoom) stay unwrapped. The `desktop-integration`
  flake check (`scripts/desktop-check.py PROFILE [--json]`) fails when a launcher's
  Nix app lacks that wrapper, a GTK app lacks dconf's GIO module, or a launcher's
  `/nix/store` program is missing. It checks the built profile offline; whether an
  app actually looks right is still a native check.
  Applications' jump-list actions (such as
  New Window) are no longer offered in search. (2026-11-05: KRunner listed System
  Settings first for "settings", WhatsApp first for "wa", and a launch through the
  runner started Dolphin in its own app unit and recorded the pick.) Title bars show Windows' minimize, maximize and close on the right. Icons
  are Fluent-dark without its application set (`Fluent-dark-real-apps`), so apps such
  as Chrome keep their own icons. Windows are 30% and menus 15% see-through, Dolphin
  included; Ubuntu's Kvantum reads themes only from `~/.config/Kvantum`, so the
  profile links its Kvantum themes there. The touchpad scrolls naturally; mice keep wheel scrolling. The clock's popup is a month view with event dots and the selected
  day's Google Calendar events (click opens the event, a camera button joins its
  Meet). `spawnkit-calendar sync` copies the calendars Google Calendar shows,
  from a month back to three months ahead, through the personal-secrets Google
  wrapper into `~/.local/share/spawnkit/calendar/events.json`; a user timer runs
  it every 15 minutes, and `events --from --to` and `status` print JSON from that
  copy, which the clock reads. KZones adds Windows-style snap layouts while
  dragging a window to the top; Meta+Up maximizes, Meta+Down minimizes and
  Meta+Left/Right keep KWin's half tiling. `spawnkitsnapassist`, a KWin script, is
  Windows' Snap Assist: once a window fills half the screen, the other windows on
  that screen show as thumbnails over the free half; clicking one snaps it there,
  Escape or a click outside dismisses them. Dolphin is forked as well: the `dolphin`
  host role builds Ubuntu's version (25.12.3, sha256-pinned, failing when Ubuntu's
  package moves) with `dolphin.patch` into `/opt/spawnkit/dolphin`, links
  `/usr/local/bin/dolphin` and points the `plasma-dolphin` daemon and the
  FileManager1 D-Bus service at it. The patch removes Open With on folders, Paste
  on items, and every service-menu and plugin entry (other apps cannot add to the
  context menu); `dolphinrc [ContextMenu]` hides the rest, leaving Open in New Tab,
  Open With (files), Rename, Create New, Cut, Copy, Copy Location, Move to Trash,
  Open Terminal Here and Properties. The patch also widens the Places panel to fit
  its longest name, up to a third of the window; dragging it wider still works.
  `spawnkit-places list` prints Places as JSON and `hide [--section S] [URL]` hides
  entries; activation hides Desktop, Music and the Recent section (Recent Files,
  Recent Locations, Modified Today and Yesterday). An already open Dolphin keeps the
  old build until it is closed (2026-11-05: built and installed; not yet viewed).
  CopyQ keeps a copied image after its app exits: Spectacle quits right after
  copying, and without Klipper the Wayland clipboard would empty, so a CopyQ script
  command (installed by the service's start step with `copyq source`) copies an
  image/png it sees back so CopyQ owns it (2026-11-05: after Spectacle exited,
  `wl-paste -l` still offered image/png, with no duplicate history item).
  Spectacle shows no notifications (its
  `spectacle.notifyrc` groups are `Event/<name>`, so the slash is escaped in Nix), and
  cancelling the Windows VM's RTX handoff ends quietly. The screen never locks on idle or on
  waking from sleep, in Plasma and GNOME, and PowerDevil never suspends on idle. plasma-manager's layout scripts call
  `qdbus`, so the profile provides one that runs Ubuntu's `qdbus6`; the panel
  script runs again at the next login only when the declared panel changes.
- **Theme trial:** a Plasma theme applies to the whole session; it cannot differ
  per virtual desktop. `spawnkit-plasma-theme` (`list --json`, `current`, `apply
  <id>`, `revert`) switches the live desktop between 20 of the most downloaded
  Plasma 6 global themes, keeping the panel layout. `apply <id> --layout` also
  loads the theme's own panels, adds the floating bottom dock its screenshots show
  (their layouts ship only the top bar), pins the Windows launchers and sets its
  wallpaper; `revert` restores the saved panels. `gallery` (the "Theme Gallery"
  launcher) is a local page with each theme's preview and an Apply button over the
  same commands. Layan, Colloid, Orchis and Graphite are built from vinceliuice's
  repositories, because nixpkgs dropped them with Plasma 5. Sweet, Nordic, Arc and
  Materia ship only Plasma 5's `metadata.desktop`, so the build adds the
  `metadata.json` Plasma 6 requires. Their Kvantum themes use Ubuntu's Kvantum;
  a Nix Qt plugin would not load into Ubuntu's Qt. Already open Qt apps restyle
  when restarted. Pin the winner in `plasma.nix`.
- **Verify on Wayland:** fractional scaling is sharp in Chrome, VS Code and
  Electron apps; CopyQ still records history (Klipper is the fallback); Looking
  Glass captures and releases input; Citrix and Webex run under XWayland; the
  Windows VM still takes the RTX; Hebrew/English switching still works.

## Phase E — Resume + verify (native)

### E1. Resume in-flight agent work
1. `python3 ~/tmp/ubuntu-migration/scripts/in_flight_agent_work.py --days 14`. The output should match `inventory/in-flight-agent-work.md`, which proves the transcripts arrived intact.
2. Fix worktrees: run `git worktree list` and `git worktree repair` in `~/repos/SkylineCapital/supa-crm` and `~/repos/skamensky/family-desk`. Expected worktrees outside `~/repos/<owner>/<repo>`:
   - `~/Documents/Codex/2026-09-29/spa/work/review-policy-drift` (`codex/review-policy-drift`)
   - `~/repos/SkylineCapital/supa-crm.worktrees/supabase-log-access`
   - `~/repos/SkylineCapital/supa-crm/.worktrees/{fix-gmail-message-ambiguity,fix-gmail-sync-catchup,fix-picklist-constraint-identity,supa-crm-declarative-schema-poc}`
   - `~/repos/SkylineCapital/supa-crm-{docusign-intake-recovery,docusign-release-dev,docusign-release-master,lead-preprocessing}`
   - `~/tmp/family-desk/publish-core` (already marked prunable; ask before pruning)
3. Open Codex and confirm that **supa-gcp-alerts**, **declarative-schemas** and **lead import** are listed. Reopen each one, read its checkpoint note, and continue only with Shmuel's go-ahead.
4. Claude: `claude --resume` from each project cwd lists the old transcripts. The Claude desktop app shows its old Code-tab sessions.
5. Recreate tmux: `tmain` (→ `supa-crm/start-tmux-session.sh`).

### E2. Verification checklist
- [ ] `nvidia-smi` works; PRIME on-demand; suspend/resume; Wi-Fi 6E; external monitor as an extended display (no monitor audio needed); webcam; audio
- [ ] `tailscale status` shows `toplap123` at **100.86.106.55** (verified 2026-11-04, listener on :2222); `ssh -p 2222` from the phone works (else update `docs/remote-access.md`)
- [ ] Home Manager check/build passed; approved profile activated; Claude + Codex logged in; assistant links and skills resolve; `rtk --version`
- [x] mise Python/Node and uv work in noninteractive agents; no shadowing legacy tool copies (2026-11-04: Python 3.12.15, Node 24.22.0, uv 0.13.1 from mise)
- [ ] Native graphics setup done; matching NVIDIA userspace version/hash declared and offloading verified
- [ ] the agent-work snapshot matches; old Codex threads visible; `claude --resume` works; worktrees repaired
- [ ] `repos-status` regenerated on native matches the pre-migration file (except for the deliberate pushes)
- [x] no `/mnt/c`, `.exe` or `wslg` references left in shell config (D4 grep is empty)
- [x] no plaintext secrets in dotfiles (2026-11-04: active dotfiles clean; the unused `~/.mybashrc`, `~/.mybashrc.sh`, `~/.bashrc.pre-spawnkit` match the store and are kept by Shmuel's choice, as is `~/.bash_history`)
- [ ] Family Desk, arnona-bot, bank-records automation, google-automation, personal-sms and clockify-sheets-sync each run end-to-end once
- [x] Required Ubuntu host packages/services configured; Tailscale daemon reachable through the managed CLI
- [x] Docker works (2026-11-04: Engine 29.1.3 reachable without sudo); the supa-crm local stack is not part of the migration
- [ ] Before adopting the Windows VM: busy-GPU start refusal, Windows GPU acceleration and repeated return to Linux verified
- [x] Citrix access works (2026-11-04: Workspace app 24.11 from the `citrix` role)
- [x] `.ica` files opened from Chrome start Citrix: the laptop profile makes `wfica.desktop` the default and replaces Ubuntu's launcher with one that drops the Nix Chrome wrapper's `LD_LIBRARY_PATH` (2026-11-05: with it, wfica exited on a Nix sqlite needing a newer glibc; confirmed working by Shmuel the same day)
- [ ] Windows Downloads/Documents/Desktop present in `~/windows-import` (2026-11-04: rsync dry run against read-only C: shows no differences except the deliberately skipped `Chrome Passwords.csv` and the portable `Desktop/Tor Browser`); all 51 Notepad++ backups imported, review by Shmuel pending
- [x] CopyQ autostarts; the `Ditto/*` tabs exist; the import printed "verified per tab"; a Hebrew clip and an image paste correctly (2026-11-04)
- [ ] log complete; summary given to Shmuel

---

## Phase F — Decommission (only on Shmuel's explicit go-ahead, weeks later)
- **Shrink the dual-boot Windows partition (to-do).** Keep the native Windows install: it's a licensed copy. Strip its data and leave it about 15 GiB of free space for an occasional login. Daily Windows use goes through the VM (`docs/windows-vm.md`). Layout: p1 EFI 0.25 GiB, p2 MSR, p3 C: 0.27–471 GiB, p5 Linux ext4 471–952 GiB, p4 WinRE 1.95 GiB at the end.
  1. Confirm with Shmuel that nothing on C: is still needed (C5 copied the Windows data). Archive or release the `ext4.vhdx` there first (next bullet).
  2. Boot native Windows once. Delete user data, the WSL distribution and large apps. Run Disk Cleanup, including system files. Turn off hibernation (`powercfg /h off`), and temporarily turn off the page file and System Restore so their files don't block shrinking.
  3. Shrink C: in Disk Management to its used size plus about 15 GiB, then turn the page file back on. If Windows refuses because of unmovable files, run `ntfsresize` from Linux with C: unmounted, then shrink p3 with `parted`. Keep p2, p4 and the Windows Boot Manager EFI entry.
  4. The freed space sits *before* p5. ext4 grows only at its end, so growing `/` means moving p5's start. That needs a live USB and GParted, with p5 unmounted, and takes hours for about 150 GiB of data. Back up first. The alternative: put the freed space in a new partition, mounted for example at `/data` or used as a libvirt image pool, with no move.
  5. Check that Windows still boots from the firmware boot menu, then record the result in `MIGRATION-LOG.md`.
- Before that, the 313 GB `ext4.vhdx` is the last full copy of the WSL world. Ask whether to archive it (external drive) or let it go.
- Then apply the generated-run retention policy to `~/.codex/sessions` and `~/tmp`.

## Certificate trust during migration

See [certificate-trust.md](certificate-trust.md) for the October 2026 eMudhra
distrust policy. Ubuntu system trust and the Java update guard belong to the
Ansible `certificate_policy` role; user runtime CA selection belongs to Home
Manager. Preserve that ownership split. The unmarked-host emergency installer
does not enroll a machine. Windows current-user distrust is not machine-wide,
Termux updates do not patch Android system trust, and existing clients may cache
old roots. Native deployment and per-client rejection tests remain separate from
Nix profile and Ansible syntax validation.


## Mint home-server CI pool

The home server uses the explicit `ansible/ci-vms.yml` playbook, not full Ubuntu
host enrollment. It provisions native KVM/libvirt, a private filtered network,
the shared VM budget and a host-owned queue controller. Pool size, guest resources,
image hashes, kernel baseline and CPU quota are declared in
`hosts/server/ci-vms.json`. Stage the supported kernel update and reboot before
production activation. Each job runs in a fresh guest with its own Docker daemon;
personal host files, sockets and credentials are not mounted into it.

The October 22 final native acceptance passed seven jobs with three 8 GiB,
four-vCPU guests under the verified effective `machine.slice` 70% CPU budget.
Earlier custom-slice measurements did not consistently include recycled QEMU
scopes and are not comparable capped-throughput results. The new kernel
`5.15.0-198-generic`, closed-lid reboot, guest isolation, controller restart and
return to zero were verified. CPU temperature reached 100 C with hardware thermal
throttling. See [the disposable CI runbook](ci-vms.md) for authentication,
isolation and maintenance. The original host-account runners were retired.
