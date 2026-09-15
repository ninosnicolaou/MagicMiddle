# Magic Middle

A tiny macOS menu-bar app that turns a physical click while your finger is in the center area of an Apple Magic Mouse into a real middle click.

## Vibe Coded!

## Features

- Magic Mouse only.
- Physical center click -> middle click.
- Normal clicks outside the center remain normal.
- Adjustable center sensitivity: Very Narrow, Narrow, Default, Wide, Very Wide.
- Optional menu-bar icon.
- No network access and no account/subscription.
- **Builds with Apple's Command Line Tools; full Xcode is not required.**

## Build

Requires macOS and Apple's Command Line Tools.

```bash
xcode-select --install
chmod +x build.sh
./build.sh
```

The build does **not** use `actool` or an Xcode project. The app icon is already bundled as an ICNS file.

The app is created at:

```text
build/Magic Middle.app
```

Install:

```bash
cp -R "build/Magic Middle.app" /Applications/
open "/Applications/Magic Middle.app"
```

## Accessibility permission

Open **System Settings -> Privacy & Security -> Accessibility** and enable **Magic Middle**. Relaunch the app after granting permission if necessary.

If macOS says the app cannot be opened because it is from an unidentified developer, right-click the app in Applications and choose **Open**. If needed:

```bash
xattr -cr "/Applications/Magic Middle.app"
```

## Center sensitivity

Open the menu-bar icon and choose **Center Sensitivity**.

- **1 — Very Narrow:** smallest center area.
- **2 — Narrow**
- **3 — Default:** original center area.
- **4 — Wide**
- **5 — Very Wide:** largest center area.

The choice is saved automatically and survives relaunches.

## Hiding the menu-bar icon

Choose **Hide Menu Bar Icon** from the app menu. The middle-click function continues running in the background.

To show it again, quit the app and run:

```bash
defaults write com.local.MagicMiddle ShowMenuBarIcon -bool true
open "/Applications/Magic Middle.app"
```

## Notes

The app uses Apple's private `MultitouchSupport.framework` because macOS does not provide a public API for Magic Mouse touch coordinates. The framework is loaded dynamically so the app can fail gracefully if Apple changes it.
