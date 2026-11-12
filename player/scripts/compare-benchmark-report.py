#!/usr/bin/env python3
"""Compares a fresh benchmark report (the BenchmarkReport JSON the bench
writes on the device) against the archived baseline, and prints what moved.

Exit code 0: clean, or every difference found is within the threshold or
otherwise explained (a different encoder, an unverifiable clip, a clip
measured on one side and not the other). Exit code 1: a regression beyond
the threshold on a clip both sides measured with the same encoder - decode
time, time to first frame, seek latency or the rebuffer count - or a hard
failure the run's own "verdicts" list already carries (hardware that should
have decoded did not, a dropped frame, a rebuffer, decode slower than real
time).

The decode-time threshold defaults to 20%, on this reasoning: a
hardware-to-software fallback is already caught structurally by the run's
own verdicts (an order of magnitude, not a percentage), so this threshold
only has to catch a smaller regression within the same decode path - a
redundant copy added, a pixel format conversion that used to be skipped -
while surviving the ordinary run-to-run jitter of an unisolated on-device
measurement (thermal throttling, background daemons) that a single sample,
not an average of several runs, cannot tell apart from a real change. 20%
clears that jitter and still catches a real regression; raise it only with
the same reasoning applied to a specific false positive, never merely
because a run failed it.

The two latencies get their own, wider threshold - 50% over an absolute
floor of 0.05 s - because they are not the same kind of measurement.
Decode time is a mean over sixty frames; time to first frame and seek
latency are each a single event, and each carries one-off costs (opening
the file, building the decode session, the distance to the next keyframe)
that move far more between two runs of identical code than a mean does. A
20% band would fire on that alone. The floor is what keeps a 10 ms wobble
on a 100 ms open from reading as a 10% move on a number that small; below
it, no percentage is meaningful. 50% catches the shape a real regression in
either path takes - a doubling, not a nudge.

The rebuffer count has no threshold at all and is compared on every run,
simulator included: it is a count of stalls, not a speed, so nothing about
the machine underneath makes one legitimate. Every corpus clip is a local
file, so any increase over the baseline is the pipeline.

Usage: compare-benchmark-report.py --baseline PATH --run PATH
       [--threshold-percent 20] [--latency-threshold-percent 50]
       [--latency-floor-seconds 0.05]

player/Tests/BenchmarkReportFixtures/ carries one small, two-clip report per
scenario this script has to tell apart: baseline.json/regressed.json (a 50%
decode-time regression), latency-regressed.json (decode time untouched, both
latencies roughly doubled - only the latency threshold catches it),
clean.json (a change under the threshold), different-encoder.json (a huge
number, but not attributable - different encoder), unverifiable.json (a huge
number, but not attributable - the clip was never confirmed),
subset.json/superset.json (a clip on only one side), simulator.json (numbers
that must never read as evidence about hardware), and hardfail.json (one of
the run's own hard failures). Running this script with --run set to each in
turn against baseline.json is how its own behaviour is checked.
"""
import argparse
import json
import sys


def load(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        # The baseline is the file most often missing, and nothing here can
        # invent one: a number no hardware produced is worse than no baseline.
        raise SystemExit(
            f"{path}: no such report.\n"
            "A baseline comes from a real run on a real Apple TV: run the "
            "bench from Settings > Diagnostics, retrieve "
            "Documents/lexis-benchmarks/report-*.json through Xcode's Devices "
            "window or Finder file sharing, and pass it as --baseline."
        )


def clips_by_file(report):
    return {clip["file"]: clip for clip in report["clips"]}


def compare_decode_time(file, base_clip, run_clip, threshold_percent):
    """Prints the decode-only mean per clip and returns True if it is a
    regression beyond the threshold. decodeOnly is compared, not playback:
    the playing run's own decode timing only resolves on the tone-mapped
    path (spec), so most clips read unmeasured there, while the decode-only
    run measures every path - it is the only number always comparable
    across the whole corpus."""
    base_decode = base_clip["decodeOnly"]
    run_decode = run_clip["decodeOnly"]
    if not base_decode["succeeded"] or not run_decode["succeeded"]:
        print(f"{file}: decode-only unmeasured in baseline or run, skipped")
        return False
    base_mean = base_decode["decodeMillisecondsMean"]
    run_mean = run_decode["decodeMillisecondsMean"]
    if base_mean == 0 or run_mean == 0:
        print(f"{file}: decode time unmeasured in baseline or run, skipped")
        return False
    change_percent = (run_mean - base_mean) / base_mean * 100
    regression = change_percent > threshold_percent
    flag = " REGRESSION" if regression else ""
    print(
        f"{file}: decode-only {base_mean:.2f}ms -> {run_mean:.2f}ms "
        f"({change_percent:+.1f}%){flag}"
    )
    return regression


def compare_latency(file, label, base_value, run_value, threshold_percent, floor_seconds):
    """Prints one of the playing run's two single-event latencies and returns
    True if it regressed past both the percentage and the absolute floor. -1
    is the runner's own UNMEASURED (no first frame ever arrived for the open,
    or no seek ever landed one) and is skipped rather than read as 0."""
    if base_value < 0 or run_value < 0:
        print(f"{file}: {label} unmeasured in baseline or run, skipped")
        return False
    change = run_value - base_value
    change_percent = change / base_value * 100 if base_value > 0 else 0.0
    regression = change > floor_seconds and change_percent > threshold_percent
    flag = " REGRESSION" if regression else ""
    print(
        f"{file}: {label} {base_value:.3f}s -> {run_value:.3f}s "
        f"({change_percent:+.1f}%){flag}"
    )
    return regression


def compare_rebuffers(file, base_clip, run_clip):
    """Prints the playing run's rebuffer count both sides and returns True if
    this run stalled more often than the baseline. No threshold and no
    simulator exemption: a stall on a local corpus clip is the pipeline
    whatever machine it ran on."""
    base_count = base_clip["playback"]["rebufferCount"]
    run_count = run_clip["playback"]["rebufferCount"]
    regression = run_count > base_count
    flag = " REGRESSION" if regression else ""
    print(f"{file}: rebuffers {base_count} -> {run_count}{flag}")
    return regression


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--run", required=True)
    parser.add_argument("--threshold-percent", type=float, default=20.0)
    parser.add_argument("--latency-threshold-percent", type=float, default=50.0)
    parser.add_argument("--latency-floor-seconds", type=float, default=0.05)
    args = parser.parse_args()

    baseline = load(args.baseline)
    run = load(args.run)
    failed = False

    if run["verdicts"]:
        failed = True
        print("hard failures in this run:")
        for verdict in run["verdicts"]:
            print(f"  {verdict['file']}: {verdict['message']}")

    if run.get("isSimulator"):
        print(
            "this run is on the tvOS simulator: every codec decodes in "
            "software there, so the decode-time and latency comparisons "
            "below are not evidence about hardware performance and are "
            "skipped; the rebuffer count is still compared, since a stall "
            "is a count and not a speed"
        )

    base_clips = clips_by_file(baseline)
    run_clips = clips_by_file(run)

    for file, run_clip in run_clips.items():
        base_clip = base_clips.get(file)
        if base_clip is None:
            print(f"{file}: not in the baseline, nothing to compare")
            continue
        if not base_clip["verified"] or not run_clip["verified"]:
            reason = base_clip["unverifiableReason"] or run_clip["unverifiableReason"]
            print(f"{file}: unverifiable ({reason}), not compared")
            continue
        if base_clip["encoder"] != run_clip["encoder"]:
            print(
                f"{file}: different encoder (baseline: {base_clip['encoder']}, "
                f"this run: {run_clip['encoder']}) - different, look into it, "
                f"not compared"
            )
            continue
        if compare_rebuffers(file, base_clip, run_clip):
            failed = True
        if run.get("isSimulator"):
            continue
        if compare_decode_time(file, base_clip, run_clip, args.threshold_percent):
            failed = True
        base_play = base_clip["playback"]
        run_play = run_clip["playback"]
        for label, key in (
            ("time to first frame", "timeToFirstFrameSeconds"),
            ("seek latency", "seekLatencySeconds"),
        ):
            if compare_latency(
                file, label, base_play[key], run_play[key],
                args.latency_threshold_percent, args.latency_floor_seconds,
            ):
                failed = True

    for file in base_clips:
        if file not in run_clips:
            print(f"{file}: in the baseline, not measured by this run")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
