# Traveler Spike

## Status

This work is parked.

`libllm`, `libtraveler`, and the `traveler` CLI are a successful spike, but they are not part of the Live V1 product plan.

Current intent:

- keep the code committed as a restart point
- do not wire it into Live routes, packaging, installers, or operator workflow
- do not assume local traveler extraction is broadly deployable on arbitrary shop-floor Windows hardware
- revisit in a future Live V2 effort if local-model runtime support and product priority justify it

The code is worth keeping because it proved the architecture and extraction path. It should be treated as parked product work, not dead code and not a current shipping dependency.

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

## Future Restart Notes

If this work is resumed later, the most relevant facts are:

- `libllm` is the generic local multimodal inference layer
- `libtraveler` is the traveler-specific prompt/schema/validation layer
- the intended product seam is `Live -> libtraveler -> LlmProvider <- libllm`
- the required traveler fields for useful extraction were:
  - `product_name`
  - `assembly`
  - `serial_number`
  - `bom_revision`
  - `atp_test_report_id`
- the major unresolved product risk was runtime viability on ordinary Windows shop hardware, not basic extraction quality on the tested Mac setup
