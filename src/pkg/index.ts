import {
  BoostsTable,
  Generation,
  ID,
  StatsTable,
  StatusName,
  TypeName,
} from '@pkmn/data';

import {Lookup} from './data';
import * as gen1 from './gen1';

export interface Battle extends Gen1.Battle {}
export interface Side extends Gen1.Side {}
export interface ActivePokemon extends Gen1.ActivePokemon {}
export interface Pokemon extends Gen1.Pokemon {}
export interface MoveSlot extends Gen1.MoveSlot {}

export namespace Gen1 {
  export interface Battle {
    sides: Iterable<Side>;
    turn: number;
    lastDamage: number;
    prng: readonly number[];
  }

  export interface Side {
    active: ActivePokemon;
    pokemon: Iterable<Pokemon>;
    lastUsedMove: ID | undefined;
    lastSelectedMove: ID | undefined;
  }

  export interface ActivePokemon {
    species: ID;
    types: readonly [TypeName, TypeName];
    stats: StatsTable;
    boosts: BoostsTable;
    volatiles: {[name: string]: Volatile};
    moves: Iterable<MoveSlot>;
    toxic: number;
  }

  export interface Pokemon {
    species: ID;
    types: readonly [TypeName, TypeName];
    hp: number;
    status: Exclude<StatusName, 'tox'> | undefined;
    stats: StatsTable;
    level: number;
    moves: Iterable<Omit<MoveSlot, 'disabled'>>;
  }

  export interface MoveSlot {
    move: ID;
    pp: number;
    disabled: number | undefined;
  }

  export interface Volatile {
    duration?: number;
    damage?: number;
    hp?: number;
    accuracy?: number;
  }
}

export class Battle {
  static create(gen: Generation, buf: ArrayBuffer, showdown = true) {
    switch (gen.num) {
    case 1: return new gen1.Battle(Lookup.get(gen), new DataView(buf), showdown);
    default: throw new Error(`Unsupported gen ${gen.num}`);
    }
  }
}
