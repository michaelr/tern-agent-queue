# Agent Queue

A Tern plugin that keeps the omp agents waiting on you in a queue and shows,
in a side pane, enough context to pick each one back up.

## Behavior

- Every 3 s the window polls `cx.agents:list()` and keeps omp agents only
  (agent blocks whose command is `omp`, and shells where `omp` was typed).
- An agent **enters** the queue when it stops working (`idle` or
  `waiting_input`) and **leaves** it as soon as it works again. Reply to an
  agent and it drops out; when it finishes, it rejoins at the back. A turn too
  quick for the poll to see it working still counts: when a queued agent's
  state or last message changes, it rejoins at the back (and a Done agent
  comes back). A last message that arrives late (Tern reports it after the
  state), or a new agent's first one, keeps the agent's place but re-reads
  its context, so a card read before omp took its first prompt fills in.
- An agent that disappears from Tern's list (closed, or its host's daemon
  detaching for a moment) is hidden but keeps its place and Done mark for
  10 minutes; if it comes back by then nothing changes.
- Order is FIFO, except agents asking a question (`waiting_input`) go first.
- **Next** and **Skip** (keys or buttons) move the current agent to the back
  (dropping its question priority) and go to the head of the queue, switching
  sessions if needed.
- **Done** (key or button) hides the agent until it works again and goes to
  the next one.
- The "current" agent is the focused one when it is queued or Done (so
  going to a Done agent, from the picker say, shows it), else the one the
  side pane last showed, so clicking the side pane (which focuses it)
  doesn't lose your place. A Done agent's card has a "done" badge and only
  **Go to**: there is nothing to skip or mark done.
- **Auto-advance** (off by default): when you reply to the focused queued
  agent, the next one comes up on its own.

The side pane shows the current agent: its illustrated scene (see Scenes),
Go to / Skip / Done buttons (with an
"asks" badge when it is asking), its project directory and git branch, and
**Now** (what it is on, from a summary; see below). Without a summary
(summaries off, or omp failing) your last prompt stands in. Below it, a row
per agent: its scene as a small square icon (the project's first letter
until one is drawn) beside its title, wrapped to two lines, over session ›
tab ("asks" first on agents asking a question). A remote host's canvas
can't show images, so there each agent takes one line: title, then
session › tab, which a narrow pane cuts first:

- **Queue**: every waiting agent; click a row to go there.
- **Running**: omp agents working now, longest-running first (counted from
  when the plugin first saw them working; a reload restarts it).
- **Done**: agents you marked done, until they work again.

Click the Running or Done heading to fold it (until a reload).

With the side pane focused, ↑/↓ (or k/j) move through the list (Queue, then Running
and Done unless folded), and the card previews each agent in turn, scene
included, with the row in bold; a Running or Done agent's card has only
**Go to**. Enter goes to the highlighted agent, Esc puts the card back on
the current one. Only the block on this machine takes keys; a remote host's
canvas side pane doesn't.

The view is built for a narrow side pane, 32 columns by default: no timers or per-row
state badges, no label column on the card, and nothing indented: the card's
title opens its body, and each list is a heading line over flush rows
rather than a section (sections indent their contents).

A status-line segment shows `N waiting · M asking` and runs Next when clicked.

Going to an agent (Next, Done, a Go to button or row, auto-advance) brings the
side pane along, without taking focus. On the window's own host the side pane
is a plugin block (`agent-queue.side`, from `host.luau`), which can show
images; the window publishes its view model to `tern.kv` (`side:<pane>`) and
the block's clicks come back as `agent-queue://` links the window claims. On
a remote host it is a canvas instead (no scenes): that host's half reads its
own `tern.kv`, where the window doesn't publish. One side pane per host, all
showing the same queue, because Tern can't move a pane to another host: the
agent's host's side pane docks as a split to the agent's left, so it sits
beside the file tree (left alone, width included, if already in that tab;
floated over the agent's top-left if docking is refused), and a host without
one gets a new one opened the same way. A toast says why once if that fails.
Close it and the next visit opens a fresh one. A canvas left on this host
from before the block is closed when the plugin loads.

A docked side pane is sized to 32 columns, or to the width you last dragged
one to (`side_cols`; a drag is noticed when the pane next moves, is hidden,
or at the next poll). Tern gives plugins no pane widths, so the block
reports its own (`cols:<pane>`, written from its `resize` hook) and the
split's ratio is steered until it matches, measuring again after each
round; a canvas's split width comes from `tern inspect --json` instead (see
`narrow` in `window.luau`). Sizes reach plugins only while Tern's window is
frontmost, so a side pane brought along in the background (auto-advance)
can keep its old width until the next move.

**Toggle side pane** hides every side pane when one is in the current tab,
and keeps them hidden: going to an agent no longer brings one along. Run it
again (from any tab) to bring the side pane beside the focused pane. Split
right with the side pane focused splits the pane right of it instead of the
side pane. A tiled side pane left alone in its tab (its agent's pane closed)
is closed at the next poll, which closes the tab.

A floating canvas needs a click to grow before its buttons work, which is
why docking comes first; use the keys there. While floating, a canvas renders
a compact card (state, folder and branch, the summary or else the task, your
last prompt, how many more are waiting and running, Skip / Done / Next);
docked, the full view. Plugins can't size a picture in picture (there is no
API for it).

### Picker

**Agent queue: pick an agent** opens a picker that fills the tab: every omp
agent as a card (its scene, title, session › tab, what it is on), grouped
like the side pane's lists: **Waiting** (the queue, in order; "asks" on
agents asking a question), **Running** and **Done**, each a heading over its
own rows. The current agent is selected first. A card without a scene (one
not drawn yet, or an agent never queued since scenes came in) shows a box
the same size with the project's folder name. Typing searches: each group
keeps the agents whose title, session › tab, folder, branch, task or summary
contain every typed word, ignoring
case, and the first match is selected. Backspace deletes a character, ⌘⌫
or ⌃U clears the search. Arrows move the selection (up and down cross from
group to group in the same column), Enter (or a click on a card) goes to
that agent as **Go to** does, Esc clears the search, or with none closes
the picker (zooming back the pane the tab was zoomed on, if any). It also
closes when focus leaves it, and running the command from it closes it.

The picker is a block of this machine (`new_block` opens blocks on the
window's current host, and remote hosts don't run this plugin), so from a
session on a remote host it switches the window to this
machine's last session and opens there; Esc goes back to the remote pane.

The search box is drawn by the picker and fed by its key handler rather
than a native text field, so the arrows and Enter keep working on the grid
while you type.

It opens as a split beside the focused pane, zoomed: a picture in picture
would float, but plugins can't size one and its default (about 83×22 cells)
is too small for the grid. Cards are at least 40 columns wide, up to five to
a row; scenes are cropped to 2:1, so a card's height follows its width and
`lib/picker.luau` works out how many rows fit (a group's heading counts,
and the top row shown always gets its group's), scrolling a row at a time
to keep the selection in view (the search line counts the rows out of
view). The
picker is a plugin block (`agent-queue.picker`) reading its model from
`tern.kv` (`picker:<pane>`) like the side pane; `agent-queue.css` lays out
the search box and grid and rings the selection.

### Scenes

Each queued or Done session gets a small illustrated scene at the top of its
card, so you can tell at a glance which agent you're on. The plugin runs
`omp -p --model smol --tools generate_image,bash` (your omp image model)
with the job's instructions as the system prompt (in the user message the
model took them for an injection and refused about 4 times in 10) and, as
the request, the session's title (omp's pane title, icon dropped), the
project's folder name, its branch and the first prompt, which it pictures
rather than acts on. The model first picks one visual
metaphor that acts out what the session is doing (a drone stitching a torn
sail for a bug fix, say; no screens of code or people at computers), then
draws it as a bold flat vector poster: one big silhouette, two or three
flat colors, 16:9 with the subject in the middle band (the picker crops to
2:1), no text, on a solid background in the project's color. The color is
picked from a list of plain hues by a hash of the project name, so a
project's sessions share a color (some projects share one too). At card
size, neon cyberpunk was all black with one glow, which is why it went;
clay dioramas were nearly as distinct, retro sci-fi too busy. `sips` then
shrinks it to a 480 px JPEG under `<plugin data>/scenes/`.

- One at a time, queued sessions (head first) then Done ones, about 40 s
  each, 3 min timeout; two failures and a session is skipped until a reload
  (the log says why).
- Kept until the pane goes for good; a new first prompt in the same pane (a
  new session) gets a new scene. `SCENE_VERSION` in `window.luau` is part of
  each scene's fingerprint, so bumping it after changing the prompt redraws
  each queued and Done session's scene; until then, and for Running agents,
  the old one stays.
- On by default; **Agent queue: toggle scenes** turns them off. Each scene
  is one image-model call and sends the session's first prompt to that
  model's provider. macOS only (`sips`).

### Summaries

When an agent enters the queue, the plugin runs `omp -p --model smol` (your
omp smol role) in the background on its recent conversation: the last 20
messages, each clipped to head and tail, about 8k characters, plus the
previous summary and the first prompt. The model answers with JSON
`{now, status}`. The docked card shows `now`; the floating card adds
`status`. A long session's card therefore follows what the agent is on now,
not what the session started as.

- Runs off the UI thread, at most 2 `omp` processes, 30 s timeout, head of the
  queue first; an unchanged conversation isn't summarized again. **Refresh** on
  the card re-runs it. Agents already queued are filled in one per poll.
- `omp` is looked up in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
  then `PATH`. If it can't start, summaries stay off for that window until a
  reload and the log says why.
- On by default; **Agent queue: toggle summaries** turns them off. Each run
  sends that conversation text to your smol model's provider.
- Queued agents only; Running agents aren't summarized.

## Commands and keys

| Palette | Default chord (macOS / other) | Action |
| --- | --- | --- |
| Agent queue: toggle side pane | `cmd+alt+shift+i` / `ctrl+alt+shift+i` | `plugin.agent-queue.toggle` |
| Agent queue: pick an agent | `cmd+alt+shift+l` / `ctrl+alt+shift+l` | `plugin.agent-queue.pick` |
| Agent queue: next agent | `cmd+alt+shift+j` / `ctrl+alt+shift+j` | `plugin.agent-queue.next` |
| Agent queue: done with this agent | `cmd+alt+shift+k` / `ctrl+alt+shift+k` | `plugin.agent-queue.done` |
| Agent queue: toggle auto-advance | none | `plugin.agent-queue.auto` |
| Agent queue: toggle summaries | none | `plugin.agent-queue.summaries` |
| Agent queue: toggle scenes | none | `plugin.agent-queue.scenes` |

Rebind in `settings.json` `keybinds`, e.g. `"cmd+;": "plugin.agent-queue.next"`.

## Layout

| File | Role |
| --- | --- |
| `window.luau` | Polling, context fetching, scenes, side pane placement and rendering, the picker, status, commands |
| `host.luau` | The side pane and picker blocks: show the model the window publishes, send clicks and picks back |
| `agent-queue.css` | The picker's grid and selection ring |
| `lib/queue.luau` | Pure queue rules (no `tern` calls) |
| `lib/view.luau` | Side pane and picker trees built with `tern.ui` |
| `lib/summary.luau` | Summary prompt and output parsing (no `tern` calls) |
| `lib/layout.luau` | A split's width in columns from `tern inspect --json` (no `tern` calls) |
| `lib/picker.luau` | The picker's grid and search: cards per row, arrow moves, scrolling, matching (no `tern` calls) |
| `tests/run.luau` | Tests for the pure modules, run with plain `luau` |

State lives in `tern.kv` (`<state>/plugin-data/agent-queue/kv.json`). Each
window keeps its own queue (with the first prompt and the summary per pane)
under `store:<its session names>`: windows see different sessions and spell
pane ids differently, so one shared queue would fight itself. A reload or
restart picks the window's queue back up. Adding, renaming or closing a
session changes that key; the next load then moves the saved queue sharing
the most agents with the window to the new key (read from `kv.json`
directly, as `tern.kv` can't list keys), so order and Done marks survive. The
auto-advance and summaries switches, the side pane's width (`side_cols`)
and whether it is hidden (`side_hidden`) are shared.

## Development

```sh
tern plugin link ./agent-queue
tern plugin types ./agent-queue   # regenerate tern.d.luau after upgrading Tern
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau \
  window.luau host.luau lib/*.luau tests/run.luau
luau tests/run.luau               # from this directory; exits non-zero on failure
```

Plugin log lines (`tern.log.warn`) land in `~/Library/Logs/Tern/tern.log`.

## Limits

- Desktop only: depends on `cx.agents`, plugin blocks and `cx.canvas`; branch
  uses `cx.git`; scenes use `sips` (macOS).
- Agent state comes from omp's progress reporting; no state-change event
  exists, hence the poll.
- Tern gives each callback 50 ms (a command's availability check 4 ms) and
  turns a hook off until `tern plugin reload` after one overrun; the log says
  "disabled until reload". Listing agents alone takes 15-25 ms with many
  sessions, more when the machine is busy, so the poll only updates the
  queue, and going to an agent, transcript reads and renders each run as
  their own timer call (renders reuse the poll's agent list). A slow list can
  still trip it; then the next focus change or canvas click more than 20 s
  later notices the poll stopped and runs `tern plugin reload`, which
  reloads every plugin (logged as "no poll for N s … reloading plugins").
  Until you switch panes or click the canvas, the queue stays frozen.
- The first prompt is read from the last 50 transcript messages the first
  time the plugin sees a pane, so a long session's "Task" may be a later one.
- A turn that finishes within 15 s of the agent last finishing, too quickly
  for the poll to see it working, keeps the agent's place: Tern reports the
  last message seconds after the state (7 s seen), so a message change that
  early reads as the report catching up. A reply identical to the previous
  one is likewise missed.
- Hosts are told apart by the host tag Tern keeps above bit 44 of window
  pane ids (documented under Limits in the SDK).
