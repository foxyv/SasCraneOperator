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


# ---- the docking watcher: the step after the game calls the boat made fast looks for work at once

class DockingWithPull(Docking):
    def __init__(self):
        super().__init__()
        self.bIsPulling = False


def pull_boat():
    b = GameObject("BP_Cargo_Boat_2_C")
    b.DockingComponent = DockingWithPull()
    return b


def dock_lines(mod):
    return [line for line in mod.printed if "DOCK:" in line]


def test_the_watcher_looks_for_work_at_once_when_the_boat_is_made_fast():
    mod = load_mod()
    b = pull_boat()
    mod.test.SetRest(9)
    assert mod.test.WatchBoat(b, "Karethe Allum") is False and mod.test.GetRest() == 9  # under way
    b.DockingComponent.docked, b.DockingComponent.bIsPulling = True, True
    assert mod.test.WatchBoat(b, "Karethe Allum") is True and mod.test.GetRest() == 0  # docked: no more waiting, the pull-in goes on
    b.DockingComponent.bIsPulling = False
    assert mod.test.WatchBoat(b, "Karethe Allum") is True  # and the end of the pull-in is noticed too


def test_the_watcher_logs_each_change_of_the_games_docking_flags_once():
    mod = load_mod()
    b = pull_boat()
    mod.test.WatchBoat(b, "A")
    mod.test.WatchBoat(b, "A")  # nothing changed
    b.DockingComponent.docked, b.DockingComponent.bIsPulling = True, True
    mod.test.WatchBoat(b, "A")
    b.DockingComponent.bIsPulling = False
    mod.test.WatchBoat(b, "A")
    lines = dock_lines(mod)
    assert len(lines) == 3
    assert "docked false, being pulled in false" in lines[0]
    assert "docked true, being pulled in true" in lines[1]
    assert "docked true, being pulled in false" in lines[2]


def test_the_watcher_says_the_operator_is_getting_ready_when_docking_starts():
    mod = load_mod()
    b = pull_boat()
    mod.test.WatchBoat(b, "Karethe Allum")
    b.DockingComponent.docked, b.DockingComponent.bIsPulling = True, True
    mod.test.WatchBoat(b, "Karethe Allum")
    assert len(toasts(mod)) == 1
