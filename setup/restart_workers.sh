#!/usr/bin/env bash

counter=0
max_retries=100

while [ $counter -lt $max_retries ]; do
    # Check if a process with 'julia * main.jl' exists
    if pgrep -f "julia .* main.jl" > /dev/null; then
        echo "Starting the script... Attempt #$((counter + 1))"
        
        # Simulate your script's main work
        ./startjlworkers.sh
        
        counter=$((counter + 1))
        echo "Script terminated. Restarting in 5 seconds... ($counter/$max_retries)"
        sleep 5
    else
        echo "No 'julia * main.jl' process found. Exiting."
        break
    fi
done

echo "Reached maximum retries ($max_retries) or 'julia * main.jl' process not found. Exiting."