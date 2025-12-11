# **Database Containerizer**

This project provides a reproducible, containerized build system that restores a SQL Server backup inside a build container, extracts schema artifacts, generates a SQL project, produces a DACPAC, generates an EF Core model, and outputs versioned build artifacts. The process runs entirely inside Docker and does not require SQL Server or supporting tools to be installed locally.

The build also produces a runtime SQL Server image with the restored database pre-materialized.

---

## **Overview**

The builder container performs the following operations:

1. Starts SQL Server in the build environment
2. Restores a database from a `.bak` file (local or remote URL)
3. Determines logical file names automatically via `RESTORE FILELISTONLY`
4. Extracts schema using **sqlpackage**
5. Creates an SDK-style `.sqlproj` database project
6. Builds a DACPAC
7. Generates an Entity Framework Core model using **EF Core Power Tools CLI**
8. Applies configuration from a provided EF Core PT config file or URL
9. Generates `efpt.renaming.json` based on database schemas
10. Produces versioned artifacts under `/artifacts`
11. Writes a `manifest.json` describing all outputs

A second stage produces a runtime SQL Server image that includes the fully restored database files.

---

## **Repository Structure**

```
.
├── Dockerfile
├── scripts/
│   ├── build.sh          # Linux/macOS builder wrapper
│   ├── build.ps1         # PowerShell wrapper
│   ├── restore-and-generate.sh
│   └── nuget-setup.sh    # feed configuration logic
├── backup/               # optional local .bak files
├── artifacts/            # populated after build
└── README.md
```

---

## **Build Inputs**

All configuration is provided using Docker build arguments or the wrapper scripts.

| Argument               | Description                                                |
| ---------------------- | ---------------------------------------------------------- |
| `DATABASE_NAME`        | Name of the database to restore and generate artifacts for |
| `DATABASE_BACKUP_FILE` | Local `.bak` file located in `backup/`                     |
| `DATABASE_BACKUP_URL`  | Remote backup URL (used when no local file is provided)    |
| `VERSION`              | Version applied to DACPAC, SQL Project, and NuGet output   |
| `EFCORE_VERSION`       | EF Core version to reference                               |
| `EFCPT_VERSION`        | EF Core Power Tools CLI version                            |
| `efcpt_config_url`     | URL to a custom EF Core PT configuration file              |
| `efcpt_config_file`    | Path to a config file within the build context             |
| `nuget_feeds`          | Semicolon-separated list of feeds (`Name=url` or `url`)    |
| `nuget_auth`           | Semicolon-separated PAT list (`Name=token`)                |
| `SA_PASSWORD`          | SA password used when no secret is supplied                |
| `USE_INSECURE_SSL`     | Allows curl/apt without certificate validation             |

---

## **Build Wrapper Scripts**

### **POSIX Shell**

Located at:

```
scripts/build.sh
```

Example:

```bash
./scripts/build.sh \
  --database_name MyDb \
  --database_backup_file backup.bak \
  --version 1.0.0 \
  --nuget_feeds "Internal=https://pkgs.dev.azure.com/org/_packaging/Internal/nuget/v3/index.json" \
  --nuget_auth "Internal=myPAT" \
  --efcpt_config_url "https://example.com/myconfig.json" \
  --tag mydb
```

---

### **PowerShell**

Located at:

```
scripts/build.ps1
```

Example:

```powershell
pwsh ./scripts/build.ps1 `
  -DatabaseName "MyDb" `
  -DatabaseBackupFile "backup.bak" `
  -Version "1.0.0" `
  -NugetFeeds "Internal=https://.../nuget/v3/index.json" `
  -NugetAuth "Internal=myPAT" `
  -EfcptConfigUrl "https://example.com/myconfig.json" `
  -Tag "mydb"
```

Both scripts:

* Forward arguments to `docker build`
* Support all configuration parameters
* Optionally extract `/artifacts` to the host using `--extract`

---

## **Manual Docker Build**

```bash
docker build \
  --build-arg DATABASE_NAME=MyDb \
  --build-arg DATABASE_BACKUP_FILE=mydb.bak \
  --build-arg VERSION=1.0.0 \
  -t mydb .
```

Use secret password injection if desired:

```bash
printf "StrongP@ss" | docker build \
  --secret id=sa_password,stdin \
  ...
```

---

## **Extracting Artifacts**

Artifacts produced:

* DACPAC under `/artifacts/dist`
* NuGet package containing EF model
* SQL project folder
* Manifest indicating all output paths

Extraction example:

```bash
docker create --name tmp mydb
docker cp tmp:/artifacts ./artifacts
docker rm tmp
```

---

## **Runtime SQL Server Image**

The runtime stage of the Dockerfile contains a SQL Server instance with the fully restored database.

Build it:

```bash
docker build --target runtime -t mydb-runtime .
```

Run it:

```bash
docker run -d \
  -e ACCEPT_EULA=Y \
  -e MSSQL_SA_PASSWORD="StrongP@ss" \
  -p 1433:1433 \
  mydb-runtime
```

The database is immediately available inside the container.

---

## **Output Files**

Example artifact layout:

```
artifacts/
├── MyDb/
│   ├── MyDb.sqlproj
│   ├── Schema/
│   └── ...
├── MyDb.EntityFrameworkCore/
│   ├── Models/
│   └── MyDbContext.cs
└── dist/
    ├── MyDb.1.0.0.dacpac
    ├── MyDb.EntityFrameworkCore.1.0.0.nupkg
    └── manifest.json
```

The manifest includes:

```json
{
  "databaseName": "MyDb",
  "version": "1.0.0",
  "dacpacVersioned": "MyDb.1.0.0.dacpac",
  "efCorePackage": "MyDb.EntityFrameworkCore.1.0.0.nupkg",
  "generatedAtUtc": "..."
}
```

---

## **EF Core Power Tools Configuration**

The EF model generator supports three modes:

### 1. **Explicit local config**

```
--build-arg efcpt_config_file=./configs/custom.json
```

### 2. **Config downloaded from a URL**

```
--build-arg efcpt_config_url=https://example.com/config.json
```

### 3. **Implicit configuration (default)**

If neither argument is provided, a base config is fetched from the EFCorePT repository and modified with:

* Namespaces based on database name
* File output paths
* Type mapping options
* Removing table/view/proc filters unless specified
* Enabling schema-based foldering

---

## **Schema-Based Renaming File**

During the build, the script inspects:

```
SELECT name FROM sys.schemas WHERE name <> 'dbo'
```

It produces:

```
efpt.renaming.json
```

This is used by EF Core PT to generate per-schema namespaces or folder structures.

---

## **NuGet Feed Configuration**

The feed configuration script supports:

```
nuget_feeds="Internal=https://...;Public=https://api.nuget.org/v3/index.json"
nuget_auth="Internal=myPAT"
```

Feeds without name mappings are assigned names automatically.

Credentials are only applied when the feed name matches a PAT entry.

