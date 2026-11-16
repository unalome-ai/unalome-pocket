# App Privacy answers (App Store Connect → App Privacy)

## Data collection

**"Do you or your third-party partners collect data from this app?"** → **No**

Result shown on the store: **Data Not Collected**.

## Why "No" is correct

Apple defines "collect" as transmitting data off the device in a way that lets you or a
partner access it for longer than the request needs.

| What the app does | Collected? |
|---|---|
| Stores chats, images and personas on the device | No, never transmitted |
| On-device speech recognition | No, never transmitted |
| Downloads model files from Hugging Face | No. Only a file request; no user data or identifier is sent by the app |
| "Report this response" email | No. Apple excludes data the user sends themselves in a free-form email outside the app |
| Analytics, ads, crash SDKs | None in the app |

## Tracking

**"Do you use data for tracking?"** → **No**

## Must stay true

The label is a legal statement. Change it before shipping any update that adds
analytics, crash reporting, an account, a remote service, or a network call that sends
anything other than a model file request.

The privacy manifest in the build (`App/PrivacyInfo.xcprivacy`) matches this: no
tracking, no collected data types, and two required-reason APIs (user defaults, disk space).
