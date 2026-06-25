# Hats Simulator — Comprehensive Specification

Authors: Paul Cohen (2003), Clayton T. Morrison (2004)  
Contributors: Joshua Moody, Andrew Hannon, Gary King, David Westbrook  
Implementation: Common Lisp (MCL, OpenMCL, SBCL, Franz Allegro)  
Contact: `claytonm@email.arizona.edu`

---

## 1. Purpose and Design Philosophy

Hats is a lightweight proxy for intelligence analysis problems. It provides a test environment for analysts (human or automated) to practice detecting harmful agents before they carry out plans in a world with partial, noisy, and expensive information.

The simulator is:
- **Tick-based**: discrete time steps, each generating a new batch of events
- **Generative**: a planner continuously invents new activities—no fixed scenario script
- **Multi-agent**: hundreds to hundreds of thousands of agents with heterogeneous roles
- **Information-asymmetric**: ground truth is hidden; analysts pay for information, which arrives with noise

---

## 2. Domain Ontology

### 2.1 World

- 2D integer grid with `(x-min, x-max) × (y-min, y-max)` bounds
- Each cell identified by `(x, y)` coordinates
- Simulation advances in discrete **ticks**

### 2.2 Capabilities

Atomic tokens representing attributes. Shared vocabulary between hats (who carry them) and beacons (which declare vulnerabilities). Capabilities are pure tokens—no internal structure.

### 2.3 Beacons

Locations of interest.

| Attribute | Description |
|-----------|-------------|
| `beacon-id` | Unique identifier |
| `(x, y)` | Fixed location in grid |
| `vulnerabilities` | Set of capability tokens |
| `alert-level` | `:OFF`, `:LEVEL-ONE`, `:LEVEL-TWO` |

A beacon is **attacked** when all four conditions hold simultaneously:
1. A meeting occurs at the beacon's location
2. That meeting is the **final planned meeting** of a terrorist taskforce
3. Combined capabilities of hats present at the meeting **match** the beacon's vulnerabilities
4. The taskforce belongs to a **terrorist organization**

### 2.4 Hats (Agents)

Each hat has:

| Attribute | Visibility | Description |
|-----------|-----------|-------------|
| `hat-id` | Public | Unique identifier |
| `advertised-color` | Public | `:TERRORIST`, `:UNKNOWN` |
| `true-color` | Hidden | `:TERRORIST`, `:COVERT-TERRORIST`, `:BENIGN` |
| `capabilities` | Paid | Current set of carried capability tokens |
| `location` | Paid | Current `(x, y)` position |

- Hats occupy exactly one location per tick
- Capabilities can change over time through trading at meetings
- `advertised-color` is observable; `true-color` must be inferred
- `COVERT-TERRORIST`: true terrorist whose advertised color is `:UNKNOWN`

### 2.5 Organizations

Sets of hats. Memberships are fixed at initialization and do not change.

| Type | Composition | Behavior |
|------|-------------|----------|
| Benign | May include terrorists, covert-terrorists, benign | Does not attack beacons |
| Terrorist | Only terrorists and covert-terrorists | Plans and executes beacon attacks |

Each hat belongs to **at least one** organization; multiple memberships allowed.

### 2.6 Taskforces

A taskforce is a subset of hats drawn from a single organization, tasked with delivering capabilities to a target destination.

- Selected **periodically** by the organization's planner
- Has a **target location** (may be a beacon)
- Executes via a planned **series of meetings** to assemble required capabilities
- Non-member organization hats may be recruited as capability sources during meetings
- Disbanded when the final meeting at the target completes
- Terrorist taskforces are the attack mechanism; benign taskforces exist as cover activity

### 2.7 Meetings

- Occur among one or more hats at any grid location
- Capabilities are traded between participants
- Tracked by tick and `(x, y)` location
- Trades serve taskforce capability-gathering goals
- A meeting at a beacon that is a terrorist taskforce's final meeting may trigger an attack (see §2.3)

---

## 3. Population Generation

Parameters controlling world population (from WSC 2004 paper):

| Parameter | Description |
|-----------|-------------|
| `N-hats` | Total number of hats |
| `N-benign-orgs` | Number of benign organizations |
| `N-terrorist-orgs` | Number of terrorist organizations |
| `org-size-mean / std` | Organization membership distribution |
| `capability-overlap` | Degree of capability sharing across organizations |
| `fraction-covert` | Fraction of terrorists that are covert |
| `grid-size` | World dimensions |

Population generator uses **overlap parameters** to control how much hat membership and capabilities cluster—higher overlap makes terrorist hats harder to distinguish from benign ones. This is the primary difficulty knob for the challenge problem.

---

## 4. Meeting Planner (Generative Planner)

The planner generates meeting trees—hierarchical structures that decompose a taskforce goal into a sequence of meetings.

### 4.1 Meeting Tree Structure

```
Taskforce goal: deliver {cap-A, cap-B, cap-C} to target T
└── Final meeting at T (tick t_n)
    ├── Pre-meeting at loc_2 (tick t_{n-1})
    │   ├── Sub-meeting at loc_1a (tick t_{n-2})
    │   └── Sub-meeting at loc_1b (tick t_{n-2})
    └── Pre-meeting at loc_3 (tick t_{n-1})
```

- Leaves are initial capability-gathering meetings
- Internal nodes assemble capabilities from children
- Root is the target meeting
- Meeting times are scheduled such that hats can travel from one meeting to the next within the tick budget

### 4.2 Planner Properties

- **Generative**: new taskforces and meeting trees are created continuously throughout simulation
- **Concurrent**: multiple taskforces from multiple organizations active simultaneously
- Both terrorist and benign organizations run the same planner—creating noise for analysts
- Planner ensures capabilities are routable (hats exist that carry required capabilities)

---

## 5. Information Broker (IB)

The IB is the sole interface between analyst and simulator state. Information falls into two categories.

### 5.1 Free Information

Always available at zero cost:

| Function | Returns |
|----------|---------|
| `(ib-world-dimensions)` | `((:x xmin xmax) (:y ymin ymax))` |
| `(ib-beacons)` | All beacons with alert status, location, vulnerabilities |
| `(ib-all-capabilities)` | All capability tokens in the world |
| `(ib-benign-organizations)` | List of benign org IDs |
| `(ib-terrorist-organizations)` | List of **some** terrorist org IDs (partial) |
| `(ib-known-terrorist-hats)` | List of **some** known terrorist hat IDs (partial) |
| `(ib-members :organization org-id)` | Hat IDs in given organization |
| `(ib-hat-advertised-color :hat-id id)` | `:TERRORIST`, `:UNKNOWN`, or `:NOT-A-KNOWN-HAT` |
| `(ib-events-history)` | Chronological list of world events (attacks, saves) |
| `(ib-clear-events-history)` | Clears events history |
| `(ib-arrested-hats)` | Currently arrested hat IDs |

Note: `ib-terrorist-organizations` and `ib-known-terrorist-hats` return **partial** information—not all terrorist entities are revealed.

### 5.2 Paid Information

Require `PAYMENT` argument; cost deducted from score:

| Function | Arguments | Returns |
|----------|-----------|---------|
| `(ib-last-location :hat-id id :payment p)` | hat-id, payment | Last known `(x y)` of hat |
| `(ib-capabilities :hat-id id :payment p)` | hat-id, payment | Current capability list |
| `(ib-meeting-times :hat-id id :payment p)` | hat-id, payment | List of ticks hat was in a meeting |
| `(ib-meeting-location :hat-id id :tick t :payment p)` | hat-id, tick, payment | `(x y)` of meeting at tick, or NIL |
| `(ib-meeting-participants :tick t :x-location x :y-location y :payment p)` | tick, location, payment | Hat IDs at that meeting |
| `(ib-meeting-trades :tick t :x-location x :y-location y :payment p)` | tick, location, payment | `(source-hat-id recipient-hat-id capability-id)` triples |

### 5.3 Noise Model

Paid IB responses are subject to noise. From the WSC 2004 paper:

**Payment probability formula:**

```
P(receive information | payment p) = 1 - e^(-λ·p)
```

where `λ` is a per-query noise parameter. Higher payment = higher probability of receiving correct information.

**Noise table** (approximate, from paper):

| Payment level | P(correct response) |
|---------------|---------------------|
| Low | ~0.50 |
| Medium | ~0.75 |
| High | ~0.95 |
| Very High | ~0.99 |

Even with high payment, responses may be:
- **Missing**: no information returned (IB returns NIL)
- **Noisy**: incorrect value returned (wrong location, wrong capabilities)
- **Delayed**: information from a prior tick

Analysts must account for noise in their inference models.

### 5.4 Default Request Manager

IB requests can be scheduled to run automatically each tick:

| Function | Description |
|----------|-------------|
| `(ib-add-default-requests request-list)` | Schedule requests to run each tick |
| `(ib-remove-default-requests request-list)` | Remove scheduled requests |
| `(ib-clear-default-requests)` | Clear all scheduled requests |
| `(ib-list-default-requests)` | Return scheduled request list |

`hats-advance` returns default request results as first return value.

---

## 6. Player Actions

### 6.1 Arrest

```lisp
(action-arrest-hat :hat-id id :x-location x :y-location y)
```

**Successful arrest** requires all three:
- (a) hat is currently at `(x, y)`
- (b) hat's true color is `:TERRORIST`
- (c) hat is currently part of an active terrorist taskforce

**On success**: hat added to arrest list; remains mobile and attends meetings but its capabilities cannot contribute to a beacon attack. Removed from arrest list when its taskforce's final meeting occurs.

**On failure**: hat immediately released; counts as a **false arrest** in scoring.

Key semantic: a terrorist not currently in a taskforce **cannot** be successfully arrested. Being a terrorist is a propensity, not a continuous crime. Prior attacks do not make an arrested hat a successful arrest.

### 6.2 Beacon Alert

```lisp
(action-alert-beacon :beacon-id id :alert-level level)
```

| Level | Interpretation | Score Impact on Attack | Cost |
|-------|---------------|------------------------|------|
| `:OFF` | No alert | Full penalty | Free |
| `:LEVEL-ONE` | Attack likely | Half penalty | — |
| `:LEVEL-TWO` | Attack imminent | No penalty | — |

Alert tracking stats:
- **Hits**: attack occurred while alert was elevated
- **False positives**: alert began and ended with no attack

Goal: minimize time alerts are elevated while maximizing hits. Level-2 is more costly when false-positive but more rewarding when a hit.

---

## 7. Simulator Controls

```lisp
(hats-initialize &key parameter-manager use-viewer?)
```
Initializes a new run. `parameter-manager` controls world generation parameters.

```lisp
(hats-advance &key number-of-ticks time-it)
```
Advances simulation by `number-of-ticks` (default 1). Returns `(default-request-results)`.

```lisp
(hats-end)
```
Terminates run and writes data to file.

---

## 8. Scoring

Three independent scoring dimensions:

### 8.1 Information Cost
Sum of all payments made to the IB over the game. Minimizing this (while still gathering useful intelligence) is a performance objective.

### 8.2 False Arrests
Count of failed arrest actions. Each false arrest penalizes the analyst. Arresting known terrorists not in a taskforce counts as false.

### 8.3 Beacon Hits / Misses
- **Hit**: beacon attacked while alert was elevated → reduced or zero score penalty
- **Miss**: beacon attacked while alert was `:OFF` → full score penalty
- **False positive**: alert elevated but no attack occurred

Scores are currently **reported separately** and not collapsed into a single utility function—they serve as comparative metrics across analyst strategies.

---

## 9. Administrative Services

```lisp
(services &key services name args docs list)
```
Lists all IB functions and documentation. Filter by service type:
- `services` — administrative
- `simulator-controls`
- `player-actions`
- `ib-request-manager`
- `ib-requests` / `ib-requests-free` / `ib-requests-paid`

```lisp
(service-names)
```
Returns list of all service function names.

---

## 10. COLAB Integration

COLAB (Collaborative Analysis Environment) is a separate system that provides AI-assisted analysis tools layered on top of Hats. Architecture described in Morrison & Cohen ~2005 paper.

### 10.1 Blackboard Architecture

Implemented with **GBBopen** (Generic Blackboard framework in Common Lisp).

- **Blackboard**: shared workspace where knowledge sources read/write hypotheses
- **Knowledge Sources (KS)**: agents that react to blackboard events and post new hypotheses
- **Trellis**: hypothesis management tool embedded in COLAB that tracks belief states about hat identities

### 10.2 COLAB Knowledge Sources

| KS Agent | Role |
|----------|------|
| IB-KS | Queries Hats IB; posts raw observations to blackboard |
| Location-KS | Tracks hat positions; infers movement patterns |
| Meeting-KS | Detects meetings; builds meeting graphs |
| Organization-KS | Maintains org membership hypotheses |
| Taskforce-KS | Infers taskforce activity from meeting patterns |
| Threat-KS | Aggregates evidence; generates threat assessments |
| Alert-KS | Issues beacon alerts based on threat assessments |
| Arrest-KS | Triggers arrest actions on high-confidence terrorists |

### 10.3 Trellis Hypothesis Tool

Trellis maintains a lattice of hypotheses about hat identity (benign vs. terrorist) and taskforce membership. Evidence from COLAB KS agents propagates through the lattice as belief updates.

### 10.4 SQL Subset Query Language

COLAB provides a domain-specific query language (SQL subset) for analyst and KS agent queries over the blackboard. Supports:
- SELECT-style projection over hat/meeting/capability facts
- WHERE filtering with conjunctive predicates
- JOIN-like cross-entity queries (e.g., "find all meetings involving known-terrorist hats at beacon locations")

---

## 11. Scale and Performance

From Morrison et al. IPAM 2007 slides:

| Configuration | Hats | Performance |
|---------------|------|-------------|
| Small | ~1,000 | Interactive |
| Medium | ~10,000 | Real-time |
| Large | ~100,000 | Batch |
| Very Large | ~500,000 | Batch / cluster |

- Implemented in Common Lisp; tested with SBCL, MCL, OpenMCL, Franz Allegro
- GBBopen blackboard scales to multi-agent scenarios
- ATAT (Automated Threat Assessment Tool) is a reference automated analyst built on COLAB

---

## 12. ATAT — Reference Automated Analyst

ATAT (Automated Threat Assessment Tool) is the reference implementation of a Hats player built on COLAB.

- Uses COLAB KS agents for all perception and inference
- Trellis tracks belief state over hat identities
- Issues alerts and arrests autonomously
- Serves as baseline for evaluating novel analyst algorithms

---

## 13. Implementation Notes

- All functions are Common Lisp symbols; call with `()` syntax
- All IB functions return Lisp lists; `NIL` = no information
- `PAYMENT` argument is a positive number (domain unspecified; relative scale matters)
- Default requests are evaluated at every `hats-advance` call
- Simulator state is global; one active simulation per Lisp process
- Source code available from Clayton Morrison (`claytonm@email.arizona.edu`)

---

## 14. Quick Reference Card

```lisp
;; Setup
(hats-initialize)
(hats-advance :number-of-ticks 10)
(hats-end)

;; Free queries
(ib-world-dimensions)
(ib-beacons)
(ib-all-capabilities)
(ib-benign-organizations)
(ib-terrorist-organizations)
(ib-known-terrorist-hats)
(ib-members :organization org-id)
(ib-hat-advertised-color :hat-id hat-id)
(ib-events-history)
(ib-arrested-hats)

;; Paid queries
(ib-last-location :hat-id hat-id :payment p)
(ib-capabilities :hat-id hat-id :payment p)
(ib-meeting-times :hat-id hat-id :payment p)
(ib-meeting-location :hat-id hat-id :tick t :payment p)
(ib-meeting-participants :tick t :x-location x :y-location y :payment p)
(ib-meeting-trades :tick t :x-location x :y-location y :payment p)

;; Actions
(action-arrest-hat :hat-id hat-id :x-location x :y-location y)
(action-alert-beacon :beacon-id beacon-id :alert-level :LEVEL-TWO)

;; Default request scheduling
(ib-add-default-requests '((ib-events-history) (ib-arrested-hats)))
(ib-clear-default-requests)
```

---

## Sources

- `ingest/README.md` — Hats Simulator Manual (Morrison, 2004)
- `ingest/hats-simulator-wsc2004-cohen-morrison.pdf` — Cohen & Morrison, "The Hats Simulator", WSC 2004
- `ingest/hats-simulator-colab-integrated-analysis-environment.pdf` — Morrison & Cohen, "The Hats Simulator and COLAB", ~2005
- `ingest/hats-simulator-ipam2007-large-scale-multiagent-simulation.pdf` — Morrison et al., IPAM 2007 slides
