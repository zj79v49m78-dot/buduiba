# Fortnite and NVIDIA Settings

Some of this the tool writes for you (menu option 2). The rest must be set by hand because it lives in the driver profile database or the game's own UI. This document covers everything, marked accordingly.

---

## The one that matters: frame rate limit

**Set by:** the tool, but you should understand it.

Your GTX 1070 cannot sustain 240 FPS in a real match. When it is pinned at 100%, frames queue ahead of the display, and each queued frame adds latency between your input and the screen.

Cap the frame rate below what the GPU can sustain in its **worst** moments — not its average ones, because the queue fills during fights, which is exactly when you need input fidelity.

### How to find your number

1. In Fortnite, turn on the FPS counter (Settings → Game UI → Show FPS).
2. Play three real matches. Not Creative — Creative does not load the GPU.
3. Note your **average** and, more importantly, the **lowest sustained figure during a fight**.
4. Run menu option 2 and enter both. It calculates the cap at ~95% of your 1% low.

As a starting point before you have measured: **150–160**.

### Why a lower number feels better

This is genuinely counterintuitive and worth stating plainly. Capping at 160 when uncapped gives you 200:

- You lose 40 frames per second of a number on screen.
- You remove roughly 2–4 frames of queued latency, which is **10–25ms** off every input.

The FPS counter goes down. The game feels transformed. If you do not believe it, cap it, play three matches, uncap it, play three more. The difference is not subtle.

---

## In-game video settings

**Set by:** the tool writes these to `GameUserSettings.ini`.

| Setting | Value | Why |
|---|---|---|
| Window Mode | **Fullscreen** | Exclusive fullscreen has the shortest present path and bypasses the desktop compositor. Borderless costs you up to a frame. |
| Resolution | **1920×1080** | Native. Do not use a stretched resolution unless you are already used to one. |
| Frame Rate Limit | **your calculated cap** | See above. |
| Rendering Mode | **Performance** | Purpose-built low-overhead renderer. On a 1070 this is a very large gain. |
| 3D Resolution | **100%** | Lowering this is the single most damaging setting for spotting distant players. Cut elsewhere first. |
| View Distance | **Epic** | Costs almost nothing on modern hardware and lets you see distant builds and players. Do not lower this. |
| Shadows | **Off** | Expensive, and shadows help opponents locate you as much as you them. |
| Anti-Aliasing | **Off** | Expensive on a 1070. |
| Textures | **Low** | Frees VRAM. Your 1070 has 8GB, so this is less critical, but it costs nothing competitively. |
| Effects | **Low** | Large gain during the busy fights where you need frames most. |
| Post Processing | **Low** | Pure visual cost, no competitive value. |
| VSync | **Off** | Adds a full frame of latency. Never on for competitive play. |
| Motion Blur | **Off** | Actively harms target tracking. |

---

## NVIDIA Reflex — set this by hand

**Where:** Fortnite → Settings → Video → **NVIDIA Reflex Low Latency** → **On + Boost**

**This must be set in the game. The tool cannot write it.**

Reflex works from the opposite direction to the frame cap: instead of limiting frames, it lets the game tell the driver to hold back CPU frame submission until the GPU is nearly ready. It keeps the render queue empty dynamically. Reflex plus a sensible cap is the correct combination — they solve the same problem by different means and stack well.

**On + Boost** additionally keeps GPU clocks elevated during CPU-bound moments, which reduces the frametime variance that reads as inconsistency.

Also enable the **latency markers**, so the in-game stats overlay reports actual system latency in milliseconds. Then you can *measure* whether a change helped instead of guessing.

---

## NVIDIA Control Panel — set these by hand

**Where:** right-click desktop → NVIDIA Control Panel → Manage 3D Settings → **Program Settings** tab → select Fortnite.

Set these per-program rather than globally.

| Setting | Value | Why |
|---|---|---|
| Max Frame Rate | **your cap** | A second limiter alongside the in-game one. The driver limiter behaves slightly differently; having both prevents overshoot. |
| Low Latency Mode | **Ultra** | See the note below. |
| Power management mode | **Prefer maximum performance** | Stops the GPU dropping clocks between frames. On a card that is your bottleneck, clock ramping is wasted time. |
| Texture filtering – Quality | **High performance** | Small but free. |
| Vertical sync | **Off** | Latency. |
| Threaded optimization | **On** | Lets the driver use more than one CPU thread for submission. |
| Monitor Technology | **G-SYNC** *(only if your monitor supports it)* | If you have G-SYNC or a G-SYNC-Compatible panel, enable it, keep VSync **off** in-game, and keep the frame cap below refresh. That combination is the lowest-latency configuration available. |

**Honest note on Low Latency Mode:** once Reflex is enabled in-game, Reflex takes precedence and the control panel's Low Latency Mode setting is effectively ignored for Fortnite. Set it to Ultra anyway — it is harmless, and it covers you if Reflex is ever unavailable after a patch. Do not expect the two settings to stack.

---

## Controller settings

**Where:** Fortnite → Settings → Controller. Set by hand.

Your GameSir in Xbox layout presents as an XInput device, so it behaves like an Xbox controller as far as Windows and Fortnite are concerned.

| Setting | Value | Why |
|---|---|---|
| Left Stick Deadzone | **as low as it goes without drift** | Lower it until the character moves on its own, then raise it one step. Deadzone is delay before input registers at all. |
| Right Stick Deadzone | **same method, tuned separately** | The sticks wear differently; tune each. |
| Build Immediately | **On** | Removes a confirmation step. |
| Edit Hold Time | **0.100** | The minimum. |
| Boost Ramp Time | **0.00** | Removes acceleration delay on aim. |
| Vibration | **Off** | Rumble is USB traffic on the same endpoint as your inputs and gives you nothing. |

**Also turn off**, under Game/Video settings: Replay Recording, and any Highlights or auto-capture options. Replay recording writes continuously during every match.

---

## The measurement discipline

Every change on this page and in the tweak set should be verified, not assumed. The method:

1. Turn on Reflex latency markers so the stats overlay shows system latency in ms.
2. Note the number in a real match — not Creative.
3. Change **one** thing.
4. Play three matches. Note the number again.

If you cannot measure a difference and cannot feel one, revert it. A tweak you cannot detect is a tweak that is not helping, and stacking twenty of those is how people end up with an unstable machine and no idea which change caused it.

---

## Quick sanity checklist

Before blaming anything complicated, confirm:

- [ ] Windows display settings show your monitor at its **full refresh rate**, not 60Hz. (`-Diagnose` flags this. It is the most commonly missed setting and it costs more latency than every registry tweak combined.)
- [ ] Fortnite is in **Fullscreen**, not Borderless.
- [ ] **Reflex is On + Boost.**
- [ ] A **frame cap is set**, and it is below what your GPU sustains.
- [ ] Controller is plugged directly into a **motherboard rear USB port**, not a front panel header or an unpowered hub.
- [ ] Discord/GeForce Experience/Steam **overlays are off** — they inject into the present path and are a recurring source of both latency and anti-cheat friction.
