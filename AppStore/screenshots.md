# Screenshots

Status: **not captured yet.** They are taken after the iPad, Mac and accessibility work
is finished, so they show the final screens. Images go in `screenshots/<set>/`.

## Required sets

| Set | Size in pixels | Device to capture on | Required |
|---|---|---|---|
| iPhone 6.9" | 1320 × 2868 | iPhone 17 Pro Max simulator | Yes |
| iPad 13" | 2064 × 2752 | iPad Pro 13" simulator | Yes, because the app runs on iPad |
| Mac | 2880 × 1800 | The Mac app, window at 1440 × 900 points | Yes, for the macOS listing |

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
| 6 | iPhone: widgets and Dynamic Island download. iPad and Mac: sidebar with conversations | Always one tap away. |

## Rules these follow

- Real app screens with believable content; no mock features.
- No vendor logos. Model names appear only as text inside the app's own interface.
- The first three shots carry the message, since they show in search results.
- Captions use the app's typeface (Inter) on the app's dark background.
- Status bar: 9:41, full battery, full signal.

## How they are captured

Simulator builds use the scripted demo engine, so the same conversation appears in
every set. Shots that need a real model (4 and 5) are captured on the iPhone and the
Mac with a real reply, then framed to the required size.
