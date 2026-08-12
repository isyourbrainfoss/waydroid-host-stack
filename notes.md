Seamless Bluetooth for Waydroid — detailed summary

Ultimate goal

100% seamless Bluetooth passthrough: Android apps behave as on a real phone — pair headphones, transfer files, use fitness sensors, Companion Device flows, background BLE, Tesla Phone Key — while the Linux host (Phosh, bluetui, PipeWire, system BT) keeps working on the same radio, with no user-facing “passthrough mode,” dongle juggling, or “give Bluetooth to Android” toggle.

That goal is aspirational. Architecture should be chosen so every major class of app is reachable, and known hard cases (dual audio stacks, UWB, OEM-specific HAL quirks) are called out explicitly.

───

Constraints on a Linux phone (postmarketOS + Phosh)

┌─────────────────────────────────┬────────────────────────────────────────────────┐
│ Constraint                      │ Why it matters                                 │
├─────────────────────────────────┼────────────────────────────────────────────────┤
│ One radio                       │ Phones almost never have a spare BT controller │
├─────────────────────────────────┼────────────────────────────────────────────────┤
│ Host must keep BT               │ Calls, media, system UI, bluetui               │
├─────────────────────────────────┼────────────────────────────────────────────────┤
│ Waydroid is LXC, not a VM with  │ No clean “assign device to guest only” without │
│ PCIe BT                         │ stealing from the host                         │
├─────────────────────────────────┼────────────────────────────────────────────────┤
│ Android apps use platform APIs, │ Compatibility = stack behavior, not “packets   │
│ not HCI                         │ somehow reach the air”                         │
├─────────────────────────────────┼────────────────────────────────────────────────┤
│ Current Waydroid images omit    │ Any solution must restore the guest stack      │
│ Bluetooth packages              │ first                                          │
└─────────────────────────────────┴────────────────────────────────────────────────┘

Non-negotiable design rule: only one entity should own the HCI controller in production. On Linux that entity should be BlueZ (bluetoothd). Everything else is a client of BlueZ (directly or through a host bridge).

───

What Android apps actually need

Apps do not open /dev/hci0. They use the AOSP Bluetooth stack via Binder:

App
 → android.bluetooth.* / system services
   → Bluetooth stack (Fluoride / Gabeldorsche)
     → Vendor HAL (IBluetoothHci / related)
       → Controller (on a real phone)

“Flawless” for arbitrary apps means covering roughly:

┌──────────────────────────┬─────────────────────────┬─────────────────────────────┐
│ Domain                   │ Examples                │ If missing                  │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ Adapter lifecycle        │ On/off, name, address,  │ Settings + most apps broken │
│                          │ scan mode               │                             │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ Classic                  │ Pairing, SPP, HID       │ Many accessories            │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ A2DP / AVRCP / HFP       │ Headphones, car audio,  │ “Pair headphones” fails as  │
│                          │ calls                   │ users expect                │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ BLE central              │ Scan, connect, GATT R/  │ Tesla, sensors, locks       │
│                          │ W/notify                │                             │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ BLE peripheral /         │ Sharing, beacons, some  │ Subset of apps              │
│ advertise                │ keys                    │                             │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ Bonding / privacy IRK    │ Reconnect, identity     │ Flaky pairing               │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ Background LE            │ Phone Key, tags,        │ Works only in foreground    │
│                          │ presence                │                             │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ CompanionDeviceManager   │ Modern pairing UX       │ App-specific flows break    │
├──────────────────────────┼─────────────────────────┼─────────────────────────────┤
│ Multi-connection         │ Headset + watch + car   │ One-app demos only          │
└──────────────────────────┴─────────────────────────┴─────────────────────────────┘

Conclusion: any design that reimplements only “scan + GATT” will never reach the goal. The guest needs a real Android Bluetooth stack. The only open question is how that stack reaches the radio without stealing it from Linux.

───

Alternatives compared

Alternative A — Exclusive HCI / USB passthrough

Idea: Bind-mount or pass the Bluetooth controller into Waydroid; Android owns the radio.

Host BlueZ ──(stopped)──✕
Android stack ── HCI ── controller

┌─────────────────────────────────────┬────────────────────────────────────────────┐
│ Pros                                │ Cons                                       │
├─────────────────────────────────────┼────────────────────────────────────────────┤
│ Closest to a real phone inside      │ Host loses Bluetooth — fails the phone     │
│ Android                             │ goal                                       │
├─────────────────────────────────────┼────────────────────────────────────────────┤
│ Full stack can work if packages     │ Bad UX: mode switch, race on boot          │
│ restored                            │                                            │
├─────────────────────────────────────┼────────────────────────────────────────────┤
│ Simpler mental model for “          │ USB dongle hacks don’t scale to internal   │
│ passthrough”                        │ SoC BT                                     │
├─────────────────────────────────────┼────────────────────────────────────────────┤
│                                     │ Pairing DB split if you flip host/guest    │
└─────────────────────────────────────┴────────────────────────────────────────────┘

Verdict: Acceptable for a desktop with a second dongle; wrong for a daily-driver Linux phone. Does not meet “seamless for host + guest.”

───

Alternative B — High-level API stubs (Java/Kotlin overlay → BlueZ)

Idea: Replace or shim android.bluetooth / .le so calls become D-Bus to host BlueZ (e.g. via xdg-dbus-proxy). No full Fluoride/Gabeldorsche.

App → stub APIs → D-Bus → BlueZ → radio

┌───────────────────────────────────┬──────────────────────────────────────────────┐
│ Pros                              │ Cons                                         │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ Host sharing is natural           │ Huge API surface; forever incomplete         │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ Faster prototype for LE-only      │ Background, Companion, profiles, OEM         │
│ demos                             │ assumptions break                            │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ Matches “Linux in the middle” at  │ Settings/system UI often inconsistent        │
│ app layer                         │                                              │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│                                   │ Every Android version is a rewrite tax       │
└───────────────────────────────────┴──────────────────────────────────────────────┘

Verdict: Good for spikes (prove BlueZ multi-client). Poor as the path to 100% app compatibility. This is how you get “Tesla demo works, random apps don’t.”

───

Alternative C — Host-only Bluetooth (no Android BT)

Idea: Never fix Waydroid BT. Unlock Tesla / use accessories via native Linux (vehicle-command, bluer, PipeWire).

Linux apps / daemons → BlueZ → radio
Waydroid apps → no BT

┌─────────────────────────────────┬────────────────────────────────┐
│ Pros                            │ Cons                           │
├─────────────────────────────────┼────────────────────────────────┤
│ Works today for some goals      │ Zero Android BT apps           │
├─────────────────────────────────┼────────────────────────────────┤
│ Simple, reliable on Phosh       │ Fails the stated ultimate goal │
├─────────────────────────────────┼────────────────────────────────┤
│ Excellent interim for phone key │                                │
└─────────────────────────────────┴────────────────────────────────┘

Verdict: Best near-term unlock for Tesla-on-Linux; not the end-state architecture.

───

Alternative D — Dual controllers

Idea: Built-in BT for Linux; USB dongle exclusively for Waydroid.

┌─────────────────────────────────┬───────────────────────────────────┐
│ Pros                            │ Cons                              │
├─────────────────────────────────┼───────────────────────────────────┤
│ Both stacks “full” and isolated │ Awkward/impossible on many phones │
├─────────────────────────────────┼───────────────────────────────────┤
│                                 │ Two MACs, two pairing DBs         │
├─────────────────────────────────┼───────────────────────────────────┤
│                                 │ Not “one phone” seamless          │
├─────────────────────────────────┼───────────────────────────────────┤
│                                 │ Power, RF, UX cost                │
└─────────────────────────────────┴───────────────────────────────────┘

Verdict: Lab workaround only.

───

Alternative E — Full Android stack + BlueZ-backed vendor HAL (shared radio)

Idea: Restore the real AOSP Bluetooth stack in the guest. Apps and system services unchanged. Only the vendor HAL (bottom of the stack) talks to a host daemon, which is a BlueZ client. BlueZ alone owns HCI.

Android app
  → real Android BT stack (in Waydroid)
    → vendor HAL (IBluetoothHci or equivalent)
      → host bridge (invisible systemd service)
        → BlueZ
          → radio

Host: bluetui / Phosh / PipeWire → BlueZ (same radio)

┌───────────────────────────────────────────────┬──────────────────────────────────┐
│ Pros                                          │ Cons                             │
├───────────────────────────────────────────────┼──────────────────────────────────┤
│ Maximum app compatibility (real stack)        │ Hard engineering (HAL + image +  │
│                                               │ policy)                          │
├───────────────────────────────────────────────┼──────────────────────────────────┤
│ Invisible middle layer (no user toggle)       │ Concurrent scan/connection       │
│                                               │ policy is subtle                 │
├───────────────────────────────────────────────┼──────────────────────────────────┤
│ Host BT remains first-class                   │ Classic audio dual-stack is the  │
│                                               │ hardest part                     │
├───────────────────────────────────────────────┼──────────────────────────────────┤
│ Aligns with Waydroid’s model (Wayland/Pulse-  │ Needs custom/maintained Waydroid │
│ style host paths)                             │ images                           │
├───────────────────────────────────────────────┼──────────────────────────────────┤
│ Bonds can live in one place (BlueZ)           │ SELinux/D-Bus/LXC plumbing       │
├───────────────────────────────────────────────┼──────────────────────────────────┤
│ Path exists in community design (#155         │ Not shipped today                │
│ Gabeldorsche/BlueZ HAL)                       │                                  │
└───────────────────────────────────────────────┴──────────────────────────────────┘

Verdict: best approach toward the ultimate goal.

───

Alternative F — Full Android stack + virtual HCI (VHCI / packet bridge)

Idea: Guest stack sees a virtual controller; a host process bridges HCI packets to the real controller or into BlueZ.

┌──────────────────────────────────┬───────────────────────────────────────────────┐
│ Pros                             │ Cons                                          │
├──────────────────────────────────┼───────────────────────────────────────────────┤
│ Stack sees “normal” HCI (great   │ If bridge owns real HCI exclusively → host    │
│ compatibility)                   │ loses BT                                      │
├──────────────────────────────────┼───────────────────────────────────────────────┤
│ Similar to emulator/Bumble       │ Multiplexing two full stacks onto one         │
│ setups                           │ controller is research-grade                  │
├──────────────────────────────────┼───────────────────────────────────────────────┤
│                                  │ Link-key / LE state machines can conflict     │
└──────────────────────────────────┴───────────────────────────────────────────────┘

Verdict: Attractive for compatibility of the guest stack, but dangerous for sharing unless the “controller” side is carefully designed as a BlueZ slave, not a second master. Often collapses into either exclusive passthrough (A) or a BlueZ-backed HAL (E) with more complexity.

Practical stance: Prefer E (stack above, BlueZ policy below). Use HCI-shaped internal protocols only if they simplify the HAL, not if they create a second controller owner.

───

Recommended approach (best overall)

One-sentence summary

Run the complete Android Bluetooth stack inside Waydroid; implement a single invisible host bridge so that stack’s vendor HAL is backed by BlueZ; never give Android exclusive ownership of the radio.

That is the only design that simultaneously:

1. Maximizes “every Android app” compatibility (real platform stack),
2. Keeps Linux Bluetooth seamless (BlueZ remains owner),
3. Hides the middle (systemd service, no UX),
4. Matches how Waydroid already shares other devices (high-level host integration, not raw steal).

───

Target architecture

┌──────────────────────────────────────────────────────────┐
│  Linux phone (systemd + Phosh + Flatpak)                 │
│                                                          │
│   bluetui / Phosh BT UI    PipeWire BT audio             │
│            │                      │                      │
│            └──────────┬───────────┘                      │
│                       ▼                                  │
│                 BlueZ (bluetoothd)  ◄── sole HCI owner   │
│                       ▲                                  │
│                       │ D-Bus                            │
│           waydroid-bt-host.service  ◄── no UI            │
│                       ▲                                  │
│                       │ Unix socket / IPC (LXC mount)    │
│  ┌────────────────────┴───────────────────────────────┐  │
│  │ Waydroid (Android)                                 │  │
│  │   Apps (Tesla, Spotify BT, watches, …)             │  │
│  │        ▼                                           │  │
│  │   AOSP Bluetooth stack (restored in image)         │  │
│  │        ▼                                           │  │
│  │   Vendor HAL (only custom BT component in guest)   │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘

User-visible model: one Bluetooth. Host tools and Android apps are peers. No “passthrough.”

───

Why this beats the alternatives for the ultimate goal

┌────────────────────┬───────────┬───────────┬────────┬──────────┬─────────────────┐
│ Goal criterion     │ A         │ B Stubs   │ C      │ D Dual   │ E Full stack +  │
│                    │ Exclusive │           │ Host-  │          │ BlueZ HAL       │
│                    │           │           │ only   │          │                 │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Android app        │ High*     │ Low       │ None   │ High*    │ Highest         │
│ surface            │           │           │        │          │                 │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Host BT remains    │ No        │ Yes       │ Yes    │ Partial  │ Yes             │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Invisible / no     │ No        │ Yes       │ N/A    │ No       │ Yes             │
│ mode switch        │           │           │        │          │                 │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Headphones (       │ Yes*      │ Unlikely  │ No     │ Yes*     │ Yes if profiles │
│ Android)           │           │ complete  │        │          │ mapped          │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Tesla Android      │ Yes*      │ Partial   │ No     │ Yes*     │ Yes if LE +     │
│ Phone Key          │           │           │        │          │ background      │
│                    │           │           │        │          │ complete        │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Tesla without      │ N/A       │ N/A       │ Yes    │ N/A      │ Optional host   │
│ Android            │           │           │        │          │ fallback        │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Maintainability    │ Medium    │ Poor      │ Easy   │ Poor on  │ Hard but        │
│                    │           │           │        │ phone    │ bounded         │
├────────────────────┼───────────┼───────────┼────────┼──────────┼─────────────────┤
│ Fits Linux phone   │ Poor      │ Good      │ Good   │ Poor     │ Best balance    │
│                    │           │ sharing   │        │          │                 │
└────────────────────┴───────────┴───────────┴────────┴──────────┴─────────────────┘

\*If guest packages restored and radio is available to Android.

Stubs fail the goal because “every app” requires the real stack’s behavior, not a subset of APIs.
Exclusive fails the goal because the Linux phone must keep Bluetooth.
Full stack + BlueZ HAL is the only design that can approach both.

───

Critical subsystems (what “seamless” must implement)

1. Image / guest foundation

• Stop removing Bluetooth packages (Bluetooth, related services/modules).
• Stack must start; BluetoothManagerService must bind IBluetooth.
• Feature flags: bluetooth, bluetooth_le, etc.
• Without this, no architecture works.

2. Vendor HAL + host bridge (the invisible middle)

• Guest: standard HAL interface expected by AOSP.
• Host: long-running service (recommended: Rust + bluer, same ecosystem as bluetui).
• Transport: Unix socket into LXC (same idea as other host integrations).
• No settings panel for “bridge mode.”

3. BlueZ as single policy owner

┌───────────────────┬──────────────────────────────────────────┐
│ Concern           │ Policy                                   │
├───────────────────┼──────────────────────────────────────────┤
│ Power on/off      │ Host state is truth; guest mirrors       │
├───────────────────┼──────────────────────────────────────────┤
│ Address / privacy │ One identity from BlueZ                  │
├───────────────────┼──────────────────────────────────────────┤
│ Bonds / link keys │ Stored in BlueZ; guest uses them via HAL │
├───────────────────┼──────────────────────────────────────────┤
│ Discovery         │ Refcounted sessions (host UI + Android)  │
├───────────────────┼──────────────────────────────────────────┤
│ Connections       │ Multiplexed under BlueZ limits           │
└───────────────────┴──────────────────────────────────────────┘

4. Profiles — LE vs classic audio (honest split toward 100%)

┌────────────────────────┬─────────────────────────────────────────────────────────┐
│ Profile class          │ Path to “flawless”                                      │
├────────────────────────┼─────────────────────────────────────────────────────────┤
│ BLE central/GATT/      │ Stack + HAL → BlueZ LE — core path                      │
│ notify                 │                                                         │
├────────────────────────┼─────────────────────────────────────────────────────────┤
│ Background LE /        │ Real stack features + correct permissions               │
│ Companion              │                                                         │
├────────────────────────┼─────────────────────────────────────────────────────────┤
│ Pairing / bonding      │ Through BlueZ agent; host + guest consistent            │
├────────────────────────┼─────────────────────────────────────────────────────────┤
│ A2DP / HFP headphones  │ Hardest: Android audio path vs PipeWire both wanting    │
│                        │ the headset                                             │
├────────────────────────┼─────────────────────────────────────────────────────────┤
│ HID keyboards/mice     │ BlueZ; optional hidraw only if required                 │
└────────────────────────┴─────────────────────────────────────────────────────────┘

Headphones “flawlessly” on Android while Linux also uses the same headphones for media is a dual-stack audio problem, not only a radio problem. Options:

1. Android media/call audio routed so A2DP/HFP are implemented by host PipeWire (Android thinks it has A2DP; host actually streams) — seamless if done well.
2. Host-only audio BT, Android-only LE — simpler, not 100% for “pair headphones in Android.”
3. Android owns A2DP exclusively when an Android app connects — breaks seamless host audio.

For true 100%, plan for (1): profile logic coordinated so the user never picks a stack; the system picks a single audio owner per device.

5. Tesla Phone Key class of apps

Needs at minimum:

• LE scan (including background)
• GATT connect + specific service/characteristics
• Stable identity / keys as the app expects
• Possibly OEM extras (some setups: UWB — out of band for BlueZ)

With a full stack + working LE HAL, the Android Tesla app is in scope.
UWB is a separate subsystem; “100% Phone Key on every car/phone combo” may require more than Bluetooth.

Host vehicle-command remains a valid fallback, not the seamless Android story.

───

Implementation strategy (maximize chance of success)

Phase 0 — Host baseline

• BlueZ healthy under Phosh; bluetui works.
• Prove multi-client: two host processes scanning/GATT without killing each other.

Phase 1 — Guest stack boots

• Custom image with Bluetooth packages restored.
• HAL can be stubbed “off” first; goal is services up, Settings not permanently broken.

Phase 2 — LE parity

• HAL + host bridge: scan, connect, GATT R/W/notify, bonding.
• Unmodified LE apps and a simple GATT test app.
• Tesla Android app becomes a realistic target.

Phase 3 — Classic pairing + non-audio profiles

• Pairing UX aligned with host agent.
• HID/SPP as needed.

Phase 4 — Audio profiles (headphones)

• Design Android A2DP/HFP → host PipeWire (or documented single-owner policy).
• This phase decides whether “pair headphones in Android” is truly flawless and host media still works.

Phase 5 — Background, multi-app, power

• Background scan, multi-connection, Doze, battery.
• Kill Waydroid → host BT unaffected.
• Kill BlueZ → Android shows BT unavailable cleanly.

Parallel track (optional)

• Host Tesla presence daemon for reliability before Phase 2–3 land.

───

Language and stack choices (supporting the best approach)

┌─────────────────┬──────────────────────┬─────────────────────────────────────────┐
│ Layer           │ Choice               │ Why                                     │
├─────────────────┼──────────────────────┼─────────────────────────────────────────┤
│ Host bridge /   │ Rust + bluer         │ Official BlueZ bindings; same stack as  │
│ policy          │                      │ bluetui; good always-on daemon          │
├─────────────────┼──────────────────────┼─────────────────────────────────────────┤
│ Experiments     │ Python bleak         │ Speed only                              │
├─────────────────┼──────────────────────┼─────────────────────────────────────────┤
│ Tesla host      │ Go vehicle-command   │ Already exists                          │
│ fallback        │                      │                                         │
├─────────────────┼──────────────────────┼─────────────────────────────────────────┤
│ Guest stack     │ AOSP/Lineage BT      │ Compatibility                           │
│                 │ modules              │                                         │
├─────────────────┼──────────────────────┼─────────────────────────────────────────┤
│ Guest HAL       │ C++/Rust as AOSP     │ Must load as real HAL                   │
│                 │ vendor code expects  │                                         │
└─────────────────┴──────────────────────┴─────────────────────────────────────────┘

Flatpak: host sandboxed apps talk to org.bluez with policy; the bridge is not a Flatpak app — it is a system/user service. Phosh/bluetui stay host-native for least friction.

───

What “100% seamless” can and cannot promise

In scope if E is done thoroughly

• Unmodified apps using standard Android BT/BLE APIs
• Pairing and reconnection via BlueZ-backed identity
• Tesla-class LE phone key when the car only needs BLE
• Host tools (bluetui) and Android both using the same radio without a mode switch

Explicit risks / non-Bluetooth gaps

┌───────────────────────────────────┬──────────────────────────────────────────────┐
│ Risk                              │ Notes                                        │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ Dual A2DP/HFP                     │ Requires audio architecture work beyond      │
│                                   │ radio passthrough                            │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ UWB Phone Key                     │ Not solved by BlueZ                          │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ OEM-only APIs / Play Integrity    │ Unrelated to BT middle layer                 │
│ side effects                      │                                              │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ Aggressive concurrent scanning    │ Need policy to avoid RF and battery          │
│                                   │ disasters                                    │
├───────────────────────────────────┼──────────────────────────────────────────────┤
│ Waydroid image maintenance        │ Stack updates track Lineage/Waydroid         │
│                                   │ releases                                     │
└───────────────────────────────────┴──────────────────────────────────────────────┘

Calling the project “seamless shared Bluetooth via BlueZ-backed Android stack” is more accurate than classic “passthrough” (which usually means exclusive device assignment). Marketing can say passthrough; engineering should say shared BlueZ + full guest stack.

───

Decision matrix (short)

┌────────────────────────────────────────────────────┬─────────────────────────────┐
│ If you optimize for…                               │ Choose                      │
├────────────────────────────────────────────────────┼─────────────────────────────┤
│ Ultimate Android app compatibility + host BT +     │ E — full stack + BlueZ HAL  │
│ invisible UX                                       │                             │
├────────────────────────────────────────────────────┼─────────────────────────────┤
│ Fastest Tesla unlock on Linux only                 │ C — host vehicle-command /  │
│                                                    │ bluer                       │
├────────────────────────────────────────────────────┼─────────────────────────────┤
│ Quick LE demo in one app                           │ B — stubs (throwaway)       │
├────────────────────────────────────────────────────┼─────────────────────────────┤
│ Desktop second dongle                              │ A or D                      │
├────────────────────────────────────────────────────┼─────────────────────────────┤
│ “Passthrough” meaning steal the radio              │ A (reject for phone)        │
└────────────────────────────────────────────────────┴─────────────────────────────┘

───

Bottom line

┌──────────────────────┬───────────────────────────────────────────────────────────┐
│ Question             │ Answer                                                    │
├──────────────────────┼───────────────────────────────────────────────────────────┤
│ Best approach?       │ Full Android Bluetooth stack in Waydroid + invisible host │
│                      │ HAL/bridge to BlueZ; BlueZ sole radio owner               │
├──────────────────────┼───────────────────────────────────────────────────────────┤
│ Why?                 │ Only this combines real app API compatibility with shared │
│                      │ host Bluetooth and no user-facing mode switch             │
├──────────────────────┼───────────────────────────────────────────────────────────┤
│ Why not stubs?       │ Incomplete forever; fails “every app”                     │
├──────────────────────┼───────────────────────────────────────────────────────────┤
│ Why not exclusive    │ Breaks Linux phone Bluetooth                              │
│ passthrough?         │                                                           │
├──────────────────────┼───────────────────────────────────────────────────────────┤
│ Headphones + Tesla   │ LE/Tesla path is stack+HAL; headphones need extra audio-  │
│ both flawless?       │ profile integration with PipeWire for true dual-OS        │
│                      │ seamless audio                                            │
├──────────────────────┼───────────────────────────────────────────────────────────┤
│ Language for the     │ Rust + bluer on host; real AOSP stack + vendor HAL in     │
│ middle?              │ guest                                                     │
├──────────────────────┼───────────────────────────────────────────────────────────┤
│ Reality check        │ Not implemented upstream today; this is the architecture  │
│                      │ that can approach the 100% goal                           │
└──────────────────────┴───────────────────────────────────────────────────────────┘

In one line: don’t pass the device through — pass the capability through: Android runs a real Bluetooth stack; Linux BlueZ remains the invisible radio and policy layer so both worlds, and eventually every well-behaved Android BT app, can just work.
