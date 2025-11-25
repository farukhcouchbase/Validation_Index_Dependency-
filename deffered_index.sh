#!/usr/bin/env bash
###############################################################################
# SCRIPT 1: Build Deferred Indexes Across Buckets, Scopes, and Collections
###############################################################################

CB_USERNAME=${CB_USERNAME:='Admin'}
CB_PASSWORD=${CB_PASSWORD:='redhat'}
CLUSTER=${CLUSTER:='localhost'}
PORT=${PORT:='8091'}
PROTOCOL=${PROTOCOL:='http'}
QUERY_NODE=${QUERY_NODE:='127.0.0.1'}
QUERY_PORT=${QUERY_PORT:='8093'}
BUCKETS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --username=*) CB_USERNAME="${1#*=}" ;;
    --password=*) CB_PASSWORD="${1#*=}" ;;
    --cluster=*) CLUSTER="${1#*=}" ;;
    --port=*) PORT="${1#*=}" ;;
    --protocol=*) PROTOCOL="${1#*=}" ;;
    --query-node=*) QUERY_NODE="${1#*=}" ;;
    --query-port=*) QUERY_PORT="${1#*=}" ;;
    --bucket=*) BUCKETS="${1#*=}" ;;
    *) exit 1 ;;
  esac
  shift
done

if [ "$(command -v jq)" = "" ]; then
  exit 1
fi

if [[ -z "$QUERY_NODE" ]]; then
  QUERY_NODE=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent \
    "$PROTOCOL://$CLUSTER:$PORT/pools/nodes" | \
    jq -r '.nodes[] | select(.services | contains(["n1ql"])) | .hostname' | head -n 1)

  if [[ "$QUERY_NODE" == "[::1]:8091" ]]; then
    QUERY_NODE="localhost"
  else
    QUERY_NODE=$(echo "$QUERY_NODE" | sed 's/:.*//')
  fi
fi

if [ -n "$BUCKETS" ]; then
  IFS=',' read -ra bucket_list <<< "$BUCKETS"
else
  mapfile -t bucket_list < <(
    curl --user "$CB_USERNAME:$CB_PASSWORD" --silent \
      "$PROTOCOL://$CLUSTER:$PORT/pools/default/buckets" |
    jq -r '.[].name'
  )
fi

for bucket in "${bucket_list[@]}"; do

  scopes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent \
    "$PROTOCOL://$CLUSTER:$PORT/pools/default/buckets/$bucket/scopes")

  # DEFAULT SCOPE
  echo "$scopes" | jq -c '.scopes[] | select(.name == "default")' | \
  while read scope; do
    scope_name=$(echo "$scope" | jq -r '.name')

    echo "$scope" | jq -c '.collections[]' | \
    while read collection; do
      collection_name=$(echo "$collection" | jq -r '.name')

      deferred_indexes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent \
        "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" \
        --data-urlencode "statement=SELECT RAW name FROM system:indexes WHERE bucket_id = '$bucket' AND scope_id = '$scope_name' AND keyspace_id = '$collection_name' AND state = 'deferred'" |
        jq -r '.results | join(", ")')

      if [ -n "$deferred_indexes" ]; then
        N1QL="BUILD INDEX ON \`$bucket\`.\`$scope_name\`.\`$collection_name\` ($deferred_indexes)"
        curl --user "$CB_USERNAME:$CB_PASSWORD" --silent --request POST \
          --data-urlencode "statement=$N1QL" \
          "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" >/dev/null 2>&1
      fi
    done
  done

  # NON-DEFAULT SCOPES
  echo "$scopes" | jq -c '.scopes[] | select(.name != "default")' | \
  while read scope; do
    scope_name=$(echo "$scope" | jq -r '.name')

    echo "$scope" | jq -c '.collections[]' | \
    while read collection; do
      collection_name=$(echo "$collection" | jq -r '.name')

      deferred_indexes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent \
        "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" \
        --data-urlencode "statement=SELECT RAW name FROM system:indexes WHERE bucket_id = '$bucket' AND scope_id = '$scope_name' AND keyspace_id = '$collection_name' AND state = 'deferred'" |
        jq -r '.results | join(", ")')

      if [ -n "$deferred_indexes" ]; then
        N1QL="BUILD INDEX ON \`$bucket\`.\`$scope_name\`.\`$collection_name\` ($deferred_indexes)"
        curl --user "$CB_USERNAME:$CB_PASSWORD" --silent --request POST \
          --data-urlencode "statement=$N1QL" \
          "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" >/dev/null 2>&1
      fi
    done
  done
done

###############################################################################
# SCRIPT 2: Build Indexes Using couchbase-cli and cbq
###############################################################################

CBQ="/opt/couchbase/bin/cbq"
CLI="/opt/couchbase/bin/couchbase-cli"

if ! command -v jq >/dev/null 2>&1; then
    exit 1
fi

if [ -n "$BUCKETS" ]; then
    IFS=',' read -ra BUCKET_LIST <<< "$BUCKETS"
else
    ALL_BUCKETS=$($CLI bucket-list -c "$CLUSTER:$PORT" -u "$CB_USERNAME" -p "$CB_PASSWORD" 2>/dev/null | grep -v "^[[:space:]]")
    IFS=$'\n' read -r -d '' -a BUCKET_LIST <<< "$ALL_BUCKETS"
fi

for bucket in "${BUCKET_LIST[@]}"; do

    INDEXES_JSON=$($CBQ -u "$CB_USERNAME" -p "$CB_PASSWORD" -q=true \
      -s "SELECT name FROM system:indexes WHERE keyspace_id = '$bucket';" 2>/dev/null)

    INDEX_NAMES=$(echo "$INDEXES_JSON" | jq -r '.results[].name' 2>/dev/null)

    if [ -z "$INDEX_NAMES" ]; then
        continue
    fi

    INDEX_LIST=$(printf "%s," $INDEX_NAMES | sed 's/,$//')

    BUILD_QUERY="BUILD INDEX ON \`$bucket\`($INDEX_LIST);"

    $CBQ -u "$CB_USERNAME" -p "$CB_PASSWORD" -q=true -s "$BUILD_QUERY" >/dev/null 2>&1

done
