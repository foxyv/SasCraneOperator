# SasCraneOperator

A crew member who works the dock crane for your cargo boat in Ships At Sea, as a UE4SS Lua mod.

## What it does

Cargo boats that have no crew positions (the class 1 and class 2 cargo boats) get one in their crew
chart: **Crane Operator**. Put a hired crew member in it and, whenever the boat is stopped beside a
dock crane, they load and unload the cargo that has been marked, one piece about every 18 seconds.

Cargo gets marked in two ways:

- **By the planner.** If you use [Ships At Sea Logistics](https://github.com/foxyv/ShipsAtSeaLogistics),
  the operator works through its list for the port you are in: what the route unloads here, and what
  it loads. Loads have to be on the dock; move them out of the warehouse yourself as usual.
- **By hand.** Look at a piece of crane cargo and press **F5**. A piece on the dock is marked to go
  to the boat, a piece in the hold to go to the dock. It gets a floating TO BOAT or TO DOCK marker,
  like the game's markers for a tracked mission. F5 again takes the mark off.

The operator takes pieces from the top of a stack first, unloads before loading, and lets down any
piece left with nothing under it. Unloaded cargo counts as delivered. A toast says when they start
and finish, and when they have to stop because the hold or the dock is full.

## Install

You need Windows, the Steam version of Ships At Sea, and UE4SS installed first.

**1. UE4SS, experimental build.** The game runs on Unreal Engine 5.7, which the stable UE4SS
release does not support.

- Download `UE4SS_v3.0.1-<build>.zip` from
  https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest
- Extract it into the game's `SAS\Binaries\Win64` folder, next to `Sas-Win64-Shipping.exe`. You
  should end up with `dwmapi.dll` and a `ue4ss` folder there.

**2. The mod.**

1. Download `SasCraneOperator-<version>.zip` from the
   [latest release](https://github.com/foxyv/SasCraneOperator/releases/latest).
2. Extract it into the game's `SAS\Binaries\Win64\ue4ss\Mods` folder, so that
   `ue4ss\Mods\SasCraneOperator\Scripts\main.lua` exists.
3. Start the game.

To check it loaded, look in `ue4ss\UE4SS.log` for a line starting `[SasCraneOperator] loaded`.

### Uninstall

Delete `ue4ss\Mods\SasCraneOperator` from the game folder. Saves made with the mod load normally
without it; a crew member who was the operator is simply resting on the boat.

## Using it

1. Hire a crew member and assign them to the cargo boat.
2. Open the boat's crew chart and drag them onto the **Crane Operator** position. It takes about a
   second.
3. Stop the boat within 100 m of a dock crane. The operator starts on whatever is marked.

To take them off duty, drag them back to Resting.

## Keys

- **F5** marks or unmarks the piece of crane cargo in the middle of your view, on foot or from a
  crane's camera, up to 80 m away.
- **Ctrl+Alt+O** puts the first resting crew member of the boat you are next to on crane duty, or
  takes the operator off. It does the same as dragging in the crew chart.

## What it changes in the game

- **The crew position** is added to the boat while the mod runs and is not written to the save. The
  mod remembers the operator's name in `operators.txt` in its own folder and seats them again a few
  seconds after a save loads.
- **The boat type's crew limit** is raised from 0 to 1 while the mod runs, so that a crew member can
  be assigned to the boat at all.
- **Cargo** is moved with the dock crane's own attach and set-down calls, into a free place the
  game's cargo grid offers.

## Limits

- The crane's arm does not move. A piece is lifted where it stands and appears where it is set down.
- Crane cargo only (pallets, crates and the like), not boxes carried by hand.
- The operator does not work while you are in the crane yourself.
- Marks made with F5 last for the session; they are not saved.
- F5 picks the piece whose outline the centre of your view passes through. It does not know what is
  in the way, so when two pieces line up it picks the nearer one.
- Tested in solo play, on the class 2 cargo boat with the stationary dock cranes. Multiplayer is
  untested.

## Working on it

```
.\deploy.ps1              # copy the mod into the game; takes -GameDir for a non-default library
.\package.ps1 v0.1.0      # build the release zip into dist\
```

Ctrl+R in game reloads UE4SS Lua mods without a restart, if `EnableHotReloadSystem = 1` is set in
`ue4ss\UE4SS-settings.ini`. The mod does all its work from one timer on the game thread; key presses
and hooks only queue work for it.

## License

MIT. See `LICENSE`.
