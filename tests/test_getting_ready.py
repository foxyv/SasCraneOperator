"""A toast when a boat with an operator on duty docks: she is getting ready, so the wait before the crane starts
is not mistaken for a broken mod."""

from tests.lua_harness import GameObject, load_mod


class Docking:
    def __init__(self):
        self.docked = False

    def IsDocked(self):
        return self.docked


def boat():
    b = GameObject("BP_Cargo_Boat_2_C")
    b.DockingComponent = Docking()
    return b


def toasts(mod):
    return [line for line in mod.printed if "getting ready" in line]


def test_docking_says_the_operator_is_getting_ready_once():
    mod = load_mod()
    b = boat()
    mod.g.NoteDocking(b, "Karethe Allum")
    assert toasts(mod) == []  # still under way
    b.DockingComponent.docked = True
    mod.g.NoteDocking(b, "Karethe Allum")
    mod.g.NoteDocking(b, "Karethe Allum")  # the next look, a moment later
    assert len(toasts(mod)) == 1 and "Karethe Allum is getting ready to work the crane" in toasts(mod)[0]


def test_it_is_said_again_for_the_next_docking():
    mod = load_mod()
    b = boat()
    b.DockingComponent.docked = True
    mod.g.NoteDocking(b, "Karethe Allum")
    b.DockingComponent.docked = False
    mod.g.NoteDocking(b, "Karethe Allum")  # undocked
    b.DockingComponent.docked = True
    mod.g.NoteDocking(b, "Karethe Allum")
    assert len(toasts(mod)) == 2


def test_two_boats_are_told_apart():
    mod = load_mod()
    first, second = boat(), boat()
    first.DockingComponent.docked = second.DockingComponent.docked = True
    mod.g.NoteDocking(first, "A")
    mod.g.NoteDocking(second, "B")
    assert len(toasts(mod)) == 2
