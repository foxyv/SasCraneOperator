"""The turn step: before a set-down the hook turns the load to face its new place.

The real script's JobStep and SteerStep are driven against a fake crane. Its hook rotator moves at a limited
speed and the load follows the hook a little behind, with optional jitter in what the script reads, as a
swinging load's yaw does. These are the failures seen in the game: turning one way then the other, turning
the long way round, reversing on noise, and turning a square block a quarter turn more than it needs.
"""

import random

import pytest

from tests.lua_harness import FakeCrane, FakeLoad, load_mod

DT = 0.1  # the script steers every 100 ms


@pytest.fixture
def mod():
    return load_mod()


def turn_job(mod, crane, load, final_yaw, symmetry):
    model = mod.table({"joints": {"turn": "Joint_HookRotator"}, "speed": {"turn": 60}, "close": {"turn": 2}, "feel": True})
    sign = mod.g.TurnSigns[crane._class_name] or 1
    return mod.lua.eval("""
        function(crane, load, model, finalYaw, symmetry, sign)
            return { phase = "turn", ticks = 0, crane = crane, cargo = load, model = model, finalYaw = finalYaw,
                     symmetry = symmetry, turnSign = sign, turnWrong = 0, drop = { X = 0, Y = 0, Z = 0 } }
        end""")(crane, load, model, final_yaw, symmetry, sign)


def run(mod, start_yaw, final_yaw, symmetry=180, direction=1.0, noise=0.0, seed=1, seconds=40, crane=None, responds=True):
    crane = crane or FakeCrane()
    crane.AttachedCargo = load = FakeLoad(crane.Joint_HookRotator, start_yaw=start_yaw, direction=direction,
                                          noise=noise, rng=random.Random(seed))
    load.responds = responds
    job = turn_job(mod, crane, load, final_yaw, symmetry)
    mod.test.SetJob(job)
    travelled, last, reversals, last_move = 0.0, load.yaw, 0, 0.0
    for tick in range(int(seconds / DT)):
        mod.test.JobStep()
        mod.test.SteerStep()
        before = crane.Joint_HookRotator.value
        crane.Joint_HookRotator.step(DT)
        load.step(DT)
        move = crane.Joint_HookRotator.value - before
        if abs(move) > 0.3:
            if last_move and (move > 0) != (last_move > 0):
                reversals += 1
            last_move = move
        step = ((load.yaw - last + 180) % 360) - 180
        travelled += abs(step)
        last = load.yaw
        if job.phase != "turn":
            break
    off = ((job.finalYaw - load.yaw + 180) % 360) - 180
    return {"job": job, "load": load, "crane": crane, "seconds": tick * DT, "reversals": reversals,
            "travelled": travelled, "off": off, "phase": job.phase, "steps": job.turnSteps or 0}


def distance_to_equivalent(final_yaw, yaw, symmetry):
    """How far the load is from the nearest facing that looks the same as the wanted one."""
    best = 360.0
    for k in range(int(360 / symmetry)):
        best = min(best, abs(((final_yaw + k * symmetry - yaw + 180) % 360) - 180))
    return best


def test_a_small_turn_is_made_once_and_finishes(mod):
    result = run(mod, start_yaw=0.0, final_yaw=40.0)
    assert result["phase"] == "aim"  # on to the next step
    assert distance_to_equivalent(40.0, result["load"].yaw, 180) <= 3.5
    assert result["steps"] <= 2
    assert result["reversals"] == 0
    assert result["seconds"] < 12


def test_a_turn_to_a_facing_ninety_degrees_off_does_not_dither(mod):
    # Both facings of a rectangular block are equally near: the choice must be made once and kept.
    for seed in range(8):
        result = run(mod, start_yaw=10.0, final_yaw=100.0, symmetry=180, noise=1.5, seed=seed)
        assert result["phase"] == "aim"
        assert result["reversals"] == 0, f"seed {seed}: the hook turned back and forth"
        assert result["travelled"] < 130  # about a quarter turn, not a half turn and back


def test_noise_in_the_load_s_yaw_does_not_reverse_the_hook(mod):
    for seed in range(10):
        result = run(mod, start_yaw=-60.0, final_yaw=25.0, noise=2.0, seed=seed)
        assert result["reversals"] == 0, f"seed {seed}: reversed on noise"
        assert distance_to_equivalent(25.0, result["load"].yaw, 180) <= 5


def test_a_rectangular_block_is_never_turned_more_than_a_quarter_turn(mod):
    for start, final in [(0, 170), (0, -170), (45, 200), (-120, 80), (170, -10), (90, 0)]:
        result = run(mod, start_yaw=float(start), final_yaw=((final + 180) % 360) - 180.0, symmetry=180)
        assert result["travelled"] <= 100, f"{start} -> {final} turned {result['travelled']:.0f} degrees"


def test_a_square_block_is_never_turned_more_than_half_a_quarter_turn(mod):
    # Any quarter turn looks the same, so it never needs more than 45 degrees (a little over for the lag).
    for start, final in [(0, 90), (0, 180), (0, 270), (30, 210), (-90, 100), (170, -100)]:
        result = run(mod, start_yaw=float(start), final_yaw=((final + 180) % 360) - 180.0, symmetry=90)
        assert result["travelled"] <= 60, f"{start} -> {final} turned {result['travelled']:.0f} degrees"
        assert distance_to_equivalent(final, result["load"].yaw, 90) <= 3.5


def test_a_hook_that_turns_the_load_the_other_way_is_found_out_and_remembered(mod):
    crane = FakeCrane()
    first = run(mod, start_yaw=0.0, final_yaw=50.0, direction=-1.0, crane=crane)
    assert first["phase"] == "aim"
    assert distance_to_equivalent(50.0, first["load"].yaw, 180) <= 3.5
    assert mod.g.TurnSigns[crane._class_name] == -1
    # The next job on that kind of crane starts out the right way and does not have to find it out again.
    second = run(mod, start_yaw=first["load"].yaw, final_yaw=-30.0, direction=-1.0, crane=crane)
    assert second["phase"] == "aim"
    assert second["reversals"] == 0
    assert second["steps"] <= 2


def test_a_load_that_does_not_respond_is_given_up_on_not_turned_for_ever(mod):
    result = run(mod, start_yaw=0.0, final_yaw=120.0, responds=False, seconds=40)
    assert result["phase"] == "aim"  # moves on after the time limit
    assert 11 <= result["seconds"] <= 14


def test_the_turn_is_logged(mod):
    run(mod, start_yaw=0.0, final_yaw=40.0)
    lines = [line for line in mod.printed if "TURN:" in line]
    assert len(lines) == 1
    assert "looks the same every 180 degrees" in lines[0]
