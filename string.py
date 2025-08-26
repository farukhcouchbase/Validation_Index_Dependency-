#!/bin/bash

# Run cbq command and overwrite fields.txt with the new output
#/opt/couchbase/bin/cbq -u Admin -p redhat -s "SELECT * FROM system:indexes;" > fields.json 2>&1
tail -n +6 fields.json > new_fields.json
jq -r '.[] | @text' new_fields.json > plain1.txt


#sudo apt update && sudo apt install python3 -y > output.log 2>&1 &
python3 extract2.py > fields1.txt
python3 string.py > fields2.txt
ubuntu@ip-172-31-25-65:~$ cat string.py 
import json
import re

def extract_index_details(filename):
    with open(filename, 'r') as file:
        content = file.read()
    
    # Extract JSON-like structure using regex
    matches = re.findall(r'\[\{.*?\}\]', content, re.DOTALL)

    for match in matches:
        try:
            data = json.loads(match)
            for obj in data:
                if 'indexes' in obj:
                    indexes = obj['indexes']
                    index_key = indexes.get('index_key')
                    condition = indexes.get('condition')
                    keyspace_id = indexes.get('keyspace_id')
                    scope_id = indexes.get('scope_id')
                    bucket_id = indexes.get('bucket_id')

                    # Construct the desired string format
                    if index_key and condition and keyspace_id and scope_id and bucket_id:
                        # Check if index_key is a list
                        if isinstance(index_key, list):
                            fields = ', '.join([f'`{field.strip()}`' for field in index_key])
                        else:
                            # If it's not a list, handle it as a string (in case it's still a string)
                            fields = ', '.join([f'`{field.strip()}`' for field in index_key.split(',')])

                        # Formatting the condition (assuming it's a valid SQL-like condition)
                        formatted_condition = condition.replace('=', ' =')

                        # Constructing the final string
                        result_string = f"`{bucket_id}`.`{scope_id}`.`{keyspace_id}`({fields}) WHERE {formatted_condition}"

                        # Printing the formatted string
                        print(result_string)
        except json.JSONDecodeError:
            continue

# Run the function on the given file
extract_index_details("plain1.txt")
