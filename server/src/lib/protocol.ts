/**
 * Wire protocol. Mirrored verbatim by the Godot client in
 * `res://scripts/net/lobby_protocol.gd`. Two copies, diffed against each other
 * in both directions: `server/test/protocol.test.ts` reads the GDScript file,
 * and `tools/validation/validate_online_frame_sync.gd` reads this one.
 *
 * The handshake rejects a version mismatch instead of tolerating it: turning a
 * silent cross-repo drift into one loud failure at connect time, with both
 * version numbers in the close reason, is worth more than any compatibility
 * shim. See close code 4001 below.
 */
export const PROTOCOL_VERSION = 6;

/**
 * Length ceiling for a cross-wire content identifier (character id, map id).
 * The Godot client holds the same number; the two are diffed in both
 * directions by `server/test/protocol.test.ts` and
 * `tools/validation/validate_online_frame_sync.gd`.
 */
export const CONTENT_ID_MAX_LENGTH = 32;

/** Lobby and control messages. */
export const OPCODE_LOBBY_MIN = 0x00;
export const OPCODE_LOBBY_MAX = 0x7f;

/** Reserved wholesale for the sync layer. */
export const OPCODE_SYNC_MIN = 0x80;
export const OPCODE_SYNC_MAX = 0xff;

export function isLobbyOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_LOBBY_MIN && opcode <= OPCODE_LOBBY_MAX;
}

export function isSyncOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_SYNC_MIN && opcode <= OPCODE_SYNC_MAX;
}

/** WebSocket close codes. 4000-4999 is the application-defined range. */
export const CLOSE_PROTOCOL_MISMATCH = 4001;
export const CLOSE_ROOM_FULL = 4002;
export const CLOSE_BAD_MESSAGE = 4003;
export const CLOSE_KICKED = 4004;
export const CLOSE_ROOM_CLOSED = 4005;
export const CLOSE_RECONNECTED_ELSEWHERE = 4006;
/**
 * The rejoining client is further behind than the frame history reaches, so
 * there is no way to walk its simulation up to the live tick. Rejecting is the
 * point: letting it in would seat a player whose world silently diverged from
 * everyone else's for the rest of the match.
 */
export const CLOSE_CANNOT_RESUME = 4007;

/**
 * Simulation tick rate. MUST equal 1 / SimClock.TICK_SECONDS on the client.
 * The server owns the tick counter during a match and paces frames at this
 * rate; clients never advance a tick the server has not sent.
 */
export const TICK_HZ = 20;
export const TICK_MS = 1000 / TICK_HZ;

/**
 * How far back the room can replay for a rejoining client: 30 seconds, which
 * covers the reconnects that actually happen (backgrounded app, WiFi handing
 * over to mobile data) without holding a whole match in memory. Past this the
 * rejoin is refused rather than served a partial replay.
 *
 * Spelled as a literal (TICK_HZ * 30) because the client's drift check reads
 * these declarations as source text and cannot evaluate an expression.
 */
export const FRAME_HISTORY_LIMIT = 600;

/** Frames per backfill message. Keeps any single message well clear of 1 MB. */
export const BACKFILL_CHUNK_FRAMES = 200;

/**
 * Fixed-point scale for every float that crosses the wire and then enters the
 * simulation. It is deliberately the same 1000 as SimWorld.POSITION_QUANTIZATION:
 * the simulation already rounds player positions to millimetres, so sending the
 * pre-rounded integer means the value the sim consumes is bit-identical on every
 * client without any client having to trust its own float formatting.
 */
export const QUANT = 1000;

export function quantize(value: number): number {
  return Math.round(value * QUANT);
}

export function dequantize(value: number): number {
  return value / QUANT;
}

/** Input bit flags packed into `PlayerCommand.b`. */
export const BIT_USE_PRESSED = 1 << 0;
export const BIT_USE_JUST_PRESSED = 1 << 1;
export const BIT_PREV_EQUIPMENT = 1 << 2;
export const BIT_NEXT_EQUIPMENT = 1 << 3;
export const BIT_CONFIRM = 1 << 4;
export const BIT_ALIVE = 1 << 5;
export const BIT_PRESENT = 1 << 6;

/**
 * Held or continuous state. These survive a pump and keep repeating while a
 * player's packets are late -- a held trigger that stops repeating would read
 * as the player letting go.
 */
export const STICKY_BITS = BIT_USE_PRESSED | BIT_ALIVE | BIT_PRESENT;

/**
 * Edges. These fire exactly once and are cleared by the pump. Mirrors
 * `ONE_SHOT_BITS` in the client's `lobby_protocol.gd`; the two must agree or a
 * repeated edge turns one weapon swap into a swap every tick.
 */
export const EDGE_BITS =
  BIT_USE_JUST_PRESSED | BIT_PREV_EQUIPMENT | BIT_NEXT_EQUIPMENT | BIT_CONFIRM;

/** Simulation request kinds raised by a player during one tick. */
export const EVENT_SHOT = 0;
export const EVENT_MELEE = 1;
export const EVENT_SPREAD_RESET = 2;
export const EVENT_SHOP_PURCHASE = 3;
export const EVENT_PLACE_ITEM = 4;

export interface SimEvent {
  /** EVENT_* discriminant. */
  k: number;
  /** Weapon profile index (shot / spread_reset). */
  w?: number;
  /** Quantized origin [x, z] and its height. */
  o?: [number, number];
  oy?: number;
  /** Quantized aim direction [x, z]. */
  a?: [number, number];
  /** Quantized melee damage / reach / half width. */
  d?: number;
  r?: number;
  hw?: number;
  /** Shop purchase: offer_type (0=weapon/1=passive/2=ammo). */
  t?: number;
  /** Shop purchase: price. */
  p?: number;
  /** Shop purchase: offer index into the deterministic per-wave shop list. */
  si?: number;
  /** Place item: index of the placeable in the placer's equipment loadout. */
  pi?: number;
  /** Place item: target grid cell. Already integral, so nothing to quantize. */
  ci?: number;
  cj?: number;
}

/**
 * One player's contribution to one tick. Every field is already quantized, so
 * the server never does arithmetic on gameplay values -- it only relays them.
 */
export interface PlayerCommand {
  /** Quantized move vector [x, y]. */
  m: [number, number];
  /** Packed BIT_* flags. */
  b: number;
  /** Quantized world position [x, z]. Feeds SimWorld.set_player_snapshot. */
  p: [number, number];
  /** Simulation requests raised this tick. Omitted when empty. */
  e?: SimEvent[];
  /** Optional frame hash sample for desync detection. */
  h?: string;
  /** Set when this player asked for a new wave on this tick. */
  w?: boolean;
}

export const EMPTY_COMMAND: PlayerCommand = { m: [0, 0], b: 0, p: [0, 0] };

/** A frame is what every client steps its simulation on. Same bytes, everyone. */
export interface Frame {
  type: 'f';
  /** Tick index this frame advances the simulation to. Monotonic from 0. */
  t: number;
  /** Index is the slot. `null` means the seat is empty or has never reported. */
  s: Array<PlayerCommand | null>;
  /** True when a new wave must be queued on this exact tick. */
  w?: boolean;
}

export type RoomState = 'lobby' | 'playing' | 'ended';

export interface RosterEntry {
  slot: number;
  player_id: string;
  nickname: string;
  ready: boolean;
  connected: boolean;
  /** Opaque to the server; resolved against the client's own catalog. */
  character_id: string;
}

/**
 * A single message cannot legitimately raise more requests than this; the cap
 * is what stops one client from making every other client's tick expensive.
 */
export const MAX_EVENTS_PER_MESSAGE = 8;

/**
 * Ceiling on events carried by one *frame* after merging a burst. A client that
 * stalled and then caught up legitimately sends several messages between two
 * pumps, so the per-message cap alone would no longer bound the work a frame
 * costs everyone else.
 */
export const MAX_MERGED_EVENTS = 24;

/**
 * Folds a newly arrived command into the one still waiting to be pumped.
 *
 * The room pumps at a fixed rate but packets do not arrive at one: a client
 * that stalled and caught up sends one command per frame it consumed, all of
 * which land in the same pump window. Overwriting would silently drop every one
 * but the last -- and with it the shots they carried. That loss is identical on
 * every client, so no hash ever disagrees; it just reads as the game eating
 * your trigger pulls after a hitch.
 *
 * Held state takes the newest value (that is what "held" means), edges
 * accumulate (they each happened), and events concatenate in arrival order.
 */
export function mergeCommand(previous: PlayerCommand | null, next: PlayerCommand): PlayerCommand {
  if (previous === null) return next;
  const merged: PlayerCommand = {
    m: next.m,
    p: next.p,
    b: (next.b & STICKY_BITS) | ((previous.b | next.b) & EDGE_BITS),
  };
  const events = [...(previous.e ?? []), ...(next.e ?? [])];
  if (events.length > 0) merged.e = events.slice(0, MAX_MERGED_EVENTS);
  // Hash and wave are per-message concerns the room has already acted on by the
  // time this runs; carrying the newest keeps the relayed command faithful.
  if (next.h !== undefined) merged.h = next.h;
  if (previous.w === true || next.w === true) merged.w = true;
  return merged;
}

/**
 * Validates a command shape before it is relayed. A malformed command is
 * dropped rather than repaired: a repaired command is a command that differs
 * between the sender's simulation and everyone else's, which is a desync with
 * extra steps.
 */
export function parseCommand(raw: unknown): PlayerCommand | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const value = raw as Record<string, unknown>;
  const move = value['m'];
  const position = value['p'];
  if (!isIntPair(move) || !isIntPair(position)) return null;
  const bits = value['b'];
  if (typeof bits !== 'number' || !Number.isInteger(bits) || bits < 0 || bits > 0xff) return null;

  const command: PlayerCommand = { m: move, b: bits, p: position };
  const events = value['e'];
  if (Array.isArray(events)) {
    const parsed: SimEvent[] = [];
    for (const entry of events.slice(0, MAX_EVENTS_PER_MESSAGE)) {
      const event = parseEvent(entry);
      if (event !== null) parsed.push(event);
    }
    if (parsed.length > 0) command.e = parsed;
  }
  const hash = value['h'];
  if (typeof hash === 'string' && hash.length <= 32) command.h = hash;
  if (value['w'] === true) command.w = true;
  return command;
}

function parseEvent(raw: unknown): SimEvent | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const value = raw as Record<string, unknown>;
  const kind = value['k'];
  if (
    kind !== EVENT_SHOT &&
    kind !== EVENT_MELEE &&
    kind !== EVENT_SPREAD_RESET &&
    kind !== EVENT_SHOP_PURCHASE &&
    kind !== EVENT_PLACE_ITEM
  ) {
    return null;
  }
  const event: SimEvent = { k: kind };
  for (const key of ['w', 'oy', 'd', 'r', 'hw', 't', 'p', 'si', 'pi', 'ci', 'cj'] as const) {
    const entry = value[key];
    if (typeof entry === 'number' && Number.isInteger(entry)) event[key] = entry;
  }
  for (const key of ['o', 'a'] as const) {
    const entry = value[key];
    if (isIntPair(entry)) event[key] = entry;
  }
  return event;
}

function isIntPair(value: unknown): value is [number, number] {
  return (
    Array.isArray(value) &&
    value.length === 2 &&
    typeof value[0] === 'number' &&
    typeof value[1] === 'number' &&
    Number.isInteger(value[0]) &&
    Number.isInteger(value[1])
  );
}
