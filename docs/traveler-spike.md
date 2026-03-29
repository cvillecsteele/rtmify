# Traveler Spike

`traveler` is the spike CLI for local traveler extraction on top of `libtraveler` and `libllm`.

## Prerequisites

- local GGUF model file
- local `mmproj` GGUF file
- a traveler image file
- build from the `sys` repo with Zig

## Build

```bash
zig build traveler
zig build test-traveler
```

## Extract

```bash
zig build traveler
./zig-out/bin/traveler extract \
  --model /abs/path/Qwen3VL-2B-Instruct-Q4_K_M.gguf \
  --mmproj /abs/path/mmproj-Qwen3VL-2B-Instruct-F16.gguf \
  --image /abs/path/traveler.jpg \
  --format pretty \
  --show-raw
```

## Evaluate a corpus

```bash
zig build traveler
./zig-out/bin/traveler eval \
  --model /abs/path/Qwen3VL-2B-Instruct-Q4_K_M.gguf \
  --mmproj /abs/path/mmproj-Qwen3VL-2B-Instruct-F16.gguf \
  --manifest test/fixtures/traveler/corpus.json \
  --format markdown
```

## Interpretation

- `accepted`: required fields were extracted and the derived product identifier was computed.
- `rejected`: required fields were missing or failed validation.
- `normalization_gap`: reserved for cases where required fields are usable but canonical Live identifier derivation remains ambiguous.

Primary rejection reasons for this spike:

- `missing_product_name`
- `missing_assembly`
- `missing_serial_number`
- `missing_bom_revision`
- `missing_atp_test_report_id`
- `header_component_confusion`
- `footer_boilerplate_capture`
- `repeated_key_flattening`
- `structurally_invalid_json`

## Tracked Baseline Corpus

The repo carries a first redacted baseline case under:

- `test/fixtures/traveler/images/vs200-baseline.JPG`
- `test/fixtures/traveler/cases/vs200-baseline.json`

That baseline exists to make `traveler eval` immediately useful and reproducible. It should be expanded as additional messy traveler examples are redacted and committed.
