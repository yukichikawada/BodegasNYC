---
# gstack: design-md-format=spec
name: BodegasNYC
description: Signage on the system shell. The map is the poster, the chrome is quiet native iOS, and the only loud things are red and orange pins and a heavy condensed title.
colors:
  primary: "#0A7A43"          # tint, "Deli Green"; dark #34C77B. Controls only, never data or status
  on-primary: "#FFFFFF"       # dark #000000
  surface: "#FFFFFF"          # systemBackground; dark #000000
  surface-grouped: "#F2F2F7"  # secondarySystemBackground / grouped; dark #1C1C1E
  text: "#000000"             # label; dark #FFFFFF
  text-muted: "#8A8A8E"       # secondaryLabel flattened on white; dark #8D8D93
  text-tertiary: "#C4C4C6"    # tertiaryLabel flattened; dark #48484A
  separator: "#C6C6C8"        # separator; dark #38383A
  accent: "#FF3B30"           # pin, systemRed asset color; dark #FF453A. Bodega pins and the mappin symbol
  accent-cat: "#FF9500"       # catPin, systemOrange asset color; dark #FF9F0A. Cat symbol everywhere, cat pins
  star: "#FFCC00"             # systemYellow; dark #FFD60A. Rating stars only
  cluster: "#8E8E93"          # systemGray. Cluster badge fill
  error: "#FF3B30"            # systemRed as text only (form errors, destructive actions); dark #FF453A
typography:
  display:
    fontFamily: SF Pro
    fontWeight: 800            # .heavy
    fontWidth: condensed       # Font.Width.condensed
    fontSize: 34pt             # .largeTitle text style; Dynamic Type scales it
    letterSpacing: 0
  display-detail:
    fontFamily: SF Pro
    fontWeight: 800
    fontWidth: condensed
    fontSize: 28pt             # .title text style
  headline:
    fontFamily: SF Pro
    fontWeight: 600
    fontSize: 17pt             # .headline
  body:
    fontFamily: SF Pro
    fontSize: 17pt             # .body
    lineHeight: 22pt
  subheadline:
    fontFamily: SF Pro
    fontSize: 15pt             # .subheadline; secondary color in nearly every use
  label:
    fontFamily: SF Pro
    fontSize: 13pt             # .footnote; .caption 12pt and .caption2 11pt below it
    letterSpacing: 0
  mono:
    fontFamily: SF Pro
    fontFeature: tnum          # .monospacedDigit() on hours, counts, ratings
rounded:
  sm: 6pt                      # pin-label capsule padding radius equivalent; small insets
  md: 12pt                     # thumbnails, inset grouped rows, sheets' inner panels
  lg: 16pt                     # the floating map card
  full: 9999pt                 # pins, cluster badge, pin label, page dots, system buttons
spacing:
  xs: 4pt                      # title to body
  sm: 8pt                      # tight groups, card above the safe area, photo gaps
  md: 12pt                     # grouping inside a card or section, between buttons
  lg: 16pt                     # page inset, card inset and padding
  xl: 24pt                     # onboarding side inset, section change
  2xl: 32pt                    # major composition break
components:
  button-primary:
    style: borderedProminent
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.full}"
  button-secondary:
    style: bordered
    textColor: "{colors.primary}"
    rounded: "{rounded.full}"
  button-destructive:
    style: plain
    textColor: "{colors.error}"
  card:
    material: regularMaterial
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
    inset: "{spacing.lg}"
    maxWidth: 480pt
  pin:
    size: 28pt
    backgroundColor: "{colors.accent}"
    backgroundColorCat: "{colors.accent-cat}"
    symbolColor: "#FFFFFF"
    stroke: 2pt white
    shadow: radius 2, y 1
    target: 44pt
  pin-selected:
    stroke: 3pt white
    shadow: radius 4, y 2
    scale: 1.15
  pin-label:
    font: "{typography.label}"
    material: regularMaterial
    rounded: "{rounded.full}"
    maxCharacters: 18
  cluster-badge:
    size: 28pt+
    backgroundColor: "{colors.cluster}"
    textColor: "#FFFFFF"
  input:
    backgroundColor: "{colors.surface-grouped}"
    rounded: 10pt
  nav-link:
    textColor: "{colors.primary}"
---

# BodegasNYC

## Overview

**Creative North Star:** Signage on the system shell. A native iOS map app whose identity lives in
its data (red and orange pins, five amenities) and its voice (dry New Yorker), not in its chrome.
The chrome is quiet, translucent where it floats, and typeset in the system face; the one
typographic flourish is a heavy condensed title that reads like awning lettering.

**Product context:** Crowdsourced map of NYC bodegas. SwiftUI, Swift 6, iOS 26, MapKit `Map`,
Supabase. Users: NYC regulars on the sidewalk (primary), explorers (secondary), portfolio
reviewers judging native craft in the first minute (tertiary). Peers: Apple Maps, Google Maps,
Citymapper, Foursquare, Beli.

**The one thing to remember:** "It knows my block better than Apple Maps does, and it talks like
a New Yorker." Every decision below serves that: the data and the words carry the brand.

**Mode per surface:**
- Persuade: onboarding (3 pages). Quiet ground, heavy condensed title, orange symbol spine.
- Operate: map, list, filters, add flow, placement bar. System controls in the tint; glass for
  controls, material for the one content card.
- Read: bodega detail, reviews, photos. Opaque page, system sections, display register on the name.
- Experience: the first add. The only authored choreography in the app.

**Reference sites:** none; competitive research declined 2026-10-20. Two independent proposals
(Codex, Claude subagent) were run against the same brief and synthesized here.

**Key characteristics:**
- The map is always on screen; everything else floats over it or slides over it.
- Only three saturated colors exist and all three are data: pin red, cat orange, star yellow.
- One tint, Deli Green, for every control. It never means data, status, or success.
- System face everywhere; one display register (heavy, condensed) on three surfaces.
- Copy is in voice (see `AppCopy`), one symbol per surface, the cat appears sparingly.

## Colors

**Strategy:** Restrained. Neutrals are the semantic system colors (`label`, `secondaryLabel`,
`systemBackground`, grouped backgrounds, `separator`), so dark mode is the system's own
hierarchy, not an inversion. Two asset-catalog colors, `pin` (systemRed) and `catPin`
(systemOrange), are the data colors and the brand; stars are `systemYellow`; cluster badges are
`systemGray`. The app tint (`AccentColor` asset) is Deli Green, #0A7A43 light and #34C77B dark.
Contrast: 5.4:1 on white, 9.6:1 on black.

**Light or dark:** both, decided by the system. The use scene is the sidewalk in daylight and the
corner at night; the map tiles already switch, so the chrome follows the system appearance.

**Rules:**
- Deli Green signals "tappable": buttons, links, toggles-on, the selected tab, text actions,
  and the icon buttons on the Liquid Glass toolbar (filter, account, add, Locate Me, walked). It
  is never used for a status ("open now", success, loading spinners) and never on a pin. The
  `AccentColor` asset carries it; toggles need an explicit `.tint(.accentColor)` on their
  `Section` because iOS switches ignore the asset. The user-location dot stays system blue
  (`.tint(.blue)` on the Map): it is status, not a control.
- Red appears in two forms that never share a surface at the same size: filled 28pt pin circles
  on the map, and plain text for form errors and destructive actions in sheets.
- Orange is the cat and only the cat (cat pins, the cat symbol in the onboarding spine, the
  first-add card, the noBodegas empty state). Yellow is stars and only stars.
- Cat and non-cat pins are distinguished by glyph (`cat` vs `figure.wave`) as well as color, so
  the red/orange pair is a redundant encoding, not the only one. Keep it that way.
- Materials (`.regularMaterial`) carry floating content (map card, pin label). On iOS 26 the
  system's Liquid Glass carries floating controls (toolbars, tab bar, map buttons) by default;
  do not apply glass to content and do not apply material to controls. Pages are opaque.

## Typography

**Face:** SF Pro, the system font, in every role. Deliberate, not default: the app is used
one-handed on a sidewalk, must scale through the accessibility Dynamic Type sizes, sits next to
MapKit's own labels, and should move like Apple built it. A bundled face would cost metrics
plumbing and read as a web app. There is no font to load.

**Display register (D5, 2026-10-20):** weight `.heavy`, width `.condensed` (`Font.Width`), on
exactly three surfaces: onboarding page titles (`.largeTitle`), the first-add card title
(`.headline`), and the bodega name in the detail header (`.title`). In SwiftUI:
`.font(.display(.largeTitle))`. The register lives only in `Font.display(_:)`
(`BodegasNYC/Views/Font+Display.swift`); never write the width chain inline. This amends DD1's
`.largeTitle.bold()`. Condensed, not compressed: compressed heavy degrades at accessibility
sizes. The register never appears in body text, list rows, the map card body, or labels.

**Scale:** Dynamic Type text styles only, never fixed point sizes except for symbol sizes
(44pt onboarding spine, 28pt card symbol column, 14pt pin glyph) and the pin label, which is
capped at `.xxLarge`. Hierarchy comes from the text style and color, not from weight alone:
title `.headline`, body `.subheadline` secondary on cards; `.subheadline` secondary + `.footnote`
tertiary on section empty states; `.title3` secondary for onboarding body.

**Numerals:** `.monospacedDigit()` on hours, counts, and the rating number so columns do not
jitter.

**Copy:** every string comes from `AppCopy` and passes `AppCopyVoiceTests`. Titles and bodies
are sentences; labels are Title Case. Symbols are exempt from the voice test.

## Layout

**Grid:** 4pt base. Page inset 16pt; card inset 16pt and padding 16pt; onboarding inset 24pt.
Grouping 12pt, title-to-body 4pt, section change 20 to 24pt, major break 32pt. Leading alignment
everywhere; nothing is centered except the system `ContentUnavailableView` on the list tab and
the page dots.

**Widths:** floating overlays `maxWidth: 480pt` centered (iPad, landscape); onboarding content
`maxWidth: 560pt`, top-aligned at 25% of the height.

**Density:** medium on the map (one floating object at a time in the bottom slot; precedence
placement bar > first-add card > empty state > add tip > streets banner), comfortable on
onboarding and detail. The map is never replaced by a results screen; list and detail sit over
it (#23 transitions will formalize how).

**Touch:** 44pt minimum for every target, including the pin's hit area and the card's close.

## Elevation & Depth

Three layers: the map (opaque), floating content on `.regularMaterial`, floating controls on
system Liquid Glass. Shadows are offset and soft: `radius 2, y 1` on pins and cluster badges,
`radius 4, y 2` on the selected pin. Pin labels and the card rely on material contrast plus the
same small shadow. No zero-offset glows, no borders as depth. Sheets use system presentation;
the sign-in sheet from the add flow is `.medium` detent on `.regularMaterial`.

## Shapes

Radius hierarchy: 16pt for the floating card; 12pt for photo thumbnails and inset panels;
capsule for pins, cluster badges, pin labels, page dots, and system buttons (iOS 26 default
shape; do not override it). Nested radius = outer radius minus the gap. No pills as labels; a
capsule is a control or a pin label, never a tag.

## Components

**Map bottom card** (`MapBottomCard`, DD13): 16pt inset, `.regularMaterial` in a 16pt rounded
rectangle, 16pt padding, 8pt above the safe area, max 480pt. Grid: 28pt symbol column
(`.title2`; `.catPin` for cat, `.secondary` otherwise), title `.headline`, body `.subheadline`
secondary (`.lineLimit(4)`, `.minimumScaleFactor(0.85)`), trailing `xmark.circle.fill` close with
a 44pt target, `.bordered` action row below the text. Stacks vertically at `.accessibility1` and
up. Reading order title, body, action, close. Every content change moves from the bottom edge
with opacity over 0.25s ease-in-out. States: emptyState (noBodegas cat/catPin with bounded
breathe; noneNearby `mappin.slash`; noFilterMatches `line.3.horizontal.decrease.circle`;
loadFailed `exclamationmark.triangle`), firstAdd, addTip, streets banner, tracking error.

**Pin** (`BodegaPinView`, DD3): 28pt circle, `.pin` or `.catPin`, white 14pt glyph, 2pt white
stroke, shadow 2/1, 44pt hit area, anchored at center. Selected: 3pt stroke, shadow 4/2, scale
1.15, drawn last. Label (`.caption2`, material capsule, 18 characters, above the circle) only
when selected or dropping. Drop: spring 0.5s bounce 0.35 with success haptic; Reduce Motion:
0.2s fade in place. VoiceOver: name, "Has a cat", button trait.

**Cluster badge:** same family as the pin, `systemGray` fill, white count, same stroke and shadow.

**Onboarding page** (`OnboardingView`, DD1 + D5): opaque `systemBackground`; 44pt symbol in
`.catPin` (`cat`, `line.3.horizontal.decrease.circle`, `mappin.and.ellipse`); title in the
display register; body `.title3` secondary; `VStack(spacing: 12)`; buttons pinned in a bottom
`safeAreaInset`, full width, `.controlSize(.large)`, primary `.borderedProminent`, secondary
`.bordered`, 12pt apart; three custom 8pt dots (`.tertiary`, current `.primary`); Skip
top-trailing `.body`, pages 1 and 2. Page 3 buttons show a `ProgressView` while the root is
loading. Advance 0.3s ease-in-out; exit 0.35s (0.25s opacity-only under Reduce Motion).

**Detail header:** name in the display register (`.title`, heavy, condensed), address
`.subheadline` secondary, stars `systemYellow` with the numeric rating tabular. `RatingSummaryView`
renders nothing when there is no average; the reviews section owns the empty state.

**Section empty state** (DD9): title `.subheadline` secondary, body `.footnote` tertiary, 2pt
apart, leading, no symbol, inside the section's `VStack`. List-tab empty states use
`ContentUnavailableView` (48pt centered symbol).

**Buttons:** `.borderedProminent` for the one primary action on a surface, `.bordered` for
secondary and card actions, `.plain` red text for destructive. Disabled is the system 45%
opacity. No custom button shapes; no gradient fills.

**Forms and sheets:** system `Form`/`List` grouped style, `.navigationBarTitleDisplayMode(.inline)`,
error text `.footnote` in red inside its section. Sign-in presented from the add flow at
`.medium` detent on `.regularMaterial`.

**Tips** (`AddBodegaTip`, placement tip): `BodegaTipStyle` renders no background when inline in
the card; the card supplies the material.

## Do's and Don'ts

- Do: take every string from `AppCopy`; new copy gets a case and passes the voice test.
- Do: use Dynamic Type text styles; cap only the pin label (`.xxLarge`).
- Do: keep one floating object in the map's bottom slot; use the precedence list.
- Do: give every object with mass a spring and every content swap a 0.25s ease-in-out.
- Do: read `accessibilityReduceMotion` and degrade to fades; keep the camera pan.
- Don't: use Deli Green for anything but controls, or any color for status.
- Don't: put the display register on body, lists, card bodies, or labels.
- Don't: nest a card in a card, add a colored edge to a card, or center a title.
- Don't: apply glass to content or material to controls; don't frost whole pages.
- Don't: add emoji, illustrations, confetti, badges, or a second mascot moment; the cat is sparing.
- Don't: show a raw error string; use the voice (`emptyLoadFailedBody`) and a Retry.

## Motion

- **Approach:** intentional. Motion explains where an object came from or that it has mass.
- **Easing:** springs for objects (pin drop `spring(duration: 0.5, bounce: 0.35)`, cat entrance
  `spring(duration: 0.4, bounce: 0.3)`); `easeInOut` for content and pages (slot 0.25s, page
  advance 0.3s, onboarding exit 0.35s); `easeOut` 0.15 to 0.2s for small state flips.
- **Duration:** micro 0.15s, short 0.25s, medium 0.3 to 0.4s, long 0.5 to 0.6s (camera pans).
- **The one authored moment:** the first add. Sheet closes, camera settles, pin drops with a
  spring and a success haptic; at +0.6s the first-add card rises; if the bodega has a cat, the
  cat enters from +24pt with a spring and bounces once; the card auto-dismisses after 8s (never
  under VoiceOver). `AddCompletionCoordinator` owns the clock.
- **Reduce Motion:** pin fades in at rest (0.2s), cat appears in place, no breathe, onboarding
  exit opacity only, camera pan stays.
- **Transitions (#23, pending):** map stays on screen through map, list and detail; list and
  detail slide over it; the pin holds position before detail opens. Specify in #23's spec and
  record the timings here when they land.

## Follow-ups

- #66 (done 2026-10-20): `AccentColor` asset set to #0A7A43 / #34C77B; `Font.display` applied
  on the three surfaces; toggle sections tinted.
- Ideas from the independent proposals, filed as issues, not adopted here: #67 pin name plates at
  block zoom (reads the block like the street; conflicts with DD3's label rule and MapKit's
  stacking, see #59), and #68 distances in blocks in the voice ("Closest is 2 blocks").

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-10-19 | DD1 to DD16 visual contract (onboarding page, pin, card, colors, slot transition, Reduce Motion, VoiceOver, Dynamic Type) | `/plan-design-review` of the voice and first-run spec; owner accepted all 16 (comments on #21/#22/#24/#25) |
| 2026-10-20 | Aesthetic: signage on the system shell; system face; restrained color; map as poster | `/design-consultation`; three independent proposals converged on the shell |
| 2026-10-20 | D4 app tint = Deli Green #0A7A43 / #34C77B, never status | NYC-specific, clear of all data colors, passes contrast; system blue reads as Apple Maps |
| 2026-10-20 | D5 display register: SF Pro heavy condensed on onboarding titles, first-add card title, detail name; amends DD1 weight/width | Awning lettering natively with Dynamic Type intact; two proposals converged on it |
| 2026-10-20 | D6 onboarding keeps DD1's opaque system background | The memorable thing is the data on the map; a saturated opener sets an expectation the quiet app does not keep |
| 2026-10-20 | catPin stays systemOrange with a white glyph; stars stay yellow | Glyph already encodes cat vs non-cat; color is redundant encoding |
| 2026-10-20 | iOS 26: Liquid Glass for controls, material for floating content, opaque pages | HIG layering; text over a busy map needs a material surface |
| 2026-10-20 | #66: `.tint(.accentColor)` on the toggle sections (not the root) so switches follow the tint without tinting spinners; Map `.tint(.blue)` keeps the location dot blue | iOS switches ignore AccentColor; the tint never encodes status, and a root tint would color every ProgressView |
