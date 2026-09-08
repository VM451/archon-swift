# ArchonContext — how it works

`ArchonContext` is an ephemeral, request-scoped assembler. It orders
contributor fragments deterministically and enforces budgets. It does not
persist, retrieve, or mutate memory.

```mermaid
flowchart TD
    C1[Contributor: memory facts] --> ASM[Assembler]
    C2[Contributor: search results] --> ASM
    C3[Contributor: tools / host actions] --> ASM
    ASM --> Cancel1{Cancellation check}
    Cancel1 -->|Cancelled| Stop[Throw CancellationError]
    Cancel1 -->|Alive| Order[Order by priority + stable identity]
    Order --> Budget{Fragment-count / UTF-8 byte budget}
    Budget -->|Over| Trunc[Truncate final fragment on char boundary]
    Budget -->|Within| Out[Assembled request context]
    Trunc --> Out
    Out --> Agent[Hand to agent graph — then discarded]
```

Durable facts and filtering stay in `ArchonMemory`. Model-specific token
budgets remain consuming-app concerns.
