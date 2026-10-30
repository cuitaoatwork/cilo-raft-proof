------------------------------- MODULE CiloHA -------------------------------
(***************************************************************************)
(* Crash tolerance of the replicated CILO enable in a group of two IED     *)
(* replicas and a witness.  Deliberately small: one enable, Raft at the    *)
(* granularity of quorum steps, at most one crash.                         *)
(*                                                                         *)
(* Only the nodes taking part in a step learn about it, so a deposed       *)
(* leader may still believe it leads, and a replica's local IEC 61850      *)
(* model may be stale.  A crashed IED loses its local model.               *)
(*                                                                         *)
(* Mode selects how the CSWI check reads the enable before an operate:     *)
(*   "Local"       the IED's local data model                              *)
(*   "LeaderLocal" the committed state of a node that believes it leads    *)
(*   "Barrier"     commit a no-op entry, then read the state up to it      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Nodes, IEDs, Mode, MaxTerm, MaxLog, MaxOps

VARIABLES
  up,     \* node is running (crash-stop, at most one crash)
  term,   \* current Raft term
  leader, \* node believes it is the leader
  log,    \* Raft log: sequence of [t |-> term, v |-> value]
  ci,     \* commit index known to the node
  disp,   \* enable in each IED's local data model (shown on the HMI)
  pend,   \* the operator write in flight, or None
  chk,    \* the barrier check in flight, or None
  gc,     \* ghost: the committed log
  acked,  \* ghost: writes acknowledged to the operator
  ops,    \* ghost: answers of completed checks
  nops    \* number of operator actions so far

vars == <<up, term, leader, log, ci, disp, pend, chk, gc, acked, ops, nops>>

Default == "permit"     \* worst case: a restarted or fresh IED permits
Noop    == "noop"
None    == [st |-> "none"]
Maj     == {Q \in SUBSET Nodes : 2 * Cardinality(Q) > Cardinality(Nodes)}
Max(S)  == CHOOSE x \in S : \A y \in S : x >= y

\* the enable after applying the first k entries of log s
Val(s, k) == LET J == {j \in 1..k : s[j].v # Noop}
             IN IF J = {} THEN Default ELSE s[Max(J)].v

LastTerm(l) == IF l = <<>> THEN 0 ELSE l[Len(l)].t
UpToDate(n, m) == LastTerm(log[n]) > LastTerm(log[m])
                  \/ (LastTerm(log[n]) = LastTerm(log[m]) /\ Len(log[n]) >= Len(log[m]))

Init == /\ up = [n \in Nodes |-> TRUE]   /\ term = [n \in Nodes |-> 0]
        /\ leader = [n \in Nodes |-> FALSE] /\ log = [n \in Nodes |-> <<>>]
        /\ ci = [n \in Nodes |-> 0]      /\ disp = [i \in IEDs |-> Default]
        /\ pend = None /\ chk = None /\ gc = <<>> /\ acked = {} /\ ops = {}
        /\ nops = 0

-----------------------------------------------------------------------------
(* Raft, one quorum step at a time *)

Elect(n, Q) == LET T == Max({term[m] : m \in Q}) + 1 IN
  /\ n \in Q /\ \A m \in Q : up[m] /\ UpToDate(n, m)
  /\ T <= MaxTerm
  /\ term' = [m \in Nodes |-> IF m \in Q THEN T ELSE term[m]]
  /\ leader' = [m \in Nodes |-> IF m \in Q THEN m = n ELSE leader[m]]
  /\ UNCHANGED <<up, log, ci, disp, pend, chk, gc, acked, ops, nops>>

Replicate(n, m) ==   \* AppendEntries from n, rejected by a higher term
  /\ n # m /\ up[n] /\ up[m] /\ leader[n] /\ term[m] <= term[n]
  /\ log' = [log EXCEPT ![m] = log[n]]
  /\ term' = [term EXCEPT ![m] = term[n]]
  /\ leader' = [leader EXCEPT ![m] = FALSE]
  /\ ci' = [ci EXCEPT ![m] = ci[n]]
  /\ UNCHANGED <<up, disp, pend, chk, gc, acked, ops, nops>>

Commit(n, Q) == LET k == Len(log[n]) IN   \* a majority of n's term stores entry k
  /\ up[n] /\ leader[n] /\ n \in Q /\ k > ci[n] /\ log[n][k].t = term[n]
  /\ \A m \in Q : term[m] = term[n] /\ Len(log[m]) >= k /\ log[m][k] = log[n][k]
  /\ ci' = [ci EXCEPT ![n] = k]
  /\ gc' = IF k > Len(gc) THEN log[n] ELSE gc
  /\ UNCHANGED <<up, term, leader, log, disp, pend, chk, acked, ops, nops>>

Crash(n) ==
  /\ \A m \in Nodes : up[m]
  /\ up' = [up EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<term, leader, log, ci, disp, pend, chk, gc, acked, ops, nops>>

-----------------------------------------------------------------------------
(* IED: the operator reaches any running IED replica, which forwards to   *)
(* any node that believes it is the leader.                               *)

Write(i, L, v) ==   \* operator changes the enable
  /\ up[i] /\ up[L] /\ leader[L] /\ pend = None
  /\ nops < MaxOps /\ Len(log[L]) < MaxLog
  /\ log' = [log EXCEPT ![L] = Append(log[L], [t |-> term[L], v |-> v])]
  /\ pend' = [i |-> i, L |-> L, k |-> Len(log[L]) + 1, e |-> [t |-> term[L], v |-> v]]
  /\ nops' = nops + 1
  /\ UNCHANGED <<up, term, leader, ci, disp, chk, gc, acked, ops>>

AckWrite ==         \* commit before display
  /\ pend # None /\ up[pend.i] /\ up[pend.L]
  /\ ci[pend.L] >= pend.k /\ log[pend.L][pend.k] = pend.e
  /\ disp' = [disp EXCEPT ![pend.i] = pend.e.v]
  /\ acked' = acked \cup {[k |-> pend.k, e |-> pend.e]}
  /\ pend' = None
  /\ UNCHANGED <<up, term, leader, log, ci, chk, gc, ops, nops>>

Answer(v) == [s |-> Len(gc), e |-> Len(gc), v |-> v]

CheckLocal(i) ==
  /\ Mode = "Local" /\ up[i] /\ nops < MaxOps
  /\ ops' = ops \cup {Answer(disp[i])}
  /\ nops' = nops + 1
  /\ UNCHANGED <<up, term, leader, log, ci, disp, pend, chk, gc, acked>>

CheckLeaderLocal(i, L) ==
  /\ Mode = "LeaderLocal" /\ up[i] /\ up[L] /\ leader[L] /\ nops < MaxOps
  /\ ops' = ops \cup {Answer(Val(log[L], ci[L]))}
  /\ nops' = nops + 1
  /\ UNCHANGED <<up, term, leader, log, ci, disp, pend, chk, gc, acked>>

CheckBarrier(i, L) ==
  /\ Mode = "Barrier" /\ up[i] /\ up[L] /\ leader[L] /\ chk = None
  /\ nops < MaxOps /\ Len(log[L]) < MaxLog
  /\ log' = [log EXCEPT ![L] = Append(log[L], [t |-> term[L], v |-> Noop])]
  /\ chk' = [i |-> i, L |-> L, k |-> Len(log[L]) + 1, t |-> term[L], s |-> Len(gc)]
  /\ nops' = nops + 1
  /\ UNCHANGED <<up, term, leader, ci, disp, pend, gc, acked, ops>>

FinishBarrier ==    \* the no-op is committed: answer, and refresh the model
  LET v == Val(log[chk.L], chk.k) IN
  /\ chk # None /\ up[chk.i] /\ up[chk.L]
  /\ ci[chk.L] >= chk.k /\ log[chk.L][chk.k] = [t |-> chk.t, v |-> Noop]
  /\ ops' = ops \cup {[s |-> chk.s, e |-> Len(gc), v |-> v]}
  /\ disp' = [disp EXCEPT ![chk.i] = v]
  /\ chk' = None
  /\ UNCHANGED <<up, term, leader, log, ci, pend, gc, acked, nops>>

-----------------------------------------------------------------------------
Next ==
  \/ \E n \in Nodes, Q \in Maj : Elect(n, Q) \/ Commit(n, Q)
  \/ \E n, m \in Nodes : Replicate(n, m)
  \/ \E n \in Nodes : Crash(n)
  \/ AckWrite \/ FinishBarrier
  \/ \E i \in IEDs : CheckLocal(i)
  \/ \E i \in IEDs, L \in Nodes : CheckLeaderLocal(i, L) \/ CheckBarrier(i, L)
                                  \/ \E v \in {"permit", "block"} : Write(i, L, v)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* Raft state machine safety holds in the abstraction (sanity check)
CommittedStable == \A n \in Nodes : SubSeq(log[n], 1, ci[n]) = SubSeq(gc, 1, ci[n])

\* no lost intent: an acknowledged write stays in the committed log
NoLostIntent == \A a \in acked : a.k <= Len(gc) /\ gc[a.k] = a.e

\* R2: the local model never shows a value that is not committed
DisplayCommitted == \A i \in IEDs : \E k \in 0..Len(gc) : disp[i] = Val(gc, k)

\* no stale check: each answer is the committed value at some instant
\* between the start and the end of the check (linearizability)
Linearizable == \A o \in ops : \E k \in o.s..o.e : Val(gc, k) = o.v
=============================================================================
