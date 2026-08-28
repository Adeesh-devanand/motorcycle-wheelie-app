# Launch, marketing and monetization

Status: draft strategy, 2026-08-28. Researched against real competitor pricing, the
App Store Review Guidelines, and RevenueCat/Slopes monetization data. Sources are
linked inline. Nothing here is legal advice — §1 needs a real lawyer before launch.

Companion to `README.md` (engineering thesis) and `docs/ui-spec.md` (product surface).

---

## The one strategic decision everything else depends on

**Sell a motorcycle attitude telemetry instrument that measures pitch, lean and
speed. Do not sell a wheelie coach.**

This is not spin, and it is not a retreat. It is what `README.md` already says the
thing is — *"Measures motorcycle pitch (wheelie angle), speed, and lean"*,
*"Instrument first, feature last."* The correct market position and the correct
legal position turn out to be the same sentence, and it is the sentence already at
the top of the repo.

Three independent research tracks converged on it:

1. **App Store review.** An app whose stated purpose is coaching wheelies, with a
   live audible cue while riding and ranked competitive attempts, is a first-submission
   rejection at somewhere around 70–90%. Three separate clauses each independently
   suffice (§1). A pitch/lean/speed instrument for closed-course use is the framing
   every surviving motorsport app uses.
2. **Market size.** "Wheelie app" is a scene of maybe tens of thousands worldwide.
   "Motorcycle telemetry and lean angle" is every enthusiast rider — and the App
   Store already contains a cluster of lean-angle apps proving that demand exists
   (§2). Same code, an order of magnitude more addressable buyers.
3. **Differentiation.** Nobody measures wheelie pitch angle in degrees. That stays
   the killer feature — it is just discovered by the community rather than shouted
   in the metadata.

The wheelie is the reason people *love* it. Attitude telemetry is the reason people
*find* it and Apple *approves* it. Lead with the instrument, let the wheelie be the
thing riders discover and post about.

---

## 1. Gate zero: do these before anything else

None of the marketing matters if the app is rejected, or if one crash ends with a
lawsuit naming you personally. These are cheap relative to the exposure.

| Action | Why | Cost |
|---|---|---|
| **Form an LLC before first download** | Separates personal assets from company liability. Does not make you unsuable, but launching as a sole proprietor exposes savings directly. | ~$100–500 |
| **Talk to a lawyer in your state** | Specifically about negligent-design exposure for software used during a dangerous activity. Not optional here. | one consult |
| **Get general/products liability, not just tech E&O** | Tech E&O averages ~$121/mo ([Insureon](https://www.insureon.com/technology-business-insurance/mobile-app-developers/cost)) but typically **excludes bodily injury** — the only claim that matters. Disclose the real use case to the broker in writing. | ~$1.5k+/yr |
| **Make GPS opt-in and default OFF** | Highest-leverage single change. A pitch log with no coordinates cannot place a rider on a public road. Fitbit and Strava data are routinely admitted as criminal evidence ([AP](https://apnews.com/article/fitbit-evidence-murder-connecticut-1622942f936e01e7289c97d5790c84c1), [Strava LE policy](https://www.strava.com/legal/law_enforcement_guidelines)); insurers demand app data after crashes to deny claims. | ~free |
| **Keep run data on-device; no cloud leaderboard you host** | A central server of geolocated stunting logs is a subpoena target and makes you the custodian. Local personal bests carry the product fine. | free (saves work) |
| **First-launch closed-course gate + EULA** | Necessary for review even though a waiver will **not** bar gross-negligence or injury claims ([Santa Barbara v. Superior Court](https://www.johnphillipslaw.com/post/the-enforceability-of-liability-waivers-in-california-personal-injury-actions)). UK/EU/AU are *stricter* — UCTA 1977 voids injury disclaimers outright, and the 2024 EU Product Liability Directive now covers software explicitly. | lawyer time |

### The clauses that decide approval

Verbatim from the [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/):

- **1.4.4** — "should never encourage drunk driving or **other reckless behavior such
  as excessive speed.**"
- **1.4.5** — "Apps should not urge customers to participate in activities (like bets,
  **challenges**, etc.) or use their devices in a way that **risks physical harm**."
- **Section 5 chapeau** — "apps that solicit, promote, or **encourage criminal or
  clearly reckless behavior will be rejected.**"

1.4.5 is the sharpest threat because the ranked-attempts mechanic *is* a challenge
format. Note also **1.1.6** (inaccurate device data) — see §6 on why the accuracy
work is a marketing asset rather than a liability.

**What survives review looks like this.** [RaceChrono Pro](https://apps.apple.com/us/app/racechrono-pro/id1129429340):
*"a versatile lap timer, data logging and data analysis app designed especially for
use in motorsports… on closed circuit or special stage tracks."* Instrument nouns,
never "coach." Post-hoc analysis foregrounded. Speed as an incidental channel, not
a gamified goal.

**Feature-by-feature review risk:**

| Feature | Risk | Call |
|---|---|---|
| Pitch/lean/speed meters, calibration | Low | Ship, lead with it |
| Run history, charts, PBs (private) | Low | Ship |
| **Live audio cue while riding** | **Highest** | Keep, but gate behind explicit closed-course confirmation and keep it out of the metadata and screenshots. This is the feature to sacrifice if the first submission is rejected. |
| **Global/competitive leaderboards** | **High** (1.4.5) | Cut from v1. Private PBs give you 80% of the retention hook with none of the exposure. |
| "Wheelie" in app name/subtitle | Medium | Keep out of name and subtitle. Fine in the description body and in keywords. Do **not** hide it while the screenshots plainly show wheelie coaching — that is deceptive metadata (2.3) and makes things worse. |

---

## 2. What you are competing against

**No app measures wheelie pitch angle in degrees.** The niche is open.

- **[CurveRank](https://apps.apple.com/us/app/curverank-motorcycle-tracker/id6762086773)**
  ("#1 Curve & Wheelie Tracker") — 4.7★, 206 ratings, actively shipped (v1.5). But it
  *counts wheelies as events*; it does not measure the angle. Subscription-gated
  behind onboarding. One review flags accuracy problems. This is your closest thing
  to a competitor and it does not do the hard part.
- A cluster of lean-angle apps proves demand and validates the audio-cue idea:
  [Lean Angle+](https://apps.apple.com/us/app/lean-angle-moto-tilt-meter/id6761253773)
  (free, ad-supported, ships *voice lean-angle alerts*),
  [Alert Position](https://apps.apple.com/us/app/alert-position/id733678534),
  [Corner Speed](https://apps.apple.com/us/app/corner-speed/id1195318427),
  [Reva](https://apps.apple.com/us/app/reva-ride-tracker/id6760342790) (gates the live
  lean gauge behind a subscription), i-Ride.
- Android wheelie "apps" are duration-only accelerometer timers, likely abandoned.

### The one real competitor: Wheelie Coach (hardware, pre-launch)

[wheeliecoach.com](https://wheeliecoach.com/) is a handlebar-clamp device that
independently converged on **almost exactly this product**, including the physics and
the audio design:

- Measures pitch *through the lift*, explicitly noting that "the motion of lifting
  throws off their sense of 'down'" — the same specific-force problem the README opens
  with — and gates out the confused reading until steady. That is a validity gate.
- Learns the rider's own balance point rather than using a preset.
- Rate-coded audio: accelerating ticks → heartbeat in the pocket → continuous tone to
  brake. And their stated reason is the same one the audio research reached
  independently: *"the three cues differ by rhythm, not pitch or volume, because
  rhythm is what survives wind noise and a helmet."*
- Claims 2° accuracy steady, 5° while lifting. "You never look at it."

**Treat this as validation, not a threat, for four reasons.**

1. **It does not exist yet.** Rev 2.0 "prototype", "Early access", empty cart, no
   price, and the demo videos are still stock placeholders with the template
   instruction copy left in ("swap for your own clips once you have them"). This is a
   pre-launch landing page. You are not behind them.
2. **It is e-bike focused** — *"that's why it works on any e-bike."* No engine, so
   none of the 100 Hz alias problem. Different vehicle, adjacent market.
3. **It is hardware.** Manufacturing, supply chain, unit cost and a physical
   distribution problem, for a niche. Your marginal cost is zero and the rider already
   owns the sensor, the screen and the speaker.
4. **You already know something they do not.** Their loop-out alarm is *rate*-derived
   — "it looks at how fast you're tipping back." You shipped that, rode it, and
   removed it, because a fast flick at a low angle fired the full tone and read as a
   false alarm. That is hard-won device knowledge they have not paid for yet.

The genuinely interesting part is point 2. An e-bike or bicycle wheelie in a park is
not reckless driving, so **the entire §1 legal gate largely evaporates for that
market** — no 1.4.4/1.4.5 exposure, no geolocated record of a prosecutable offence,
no products-liability question about coaching an illegal maneuver. The sensor problem
is also *easier* (no engine alias). See open questions.

### Price anchors — everything the buyer already pays

| What | Price | Model |
|---|---|---|
| Lean Angle+ | Free (ads) | ad-supported |
| RaceChrono Pro | ~$20 (user-reported) | one-time |
| Harry's LapTimer | 3 one-time tiers | one-time |
| TrackAddict Pro | freemium → one-time IAP | 3-recording free cap |
| dragy Lite / RaceBox Mini / dragy Pro | $119 / $129–139 / $199 | hardware |
| AIM Solo 2 | ~$499 | hardware |
| Garmin Catalyst R1 | $799.99 | hardware |
| Wheelie Coach | unannounced (pre-launch) | hardware |
| **[SoFlo Wheelie School](https://www.soflowheelieschool.net/) — one day** | **$300** (own bike) / $350 (rental) | per session |
| [Stunt Asylum](https://rewards.bennetts.co.uk/rewards/stunt-asylum) UK | £270 (~$340) | per session |

**Read this table twice.** A rider chasing the balance point already pays **$300 for
a single day** of coaching, and $129–$800 for hardware that still cannot tell them
their pitch angle. Every plausible app price is a rounding error against that. You
are not competing on price — you are competing on being trusted.

Measurement-instrument apps price as one-time ~$10–30. Community/nav/safety apps
price as annual subscriptions. You are structurally the former but need the latter's
economics, which §4 resolves.

---

## 3. Who the customer actually is (and why the creator instinct is half right)

Your instinct that content creators are the channel is right. The targeting is wrong
in two ways.

**The user and the distributor are different people.** A pro stunt rider already
knows where the balance point is by feel. A degree readout is a novelty to them, not
a tool. The person who genuinely needs "you held 42° for 3.1s, your best was 38°" is
the **intermediate learner grinding toward the balance point.** But the pro has the
audience the learner is sitting in. So: build for the learner, market through the
creator, and never confuse the two.

**Micro beats mega, decisively.** Micro-influencers (10k–100k) average
[3.86% engagement vs 1.21% for mega](https://joinmavely.com/), at roughly
[a tenth of the cost](https://digitalapplied.com/). Mega channels (Yammie Noob
~1.55M, FortNine) are unreachable without a budget and their audience is mostly
non-wheelie anyway. The reachable, convertible tier is micro and nano — regional
wheelie coaches, learner-focused channels, and riders posting their own attempts.

**Cold outreach reality:** reply rates run [~3.4–5%](https://woodpecker.co/) even
with good copy. The lever that multiplies it is specificity — reference their actual
clip. Offer free lifetime Pro plus "I'll make you a custom overlay of your last
run." Never lead with cash you do not have; micro flat fees start around $100 and
run past $2,000 per deliverable.

**Constrain the partner list to closed-course and sanctioned riders.** Public-road
stunting is being actively criminalized — a NASCAR founder's great-grandson's channel
was [shut down by Florida's Super Speeder law](https://www.roadandtrack.com/), and
Brice Bennett was [arrested over 190mph+ public-road videos](https://nypost.com/).
A partner who gets arrested mid-campaign takes your brand with them, and "app that
sponsors street stunters" is the exact story that triggers a post-launch takedown
under 1.4.5. Red Bull / Monster athletes (Aaron Colton, Ernie Vigil) and stunt
academies ride controlled ground and are safe to associate with. Street channels are
not.

### The primary target: the wheelie *teacher*, not the wheelie *rider*

This is the sharpest segment in the whole plan, and it dissolves the user/distributor
mismatch above rather than working around it.

A pro performer doesn't need an angle readout — they have feel. But a **teacher's core
problem is that feel does not transmit.** They can say "find the balance point"; they
cannot show a student a number. For them the app is not a novelty, it is a
**pedagogical instrument** — the first objective feedback they can point at. The
"pros don't need it" objection simply does not apply to someone whose job is
explaining the thing rather than doing it.

Everything else lines up behind that:

- **Their audience is definitionally your user.** Someone who follows a "how to
  wheelie" account is a learner. That is a far cleaner match than a stunt performer's
  audience, which is mostly spectators.
- **Instruction is the one content format where an on-screen number is genuinely
  useful rather than a gimmick.** "Here is what 35° looks like next to 45°" is a
  better lesson than any verbal description — so the overlay makes their existing
  content better, which is the condition for unprompted use.
- **They teach on closed courses**, because that is the only way to teach legally and
  insurably. The segment self-selects for exactly the partner profile §1 requires.
- **Their reputation rests on judgment about technique**, so an endorsement from them
  carries more weight than a stunt rider's.

**And several of them are already selling digital products** — which makes them
resellers, not just channels. School of Wheelie sells a 3.5-hour
[course on Whop](https://whop.com/school-of-wheelie/master-the-wheelie/);
[Wheelie Academy CA](https://www.wheelieacademyca.com/) sells wheelie-machine
blueprints with video tutorials. They already have an audience they monetize and the
payment infrastructure to do it. So the conversation is not "please mention my app."
It is **"give your students a measurement tool"** — which converts to the $199/yr
coach tier, a student discount code, or a revenue share.

**Named starting list** (verify follower counts yourself; several are schools with an
instructor-influencer attached):

| Who | Where | Note |
|---|---|---|
| [Wheelie University](https://www.wheelieuniversity.com/) — Brian Steeves | San Diego | [Gear Patrol covered it](https://www.gearpatrol.com/cars/motorcycles/a223530/wheelie-university-san-diego/) — press-friendly, already a story |
| [School of Wheelie](https://whop.com/school-of-wheelie/master-the-wheelie/) | online | **Already sells a course.** Highest-fit reseller |
| [Wheelie Academy CA](https://www.wheelieacademyca.com/) | CA | Sells blueprints + video tutorials; builds wheelie machines |
| [Superbike-Coach](https://www.superbike-coach.com/portfolio-item/wheelie-course/) — Can Akkaya | CA | Full-day wheelie course, established brand |
| [SoFlo Wheelie School](https://www.soflowheelieschool.net/) | FL | $300/day, the price anchor |
| [Stunt Asylum](https://rewards.bennetts.co.uk/rewards/stunt-asylum) | UK | £270; Bennetts relationship = press adjacency |
| Live 100 MOTO (via [Riders-Share](https://www.riders-share.com/experience/RcdiPMmPspT62SSnc)) | US | Wheelie machine + training |
| [@tlivesay254](https://instagram.com/tlivesay254/) | IG | Runs camps; "I taught a complete noob" format |

Eight nameable targets before doing any real prospecting. Instagram and TikTok will
surface more — the segment is real, not theoretical.

### The ask, inverted

"Telling them about the app" is the weak version and will mostly get ignored. A
teacher's *first* question will be **"how accurate is it?"**, because their reputation
is what they'd be lending you. If the answer is "I haven't checked it against video
yet," you have burned a contact you cannot un-burn.

So lead with a question, not a pitch: ask what they wish they could show a student.
Their answers are free product direction from the people closest to your user, and
they will be specific — a coach view where the student rides and the instructor
reviews, a before/after export for a student's progress, angle held versus attempt
count across a day. That is the shape of the coach tier, and they should design it.

Expect **~3–5% reply rates** on cold outreach even with good copy. "Multiple
influencers" needs to mean 20–40 personalized messages, not three. The single lever
that multiplies response is referencing one specific clip of theirs.

---

## 4. Monetization: what, how, how much, when

### The model: free measurement, paid depth

Hard paywalls convert about **5x better** than freemium — 10.7% vs 2.1% median
download-to-paid, and ~8x the revenue per install
([RevenueCat](https://www.revenuecat.com/blog/growth/hard-paywall-vs-freemium)).
Despite that, **do not gate the measurement.** Your only growth channel is riders
posting clips with a number burned into them. Gate the live meter and you delete the
viral loop that is the entire marketing plan. RevenueCat names this as the legitimate
exception: reserve freemium for when free usage genuinely drives virality. It does here.

Slopes, Strava and Garmin all gate *analysis*, never the act of recording.

| Free — the funnel and the marketing | Paid — the depth |
|---|---|
| Live pitch / lean / speed meters | Unlimited run history + charts |
| Live audio cue (closed-course gated) | Target-band configuration |
| Last 10 runs | Multiple bike profiles |
| Personal best | CSV / telemetry export |
| Calibration, 1 bike profile | **Un-watermarked** video overlay export |
| **Watermarked** share clip / overlay | Session comparison, coaching insights |

Gate the **watermark, not the share.** Free shares carrying your mark are free
advertising; the clean export is the upgrade. This one detail is the difference
between a growth engine and a private logbook.

### Price

Motorcycling is seasonal in most of the northern hemisphere — exactly Slopes'
problem. Curtis Herbert **killed the monthly tier** because a July charge for a
winter app drove cancellations, and replaced it with an annual pass plus consumable
day passes, where anything recorded under a pass stays Premium forever
([pricing FAQ](https://slopes.helpscoutdocs.com/article/151-pricing-faq),
[RevenueCat interview](https://www.revenuecat.com/blog/growth/slopes-from-indie-side-hustle-to-1m-in-arr-and-an-apple-design-award)).
Transplant that structure directly.

| Tier | Price | Rationale |
|---|---|---|
| **Season Pass (annual)** | **$29.99/yr** | Primary revenue line. Well under Strava $79.99, Surfline $99.99, Garmin Connect+ $69.99. One tenth of a single wheelie-school day. |
| **Day pass (consumable)** | **$2.99** | Captures the casual seasonal rider who will never subscribe. Sessions recorded under it stay Premium forever. |
| **Lifetime unlock** | **$59.99** | The anti-subscription cohort is real and loud in moto communities. 2x annual. |
| **Coach / School tier** | **$199/yr** | Multi-rider management for instructors. OnForm's coach-pays-athlete-free model. |
| **No monthly tier** | — | Seasonality makes it a churn machine. |
| Free trial | **14 days** | 17–32 day trials convert **42.5%** vs **25.5%** for sub-4-day. 55% of 3-day-trial cancellations happen on **day zero**. |

Turn on **regional pricing** — North America realizes ~4x the LTV per download of
the global average. Protect NA/EU, discount emerging markets.

### When

**From day one, on depth — not later.** The two documented failure modes are both
fatal and they are opposites. Shipping free with a vague plan to "monetize later"
is the dominant indie failure — [56% of new apps never clear $1K](https://www.airbridge.io/blog/how-to-begin-marketing-a-subscription-app),
and a base trained on free is very hard to convert afterwards. Charging before the
user has felt the value is the other; an indie dev's
[postmortem](https://medium.com/@jonathansiddle/five-reasons-my-indie-flutter-app-failed-acc357a9df43)
names asking for money pre-value as his core mistake.

Free core plus a depth paywall present at launch threads both. Wire RevenueCat in
from the first build (free until real revenue) so you can A/B the paywall later.
Defer *price rises and new gates* until you have a happy free base — never the
paywall itself.

### Expected revenue — be honest with yourself

Health & Fitness runs ~$0.63 revenue per install; median year-one realized LTV is
$21.37. At a realistic 10–30k downloads and 2–5% conversion you are looking at
roughly **200–1,500 payers, i.e. $6k–$45k/yr gross**. Slopes made **$10,600 in its
first two years** and took nine years to $1M ARR. This is a real business and it is
not a salary for a long time.

Which is exactly why the **school/coach tier matters out of proportion** — 20 schools
at $199 equals hundreds of consumer conversions, from 20 conversations. And why the
lean-angle framing in §0 matters: it is the difference between a $10k niche and
something with room to grow.

### Side revenue

| Line | Verdict |
|---|---|
| Phone-mount / gear affiliate links on a "recommended setup" screen | **Yes, now.** Contextual, converts, zero downside. Users literally need a damped mount. Hundreds to low thousands per year. |
| Pro / coach tier | **Yes, once a consumer base exists.** Natural extension. |
| Moto brand sponsorship of challenges | **Later.** Needs visible community first. |
| B2B licensing to stunt schools | **Opportunistic.** Few buyers, each worth a lot. |
| Selling anonymized telemetry | **Never.** Torches the word-of-mouth that is your only channel, creates GDPR/CCPA exposure, and aggregating illegal-riding location data is a liability magnet. |

---

## 5. The one feature that is actually the marketing

**Build the overlay video export.** It is not in the M0–M5 milestones and it is the
single highest-leverage thing on the roadmap.

One tap, from a saved run to a postable clip with angle in degrees, a duration timer,
and a "NEW PB" flash burned in, watermarked with the app name. This is not a
nice-to-have; it *is* the growth engine, and without it the app is a private logbook
with nothing for anyone to show.

The precedent is unambiguous. Strava reached 125M athletes largely by turning GPS
data into social currency — stat stickers, the
["Strava fridge" overlay trend](https://www.dailydot.com/), Meta-glasses stat
overlays. Whoop did it with recovery scores. Sim racing did it with telemetry HUDs.
The number on screen is the advertisement.

It also fits the sport's native content format perfectly: "longest wheelie" is
already a canonical record framing, from
[Guinness distance records](https://www.guinnessworldrecords.com/) to Gary
Rothwell's 209mph wheelie. Riders already narrate in numbers. Hand them the number.

**Do not begin creator outreach until this works flawlessly and you have two or
three example clips you made yourself.** You get one shot per creator; spending it
before the shareable artifact exists wastes it.

Keep location out of the overlay. A rider choosing to post their own clip is their
decision; a coordinate you burned in is a fact you handed a prosecutor.

---

## 6. Positioning: the accuracy work is the differentiator

`README.md` contains an unusual asset: a genuine error budget. Gyro integration over
a 5–30s wheelie drifts 0.03–0.08°; the entire error budget is the pitch estimate and
gyro bias at wheelie onset; bias to ±0.5°/s costs 5° over a 10s hold, ±0.05°/s costs
0.5°. There is an ESKF, Allan deviation analysis, a validity gate, an accuracy matrix
(T3.9), an aliasing disclosure (T3.10), and 208 tests.

Meanwhile the nearest commercial competitor has 4.7 stars *and a review complaining
about accuracy.*

So the position is: **the one that is actually accurate, and here is the error budget
to prove it.** Publish the accuracy matrix. Show the confidence degradation as bias
goes stale. Explain why calibration takes 8 seconds and why the 100Hz engine-alias
problem is disclosed rather than hidden. That is the "engineer's instrument"
positioning, it is *true*, it is not copyable by an app that guessed, and it appeals
precisely to the rider who will pay $30/yr.

It also discharges Guideline 1.1.6 (no inaccurate device data): honest disclosed
uncertainty is the defense against an over-claim complaint. Never claim precision
the error budget does not support.

---

## 7. Where the audience actually is

Two assumptions worth killing before planning around them.

**The stunt forums are dead.** stuntride.org is technically still up — but its stunt
boards last saw real posts in 2013–2017, and current activity is off-topic (dating,
firearms). It is a nostalgia trickle, not an audience. Do not try to revive it.

**The national competition circuit is dead.** XDL, the "only national stunt
championship," has no coverage past ~2012–2013. Any plan built on XDL is built on
nothing.

The scene moved to short-form video, bike-specific Reddit, Facebook groups, and
Discord.

### Reddit — and the sub you would have guessed wrong

| Subreddit | Members | Fit | Promo |
|---|---|---|---|
| **`r/bikelife`** | **527K** | **The actual wheelie culture. Your #1 target.** | Tolerated more than elsewhere; mods vary |
| **`r/hondagrom`** | 35K | Wheelie-heavy — mini-moto *is* wheelie culture | 9:1 rule |
| **`r/supermoto`** | 69K | Wheelies core to the discipline | 9:1 rule |
| `r/GromSquad` | 5K | Wheelie-heavy, informal | Loose |
| `r/dirtbikes` | 156K | Good fit; has an official Discord | 9:1 rule |
| `r/motorcycle` | 300K | Looser than its big sibling | 9:1 rule |
| `r/sportbikes` / `r/Ninja400` / `r/CBR` / `r/MotoUK` | 30K / 15K / 17K / 60K | Secondary | 9:1 rule |
| `r/motorcycles` | 4.4M | **Deceptive.** Safety-culture dominant, moralizes stunt posts, promo removed on sight | Effectively banned |
| `r/motocamping` | 55K | Off-topic — skip | — |

Reddit's operative norm is the informal **9:1 rule** — no more than ~10% of your
activity self-promotional. Big moto subs remove naked "check out my app" posts
immediately. The only thing that works is a native clip with a genuine question.

Note: **`r/Wheelie`, `r/stunting`, `r/GromNation` and `r/SuperMotoJunkies` could not
be verified to exist.** The wheelie audience is distributed across r/bikelife and
r/hondagrom instead — which is itself the finding. Do not plan a post to a sub you
have not opened.

### Discord and forums that are alive
- **Motorsport Community** (dirtbike/offroad, 150–200k messages/month, tied to
  r/dirtbikes) — the single best Discord target.
- **hondagrom.net / gromforum.com** — small, alive, gear-nerd riders who document.
  Ideal beta validators.
- **supermotojunkie.com** — alive, real thread volume.
- **GTAMotorcycle.com** — has a *"closed-course only"* stunting subforum. Regional
  (Toronto) but the framing is already aligned with yours.
- Facebook bikelife/stunt groups exist and are large, but **sizes are unverifiable
  from outside** — check manually before investing.

### Events
**Stunt Warz** (stuntwarzofficial.com, SMT Wheels sponsors, active as of Mar 2026) is
the live US stunt event — multiple venues per year, large open lots, riders and
spectators together. An indie dev could realistically show up and demo. Schedule is
announced per-event on their socials, not centrally published.

Also: Moto Stunts International (UK display team — media angle, not a rider
gathering), and seasonal dealer stunt shows.

---

## 8. The calendar you are actually on

Riding season in the northern hemisphere runs **April–October, peaking May–September.**
It is now late August 2026. That means the in-person and organic-content window for
2026 is roughly **six weeks and then shut until spring.**

Treat that as a gift rather than a loss. It gives you a clean **build-through-winter,
launch-into-spring** shape:

| Window | Focus |
|---|---|
| **Sep–Oct 2026** | Last rideable weeks. Get M1 logger data and filmed ground truth *now* — this is the only thing that has a hard deadline, because you cannot collect wheelie data in January. |
| **Nov 2026 – Feb 2027** | Legal gate zero. Accuracy work (M3/M4). Build the overlay export. Submit and iterate through App Store review with no time pressure. Recruit beta creators, who are also indoors and bored. |
| **Mar–Apr 2027** | Launch into the start of the season. Content engine live. Approach schools as they open their calendars. |
| **May–Sep 2027** | Peak. Events, creators, press, the paid tiers earning. |

The one thing that must happen in the next six weeks is **data collection.** Everything
else can wait for the cold months.

---

## 9. Channel and sequence: who to contact, and when

Gated on **product maturity**, not calendar. Each gate exists because contacting
people before it is met burns the contact permanently — you get one first impression
per creator.

### Gate 0 — legal and framing (before anything public)
LLC, lawyer, liability insurance, GPS off by default, on-device storage, closed-course
gate, instrument framing in all metadata. **Contact nobody.** Ship nothing.

### Gate 1 — M1 logger + filmed rides with tripod ground truth *(do this before winter)*
The README already names this as the milestone before all others. You cannot claim
accuracy you have not checked against video.
**Contact:** 5–10 riders you personally know, plus one local session. Goal is
ground-truth data, not users. No public posts.

### Gate 2 — accuracy validated (M3/M4) + overlay export working
The two prerequisites for anyone else's attention. Note the split in who to ask and
why — these are different asks, not one:

1. **Mid-tier Grom/stunt/supermoto creators — for BETA.** They already film every
   ride, so video ground truth is free for them; they have rigs, they like gadgets,
   and they want content. Highest-yield beta channel by a distance. Offer free
   lifetime plus a "featured accuracy test" clip.
2. **Wheelie schools — for CREDIBILITY and B2B** (§3). Closed course, $300/day
   students who are exactly your user, instructor as micro-influencer. Free
   instructor accounts for feedback and permission to film.
3. **r/hondagrom, r/GromSquad, r/supermoto** — a sincere "help me validate my
   wheelie meter, I'll credit you" reads as genuine, not promo. Karma first.
4. **Post your own clips.** You are creator zero. Free, and it tests the hook before
   you spend a creator relationship on it.

### Gate 3 — App Store live, 50–100 real users, no accuracy complaints
**Contact:** r/bikelife (the big one — save it until the app is good, you get one
shot), Motorsport Community Discord, Facebook groups, larger creators now backed by
real UGC.

**Press, but as a story not a launch.** RevZilla's **Common Tread explicitly will not
run regurgitated press releases** — pitch the narrative instead: *an indie dev turned
an iPhone into a wheelie instrument, and here is the sensor-physics problem that made
it hard.* Your README is genuinely a better pitch than any press release. Outlets:
RideApart, Common Tread, Cycle World, MCN, Bennetts, Motorcycle.com, ADVrider.

**Product Hunt: post once, expect zero riders.** Only ~10% of launches now get
featured (down from 60–98% pre-2024) and the audience is SaaS makers, not stunt
riders. Do it for the permanent backlink, budget no hope beyond that.

### Gate 4 — retention and revenue proven
Moto brands for sponsored challenges, schools for paid B2B licensing, launch the
coach tier. Stunt Warz appearances in the spring–summer window.

### Channel ranking, honestly

| # | Channel | Realistic installs | Effort |
|---|---|---|---|
| 1 | **TikTok/Reels/Shorts — your own overlay clips** | 100s–low 1000s per hit; an occasional viral clip 5–20k | High, sustained |
| 2 | **App Store ASO** | Compounding forever; the durable baseline | Medium, one-time + iterate |
| 3 | Reddit organic (bikelife, hondagrom, supermoto) | 50–500 per well-received post | Medium; karma first |
| 4 | Moto Discords | 20–200 | Low–medium |
| 5 | Facebook groups | 50–500 | Medium; promo-hostile |
| 6 | Events (spring 2027) | 20–100 per event but **highest quality** | High; travel, seasonal |
| 7 | Press | 0, or 1000s on a hit | Low effort, low hit rate |
| 8 | Product Hunt | ~0 | Skip beyond the backlink |

TikTok is #1 not by preference but because that is where the audience physically is,
and because TikTok-driven installs show measurably better retention (39% lower
uninstall, 59% more week-one engagement per TikTok's own business data). This is the
second independent argument for building the overlay export first — it is the raw
material for channel #1.

---

## 10. The ASO conflict, and how to resolve it

This is a real conflict, not a wording problem, and it deserves stating plainly.

**The legally safe framing is the commercially crowded one.** "Lean angle" and
"telemetry" are contested by CurveRank, Lean Angle: Moto Tilt Meter, Lean Angle+,
BikeSensor, SafeRide Telemeter and Reva. Hard to rank.

**The commercially open keyword is the legally risky one.** "Wheelie meter" and
"wheelie angle" are low-competition, exact-match, high-intent long-tail gold — and
"wheelie" is precisely the word that draws Guideline 1.1 scrutiny.

**Resolution — exploit the fact that Apple reviews the storefront face, but indexes
more than that.** Review reads the app name, subtitle, description, screenshots and
the app's behavior. The **100-character keyword field is invisible to users** and
carries far less review salience while still being fully indexed for search.

| Surface | What goes there |
|---|---|
| **App name** | Brand + instrument noun. No "wheelie". |
| **Subtitle** | Instrument framing — pitch, lean, telemetry, closed course. Reviewed, so keep it clean. |
| **Keyword field (invisible)** | `wheelie, wheelie angle, wheelie meter, balance point, pitch angle, stunt, …` — capture the long tail here. |
| **Description body** | May discuss wheelie measurement, in measurement/training language with the closed-course framing. |
| **Screenshots** | Must match the subtitle's framing. This is the most common self-inflicted rejection: clean metadata over screenshots that plainly show wheelie coaching reads as deceptive metadata (2.3) and is *worse* than being honest. |

Because "wheelie meter" is low-competition, the keyword field alone may be enough to
rank first — that is what low competition means. You likely lose very little.

**Then reassess after approval.** Once you have an approval history and reviews
establishing the app as a measurement tool, moving "wheelie" into the subtitle
becomes a much smaller risk. Same logic as the audio cue: earn the track record
first, then spend it.

---

## 11. Stop signals

Know in advance what would tell you to stop pushing and fix something. Each of these
is a "the problem is upstream" signal, not a reason to market harder.

| Signal | What it means |
|---|---|
| Can't hit an accuracy you'd defend on camera | Sensor math. Everything downstream depends on the number being credible. |
| Fewer than 5 of 30–40 sincere beta asks bite | The value proposition isn't landing. Reframe before buying reach. |
| Beta riders measure once and never return | You have a novelty, not a habit. Fix the reason-to-return. |
| 30+ posted clips, near-zero profile clicks | The overlay isn't compelling or the CTA is missing. Fix the creative. |
| 90 days, working content loop, still a handful of engaged users | Product-market fit, not distribution. Go re-interview riders. |

A bigger audience for an app nobody reopens just burns the audience faster.

---

## Open questions

- **Whether e-bike / MTB is the better launch market, or a second one.** A bicycle
  wheelie in a park is not reckless driving, which deletes most of §1 — no 1.4.4/1.4.5
  exposure, no geolocated record of an offence, no coaching-an-illegal-maneuver
  liability — and the sensor problem is easier without an engine. Wheelie Coach chose
  that market deliberately. The counter-argument is that the moto rider is the one who
  already pays $300/day, and mounting a phone on a bicycle is a worse experience. Worth
  deciding before the App Store metadata is written, because it changes the framing.
- Season Pass at $29.99 vs $24.99 — worth an A/B once RevenueCat is wired.
- Whether the live audio cue ships in v1 at all, or is held for v1.1 after the app
  has an approval history and reviews establishing it as a measurement tool.
- Whether to keep any leaderboard concept as opt-in, local-only, and non-geolocated.
- Confirm CurveRank Pro's actual subscription price — the only direct-ish comparable
  whose price is still unknown.
- Watch Wheelie Coach's launch for a hardware price anchor, and for whether they
  extend from e-bikes to motorcycles.
