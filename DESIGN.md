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
  text-muted: "#636366"       # textMuted asset (#95 D6); dark #98989F, Increase Contrast #545458 / #AEAEB2. Data lines on opaque surfaces only
  text-secondary: "#8A8A8E"   # secondaryLabel flattened on white; dark #8D8D93. Symbols on material, system Form headers and footers (body text on material is .primary, #95 D11)
  text-tertiary: "#C4C4C6"    # tertiaryLabel flattened; dark #48484A. Non-text only (decorative chevrons), never on text (#95 D7)
  separator: "#C6C6C8"        # separator; dark #38383A
  accent: "#FF3B30"           # pin, systemRed asset color; dark #FF453A. Bodega pins and the mappin symbol
  accent-cat: "#FF9500"       # catPin, systemOrange asset color; dark #FF9F0A. Cat symbol everywhere, cat pins, the onboarding spine and the Streets Walked intro's symbol (#126)
  star: "#FFCC00"             # systemYellow; dark #FFD60A. Rating stars only
  walked: "#5856D6"           # walked asset (#108 D1); dark #7D7AFF, Increase Contrast #3634A3 / #A5A3FF. Walked blocks only
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
    fontSize: 15pt             # .subheadline; textMuted on opaque surfaces, .primary as body on material (#95 D11)
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
- Only four saturated colors exist and all four are data: pin red, cat orange, star yellow,
  walked indigo.
- One tint, Deli Green, for every control. It never means data, status, or success.
- System face everywhere; one display register (heavy, condensed) on four surfaces.
- Copy is in voice (see `AppCopy`), one symbol per surface, the cat appears sparingly.

## Colors

**Strategy:** Restrained. Neutrals are the semantic system colors (`label`, `secondaryLabel`,
`systemBackground`, grouped backgrounds, `separator`), so dark mode is the system's own
hierarchy, not an inversion. One scoped exception (#95 D6): `secondaryLabel` flattens to 3.44:1
on white and 3.29:1 on grouped, under WCAG AA, so muted text on an opaque surface (for example
list and duplicate rows, the detail header's address, distance and rating count, hours, review
dates, section empty states, the onboarding body, the root loading line, the add form's Closed
label, a tip inline in the form or the list) uses the
`textMuted` asset, #636366 / #98989F with Increase Contrast slots #545458 / #AEAEB2, at least
4.5:1 on white, grouped and the elevated #2C2C2E. Body text on material (#95 D11: every map
card body, tip messages on the card and in the popover, the sign-in and duplicate sheet bodies)
is `.primary`, as in iOS notification banners; titles keep `.headline` for hierarchy, and symbols
and icons on material stay `.secondary` (non-text, 3:1). Vibrant `.secondary` measured 3.3 to
4.0:1 on material in light, on `.regularMaterial` and `.thickMaterial` alike, so thickening could
not meet 4.5:1; the materials stay `.regularMaterial` and `.thickMaterial` is not used. System
`Form` headers and footers and the DEBUG captions keep `.secondary`. `.tertiary` is
never on text (#95 D7); it is for non-text decoration only (the duplicate chevron); inactive page dots, which must hold 3:1, are `.secondary` (3.44:1 light, 6.36:1 dark). Error and consequence copy is
`.primary` (#95 D8). Two asset-catalog colors, `pin` (systemRed) and `catPin`
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
  first-add card, the noBodegas empty state), and the Streets Walked intro's symbol (#126 D3). Yellow is stars and only stars.
- Indigo is walked blocks and only walked blocks (#108 D1): the `walked` asset, #5856D6 light and
  #7D7AFF dark, with Increase Contrast slots #3634A3 / #A5A3FF, at full opacity with round caps and
  joins. Each walked block is a line on its street's centerline, chained into runs, drawn above
  the roads and under the labels, pins and location dot (`.mapOverlayLevel(level: .aboveRoads)`),
  8pt up to 400 m of visible height, 5pt to 2 km, 3pt to 8 km, 2pt above, with 10% hysteresis on
  the way out. Visible height is the app's measure, not the screen's: the ground distance from
  the top-centre to the bottom-centre of the Map's laid-out frame (`visibleHeightMeters`). On the
  iPhone 17 Pro simulator (iOS 26.5, #113 QA) that measured about 0.75 of the full screen's
  height; the ratio varies with device and safe areas. There, Locate Me's 850 m camera distance
  measures about 350 m while about 480 m of street is on a full screen, so the bands are roughly
  530 m / 2.6 km / 10.5 km of full-screen height on that device. Past 1,000 visible runs (2,000 in the spec, lowered after the R3 device check) the layer hides and the bottom card says "Zoom in to see
  your blocks."; it never draws a subset. Changes land at camera rest and swap in place, with no
  fade: MapKit does not animate `MapPolyline` changes (#113 dropped D10's 0.2s fade), so Reduce
  Motion needs nothing special. Nothing is written mid-gesture, and a settle that changes nothing
  drawn writes nothing. A run is drawn while its box meets the view plus 25% on each side. A wider
  retain margin (#115) was reverted: on device it did not cut settle hitches, because MapKit's
  add/remove cost grows with the lines drawn, not only the lines changed (#113).
- Cat and non-cat pins are distinguished by glyph (`cat` vs `figure.wave`) as well as color, so
  the red/orange pair is a redundant encoding, not the only one. Keep it that way.
- Materials (`.regularMaterial`) carry floating content (map card, pin label); `.thickMaterial` is not used (#95 D11). On iOS 26 the
  system's Liquid Glass carries floating controls (toolbars, tab bar, map buttons) by default;
  do not apply glass to content and do not apply material to controls. Pages are opaque.

## Typography

**Face:** SF Pro, the system font, in every role. Deliberate, not default: the app is used
one-handed on a sidewalk, must scale through the accessibility Dynamic Type sizes, sits next to
MapKit's own labels, and should move like Apple built it. A bundled face would cost metrics
plumbing and read as a web app. There is no font to load.

**Display register (D5, 2026-10-20):** weight `.heavy`, width `.condensed` (`Font.Width`), on
exactly four surfaces: onboarding page titles (`.largeTitle`), the first-add card title
(`.headline`), the bodega name in the detail header (`.title`), and the Streets Walked intro
headline (`.largeTitle`, #126 D4). In SwiftUI:
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
title `.headline`, body `.subheadline` `.primary` on cards (#95 D11); `.subheadline` + `.footnote`, both
`textMuted`, on section empty states; `.title3` `textMuted` for onboarding body. No text is
`.tertiary` (#95 D7).

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
the list tab, the page dots, the photo viewer counter (#107), and a viewer page's content (the
photo, or its load failure standing in its place).

**Widths:** floating overlays `maxWidth: 480pt` centered (iPad, landscape); onboarding content
`maxWidth: 560pt`, top-aligned at 25% of the height.

**Density:** medium on the map (one floating object at a time in the bottom slot; precedence
placement card > first-add card > recorder problem > empty state > add tip > streets banner > zoom in for
blocks, #123 DS2), comfortable on
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
`.primary` (#95 D11; `.lineLimit(4)`, `.minimumScaleFactor(0.85)`), trailing `xmark.circle.fill` close with
a 44pt target, `.bordered` action row below the text. Stacks vertically at `.accessibility1` and
up. Reading order title, body, action, close. Every content change moves from the bottom edge
with opacity over 0.25s ease-in-out (opacity only under Reduce Motion, #23). States: emptyState (noBodegas cat/catPin with bounded
breathe; noneNearby `mappin.slash`; noneOnBlock `mappin.slash`, the nearby empty card at block zoom,
"Nothing on this block yet." / "Pinch out and look around. Or add the one on your corner." with
Add a Bodega (#84; above block zoom noneNearby keeps "Nothing near you yet."); noFilterMatches `line.3.horizontal.decrease.circle`;
loadFailed `exclamationmark.triangle`), firstAdd, addTip, streets banner ("No streets yet." once a count finds no walked
blocks, never while the first count runs and never while recording is paused, #108 D8, #123 DS3),
zoomInForBlocks (`plus.magnifyingglass`, title only, lowest precedence, #108 D3), recorder (#123 DS1, DS6:
Streets Walked's recorder problem, under first-add and over everything else; `.secondary` symbol, `.bordered`
Open Settings when Settings can fix it, always closable). Recorder problems, one shown in the order restricted >
denied > servicesOff > preciseOff > needsAlways > saveFailed: needsAlways `location.slash` "Recording paused." /
"Streets Walked needs location set to Always. Your blocks stay."; denied `location.slash` "Recording can't see
you." / "Location is off for this app. Your blocks stay."; servicesOff `location.slash` "Recording can't see
you." / "Location Services is off for the whole phone."; restricted `location.slash` "Recording isn't allowed
here." / "Location is restricted on this phone. Your blocks stay." (no action); preciseOff `scope` "Recording
paused." / "Blocks need Precise Location, and it's off."; saveFailed `exclamationmark.triangle` "That stretch
didn't save." / "Recording keeps going. Your other blocks are fine." (no action; recording continues). Closing
the card hides it for that problem until the problem changes or the next cold launch, in every window; the
menu and Your Blocks still say paused. VoiceOver hears the card's title when a problem appears while the app is
active, and "Recording again." when recording resumes. There is no tracking-error banner.

**Pin** (`BodegaPinView`, DD3): 28pt circle, `.pin` or `.catPin`, white 14pt glyph, 2pt white
stroke, shadow 2/1, 44pt hit area, anchored at center. Selected: 3pt stroke, shadow 4/2, scale
1.15, drawn last. Label: `.caption2` `.primary` on a `.regularMaterial` capsule, one line up to
160pt of text, tail-truncated, 4pt above the circle. It shows when the pin is selected (held) or
dropping, and at block zoom on every pin whose label clears every kept label and every drawn
circle (#67). Block zoom is a visible map height (top-centre to bottom-centre of the map) of
400 m or less; labels stay until it passes 440 m, so a settle near the line never blinks them.
That height is the app's `visibleHeightMeters`, the Map's laid-out frame, not the full screen.
On the iPhone 17 Pro simulator (iOS 26.5, #113 QA) it measured about 0.75 of the full screen's
height (the ratio varies with device and safe areas): Locate Me's 850 m camera measures about
350 m with about 480 m of street on a full screen, so 400 / 440 m are roughly 530 / 590 m of
full-screen height on that device.
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
display register; body `.title3` `textMuted` (#95 D8); `VStack(spacing: 12)`; buttons pinned in a bottom
`safeAreaInset`, full width, `.controlSize(.large)`, primary `.borderedProminent`, secondary
`.bordered`, 12pt apart; three custom 8pt dots (`.secondary`, 3:1 non-text with a clear step from the current `.primary` dot; #95 D7); Skip
top-trailing `.body`, pages 1 and 2. Page 3 buttons show a `ProgressView` while the root is
loading. Advance 0.3s ease-in-out; exit 0.35s (0.25s opacity-only under Reduce Motion).

**Detail header:** name in the display register (`.title`, heavy, condensed), address
`.subheadline` `textMuted`, stars `systemYellow` with the numeric rating tabular and the review
count `.subheadline` `textMuted` (#95 D6). `RatingSummaryView`
renders nothing when there is no average; the reviews section owns the empty state. Third line
(#68): the distance as a sentence, `AppCopy.distanceFromYou` ("2 blocks from you."),
`.subheadline` `textMuted`, no monospaced digits, 4pt under the address (under the name when there
is no address); its own VoiceOver element, not a header. While location is authorized with full accuracy the line is
reserved as an empty line and the sentence fades in over it (0.2s `easeOut`, opacity only), so
the sections below never shift. A load failure under the sections is `.footnote` `.primary`
(consequence copy, #95 D8).

**Data points** (`DataPointsSection`, #70, #95 D9): five amenities (cat, hot food, nicotine,
beer, lotto), symbol over a `.caption2` caption, or one symbol-and-caption row per point when the
columns do not fit and at accessibility sizes. Presence is shape plus contrast: present, symbol
and caption `.primary`; absent, the same symbol and a struck-through caption in `textMuted`, with
no opacity dimming. D9 prefers a symbol's `.slash` variant, but none of the five has one in
iOS 26 (checked against the runtime's SF Symbols list; `TextContrastTests` fails if one appears),
so the strikethrough is the shape cue for all. VoiceOver reads the caption with a Yes or No value;
the symbol is hidden. Hours times and review dates are `textMuted` too.

**List row** (`BodegaRow`, #68): name `.headline`, address `.subheadline` `textMuted` (#95 D6), both wrapping
at every size and never truncating. The distance (`AppCopy.distanceValue`, `.value` kind) is
`.subheadline` `textMuted` with monospaced digits, trailing the name on its first baseline with at
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

**List order** (#81): the List tab is nearest first by default, sorted by the same straight-line
distance the rows show, from a fix pinned when the List tab is entered or the order changes, and
only a fix at most 10 minutes old is pinned. The first usable fix after an unpinned start (a cold
start, or a pinned fix that was too old) cross-fades the order once: the rows fade in place, 0.25s
`easeInOut` (`BrowseMotion.ListOrder.reorderSeconds`), with the #68 distance fade in the same
transaction, instant under Reduce Motion, never a row sliding to its new place; it is applied only
when the scroll is at rest, never under a moving finger, and keeps the scroll offset. Later fixes
change the values, never the order; popping back from a detail never re-sorts. A lost fix falls
back to newest first as the distances fade out. Newest first is the fetch order (`created_at`
descending) with local additions in front, not a client-side timestamp sort. On a cold start the
list may open newest-first and cross-fade once to nearest when the first fix lands. The list
itself never hints at its order (the #68 silent states). The Filters sheet carries the control:
sections Must Have, List Order, Search; List Order is an inline picker (Nearest First, Newest
First; Deli Green checkmarks) with exactly one system footer line under Nearest First, updated live:
"Sorted from where you opened the list." while the list is nearest-ordered; "Nearest first needs
your location. Tap Locate Me on the map." while the map can still prompt; "Newest first for now.
Nearest first needs to know where you are." otherwise (denied, restricted, Precise Location off,
a fix pending or expired); no footer under Newest First, and never a button, symbol or Settings
link. Choosing an order in the sheet scrolls the list to its top. The order is not a filter:
Clear Filters (renamed from Clear) and the toolbar badge ignore it. The sheet opens at `.large`
only at accessibility sizes. VoiceOver: an automatic re-sort while the list is in front (no sheet,
no detail) announces "Nearest first now." and keeps focus on the same bodega (on the new first row
if focus was on the first); a loss is silent. The choice is remembered (`UserDefaults` key
`listOrder`). The list fetches every row in one request, capped at 1,000 by PostgREST (TODOS.md).

**Photo viewer** (`PhotoViewer`, #107): gallery thumbnails are 120pt buttons, 12pt radius, each
the source of a `.fullScreenCover` that zooms out of it (a crossfade under Reduce Motion) and back
into the current photo's thumbnail, which the gallery scrolls into view first. The viewer pages
a snapshot of the gallery (`TabView(.page)`), always dark as in Photos, on the dark
`systemBackground` with semantic colors only. Each page is a `UIScrollView` zoom page: pinch 1x
to 4x, double tap 1x / 2.5x at the tap, paging only at 1x. Controls are system Liquid Glass
toolbar buttons with 44pt targets: close (`xmark`) leading, the counter ("3 of 12", `.subheadline`,
monospaced digits) as the principal item, an `ellipsis.circle` menu with Flag Photo trailing, whose
flag sheet and thanks alert open over the viewer. The flag sheet is a standard form and keeps the
system appearance (light in Light Mode); only the viewer itself is forced dark. Controls show on open and never auto-hide; a
single tap (once a double tap has failed) toggles them with the status bar and home indicator
(0.2s `easeOut`, opacity only; `PhotoMotion`); under VoiceOver they stay. At 1x a downward drag
moves the photo and fades the ground; past 100pt or a fast flick it closes, else it snaps back.
Loading is a `ProgressView`; a failure is the `photo` symbol `.secondary`, "That one didn't load."
`.primary`, and a `.bordered` Retry that reloads that page only. VoiceOver: thumbnails read
"Photo N of M" with the hint "Opens full screen."; a page is an image with the same label and the
actions Zoom In and Reset Zoom; a page change announces "Photo N of M."; escape closes, and focus
returns to the current photo's thumbnail. A captioned photo shows its caption in an opaque band
over the bottom of the page while the controls are up, the photo fitted and centred in the space
above it; the page itself stays full screen (`.body` `.primary`, 3 lines, 16pt inset, no gradient);
"More" expands it into a scroll capped at half the screen, and it hides with the controls. A
thumbnail's VoiceOver value is its caption; after the flag sheet closes, focus returns to the menu.

**Add Photos sheet** (`AddPhotoView`, #107 PR 2): opens the moment the picker (up to 10, in
selection order) closes, titled "Add Photos" with the bodega's name as the subtitle. One pick gets
the large preview (fit, max 360pt, 12pt radius) with the caption below; two to ten get an
inset-grouped list of rows: a 64pt 12pt-radius thumbnail that opens the viewer on the batch (no
menu, no captions), the caption field, and the status. Rows stack at accessibility sizes and
otherwise use `ViewThatFits` (the `BodegaRow` idiom). A placeholder row (grey tile, spinner) stands
in while a pick is prepared. Status is neutral and shape-coded: nothing while waiting, an untinted
spinner while preparing or uploading, `checkmark.circle` `.secondary` once up,
`exclamationmark.circle` `.primary` with "Didn't go through" on a failure; never red or green. A
caption locks (plain `.body` text) once its upload starts; the counter shows from 120 characters
(`.footnote` `textMuted`, monospaced, red only over 140). Return moves to the next caption. Rows
remove by swipe or the VoiceOver Remove action. The leading button is Cancel, Stop during a pass,
Done once one photo is up; with an unsent caption it asks "Discard N photos?". The footer carries
"Uploading 3 of 8." or, after a failure, "2 went up. 1 didn't. Try again." with "Retry N" in the
trailing button. When it closes, the new thumbnails insert at the front of the gallery and it
scrolls to its leading edge.

**Your Blocks sheet** (`YourBlocksSheet`, #108 PR 2, D7, D8, D11): opened by Your Blocks, the first
item of the Streets Walked menu (hint "Shows blocks walked in each borough."); opening it brings the
counts up to date and loads the street data even with no history. Inset-grouped `List`, inline title
"Your Blocks", Done, `.medium` and `.large` (`.large` only at accessibility sizes), opaque
(`systemGroupedBackground`) at both detents, because the counts are `textMuted` data lines, which
belong on opaque surfaces only, and iOS 26 otherwise draws a `.medium` sheet as glass. Section 1 is
New York City, "412 blocks" with "of 99,360" in `textMuted`; section 2 is Manhattan, Brooklyn,
Queens, Bronx, Staten Island, each "412 of 9,300 blocks" in `.subheadline` `textMuted` under the
name in `.body`, the percent trailing in `.body`, all monospaced digits. The percent rounds down;
any nonzero count under 1% shows "<1%". Rows stack at accessibility sizes and otherwise use
`ViewThatFits` (the `BodegaRow` idiom). No progress bars, no display register, no indigo (the sheet
is numbers, not the overlay). Footer: "A block counts once you've walked most of it. Your walks stay
on this phone.", plus "Recording is off. Your blocks stay." (or, while paused, "Recording is paused. Your
blocks stay." with an Open Settings row when Settings can fix the problem, #123 DS3) and "Without Motion &
Fitness, rides are filtered by speed only." when they apply. States, failure > counting > zero: "The street map didn't
load. Your walks are still saved." in `.primary` replaces both sections, as does "Your blocks
couldn't be counted. Your walks are still saved." when the first count fails and its one automatic
retry fails too (#113; reopening the sheet counts again); a Clear History during the first count
ends on zero; a first count shows "—" and, after 0.5s, "Counting your blocks…" under the city; a
recount keeps the last counts; zero adds "Walk somewhere. This fills in on its own." under the city (not
while paused).
Someone already recording whose Motion & Fitness was never asked gets an Allow Motion Access row;
after a denial it is Open Settings. VoiceOver: each row is one element, "Manhattan, 412 of 9,300
blocks, 4 percent."; "<1%" reads "less than 1 percent", "—" reads "counting".

**Streets Walked intro sheet** (`StreetsWalkedIntroSheet`, #126): the intro's fourth page, delivered as a sheet the first time the map is quiet after onboarding (1.5 s after the gate holds, camera at rest, active scene, nothing presented, no first-add choreography, recording off, no history; once per device; reopened any time from the Streets Walked menu's "How Streets Walked Works"). `.large` only, opaque `systemBackground`, inline title "Streets Walked", Done. The onboarding page composition at the compact 16pt top inset: 44pt `figure.walk` in `.catPin` (the fourth spine symbol), headline in the display register (D5's fourth surface) with the header trait, body `.title3` `textMuted`, a `.headline` permission heading "Recording needs location set to Always.", the permission paragraph in `.primary` (consequence copy, #95 D8) chosen by authorization status (notDetermined, whenInUse, denied, restricted, always) or, while paused, the recorder problem's own line, then "It lives under Streets Walked, the walking figure in the map's toolbar." in `textMuted`; `VStack(spacing: 12)`, 24pt inset, 560 max width. On reopen the status line ("Recording is on." `textMuted`, or "Recording is paused. Your blocks stay." `.primary`) sits under the headline. Bottom `safeAreaInset` bar on the same opaque ground, `.controlSize(.large)`, 12pt apart: off → Start Recording (`.borderedProminent`) and Not Now (`.bordered`); off and restricted → Not Now; recording → none; paused for something Settings fixes → Open Settings (`.borderedProminent`); paused otherwise → none. Start Recording dismisses the sheet, then runs the menu's exact path (#123 DS4). VoiceOver: symbol hidden; headline and permission heading are headers; order headline, status, paragraphs, buttons; each paragraph its own element; escape dismisses without starting; focus returns to the Streets Walked toolbar control after a manual close. Every text `fixedSize`, no caps, labels wrap; where the pinned bar would leave under 200pt of reading space (AX sizes in compact height) the bar moves to the end of the scroll. System sheet motion only. Swipe-down is Not Now.

**Section empty state** (DD9, amended by #95 D7): title `.subheadline` `textMuted`, body
`.footnote` `textMuted` (never `.tertiary`), 2pt
apart, leading, no symbol, inside the section's `VStack`. List-tab empty states use
`ContentUnavailableView` (48pt centered symbol).

**Buttons:** `.borderedProminent` for the one primary action on a surface, `.bordered` for
secondary and card actions, `.plain` red text for destructive. Disabled is the system 45%
opacity. No custom button shapes; no gradient fills.

**Forms and sheets:** system `Form`/`List` grouped style, `.navigationBarTitleDisplayMode(.inline)`,
error text `.footnote` in red inside its section. Sign-in presented from the add flow at
`.medium` detent on `.regularMaterial`, as is the #20 duplicate sheet.

**Tips** (`AddBodegaTip`, placement tip, `DistancesTip` first in the loaded list, #68): `BodegaTipStyle` renders no background when inline in
the card; the card supplies the material. Inline on an opaque container (the add form's
first row, the list's Distances tip) the message is `textMuted` (`onOpaqueSurface`, #95 D6);
on the card and in the popover it is `.primary` (#95 D11).

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
  350.2 m on the iPhone 17 Pro simulator; the app's measure, which there was about 0.75 of the
  screen, so about 480 m of street is on a full screen, #113), heading kept, pitch levelled, `easeInOut`
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
  fades (0.25s; also under Prefer Cross-Fade Transitions), a list order change is instant (#81).
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
- **Photos (#107):** values live in `PhotoMotion`. Viewer controls 0.2s `easeOut`, opacity only;
  upload row status 0.15s `easeOut`; caption band expand 0.25s `easeInOut`; new gallery thumbnails
  0.25s `easeInOut`. Under Reduce Motion everything is opacity only (the caption band expands
  instantly) and the thumbnail zoom becomes a crossfade.

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
| 2026-10-21 | #81 spec D1 to D2: the list is nearest first by default whenever a usable fix exists and newest first otherwise, with a List Order picker (Nearest First / Newest First) in the Filters sheet, remembered across launches; the nearest order is pinned to the fix in hand at List tab entry, re-sorts once if the first usable fix lands after the page is up, and otherwise never reorders under the finger | #68 put the deciding number on every row and then ignored it; the toolbar has no room for a sort control at accessibility sizes |
| 2026-10-21 | #81 eng R1 to R4 and F1: only a fix at most 10 minutes old is pinned; the pin runs on tab entry, the first attach and an order change, never on a re-appearance; the 1,000-row `fetchAll` cap documented with a TODO; the sheet footer keys on the pinned fix, not on whether a fix exists; newest first is insertion order (local additions in front) | `/plan-eng-review` plus a Codex outside voice; owner accepted all. A stale kept fix must not anchor a visit, and the root view re-appears after every pop |
| 2026-10-21 | #81 design D1 to D7: List Order sits after Must Have; the footer by state with no Settings nudge; VoiceOver hears the automatic re-sort; a 0.25s cross-fade applied at scroll rest, no animation inside the page slide; Clear Filters, `.large` at accessibility sizes, tinted checkmarks; "Sorted from where you opened the list." while nearest is active; an order change in the sheet scrolls to the top | `/plan-design-review` with two outside voices; owner accepted all. Rows sliding under a reading finger are worse than a fade; Locate Me is a dead tap for denied users |
| 2026-10-21 | #84 spec D3: Locate Me lands at block zoom (about 350 m visible height; `locateMeCameraDistance` 850 m measured 350.2 m); the follow handover was dropped by probe P1 (MapKit re-zoomed to 2,425 m on it), so the landing is one-shot and a second tap re-centres | #67's labels never showed on the hero tap, which landed at 2,424 m; `MapCameraPosition` cannot follow at a chosen distance |
| 2026-10-21 | #84 eng R1 to R4: a late Locate Me result is dropped after a newer tap, a settle, the List tab or a change of placement; only a precise fix (100 m or better) lands block zoom, else MapKit's `.userLocation`; R2 (scene-inactive event) belongs to the peek, which did not ship; R4's landing check went with the handover | `/plan-eng-review` plus a Codex outside voice; owner accepted all |
| 2026-10-21 | #84 design D1, D3, D5 to D8: a precise fix kept from the last 60s lands at once, else the symbol pulses while waiting; noneOnBlock card at block zoom; D5's follow glyph fell away with the handover; Locate Me ignored during the first add; Near Me lands one-shot; 0.9s flights over three zoom levels or 2 km, 0.6s otherwise | `/plan-design-review` with two outside voices; owner accepted all |
| 2026-10-21 | #84 spec D4 (long-press peek) not shipped: probe P2 check (e) failed with both gesture forms. With `.onLongPressGesture` on the pin MapKit still reported the touch as a selection about 0.1s into the press, so the pin held and the detail pushed under the finger; with `.simultaneousGesture(LongPressGesture)` the press peeked cleanly but MapKit stopped seeing quick taps at all (check (a)). DD3's recovery stays the tap; #84 stays open for the peek | Design D4's stop rule; a UIKit long-press recognizer hit-testing annotation points is the remaining route, a separate decision |
| 2026-10-21 | #84 long-press peek shelved (owner D10). Probe P4 tried the single-owner route (D5: no `selection:`, no `.tag`, annotation gestures own the tap). Taps, cluster zoom and VoiceOver buttons worked, but no SwiftUI long press both recognises inside an annotation and lets a pan that starts on a pin move the map: `.onLongPressGesture` never fired, and the `simultaneousGesture` forms blocked the pan (0/9). The window-observer route was rejected in eng review (a MapKit selection carries no touch identity). DD3 recovery stays the tap or a zoom; main keeps MapKit selection | Evidence under `~/.gstack/projects/yukichikawada-BodegasNYC/qa/84-peek-probe/` (P2, `p4/`); reopen only with a UIKit route that keeps map pans |
| 2026-10-21 | #95 design D6 to D9 and D11: a `textMuted` asset (#636366 / #98989F, Increase Contrast #545458 / #AEAEB2) for muted text on opaque surfaces, a scoped exception to the system-neutrals rule; `.tertiary` never on text (empty-state bodies `textMuted`, the duplicate footnote `.primary`, page dots `.secondary` (3:1 non-text, kept a step lighter than the current dot), the decorative chevron kept); error and consequence copy `.primary`, the onboarding body `textMuted`, system `Form` headers and footers keep `.secondary`; data points carry presence by shape plus contrast (absent: struck-through caption in `textMuted`, no opacity; none of the five symbols has a `.slash` variant); inline tips on opaque rows take `textMuted`. D11 (owner): body text on material (map card bodies, tip messages on the card and in the popover, the sign-in and duplicate sheet bodies) is `.primary`, as in iOS notification banners, titles keep `.headline`, symbols on material stay `.secondary`, and the materials stay `.regularMaterial` (`.thickMaterial` is not used) | `/plan-design-review` with a Codex design voice and an independent Claude pass; owner accepted all. Flattened `secondaryLabel` measured 3.44:1 on white and 3.29:1 on grouped, `.tertiary` 1.74:1, under WCAG AA for body text. D11: live, vibrant `.secondary` on material held 3.3 to 4.0:1 in light on both regular and thick material, so thickening could not meet the 4.5:1 gate |
| 2026-10-23 | #107 design D3: the photo viewer is always dark, as in Photos; semantic `.primary`/`.secondary` on the dark `systemBackground`, no `.white` literals. Its counter is a centered principal toolbar item, an exception to the leading-alignment rule | `/plan-design-review` with two outside voices; owner accepted all. A bright photo on a light ground loses its edges, and every photo app the user knows is dark here |
| 2026-10-23 | #108 walked blocks replace the raw GPS trace: fixes are map-matched to CSCL street blocks (walked at 6 of 10 tenths), drawn in a new `walked` indigo (#5856D6 / #7D7AFF, Increase Contrast slots; "Indigo is walked blocks and only walked blocks"), above roads and under labels and pins, 8/5/3/2pt by visible height with 10% hysteresis, hidden past 1,000 runs (2,000 lowered after the R3 device check, where 1,087 to 2,000 runs hitched) with "Zoom in to see your blocks.", changes at camera rest with a 0.2s fade (none under Reduce Motion) (fade dropped in #113). Menu: Show on Map, Start/Stop Recording, Clear History… with "Delete your walked history?"; Motion & Fitness asked once after Start Recording; no one-time announcement (D9 declined). The Your Blocks sheet followed in PR 2 (next row) | `/plan-design-review` D1 to D11 with two outside voices; owner accepted all but D9. The orange trace broke the cat-only rule and read as noise; indigo is clear of red, orange, yellow and Deli Green |
| 2026-10-23 | #108 PR 2 Your Blocks sheet (D5 to D8, D11): first in the Streets Walked menu with the hint "Shows blocks walked in each borough."; an inset-grouped list, New York City then the five boroughs, name over a `textMuted` count with the percent trailing, rounded down with "<1%" under one; no progress bars, no display register; states failure > counting > zero, a first count shows "—" and "Counting your blocks…" after 0.5s, a recount keeps the last counts; an Allow Motion Access row for people already recording, Open Settings after a denial; one VoiceOver element per row | `/plan-design-review` D7, D8, D11, owner accepted. The sheet is the accessible equivalent of the overlay; a percent of a borough is honest only as a number, and bars would make 1% look like nothing |
| 2026-10-23 | #113 item 1: walked runs enter at the view + 25% and, once drawn, stay until they leave the view + 75%; the over-cap decision is still counted on the + 25% set, and kept runs fill only the room under 1,000, farthest dropped first | The #110 device trace put a 167 ms settle hitch in MapKit's overlay add/remove, scaling with the lines changed; a replayed pan session over the 5,000-block seed swaps fewer lines per settle (numbers in the PR). Not yet confirmed on device. **Reverted the same day**: a same-driver device A/B showed no fewer hitches and 15–25% more overlay time per settle (next row) |
| 2026-10-23 | #113 item 1 reverted (#115 backed out): walked runs are again drawn only while they meet the view + 25% | Device A/B on the iPhone 17 Pro Max (Release, 5,000-block seed, scripted pans): main with #115 had 15 and 16 hitches, longest 167–200 ms, 58–62 ms overlay add/remove per settle; the commit before it had 15 and 20 hitches, longest 117–133 ms, about 50 ms per settle. Cost tracks lines drawn, and #115 drew about 29% more |
| 2026-10-23 | #113 item 5: when the first count of a launch fails and its one automatic retry fails too, Your Blocks shows "Your blocks couldn't be counted. Your walks are still saved." in `.primary`, in the street-map failure's place (both sections replaced; reopening the sheet counts again); a Clear History during the first count ends on the zero state; a failed recount keeps the last counts | D8 had no state for a count that fails: the sheet said "Counting your blocks…" until it was reopened. Zero was not an option, because with history it would be false and without a count there are no totals; one line in the existing failure layout is the least new UI |
| 2026-10-23 | #113 D10 fade dropped: walked-block changes swap in place at camera rest, no 0.2s fade, and Reduce Motion needs nothing special; mid-gesture writes and unchanged writes are still skipped | MapKit does not animate `MapPolyline` changes; verified on simulator in #113 (an `easeOut(0.2)` transaction around the write landed within one frame for Show on Map, data changes and the first count) |
| 2026-10-23 | #113 map-height wording: "visible height" (the 400 m / 2 km / 8 km width bands, #67's 400/440 m block zoom, Locate Me's 350 m) means the app's `visibleHeightMeters`, the ground distance across the Map's laid-out frame, measured at about 0.75 of the full screen's height on the iPhone 17 Pro simulator (iOS 26.5, #113 QA; varies with device and safe areas), where an 850 m camera ≈ 350 m measure ≈ 480 m of street on a full screen; no threshold changed | Simulator QA in #113 found the gap; the bands are internally consistent and were tuned on this measure, so the owner kept the numbers and fixed the wording rather than rescale |
| 2026-10-28 | #123 recording paused: Streets Walked recording is off, recording, or paused for one problem (restricted > denied > servicesOff > preciseOff > needsAlways; a failed save shows a card but keeps recording). The problem is a `MapBottomCard` state under first-add and over every other card, with DS6's symbols and copy (the denied body says "this app", since copy never names the app); the yellow footnote `TrackingErrorBanner` is gone. While paused the menu has a "Recording Paused" section with Open Settings above Stop Recording, Your Blocks says "Recording is paused. Your blocks stay." with Open Settings, and "No streets yet." stays away. Start Recording never jumps to Settings: any answer but Always saves the intent and shows the card, and granting Always later starts recording on return. Closing the card hides it for that problem until it changes or the next cold launch. VoiceOver hears the title when a problem appears and "Recording again." on resume | `/plan-design-review` DS1 to DS7 with two outside voices; owner accepted all. One slot with a defined precedence; the same state everywhere, so a dismissed card still leaves the menu and Your Blocks honest; no status colour or badge (Do's and Don'ts) |
| 2026-10-29 | #126 intro sheet: page four of the intro as a `.large` sheet on opaque `systemBackground`, presented once per device the first time the map is quiet (1.5 s, camera at rest) and reopened from the Streets Walked menu's "How Streets Walked Works"; `.catPin` `figure.walk` as the fourth spine symbol, the headline as D5's fourth display surface, a `.headline` permission heading over a `.primary` paragraph by authorization status (or the paused problem's line), Start Recording / Not Now, Open Settings `.borderedProminent` while paused for something Settings fixes, no Start Recording when restricted; Start Recording dismisses first, then runs the menu's path | Two outside voices and the native review agreed on the detent, the copy's honesty about iOS timing, the `.primary` consequence copy and the accessibility contract; Codex alone would have kept the grey symbol and plain bold title; the owner extended the spine and D5 by one named surface each so the sheet reads as the intro, not a system alert |
