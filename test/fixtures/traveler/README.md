# Traveler Corpus

This directory holds the tracked redacted corpus for the traveler spike.

Layout:

- `corpus.json`: manifest listing case JSON files
- `cases/<case-id>.json`: expected fields and acceptable status for one image
- `images/<case-id>.*`: the matching redacted traveler image

Current tracked baseline:

- `cases/vs200-baseline.json`
- `images/vs200-baseline.JPG`

The case file is the evaluation truth. It is allowed to disagree with the current model output; the harness exists to measure exactly those mismatches.
