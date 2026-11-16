# Screenshots

Status: **captured.** 18 images, 6 per set, in `screenshots/`, at the exact sizes below,
PNG without transparency. They are plain app screens without captions, which App Store
Connect accepts as they are. The captions in the shot list are optional; add them later
if you want marketing-style images.

## Required sets

| Set | Size in pixels | Device to capture on | Required |
|---|---|---|---|
| iPhone 6.9" (`iphone-6.9/`) | 1320 × 2868 | iPhone Pro Max simulator | Yes |
| iPad 13" (`ipad-13/`) | 2064 × 2752 | iPad Pro 13" simulator | Yes, because the app runs on iPad |
| Mac (`mac/`) | 2880 × 1800 | The Mac app, window at 1440 × 900 points | Yes, for the macOS listing |

Apple scales the 6.9" set down for smaller iPhones, so no other iPhone size is needed.
Up to 10 per set; this plan uses 6. Confirm the sizes on the upload page; Apple shows
the accepted dimensions next to each slot.

## Shot list (same order in every set)

| # | Screen | Caption on the image |
|---|---|---|
| 1 | Chat with a streamed answer and the "On device" status pill | Your AI. In your pocket. |
| 2 | Onboarding "private by design" | Nothing leaves this device. |
| 3 | Models list with capability pills and the device recommendation | Models that fit your device. |
| 4 | Chat with a photo and the model's description | Ask about what you see. |
| 5 | Thinking mode expanded, with a code block or table in the answer | Thinks before it answers. |
| 6 | iPhone: Models list with a download in progress. iPad and Mac: sidebar with conversations | Always one tap away. |

## Rules these follow

- Real app screens with believable content; no mock features.
- No vendor logos. Model names appear only as text inside the app's own interface.
- The first three shots carry the message, since they show in search results.
- Captions use the app's typeface (Inter) on the app's dark background.
- Status bar: 9:41, full battery, full signal.

## How they were captured

A debug-only screenshot mode (launch argument `-UnalomeScreenshotMode YES`) fills the app
with sample conversations and replays prepared answers under the name of a catalog model.
It is compiled out of Release builds. The photo in shot 4 is drawn in code, so it has no
copyright. The answers shown are written by hand, not produced by the model; the screens
themselves are the real app.

## Known imperfections

- The Models shots show the simulator host's free storage (about 596 GB) and the model
  recommended for that machine.
- On Mac the selected sidebar row uses the system accent colour (green in these shots),
  not the app's emerald.
- Widgets and the Dynamic Island are not shown; they cannot be captured in the simulator.
