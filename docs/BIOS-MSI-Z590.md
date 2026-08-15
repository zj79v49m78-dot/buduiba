# BIOS Guide — MSI MPG Z590 Gaming Plus + i5-11400F

Your CPU is a **locked** part. There is no multiplier to raise, so "overclocking" in the usual sense is not available. That is not the same as saying there is nothing to gain here — there is, and one item on this list is probably the single largest CPU improvement available to your machine.

Ranked by how much they actually matter:

---

## 1. Power limits — the big one

**This is the most important setting in this document.**

Intel ships the 11400F with a sustained power limit (PL1) of **65W** and a short-term boost limit (PL2) of **154W**. After roughly 28 seconds of sustained load, the chip drops from 154W to 65W and its all-core clock falls with it.

A Fortnite match is a sustained load. So your CPU spends the first half-minute fast and the rest of the game throttled to its base power budget. This is exactly the shape of "my FPS is fine at first and gets worse in endgames" — and endgames are when frames matter most.

Raising PL1 to match PL2 keeps the chip at its boost clock indefinitely.

**Where:** `OC` → set `OC Explore Mode` to `Advanced` → `Advanced CPU Configuration`

| Setting | Set to |
|---|---|
| Long Duration Power Limit (PL1) | `154` (or `4095` for unlimited) |
| Short Duration Power Limit (PL2) | `154` |
| Long Duration Maintained | `56` or higher |
| CPU Current Limit | `200` |

**What this costs you:** heat and power. The 11400F is a modest 6-core part and 154W sustained is well within what any competent cooler handles, but if you are on the Intel stock cooler, watch your temperatures. Anything sustained under about 85°C is fine. If you see 95–100°C and clocks dropping, the cooler is the limit and you should back PL1 down to around 95–110W or buy a better cooler (a £25 tower cooler transforms this chip).

**Verify it worked:** run something CPU-heavy for two minutes and watch the clock speed in Task Manager. Before, it drops after ~28 seconds. After, it should hold.

---

## 2. XMP — free performance you already paid for

Your RAM is rated for 3200 MHz. Without XMP enabled it runs at the JEDEC default of **2133 MHz**. That is a 33% memory bandwidth loss, and Fortnite is genuinely sensitive to memory performance — it shows up in your 1% lows, which is to say in the frametime consistency you feel as smoothness.

**Where:** `OC` → `Extreme Memory Profile (XMP)` → `Profile 1`

**Verify:** run `.\FortressOne.ps1 -Diagnose`. The inventory reports each module's rated speed alongside what it is actually running at, and flags the gap. Task Manager → Performance → Memory also shows the running speed.

If the machine fails to boot with XMP on, clear CMOS (button on the rear I/O or the jumper on the board) and try `Profile 2` if present, or set the frequency manually to 3000 MHz.

---

## 3. Memory slot placement

With two sticks on a four-slot board, they must be in the correct pair or you run in **single channel**, which halves memory bandwidth and is a larger loss than anything else on this page.

On the MPG Z590 Gaming Plus, use **DIMMA2 and DIMMB2** — the second and fourth slots counting away from the CPU.

**Verify:** Task Manager → Performance → Memory shows "Channels: 2" (some builds label it "Slots used"). CPU-Z's Memory tab reports "Dual" under Channel. `-Diagnose` also warns if it only sees one module.

---

## 4. Intel Speed Shift (HWP)

Lets the CPU manage its own frequency transitions in hardware rather than waiting for the OS. Transitions land in roughly 1ms instead of roughly 30ms, which matters for the bursty load a shooter produces.

**Where:** `OC` → `CPU Features` → `Intel Speed Shift Technology` → `Enabled`

Pairs with the `pwr.cpu.min-state-100` tweak: Speed Shift makes the ramp fast, the power plan means you rarely need to ramp at all.

---

## 5. C-States — leave them on

You will find a lot of guides telling you to disable C-States for lower latency. On Sandy Bridge in 2012 that was reasonable advice. On Rocket Lake it is mostly obsolete: modern C-state exit latencies are in the microsecond range, and disabling them can actually *reduce* your peak turbo, because turbo budget depends on other cores being genuinely idle.

**Recommendation:** leave C-States at `Auto`/`Enabled`.

If you want to test it, change one thing, play three matches, and change it back if you cannot tell. That is the correct methodology for every marginal setting on this page.

---

## 6. Things that do not apply to your build

**Resizable BAR** — requires Ampere (RTX 30) or newer. Your GTX 1070 is Pascal and does not support it. Enabling `Above 4G Decoding` and `Re-Size BAR Support` in BIOS is harmless but will do nothing for you.

**Secure Boot / TPM** — Fortnite does not require either (that is Valorant's Vanguard, not Easy Anti-Cheat). Leave them however they are. Note that if you enable Secure Boot later, it can re-enable the VBS features the Windows 11 tweak pack disables.

**CPU voltage / BCLK** — the 11400F is locked. BCLK overclocking on Z590 exists but is unstable, risks your storage controller, and the return on a locked 6-core is not worth it. Skip.

---

## 7. Fan curve

Set this in BIOS rather than in software, so it works before Windows loads and does not depend on a vendor utility running in the background — one fewer resident process, which is the point of the whole exercise.

**Where:** `Hardware Monitor` (F7 on the MSI UI)

A reasonable curve for a gaming machine: 30% until 50°C, ramping to 100% at 85°C. Once this is set you can remove MSI Center entirely if you want to.

---

## 8. BIOS version

Rocket Lake received meaningful microcode updates after launch. Check your current version with `.\FortressOne.ps1 -Diagnose` (reported as "BIOS") and compare against the MSI support page for the MPG Z590 Gaming Plus (board code MS-7D07).

**A caution:** a failed BIOS flash is one of the few genuinely unrecoverable things you can do to a motherboard. Only update if you are on a notably old version, use the M-FLASH utility from a FAT32 USB stick, and do not lose power partway through. If your BIOS is from 2022 or later, the benefit is small and the risk is not worth chasing.

---

## Order of operations

1. Enable XMP. Boot. Verify 3200 MHz.
2. Confirm dual channel. If not, move the sticks.
3. Raise the power limits. Boot. Load-test for two minutes and watch temperature.
4. Enable Speed Shift.
5. Save and exit. Then run `.\FortressOne.ps1 -Diagnose` to confirm Windows sees all of it.

Change one thing at a time and verify between each. If you change five settings and the machine will not boot, you have learned nothing about which one was responsible.

**If something goes wrong:** clear CMOS. Every setting here reverts to default, including any that stopped the machine booting. This is why BIOS changes are, in practice, among the safest changes in this repository — the reset is a physical button.
