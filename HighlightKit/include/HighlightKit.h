// HighlightKit: tree-sitter with the grammars Clauntty highlights code with, each with
// its highlight query (nvim-treesitter's, inherited files resolved). Built by
// scripts/build-highlightkit.py from the pins in HighlightKit/grammars.json.

#ifndef HIGHLIGHTKIT_H
#define HIGHLIGHTKIT_H

#include "tree_sitter/api.h"

typedef struct {
    /// nvim-treesitter's name for it: "swift", "c_sharp", "markdown_inline"
    const char *name;
    const TSLanguage *(*language)(void);
    /// highlights.scm, written for Neovim: a later pattern wins over an earlier one
    const char *highlights;
    /// injections.scm (code inside a Markdown fence, <script> in HTML), or ""
    const char *injections;
    /// File extensions it's for, without dots, space separated ("" for an injection-only one)
    const char *extensions;
    /// Whole file names it's for ("Makefile"), space separated
    const char *filenames;
} HKGrammar;

extern const unsigned hk_grammar_count;

/// The grammar at `index` (below hk_grammar_count)
const HKGrammar *hk_grammar(unsigned index);

#endif
