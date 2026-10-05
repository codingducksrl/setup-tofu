#!/usr/bin/env bash
# Tests for scripts/setup.sh. Plain bash: stubbed `aws`/`tofu` on PATH and
# temporary $GITHUB_ENV/$GITHUB_OUTPUT files. Assertions look at files, names
# and exit codes; the fake secrets are compared in memory and never printed.
#
#   bash test/setup_test.sh
#   SHELLCHECK=/path/to/shellcheck REQUIRE_SHELLCHECK=true bash test/setup_test.sh
#   BASH_UNDER_TEST=/bin/bash bash test/setup_test.sh   # run setup.sh with another bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SETUP=$ROOT/scripts/setup.sh
BASH_BIN=${BASH_UNDER_TEST:-bash}
STUBS=$ROOT/test/stubs
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

STATE_ACCOUNT=111111111111
TARGET_ACCOUNT=222222222222
# Three lines: two long ones, one shorter than 4 characters, trailing newline.
SECRET=$'first-secret-line\nQ7#\nthird-secret-line\n'
FIXED_HEX=00112233445566778899aabbccddeeff

passed=0 failed=0 CASE="" DIR="" WORK="" STATUS=0

# --- assertions --------------------------------------------------------------

pass() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  printf 'FAIL  %s: %s\n' "$CASE" "$*"
}
# check DESCRIPTION COMMAND...: the command decides; only DESCRIPTION is printed.
check() {
  local desc=$1
  shift
  if "$@"; then pass; else fail "$desc"; fi
}
# expect_eq DESCRIPTION ACTUAL EXPECTED: for non-secret values, shown on failure.
expect_eq() {
  if [[ "$2" == "$3" ]]; then pass; else fail "$1: expected [$3], got [$2]"; fi
}
expect_status() {
  if [[ "$STATUS" == "$1" ]]; then
    pass
  else
    fail "exit status: expected $1, got $STATUS"
    # Diagnostics only; stdout loses its add-mask lines.
    sed 's/^/      stderr: /' "$DIR/stderr"
    grep -v '^::add-mask::' "$DIR/stdout" | sed 's/^/      stdout: /'
  fi
}

eq() { [[ "$1" == "$2" ]]; }
has_line() { grep -qxF -- "$2" "$1"; }
contains() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
is_empty() { [[ ! -s "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }
tree_lacks() { ! grep -rqF -- "$2" "$1"; }

# scan_env FILE MODE [NAME] reads a $GITHUB_ENV-style file the way the runner
# does (heredoc blocks; the value is every line up to the delimiter line).
#   check  succeed only if every entry is NAME<<ghadelim_<32 hex>, delimiters unique
#   names  print every entry name
#   value  print NAME's value followed by "x" (strip it after capturing)
scan_env() {
  local file=$1 mode=$2 want=${3:-} line name="" delim="" value=""
  local in=false first=true found=false seen=" "
  local header='^([A-Za-z_][A-Za-z0-9_-]*)<<(.*)$' random='^ghadelim_[0-9a-f]{32}$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$in" == false ]]; then
      [[ -n "$line" ]] || continue
      [[ "$line" =~ $header ]] || return 1
      name=${BASH_REMATCH[1]} delim=${BASH_REMATCH[2]} value="" first=true in=true
      if [[ "$mode" == check ]]; then
        [[ "$delim" =~ $random && "$seen" != *" $delim "* ]] || return 1
        seen+="$delim "
      fi
    elif [[ "$line" == "$delim" ]]; then
      in=false
      case "$mode" in
        names) printf '%s\n' "$name" ;;
        value) if [[ "$name" == "$want" ]]; then printf '%sx' "$value" && found=true; fi ;;
      esac
    elif [[ "$first" == true ]]; then
      value=$line first=false
    else
      value+=$'\n'$line
    fi
  done <"$file"
  [[ "$in" == false ]] || return 1
  [[ "$mode" != value || "$found" == true ]]
}
entry() {
  local v
  v=$(scan_env "$1" value "$2") || return 1
  printf '%s' "${v%x}"
}
names_of() { scan_env "$1" names | LC_ALL=C sort | tr '\n' ' '; }
sorted() { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' '; }

# --- fixtures ----------------------------------------------------------------

new_case() {
  CASE=$1
  DIR=$TMP/$CASE
  mkdir -p "$DIR/work" "$DIR/bin"
  WORK=$(cd "$DIR/work" && pwd -P)
  reset_files
  cat >"$WORK/main.tf" <<'EOF'
provider "aws" {
  region = "eu-south-1"
}

variable "db_password" {
  type      = string
  sensitive = true
  ephemeral = true
}

variable "app_version" {
  type = string
}
EOF
  cat >"$WORK/network.tofu" <<'EOF'
variable "subnets" {
  type = list(string)
}
EOF
  set_params
}

reset_files() {
  : >"$DIR/github_env"
  : >"$DIR/github_output"
  : >"$DIR/aws.log"
  rm -f "$WORK"/*_override.tf
}

# set_params [NAME TYPE VALUE]...: what GetParametersByPath will return.
set_params() {
  local json='{"Parameters":[]}'
  while (($# >= 3)); do
    json=$(printf '%s' "$json" | jq --arg n "$1" --arg t "$2" --arg v "$3" \
      '.Parameters += [{Name: $n, Type: $t, Value: $v, Version: 1, DataType: "text"}]')
    shift 3
  done
  printf '%s\n' "$json" >"$DIR/params.json"
}

# run_setup MODE [NAME=value]...: run setup.sh in $WORK with a clean
# environment; later assignments override the defaults. Sets STATUS.
run_setup() {
  local mode=$1 args=()
  shift
  [[ "$mode" == run ]] || args=("$mode")
  (
    cd "$WORK" && env -i \
      PATH="$DIR/bin:$STUBS:$PATH" HOME="$DIR" \
      GITHUB_ACTIONS=true ACTIONS_ID_TOKEN_REQUEST_URL=https://token.invalid/ \
      GITHUB_ENV="$DIR/github_env" GITHUB_OUTPUT="$DIR/github_output" \
      AWS_REGION=eu-south-1 AWS_DEFAULT_REGION=eu-south-1 \
      TFS_ENV=production \
      TFS_STATE_ROLE_ARN= TFS_TARGET_ROLE_ARN= \
      TFS_STATE_ACCOUNT=$STATE_ACCOUNT TFS_TARGET_ACCOUNT=$TARGET_ACCOUNT \
      TFS_STATE_BUCKET=my-state-bucket TFS_STATE_KEY= \
      TFS_STATE_REGION=eu-south-1 TFS_TARGET_REGION= TFS_STATE_PROFILE=tf-state \
      TFS_SSM_PREFIX= TFS_WORKING_DIRECTORY=. TFS_BACKEND_FILE=tfw_backend_override.tf \
      TFS_USE_LOCKFILE=true TFS_STRICT_VARS=false TFS_DISABLE_INPUT=true \
      STUB_STATE_ACCOUNT=$STATE_ACCOUNT STUB_AMBIENT_ACCOUNT=$TARGET_ACCOUNT \
      STUB_PARAMS_FILE="$DIR/params.json" STUB_AWS_LOG="$DIR/aws.log" \
      "$@" "$BASH_BIN" "$SETUP" ${args[@]+"${args[@]}"}
  ) >"$DIR/stdout" 2>"$DIR/stderr"
  STATUS=$?
}

backend_text() { # PROFILE LOCKFILE KEY
  printf '%s\n' \
    '# Generated by tofu-setup for env "production". Do not edit, do not commit.' \
    'terraform {' \
    '  backend "s3" {' \
    '    bucket       = "my-state-bucket"' \
    "    key          = \"$3\"" \
    '    region       = "eu-south-1"' \
    "    profile      = \"$1\"" \
    '    encrypt      = true'
  if [[ "$2" == true ]]; then printf '%s\n' '    use_lockfile = true'; fi
  printf '%s\n' '  }' '}'
}

nothing_written() {
  check "GITHUB_ENV untouched" is_empty "$DIR/github_env"
  check "GITHUB_OUTPUT untouched" is_empty "$DIR/github_output"
  check "no backend file" absent "$WORK/tfw_backend_override.tf"
}

# --- 1. happy path -----------------------------------------------------------

new_case happy-path
set_params \
  /terraform/production/db_password SecureString "$SECRET" \
  /terraform/production/app_version String 1.10 \
  /terraform/production/subnets StringList subnet-a,subnet-b \
  /terraform/production/bad-name String whatever \
  /terraform/production/not_declared String plain \
  /terraform/production/nested/deep String not-a-direct-child \
  /terraform/dev/db_password String other-env
run_setup run
expect_status 0

check "add-mask only for the two long secret lines" eq \
  "$(grep '^::add-mask::' "$DIR/stdout" | LC_ALL=C sort | tr '\n' '|')" \
  "::add-mask::first-secret-line|::add-mask::third-secret-line|"
for line in first-secret-line third-secret-line 'Q7#'; do
  check "secret line only in add-mask commands" eq "$(grep -v '^::add-mask::' "$DIR/stdout" | grep -cF -- "$line")" 0
  check "secret line not in stderr" lacks "$DIR/stderr" "$line"
  check "secret line not in GITHUB_OUTPUT" lacks "$DIR/github_output" "$line"
  check "secret line not in the working tree" tree_lacks "$WORK" "$line"
done
check "short secret line never printed" lacks "$DIR/stdout" 'Q7#'

check "GITHUB_ENV holds only heredoc blocks with unique random delimiters" scan_env "$DIR/github_env" check
expect_eq "GITHUB_ENV names" "$(names_of "$DIR/github_env")" \
  "$(sorted TF_VAR_db_password TF_VAR_app_version TF_VAR_subnets TF_VAR_not_declared TF_INPUT TF_IN_AUTOMATION)"
check "TF_VAR_db_password round-trips exactly" eq "$(entry "$DIR/github_env" TF_VAR_db_password && printf x)" "${SECRET}x"
expect_eq "TF_VAR_app_version" "$(entry "$DIR/github_env" TF_VAR_app_version)" 1.10
expect_eq "TF_VAR_subnets" "$(entry "$DIR/github_env" TF_VAR_subnets)" '["subnet-a","subnet-b"]'
expect_eq "TF_VAR_not_declared" "$(entry "$DIR/github_env" TF_VAR_not_declared)" plain
expect_eq "TF_INPUT" "$(entry "$DIR/github_env" TF_INPUT)" 0
expect_eq "TF_IN_AUTOMATION" "$(entry "$DIR/github_env" TF_IN_AUTOMATION)" 1

check "invalid name skipped with a log line" contains "$DIR/stderr" \
  "skipping /terraform/production/bad-name: 'bad-name' is not a valid variable name"
check "warning lists not_declared" has_line "$DIR/stdout" \
  "::warning title=tofu-setup::parameters with no matching variable block: not_declared"
check "summary logged" contains "$DIR/stderr" "exported 4 variable(s), 1 masked as secret(s)"

check "GITHUB_OUTPUT holds only heredoc blocks" scan_env "$DIR/github_output" check
expect_eq "output variable-names" "$(entry "$DIR/github_output" variable-names)" \
  "app_version db_password not_declared subnets"
expect_eq "output secret-count" "$(entry "$DIR/github_output" secret-count)" 1
expect_eq "output backend-file" "$(entry "$DIR/github_output" backend-file)" "$WORK/tfw_backend_override.tf"
expect_eq "backend file" "$(cat "$WORK/tfw_backend_override.tf")" "$(backend_text tf-state true production/terraform.tfstate)"
expect_eq "aws calls" "$(cat "$DIR/aws.log")" "$(printf '%s\n' \
  "sts get-caller-identity --profile tf-state --region eu-south-1 --query Account --output text" \
  "sts get-caller-identity --region eu-south-1 --query Account --output text" \
  "ssm get-parameters-by-path --path /terraform/production/ --with-decryption --profile tf-state --region eu-south-1 --output json")"

# A later step: plain `tofu` sees the exported names and the backend override.
tofu_out=$(
  cd "$WORK" || exit 1
  for v in $(compgen -e | grep '^TF_'); do unset "$v"; done
  for name in $(scan_env "$DIR/github_env" names); do
    value=$(scan_env "$DIR/github_env" value "$name")
    export "$name=${value%x}"
  done
  PATH="$STUBS:$PATH" tofu plan -out plan.bin
)
expect_eq "tofu sees the job environment" "$tofu_out" "$(printf '%s\n' "tofu plan -out plan.bin" \
  TF_INPUT TF_IN_AUTOMATION TF_VAR_app_version TF_VAR_db_password TF_VAR_not_declared TF_VAR_subnets \
  "override tfw_backend_override.tf")"

# --- 2. strict-vars with an undeclared parameter ------------------------------

new_case strict-vars
set_params /terraform/production/app_version String 1.10 /terraform/production/not_declared String plain
run_setup run TFS_STRICT_VARS=true
expect_status 2
check "GITHUB_ENV untouched" is_empty "$DIR/github_env"
check "GITHUB_OUTPUT untouched" is_empty "$DIR/github_output"
check "error names the parameter" has_line "$DIR/stdout" \
  "::error title=tofu-setup::parameters with no matching variable block: not_declared"

# --- 3. state profile resolves to the wrong account ---------------------------

new_case wrong-state-account
set_params /terraform/production/app_version String 1.10
run_setup run STUB_STATE_ACCOUNT=333333333333
expect_status 2
nothing_written
check "parameters never read" lacks "$DIR/aws.log" "ssm "
check "error explains" contains "$DIR/stdout" \
  "profile 'tf-state' resolves to account 333333333333, expected $STATE_ACCOUNT"

# --- 4. ambient credentials are the state account -----------------------------

new_case separation-lost
set_params /terraform/production/app_version String 1.10
run_setup run STUB_AMBIENT_ACCOUNT=$STATE_ACCOUNT
expect_status 2
nothing_written
check "parameters never read" lacks "$DIR/aws.log" "ssm "
check "error says separation lost" contains "$DIR/stdout" "separation lost"

# --- 5. a value containing its delimiter --------------------------------------

new_case delimiter-collision
printf '#!/usr/bin/env bash\necho %s\n' "$FIXED_HEX" >"$DIR/bin/openssl"
chmod +x "$DIR/bin/openssl"
set_params /terraform/production/app_version String "1.10" \
  /terraform/production/payload String $'x\nghadelim_'"$FIXED_HEX"$'\nTF_VAR_injected=1'
run_setup run
expect_status 2
check "GITHUB_ENV untouched" is_empty "$DIR/github_env"
check "GITHUB_OUTPUT untouched" is_empty "$DIR/github_output"
check "error names the variable" contains "$DIR/stdout" "the value of TF_VAR_payload contains its heredoc delimiter"

# --- 6. use-lockfile=false ----------------------------------------------------

new_case no-lockfile
set_params /terraform/production/app_version String 1.10
run_setup run TFS_USE_LOCKFILE=false
expect_status 0
check "no use_lockfile line" lacks "$WORK/tfw_backend_override.tf" use_lockfile
expect_eq "backend file" "$(cat "$WORK/tfw_backend_override.tf")" "$(backend_text tf-state false production/terraform.tfstate)"

# --- 7. shellcheck ------------------------------------------------------------

CASE=shellcheck
SHELLCHECK=${SHELLCHECK:-shellcheck}
if command -v "$SHELLCHECK" >/dev/null 2>&1; then
  check "shellcheck -s bash is clean" "$SHELLCHECK" -s bash \
    "$SETUP" "$STUBS/aws" "$STUBS/tofu" "$ROOT/test/setup_test.sh"
elif [[ "${REQUIRE_SHELLCHECK:-false}" == true ]]; then
  fail "shellcheck not found"
else
  printf 'SKIP  shellcheck: not installed (set SHELLCHECK=/path/to/shellcheck)\n'
fi

# --- more: inputs, check mode, options, edge cases -----------------------------

new_case invalid-inputs
set_params /terraform/production/app_version String 1.10
bad_inputs=(
  "TFS_ENV="
  "TFS_STATE_ACCOUNT="
  "TFS_TARGET_ACCOUNT="
  "TFS_STATE_BUCKET="
  "TFS_STATE_REGION="
  "TFS_STATE_ACCOUNT=12345"
  "TFS_TARGET_ACCOUNT=$STATE_ACCOUNT"
  "TFS_STATE_ROLE_ARN=arn:aws:iam::$TARGET_ACCOUNT:role/terraform-production-action-role"
  "TFS_TARGET_ROLE_ARN=terraform"
  "TFS_BACKEND_FILE=backend.tf"
  "TFS_BACKEND_FILE=sub/backend_override.tf"
  "TFS_STATE_KEY=app/\"prod\"/terraform.tfstate"
  "TFS_STATE_KEY=app/\${var.x}/terraform.tfstate"
  "TFS_STATE_KEY=/app/terraform.tfstate"
  "TFS_STATE_BUCKET=My_Bucket"
  "TFS_STATE_REGION=eu-south-1\""
  "TFS_TARGET_REGION=EU"
  "TFS_ENV=prod"
  "TFS_ENV=Production"
  "TFS_ENV=production"$'
'"x"
  "TFS_SSM_PREFIX=terraform/production"
  "TFS_STATE_PROFILE=tf state"
  "TFS_STRICT_VARS=yes"
)
for bad in "${bad_inputs[@]}"; do
  CASE="invalid-inputs [${bad//$'\n'/\\n}]"
  reset_files
  run_setup run "$bad"
  expect_status 2
  nothing_written
  check "no aws call" is_empty "$DIR/aws.log"
done
reset_files
run_setup run "TFS_TARGET_ACCOUNT=$STATE_ACCOUNT" "TFS_TARGET_ROLE_ARN=arn:aws:iam::$STATE_ACCOUNT:role/x"
CASE=invalid-inputs
check "same accounts report separation lost" contains "$DIR/stdout" "separation lost"

new_case check-mode
run_setup check
expect_status 0
check "GITHUB_ENV untouched" is_empty "$DIR/github_env"
check "no backend file" absent "$WORK/tfw_backend_override.tf"
check "no aws call" is_empty "$DIR/aws.log"
check "GITHUB_OUTPUT holds only heredoc blocks" scan_env "$DIR/github_output" check
expect_eq "outputs" "$(names_of "$DIR/github_output")" "$(sorted state-role-arn target-role-arn)"
expect_eq "default state role" "$(entry "$DIR/github_output" state-role-arn)" \
  "arn:aws:iam::$STATE_ACCOUNT:role/terraform-production-action-role"
expect_eq "default target role" "$(entry "$DIR/github_output" target-role-arn)" \
  "arn:aws:iam::$TARGET_ACCOUNT:role/terraform"
for env in dev staging production; do
  reset_files
  run_setup check "TFS_ENV=$env"
  expect_status 0
  expect_eq "state role for $env" "$(entry "$DIR/github_output" state-role-arn)" \
    "arn:aws:iam::$STATE_ACCOUNT:role/terraform-$env-action-role"
done
reset_files
run_setup check "TFS_TARGET_ROLE_ARN=arn:aws:iam::$TARGET_ACCOUNT:role/ci/custom-deploy"
expect_status 0
expect_eq "explicit target role wins" "$(entry "$DIR/github_output" target-role-arn)" \
  "arn:aws:iam::$TARGET_ACCOUNT:role/ci/custom-deploy"
reset_files
run_setup check ACTIONS_ID_TOKEN_REQUEST_URL=
expect_status 2
check "missing id-token permission explained" contains "$DIR/stdout" "id-token: write"
run_setup check TFS_WORKING_DIRECTORY=missing
expect_status 2
check "missing working directory explained" contains "$DIR/stdout" "is not a directory"

new_case options
set_params /custom/path/app_version String 2.0 /terraform/production/app_version String 1.10
run_setup run TFS_SSM_PREFIX=/custom/path/ TFS_STATE_PROFILE=state-prod STUB_PROFILE=state-prod \
  TFS_STATE_KEY=app/prod/terraform.tfstate \
  TFS_TARGET_REGION=eu-west-1 TFS_DISABLE_INPUT=false TFS_BACKEND_FILE=backend_override.tf AWS_PROFILE=other
expect_status 0
check "GITHUB_ENV holds only heredoc blocks" scan_env "$DIR/github_env" check
expect_eq "GITHUB_ENV names" "$(names_of "$DIR/github_env")" "$(sorted AWS_DEFAULT_REGION AWS_REGION TF_VAR_app_version)"
expect_eq "TF_VAR_app_version from the custom prefix" "$(entry "$DIR/github_env" TF_VAR_app_version)" 2.0
expect_eq "AWS_REGION follows target-region" "$(entry "$DIR/github_env" AWS_REGION)" eu-west-1
expect_eq "backend file" "$(cat "$WORK/backend_override.tf")" "$(backend_text state-prod true app/prod/terraform.tfstate)"
expect_eq "output backend-file" "$(entry "$DIR/github_output" backend-file)" "$WORK/backend_override.tf"
check "AWS_PROFILE warning" contains "$DIR/stdout" "::warning title=tofu-setup::AWS_PROFILE=other is set"
expect_eq "aws calls" "$(cat "$DIR/aws.log")" "$(printf '%s\n' \
  "sts get-caller-identity --profile state-prod --region eu-south-1 --query Account --output text" \
  "sts get-caller-identity --region eu-west-1 --query Account --output text" \
  "ssm get-parameters-by-path --path /custom/path/ --with-decryption --profile state-prod --region eu-south-1 --output json")"

new_case unknown-type
set_params /terraform/production/app_version String 1.10 /terraform/production/weird Fancy value
run_setup run
expect_status 2
check "GITHUB_ENV untouched" is_empty "$DIR/github_env"
check "error names the type" contains "$DIR/stdout" "unknown parameter type 'Fancy' for /terraform/production/weird"

new_case no-parameters
run_setup run
expect_status 0
expect_eq "output variable-names" "$(entry "$DIR/github_output" variable-names)" ""
expect_eq "output secret-count" "$(entry "$DIR/github_output" secret-count)" 0
check "warning about the empty prefix" contains "$DIR/stdout" "no parameters found under /terraform/production/"

new_case outside-actions
set_params /terraform/production/db_password SecureString "$SECRET"
run_setup run GITHUB_ACTIONS=
expect_status 0
check "nothing on stdout" is_empty "$DIR/stdout"
check "secret line not in stderr" lacks "$DIR/stderr" first-secret-line
check "secret still exported" eq "$(entry "$DIR/github_env" TF_VAR_db_password && printf x)" "${SECRET}x"

new_case rng-fallback
printf '#!/usr/bin/env bash\nexit 1\n' >"$DIR/bin/openssl"
chmod +x "$DIR/bin/openssl"
set_params /terraform/production/app_version String 1.10
run_setup run
expect_status 0
check "urandom delimiters are valid and unique" scan_env "$DIR/github_env" check

new_case usage
run_setup unexpected-argument
expect_status 2

# --- summary -----------------------------------------------------------------

printf '%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
