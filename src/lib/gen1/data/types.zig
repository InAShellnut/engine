//! Code generated by `tools/generate` - manual edits will be overwritten

const std = @import("std");

const gen1 = @import("../../gen1/data.zig");

const assert = std.debug.assert;
const Effectiveness = gen1.Effectiveness;

const S = Effectiveness.Super;
const N = Effectiveness.Neutral;
const R = Effectiveness.Resisted;
const I = Effectiveness.Immune;

/// Representation of a type in Pokémon.
pub const Type = enum(u4) {
    Normal,
    Fighting,
    Flying,
    Poison,
    Ground,
    Rock,
    Bug,
    Ghost,
    Fire,
    Water,
    Grass,
    Electric,
    Psychic,
    Ice,
    Dragon,

    const CHART = [15][15]Effectiveness{
        [_]Effectiveness{ N, N, N, N, N, R, N, I, N, N, N, N, N, N, N }, // Normal
        [_]Effectiveness{ S, N, R, R, N, S, R, I, N, N, N, N, R, S, N }, // Fighting
        [_]Effectiveness{ N, S, N, N, N, R, S, N, N, N, S, R, N, N, N }, // Flying
        [_]Effectiveness{ N, N, N, R, R, R, S, R, N, N, S, N, N, N, N }, // Poison
        [_]Effectiveness{ N, N, I, S, N, S, R, N, S, N, R, S, N, N, N }, // Ground
        [_]Effectiveness{ N, R, S, N, R, N, S, N, S, N, N, N, N, S, N }, // Rock
        [_]Effectiveness{ N, R, R, S, N, N, N, R, R, N, S, N, S, N, N }, // Bug
        [_]Effectiveness{ I, N, N, N, N, N, N, S, N, N, N, N, I, N, N }, // Ghost
        [_]Effectiveness{ N, N, N, N, N, R, S, N, R, R, S, N, N, S, R }, // Fire
        [_]Effectiveness{ N, N, N, N, S, S, N, N, S, R, R, N, N, N, R }, // Water
        [_]Effectiveness{ N, N, R, R, S, S, R, N, R, S, R, N, N, N, R }, // Grass
        [_]Effectiveness{ N, N, S, N, I, N, N, N, N, S, R, R, N, N, R }, // Electric
        [_]Effectiveness{ N, S, N, S, N, N, N, N, N, N, N, N, R, N, N }, // Psychic
        [_]Effectiveness{ N, N, S, N, S, N, N, N, N, R, S, N, N, R, S }, // Ice
        [_]Effectiveness{ N, N, N, N, N, N, N, N, N, N, N, N, N, N, S }, // Dragon
    };

    const PRECEDENCE = [_]Types{
        .{ .type1 = .Fire, .type2 = .Ice },
        .{ .type1 = .Grass, .type2 = .Water },
        .{ .type1 = .Water, .type2 = .Rock },
        .{ .type1 = .Water, .type2 = .Water },
        .{ .type1 = .Electric, .type2 = .Electric },
        .{ .type1 = .Ice, .type2 = .Ice },
        .{ .type1 = .Fire, .type2 = .Water },
        .{ .type1 = .Electric, .type2 = .Flying },
        .{ .type1 = .Grass, .type2 = .Ground },
        .{ .type1 = .Grass, .type2 = .Poison },
        .{ .type1 = .Grass, .type2 = .Rock },
        .{ .type1 = .Grass, .type2 = .Flying },
        .{ .type1 = .Ice, .type2 = .Water },
        .{ .type1 = .Ice, .type2 = .Flying },
        .{ .type1 = .Fighting, .type2 = .Normal },
        .{ .type1 = .Fighting, .type2 = .Flying },
        .{ .type1 = .Fighting, .type2 = .Psychic },
        .{ .type1 = .Fighting, .type2 = .Rock },
        .{ .type1 = .Fighting, .type2 = .Ice },
        .{ .type1 = .Poison, .type2 = .Grass },
        .{ .type1 = .Poison, .type2 = .Poison },
        .{ .type1 = .Poison, .type2 = .Bug },
        .{ .type1 = .Ground, .type2 = .Grass },
        .{ .type1 = .Ground, .type2 = .Bug },
        .{ .type1 = .Ground, .type2 = .Poison },
        .{ .type1 = .Bug, .type2 = .Flying },
        .{ .type1 = .Bug, .type2 = .Ghost },
        .{ .type1 = .Bug, .type2 = .Poison },
        .{ .type1 = .Electric, .type2 = .Dragon },
    };

    comptime {
        assert(@bitSizeOf(Type) == 4);
        assert(@sizeOf(@TypeOf(CHART)) == 225);
        assert(@sizeOf(@TypeOf(PRECEDENCE)) == 29);
    }

    /// The number of types in this generation.
    pub const size = 15;

    /// Whether or not this type is considered to be special as opposed to physical.
    pub inline fn special(self: Type) bool {
        return @enumToInt(self) >= @enumToInt(Type.Fire);
    }

    /// The `Effectiveness` of type `t2` vs. type `t1`.
    pub inline fn effectiveness(t1: Type, t2: Type) Effectiveness {
        return CHART[@enumToInt(t1)][@enumToInt(t2)];
    }

    /// The precedence order of type `t2` vs. type  `t1`.
    pub fn precedence(t1: Type, t2: Type) u8 {
        for (PRECEDENCE, 0..) |matchup, i| {
            if (matchup.type1 == t1 and matchup.type2 == t2) return @intCast(u8, i);
        }
        unreachable;
    }
};

/// Representation of a Pokémon's typing.
pub const Types = packed struct {
    /// A Pokémon's primary type.
    type1: Type = .Normal,
    /// A Pokémon's secondary type (may be identical to its primary type).
    type2: Type = .Normal,

    comptime {
        assert(@sizeOf(Types) == 1);
    }

    /// Whether this typing is immune to type `t`.
    pub inline fn immune(self: Types, t: Type) bool {
        return t.effectiveness(self.type1) == I or t.effectiveness(self.type2) == I;
    }

    /// Whether this typing includes type `t`.
    pub inline fn includes(self: Types, t: Type) bool {
        return self.type1 == t or self.type2 == t;
    }
};
