const std = @import("std");
const build_options = @import("build_options");

const common = @import("../common/data.zig");
const protocol = @import("../common/protocol.zig");
const rng = @import("../common/rng.zig");

const data = @import("data.zig");

const assert = std.debug.assert;

const expectEqual = std.testing.expectEqual;

const showdown = build_options.showdown;

const Choice = common.Choice;
const Player = common.Player;
const Result = common.Result;

const Damage = protocol.Damage;

const Gen12 = rng.Gen12;

const ActivePokemon = data.ActivePokemon;
const Move = data.Move;
const Side = data.Side;
const Species = data.Species;
const Stats = data.Stats;
const Status = data.Status;

// zig fmt: off
const BOOSTS = &[_][2]u8{
    .{ 25, 100 }, // -6
    .{ 28, 100 }, // -5
    .{ 33, 100 }, // -4
    .{ 40, 100 }, // -3
    .{ 50, 100 }, // -2
    .{ 66, 100 }, // -1
    .{   1,  1 }, //  0
    .{ 15,  10 }, // +1
    .{  2,   1 }, // +2
    .{ 25,  10 }, // +3
    .{  3,   1 }, // +4
    .{ 35,  10 }, // +5
    .{  4,   1 }, // +6
};
// zig fmt: on

pub fn update(battle: anytype, c1: Choice, c2: Choice, log: anytype) !Result {
    if (battle.turn == 0) return start(battle, log);

    selectMove(battle, .P1, c1);
    selectMove(battle, .P2, c2);

    // TODO: https://glitchcity.wiki/Partial_trapping_move_Mirror_Move_link_battle_glitch

    if (turnOrder(battle, c1, c2) == .P1) {
        if (try doTurn(battle, .P1, c1, .P2, c2, log)) |r| return r;
    } else {
        if (try doTurn(battle, .P2, c2, .P1, c1, log)) |r| return r;
    }

    var p1 = battle.side(.P1); // FIXME what about thrashing/rage?
    if (p1.active.volatiles.data.attacks == 0) {
        p1.active.volatiles.Trapping = false;
    }
    var p2 = battle.side(.P2);
    if (p2.active.volatiles.data.attacks == 0) {
        p2.active.volatiles.Trapping = false;
    }

    return endTurn(battle, log);
}

fn start(battle: anytype, log: anytype) !Result {
    const p1 = battle.side(.P1);
    const p2 = battle.side(.P2);

    var slot = findFirstAlive(p1);
    if (slot == 0) return if (findFirstAlive(p2) == 0) Result.Tie else Result.Lose;
    try switchIn(battle, .P1, slot, true, log);

    slot = findFirstAlive(p2);
    if (slot == 0) return Result.Win;
    try switchIn(battle, .P2, slot, true, log);

    return endTurn(battle, log);
}

fn findFirstAlive(side: *const Side) u8 {
    for (side.pokemon) |pokemon, i| {
        if (pokemon.hp > 0) return side.order[i];
    }
    return 0;
}

// FIXME decrementPP?
fn selectMove(battle: anytype, player: Player, choice: Choice) void {
    var side = battle.side(player);
    var volatiles = &side.active.volatiles;
    const stored = side.stored();

    // pre-battle menu
    if (volatiles.Recharging or volatiles.Rage) return;
    volatiles.Flinch = false;
    if (volatiles.Thrashing or volatiles.Charging) return;

    // battle menu
    if (choice.type == .Switch) return;

    // pre-move select
    if (Status.is(stored.status, .FRZ) or Status.is(stored.status, .SLP)) return;
    if (volatiles.Bide or volatiles.Trapping) return;

    if (battle.foe(player).active.volatiles.Trapping) {
        side.last_selected_move = .SKIP_TURN;
        return;
    }

    // move select
    if (choice.data == 0) {
        const struggle = ok: {
            for (side.active.moves) |move, i| {
                if (move.pp > 0 and volatiles.data.disabled.move != i + 1) break :ok false;
            }
            break :ok true;
        };

        assert(struggle);
        side.last_selected_move = .Struggle;
    } else {
        assert(choice.data <= 4);
        const move = side.active.moves[choice.data - 1];

        assert(move.pp != 0); // FIXME: wrap underflow?
        assert(side.active.volatiles.data.disabled.move != choice.data);
        side.last_selected_move = move.id;
    }

    if (showdown) _ = battle.rng.next(); // BUG: getRandomTarget
}

fn switchIn(battle: anytype, player: Player, slot: u8, initial: bool, log: anytype) !void {
    var side = battle.side(player);
    var foe = battle.foe(player);
    var active = &side.active;
    const incoming = side.get(slot);

    assert(incoming.hp != 0);
    assert(slot != 1 or initial);

    const out = side.order[0];
    side.order[0] = side.order[slot - 1];
    side.order[slot - 1] = out;

    side.last_used_move = .None;
    foe.last_used_move = .None;

    active.stats = incoming.stats;
    active.volatiles = .{};
    active.boosts = .{};
    active.species = incoming.species;
    active.types = incoming.types;
    for (incoming.moves) |move, j| {
        active.moves[j] = move;
    }

    if (Status.is(incoming.status, .PAR)) {
        active.stats.spe = @maximum(active.stats.spe / 4, 1);
    } else if (Status.is(incoming.status, .BRN)) {
        active.stats.atk = @maximum(active.stats.atk / 2, 1);
    }

    foe.active.volatiles.Trapping = false;

    try log.switched(active.ident(side, player), incoming);
}

fn turnOrder(battle: anytype, c1: Choice, c2: Choice) Player {
    if ((c1.type == .Switch) != (c2.type == .Switch)) return if (c1.type == .Switch) .P1 else .P2;

    const m1 = battle.side(.P1).last_selected_move;
    const m2 = battle.side(.P2).last_selected_move;

    if ((m1 == .QuickAttack) != (m2 == .QuickAttack)) return if (m1 == .QuickAttack) .P1 else .P2;
    if ((m1 == .Counter) != (m2 == .Counter)) return if (m1 == .Counter) .P2 else .P1;

    // NB: https://www.smogon.com/forums/threads/adv-switch-priority.3622189/
    if (!showdown and c1.type == .Switch and c2.type == .Switch) return .P1;

    const spe1 = battle.side(.P1).active.stats.spe;
    const spe2 = battle.side(.P2).active.stats.spe;
    if (spe1 == spe2) {
        const p1 = if (showdown)
            battle.rng.range(u8, 0, 2) == 0
        else
            battle.rng.next() < Gen12.percent(50) + 1;
        return if (p1) .P1 else .P2;
    }

    return if (spe1 > spe2) .P1 else .P2;
}

fn doTurn(battle: anytype, p: Player, pc: Choice, f: Player, fc: Choice, log: anytype) !?Result {
    try executeMove(battle, p, pc, log);
    if (try checkFaint(battle, f, true, log)) |r| return r;
    try handleResidual(battle, p, log);
    if (try checkFaint(battle, p, true, log)) |r| return r;

    try executeMove(battle, f, fc, log);
    if (try checkFaint(battle, p, true, log)) |r| return r;
    try handleResidual(battle, f, log);
    if (try checkFaint(battle, f, true, log)) |r| return r;

    return null;
}

fn endTurn(battle: anytype, log: anytype) !Result {
    if (showdown and checkEBC(battle)) return Result.Tie;

    battle.turn += 1;
    try log.turn(battle.turn);

    if (showdown) {
        return if (battle.turn >= 1000) Result.Tie else Result.Default;
    } else {
        return if (battle.turn >= 0xFFFF) Result.Error else Result.Default;
    }
}

fn checkEBC(battle: anytype) bool {
    ebc: for (battle.sides) |side, i| {
        var foe_all_ghosts = true;
        var foe_all_transform = true;

        for (battle.sides[~@truncate(u1, i)].pokemon) |pokemon| {
            if (pokemon.species == .None) continue;

            const ghost = pokemon.hp == 0 or pokemon.types.includes(.Ghost);
            foe_all_ghosts = foe_all_ghosts and ghost;
            foe_all_transform = foe_all_transform and pokemon.hp == 0 or transform: {
                for (pokemon.moves) |m| {
                    if (m.id == .None) break :transform true;
                    if (m.id != .Transform) break :transform false;
                }
                break :transform true;
            };
        }

        for (side.pokemon) |pokemon| {
            if (pokemon.hp == 0 or Status.is(pokemon.status, .FRZ)) continue;
            const transform = foe_all_transform and transform: {
                for (pokemon.moves) |m| {
                    if (m.id == .None) break :transform true;
                    if (m.id != .Transform) break :transform false;
                }
                break :transform true;
            };
            if (transform) continue;
            const no_pp = foe_all_ghosts and no: {
                for (pokemon.moves) |m| {
                    if (m.pp != 0) break :no false;
                }
                break :no true;
            };
            if (no_pp) continue;

            continue :ebc;
        }

        return true;
    }

    return false;
}

fn executeMove(battle: anytype, player: Player, choice: Choice, log: anytype) !void {
    var side = battle.side(player);
    const foe = battle.foe(player);
    if (side.last_selected_move == .SKIP_TURN) return;
    if (choice.type == .Switch) return switchIn(battle, player, choice.data, false, log);

    if (!try beforeMove(battle, player, choice.data, log)) return; // FIXME
    // FIXME set volatiles.data.state = 0 if not bide (getCurrentMove)
    if (!try canExecute(battle, player, log)) return;

    const move = Move.get(side.last_selected_move);
    if (move.effect == .SuperFang or move.effect == .SpecialDamage) {
        // TODO checkHit
        battle.last_damage = switch (side.last_selected_move) {
            .SuperFang => @maximum(foe.active.stats.hp / 2, 1),
            .SeismicToss, .NightShade => side.stored().level,
            .SonicBoom => 20,
            .DragonRage => 40,
            // NB: if power = 0 then a desync occurs (or a miss on Pokémon Showdown)
            .Psywave => power: {
                const max = @truncate(u8, @as(u16, side.stored().level) * 3 / 2);
                // NB: these values will diverge
                if (showdown) {
                    break :power battle.rng.range(u8, 0, max);
                } else {
                    while (true) {
                        const r = battle.rng.next();
                        if (r < max) break :power r;
                    }
                }
            },
            else => unreachable,
        };
        return; // TODO
    }

    // NB: can't reorder this even when unused (eg. Counter) as it advances the RNG
    const crit = checkCriticalHit(battle, player, move);

    // NB: Counter desync due to changing move selection prior to switching is not supported
    if (side.last_selected_move == .Counter) {
        const foe_last_move = Move.get(foe.last_selected_move);
        const miss = foe_last_move.bp == 0 or
            foe.last_selected_move == .Counter or
            foe_last_move.type != .Normal or
            foe_last_move.type != .Fighting or
            battle.last_damage == 0;
        const damage = if (battle.last_damage > 0x7FFF) 0xFFFF else battle.last_damage * 2;

        // TODO checkHit, then skip if miss
        _ = miss;
        _ = damage;
        return;
    }

    battle.last_damage = 0;

    if (move.effect == .OHKO) {
        const miss = side.active.stats.spe < foe.active.stats.spe;
        // NB: this can overflow after adjustDamage, but will still be sufficient to OHKO
        const damage: u16 = if (miss) 0 else 0xFFFF;
        const ohko = !miss;

        // TODO
        _ = miss;
        _ = damage;
        _ = ohko;
    }

    if (move.bp == 0) {
        return; // TODO playerCheckIfFlyOrChargeEffect
    }

    var damage = calcDamage(battle, player, move, crit);
    damage = adjustDamage(battle, player, damage);
    damage = randomizeDamage(battle, damage); // FIXME crit?

    const hit = checkHit(battle, player, move);

    if (move.effect == .MirrorMove) {
        if (foe.last_used_move == .None or foe.last_used_move == .MirrorMove) {
            // TODO
            return; // TODO
        } else {
            // FIXME side.last_selected_move = foe.last_used_move;
            return executeMove(battle, player, choice, log);
        }
    } else if (move.effect == .Metronome) {
        // FIXME: test this + show where differs
        // NB: these values will diverge
        const random = if (showdown) blk: {
            const r = battle.rng.range(u8, 0, @enumToInt(Move.Struggle) - 2);
            break :blk @intToEnum(Move, r + @as(u2, (if (r < @enumToInt(Move.Metronome)) 1 else 2)));
        } else loop: {
            while (true) {
                const r = battle.rng.next();
                if (r == 0 or r == @enumToInt(Move.Metronome)) continue;
                if (r >= @enumToInt(Move.Struggle)) continue;
                break :loop @intToEnum(Move, r);
            }
        };

        _ = random; // FIXME side.last_selected_move = random
        return executeMove(battle, player, choice, log);
    }

    if (move.effect.residual2()) {
        try moveEffect(battle, player, move, log);
        return;
    }

    // TODO
    _ = hit;
}

// TODO return an enum instead of bool to handle multiple cases
fn beforeMove(battle: anytype, player: Player, mslot: u8, log: anytype) !bool {
    var side = battle.side(player);
    const foe = battle.foe(player);
    var active = &side.active;
    var stored = side.stored();
    const ident = active.ident(side, player);
    var volatiles = &active.volatiles;

    assert(active.move(mslot).id != .None);

    if (Status.is(stored.status, .SLP)) {
        stored.status -= 1;
        if (!Status.any(stored.status)) try log.cant(ident, .Sleep);
        side.last_used_move = .None;
        return false;
    }

    if (Status.is(stored.status, .FRZ)) {
        try log.cant(ident, .Freeze);
        side.last_used_move = .None;
        return false;
    }

    if (foe.active.volatiles.Trapping) {
        try log.cant(ident, .Trapped);
        return false;
    }

    if (volatiles.Flinch) {
        volatiles.Flinch = false;
        try log.cant(ident, .Flinch);
        return false;
    }

    if (volatiles.Recharging) {
        volatiles.Recharging = false;
        try log.cant(ident, .Recharging);
        return false;
    }

    if (volatiles.data.disabled.duration > 0) {
        volatiles.data.disabled.duration -= 1;
        if (volatiles.data.disabled.duration == 0) {
            volatiles.data.disabled.move = 0;
            try log.end(ident, .Disable);
        }
    }

    if (volatiles.Confusion) {
        assert(volatiles.data.confusion > 0);

        volatiles.data.confusion -= 1;
        if (volatiles.data.confusion == 0) {
            volatiles.Confusion = false;
            try log.end(ident, .Confusion);
        } else {
            try log.activate(ident, .Confusion);

            const confused = if (showdown)
                !battle.rng.chance(u8, 128, 256)
            else
                battle.rng.next() >= Gen12.percent(50) + 1;

            if (confused) {
                // FIXME: implement self hit
                volatiles.Bide = false;
                volatiles.Thrashing = false;
                volatiles.MultiHit = false;
                volatiles.Flinch = false;
                volatiles.Charging = false;
                volatiles.Trapping = false;
                volatiles.Invulnerable = false;
                return false;
            }
        }
    }

    if (volatiles.data.disabled.move == mslot) {
        volatiles.Charging = false;
        try log.disabled(ident, active.move(volatiles.data.disabled.move).id);
        return false;
    }

    if (Status.is(stored.status, .PAR)) {
        const paralyzed = if (showdown)
            battle.rng.chance(u8, 63, 256)
        else
            battle.rng.next() < Gen12.percent(25);

        if (paralyzed) {
            volatiles.Bide = false;
            volatiles.Thrashing = false;
            volatiles.Charging = false;
            volatiles.Trapping = false;
            // NB: Invulnerable is not cleared, resulting in the Fly/Dig glitch
            try log.cant(ident, .Paralysis);
            return false;
        }
    }

    if (volatiles.Bide) {
        // TODO accumulate? overflow?
        volatiles.data.state += battle.last_damage;
        try log.activate(ident, .Bide);

        assert(volatiles.data.attacks > 0);

        volatiles.data.attacks -= 1;
        if (volatiles.data.attacks != 0) return false;

        volatiles.Bide = false;
        try log.end(ident, .Bide);

        if (volatiles.data.state > 0) {
            try log.fail(ident, .None);
            return false;
        }
        // TODO unleash energy
    }

    if (volatiles.Thrashing) {
        assert(volatiles.data.attacks > 0);

        // TODO PlayerMoveNum = THRASH
        volatiles.data.attacks -= 1;
        if (volatiles.data.attacks == 0) {
            volatiles.Thrashing = false;
            volatiles.Confusion = true;
            // NB: these values will diverge
            volatiles.data.confusion = @truncate(u4, if (showdown)
                battle.rng.range(u8, 3, 5)
            else
                (battle.rng.next() & 3) + 2);
            try log.start(ident, .ConfusionSilent);
        }
        // TODO: skip DecrementPP, call PlayerCalcMoveDamage directly
    }

    if (volatiles.Trapping) {
        assert(volatiles.data.attacks > 0);
        volatiles.data.attacks -= 1;
        if (volatiles.data.attacks == 0) {
            // TODO skip DamageCalc/DecrementPP/MoveHitTest
        }
    }

    if (volatiles.Rage) {
        // TODO skip DecrementPP, go to PlayerCanExecuteMove
    }

    return true;
}

fn canExecute(battle: anytype, player: Player, log: anytype) !bool {
    var side = battle.side(player);
    const move = Move.get(side.last_selected_move);

    if (side.active.volatiles.Charging) {
        side.active.volatiles.Charging = false;
        side.active.volatiles.Invulnerable = false;
    } else if (move.effect == .Charge) {
        try moveEffect(battle, player, move, log);
        return false;
    }

    if (move.effect.residual1()) {
        try moveEffect(battle, player, move, log);
        return false;
    }

    if (move.effect == .Thrashing or move.effect == .Trapping) {
        try moveEffect(battle, player, move, log);
    }

    return true;
}

fn checkCriticalHit(battle: anytype, player: Player, move: Move.Data) bool {
    const side = battle.side(player);

    var chance = Species.chance(side.active.species);

    // NB: Focus Energy reduces critical hit chance instead of increasing it
    chance = if (side.active.volatiles.FocusEnergy)
        chance / 2
    else
        @minimum(chance * 2, 0xFF);

    chance = if (move.effect == .HighCritical)
        @minimum(chance * 4, 0xFF)
    else
        chance / 2;

    if (showdown) return battle.rng.chance(u8, chance, 256);
    // NB: these values will diverge (due to rotations)
    return std.math.rotl(u8, battle.rng.next(), 3) < chance;
}

fn calcDamage(battle: anytype, player: Player, move: Move.Data, crit: bool) u16 {
    const side = battle.side(player);
    const foe = battle.foe(player);

    const special = move.type.special();

    // zig fmt: off
    var atk =
        if (crit)
            if (special) side.stored().stats.spc
            else side.stored().stats.atk
        else
            if (special) side.active.stats.spc
            else side.active.stats.atk;

    var def =
        if (crit)
            if (special) foe.stored().stats.spc
            else foe.stored().stats.def
        else
            // NB: not capped to MAX_STAT_VALUE, can be 999 * 2 = 1998
            if (special)
                foe.active.stats.spc * @as(u2, if (foe.active.volatiles.LightScreen) 2 else 1)
            else
                foe.active.stats.def * @as(u2, if (foe.active.volatiles.Reflect) 2 else 1);
    // zig fmt: on

    if (atk > 0xFF or def > 0xFF) {
        atk = @maximum((atk / 4) & 0xFF, 1);
        // NB: not adjusted to be a minimum of 1 on cartridge (can lead to division-by-zero freeze)
        def = @maximum((def / 4) & 0xFF, if (showdown) 1 else 0);
    }

    const lvl = @as(u16, side.stored().level * @as(u2, if (crit) 2 else 1));

    def = if (move.effect == .Explode) @maximum(def / 2, 1) else def;

    return @minimum(997, ((lvl * 2 / 5) + 2) *% move.bp *% atk / def / 50) + 2;
}

fn adjustDamage(battle: anytype, player: Player, damage: u16) u16 {
    const side = battle.side(player);
    const foe = battle.foe(player);
    const move = Move.get(side.last_selected_move);

    var d = damage;
    if (side.active.types.includes(move.type)) d *%= 2;

    d = d *% @enumToInt(move.type.effectiveness(foe.active.types.type1)) / 10;
    d = d *% @enumToInt(move.type.effectiveness(foe.active.types.type2)) / 10;

    return d;
}

fn randomizeDamage(battle: anytype, damage: u16) u16 {
    if (damage <= 1) return damage;

    // NB: these values will diverge
    const random = if (showdown)
        battle.rng.range(u8, 217, 256)
    else loop: {
        while (true) {
            const r = battle.rng.next();
            if (r >= 217) break :loop r;
        }
    };

    return damage *% random / 0xFF;
}

fn checkHit(battle: anytype, player: Player, move: Move.Data) bool {
    var side = battle.side(player);
    const foe = battle.foe(player);

    assert(!side.active.volatiles.Bide and move.effect != .Bide);

    if (move.effect == .DreamEater and !Status.is(foe.stored().status, .SLP)) return false;
    if (move.effect == .Swift) return true;
    if (foe.active.volatiles.Invulnerable) return false;

    // NB: Conversion / Haze / Light Screen / Reflect qualify but do not call checkHit
    if (foe.active.volatiles.Mist and
        (move.effect == .AttackDown1 or move.effect == .DefenseDown1 or
        move.effect == .SpeedDown1 or move.effect == .AccuracyDown1 or
        move.effect == .DefenseDown2)) return false;

    // NB: Thrash / Petal Dance / Rage get their accuracy overwritten on subsequent hits
    const overwritten = side.active.volatiles.data.state > 0;
    assert(!overwritten or (move.effect == .Thrashing or move.effect == .Rage));
    var accuracy = if (!showdown and overwritten)
        side.active.volatiles.data.state
    else
        @as(u16, move.accuracy());

    var boost = BOOSTS[@intCast(u4, side.active.boosts.accuracy + 6)];
    accuracy = accuracy * boost[0] / boost[1];
    boost = BOOSTS[@intCast(u4, -foe.active.boosts.evasion + 6)];
    accuracy = accuracy * boost[0] / boost[1];
    accuracy = @minimum(0xFF, @maximum(1, accuracy));

    side.active.volatiles.data.state = accuracy;

    const miss = if (showdown)
        !battle.rng.chance(u8, @truncate(u8, accuracy), 256)
    else
        battle.rng.next() >= accuracy;

    if (miss) {
        battle.last_damage = 0;
        side.active.volatiles.Trapping = false;
    }

    return miss;
}

fn applyDamage(battle: anytype, player: Player, move: Move.Data) void {
    assert(move.bp != 0);
    assert(battle.last_damage != 0);

    var foe = battle.foe(player);
    if (foe.active.volatiles.Substitute) {
        // NB: foe.volatiles.data.substitute is a u8 so must be less than 0xFF anyway
        if (battle.last_damage >= foe.volatiles.data.substitute) {
            foe.active.volatiles.data.substitute = 0;
            foe.active.volatiles.Substitute = false;
            // NB: battle.last_damage is not updated with the amount of HP the Substitute had
        } else {
            foe.active.volatiles.data.substitute -= battle.last_damage;
        }
    } else {
        if (battle.last_damage > foe.active.hp) battle.last_damage = foe.active.hp;
        foe.active.hp -= battle.last_damage;
    }
}

fn checkFaint(battle: anytype, player: Player, recurse: bool, log: anytype) !?Result {
    var side = battle.side(player);
    if (side.stored().hp > 0) return null;

    var foe = battle.foe(player);
    foe.active.volatiles.MultiHit = false;
    if (foe.active.volatiles.Bide) {
        foe.active.volatiles.data.state = if (showdown) 0 else foe.active.volatiles.data.state & 0xFF;
        if (foe.active.volatiles.data.state != 0) return Result.Error;
    }

    side.active.volatiles = .{};
    side.last_used_move = .None;
    // try log.faint(side.active.ident(side, player));

    //  TODO: if (findFirstAlive(side) == 0)

    _ = log;
    _ = recurse;

    return null;
}

fn handleResidual(battle: anytype, player: Player, log: anytype) !void {
    var side = battle.side(player);
    var stored = side.stored();
    const ident = side.active.ident(side, player);
    var volatiles = &side.active.volatiles;

    const brn = Status.is(stored.status, .BRN);
    if (brn or Status.is(stored.status, .PSN)) {
        var damage = @maximum(stored.stats.hp / 16, 1);

        if (volatiles.Toxic) {
            volatiles.data.toxic += 1;
            damage *= volatiles.data.toxic;
        }

        stored.hp -= @minimum(damage, stored.hp);
        try log.damage(ident, stored, if (brn) Damage.Burn else Damage.Poison); // TODO: damageOf?
    }

    if (volatiles.LeechSeed) {
        var damage = @maximum(stored.stats.hp / 16, 1);

        // NB: Leech Seed + Toxic glitch
        if (volatiles.Toxic) {
            volatiles.data.toxic += 1;
            damage *= volatiles.data.toxic;
        }

        stored.hp -= @minimum(damage, stored.hp);

        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = foe.active.ident(foe, player.foe());

        try log.damageOf(ident, stored, .LeechSeedOf, foe_ident);

        // NB: uncapped damage is added back to the foe
        foe_stored.hp = @minimum(foe_stored.hp + damage, foe_stored.stats.hp);
        try log.drain(foe_ident, foe_stored, ident);
    }
}

// TODO: struggle bypass/wrap underflow
fn decrementPP(side: *Side, choice: Choice) void {
    assert(choice.type == .Move);
    assert(choice.data <= 4);

    if (choice.data == 0) return; // Struggle

    var active = &side.active;
    const volatiles = &active.volatiles;

    if (volatiles.Bide or volatiles.Thrashing or volatiles.MultiHit or volatiles.Rage) return;

    active.move(choice.data).pp -= 1;
    if (volatiles.Transform) return;

    side.stored().move(choice.data).pp -= 1;
}

fn moveEffect(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
    return switch (move.effect) {
        .Bide => Effects.bide(battle, player, log),
        .BurnChance1, .BurnChance2 => Effects.burnChance(battle, player, move, log),
        .Charge => Effects.charge(battle, player, log),
        .Confusion, .ConfusionChance => Effects.confusion(battle, player, move, log),
        .Conversion => Effects.conversion(battle, player, log),
        .Disable => Effects.disable(battle, player, move, log),
        .DrainHP, .DreamEater => Effects.drainHP(battle, player, log),
        .Explode => Effects.explode(battle, player),
        .FlinchChance1, .FlinchChance2 => Effects.flinchChance(battle, player, move),
        .FocusEnergy => Effects.focusEnergy(battle, player, log),
        .FreezeChance => Effects.freezeChance(battle, player, move, log),
        .Haze => Effects.haze(battle, player, log),
        .Heal => Effects.heal(battle, player, log),
        .HyperBeam => Effects.hyperBeam(battle, player),
        .LeechSeed => Effects.leechSeed(battle, player, log),
        .LightScreen => Effects.lightScreen(battle, player, log),
        .Mimic => Effects.mimic(battle, player, log),
        .Mist => Effects.mist(battle, player, log),
        .MultiHit, .DoubleHit, .Twineedle => Effects.multiHit(battle, player, move, log),
        .Paralyze => Effects.paralyze(battle, player, move, log),
        .ParalyzeChance1, .ParalyzeChance2 => Effects.paralyzeChance(battle, player, move, log),
        .PayDay => Effects.payDay(log),
        .Poison, .PoisonChance1, .PoisonChance2 => Effects.paralyze(battle, player, move, log),
        .Rage => Effects.rage(battle, player),
        .Recoil => Effects.recoil(battle, player, log),
        .Reflect => Effects.reflect(battle, player, log),
        .Sleep => Effects.sleep(battle, player, move, log),
        .Splash => Effects.splash(battle, player, log),
        .SwitchAndTeleport => {}, // does nothing outside of wild battles
        .Thrashing => Effects.thrashing(battle, player),
        .Transform => Effects.transform(battle, player, log),
        .Trapping => Effects.trapping(battle, player),
        // zig fmt: off
        .AttackUp1, .AttackUp2, .DefenseUp1, .DefenseUp2,
        .EvasionUp1, .SpecialUp1, .SpecialUp2, .SpeedUp2 =>
            Effects.boost(battle, player, move, log),
        .AccuracyDown1, .AttackDown1, .DefenseDown1, .DefenseDown2, .SpeedDown1,
        .AttackDownChance, .DefenseDownChance, .SpecialDownChance, .SpeedDownChance =>
            Effects.unboost(battle, player, move, log),
        // zig fmt: on
        else => unreachable,
    };
}

pub const Effects = struct {
    fn bide(battle: anytype, player: Player, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = log;
    }

    fn burnChance(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = foe.active.ident(foe, player.foe());

        if (Status.is(foe_stored.status, .FRZ)) {
            assert(move.type == .Fire);
            foe_stored.status = 0;
        }

        const cant = foe.active.volatiles.Substitute or Status.any(foe_stored.status);
        if (cant) return log.fail(foe_ident, .Burn);

        const chance = !foe.active.types.includes(move.type) and if (showdown)
            battle.rng.chance(u8, @as(u8, if (move.effect == .BurnChance1) 26 else 77), 256)
        else
            battle.rng.next() < 1 + (if (move.effect == .BurnChance1)
                Gen12.percent(10)
            else
                Gen12.percent(30));
        if (!chance) return;

        foe_stored.status = Status.init(.BRN);
        foe.active.stats.atk = @maximum(foe.active.stats.atk / 2, 1);

        try log.status(foe_ident, foe_stored.status, .None);
    }

    fn charge(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var volatiles = &side.active.volatiles;
        const ident = side.active.ident(side, player);

        volatiles.Charging = true;
        const move = side.last_selected_move;
        if (move == .Fly or move == .Dig) volatiles.Invulnerable = true;
        try log.prepare(ident, move);
    }

    fn confusion(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);
        const player_ident = side.active.ident(side, player);
        const foe_ident = foe.active.ident(foe, player.foe());

        if (move.effect == .ConfusionChance) {
            const chance = if (showdown)
                // BUG: this diverges because showdown uses 26 instead of 25
                battle.rng.chance(u8, 26, 256)
            else
                battle.rng.next() < Gen12.percent(10);
            if (!chance) return;
        } else {
            if (foe.active.volatiles.Substitute) return;

            if (!checkHit(battle, player, move)) {
                try log.lastmiss();
                return log.miss(player_ident, foe_ident);
            }
        }

        if (foe.active.volatiles.Confusion) return;
        foe.active.volatiles.Confusion = true;

        // NB: these values will diverge
        foe.active.volatiles.data.confusion = @truncate(u4, if (showdown)
            battle.rng.range(u8, 3, 5)
        else
            (battle.rng.next() & 3) + 2);

        try log.start(foe_ident, .Confusion);
    }

    fn conversion(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        const foe = battle.foe(player);

        const ident = side.active.ident(side, player);

        if (foe.active.volatiles.Invulnerable) {
            try log.miss(ident, foe.active.ident(foe, player.foe()));
            return;
        }

        side.active.types = foe.active.types;
        try log.typechange(ident, foe.active.types);
    }

    fn disable(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        var volatiles = &foe.active.volatiles;

        const player_ident = side.active.ident(side, player);
        const foe_ident = foe.active.ident(foe, player.foe());

        if (!checkHit(battle, player, move) or volatiles.data.disabled.move != 0) {
            try log.lastmiss();
            return log.miss(player_ident, foe_ident);
        }

        const m = Move.None; // TODO
        volatiles.data.disabled.move = 0; // TODO;

        // NB: these values will diverge
        volatiles.data.disabled.duration = @truncate(u4, if (showdown)
            // BUG: battle.rng.range(u8, 1, 7) + 1 = 2 - 8...?
            battle.rng.range(u8, 1, 7)
        else
            (battle.rng.next() & 7) + 1);

        try log.startEffect(foe_ident, .Disable, m);
    }

    fn drainHP(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        var stored = side.stored();

        const player_ident = side.active.ident(side, player);
        const foe_ident = foe.active.ident(foe, player.foe());

        const drain = @maximum(battle.last_damage / 2, 1);
        battle.last_damage = drain;
        stored.hp = @minimum(stored.stats.hp, stored.hp + drain);

        try log.drain(player_ident, stored, foe_ident);
    }

    fn explode(battle: anytype, player: Player) !void {
        var side = battle.side(player);
        var stored = side.stored();

        stored.hp = 0;
        stored.status = 0;
        side.active.volatiles.LeechSeed = false;
    }

    fn flinchChance(battle: anytype, player: Player, move: Move.Data) !void {
        var volatiles = &battle.foe(player).active.volatiles;

        if (volatiles.Substitute) return;

        const chance = if (showdown)
            battle.rng.chance(u8, @as(u8, if (move.effect == .FlinchChance1) 26 else 77), 256)
        else
            battle.rng.next() < 1 + (if (move.effect == .FlinchChance1)
                Gen12.percent(10)
            else
                Gen12.percent(30));
        if (!chance) return;

        volatiles.Flinch = true;
        volatiles.Recharging = false;
    }

    fn focusEnergy(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        const ident = side.active.ident(side, player);

        if (side.active.volatiles.FocusEnergy) return;
        side.active.volatiles.FocusEnergy = true;

        try log.start(ident, .FocusEnergy);
    }

    fn freezeChance(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = foe.active.ident(foe, player.foe());

        const cant = foe.active.volatiles.Substitute or Status.any(foe_stored.status);
        if (cant) return log.fail(foe_ident, .Freeze);

        const chance = !foe.active.types.includes(move.type) and if (showdown)
            battle.rng.chance(u8, 26, 256)
        else
            battle.rng.next() < 1 + Gen12.percent(10);
        if (!chance) return;

        // FIXME: Freeze Clause Mod
        foe_stored.status = Status.init(.FRZ);
        // NB: Hyper Beam recharging status is not cleared

        try log.status(foe_ident, foe_stored.status, .None);
    }

    // TODO: handle showdown bugginess...
    fn haze(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        var side_stored = side.stored();
        var foe_stored = foe.stored();

        const player_ident = side.active.ident(side, player);
        const foe_ident = foe.active.ident(foe, player.foe());

        side.active.boosts = .{};
        foe.active.boosts = .{};

        side.active.stats = side_stored.stats;
        foe.active.stats = foe_stored.stats;

        try log.activate(player_ident, .Haze);
        try log.clearallboost();

        if (Status.any(foe_stored.status)) {
            if (Status.is(foe_stored.status, .FRZ) or Status.is(foe_stored.status, .SLP)) {
                foe.last_selected_move = .SKIP_TURN;
            }

            try log.curestatus(foe_ident, foe_stored.status, .Silent);
            foe_stored.status = 0;
        }

        try clearVolatiles(&side.active, player_ident, log);
        try clearVolatiles(&foe.active, foe_ident, log);
    }

    fn heal(battle: anytype, player: Player, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = log;
    }

    fn hyperBeam(battle: anytype, player: Player) !void {
        battle.side(player).active.volatiles.Recharging = true;
    }

    fn leechSeed(battle: anytype, player: Player, log: anytype) !void {
        var foe = battle.foe(player);
        const foe_ident = foe.active.ident(foe, player.foe());

        if (foe.active.types.includes(.Grass) or foe.active.volatiles.LeechSeed) return;
        foe.active.volatiles.LeechSeed = true;

        try log.start(foe_ident, .LeechSeed);
    }

    fn lightScreen(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        const ident = side.active.ident(side, player);

        if (side.active.volatiles.LightScreen) {
            try log.fail(ident, .None);
            return;
        }
        side.active.volatiles.LightScreen = true;

        try log.start(ident, .LightScreen);
    }

    fn mimic(battle: anytype, player: Player, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = log;
    }

    fn mist(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        const ident = side.active.ident(side, player);

        if (side.active.volatiles.Mist) return;
        side.active.volatiles.Mist = true;

        try log.start(ident, .Mist);
    }

    fn multiHit(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = move;
        _ = log;
    }

    fn paralyze(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = foe.active.ident(foe, player.foe());

        if (Status.any(foe_stored.status)) return log.fail(foe_ident, .Paralysis);
        if (foe.active.types.immune(move.type)) return log.immune(foe_ident, .None);
        if (!checkHit(battle, player, move)) {
            const side = battle.side(player);
            const player_ident = side.active.ident(side, player);

            try log.lastmiss();
            return log.miss(player_ident, foe_ident);
        }

        foe_stored.status = Status.init(.PAR);
        foe.active.stats.spe = @maximum(foe.active.stats.spe / 4, 1);

        try log.status(foe_ident, foe_stored.status, .None);
    }

    fn paralyzeChance(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = foe.active.ident(foe, player.foe());

        const cant = foe.active.volatiles.Substitute or Status.any(foe_stored.status);
        if (cant) return log.fail(foe_ident, .Paralysis);

        // NB: Body Slam can't paralyze a Normal type Pokémon
        const chance = !foe.active.types.includes(move.type) and if (showdown)
            battle.rng.chance(u8, @as(u8, if (move.effect == .ParalyzeChance1) 26 else 77), 256)
        else
            battle.rng.next() < 1 + (if (move.effect == .ParalyzeChance1)
                Gen12.percent(10)
            else
                Gen12.percent(30));
        if (!chance) return;

        foe_stored.status = Status.init(.PAR);
        foe.active.stats.spe = @maximum(foe.active.stats.spe / 4, 1);

        try log.status(foe_ident, foe_stored.status, .None);
    }

    fn payDay(log: anytype) !void {
        try log.fieldactivate();
    }

    fn poison(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        var foe_stored = foe.stored();

        const player_ident = side.active.ident(side, player);
        const foe_ident = foe.active.ident(foe, player.foe());

        const cant = foe.active.volatiles.Substitute or
            Status.any(foe_stored.status) or
            foe.active.types.includes(.Poison);

        if (cant) return log.fail(foe_ident, .Poison);

        const chance = if (move.effect == .Poison) true else if (showdown)
            battle.rng.chance(u8, if (move.effect == .PoisonChance1) 52 else 103, 256)
        else
            battle.rng.next() < 1 + (if (move.effect == .PoisonChance1)
                Gen12.percent(20)
            else
                Gen12.percent(40));
        if (!chance) return;

        if (!checkHit(battle, player, move)) {
            try log.lastmiss();
            return log.miss(player_ident, foe_ident);
        }

        foe_stored.status = Status.init(.PSN);
        if (foe.last_selected_move == .Toxic) {
            foe.active.volatiles.Toxic = true;
            foe.active.volatiles.data.toxic = 0;
        }

        try log.status(foe_ident, foe_stored.status, .None);
    }

    fn rage(battle: anytype, player: Player) !void {
        battle.side(player).active.volatiles.Rage = true;
    }

    fn recoil(battle: anytype, player: Player, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = log;
    }

    fn reflect(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        const ident = side.active.ident(side, player);

        if (side.active.volatiles.Reflect) {
            try log.fail(ident, .None);
            return;
        }

        side.active.volatiles.Reflect = true;
        try log.start(ident, .Reflect);
    }

    fn sleep(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = foe.active.ident(foe, player.foe());

        if (foe.active.volatiles.Recharging) {
            foe.active.volatiles.Recharging = false;
            // NB: hit test not applied if the target is recharging (fallthrough)
        } else if (Status.any(foe_stored.status)) {
            return log.fail(foe_ident, .Sleep);
        } else if (!checkHit(battle, player, move)) {
            const side = battle.side(player);
            const player_ident = side.active.ident(side, player);

            try log.lastmiss();
            return log.miss(player_ident, foe_ident);
        }

        // NB: these values will diverge
        const duration = @truncate(u3, if (showdown)
            battle.rng.range(u8, 1, 8)
        else loop: {
            while (true) {
                const r = battle.rng.next() & 7;
                if (r != 0) break :loop r;
            }
        });
        // FIXME: Sleep Clause Mod
        foe_stored.status = Status.slp(duration);
        try log.status(foe_ident, foe_stored.status, .None);
    }

    fn splash(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        const ident = side.active.ident(side, player);

        try log.activate(ident, .Splash);
    }

    fn thrashing(battle: anytype, player: Player) !void {
        var volatiles = &battle.side(player).active.volatiles;

        volatiles.Thrashing = true;
        // NB: these values will diverge
        volatiles.data.attacks = @truncate(u4, if (showdown)
            battle.rng.range(u8, 2, 4)
        else
            (battle.rng.next() & 1) + 2);
    }

    fn transform(battle: anytype, player: Player, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = log;
    }

    fn trapping(battle: anytype, player: Player) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        if (side.active.volatiles.Trapping) return;
        side.active.volatiles.Trapping = true;
        // NB: Recharging is cleared even if the trapping move misses
        foe.active.volatiles.Recharging = false;

        side.active.volatiles.data.attacks = distribution(battle) - 1;
    }

    fn boost(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = move;
        _ = log;
    }

    fn unboost(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        // TODO
        _ = battle;
        _ = player;
        _ = move;
        _ = log;
    }
};

fn clearVolatiles(active: *ActivePokemon, ident: u8, log: anytype) !void {
    var volatiles = &active.volatiles;
    if (volatiles.data.disabled.move != 0) {
        volatiles.data.disabled = .{};
        try log.end(ident, .DisableSilent);
    }
    if (volatiles.Confusion) {
        // NB: volatiles.data.confusion is left unchanged
        volatiles.Confusion = false;
        try log.end(ident, .ConfusionSilent);
    }
    if (volatiles.Mist) {
        volatiles.Mist = false;
        try log.end(ident, .Mist);
    }
    if (volatiles.FocusEnergy) {
        volatiles.FocusEnergy = false;
        try log.end(ident, .FocusEnergy);
    }
    if (volatiles.LeechSeed) {
        volatiles.LeechSeed = false;
        try log.end(ident, .LeechSeed);
    }
    if (volatiles.Toxic) {
        if (showdown) volatiles.data.toxic = 0;
        // NB: volatiles.data.toxic is left unchanged
        volatiles.Toxic = false;
        try log.end(ident, .Toxic);
    }
    if (volatiles.LightScreen) {
        volatiles.LightScreen = false;
        try log.end(ident, .LightScreen);
    }
    if (volatiles.Reflect) {
        volatiles.Reflect = false;
        try log.end(ident, .Reflect);
    }
    if (!showdown) return;
    // TODO: other volatiles
}

const DISTRIBUTION = [_]u4{ 2, 2, 2, 3, 3, 3, 4, 5 };

// NB: these values will diverge
fn distribution(battle: anytype) u4 {
    if (showdown) return DISTRIBUTION[battle.rng.range(u8, 0, DISTRIBUTION.len)];
    const r = (battle.rng.next() & 3);
    return @truncate(u4, (if (r < 2) r else battle.rng.next() & 3) + 2);
}

test "RNG agreement" {
    var expected: [256]u8 = undefined;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        expected[i] = @truncate(u8, i);
    }

    var spe1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var spe2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    var cfz1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var cfz2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    var par1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var par2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    var brn1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var brn2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    i = 0;
    while (i < expected.len) : (i += 1) {
        try expectEqual(spe1.range(u8, 0, 2) == 0, spe2.next() < Gen12.percent(50) + 1);
        try expectEqual(!cfz1.chance(u8, 128, 256), cfz2.next() >= Gen12.percent(50) + 1);
        try expectEqual(par1.chance(u8, 63, 256), par2.next() < Gen12.percent(25));
        try expectEqual(brn1.chance(u8, 26, 256), brn2.next() < Gen12.percent(10) + 1);
    }
}

pub fn choices(battle: anytype, player: Player, request: Choice.Type, out: []Choice) u8 {
    var n: u8 = 0;
    switch (request) {
        .Pass => {
            out[n] = .{};
            n += 1;
        },
        .Switch => {
            const side = battle.side(player);
            var slot: u4 = 2;
            while (slot <= 6) : (slot += 1) {
                const pokemon = side.get(slot);
                if (pokemon.hp == 0) continue;
                out[n] = .{ .type = .Switch, .data = slot };
                n += 1;
            }
            if (n == 0) {
                out[n] = .{};
                n += 1;
            }
        },
        .Move => {
            const side = battle.side(player);
            const foe = battle.foe(player);

            var active = side.active;

            if (active.volatiles.Recharging) {
                out[n] = .{ .type = .Move, .data = 0 }; // recharge
                n += 1;
                return n;
            }

            const trapped = foe.active.volatiles.Trapping;
            if (!trapped) {
                var slot: u4 = 2;
                while (slot <= 6) : (slot += 1) {
                    const pokemon = side.get(slot);
                    if (pokemon.hp == 0) continue;
                    out[n] = .{ .type = .Switch, .data = slot };
                    n += 1;
                }
            }

            const before = n;
            var slot: u4 = 1;
            while (slot <= 4) : (slot += 1) {
                const m = active.move(slot);
                if (m.id == .None) break;
                if (m.pp == 0 and !trapped) continue;
                if (active.volatiles.data.disabled.move == slot) continue;
                out[n] = .{ .type = .Move, .data = slot };
                n += 1;
            }
            if (n == before) {
                out[n] = .{ .type = .Move, .data = 0 }; // Struggle
                n += 1;
            }
        },
    }
    return n;
}
