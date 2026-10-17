"""A piece the hold cannot take: flagged, reported to the planner, and looked at again only when it could fit.

This is the lifecycle that went wrong in the game: the flag was dropped each time the hold changed at all, and
the operator fetched the same box again and again. It is flagged once now, and stays flagged while other cargo is
loaded or moved about, until something comes off the hold or it is another boat.
"""

import pytest

from tests.lua_harness import FakeArea, FakeCargo, FakeItem, GameObject, load_mod

BOX = (0x11112222, 0x33334444, 0x55556666, 0x77778888)
BOX_TEXT = "11112222333344445555666677778888"  # the same four numbers, as the script writes a GUID


@pytest.fixture
def mod():
    return load_mod()


def site_of(mod, hold, boat):
    return mod.lua.eval("function(hold, boat) return { hold = hold, boat = boat } end")(hold, boat)


def pallet(number):
    return FakeItem(guid=(number, 0, 0, 0), name=f"Pallet {number}")


def loadfail(mod):
    path = next(mod.folder_path.rglob("loadfail.txt"), None)
    return set(path.read_text().split()) if path else set()


def test_a_piece_that_does_not_fit_is_flagged_and_reported_to_the_planner(mod):
    hold, boat = FakeArea(pieces=[(pallet(1), 0, 0, 0, 4, 4, 4)]), GameObject("BP_Cargo_Boat_2_C")
    cargo = FakeCargo(FakeItem(guid=BOX, name="Box With Equipment"))
    mod.g.MarkNoRoom(site_of(mod, hold, boat), cargo)
    assert loadfail(mod) == {BOX_TEXT}
    assert any("does not fit" in line for line in mod.printed)


def test_the_hold_s_free_room_is_counted_in_cells(mod):
    hold = FakeArea(size=(12, 12, 4), pieces=[(pallet(1), 0, 0, 0, 4, 4, 4), (pallet(2), 4, 0, 0, 4, 2, 1)])
    assert mod.g.HoldFree(site_of(mod, hold, GameObject())) == 12 * 12 * 4 - 64 - 8


def test_it_stays_flagged_while_other_cargo_is_loaded_or_moved_about(mod):
    boat = GameObject("BP_Cargo_Boat_2_C")
    first, second = pallet(1), pallet(2)
    hold = FakeArea(pieces=[(first, 0, 0, 0, 4, 4, 4), (second, 4, 0, 0, 4, 4, 4)])
    site = site_of(mod, hold, boat)
    mod.g.MarkNoRoom(site, FakeCargo(FakeItem(guid=BOX)))
    # the pieces are moved about: the same room is free
    hold.set_pieces([(first, 0, 8, 0, 4, 4, 4), (second, 8, 0, 0, 4, 4, 4)])
    mod.g.RefreshNoRoom(site)
    assert loadfail(mod) == {BOX_TEXT}
    # another piece is loaded: less room than before
    hold.set_pieces([(first, 0, 8, 0, 4, 4, 4), (second, 8, 0, 0, 4, 4, 4), (pallet(3), 4, 4, 0, 4, 4, 4)])
    mod.g.RefreshNoRoom(site)
    assert loadfail(mod) == {BOX_TEXT}


def test_it_is_looked_at_again_when_something_comes_off_the_hold(mod):
    boat = GameObject("BP_Cargo_Boat_2_C")
    first, second = pallet(1), pallet(2)
    hold = FakeArea(pieces=[(first, 0, 0, 0, 4, 4, 4), (second, 4, 0, 0, 4, 4, 4)])
    site = site_of(mod, hold, boat)
    mod.g.MarkNoRoom(site, FakeCargo(FakeItem(guid=BOX)))
    hold.set_pieces([(first, 0, 0, 0, 4, 4, 4)])  # the second pallet is taken off
    mod.g.RefreshNoRoom(site)
    assert loadfail(mod) == set()  # the planner is told to plan for the box again


def test_it_is_looked_at_again_on_another_boat(mod):
    hold = FakeArea(pieces=[(pallet(1), 0, 0, 0, 4, 4, 4)])
    mod.g.MarkNoRoom(site_of(mod, hold, GameObject("BP_Cargo_Boat_2_C")), FakeCargo(FakeItem(guid=BOX)))
    mod.g.RefreshNoRoom(site_of(mod, hold, GameObject("BP_Cargo_Boat_3_C")))
    assert loadfail(mod) == set()


def test_the_report_is_emptied_when_the_mod_starts():
    mod = load_mod(files={"SasLogistics/loadfail.txt": BOX_TEXT + "\n"})
    assert loadfail(mod) == set()  # an old report must not hide a piece for ever


def test_a_piece_turned_where_it_stands_is_seen_as_changed(mod):
    # Turned a quarter, a 4x2 piece covers 2x4 cells from the same corner: the picture of the area must follow.
    piece = pallet(1)
    hold = FakeArea(pieces=[(piece, 0, 0, 0, 4, 2, 1, 0.0)])
    before = mod.g.CachedBoxes(hold)
    assert (before[piece.GetAddress()].size.X, before[piece.GetAddress()].size.Y) == (4, 2)
    hold.set_pieces([(piece, 0, 0, 0, 2, 4, 1, 90.0)])
    after = mod.g.CachedBoxes(hold)
    assert (after[piece.GetAddress()].size.X, after[piece.GetAddress()].size.Y) == (2, 4)


def test_the_picture_of_an_unchanged_area_is_kept(mod):
    hold = FakeArea(pieces=[(pallet(1), 0, 0, 0, 4, 4, 4)])
    assert mod.g.CachedBoxes(hold) is not None
    first = mod.g.CachedBoxes(hold)
    second = mod.g.CachedBoxes(hold)
    same = mod.lua.eval("function(a, b) return rawequal(a, b) end")
    assert same(first, second)  # the very same table, not read all over again
