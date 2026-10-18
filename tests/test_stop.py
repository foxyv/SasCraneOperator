"""STOP: Ctrl+Alt+S stops the crane operator at once. The piece in hand is let alone, every mark by hand is taken
off, and nothing new is started (planner orders included) until it is pressed again or a new mark is made."""

import pytest

from tests.lua_harness import load_mod


@pytest.fixture
def mod():
    m = load_mod()
    # count how often the work loop goes looking for a boat's crew, which is the first thing it does
    m.lua.execute("""
        Lookups = 0
        function FindAllOf(name)
            if name == 'SasBoatCrewComponent' then Lookups = Lookups + 1 end
            return nil
        end
    """)
    return m


def test_stopping_drops_the_job_and_every_mark(mod):
    mod.test.SetJob(mod.table({"phase": "to drop"}))
    mod.test.GetManual()["A" * 32] = "load"
    mod.test.GetManual()["B" * 32] = "unload"
    mod.test.StopOperator()
    assert mod.test.GetJob() is None
    assert len(list(mod.test.GetManual().keys())) == 0
    assert mod.test.GetHalted() is True
    assert any("STOP: the crane operator was stopped in the middle of a piece" in line for line in mod.printed)


def test_stopping_with_nothing_in_hand_says_so(mod):
    mod.test.StopOperator()
    assert any(line.strip().endswith("was stopped") for line in mod.printed if "STOP:" in line)


def test_nothing_new_is_started_while_stopped(mod):
    mod.test.StopOperator()
    for _ in range(5):
        mod.test.Work()
    assert mod.g.Lookups == 0  # the work loop never even looked for a crew


def test_it_works_normally_when_not_stopped(mod):
    for _ in range(3):
        mod.test.Work()
    assert mod.g.Lookups >= 1


def test_pressing_again_lets_the_operator_carry_on(mod):
    mod.test.StopOperator()
    mod.test.StopOperator()
    assert mod.test.GetHalted() is False
    for _ in range(3):  # the first step only counts down the short wait before looking for work
        mod.test.Work()
    assert mod.g.Lookups >= 1
