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
                    name = indexes.get('name') 
                    index_key = indexes.get('index_key')
                    condition = indexes.get('condition')
                    keyspace_id = indexes.get('keyspace_id')
                    scope_id = indexes.get('scope_id')
                    bucket_id = indexes.get('bucket_id')
                    
                    print ("NAME      :", name) 
                    print("Bucket ID  :", bucket_id)
                    print("Keyspace ID:", keyspace_id)
                    print("Scope ID   :", scope_id)
                    print("Index Key  :", index_key)
                    print("Condition  :", condition)
        except json.JSONDecodeError:
            continue

# Run the function on the given file
extract_index_details("plain1.txt")
