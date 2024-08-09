#!/bin/bash

# Start a new tmux session
SESSION_NAME="Juleana"
tmux new-session -d -s $SESSION_NAME -n 'Processing'

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

# Create a new window named "Monitoring" and split it into 2 panes horizontally
tmux new-window -t $SESSION_NAME -n 'Monitoring'
tmux split-window -v -t $SESSION_NAME:2

# Run monitoring commands in the "Monitoring" window panes
tmux send-keys -t $SESSION_NAME:2.0 'watch -n 30 "sinfo | grep idle"' C-m
tmux send-keys -t $SESSION_NAME:2.1 'watch -n 30 squeue -u $USER' C-m

# Attach to the session
tmux attach -t $SESSION_NAME