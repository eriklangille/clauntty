import { readFileSync } from "fs";

type Priority = "critical" | "review" | "skim";

interface Note {
  path: string;
  priority?: Priority;
}

/** The first line with `text` in it */
export function lineOf(lines: string[], text: string): number | undefined {
  const index = lines.findIndex((l) => l.includes(text.trim()));
  return index < 0 ? undefined : index + 1; // 1-based
}

const notes: Note[] = JSON.parse(readFileSync(`/tmp/${"notes"}.json`, "utf8"));
console.log(notes.length, 0x1f, /^\d+$/.test("42"));
