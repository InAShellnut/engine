//! Code generated by `tools/generate` - manual edits will be overwritten.

const assert = @import("std").debug.assert;
const Effectiveness = @import("../../gen1/data.zig").Effectiveness;

/// Type constants representing all non-glitch types.
///
/// **NOTE**: these do *not* match the in-game values (eg. there is no gap between
/// the Physical and Special types).
///
/// *See:* https://pkmn.cc/pokered/constants/type_constants.asm
///
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

    comptime {
        assert(@bitSizeOf(Type) == 4);
    }

    pub fn effectiveness(t1: Type, t2: Type) Effectiveness {
        return TYPE_CHART[@enumToInt(t1)][@enumToInt(t2)];
    }
};

// TODO: [2]Type
pub const Types = packed struct {
    type1: Type,
    type2: Type,

    comptime {
        assert(@bitSizeOf(Types) == 8);
    }
};

const S = Effectiveness.Super;
const N = Effectiveness.Neutral;
const R = Effectiveness.Resisted;
const I = Effectiveness.Immune;

/// Type chart, organizated in terms of damage-dealt like on the cartridge. However,
/// unlike in-game we store the entire table as a multidimensional array for faster
/// queries (the cartridge's approach of only listing non-neutral matchups saves memory
/// but requires linear scanning for lookups).
///
/// **NOTE**: Pokémon Showdown stores its type chart in the reverse order (ie. damage-dealt).
///
/// *See:* ttps://pkmn.cc/pokered/data/types/type_matchups.asm
///
const TYPE_CHART = [15][15]Effectiveness{
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
