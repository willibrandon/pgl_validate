# pgl_validate — Cross-Node Data Validation for pglogical (and Logical Replication)

## Complete Technical Design Document

**Status:** Implementation-tracking (v4 — supersedes v1/v2/v3; current code and CI are expected to match this document. v4 makes barrier convergence edge-specific and exact, fixes the `row_digest` signature, gates approximate filters, and adds a validation-strength matrix.)
**Component:** `pgl_validate` — a standalone PostgreSQL extension (Rust / [pgrx](https://github.com/pgcentralfoundation/pgrx))
**Targets:** PostgreSQL 15, 16, 17, 18
**Primary use case:** pglogical bidirectional (multi-master) replication. Native logical replication and physical standbys are designed as explicit secondary modes.

> ### What changed in v4 (third review response)
> 1. **Barrier convergence is exact and edge-specific.** v3 waited for `origin_progress ≥ pg_current_wal_lsn()` captured *after* the barrier — an over-estimate under concurrent WAL that origin progress may never hit. v4 captures the barrier's **exact** end LSN `L_b` (`last_commit_lsn()` = `XactLastCommitEnd`) and makes `pg_replication_origin_progress(origin(O→T)) ≥ L_b` the **authoritative** convergence condition; barrier-token visibility is a corroborating liveness check only (token-alone is unsound in `forward_origins = {all}` cascades). `wait_slot_confirm_lsn(slot, L_b)` is called with the explicit `L_b` (§8.1).
> 2. **The pglogical filtered-table truth table is corrected and is now sound.** Filtered `UPDATE`s are sent as `UPDATE`s; if the target row is absent, apply *skips* it ("can't do INSERT here", `pglogical_apply_heap.c:750`; demonstrated by id=6 in `row_filter.sql:156`/`row_filter.out`). So `P_F ⊆ S` is **false** for pglogical. v4 validates only the sound **filtered-intersection** property for pglogical-filtered tables (§9.4).
> 3. **`best_effort` fences are an explicit, opt-in *degraded* mode that can never yield an exact `match`/`differ`** — they produce a `degraded` verdict; the default is to **abort** when no barrier can be injected (§8.1, §16, §19).
> 4. **The barrier table is standalone, FK-free, and cascade-safe.** It carries a token with **no unique constraint** — under `forward_origins='{all}'` the same token can arrive twice at a target, and a unique key would cause an `insert_insert` conflict that `conflict_resolution = error` turns into an apply stall. It is a normal logged table (pglogical forbids UNLOGGED/TEMP in repsets); run/edge bookkeeping lives in a separate *non-replicated* coordinator table (§16, Appendix A).
> 5. **`track_commit_timestamp` is consistently optional/advisory** (the §5 run-phase text is fixed to match §11.3).
> 6. **Session-sensitive row filters are no longer overclaimed.** Only *immutable, context-free* filters are validated exactly (deparse). Stable-session-sensitive and volatile filters are `unsupported`/`approximate` on a **separate diagnostic path that is not G-SOUND** (§9.5).
> 7. **Repair is tightened**: origin set **before** `BEGIN` and reset **after** `COMMIT` (mirroring `pglogical_sync.c:421/465`); `local_only` repair refuses downstream `forward_origins = {all}` subscriptions because pausing apply workers does not discard retained slot WAL; in-transaction target verification vs post-commit cross-node revalidation are distinguished; `setval` is called out as non-transactional (§18).
> 8. **`row_digest` is `STABLE`, not `IMMUTABLE`** (text fallback depends on pinned session GUCs); canonicalization decisions are pushed by the coordinator as explicit directives so they are uniform across mixed-version nodes (§10.4, §15.1).
> 9. **Verdict states extended** to `indeterminate | partial | approximate | degraded` (§16).
> 10. **Edge identity normalized** (provider/target node, subscription, slot, origin name, repsets, backend), `paranoid_confirm` given a spill bound, and `on_fence_timeout` default changed to `abort_run` (§16, §19).
>
> ### What changed in v3 (second review response)
> The v3 corrections, each traceable to a verified source fact:
> 1. **The consistency proof no longer uses per-tuple LSN.** `pglogical.xact_commit_timestamp_origin(xid)` returns only `(timestamp, roident)` — no commit LSN (`pglogical_functions.c:2370`). v2's "is this tuple older than the edge fence?" test was therefore unimplementable. Replaced by **digest stability across a barrier-converged epoch** (§8), which uses only reliable per-edge convergence and re-readable row digests — both of which exist. A full soundness proof is given.
> 2. **Convergence uses a real per-edge barrier + `wait_slot_confirm_lsn`, not an arbitrary `pg_current_wal_lsn()`.** Origin progress only advances on *applied replicated commits*, so an arbitrary WAL position may never be reached (§8.1). pglogical's `wait_slot_confirm_lsn()` (`pglogical_monitoring.c:31`) is used as documented.
> 3. **`table_data_filtered()` applies the row filter only — no column projection** (`pglogical_functions.c:2086`); column projection comes from `att_list` (§9). Corrected.
> 4. **Row filters run in the replication session** (`README.md:656`): `CURRENT_USER`/volatile expressions are not reproducible in a validator session. v3 detects volatile/session-sensitive filters and either runs `table_data_filtered()` under the apply role or flags the table (§9.4).
> 5. **A complete action-mask × row-filter truth table** grounded in the verified output-plugin behavior — row filter is evaluated on the *new* tuple and the change is *dropped* (not turned into a DELETE) on failure (`pglogical_output_plugin.c:646`) — replaces the hand-wavy weakened-property list (§9.4).
> 6. **Repair is fully specified** against the real `forward_origins ∈ {{}, {all}}` semantics (`README.md:311`): origin creation, loop prevention, local-only vs replicated modes, conflict behavior, locking, FK ordering, privilege, revalidation (§18). `session_replication_role` remains rejected.
> 7. **Collision bounds corrected**: a 256-bit hash gives ≈ 2⁻¹²⁸ generic collision resistance (birthday), not 2⁻²⁵⁶ (§10.2).
> 8. **The set-confirm primitive is real SQL**: `array_agg(rd ORDER BY rd)` into `hash_digest_array(bytea[])` — not a mis-declared scalar used as an aggregate (§10.2, §15).
> 9. **Generated SQL uses `VARIADIC "any"` correctly**: heterogeneous columns are passed as ordinary variadic arguments `row_digest(t.a, t.b, …)`, never a homogeneous `ARRAY[...]` (§12).
> 10. **Physical standby uses the same digest-stability confirm** (replay-LSN convergence), closing the "different logical times" gap (§13.3).
> 11. **`track_commit_timestamp` downgraded to optional/diagnostic** — soundness no longer depends on it (§11.3).
> 12. **Catalogs fixed**: per-edge `fence_attempt`, `divergence.detected_epoch` FK'd to `fence_epoch`, and `repair_run`/`repair_result` + `fence_barrier` DDL added (§16, Appendix A).
>
> ### What changed from v1 (first review response, retained)
> The v2 redesign of the consistency core and pglogical integration. The substantive v2 corrections:
> 1. **Consistency is no longer a current-snapshot commit-timestamp filter.** That approach was unsound: a post-fence `UPDATE` (not just a `DELETE`) makes the old tuple invisible and the new tuple filtered, so the row falsely appears missing. Replaced by a **vector-fence epoch model with hot-key recheck** (Section 8).
> 2. **The fence is a per-origin LSN vector, not a wall-clock `max(commit_ts)`.** Wall-clock commit timestamps are not a cross-node total order (Section 8.2).
> 3. **Validation is defined against pglogical's replication contract** — replication-set action masks, column lists (`set_att_list`), row filters (`set_row_filter`), sequence buffering, and per-table sync state — not against naïve byte-equality (Sections 9, 11).
> 4. **Repair is origin-aware, locked, FK-ordered, and transactional.** `session_replication_role = replica` is explicitly rejected as loop prevention (Section 18).
> 5. **Privilege claims corrected.** pglogical administration requires superuser; validation-compute is least-privilege, but discovery/origin/repair are privileged. The tiers are separated (Section 17).
> 6. **Checksum equality is stated with its true collision bound**, and uses a homomorphic set hash (LtHash) plus a cryptographic sorted-digest confirmation, not an ad-hoc `(sum, sum_sq, xor)` (Section 10).
> 7. **`send` is not assumed universal**; per-type canonical-encoding resolution with a text fallback and explicit failure for unstable types (Section 10.3).
> 8. **pgrx hot path is implementable as specified**: a raw-fcinfo scalar `row_digest(VARIADIC "any")` plus a concrete-typed `#[pg_aggregate]` over `bytea`; planner transparency comes from coordinator-generated SQL, not an opaque relation-scanning function (Sections 10.4, 12).
> 9. **Sequences, TRUNCATE, native logical replication, and physical standbys are designed, not asserted** (Sections 9.5, 13).

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Goals and Non-Goals](#2-goals-and-non-goals)
3. [Problem Statement](#3-problem-statement)
4. [Prior Art and What We Borrow](#4-prior-art-and-what-we-borrow)
5. [Solution Overview](#5-solution-overview)
6. [Technology Choices](#6-technology-choices)
7. [The Three Guarantees](#7-the-three-guarantees)
8. [Consistency: Barrier-Converged Epochs and Digest-Stability Confirmation](#8-consistency-barrier-converged-epochs-and-digest-stability-confirmation)
9. [The pglogical Replication Contract](#9-the-pglogical-replication-contract)
10. [Checksums and Canonical Encoding](#10-checksums-and-canonical-encoding)
11. [Chunking, Localization, and Preconditions](#11-chunking-localization-and-preconditions)
12. [Node-Local Primitives and Planner Transparency](#12-node-local-primitives-and-planner-transparency)
13. [Replication Backends: pglogical, Native, Physical Standby](#13-replication-backends-pglogical-native-physical-standby)
14. [Distributed Execution Model](#14-distributed-execution-model)
15. [SQL API Surface](#15-sql-api-surface)
16. [Catalog and Data Model](#16-catalog-and-data-model)
17. [Privilege and Security Model](#17-privilege-and-security-model)
18. [Repair and Reconciliation](#18-repair-and-reconciliation)
19. [Configuration, Governance, Observability](#19-configuration-governance-observability)
20. [pgrx Implementation Plan](#20-pgrx-implementation-plan)
21. [Testing Strategy](#21-testing-strategy)
22. [Edge Cases and Failure Modes](#22-edge-cases-and-failure-modes)
23. [Cross-Version Compatibility and Packaging](#23-cross-version-compatibility-and-packaging)
24. [Milestones](#24-milestones)
25. [Open Questions and Future Work](#25-open-questions-and-future-work)
26. [Appendix A: Catalog DDL](#appendix-a-catalog-ddl)
27. [Appendix B: Worked Examples](#appendix-b-worked-examples)
28. [Appendix C: Row Digest and Set-Hash Specification](#appendix-c-row-digest-and-set-hash-specification)

---

## 1. Executive Summary

`pgl_validate` proves whether two or more pglogical-replicating PostgreSQL nodes actually hold the data they are *contractually supposed* to hold, using the two universally understood signals: **row counts** and **content checksums**. Replication can report healthy while data silently diverges (a `keep_local` conflict, a manual subscriber write, an interrupted initial COPY, a skipped apply transaction, decoding edge cases). No first-class, trustworthy verifier exists today.

Three things make this hard, and this design addresses each head-on:

1. **Consistency under lag.** You cannot reconstruct a node's past from its present snapshot, you cannot reduce a multi-origin topology to one timestamp, and PostgreSQL/pglogical expose no per-tuple commit LSN. `pgl_validate` uses a **barrier-converged epoch model with digest-stability confirmation**: a per-edge barrier (a real replicated transaction on a dedicated repset) gives an exact, edge-specific apply cut — proven by the edge's origin progress passing the barrier's exact end LSN, corroborated by token visibility; nodes are read on their own self-consistent snapshots; transient differences are confirmed real only if they **persist with unchanged per-row digests across a later barrier-converged epoch**. Verdicts are anchored to barrier-proven convergence and **sound: a confirmed divergence is always real.**
2. **The replication contract.** Equality is defined by pglogical's metadata, not by naïveté. Column lists, row filters, action masks (insert/update/delete/truncate), sequence buffering, and per-table sync state all change what "in sync" means. `pgl_validate` reads `pglogical.replication_set*`, uses `table_data_filtered()`/`show_repset_table_info()`, and validates the **strongest property the contract guarantees** for each table — never flagging intentional topology behavior as divergence.
3. **Correct, efficient mechanics.** Computation is pushed to each node via coordinator-generated SQL (planner-visible, index-using, parallel-safe). Only digests cross the wire. A homomorphic set hash (LtHash) plus cryptographic confirmation gives order-independent, duplicate-correct comparison with an honest collision bound. Merkle bisection localizes divergence to exact keys. Optional repair is origin-aware, locked, FK-ordered, and transactional.

### Validation strength — read this first

The guarantee `pgl_validate` can *soundly* prove is a function of the **backend** and the **replication contract**, not a single "tables are equal" promise. The most important caveat: **pglogical row-filtered tables can only be validated by content-intersection** — pglogical cannot insert a row that enters the filter via UPDATE (the id=6 case, §9.4), so missing/extra rows are *permitted by the contract* and reported as `advisory`, never as a divergence. Full equality of a filtered table requires native logical replication (PG ≥ 17).

| Backend / contract | What is soundly validated | `validated_property` |
|---|---|---|
| pglogical / native — full `I,U,D,T`, no filter | full row-set + content equality | `full` |
| any — no delete or no truncate (no filter) | provider ⊆ subscriber, content equal (extras legitimate) | `superset` |
| **pglogical — any row filter** | **content equality on co-present in-filter keys only; presence is `advisory`** | `filtered_intersection` |
| native (PG ≥ 17) — row filter, `I,U,D` | full `S = P_F` (filter transitions become INSERT/DELETE) | `full` |
| any — no update (insert-only) | key-set + counts; **no** content equality | `keys_only` |
| pglogical — filtered + no update | co-presence only (advisory) | `filtered_advisory` |
| no insert, or no usable key, or mid-sync | not soundly bounded → skipped/keyless, flagged | `unsupported_mask` / `keyless` |
| any edge fenced without a barrier (opt-in) | cannot be exact | verdict `degraded` |
| non-deterministic row filter (opt-in) | cannot be exact | verdict `approximate` |

Every run records the per-table `validated_property` and stamps the verdict accordingly, so "match" always carries the precise meaning of what was proven.

---

## 2. Goals and Non-Goals

### Goals

- **G1** Prove contract-correct equality across 2+ nodes with **zero false positives**.
- **G2** Report both **row counts** and **content checksums**, per table and per chunk.
- **G3** Operate **online** with bounded, configurable impact.
- **G4** Be **lag-correct** via vector-fence epochs (G1 holds under arbitrary lag and live load).
- **G5** **Localize** divergence to exact keys (missing/extra/differs).
- **G6** Honor the **pglogical contract** exactly: repsets, column lists, row filters, action masks, sequences, sync state.
- **G7** Support **bidirectional / N-way** topologies with a per-origin fence vector.
- **G8** Be **operable**: async runs, scheduling, progress, resumability, observability.
- **G9** Be **complete and fully tested**, including real multi-node replication scenarios (repository policy).
- **G10** Offer **origin-aware, transactional repair** as an explicit, privileged, opt-in operation.

### Non-Goals

- **NG1** Not a replication engine.
- **NG2** Not a DDL/schema migration tool (it *detects* drift as a precondition failure).
- **NG3** Not a UI/dashboard (exposes SQL, views, metrics).
- **NG4** Does not silently "fix" anything; repair is explicit and gated.

---

## 3. Problem Statement

Logical replication is eventually consistent and tolerant of local writes and partial contracts, so data can diverge while every health indicator is green:

| Divergence source | Why monitoring misses it |
|---|---|
| Conflict resolved `keep_local`/`skip` | Replication healthy; row legitimately differs |
| Manual write on a subscriber | No replication event |
| Interrupted/partial initial COPY | Subscription later reports `replicating` |
| Apply skipped a transaction | LSN advances; gap invisible |
| Decoding/apply edge cases (toast, types) | Rare, silent |
| Bidirectional split-brain | Both sides "win" different rows |
| **Misread contract** (filter/column/action mask) | Naïve tools flag *intended* differences as bugs |

The last row is why a correct validator must be contract-aware: a row-filtered or insert-only table is *supposed* to differ in specific ways. The operator's question is precise: *"Given what this topology promises, is the data correct?"*

---

## 4. Prior Art and What We Borrow

| Tool / Technique | Adopt | Avoid |
|---|---|---|
| Percona `pt-table-checksum` | Server-side chunked checksums sized to bound per-query time; replication-aware throttling | `BIT_XOR`/CRC combiner (cancels duplicate rows; 32-bit collisions) |
| `pg_comparator` | Merkle bisection to localize divergent keys in `O(log n)` round-trips | `md5(t::text)` (locale/format false positives) |
| Bucardo `validate` | Compare on the replication key; recheck under traffic | No formal convergence gate |
| EDB LiveCompare | Recheck of candidates after convergence; commit-timestamp awareness | (closed; we make the LSN-anchored guarantee explicit) |
| Homomorphic hashing (LtHash, Lewi et al.) | Additive, parallel-safe, **collision-resistant** multiset hash | ad-hoc additive sums with overstated equality |
| pglogical `table_data_filtered()` | Authoritative source for "what the provider would replicate" | hand-rolling row-filter/column-list semantics |

---

## 5. Solution Overview

```
                 pgl_validate run (coordinator = a primary node)
        ┌─────────────────────────────────────────────────────────────┐
        │ background worker drives the run                              │
        │ - discovers contract from pglogical.* catalogs               │
        │ - builds per-origin fence vector (epoch)                     │
        │ - fans out coordinator-GENERATED SQL over libpq (async)      │
        │ - persists typed state to pgl_validate.* catalogs            │
        └───────────────┬─────────────────────────────────────────────┘
       libpq (digests   │  generated SQL: SELECT count(*),
       + keys only)     │  pgl_validate.lthash(pgl_validate.row_digest(enc, <name-sorted cols…>))
                        │  FROM <rel> WHERE <key range> [AND <inlined immutable filter>] ...
            ┌───────────┼───────────────────────┬──────────────────────┐
            ▼           ▼                        ▼                      ▼
     ┌────────────┐ ┌────────────┐        ┌────────────┐        ┌────────────┐
     │ Node A     │ │ Node B     │  ...   │ Node C     │        │ Standby S  │
     │ (ref/prov) │ │ (sub/prov) │        │ (sub)      │        │ (read-only)│
     │ contract-  │ │ contract-  │        │ contract-  │        │ full-copy  │
     │ scoped     │ │ scoped     │        │ scoped     │        │ replay-LSN │
     │ checksums  │ │ checksums  │        │ checksums  │        │ fence      │
     └────────────┘ └────────────┘        └────────────┘        └────────────┘
        data stays local; planner uses indexes; only digests/keys cross the wire
```

**Run phases:**
1. **Discover & plan** — resolve participants, edges (origins), tables, and each table's *contract* (repset action mask, column list, row filter, sync state) and *comparison key*.
2. **Precondition gate** — extension present, schemas/columns/types compatible, key available, sync state READY (`track_commit_timestamp` is advisory only — §11.3). Fail fast, per table.
3. **Open epoch** — inject a per-edge barrier (dedicated barrier repset) and capture each barrier's exact end LSN; wait for all participants to converge (origin progress past the barrier end LSN, token visible) per §8.
4. **Count & coarse checksum** — per table, compute count + LtHash over a few top chunks on every node concurrently. Compare.
5. **Bisect** — split mismatched chunks (Merkle) until localized.
6. **Localize** — fetch `(key, row_digest)` for small ranges; classify keys; confirm clean chunks with a cryptographic sorted-digest hash.
7. **Recheck** — re-examine candidates at later epochs; confirm only those that persist across convergence; clear hot keys.
8. **Report / optionally repair.**

---

## 6. Technology Choices

| Concern | Choice | Rationale |
|---|---|---|
| Language/framework | **Rust + pgrx** | Safe FFI, `panic!`→`ERROR`, PG15–18 from one codebase, aggregate/bgworker/SPI support |
| Row digest | **`row_digest(enc int[], VARIADIC "any") → bytea`**, raw-fcinfo scalar | `enc[]` first (VARIADIC must be last); reads per-arg type via `get_fn_expr_argtype`; isolates all dynamic-type logic in one function |
| Chunk accumulator | **`#[pg_aggregate]` LtHash over `bytea`** | Concrete-typed (implementable in pgrx), additive ⇒ parallel-safe & combinable, collision-resistant |
| Cryptographic confirm | **sorted-digest BLAKE3** per localized chunk | True set hash for clean-dismissal/divergence certainty |
| Node-local execution | **coordinator-generated SQL** run via SPI (local) and libpq (remote) | Planner sees real predicates → index range scans; `EXPLAIN`-able |
| Transport | **libpq** via `pq-sys`, non-blocking | Same auth/TLS/`pg_hba` as core; one `WaitEventSet` polls N peers |
| Orchestration | **background worker** (`pgrx::bgworkers`) | Long runs, scheduling, survives disconnect, throttling |
| Contract source | `pglogical.replication_set*`, `local_sync_status`, `table_data_filtered()`, `show_repset_table_info()`, `show_subscription_table()`, `pg_replication_origin*` | Authoritative; no re-derivation of semantics |

---

## 7. The Three Guarantees

- **G-SOUND (no false positives).** A *confirmed* divergence is real with respect to the contract at the fenced epoch. Lag and live load never yield a divergence verdict (they yield *recheck-pending*, which resolves to cleared or confirmed).
- **G-COMPLETE (no false negatives, modulo bounded collision).** A genuine, persistent, contract-relevant divergence is reported. The only theoretical miss is a hash collision. By default a clean chunk is dismissed on the **LtHash** bound alone (SIS, ≥ 128-bit); a chunk that is *bisected toward a divergence* gets the stronger cryptographic `hash_digest_array` confirmation (≈ 2⁻¹²⁸ at 256-bit) during localization. Cryptographic confirmation of **every** clean chunk is **not** done by default — it requires `paranoid_confirm` (§19). So the honest statement is: divergence confirmation is cryptographic; clean dismissal is LtHash-bounded unless `paranoid_confirm` is set.
- **G-DETERMINISTIC.** Digests are a pure function of canonical logical content: independent of physical order, ctid, vacuum, locale, `DateStyle`, `extra_float_digits`, and parallel-worker count.

---

## 8. Consistency: Barrier-Converged Epochs and Digest-Stability Confirmation

> **What this section must not assume.** PostgreSQL does not expose, for a live tuple, the WAL LSN at which it was last modified. pglogical's `xact_commit_timestamp_origin(xid)` returns only `(timestamp, roident)` — no LSN (`pglogical_functions.c:2370`). Therefore the design must **never** compare a row version to an LSN fence per-tuple. v2 did, and was unsound. v3 uses only two facts that *are* available: (a) **reliable per-edge convergence to a known LSN**, and (b) **re-readable per-row digests**. The soundness proof (§8.4) rests on exactly these.

### 8.1 The convergence primitive: per-edge barrier + slot confirmation

A topology has **edges** `(origin O → target T)`, one per replication stream. To fence edge `(O→T)` *exactly*, `pgl_validate` injects a **barrier** on a **dedicated barrier replication set**. The **authoritative** convergence condition is the named edge's origin progress reaching the barrier's *exact* end LSN; token visibility is required only as a corroborating liveness check (it alone is insufficient — see the cascade caveat):

0. **Setup (once).** `pgl_validate` owns a dedicated replication set `pgl_validate_barrier` with `replicate_insert = true` (others off) containing only the standalone barrier table, and ensures every validated subscription includes it (`pglogical.alter_subscription_add_replication_set`). The barrier therefore flows on **exactly** the subscriptions/slots/origins being validated, with known routing — not piggy-backed on user repsets that might not replicate inserts or route differently.
1. **Inject.** The coordinator drives a **dedicated libpq session on `O`** (transaction control lives in the coordinator, not in a SQL function — see §15.1): `INSERT` a fresh UUID `token` into `pgl_validate.fence_barrier`; `COMMIT`; then `SELECT pgl_validate.last_commit_lsn()` in that same session to read the backend's `XactLastCommitEnd` — the barrier commit's **exact** end LSN `L_b` (not the `pg_current_wal_lsn()` over-estimate).
2. **Flush signal.** Call `pglogical.wait_slot_confirm_lsn(slot(O→T), L_b)` — passing the captured `L_b` **explicitly** rather than relying on the NULL/`XactLastCommitEnd` fallback (`pglogical_monitoring.c:50`), since the coordinator already holds the exact value — to confirm `T` received and flushed the barrier.
3. **Apply proof (edge-specific, exact).** Converge when **both** hold on `T`:
   - **Origin progress past `L_b`:** `pg_replication_origin_progress(origin(O→T), true) >= L_b`. This is the **authoritative, edge-specific** condition — the origin for the `O→T` subscription advances only as `T` applies the `O→T` stream, so reaching `L_b` proves `T` applied that stream through the barrier.
   - **Token visibility:** `SELECT 1 FROM pgl_validate.fence_barrier WHERE token = $1` on `T` (liveness/sanity corroboration).
4. By in-order apply, both holding proves `T` has applied everything `O` sent on this edge up to and including the barrier.

> **Cascade caveat (why token visibility alone is insufficient).** pglogical's default `forward_origins` is `{all}` (`README.md:311`), so in a cascade `O→X→T` the *same* barrier token can reach `T` via `X` while the direct `O→T` stream is still behind. Token visibility would then falsely signal convergence. The origin-progress-past-`L_b` condition is what makes the fence **edge-specific**; token visibility is retained only as a corroborating liveness check.

**Degraded mode (opt-in, never "exact").** If a barrier genuinely cannot be injected on an edge (e.g. the operator declines the dedicated barrier repset), the run does **not** silently weaken: by default it **aborts** that edge (`require_barrier`). Only with explicit `allow_degraded_fence` does it fall back to `wait_slot_confirm_lsn` against a captured LSN — and then every verdict on that edge is stamped **`degraded`**, a distinct outcome that can **never** be reported as exact `match`/`differ` (it does not satisfy G-SOUND).

For a **physical standby** (§13.3) no replicated-commit barrier is needed: all WAL is replayed in order, so `pg_last_wal_replay_lsn() ≥ L` against a plain primary `pg_current_wal_lsn()` `L` is itself an exact, reliable cut (origin progress does not exist on a standby).

**Barrier retention (insert-only ⇒ delete locally, guarded by active epochs).** The barrier table is a **normal, logged** table — pglogical rejects `UNLOGGED`/`TEMP` tables in a replication set (`pglogical_repset.c:1028`), so it cannot be unlogged. Because the `pgl_validate_barrier` repset replicates **inserts only**, a `DELETE`/`TRUNCATE` of old tokens on the origin would **not** propagate — so cleanup cannot go through replication. Instead the coordinator, at end of run and on a schedule, **deletes spent tokens directly and independently on each participant** over libpq.

Cleanup is **not** purely time-based, because a long-running, paused, or lagged run could still have a pending convergence check that needs to observe a token's visibility — deleting it early would (at worst) force a spurious `timeout`/`degraded`. The guard is **structural**: a token is eligible for deletion only if it is **not referenced by any unfinished run's epoch**. The coordinator computes the protected set from its own catalogs

```sql
-- protected = tokens of runs still in flight
SELECT br.token FROM pgl_validate.fence_barrier_run br
JOIN pgl_validate.run r USING (run_id)
WHERE r.status NOT IN ('completed','failed','canceled');
```

and issues, on each node, `DELETE FROM pgl_validate.fence_barrier WHERE injected_at < now() - barrier_retention AND NOT (token = ANY ($1::uuid[]))`. (Implementation note: pass the protected set as a **typed `uuid[]`** and use `NOT (token = ANY(...))` rather than `token <> ALL(...)` — the latter has surprising NULL/empty-array semantics; for large protected sets, prefer an anti-join against a temp table.) So `barrier_retention` (default `1 hour`) is only a *floor* for harmless garbage; an in-flight epoch's token is **never** removed regardless of age. Per-node local cleanup is otherwise always safe — tokens are single-use, and divergent barrier-table contents across nodes are expected and harmless (the barrier table is excluded from validation).

### 8.2 Vector fence (epoch)

An **epoch** `E` records, per edge, the barrier `token(O→T)` and its exact end LSN `L_b(O→T)`. `T` is **converged to `E`** when, for every edge feeding `T`, the §8.1 conjunction holds: `pg_replication_origin_progress(origin(O→T)) >= L_b(O→T)` **and** the token is visible. For bidirectional A↔B, `E` has two entries; for an N-way mesh, one per directed edge. No wall-clock time and no per-tuple LSN are involved — convergence is an exact, edge-specific, in-order apply cut.

### 8.3 Bulk phase (honest, unfiltered reads)

Converge all edges to an initial epoch `E0`. Then open `REPEATABLE READ` transactions on every participant, fired as close together in real time as possible (concurrent libpq), and compute per-chunk `(count, LtHash)` over each node's **current, unfiltered** snapshot — never a commit-ts-filtered view. Because providers keep writing after `E0`, a chunk may still mismatch if a row changed between convergence and snapshot acquisition; such mismatches are *bisected* (§11) and *localized* to candidate keys. For each candidate key the coordinator records every node's `row_digest(k)` from this read — call it **sample A**.

### 8.4 Confirmation by digest stability (the soundness core)

A candidate is **not** a verdict. It is resolved by one or more confirm rounds, each opening a fresh epoch:

1. Inject barriers on every edge **now** (strictly after sample A) → epoch `E1`; converge all edges to `E1`. Because the barriers are injected after sample A, each edge's `E1` LSN is `≥` that edge's position at sample A.
2. Re-read each candidate key's `row_digest(k)` on every node from fresh snapshots taken **after** convergence to `E1` → **sample B**.
3. Decide per key:
   - **Cleared** — sample-B digests now agree across all nodes (it was lag).
   - **Confirmed divergent** — sample-B digests still disagree **and** every node's digest is unchanged between A and B (`digest_A(node,k) == digest_B(node,k)` on every node).
   - **Still hot** — some node's digest changed A→B (the key is being actively written, or replication is still settling). Repeat with a new epoch, up to `recheck_passes` (default 3). Persistent hotness → **indeterminate** (surfaced, and itself meaningful: a continuously-conflicting key in active-active, or a pathological write rate on exactly the divergent key).

**Soundness theorem.** *If a candidate `k` is confirmed, the nodes genuinely differ at `k`.*

*Proof.* Suppose, for contradiction, the difference were merely lag: some replicated change `c` to `k` had been applied on a source node but not yet on node `N` at sample A. Then `c` committed on its edge `(O→N)` **before** sample A, so its commit LSN is `< L_b(O→N)`, the exact end LSN of that edge's `E1` barrier (injected *after* sample A). Convergence to `E1` (§8.2) requires `pg_replication_origin_progress(origin(O→N)) >= L_b(O→N)` — and since the origin for the `O→N` subscription advances strictly in that stream's commit order, reaching `L_b` proves `N` applied **every** `O→N` transaction with commit LSN `< L_b`, including `c`. Applying `c` changes `k`'s value on `N`, so `digest_B(N,k) ≠ digest_A(N,k)` — contradicting the confirmation condition that every node's digest is unchanged A→B. Hence no such pending replicated change exists; the difference is intrinsic to the nodes' committed state and persists under full convergence → real. ∎

The proof rests on the **edge-specific** convergence condition — origin progress past the barrier's exact end LSN `L_b` — which is why it is immune to the cascade case (a token reaching `N` via another path does *not* advance the `O→N` origin). Token visibility is a corroborating liveness check, **not** the load-bearing condition. The proof needs no per-tuple LSN, no LSN over-estimate, no commit timestamp, and no cross-node clock.

### 8.5 Bidirectional / N-way, and the role of commit timestamps

`E` is a vector over **all** directed edges; barriers are injected on each origin and convergence requires every edge. The proof generalizes unchanged — the contradiction fires on whichever edge carried `c`. `xact_commit_timestamp_origin` is used **only as a diagnostic** (to attribute a *confirmed* divergent key to the origin that last wrote it, informing repair-authority hints), never for soundness. Consequently `track_commit_timestamp` is **optional** (recommended for diagnostics and for `last_update_wins` repair), not a precondition (§11.3).

### 8.6 Cost and liveness

The bulk phase is one indexed scan per node (chunked); under load it incurs extra bisection proportional to the write rate in the convergence→snapshot window, which near-simultaneous reads keep small. The confirm phase operates **only** on the localized candidate keys (typically few), re-reading a handful of digests per round. A genuinely divergent key that is not being further modified is confirmed in a single round; a continuously-hot key is bounded by `recheck_passes` → `indeterminate`. Every confirmation is thus gated on **barrier-proven, edge-specific convergence** past a captured epoch, without ever needing a frozen global snapshot of a live multi-writer source.

---

## 9. The pglogical Replication Contract

Equality is meaningful only relative to what the topology promises. `pgl_validate` reads the contract from pglogical catalogs and validates the **strongest sound property** per table.

### 9.1 Sources (verified against pglogical 2.5.0 schema)

- `pglogical.replication_set(set_id, set_nodeid, set_name, replicate_insert, replicate_update, replicate_delete, replicate_truncate)` — the **action mask**.
- `pglogical.replication_set_table(set_id, set_reloid, set_att_list text[], set_row_filter pg_node_tree)` — **column list** and **row filter**.
- `pglogical.replication_set_seq(set_id, set_seqoid)` + `pglogical.sequence_state(seqoid, cache_size, last_value)` — **sequences**.
- `pglogical.local_sync_status(sync_kind, sync_subid, sync_nspname, sync_relname, sync_status "char", sync_statuslsn)` — **per-table sync state** (`i` init, `s` structure, `d` data, `c` constraints, `w` syncwait, `u` catchup, `y` syncdone, `r` ready).
- `pglogical.show_repset_table_info(relation, repsets) → (relid, nspname, relname, att_list, has_row_filter)` — convenience for column list + filter presence.
- `pglogical.table_data_filtered(NULL::reltype, relation, repsets) → SETOF reltype` — returns the provider rows that **pass the row filter(s)** for the repsets (`pglogical_functions.c:2086`). It applies the **row filter only**; it does **not** project columns — it returns full `reltype` rows. Column projection is obtained separately from `att_list` (`show_repset_table_info` / `replication_set_table.set_att_list`) and applied by `pgl_validate` when computing the digest.
- `pglogical.show_subscription_status()` → `status, provider_node, replication_sets, forward_origins` — topology and edges.
- `pglogical.show_subscription_table(subscription, relation) → status` — per-table sync status from the subscriber side.

### 9.2 Sync state gate

Only tables at `sync_status = 'r'` (READY) on the relevant subscription are content-validated. Tables in `i/s/d/c/w/u/y` are recorded as `skipped (sync_status=X)` with their `sync_statuslsn` — **never** counted as divergence. (`'y'` syncdone-at-lsn means caught up to a point but not promoted to ready; treated as not-ready.)

### 9.3 Column list (`set_att_list`)

`pgl_validate` does **not** re-derive the effective column set from raw `set_att_list` arrays. pglogical builds one effective column bitmap by OR-ing the per-repset `set_att_list`s across all covering repsets (a NULL `set_att_list` in any covering repset means "all columns" and wins), skipping dropped columns (`pglogical_repset.c:466`, `get_table_replication_info`). **`pglogical.show_repset_table_info(relation, repsets)` is the authoritative source** — it returns exactly the resolved `att_list` (the actual column names pglogical would replicate; `pglogical_functions.c:2005-2021`) plus `has_row_filter`. `pgl_validate` calls it and hashes precisely that set; the generated SQL emits those columns sorted by name (§10.1).

### 9.4 Action mask × row filter — the complete truth table

What "in sync" means is a function of the per-repset action flags `(replicate_insert I, replicate_update U, replicate_delete D, replicate_truncate T)` and the row filter `F`. The table below is grounded in pglogical's **verified** output-plugin behavior:

- **Row filter is evaluated on the *new* tuple for INSERT/UPDATE and on the *old* tuple for DELETE; if it fails, the entire change is *dropped* — pglogical does *not* synthesize a DELETE when a row leaves the filter** (`pglogical_output_plugin.c:646-664`). (This differs from native PG17+ row filters, which convert filter-leave updates to deletes — handled in §13.2.)
- Column (`att_list`) filtering is applied independently of row filtering (`pglogical_output_plugin.c:673`).

**The subtlety that makes filtered tables hard (verified).** For an **unfiltered** table, every provider row was necessarily inserted (`I`), so the insert flowed and the row exists on the subscriber — `P ⊆ S` is sound. With a **filter**, this breaks: a row inserted while it *fails* `F` is dropped, and if a later `UPDATE` moves it *into* `F`, pglogical sends that as an **UPDATE** (not an INSERT); the subscriber has no such row, so apply hits "the tuple to be updated could not be found … can't do INSERT here" and **skips** it (`pglogical_apply_heap.c:750`). The pglogical regression suite demonstrates exactly this: `id=6` enters the filter via UPDATEs but is **permanently absent** downstream (`row_filter.sql:156-159`, `expected/row_filter.out`). **Therefore `P_F ⊆ S` is *not* sound for pglogical-filtered tables.** (Native PG ≥ 17 converts filter transitions to INSERT/DELETE and *does* maintain `S = P_F` — §13.2; the backend determines which table applies.)

Let `P` = provider rows (projected to `att_list`), `P_F` = those passing `F`, `S` = subscriber rows (projected). For the **pglogical** backend, the soundly-validatable relation is:

| I | U | D∧T | filter | Sound current-state relation | Content compared? | `validated_property` |
|:-:|:-:|:-:|:-:|---|:-:|---|
| ✓ | ✓ | ✓ | none | `S = P` | yes | `full` |
| ✓ | ✓ | ✗ | none | `P ⊆ S` (provider deletes/truncate not propagated ⇒ extras legitimate) | yes | `superset` |
| ✓ | ✓ | any | `F`  | **intersection only**: for keys present on both sides where the *provider* row passes `F`, content matches. Presence is **not** bounded either way (id=6 absence; filter-leave staleness) | yes, on the co-present in-filter set | `filtered_intersection` |
| ✓ | ✗ | ✓ | none | `keys(P) = keys(S)` | **no** (updates drift) | `keys_only` |
| ✓ | ✗ | any | `F`  | even co-present content is not guaranteed (updates not sent) — only co-presence is observable | **no** | `filtered_advisory` |
| ✓ | ✗ | ✗ | none | `keys(P) ⊆ keys(S)` | **no** | `keys_only` |
| ✗ | — | — | any  | no insert flow ⇒ not provider-bounded | — | `unsupported_mask` (skipped, flagged) |

For `filtered_intersection`/`filtered_advisory`, a key present on one side but not the other is reported as **`advisory`**, *never* a confirmed divergence — because the contract genuinely permits it (id=6 / filter-leave). Only a content mismatch on a co-present, in-filter key is a real divergence. The `validated_property` is recorded in `pgl_validate.table_plan` and surfaced in the verdict label (e.g. `match (filtered_intersection)`), so the operator always knows precisely what was proven and what was not. Bidirectional topologies apply this table **per directed edge**; a symmetric full contract (`I,U,D,T`, no filter, `forward_origins = {}`) reduces to `S_A = S_B`.

### 9.5 Generating the provider-side population (row filters run in the replication session)

pglogical evaluates row filters **inside the replication session**, so session-sensitive expressions take the replication user's values, and volatile functions are permitted (`README.md:652-658`). A validator session cannot fully reproduce that context: `SET ROLE` does **not** reproduce `SESSION_USER`, `search_path`, arbitrary GUCs read via `current_setting(...)`, or every context-sensitive stable expression. `pgl_validate` therefore classifies each table's filter conservatively, by scanning the `set_row_filter` node tree:

1. **Immutable and context-free** (no volatile functions, no session/GUC references — the common case, e.g. `id > 0`): deparse via `pg_get_expr(set_row_filter, set_reloid)` and inline it as an **indexable** `WHERE (<filter>)`. This is **exact** because the expression is fully deterministic regardless of session — it stays on the G-SOUND verdict path.
2. **Anything else** (references `CURRENT_USER`/`SESSION_USER`/`current_setting`/`search_path`, or any non-immutable/volatile function): exact reproduction from outside the live decode stream is **not guaranteed**. The table is recorded with `schema_issue = NONDETERMINISTIC_ROW_FILTER` and may be validated only on an explicit, **separate diagnostic path** (`allow_approximate_filters`) that evaluates `pglogical.table_data_filtered()` connected **as the replication user**; its result is stamped **`approximate`** and **never** reported as an exact `match`/`differ`. Without that opt-in, the table is `skipped (reason=nondeterministic_filter)`.

Exact validation thus requires either no filter or an immutable, context-free filter; `approximate` is a clearly-separated, opt-in diagnostic that does not satisfy G-SOUND. The subscriber side is always a plain indexed range scan over filter-passing rows; both sides compute the digest over the same canonical `att_list` columns.

### 9.6 Sequences

pglogical replicates sequences by advancing the subscriber's sequence **ahead** of the provider by a buffer (`sequence_state.cache_size`); subscriber and provider `last_value` are **deliberately not equal**. The validated contract is therefore a *window*, not equality:

```
provider_last_value  <=  subscriber_last_value  <=  provider_last_value + buffer_tolerance
```

where `buffer_tolerance = sequence_buffer_multiplier * cache_size` (default multiplier 2). A subscriber value **below** the provider's is a real defect (risk of duplicate IDs) and is reported; a value within the window is `match`; far above the window is reported as drift. Sequence results live in `pgl_validate.sequence_result` (Section 16).

### 9.7 TRUNCATE

`replicate_truncate = false` means a `TRUNCATE` on the provider does not propagate, which can legitimately produce whole-table divergence; this is surfaced as a contract note, not a silent mismatch. When truncate **is** replicated, no special handling is needed (it manifests as ordinary row presence/absence under the fence).

---

## 10. Checksums and Canonical Encoding

### 10.1 Canonical row digest (G-DETERMINISTIC)

`row_digest(enc int[], VARIADIC "any") → bytea` produces a digest over the contract's replicated columns, 256-bit by default and 512-bit when `hash_algorithm = 'blake3_512'` (the generated SQL supplies the columns name-sorted and the aligned `enc[]`):

1. **Columns** = the effective replicated column set as reported by `pglogical.show_repset_table_info()` (§9.3), **emitted by the generated SQL sorted by column name** (robust to differing physical `attnum` across nodes). `row_digest` itself hashes its args positionally; the name-sort happens in `sqlgen`.
2. For each column in canonical order:
   - 1-byte null tag (`0x00` NULL / `0x01` present);
   - if present: canonical value bytes (Section 10.3), `uint32`-length-framed to prevent cross-column aliasing.
3. `digest = BLAKE3(framed bytes)[0..N]`, where `N` is selected by `hash_algorithm` (`32` bytes for `blake3_256`, `64` bytes for `blake3_512`).

The digest is a pure function of logical content — independent of physical order, ctid, page layout, vacuum, locale, and GUCs.

### 10.2 Multiset combination (honest collision bound)

v1 claimed "chunks equal **iff** `(count, sum, sum_sq, xor)` equal." That is false: distinct multisets can collide in those moments without any BLAKE3 collision. Corrected construction:

- **Fast path — LtHash** (lattice-based homomorphic multiset hash; Lewi et al., "Securing Update Propagation with Homomorphic Hashing"). Each row digest is expanded by a BLAKE3-XOF into `n` lanes of `b` bits (default `n=1024`, `b=16`, ~2 KB state); the chunk hash is the component-wise sum mod `2^b`. It is **additive** (hence parallel-safe and mergeable across partial aggregates and across chunks), **order-independent**, and **duplicate-correct**. Its collision resistance reduces to a short-integer-solution (SIS) lattice problem; with the default parameters the security level is ≥ 128 bits. Plus an independent `count`.
- **Confirm path — `hash_digest_array`.** When a chunk is small enough to localize (Section 11), the per-row 256-bit digests are collected **in sorted order** and hashed: `pgl_validate.hash_digest_array(array_agg(rd ORDER BY rd))`. This is computed with the built-in ordered `array_agg` plus a plain `bytea[] → bytea` BLAKE3 function — **not** a custom aggregate (the v2 `sorted_digest(bytea)` was mis-declared as a scalar but used as an aggregate; removed). It is a true cryptographic set hash: two chunks are equal **iff** their digest multisets are equal, except for a hash collision. It is used to (a) confirm a divergence during localization (always), and (b) cryptographically confirm a *clean* dismissal **only** when `paranoid_confirm` is enabled — by default clean chunks are dismissed on the LtHash bound alone.

**Collision bounds (corrected).** A 256-bit BLAKE3 digest provides ≈ **2⁻¹²⁸** *generic* collision resistance (birthday bound), **not** 2⁻²⁵⁶ as v2 stated. So: a chunk dismissed as clean is equal except with probability bounded by the LtHash SIS bound on the fast path (≥ 128-bit), and ≈ 2⁻¹²⁸ once `hash_digest_array` runs (which it does for any chunk near a divergence and, optionally via `paranoid_confirm`, for all chunks). For deployments wanting 256-bit collision resistance, `hash_algorithm = blake3_512` widens the row digest accordingly (≈ 2⁻²⁵⁶). The blanket "iff" of v1 and the 2⁻²⁵⁶ claim of v2 are both removed.

### 10.3 Canonical value encoding (`send` is not universal)

Per replicated column, the canonical encoding is resolved at plan time and pinned for the run:

1. **Binary `send`** (`typsend != 0`) **iff** the type's binary wire format is stable across all participants' PG majors, per a maintained per-type stability table (the standard built-in types are stable; the table encodes known exceptions). Binary `send` is locale/GUC-independent and auto-detoasts.
2. **Canonical text** fallback for types lacking a stable/usable `send`: the value's `out` function under **pinned GUCs** set in the validation session — `extra_float_digits = 3`, `DateStyle = 'ISO, YMD'`, `IntervalStyle = 'iso_8601'`, `bytea_output = 'hex'`, `TimeZone = 'UTC'`, neutral numeric formatting. Text output of a *stored value* is collation-independent (collation governs comparison/order, not representation).
3. **Unsupported** types (no stable `send`, no stable text — exotic extension types) → **precondition failure for that table**, surfaced explicitly. Never silently wrong.

**JSON:** default is **exact byte comparison** for `json` (preserves genuinely-stored differences — whitespace, key order, duplicate keys). Normalization via `jsonb` is **opt-in** (`json_normalize = on`), documented as semantics-changing. `jsonb` storage is already canonical, so its `send` is canonical.

**Float policy:** `-0.0`/`+0.0` and `NaN` bit-patterns are normalized by default (`float_signed_zero_distinct`, `float_nan_distinct` GUCs to opt out). With binary `send` these normalizations are applied to the value before encoding.

**Mixed-version topologies:** the precondition records each participant's PG major and the per-type encoding chosen; if a type's binary format is not stable across the participant set, that column falls back to text (or the table fails the precondition if text is also unstable).

### 10.4 Implementability in pgrx

- `row_digest(enc int[], VARIADIC "any") → bytea` is a **scalar** function implemented at the raw `pg_sys::FunctionCallInfo` level (pgrx exposes fcinfo and `AnyElement`; `get_fn_expr_argtype` resolves each argument's type). `enc` is the **first, non-variadic** argument (PostgreSQL requires `VARIADIC` to be last) and carries the coordinator's per-column encoding-mode code for each variadic column, **positionally aligned** with the variadic args. All dynamic-type logic is confined here. This is acknowledged lower-level pg_sys/cshim work — not a trait-based pgrx aggregate over `"any"`, which pgrx does not support.
- **Canonical column order is the generated SQL's job, not `row_digest`'s.** `row_digest` cannot reorder by column name from raw fcinfo — it hashes its variadic args in the order received. The coordinator's `sqlgen` therefore emits the columns **already sorted by column name** (and emits `enc[]` in the same order). `row_digest` hashes positionally; §10.1's "canonical order" is established upstream in the generated SQL.
- **Volatility is `STABLE`, not `IMMUTABLE`.** The text-fallback path (§10.3) calls type `out` functions whose output can depend on session GUCs (`DateStyle`, `TimeZone`, …), so `row_digest` is **not** immutable — claiming so would be wrong. Determinism *within a run* is instead guaranteed two ways: (1) the coordinator pins the required canonicalization GUCs with `SET LOCAL` in **every** node session (the same `extra_float_digits = 3` / `IntervalStyle` discipline pglogical itself uses for COPY, `pglogical_sync.c:408`); and (2) the **per-column encoding decision is made once by the coordinator and pushed via `enc[]`**, never inferred per-node — so a mixed-version topology cannot have one node choose `send` while another chooses text. This is the cross-node encoding control the API previously lacked.
- `pgl_validate.lthash(bytea) → lthash_state` is a clean **`#[pg_aggregate]`** with concrete `Args = Option<&[u8]>` and a `State = lthash_state` (`#[derive(PostgresType)]` varlena). It implements `state`, `combine`, `serial`/`deserial` (for parallel workers and partial transfer), and `finalize`; declared `parallel_safe`. (It is deterministic given its bytea inputs, but inherits `row_digest`'s `STABLE` classification at the query level.)

Both pieces are independently unit-testable (`#[test]` for the pure byte/lane math; `#[pg_test]` for the in-server behavior).

---

## 11. Chunking, Localization, and Preconditions

### 11.1 Comparison key

In priority order: (1) the table's **replica identity** (PK or `REPLICA IDENTITY` index) — the key replication itself uses; (2) a user-specified unique key; (3) **keyless fallback** (whole-relation set hash + count; hash-bucket sub-chunking for impact control; localization limited to "table differs, no key" with a recommendation to set a replica identity). Keyless tables are still *validated* (the set hash is definitive), only less *localizable*.

### 11.2 Range chunking and Merkle bisection

Key space is partitioned into ordered ranges `[lo, hi)` sized to `chunk_target_rows` (adaptive via `pg_stats` histograms / sampling, capped by `chunk_max_duration`). Range chunking permits **index range scans** and is resumable/throttleable. Composite and text/uuid keys use row-comparison boundaries; boundaries are stored as canonical bytes so they are node-independent.

```
validate_chunk(range):
  per-node = parallel_for T in participants: run generated SQL → (count, lthash) for range
  if all equal: optionally paranoid-confirm; mark CLEAN; return
  if range.rows <= localize_threshold:
      enumerate (key, row_digest) per node; set-diff; hash_digest_array confirm; emit candidates
  else:
      for sub in split(range, split_fanout): validate_chunk(sub)   # parallel
```

Localized keys are classified `missing_on` / `extra_on` / `differs` (subject to the action-mask semantics of Section 9.4), then enter digest-stability confirmation (Section 8.4). Confirmed `differs` keys may carry captured tuples (bounded by `max_reported_tuple_bytes`).

### 11.3 Precondition gate (fail fast, per table)

1. `pgl_validate` present and ABI-compatible on every participant.
2. `track_commit_timestamp` is **recommended but optional** — soundness (§8.4) does **not** depend on it. When off, the only loss is origin attribution diagnostics for confirmed-divergent keys (repair-authority hints) and `last_update_wins`-style repair; a `schema_issue = NO_COMMIT_TS` advisory (not a failure) is recorded. (v2 incorrectly made this a hard precondition for a stable/hot test that no longer exists.)
3. Relation exists; **replicated column set, types, typmods match**; non-deterministic collations flagged.
4. Comparison key present on all nodes (or explicit keyless opt-in).
5. Server encodings compatible (required for cross-node byte comparison).
6. Per-table sync state READY (Section 9.2).
7. Every replicated column has a resolved canonical encoding (Section 10.3), else table fails.

Failures are recorded in `pgl_validate.schema_issue` with a machine code and message; the run continues with remaining tables (`on_precondition_fail = skip_table` default, or `abort_run`).

---

## 12. Node-Local Primitives and Planner Transparency

The node-local checksum is **coordinator-generated SQL**, not an opaque relation-scanning C function. For a full-contract table:

```sql
-- enc[] (first arg) carries the per-column encoding mode; the columns follow as ordinary
-- VARIADIC "any" args, emitted SORTED BY NAME (amount, id, status) -- never an ARRAY[...]
-- (PostgreSQL arrays are single-typed, so ARRAY[t.a, t.b, t.c] would fail on mixed columns).
SELECT count(*) AS n_rows,
       pgl_validate.lthash(
         pgl_validate.row_digest('{2,1,1}'::int[], t."amount", t."id", t."status")) AS h
FROM   public.orders AS t
WHERE  t."id" >= $1 AND t."id" < $2;          -- key-range predicate the planner can index
```

For a row-filtered provider side with an **immutable, context-free** filter (§9.5 case 1), the generated SQL inlines the deparsed filter as an indexable `WHERE`, so **the planner uses the replica-identity index and parallel workers** and `EXPLAIN`/`auto_explain` show exactly what each chunk does. The `pglogical.table_data_filtered(...)` path is used **only** on the explicit `allow_approximate_filters` diagnostic path (§9.5 case 2) — never in the normal exact-validation generator; it is a function scan, labeled non-chunkable, and its results are stamped `approximate`, never exact. (v1's opaque-wrapper "EXPLAIN-friendly" claim remains withdrawn; planner transparency comes from the generated SQL.)

Row-level localization uses an analogous generated query returning `(key, pgl_validate.row_digest(enc, t.<name-sorted cols…>))` for a small range, with the same predicates.

---

## 13. Replication Backends: pglogical, Native, Physical Standby

`pgl_validate` is **pglogical-first**; the other backends are explicitly designed, not assumed.

### 13.1 pglogical (primary)

Topology, edges, contract, sync state, sequences as in Section 9. Origins for the fence vector come from the subscriptions' origin names; `forward_origins` informs cascade edges.

### 13.2 Native logical replication (secondary, fully specified)

- **Topology/state:** `pg_subscription`, `pg_subscription_rel.srsubstate` (`i` init, `d` data copy, `f` finished copy, `s` sync, `r` ready) — only `r` validated.
- **Contract:** `pg_publication(pubinsert, pubupdate, pubdelete, pubtruncate, pubviaroot)`, and per-table row filter `prqual` + column list `prattrs` from `pg_publication_rel`/`pg_publication_tables`. The action mask maps to the same weakened-property table as Section 9.4. Row filters are deparsed via `pg_get_expr(prqual, prrelid)` into an indexable predicate (no `table_data_filtered()` equivalent exists in core).
- **Filter-transition difference from pglogical:** native PG ≥ 17 row filters **do** convert an UPDATE whose new row leaves the filter into a DELETE on the subscriber (and old-leaves/new-matches into an INSERT). So the native truth table is *much stronger* than pglogical's §9.4 for filtered tables: with `I,U,D` and a filter, native maintains full `S = P_F` — whereas pglogical can only validate `filtered_intersection` (the id=6 absence cannot occur under native because the filter-enter UPDATE is delivered as an INSERT). `pgl_validate` selects the pglogical or native variant of the truth table per backend.
- **Partition root:** honor `pubviaroot` — validate at root or leaf consistently across nodes.
- **Fence — native barrier lifecycle (explicit).** Native has no replication sets, so `pgl_validate` builds the equivalent on core primitives:
  - **Setup (additive, permanent):** a dedicated publication `pgl_validate_barrier_pub` with `publish = 'insert'` containing only `pgl_validate.fence_barrier`. It is **added to** each validated subscription with `ALTER SUBSCRIPTION … ADD PUBLICATION pgl_validate_barrier_pub WITH (copy_data = false, refresh = true)` — `ADD` (not `SET`) **preserves the subscription's existing publication list**, and `copy_data = false` skips an initial COPY (barrier tokens are transient; no history is needed). The membership is **permanent** (established once, like the pglogical barrier repset, not toggled per run) to avoid repeated catalog/DDL churn and `REFRESH` races. The subscription's existing slot/origin (`pg_<subid>`) carries the barrier, so it is on exactly the validated edge.
  - **Convergence:** the **authoritative** signal is the same edge-specific origin check — `pg_replication_origin_progress('pg_<subid>') >= L_b`. Core has no `wait_slot_confirm_lsn`, so the provider-side flush signal polls `confirmed_flush_lsn` from `pg_replication_slots` for that edge's slot directly; token visibility corroborates.
  - **Refresh/failure handling:** if `REFRESH PUBLICATION` cannot run (subscription disabled, `copy_data` constraints) or the slot/origin cannot be mapped to the edge, the edge is treated as **un-fenceable** → abort by default, or `degraded` under explicit opt-in (as in §8.1). Native row-filter `prqual` is deparsed only when immutable/context-free (the §9.5 rule applies identically); otherwise `approximate`.
  - **Retention:** identical to §8.1 — inserts-only publication means token cleanup is per-node direct `DELETE` over libpq, never via replication.

### 13.3 Physical standby (secondary, read-only participant)

- A standby is **read-only** and has **no replication origins**, so it is a **participant** only, never a coordinator; no result catalogs are written there.
- A standby is a byte-exact physical copy, so the contract is **full equality of all tables** (no filters/column lists/action masks).
- **Fence/convergence:** unlike a logical edge, a standby replays *all* WAL, so a barrier transaction is unnecessary — `pg_last_wal_replay_lsn() ≥ L` against a plain primary `pg_current_wal_lsn()` `L` is itself reliable (the §8.1 reachability caveat does not apply to physical replay).
- **Soundness uses the same §8.4 digest-stability confirm.** v2's concern that "a primary's current snapshot and a standby's replay snapshot observe different logical times" is real but is handled exactly as for logical edges: a candidate difference is confirmed only if it persists with **unchanged digests on both the primary and the standby** across convergence to a later replay-LSN fence captured after the first read. The proof of §8.4 carries over with "applied through `E1[edge]`" replaced by "replayed through `L1`." No per-tuple LSN is needed.
- The coordinator must be a primary; standby results are stored on the coordinator's catalogs.

---

## 14. Distributed Execution Model

### 14.1 Roles

- **Coordinator** — a *primary* participant; its background worker drives the state machine, owns the run's catalog rows, opens libpq to peers, and generates per-chunk SQL. Role is per-run.
- **Participant** — any node (incl. read-only standbys) holding a copy; computes its own digests via generated SQL.
- **Reference** — the comparison baseline for missing/extra classification (default: the table's pglogical provider/origin; configurable).

### 14.2 Connectivity and wire payloads

libpq, non-blocking, one `WaitEventSet` polling N peers, so a chunk fan-out costs ≈ 1× latency. DSNs resolve from explicit args, `pglogical.node_interface.if_dsn`, or `pgl_validate.peer`. Across the wire: `(count, lthash)` per chunk (~2 KB), `(key, row digest)` only for small divergent ranges (32 bytes with `blake3_256`, 64 with `blake3_512`), and (optional, capped) full tuples for confirmed `differs` keys. **Table data is never shipped for comparison.**

### 14.3 Parallelism

Across nodes (async libpq), across chunks (`max_parallel_chunks`), and within a node (the `parallel_safe` LtHash aggregate uses PG parallel workers). All three compose; defaults are conservative.

---

## 15. SQL API Surface

All objects in schema `pgl_validate`. Functions are `SECURITY INVOKER` unless noted; privilege requirements per Section 17.

### 15.1 Node-local primitives

```sql
-- Scalar digest over a heterogeneous row. enc[] is the FIRST arg (VARIADIC must be last) and
-- carries the coordinator's per-column encoding mode, positionally aligned with the columns;
-- the generated SQL passes columns ALREADY SORTED BY NAME. Called as
-- row_digest('{1,1,2}'::int[], c_a, c_b, c_c) -- NOT with an ARRAY of columns.
-- STABLE (not IMMUTABLE): text-fallback encoding depends on pinned session GUCs (§10.4).
pgl_validate.row_digest(enc int[], VARIADIC "any") RETURNS bytea STABLE PARALLEL SAFE;  -- raw-fcinfo scalar
-- LtHash multiset accumulator: a real aggregate over the per-row bytea digests.
pgl_validate.lthash(bytea) RETURNS pgl_validate.lthash_state PARALLEL SAFE;         -- #[pg_aggregate]
pgl_validate.lthash_combine(pgl_validate.lthash_state, pgl_validate.lthash_state)   -- exposed for tests
    RETURNS pgl_validate.lthash_state IMMUTABLE PARALLEL SAFE;
-- Cryptographic set-hash for localized chunks: a PLAIN function over an already-sorted
-- bytea[]; the ordering is supplied by the caller's array_agg(... ORDER BY ...). This is
-- deliberately NOT an aggregate (v2's sorted_digest(bytea) was mis-declared).
pgl_validate.hash_digest_array(bytea[]) RETURNS bytea IMMUTABLE PARALLEL SAFE;
-- Usage: SELECT pgl_validate.hash_digest_array(array_agg(rd ORDER BY rd)) FROM (... ) s(rd);
-- Fence helpers. last_commit_lsn() returns the calling backend's XactLastCommitEnd — the EXACT
-- end LSN of the barrier commit just made (§8.1), used for the edge's origin-progress check.
pgl_validate.last_commit_lsn() RETURNS pg_lsn;        -- exact XactLastCommitEnd of this session
-- NOTE: barrier injection is NOT a SQL function — a plain function cannot do transaction control.
-- The coordinator performs INSERT + COMMIT directly over its libpq session on the origin, then
-- calls last_commit_lsn() in that same session. (A top-level CALL pgl_validate.inject_barrier(edge)
-- PROCEDURE is offered for manual/diagnostic use, since PROCEDUREs may COMMIT; it is not used on the
-- normal path.) Barrier cleanup is likewise driven by the coordinator (§8.1 retention).
-- Introspection of the SQL the engine WILL generate (planner-transparent, EXPLAIN-able):
pgl_validate.plan_chunk_sql(rel regclass, key_cols text[], lo bytea, hi bytea,
                            cols text[], repsets text[] DEFAULT NULL) RETURNS text STABLE;
```

### 15.2 Orchestration

```sql
pgl_validate.compare(
    tables    regclass[] DEFAULT NULL,    -- explicit; NULL => expand repset/auto
    repset    text       DEFAULT NULL,    -- pglogical replication set
    peers     text[]     DEFAULT NULL,    -- DSNs/node names; NULL => discover
    reference text       DEFAULT NULL,    -- baseline; NULL => provider
    options   jsonb      DEFAULT '{}'     -- per-run GUC overrides
) RETURNS bigint;                          -- run_id

pgl_validate.compare_table(table_name regclass, peers text[] DEFAULT NULL,
                           options jsonb DEFAULT '{}') RETURNS pgl_validate.table_result;
pgl_validate.cancel(run_id bigint) RETURNS boolean;
pgl_validate.pause(run_id bigint)  RETURNS boolean;
pgl_validate.resume(run_id bigint) RETURNS boolean;   -- also resumes a crashed run
```

### 15.3 Results

```sql
pgl_validate.run_status(run_id bigint)  RETURNS pgl_validate.run;
pgl_validate.divergences(run_id bigint) RETURNS SETOF pgl_validate.divergence;
pgl_validate.sequences(run_id bigint)   RETURNS SETOF pgl_validate.sequence_result;
pgl_validate.report(run_id bigint)      RETURNS jsonb;
-- Views over the catalogs (Section 16): runs, run_progress, table_results,
--   chunk_results, divergences, sequence_results, schema_issues.
```

### 15.4 Repair (privileged; Section 18)

```sql
pgl_validate.generate_repair(run_id bigint, authoritative text) RETURNS SETOF text;
pgl_validate.apply_repair(
    run_id bigint, authoritative text, target text, confirm text,
    propagation text DEFAULT 'local_only',          -- 'local_only' | 'replicate' (§18.2)
    acknowledge_conflict_policy boolean DEFAULT false -- required for 'replicate'
) RETURNS pgl_validate.repair_run;                    -- origin-aware, locked, FK-ordered, transactional
-- Per-key outcomes land in pgl_validate.repair_result (FK repair_id).
```

---

## 16. Catalog and Data Model

State is persisted (typed, normalized, FK-linked) so runs are resumable and auditable. Full DDL in [Appendix A](#appendix-a-catalog-ddl). Key tables:

- `run` — one row per run; status enum `planning|fencing|running|paused|rechecking|completed|failed|canceled`.
- `run_participant` — per node: role, pg_version, backend (`pglogical|native|standby`), DSN ref, per-node status.
- `run_edge` — **normalized edge identity** (provider node, target node, subscription, slot, origin name, repsets, backend); referenced by `fence_*` via `edge_id` because `'A->B'` text cannot distinguish multiple DBs/subscriptions/slots/repsets/origins between the same node pair.
- `fence_epoch` / `fence_edge` — the **vector fence per epoch** (`fence_edge(run_id, epoch_seq, edge_id, barrier_token, barrier_end_lsn, degraded)`), plus `fence_attempt` keyed **per (run, epoch, edge_id)**; each edge converges independently and records `origin_progress_lsn` vs `barrier_end_lsn` (**the authoritative, edge-specific condition** — origin progress ≥ the barrier's exact end LSN), `token_visible` (corroborating liveness), `confirmed_flush_lsn`, and `status` (incl. `degraded`).
- `fence_barrier` — **standalone, FK-free, and deliberately NON-unique on `token`** (a cascade can deliver the same token twice; a unique constraint would cause an `insert_insert` conflict that `conflict_resolution = error` turns into an apply stall). A normal logged table (pglogical forbids UNLOGGED/TEMP in repsets); the only `fence_*` table added to a repset. Run/edge linkage lives in the **non-replicated** `fence_barrier_run`.
- `table_plan` — per (run, table): key_cols, **contract** (repset action mask, has_row_filter, att_list, repsets), sync_status, and the `validated_property` actually checked (full / superset / keys_only / filtered_intersection / filtered_advisory / keyless / unsupported_mask).
- `table_result` (FK→`table_plan`) — verdict `match|differ|indeterminate|partial|approximate|degraded|skipped|error|fence_timeout`.
- `table_node_result` — per (run, table, node): `n_rows bigint`, `lthash bytea`, `set_hash bytea` (typed, not JSONB).
- `chunk_result` — per (run, table, chunk_id, parent_id): `lo/hi bytea`, state enum `pending|running|clean|split|divergent|candidate`.
- `chunk_node_result` — per (chunk, node): `n_rows`, `lthash`.
- `divergence` — per key: `classification (missing_on|extra_on|differs)`, `node`, `key_text`, `key_bytes`, `status (candidate|confirmed|cleared|indeterminate|advisory)`, detection epoch FK, optional `tuple jsonb` (capped). The `advisory` status carries the §9.4 filtered-table presence differences that the contract permits and that are therefore **never** promoted to `confirmed`.
- `divergence_recheck` — per (divergence, epoch_seq): outcome.
- `conflict_evidence` — optional pglogical conflict-history rows correlated to confirmed divergences by subscription, relation, time window, and tuple JSON containing the divergent key. This is explanatory evidence (`update_update` + `keep_local`, `skip`, etc.), never a source of validation truth.
  Vanilla pglogical deployments may not expose `pglogical.conflict_history`; absence of that table is a normal, supported state that must return zero conflict evidence without weakening or failing validation. Queryable conflict history from the willibrandon pglogical fork enriches reports only.
- `sequence_result` — per sequence: provider/subscriber `last_value`, `cache_size`, `within_contract boolean`, verdict.
- `schema_issue` — per precondition failure (FKs).

All child tables carry FKs to `run` / `table_plan` with `ON DELETE CASCADE`; states referenced in prose (`running`, `candidate`, etc.) are present in the CHECK enums. Critical checksums and fences are **typed columns / child tables**, not opaque JSONB. Retention via `pgl_validate.purge(before timestamptz)` and optional scheduled cleanup.

Resumability: every visited chunk's verdict is committed; a resumed run skips `clean` chunks and re-fences from the frontier (safe — verdicts are per-chunk and convergence-gated). A crashed coordinator's held snapshots are gone, so resume opens a fresh epoch.

---

## 17. Privilege and Security Model

v1's "no superuser required" was false. **pglogical replication and administration require superuser** (pglogical `README.md`). The privilege tiers are separated:

| Tier | Capability | Privilege |
|---|---|---|
| **T1 — Validate (compute)** | Run generated checksum SQL: `SELECT` on validated tables, `EXECUTE` on `pgl_validate.row_digest`/`lthash`/`hash_digest_array`, `CONNECT`/`USAGE` | Least-privilege read-only role |
| **T2 — Discover** | Read pglogical catalogs, call `table_data_filtered()`/`show_*`, read `pg_replication_origin_progress`, sync status | Elevated: effectively **superuser** in pglogical topologies (per pglogical's model), or a role granted access to pglogical catalogs + replication-monitor functions |
| **T3 — Orchestrate** | Launch background workers, write `pgl_validate.*` catalogs | `pgl_validate` owner role; dynamic bgworker registration may require superuser depending on deployment |
| **T4 — Repair** | Origin setup/advance, locking, DML on target | **Superuser / replication-origin + table-owner privileges** |

Security properties: only digests/keys cross the wire by default; full-tuple capture is opt-in and capped; functions are `SECURITY INVOKER` (the aggregate cannot read tables the caller cannot); DSNs follow libpq conventions (`.pgpass`, services, TLS) and any stored DSNs are `REVOKE`d from `PUBLIC`; every run, its options, its launcher, and every repair statement are audited in catalogs. The validation path issues **no writes** to user data; repair is the only writer and is T4-gated.

---

## 18. Repair and Reconciliation

Repair is **opt-in, single-target, transactional, locked, FK-ordered, and explicit about propagation**, and is designed against pglogical's *actual* origin-forwarding semantics — which support only `forward_origins ∈ {{}, {all}}` (`README.md:311-315`), **not** arbitrary per-repair routing. `session_replication_role = replica` is **explicitly rejected** (it is not an origin mechanism, requires elevated privilege, and changes trigger semantics).

### 18.1 Generate

`generate_repair(run_id, authoritative)` emits the minimal DML to reconcile each non-authoritative node to `authoritative` for **confirmed** divergent keys only, and only those that are divergences *under the table's validated property* (§9.4). For `superset`, subscriber extras are contract-permitted and are advisory/no-op. For `keys_only`, repair reconciles key presence only: `missing_on` becomes `INSERT`, and `extra_on` becomes `DELETE` only when delete/truncate are part of the replicated contract; content drift remains out of scope because updates are not replicated. For `full`, `differs` becomes `UPDATE`. Output is reviewable text; nothing is applied.

### 18.2 Origin model and loop prevention (the complete specification)

The repair tags its writes with a dedicated origin, and — mirroring pglogical's own sync path, which sets the origin **before** `BEGIN` and resets it **after** `COMMIT` (`pglogical_sync.c:421, 465`) — the exact ordering is mandatory: `pg_replication_origin_create('pgl_validate_repair')` (once, idempotent); then **outside/before** the repair transaction `pg_replication_origin_session_setup('pgl_validate_repair')`; then `BEGIN … COMMIT`; then `pg_replication_origin_session_reset()` after commit (to avoid races on the origin with other backends). Whether those writes leave the target is **fully determined by the target's outbound subscriptions' `forward_origins`** — there is no per-write routing knob. `apply_repair` takes an explicit `propagation` mode and validates it against the topology:

- **`local_only` (default).** The repair must not propagate off `target`.
  - If every downstream subscription from `target` uses `forward_origins = {}` (the bidirectional norm): an origin-tagged write is treated as "received from elsewhere" and is **not re-forwarded** — loop prevention by exactly the mechanism pglogical already uses.
  - If any registered downstream subscription uses `forward_origins = {all}` (cascade): origin tagging cannot stop propagation, and merely disabling/re-enabling the subscription is **not** a sound fix because the subscription's slot retains the repair WAL and can decode it after re-enable. Therefore `local_only` is refused before applying DML, with the forwarding subscriptions recorded in the repair error. `pgl_validate` never pauses, disables, or rewrites pglogical subscription state to force the repair through; the operator must change the topology outside the repair run (for example by recreating the downstream subscription with `forward_origins = {}` where pglogical requires that) or choose `replicate` with an explicit conflict-policy acknowledgement.
- **`replicate`.** Written as a **local-origin** change (no origin setup), allowed to flow downstream; conflicts at peers are resolved by each peer's `pglogical.conflict_resolution` (converges to the authoritative value only if peers do not keep local). Refused unless `acknowledge_conflict_policy := true`; effective per-peer resolution is recorded.

### 18.3 What is and isn't transactional (stated honestly)

`apply_repair(run_id, authoritative, target, confirm, propagation, …)` is guarded by a type-to-confirm token equal to the target node name, and is transactional **for the row DML**, with explicit non-transactional steps called out:

1. **Establish propagation mode** per §18.2 (origin session setup before `BEGIN`; or preflight refusal when downstream `forward_origins = {all}` would forward a `local_only` repair).
2. `BEGIN`. **Lock** the divergent keys on `target` (`SELECT … FOR UPDATE`).
3. **FK-ordered DML.** `INSERT`s parent→child, `DELETE`s child→parent (topological sort over `pg_constraint`); `UPDATE`s for `differs`.
4. **In-transaction verification.** Before commit, re-read the repaired keys *on the target* and assert they now equal the authoritative values — this is what the lock protects, and it either holds or the transaction **rolls back** (atomic for the row DML).
5. `COMMIT`; then `pg_replication_origin_session_reset()`. **The locks release at commit**, so the subsequent **cross-node** revalidation (a focused mini-run against all peers) runs *without* holding locks and is recorded as the authoritative post-repair verdict — it is explicitly a *post*-commit check, not part of the atomic unit.
6. **Sequences are non-transactional.** `setval` is **not** rolled back by a transaction abort, so sequence reconciliation is performed as a **separate, clearly-labeled non-transactional step** (after the row DML commits) and recorded as such in `repair_result(action = 'setval')`. The "transactional" guarantee covers the row DML in steps 2–5, not `setval`.

### 18.4 Bidirectional caveat

In active-active, repairing a conflicted key requires designating an authority. `local_only` reconciles just the `target`; full mesh convergence then relies either on a subsequent authoritative write or on `replicate` mode with a compatible conflict policy. This is genuinely delicate, is T4-privileged (superuser; origin + table-owner), and defaults to **generate-only** — `apply_repair` is always an explicit, separate, audited step.

---

## 19. Configuration, Governance, Observability

### 19.1 GUCs (selected; all `pgl_validate.*`, overridable per-run via `options`)

| GUC | Default | Purpose |
|---|---|---|
| `hash_algorithm` | `blake3_256` | row and set digest width / algo (`blake3_256`\|`blake3_512`) |
| `paranoid_confirm` | `off` | run the cryptographic `hash_digest_array` confirm on **every** clean chunk. Bounded by `paranoid_confirm_max_rows` (default = `localize_threshold`): a clean chunk larger than this is **subdivided** so `array_agg(ORDER BY)` never materializes an unbounded array; an external/streaming sorted-hash path is used above the in-memory cap |
| `paranoid_confirm_max_rows` | `1000` | per-statement row cap for the sorted-set confirm; larger chunks are split or stream-sorted (memory/spill bound) |
| `chunk_target_rows` | `50000` | adaptive chunk sizing |
| `chunk_max_duration` | `2s` | split-and-retry threshold |
| `split_fanout` | `4` | Merkle children per level |
| `localize_threshold` | `1000` | switch to row-level localization |
| `max_parallel_chunks` | `4` | concurrent chunk subtrees |
| `fence_timeout_ms` | `300000` | wait for a peer to reach a fence |
| `fence_poll_interval_ms` | `100` | poll interval while waiting for fence convergence |
| `require_barrier` | `on` | abort an edge that cannot be barrier-fenced; set `allow_degraded_fence` to opt into `degraded` verdicts instead |
| `allow_degraded_fence` | `off` | opt into degraded fence verdicts when an exact barrier is unavailable |
| `allow_approximate_filters` | `off` | opt into diagnostic pglogical filter evaluation that is never G-SOUND |
| `recheck_passes` | `3` | epochs before confirm/indeterminate |
| `max_snapshot_age` | `5min` | re-fence to bound vacuum impact |
| `statement_timeout_per_chunk` | `30s` | hard per-chunk cap |
| `throttle_max_lag` | `off` | pause if any peer's lag exceeds this |
| `json_normalize` | `off` | normalize `json` via `jsonb` (semantics-changing) |
| `float_signed_zero_distinct` | `off` | distinguish `-0.0` from `+0.0` in row digests |
| `float_nan_distinct` | `off` | preserve distinct NaN bit patterns in row digests |
| `sequence_buffer_multiplier` | `2` | sequence window tolerance × `cache_size` |
| `max_reported_tuple_bytes` | `8192` | cap captured divergent tuples |
| `max_reported_divergences` | `1000` | cap persisted key-level divergences per table and peer |
| `correlate_conflict_history` | `on` | attach fork-provided pglogical conflict-history rows when available |
| `conflict_history_max_rows` | `1000` | cap conflict-history rows fetched per peer |
| `scheduler_database` | (unset) | database where the static scheduler worker dispatches schedules |
| `scheduler_interval_ms` | `60000` | scheduler polling interval |

LtHash uses a fixed 1024 × 16-bit accumulator. Those parameters are part of the `lthash_state` binary/text representation and are not GUCs.

Per-run `options` add policy choices that should be explicit on each validation request: `on_fence_timeout = 'abort_run' | 'skip_peer'` and `on_precondition_fail = 'skip_table' | 'abort_run'`. A requested comparison that loses a peer defaults to aborting; `skip_peer` stamps the run `partial`, never plain `match`.

### 19.2 Governance

Bounded per-chunk statements (`chunk_max_duration`, `statement_timeout_per_chunk`); **snapshot-age cap** with re-fence to bound vacuum/bloat from held `REPEATABLE READ` transactions; **lag-aware throttle** (never harm the replication being validated); inter-chunk I/O throttle; conservative parallelism caps. Read-only validation path.

### 19.3 Observability

Reporting surfaces: `runs`, `run_progress` (chunks done/total, ETA, bytes scanned, phase, current epoch), `table_results`, `chunk_results`, `divergences`, `conflict_evidence`, `sequence_results`, `schema_issues`. `report(run_id)` returns a complete structured JSON verdict (per-table contract + property validated, counts per node, confirmed keys, correlated pglogical conflict evidence, sequence windows, timing, resource stats) suitable for CI gates. `metrics()` exposes stable counters/gauges (runs by status, tables matched/differing, last successful validation per table, rows scanned, bytes transferred) for scraping. Phase transitions, per-epoch fence vectors, convergence waits, throttle events, and re-fences are logged with the run id via `log!`/`ereport!`.

---

## 20. pgrx Implementation Plan

```
pgl_validate/
├── Cargo.toml                 # cdylib; features pg15..pg18; deps: pgrx, pq-sys, blake3
├── pgl_validate.control
├── sql/
│   ├── bootstrap/             # extension_sql_file!: catalogs, contracts, barriers, fencing,
│   │                           # planning SQL, compare orchestration, repair, reporting, cleanup
│   └── comments.sql            # SQL object comments and privilege-role descriptions
├── src/
│   ├── lib.rs                 # pg_module_magic!, _PG_init (GUCs, optional launcher worker)
│   ├── sql_api.rs             # pgrx SQL bindings, aggregate, libpq wrappers, worker launcher
│   ├── digest/
│   │   ├── encode.rs          # canonical per-type encoding: send vs pinned-text vs error  (#[test])
│   │   ├── row_digest.rs      # raw-fcinfo VARIADIC "any" scalar; framing; BLAKE3            (#[pg_test])
│   │   └── lthash.rs          # LtHash lanes + sorted-digest; #[pg_aggregate]               (#[test]/#[pg_test])
│   ├── transport/             # libpq fan-out, remote checksums/localization, DSN handling
│   ├── worker.rs              # dynamic run worker + optional static launcher/scheduler
│   └── pg_tests.rs            # in-server regression coverage for SQL and Rust surfaces
└── tests/                     # cargo pgrx regress + multi-node harness (Section 21)
```

**Boundary discipline:** PostgreSQL-visible orchestration stays in `sql/bootstrap/*.sql` unless there is a concrete reason it needs Rust. That includes catalog invariants, contract discovery, barrier/fence state transitions, planner-visible SQL generation, Merkle/chunk state, repair bookkeeping, reporting, and maintenance. Keeping that logic in SQL is intentional: DBAs can inspect it with normal PostgreSQL tools, generated checksum queries remain planner-visible, and catalog behavior can be covered directly by `#[pg_test]` and multi-node harnesses.

Rust owns the pieces that are either CPU-bound, pgrx-specific, or outside PL/pgSQL's natural boundary: canonical row encoding, the raw-fcinfo heterogeneous `row_digest`, LtHash and sorted-digest confirmation, libpq transport, GUC registration, and background worker launch/execution. Pure Rust tests cover digest math and encoding helpers; SQL behavior is tested through in-server regression tests and real replication harnesses.

**Hot path** is exactly two custom objects (`row_digest` scalar via raw fcinfo; `lthash` concrete-typed aggregate); everything else is planner-visible generated SQL (Section 12), so the design is implementable within pgrx's actual capabilities.

---

## 21. Testing Strategy

Per repository policy, **every feature ships with complete regression tests exercising the full path with real provider/subscriber replication** — no schema-only or simplified tests.

### 21.1 Pyramid

1. **`#[test]` (pure Rust):** encoding rules (null tag, length framing, name-ordering, send-vs-text selection, float/json policy), LtHash lane math (commutativity, associativity, duplicate sensitivity) and its collision-bound parameters, sorted-digest set-hash, Merkle split/boundary math, FK topological sort, contract parsing.
2. **`#[pg_test]` (in-server):** `row_digest`/`lthash`/`hash_digest_array` over real tables — order independence (post-`CLUSTER`), parallel-worker equivalence (`max_parallel_workers_per_gather` 0 vs N), all scalar/container/json/numeric/bytea/array/composite/timestamptz types, keyless path.
3. **`cargo pgrx regress`:** golden output for the SQL API, generated-SQL shape, views, GUCs, schema-issue codes, repair DML.
4. **Multi-node integration harness (centerpiece):** brings up **two+ real PostgreSQL instances**, installs `pgl_validate` on each, configures **real pglogical replication** (and a native-logical path, and a physical-standby path), runs end-to-end scenarios.

### 21.2 Mandatory scenarios (each fully implemented)

| Scenario | Asserts |
|---|---|
| Clean sync, idle and under live write load | No false positives under lag (G-SOUND); hot keys cleared by recheck |
| Missing / extra / value-drift on subscriber | Localized to exact key; correct classification; survives recheck |
| **Post-fence UPDATE on provider** (the v2 bug) | Candidate raised then **cleared** by recheck — no phantom-missing |
| Post-fence DELETE on provider | Cleared by recheck |
| **Barrier convergence is exact & edge-specific** | Converge on `origin_progress(origin(O→T)) ≥ L_b` (authoritative) with `wait_slot_confirm_lsn(slot, L_b)` and token visibility as corroboration; **cascade test**: a token reaching T via `O→X→T` must NOT mark the direct `O→T` edge converged |
| **Cascade duplicate token + `conflict_resolution = error`** | In `O→X→T` *and* `O→T` with `forward_origins='{all}'`, the same token arrives twice at T; with no unique constraint the duplicate is a harmless heap row and apply does **not** error/stall (the explicit test the review requires) |
| **pglogical filtered-table id=6 case** (`row_filter.sql:156`) | Row that enters the filter via UPDATE is legitimately absent downstream → reported `advisory`, **never** a confirmed divergence (G-SOUND) |
| **Native filtered table** (PG ≥ 17) | Filter-enter UPDATE delivered as INSERT → full `S = P_F` validated (stronger than pglogical) |
| **Degraded fence (no barrier)** | Default **aborts**; with `allow_degraded_fence`, verdict is `degraded` and never `match`/`differ` |
| **Non-deterministic row filter** (`current_setting`/`CURRENT_USER`) | Exact path refused; only `approximate` under explicit opt-in, never on the G-SOUND path |
| **Column list** (`set_att_list`) | Only listed columns hashed; non-listed differences ignored |
| **Insert-only repset** (no update) | Validates keys+counts only; content drift **not** flagged |
| **No-delete repset** | `extra_on(sub)` **not** a divergence; missing/differs still caught |
| **Mid-sync table** (`sync_status != 'r'`) | Skipped with reason, not divergence |
| **Sequence drift** | Within-window = match; subscriber-below-provider = reported defect |
| Duplicate-row table (no PK) | LtHash detects the dup that XOR would miss; keyless verdict definitive |
| Schema/type/collation drift | Precondition failure with code; other tables still validated |
| Bidirectional conflict (`keep_local`) | Real divergence detected; vector fence + origin attribution correct |
| Mixed PG major versions | Encoding falls back to text where send-format unstable; no false positive |
| Native logical replication (row filter + pubactions) | Contract honored as for pglogical |
| Physical standby participant | Full-equality contract; replay-LSN fence; coordinator on primary |
| Repair: origin set-before-BEGIN / reset-after-COMMIT; multi-table FK ordering; `replicate` vs `local_only` | Post-repair `match`; no replication loop; FK order correct |
| Repair with downstream `{all}` cascade subscription | `local_only` is refused before DML; no target mutation occurs; operator must reconfigure or choose `replicate` |
| Sequence repair is non-transactional | `setval` reconciliation recorded separately; row-DML rollback does not un-`setval` |
| Resume after coordinator kill mid-run | Resumes from frontier; final verdict identical |
| Throttle / lag-pause | Pauses above threshold; resumes |

### 21.3 Property/differential

proptest over encoding+LtHash+sorted-digest (equal multisets ⇒ equal hashes; single perturbation ⇒ different, modulo stated bound); differential test of the aggregate vs an independent in-test reference (sorted, framed) computation. CI matrix PG15–18 × Linux/macOS/Windows, consistent with the fork's pipeline.

---

## 22. Edge Cases and Failure Modes

| Case | Handling |
|---|---|
| Peer unreachable mid-run | libpq error → peer `unreachable`; default `on_fence_timeout = abort_run`; only with explicit `skip_peer` does the run continue, stamped `partial` (never plain `match`) |
| Replication broken / never converges | Convergence timeout → table `fence_timeout`, never a false `match` |
| Barrier cannot be injected on an edge/repset | Default: **abort that edge** (`require_barrier`). Only with explicit `allow_degraded_fence` does it fall back to `wait_slot_confirm_lsn`; every verdict on that edge is then `degraded` and can never be `match`/`differ` |
| `track_commit_timestamp = off` | Advisory `NO_COMMIT_TS` only — soundness is independent of it (§8.4/§11.3); origin-attribution diagnostics and `last_update_wins` repair are disabled |
| No replica identity | Keyless path; table verdict definitive; localization limited and stated |
| Non-deterministic collation column | Hashed by canonical bytes (matches replication's own equality); flagged |
| Unstable `send` / exotic type | Text fallback, or per-table precondition failure; never silently wrong |
| Continuously-hot key | `recheck_passes` cap → `indeterminate` with diagnostics (itself meaningful) |
| Snapshot too old | Re-fence at `max_snapshot_age`; per-table fences keep cost low |
| DDL during a run | Affected table errors and is re-planned on resume; others unaffected |
| Whole-table divergence | Bisection still localizes; enumerated keys capped (`max_reported_divergences`) with a summary count |
| Partitioned tables | Each leaf validated independently; `pubviaroot`/parent semantics honored; parent = aggregate of leaves |
| Coordinator on a standby | Rejected at planning: coordinator must be a primary |

---

## 23. Cross-Version Compatibility and Packaging

- **Supported:** PostgreSQL 15–18 (the fork's window). pgrx feature flags `pg15`–`pg18`; one cdylib per major.
- **Version-sensitive surfaces** isolated in `compat/`: `pg_replication_origin_progress`, `pg_xact_commit_timestamp_origin`, the per-type `send`-format stability table, snapshot/`REPEATABLE READ` helpers, parallel-aggregate `serial`/`deserial`. Gated with `#[cfg(feature = "pgNN")]` / `PG_VERSION_NUM`.
- **Mixed-version topologies:** comparison over canonical encoding is valid iff the chosen encoding is stable across the participants' majors; the precondition records versions and per-type choices and falls back to text or flags accordingly.
- **Packaging:** `cargo pgrx package` per major for Linux, macOS, and Windows zip artifacts, plus a WiX v5 MSI for each Windows x64 PostgreSQL major. MSI installers must mirror the pglogical fork's release expectations: registry-based PostgreSQL path detection, explicit `POSTGRESQLDIR` override, browse fallback, per-user developer install support, clean uninstall, major-version-specific UpgradeCode values for side-by-side pg15/pg16/pg17/pg18 support, and CI verification with silent install/uninstall. `CREATE EXTENSION pgl_validate;` on **every** participant; scheduling additionally needs `shared_preload_libraries = 'pgl_validate'`. No user-schema changes; all objects under `pgl_validate`. pglogical support is a mandatory release and regression-test gate, and pglogical must be installed on pglogical participants. CI must cover both the Windows-capable fork release path and upstream vanilla pglogical source on platforms where upstream ships a normal source build; queryable conflict history from the fork is report enrichment only, never a validation precondition. Native logical and standby modes are additional backend paths, not a reason to weaken pglogical coverage. Standard `--X.Y.sql` / `--X.Y--A.B.sql` scripts.
- **Initial release:** the first public release tag is `v0.1.0`, matching `Cargo.toml` and `pgl_validate.control`. Cut it only after the implementation goal is met, CI is green, release artifacts include zip packages, Windows x64 MSI installers, and checksums, and the documentation reflects the shipped behavior. License is MIT, copyright Brandon Williams.

---

## 24. Milestones

| Milestone | Deliverable | Tests gating completion |
|---|---|---|
| **M1 — Digest + set hash** | `encode.rs`, `row_digest.rs`, `lthash.rs` (LtHash + sorted-digest) | unit + property + `#[pg_test]` order/parallel/types |
| **M2 — Generated SQL + two-node compare** | `sql/bootstrap/040_planning.sql`, `sql/bootstrap/050_compare.sql`, `src/transport/libpq.rs` | two-node clean/missing/extra/differs; EXPLAIN shows index scans |
| **M3 — Contract** | `sql/bootstrap/010_contracts.sql`, `sql/bootstrap/050_compare.sql` | row-filter, column-list, insert-only, no-delete, mid-sync, sequence scenarios |
| **M4 — Vector fence + recheck** | `sql/bootstrap/020_barriers.sql`, `030_fencing.sql`, `036_re_fence.sql`, `050_compare.sql`, `src/transport/libpq.rs` | post-fence UPDATE/DELETE cleared; live-load no false positive; bidirectional |
| **M5 — Merkle + localization** | `sql/bootstrap/040_planning.sql`, `050_compare.sql` | localize-to-key; keyless; partitioned |
| **M6 — Async fan-out + N-way** | `src/transport/libpq.rs`, `sql/bootstrap/050_compare.sql` | N-way + bidirectional fences |
| **M7 — Orchestration + catalogs** | `src/worker.rs`, `sql/bootstrap/001_catalog.sql`, `070_reporting.sql`, views, resumability, scheduling | resume-after-crash; throttle/pause |
| **M8 — Native + standby backends** | `sql/bootstrap/010_contracts.sql`, `030_fencing.sql`, `035_throttle.sql`, `050_compare.sql`, `src/transport/libpq.rs` | native row-filter/pubactions; standby participant |
| **M9 — Repair** | `sql/bootstrap/060_repair.sql`, `src/transport/libpq.rs` (origin-aware, locked, FK-ordered) | generate/apply/revalidate; multi-table FK; no loop |
| **M10 — Hardening + release** | security tiers, observability, cross-version, packaging | full matrix PG15–18 × 3 OSes |

Each milestone is independently shippable and fully tested before the next (no deferred work).

---

## 25. Open Questions and Future Work

- **Incremental validation** — re-validate only key ranges whose `pg_xact_commit_timestamp` watermark advanced since the last clean run, for cheap continuous assurance (catalog already records per-chunk verdicts and epochs).
- **Explicit sampling mode** — statistically-bounded partial validation for very large tables, with a *reported* confidence level (never silent scope reduction).
- **Slot-peek fence** — derive an exact provider fence LSN from a logical slot peek instead of `pg_current_wal_lsn()`, if a future need arises.
- **Conflict-history summaries and retention** — conflict-history correlation is part of the catalog/API path; `conflict_summary(run_id)` provides compact cause counts by table/node/conflict type/resolution, and `purge_conflict_evidence(before, run_id)` lets operators retain validation results while pruning raw evidence in long-running fleets.

---

## Appendix A: Catalog DDL

This appendix mirrors [`sql/bootstrap/001_catalog.sql`](../sql/bootstrap/001_catalog.sql), the authoritative install DDL. Keep them in sync whenever catalog objects change.

```sql
CREATE SCHEMA IF NOT EXISTS pgl_validate;

CREATE TABLE pgl_validate.peer (
    name                    text PRIMARY KEY,
    dsn                     text NOT NULL,
    backend                 text NOT NULL DEFAULT 'pglogical'
                            CHECK (backend IN ('pglogical','native','standby')),
    subscription_name       name,
    reverse_subscription_name name,
    replication_sets        text[],
    connect_timeout_seconds int NOT NULL DEFAULT 10
                            CHECK (connect_timeout_seconds > 0),
    statement_timeout_ms    int NOT NULL DEFAULT 600000
                            CHECK (statement_timeout_ms > 0),
    lock_timeout_ms         int NOT NULL DEFAULT 30000
                            CHECK (lock_timeout_ms > 0),
    added_at                timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON pgl_validate.peer FROM PUBLIC;

CREATE TABLE pgl_validate.run (
    run_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status         text NOT NULL CHECK (status IN
                   ('planning','fencing','running','paused','rechecking',
                    'completed','failed','canceled')),
    options        jsonb NOT NULL DEFAULT '{}',
    reference_node text,
    launched_by    name NOT NULL DEFAULT current_user,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    tables_total   int,
    tables_matched int,
    tables_differ  int,
    error          text
);

CREATE TABLE pgl_validate.run_participant (
    run_id     bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    node       text NOT NULL,
    role       text NOT NULL CHECK (role IN ('coordinator','reference','participant')),
    backend    text NOT NULL CHECK (backend IN ('pglogical','native','standby')),
    pg_version int  NOT NULL,
    dsn_ref    text,
    status     text NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','connected','converged','skipped','unreachable','done','error')),
    PRIMARY KEY (run_id, node)
);

CREATE TABLE pgl_validate.fence_epoch (
    run_id     bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    epoch_seq  int NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, epoch_seq)
);

CREATE TABLE pgl_validate.run_edge (
    run_id        bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    edge_id       int NOT NULL,
    provider_node text NOT NULL,
    target_node   text NOT NULL,
    backend       text NOT NULL CHECK (backend IN ('pglogical','native','standby')),
    subscription  text,
    slot_name     text,
    origin_name   text,
    repsets       text[],
    PRIMARY KEY (run_id, edge_id)
);

CREATE TABLE pgl_validate.fence_edge (
    run_id          bigint NOT NULL,
    epoch_seq       int NOT NULL,
    edge_id         int NOT NULL,
    fence_kind      text NOT NULL CHECK (fence_kind IN ('barrier','standby_replay','degraded')),
    barrier_token   uuid,
    barrier_end_lsn pg_lsn,
    PRIMARY KEY (run_id, epoch_seq, edge_id),
    CONSTRAINT fence_edge_required CHECK (
        (fence_kind = 'barrier'        AND barrier_token IS NOT NULL AND barrier_end_lsn IS NOT NULL) OR
        (fence_kind = 'standby_replay' AND barrier_token IS NULL     AND barrier_end_lsn IS NOT NULL) OR
        (fence_kind = 'degraded')
    ),
    FOREIGN KEY (run_id, epoch_seq) REFERENCES pgl_validate.fence_epoch(run_id, epoch_seq) ON DELETE CASCADE,
    FOREIGN KEY (run_id, edge_id) REFERENCES pgl_validate.run_edge(run_id, edge_id) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.fence_attempt (
    run_id              bigint NOT NULL,
    epoch_seq           int NOT NULL,
    edge_id             int NOT NULL,
    barrier_end_lsn     pg_lsn,
    origin_progress_lsn pg_lsn,
    token_visible       boolean NOT NULL DEFAULT false,
    confirmed_flush_lsn pg_lsn,
    converged_at        timestamptz,
    status              text NOT NULL DEFAULT 'waiting'
                        CHECK (status IN ('waiting','converged','timeout','degraded')),
    CONSTRAINT fence_attempt_converged_truth CHECK (
        status <> 'converged'
        OR (barrier_end_lsn IS NOT NULL
            AND origin_progress_lsn IS NOT NULL
            AND origin_progress_lsn >= barrier_end_lsn
            AND token_visible)
    ),
    PRIMARY KEY (run_id, epoch_seq, edge_id),
    FOREIGN KEY (run_id, epoch_seq, edge_id)
        REFERENCES pgl_validate.fence_edge(run_id, epoch_seq, edge_id) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.fence_barrier (
    id          bigint GENERATED BY DEFAULT AS IDENTITY,
    token       uuid NOT NULL,
    injected_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX fence_barrier_token_idx ON pgl_validate.fence_barrier (token);

CREATE TABLE pgl_validate.fence_barrier_run (
    token           uuid NOT NULL,
    run_id          bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    epoch_seq       int NOT NULL,
    edge_id         int NOT NULL,
    origin_node     text NOT NULL,
    barrier_end_lsn pg_lsn,
    PRIMARY KEY (run_id, epoch_seq, edge_id),
    FOREIGN KEY (run_id, edge_id) REFERENCES pgl_validate.run_edge(run_id, edge_id) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.table_plan (
    run_id             bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    schema_name        text NOT NULL,
    table_name         text NOT NULL,
    key_cols           text[],
    att_list           text[],
    repsets            text[],
    repl_insert        boolean,
    repl_update        boolean,
    repl_delete        boolean,
    repl_truncate      boolean,
    has_row_filter     boolean NOT NULL DEFAULT false,
    sync_status        "char",
    validated_property text NOT NULL
                       CHECK (validated_property IN ('full','superset','keys_only',
                              'filtered_intersection','filtered_advisory','keyless',
                              'unsupported_mask','skipped')),
    PRIMARY KEY (run_id, schema_name, table_name)
);

CREATE TABLE pgl_validate.table_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    verdict     text NOT NULL CHECK (verdict IN
                ('match','differ','indeterminate','partial','approximate',
                 'degraded','skipped','error','fence_timeout')),
    reason      text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    PRIMARY KEY (run_id, schema_name, table_name),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.table_node_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    node        text NOT NULL,
    n_rows      bigint,
    lthash      bytea,
    set_hash    bytea,
    PRIMARY KEY (run_id, schema_name, table_name, node),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.chunk_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    chunk_id    bigint NOT NULL,
    parent_id   bigint,
    lo          bytea,
    hi          bytea,
    state       text NOT NULL CHECK (state IN
                ('pending','running','clean','split','divergent','candidate')),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, schema_name, table_name, chunk_id),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE
);

CREATE TABLE pgl_validate.chunk_node_result (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    chunk_id    bigint NOT NULL,
    node        text NOT NULL,
    n_rows      bigint,
    lthash      bytea,
    PRIMARY KEY (run_id, schema_name, table_name, chunk_id, node),
    FOREIGN KEY (run_id, schema_name, table_name, chunk_id)
        REFERENCES pgl_validate.chunk_result(run_id, schema_name, table_name, chunk_id)
        ON DELETE CASCADE
);

CREATE TABLE pgl_validate.divergence (
    run_id         bigint NOT NULL,
    schema_name    text NOT NULL,
    table_name     text NOT NULL,
    key_text       text NOT NULL,
    key_bytes      bytea NOT NULL,
    classification text NOT NULL CHECK (classification IN ('missing_on','extra_on','differs')),
    node           text NOT NULL,
    status         text NOT NULL DEFAULT 'candidate'
                   CHECK (status IN ('candidate','confirmed','cleared','indeterminate','advisory')),
    detected_epoch int NOT NULL,
    tuple          jsonb,
    detected_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, schema_name, table_name, key_bytes, node),
    FOREIGN KEY (run_id, schema_name, table_name)
        REFERENCES pgl_validate.table_plan(run_id, schema_name, table_name) ON DELETE CASCADE,
    FOREIGN KEY (run_id, detected_epoch)
        REFERENCES pgl_validate.fence_epoch(run_id, epoch_seq)
);

CREATE TABLE pgl_validate.divergence_recheck (
    run_id      bigint NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    key_bytes   bytea NOT NULL,
    node        text NOT NULL,
    epoch_seq   int NOT NULL,
    outcome     text NOT NULL CHECK (outcome IN ('still_differs','cleared','still_hot')),
    at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, schema_name, table_name, key_bytes, node, epoch_seq),
    FOREIGN KEY (run_id, schema_name, table_name, key_bytes, node)
        REFERENCES pgl_validate.divergence(run_id, schema_name, table_name, key_bytes, node)
        ON DELETE CASCADE
);

CREATE TABLE pgl_validate.conflict_evidence (
    run_id               bigint NOT NULL,
    schema_name          text NOT NULL,
    table_name           text NOT NULL,
    key_bytes            bytea NOT NULL,
    node                 text NOT NULL,
    source               text NOT NULL DEFAULT 'pglogical_conflict_history'
                         CHECK (source IN ('pglogical_conflict_history')),
    conflict_id          bigint NOT NULL,
    recorded_at          timestamptz NOT NULL,
    subscription_name    text,
    conflict_type        text NOT NULL,
    resolution           text NOT NULL,
    index_name           text,
    local_tuple          jsonb,
    local_xid            text,
    local_origin         integer,
    local_commit_ts      timestamptz,
    remote_tuple         jsonb,
    remote_origin        integer NOT NULL,
    remote_commit_ts     timestamptz NOT NULL,
    remote_commit_lsn    pg_lsn NOT NULL,
    has_before_triggers  boolean NOT NULL,
    matched_on           text[] NOT NULL DEFAULT ARRAY[]::text[],
    observed_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (
        run_id, schema_name, table_name, key_bytes, node,
        source, recorded_at, conflict_id
    ),
    FOREIGN KEY (run_id, schema_name, table_name, key_bytes, node)
        REFERENCES pgl_validate.divergence(run_id, schema_name, table_name, key_bytes, node)
        ON DELETE CASCADE
);

CREATE TABLE pgl_validate.sequence_result (
    run_id                bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    schema_name           text NOT NULL,
    seq_name              text NOT NULL,
    provider_node         text NOT NULL,
    provider_last_value   bigint,
    subscriber_node       text NOT NULL,
    subscriber_last_value bigint,
    cache_size            int,
    within_contract       boolean,
    verdict               text NOT NULL CHECK (verdict IN ('match','behind','ahead_of_window','error')),
    PRIMARY KEY (run_id, schema_name, seq_name, subscriber_node)
);

CREATE TABLE pgl_validate.schema_issue (
    run_id      bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    node        text NOT NULL,
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    issue_code  text NOT NULL,
    detail      text,
    PRIMARY KEY (run_id, node, schema_name, table_name, issue_code)
);

CREATE TABLE pgl_validate.schedule (
    name        text PRIMARY KEY,
    cron        text NOT NULL,
    tables      text[],
    repset      text,
    peers       text[],
    options     jsonb NOT NULL DEFAULT '{}',
    enabled     boolean NOT NULL DEFAULT true,
    last_run_id bigint REFERENCES pgl_validate.run(run_id) ON DELETE SET NULL
);

CREATE TABLE pgl_validate.worker_task (
    task_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    task_kind     text NOT NULL CHECK (task_kind IN ('compare')),
    request       jsonb NOT NULL,
    status        text NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','starting','running','paused','completed','failed','canceled')),
    launched_by   name NOT NULL DEFAULT current_user,
    database_name name NOT NULL DEFAULT current_database(),
    worker_pid    integer,
    enqueued_at   timestamptz NOT NULL DEFAULT now(),
    started_at    timestamptz,
    finished_at   timestamptz,
    error         text
);
CREATE INDEX worker_task_run_idx ON pgl_validate.worker_task (run_id);
CREATE INDEX worker_task_active_idx ON pgl_validate.worker_task (status, enqueued_at)
WHERE status IN ('queued','starting','running');

CREATE TABLE pgl_validate.repair_run (
    repair_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id         bigint NOT NULL REFERENCES pgl_validate.run(run_id) ON DELETE CASCADE,
    authoritative  text NOT NULL,
    target         text NOT NULL,
    propagation    text NOT NULL CHECK (propagation IN ('local_only','replicate')),
    paused_subs    text[],
    origin_name    text,
    status         text NOT NULL DEFAULT 'running'
                   CHECK (status IN ('running','applied','revalidated','failed','rolled_back')),
    launched_by    name NOT NULL DEFAULT current_user,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    error          text
);

CREATE TABLE pgl_validate.repair_result (
    repair_id      bigint NOT NULL REFERENCES pgl_validate.repair_run(repair_id) ON DELETE CASCADE,
    schema_name    text NOT NULL,
    table_name     text NOT NULL,
    key_bytes      bytea NOT NULL,
    action         text NOT NULL CHECK (action IN ('insert','update','delete','setval')),
    statement      text NOT NULL,
    post_verdict   text CHECK (post_verdict IN ('match','still_differs','indeterminate')),
    PRIMARY KEY (repair_id, schema_name, table_name, key_bytes, action)
);

CREATE OR REPLACE VIEW pgl_validate.runs AS
SELECT * FROM pgl_validate.run;

CREATE OR REPLACE VIEW pgl_validate.table_results AS
SELECT * FROM pgl_validate.table_result;

CREATE OR REPLACE VIEW pgl_validate.chunk_results AS
SELECT * FROM pgl_validate.chunk_result;

CREATE OR REPLACE VIEW pgl_validate.divergences AS
SELECT * FROM pgl_validate.divergence;

CREATE OR REPLACE VIEW pgl_validate.sequence_results AS
SELECT * FROM pgl_validate.sequence_result;

CREATE OR REPLACE VIEW pgl_validate.schema_issues AS
SELECT * FROM pgl_validate.schema_issue;

CREATE OR REPLACE VIEW pgl_validate.worker_tasks AS
SELECT * FROM pgl_validate.worker_task;

CREATE OR REPLACE VIEW pgl_validate.run_progress AS
WITH chunk_counts AS (
    SELECT
        cr.run_id,
        count(cr.*) FILTER (WHERE cr.state IN ('clean','divergent')) AS chunks_done,
        count(cr.*) FILTER (WHERE cr.state <> 'split') AS chunks_total
    FROM pgl_validate.chunk_result cr
    GROUP BY cr.run_id
),
chunk_scan AS (
    SELECT
        cnr.run_id,
        COALESCE(sum(cnr.n_rows), 0)::bigint AS rows_scanned
    FROM pgl_validate.chunk_node_result cnr
    GROUP BY cnr.run_id
),
table_progress AS (
    SELECT
        tnr.run_id,
        COALESCE(sum(tnr.n_rows), 0)::bigint AS rows_scanned
    FROM pgl_validate.table_node_result tnr
    GROUP BY tnr.run_id
),
run_digest_width AS (
    SELECT
        r.run_id,
        CASE COALESCE(r.options->>'hash_algorithm', 'blake3_256')
            WHEN 'blake3_512' THEN 64
            ELSE 32
        END::bigint AS digest_width
    FROM pgl_validate.run r
),
epoch_progress AS (
    SELECT
        fe.run_id,
        max(fe.epoch_seq) AS current_epoch
    FROM pgl_validate.fence_epoch fe
    GROUP BY fe.run_id
),
fence_progress AS (
    SELECT
        fa.run_id,
        bool_or(fa.status = 'waiting') AS has_waiting_fence
    FROM pgl_validate.fence_attempt fa
    GROUP BY fa.run_id
),
divergence_progress AS (
    SELECT
        d.run_id,
        bool_or(d.status = 'candidate') AS has_candidate_divergence
    FROM pgl_validate.divergence d
    GROUP BY d.run_id
)
SELECT
    r.run_id,
    r.status,
    CASE
        WHEN r.status IN ('completed','failed','canceled','paused') THEN r.status
        WHEN COALESCE(fp.has_waiting_fence, false) THEN 'fencing'
        WHEN COALESCE(dp.has_candidate_divergence, false) THEN 'rechecking'
        WHEN r.status = 'running' THEN 'running'
        ELSE r.status
    END AS phase,
    ep.current_epoch,
    COALESCE(cc.chunks_done, 0)::bigint AS chunks_done,
    COALESCE(cc.chunks_total, 0)::bigint AS chunks_total,
    (COALESCE(cs.rows_scanned, 0) + COALESCE(tp.rows_scanned, 0))::bigint AS rows_scanned,
    (
        (COALESCE(cs.rows_scanned, 0) + COALESCE(tp.rows_scanned, 0))
        * COALESCE(rdw.digest_width, 32)
    )::bigint AS bytes_scanned,
    CASE
        WHEN r.status IN ('completed','failed','canceled')
          OR r.started_at IS NULL
          OR COALESCE(cc.chunks_done, 0) <= 0
          OR COALESCE(cc.chunks_total, 0) <= COALESCE(cc.chunks_done, 0)
        THEN NULL::interval
        ELSE make_interval(secs => (
            extract(epoch FROM (clock_timestamp() - r.started_at))
            * (COALESCE(cc.chunks_total, 0) - COALESCE(cc.chunks_done, 0))::double precision
            / COALESCE(cc.chunks_done, 0)::double precision
        ))
    END AS eta,
    r.started_at,
    r.finished_at
FROM pgl_validate.run r
LEFT JOIN chunk_counts cc USING (run_id)
LEFT JOIN chunk_scan cs USING (run_id)
LEFT JOIN table_progress tp USING (run_id)
LEFT JOIN run_digest_width rdw USING (run_id)
LEFT JOIN epoch_progress ep USING (run_id)
LEFT JOIN fence_progress fp USING (run_id)
LEFT JOIN divergence_progress dp USING (run_id);
```

---

## Appendix B: Worked Examples

### B.1 Validate a replication set across subscribers, nightly

```sql
-- On a provider/coordinator (requires shared_preload_libraries='pgl_validate' for scheduling).
INSERT INTO pgl_validate.schedule(name, cron, repset, options)
VALUES ('nightly-default', '0 2 * * *', 'default',
        '{"throttle_max_lag":"30s","chunk_target_rows":100000}');
```

### B.2 One-off validation of specific tables against named peers

```sql
SELECT pgl_validate.compare(
    tables    => ARRAY['public.orders','public.order_items']::regclass[],
    peers     => ARRAY['node_beta','node_gamma'],
    reference => 'node_alpha'
);                                              -- e.g. run_id 4217

SELECT verdict, reason FROM pgl_validate.table_result WHERE run_id = 4217;
SELECT * FROM pgl_validate.divergences(4217) WHERE status = 'confirmed';
SELECT * FROM pgl_validate.sequences(4217) WHERE NOT within_contract;
```

### B.3 CI gate (synchronous)

```sql
-- verdict ∈ match | differ | indeterminate | partial | approximate | degraded | skipped | error
-- A strict CI gate should require exactly 'match' and fail on anything else (a 'degraded' or
-- 'approximate' result means the comparison was not exact — see the validation-strength matrix).
SELECT (pgl_validate.compare_table('public.accounts')).verdict = 'match' AS in_sync;
```

### B.4 Inspect the planner-transparent SQL the engine will run

```sql
SELECT pgl_validate.plan_chunk_sql('public.orders', ARRAY['id'],
       lo => NULL, hi => NULL, cols => ARRAY['id','amount','status']);
-- => SELECT count(*), pgl_validate.lthash(
--           pgl_validate.row_digest('{2,1,1}'::int[], t."amount", t."id", t."status"))
--    FROM public.orders t WHERE true;
-- Note: enc[] is first; columns follow as VARIADIC "any" args sorted by name, never an ARRAY[...].
-- EXPLAIN that statement on any node to see the index/parallel plan.
```

### B.5 Origin-aware repair from the authoritative node

```sql
SELECT pgl_validate.generate_repair(4217, authoritative => 'node_alpha');   -- review first
-- Default local_only: relies on downstream forward_origins={} not re-forwarding the tagged
-- origin; downstream {all} subscriptions are refused before DML (§18.2).
SELECT pgl_validate.apply_repair(4217, authoritative => 'node_alpha',
                                 target => 'node_beta', confirm => 'node_beta',
                                 propagation => 'local_only');
```

---

## Appendix C: Row Digest and Set-Hash Specification

```
# Per-column canonical encoding (resolved at plan time, pinned for the run):
fn encode(col_type, value, opts) -> bytes:
    if value IS NULL: return                      # caller writes the 0x00 null tag instead
    if col_type == json and not opts.json_normalize: return text_out(value)   # exact
    if col_type == json and opts.json_normalize:    value := jsonb(value)
    if col_type in {float4,float8}:
        if value == -0.0 and not opts.signed_zero_distinct: value := 0.0
        if is_nan(value) and not opts.nan_distinct:         value := CANONICAL_NAN
    if has_stable_send(col_type, participant_versions): return typsend(col_type, value)
    if has_stable_text(col_type): return text_out_with_pinned_gucs(col_type, value)
    raise PreconditionError(UNSTABLE_TYPE, col_type)

# Row digest (256-bit). Args arrive ALREADY name-sorted from the generated SQL, positionally
# aligned with enc[]; row_digest hashes in arg order (it does NOT sort -- raw fcinfo cannot).
fn row_digest(enc: int[], cols: any[]) -> [u8;N]:    # cols is the VARIADIC "any" tail
    h := blake3()
    for i, c in enumerate(cols):                      # in the order received
        if c.value IS NULL: h.update([0x00])
        else:
            b := encode(c.type, c.value, mode = enc[i])
            h.update([0x01]); h.update(u32_le(len(b))); h.update(b)
    return h.finalize()[0..N]                         # blake3_256 => N=32; blake3_512 => N=64

# Chunk accumulator (LtHash; additive, parallel-safe, collision-resistant):
fn lthash_add(state[n], rd) :                     # n lanes of b bits, default n=1024,b=16
    lanes := blake3_xof(rd, n*b/8)                # expand row digest to n lanes
    for i in 0..n: state[i] := (state[i] + lane(lanes,i)) mod 2^b
fn lthash_combine(a,b): for i in 0..n: a[i] := (a[i]+b[i]) mod 2^b
# Two chunks equal on the fast path => multisets equal except w.p. <= LtHash bound; plus an independent count.

# Cryptographic confirmation for a localized (small) chunk.
# In SQL: pgl_validate.hash_digest_array(array_agg(rd ORDER BY rd))  -- ordering by the caller.
fn hash_digest_array(sorted_row_digests: bytea[]) -> [u8;N]:         # plain function, NOT an aggregate
    return blake3(concat(sorted_row_digests))    # equal IFF multisets equal, except w.p. ~= 2^-128
                                                 #   (256-bit hash => ~128-bit birthday bound;
                                                 #    blake3_512 => ~2^-256)
```

# Digest-stability confirmation (the §8.4 soundness core; uses only convergence + re-reads):
#   sample_A[node][k] := row_digest(k) at the bulk read
#   converge all edges to a fresh epoch E1 injected AFTER sample_A
#   sample_B[node][k] := row_digest(k) after convergence to E1
#   confirmed := (nodes still differ at k) AND (for all nodes: sample_A == sample_B)
#   cleared   := nodes now agree;   still_hot := some node's digest changed A->B (retry/indeterminate)

**Properties proven in the test suite:** order independence (any permutation ⇒ identical LtHash and `hash_digest_array`); duplicate sensitivity (an extra copy changes `count` and LtHash — XOR would not); GUC/locale independence; parallel-worker equivalence; the stated collision bounds (LtHash SIS ≥ 128-bit; `hash_digest_array` ≈ 2⁻¹²⁸ at 256-bit, ≈ 2⁻²⁵⁶ at 512-bit); and the §8.4 digest-stability confirmation soundness (a confirmed candidate cannot be a lag artifact).

---

*End of design document.*
