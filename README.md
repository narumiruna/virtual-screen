# Display Loom

A macOS menu bar app that creates multiple system-recognized virtual displays at up to 8K and 60 Hz.

> [!WARNING]
> This app uses the private CoreGraphics `CGVirtualDisplay` API, cannot be distributed through the Mac App Store, and may require updates after future macOS releases.

## Requirements

- macOS 13.2 or later.
- Intel or Apple Silicon Mac.
- Xcode 15 or later.

## Run

Install [just](https://github.com/casey/just), then run:

```sh
just run
```

Alternatively, open `DisplayLoom.xcodeproj` and run the `DisplayLoom` scheme.
The app appears only in the menu bar.
Use its display icon to add, connect, rename, resize, mirror, disconnect, or remove virtual displays.

## Mirroring

Open a connected virtual display in the menu and choose **Mirror Display** to mirror an online built-in or external display. Choose **Do Not Mirror** to return it to an extended desktop.

Display Loom remembers the selected source and restores mirroring after reconnecting the virtual display, relaunching the app, waking the Mac, or reconnecting the source display. While mirroring, macOS controls the compatible display mode, so the virtual display's saved resolution cannot be changed until mirroring is disabled.

## Resolutions

- **16:9:** 1280×720, 1366×768, 1600×900, 1920×1080, 2560×1440, 3200×1800, 3840×2160, 5120×2880, 7680×4320.
- **16:10:** 1280×800, 1440×900, 1680×1050, 1920×1200, 2560×1600, 2880×1800, 3840×2400, 5120×3200, 7680×4800.

All modes use native LoDPI pixels at 60 Hz.
8K and multiple high-resolution displays can consume substantial memory and GPU resources.

## Test

```sh
just test
```

Run `just test-live` only when you want the integration test to create and switch a real virtual display.

## License

[MIT](LICENSE)
