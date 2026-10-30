# Crash tolerance of a replicated IEC 61850 interlock: TLA+ model

This is the model and check script behind the crash-tolerance section of *A High Availability Architecture for Virtualised Protection and Control* (DPSP Europe 2027).

Two IED replicas and a witness form one Raft group. The group replicates the CILO enable (`EnaOpn`/`EnaCls`). Before every select/operate, CSWI checks the enable. The model asks whether that check can ever see a stale value when members crash, leaders change, and some replicas hold stale local copies.

## Run

With Docker (no other dependency):

```sh
make docker
# or: docker build -t cilo-raft-proof . && docker run --rm cilo-raft-proof
```

With a local Java 11+ and [`tla2tools.jar`](https://github.com/tlaplus/tlaplus/releases/tag/v1.8.0):

```sh
TLA2TOOLS=/path/to/tla2tools.jar make local
```

Expected output (the Barrier run takes about 2.5 minutes on a 14-core machine):

```
Mode         Expected   Result           States     Time
Local        violated   violated           1686       4s
LeaderLocal  violated   violated           3064       4s
Barrier      holds      holds           3924888     149s
```

The two refuted modes run with one TLC worker, so their traces are shortest counterexamples and the numbers are reproducible; the Barrier run uses all cores. Full TLC output, including the counterexample traces, is written to `results/<Mode>.log`. The script exits with status 0 only if all three verdicts match the expected ones.

## What is modelled

| File | Content |
|---|---|
| `CiloHA.tla` | Specification and properties |
| `MC.tla` | Symmetry between the two IED replicas |
| `Local.cfg`, `LeaderLocal.cfg`, `Barrier.cfg` | One configuration per read variant |
| `run.sh`, `Dockerfile`, `Makefile` | Reproduction |

**Raft at quorum-step granularity.**
- An election, a replication step and a commit are each one atomic step.
- Only the members taking part in a step learn about it. Deposed leaders that still believe they lead and stale followers therefore arise naturally.
- A commit requires a majority that stores the entry in the leader's term.

**Faults.**
- At most one member crashes (crash-stop; restart is not modelled).
- A crashed IED loses its local data model.
- The model's default value, `permit`, is the worst case for a model that is not yet initialised.

**Clients.**
- The operator can reach any running IED replica.
- An IED replica forwards a request to any member that believes it is the leader, including the witness.

**Write path.** A write is acknowledged and displayed only after it is committed (commit before display).

**Convergent path.** At any time, an IED may apply to its local data model what its own Raft member has committed so far, which may lag behind the group.

**Read variants for the CSWI check** (`Mode`):

| Mode | The check reads |
|---|---|
| `Local` | the IED's local data model |
| `LeaderLocal` | the committed state of a member that believes it is the leader |
| `Barrier` | first commits a no-op entry, then reads the state up to it (the mechanism in the paper) |

**Bounds:** 3 members, 2 terms, 3 log entries, 3 operator actions, 1 crash.

## Properties (invariants)

| Name | Meaning |
|---|---|
| `CommittedStable` | Raft state machine safety holds in the abstraction (sanity check) |
| `NoLostIntent` | An acknowledged operator write stays in the committed log |
| `DisplayCommitted` | A local data model shows only committed values (display never ahead of commit) |
| `Linearizable` | Every check answer equals the committed value at some instant between the start and the end of the check |

## Results

| Mode | Verdict | Counterexample |
|---|---|---|
| `Local` | violated | `block` is committed, but the local model of the replica that took the write has not been updated yet. A check there answers `permit` (5 steps). |
| `LeaderLocal` | violated | Leader r1 of term 1 is cut off but still believes it leads. r2 and the witness elect r2 for term 2 and commit `block`. A check forwarded to r1 answers `permit` from r1's own committed state (6 steps). |
| `Barrier` | all four invariants hold | — |

**Scope.** This is a bounded model check of an abstraction, not a mechanised proof. The paper gives the unbounded argument from Raft's safety properties. Restart of a crashed member, Byzantine faults, timing and the protection path are not modelled.
