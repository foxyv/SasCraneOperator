"""An operator with no character on deck: the game is asked to give her one up to three times, a few seconds
apart (the first ask can come before the world is ready), and the log says when one has appeared."""

from tests.lua_harness import FakeText, GameObject, load_mod


def member(name="Karethe Allum"):
    m = GameObject("SasCrewMember")
    m.CrewMemberName = FakeText(name)
    return m


def asks(mod):
    return [line for line in mod.printed if "has no character on deck" in line]


def test_asking_is_spaced_then_slower_and_stops_after_twelve_tries():
    mod = load_mod()
    who, boat = member(), GameObject("BP_Cargo_Boat_2_C")
    for _ in range(5):
        mod.g.GiveAvatar(who, boat, None)  # five looks in a row, a moment apart: only the first asks
    assert len(asks(mod)) == 1 and mod.g.AvatarTries["Karethe Allum"] == 1
    for expected in list(range(2, 13)) + [12, 12]:
        mod.g.AvatarAt["Karethe Allum"] -= 100  # the wait is up
        mod.g.GiveAvatar(who, boat, None)
        assert mod.g.AvatarTries["Karethe Allum"] == expected
    assert len(asks(mod)) == 12  # never a thirteenth


def test_after_the_quick_tries_the_wait_between_asks_is_longer():
    mod = load_mod()
    who, boat = member(), GameObject("BP_Cargo_Boat_2_C")
    for _ in range(3):
        mod.g.GiveAvatar(who, boat, None)
        mod.g.AvatarAt["Karethe Allum"] -= 10  # more than the quick wait
    mod.g.GiveAvatar(who, boat, None)
    assert mod.g.AvatarTries["Karethe Allum"] == 3  # but not enough for the slow one
    mod.g.AvatarAt["Karethe Allum"] -= 30
    mod.g.GiveAvatar(who, boat, None)
    assert mod.g.AvatarTries["Karethe Allum"] == 4


def test_two_operators_are_counted_apart():
    mod = load_mod()
    boat = GameObject("BP_Cargo_Boat_2_C")
    mod.g.GiveAvatar(member("A"), boat, None)
    mod.g.GiveAvatar(member("B"), boat, None)
    assert mod.g.AvatarTries["A"] == 1 and mod.g.AvatarTries["B"] == 1
