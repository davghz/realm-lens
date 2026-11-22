# Realm Lens

A native macOS workbench for [Realm](https://github.com/davghz/realm) spaces with embedded agent terminals
and goal orchestration.

Two surfaces:

- **Menu bar** — ambient presence. `realm ✓3 ?1 ✗1 @2`. Answers "is anything working,
  is anything stuck" without opening a window.
- **Window** — two modes. **Terminals is the default and comes first**, because this is a
  workbench: it is where you drive agents. The graph is a reference you consult.
  - **Terminals** — real agent CLIs in real PTYs, each roped to an orchestrator panel.
    Answers "who is working, on what, and is anyone stalled". Panes are pre-authorized
    with each CLI's own auto-approve switch, and a pane stopped at an update or
    workspace-trust prompt says so in its header instead of looking busy.
  - **Graph** — nodes and dependency edges. Answers "what does the space believe".

## Build

```sh
./build.sh            # release, default
./build.sh debug
./build.sh test
open dist/RealmLens.app
```

Requires macOS 15 or later, a Swift 6 toolchain, and the Realm CLI on your login shell’s PATH. Install and sign in to each agent CLI you intend to use. Build and test commands pass a minimal environment to SwiftPM plugins.

The downloadable Apple silicon app is ad-hoc signed and runs outside the App Sandbox so it can start the agent CLIs installed on your Mac. You can also build it locally with the commands above.

## Run a goal

In Terminals, choose an **Orchestrator** and one or more **Workers**, enter a goal,
and select **Run Goal**. The orchestrator opens in the large pane and plans one
task per worker. Realm delivers each assignment to that worker’s interactive CLI
and passes its findings to the next worker. Click any pane to enlarge it and type
directly into its terminal. **Show workspace terminals** opens your manual sessions.
**Show goal terminals** returns to the goal pane you last selected. **Add workspace
terminal** opens and focuses a new manual session.

**Full access (YOLO)** is on by default for goals. It launches each selected CLI
with its full-access flag and accepts recognized workspace-trust and bypass
confirmations. Turn it off to answer permissions in each CLI. **Per turn** sets
the time limit for each agent, initially 15 minutes. **Open Report** opens the
record of the goal and its handoffs. **Cancel Run** stops an active run.

## Terminals

Each pane runs one agent CLI with its own `REALM_AGENT`, so attribution and lease
ownership are correct without typing anything:

```sh
/bin/zsh -lic 'exec opencode'      # REALM_AGENT=opencode
/bin/zsh -lic 'exec codex'         # REALM_AGENT=codex
/bin/zsh -lic 'exec claude'        # REALM_AGENT=claude
```

A login-interactive shell is used because agent CLIs are usually installed into a PATH
assembled by `.zshrc`/`.zprofile`, which a non-interactive process never reads. The
`exec` means the shell is *replaced* by the CLI, so there is still exactly one process
to signal.

### Ropes

Each pane's **top-leading corner** is tethered to a dock rail on the left edge of the
orchestrator panel. The rope is a live view of the **space**, not of the process table:

| Rope | Meaning |
|---|---|
| solid green, thick, `T002` label | agent holds a live lease with time left |
| solid orange + dot | lease expires in under 2 minutes |
| dashed grey | lease exists but has expired — agent is stalled |
| faint grey, `—` | no lease; agent is idle |

An agent process that is alive but holding nothing draws a faint rope, because "running"
is not "working". Colour is never the only signal: width, dash pattern, and a text label
all carry the same information.

Panes are stacked in **one column**, not a grid. A rope from a pane in a second column
would have to cross the pane in the first column to reach the dock, and a tether you
cannot follow is worse than none. Stacked vertically, every rope owns its own corridor
and no two cross.

### Process lifetime

- Panes **spawn** their agent. Agent CLIs have no attach protocol, so "attach to an
  already-running CLI" would be a lie.
- **Closing the window terminates every pane**, because an agent whose window is gone can
  keep renewing leases and writing nodes nobody is watching. The toolbar says so in
  orange while anything is running.
- Switching between Graph and Terminals does **not** terminate anything.
- Shutdown signals the child's **process group** (`SIGTERM`, then `SIGKILL`), so helpers
  an agent forked die too, and then **reaps** it. SwiftTerm's own terminate path closes
  its I/O before the exit monitor fires, leaving the child a permanent zombie — a real
  bug found by probe, not assumed.

Probes for all of the above are in `Sources/Probe/`.

## Reading a space

The reader is read-only-first and refuses a hot journal rather than rolling it back:

```
1. <db>-journal exists and is non-empty  ->  refuse, touch nothing
2. SQLITE_OPEN_READONLY, probe user_version
3. if READONLY cannot attach the WAL     ->  re-check hot journal, then READWRITE + query_only
```

`PRAGMA query_only=ON` blocks statement writes but is **not** a no-recovery guarantee, so
it is only the fallback, and only after the hot-journal check.

`sqlite3_step` errors propagate. `while sqlite3_step(...) == SQLITE_ROW` treats
`SQLITE_CORRUPT` as "no rows" — a truncated database used to render as an empty, healthy
graph with exit 0.

## Pointing it at a space

```sh
defaults write dev.realm.lens "realm.spacePath" -string "/path/to/.realm"
open -a RealmLens --args --show-window
```

On first launch, use **Choose space…** to select a project initialized with `realm init`. The app remembers your choice. Hidden folders are shown, because `.realm`
starts with a dot and would otherwise be unreachable.

## Layout

| Path | What |
|---|---|
| `Sources/RealmLensCore/` | reader, no SwiftUI/AppKit. Queries the workspace database. |
| `Sources/realm-lens/` | headless JSON dump of the reader's model |
| `Sources/RealmLens/` | the app |
| `Sources/Probe/` | headless PTY lifetime probes |

`RealmLensCore` and the headless reader have **no dependencies**. SwiftTerm is linked
into the GUI target.

## Prompt detection, corrected against real CLIs

Pre-authorizing permissions removes permission prompts, but two other blockers remain and
both look identical to a working pane from the outside. Installing the app against real
CLIs exposed **three** defects in the first version of the detector, each now covered by a
probe:

1. **Repaints counted as activity.** A TUI waiting at a dialog keeps redrawing its box
   borders. Treating any complete line as "work resumed" meant the flag was detected and
   then immediately cleared, so it was off almost all the time. Repaints are the PTY's
   heartbeat, not evidence of progress; a line now counts only if it carries at least two
   meaningful non-box-drawing characters.
2. **One vendor's wording.** The trust rule required `"trust this folder"` *and*
   `"no, exit"` — Claude's phrasing. Codex says `"Trust this folder?"` with numbered
   options and Antigravity says `"Do you trust the contents of this project?"`, so both
   showed **no badge while blocked**. The rule now matches the subject (trust + folder /
   project / workspace) plus a question, which is structural rather than sentence-specific.
3. **A numbered option was required.** Claude's choices are unnumbered (`> No, exit`), so
   requiring a numbered menu missed the dialog that motivated the feature.

Triple-checked behaviour: all three trust dialects detected; a passive `"update available"`
banner is *not* a prompt while a real update **menu** is; detection is independent of PTY
chunk boundaries (all 38 two-chunk splits plus bytewise delivery); a prompt survives
repaints and clears on real work.

With **Full access** enabled, goal terminals confirm recognized workspace-trust and full-access startup prompts. Other prompts stay available in the native terminal.
