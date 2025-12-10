#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_NAME:?DATABASE_NAME env var is required}"

SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

# Start SQL Server in the background
/opt/mssql/bin/sqlservr &

MSSQL_PID=$!

echo "Starting SQL Server..."

first_error_logged=false

# Wait for SQL Server to be ready
for i in {1..60}; do
  if "$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" >/dev/null 2>&1; then
    echo "SQL Server is up."
    break
  fi

  if [ "$first_error_logged" = false ]; then
    echo "First connection attempt failed; capturing error for debugging:"
    "$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" || true
    first_error_logged=true
  fi

  echo "Waiting for SQL Server to be ready (${i}/60)..."
  sleep 2
done

if ! "$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" >/dev/null 2>&1; then
  echo "ERROR: SQL Server did not become ready in time."
  kill "$MSSQL_PID" || true
  exit 1
fi

echo "Restoring $DATABASE_NAME if needed..."
"$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "
IF DB_ID('$DATABASE_NAME') IS NULL
BEGIN
  RESTORE DATABASE [$DATABASE_NAME]
  FROM DISK = N'/var/opt/mssql/backup/$DATABASE_NAME.bak'
  WITH MOVE '$DATABASE_NAME' TO '/var/opt/mssql/data/$DATABASE_NAME.mdf',
       MOVE '${DATABASE_NAME}_log' TO '/var/opt/mssql/data/${DATABASE_NAME}_log.ldf',
       REPLACE
END
"

echo "Restore step complete."

# ---- Generate SQL project + DACPAC into /artifacts ----
ARTIFACTS_ROOT="/artifacts"
PROJECT_ROOT="$ARTIFACTS_ROOT/$DATABASE_NAME"
SCHEMA_TMP="$PROJECT_ROOT/SchemaTmp"
DIST_ROOT="$ARTIFACTS_ROOT/dist"

echo "Generating SDK-style SQL project under $PROJECT_ROOT..."

# Clean any existing project folder
rm -rf "$PROJECT_ROOT"

mkdir -p "$PROJECT_ROOT" "$DIST_ROOT"

# Create an SDK-style SQL project (targeting SQL 2022 = Sql160)
cd "$ARTIFACTS_ROOT"
dotnet new sln -n "$DATABASE_NAME" --force

# Support both .sln and .slnx
slnfile=$(ls | grep "^$DATABASE_NAME.*\.sln")

cd "$PROJECT_ROOT"
dotnet new sqlproj -tp Sql160 --force
dotnet sln "$ARTIFACTS_ROOT/$slnfile" add "$DATABASE_NAME.sqlproj"

# Build a connection string that disables strict TLS validation
CONN_STR="Server=localhost;Database=$DATABASE_NAME;User ID=sa;Password=${MSSQL_SA_PASSWORD};Encrypt=False;TrustServerCertificate=True"

# Extract schema into a temp subfolder (SchemaTmp)
sqlpackage \
  /a:Extract \
  /SourceConnectionString:"$CONN_STR" \
  /tf:"$SCHEMA_TMP" \
  /p:ExtractTarget=SchemaObjectType

# Move schema files into the project root and remove temp folder
mv -f "$SCHEMA_TMP"/* "$PROJECT_ROOT"
rm -rf "$SCHEMA_TMP"

echo "SQL project generated at ${PROJECT_ROOT}"

echo "Building generated project (DACPAC) with Version=$VERSION and DacVersion=$VERSION ..."
dotnet build "$DATABASE_NAME.sqlproj" -c Release \
  /p:Version="$VERSION" \
  /p:DacVersion="$VERSION"

DACPAC_PATH="$PROJECT_ROOT/bin/Release/$DATABASE_NAME.dacpac"
if [ -f "$DACPAC_PATH" ]; then
  echo "DACPAC built at $DACPAC_PATH"

  VERSIONED_DACPAC="$DIST_ROOT/${DATABASE_NAME}.${VERSION}.dacpac"

  echo "Copying versioned DACPAC to $VERSIONED_DACPAC..."
  cp "$DACPAC_PATH" "$VERSIONED_DACPAC"
else
  echo "WARNING: DACPAC not found at $DACPAC_PATH"
fi

# ---- EF Core model from DACPAC via EF Core Power Tools CLI ----
cd "$ARTIFACTS_ROOT"
EF_PROJECT_NAME="$DATABASE_NAME.EntityFrameworkCore"
EF_MODEL_DIR="$ARTIFACTS_ROOT/$EF_PROJECT_NAME"

dotnet new classlib -n "$EF_PROJECT_NAME" --force
dotnet sln "$ARTIFACTS_ROOT/$slnfile" add "$EF_PROJECT_NAME/$EF_PROJECT_NAME.csproj"

cd "$EF_MODEL_DIR"
dotnet add package Microsoft.EntityFrameworkCore.SqlServer --version "$EFCORE_VERSION"
dotnet add package Microsoft.EntityFrameworkCore.Design --version "$EFCORE_VERSION"
dotnet add package Microsoft.EntityFrameworkCore.SqlServer.NetTopologySuite --version "$EFCORE_VERSION"
dotnet add package Microsoft.EntityFrameworkCore.SqlServer.HierarchyId --version "$EFCORE_VERSION"

curl -sSL https://raw.githubusercontent.com/ErikEJ/EFCorePowerTools/refs/heads/master/samples/efcpt-config.json \
  | jq '
    # 1. Enable split-dbcontext-preview
    .["file-layout"]["split-dbcontext-preview"] = true

    # 2. Remove tables/views/procs/functions
    # need to set stored procedures to [{"name": "[dbo].[uspSearchCandidateResumesResult]", "include": false}] to include all except uspSearchCandidateResumesResult
    | .tables = null
    | .views = null
    | ."stored-procedures" = [{"name": "[dbo].[uspSearchCandidateResumesResult]", "include": false}]
    | .functions = null

    # 3. Names: use DATABASE_NAME
    | .names["root-namespace"]        = (env.DATABASE_NAME + ".EntityFrameworkCore")
    | .names["dbcontext-name"]        = (env.DATABASE_NAME + "Context")
    | .names["dbcontext-namespace"]   = ""
    | .names["model-namespace"]       = "Models"

    # 4. File Layout: put DbContext in root, models in Models subfolder
    | .["file-layout"]["output-dbcontext-path"] = "."
    | .["file-layout"]["output-path"]           = "Models"

    # 5. Enable Type Mappings
    | .["type-mappings"]["use-DateOnly-TimeOnly"] = true
    | .["type-mappings"]["use-HierarchyId"] = true
    | .["type-mappings"]["use-spatial"] = true
  ' > efcpt-config.json

echo "Generating Entity Framework Core model in $EF_MODEL_DIR from DACPAC..."
# efcpt picks up efcpt-config.json in the project root
efcpt "$DACPAC_PATH" mssql

# Remove default Class1 if it exists
rm -f "$EF_MODEL_DIR/Class1.cs" || true

echo "Building EF Core project with Version=$VERSION ..."
dotnet build "$EF_MODEL_DIR/$EF_PROJECT_NAME.csproj" -c Release \
  /p:Version="$VERSION"

echo "Packing EF Core project into NuGet package with PackageVersion=$VERSION ..."
dotnet pack "$EF_MODEL_DIR/$EF_PROJECT_NAME.csproj" \
  -c Release \
  -o "$DIST_ROOT" \
  /p:PackageVersion="$VERSION" \
  /p:Version="$VERSION"

NUGET_PATH="$DIST_ROOT/${EF_PROJECT_NAME}.${VERSION}.nupkg"
if [ ! -f "$NUGET_PATH" ]; then
  # Fallback: pick first matching nupkg if naming changed
  NUGET_PATH="$(ls "$DIST_ROOT"/*.nupkg | head -n 1 || true)"
fi

# ---- Manifest.json ----
MANIFEST_PATH="$DIST_ROOT/manifest.json"
echo "Writing manifest to $MANIFEST_PATH"

cat > "$MANIFEST_PATH" <<EOF
{
  "databaseName": "$DATABASE_NAME",
  "version": "$VERSION",
  "dacpacVersioned": "$(basename "${VERSIONED_DACPAC:-}")",
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

# ---- Cleanup ----

echo "Stopping SQL Server..."
kill "$MSSQL_PID" || true
wait "$MSSQL_PID" 2>/dev/null || wait "$MSSQL_PID" 2>/dev/null || true

echo "Build-time database materialization and artifact generation complete."
