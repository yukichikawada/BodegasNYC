# App Store Connect: the listing, field by field

Everything App Store Connect asks for before the first submission, with the
text to paste. `docs/RELEASE.md` says when to do each step; this file says
what to type. Keep it in step with the app: when the name, the data the app
collects, or the permissions change, change the matching field here and in
App Store Connect.

Character limits are App Store Connect's. Counts below were checked with
`wc -m` on 2026-11-03.

## 1. New app record (App Store Connect → My Apps → +)

| Field | Value |
| --- | --- |
| Platforms | iOS |
| Name | `My Bodegas` (10 of 30). Store names are unique; a search of the US store on 2026-11-03 found "My Bodega" (La Bodega Ltd) but no "My Bodegas". App Store Connect is the only authority: if it rejects the name, fall back to `My Bodegas: NYC Corner Stores` (29). |
| Primary language | English (U.S.) |
| Bundle ID | `Yukichi.BodegasNYC` (pick from the list; it is registered with Sign in with Apple, team `3BAMVTHBKF`) |
| SKU | `bodegasnyc-ios` (never shown to users, cannot change later) |
| User access | Full Access |

Before this step, in Certificates, Identifiers & Profiles → Identifiers →
BodegasNYC → Capabilities, confirm **Sign in with Apple** is checked. It must
be, since the key `R8XB2FQA54` and the device sign-in already work, but the
record will not pass review without it.

## 2. App Information

| Field | Value |
| --- | --- |
| Subtitle | `NYC corner stores, mapped` (25 of 30) |
| Primary category | Food & Drink |
| Secondary category | Travel |
| Content rights | **Yes**, the app contains third-party content (user photos and reviews), and you have the rights or permission to use it. The privacy policy and the in-app flow make posted content public; the standard Apple EULA covers the license. |
| Age rating | Fill the questionnaire (section 3). |
| License agreement | Apple's standard EULA (leave the custom one blank). |
| Privacy Policy URL | `https://yukichikawada.github.io/BodegasNYC/privacy/` |
| Privacy Choices URL | leave blank |

## 3. Age rating questionnaire

Apple replaced the old tiers in 2025 with 4+, 9+, 13+, 16+ and 18+, and
in July 2026 added questions about user-generated content surfaced in
feeds. Answer **No** to everything except the rows below. Expect the result
to be **13+** because of user-generated content; accept it, do not override
down.

| Question | Answer | Why |
| --- | --- | --- |
| User-generated content | **Yes** | Photos, reviews, added bodegas and flags are posted by users and visible to everyone. |
| Does the app show user-generated content in a feed or recommend it | **No** (if asked) | Content is attached to a place on a map and to that place's detail screen; there is no feed and no ranking of people. |
| Does the app let users share their location with others | **No** | The nearby query sends coordinates to the server and does not store them; Streets Walked history stays on the device. |
| Messaging, chat, user profiles | **No** | There is no messaging and no public profile. |
| Gambling, contests | **No** | "Lotto" is a data point about the store, not a feature. |
| Alcohol, tobacco | **No** (reference only) | "Beer" and "Cigarettes" are yes/no facts about a store, with no sale, promotion or imagery. If the questionnaire offers "infrequent/mild references", pick that over "none". |
| Unrestricted web access, medical, violence, horror, mature themes, parental controls | **No** | |

Guideline 1.2 (user-generated content) is what App Review checks against
this answer. The app has: a report path (Flag an Issue on every bodega,
review and photo, `BodegasNYC/Views/FlagIssueView.swift`), automatic
filtering (three flags hide the item, `trg_flags_auto_hide`), and published
contact information (the privacy page lists the owner's email). The one
1.2 item it does **not** have is a way for a user to block another user. A
reviewer may or may not ask for it; if they do, the answer is a "hide
everything from this author" toggle, tracked as a follow-up when it comes.

## 4. Pricing and Availability

| Field | Value |
| --- | --- |
| Price | Free (USD 0, tier "Free") |
| Availability | All countries and regions. The data is NYC-only, but the app is a portfolio piece and a free listing has no downside abroad. Narrow to United States only if the owner prefers. |
| Pre-order | No |
| Apple Silicon Macs, Apple Vision Pro | Both "Make this app available" boxes unchecked (iPhone-only app, untested on either; one checkbox each to turn on later). |
| Tax category | leave the default (free app, no agreements beyond the free-apps one) |

## 5. App Privacy

Source of truth: `BodegasNYC/PrivacyInfo.xcprivacy`. "Do you or your
third-party partners collect data from this app?" → **Yes**. Then one row
per data type. For every type: tracking **No**. "Linked" means linked to
the user's identity.

| App Store Connect category → type | Collected | Linked | Purposes |
| --- | --- | --- | --- |
| Location → Precise Location | Yes | No | App Functionality |
| Contact Info → Email Address | Yes | Yes | App Functionality |
| Identifiers → User ID | Yes | Yes | App Functionality |
| User Content → Photos or Videos | Yes | Yes | App Functionality |
| User Content → Other User Content | Yes | Yes | App Functionality |
| Diagnostics → Crash Data | Yes | Yes | App Functionality |
| Diagnostics → Performance Data | Yes | Yes | App Functionality |
| Diagnostics → Other Diagnostic Data | Yes | Yes | App Functionality |
| Usage Data → Product Interaction | Yes | Yes | Analytics |
| Usage Data → Other Usage Data | Yes | Yes | Analytics |

Everything else (Name, Phone, Contacts, Health, Financial, Browsing or Search
History, Purchases, Sensitive Info, Coarse Location, Device ID, Advertising
Data, Audio) → not collected. Tracking → **No, we do not track**. Streets
Walked and Motion data stay on the device and are not "collected" in
Apple's sense.

Diagnostics and usage are linked because a signed-in user's Sentry and
PostHog events carry their user id (#147). If the answers change, change the
manifest first, then this table, then App Store Connect.

## 6. Version 1.0 page

### Screenshots

The app is iPhone only, so App Store Connect wants one iPhone set. Upload
the **6.9" set** (1320 × 2868) and let App Store Connect scale it down; add
a 6.5" set only if the scaled frames look wrong. Source: the dark set under
`~/.gstack/projects/yukichikawada-BodegasNYC/app-store-screenshots-6.9/dark/`
(#138; owner sign-off pending), or the framed marketing versions from the
same shots once the marketing session delivers them. Order, first frame is
the one most people see:

1. `02-map-pins.png` — the map, the poster shot
2. `06-detail.png` — bodega detail, photos and the glowing pin
3. `03-filters.png` — Filters, cat on
4. `04-streets-walked.png` — the cyan trail
5. `05-your-blocks.png` — Your Blocks
6. `01-onboarding.png` — onboarding page 1

Up to ten frames; six is plenty. App preview video: skip for 1.0.

### Text

**Promotional text** (can change without a new build; 157 of 170):

> Every bodega in New York on one map, with the things a business listing never tells you: the cat, the hot food, the beer, the lotto, the ATM, the real hours.

**Description** (4000 max; this one is about 1,550):

> New York runs on bodegas, and the big map apps treat them as an afterthought: a pin, a wrong closing time, a photo of the awning. My Bodegas is a map of the city's corner stores built by the people who actually use them.
>
> FIND THE RIGHT ONE
> Every bodega carries the six things you want to know before you walk in: is there a cat, is there hot food, do they sell beer, lotto, cigarettes, and is there an ATM. Filter the map to the ones that matter right now, then tap a pin for hours, photos, a rating and reviews.
>
> ADD WHAT'S MISSING
> Drop a pin or use your location to add a bodega. The app checks for duplicates before it saves. Sign in with Apple to add photos, write a review, or flag a listing that closed or changed. Photos are resized on your phone before upload, so no camera or location metadata leaves it.
>
> STREETS WALKED
> An optional layer that records the streets you walk, including with the app in the background, and lights them up on your own map. Rides are filtered out with Motion & Fitness, so the cab home doesn't count. Your Blocks shows what share of the city, and of each borough, you've covered. The history never leaves your phone. Off by default; turn it on from the walking-figure button on the map.
>
> MADE FOR NEW YORK
> Map and list views, pins that cluster when you zoom out and label themselves at block level, directions to the door, and a map that reads at night as well as it does at noon.
>
> Browsing works without an account. No ads. Nothing is sold.
>
> Privacy policy: https://yukichikawada.github.io/BodegasNYC/privacy/

**Keywords** (100 max, comma-separated, no spaces after commas; do not
repeat words already in the name or subtitle; 97 of 100):

```
bodega,deli,new york,manhattan,brooklyn,queens,bronx,cat,hot food,beer,lotto,atm,walk,streets,map
```

| Field | Value |
| --- | --- |
| Support URL | `https://yukichikawada.github.io/BodegasNYC/` (live; lists the privacy page, the source and the PRD; add the contact email there if App Review asks for it on the support page itself) |
| Marketing URL | `https://github.com/yukichikawada/BodegasNYC` (optional) |
| Version | `1.0.0` (must match `MARKETING_VERSION`; the record was created as `1.0` on 2026-11-03 and is renamed to `1.0.0` before submission, an editable field while the version is unreleased) |
| Copyright | `2026 Yukichi Kawada` |
| Routing app coverage file | none |
| Build | attach after the first upload (#139) |
| Version release | Manually release this version (so the owner picks the day) |

### App Review Information

| Field | Value |
| --- | --- |
| Sign-in required | **Off**. Browsing works signed out; contributing uses Sign in with Apple, which works on the reviewer's device with their own Apple Account. |
| Demo account | none (the email/password sign-in is `#if DEBUG` and absent from the Release build) |
| Contact first/last name, phone, email | the owner's; App Review calls the number if a question needs an answer today. The phone number is required: without it App Store Connect drops the whole block (notes, contact, sign-in toggle) on Save and shows no error (the API returns 409 `contactPhone` required). |
| Attachment | none |

**Notes** (paste as one block):

> Browsing the map and list works without signing in. Adding bodegas, photos, reviews and flags uses Sign in with Apple only, so no demo account is needed; your own Apple Account works.
>
> Location: finding nearby bodegas uses When-In-Use location only. "Streets Walked" is an optional feature, off by default, started from its own button in the app (the walking figure in the map's top bar). It records the streets the user walks so they can see them highlighted on their own map, and it is the only thing that asks for Always location and uses the background `location` mode. The walk history stays on the device and is never uploaded. To try it: on the map, tap the walking-figure button → Start Recording, grant Always, walk or simulate a route (Features → Location → Freeway Drive on a simulator), then reopen the app. Motion & Fitness is used only to tell walking from riding.
>
> User-generated content: every bodega, review and photo has a "Flag an Issue" action. Three flags hide the item automatically, and the owner reviews flags. The privacy policy (linked in the app's Account menu and in the listing) carries the contact email. Account deletion is in the app: Account → Your Account → Delete Account. It removes the account, its data and the Sign in with Apple grant.
>
> Analytics: crash reports (Sentry) and product analytics (PostHog) are on by default and can be turned off in the Account menu under Share Usage and Diagnostics. Neither is used for tracking or advertising.

## 7. Agreements and regulations

Digital Services Act: App Store Connect shows a banner until the account's
trader status is provided (App Information → App Store Regulations & Permits →
Digital Services Act → Set Up; non-trader is the answer for a free app with no
business behind it). Without it Apple can remove the app from the EU store,
which matters because availability is all countries.


Free app: the Apple Developer Program License Agreement and the free-apps
schedule must be accepted under Business → Agreements. No banking or tax
forms until the app charges money.

## Status

Filled in and verified on 2026-11-03 (app id 6830464647): sections 1 to 6,
including the published App Privacy answers and the App Review block. Open:
screenshots, attaching the build, the Digital Services Act setup, Submit.

## How it was filled

App Store Connect has no API for creating the app record, the App Privacy
answers or the age rating, so the record is created by hand. Two ways to do
the rest:

- **By hand**, from this file, in one sitting (about 30 minutes).
- **Assisted**: sign in to App Store Connect in Chrome and let the Claude
  Code session drive the browser from this file, confirming each page before
  it saves. Or create an App Store Connect API key (Users and Access → Keys,
  role App Manager), store the `.p8` under `~/.config/bodegasnyc/`, and
  version metadata and screenshots can be pushed through the API; the record,
  privacy answers and age rating still need the browser.

Then #136 (the icon) and #139 (archive, TestFlight, submit) close out the
launch.
