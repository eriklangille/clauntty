# Code review in Clauntty

Claude hands over a change as a **review**: the hunks ordered by how much they
need a careful read, and a few comments pinned to the lines that matter.

## Notes

- `priority`: `critical` | `review` | `skim` | `mechanical`
- Comments anchor with [match](https://example.com/docs#match) text.

```swift
let review = Review(bundle: bundle, sessionId: id, host: host)
```

> Native is only worth it if 1 and 2 come out yes.
