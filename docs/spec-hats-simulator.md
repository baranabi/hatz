# Hats Simulator — Language-Agnostic Specification

Version: 1.0  
Source: Cohen & Morrison (WSC 2004), Morrison & Cohen (~2005), Morrison et al. (IPAM 2007), Hats Manual (Morrison 2004)

---

## 1. Overview

The Hats Simulator is a discrete-time, 2D grid-world multi-agent simulation for intelligence analysis. Agents pursue goals through a generative planner. A defender (human or automated) observes the world through a paid, noisy information interface and takes defensive actions. The simulator measures defender performance across information cost, false arrests, and beacon alert effectiveness.

**Core invariants:**
- Ground truth is never directly observable by the defender
- All information has a cost or is deliberately incomplete
- The same seed and parameters always produce the same simulation trajectory (deterministic)

---

## 2. World

### 2.1 Grid

- Bounded 2D integer coordinate space
- Defined by `(x_min, x_max)` and `(y_min, y_max)`
- Each cell identified by integer pair `(x, y)`
- No topology (no wrapping, no adjacency constraints beyond Euclidean distance)

### 2.2 Time

- Advances in discrete **ticks** (non-negative integers starting at 0)
- Each tick: hats move, meetings execute, planner may generate new taskforces
- Tick is the universal timestamp for all events and IB queries

---

## 3. Entities

### 3.1 Capability

An atomic token drawn from a finite, globally-known set. Capabilities have no internal structure; equality is identity. They serve as the matching vocabulary between hats (who carry them) and beacons (which require them).

### 3.2 Beacon

A fixed target location.

| Field | Type | Mutability | Description |
|-------|------|-----------|-------------|
| `id` | opaque ID | immutable | Unique identifier |
| `location` | `(x, y)` | immutable | Fixed grid position |
| `vulnerabilities` | set of capability IDs | immutable | Capabilities required to attack this beacon |
| `alert_level` | enum | mutable by defender | Current alert state |

**Alert levels** (ordered):

| Value | Meaning |
|-------|---------|
| `OFF` | No elevated alert |
| `LEVEL_ONE` | Low-level threat indication |
| `LEVEL_TWO` | High-level threat indication |

Default alert level: `OFF`.

### 3.3 Hat (Agent)

A mobile agent.

| Field | Type | Visibility | Description |
|-------|------|-----------|-------------|
| `id` | opaque ID | public | Unique identifier |
| `advertised_color` | enum | public | Self-reported affiliation |
| `true_color` | enum | hidden | Actual affiliation |
| `capabilities` | set of capability IDs | paid | Currently carried capabilities |
| `location` | `(x, y)` | paid | Current grid position |

**Advertised color values:**

| Value | Meaning |
|-------|---------|
| `TERRORIST` | Hat presents itself as a known terrorist |
| `UNKNOWN` | Hat's affiliation is not advertised |

**True color values:**

| Value | Meaning |
|-------|---------|
| `BENIGN` | Not a terrorist; will never attack |
| `TERRORIST` | Terrorist; advertised as such |
| `COVERT_TERRORIST` | Terrorist; advertised as `UNKNOWN` |

Rules:
- Each hat occupies exactly one cell per tick
- Capabilities are a dynamic set; they change as trades occur at meetings
- `advertised_color` is stable; `true_color` is immutable after initialization
- A hat is detectable as `COVERT_TERRORIST` only through inference, never through free IB queries

### 3.4 Organization

A named group of hats.

| Field | Type | Mutability | Description |
|-------|------|-----------|-------------|
| `id` | opaque ID | immutable | Unique identifier |
| `type` | enum | immutable | `BENIGN` or `TERRORIST` |
| `members` | set of hat IDs | immutable | Fixed at initialization |

Rules:
- Every hat belongs to at least one organization
- A hat may belong to multiple organizations
- Membership does not change after initialization
- **Benign organizations** may contain terrorists and covert-terrorists as members but do not execute attacks
- **Terrorist organizations** contain only terrorists and covert-terrorists

### 3.5 Taskforce

A temporary operational unit.

| Field | Type | Description |
|-------|------|-------------|
| `id` | opaque ID | Unique identifier |
| `organization_id` | org ID | Parent organization |
| `members` | set of hat IDs | Subset of parent org's members |
| `target` | `(x, y)` | Destination (may be a beacon location) |
| `required_capabilities` | set of capability IDs | Capabilities needed at target |
| `meeting_plan` | meeting tree | Scheduled sequence of meetings |
| `status` | enum | `ACTIVE`, `DISBANDED` |

Rules:
- Taskforces are created periodically by the organization's planner throughout the run
- A hat may be a member of at most one taskforce at a time (per the arrest semantics)
- Non-member hats from the same organization may participate in meetings as capability sources
- A taskforce is disbanded when its final meeting completes
- Both benign and terrorist organizations create taskforces; benign taskforces are indistinguishable from terrorist ones without ground-truth access

---

## 4. Meeting

A meeting is an event at a specific tick and location involving one or more hats.

| Field | Type | Description |
|-------|------|-------------|
| `tick` | integer | When the meeting occurred |
| `location` | `(x, y)` | Where the meeting occurred |
| `participants` | list of hat IDs | Hats present |
| `trades` | list of `(source_hat_id, recipient_hat_id, capability_id)` | Capability transfers |

Rules:
- Any grid location is a valid meeting location
- Multiple meetings may occur at different locations on the same tick
- Capability trades are atomic: capability moves from source to recipient
- Meetings are the sole mechanism for capability transfer between hats
- Meetings are observable (with payment) after they occur; they are not announced in advance

---

## 5. Beacon Attack Condition

A beacon is attacked when **all four** of the following hold at the same tick:

1. A meeting occurs **at the beacon's location**
2. The meeting is the **final planned meeting** of a taskforce
3. The taskforce belongs to a **terrorist organization**
4. The **combined capabilities** of hats present at the meeting are a **superset** of the beacon's `vulnerabilities`

An attack is recorded as an event in the world event log.

---

## 6. Meeting Planner (Generative Planner)

### 6.1 Responsibility

For each organization, the planner periodically generates new taskforces and their meeting trees. The planner runs continuously; there is no fixed scenario.

### 6.2 Meeting Tree

A meeting tree is a directed rooted tree where:
- **Root** = final meeting at the taskforce's target
- **Internal nodes** = intermediate assembly meetings
- **Leaves** = initial capability-acquisition meetings
- **Edges** indicate hat travel and capability flow (children deliver to parent)

Meeting times are scheduled so that hats can physically travel between consecutive meetings given the grid distances.

### 6.3 Properties

- Both benign and terrorist organizations use the same planner mechanism
- Multiple taskforces from multiple organizations are active concurrently
- The planner guarantees feasibility: required capabilities exist among accessible hats

---

## 7. Population Generation

Parameters that shape a simulation run:

| Parameter | Description |
|-----------|-------------|
| `n_hats` | Total hats in world |
| `n_benign_orgs` | Number of benign organizations |
| `n_terrorist_orgs` | Number of terrorist organizations |
| `org_size_distribution` | Mean and std of org membership size |
| `capability_overlap` | Degree of capability sharing across orgs (difficulty knob) |
| `fraction_covert` | Fraction of terrorists that are covert |
| `grid_dimensions` | `(width, height)` of the grid |
| `seed` | Random seed for deterministic replay |

Higher `capability_overlap` → terrorist hats harder to distinguish → higher analyst difficulty.

---

## 8. Simulator Lifecycle

```
initialize(params, seed)
  → world is generated; hats, beacons, orgs created; planner initialized

loop:
  advance(n_ticks)
    → for each tick:
        1. planner may generate new taskforces
        2. hats move toward scheduled meetings
        3. scheduled meetings execute (trades recorded)
        4. beacon attack condition evaluated for each meeting
        5. default IB requests execute (if any scheduled)
        6. events appended to history

end()
  → simulation terminates; final report produced
```

A simulation run is isolated. Advancing is the only way time moves.

---

## 9. Player Actions

### 9.1 Arrest Hat

Attempt to arrest a hat at a specified location.

**Input:**
- `hat_id`: the hat to arrest
- `location`: `(x, y)` where the arrest is attempted

**Success condition** — all three must hold:
1. Hat is currently at `location`
2. Hat's `true_color` is `TERRORIST` or `COVERT_TERRORIST`
3. Hat is currently a member of an **active terrorist taskforce**

**On success:**
- Hat is added to the **arrest list**
- Hat continues moving and attending meetings normally
- Hat's capabilities are **excluded** from beacon attack evaluation for its current taskforce
- Hat is removed from arrest list when its taskforce's final meeting completes

**On failure:**
- Hat is immediately released
- Recorded as a **false arrest** in scoring
- Does not affect the hat's behavior

**Semantic note:** A terrorist hat not currently in a taskforce cannot be successfully arrested. Membership in an active terrorist taskforce is a necessary condition, not merely being a terrorist. A hat that previously participated in an attack but is not currently in a taskforce produces a false arrest.

### 9.2 Set Beacon Alert

Set the alert level for a beacon.

**Input:**
- `beacon_id`
- `alert_level`: `OFF`, `LEVEL_ONE`, or `LEVEL_TWO`

**Effect on scoring when an attack occurs:**

| Alert Level | Score Impact |
|-------------|-------------|
| `OFF` | Full attack penalty applied |
| `LEVEL_ONE` | Half attack penalty applied |
| `LEVEL_TWO` | No attack penalty applied |

**False positive:** an alert period that begins and ends without an attack occurring.

Goal: maximize hits (attack occurred while alert elevated) while minimizing false-positive duration and false arrests.

---

## 10. Scoring

Three independent dimensions reported at run end:

### 10.1 Information Cost
Total cumulative payment made to the IB across all paid queries. Objective: minimize.

### 10.2 False Arrests
Count of failed arrest actions. Objective: minimize.

### 10.3 Beacon Alert Effectiveness

Per beacon, tracked separately for LEVEL_ONE and LEVEL_TWO:

| Metric | Definition |
|--------|-----------|
| `hits` | Count of attacks that occurred while alert was elevated |
| `false_positives` | Count of alert intervals that ended with no attack |

Scores are reported as separate dimensions, not collapsed to a single number.

---

## 11. Determinism

Given the same `seed` and `parameters`, identical sequences of `advance()` calls and player actions produce identical simulation outcomes. This enables:
- Reproducible experiments
- Contract-level fixture testing
- Replay and post-hoc analysis
