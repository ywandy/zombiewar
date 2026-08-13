import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  BIT_ALIVE,
  BIT_CONFIRM,
  BIT_NEXT_EQUIPMENT,
  BIT_PREV_EQUIPMENT,
  BIT_PRESENT,
  BIT_USE_JUST_PRESSED,
  BIT_USE_PRESSED,
  CONTENT_ID_MAX_LENGTH,
  EDGE_BITS,
  EVENT_MELEE,
  EVENT_PLACE_ITEM,
  EVENT_SHOT,
  MAX_MERGED_EVENTS,
  PROTOCOL_VERSION,
  QUANT,
  STICKY_BITS,
  TICK_HZ,
  TICK_MS,
  isLobbyOpcode,
  isSyncOpcode,
  mergeCommand,
  parseCommand,
  type PlayerCommand,
} from '../src/lib/protocol.js';

const CLIENT_PROTOCOL = resolve(import.meta.dirname, '../../scripts/net/lobby_protocol.gd');

function readGdConstant(source: string, name: string): number {
  // `1 << 3` first: its leading `1` is itself a valid literal, so a
  // literal-first reader would silently read every bit flag as 1.
  const shift = new RegExp(`const ${name} := 1 << (\\d+)`).exec(source);
  if (shift !== null) return 1 << Number.parseInt(shift[1]!, 10);
  const match = new RegExp(`const ${name} := (0x[0-9A-Fa-f]+|\\d+)`).exec(source);
  if (match === null) throw new Error(`client protocol has no constant ${name}`);
  return Number(match[1]);
}

describe('protocol constants', () => {
  const source = readFileSync(CLIENT_PROTOCOL, 'utf8');

  it.each([
    ['PROTOCOL_VERSION', PROTOCOL_VERSION],
    ['TICK_HZ', TICK_HZ],
    ['BIT_USE_PRESSED', BIT_USE_PRESSED],
    ['BIT_USE_JUST_PRESSED', BIT_USE_JUST_PRESSED],
    ['BIT_ALIVE', BIT_ALIVE],
    ['BIT_PRESENT', BIT_PRESENT],
    ['EVENT_SHOT', EVENT_SHOT],
    ['EVENT_PLACE_ITEM', EVENT_PLACE_ITEM],
    ['CONTENT_ID_MAX_LENGTH', CONTENT_ID_MAX_LENGTH],
  ])('%s matches the Godot client', (name, expected) => {
    expect(readGdConstant(source, name)).toBe(expected);
  });

  it('shares the quantisation scale with the client', () => {
    // The client spells it as a float (1000.0) because GDScript needs it that way.
    expect(new RegExp(`const QUANT := ${QUANT}\\.0`).test(source)).toBe(true);
  });

  it('paces frames at exactly the tick rate', () => {
    expect(TICK_MS).toBe(50);
    expect(1000 / TICK_HZ).toBe(TICK_MS);
  });

  it('keeps the lobby and sync opcode ranges disjoint', () => {
    expect(isLobbyOpcode(0x7f)).toBe(true);
    expect(isSyncOpcode(0x7f)).toBe(false);
    expect(isLobbyOpcode(0x80)).toBe(false);
    expect(isSyncOpcode(0x80)).toBe(true);
  });
});

describe('parseCommand', () => {
  const valid = { m: [100, 0], b: BIT_ALIVE | BIT_PRESENT, p: [1000, -2000] };

  it('accepts a well-formed command', () => {
    expect(parseCommand(valid)).toEqual(valid);
  });

  it.each([
    ['non-integer position', { ...valid, p: [1.5, 2] }],
    ['short move pair', { ...valid, m: [1] }],
    ['missing bits', { m: [0, 0], p: [0, 0] }],
    ['out-of-range bits', { ...valid, b: 999 }],
    ['not an object', 'nope'],
    ['null', null],
  ])('drops a command with %s', (_label, input) => {
    expect(parseCommand(input)).toBeNull();
  });

  it('caps the events a single tick may raise', () => {
    const events = Array.from({ length: 20 }, () => ({ k: EVENT_SHOT, w: 0 }));
    const parsed = parseCommand({ ...valid, e: events });
    expect(parsed?.e?.length).toBe(8);
  });

  it('drops unknown event kinds rather than repairing them', () => {
    // A repaired command differs between the sender's simulation and everyone
    // else's, which is a desync with extra steps.
    const parsed = parseCommand({ ...valid, e: [{ k: 99 }, { k: EVENT_SHOT, w: 1 }] });
    expect(parsed?.e).toEqual([{ k: EVENT_SHOT, w: 1 }]);
  });

  it('carries a placement cell through untouched, negatives included', () => {
    // The cell is the whole payload of a placement: drop `ci`/`cj` from the
    // copied-key list and every barrel silently lands on the grid origin
    // instead of in front of the player -- on every client at once, so no
    // desync fires to point at it.
    const place = { k: EVENT_PLACE_ITEM, pi: 5, ci: -12, cj: 7 };
    expect(parseCommand({ ...valid, e: [place] })?.e).toEqual([place]);
  });

  it('ignores an over-long hash', () => {
    expect(parseCommand({ ...valid, h: 'x'.repeat(64) })?.h).toBeUndefined();
  });
});

describe('bit classes', () => {
  const source = readFileSync(CLIENT_PROTOCOL, 'utf8');

  it('splits every defined bit into exactly one of sticky or edge', () => {
    expect(STICKY_BITS & EDGE_BITS).toBe(0);
    expect(STICKY_BITS | EDGE_BITS).toBe(
      BIT_USE_PRESSED |
        BIT_USE_JUST_PRESSED |
        BIT_PREV_EQUIPMENT |
        BIT_NEXT_EQUIPMENT |
        BIT_CONFIRM |
        BIT_ALIVE |
        BIT_PRESENT,
    );
  });

  it('agrees with the client on which bits are one-shot', () => {
    // The client clears exactly these after each send. If the two lists drift,
    // one side repeats an edge every tick and the other does not -- a desync
    // whose cause is two files that never reference each other.
    const match = /const ONE_SHOT_BITS := \(([^)]*)\)/.exec(source);
    if (match === null) throw new Error('client protocol has no ONE_SHOT_BITS');
    const names = match[1]!
      .split('|')
      .map((entry) => entry.trim())
      .filter((entry) => entry !== '');
    expect(new Set(names)).toEqual(
      new Set(['BIT_USE_JUST_PRESSED', 'BIT_PREV_EQUIPMENT', 'BIT_NEXT_EQUIPMENT', 'BIT_CONFIRM']),
    );
    expect(names.reduce((bits, name) => bits | readGdConstant(source, name), 0)).toBe(EDGE_BITS);
  });
});

describe('mergeCommand', () => {
  const shot = (weapon: number) => ({ k: EVENT_SHOT, w: weapon });
  const base = (overrides: Partial<PlayerCommand> = {}): PlayerCommand => ({
    m: [0, 0],
    b: BIT_ALIVE | BIT_PRESENT,
    p: [0, 0],
    ...overrides,
  });

  it('takes the arriving command when the slot is empty', () => {
    const next = base({ m: [5, 5] });
    expect(mergeCommand(null, next)).toBe(next);
  });

  it('takes the newest move, position and held bits', () => {
    const previous = base({ m: [1, 1], p: [10, 10], b: BIT_ALIVE | BIT_PRESENT | BIT_USE_PRESSED });
    const next = base({ m: [2, 2], p: [20, 20], b: BIT_ALIVE | BIT_PRESENT });
    const merged = mergeCommand(previous, next);
    expect(merged.m).toEqual([2, 2]);
    expect(merged.p).toEqual([20, 20]);
    // The player let go between the two samples; the trigger must not stay down.
    expect(merged.b & BIT_USE_PRESSED).toBe(0);
  });

  it('accumulates edges that happened in different messages', () => {
    const previous = base({ b: BIT_ALIVE | BIT_PRESENT | BIT_USE_JUST_PRESSED });
    const next = base({ b: BIT_ALIVE | BIT_PRESENT | BIT_NEXT_EQUIPMENT });
    const merged = mergeCommand(previous, next);
    expect(merged.b & BIT_USE_JUST_PRESSED).toBe(BIT_USE_JUST_PRESSED);
    expect(merged.b & BIT_NEXT_EQUIPMENT).toBe(BIT_NEXT_EQUIPMENT);
  });

  it('keeps every event in arrival order', () => {
    const previous = base({ e: [shot(0), { k: EVENT_MELEE, d: 5 }] });
    const next = base({ e: [shot(1)] });
    expect(mergeCommand(previous, next).e).toEqual([shot(0), { k: EVENT_MELEE, d: 5 }, shot(1)]);
  });

  it('bounds the events one frame can carry however long the burst', () => {
    let merged: PlayerCommand | null = null;
    for (let message = 0; message < 20; message += 1) {
      merged = mergeCommand(merged, base({ e: [shot(0), shot(1)] }));
    }
    expect(merged?.e?.length).toBe(MAX_MERGED_EVENTS);
  });

  it('does not resurrect edges the pump already cleared', () => {
    // What `latest[slot]` looks like after pumpFrame: held bits, no events.
    const pumped = base({ b: BIT_ALIVE | BIT_PRESENT | BIT_USE_PRESSED });
    const next = base({ b: BIT_ALIVE | BIT_PRESENT });
    expect(mergeCommand(pumped, next)).toEqual(next);
  });

  it('keeps the shots a caught-up client fired across the whole burst', () => {
    // The regression this exists for: GameplayArena sends one command per frame it
    // consumes, so catching up after a hitch delivers several at once.
    const burst = [
      base({ m: [1, 0], e: [shot(0)], b: BIT_ALIVE | BIT_PRESENT | BIT_USE_JUST_PRESSED }),
      base({ m: [2, 0], e: [shot(0)] }),
      base({ m: [3, 0], e: [shot(1)], b: BIT_ALIVE | BIT_PRESENT | BIT_CONFIRM }),
    ];
    const merged = burst.reduce<PlayerCommand | null>(
      (accumulated, command) => mergeCommand(accumulated, command),
      null,
    );
    expect(merged).not.toBeNull();
    expect(merged!.e).toEqual([shot(0), shot(0), shot(1)]);
    expect(merged!.m).toEqual([3, 0]);
    expect(merged!.b & BIT_USE_JUST_PRESSED).toBe(BIT_USE_JUST_PRESSED);
    expect(merged!.b & BIT_CONFIRM).toBe(BIT_CONFIRM);
  });
});
