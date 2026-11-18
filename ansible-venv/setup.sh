#!/usr/bin/env bash
#
# Bootstraps a project-local ansible-core virtual environment.
# Intended to live in a git submodule; the parent repo is assumed to be "..".
#
# Overrides (all optional):
#   PYTHON_BIN=python3.12        use a specific interpreter instead of the default python3
#   ANSIBLE_CORE_SPEC=2.16.*     skip auto-selection and install this ansible-core version
#   REQUIREMENTS_FILE=/path.yml  use a different requirements file
#   VENV_DIR=/path/to/venv       build the venv somewhere other than ./venv
#
# pip honors PIP_INDEX_URL / pip.conf, so a local mirror needs no changes here.

set -euo pipefail

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 
# Prefer git's view of the superproject so nested submodule paths work;
# fall back to ".." when git is unavailable or this isn't a submodule.
detect_project_root() {
    local root
    if root="$(git -C "${SCRIPT_DIR}" rev-parse --show-superproject-working-tree 2>/dev/null)" \
        && [[ -n "${root}" ]]; then
        printf '%s\n' "${root}"
    else
        (cd "${SCRIPT_DIR}/.." && pwd)
    fi
}

PROJECT_ROOT="${PROJECT_ROOT:-$(detect_project_root)}"
PROJECT_ROOT="$(cd "${PROJECT_ROOT}" 2>/dev/null && pwd)" \
    || die "PROJECT_ROOT does not exist: ${PROJECT_ROOT}"

VENV_DIR="${VENV_DIR:-${SCRIPT_DIR}/venv}"
BACKUP_DIR="${VENV_DIR}.previous"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${PROJECT_ROOT}/requirements.yml}"
ROLES_DIR="${PROJECT_ROOT}/roles"
COLLECTIONS_DIR="${PROJECT_ROOT}/collections"

# Print the absolute path of the server's default Python 3 interpreter.
# If PYTHON_BIN is set, only that interpreter is considered (no silent fallback).
find_python() {
    local candidates=(python3 python)
    local candidate path

    if [[ -n "${PYTHON_BIN:-}" ]]; then
        candidates=("${PYTHON_BIN}")
    fi

    for candidate in "${candidates[@]}"; do
        path="$(command -v "${candidate}" 2>/dev/null)" || continue
        if "${path}" -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2>/dev/null; then
            printf '%s\n' "${path}"
            return 0
        fi
    done
    return 1
}

# Print "MAJOR.MINOR" for the given interpreter.
python_version() {
    "$1" -c 'import sys; print("%d.%d" % sys.version_info[:2])'
}

# Map a controller Python version to the newest ansible-core line that supports it.
# Source: ansible-core support matrix (docs.ansible.com). Revisit when a new line ships.
ansible_core_for_python() {
    case "$1" in
        3.9)            echo "2.15.*" ;;  # last line supporting a 3.9 controller (EOL)
        3.10)           echo "2.17.*" ;;  # controller 3.10-3.12
        3.11)           echo "2.19.*" ;;  # controller 3.11-3.13
        3.12|3.13|3.14) echo "2.20.*" ;;  # controller 3.12-3.14
        *)              return 1 ;;
    esac
}

# Succeeds if the auto-selected line is past upstream EOL (as of Oct 2026).
is_eol_line() {
    case "$1" in
        2.15.*|2.16.*|2.17.*) return 0 ;;
        *)                    return 1 ;;
    esac
}

# Only ever rm -rf a directory that is recognizably a venv.
is_venv() {
    [[ -f "$1/pyvenv.cfg" ]]
}

# If the build fails after the old venv was moved aside, put it back.
restore_on_failure() {
    local rc=$?
    if (( rc != 0 )) && [[ -d "${BACKUP_DIR}" ]]; then
        warn "Build failed (exit ${rc}); restoring previous venv."
        rm -rf "${VENV_DIR}"
        mv "${BACKUP_DIR}" "${VENV_DIR}"
    fi
}

# --- interpreter + version selection ---------------------------------------

PYTHON="$(find_python)" \
    || die "No usable Python 3 interpreter found (tried: ${PYTHON_BIN:-python3 python})."
PY_VERSION="$(python_version "${PYTHON}")"
 
"${PYTHON}" -c 'import venv, ensurepip' 2>/dev/null \
    || die "Python ${PY_VERSION} (${PYTHON}) lacks venv/ensurepip (Debian/Ubuntu: install python3-venv)."
 
if [[ -n "${ANSIBLE_CORE_SPEC:-}" ]]; then
    CORE_SPEC="${ANSIBLE_CORE_SPEC}"
    log "Using ansible-core override: ${CORE_SPEC}"
else
    CORE_SPEC="$(ansible_core_for_python "${PY_VERSION}")" \
        || die "Python ${PY_VERSION} has no mapped ansible-core version. Set ANSIBLE_CORE_SPEC or PYTHON_BIN."
    if is_eol_line "${CORE_SPEC}"; then
        warn "Python ${PY_VERSION} limits you to ansible-core ${CORE_SPEC}, which is EOL upstream."
        warn "Install a newer interpreter (e.g. dnf install python3.12) and set PYTHON_BIN."
    fi
fi

# Bare versions keep the original "==" behavior; anything else is a pip specifier.
if [[ "${CORE_SPEC}" =~ ^[0-9] ]]; then
    PIP_REQ="ansible-core==${CORE_SPEC}"
else
    PIP_REQ="ansible-core${CORE_SPEC}"
fi
 
log "Project root: ${PROJECT_ROOT}"
log "Interpreter:  Python ${PY_VERSION} (${PYTHON})"
log "Requirement:  ${PIP_REQ}"

# --- venv (rebuilt every run for reproducibility) ---------------------------

if [[ -d "${VENV_DIR}" ]]; then
    log "Removing existing venv at ${VENV_DIR}"
    rm -rf "${VENV_DIR}"
fi

log "Creating venv at ${VENV_DIR}"
"${PYTHON}" -m venv "${VENV_DIR}"

# Call the venv's binaries directly instead of sourcing activate.
VENV_PY="${VENV_DIR}/bin/python"
GALAXY="${VENV_DIR}/bin/ansible-galaxy"

log "Upgrading pip"
"${VENV_PY}" -m pip install --quiet --upgrade pip

log "Installing ansible-core==${CORE_SPEC}"
"${VENV_PY}" -m pip install "ansible-core==${CORE_SPEC}"

# --- roles / collections (optional) -----------------------------------------

if [[ -f "${REQUIREMENTS_FILE}" ]]; then
    # Run from the parent repo so ansible-galaxy picks up its ansible.cfg
    # (galaxy server_list for an internal mirror, roles_path, etc.).
    (
        cd "${PROJECT_ROOT}"
        mkdir -p "${ROLES_DIR}" "${COLLECTIONS_DIR}"

        log "Installing roles from ${REQUIREMENTS_FILE} -> ${ROLES_DIR}"
        "${GALAXY}" role install -r "${REQUIREMENTS_FILE}" -p "${ROLES_DIR}" --force

        log "Installing collections from ${REQUIREMENTS_FILE} -> ${COLLECTIONS_DIR}"
        "${GALAXY}" collection install -r "${REQUIREMENTS_FILE}" -p "${COLLECTIONS_DIR}" --force
    )
else
    log "No requirements file at ${REQUIREMENTS_FILE}; skipping roles and collections."
fi

# --- summary ----------------------------------------------------------------

echo
log "Done."
echo "    ansible-core: $("${VENV_DIR}/bin/ansible" --version | head -n1)"
echo "    python:       ${PY_VERSION} (${PYTHON})"
echo "    venv path:    ${VENV_DIR}"
if [[ -f "${REQUIREMENTS_FILE}" ]]; then
    echo "    roles:        ${ROLES_DIR}"
    echo "    collections:  ${COLLECTIONS_DIR}"
fi
echo
echo "Activate with:"
echo "    source ${VENV_DIR}/bin/activate"

