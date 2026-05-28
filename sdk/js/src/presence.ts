export interface PresenceMeta {
  online_at: number;
  room?: string;
  role?: string;
  [key: string]: unknown;
}

export interface PresenceEntry {
  metas: PresenceMeta[];
}

export type PresenceMap = Record<string, PresenceEntry>;

export type PresenceHandler = (
  joins: PresenceMap,
  leaves: PresenceMap,
  current: PresenceMap
) => void;

export class Presence {
  private state: PresenceMap = {};
  private handlers: PresenceHandler[] = [];

  syncState(newState: PresenceMap): void {
    const joins: PresenceMap = {};
    const leaves: PresenceMap = {};

    for (const key of Object.keys(newState)) {
      if (!this.state[key]) {
        joins[key] = newState[key];
      }
    }

    for (const key of Object.keys(this.state)) {
      if (!newState[key]) {
        leaves[key] = this.state[key];
      }
    }

    this.state = { ...newState };
    this.notify(joins, leaves);
  }

  syncDiff(diff: { joins: PresenceMap; leaves: PresenceMap }): void {
    const joins = diff.joins || {};
    const leaves = diff.leaves || {};

    for (const [key, entry] of Object.entries(joins)) {
      this.state[key] = entry;
    }

    for (const key of Object.keys(leaves)) {
      delete this.state[key];
    }

    this.notify(joins, leaves);
  }

  list(): Array<{ id: string } & PresenceEntry> {
    return Object.entries(this.state).map(([id, entry]) => ({ id, ...entry }));
  }

  get(id: string): PresenceEntry | undefined {
    return this.state[id];
  }

  onChange(handler: PresenceHandler): () => void {
    this.handlers.push(handler);
    return () => {
      this.handlers = this.handlers.filter((h) => h !== handler);
    };
  }

  private notify(joins: PresenceMap, leaves: PresenceMap): void {
    for (const h of this.handlers) {
      h(joins, leaves, this.state);
    }
  }
}
