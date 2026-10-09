# Agent guide — version 1

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

Routine fixes and already-scoped coding tasks do not require project framing. Reuse established decisions rather than restarting discovery.
