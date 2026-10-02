# ActionbarSaveFix

Keeps item and macro buttons on your action bars on private servers that fail to
persist them.

Some private/emulated server implementations save spell actions reliably but lose
item and macro actions across a relog. This addon keeps its own record of your
bar layout and puts the missing buttons back.

Spells are server-authoritative and are never touched.

## Install

1. Unzip the archive.
2. Put the `ActionbarSaveFix` folder in `World of Warcraft/_classic_era_/Interface/AddOns/`.

You should end up with:

```
Interface/AddOns/ActionbarSaveFix/ActionbarSaveFix.lua
Interface/AddOns/ActionbarSaveFix/ActionbarSaveFix.toc
```

3. Start the game and enable it in the AddOn list.

## Usage

There is nothing to configure. Re-arrange your bars as much as you like — drag,
remove, swap, whatever. No manual saving step exists or is needed. If the server
drops your buttons, the addon notices and puts them back.

State is stored per character and saved on logout.

## Commands

Everything here is optional and only needed if you want to inspect or override
something. The addon prints nothing during normal play.

| Command | Effect |
|---|---|
| `/abfix` | Show the command list |
| `/abfix status` | Show saved / present / missing slot counts and names |
| `/abfix sync` | Force a reconcile and repair pass now |
| `/abfix restore` | Force a repair pass now |
| `/abfix learn` | Overwrite the snapshot from your bars as they are now |
| `/abfix drop <slot>` | Stop tracking one slot, so it will never be repaired |
| `/abfix sound off\|sfx\|all` | Control sound suppression during restore (default `sfx`) |
| `/abfix verbose on\|off` | Show/hide background diagnostic logging (default off) |

### Notes on two commands

**`/abfix drop <slot>`** — the snapshot is append-only, so a slot you deliberately
clear stays tracked and will be repaired. In practice you rarely need this,
because a slot you clear yourself is normally recognised as your own edit and left
alone. It exists as an escape hatch for when that distinction goes wrong.

**`/abfix sound`** — restoring has to move each action via the cursor
(`PickupItem`/`PickupMacro` then `PlaceAction`), which plays the "Pick Up / Put
Down" sound. There is no cursor-free way to write an action slot in this client,
so SFX is muted for the duration of the placement pass instead. Your existing
sound settings are always preserved — if you already had SFX off, it stays off.
Use `off` if you would rather it not touch sound at all.

## How it works

Two independent watchers detect changes to your bars:

- **`ACTIONBAR_SLOT_CHANGED`** — the client's own event, which reports the slot
  that changed. This is how the addon tells "the player just edited this" apart
  from "the server lost this", which otherwise look identical.
- **A slow 5-second poll** — a safety net. A server-side drop may not raise any
  UI event at all, so polling is what catches the failure mode that actually
  matters.

Changes you make are recorded as your intended layout. Changes that arrive with
no player action behind them are treated as damage and repaired.

Two safeguards exist so it never fights you:

- A slot you touched in the last few seconds is not repaired.
- Nothing at all runs while your cursor is occupied. Mid-drag, the empty slot you
  dragged from is in your hand rather than lost, and touching the cursor there
  would destroy the item you are moving.

## Compatibility

Written for WoW Classic Era, interface `11402`.

It relies on Classic Era's `PlaceAction(slot)`, which takes a **single** argument
and drops whatever is on the cursor into that slot. The retail-style
`PlaceAction(slot, type, id)` form is silently ignored in this client and does
nothing without raising an error. If you use a different Classic flavour, the
addon may be silently ineffective rather than broken — that is the first thing to
check if buttons are not being restored.

Items that are no longer in your bags cannot be restored; this is a client
limitation, not an addon one. The addon retries and then reports it (visible
under `/abfix verbose on`).

## Credits

Author: Space Bunny Free