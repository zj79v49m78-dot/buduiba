# FortressOne

A reversible Windows tuning tool for a machine that exists to run one game.

Built for a specific system: **i5-11400F · GTX 1070 · 16GB DDR4-3200 · MSI MPG Z590 Gaming Plus · 244Hz · wired GameSir (Xbox layout) · wired ethernet behind double-NAT.**

---

## Read this before you run anything

**The frame cap is the fix.** If you take one thing from this repository, take this:

> Your GPU is the bottleneck in real matches. When a GPU sits at 99–100% utilisation, frames queue ahead of the display, and every queued frame adds latency between your thumb and the screen. Capping your frame rate *below* what the GPU can sustain keeps that queue empty. You will see a **lower FPS number** and get **dramatically lower input delay**.

That is why Creative feels perfect at 240 FPS and a real match feels awful at 200. Same PC, same settings — the only variable is GPU headroom. Every registry tweak in this tool combined is smaller than this one change.

Run option **2** in the menu. It calculates the cap for your hardware and explains its reasoning.

---

## Quick start

```powershell
# 1. Diagnose first. Changes nothing. Tells you what is actually wrong.
.\FortressOne.ps1 -Diagnose

# 2. See exactly what would change, without changing it.
.\FortressOne.ps1 -Apply core -DryRun

# 3. Apply.
.\FortressOne.ps1 -Apply core

# Undo everything, at any time.
.\FortressOne.ps1 -Revert -All
```

Or run `.\FortressOne.ps1` with no arguments for the interactive menu.

If Windows blocks the script: `Set-ExecutionPolicy -Scope Process Bypass`

---

## How reversibility actually works

Most tweaking tools ship an "undo" that is a second, separately-written list of values to restore. That list drifts out of sync with the apply path, and the bugs only surface when you need it most.

FortressOne does not do that. **There is no per-tweak undo code.** Instead, the engine always executes in this order:

1. Read the current state of every target.
2. Write that state into the journal.
3. *Only then* write the new value.

Reverting replays recorded prior states in reverse. It is the same code for every tweak, so it is exercised constantly rather than only in emergencies.

Two facts are recorded per target: **did it exist**, and **what was it**. That distinction matters — restoring a registry value to `0` is not the same as deleting a value that never existed, and conflating them is the most common way tools leave a system permanently altered while claiming to have restored it.

The journal lives in `%ProgramData%\FortressOne\journal\`:

- `applied.json` — index of what is currently applied
- `tx-<guid>.json` — immutable per-transaction records; the index can be rebuilt from these if it is ever corrupted

`.\FortressOne.ps1 -Status` reads the **live system**, not the journal, so it detects drift — changes undone by Windows Update, Tamper Protection, or another tool.

---

## What this tool will not do, and why

**It will not inject into, hook, or read the Fortnite process.** Easy Anti-Cheat and BattlEye scan for exactly that. Every change here is OS-level and applied while the game is closed. Tools that behave otherwise get people banned.

**It will not write Engine.ini rendering overrides.** Config edits that strip foliage, disable fog or otherwise change what you can see relative to other players are config exploits. Epic removes them and penalises them. Every setting this tool writes is one you could set in the game's own options menu.

**It will not bypass Defender Tamper Protection.** Anything that defeats Tamper Protection is behaviourally indistinguishable from malware. If you want Defender off, turn Tamper Protection off yourself in Windows Security first. (The Fortnite folder exclusion is a better trade anyway — nearly all the benefit, none of the exposure.)

**It will not mass-uninstall your desktop software.** Not squeamishness — the protection list exists precisely so aggressive removal is survivable. The reason is that a blind sweep cannot tell a redundant vendor utility from the Visual C++ runtime Fortnite links against, the chipset package governing your USB and PCIe behaviour, or the driver package your controller enumerates through. Removing those does not produce a leaner machine; it produces a machine that no longer runs Fortnite.

So instead: the inventory is complete, the scoring is aggressive, the protection list is short and specific, and the decision is shown to you rather than assumed. Same destination, without the failure mode where you finish and the game won't start.

---

## The protection list

`data/protected.json` is a hard veto that no tier or selection overrides. Every entry states why. It covers Easy Anti-Cheat and BattlEye, the audio stack, **the XInput/HID stack your GameSir runs on**, core networking (`nsi`, `BFE`, `AFD` — the classic "my internet died after debloating" causes), boot-critical storage drivers, and the NVIDIA driver stack.

A test asserts that no shipped tweak trips the veto, so the list and the tweak set cannot silently contradict each other.

---

## Repository layout

```
FortressOne.ps1              Entry point; self-elevates
src/Core/
  FO.Logging.psm1            Structured logging
  FO.Journal.psm1            State journal — the revert mechanism
  FO.Providers.psm1          Read/write adapters (registry, service, task,
                             power, tcp, nic, bcd, defender exclusion)
  FO.Engine.psm1             Load, validate, veto, apply, verify, revert
  FO.Backup.psm1             Restore points and registry exports
src/Diag/
  FO.Diag.System.psm1        Hardware inventory + interpreted findings
  FO.Diag.Network.psm1       Ping matrix, bufferbloat, double-NAT
  FO.Diag.Latency.psm1       MSI mode, USB power, timer resolution
src/Modules/
  FO.Fortnite.psm1           Frame cap calculation, GameUserSettings.ini
  FO.Debloat.psm1            App/startup inventory and removal
data/
  tweaks/*.json              58 tweak definitions
  protected.json             Hard veto list
  bloat-catalog.json         Removal classification
docs/
  DIAGNOSIS.md               What is wrong with this specific machine
  FORTNITE-SETTINGS.md       In-game and NVIDIA Control Panel settings
  BIOS-MSI-Z590.md           BIOS guide — the real CPU win on a locked chip
  TWEAK-REFERENCE.md         Generated from the definitions
tests/Test-FortressOne.ps1   39 tests
tools/Build-TweakReference.ps1
```

---

## Tiers

| Tier | Contains | Trade-off |
|---|---|---|
| **core** | Scheduler, MMCSS, power policy, USB suspend, Game DVR, telemetry | Essentially free. Start here. |
| **aggressive** | VBS/HVCI, NIC interrupt moderation, service pruning, Defender exclusions | Real trade-offs, individually stated. |
| **nuclear** | Defender off, Windows Update off, search indexing off | Genuine security and maintenance costs. |

Tiers are cumulative. Every tweak carries a mandatory rationale — the engine **rejects any definition whose rationale is under 40 characters**, which is the structural defence against cargo-cult tweaks. Where a popular tweak does nothing useful, it says so: see `lat.nagle.disable-tcp-coalescing`, which is included with an explanation of why it will not fix your input delay despite every guide claiming it will.

---

## Tests

```bash
pwsh -File tests/Test-FortressOne.ps1
```

39 tests covering definition validation, journal round-trip and index rebuild, veto logic, registry path normalisation, INI round-tripping (including that unrecognised keys survive a rewrite), frame cap maths, and address classification.

They do **not** cover actual registry/service/powercfg writes, which require Windows. Verify those on the target machine with `-Apply core -DryRun`.

---

## Honest expectations

| Complaint | Verdict |
|---|---|
| Controller input delay | **Fixable, large.** Frame cap + Reflex + USB power. This is the big one. |
| FPS in-game | **Improvable, modest.** VBS off, XMP, BIOS power limits. The GTX 1070 is the ceiling. |
| Ping in the high 30s | **Mostly not fixable.** That is distance to the datacentre. Physics. |
| Ping *spikes* under load | **Very fixable** — bufferbloat, at the router. The tool measures it. |
| Double-NAT | **Real but small.** Costs 1–3ms, not 30. Affects NAT type more than ping. |

The diagnostic report will tell you which of these actually apply to your machine rather than assuming.
