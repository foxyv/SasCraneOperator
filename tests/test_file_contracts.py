"""The files the operator mod shares with the planner and the Logistics mod.

Three programs written separately talk through plain text files, and nothing else checks they agree:

  crane_orders.txt   the planner writes it, this mod reads it: one GUID a line, " U" after those to unload;
  loadfail.txt       this mod writes it, the planner reads it: one GUID a line.

Each side is tested against the same sample file (tests/fixtures/*.golden.txt, kept identical in the Logistics
repository), so a change to the format on one side fails a test on that side. The Logistics repository has the
matching tests for its end, and one that runs the two together when both repositories are side by side.
"""

import re
from pathlib import Path

from tests.lua_harness import FakeArea, FakeCargo, FakeItem, GameObject, load_mod
from tests.test_no_room import loadfail, site_of

FIXTURES = Path(__file__).parent / "fixtures"
GUID = re.compile(r"^[0-9A-F]{32}$")


def test_the_orders_file_is_read_as_the_planner_writes_it():
    # The sample has the odd lines a hand-edited or truncated file could: lower case, extra spaces, a blank line,
    # a short GUID, a long one and one that is not hexadecimal. Only the four good lines count.
    mod = load_mod(files={"SasLogistics/crane_orders.txt": (FIXTURES / "marks.golden.txt").read_text()})
    to_load, to_unload, count = mod.test.ReadMarks()
    assert set(to_load.keys()) == {"11112222333344445555666677778888", "AAAABBBBCCCCDDDDEEEEFFFF00002222"}
    assert set(to_unload.keys()) == {"AAAABBBBCCCCDDDDEEEEFFFF00001111", "0123456789ABCDEF0123456789ABCDEF"}
    assert count == 4


def test_a_missing_orders_file_means_no_orders():
    mod = load_mod()
    to_load, to_unload, count = mod.test.ReadMarks()
    assert count == 0 and not set(to_load.keys()) and not set(to_unload.keys())


def test_the_no_room_file_is_written_in_the_format_the_planner_reads():
    mod = load_mod()
    hold, boat = FakeArea(pieces=[]), GameObject("BP_Cargo_Boat_2_C")
    site = site_of(mod, hold, boat)
    mod.g.MarkNoRoom(site, FakeCargo(FakeItem(guid=(0x11112222, 0x33334444, 0x55556666, 0x77778888))))
    mod.g.MarkNoRoom(site, FakeCargo(FakeItem(guid=(0xAAAABBBB, 0xCCCCDDDD, 0xEEEEFFFF, 0x00001111))))
    written = loadfail(mod)
    assert written == set((FIXTURES / "loadfail.golden.txt").read_text().split())
    assert all(GUID.match(line) for line in written)


def test_a_guid_whose_numbers_are_negative_is_still_32_hexadecimal_digits():
    # The game hands out GUIDs as four signed 32-bit numbers; a negative one must not come out longer or short.
    mod = load_mod()
    mod.g.MarkNoRoom(site_of(mod, FakeArea(pieces=[]), GameObject("BP_Cargo_Boat_2_C")),
                     FakeCargo(FakeItem(guid=(-1, -2, 0, 7))))
    assert loadfail(mod) == {"FFFFFFFF" + "FFFFFFFE" + "00000000" + "00000007"}


def test_the_golden_files_are_what_the_tests_say_they_are():
    assert (FIXTURES / "marks.golden.txt").read_text().count("\n") == 8
    assert sorted((FIXTURES / "loadfail.golden.txt").read_text().split()) == [
        "11112222333344445555666677778888", "AAAABBBBCCCCDDDDEEEEFFFF00001111"]
