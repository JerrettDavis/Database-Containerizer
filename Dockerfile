# ==========================
# Stage 1: Builder
# ==========================
FROM mcr.microsoft.com/mssql/server:2022-latest AS builder

# --------------------------
# Tooling & infrastructure (stable-ish)
# --------------------------
ARG DOTNET_VERSION=10.0.100
ARG EFCORE_VERSION=10.0.0
ARG EFCPT_VERSION=10.*
ARG USE_INSECURE_SSL=no

# Tooling env (stable)
ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="$PATH:$DOTNET_ROOT:/root/.dotnet/tools:/opt/mssql-tools18/bin:/opt/sqlpackage"

USER root

# Optionally relax SSL verification for apt/curl
RUN if [ "$USE_INSECURE_SSL" = "yes" ]; then \
      echo 'Acquire::https::Verify-Peer "false";'  >  /etc/apt/apt.conf.d/99insecure-https; \
      echo 'Acquire::https::Verify-Host "false";' >> /etc/apt/apt.conf.d/99insecure-https; \
      printf "Acquire { https::Verify-Peer false }\n" > /etc/apt/apt.conf.d/99verify-peer.conf; \
      echo 'WARNING: apt https verification disabled'; \
    fi

# Base deps (includes unzip for sqlpackage and jq for config editing)
RUN apt-get update && \
    apt-get install -y wget curl apt-transport-https ca-certificates gnupg unixodbc-dev unzip jq && \
    rm -rf /var/lib/apt/lists/*

# Install .NET via dotnet-install
RUN if [ "$USE_INSECURE_SSL" = "yes" ]; then CURL_FLAGS=-k; else CURL_FLAGS=; fi; \
    mkdir -p "$DOTNET_ROOT" && \
    curl $CURL_FLAGS -L https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --version "$DOTNET_VERSION" --install-dir "$DOTNET_ROOT" && \
    ln -s "$DOTNET_ROOT/dotnet" /usr/bin/dotnet && \
    rm /tmp/dotnet-install.sh

# Install mssql-tools18 (sqlcmd)
RUN if [ "$USE_INSECURE_SSL" = "yes" ]; then CURL_FLAGS=-k; else CURL_FLAGS=; fi; \
    curl $CURL_FLAGS https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
    curl $CURL_FLAGS https://packages.microsoft.com/config/ubuntu/22.04/prod.list \
        > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 && \
    ln -s /opt/mssql-tools18/bin/sqlcmd /usr/bin/sqlcmd && \
    rm -rf /var/lib/apt/lists/*


# Configure optional extra NuGet feeds
ARG nuget_feeds=""
ARG nuget_auth=""

ENV NUGET_FEEDS="${nuget_feeds}" \
    NUGET_AUTH="${nuget_auth}"

# Copy NuGet configuration script
COPY ./scripts/nuget-configure.sh /scripts/nuget-configure.sh
RUN sed -i 's/\r$//' /scripts/nuget-configure.sh && chmod +x /scripts/nuget-configure.sh

# Configure extra NuGet feeds
RUN /scripts/nuget-configure.sh

# Install SQL project templates and tools (only depend on EFCORE/EFCPT/tooling, not feeds)
RUN dotnet tool install ErikEJ.EFCorePowerTools.Cli -g --version "$EFCPT_VERSION"
RUN dotnet tool install dotnet-ef -g --version "$EFCORE_VERSION"
RUN dotnet new install Microsoft.Build.Sql.Templates@2.0.0

# Make EFCORE/EFCPT versions visible to the restore script
ENV EFCORE_VERSION="${EFCORE_VERSION}" \
    EFCPT_VERSION="${EFCPT_VERSION}"

# Install standalone sqlpackage for Linux (ZIP)
RUN mkdir -p /opt/sqlpackage && \
    if [ "$USE_INSECURE_SSL" = "yes" ]; then CURL_FLAGS=-k; else CURL_FLAGS=; fi; \
    curl $CURL_FLAGS -L "https://aka.ms/sqlpackage-linux" -o /tmp/sqlpackage-linux.zip && \
    unzip /tmp/sqlpackage-linux.zip -d /opt/sqlpackage && \
    rm /tmp/sqlpackage-linux.zip && \
    chmod +x /opt/sqlpackage/sqlpackage


# --------------------------
# Product- & DB-specific (high-churn)
# --------------------------

# DB + build metadata args/env
ARG VERSION=1.0.0
ARG DATABASE_BACKUP_URL=https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak
ARG DATABASE_NAME=AdventureWorks2022

# Optional: name of a .bak file in the local 'backup' folder in the build context
ARG DATABASE_BACKUP_FILE=""

ARG SA_PASSWORD=Your_SA_Password123!
ARG IMAGE_REPOSITORY=local/database-containerizer
ARG COMMIT_SHA=local

ARG efcpt_config_url=""
ARG efcpt_config_file=""

ENV ACCEPT_EULA=Y \
    MSSQL_PID=Developer \
    SQLCMDENCRYPT=optional \
    SQLCMDTRUSTSERVERCERTIFICATE=true

ENV DATABASE_NAME="${DATABASE_NAME}" \
    DATABASE_BACKUP_URL="${DATABASE_BACKUP_URL}" \
    DATABASE_BACKUP_FILE="${DATABASE_BACKUP_FILE}" \
    VERSION="${VERSION}" \
    IMAGE_REPOSITORY="${IMAGE_REPOSITORY}" \
    COMMIT_SHA="${COMMIT_SHA}" \
    EFCPT_CONFIG_URL="${efcpt_config_url}" \
    EFCPT_CONFIG_FILE="${efcpt_config_file}"

# Copy any config files (e.g., efcpt-config.json)
COPY config/ /artifacts

# Prepare backup + scripts + artifacts folder
RUN mkdir -p /var/opt/mssql/backup /scripts /artifacts /build-backups

# Bring any local .bak files into the image (optional)
COPY backup/ /build-backups/

# Choose backup source: file first, otherwise URL
RUN if [ -n "$DATABASE_BACKUP_FILE" ] && [ -f "/build-backups/$DATABASE_BACKUP_FILE" ]; then \
      echo "Using local backup file /build-backups/$DATABASE_BACKUP_FILE"; \
      cp "/build-backups/$DATABASE_BACKUP_FILE" "/var/opt/mssql/backup/${DATABASE_NAME}.bak"; \
    else \
      echo "Local backup not provided or not found; downloading from ${DATABASE_BACKUP_URL}"; \
      curl -L \
        -o "/var/opt/mssql/backup/${DATABASE_NAME}.bak" \
        "${DATABASE_BACKUP_URL}"; \
    fi

# Bring in the build-time script
COPY ./scripts/restore-and-generate.sh /scripts/restore-and-generate.sh
RUN sed -i 's/\r$//' /scripts/restore-and-generate.sh && chmod +x /scripts/restore-and-generate.sh

# Run the script at build time:
# - starts SQL Server
# - restores the database
# - generates sqlproj + dacpac + EFCore NuGet into /artifacts
RUN --mount=type=secret,id=sa_password \
    if [ -f /run/secrets/sa_password ]; then \
        echo "Using MSSQL_SA_PASSWORD from build secret."; \
        MSSQL_SA_PASSWORD="$(cat /run/secrets/sa_password)"; \
    else \
        echo "No sa_password secret found. Falling back to SA_PASSWORD build arg."; \
        MSSQL_SA_PASSWORD="$SA_PASSWORD"; \
    fi; \
    export MSSQL_SA_PASSWORD; \
    /scripts/restore-and-generate.sh

# ==========================
# Stage 2: Runtime image
# ==========================
FROM mcr.microsoft.com/mssql/server:2022-latest

ARG DATABASE_NAME=AdventureWorks2022
ARG SA_PASSWORD=Your_SA_Password123!

ENV ACCEPT_EULA=Y \
    MSSQL_PID=Developer \
    MSSQL_SA_PASSWORD=${SA_PASSWORD} \
    MSSQL_TCP_PORT=1433

USER root

# Copy materialized database files & artifacts from builder
COPY --from=builder /var/opt/mssql /var/opt/mssql
COPY --from=builder /artifacts /artifacts

EXPOSE 1433
