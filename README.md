# SasCraneOperator

A crew member who works the crane for your cargo boat in Ships At Sea, as a UE4SS Lua mod.

## What it does

Every cargo boat gets a **Crane Operator** position in its crew chart. On the class 1 and class 2
cargo boats it is their only crew position; on the class 3 cargo ship it sits alongside the ship's
own Engineering positions. Put a hired crew member in it and, whenever the boat is docked, they load
and unload the cargo that has been marked, one piece at a time:

- **The class 1 and 2 boats** use the dock crane beside their hold.
- **The class 3 cargo ship** uses its own deck cranes, one or two, never the dock's. Large-container
  docks have no crane of their own, so this is how large containers get on and off.

Cargo gets marked in two ways:

- **By the planner.** If you use [Ships At Sea Logistics](https://github.com/foxyv/ShipsAtSeaLogistics),
  the operator works through its list for the port you are in: what the route unloads here, and what
  it loads. Take loads out of the warehouse yourself as usual.
- **By hand.** Look at a piece of crane cargo and press **F5**. A piece on the dock is marked to go
  to the boat, a piece in the hold to go to the dock. It gets a floating TO BOAT or TO DOCK marker,
  like the game's markers for a tracked mission. F5 again takes the mark off.

### How the operator works

While there is work the operator sits in the crane's seat and the crane moves. The boom goes over the
piece, the hook comes down and latches it, it is lifted, carried across, turned to face the way its
new place does, and lowered into it. A piece takes about half a minute. When the work is done the
crane is put back as it was found and the operator goes back to their place on the boat.

Along the way the operator:

- **unloads before loading**, and takes pieces from the top of a stack first;
- **moves aside anything standing on a marked piece** before lifting it, and lets down any piece
  left with nothing under it;
- **sets pieces down neatly**: squarely on top of a piece of the same size, or else in the spot on
  the floor that sits most snugly against other pieces and the area's sides;
- **puts each piece only where it belongs**: medium and large cargo go to their own dock areas;
- **brings a piece the warehouse put out somewhere no crane reaches** to the dock area by the boat
  first, with a toast;
- **on the class 3 ship, picks the crane** that can reach both where a piece is and where it is
  going, changing seats when the other crane suits it better. When neither can do the whole move,
  one brings it across the hold for the other to finish (a hand-over). A piece neither crane can get
  to is left alone, with a toast saying it is out of reach.

Unloaded cargo counts as delivered. A toast says when the operator starts and finishes, and when they
have to stop because the hold or the dock is full.

### A steadier hook on the deck cranes

The class 3 ship's cranes sometimes let a load go a moment after latching it, for the game's own
operators too. Whoever is at the controls, a load that comes off within a second and a half of
latching is latched again straight away; letting go again soon after that is taken as meant. The
crane operator also latches a load again if it comes off while still hanging by the hook.

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
   second. On the class 3 ship they can be moved between Crane Operator and Engineering both ways.
3. Dock the boat: beside a dock crane for the class 1 and 2 boats, anywhere for the class 3 ship.
   Once it is made fast, the operator starts on whatever is marked. They stop when you undock.

To take them off duty, drag them back to Resting or into another position.

## Keys

- **F5** marks or unmarks the piece of crane cargo in the middle of your view, on foot or from a
  crane's camera, up to 80 m away.
- **Ctrl+Alt+O** puts the first resting crew member of the boat you are next to on crane duty, or
  takes the operator off. It does the same as dragging in the crew chart.
- **Ctrl+Alt+H** sets where the operator waits on the boat when not at the crane: stand on the boat
  where you want them and press it. Without it they go back to wherever they last stood on the
  boat, or to the helm if that is not known.

## What it changes in the game

- **The crew position** is added to the boat while the mod runs and is not written to the save. The
  mod remembers the operator's name in `operators.txt` in its own folder and seats them again a few
  seconds after a save loads.
- **The boat type's crew limit** is raised from 0 to 1 on boats that have none, so that a crew member
  can be assigned to the boat at all.
- **Cargo** is moved with the crane's own attach and set-down calls, into a free place in the game's
  cargo grid. The crane's joints are steered so that the hook goes to the piece and carries it across.
  A piece brought to the dock by the boat is moved across unseen, the way the warehouse puts cargo out.
- **The operator** is put in the crane's seat with the crane's own driver call, and their idle
  behaviour is stopped while they sit there. While they are in the seat the crane is in use, so you
  cannot climb in until they finish. A waiting place set with Ctrl+Alt+H is kept in `spots.txt` in
  the mod's folder.
- **The deck cranes' hook** is latched again when it lets a load go just after latching (see above).

## Limits

- The crane does not look out for what is in the way. Before a long swing it lifts the load high
  (the deck cranes to about 7 m above their foot), which clears most cargo, but a load can still meet
  a tall stack or part of the boat.
- A piece keeps the way it faced when it was picked up, turned to match its new place; it is not
  turned a quarter round to line up with its neighbours.
- Only the stationary dock crane and the class 3 ship's deck cranes are moved. At any other kind of
  crane a piece is lifted where it stands and appears where it is set down.
- The operator does not walk to the crane or back; they appear in the seat and back on the boat. The
  cargo boats' decks have no walkable route for crew.
- Crane cargo only (pallets, crates, containers and the like), not boxes carried by hand.
- The operator does not work while you are in the crane yourself.
- Marks made with F5 last for the session; they are not saved.
- F5 picks the piece whose outline the centre of your view passes through. It does not know what is
  in the way, so when two pieces line up it picks the nearer one.
- Tested in solo play, on the class 2 cargo boat with the stationary dock cranes and on the class 3
  cargo ship with two deck cranes and no towing rig. Multiplayer is untested.

## Working on it

```
.\deploy.ps1              # copy the mod into the game; takes -GameDir for a non-default library
.\package.ps1 v0.1.0      # build the release zip into dist\
```

Ctrl+R in game reloads UE4SS Lua mods without a restart, if `EnableHotReloadSystem = 1` is set in
`ue4ss\UE4SS-settings.ini`. The mod does all its work from two timers on the game thread, one for
decisions and one for steering the crane; key presses and hooks only queue work for them.

The cranes' measurements, and what was learned about the game along the way, are in the
[Ships At Sea game notes](https://github.com/foxyv/ShipsAtSeaLogistics/blob/master/docs/SHIPS_AT_SEA_GAME_NOTES.md).

## License

MIT. See `LICENSE`.
