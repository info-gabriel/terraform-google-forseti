#!/bin/bash
# Copyright 2020 The Forseti Security Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source /home/ubuntu/forseti_env.sh


# set -x enables a mode of the shell where all executed commands are printed to the terminal.
# With this  enabled, we should not put anything private/secret in the commands called because
# they will be logged.
set -x

# Remove any CAI temp files generated by the forseti process.
# Failed inventory due to various reasons could cause the temp files not being deleted.
sudo rm -rf /tmp/forseti-cai-*

# Put the config files in place.
sudo gsutil cp gs://$SCANNER_BUCKET/configs/forseti_conf_server.yaml ${forseti_server_conf_path}
sudo gsutil cp -r gs://$SCANNER_BUCKET/rules $FORSETI_HOME/

# Download the Newest Config Validator constraints from GCS.
if [ "${policy_library_sync_enabled}" != "true" ]; then
  sudo gsutil -m rsync -d -r gs://$SCANNER_BUCKET/policy-library ${policy_library_home}/policy-library
fi

# Restart the config validator service to pick up the latest policy.
sudo systemctl restart config-validator

if [ ! -f "$FORSETI_SERVER_CONF" ]; then
    echo "Forseti conf not found, exiting."
    exit 1
fi

# Reload the server configuration settings
forseti server configuration reload

# Set the output format to json
forseti config format json

# Ensure we are not using stale model, and produce stale violations.
forseti config delete model

# Purge inventory.
# Use retention_days from configuration yaml file.
forseti inventory purge

# Run inventory command
MODEL_NAME=$(/bin/date -u +%Y%m%dT%H%M%S)
echo "Running Forseti inventory."
forseti inventory create --import_as $MODEL_NAME
echo "Finished running Forseti inventory."

GET_MODEL_STATUS="forseti model get $MODEL_NAME | python -c \"import sys, json; print json.load(sys.stdin)['status']\""
MODEL_STATUS=`eval $GET_MODEL_STATUS`

if ([ "$MODEL_STATUS" != "SUCCESS" ] && [ "$MODEL_STATUS" != "PARTIAL_SUCCESS" ])
    then
        echo "Newly created Model is not in SUCCESS or PARTIAL_SUCCESS state."
        echo "Please contact discuss@forsetisecurity.org for support."
        exit
fi

# Run model command
echo "Using model $MODEL_NAME to run scanner"
forseti model use $MODEL_NAME
# Sometimes there's a lag between when the model
# successfully saves to the database.
sleep 5s

echo "Forseti config: $(forseti config show)"

# Run scanner command
echo "Running Forseti scanner."
SCANNER_COMMAND=`forseti scanner run`
SCANNER_INDEX_ID=`echo $SCANNER_COMMAND | grep -o -P '(?<=(ID: )).*(?=is created)'`
echo "Finished running Forseti scanner."

# Run notifier command
echo "Running Forseti notifier."
forseti notifier run --scanner_index_id $SCANNER_INDEX_ID
echo "Finished running Forseti notifier."

# Clean up the model tables
echo "Cleaning up model tables"
forseti model delete $MODEL_NAME

