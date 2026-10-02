# AI/AN Medicaid exclusion verification — issues and options for tribal governance review

**Subject.** From 1 January 2027 many adults on Medicaid must document 80 hours a month of
work or equivalent activity or lose coverage. American Indians and Alaska Natives are
excluded by statute — but only where the state knows. State eligibility systems generally
cannot tell. From 1 January 2028, where a state has nothing on file, it is **required** to
demand documents from the person. The determination that matters is already made by Indian
health providers at registration. There is currently no way for a state to ask.

**Purpose of this document.** Not to seek approval of a design. To set out the issues we
have found, including the ones that count against building anything, and three outcomes
that are open — with what each protects and what each costs. The decision is not ours.

**Status.** Design only. Nothing built. No state approached. No tribal partner has agreed to
anything. Reviewed by us and by two independent automated reviewers; their findings changed
this document materially and are reflected in §2.

**Who is asking, and our bias.** Lakeraven, a vendor that builds and maintains software for
tribal health programs running RPMS. We have no mandate from any nation to design this and
no standing to decide it. **We sell software, so we have a commercial interest in every
outcome below except A — including D, where we would be building to someone else's
requirements.** Our stated preference, C, is also the outcome that makes us most
structurally necessary, which is the clearest reason to discount it. Weigh our reasoning
accordingly; we have tried to make A's case as well as our own.

**Not a consultation.** Government-to-government consultation and nation-by-nation
agreements would have to happen through proper channels before anything was built. This is
one vendor's technical analysis, circulated early so that the architecture can be rejected
cheaply.

---

## 1. What is being proposed, in brief

One question, about one named person, answered by the provider that already made the
determination:

> Does this provider hold a determination that this person is eligible for services from an
> Indian health provider?

The answer is **yes**, **no**, or **we hold no determination** — plus **who** asserts it and
**when**. Nothing else. No roll, no list, no batch, no search, no demographics, no tribe
name, no enrollment number, no blood quantum, no degree of descent, and no reason code
saying *why* the answer is yes.

Two possible delivery paths: the state asks the provider directly (no action required from
the person), or the person carries a signed confirmation and shows it when asked.

**One precision, because our earlier wording invited a fair objection.** The provider's
underlying registration record never leaves its system. **The answer does leave** — that is
the point of the service — and once a state holds it, §2.1 governs what happens next. We
should not say "the record stays with the provider" as though nothing crossed the boundary.

That is the whole proposal. Everything below is about what it would and would not protect.

---

## 2. The issues

Ordered by how much they should weigh on the decision, not by how comfortable they are.

### 2.1 The state accumulates a population, and we cannot stop it

Our first draft claimed "no cohort" as a property of the software. An independent reviewer
called that an overclaim and was right.

**A state that uses this will, over time, hold a list of people in its Medicaid files
flagged as excluded on this basis — a derived population of AI/AN beneficiaries, held by a
state.** Federal rule *requires* the state to record the determination. Nothing in the
software reaches into state systems to govern what they keep, how they shape it, how long
they hold it, or who else inside the state sees it.

Once a flag is in a state eligibility file it is subject to that state's records law, its
data-sharing arrangements with other state programs, subpoena, breach, and whatever future
administration inherits it.

**This is the central issue.** Protections against it are contractual, not structural
(§2.2). If that trade is unacceptable, outcome A is the answer and the rest of this document
is detail.

### 2.2 The protections that matter are promises, not properties

What federal rule already requires: the person must be told; the exchange must be secure; a
written agreement with use-and-disclosure safeguards must exist first; and **the state may
never re-check this determination** — once established it is permanent by rule, so the
number of questions ever asked about one person is one.

What must be negotiated and will not happen by itself: the shape in which the state stores
the determination; no secondary use, analytics, cohort-building, cross-program sharing, or
law-enforcement and immigration disclosure beyond what law compels; **audit rights for the
operating body over what the state keeps**, not only over its own query log; a stated and
enforced retention and deletion period; breach notification to the operating body.

We will say plainly: **nothing in federal rule gives a data source audit rights over a
state's retention.** It has to be bargained for, and it is the term most likely to be
refused.

The only enforcement we can see is **making these conditions of participation** — a
provider does not connect to a state that will not agree. That requires willingness to
withhold connection, which is a decision we cannot make and which is much easier for a
large operator than a small one (§4).

### 2.3 Serial querying across providers defeats part of the design

The design refuses to answer twice about the same person, so a state cannot watch an answer
change. But a state may ask provider A ("no determination") and then provider B ("yes") —
two lawful first answers — and infer a registration pattern anyway.

**We have not solved this.** The obvious fix is a shared record across providers of who has
been asked about, and we rejected it: it would require providers to learn which of their
peers a state had asked about, which is worse than the problem. We are bringing it as an
open problem rather than deciding it unilaterally.

Mitigation we do propose: a **volume ceiling per requesting state, set by the operating
body** — not by us and not by the state — plus query logs that surface volume and anomaly
patterns rather than only individual calls, and an agreement term binding every query to a
named individual already in an eligibility determination. Without that, a state can issue
one permitted single-person query per beneficiary across its whole caseload and, from the
pattern of "no determination" answers, **map the boundary of a provider's patient
population** — a bulk extract assembled one allowed call at a time. Cheap to build now,
effectively impossible to retrofit after a state has integrated.

### 2.4 The federal definition is broader than yours

For Medicaid purposes the federal definition of "Indian" is not "citizen of a federally
recognized nation." It is a list of alternatives reaching members of **state-recognized**
tribes, members of tribes **terminated since 1940**, **first- and second-degree
descendants** of such members living in urban centers, and — through the IHS service rule —
anyone **"regarded as an Indian by the community in which he/she lives."**

So the federal set includes people **no federally recognized nation claims as a citizen.**
That appears deliberate: a service program discharging a trust obligation to a population
rather than a membership roster, with urban provisions existing because federal relocation
policy scattered people from their nations.

**The mechanism this creates, which is yours to weigh and not ours to characterise:** a
confirmation can read *yes* for someone a nation does not recognize, and a third party could
read it as evidence of membership. We do not think a vendor should tell nations what that
means for them. We do think we are obliged to say the mechanism exists and to constrain what
we build accordingly:

- We will never describe this as verifying who is Indian. The assertion is *eligibility for
  services from an Indian health provider*. That binds our code, field names, documents, and
  anything we say to a state.
- We will never claim to help a state identify your citizens. The accurate claim is
  narrower: **your clinic confirms who your clinic serves.**
- We propose any confirmation be restricted, by agreement and by its own contents, to
  Medicaid and CHIP eligibility and be unusable elsewhere.

It is also why this cannot be centralized at the determination level: you cannot build a
registry of a group defined partly by local community regard.

### 2.5 Disenrollment — what is blocked and what is not

Nations disenroll; that is a sovereign act. Because the definition is a list of
alternatives, **a person a nation has disenrolled may still be eligible for services**, and
a provider's record may still read yes.

**Blocked.** Once the service has given a yes or a no it replays that answer with its
original timestamp and does not look again — so a state cannot watch a determination be
withdrawn, which would be reading a nation's governance decision through a Medicaid
interface. And a person-carried confirmation is never cancelled because the underlying
situation changed; cancellation is reserved for issuing errors and security problems. If we
cancelled on change, the cancellation list would be a machine-readable disenrollment feed
timed to your decisions.

**Not blocked.** §2.3's serial querying, and everything a state does after it has an
answer. And the uncomfortable consequence of the cancellation rule: **a confirmation may
remain valid for someone a nation has since disenrolled.** We think that is correct — it
reports what a provider determined, not what a nation decided — but you should hear it from
us.

**One error worth showing you.** An earlier version of the replay rule froze *all* answers,
including "we hold no determination." A reviewer pointed out that if a state asks before a
person establishes care, the honest answer is "no record" — and freezing it would mean that
once the person does register and become eligible, the service could never say so. A rule
meant to protect nations would have permanently locked eligible people out of the exclusion.
Fixed: "no determination" can later become "yes"; yes and no never change. We show it
because it is the kind of error review exists to catch.

### 2.6 Some eligible people will not be found

To ask about a person the state must identify them. We propose **exact Social Security
Number matching only**, with no fallback to name-and-address matching, because a near-match
against this population is itself a disclosure.

**That choice costs people, and the cost is unmeasured.** I/T/U records are known to carry
missing or mismatched SSNs. Exact-match-only means the answer comes back "no determination"
for some people who *are* service-eligible — and in 2028 that lands on them as a demand for
documents. Nobody has measured the rate.

### 2.7 Participation will be uneven, and that falls on members

A voluntary design means well-resourced programs participate sooner. Members of
non-participating nations keep the documentation burden. We have no fix for this, and it is
a reason the person's own statement must remain available regardless (§2.8).

### 2.8 Verification rails fail at the margin — evidence, not sentiment

National tribal organizations have asked CMS to accept a person's own statement as
sufficient. We are not proposing to displace that and would argue against proposals that
did. Two sourced data points:

- **India's Aadhaar system**, used to gate food rations: a Jharkhand household survey by
  Drèze and co-authors found exclusion as high as 20% where fingerprint checks were required
  for every transaction; the State of Aadhaar Report (2020) found over 30% of people whose
  check failed received no rations at all. Causes: fingerprints worn by manual labour,
  biometrics degrading with age, connectivity failure.
- **Louisiana's Medicaid work-requirement pilot** (KFF Health News): 13,000 enrollees texted
  to verify income through an app; **894 completed — under 7%.** Those tools verify income
  only and cannot confirm exclusions at all. Arizona is running a similar pilot.

A verification path that gates benefits fails on the poor, rural, elderly, disabled and
offline. Any version of this must reduce how often a person is asked to prove something
without removing their ability simply to say so.

### 2.9 When it goes wrong, the person pays

Three cases: the answer is wrong because the field was never maintained; the answer is "no
determination" because of a wrongful non-match (§2.6); or the person's provider does not
participate (§2.7). In each the person is pushed back to documents, which from 2028 is where
coverage is lost.

Federal rule provides a fair-hearing process and bars terminating eligibility *solely*
because someone cannot produce documentation that does not exist. Whether that holds at
renewal scale is not something this design controls. **A remedy and appeal path needs
designing with you; we have not designed it.**

---

## 3. One condition that applies to every outcome

**A federal override we cannot design around.** Federal rule already requires states to
obtain eligibility information through a federal data service where it is available there,
and once a source is available states must connect within twelve months. If CMS ever
carries this verification federally, states will be obliged to migrate, and an arrangement
nations chose could be superseded. We have designed the transaction to be identical either
way, which preserves continuity but not the choice. We are not pursuing the federal path. We
cannot prevent it. It is listed here rather than as an outcome because **CMS decides it, not
you** — but it bears on every choice below, and §6 asks whether it changes your answer.

---

## 4. Four outcomes

**A note on why there are four.** We drafted three and had the set reviewed. The reviewer's
finding was that treating "person-carried only" as a variant of the query models **forces
the reviewer to accept state-initiated querying as the default**, when it is in fact a
distinct architectural choice that *structurally* removes the two largest risks rather than
mitigating them by contract. That was right, so it is outcome B below. The four are ordered
by how much a state learns — least to most.

### Outcome A — Do not build it

Oppose a technical verification path. Press CMS and states to accept the person's own
statement, and rely on the fair-hearing protections and the bar on terminating eligibility
for missing documents.

| | |
|---|---|
| **Protects** | No new disclosure surface exists. §2.1's state-held population never accumulates through this route. §2.3, §2.4's misreading risk, §2.5's residue and §2.6's non-match all become moot. Nothing can be federalized (§3) because nothing exists. |
| **Costs** | From January 2028 states must demand documentation where they have nothing on file, whenever documentation is reasonably available. The rule does not specify what counts, and states may accept a range of evidence — but members who cannot produce whatever their state will accept carry the burden with only attestation and appeals as protection. That includes many people the federal definition covers *because* they are not enrolled (§2.4). |
| **Requires of nations** | Advocacy capacity at CMS and in states; no technical capacity. |
| **Honest assessment** | **A coherent position, not a null one.** It trades a quantified future harm to members against an architectural risk to nations. If §2.1 is unacceptable at any price, this is the correct answer and we would stop. |
| **What we would do** | Stop. We would not take it to a state. We would say publicly, if useful, why we stopped. |

### Outcome B — Person-carried only: no state querying at all

Providers issue a signed confirmation to the person. The person presents it when a state
asks for documentation. **There is no interface for a state to query a provider. It does not
exist and cannot be switched on.**

| | |
|---|---|
| **Protects** | **The two biggest risks disappear structurally rather than contractually.** The state asks nobody, so there is no query log, no serial-querying channel (§2.3), and no pattern of enquiries about named people. §2.2's doomed audit-rights term stops being load-bearing, because the main thing it was meant to govern never happens. No endpoint to run, so §2.7's capacity burden largely lifts. Nothing for CMS to federalize at the provider end (§3). |
| **Costs** | **It only works when the person acts** — and §2.8 is the evidence for what that costs: under 7% completion in a comparable Medicaid pilot, and exclusion up to 20% in a national system that gated food. The people it fails are §2.6's non-match population and §2.8's margin: the same people. Federal rule prefers verification that requires nothing of the beneficiary, so this is the *second*-preference path legally. A portable confirmation can also be demanded by landlords, employers or police, and misread as evidence of membership (§2.4) — a coercion surface the query path does not create. Requires phones, connectivity, and a wallet that works. |
| **Requires of nations** | Agreement to issue; a decision on what the confirmation may say and how long it is good for; no ongoing operations. |
| **Honest assessment** | **The strongest answer to §2.1 and §2.2, and the weakest answer to §2.8.** If the governing concern is what states accumulate, this is the best outcome available. If the governing concern is that eligible people keep coverage without having to do anything, it is the worst of B, C and D. |
| **What we would do** | Build issuance into provider systems. We would never be in the data path, and neither would a state. |

### Outcome C — Federated query: each nation or facility operates its own

We build and support the software; each participating nation or 638 facility runs its own
endpoint, sets its own volume ceiling, and signs its own terms with each state.

| | |
|---|---|
| **Protects** | No *data* chokepoint — no central custodian of answers, and the underlying registration record never leaves the provider's system. Each nation's participation, terms, and withdrawal are its own decision. Works without the person doing anything, which is the path federal rule prefers. Closest to OCAP on possession. |
| **Costs** | **We would be the chokepoint, and our earlier draft denied it.** A reviewer caught that: if we build, maintain, and support every federated endpoint, then we are a single point of failure and a single point of compulsion, even though no patient data passes through us. Mitigations exist — the specification is public, the software could be open-sourced, source could be escrowed, another vendor could take it on — but today it would be us, and a nation should treat vendor dependence as a real cost of this outcome. Beyond that: **capacity** (most programs cannot run an endpoint today); **negotiating asymmetry** — each nation bargains alone against a state over §2.2's terms, and withholding connection is hardest for the programs with least capacity; **unevenness** (§2.7) falls on members of non-participating nations; and a single provider cannot see §2.3's serial-query pattern across states. |
| **Requires of nations** | Technical capacity or a support arrangement; legal capacity to negotiate per state; separate decisions on terms. |
| **Honest assessment** | Our commercial preference, which is a reason to discount our enthusiasm for it. Strong on possession, weak on bargaining power, and dependent on us in a way we should not have glossed. |
| **What we would do** | Build it, support it, charge for support. Publish the terms we think should be conditions of participation so no nation drafts them alone. |

### Outcome D — Collective query: a national tribal organization operates it

One operator acting for participating nations — a single integration for states, one set of
terms, one volume policy.

| | |
|---|---|
| **Protects** | **Bargaining power.** §2.2's contractual protections — especially audit rights over state retention — are plausible when negotiated once by a body states must deal with, and implausible when negotiated by a small program alone. Relieves C's capacity burden. One body can detect §2.3's cross-state query patterns, which no single provider can. Uniform terms mean no nation is picked off individually. Works without the person acting. |
| **Costs** | **Concentration.** One body becomes custodian and chokepoint; compelled, breached, or defunded, it affects everyone at once. It sees every query about every participating nation's patients — visibility that does not exist in B or C. It must *want* a permanent operational and liability burden and be funded for it. Provenance must still name the determining provider, never the operator, or the operator becomes the apparent source of record. |
| **Requires of nations** | Agreement on who that body is and its mandate; delegation of a function touching members' coverage; a funding path for the operator. |
| **Honest assessment** | Probably the best realistic answer on §2.2 *if* a query path is built at all — and the one we have least standing to propose, since it depends on an organization choosing to take it on. **Note the tension with B:** D wins the contract fight; B avoids needing to win it. |
| **What we would do** | Build to the operator's requirements. We would not be in the data path. |

### Comparison

| | A: Don't build | B: Person-carried only | C: Federated query | D: Collective query |
|---|---|---|---|---|
| §2.1 state-held population | never arises | **arises only when a person presents** | arises per state | arises per state |
| §2.2 contract terms load-bearing? | n/a | **largely not** | yes, weak position | yes, strongest position |
| §2.3 serial querying | n/a | **impossible** | possible, undetectable | possible, **detectable** |
| Works without the person acting | n/a | **no** | yes | yes |
| Fails the §2.8 margin | n/a | **yes, worst** | no | no |
| Data chokepoint | none | none | none | high |
| **Vendor** chokepoint | none | moderate | **high** | moderate |
| Capacity required of nations | advocacy only | low | high | low |
| Who sees queries | nobody | nobody | the provider | provider **and** operator |
| Coercible from the person | n/a | **yes** | no | no |
| Burden on members from 2028 | highest | moderate | low | lowest |
| Reversible | n/a | easily | per nation | harder once states depend |
| Exposed to federal override (§3) | n/a | partly | yes | yes |

**The honest shape of the choice:** B and D are the two serious options and they disagree
about which risk matters more. B removes the state-accumulation problem and pays for it in
people who will not or cannot act. D keeps the easier path for people and bets that a
collective body can win contract terms that a single nation cannot. C is the most natural
fit for how tribal health IT is organised today and is the weakest on both counts. A is
correct if §2.1 is unacceptable at any price.

**Two concessions we should make explicitly**, both from review:

- Naming discipline binds us, not states. We will not describe this as verifying who is
  Indian (§2.4) — but a state holding a durable flag may treat it as a registry whatever we
  call it. Our vocabulary does not constrain theirs.
- Proposing an architecture whose principal defence is a contract term we ourselves call
  "most likely to be refused" is a weakness, not a nuance. It is the strongest argument for
  B over C and D, and we would rather state it than let it be found.

---

## 5. What we do not know, and would find out before anything is built

- **Whether the determination is reliably recorded** in provider systems today. We have
  identified the fields; we are not yet certain how one of them is used in practice, and a
  site that never maintained it may hold nothing. **This could invalidate the whole
  premise**, and it is the first thing we would check.
- **Whether health-privacy law permits a provider to answer a state at all.** Not yet put to
  a lawyer. It decides whether B and C are even available.
- **The wrongful non-match rate** (§2.6).
- **Whether tribal law permits a provider to answer a state** — not ours to resolve.
- Device and connectivity reality at participating sites, if the person-carried variant
  (§3.2) is in play.

---

## 6. What we are asking you to weigh

1. **Is §2.1 acceptable at any price?** If not, outcome A, and we stop. Everything else
   only matters if this is answered yes.
2. **If a state must be able to ask — is §2.2 survivable without a collective operator?**
   If the contract terms can only be won once, by a body states must deal with, that points
   at D and makes C a staging post at best.
3. **Or is the right answer to avoid the contract fight entirely (B)** — accepting that some
   people will not present a confirmation and will be pushed to documents, which §2.8 says
   will be the poorest, most rural, oldest and least connected?
4. **That is the real trade, and it is a values question, not a technical one.** Fewer
   state-held records, or fewer people losing coverage. We do not think a vendor should
   answer it.
5. **Is §2.3 tolerable** in C or D, and is our reason for rejecting a cross-provider shared
   record right?
6. **Is §2.4 handled adequately**, and is there a constraint we should adopt that we have
   not?
7. **Does §3's federal override change your answer to 2?**
8. **Is there a reason not to build any of this that we have not reached?**

We would rather hear question 8 answered now than after a state has been approached. There
is no deadline on our side; the only clock is 1 January 2028, and it is not ours.

---

### Appendix — the regulatory chain

The exclusion is statutory. The implementing rule defines the excluded group by reference to
a definition of "Indian" used elsewhere in Medicaid for cost-sharing protections; that
definition reaches the IHS rule on persons to whom services will be provided; and that rule
assigns the determination to the facility, listing tribal membership as one form of evidence
among several and giving doubtful cases to the medical officer in charge. The implementing
rule never cites the IHS service rule and says nothing about how a state should confirm the
exclusion electronically — which is the gap at issue.

Precise citations, the full comparison of delivery mechanisms, and a list of everything we
could not establish are in the companion technical specification in this repository.
