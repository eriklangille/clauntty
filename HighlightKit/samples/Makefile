# Build the grammars once; both apps link them
KIT := build/highlightkit
SOURCES = $(wildcard HighlightKit/*.json)

.PHONY: all clean

all: $(KIT)/HighlightKit.xcframework

$(KIT)/HighlightKit.xcframework: $(SOURCES)
	python3 scripts/build-highlightkit.py
	@echo "built $@"

clean:
	rm -rf $(KIT)
