# Rules file test results

The latest results for every shipped rules file in [`examples/rules/`](../examples/rules). Each stack has three samples (two with planted bugs, one clean change), and each model ran every sample three times with the same prompt the pipeline sends. How the tests work is in [Writing and testing rules files](rules-files.md).

- **Run:** 2 November 2026, PullPicket `development` with the base prompt from this release.
- **Large model:** Claude Opus 5.5 (`claude-opus-5-5`), default settings.
- **Small model:** Claude Haiku 5.5 (`claude-haiku-5-5`), default settings.
- **CRITICAL** and **WARNING** columns show the share of planted bugs caught at that severity or above, across the three runs.
- **Noise** counts `CRITICAL` or `WARNING` comments on the clean sample across its three runs. Zero is the target.

| Rules file | Large: CRITICAL | Large: WARNING | Large: noise | Small: CRITICAL | Small: WARNING | Small: noise |
| --- | --- | --- | --- | --- | --- | --- |
| [Angular](../examples/rules/angular.rules.md) | 100% | 100% | 0 | 100% | 100% | 0 |
| [ASP.NET Core](../examples/rules/aspnetcore.rules.md) | 100% | 100% | 0 | 67% | 100% | 0 |
| [Bicep](../examples/rules/bicep.rules.md) | 100% | 100% | 0 | 100% | 100% | 5 |
| [C++](../examples/rules/cpp.rules.md) | 100% | 100% | 0 | 100% | 100% | 4 |
| [Django](../examples/rules/django.rules.md) | 100% | 100% | 0 | 100% | 83% | 5 |
| [Dockerfiles and Compose](../examples/rules/docker.rules.md) | 100% | 92% | 0 | 100% | 100% | 0 |
| [FastAPI](../examples/rules/fastapi.rules.md) | 100% | 100% | 0 | 78% | 100% | 0 |
| [Go](../examples/rules/go.rules.md) | 100% | 100% | 0 | 100% | 100% | 0 |
| [Kubernetes and Helm](../examples/rules/kubernetes.rules.md) | 100% | 100% | 0 | 100% | 89% | 2 |
| [NestJS](../examples/rules/nestjs.rules.md) | 100% | 100% | 0 | 83% | 100% | 1 |
| [Next.js](../examples/rules/nextjs.rules.md) | 100% | 100% | 0 | 89% | 100% | 5 |
| [Node.js with Express](../examples/rules/node-express.rules.md) | 100% | 100% | 0 | 93% | 100% | 0 |
| [React with Vite](../examples/rules/react-vite.rules.md) | 100% | 100% | 0 | 100% | 100% | 0 |
| [Rust](../examples/rules/rust.rules.md) | 100% | 100% | 0 | 100% | 100% | 0 |
| [Spring Boot](../examples/rules/spring-boot.rules.md) | 100% | 100% | 0 | 100% | 100% | 0 |
| [SQL migrations](../examples/rules/sql-migrations.rules.md) | 100% | 100% | 0 | 56% | 67% | 1 |
| [Terraform](../examples/rules/terraform.rules.md) | 100% | 100% | 0 | 75% | 83% | 8 |
| [Vue](../examples/rules/vue.rules.md) | 100% | 100% | 0 | 100% | 100% | 2 |

## What this means for choosing a model

The large model meets the shipping bar on every stack. It caught every planted bug and left every clean sample alone; the one gap was a `latest` image tag rated `SUGGESTION` instead of `WARNING` in one of three runs.

The small model catches most planted bugs but is noisier. On several stacks it posts `WARNING` comments on correct code, and on SQL migrations and Terraform it often rates a `CRITICAL` finding lower. For pull requests where false alarms cost reviewers time, use a mid-sized or large model. A small model is fine for a first pass on low-risk repositories if your team is happy to dismiss some noise.

Other model families (GPT, Llama, Mistral) were not part of this run. Test yours with `tools/Invoke-RulesEval.ps1 -Provider azure` or `-Provider openai`, as shown in [Writing and testing rules files](rules-files.md#running-the-tests).
