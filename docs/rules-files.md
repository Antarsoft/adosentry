# Writing and testing rules files

A rules file tells the reviewer what matters in one repository. In `rules` mode the engine sends the shared [base prompt](../ai-code-review/prompts/base.codereviewprompt.md) first and your rules file after it. The base prompt owns the input and output format, the severity levels, noise control and the untrusted-content policy. Your rules file owns what counts as a finding.

PullPicket ships a tested rules file for each common stack in [`examples/rules/`](../examples/rules). Copy the closest one into your repository, for example to `pipelines/ai-code-review/<repo>.rules.md`, and adapt it. The shipped files are a strong starting point, not a finished policy: you know which patterns your team uses on purpose, and the reviewer only knows what the file tells it.

## Layout

Every shipped file has the same four parts. Keep them when you adapt one.

```markdown
# Repository rules — <stack>

<One or two sentences: the stack and its major versions, and which file types to review.>

## <Stack> rules

### <Topic, such as Security or Data access>

1. <A pattern you can see in a diff>, <its consequence if that is not obvious>. (<SEVERITY>)

## Conventions to respect

<What linters, formatters and type checkers already enforce, and patterns that are intentional here.>
```

## What makes a good rule

- **It names a pattern that is visible in a diff.** "A route without the guard its siblings use" works. "Keep the code secure" does not: the model already tries to, and the sentence only adds noise.
- **It states its severity.** Use the base prompt's levels: `CRITICAL` for exposed secrets, auth bypasses, injection and data loss; `WARNING` for likely production bugs; `SUGGESTION` for quality and consistency. A rule with a severity is applied every time the pattern appears. A rule without one is treated as a judgment call.
- **It says why when the reason is not obvious.** "Every Server Action is a public HTTP endpoint" is what makes a missing auth check read as CRITICAL to a smaller model.
- **It matches the current framework.** Name the version in the first paragraph, and update rules when the framework changes a default (for example, Next.js 15 stopped caching `fetch` by default).
- **It leaves tooling alone.** Anything Prettier, ESLint, `gofmt`, `clippy`, `terraform fmt` or the compiler already reports goes under "Conventions to respect" as something not to comment on.

Keep a file between about 30 and 60 numbered rules at most. Every rule is sent with every batch, so a long file costs tokens on every review, and a file full of minor rules makes the important ones easier to miss.

## The quality bar for shipped files

A rules file in `examples/rules/` ships only when its samples in [`evals/`](../evals) pass on a large model at default settings, in each of three runs:

- every planted `CRITICAL` bug is caught at `CRITICAL`,
- at least 80% of planted `WARNING` bugs are caught at `WARNING` or above,
- no clean sample gets a `CRITICAL` or `WARNING` comment.

Every file is also run on a small model, and its scores are published per stack in [Rules file test results](rules-results.md) instead of being held to the same bar. Clients choose their own model and reasoning effort, so when a small model misses a rule that the large one catches, check whether the rule is too vague before blaming the model.

## Samples

Each stack has a folder in `evals/<stack>/` with one folder per sample:

```
evals/nextjs/server-action-no-auth/
  before/app/projects/[id]/actions.ts   the file before the change (leave out for new files)
  after/app/projects/[id]/actions.ts    the file after the change
  expect.json                           what the reviewer should find
```

```json
{
  "description": "A new Server Action deletes a project with no session check.",
  "findings": [
    { "id": "delete-no-auth", "file": "/app/projects/[id]/actions.ts", "anchor": "export async function deleteProject", "minSeverity": "CRITICAL", "tolerance": 3 }
  ]
}
```

- `anchor` is a piece of text from exactly one added line. If the text appears on several added lines, add `"occurrence": N` to pick the Nth from the top. The finding counts as caught when a comment lands within `tolerance` lines of it (default 2) at `minSeverity` or above.
- When a bug can fairly be reported on more than one line (a field and the line that writes it, a role binding and the role it names), list the other lines in `"alsoAt": [{ "anchor": "…" }]`. Each entry can also set its own `file`, `occurrence` and `tolerance`.
- Plant every bug on an added line. The reviewer can only comment on added lines, so a bug that exists only as a removed line (a deleted check, say) needs a nearby added line for the comment to land on.
- A sample with `"findings": []` is a clean sample: a realistic, correct change that should get no `CRITICAL` or `WARNING` comment. Every stack needs at least one. Clean samples are what keep a rules file from getting noisy.
- Use placeholder code and names only. Planted secrets must be made up: `.gitleaks.toml` skips `evals/` so they do not fail the secret scan, which also means a real secret there would go unnoticed.

The Pester suite checks that every sample is well formed, so a broken anchor fails CI before anyone spends tokens on it.

## Running the tests

[`tools/Invoke-RulesEval.ps1`](../tools/Invoke-RulesEval.ps1) builds the exact prompt the pipeline would send for each sample, asks a model, and scores the answer:

```powershell
$env:ANTHROPIC_API_KEY = '<key>'
./tools/Invoke-RulesEval.ps1 -Provider anthropic -Model claude-haiku-5-5 -Stack nextjs, nestjs -Runs 3

$env:AZURE_OPENAI_API_KEY = '<key>'
./tools/Invoke-RulesEval.ps1 -Provider azure -Model gpt-5-mini `
    -Endpoint 'https://<resource>.openai.azure.com/openai/v1/chat/completions'
```

`-Provider` is `anthropic`, `openai`, `azure` or `manual`. With `manual` no model is called: each sample's prompt is written to `evals/.work/<stack>/<sample>.prompt.md`, and any answer saved next to it as `<sample>.answer.json` is scored. The script prints a table per stack and run, lists every miss and every noisy comment, and exits with code 1 if a stack fails.

Every answer is saved under `evals/.work/<model>/` (or `-WorkDir`). After you change a sample's `expect.json`, `-Rescore` scores the saved answers again without calling the model.

Model answers vary from run to run, so use `-Runs 3` before you call a rules file done, and re-run the stacks you touched whenever the base prompt changes.
