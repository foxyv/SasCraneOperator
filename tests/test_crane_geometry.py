"""The arm maths: given a point, the joints that put the hook over it.

The mod works the joints out backwards (inverse kinematics) from measurements of the two cranes. These tests run
the other way: they take the joints the mod returns, work out where the arm would be (forward kinematics,
written here from the same documented measurements), and check it is where the mod was asked to put it.
"""

import math
import random

import pytest

from tests.lua_harness import FakeCrane, Vec, load_mod


@pytest.fixture(scope="module")
def mod():
    return load_mod()


def turn(degrees):
    return ((degrees + 180) % 360) - 180


# ---- the dock crane (T01): swivel, hoist and telescope --------------------------------------------

def dock_forward(mod, pose):
    """Where the boom's tip is, in the plane, from the crane's origin, and how high above it."""
    g = mod.g
    length = g.BOOM_CM + pose.telescope * g.TELESCOPE_CM_PER_UNIT
    angle = math.radians(pose.hoist - g.BOOM_DROOP_DEG)
    return length * math.cos(angle) - g.BOOM_BACK_CM, g.BOOM_UP_CM + length * math.sin(angle)


def dock_arm(mod, crane, x, y, z=0.0):
    return mod.test.DockCrane.Arm(crane, Vec(X=x, Y=y, Z=z))


def test_the_dock_crane_swivels_towards_the_point_whatever_way_it_faces(mod):
    for yaw in (0.0, 90.0, -135.0, 40.0):
        crane = FakeCrane("BP_StationaryCrane_T01_C", location=(1000.0, -2000.0, 300.0), yaw=yaw)
        for azimuth in (0.0, 35.0, 90.0, -120.0, 179.0):
            radius = 600.0
            x, y = 1000.0 + radius * math.cos(math.radians(azimuth)), -2000.0 + radius * math.sin(math.radians(azimuth))
            arm = dock_arm(mod, crane, x, y)
            assert abs(turn(arm.pose.swivel - turn(azimuth - yaw))) < 0.01


def test_the_dock_crane_reaches_every_point_inside_its_range_to_the_centimetre(mod):
    crane = FakeCrane("BP_StationaryCrane_T01_C", location=(0.0, 0.0, 0.0), yaw=0.0)
    for out in range(300, 860, 25):  # from about 2.7 m, the closest the boom comes in, to the limit of its run
        arm = dock_arm(mod, crane, float(out), 0.0)
        reach, _ = dock_forward(mod, arm.pose)
        assert abs(reach - out) < 1.0, f"asked for {out} cm, the boom reaches {reach:.1f}"


def test_the_boom_raises_to_come_in_and_runs_out_to_go_further(mod):
    crane = FakeCrane("BP_StationaryCrane_T01_C")
    close = dock_arm(mod, crane, 400.0, 0.0).pose  # less than the shortest boom lying flat: raised, not run out
    assert close.telescope == 0 and close.hoist > 0
    far = dock_arm(mod, crane, 450.0, 0.0).pose  # further than that: run out, lying flat
    assert far.telescope > 0 and far.hoist == 0
    telescope = [dock_arm(mod, crane, float(out), 0.0).pose.telescope for out in range(450, 860, 50)]
    assert telescope == sorted(telescope)


def test_closer_than_the_boom_comes_in_the_dock_crane_stops_at_its_closest(mod):
    crane = FakeCrane("BP_StationaryCrane_T01_C")
    arm = dock_arm(mod, crane, 150.0, 0.0)  # 1.5 m: the boom cannot be raised enough
    assert arm.pose.hoist == mod.g.HOIST_MAX
    reach, _ = dock_forward(mod, arm.pose)
    assert 250 < reach < 300  # about 2.7 m, the nearest it gets


def test_beyond_its_range_the_dock_crane_stops_short_and_the_mod_knows_where(mod):
    """Asked for a point further out than the boom runs, the arm comes back at full stretch and short of it. That
    is why the mod keeps its own limit (maxOut) and stages the piece nearer, not trusting the arm to refuse."""
    crane = FakeCrane("BP_StationaryCrane_T01_C")
    limit = mod.test.DockCrane.maxOut
    arm = dock_arm(mod, crane, limit + 400.0, 0.0)
    assert arm.pose.telescope == mod.g.TELESCOPE_MAX
    reach, _ = dock_forward(mod, arm.pose)
    assert reach < limit + 400.0 - 100  # well short of the point
    # at the limit itself the boom still gets there, with the margin the mod keeps
    arm = dock_arm(mod, crane, limit, 0.0)
    reach, _ = dock_forward(mod, arm.pose)
    assert abs(reach - limit) < 1.0
    assert 800 < limit < 900  # about 8.6 m, as measured


def test_the_dock_crane_tip_height_is_where_the_boom_puts_it(mod):
    crane = FakeCrane("BP_StationaryCrane_T01_C", location=(0.0, 0.0, 120.0))
    for out in (200, 400, 600, 800):
        arm = dock_arm(mod, crane, float(out), 0.0)
        _, height = dock_forward(mod, arm.pose)
        assert abs((120.0 + height) - arm.tipZ) < 0.5


def test_the_dock_crane_raises_its_boom_for_a_higher_tip_and_keeps_its_reach(mod):
    """Lying flat, the hook only gets as high as the tallest stack on a medium dock, so a load carried over it
    needs the boom raised a little, and run out further so the hook stays over the same spot."""
    crane = FakeCrane("BP_StationaryCrane_T01_C", location=(0.0, 0.0, 120.0))
    for out in (500, 650, 800):
        flat = dock_arm(mod, crane, float(out), 0.0)
        assert flat.pose.hoist == 0
        higher = mod.test.DockCrane.Arm(crane, Vec(X=float(out), Y=0.0, Z=0.0), flat.tipZ + 150)
        assert higher.pose.hoist > 0 and higher.pose.telescope > flat.pose.telescope
        reach, height = dock_forward(mod, higher.pose)
        assert abs(reach - out) < 1.0
        assert abs((120.0 + height) - higher.tipZ) < 0.5
        assert abs(higher.tipZ - (flat.tipZ + 150)) < 1.0
    # A lower tip than the flat boom gives leaves it flat, and at the limit of its run it cannot rise.
    flat = dock_arm(mod, crane, 600.0, 0.0)
    assert mod.test.DockCrane.Arm(crane, Vec(X=600.0, Y=0.0, Z=0.0), flat.tipZ - 100).pose.hoist == 0
    limit = mod.test.DockCrane.maxOut
    top = mod.test.DockCrane.Arm(crane, Vec(X=limit, Y=0.0, Z=0.0), 5000.0)
    reach, _ = dock_forward(mod, top.pose)
    assert abs(reach - limit) < 1.0 and top.tipZ < 5000.0


# ---- the deck crane (T02): swivel, hoist, bend and telescope --------------------------------------

def deck_forward(mod, pose):
    """The arm's end: how far out from the crane's origin and how high above it."""
    k = {name: mod.g.KNUCKLE[name] for name in (
        "pivotBack", "pivotUp", "lower", "lowerAt", "lowerPerUnit", "upper", "upperPerUnit", "bendAt", "bendPerUnit")}
    lower_angle = math.radians(k["lowerAt"] + pose.hoist * k["lowerPerUnit"])
    knuckle_x = -k["pivotBack"] + k["lower"] * math.cos(lower_angle)
    knuckle_z = k["pivotUp"] + k["lower"] * math.sin(lower_angle)
    upper_angle = lower_angle + math.radians(k["bendAt"] + pose.bend * k["bendPerUnit"])
    upper = k["upper"] + pose.telescope * k["upperPerUnit"]
    return knuckle_x + upper * math.cos(upper_angle), knuckle_z + upper * math.sin(upper_angle)


def deck_arm(mod, crane, x, y, z, tip=None):
    return mod.test.DeckCrane.Arm(crane, Vec(X=x, Y=y, Z=z), tip)


def test_every_pose_the_deck_crane_returns_puts_the_hook_where_it_was_asked(mod):
    rng = random.Random(3)
    k = mod.g.KNUCKLE
    reachable = 0
    for _ in range(300):
        yaw = rng.uniform(-180, 180)
        crane = FakeCrane("BP_StationaryCrane_T02_WithCable_C", location=(rng.uniform(-5e3, 5e3), rng.uniform(-5e3, 5e3), 200.0), yaw=yaw)
        radius, bearing = rng.uniform(200, 1100), rng.uniform(-170, 170) + yaw
        point = (crane.location[0] + radius * math.cos(math.radians(bearing)),
                 crane.location[1] + radius * math.sin(math.radians(bearing)), 200.0 + rng.uniform(-50, 150))
        tip = point[2] + rng.uniform(150, 450)
        arm = deck_arm(mod, crane, *point, tip=tip)
        if arm is None:
            continue
        reachable += 1
        out_of_arm, height = deck_forward(mod, arm.pose)
        hook_out = math.sqrt(radius ** 2 - k["side"] ** 2)
        assert abs(out_of_arm - (hook_out - k["ahead"])) < 0.5
        assert abs((200.0 + height) - arm.tipZ) < 0.5
        # the hook, 47 cm to the arm's left and 3 cm beyond its end, is over the point
        swivel_world = math.radians(arm.pose.swivel + yaw)
        along, side = out_of_arm + k["ahead"], k["side"]
        hook_x = crane.location[0] + along * math.cos(swivel_world) - side * math.sin(swivel_world)
        hook_y = crane.location[1] + along * math.sin(swivel_world) + side * math.cos(swivel_world)
        assert math.hypot(hook_x - point[0], hook_y - point[1]) < 1.0
        assert abs(arm.pose.swivel) <= 179
        assert -1 <= arm.pose.bend <= 1 and arm.pose.hoist <= 1 and arm.pose.telescope >= 0
    assert reachable > 50  # most of the test points are within reach, so the check above ran a lot


def test_the_deck_crane_refuses_what_it_cannot_reach(mod):
    crane = FakeCrane("BP_StationaryCrane_T02_WithCable_C", location=(0.0, 0.0, 200.0))
    assert deck_arm(mod, crane, 3000.0, 0.0, 200.0) is None  # 30 m out
    assert deck_arm(mod, crane, 20.0, 0.0, 200.0) is None  # inside the hook's own offset from the arm
    assert deck_arm(mod, crane, 600.0, 0.0, 200.0) is not None


def test_the_deck_crane_does_not_swing_through_the_back_of_its_range(mod):
    # The swivel stops at half a turn either way; a point straight behind needs the limit and is refused or
    # reached by swinging at most that far, never by the long way round.
    crane = FakeCrane("BP_StationaryCrane_T02_WithCable_C", location=(0.0, 0.0, 200.0), yaw=0.0)
    for bearing in range(-175, 180, 25):
        x, y = 700.0 * math.cos(math.radians(bearing)), 700.0 * math.sin(math.radians(bearing))
        arm = deck_arm(mod, crane, x, y, 200.0)
        if arm is not None:
            assert abs(arm.pose.swivel) <= 179


def test_nearer_points_are_reachable_whenever_a_further_one_in_that_direction_is(mod):
    crane = FakeCrane("BP_StationaryCrane_T02_WithCable_C", location=(0.0, 0.0, 200.0))
    for bearing in (0.0, 45.0, -90.0, 130.0):
        reach = [deck_arm(mod, crane, r * math.cos(math.radians(bearing)), r * math.sin(math.radians(bearing)), 200.0) is not None
                 for r in range(300, 1300, 50)]
        furthest = max((i for i, ok in enumerate(reach) if ok), default=-1)
        assert furthest >= 0
        # no gap in the middle of the range: reachable from the nearest reachable point to the furthest
        first = reach.index(True)
        assert all(reach[first:furthest + 1])


def test_turn_wraps_into_half_a_turn_each_way(mod):
    for degrees in (0, 190, -190, 360, -540, 90, 725, -359):
        wrapped = mod.test.Turn(float(degrees))
        assert -180 <= wrapped <= 180
        assert abs(((degrees - wrapped) / 360) - round((degrees - wrapped) / 360)) < 1e-9  # a whole number of turns apart
