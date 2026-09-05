# ArchonSearch

`ArchonSearch` owns discovery, crawling, extraction, research orchestration,
deduplication, citations, and monitoring. `SearchProvider` is the stable
boundary for local corpus and explicit network adapters.

`LocalSearchIndex` is an actor-isolated, file-backed offline corpus with
deterministic term ranking, bounded results, atomic persistence, and a
`SearchProvider` adapter. Cloud providers remain explicit network-dependent
adapters and must disclose their capabilities.

## Sources and policy

Discovery sources include DuckDuckGo, Wikipedia, local workspaces, and public
social-platform queries. A local-only request must name a local workspace and
cannot request a live crawl. Local workspace enumeration is bounded and
cooperatively cancellable. Network responses disclose `usedNetwork`.

## Research behavior

Research can bound page count, crawl depth, latency, and extraction output. The
search path keeps source URLs, scraped content, citations, and a research-node
path so callers can inspect evidence rather than receiving an untraceable
answer. Structured extraction requires a host-supplied generation boundary when
the local semantic core cannot fulfill it.
