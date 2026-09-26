/** The in-memory store behind the API. There is no database, so a restart is a clean slate. */
export interface Note {
  readonly id: number;
  readonly text: string;
  readonly createdAt: string;
}

export class NoteStore {
  readonly #notes: Note[] = [];
  #nextId = 1;

  add(text: string, now: Date = new Date()): Note {
    const note: Note = { id: this.#nextId, text, createdAt: now.toISOString() };
    this.#nextId += 1;
    this.#notes.push(note);
    return note;
  }

  /** Oldest first, which is the order clients render. */
  list(): readonly Note[] {
    return this.#notes;
  }

  find(id: number): Note | undefined {
    return this.#notes.find(note => note.id === id);
  }

  remove(id: number): boolean {
    const index = this.#notes.findIndex(note => note.id === id);
    if (index === -1) return false;
    this.#notes.splice(index, 1);
    return true;
  }
}
