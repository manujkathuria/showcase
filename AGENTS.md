# Agent guide — version 4

## Project

Build a real Go streaming engine and showcase its engineering process. Read [docs/project-brief.md](docs/project-brief.md) for established purpose, decisions, and open questions when planning or changing project behavior. Zerodha provides the first live input. Architecture decisions are developed with the user; discussion does not authorize application implementation.

## Working principles

- Correct delivery is required. Optimize performance within that requirement and support performance claims with measurements.
- Inspect relevant code and conventions before changing them. Keep work scoped, simple, and idiomatic.
- Resolve routine choices independently. Raise ambiguity that changes intended behavior, correctness guarantees, or public contracts, with a recommendation.
- Define acceptance criteria for implementation tasks and verify meaningful behavior. Report what was checked and any remaining limitations.
- Preserve user changes. Distinguish proposals from confirmed decisions and planned work from completed work.

## Incremental skills

Add focused guidance as recurring engineering decisions arise during the work, rather than creating a complete rulebook in advance.

When a skill is introduced, record its path and concrete task triggers here. Infer relevant triggers from the work and read matching skills before making the corresponding decisions; the user should not need to name them. Load only relevant guidance and reuse it while it remains available and unchanged.

| Task triggers | Required skill |
| --- | --- |
| Starting a project; defining substantial new capability scope; discussing requirements, constraints, architecture, or the first delivery slice | [project-framing](.agents/skills/project-framing/SKILL.md) |
| Creating or changing Go event structs, arrays, slices, buffers, batches, binary codecs, channel payloads, or allocation-sensitive loops | [go-data-ownership](.agents/skills/go-data-ownership/SKILL.md) |
| Defining or modifying repeatedly stored Go structs, including event/depth records and batch elements; investigating struct footprint | [go-struct-alignment](.agents/skills/go-struct-alignment/SKILL.md) |
| Choosing value/pointer semantics, storage lifetimes, buffer reuse, or changing/diagnosing allocation-sensitive code | [go-stack-vs-heap](.agents/skills/go-stack-vs-heap/SKILL.md) |
| Implementing or changing Go network/file I/O loops, database bulk writers, batch sizes, or investigating syscall/scheduling overhead | [go-io-batching](.agents/skills/go-io-batching/SKILL.md) |

For known bounded data, use concrete types, fixed-capacity storage, and explicit ownership/reuse. Keep memory bounded and avoid unnecessary per-event allocations; verify allocation claims rather than assuming stack placement. Triggers are cumulative; load each relevant skill before its decisions.

Routine fixes and already-scoped coding tasks do not require project framing. Reuse established decisions rather than restarting discovery.
