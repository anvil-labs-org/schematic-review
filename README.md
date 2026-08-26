# Anvil Schematic Review

Run an [Anvil](https://anvil.design) schematic review of your board on every
pull request. The action reviews the PR's head commit and links the review in
the job log and summary; each reviewed commit becomes the next revision of
your board in Anvil.

## Usage

Create an organization API key in Anvil (**Settings → API Keys**) and store it
as the `ANVIL_API_KEY` secret in your repository. Then add
`.github/workflows/anvil-review.yml`:

```yaml
name: anvil-review
on: pull_request

jobs:
  review:
    name: review (${{ matrix.board }})
    runs-on: ubuntu-latest
    timeout-minutes: 60
    strategy:
      fail-fast: false
      matrix:
        include:
          # Your boards — one "- board:" entry per board.
          - board: main-board
            schematic: boards/main/main.kicad_sch
    steps:
      - uses: anvil-labs-org/schematic-review@v1
        with:
          api-key: ${{ secrets.ANVIL_API_KEY }}
          schematic-path: ${{ matrix.schematic }}
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `api-key` | yes | — | Anvil organization API key. |
| `schematic-path` | yes | — | Repository-relative path of the board's top-level schematic file, or its folder. |
| `auto` | no | `"true"` | Proceed without in-app confirmations of part normalization and BOM mapping. Still in development. |
| `strict` | no | `"false"` | Fail the check when the review finds critical or major issues. |
| `api-url` | no | `https://api.anvil.design` | Anvil API base URL. |

## Exit codes

- `0` — review completed (with `strict`: completed and passed), or a human
  step is pending in Anvil (linked in the job summary).
- `1` — review gate failed (`strict` only).
- `3` — service error or timeout.

Re-running a job is safe: the same repository, commit, and schematic return
the existing review instead of starting a new one.
