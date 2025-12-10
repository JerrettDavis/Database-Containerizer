# ==========================
# Stage 1: Builder
# ==========================
FROM mcr.microsoft.com/mssql/server:2022-latest AS builder

ARG DOTNET_VERSION=10.0.100
ARG EFCORE_VERSION=10.0.0
ARG EFCPT_VERSION=10.*
ARG VERSION=1.0.0
ARG DATABASE_BACKUP_URL=https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak
ARG DATABASE_NAME=AdventureWorks2022
ARG SA_PASSWORD=Your_SA_Password123!
ARG IMAGE_REPOSITORY=local/database-containerizer
ARG COMMIT_SHA=local


ENV ACCEPT_EULA=Y \
    MSSQL_PID=Developer \
    MSSQL_SA_PASSWORD=${SA_PASSWORD} \
    MSSQL_TCP_PORT=1433 \
    VERSION=${VERSION} \
    DOTNET_ROOT=/usr/share/dotnet \
    SQLCMDENCRYPT=optional \
    SQLCMDTRUSTSERVERCERTIFICATE=true \
    DATABASE_NAME=${DATABASE_NAME} \
    DATABASE_BACKUP_URL=${DATABASE_BACKUP_URL} \
    EFCPT_VERSION=${EFCPT_VERSION} \
    EFCORE_VERSION=${EFCORE_VERSION} \
    IMAGE_REPOSITORY=${IMAGE_REPOSITORY} \
    COMMIT_SHA=${COMMIT_SHA}

USER root

# Base deps (includes unzip for sqlpackage and jq for config editing)
RUN apt-get update && \
    apt-get install -y wget curl apt-transport-https ca-certificates gnupg unixodbc-dev unzip jq && \
    rm -rf /var/lib/apt/lists/*

# Install .NET via dotnet-install
RUN mkdir -p "$DOTNET_ROOT" && \
    curl -L https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --version "$DOTNET_VERSION" --install-dir "$DOTNET_ROOT" && \
    ln -s "$DOTNET_ROOT/dotnet" /usr/bin/dotnet && \
    rm /tmp/dotnet-install.sh

# Install mssql-tools18 (sqlcmd)
RUN curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list \
        > /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 && \
    ln -s /opt/mssql-tools18/bin/sqlcmd /usr/bin/sqlcmd && \
    rm -rf /var/lib/apt/lists/*

# PATH for dotnet, sqlcmd
ENV PATH="$PATH:$DOTNET_ROOT:/root/.dotnet/tools:/opt/mssql-tools18/bin"

# Install SQL project templates and tools
RUN dotnet new install Microsoft.Build.Sql.Templates
RUN dotnet tool install ErikEJ.EFCorePowerTools.Cli -g --version $EFCPT_VERSION
RUN dotnet tool install dotnet-ef -g --version $EFCORE_VERSION

# Install standalone sqlpackage for Linux (ZIP)
RUN mkdir -p /opt/sqlpackage && \
    curl -L "https://aka.ms/sqlpackage-linux" -o /tmp/sqlpackage-linux.zip && \
    unzip /tmp/sqlpackage-linux.zip -d /opt/sqlpackage && \
    rm /tmp/sqlpackage-linux.zip && \
    chmod +x /opt/sqlpackage/sqlpackage

# Add sqlpackage to PATH
ENV PATH="$PATH:/opt/sqlpackage"

# Prepare backup + scripts + artifacts folder
RUN mkdir -p /var/opt/mssql/backup /scripts /artifacts

# Download the backup
RUN curl -L \
    -o "/var/opt/mssql/backup/${DATABASE_NAME}.bak" \
    "${DATABASE_BACKUP_URL}"

# Bring in the build-time script
COPY restore-and-generate.sh /scripts/restore-and-generate.sh
RUN chmod +x /scripts/restore-and-generate.sh

# Run the script at build time:
# - starts SQL Server
# - restores the database
# - generates sqlproj + dacpac + EFCore NuGet into /artifacts
RUN --mount=type=secret,id=sa_password \
    export MSSQL_SA_PASSWORD="$(cat /run/secrets/sa_password 2>/dev/null || echo "$SA_PASSWORD")" && \
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