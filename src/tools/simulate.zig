const std = @import("std");
const pkmn = @import("pkmn");

// https://gist.github.com/scheibo/ae7bef7600d0a2af508c6d03e419e0b8
pub fn simulate(gen: u8, num: usize, seed: u64) !void {
    std.debug.assert(gen >= 1 and gen <= 8);

    var random = pkmn.rng.Random.init(seed);
    // var random = std.rand.DefaultPrng.init(seed).random();

    var options: [pkmn.MAX_OPTIONS_SIZE]pkmn.Choice = undefined;

    var i: usize = 0;
    while (i <= num) : (i += 1) {
        var battle = switch (gen) {
            1 => pkmn.gen1.helpers.Battle.random(&random, true),
            else => unreachable, // TODO
        };

        var c1 = pkmn.Choice{};
        var c2 = pkmn.Choice{};

        var result = try battle.update(c1, c2, null);
        while (result.type == .None) : (result = try battle.update(c1, c2, null)) {
            c1 = options[random.range(0, battle.choices(.P1, result.p1, options) - 1)];
            c2 = options[random.range(0, battle.choices(.P2, result.p2, options) - 1)];
            // c1 = options[random.uintLessThan(battle.choices(.P1, result.p1, options))];
            // c2 = options[random.uintLessThan(battle.choices(.P2, result.p2, options))];
        }

        const msg = switch (result.type) {
            .Win => "won by Player A",
            .Lose => "won by Player B",
            .Tie => "ended in a tie",
            .Error => "encountered an error",
            else => unreachable,
        };

        try std.debug.print("Battle {d} {s} after {d} turns", .{ i + 1, msg, battle.turn });
    }
}