# The Hats Simulator

Created by Paul Cohen (original version, 2003) and Clayton T. Morrison (2004)

With contributions from Joshua Moody, Andrew Hannon, Gary King and David Westbrook

The Hats Simulator is written in common lisp.

Contact Clayton Morrison for access to the code: `claytonm@email.arizona.edu`

# The Hats Simulator Manual

## (1) Introduction

The Hats Simulator is designed to be a lightweight proxy for many
intelligence analysis problems, and thus a test environment for
analysts' tools.  It is a virtual world in which many agents engage in
individual and collective activities.  Most are benign, some intend
harm.  The activities are planned by a generative planner, so the
simulator is continuously inventing new ways for agents to achieve
their goals.  Playing against the simulator, the job of the analyst is
to find harmful agents before they carry out their plans.  The
simulator maintains information about all the agents, but some is
hidden from analysts and some is expensive.  After each game, the
analyst is assessed a set of scores including the cost of acquiring
information about agents, the cost of falsely accusing benign agents
and the cost of failing to detect harmful agents.

(In the rest of this manual, "analyst", "user" and "player" all refer
to the user of the Hats Simulator, and include humans and computer
programs.)


## (2) What the analyst knows about the Hats domain

What the analyst knows initially about the Hats domain is explained
while describing the ontology of the Hats domain, in the following
outline:

```
    () Hats World
        () A 2-dimensional grid-world
        () Each grid cell has an x,y coordinate location
        () The Hats Simulator is tick based:
            a new set of events occur at each tick.
    () Capabilities
        () Represent atomic attributes of Hats and Beacons
        () Are themselves nothing but tokens of generic types
    () Beacons
        () Represent "locations of interest" in the grid-world
        () Each has a single, unique location in the grid-world
        () Each has a set of capabilities (called "vulnerabilities")
        () Beacons can be set to different alert levels (see below)
    () Hats
        () The agents of the Hats domain
        () Each has a unique ID by which to identify and refer to it
        () Hats can move from one location to another 
            but occupy only one location per time tick
        () Each hat has:
            () a list of "carried" capabilities - may change over time
            () an advertised color (terrorist or unknown)
            () a true color (terrorist, covert-terrorist or benign)
        () The analyst has direct access to each hat's advertised color
            but must infer the hat's true color
    () Organizations
        () Sets of hats
        () Each hat is a member of at least one organization; 
            hats can belong to multiple organizations
        () Two general kinds of organizations:
            () Benign organizations
                () May include terrorists, covert-terrorists and benign hats
                () Do no harm
            () Terrorist organizations
                () Include only terrorists and covert-terrorists
                () Attempt to attack beacons
        () Organization memberships are determined at the beginning 
            for each hat and do not change
    () Taskforce
        () A subset of hats selected from a single organization
        () Are tasked with bringing capabilities to a destination
        () Are chosen periodically by an organization's planner 
        () When a taskforce is chosen, a series of meetings are planned 
            in order to get specified capabilities to a target destination
        () A taskforce target may be any location, including a beacon
        () When final meeting takes place on target, taskforce is disbanded
        () Both benign and terrorist organizations convene taskforces
    () Meetings
        () Take place amongst hats
        () May occur at any location (including beacons)
        () Capabilities may be traded between hats in a meeting
            - some trades are in the service of gathering capabilities
                for a taskforce
        () A taskforce may not carry all of the required capabilities
            amongst it's members to meet the taskforce's goal, so other 
            members of the taskforce's organization may be recruited for
            trading their capabilities during meetings
        () Criteria for when a beacon is ATTACKED: 
          IF
           (a) a meeting occurs on beacon,
           (b) this meeting is the final planned meeting of a taskforce,
           (c) capabilities of hats at the meeting match 
                   the vulnerabilities of beacon, 
          and
           (d) the taskforce is from a terrorist organization
          THEN: the meeting results in the beacon being attacked
```

Section 4 lists the commands available to user of the Hats system,
including the facilities to request information about the current
state of the simulation.  The user can also take two kinds of actions
that affect scoring of the user's performance: changing beacon alert
levels and arresting hats.

### Beacon Alerts

Each beacon can be in one of three alert levels: off (default),
level-1 or level-2.  Off indicates there is no threat of an impending
attack, level-1 indicates there is a chance of an attack, and level-2
indicates an attack is likely.  The Hats Simulator keeps basic
statistics of beacon alert levels, including the amount of time a
beacon alert is elevated (level-1 or level-2) and whether actual
attacks do or do not occur during elevated alerts.  These statistics
include counts of "hits" and "false positives", where "hits" =
occurances of an attack while alert is elevated, and "false-positives"
= alerts that begin and end with no beacon attack occuring; these
scores are kept for both level-1 and level-2 alert levels.  In
general, the goal is to minimize the time beacon alerts are elevated,
and level-2 alerts are deemed "more costly" than level-1 alerts; on
the other hand, if an attack _does_ occur on a beacon, it is generally
better to have a higher alert level (level-2 being better than
level-1).

### Arresting Hats

Users can also arrest hats in order to prevent beacon attacks.  A
successful arrest results when the arrested hat is currently a member
of terrorist taskforce.  Arrests of any other hats, including hats
that are terrorists but not currently part of a terrorist taskforce,
result in arrest failure and are equivalent to a false arrest.  This
is an important aspect of the semantics of "being a terrorist" in the
current model: one can be a terrorist but not be guilty of any crime.
Terrorism is a matter of a propensity to engage in terrorist acts (a
terrorist act in the Hats domain is planning and executing an attack
on a beacon); but terrorist hats must be engaged in an ongoing
terrorist activity to be successfully arrested.  In this model,
arresting a hat that previously committed a terrorist act but is
currently not a part of a terrorist taskforce cannot be successfully
arrested.

Also, successful arrests do not entail saving a beacon.  As noted in
the criteria for when a beacon is attacked (the last subsection under
the outline describing meetings), a beacon is only attacked when some
subset of terrorist taskforce members engaging in the final, target
meeting are also carrying the requisite capabilities that match the
target beacon's vulnerabilities.


Currently, the statistics kept on beacon hits and misses and
successful and false arrests are not amortized into a uniform cost
model; they are simply reported as another measure of comparative
player performance.


## (3) The Hats Simulator Interface Description

The analyst playing the Hats game interacts with the simulator through
an interface that includes the Hats Information Broker.  The
Information Broker (IB) is the facility by which the analyst can get
information about the state of the simulator.  Some general
information is free, other information requires payment.  The complete
list of commands available, including arguments and documentation, is
listed in the next section and can be obtained at any time using the
command (services).

The interface includes the following categories of commands:

```
    () Administrative Services - allowing the user to get general information 
        about the services provided by the Hats interface.
    () Simulator Controls - by which the user can initialize, advance or
        end a Hats Simulator run.
    () Player Actions - The set of "actions" the player can take in the
        Hats world.  Currently this includes changing beacon alert statuses
        and arresting hats.
    () IB Request manager - a facility through which sets of information broker
        requests can be automatically scheduled and managed
    () IB Requests - the set of requests for information that the user
        can make.  Some information is free, other requests require payment.
```

## (4) Hats Simulator Interface Functions

The following commands are available to the user -- NOTE: this list
can be obtained at any time using the function (services).

```
       Function: SERVICES
      Arguments: (&KEY SERVICES NAME ARGS DOCS LIST)
  Documentation: "Outputs details of all Information Broker functions (services) and their usage.

KEYWORDS:
  services : optional list of only the services of interest; 
             nil (default) = show all
             Can list specific service function names, including 
             service-types drawn from the following list:
                services           (administrative services) 
                simulator-controls (hats simulator control)
                player-actions     (user actions taken in the hats environment)
                ib-request-manager (information broker request manager servcs)
                ib-requests        (ALL valid information broker requests)
                ib-requests-free   (all FREE information broker requests)
                ib-requests-paid   (all PAID information broker requests)
  name     : t = include name of service in service description
  args     : t = include argument signature in service description
  docs     : t = include documentation string in service description
  list     : t = return as list of lists where each sublist contains 
                   the information requested for the service
             nil = return text list of each service 
                   (with requested information)

   NOTE: all arguments are keywords, so must all be proceeded by a colon.
         E.g., to ask for only the argument signature for the functions 
         ib-beacons and ib-meeting-times do:

         (ib-services :services '(ib-beacons ib-meeting-times) :args t)"

------------------------------------------------------

       Function: SERVICE-NAMES
      Arguments: NIL
  Documentation: "Returns list of all Information Broker service functions."

------------------------------------------------------

       Function: HATS-INITIALIZE
      Arguments: (&KEY PARAMETER-MANAGER USE-VIEWER?)
  Documentation: "Initializes the Hats simulator."

------------------------------------------------------

       Function: HATS-ADVANCE
      Arguments: (&KEY NUMBER-OF-TICKS TIME-IT)
  Documentation: "Advance the simulation by NUMBER-OF-TICKS (default 1 tick).  If default information broker requests exist, they will be executed at each tick and returned in a list as the first of the return values."

------------------------------------------------------

       Function: HATS-END
      Arguments: NIL
  Documentation: "Terminates Hats simulation run and outputs data to file."

------------------------------------------------------

       Function: ACTION-ARREST-HAT
      Arguments: (&KEY HAT-ID X-LOCATION Y-LOCATION)
  Documentation: "Arrest action arrests a hat at a given location.  
IF hat is:
     (a) currently at designated location,
     (b) a terrorist, and
     (c) currently part of a taskforce
THEN arrest is :SUCCESSFUL, else :FAILURE.
Hat is immediately released if :FAILURE, else remains on an "arrest list" 
until the taskforce the hat belongs to holds its final meeting, at which 
time the hat is removed from "arrest list".  During time on the "arrest 
list", the hat will still move around, going to its normally scheduled 
meetings (its behavior is essentially unchanged); but it cannot lend its 
capabilities to a successful attack, so arresting the right hat CAN prevent 
a beacon attack from being recorded."

------------------------------------------------------

       Function: ACTION-ALERT-BEACON
      Arguments: (&KEY BEACON-ID ALERT-LEVEL)
  Documentation: "Alert Beacon action sets the beacon alert-level for specified BEACON-ID.  The following are acceptable alert levels, their interpretation, affects of alert on score when attack occurs, and cost:
   :OFF - "no alert" - full impact on score - free
   :LEVEL-ONE - "lowest alert level; attack likely" - 1/2 impact on score
   :LEVEL-TWO - "highest alert level; attack imminent" - no impact on score"

------------------------------------------------------

       Function: IB-ADD-DEFAULT-REQUESTS
      Arguments: (REQUEST-LIST)
  Documentation: "Adds list of requests ((<request-function> [<keyword> <argument>]*)*) to default requests."

------------------------------------------------------

       Function: IB-REMOVE-DEFAULT-REQUESTS
      Arguments: (REQUEST-LIST)
  Documentation: "Removes each request in the argument list ((<request-function> <arguments>)*) from default requests."

------------------------------------------------------

       Function: IB-CLEAR-DEFAULT-REQUESTS
      Arguments: NIL
  Documentation: "Clears all default requests."

------------------------------------------------------

       Function: IB-LIST-DEFAULT-REQUESTS
      Arguments: NIL
  Documentation: "Returns list of all default requests."

------------------------------------------------------

       Function: IB-WORLD-DIMENSIONS
      Arguments: NIL
  Documentation: "Returns list of ((:x <x-min> <x-max>) (:y <y-min> <y-max>)) hats world dimensions."

------------------------------------------------------

       Function: IB-BEACONS
      Arguments: NIL
  Documentation: "Returns list of all beacons and their state, in the following format: (<beacon-id> <alert-status> (<x-location> <y-location>) (<list-of-vulnerabilities>)).  Perfect information."

------------------------------------------------------

       Function: IB-ALL-CAPABILITIES
      Arguments: NIL
  Documentation: "Returns list of all capabilities (beacon vulnerabilities or carried by hats).  Perfect information"

------------------------------------------------------

       Function: IB-BENIGN-ORGANIZATIONS
      Arguments: NIL
  Documentation: "Returns list of all benign organization id's."

------------------------------------------------------

       Function: IB-TERRORIST-ORGANIZATIONS
      Arguments: NIL
  Documentation: "Returns list of some terrorist organization id's."

------------------------------------------------------

       Function: IB-KNOWN-TERRORIST-HATS
      Arguments: NIL
  Documentation: "Returns list of some known terrorist hat-id's."

------------------------------------------------------

       Function: IB-MEMBERS
      Arguments: (&KEY ORGANIZATION)
  Documentation: "Returns list of members (hat-id's) of organization."

------------------------------------------------------

       Function: IB-HAT-ADVERTISED-COLOR
      Arguments: (&KEY HAT-ID)
  Documentation: "Returns the advertised color of specified hat as one of three values:
        :TERRORIST        a known terrorist
        :UNKNOWN          not known to be a terrorist
        :NOT-A-KNOWN-HAT  hat-id does not refer to a known hat"

------------------------------------------------------

       Function: IB-EVENTS-HISTORY
      Arguments: NIL
  Documentation: "Returns list of world events (e.g., beacon attack, beacon save) in chronological order."

------------------------------------------------------

       Function: IB-CLEAR-EVENTS-HISTORY
      Arguments: NIL
  Documentation: "Clears events history."

------------------------------------------------------

       Function: IB-ARRESTED-HATS
      Arguments: NIL
  Documentation: "Returns list of hat-id's for hats currently arrested."

------------------------------------------------------

       Function: IB-LAST-LOCATION
      Arguments: (&KEY HAT-ID PAYMENT)
  Documentation: "Returns the last location (x y) of the requested hat.  Payment required."

------------------------------------------------------

       Function: IB-CAPABILITIES
      Arguments: (&KEY HAT-ID PAYMENT)
  Documentation: "Returns a list of the current capability-id's of the requested hat.  Payment required."

------------------------------------------------------

       Function: IB-MEETING-TIMES
      Arguments: (&KEY HAT-ID PAYMENT)
  Documentation: "Returns a list of ticks a hat participated in a meeting.  Payment required."

------------------------------------------------------

       Function: IB-MEETING-LOCATION
      Arguments: (&KEY HAT-ID TICK PAYMENT)
  Documentation: "Returns the location (x y) of the meeting a hat had at given tick, or NIL if no meeting.  Payment required."

------------------------------------------------------

       Function: IB-MEETING-PARTICIPANTS
      Arguments: (&KEY TICK X-LOCATION Y-LOCATION PAYMENT)
  Documentation: "Returns list of meeting participants (hat-id's), or nil if no meeting took place.  Payment required."

------------------------------------------------------

       Function: IB-MEETING-TRADES
      Arguments: (&KEY TICK X-LOCATION Y-LOCATION PAYMENT)
  Documentation: "Returns list of capability trades (<source-hat-id> <recipient-hat-id> <capability-id>) 
that took place at a meeting, or nil if no meeting.  Payment required."
```

## (4) Loading the Hats Simulator from source files

TODO

## (5) Interacting with the Hats Simulator from Lisp

TODO
