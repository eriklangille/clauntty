from dataclasses import dataclass
import re

PRIORITIES = ("critical", "review", "skim", "mechanical")


@dataclass
class Note:
    path: str
    priority: str = "skim"

    def rank(self) -> int:
        """Lower is more important"""
        return PRIORITIES.index(self.priority)


def line_of(lines: list[str], text: str) -> int | None:
    # 1-based, like git
    for i, line in enumerate(lines, start=1):
        if re.search(rf"\b{re.escape(text)}\b", line):
            return i
    return None

print(f"{len(PRIORITIES)} priorities, {0.5:.1%}")
