#!/usr/bin/env sh
set -eu

# NUGET_FEEDS: semicolon-separated list
#   - "name=url"  or just "url"
# NUGET_AUTH: semicolon-separated "name=PAT" pairs

: "${NUGET_FEEDS:=}"
: "${NUGET_AUTH:=}"

if [ -z "$NUGET_FEEDS" ]; then
  echo "No extra NuGet feeds provided."
  exit 0
fi

echo "Configuring NuGet feeds from NUGET_FEEDS..."

counter=1

# Snapshot feeds into positional args
OLDIFS=$IFS
IFS=';'
set -- $NUGET_FEEDS
IFS=$OLDIFS

for entry in "$@"; do
  [ -z "$entry" ] && continue

  # name=url or just url
  case "$entry" in
    *"="*)
      name=${entry%%=*}
      url=${entry#*=}
      ;;
    *)
      name="ExtraFeed${counter}"
      url="$entry"
      counter=$((counter+1))
      ;;
  esac

  # Look up matching PAT (if any) by name
  auth_pass=""
  if [ -n "${NUGET_AUTH:-}" ]; then
    OLDIFS2=$IFS
    IFS=';'
    set -- $NUGET_AUTH
    IFS=$OLDIFS2

    for auth_entry in "$@"; do
      [ -z "$auth_entry" ] && continue
      auth_name=${auth_entry%%=*}
      auth_val=${auth_entry#*=}
      if [ "$auth_name" = "$name" ]; then
        auth_pass="$auth_val"
        break
      fi
    done
  fi

  echo "Configuring NuGet source '$name' → '$url'"

  dotnet nuget remove source "$name" >/dev/null 2>&1 || true

  if [ -n "$auth_pass" ]; then
    echo "  (using PAT from NUGET_AUTH)"
    dotnet nuget add source "$url" \
      --name "$name" \
      --username "pat" \
      --password "$auth_pass" \
      --store-password-in-clear-text || true
  else
    dotnet nuget add source "$url" --name "$name" || true
  fi
done

echo "Final NuGet sources:"
dotnet nuget list source