#!/usr/bin/env bash

CB_USERNAME=${CB_USERNAME:='Admin'}
CB_PASSWORD=${CB_PASSWORD:='redhat'}
CLUSTER=${CLUSTER:='localhost'}
PORT=${PORT:='8091'}
PROTOCOL=${PROTOCOL:='http'}
QUERY_NODE=${QUERY_NODE:='127.0.0.1'}
QUERY_PORT=${QUERY_PORT:='8093'}
BUCKET=""   # Optional bucket argument

while [ $# -gt 0 ]; do
  case "$1" in
    --username=*) CB_USERNAME="${1#*=}" ;;
    --password=*) CB_PASSWORD="${1#*=}" ;;
    --cluster=*) CLUSTER="${1#*=}" ;;
    --port=*) PORT="${1#*=}" ;;
    --protocol=*) PROTOCOL="${1#*=}" ;;
    --query-node=*) QUERY_NODE="${1#*=}" ;;
    --query-port=*) QUERY_PORT="${1#*=}" ;;
    --bucket=*) BUCKET="${1#*=}" ;;   # NEW bucket option
    *) printf "* Error: Invalid argument.\n"; exit 1 ;;
  esac
  shift
done

if [ "$(command -v jq)" = "" ]; then
  echo >&2 "jq command is required, see (https://stedolan.github.io/jq/download)";
  exit 1;
fi

# Find a query node in the cluster to use if not specified
if [[ -z "$QUERY_NODE" ]]; then
  QUERY_NODE=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$CLUSTER:$PORT/pools/nodes" | \
    jq -r '.nodes[] | select(.services | contains(["n1ql"])) | .hostname' | head -n 1)

  # Convert IPv6 localhost format "[::1]:8091" to "localhost" without port, otherwise keep as is
  if [[ "$QUERY_NODE" == "[::1]:8091" ]]; then
    QUERY_NODE="localhost"
  else
    # Strip the port from other formats if necessary, leaving only the hostname/IP
    QUERY_NODE=$(echo "$QUERY_NODE" | sed 's/:.*//')
  fi
fi

# Get all buckets (or only the given one)
if [ -n "$BUCKET" ]; then
  buckets="$BUCKET"
else
  buckets=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$CLUSTER:$PORT/pools/default/buckets" | jq -r '.[].name')
fi

# Loop through each bucket
for bucket in $buckets; do
  echo "Processing Bucket: $bucket"

  # Get all scopes and collections in the bucket, including the default scope
  scopes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$CLUSTER:$PORT/pools/default/buckets/$bucket/scopes")

  # Always process the default scope first, if it exists
  echo "$scopes" | jq -c '.scopes[] | select(.name == "default")' | while read scope; do
    scope_name=$(echo "$scope" | jq -r '.name')
    echo "  Processing Scope: $scope_name"

    # Loop through each collection in the default scope
    echo "$scope" | jq -c '.collections[]' | while read collection; do
      collection_name=$(echo "$collection" | jq -r '.name')
      echo "    Processing Collection: $collection_name"

      # Get deferred indexes for the collection
      deferred_indexes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" \
        --data-urlencode "statement=SELECT RAW name FROM system:indexes WHERE bucket_id = '$bucket' AND scope_id = '$scope_name' AND keyspace_id = '$collection_name' AND state = 'deferred'" | \
        jq -r '.results | join(", ")')

      echo "      Deferred indexes: $deferred_indexes"

      if [ -n "$deferred_indexes" ]; then
        # If there are deferred indexes, build them
        N1QL="BUILD INDEX ON \`$bucket\`.\`$scope_name\`.\`$collection_name\` ($deferred_indexes)"
        echo "      Executing N1QL: $N1QL"

        # Execute the BUILD INDEX command
        response=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent --request POST \
          --data-urlencode "statement=$N1QL" "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service")

        # Parse and print the response
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

  # Process other scopes in the bucket
  echo "$scopes" | jq -c '.scopes[] | select(.name != "default")' | while read scope; do
    scope_name=$(echo "$scope" | jq -r '.name')
    echo "  Processing Scope: $scope_name"

    # Loop through each collection in the scope
    echo "$scope" | jq -c '.collections[]' | while read collection; do
      collection_name=$(echo "$collection" | jq -r '.name')
      echo "    Processing Collection: $collection_name"

      # Get deferred indexes for the collection
      deferred_indexes=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service" \
        --data-urlencode "statement=SELECT RAW name FROM system:indexes WHERE bucket_id = '$bucket' AND scope_id = '$scope_name' AND keyspace_id = '$collection_name' AND state = 'deferred'" | \
        jq -r '.results | join(", ")')

      echo "      Deferred indexes: $deferred_indexes"

      if [ -n "$deferred_indexes" ]; then
        # If there are deferred indexes, build them
        N1QL="BUILD INDEX ON \`$bucket\`.\`$scope_name\`.\`$collection_name\` ($deferred_indexes)"
        echo "      Executing N1QL: $N1QL"

        # Execute the BUILD INDEX command
        response=$(curl --user "$CB_USERNAME:$CB_PASSWORD" --silent --request POST \
          --data-urlencode "statement=$N1QL" "$PROTOCOL://$QUERY_NODE:$QUERY_PORT/query/service")

        # Parse and print the response
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
