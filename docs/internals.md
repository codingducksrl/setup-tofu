# tofu-setup internals

How the action works and why. For usage, see the [README](../README.md).

## Design constraints

- **Two accounts, two roles, two independent trust boundaries.** Both roles are assumed
  directly from the job's GitHub OIDC token. There is no role chaining (the target role
  never assumes the state role) and no `assume_role` in the backend.
- **State credentials exist only as a named AWS profile** (default `tf-state`). The
  target credentials are the ambient `AWS_*` environment variables. The S3 backend uses
  the profile, and the AWS provider uses the environment.
- **Variables are delivered only as `TF_VAR_<name>`.** OpenTofu parses environment values
  against the declared variable type (string stays string, number/bool convert,
  list/map/object parse as HCL), so the action never guesses types. No tfvars file is
  generated.
- **Secrets never touch disk in plain text by the action's doing.** They are masked before
  they reach `$GITHUB_ENV`, and they are never printed, logged or returned as outputs.
- **It is a composite action, not a reusable workflow.** A reusable workflow runs as a
  separate job and cannot set environment variables for the caller's steps.

## Flow

```
GitHub OIDC token ──► state role  ──► profile in ~/.aws ──► S3 backend, SSM parameters
                 └──► target role ──► AWS_* environment ──► AWS provider
```

`action.yml` runs four steps:

| step | what it does |
|---|---|
| Validate inputs | `scripts/setup.sh check`: validates the inputs and resolves the role ARNs into step outputs |
| AWS credentials (state) | `configure-aws-credentials` with `aws-profile`: writes `~/.aws/credentials` and `~/.aws/config` only |
| AWS credentials (target) | `configure-aws-credentials`: exports `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`, `AWS_REGION` and `AWS_DEFAULT_REGION` |
| Backend + variables | `scripts/setup.sh`: asserts both identities, writes the backend file, exports the parameters |

`action.yml` only wires inputs to `TFS_*` environment variables. The script reads nothing
else, and no `${{ inputs.* }}` expression appears in a `run:` body (script injection).

## Step 1: input validation (`setup.sh check`)

This runs before any role is assumed, for two reasons:

- GitHub does not enforce `required: true` for composite actions. A missing input would
  otherwise surface as an obscure error from `configure-aws-credentials`.
- The credential steps need the role ARNs. Unless they are passed explicitly, they are
  derived from the naming convention:

  ```
  state:  arn:aws:iam::<state-account>:role/terraform-<env>-action-role
  target: arn:aws:iam::<target-account>:role/terraform
  ```

  The resolved ARNs are written to `$GITHUB_OUTPUT` (`state-role-arn`, `target-role-arn`),
  and the credential steps read them from `steps.check.outputs`.

Checks, in order:

1. Required inputs: `env`, `state-account`, `target-account`, `state-bucket`,
   `state-region`.
2. Booleans (`use-lockfile`, `strict-vars`, `disable-input`) are `true` or `false`.
3. `env` is `dev`, `staging` or `production`.
4. Both account ids are 12 digits and differ from each other. The same account in both is
   reported as "separation lost".
5. Each role ARN (default or explicit) is an IAM role ARN in its declared account.
6. The bucket name is a valid S3 bucket name.
7. `state-key` uses only letters, digits, `/`, `=` and `` !-_.*'() ``, and does not
   start or end with `/` or contain `//`.
8. Region names, the profile name and the SSM prefix (an absolute path) contain only safe
   characters.
9. `backend-file` is a plain file name ending in `_override.tf`.
10. `aws`, `jq` and `base64` are on `PATH`.
11. The working directory exists. Inside Actions, `ACTIONS_ID_TOKEN_REQUEST_URL` must be
    set. The runner sets it for script steps only when the job has
    `permissions: id-token: write`.

The character restrictions exist because these values are interpolated into HCL strings
(`"`, `\`, `${`, `%{` and newlines would inject configuration) and into SSM paths.

## Steps 2 and 3: credentials

Both steps use `aws-actions/configure-aws-credentials`, pinned by SHA (v6.3.0). The
behaviours below were checked against that version's source.

- **`aws-profile`** (state step). With a profile set, `output-env-credentials` defaults to
  false. The action writes `[<profile>]` to `~/.aws/credentials` and
  `[profile <profile>]` with `region` to `~/.aws/config` (or to `AWS_SHARED_CREDENTIALS_FILE`
  / `AWS_CONFIG_FILE`). It exports neither credentials, `AWS_REGION` nor `AWS_PROFILE`.
- **`overwrite-aws-profile: true`**. Without it, the step fails if the profile already
  exists, which happens on persistent self-hosted runners.
- **`allowed-account-ids`**. The step fails if the assumed credentials belong to another
  account.
- **`role-chaining: false` and `translate-env-variables: false`**. By default the action
  copies job environment variables (`AWS_REGION`, `ROLE_TO_ASSUME`, `ROLE_CHAINING`,
  `USE_EXISTING_CREDENTIALS`, `UNSET_CURRENT_CREDENTIALS`, `OVERWRITE_AWS_PROFILE`, …)
  into any input that is not set. A job-level `ROLE_CHAINING=true` could then turn on role
  chaining. Side effect: proxies configured only through `HTTPS_PROXY` or `NO_PROXY` are
  not picked up by these steps. `HTTP_PROXY` still is.
- **Session names** `tofu-state-<run id>` and `tofu-deploy-<run id>` make CloudTrail
  entries traceable to a workflow run.
- **Cleanup.** The post step clears the environment variables the target step set. With
  `aws-profile` it does nothing, so the profile files stay in `~/.aws` until the runner is
  discarded.

## Why the backend gets the state credentials

The generated backend sets `profile = "<state-profile>"`, and the provider sets no
profile.

- OpenTofu's S3 backend passes a configured `profile` to the AWS SDK as an explicitly
  selected profile. In aws-sdk-go-v2 (`config.resolveCredentialChain`), an explicitly
  selected profile takes precedence over environment credentials. The environment
  credentials win only when no profile was selected in code.
- The AWS CLI behaves the same way with `--profile`, which the identity assertions use.
  An `AWS_PROFILE` *environment variable* does not beat environment credentials, which is
  why the script only warns about it.
- This was checked with OpenTofu 1.12.3. With environment credentials set and the profile
  missing, `tofu init` fails with `failed to get shared config profile, tf-state`, so it
  never falls back to the environment.
- It fails closed. If the backend ever used the target credentials, `tofu init` would get
  access errors, because neither role has permissions in the other account.

## Step 4: backend and variables (`setup.sh`)

Nothing below writes to `$GITHUB_ENV` or `$GITHUB_OUTPUT` until the very end.
Every checked failure exits with status 2.

### Identity assertions

Run before any file is written, after a warning if `AWS_PROFILE` is set:

1. `aws sts get-caller-identity --profile <profile> --region <state-region>` must return
   `state-account`.
2. The ambient `aws sts get-caller-identity --region <target-region>` must not return
   the state account ("separation lost"). It must return `target-account`.

`AWS_PAGER` is cleared for these calls.

### Backend file

The script deletes any existing `<working-directory>/<backend-file>`, so it never writes
through a committed symlink, then writes:

```hcl
# Generated by tofu-setup for env "<env>". Do not edit, do not commit.
terraform {
  backend "s3" {
    bucket       = "<state-bucket>"
    key          = "<state-key>"
    region       = "<state-region>"
    profile      = "<state-profile>"
    encrypt      = true
    use_lockfile = true      # only when use-lockfile is true
  }
}
```

OpenTofu loads `_override.tf` files after the rest of the module. A backend block in an
override replaces the module's backend or `cloud` block, and is also accepted when the
module has none. The result is deterministic whatever the code contains.

### Declared variables

A top-level grep, not an HCL parser. The script collects `variable "<name>"` and
`variable <name>` block headers from `*.tf` and `*.tofu` in the working directory. The
list is used only for the undeclared-parameter warning or failure. `.tf.json` files are
not scanned.

### Fetching parameters

One call, with no `--recursive` (direct children only); the CLI paginates on its own:

```
aws ssm get-parameters-by-path --path <prefix>/ --with-decryption \
  --profile <profile> --region <state-region> --output json
```

The JSON is held in a shell variable and fed to `jq` through a pipe. `jq` emits one row
per parameter: `Name<TAB>Type<TAB>base64(Value)` (`@tsv`). Base64 keeps newlines and
tabs inside values intact. The rows reach the loop through process substitution, which
is a pipe.

### Per parameter

1. The leaf name is the parameter name minus the prefix. It must match
   `^[A-Za-z_][A-Za-z0-9_]*$`. Otherwise the script logs `skipping <name>` and moves on.
2. The value is decoded with `$(… | base64 -d && printf x)`, then the `x` is stripped.
   The sentinel keeps trailing newlines that command substitution would otherwise remove.
3. The value is handled by type:
   - `SecureString`: every line is registered with `::add-mask::` (see below) and counted.
   - `StringList`: converted to a JSON array with `jq -Rsc 'split(",")'`. Slurping (`-s`)
     keeps a value with an embedded newline as one array.
   - `String`: unchanged.
   - Any other type: the step fails.
4. A leaf without a matching `variable` block is added to the undeclared list.
5. A `TF_VAR_<leaf>` entry is appended to the in-memory `$GITHUB_ENV` buffer.

After the loop:

- Undeclared names fail the step with `strict-vars: true`, and produce one warning
  otherwise.
- `TF_INPUT=0` and `TF_IN_AUTOMATION=1` are added when `disable-input` is true.
- `AWS_REGION` and `AWS_DEFAULT_REGION` are re-exported only if they differ from the
  target region the credential step already set.
- The outputs are added to the `$GITHUB_OUTPUT` buffer: `variable-names` (sorted leaf
  names), `secret-count` and `backend-file` (absolute path).
- Both buffers are appended to their files in one write each.

### Writing `$GITHUB_ENV` and `$GITHUB_OUTPUT`

Every entry, secret or not, uses GitHub's multi-line form with its own delimiter:

```
TF_VAR_<name><<ghadelim_<32 random hex>
<value>
ghadelim_<32 random hex>
```

- The delimiter comes from `openssl rand -hex 16`, falling back to `/dev/urandom` via
  `od`. A new one is generated for every value, and the step fails if a value contains
  its delimiter.
- The `NAME=value` form is never used. A value containing a newline would define further
  variables.
- The runner takes everything up to the delimiter line, minus the newline just before it,
  so values round-trip exactly, including a trailing newline.
- Because entries are buffered, a failure anywhere (undeclared names with `strict-vars`,
  an unknown type, a delimiter collision) leaves both files untouched.

### Masking

- For each line of a `SecureString`, the script strips a trailing `\r`. If the line is at
  least 4 characters long and not only whitespace, it emits
  `::add-mask::<line>` on stdout.
- Lines are escaped as `@actions/core` does: `%` → `%25`, `\r` → `%0D`, `\n` → `%0A`. A
  literal `%0A` inside a secret is therefore masked as written.
- Masks are emitted only when `GITHUB_ACTIONS=true`, and always before anything is
  written to `$GITHUB_ENV`.
- Shorter lines are not masked, because masking very short strings would garble the log.
  The README tells users to avoid them.

### Logging

- Progress goes to stderr and contains parameter names and types only.
- Inside Actions, warnings and errors are emitted as `::warning` / `::error` annotations
  so they appear on the run summary. Outside Actions, they go to stderr.

## Where secret values live

```
aws CLI stdout → shell variable → jq (stdin) → rows variable → loop variable → buffer → $GITHUB_ENV
```

- Never in the argv of an external command. Argv is readable by other processes through
  `/proc/<pid>/cmdline`. Only shell builtins (`printf`, `[[ ]]`, parameter expansion)
  see a secret as an argument.
- Never in a temporary file or a here-string. Bash before 5.1 backs here-strings with
  temporary files.
- Never echoed. `set -x` must never be enabled in `setup.sh`.

The accepted trade-off: everything written to `$GITHUB_ENV` is visible to every later step
of the job. The alternative, a per-command wrapper that runs the same checks, fetches the
parameters on each call and `exec`s `tofu` with `TF_VAR_*` in that process only, is not
part of this repository.

## Plan and apply behaviour

OpenTofu 1.11 added ephemeral variables. In `internal/tofu/context_apply.go`
(`mergePlanAndApplyVariables`), applying a saved plan works like this:

- Values given at apply time, including `TF_VAR_*`, are compared with the values stored in
  the plan for non-ephemeral variables. A difference is an error: "Mismatch between input
  and plan variable value".
- Ephemeral variables are not stored in the plan and must be given at apply time. A
  changed value is used silently.

This was checked with OpenTofu 1.12.3, which also confirmed that non-ephemeral values,
including `sensitive` ones, are stored in plain text in the plan file. OpenTofu 1.10 has
neither check.

## Repository layout

```
action.yml                 inputs → TFS_* env → scripts/setup.sh; the two credential steps
scripts/setup.sh           all logic; bash 3.2 compatible
test/setup_test.sh         test runner
test/stubs/aws             stub CLI: sts get-caller-identity, ssm get-parameters-by-path
test/stubs/tofu            prints the TF_* names (never values) it would see
examples/                  plan and apply workflows
.github/workflows/ci.yml   shellcheck and tests on Ubuntu (bash 5) and macOS (bash 3.2)
.github/dependabot.yml     weekly updates of the pinned actions
```

## Tests

```bash
bash test/setup_test.sh
SHELLCHECK=/path/to/shellcheck REQUIRE_SHELLCHECK=true bash test/setup_test.sh
BASH_UNDER_TEST=/bin/bash bash test/setup_test.sh   # run setup.sh under another bash
```

The runner is plain bash with no dependencies beyond `jq` and `openssl`.

- Each case runs `setup.sh` in a temporary module directory with a clean environment
  (`env -i`). The stub `aws` comes first on `PATH`, and `$GITHUB_ENV`/`$GITHUB_OUTPUT`
  are temporary files.
- The stub `aws` checks the exact call shapes, filters parameters by path the way the API
  does without `--recursive`, and logs its arguments. Arguments never carry secrets.
- `$GITHUB_ENV` and `$GITHUB_OUTPUT` are parsed the way the runner parses them. The tests
  check the heredoc format, that delimiters are unique and random, and that values
  round-trip exactly.
- Fake secrets are compared in memory only. On failure, the runner prints stderr and
  stdout without the `::add-mask::` lines.

Cases:

| case | checks |
|---|---|
| happy-path | masks only for the long secret lines; heredoc format; `1.10` round-trips; `StringList` → JSON; `bad-name` skipped; `not_declared` warned; outputs; exact aws calls; no secret in stderr, outputs or the working tree; a later `tofu` sees the variables |
| strict-vars | undeclared parameter → exit 2, nothing written |
| wrong-state-account | exit 2 before the backend file exists, no SSM call |
| separation-lost | ambient = state account → exit 2 "separation lost" |
| delimiter-collision | fixed RNG (stub `openssl`), value contains the delimiter → exit 2, nothing written |
| no-lockfile | no `use_lockfile` line |
| shellcheck | `shellcheck -s bash` on the script, the stubs and the runner |
| invalid-inputs | each bad or missing input → exit 2, no aws call, nothing written |
| check-mode | default and explicit role ARNs in the outputs; missing OIDC token; missing working directory |
| options | custom prefix, profile, key, target region and backend file; `AWS_PROFILE` warning |
| unknown-type, no-parameters, outside-actions, rng-fallback, usage | edge cases |

CI runs the suite on `ubuntu-latest` (bash 5, GNU tools, shellcheck required) and on
`macos-latest` with `/bin/bash` 3.2 and BSD tools.

## Maintenance notes

- Every action is pinned by commit SHA with the version in a comment. Dependabot proposes
  updates weekly.
- When updating `configure-aws-credentials`, re-check:
  - that `aws-profile` still means profile files only, with no environment export,
  - the list of translated environment variables,
  - the names of the inputs used here.
- Keep `setup.sh` bash 3.2 compatible (macOS):
  - no associative arrays, `mapfile`, `${var,,}` or `[[ -v ]]`,
  - guard empty-array expansions under `set -u` with `${a[@]+"${a[@]}"}`.
