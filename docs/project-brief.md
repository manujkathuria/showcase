# Project brief

Status: Purpose established; scope, detailed requirements, architecture, and delivery plan are under discussion. This document records project decisions, not completed implementation.

## 1. Purpose

Build a real, usable Go streaming engine that ingests live data, processes events, and delivers results with durable acceptance and replay. Showcase both the working system and the engineering process used to build it.

Zerodha is the first real input source. The engine should have clear boundaries for feeds, processing, and sinks so its core behavior is reusable beyond market data.

The project demonstrates senior Go backend engineering through explicit guarantees, defensible design decisions, verified failure recovery, and measured performance. Correct delivery is required; performance is optimized within that requirement.

The engineering process is also part of the showcase: project documentation, architecture decisions, `AGENTS.md`, and focused skills show how implementation is delegated, reviewed, and verified. Guidance evolves from actual work rather than a comprehensive rulebook created in advance.

The initial operator is the project author. Hiring managers and engineers are an additional audience for the system and its engineering evidence. The useful output of the first version remains to be defined.

## 2. Scope

The first usable version and explicit deferred work have not yet been agreed.

Complete market coverage is not required merely to demonstrate ingestion. The subscription universe and whether order management belongs in the first version remain open.

## 3. Requirements

Established direction:

- Accepted events must survive crashes and support replay.
- Delivery correctness takes priority over optimization.
- Performance claims must be supported by measurements.

To define before implementation:

- Durable acceptance boundary and supported failure model: process crash, machine loss, or both.
- Delivery semantics, ordering scope, duplicate handling, and consumer progress.
- Retention, replay behavior, and handling of source disconnects.
- Resource limits, overload behavior, and shutdown behavior.
- Representative workload, performance objectives, and acceptance criteria.

## 4. Constraints and technology direction

- Core implementation language: Go.
- First live source: Zerodha WebSocket.
- Communication between separate services: gRPC.
- Cloud deployment direction: Google Cloud; specific services and topology are undecided.
- Local PostgreSQL with TimescaleDB is established for subscription configuration in database `intraday_streaming`, schema `feed`; see [local-database.md](local-database.md). This replaces the earlier SQLite proposal. Table design, other storage responsibilities, and Redis usage remain to be agreed.
- Budget, timeline, and operational limits are not yet defined.

Source limits must be verified when choosing subscriptions and connection assignments.

## 5. Architecture

Conceptual flow: feed → processing → sinks, with durability and replay satisfying the eventual delivery contract.

Feed, processor, and sink will be separate services communicating over gRPC. The feed receives raw messages; the processor handles market parsing. Independent subscribers and consumer scaling are desired capabilities. Persistence implementation, partitioning, and scaling mechanisms remain open.

Choose components from the agreed requirements. A microservices architecture is not itself a success criterion.

## 6. Delivery plan

Next: define the useful output and scope of the first version, then resolve the requirements that determine its architecture.

The first infrastructure task is [feed configuration tables](tasks/001-feed-configuration.md), assigned for Antigravity implementation: instrument catalogue and enabled full-mode subscriptions in the existing local database. Live ticks and depth storage are planned later sink responsibilities; their schema is not yet agreed.

The first implementation slice should run end to end and have observable acceptance criteria and appropriate verification. No application implementation is authorized by this brief alone.
