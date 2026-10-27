// Collapsed files, the way GitHub does it
const LOCKFILES = new Set(["package-lock.json", "yarn.lock"]);

export async function load(path, { limit = 512 * 1024 } = {}) {
  if (LOCKFILES.has(path)) return null;
  const res = await fetch(`/files/${encodeURIComponent(path)}`);
  const text = await res.text();
  return text.length > limit ? null : text.split("\n");
}

class Cache extends Map {
  get size() { return super.size; }
}
