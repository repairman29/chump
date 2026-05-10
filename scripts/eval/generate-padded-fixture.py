#!/usr/bin/env python3
"""generate-padded-fixture.py — EVAL-101: create neutral-padded fixture for Cell C.

Reads the reflection_tasks.json fixture, appends ~500 tokens (~2000 chars) of
neutral text to each task's "prompt" field. The padding is Lorem-ipsum-style
prose about an unrelated topic (historical weather patterns) so it adds token
count without triggering confound-relevant cognitive processing.

Usage:
  python3 scripts/eval/generate-padded-fixture.py [--n-tokens 500] [--seed 42]
  # Writes to scripts/eval/fixtures/reflection_tasks_padded.json

Preregistration: docs/eval/preregistered/EVAL-101.md §3 (Cell C)
"""

import argparse, json, os, random

PADDING_SOURCE = (
    "Historical weather patterns across the European continent have been "
    "meticulously recorded since the early eighteenth century when the first "
    "mercury barometers were deployed in observatories from London to Saint "
    "Petersburg. These records reveal a complex interplay between Atlantic "
    "oscillations, continental air masses, and solar irradiance that "
    "meteorologists continue to study with increasingly sophisticated models. "
    "The correlation between barometric pressure gradients and subsequent "
    "precipitation events was first systematically documented by the British "
    "Meteorological Office in 1854, establishing a methodological framework "
    "that remained largely unchanged for over a century. Temperature records "
    "from the Central England Temperature series, which began in 1659, "
    "represent the oldest continuous instrumental temperature record in "
    "existence and have been instrumental in understanding long-term climate "
    "variability. The seasonal migration of the Intertropical Convergence Zone "
    "drives monsoon patterns that affect billions of people across South Asia "
    "and West Africa, yet predicting the precise timing and intensity of these "
    "seasonal shifts remains a formidable challenge even with modern satellite "
    "observations and ensemble forecasting techniques. Ocean currents such as "
    "the North Atlantic Drift moderate coastal climates by transporting warm "
    "water from equatorial regions toward higher latitudes, a process that "
    "keeps ports in Norway ice-free year-round while similar latitudes in "
    "Canada remain frozen for months. The study of tree rings, or dendrochronology, "
    "has provided scientists with a proxy record of growing-season conditions "
    "stretching back thousands of years, revealing patterns of drought and "
    "plenty that shaped human migration and agricultural development across "
    "multiple continents. Atmospheric pressure systems typically move from "
    "west to east in mid-latitudes due to the prevailing westerlies driven by "
    "the Coriolis effect, though blocking patterns can cause weather systems "
    "to stall over a region for extended periods, leading to prolonged heat "
    "waves or flooding events. The development of weather radar during World "
    "War II marked a turning point in the ability to track precipitation in "
    "real time, and the subsequent deployment of doppler radar networks has "
    "dramatically improved the accuracy of severe weather warnings for "
    "tornadoes and thunderstorms. Weather balloons launched twice daily from "
    "over nine hundred stations worldwide provide the vertical profiles of "
    "temperature, humidity, and pressure that form the backbone of numerical "
    "weather prediction models, which have improved their five-day forecast "
    "accuracy by approximately one day per decade since the 1980s."
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n-tokens", type=int, default=500)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--input", default="scripts/ab-harness/fixtures/reflection_tasks.json"
    )
    parser.add_argument(
        "--output", default="scripts/eval/fixtures/reflection_tasks_padded.json"
    )
    args = parser.parse_args()

    random.seed(args.seed)

    with open(args.input) as f:
        fixture = json.load(f)

    # Each padding "token" ≈ 4 characters. Generate a neutral string of
    # approximately n_tokens * 4 chars by cycling the padding source.
    target_chars = args.n_tokens * 4
    padding = (PADDING_SOURCE * ((target_chars // len(PADDING_SOURCE)) + 2))[
        :target_chars
    ]

    for task in fixture.get("tasks", []):
        if "prompt" in task:
            task["prompt"] = task["prompt"].rstrip() + "\n\n[CONTEXT]\n" + padding

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(fixture, f, indent=2)

    count = len(fixture.get("tasks", []))
    print(f"Wrote {count} tasks to {args.output}")
    print(f"  Padding: ~{args.n_tokens} tokens per task")


if __name__ == "__main__":
    main()
