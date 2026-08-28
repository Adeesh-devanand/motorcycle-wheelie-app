I'll read the CalibrationService and the two allowed core files.Now I have the full picture. The key finding is in `feedIMU`: after `.done`, `estimator` is set to nil, and `canAutoStart` is purely a cooldown check that ignores the calibrated state. Let me read the two allowed core files to confirm `biasStaleAfter` and tracker semantics.I have everything needed. The root cause is confirmed by the code.

## Root cause

`CalibrationService.feedIMU` — `/Users/vinothiniraju/Documents/Ade