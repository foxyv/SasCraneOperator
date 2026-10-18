"""An operator with no character on deck: the game is asked to give her one up to three times, a few seconds
apart (the first ask can come before the world is ready), and the log says when one has appeared."""

from tests.lua_harness import FakeText, GameObject, load_mod


def member(name="Karethe Allum"):
    m = GameObject("SasCrewMember")
    m.CrewMemberName = FakeText(name)
    return m


def asks(mod):
    return [line for line in mod.printed if "has no character on deck" in line]


def test_asking_is_spaced_and_stops_after_three_tries():
    mod = load_mod()
    who, boat = member(), GameObject("BP_Cargo_Boat_2_C")
    for _ in range(5):
        mod.g.GiveAvatar(who, boat, None)  # five looks in a row, a moment apart: only the first asks
    assert len(asks(mod)) == 1 and mod.g.AvatarTries["Karethe Allum"] == 1
    for expected in (2, 3, 3):
        mod.g.AvatarAt["Karethe Allum"] -= 100  # the wait is up
        mod.g.GiveAvatar(who, boat, None)
        assert mod.g.AvatarTries["Karethe Allum"] == expected
    assert len(asks(mod)) == 3  # never a fourth


def test_two_operators_are_counted_apart():
    mod = load_mod()
    boat = GameObject("BP_Cargo_Boat_2_C")
    mod.g.GiveAvatar(member("A"), boat, None)
    mod.g.GiveAvatar(member("B"), boat, None)
    assert mod.g.AvatarTries["A"] == 1 and mod.g.AvatarTries["B"] == 1
