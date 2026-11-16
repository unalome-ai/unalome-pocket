# Publishing Unalome Pocket to the App Store

Everything needed to submit version 1.0.0, in the order you do it.
Text to paste is in the other files of this folder; this file says where each piece goes.

| File | What it is |
|---|---|
| `listing.md` | Name, subtitle, description, keywords, URLs, category |
| `privacy-policy.md` | The privacy policy to publish on unalome.ai |
| `app-privacy-label.md` | Answers for the "App Privacy" section |
| `age-rating.md` | Answers for the age-rating questionnaire |
| `review-notes.md` | Notes and contact details for App Review |
| `screenshots.md` | Required sizes and the shot list; images go in `screenshots/` |
| `scripts/archive.sh` | Builds the Release archive and uploads it |
| `scripts/ExportOptions.plist` | Export settings used by the script |

## Values to confirm first

These are placeholders I chose. Search this folder for each and replace it if it is wrong.

| Value | Placeholder used | Where it also appears |
|---|---|---|
| Privacy policy URL | `https://unalome.ai/pocket/privacy` | `listing.md`, the app's About screen |
| Support URL | `https://unalome.ai/pocket` | `listing.md` |
| Support email | `support@unalome.ai` | `review-notes.md`, the app's "Report" actions |
| Source code | `https://github.com/unalome-ai/unalome-pocket` | `listing.md`, the app's About screen |

GitHub names cannot contain a dot, so `unalome.ai` is not possible as an organisation name;
`unalome-ai` is assumed.

## Step 1. Apple Developer account (you)

1. Sign in at <https://developer.apple.com/account>. Membership must show as active
   (99 USD per year). A free personal team cannot publish.
2. You publish as an individual, so the App Store shows your legal name as the seller.
   No D-U-N-S number is needed.
3. Accept any pending agreements in App Store Connect under **Business**. A free app
   needs only the free-apps agreement; no bank or tax details.

## Step 2. Identifiers (you, about 5 minutes)

At <https://developer.apple.com/account/resources/identifiers>:

1. App ID `ai.unalome.pocket` with capabilities **App Groups** and
   **Increased Memory Limit**.
2. App ID `ai.unalome.pocket.widgets` with **App Groups**.
3. App Group `group.ai.unalome.pocket`, assigned to both App IDs.

Xcode's automatic signing has already created most of these for development builds.
Check that they exist; create only what is missing.

## Step 3. Publish the privacy policy (you)

Publish the text of `privacy-policy.md` at the privacy policy URL.
The URL must be live before you submit; App Review opens it.

## Step 4. Create the app record (you)

In <https://appstoreconnect.apple.com> choose **Apps → + → New App**:

| Field | Value |
|---|---|
| Platforms | iOS and macOS (one record covers iPhone, iPad and Mac) |
| Name | Unalome Pocket |
| Primary language | English (U.S.) |
| Bundle ID | ai.unalome.pocket |
| SKU | unalome-pocket |
| User access | Full access |

If the name is taken, App Store Connect says so at this step.

## Step 5. Upload the build

From the repository root:

```sh
AppStore/scripts/archive.sh ios      # iPhone and iPad
AppStore/scripts/archive.sh macos    # Mac
```

The script reads your team ID from `Config/Local.xcconfig`, archives the Release
configuration and uploads it. It needs Xcode signed in to your Apple account
(**Xcode → Settings → Accounts**). Processing takes 10 to 30 minutes; the build then
appears under **TestFlight**.

Raise the build number in `project.yml` (`CURRENT_PROJECT_VERSION`) before every new upload.

## Step 6. TestFlight (recommended before submitting)

1. Under **TestFlight → Internal Testing**, create a group and add yourself.
2. Install through the TestFlight app on a second device if you have one.
3. Run the checks in "Before you press Submit" below.

## Step 7. Fill in the listing

On the version page (**1.0 Prepare for Submission**), for iOS and again for macOS:

1. Screenshots from `screenshots/` (see `screenshots.md`).
2. Promotional text, description, keywords, support URL, marketing URL from `listing.md`.
3. Build: select the uploaded build.
4. Copyright from `listing.md`.
5. App Review Information: contact details and notes from `review-notes.md`.
   Sign-in required: **No**.

Under **App Information**: subtitle, category and privacy policy URL from `listing.md`;
content rights: "does not contain third-party content"; age rating from `age-rating.md`.

Under **App Privacy**: answers from `app-privacy-label.md`.

Under **Pricing and Availability**: price **Free**, all countries.
Consider removing mainland China: apps offering generative AI there need a local licence.

Export compliance: the build already declares that it uses no non-exempt encryption,
so no question is asked.

## Step 8. Submit (you)

**Add for Review → Submit**. Choose "Manually release this version" if you want to pick
the launch day. First review usually takes one to three days.

## Before you press Submit

- [ ] Fresh install: onboarding, download the smallest model, first reply.
- [ ] Airplane mode: chat still works with an installed model.
- [ ] An image question with Qwen 3.5 2B on an 8 GB iPhone.
- [ ] Voice input, with permission granted and denied.
- [ ] "Report this response" opens an email draft.
- [ ] Widgets, the Control Center control and the download Live Activity.
- [ ] iPad in Split View; the Mac app.
- [ ] VoiceOver through one full chat; largest text size.
- [ ] Privacy policy and support URLs open.
- [ ] The public repository exists and contains no signing team ID.

## If the review is rejected

The usual reasons for this kind of app, and the answer to each:

| Reason | Answer |
|---|---|
| 1.2 User-generated or AI content | Point to "Report this response" on every reply and the notice under the chat |
| 2.1 App could not be tested | Review notes name the built-in model and the smallest download |
| 2.5.2 Downloaded code | Model weights are data files; nothing downloaded is executed as code |
| 5.1.1 Privacy | No account, no data collected; policy URL is live |
| 4.3 Similar apps | Open source, own design, own catalog and device-fit checks |

Reply in the Resolution Center; a new build is needed only if code changes.
