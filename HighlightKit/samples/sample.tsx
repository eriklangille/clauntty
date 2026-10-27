import { useState } from "react";

type Props = { title: string; count?: number };

export function Badge({ title, count = 0 }: Props) {
  const [open, setOpen] = useState(false);
  return (
    <button className="badge" onClick={() => setOpen(!open)} disabled={count > 9}>
      {title} <span>{count}</span>
    </button>
  );
}
