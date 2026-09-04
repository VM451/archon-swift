# ArchonSearch

`ArchonSearch` owns discovery, crawling, extraction, research orchestration,
deduplication, citations, and monitoring. `SearchProvider` is the stable
boundary for local corpus and explicit network adapters.

## Sources and policy

Discovery sources include DuckDuckGo, Wikipedia, local workspaces, and public
social-platform queries. A local-only request must name a local workspace and
cannot request a live crawl. Network responses disclose `usedNetwork`.

## Research behavior

Research can bound page count, crawl depth, latency, and extraction output. The
search path keeps source URLs, scraped content, citations, and a research-node
path so callers can inspect evidence rather than receiving an untraceable
answer. Structured extraction requires a host-supplied generation boundary when
the local semantic core cannot fulfill it.
