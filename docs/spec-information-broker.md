# Information Broker — Language-Agnostic Specification

Version: 1.0  
Source: Cohen & Morrison (WSC 2004), Morrison & Cohen (~2005), Hats Manual (Morrison 2004)

---

## 1. Overview

The Information Broker (IB) is the **sole interface** between a defender and the simulator's internal state. The defender cannot observe the world directly; all knowledge must be obtained through IB queries or inferred from prior query results.

The IB provides two classes of queries:
- **Free queries**: always succeed; return perfect or deliberately partial information
- **Paid queries**: require a payment parameter; return noisy information with probability determined by payment amount

The IB also provides a **default request scheduler** that automatically re-executes a set of queries each tick.

---

## 2. Data Types

| Type | Description |
|------|-------------|
| `HatId` | Opaque identifier for a hat |
| `BeaconId` | Opaque identifier for a beacon |
| `OrgId` | Opaque identifier for an organization |
| `CapabilityId` | Opaque identifier for a capability token |
| `Location` | Integer pair `(x, y)` |
| `Tick` | Non-negative integer |
| `Payment` | Positive number; scale is relative |
| `AlertLevel` | Enum: `OFF`, `LEVEL_ONE`, `LEVEL_TWO` |
| `AdvertisedColor` | Enum: `TERRORIST`, `UNKNOWN`, `NOT_A_KNOWN_HAT` |
| `Trade` | Tuple `(source_hat_id, recipient_hat_id, capability_id)` |

`null` / `nil` / `None` (language-appropriate): no information available for this query.

---

## 3. Free Queries

Free queries have **no payment parameter** and always return a result. Some return deliberately incomplete information (marked below).

---

### 3.1 `get_world_dimensions`

Returns the grid bounds.

**Input:** none  
**Output:**
```
{
  x: { min: integer, max: integer },
  y: { min: integer, max: integer }
}
```

---

### 3.2 `get_beacons`

Returns all beacons with full state. Perfect information.

**Input:** none  
**Output:** list of
```
{
  id: BeaconId,
  location: Location,
  vulnerabilities: [CapabilityId],
  alert_level: AlertLevel
}
```

---

### 3.3 `get_all_capabilities`

Returns the complete set of capability tokens that exist in the world. Perfect information.

**Input:** none  
**Output:** `[CapabilityId]`

---

### 3.4 `get_benign_organizations`

Returns IDs of all benign organizations. Perfect information.

**Input:** none  
**Output:** `[OrgId]`

---

### 3.5 `get_terrorist_organizations`

Returns IDs of **some** terrorist organizations. **Partial** — not all terrorist orgs are revealed.

**Input:** none  
**Output:** `[OrgId]`

---

### 3.6 `get_known_terrorist_hats`

Returns IDs of **some** known terrorist hats. **Partial** — not all terrorists are revealed; covert terrorists are not included.

**Input:** none  
**Output:** `[HatId]`

---

### 3.7 `get_organization_members`

Returns all hat IDs in a given organization.

**Input:** `org_id: OrgId`  
**Output:** `[HatId]`

---

### 3.8 `get_hat_advertised_color`

Returns the advertised color of a hat.

**Input:** `hat_id: HatId`  
**Output:** `AdvertisedColor`

- `TERRORIST`: hat advertises itself as terrorist
- `UNKNOWN`: hat's affiliation is not advertised
- `NOT_A_KNOWN_HAT`: `hat_id` does not refer to any known hat

---

### 3.9 `get_events_history`

Returns all world events in chronological order (beacon attacks, beacon saves, etc.).

**Input:** none  
**Output:** list of event records (structure is implementation-defined; must include tick, event type, and relevant entity IDs)

---

### 3.10 `clear_events_history`

Clears the event log. Future calls to `get_events_history` will only return events after the clear point.

**Input:** none  
**Output:** none

---

### 3.11 `get_arrested_hats`

Returns IDs of hats currently on the arrest list.

**Input:** none  
**Output:** `[HatId]`

---

## 4. Paid Queries

Paid queries require a `payment` parameter (positive number). Higher payment yields higher probability of receiving correct information. All paid queries may return `null` or a noisy value.

See §5 for the noise model.

---

### 4.1 `get_hat_last_location`

Returns the most recently known location of a hat.

**Input:**
- `hat_id: HatId`
- `payment: Payment`

**Output:** `Location | null`

`null` indicates the IB could not or did not return information this query.

---

### 4.2 `get_hat_capabilities`

Returns the current set of capabilities carried by a hat.

**Input:**
- `hat_id: HatId`
- `payment: Payment`

**Output:** `[CapabilityId] | null`

---

### 4.3 `get_hat_meeting_times`

Returns the list of ticks at which a hat participated in a meeting.

**Input:**
- `hat_id: HatId`
- `payment: Payment`

**Output:** `[Tick] | null`

---

### 4.4 `get_meeting_location`

Returns the location of a meeting a hat attended at a given tick.

**Input:**
- `hat_id: HatId`
- `tick: Tick`
- `payment: Payment`

**Output:** `Location | null`

`null` if no meeting occurred for this hat at this tick, or if IB did not return information.

---

### 4.5 `get_meeting_participants`

Returns the list of hats that participated in the meeting at a given tick and location.

**Input:**
- `tick: Tick`
- `location: Location`
- `payment: Payment`

**Output:** `[HatId] | null`

`null` if no meeting occurred at this tick+location, or if IB did not return information.

---

### 4.6 `get_meeting_trades`

Returns the capability trades that took place at a meeting.

**Input:**
- `tick: Tick`
- `location: Location`
- `payment: Payment`

**Output:** `[Trade] | null`

Each `Trade` is `(source_hat_id, recipient_hat_id, capability_id)`.

`null` if no meeting occurred at this tick+location, or if IB did not return information.

---

## 5. Noise Model

### 5.1 Payment-Probability Relationship

The probability that a paid query returns correct information follows:

```
P(correct | payment p) = 1 - exp(-λ · p)
```

where `λ` is a per-query-type noise parameter (positive real; implementation-defined per query type).

Properties:
- `p → 0`: probability approaches 0 (no payment = no information)
- `p → ∞`: probability approaches 1 (cannot reach certainty)
- Higher `λ` = a given query type is cheaper to answer reliably

### 5.2 Noise Outcomes

When a paid query does **not** return correct information, the result is one of:

| Outcome | Description |
|---------|-------------|
| **Missing** | IB returns `null` |
| **Perturbed** | IB returns a plausible but incorrect value (e.g., wrong location nearby, wrong capability in list) |
| **Stale** | IB returns information that was correct at a prior tick |

Defenders must model uncertainty in all paid query results.

### 5.3 Approximate Payment Bands

(From WSC 2004 paper; exact values are implementation-specific.)

| Payment Band | Approximate P(correct) |
|--------------|------------------------|
| Low | ~0.50 |
| Medium | ~0.75 |
| High | ~0.95 |
| Very High | ~0.99 |

---

## 6. Default Request Scheduler

The IB provides a mechanism to automatically re-execute a set of queries at every tick advance.

### 6.1 Operations

**`add_default_requests(requests)`**  
Add queries to the default schedule. Each entry specifies a query and its arguments (including payment, for paid queries).  
Input: list of query descriptors  
Output: none

**`remove_default_requests(requests)`**  
Remove specific queries from the default schedule.  
Input: list of query descriptors matching previously added entries  
Output: none

**`clear_default_requests()`**  
Remove all queries from the default schedule.  
Input: none  
Output: none

**`list_default_requests()`**  
Return the current default schedule.  
Input: none  
Output: list of query descriptors

### 6.2 Execution

When `advance(n_ticks)` is called, the default request schedule executes at **each** tick. Results from each tick are collected and returned alongside the advance result.

---

## 7. Simulator Control Queries

These are part of the IB interface (administrative category) but control simulation lifecycle rather than querying state.

**`initialize(params, seed)`**  
Initialize a new simulation run. Must be called before any other IB query.

**`advance(n_ticks)`**  
Advance simulation by `n_ticks` (default: 1).  
Returns: default request results for each tick advanced.

**`end()`**  
Terminate run. Produces final report. No further queries valid after this call.

---

## 8. Player Actions (IB-Mediated)

Player actions are submitted through the IB interface and affect simulation state.

### 8.1 `arrest_hat`

**Input:**
- `hat_id: HatId`
- `location: Location`

**Output:** `SUCCESSFUL | FAILURE`

See [spec-hats-simulator.md §9.1](spec-hats-simulator.md) for full arrest semantics.

### 8.2 `alert_beacon`

**Input:**
- `beacon_id: BeaconId`
- `alert_level: AlertLevel`

**Output:** none

See [spec-hats-simulator.md §9.2](spec-hats-simulator.md) for scoring implications.

---

## 9. Query Completeness and Partiality

| Query | Complete? | Notes |
|-------|-----------|-------|
| `get_world_dimensions` | Yes | Perfect |
| `get_beacons` | Yes | Perfect |
| `get_all_capabilities` | Yes | Perfect |
| `get_benign_organizations` | Yes | Perfect |
| `get_terrorist_organizations` | **Partial** | Not all terrorist orgs revealed |
| `get_known_terrorist_hats` | **Partial** | Not all terrorists revealed; covert terrorists absent |
| `get_organization_members` | Yes | Perfect for the given org |
| `get_hat_advertised_color` | Yes | But `advertised_color ≠ true_color` |
| All paid queries | **Noisy** | Probabilistically correct per noise model |

---

## 10. Error Cases

| Condition | Expected Behavior |
|-----------|------------------|
| Unknown `hat_id` | `get_hat_advertised_color` returns `NOT_A_KNOWN_HAT`; other queries return `null` |
| Unknown `org_id` | `get_organization_members` returns empty list or error |
| Unknown `beacon_id` | `alert_beacon` is a no-op or returns error |
| `payment ≤ 0` | Paid query behavior undefined; implementations should reject |
| Query before `initialize` | Behavior undefined; implementations should reject |
| Query after `end` | Behavior undefined; implementations should reject |
