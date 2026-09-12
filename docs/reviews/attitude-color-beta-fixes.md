# Beta: metric colors and attitude recovery

Angle and speed preferences now reach live values and labels, run summaries,
chart maxima and axes, scrubber values, interval timelines, history and settings.
History bars keep their relative lengths; angle/speed use their selected colors.
Duration ranking and warning/record badges retain their semantic colors.

The swipe solver previously projected a screen-plane line off gravity. On an
oblique mount that changes its screen direction, introducing a heading error
that couples lean into pitch. The solver now preserves screen X:Y and solves
for the missing Z using the measured gravity constraint. Near-vertical screens
still use the rider-facing screen-normal assumption: their forward component
cannot be recovered uniquely. Repeat calibration and the alignment swipe when
reviewing this build. Incorrect swipe direction or phone movement in its mount
can still produce incorrect measurements.

The raw-gyro estimator previously had no drift recovery. It now refreshes bias
and gravity after three continuous seconds of independent stop evidence:
fresh raw GNSS speed <= 0.3 m/s with accuracy <= 0.5 m/s, stable near-gravity
specific force, and low/stable rotation. Events, turns, acceleration, vibration,
saturation and gaps cancel the window. Updates preserve mount axes and heading;
they do not force a stationary slope or leaning bike to zero pitch/roll.
The pipeline logs correction count and the current bias. The reported sigma
remains a partial mean-error model, not a complete accuracy guarantee.

This bounds drift between confirmed stops. It cannot remove gyro drift during
sustained riding, a flight, disabled speed sensing, or unavailable/unreliable GPS.
S3/flight logs were not inspected because AWS access was unavailable and the user
asked to skip that work. Physical ride validation remains necessary.

Regression coverage includes compound mounts, left/right banked turns, real
42-degree pitch with lean, warm-up bias drift in both directions, stationary
slope/lean preservation, stale/missing/inaccurate GPS, apparent display-speed zero,
acceleration, slow tilt, vibration, active events, saturation and sample gaps.

CI calls the reusable Release Beta (TestFlight) workflow only after the core
suite and Debug/Beta/Release iOS jobs succeed on a push to beta/main. It checks
out the same commit that passed CI. Pull requests cannot trigger uploads. The
existing manual Beta release remains available; public releases are unchanged.
