# Building & installing the iOS app (no Mac required)

You don't own a Mac, so the app is compiled in the cloud by **GitHub Actions**
(which runs on Apple-hosted macOS runners). Every push builds an **unsigned
`.ipa`** that you sideload with **AltStore** or **SideStore** using a free Apple ID.

## 1. Get the IPA

1. Push this repo to GitHub (see the root `README` / the steps below).
2. Open the repo → **Actions** tab → the latest **"iOS build"** run.
3. Download the **`DeskLink-unsigned-ipa`** artifact (a `.zip`). Inside is
   `DeskLink.ipa`.

> The IPA is **unsigned**. AltStore/SideStore will (re)sign it with your own
> free Apple ID certificate at install time — that's exactly how sideloading works.

## 2. Install AltStore or SideStore

- **AltStore** (https://altstore.io) — needs the AltServer helper running on a
  PC on the same Wi-Fi to refresh the 7-day certificate.
- **SideStore** (https://sidestore.io) — refreshes on-device over your network,
  no PC needed after setup. Recommended for a PC-only household.

Follow their installer once, signing in with a free Apple ID.

## 3. Sideload DeskLink

1. In AltStore/SideStore tap **+** and pick `DeskLink.ipa`.
2. It signs and installs. The app appears on your home screen.
3. Free Apple ID certs expire after **7 days** — just refresh in the app before
   then (SideStore can auto-refresh).

## 4. First run / permissions

- Same Wi-Fi as the PC. Launch DeskLink; it auto-discovers the PC (Bonjour).
- Grant **Local Network** permission (required to find/connect to the PC).
- Grant **Microphone** permission if you want the mic→PC feature.
- Enter the 6-digit pairing code shown by the PC server.

## Capability notes for free-sideload builds

| Feature                                   | Works on free sideload? |
|-------------------------------------------|:-----------------------:|
| Wi-Fi audio playback / mic                | ✅ |
| Now Playing in Dynamic Island / Lock Screen | ✅ (`MPNowPlayingInfoCenter`) |
| ActivityKit **Live Activity** (album art in island) | ✅ (local Live Activities need no paid account / push) |
| **Remote** push updates to the Live Activity | ❌ (needs APNs / paid account — not used; we update locally) |
| Background audio                          | ✅ (`UIBackgroundModes: audio`) |

Because we never use remote push, everything DeskLink needs runs on a free Apple ID.

## Why XcodeGen?

The Xcode project is generated from `ios/project.yml` by **XcodeGen** during CI,
so there's no fragile `.xcodeproj` to hand-edit or merge. Change targets/settings
in `project.yml`.
