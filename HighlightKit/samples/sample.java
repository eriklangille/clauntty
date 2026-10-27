package review;

import java.util.List;

/** A hunk of a diff */
public final class Hunk {
    private static final int CONTEXT = 3;
    private final int newStart;
    private final List<String> lines;

    public Hunk(int newStart, List<String> lines) {
        this.newStart = newStart;
        this.lines = lines;
    }

    @Override
    public String toString() {
        return String.format("@@ +%d,%d @@", newStart, lines.size()); // header
    }
}
