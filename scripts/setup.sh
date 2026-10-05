#!/usr/bin/env bash
# tofu-setup: prepare the current job for plain `tofu` runs against a target
# AWS account while state and configuration live in a separate state account.
#
#   setup.sh check   validate inputs and resolve the role ARNs (written as step
#                    outputs); runs before any role is assumed
#   setup.sh         assert both identities, write the backend override file
#                    and export SSM parameters as TF_VAR_* via $GITHUB_ENV
#
# Configuration is read only from TFS_* environment variables (see action.yml).
# Exit status 2 means a checked failure; nothing is written to $GITHUB_ENV or
# $GITHUB_OUTPUT unless every check passed.
#
# Secret values travel only through shell variables, builtins and pipes. Never
# add `set -x` here, never echo a value, and never pass one as an argument to
# an external command (argv is visible to other processes).
set -Eeuo pipefail

log() { printf 'tofu-setup: %s\n' "$*" >&2; }

# Escape workflow-command data the way @actions/core does.
escape_data() {
  local s=$1
  s=${s//'%'/%25}
  s=${s//$'\r'/%0D}
  s=${s//$'\n'/%0A}
  printf '%s' "$s"
}

# Inside Actions, warnings and errors become annotations on the run summary.
annotate() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::%s title=tofu-setup::%s\n' "$1" "$(escape_data "$2")"
  else
    log "$1: $2"
  fi
}
warn() { annotate warning "$*"; }
die() { annotate error "$*"; exit 2; }

need() { [[ -n "${!1:-}" ]] || die "input '$2' is required"; }

# bool VAR DEFAULT: print true/false, fail on anything else.
bool() {
  case "${!1:-$2}" in
    true | True | TRUE) printf true ;;
    false | False | FALSE) printf false ;;
    *) return 1 ;;
  esac
}

# role_account ARN INPUT ACCOUNT: the role must live in the declared account.
role_account() {
  local re='^arn:aws[a-z-]*:iam::([0-9]{12}):role/[A-Za-z0-9+=,.@_/-]+$'
  [[ "$1" =~ $re ]] || die "input '$2' is not an IAM role ARN"
  [[ "${BASH_REMATCH[1]}" == "$3" ]] \
    || die "input '$2' is a role in account ${BASH_REMATCH[1]}, expected $3"
}

load_config() {
  need TFS_ENV env
  need TFS_STATE_ACCOUNT state-account
  need TFS_TARGET_ACCOUNT target-account
  need TFS_STATE_BUCKET state-bucket
  need TFS_STATE_REGION state-region

  env_name=$TFS_ENV
  state_account=$TFS_STATE_ACCOUNT
  target_account=$TFS_TARGET_ACCOUNT
  state_bucket=$TFS_STATE_BUCKET
  state_key=${TFS_STATE_KEY:-$TFS_ENV/terraform.tfstate}
  state_region=$TFS_STATE_REGION
  target_region=${TFS_TARGET_REGION:-$TFS_STATE_REGION}
  state_profile=${TFS_STATE_PROFILE:-tf-state}
  ssm_prefix=${TFS_SSM_PREFIX:-/terraform/$TFS_ENV}
  ssm_prefix=${ssm_prefix%/}/
  backend_file=${TFS_BACKEND_FILE:-tfw_backend_override.tf}
  use_lockfile=$(bool TFS_USE_LOCKFILE true) || die "input 'use-lockfile' must be true or false"
  strict_vars=$(bool TFS_STRICT_VARS false) || die "input 'strict-vars' must be true or false"
  disable_input=$(bool TFS_DISABLE_INPUT true) || die "input 'disable-input' must be true or false"

  # Every value below ends up inside an HCL string or an SSM path, so only
  # plain characters are accepted: no quotes, backslashes, `${` or newlines.
  local re_bucket='^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'
  local re_key="^[A-Za-z0-9!_.*'()/=-]+$"
  local re_region='^[a-z]{2,}(-[a-z0-9]+)+$'
  local re_profile='^[A-Za-z0-9_.-]+$'
  local re_prefix='^/([A-Za-z0-9_.-]+/)*$'
  local re_backend='^[A-Za-z0-9_.-]*_override\.tf$'

  case "$env_name" in
    dev | staging | production) ;;
    *) die "input 'env' must be dev, staging or production" ;;
  esac
  [[ "$state_account" =~ ^[0-9]{12}$ ]] || die "input 'state-account' must be a 12-digit account id"
  [[ "$target_account" =~ ^[0-9]{12}$ ]] || die "input 'target-account' must be a 12-digit account id"
  [[ "$state_account" != "$target_account" ]] \
    || die "state-account and target-account are the same account; separation lost"
  # Role names follow a fixed convention unless an ARN is passed explicitly.
  state_role_arn=${TFS_STATE_ROLE_ARN:-arn:aws:iam::$state_account:role/terraform-$env_name-action-role}
  target_role_arn=${TFS_TARGET_ROLE_ARN:-arn:aws:iam::$target_account:role/terraform}
  role_account "$state_role_arn" state-role-arn "$state_account"
  role_account "$target_role_arn" target-role-arn "$target_account"
  [[ "$state_bucket" =~ $re_bucket ]] || die "input 'state-bucket' is not a valid S3 bucket name"
  [[ "$state_key" =~ $re_key ]] \
    || die "input 'state-key' may only contain letters, digits, '/', '=' and !-_.*'()"
  [[ "$state_key" != /* && "$state_key" != */ && "$state_key" != *//* ]] \
    || die "input 'state-key' must not start or end with '/' or contain '//'"
  [[ "$state_region" =~ $re_region ]] || die "input 'state-region' is not a valid region name"
  [[ "$target_region" =~ $re_region ]] || die "input 'target-region' is not a valid region name"
  [[ "$state_profile" =~ $re_profile ]] \
    || die "input 'state-profile' may only contain letters, digits, '_', '.' and '-'"
  [[ "$ssm_prefix" =~ $re_prefix ]] \
    || die "input 'ssm-prefix' must be an absolute parameter path such as /terraform/prod"
  [[ "$backend_file" =~ $re_backend ]] \
    || die "input 'backend-file' must be a plain file name ending in _override.tf"

  local tool
  for tool in aws jq base64; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
  done
}

# 32 random hex characters, from openssl or /dev/urandom.
rand_hex() {
  local hex=""
  if command -v openssl >/dev/null 2>&1; then
    hex=$(openssl rand -hex 16 2>/dev/null) || hex=""
  fi
  if [[ ! "$hex" =~ ^[0-9a-f]{32}$ ]]; then
    hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || hex=""
  fi
  [[ "$hex" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s' "$hex"
}

# add_entry BUFFER NAME VALUE: append NAME in the heredoc form GitHub parses
# for $GITHUB_ENV and $GITHUB_OUTPUT. Every value gets its own random
# delimiter, so no value can close its block and inject further variables.
add_entry() {
  local delim
  delim=ghadelim_$(rand_hex) || die "cannot generate a random delimiter"
  [[ "$3" != *"$delim"* ]] || die "the value of $2 contains its heredoc delimiter"
  printf -v "$1" '%s%s<<%s\n%s\n%s\n' "${!1}" "$2" "$delim" "$3" "$delim"
}

# Register every line of a secret (4+ characters) with the runner's masker.
mask() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    if ((${#line} >= 4)) && [[ "$line" =~ [^[:space:]] ]]; then
      printf '::add-mask::%s\n' "$(escape_data "$line")"
    fi
  done < <(printf '%s' "$1")
}

assert_credentials() {
  local state_acct target_acct
  [[ -z "${AWS_PROFILE:-}" ]] \
    || warn "AWS_PROFILE=$AWS_PROFILE is set; tools may resolve it instead of the ambient target credentials"

  state_acct=$(aws sts get-caller-identity --profile "$state_profile" --region "$state_region" \
    --query Account --output text) || die "cannot resolve credentials for profile '$state_profile'"
  [[ "$state_acct" == "$state_account" ]] \
    || die "profile '$state_profile' resolves to account $state_acct, expected $state_account"

  target_acct=$(aws sts get-caller-identity --region "$target_region" \
    --query Account --output text) || die "cannot resolve the ambient credentials"
  [[ "$target_acct" != "$state_acct" ]] \
    || die "ambient credentials resolve to the state account $state_acct; separation lost"
  [[ "$target_acct" == "$target_account" ]] \
    || die "ambient credentials resolve to account $target_acct, expected $target_account"
  log "state profile '$state_profile' -> $state_acct, ambient credentials -> $target_acct"
}

write_backend() {
  local lock_line=""
  [[ "$use_lockfile" != "true" ]] || lock_line=$'\n    use_lockfile = true'
  rm -f -- "$backend_file"
  cat >"$backend_file" <<EOF
# Generated by tofu-setup for env "$env_name". Do not edit, do not commit.
terraform {
  backend "s3" {
    bucket       = "$state_bucket"
    key          = "$state_key"
    region       = "$state_region"
    profile      = "$state_profile"
    encrypt      = true$lock_line
  }
}
EOF
  log "wrote $backend_file (s3://$state_bucket/$state_key via profile '$state_profile')"
}

# Names of the variable blocks in the root module (a grep, not an HCL parser).
read_declared() {
  local files=()
  declared=""
  shopt -s nullglob
  files=(*.tf *.tofu)
  shopt -u nullglob
  ((${#files[@]} > 0)) || return 0
  declared=$(grep -hoE '^[[:space:]]*variable[[:space:]]*("[A-Za-z_][A-Za-z0-9_-]*"|[[:space:]][A-Za-z_][A-Za-z0-9_-]*)' \
    -- "${files[@]}" | sed -E 's/^[[:space:]]*variable[[:space:]]*"?([A-Za-z0-9_-]+).*/\1/' | LC_ALL=C sort -u) || true
}

export_parameters() {
  local params rows name type b64 leaf value
  local count=0 secrets=0 names="" undeclared=""

  log "reading parameters under $ssm_prefix via profile '$state_profile'"
  params=$(aws ssm get-parameters-by-path --path "$ssm_prefix" --with-decryption \
    --profile "$state_profile" --region "$state_region" --output json) \
    || die "GetParametersByPath failed for $ssm_prefix"
  rows=$(printf '%s' "$params" | jq -r '.Parameters[] | [.Name, .Type, (.Value | @base64)] | @tsv') \
    || die "unexpected GetParametersByPath response"
  params=""

  while IFS=$'\t' read -r name type b64; do
    [[ -n "$name" ]] || continue
    leaf=${name#"$ssm_prefix"}
    if [[ ! "$leaf" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log "skipping $name: '$leaf' is not a valid variable name"
      continue
    fi
    # The trailing x keeps trailing newlines that $(...) would strip.
    value=$(printf '%s' "$b64" | base64 -d && printf x) || die "cannot decode the value of $name"
    value=${value%x}
    case "$type" in
      SecureString)
        mask "$value"
        secrets=$((secrets + 1))
        ;;
      StringList)
        value=$(printf '%s' "$value" | jq -Rsc 'split(",")') || die "cannot convert $name to a list"
        ;;
      String) ;;
      *) die "unknown parameter type '$type' for $name" ;;
    esac
    case $'\n'"$declared"$'\n' in
      *$'\n'"$leaf"$'\n'*) ;;
      *) undeclared+=" $leaf" ;;
    esac
    add_entry env_buf "TF_VAR_$leaf" "$value"
    names+="$leaf"$'\n'
    count=$((count + 1))
    log "TF_VAR_$leaf <- $name ($type)"
  done < <(printf '%s\n' "$rows")
  rows="" value="" b64=""

  ((count > 0)) || warn "no parameters found under $ssm_prefix"
  if [[ -n "$undeclared" ]]; then
    local msg="parameters with no matching variable block:$undeclared"
    if [[ "$strict_vars" == "true" ]]; then die "$msg"; fi
    warn "$msg"
  fi

  if [[ "$disable_input" == "true" ]]; then
    add_entry env_buf TF_INPUT 0
    add_entry env_buf TF_IN_AUTOMATION 1
  fi
  [[ "${AWS_REGION:-}" == "$target_region" ]] || add_entry env_buf AWS_REGION "$target_region"
  [[ "${AWS_DEFAULT_REGION:-}" == "$target_region" ]] || add_entry env_buf AWS_DEFAULT_REGION "$target_region"

  names=$(printf '%s' "$names" | LC_ALL=C sort | tr '\n' ' ')
  add_entry out_buf variable-names "${names% }"
  add_entry out_buf secret-count "$secrets"
  add_entry out_buf backend-file "$PWD/$backend_file"

  printf '%s' "$env_buf" >>"$GITHUB_ENV"
  printf '%s' "$out_buf" >>"$GITHUB_OUTPUT"
  env_buf="" out_buf=""
  log "exported $count variable(s), $secrets masked as secret(s)"
}

main() {
  local mode=${1:-run}
  [[ $# -le 1 && ("$mode" == "run" || "$mode" == "check") ]] || die "usage: setup.sh [check]"
  load_config

  env_buf="" out_buf=""

  if [[ "$mode" == "check" ]]; then
    [[ -d "${TFS_WORKING_DIRECTORY:-.}" ]] \
      || die "input 'working-directory' (${TFS_WORKING_DIRECTORY:-}) is not a directory"
    if [[ "${GITHUB_ACTIONS:-}" == "true" && -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
      die "no OIDC token available; the job needs 'permissions: id-token: write'"
    fi
    # The credential steps read the resolved role ARNs from these outputs.
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      add_entry out_buf state-role-arn "$state_role_arn"
      add_entry out_buf target-role-arn "$target_role_arn"
      printf '%s' "$out_buf" >>"$GITHUB_OUTPUT"
    fi
    log "inputs are valid; state role $state_role_arn, target role $target_role_arn"
    return 0
  fi

  [[ -n "${GITHUB_ENV:-}" && -n "${GITHUB_OUTPUT:-}" ]] \
    || die "GITHUB_ENV and GITHUB_OUTPUT must be set; run this inside GitHub Actions"
  export AWS_PAGER=""

  assert_credentials
  write_backend
  read_declared
  export_parameters
}

main "$@"
