#!/bin/bash

DEFAULT_SESSION_NAME="Juleana"

# Ask if the default session name should be used
read -p "Do you want to use the default session name '$DEFAULT_SESSION_NAME'? [Y/n] Hit enter: " use_default_session_name
use_default_session_name=${use_default_session_name:-Y}

if [[ "$use_default_session_name" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    SESSION_NAME=$DEFAULT_SESSION_NAME
else
    read -p "Enter the new session name (single word) or hit enter to use the default: " new_session_name
    if [[ -z "$new_session_name" ]]; then
        SESSION_NAME=$DEFAULT_SESSION_NAME
    elif [[ "$new_session_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        SESSION_NAME=$new_session_name
    else
        echo "Invalid session name. Using default session name '$DEFAULT_SESSION_NAME'."
        SESSION_NAME=$DEFAULT_SESSION_NAME
    fi
fi

# Check if the session already exists
if tmux has-session -t $SESSION_NAME 2>/dev/null; then
    read -p "Session '$SESSION_NAME' already exists. Do you want to delete it and create a new one? [Y/n] Hit enter: " delete_session
    delete_session=${delete_session:-Y}
    
    if [[ "$delete_session" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
        tmux kill-session -t $SESSION_NAME 2>/dev/null
        echo "Session '$SESSION_NAME' deleted."
        tmux start-server
    else
        echo "Exiting script."
        exit 0
    fi
fi

# Start a new tmux session
tmux new-session -d -s $SESSION_NAME -n 'Processing'

# Change directory to the parent directory of where the script is located
PARENT_DIR=$(dirname "$(readlink -f "$0")")/..

# Function to send the cd command to all panes in a window
send_cd_command_to_all_panes() {
    local window_index=$1
    local pane_count=$(tmux list-panes -t $SESSION_NAME:$window_index -F "#{pane_index}" | wc -l)
    for ((pane_index=0; pane_index<pane_count; pane_index++)); do
        tmux send-keys -t $SESSION_NAME:$window_index.$pane_index "cd $PARENT_DIR" C-m
    done
}

# Send the cd command to the first window
send_cd_command_to_all_panes 0

# Enable mouse mode
tmux set-option -t $SESSION_NAME mouse on

# Since the first window is already created and named "Processing" upon session creation,
# we proceed to create the additional windows.

# Create a new window named "Slurm" and split it into 4 panes
tmux new-window -t $SESSION_NAME -n 'Slurm'
tmux split-window -h -t $SESSION_NAME:1
tmux split-window -v -t $SESSION_NAME:1.1
tmux select-pane -t $SESSION_NAME:1.0
tmux split-window -v -t $SESSION_NAME:1.0

# Send the cd command to the second window
send_cd_command_to_all_panes 1

# Create a new window named "Monitoring" and split it into 2 panes horizontally
tmux new-window -t $SESSION_NAME -n 'Monitoring'
tmux split-window -v -t $SESSION_NAME:2

# Send the cd command to the third window
send_cd_command_to_all_panes 2

# Run monitoring commands in the "Monitoring" window panes
tmux send-keys -t $SESSION_NAME:2.0 'watch -n 30 "sinfo | grep idle"' C-m
tmux send-keys -t $SESSION_NAME:2.1 'watch -n 30 squeue -u $USER' C-m

# Attach to the first window in the session
tmux select-window -t $SESSION_NAME:0
tmux attach -t $SESSION_NAME