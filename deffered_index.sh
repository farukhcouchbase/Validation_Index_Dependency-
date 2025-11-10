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
BUCKETS=""   # Optional comma-separated bucket argument

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
    *) printf "* Error: Invalid argument.\n"; exit 1 ;;
  esac
  shift
done

if [ "$(command -v jq)" = "" ]; then
  echo >&2 "jq command is required, see (https://stedolan.github.io/jq/download)"
  exit 1
fi

# Find a query node in the cluster to use if not specified
if [[ -z "$QUERY_NODE" ]]; then
  QUERY_NODE=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$CLUSTER:$PORT/pools/nodes" | \
    jq -r '.nodes[] | select(.services | contains(["n1ql"])) | .hostname' | head -n 1)

  if [[ "$QUERY_NODE" == "[::1]:8091" ]]; then
    QUERY_NODE="localhost"
  else
    QUERY_NODE=$(echo "$QUERY_NODE" | sed 's/:.*//')
  fi
fi

# Determine list of buckets
if [ -n "$BUCKETS" ]; then
  IFS=',' read -ra bucket_list <<< "$BUCKETS"
else
  mapfile -t bucket_list < <(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$CLUSTER:$PORT/pools/default/buckets" | jq -r '.[].name')
fi

# Loop through each bucket
for bucket in "${bucket_list[@]}"; do
  echo "Processing Bucket: $bucket"

  scopes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$CLUSTER:$PORT/pools/default/buckets/$bucket/scopes")

  # Process default scope first
  echo "$scopes" | jq -c '.scopes[] | select(.name == "default")' | while read scope; do
    scope_name=$(echo "$scope" | jq -r '.name')
    echo "  Processing Scope: $scope_name"

    echo "$scope" | jq -c '.collections[]' | while read collection; do
      collection_name=$(echo "$collection" | jq -r '.name')
      echo "    Processing Collection: $collection_name"

      deferred_indexes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" \
        --data-urlencode "statement=SELECT RAW name FROM system:indexes WHERE bucket_id = '$bucket' AND scope_id = '$scope_name' AND keyspace_id = '$collection_name' AND state = 'deferred'" | \
        jq -r '.results | join(", ")')

      echo "      Deferred indexes: $deferred_indexes"

      if [ -n "$deferred_indexes" ]; then
        N1QL="BUILD INDEX ON \`$bucket\`.\`$scope_name\`.\`$collection_name\` ($deferred_indexes)"
        echo "      Executing N1QL: $N1QL"

        response=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent --request POST \
          --data-urlencode "statement=$N1QL" "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service")

        status=$(echo "$response" | jq -r '.status')
        if [ "$status" == "success" ]; then
          echo "        Success: Indexes built successfully."
        else
          error_msg=$(echo "$response" | jq -r '.errors[0].msg // "Unknown error"')
          echo "        Error: $error_msg"
        fi
      else
        echo "      No deferred indexes to build in collection $collection_name."
      fi
    done
  done

  # Process other scopes
  echo "$scopes" | jq -c '.scopes[] | select(.name != "default")' | while read scope; do
    scope_name=$(echo "$scope" | jq -r '.name')
    echo "  Processing Scope: $scope_name"

    echo "$scope" | jq -c '.collections[]' | while read collection; do
      collection_name=$(echo "$collection" | jq -r '.name')
      echo "    Processing Collection: $collection_name"

      deferred_indexes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" \
        --data-urlencode "statement=SELECT RAW name FROM system:indexes WHERE bucket_id = '$bucket' AND scope_id = '$scope_name' AND keyspace_id = '$collection_name' AND state = 'deferred'" | \
        jq -r '.results | join(", ")')

      echo "      Deferred indexes: $deferred_indexes"

      if [ -n "$deferred_indexes" ]; then
        N1QL="BUILD INDEX ON \`$bucket\`.\`$scope_name\`.\`$collection_name\` ($deferred_indexes)"
        echo "      Executing N1QL: $N1QL"

        response=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent --request POST \
          --data-urlencode "statement=$N1QL" "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service")

        status=$(echo "$response" | jq -r '.status')
        if [ "$status" == "success" ]; then
          echo "        Success: Indexes built successfully."
        else
          error_msg=$(echo "$response" | jq -r '.errors[0].msg // "Unknown error"')
          echo "        Error: $error_msg"
        fi
      else
        echo "      No deferred indexes to build in collection $collection_name."
      fi
    done
  done
done

echo "All deferred indexes processed."

###############################################################################
# SCRIPT 2: Build Indexes Using couchbase-cli and cbq
# (Uses same variable naming as SCRIPT 1)
###############################################################################

CBQ="/opt/couchbase/bin/cbq"
CLI="/opt/couchbase/bin/couchbase-cli"

# Reuse existing variables: CB_USERNAME, CB_PASSWORD, CLUSTER, PORT

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is required but not installed. Please install it first."
    exit 1
fi

echo "Fetching all buckets..."
# Get only lines without leading spaces = bucket names
BUCKETS=$($CLI bucket-list -c "$CLUSTER:$PORT" -u "$CB_USERNAME" -p "$CB_PASSWORD" | grep -v "^[[:space:]]")

if [ -z "$BUCKETS" ]; then
    echo "No buckets found on cluster."
    exit 0
fi

# Loop through each bucket
for bucket in $BUCKETS; do
    echo "----------------------------------------------------"
    echo "Processing bucket: $bucket"

    # Get all indexes for this bucket
    INDEXES_JSON=$($CBQ -u "$CB_USERNAME" -p "$CB_PASSWORD" -q=true -s "SELECT name FROM system:indexes WHERE keyspace_id = '$bucket';")
    INDEX_NAMES=$(echo "$INDEXES_JSON" | jq -r '.results[].name')

    if [ -z "$INDEX_NAMES" ]; then
        echo "No indexes found for bucket '$bucket'. Skipping..."
        continue
    fi

    # Build comma-separated list of index names
    INDEX_LIST=$(printf "%s," $INDEX_NAMES | sed 's/,$//')

    BUILD_QUERY="BUILD INDEX ON \`$bucket\`($INDEX_LIST);"
    echo "Running: $BUILD_QUERY"

    $CBQ -u "$CB_USERNAME" -p "$CB_PASSWORD" -q=true -s "$BUILD_QUERY"

    echo "Indexes built successfully for bucket '$bucket'."
done

echo "----------------------------------------------------"
echo "✅ All indexes built successfully for all buckets."
