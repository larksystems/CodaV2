import json
import csv

messages_file = "/Users/mariana/Development/TEMP_IFRC_Coda/messages_to_label.csv"
coda_export = "/Users/mariana/Development/TEMP_IFRC_Coda/backup_for_export.json"

with open(messages_file) as f:
  csv_reader = csv.reader(f)
  messages = []

  for row in csv_reader:
    messages.append(row[0].strip())

with open(coda_export) as f:
  backup = json.load(f)
  backup_messages = backup["segments"]["ifrc_community_newdata_jul"]["messages"]
  backup_messages_map = {}
  for message in backup_messages:
    backup_messages_map[message["Text"].strip()] = message

  schemes = backup["segments"]["ifrc_community_newdata_jul"]["schemes"]
  schemes_map = {}
  for scheme in schemes:
    codes = scheme["Codes"]
    codes_map = {}
    for code in codes:
      codes_map[code["CodeID"]] = code
    schemes_map[scheme["SchemeID"]] = codes_map

FEEDBACK_SCHEME = "Scheme-0feedback"
CATEGORY_SCHEME = "Scheme-1category"
CODE_SCHEME = "Scheme-2code"

for message in messages:
  if message not in backup_messages_map.keys():
    print(f"{message}\t-\t-\t-")
    continue

  feedback_code = None
  category_code = None
  code_code = None
  labels = backup_messages_map[message]["Labels"]
  labels.reverse()
  for label in labels:
    code_id = label["CodeID"]
    if code_id == "SPECIAL-MANUALLY_UNCODED":
      continue
    code = schemes_map[label["SchemeID"]][code_id]["DisplayText"]
    if label["SchemeID"] == FEEDBACK_SCHEME:
      feedback_code = code
    if label["SchemeID"] == CATEGORY_SCHEME:
      category_code = code
    if label["SchemeID"] == CODE_SCHEME:
      code_code = code

  print(f"{message}\t{feedback_code}\t{category_code}\t{code_code}")
