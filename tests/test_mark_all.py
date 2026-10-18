"""Load all / Unload all: Ctrl+Alt+L marks every piece on the docks near the boat to go aboard, Ctrl+Alt+U marks
everything in the boat's hold to go ashore. They make the same marks F5 makes by hand; pressing again, when
everything is already marked, takes the marks off."""

import pytest

from tests.lua_harness import FakeArea, FakeCargo, FakeItem, Vec, load_mod


class Placed:
    """A fake with a place in the world."""

    def K2_GetActorLocation(self):
        return Vec(X=self.at[0], Y=self.at[1], Z=self.at[2])


class PlacedCargo(Placed, FakeCargo):
    pass


class PlacedArea(Placed, FakeArea):
    pass


def guid_text(number):
    return f"{number:08X}" + "0" * 24


def world(mod, hold_pieces=2, dock_pieces=3, far_pieces=1):
    """A hold at the origin with some pieces in it, a dock area beside it with some on the dock, and one
    piece on a dock area a long way off (another port)."""
    hold = PlacedArea(pieces=[], class_name="BP_BoatCargoArea_C")
    hold.at = (0.0, 0.0, 0.0)
    dock = PlacedArea(pieces=[], class_name="BP_CargoMissionSpawnArea_Heavy_C")
    dock.at = (1500.0, 0.0, 0.0)
    far = PlacedArea(pieces=[], class_name="BP_CargoMissionSpawnArea_Heavy_C")
    far.at = (500000.0, 0.0, 0.0)
    cargo, number = [], 0
    for count, area in ((hold_pieces, hold), (dock_pieces, dock), (far_pieces, far)):
        for _ in range(count):
            number += 1
            piece = PlacedCargo(FakeItem(guid=(number, 0, 0, 0), name=f"Piece {number}"))
            piece.CargoArea = area
            piece.at = area.at
            cargo.append(piece)
    mod.g.CargoList = mod.table(cargo)
    mod.lua.execute("function FindAllOf(name) if name == 'HeavyCargo' then return CargoList end end")
    return hold, cargo


@pytest.fixture
def mod():
    return load_mod()


def marks(mod):
    manual = mod.test.GetManual()
    return {k: manual[k] for k in manual.keys()}


def test_load_all_marks_every_piece_on_the_docks_near_the_boat(mod):
    hold, _ = world(mod)
    marked, total = mod.test.MarkAll("load", hold)
    assert (marked, total) == (3, 3)
    assert marks(mod) == {guid_text(n): "load" for n in (3, 4, 5)}  # not the two in the hold, not the far one


def test_unload_all_marks_everything_in_the_hold(mod):
    hold, _ = world(mod)
    marked, total = mod.test.MarkAll("unload", hold)
    assert (marked, total) == (2, 2)
    assert marks(mod) == {guid_text(1): "unload", guid_text(2): "unload"}


def test_pressing_again_takes_the_marks_off(mod):
    hold, _ = world(mod)
    mod.test.MarkAll("load", hold)
    marked, total = mod.test.MarkAll("load", hold)
    assert (marked, total) == (-3, 3) and marks(mod) == {}


def test_a_partly_marked_set_is_completed_not_cleared(mod):
    hold, _ = world(mod)
    mod.test.GetManual()[guid_text(3)] = "load"  # one piece marked by hand with F5
    marked, total = mod.test.MarkAll("load", hold)
    assert (marked, total) == (3, 3) and len(marks(mod)) == 3


def test_load_and_unload_marks_are_kept_apart(mod):
    hold, _ = world(mod)
    mod.test.MarkAll("load", hold)
    mod.test.MarkAll("unload", hold)
    assert marks(mod) == {guid_text(1): "unload", guid_text(2): "unload", guid_text(3): "load", guid_text(4): "load",
                          guid_text(5): "load"}


def test_nothing_to_mark_is_reported_as_nothing(mod):
    hold, _ = world(mod, hold_pieces=0, dock_pieces=0, far_pieces=1)
    assert mod.test.MarkAll("load", hold) == (0, 0)
    assert mod.test.MarkAll("unload", hold) == (0, 0)
    assert marks(mod) == {}
