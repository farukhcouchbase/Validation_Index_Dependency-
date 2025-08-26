#!/bin/bash

# Run cbq command and overwrite fields.txt with the new output
#/opt/couchbase/bin/cbq -u Admin -p redhat -s "SELECT * FROM system:indexes;" > fields.json 2>&1
tail -n +6 fields.json > new_fields.json
jq -r '.[] | @text' new_fields.json > plain1.txt


#sudo apt update && sudo apt install python3 -y > output.log 2>&1 &
python3 extract2.py > fields1.txt
python3 string.py > fields2.tx
