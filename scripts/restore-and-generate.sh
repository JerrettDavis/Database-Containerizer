#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_NAME:?DATABASE_NAME env var is required}"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
RESTORE_FILE="/var/opt/mssql/backup/$DATABASE_NAME.bak"

###########################################
#  function: start_sql_server
###########################################
start_sql_server() {
  echo "Starting SQL Server..."
  /opt/mssql/bin/sqlservr &
  MSSQL_PID=$!
}


###########################################
#  function: wait_for_sql_server
###########################################
wait_for_sql_server() {
  echo "Waiting for SQL Server to become ready..."
  local first_error_logged=false

  for i in {1..60}; do
    if "$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" >/dev/null 2>&1; then
      echo "SQL Server is up."
      return 0
    fi

    if [ "$first_error_logged" = false ]; then
      echo "First connection attempt failed; capturing diagnostic output:"
      "$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" || true
      first_error_logged=true
    fi

    echo "Still waiting (${i}/60)..."
    sleep 2
  done

  echo "ERROR: SQL Server did not become ready in time."
  kill "$MSSQL_PID" || true
  exit 1
}


###########################################
#  function: restore_database
###########################################
restore_database() {
  echo "Restoring $DATABASE_NAME if needed..."

  echo "Reading logical file names from backup..."
  local FILELIST
  FILELIST="$(
    $SQLCMD -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" \
    -Q "RESTORE FILELISTONLY FROM DISK = N'$RESTORE_FILE'" \
    -s"|" -W -h -1
  )"

  DATA_LOGICAL=$(echo "$FILELIST" | grep "|D|" | awk -F"|" '{print $1}')
  LOG_LOGICAL=$(echo "$FILELIST"  | grep "|L|" | awk -F"|" '{print $1}')

  echo "  Data logical name: $DATA_LOGICAL"
  echo "  Log logical name:  $LOG_LOGICAL"

  if [ -z "$DATA_LOGICAL" ] || [ -z "$LOG_LOGICAL" ]; then
    echo "ERROR: Unable to determine logical file names from backup."
    echo "$FILELIST"
    exit 1
  fi

  $SQLCMD -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "
IF DB_ID('$DATABASE_NAME') IS NULL
BEGIN
  PRINT 'Restoring database [$DATABASE_NAME] from $RESTORE_FILE';

  RESTORE DATABASE [$DATABASE_NAME]
  FROM DISK = N'$RESTORE_FILE'
  WITH
      MOVE '$DATA_LOGICAL' TO '/var/opt/mssql/data/$DATABASE_NAME.mdf',
      MOVE '$LOG_LOGICAL'  TO '/var/opt/mssql/data/${DATABASE_NAME}_log.ldf',
      REPLACE, RECOVERY;
END
ELSE
BEGIN
  PRINT 'Database [$DATABASE_NAME] already exists, skipping restore.';
END
  "

  echo "Restore step complete."
}


###########################################
#  function: generate_sql_project
###########################################
generate_sql_project() {
  ARTIFACTS_ROOT="/artifacts"
  PROJECT_ROOT="$ARTIFACTS_ROOT/$DATABASE_NAME"
  SCHEMA_TMP="$PROJECT_ROOT/SchemaTmp"
  DIST_ROOT="$ARTIFACTS_ROOT/dist"

  export ARTIFACTS_ROOT PROJECT_ROOT SCHEMA_TMP DIST_ROOT

  echo "Generating SDK-style SQL project in $PROJECT_ROOT..."

  rm -rf "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT" "$DIST_ROOT"

  cd "$ARTIFACTS_ROOT"
  dotnet new sln -n "$DATABASE_NAME" --force

  slnfile=$(ls | grep "^$DATABASE_NAME.*\.sln")

  cd "$PROJECT_ROOT"
  dotnet new sqlproj -tp Sql160 --force
  dotnet sln "$ARTIFACTS_ROOT/$slnfile" add "$DATABASE_NAME.sqlproj"

  local CONN_STR="Server=localhost;Database=$DATABASE_NAME;User ID=sa;Password=${MSSQL_SA_PASSWORD};Encrypt=False;TrustServerCertificate=True"

  sqlpackage \
    /a:Extract \
    /SourceConnectionString:"$CONN_STR" \
    /tf:"$SCHEMA_TMP" \
    /p:ExtractTarget=SchemaObjectType

  mv -f "$SCHEMA_TMP"/* "$PROJECT_ROOT"
  rm -rf "$SCHEMA_TMP"

  echo "SQL project extracted."
}


###########################################
#  function: build_dacpac
###########################################
build_dacpac() {
  echo "Building DACPAC..."
  cd "$PROJECT_ROOT"

  dotnet build "$DATABASE_NAME.sqlproj" -c Release \
    /p:Version="$VERSION" \
    /p:DacVersion="$VERSION"

  dotnet pack "$DATABASE_NAME.sqlproj" \
    -c Release \
    -o "$DIST_ROOT" \
    /p:PackageVersion="$VERSION" \
    /p:Version="$VERSION"

  DACPAC_PATH="$PROJECT_ROOT/bin/Release/$DATABASE_NAME.dacpac"
  VERSIONED_DACPAC="$DIST_ROOT/${DATABASE_NAME}.${VERSION}.dacpac"
  SQLPROJ_NUGET_PATH="$DIST_ROOT/${DATABASE_NAME}.${VERSION}.nupkg"

  export DACPAC_PATH VERSIONED_DACPAC

  if [ -f "$DACPAC_PATH" ]; then
    echo "Copying DACPAC to $VERSIONED_DACPAC"
    cp "$DACPAC_PATH" "$VERSIONED_DACPAC"
  else
    echo "WARNING: DACPAC missing at $DACPAC_PATH"
  fi
}

###########################################
#  function: generate_efpt_renaming
###########################################

generate_efpt_renaming() {
  local output_dir="${1:-/artifacts}"
  local output_file="${output_dir}/efpt.renaming.json"

  mkdir -p "$output_dir"

  echo "Generating efpt.renaming.json in ${output_file} ..."

  # Query all schema names except dbo, from the target DB,
  # but connect to master to avoid default-database login issues.
  # -h-1: no headers
  # -W  : trim trailing spaces
  # -s" ": space as separator (single-column output)
  local schemas
  schemas="$(
    "$SQLCMD" \
      -C \
      -S localhost \
      -U sa \
      -P "$MSSQL_SA_PASSWORD" \
      -d master \
      -h -1 -W -s" " \
      -Q "SELECT name FROM [$DATABASE_NAME].sys.schemas WHERE name <> 'dbo' ORDER BY name"
  )"

  # Start JSON array
  echo "[" > "$output_file"

  local first=1
  while IFS= read -r schema; do
    schema="$(echo "$schema" | tr -d '\r' | xargs)"
    [ -z "$schema" ] && continue

    if [ $first -eq 0 ]; then
      echo "," >> "$output_file"
    fi
    first=0

    cat >> "$output_file" <<EOF
  {
    "SchemaName": "$schema",
    "UseSchemaName": true
  }
EOF
  done <<EOF_SCHEMAS
$schemas
EOF_SCHEMAS

  echo "]" >> "$output_file"

  echo "efpt.renaming.json generated with the following schemas:"
  echo "$schemas"
}



###########################################
#  function: generate_ef_project
###########################################
generate_ef_project() {
  EF_PROJECT_NAME="${DATABASE_NAME}.EntityFrameworkCore"
  EF_MODEL_DIR="${ARTIFACTS_ROOT}/${EF_PROJECT_NAME}"

  echo "Generating EF Core project at $EF_MODEL_DIR..."

  cd "$ARTIFACTS_ROOT"
  dotnet new classlib -n "$EF_PROJECT_NAME" --force
  dotnet sln "$ARTIFACTS_ROOT/$slnfile" add "$EF_PROJECT_NAME/$EF_PROJECT_NAME.csproj"

  cd "$EF_MODEL_DIR"
  dotnet add package Microsoft.EntityFrameworkCore.SqlServer --version "$EFCORE_VERSION"
  dotnet add package Microsoft.EntityFrameworkCore.Design --version "$EFCORE_VERSION"
  dotnet add package Microsoft.EntityFrameworkCore.SqlServer.NetTopologySuite --version "$EFCORE_VERSION"
  dotnet add package Microsoft.EntityFrameworkCore.SqlServer.HierarchyId --version "$EFCORE_VERSION"

  # ---------------------------
  # Resolve efcpt-config.json
  # ---------------------------
  echo "Preparing efcpt-config.json..."

  if [ -n "${EFCPT_CONFIG_FILE:-}" ] && [ -f "${EFCPT_CONFIG_FILE:-}" ]; then
    echo "Using custom EFCore Power Tools config file: ${EFCPT_CONFIG_FILE}"
    cp "${EFCPT_CONFIG_FILE}" efcpt-config.json

  elif [ -n "${EFCPT_CONFIG_URL:-}" ]; then
    echo "Downloading EFCore Power Tools config from: ${EFCPT_CONFIG_URL}"
    curl -sSL "${EFCPT_CONFIG_URL}" -o efcpt-config.json

  else
    echo "Using default EFCore Power Tools config template (patched via jq)..."
    curl -sSL https://raw.githubusercontent.com/ErikEJ/EFCorePowerTools/refs/heads/master/samples/efcpt-config.json \
      | jq '
          .["file-layout"]["split-dbcontext-preview"] = true
          | .tables = null
          | .views = null
          | ."stored-procedures" = [{"name": "[dbo].[uspSearchCandidateResumesResult]", "include": false}]
          | .functions = null
          | .names["root-namespace"]        = (env.DATABASE_NAME + ".EntityFrameworkCore")
          | .names["dbcontext-name"]        = (env.DATABASE_NAME + "Context")
          | .names["dbcontext-namespace"]   = ""
          | .names["model-namespace"]       = "Models"
          | .["file-layout"]["output-dbcontext-path"] = "."
          | .["file-layout"]["output-path"]           = "Models"
          | .["file-layout"]["use-schema-folders-preview"] = true
          | .["file-layout"]["use-schema-namespaces-preview"] = true
          | .["type-mappings"]["use-DateOnly-TimeOnly"] = true
          | .["type-mappings"]["use-HierarchyId"] = true
          | .["type-mappings"]["use-spatial"] = true
      ' > efcpt-config.json
  fi

  # ---------------------------
  # Schema-based renaming & EF model generation
  # ---------------------------
  generate_efpt_renaming "$EF_MODEL_DIR"

  echo "Generating Entity Framework model from DACPAC..."
  efcpt "$DACPAC_PATH" mssql

  rm -f "Class1.cs" || true

  echo "Building EF Core project..."
  dotnet build "$EF_PROJECT_NAME.csproj" -c Release \
    /p:Version="$VERSION"

  echo "Packing EF Core project..."
  dotnet pack "$EF_PROJECT_NAME.csproj" \
    -c Release \
    -o "$DIST_ROOT" \
    /p:PackageVersion="$VERSION" \
    /p:Version="$VERSION"

  NUGET_PATH="$DIST_ROOT/${EF_PROJECT_NAME}.${VERSION}.nupkg"
}

###########################################
#  function: write_manifest
###########################################
write_manifest() {
  local MANIFEST_PATH="$DIST_ROOT/manifest.json"

  echo "Writing manifest → $MANIFEST_PATH"

  cat > "$MANIFEST_PATH" <<EOF
{
  "databaseName": "$DATABASE_NAME",
  "version": "$VERSION",
  "dacpacVersioned": "$(basename "${VERSIONED_DACPAC:-}")",
  "sqlProjectPackage": "$(basename "${SQLPROJ_NUGET_PATH:-}")",
  "efCorePackage": "$(basename "${NUGET_PATH:-}")",
  "efCoreProjectName": "$EF_PROJECT_NAME",
  "imageRepository": "${IMAGE_REPOSITORY:-unknown}",
  "imageTags": [
    "$VERSION",
    "latest"
  ],
  "commitSha": "${COMMIT_SHA:-unknown}",
  "generatedAtUtc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}


###########################################
# MAIN EXECUTION FLOW
###########################################
start_sql_server
wait_for_sql_server
restore_database
generate_sql_project
build_dacpac
generate_ef_project
write_manifest

echo "Stopping SQL Server..."
kill "$MSSQL_PID" || true
wait "$MSSQL_PID" 2>/dev/null || true

echo "Build-time database materialization and EF generation complete."
