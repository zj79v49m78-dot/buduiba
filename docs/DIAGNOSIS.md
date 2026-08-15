# Diagnosis

What is actually wrong, in priority order, based on the symptoms described:

> *"In Creative on a simple map I had 240 constant and absolutely zero delay on my controller for the first time. But then in game, 200 FPS and a lot of delay. It feels like 10000 delay on my controller, unplayable. And my ping is high 30s even though I have very good ethernet."*

That description is unusually diagnostic. Most people say "it feels laggy"; you gave a controlled comparison — same PC, same controller, same settings, two different scenarios, wildly different feel. That narrows it down enormously.

---

## 1. The input delay — GPU-bound render queue

**Confidence: very high. This is your problem.**

Look at what changed between your two scenarios:

| | Creative, simple map | Real match |
|---|---|---|
| FPS | 240 | 200 |
| GPU utilisation | maybe 50–60% | 99–100% |
| Input feel | **instant** | **unplayable** |

The FPS difference is small — 240 to 200 is 17%. The *feel* difference is enormous. A 17% frame rate drop cannot explain "feels like 10000 delay". So the frame rate is not what changed. **GPU headroom** is.

Here is the mechanism. Your CPU prepares frames and hands them to the GPU. When the GPU has headroom, it finishes each frame before the next arrives — the queue stays empty, and a frame goes from input to screen in about one frame interval.

When the GPU is saturated, the CPU keeps submitting anyway, and frames **stack up in a queue**. By the time a frame reaches your monitor it may have waited several frame intervals. Critically, **the controller input that produced it was sampled at the start of that wait.** You are looking at a picture of where your stick was three or four frames ago.

In Creative your GPU is at 60%, the queue is empty, and you felt what your hardware is genuinely capable of. In a match it is at 100%, the queue is full, and you are feeling the queue.

**The fix, in order of size:**

1. **Cap your frame rate below what the GPU sustains.** Around 150–160 to start. Measure your real in-match 1% low and let the tool calculate it properly. You will see a lower FPS number and dramatically better input.
2. **Reflex → On + Boost.** Solves the same problem from the driver side by holding back CPU submission dynamically. Stacks well with the cap.
3. **Drop Effects, Post Processing and Shadows.** Not for the FPS number — to buy back GPU headroom so the queue stays empty.
4. **USB power management off** (`pwr.usb.selective-suspend-off` plus the per-device tweak). This is a separate, smaller contributor, and it has a distinctive signature: the *first* input after a pause feels mushy while continuous movement feels fine. If that matches what you feel, this is part of it too.

**What will not fix it:** none of the registry tweaks. They are worth applying and they will help frametime consistency, but if you apply all 58 and leave the frame rate uncapped, it will still feel bad. The cap is the fix.

---

## 2. The ping — mostly not a fault

**Confidence: high.**

High-30s to an Epic datacentre is **normal**. It is the round trip to a physical building some hundreds of kilometres away, and it is bounded by the speed of light in fibre plus a handful of router hops. "Very good ethernet" makes your connection stable and low-jitter; it does not make the datacentre closer.

For context, Fortnite's servers also run at a fixed tick rate, adding tens of milliseconds of its own on top of whatever your network ping is. Everyone playing has that. At high-30s you are in the range competitive players consider fine.

**However — two things here genuinely are worth checking, and the tool checks both:**

**Bufferbloat.** This is the real villain in most "my ping is fine but the game feels bad" cases and almost nobody measures it. Oversized router buffers mean that when *anything* saturates your line — a game patch, a Windows update, someone else streaming — your packets queue and latency goes from 35ms to 300ms+. Speed tests still report the connection as fine. If your delay is noticeably worse while the launcher is patching or when the house is busy, this is why. Fixed at the **router** with SQM/QoS, not on the PC. `-Diagnose` grades it A+ through F.

**Wrong region.** If Fortnite is matching you to a region that is not your closest, that is real latency you can remove for free. The diagnostic measures latency to every Fortnite region and tells you which is actually nearest.

**Your double-NAT:** real, but do not over-blame it. A second NAT layer costs roughly 1–3ms, not 30. What it genuinely causes is a Strict or Moderate NAT type, occasional voice chat problems and slower peer connection setup. If you want it gone, put the outer router in bridge/modem mode. Do not expect your ping number to move much.

---

## 3. FPS — the GTX 1070 is your ceiling

**Confidence: high.**

A GTX 1070 in Performance Mode at 1080p lands somewhere around 150–200 FPS in real matches depending on the situation. That is the card. No software makes it a 240Hz card for Fortnite battle royale.

What is genuinely available:

- **BIOS power limits** (see `BIOS-MSI-Z590.md`). Your 11400F throttles from 154W to 65W after ~28 seconds of sustained load. Fixing this is the largest CPU gain available, and it specifically helps in *long* engagements — endgames — which is when it matters.
- **XMP.** If your RAM is running at 2133 instead of 3200, you are losing real 1% lows. `-Diagnose` will tell you.
- **VBS/HVCI off.** Measurable CPU recovery on Windows 11, and it lands hardest on 6-core parts. Genuine security trade-off, stated as such.

Set your expectations correctly: you are optimising for **consistent frametimes at a sustainable frame rate**, not for a bigger number. Consistency is what you feel.

---

## 4. What "reset my PC, applied tweaks, then reverted" may have left behind

You reported the system as clean, so this is a precaution rather than a diagnosis. Run:

```powershell
.\FortressOne.ps1 -Status
```

This reads the **live system**, not the journal, and flags anything in a partial or drifted state. Two leftovers worth checking specifically, because both are common and both make things worse:

- **`bcdedit useplatformclock yes`** — a very widely-repeated tweak that forces Windows onto the HPET timer. On modern hardware this is actively harmful. `lat.boot.unforce-hpet` removes it, and is a harmless no-op if you never set it.
- **Display refresh rate reset to 60Hz.** A Windows reset or a driver reinstall often reverts this and it is easy to miss. `-Diagnose` flags it. This one costs more latency than every registry tweak in this repository combined.

---

## Recommended order

1. **Check the basics.** Refresh rate at 244Hz. Fullscreen not borderless. Controller in a rear motherboard port.
2. **BIOS**: XMP on, dual channel confirmed, power limits raised.
3. **Frame cap + Reflex.** This is the fix. Measure your real in-match 1% low first.
4. `-Apply core`. Low risk, good value.
5. **Measure.** Reflex latency markers on. Play three matches. Note the number.
6. `-Apply aggressive` if you want the VBS and NIC changes, having read their trade-offs.
7. **Measure again.** If a change made no difference you could detect, revert it.
8. Debloat last. It is the most satisfying and the least impactful — a machine with 40 fewer Store apps has almost exactly the same in-match frametimes. Do it because you want a clean machine, not because it will fix your input delay.

Step 3 is worth more than steps 4, 6 and 8 combined. If you only do one thing, do that one.
