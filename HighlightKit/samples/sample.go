package review

import (
	"fmt"
	"strings"
)

// Hunk is one @@ section of a diff
type Hunk struct {
	OldStart, NewStart int
	Lines              []string
}

func (h *Hunk) Contains(line int) bool {
	return line >= h.NewStart && line < h.NewStart+len(h.Lines)
}

func main() {
	h := &Hunk{NewStart: 12, Lines: strings.Split("a\nb", "\n")}
	fmt.Printf("%v %d\n", h.Contains(13), 0x1F)
}
