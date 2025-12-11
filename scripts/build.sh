#!/usr/bin/env bash
set -euo pipefail

# Defaults
NUGET_FEEDS=""
NUGET_AUTH=""
USE_INSECURE_SSL="no"
VERSION="1.0.0"
SA_PASSWORD="YourStrong!P@ssw0rd"
IMAGE_REPOSITORY="local/database-containerizer"
EFCPT_CONFIG_URL=""
EFCPT_CONFIG_FILE=""
DATABASE_BACKUP_URL=""
DATABASE_BACKUP_FILE=""
DATABASE_NAME="MyDB"
TAG="mydb"
CONTEXT=""
EXTRACT_TO=""
NO_EXTRACT_ARTIFACTS=0

print_help() {
  cat <<EOF
Usage: build.sh [options]

Options:
  --nuget_feeds=VALUE          Semicolon-separated NuGet feeds (name=url or url)
  --nuget_auth=VALUE           Semicolon-separated name=PAT pairs
  --use_insecure_ssl=VALUE     yes|no – controls curl/apt SSL verification
  --version=VALUE              Product/database artifact version
  --sa_password=VALUE          SA password for SQL Server (build-time)
  --image_repository=VALUE     Metadata only, for manifest
  --efcpt_config_url=VALUE     URL to efcpt-config.json (optional)
  --efcpt_config_file=VALUE    Path in build context to efcpt-config.json
  --database_backup_url=VALUE  URL to database .bak (optional)
  --database_backup_file=VALUE Local .bak filename under /backup (optional)
  --database_name=VALUE        Database name
  --tag=VALUE                  Docker image tag
  --context=PATH               Docker build context (default: repo root)
  --extract_to=PATH            Where to extract /artifacts (default: ./artifacts)
  --no_extract_artifacts       Do not extract /artifacts
  -h, --help                   Show this help
EOF
}

# ------------------ parse args ------------------
for arg in "$@"; do
  case "$arg" in
    --nuget_feeds=*)          NUGET_FEEDS="${arg#*=}" ;;
    --nuget_auth=*)           NUGET_AUTH="${arg#*=}" ;;
    --use_insecure_ssl=*)     USE_INSECURE_SSL="${arg#*=}" ;;
    --version=*)              VERSION="${arg#*=}" ;;
    --sa_password=*)          SA_PASSWORD="${arg#*=}" ;;
    --image_repository=*)     IMAGE_REPOSITORY="${arg#*=}" ;;
    --efcpt_config_url=*)     EFCPT_CONFIG_URL="${arg#*=}" ;;
    --efcpt_config_file=*)    EFCPT_CONFIG_FILE="${arg#*=}" ;;
    --database_backup_url=*)  DATABASE_BACKUP_URL="${arg#*=}" ;;
    --database_backup_file=*) DATABASE_BACKUP_FILE="${arg#*=}" ;;
    --database_name=*)        DATABASE_NAME="${arg#*=}" ;;
    --tag=*)                  TAG="${arg#*=}" ;;
    --context=*)              CONTEXT="${arg#*=}" ;;
    --extract_to=*)           EXTRACT_TO="${arg#*=}" ;;
    --no_extract_artifacts)   NO_EXTRACT_ARTIFACTS=1 ;;
    -h|--help)                print_help; exit 0 ;;
    *)
      echo "Unknown argument: $arg" >&2
      print_help
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$CONTEXT" ]; then
  CONTEXT="$REPO_ROOT"
fi

if [ -z "$EXTRACT_TO" ]; then
  EXTRACT_TO="$REPO_ROOT/artifacts"
fi

echo "[DEBUG] build.sh invoked (PID $$), args: $*"
echo "Building image '$TAG' using context '$CONTEXT'..."
echo "  DATABASE_NAME        = $DATABASE_NAME"
echo "  VERSION              = $VERSION"
echo "  NUGET_FEEDS          = $NUGET_FEEDS"
echo "  NUGET_AUTH           = $NUGET_AUTH"
echo "  USE_INSECURE_SSL     = $USE_INSECURE_SSL"
echo "  DATABASE_BACKUP_URL  = $DATABASE_BACKUP_URL"
echo "  DATABASE_BACKUP_FILE = $DATABASE_BACKUP_FILE"
echo "  EFCPT_CONFIG_URL     = $EFCPT_CONFIG_URL"
echo "  EFCPT_CONFIG_FILE    = $EFCPT_CONFIG_FILE"
echo "  ARTIFACT EXTRACT TO  = $EXTRACT_TO"
echo

build_args=(
  --progress=plain
  --build-arg "nuget_feeds=$NUGET_FEEDS"
  --build-arg "nuget_auth=$NUGET_AUTH"
  --build-arg "USE_INSECURE_SSL=$USE_INSECURE_SSL"
  --build-arg "VERSION=$VERSION"
  --build-arg "SA_PASSWORD=$SA_PASSWORD"
  --build-arg "IMAGE_REPOSITORY=$IMAGE_REPOSITORY"
  --build-arg "efcpt_config_url=$EFCPT_CONFIG_URL"
  --build-arg "efcpt_config_file=$EFCPT_CONFIG_FILE"
  --build-arg "DATABASE_BACKUP_URL=$DATABASE_BACKUP_URL"
  --build-arg "DATABASE_BACKUP_FILE=$DATABASE_BACKUP_FILE"
  --build-arg "DATABASE_NAME=$DATABASE_NAME"
  -t "$TAG"
  "$CONTEXT"
)

echo "Running: docker build ${build_args[*]}"
docker build "${build_args[@]}"

if [ "$NO_EXTRACT_ARTIFACTS" -eq 1 ]; then
  echo "Skipping artifact extraction (--no_extract_artifacts)."
  exit 0
fi

tmp_container="${TAG}-tmp-$$"
echo "Creating temp container '$tmp_container' to extract /artifacts..."
docker create --name "$tmp_container" "$TAG" >/dev/null

mkdir -p "$EXTRACT_TO"
echo "Copying container /artifacts → $EXTRACT_TO"
docker cp "${tmp_container}:/artifacts/." "$EXTRACT_TO"

echo "Removing temp container '$tmp_container'..."
docker rm "$tmp_container" >/dev/null

echo "Artifacts extracted to: $EXTRACT_TO"
echo "Build complete."

