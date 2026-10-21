# Design: Calm in Ember

The look of Dokkit's web app, and the one the phone apps and every new page follow. The approved
clickable mock is in `gallery/calm-ember/` (open `index.html`; routes `#inbox`, `#issue/DOK-3`,
`#everything`, `#machine/db-01`, `#jobs`, `#logs`, `#settings`). The "demo is full" page with its game
is `gallery/calm-ember/demo-full/`. When the mock and this page disagree, the mock wins.

The phone apps differ from these rules in a few places. Those differences are in **Phone apps only** near the
end, and they apply to the Android and iOS apps alone; the web app, the site and everything else keep the rules
as written here.

## Rules that are not up for debate

- **Add, never replace.** A redesign keeps every control, option, page and behaviour that exists.
  A new option is appended to a list; nothing is removed to make a layout fit.
- **Nothing operational is hard-coded.** Every value a person might care about keeps today's value
  as its default and can be changed, per machine, service or job where that makes sense. Each
  setting shows its default and a Reset next to it.
- **Theme follows the system** until someone picks light or dark. Light and dark are both warm.
- **Orange, not teal.** The brand colour is orange in both themes. Teal survives only as one accent a
  person can choose.
- **State is the loudest thing on screen.** Something that needs a person looks like it; things that
  are fine go quiet.
- **Motion is subtle and never in the way.** No scroll-linked animation, no scroll hijacking, and all
  of it stops under reduced motion.

## Colour

Light (default when the system is light):

| Token | Value | Use |
|---|---|---|
| bg | `#f8f3ee` | page |
| bg-2 | `#efe6dd` | sidebar, segmented controls |
| panel | `#fffcf9` | cards and panels |
| line | `#e2d4c9` | hairlines |
| ink / ink-2 / muted | `#241a15` / `#4d3d33` / `#6b5a4f` | text, secondary text, labels |
| brand / brand-ink | `#f28a3a` / `#2a1203` | primary buttons, selection, focus accents (dark text on orange) |
| focus | `#a8460a` | focus ring |

Dark:

| Token | Value |
|---|---|
| bg / bg-2 / panel / line | `#1e1917` / `#171311` / `#27201d` / `#40342f` |
| ink / ink-2 / muted | `#f7f1ec` / `#dccdc2` / `#b9a99e` |
| brand / brand-ink | `#ff9a4d` / `#2a1203` |
| focus | `#ffb074` |

State tints, each a soft surface, an ink for text on it and a solid for marks (light / dark):

| State | Surface | Ink | Solid |
|---|---|---|---|
| Down (rose) | `#fbe7e4` / `#3a2421` | `#b42d25` / `#ffa39c` | `#e0675e` / `#ff7b72` |
| Slow (amber) | `#fbf0d6` / `#382e1c` | `#855b00` / `#f5c542` | `#e3a51c` / `#f5c542` |
| Soon (peach) | `#f6ead9` / `#362a20` | `#85561a` / `#e7b77d` | `#d9a066` / `#e7b77d` |
| Fine (sage) | `#e5f1e6` / `#1f2d23` | `#1d7537` / `#7bd88f` | `#8fcf9e` / `#7bd88f` |

## Type and shape

- Figtree for everything people read; IBM Plex Mono for technical strings (machine and service
  names, ids, times, numbers that line up).
- Page title 34px, weight 800, tight tracking; a lede sentence under it at 18px.
- Panels 16px radius, small controls 12px, pills fully round. Soft shadows, never hard edges.
- Icons are Phosphor; state icons sit in a tinted circle (44px, 56px on hero headers).

## Patterns

- **Page header:** a small eyebrow (greeting or state tag), the title, and one sentence that says
  what the page shows right now ("4 things need you today. 2 are coming up, and nothing else is
  wrong."). The sentence must be true: when a list is capped, say so.
- **Issue card:** tinted by state, icon in a tinted circle, the title, one plain sentence ("Something
  is wrong with nightly-purge on db-01 since 22 h ago."), quiet metadata in mono, and one next-step
  button on the right ("See the last run", "Compare with the deploy").
- **All fine:** a sage panel, "Everything else is fine: 46 services on 6 machines." Hidden when
  nothing is watched.
- **Heat map (the last day):** 48 square cells, 2px gap, 2px radius, full width of its panel. Sage
  fine, amber slow, rose down, an outlined cell for not expected.
- **Tables (Logs):** sortable headers with a caret, filters in one row, a count line, Export CSV
  beside the count.
- **Settings:** grouped panels that fold open. Each row: title and one-line explanation, the
  control, and "Default: …" with Reset when changed. A switch turns a whole row on or off. Save sits
  at the bottom of each panel.
- **Who is told:** the existing choices plus "Whoever is on call in PagerDuty", which reads the
  on-call person from a PagerDuty schedule.

## Motion

- A very slow warm glow drifting behind the page (about two minutes per turn).
- Pages and rows settle in with a short fade and 6px rise; heat-map cells and meters fill in once.
- Panels fold open and closed with a short slide.
- Nothing else moves. Everything stops under `prefers-reduced-motion`.

## Phone apps only

These rules are for the Android and iOS apps, and only there they replace the matching rules above. The
approved direction is "Statement", built in `apps/android/`.

- **Type.** Figtree for everything, technical strings included: machine and service names, ids, times and
  numbers use Figtree, not IBM Plex Mono. Big figures use the heavy weight.
- **Colour.** Orange is the only brand colour. There is no teal accent to choose.
- **Every page opens with a statement card.** A rounded gradient card inset from the edges, tinted by the page's
  state (rose, amber, peach, sage, or a warm orange on pages without one), with the state as a large sentence.
  Its tint washes down the whole screen, so it never ends in an edge. As the page scrolls the card settles into
  a slim pinned card and the content passes under it.
- **Big cards** with 24 dp corners and generous air sit under it. Tabs (Home, Servers, Settings) live in a
  floating bar.
- **The last day** is one capsule per machine, the height of a meter: half hours in the same state merge into one
  stretch, with a hairline gap only where the state changes. The legend uses the same capsule shape.
- **Motion can follow the scroll** (the statement card settling); it still never hijacks or snaps the scroll.
  Beyond that:
  - The tab bar and the segmented switches share a clear glass lens over the chosen item, on the measured iOS 27
    springs: it lifts and grows mid-move, leans into the travel, squashes on landing and wobbles once; pressing
    and dragging moves it under the finger.
  - Tab pages and lists that change with a switch slide on that same spring, in the direction of travel.
  - An issue card grows into its service page; the server picker grows out of its button into a window with a
    soft halo around it.
  - Numbers count up once, heat maps and charts fill once.
  - All of it stops under reduced motion.

## How the design was reached, and how to do it again

This process produced the approved look; repeat it for the phone apps or any new screen.

1. Write one shared file of made-up data (`gallery/calm-ember/shared/data.js` is the model) so every
   option shows the same estate.
2. Build several clearly different, clickable directions on that data, each covering the real
   screens (inbox, an issue, everything, a machine, jobs, logs, settings), working at phone width.
   Serve them on the LAN behind one page with a tab per direction, and open it for the owner.
3. Let the owner mix: the winner here was one direction's layout in another's colours.
4. Then change one thing at a time as the owner names it, refreshing the same page.
5. Only then build it into the product, keeping every existing behaviour (rule 1).
