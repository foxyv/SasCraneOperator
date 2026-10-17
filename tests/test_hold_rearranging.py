"""Makes room in a full hold: the mod's CompactSpace, checked by a validator written separately in Python.

The validator replays the plan on its own model of the hold and insists every move is one the game would
allow (nothing standing on the piece, the new place free and squarely supported, inside the hold) and that
the piece wanted then has a free window. So a bug in the mod's own checking cannot pass these tests.
"""

import time

import pytest

from tests.lua_harness import load_mod

LIMIT = (12, 12, 4)

# Pieces as (id, x, y, z, size x, y, z), in 25 cm cells. The first is the Dr. Phil's hold on the evening
# the operator first got stuck; the second is the same hold a day later.
EVENING = [
    (1, 0, 2, 0, 2, 2, 4), (2, 4, 0, 0, 2, 2, 4), (3, 0, 0, 0, 4, 2, 1), (4, 0, 0, 1, 4, 2, 1),
    (5, 8, 4, 0, 4, 2, 1), (6, 8, 9, 0, 4, 2, 1), (7, 8, 6, 0, 4, 3, 3), (8, 0, 6, 0, 4, 4, 4),
    (9, 2, 2, 0, 4, 4, 4), (10, 4, 6, 0, 4, 4, 4), (11, 6, 0, 0, 4, 4, 4),
]
NEXT_DAY = [
    (1, 0, 0, 0, 2, 2, 4), (2, 0, 2, 0, 4, 2, 1), (3, 0, 2, 1, 4, 2, 1), (4, 2, 0, 0, 4, 2, 1),
    (5, 2, 0, 1, 4, 2, 1), (6, 2, 0, 2, 4, 2, 1), (7, 2, 0, 3, 4, 2, 1), (8, 8, 4, 0, 4, 3, 3),
    (9, 0, 4, 0, 4, 4, 3), (10, 0, 8, 0, 4, 4, 4), (11, 4, 2, 0, 4, 4, 4), (12, 4, 6, 0, 4, 4, 4),
    (13, 8, 0, 0, 4, 4, 4), (14, 8, 8, 0, 4, 4, 4),
]


def cells(piece):
    _, x, y, z, sx, sy, sz = piece
    return {(a, b, c) for a in range(x, x + sx) for b in range(y, y + sy) for c in range(z, z + sz)}


def occupancy(pieces, skip=None):
    taken = {}
    for piece in pieces:
        if piece[0] != skip:
            for cell in cells(piece):
                taken[cell] = piece[0]
    return taken


def apply_move(pieces, move):
    """The pieces after the move, or None if the game would not allow it."""
    by_id = {p[0]: p for p in pieces}
    piece = by_id[move["id"]]
    _, _, _, _, sx, sy, sz = piece
    others = occupancy(pieces, skip=piece[0])
    x, y, z = move["x"], move["y"], move["z"]
    if x < 0 or y < 0 or z < 0 or x + sx > LIMIT[0] or y + sy > LIMIT[1] or z + sz > LIMIT[2]:
        return None
    for a in range(piece[1], piece[1] + sx):  # nothing may stand on it
        for b in range(piece[2], piece[2] + sy):
            if (a, b, piece[3] + sz) in others:
                return None
    new = (piece[0], x, y, z, sx, sy, sz)
    if cells(new) & set(others):
        return None
    if z > 0:  # squarely supported, by other pieces
        for a in range(x, x + sx):
            for b in range(y, y + sy):
                if (a, b, z - 1) not in others:
                    return None
    return [new if p[0] == piece[0] else p for p in pieces]


def has_window(pieces, want):
    taken = occupancy(pieces)
    wx, wy, wz = want
    free = {(x, y) for x in range(LIMIT[0]) for y in range(LIMIT[1])
            if not any((x, y, z) in taken for z in range(min(wz, LIMIT[2])))}
    for w, h in {(wx, wy), (wy, wx)}:
        for x in range(LIMIT[0] - w + 1):
            for y in range(LIMIT[1] - h + 1):
                if all((a, b) in free for a in range(x, x + w) for b in range(y, y + h)):
                    return True
    return False


def plan_for(mod, pieces, want, movable=True, seconds=None):
    """The mod's plan (a list of moves) or None. `seconds` raises the search's time limit: the search stops at
    its limit, so a hard case given the usual second finds a plan or not depending on how busy the machine is;
    with a generous limit the result depends only on the (fixed) random seed."""
    mod.g.COMPACT_BUDGET_S = seconds if seconds is not None else 1.0
    boxes = {}
    for pid, x, y, z, sx, sy, sz in pieces:
        box = {"id": pid, "low": {"X": x, "Y": y, "Z": z}, "size": {"X": sx, "Y": sy, "Z": sz}}
        if movable:
            box["anchor"] = {"X": 0, "Y": 0, "Z": 0}
        boxes[pid] = box
    moves = mod.g.CompactSpace(mod.table(boxes), mod.table({"X": LIMIT[0], "Y": LIMIT[1], "Z": LIMIT[2]}),
                               mod.table({"X": want[0], "Y": want[1], "Z": want[2]}))
    if moves is None:
        return None
    return [{"id": moves[i].id, "x": moves[i].x, "y": moves[i].y, "z": moves[i].z} for i in range(1, len(moves) + 1)]


def assert_valid(pieces, plan, want):
    state = pieces
    for number, move in enumerate(plan, 1):
        state = apply_move(state, move)
        assert state is not None, f"move {number} ({move}) is not one the game allows"
    assert has_window(state, want), "after the plan there is still no space for the piece"


@pytest.fixture
def mod():
    return load_mod()


def test_the_evening_hold_makes_room_for_a_pallet(mod):
    plan = plan_for(mod, EVENING, (4, 4, 4))
    assert plan is not None
    assert len(plan) <= 4
    assert_valid(EVENING, plan, (4, 4, 4))


def test_a_second_pallet_fits_once_the_first_is_in(mod):
    first = plan_for(mod, EVENING, (4, 4, 4))
    state = EVENING
    for move in first:
        state = apply_move(state, move)
    # the pallet goes into the window the plan opened; put it there on the validator's model
    taken = occupancy(state)
    spot = next((x, y) for x in range(9) for y in range(9)
                if not any((a, b, c) in taken for a in range(x, x + 4) for b in range(y, y + 4) for c in range(4)))
    state = state + [(99, spot[0], spot[1], 0, 4, 4, 4)]
    second = plan_for(mod, state, (4, 4, 4))
    assert second is not None
    assert_valid(state, second, (4, 4, 4))


def test_every_plan_found_on_the_next_day_hold_is_valid(mod):
    for want in ((4, 4, 4), (4, 4, 3), (4, 3, 3), (4, 2, 1), (9, 2, 2), (2, 2, 4)):
        plan = plan_for(mod, NEXT_DAY, want, seconds=20 if want != (9, 2, 2) else 1.0)  # the pipe fits nowhere
        if plan is not None:
            assert_valid(NEXT_DAY, plan, want)


def test_a_hold_with_room_needs_no_moves(mod):
    plan = plan_for(mod, [(1, 0, 0, 0, 4, 4, 4)], (4, 4, 4))
    assert plan == []


def test_a_full_hold_is_given_up_on_quickly(mod):
    full = [(n, x, y, 0, 4, 4, 4) for n, (x, y) in enumerate([(x, y) for x in (0, 4, 8) for y in (0, 4, 8)], 1)]
    started = time.time()
    assert plan_for(mod, full, (4, 4, 4)) is None
    assert time.time() - started < 1.0


def test_pieces_that_cannot_be_moved_are_left_alone(mod):
    # Nothing has an anchor, so nothing may be moved: the only plan is none at all.
    assert plan_for(mod, EVENING, (4, 4, 4), movable=False) is None


def test_the_same_hold_gives_the_same_plan(mod):
    assert plan_for(mod, EVENING, (4, 4, 4)) == plan_for(mod, EVENING, (4, 4, 4))


def test_it_never_asks_for_more_moves_than_it_may(mod):
    plan = plan_for(mod, NEXT_DAY, (4, 3, 3), seconds=20)
    assert plan is None or len(plan) <= mod.g.COMPACT_MOVES


def test_a_piece_that_fits_inside_a_bigger_one_fits_whenever_the_bigger_does(mod):
    # Wherever the hold can be rearranged to take a 4x4x4, it takes anything that fits inside that space.
    big = plan_for(mod, NEXT_DAY, (4, 4, 4), seconds=20)
    assert big is not None
    for smaller in ((4, 4, 3), (4, 3, 3), (4, 2, 2), (3, 3, 3), (2, 2, 4)):
        plan = plan_for(mod, NEXT_DAY, smaller, seconds=20)
        assert plan is not None, f"a {smaller} piece fits where a 4x4x4 does, but no plan was found"
        assert_valid(NEXT_DAY, plan, smaller)
