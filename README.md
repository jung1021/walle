# Wall-E — Stage 1: prove the build pipeline

A trivial iOS app whose only job right now is to confirm the whole no-Mac
toolchain works: **GitHub Actions compiles it → you download an unsigned IPA →
Sideloadly installs it on your iPhone.** Once this works, we add the camera,
Claude, voice, and wake word in later stages.

## What's here

| File | What it does |
|---|---|
| `project.yml` | XcodeGen spec — describes the app so CI can generate the Xcode project. No Mac needed to edit it. |
| `Sources/` | The Swift code (one screen that says "Wall-E"). |
| `.github/workflows/build.yml` | The GitHub Actions job that builds the IPA on a macOS runner. |

There is intentionally **no `.xcodeproj`** — CI generates it from `project.yml`.

## One-time setup

1. **Create a GitHub repo** and make it **Public** (public repos get free,
   unlimited macOS build minutes). Push these files to the `main` branch.
2. Edit `project.yml` and change `com.changeme` to something of your own, e.g.
   `com.logan`. Any reverse-domain string is fine; Sideloadly can override it anyway.

## Build it

1. Push to `main` (or open the repo's **Actions** tab → **Build unsigned IPA** →
   **Run workflow**).
2. Wait ~3–5 minutes for the job to finish (green check).
3. Open the finished run → scroll to **Artifacts** → download **WallE-unsigned-ipa**.
4. Unzip it — inside is `WallE.ipa`.

## Install it with Sideloadly (on your Windows PC)

1. Install **Sideloadly** (sideloadly.io) and **iTunes** (the Apple-site version,
   not the Microsoft Store version) so Sideloadly can see your iPhone.
2. Plug in your iPhone, open Sideloadly.
3. Drag `WallE.ipa` into Sideloadly, enter your Apple ID, click **Start**.
4. On the iPhone: **Settings → General → VPN & Device Management** → trust your
   Apple ID. Then launch **Wall-E**.

If you see the "Wall-E / Build pipeline online" screen, the pipeline works and
we're ready for Stage 2 (the camera).

## Notes

- **Free Apple ID:** the app stops opening after 7 days — just re-run Sideloadly
  to refresh it. A paid Apple Developer account ($99/yr) makes it last a year.
- **Never commit your Claude API key.** It will go into an in-app settings screen
  in a later stage, not into this repo.
