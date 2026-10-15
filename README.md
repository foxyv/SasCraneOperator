# SasCraneOperator

A crew member who works the crane for your cargo boat in Ships At Sea, as a UE4SS Lua mod.

## What it does

Every cargo boat gets a **Crane Operator** position in its crew chart. On the class 1 and class 2
cargo boats it is their only crew position; on the class 3 cargo ship it sits alongside the ship's
own Engineering positions. Put a hired crew member in it and, whenever the boat is docked, they load
and unload the cargo that has been marked, one piece at a time:

- **The class 1 and 2 boats** use the dock crane beside their hold.
  The boat has to be made fast to the dock, with the pull-in finished, for the dock crane to work.
- **The class 3 cargo ship** uses its own deck cranes, one or two, never the dock's. Large-container
  docks have no crane of their own, so this is how large containers get on and off. It may be
  docked, or, where the dock it needs has no place to moor beside, lying still with its engines
  off. It only puts cargo ashore at a dock area one of its cranes really reaches; otherwise the
  piece stays aboard, with a toast.

Cargo gets marked in two ways:

- **By the planner.** If you use [Ships At Sea Logistics](https://github.com/foxyv/ShipsAtSeaLogistics),
  the operator works through its list for the port you are in: what the route unloads here, and what
  it loads. Take loads out of the warehouse yourself as usual. Untick "Send orders to the crane
  operator" in the planner and the operator moves only what you mark by hand.
- **By hand.** Look at a piece of crane cargo and press **F5**. A piece on the dock is marked to go
  to the boat, a piece in the hold to go to the dock. It gets a floating TO BOAT or TO DOCK marker,
  like the game's markers for a tracked mission. F5 again takes the mark off. While an operator is
  on duty nearby, the piece you are looking at shows a hint saying what F5 will do with it, so with
  stacked pieces you can see which one will be picked.

### How the operator works

While there is work the operator sits in the crane's seat and the crane moves. The boom goes over the
piece, the hook comes down and latches it, it is lifted straight up off its stack, carried across,
turned the shorter way to face the way its new place does, lined up squarely over it, and lowered
into it. While a load is lifted out from among other cargo and lowered in between it, it does not
collide with it, so it does not snag. On the
deck cranes the boom is drawn in before every swing and run out again after it, so it clears the
ship's superstructure, and the load is carried high enough to clear everything under its way. A piece takes about half a minute. When the work is done the
crane is put back as it was found, along one planned route, moving smoothly through its steps, and the operator goes back to their place on the boat.

Along the way the operator:

- **unloads before loading**, does everything the cranes can reach before moving cargo around the
  dock, and takes pieces from the top of a stack first;
- **moves aside anything standing on a marked piece** before lifting it, and lets down any piece
  left with nothing under it;
- **sets pieces down neatly**: squarely on top of a piece of the same size, or else in the spot on
  the floor that sits most snugly against other pieces and the area's sides, filling an area from
  the far side in so nothing already set down is in the way;
- **puts each piece only where it belongs**: medium and large cargo go to their own dock areas;
- **brings a piece the warehouse put out somewhere no crane reaches** to the dock area by the boat
  first, with a toast, once per piece and only to a spot a crane can then pick it up from. Anything
  standing on it is moved aside first, and any piece left hanging in the air anywhere nearby is let
  down;
- **on the class 3 ship, picks the crane** that can reach both where a piece is and where it is
  going. It finishes what the crane it sits in can do before changing seats. When neither can do the
  whole move, one brings it across the hold for the other to finish (a hand-over). A piece neither
  crane can get to, or cannot lift clear of the cargo around it, is left alone with a toast.

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
   Once it is made fast, the operator starts on whatever is marked. They stop when you undock. A
   boat too big to dock where its cargo has to go can also just lie still beside the dock with its
   engines off; starting an engine counts as leaving.

To take them off duty, drag them back to Resting or into another position.

## Keys

- **F5** marks or unmarks the piece of crane cargo in the middle of your view, on foot or from a
  crane's camera, up to 80 m away.
- **Shift+F5** switches off the hint over the piece you are looking at, or back on. It stays the
  way you leave it after a restart.
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

- The crane does not plan a way around things, only over them. Before each move it traces straight
  down along the load's way, and round the arc its arm sweeps, to find the highest thing under them,
  and carries the load a metre above that (at least 20 cm when the arm cannot reach higher; otherwise
  the piece is left alone). The arm is drawn in, swung and run out in short steps at that height. If
  the crane is caught on something anyway, it lifts a metre and carries on, a few times at most.
- A rectangular piece may be turned half round to its place, so a container's doors can end up at
  the other end.
- When a piece to load does not fit, the operator works out moves across the whole hold: flat pieces
  are stacked, others slid together, until the piece has a space. Each move is a full crane job, so a
  crowded hold takes a while. It does not check that every move is within the crane's reach.
- The crane's motor sounds are played by the mod, since the operator does not use the controls. They
  start when the crane moves and stop after it has been still for a moment.
- Reloading the mod with Ctrl+R while a load is in the air can leave that one piece without its
  normal collision until the game is restarted.
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
`ue4ss\UE4SS-settings.ini`, but it has frozen or crashed the game more than once, so restart the game
to try a change. The mod does all its work from two timers on the game thread, one for decisions and
one for steering the crane; key presses and hooks only queue work for them.

For testing, the mod writes a lot to `ue4ss\UE4SS.log`: every latch attempt, why a piece was left
alone, how high a load is carried and why, hand-overs, and a `BUMP:` line each time a load on the hook
runs into other cargo, with where and in which step. It also writes a `DROP:` line for every set-down
(where the piece was let go, where it was sent, and a second later where it ended up), an `AIM:` line
for how close the hook was over a piece before it came down, `PROFILE:` and `SLOW:` lines saying
where the mod's time goes, and `HITCH:` when the game thread was away for over a second.

The cranes' measurements, and what was learned about the game along the way, are in the
[Ships At Sea game notes](https://github.com/foxyv/ShipsAtSeaLogistics/blob/master/docs/SHIPS_AT_SEA_GAME_NOTES.md).

## License

MIT. See `LICENSE`.
