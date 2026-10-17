"""Taking cargo off to make room.

The planner lists in removable.txt the pieces aboard that it would leave on the dock at this port anyway. When a
piece to load cannot be fitted even by rearranging, the biggest of those still in the hold is taken off and the
loading tried again. Nothing else is ever taken off, and nothing is taken off that is not needed.
"""

import pytest

from tests.lua_harness import FakeArea, FakeCargo, FakeItem, GameObject, load_mod
from tests.test_no_room import site_of


def guid_text(number):
    return f"{number:08X}" + "0" * 24


def piece(number):
    return FakeItem(guid=(number, 0, 0, 0), name=f"Piece {number}")


def hold_with(mod, pieces, removable, elsewhere=()):
    """A hold holding the pieces ((item, x, y, z, size x, y, z) each) and the world's cargo list with them
    (and any `elsewhere`, which stands in another area); the planner's list names `removable` numbers."""
    hold = FakeArea(pieces=pieces)
    other = FakeArea(pieces=[], class_name="BP_CargoArea_C")
    cargo = []
    for item, *_ in pieces:
        cargo.append(FakeCargo(item))
        cargo[-1].CargoArea = hold
    for item in elsewhere:
        cargo.append(FakeCargo(item))
        cargo[-1].CargoArea = other
    mod.g.CargoList = mod.table(cargo)
    mod.lua.execute("function FindAllOf(name) if name == 'HeavyCargo' then return CargoList end end")
    path = mod.folder_path / "SasLogistics" / "removable.txt"
    path.write_text("".join(guid_text(n) + "\n" for n in removable))
    return hold, site_of(mod, hold, GameObject("BP_Cargo_Boat_2_C"))


@pytest.fixture
def mod():
    return load_mod()


def test_the_removable_file_is_read_ignoring_what_is_not_a_guid(mod):
    (mod.folder_path / "SasLogistics" / "removable.txt").write_text(
        f"{guid_text(1)}\n{guid_text(2)}  \n\nSHORT\n{guid_text(3)} U\n{guid_text(4).lower()}\n")
    assert set(mod.g.ReadRemovable().keys()) == {guid_text(1), guid_text(2), guid_text(4)}  # "... U" is not a line it knows


def test_nothing_is_taken_off_when_nothing_is_removable(mod):
    _, site = hold_with(mod, [(piece(1), 0, 0, 0, 4, 4, 4)], removable=[])
    assert mod.g.TakeOffForRoom(site) is None


def test_the_biggest_removable_piece_in_the_hold_goes_first(mod):
    big, small, tall = piece(1), piece(2), piece(3)
    _, site = hold_with(mod, [(small, 0, 0, 0, 4, 2, 1), (big, 4, 0, 0, 4, 4, 4), (tall, 0, 4, 0, 2, 2, 4)],
                        removable=[1, 2, 3])
    taken = []
    while True:
        cargo = mod.g.TakeOffForRoom(site)
        if cargo is None:
            break
        taken.append(cargo.GetRepresentedInventoryItem().name)
    assert taken == ["Piece 1", "Piece 3", "Piece 2"]  # 64 cells, then 16, then 8: each taken once


def test_only_pieces_the_planner_named_and_that_are_in_the_hold_are_taken(mod):
    named, not_named, on_the_dock = piece(1), piece(2), piece(3)
    _, site = hold_with(mod, [(named, 0, 0, 0, 4, 4, 4), (not_named, 4, 0, 0, 4, 4, 4)], removable=[1, 3],
                        elsewhere=[on_the_dock])
    first = mod.g.TakeOffForRoom(site)
    assert first.GetRepresentedInventoryItem().name == "Piece 1"
    assert mod.g.TakeOffForRoom(site) is None  # piece 2 was not named, piece 3 is not in the hold


def test_the_pieces_taken_off_are_added_to_the_unloads(mod):
    _, site = hold_with(mod, [(piece(1), 0, 0, 0, 4, 4, 4)], removable=[1])
    assert mod.g.TakeOffForRoom(site) is not None
    unload = mod.table({})
    mod.g.ApplyActivated(unload)
    assert set(unload.keys()) == {guid_text(1)}
