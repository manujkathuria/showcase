---
name: project-framing
description: Establish purpose, scope, requirements, constraints, architecture, and a first delivery slice when starting a project or discussing a substantial new capability. Use before implementation planning; do not activate for routine fixes or already-scoped coding tasks.
---

# Project framing

Help the user make technical and delivery decisions before assigning implementation. Produce an actionable project brief, not a predetermined architecture or a Scrum ceremony.

## Discussion workflow

Start from available conversation and repository context. State what is already established; ask only for missing information that materially affects the next decision. Discuss in manageable steps rather than presenting a six-part questionnaire. Refine earlier conclusions when later constraints reveal a conflict.

1. **Purpose:** Identify what is being built, its users or audience, and the outcome that matters. For a showcase, distinguish the engineering capabilities to demonstrate from the example business domain.
2. **Scope:** Define the smallest useful first version and explicit deferred work. Separate requirements from possible extensions.
3. **Requirements:** Describe observable behavior and acceptance criteria, including relevant failure cases. For streaming work, resolve acceptance, delivery, ordering, replay, overload, and recovery guarantees where they affect the design. Make performance objectives measurable; do not invent targets.
4. **Constraints:** Identify source limitations, deployment environment, cost, time, operational capacity, and existing technology choices. Mark unknowns and assumptions. Verify external facts when a design depends on them.
5. **Architecture:** Choose responsibilities, boundaries, data flow, state ownership, and failure handling from the requirements. Explain consequential tradeoffs and recommend an option. Do not equate senior engineering with microservices or add components merely to showcase technologies.
6. **Delivery plan:** Propose a small end-to-end implementation slice with observable acceptance criteria and appropriate verification. Identify dependencies and unresolved blockers; defer task decomposition that depends on unmade decisions.

## Decision discipline

- Clearly distinguish confirmed decisions, recommendations, assumptions, and open questions. Do not treat silence as agreement on a consequential choice.
- Resolve routine details autonomously. Bring choices that change scope, externally visible behavior, guarantees, or major architecture to the user with a recommendation and its implications.
- Preserve earlier decisions unless new evidence warrants revisiting them. Extend an existing brief rather than restarting discovery.
- Match depth to the task. An already-scoped capability may need only a focused update to requirements and architecture.
- Discussion and planning do not authorize application implementation, deployment, or live external side effects.

## Output and completion

Keep a concise brief in the conversation covering the six areas. Save or update a repository document when requested or when documentation is part of the task; use the existing location if available.

The brief is ready for implementation planning when the first slice has a clear purpose, scope, behavioral contract, feasible architecture, and verification criteria. Unknowns may remain for later slices; do not call a blocking requirement resolved without evidence or user input.

For an implementation handoff, include the slice objective, relevant decisions and contracts, scope exclusions, acceptance criteria, and verification expectations. Mark proposed work as proposed until implementation is requested.
