# **Database Containerizer – Automated SQL Server → DACPAC → EF Core Model Pipeline**

> **Build once. Reuse everywhere.**  
> This project provides a fully automated, reproducible, Docker-based pipeline that:
>
> 1. Spins up SQL Server inside a builder container  
> 2. Restores a `.bak` backup into SQL Server  
> 3. Extracts a **DACPAC** using `sqlpackage`  
> 4. Generates a **SQL Server Database Project (.sqlproj)**  
> 5. Generates an **Entity Framework Core model** using *EFCore Power Tools CLI*  
> 6. Produces **versioned distributable artifacts**:  
>    - `.dacpac`  
>    - `.sqlproj` folder  
>    - NuGet package containing the EFCore model  
> 7. Copies them to `/artifacts/dist`  
> 8. Produces a final runtime SQL Server image with the database already materialized

This containerized build system enables organizations to standardize database provisioning, reverse engineering, schema extraction, and API model generation—fully automated, deterministic, and CI/CD-friendly.

---

## **Why this exists**

Database scaffolding is often painful, inconsistent, and environment-dependent.  
This repository solves the problem by:

- Running *every step* inside a Linux builder container  
- Guaranteeing reproducible database and schema artifacts  
- Automatically generating EF Core models and NuGet packages  
- Making the outputs portable, cacheable, and versionable  
- Eliminating local setup requirements (SQL Server, tools, SDKs)

It is ideal for:

- **Enterprise environments** needing consistent artifacts across teams  
- **Open source projects** wanting to publish ready-to-use models  
- **CI/CD systems** that need automated database builds  
- **Teams migrating legacy SQL databases into modern .NET solutions**

---

## **Features**

### ✔ Automated SQL restore  
Restores any `.bak` file to SQL Server 2022 inside the builder container.

### ✔ Automated DACPAC generation  
Uses **sqlpackage** (standalone Linux version) to extract schema.

### ✔ Automated `.sqlproj` creation  
Builds a full SDK-style SQL project, ready for Visual Studio / Azure DevOps / MSBuild pipelines.

### ✔ EF Core Model Generation  
Powered by **EF Core Power Tools CLI**, generating:
- Clean entity classes  
- Fluent configuration files  
- Split DbContext (preview)  
- Optional hierarchy, spatial, and advanced types  

### ✔ NuGet packaging  
Builds and version-stamps a distributable:
```

<DatabaseName>.EntityFrameworkCore.<version>.nupkg

```

### ✔ Version stamping  
A single `VERSION` build argument propagates to:
- DACPAC (`DacVersion`)
- SQL project (`Version`)
- EF Core DLL
- NuGet Package (`PackageVersion`)

### ✔ Secrets support  
Secure SA password injection using Docker BuildKit secrets.

### ✔ Multi-stage Dockerfile  
Produces:
1. A builder image that extracts and packages all artifacts  
2. A runtime SQL Server image with the fully materialized restored database  

---

## **Repository Structure**

```
.
├─ Dockerfile
├─ restore-and-generate.sh
├─ artifacts/              # Populated at build time
│  ├─ <DatabaseName>/
│  ├─ <DatabaseName>.EntityFrameworkCore/
│  └─ dist/
│     ├─ *.dacpac
│     └─ *.nupkg
└─ README.md

```

The `/artifacts` directory only exists after building the image or exporting artifacts via `docker cp`.

---

## **Prerequisites**

You need:

- Docker Desktop or Docker Engine 20+  
- BuildKit enabled (required for secrets)  
- Internet access to download:
  - SQL Server base image  
  - .NET SDK  
  - sqlpackage  
  - EFCore Power Tools CLI  

Enable BuildKit:

```bash
export DOCKER_BUILDKIT=1
```

---

## **Building the Builder Image**

### **With secret SA password**

```bash
printf "MyStrongPassword123!" | docker build \
  --secret id=sa_password,stdin \
  --build-arg VERSION=1.2.3 \
  --build-arg DATABASE_NAME=AdventureWorks2022 \
  -t db-builder .
```

### **Without secret (fallback)**

Not recommended for real environments; logs the password.

```bash
docker build \
  --build-arg SA_PASSWORD=MyPassword \
  --build-arg VERSION=1.2.3 \
  -t db-builder .
```

---

## **Extracting Artifacts From the Builder Image**

Best method: `docker create` + `docker cp`.

```bash
docker create --name dbtmp db-builder
docker cp dbtmp:/artifacts ./artifacts
docker rm dbtmp
```

Artifacts produced:

```
artifacts/dist/<DatabaseName>.<Version>.dacpac
artifacts/dist/<DatabaseName>.EntityFrameworkCore.<Version>.nupkg
artifacts/<DatabaseName>/*.sqlproj
```

---

## **Producing the Final Runtime Image**

```bash
docker build -t mydb-runtime --target runtime .
```

Run it:

```bash
docker run -d \
  -e ACCEPT_EULA=Y \
  -e MSSQL_SA_PASSWORD="MyStrongPassword123!" \
  -p 1433:1433 \
  mydb-runtime
```

This SQL Server instance already contains the restored database.

---

## **Using the Output Artifacts**

### **DACPAC**

Publish to any SQL environment:

```bash
sqlpackage /a:Publish \
           /SourceFile:AdventureWorks2022.dacpac \
           /TargetConnectionString:"Server=...;"
```

### **NuGet Package**

Consume the autogenerated EF Core model:

```bash
dotnet add package AdventureWorks2022.EntityFrameworkCore --version 1.2.3
```

Works with:

* NuGet.org
* GitHub Packages
* Azure Artifacts
* Nexus / Artifactory internal feeds

---

## **Configuration Reference**

| Build Arg             | Description                | Example            |
| --------------------- | -------------------------- | ------------------ |
| `DATABASE_NAME`       | Logical DB name            | AdventureWorks2022 |
| `DATABASE_BACKUP_URL` | URL to `.bak`              | https://...        |
| `VERSION`             | Artifact version           | 1.2.3              |
| `EFCORE_VERSION`      | EF Core version            | 10.0.0             |
| `EFCPT_VERSION`       | EFCore Power Tools version | 10.*               |
| `SA_PASSWORD`         | Fallback SA password       | MyPassword         |

---

## **Security Notes**

* Prefer BuildKit secrets always
* Avoid committing passwords into Dockerfile ARG/ENV
* Final runtime image does *not* include build secrets
* Builder stage is discardable in CI/CD pipelines

---

## **Contributing**

Contributions are welcome!
Feel free to submit pull requests, bug reports, or feature requests.

---

## **License**

Licensed under the **MIT License**.
Perfect for open source, commercial, and enterprise use.

---

## **Credits**

* [Microsoft SQL Server Team](https://github.com/MicrosoftDocs/sql-docs)
* [.NET SDK Team](https://github.com/microsoft/dotnet)
* [ErikEJ – *EF Core Power Tools*](https://github.com/ErikEJ/EFCorePowerTools)
* [AdventureWorks Sample Database](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/adventure-works)


