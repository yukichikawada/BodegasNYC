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
    font: "{typography.label}"   # .caption2, Dynamic Type capped at .xxLarge
    material: regularMaterial
    rounded: "{rounded.full}"
    maxWidth: 160pt              # text width before 6pt side padding; tail-truncated (#67)
    shadow: radius 2, y 1        # selected, held or dropping only; resting labels are flat
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
- Operate: map, list, filters, add flow, placement card. System controls in the tint; glass for
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
- Deli Green signals "tappable" in content: buttons, links, text actions, toggles-on, the
  selected tab. Icon and text buttons on Liquid Glass toolbars (filter, account, add, Locate Me,
  walked; a sheet's Cancel) take the label color, which is the iOS 26 system behavior for glass;
  do not force the tint on them. It is never used for a status ("open now", success, loading
  spinners) and never on a pin. The `AccentColor` asset carries it; toggles need an explicit
  `.tint(.accentColor)` on their `Section` because iOS switches ignore the asset, and there is no
  app-root tint because it would color every `ProgressView`. The user-location dot stays system
  blue (`.tint(.blue)` on the Map): it is status, not a control.
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
capped at `.xxLarge` (DD16, kept by #67 design D5): past that the capsule outgrows the 28pt
circle it names and block-zoom placement would hide most labels. The tradeoff is deliberate: the
List tab, whose rows wrap at every size and carry the distance, is the fully scaling way to
compare the same places. Hierarchy comes from the text style and color, not from weight alone:
title `.headline`, body `.subheadline` secondary on cards; `.subheadline` secondary + `.footnote`
tertiary on section empty states; `.title3` secondary for onboarding body.

**Numerals:** `.monospacedDigit()` on hours, counts, the rating number and a list row's distance
value so columns do not jitter (not on the detail header's distance sentence: it is prose).

**Copy:** every string comes from `AppCopy` and passes `AppCopyVoiceTests`. Titles and bodies
are sentences; labels are Title Case; values (`CopyString.Kind.value`, #68) are short data
fragments in a data position, 1 to 4 words, no period, not Title Case, never starting lowercase
("2 blocks", "Around the corner", "0.6 miles"). Symbols are exempt from the voice test.

## Layout

**Grid:** 4pt base. Page inset 16pt; card inset 16pt and padding 16pt; onboarding inset 24pt.
Grouping 12pt, title-to-body 4pt, section change 20 to 24pt, major break 32pt. Leading alignment
everywhere, except a trailing data value on a list row, which sits at the row's trailing edge when
the whole row fits on one line. Nothing is centered except the system `ContentUnavailableView` on
the list tab and the page dots.

**Widths:** floating overlays `maxWidth: 480pt` centered (iPad, landscape); onboarding content
`maxWidth: 560pt`, top-aligned at 25% of the height.

**Density:** medium on the map (one floating object at a time in the bottom slot; precedence
placement card > first-add card > empty state > add tip > streets banner), comfortable on
onboarding and detail. At block zoom the pin layer carries names (#67); the bottom-slot rule is
unchanged. The map is never replaced by a results screen; list and detail sit over
it. The List tab slides over the live map; detail zooms out of its pin.

**Touch:** 44pt minimum for every target, including the pin's hit area and the card's close.

## Elevation & Depth

Three layers: the map (opaque), floating content on `.regularMaterial`, floating controls on
system Liquid Glass. Shadows are offset and soft: `radius 2, y 1` on pins and cluster badges,
`radius 4, y 2` on the selected pin. The card relies on material contrast plus the same small
shadow. Pin labels at rest are a flat material layer; the selected, held or dropping label
carries the small shadow (#67). No zero-offset glows, no borders as depth. Sheets use system presentation;
the sign-in sheet from the add flow is `.medium` detent on `.regularMaterial`.

## Shapes

Radius hierarchy: 16pt for the floating card; 12pt for photo thumbnails and inset panels;
capsule for pins, cluster badges, pin labels, page dots, and system buttons (iOS 26 default
shape; do not override it). Nested radius = outer radius minus the gap. No pills as labels; a
capsule is a control or a pin label, never a tag.

## Components

**Map bottom card** (`MapBottomCard`, DD13): 16pt inset, `.regularMaterial` in a 16pt rounded
rectangle with the small card shadow (radius 2, y 1, under the shape), 16pt padding, 8pt above
the safe area, max 480pt. Grid: 28pt symbol column
(`.title2`; `.catPin` for cat, `.secondary` otherwise), title `.headline`, body `.subheadline`
secondary (`.lineLimit(4)`, `.minimumScaleFactor(0.85)`), trailing `xmark.circle.fill` close with
a 44pt target, `.bordered` action row below the text. Stacks vertically at `.accessibility1` and
up. Reading order title, body, action, close. Every content change moves from the bottom edge
with opacity over 0.25s ease-in-out (opacity only under Reduce Motion, #23). States: emptyState (noBodegas cat/catPin with bounded
breathe; noneNearby `mappin.slash`; noneOnBlock `mappin.slash`, the nearby empty card at block zoom,
"Nothing on this block yet." / "Pinch out and look around. Or add the one on your corner." with
Add a Bodega (#84; above block zoom noneNearby keeps "Nothing near you yet."); noFilterMatches `line.3.horizontal.decrease.circle`;
loadFailed `exclamationmark.triangle`), firstAdd, addTip, streets banner, tracking error.

**Pin** (`BodegaPinView`, DD3): 28pt circle, `.pin` or `.catPin`, white 14pt glyph, 2pt white
stroke, shadow 2/1, 44pt hit area, anchored at center. Selected: 3pt stroke, shadow 4/2, scale
1.15, drawn last. Label: `.caption2` `.primary` on a `.regularMaterial` capsule, one line up to
160pt of text, tail-truncated, 4pt above the circle. It shows when the pin is selected (held) or
dropping, and at block zoom on every pin whose label clears every kept label and every drawn
circle (#67). Block zoom is a visible map height (top-centre to bottom-centre of the map) of
400 m or less; labels stay until it passes 440 m, so a settle near the line never blinks them.
Placement: held and dropping labels first, always kept; then north to south, then by id; a label
that would touch another label (4pt clearance) or another pin's, cluster's or the location
dot's drawn circle is hidden, never moved. The location dot counts as drawn, a 24pt square for
the blue dot and its white ring; its translucent accuracy halo may be covered, so a user standing
on a bodega keeps its name. North-first is for pan stability, not relevance: a
pure pan never swaps which neighbour is named, so do not change it to distance from the centre.
Labels change only when the camera settles (or the map's size, the text size or the Map tab's
return); a pinch clears them and the settle brings them back; each fades 0.2s ease-out, opacity
only. During the first add only the dropping pin is labelled. A hidden label is recovered by the
tap, which holds the pin 0.25s and commits to detail. A tap on a shown label opens its pin
(MapKit hit-tests the whole annotation view, label included); where a label lies over a
neighbour's 44pt target, a tap there still opens the neighbour (checked live on #67). Labels under the glass toolbar or the bottom
card are illegible, as pins there already are. Drop: spring 0.5s bounce 0.35 with success haptic; Reduce Motion:
0.2s fade in place. VoiceOver: name, "Has a cat", button trait.

**Placement card** (`PlacementBottomBar`, #23): the bottom slot's top-precedence occupant, in the
card family. Chrome `{components.card}`: `.regularMaterial` in a `{rounded.lg}` 16pt rounded
rectangle, `{spacing.lg}` 16pt padding and side inset, `maxWidth` 480pt, `{spacing.sm}` 8pt above
the slot's 24pt attribution clearance, the card shadow. Text column: a title
`.headline` in voice (`AppCopy.placementCardTitle`), no body, no symbol column. Action row below:
Near Me and Cancel `{components.button-secondary}`, Use This Location
`{components.button-primary}`, on one row only while all three fit without wrapping (on a
402pt-wide iPhone they do not, so it stacks there too); stacked: Near Me and Cancel on one row
while they fit, Use This Location full width below; always stacked from `.xLarge` up. In
landscape at accessibility sizes the title keeps to one line (scale factor down to 0.5) so the
crosshair still fits above the card. Near Me lands at block zoom and does not follow; a second
tap re-centres (#84 design D7). It is a task panel: the material groups the task
and its buttons keep native control styling. This is the one material-under-controls exception
to the Colors rule. The placement tip is a popover on Use This Location, arrow at the bottom,
presented 0.3s after the card appears and dismissed before the card leaves. The crosshair
(`figure.wave`, red, fixed 34pt, `.largeTitle`'s default; a symbol, so it does not scale) is centred in the band the card leaves uncovered and is
hidden from VoiceOver; the card's title is the instruction.

**Cluster badge:** same family as the pin, `systemGray` fill, white count, same stroke and shadow.
Never labelled.

**Map tiles** (#67 design D1): `.standard` with Apple's commercial points of interest excluded
at every zoom, so the map's only business names are ours: store, food market, restaurant, cafe,
bakery, brewery, winery, nightlife, pharmacy, laundry, ATM, bank, gas station, EV charger, car
rental, hotel, fitness center, movie theater, theater, marina, spa, beauty, automotive repair,
music venue (`BodegaMapViewModel.excludedPOICategories`). Businesses Apple leaves unclassified
still show; no category can hide them. Wayfinding stays: public transport, parks,
schools, universities, hospitals, libraries, museums, landmarks, airports, stadiums, national
parks, beaches, zoos, aquariums, amusement parks, fire stations, police, post offices, restrooms.
Pin labels are placed clear of the location dot itself (24pt) at each settle; the dot may drift
under a label between settles, and its accuracy halo may sit under a label.

**Onboarding page** (`OnboardingView`, DD1 + D5): opaque `systemBackground`; 44pt symbol in
`.catPin` (`cat`, `line.3.horizontal.decrease.circle`, `mappin.and.ellipse`); title in the
display register; body `.title3` secondary; `VStack(spacing: 12)`; buttons pinned in a bottom
`safeAreaInset`, full width, `.controlSize(.large)`, primary `.borderedProminent`, secondary
`.bordered`, 12pt apart; three custom 8pt dots (`.tertiary`, current `.primary`); Skip
top-trailing `.body`, pages 1 and 2. Page 3 buttons show a `ProgressView` while the root is
loading. Advance 0.3s ease-in-out; exit 0.35s (0.25s opacity-only under Reduce Motion).

**Detail header:** name in the display register (`.title`, heavy, condensed), address
`.subheadline` secondary, stars `systemYellow` with the numeric rating tabular. `RatingSummaryView`
renders nothing when there is no average; the reviews section owns the empty state. Third line
(#68): the distance as a sentence, `AppCopy.distanceFromYou` ("2 blocks from you."),
`.subheadline` secondary, no monospaced digits, 4pt under the address (under the name when there
is no address); its own VoiceOver element, not a header. While location is authorized with full accuracy the line is
reserved as an empty line and the sentence fades in over it (0.2s `easeOut`, opacity only), so
the sections below never shift.

**List row** (`BodegaRow`, #68): name `.headline`, address `.subheadline` secondary, both wrapping
at every size and never truncating. The distance (`AppCopy.distanceValue`, `.value` kind) is
`.subheadline` secondary with monospaced digits, trailing the name on its first baseline with at
least 8pt between, one line, while the whole row fits on one line; otherwise, and always from
`.accessibility1` up, it is a third leading line under the address and may wrap (the `ReviewRow`
idiom). While location is authorized with full accuracy (Precise Location on) the slot is reserved (a hidden placeholder as wide as the
widest value, "Around the corner" or "2,450 miles", side by side, an empty line stacked) and the value fades in
and out over it with a 0.2s opacity-only `easeOut` (`BrowseMotion.Distance.appearSeconds`); a
value that changes is not animated. Not authorized: no slot, and the row is name over address.
VoiceOver reads one element, "Name, address, 2 blocks from you." The #20 duplicate sheet uses the
same row with no distance. The distance is straight-line from the location fix to the pin, a folk
estimate like every map app's list distance, not blocks walked; a block is a street block at 20 to
the mile. No permission, a coarse or expired fix and Precise Location off are silent states: no
hint, no footer, no spinner, no red; with Precise Location off no slot is reserved either. The one
visible addition is the one-time Distances tip inline at the top of the loaded list, shown only
while location has never been asked for (Show Map; never prompts). Denied users get no tip and no
Settings nudge.

**Section empty state** (DD9): title `.subheadline` secondary, body `.footnote` tertiary, 2pt
apart, leading, no symbol, inside the section's `VStack`. List-tab empty states use
`ContentUnavailableView` (48pt centered symbol).

**Buttons:** `.borderedProminent` for the one primary action on a surface, `.bordered` for
secondary and card actions, `.plain` red text for destructive. Disabled is the system 45%
opacity. No custom button shapes; no gradient fills.

**Forms and sheets:** system `Form`/`List` grouped style, `.navigationBarTitleDisplayMode(.inline)`,
error text `.footnote` in red inside its section. Sign-in presented from the add flow at
`.medium` detent on `.regularMaterial`.

**Tips** (`AddBodegaTip`, placement tip, `DistancesTip` first in the loaded list, #68): `BodegaTipStyle` renders no background when inline in
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
- **Duration:** micro 0.15s, short 0.25s, medium 0.3 to 0.4s, long 0.5 to 0.6s (camera pans);
  camera flights over three zoom levels 0.9s.
- **Locate Me (#84):** a precise fix (100 m or better) flies the camera to block zoom,
  `locateMeCameraDistance` 850 m, about 350 m of visible height (measured
  350.2 m on the iPhone 17 Pro simulator), heading kept, pitch levelled, `easeInOut`
  0.9s when the flight zooms in more than three levels (a ratio of 8) or moves more than 2 km,
  0.6s otherwise. A precise fix kept from the last 60s lands at once; otherwise the toolbar
  symbol pulses while the fix is awaited (no spinner). The landing is one-shot: the camera does not follow the user afterwards and a
  second tap re-centres (probe P1: handing over to `.userLocation` at the landing's settle made
  MapKit re-zoom to its own follow distance, 2,425 m of visible height, so the handover was
  dropped and the toolbar symbol has no follow state). Without a precise fix, Locate
  Me lands where MapKit lands it, at its zoom, with the accuracy halo; no hint. A fix older than
  10 minutes never lands block zoom. A result that comes back after a pan (the centre moved over
  20 m; rotation and layout settles do not count), a newer tap, the List tab, a pushed detail or a
  change of placement is dropped, and the pulse stops. Ignored during the first add's drop and
  card. The `.nearby` radius keeps its 200 m floor, so an empty block shows noneOnBlock; the
  nearby fetch waits for the landing's settle, so the bottom card changes once.
- **The one authored moment:** the first add. Sheet closes, camera settles, pin drops with a
  spring and a success haptic; at +0.6s the first-add card rises; if the bodega has a cat, the
  cat enters from +24pt with a spring and bounces once; the card auto-dismisses after 8s (never
  under VoiceOver). `AddCompletionCoordinator` owns the clock.
- **Reduce Motion:** pin fades in at rest (0.2s), cat appears in place, no breathe, onboarding
  exit opacity only, camera pan stays. Bottom slot fades in place (map card and placement card,
  0.25s), held pin keeps its stroke and label without the scale, crosshair fades in (0.2s), list
  fades (0.25s; also under Prefer Cross-Fade Transitions).
- **Transitions (#23):** the map stays mounted through map, list and detail; it is never rebuilt
  on a tab switch. Values live in `BrowseMotion`.
  - List: the page slides up from the bottom over the live map, 0.3s ease-in-out, move only (no
    opacity: the page is opaque, so the map never ghosts through it); 0.25s fade under Reduce
    Motion or Prefer Cross-Fade Transitions. The list is a page, not a sheet: it leaves by the
    Map/List control, no drag to dismiss. Locate Me and Streets Walked leave the toolbar on the
    List tab without animation.
  - Placement: the crosshair lands with the pin's spring (0.5s, bounce 0.35, from 0.6 scale) and
    the card enters through the bottom slot (move with opacity, 0.25s ease-in-out); the tip
    appears at +0.3s. Leaving: tip dismissed, card leaves through the slot, crosshair fades 0.15s.
    From the List tab the page leaves first (its own duration), then placement starts.
  - Pin to detail (measured on the iPhone 17 Pro simulator, iOS 26): the tapped pin takes its
    selected look (0.15s `easeOut`) and rests 0.10s: hold 0.25s, then the detail is pushed with
    the system zoom from the pin (about 0.5s); a list row keeps the standard push. Back or a
    completed swipe shrinks the detail into the pin (zoom pop about 0.3s, median of three
    back-button recordings); the pin releases 0.1s after the pop, `releaseSeconds = 0.4` (pop +
    0.1s, rounded to 0.05s). The detail's spinner waits 0.5s, so the page grows out of the pin
    with its content. Under Reduce Motion the system zoom becomes a crossfade.
  - No haptic on pin tap; the first add keeps the app's one haptic.

## Follow-ups

- #66 (done 2026-10-20): `AccentColor` asset set to #0A7A43 / #34C77B; `Font.display` applied
  on the three surfaces; toggle sections tinted.
- Ideas from the independent proposals, filed as issues: #67 names at block zoom (adopted
  2026-10-21 as DD3 capsule labels, not the proposed name plates; see the Decisions Log), and #68
  distances in blocks in the voice ("Closest is 2 blocks"; list rows
  and the detail header adopted 2026-10-21, the map result line is still an idea).

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
| 2026-10-20 | #66: `.tint(.accentColor)` on the toggle sections, no root tint; glass toolbar buttons keep the label color; Map `.tint(.blue)` keeps the location dot blue | iOS switches ignore AccentColor; a root tint colored every ProgressView, and label-colored glass buttons are the iOS 26 default and keep the chrome quiet |
| 2026-10-20 | #23 T2: the List tab is an opaque page that slides up over an always-mounted map (0.3s, move only; 0.25s fade under Reduce Motion or Prefer Cross-Fade); a page, not a sheet | PRD §8: the map never goes away; the camera and tiles are identical on return, and an opaque page never ghosts the map |
| 2026-10-20 | #23 T3: the placement bar becomes a floating card in the bottom slot (card chrome, title in voice, Cancel bordered), the crosshair centred in the uncovered band | A safe-area inset moved every pin on entry and exit; a strip cannot clear the attribution row; the card family already owns the slot |
| 2026-10-20 | #23 design review: pin hold 0.25s, no tap haptic, slot and crosshair fade under Reduce Motion, list leaves before placement arrives, the one material-under-controls exception for the placement card | Design review 2A to 18A, owner accepted all; the placement card is a task panel, so its buttons stay native controls on material |
| 2026-10-20 | #23: every bottom-slot card (map card, first-add card, placement card) carries the radius 2 / y 1 shadow from `MapBottomCardChrome` | Elevation already specified it; the #58 cards shipped without it |
| 2026-10-21 | #68 spec D1 to D4: distance on list rows and the detail header; a block is a street block at 20 to the mile, rounded to the nearest whole block, "Around the corner" when it rounds to zero; position read only when When-In-Use is already granted, never prompted from the list or detail; a fourth copy kind, `.value`, and a full sentence in the header | New Yorkers measure in blocks; the voice goes into the numbers on the two Read surfaces that already exist, with no new map chrome |
| 2026-10-21 | #68 eng D5 to D12: tests in `BlockDistanceTests` (no `CoordinateTests`); `UserLocationProvider` owns the fix; one explicit row VoiceOver label; regression contract (no permission renders as before); foreground refresh; fixes carry accuracy and coarse fixes (over 100 m) are hidden; a kept fix expires after 10 minutes; straight-line distance, documented | `/plan-eng-review` plus a Codex outside voice; owner accepted all |
| 2026-10-21 | #68 design D1 to D7: trailing value when the whole row fits, else stacked; reserved slot with a 0.2s opacity fade; "Around the corner" needs a fix accurate to 50 m; one-time inline Distances tip; "miles" spelled out with no ".0" and singular at 1; 20 blocks before miles | `/plan-design-review` with two outside voices; owner accepted all. Late arrival must not move rows, and a ten-block cap put most of a city-wide list in miles |
| 2026-10-21 | #67 spec D1 to D2: at block zoom every pin shows the existing DD3 capsule label with overlap avoidance, and the circle stays; the display-register name plates were not adopted; block zoom is a zoom threshold only (visible height 400 m), greedy placement, priority then north first, no pin-count rule | D5 keeps the display register to three surfaces; a pin-count rule blinks when the 13th pin pans in |
| 2026-10-21 | #67 eng D1 to D3 and F1 to F3: data and priority refreshes wait for the camera to settle; label widths and heights are measured with the font (cached per name and text size), not estimated; only items within half a span of the visible region take part; the held stand-in is an item; fixtures isolate the label-label rule; the pan guarantee holds for uniform screen translations only (pitch may change spacing) | `/plan-eng-review` plus a Codex outside voice; owner accepted all. The 8pt-per-character figure was not an upper bound |
| 2026-10-21 | #67 design D1 to D11: Apple's commercial POIs hidden and the location dot an obstacle; hysteresis 400/440 m; truncation by width (160pt) for every label; visible height measured from the screen, so heading does not change it; the `.xxLarge` cap kept with the List tab as the scaling surface; contrast gate with `.thickMaterial` as the pre-approved fallback; one label style, the priority label alone lifted by the small shadow; obstacles are the drawn circles (32pt, 36pt held or dropping, 24pt location dot), and the 4pt clearance applies between labels only; a pinch clears labels; the first add labels only the dropping pin | `/plan-design-review` with two outside voices; owner accepted all. Two bodegas across a street lost both labels to the 44pt hit square. D1 refined in QA: the location-dot obstacle shrunk from 44pt to the drawn 24pt dot after QA found a user standing on a pin lost both labels |
| 2026-10-21 | #84 spec D3: Locate Me lands at block zoom (about 350 m visible height; `locateMeCameraDistance` 850 m measured 350.2 m); the follow handover was dropped by probe P1 (MapKit re-zoomed to 2,425 m on it), so the landing is one-shot and a second tap re-centres | #67's labels never showed on the hero tap, which landed at 2,424 m; `MapCameraPosition` cannot follow at a chosen distance |
| 2026-10-21 | #84 eng R1 to R4: a late Locate Me result is dropped after a newer tap, a settle, the List tab or a change of placement; only a precise fix (100 m or better) lands block zoom, else MapKit's `.userLocation`; R2 (scene-inactive event) belongs to the peek, which did not ship; R4's landing check went with the handover | `/plan-eng-review` plus a Codex outside voice; owner accepted all |
| 2026-10-21 | #84 design D1, D3, D5 to D8: a precise fix kept from the last 60s lands at once, else the symbol pulses while waiting; noneOnBlock card at block zoom; D5's follow glyph fell away with the handover; Locate Me ignored during the first add; Near Me lands one-shot; 0.9s flights over three zoom levels or 2 km, 0.6s otherwise | `/plan-design-review` with two outside voices; owner accepted all |
| 2026-10-21 | #84 spec D4 (long-press peek) not shipped: probe P2 check (e) failed with both gesture forms. With `.onLongPressGesture` on the pin MapKit still reported the touch as a selection about 0.1s into the press, so the pin held and the detail pushed under the finger; with `.simultaneousGesture(LongPressGesture)` the press peeked cleanly but MapKit stopped seeing quick taps at all (check (a)). DD3's recovery stays the tap; #84 stays open for the peek | Design D4's stop rule; a UIKit long-press recognizer hit-testing annotation points is the remaining route, a separate decision |
