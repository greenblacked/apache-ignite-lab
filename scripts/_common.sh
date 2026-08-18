#!/usr/bin/env bash

# Shared helpers for the lab scripts. This file is sourced, not executed.

lab_load_env() {
  local root="$1"
  local allexport_was_set=0

  LAB_COMPOSE_ENV_ARGS=()

  if [[ -f "$root/.env" ]]; then
    [[ $- == *a* ]] && allexport_was_set=1
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$root/.env"
    [[ "$allexport_was_set" -eq 1 ]] || set +a
    LAB_COMPOSE_ENV_ARGS=(--env-file "$root/.env")
  fi

  LAB_NETWORK="${IGNITE_LAB_NETWORK:-ignite-lab}"
  if [[ ! "$LAB_NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "Invalid IGNITE_LAB_NETWORK: $LAB_NETWORK" >&2
    return 2
  fi
}

lab_compose() {
  local compose_file="$1"
  shift
  docker compose "${LAB_COMPOSE_ENV_ARGS[@]}" -f "$compose_file" "$@"
}

lab_require_builtin_user() {
  local user="${IGNITE_LAB_USER:-ignite}"

  if [[ "$user" != "ignite" ]]; then
    echo "Unsupported IGNITE_LAB_USER '$user'." >&2
    echo "These bootstrap scripts configure the built-in 'ignite' user only." >&2
    return 2
  fi
}
