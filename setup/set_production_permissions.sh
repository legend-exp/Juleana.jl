#!/usr/bin/env bash

# Check if a command-line argument for BASE_PATH is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <base_path>"
  echo "Error: You must provide the base path as a command-line argument."
  exit 1
fi

# Define the base path from the first command line argument
BASE_PATH="$1"

# Check if the provided base path exists and is a directory
if [ ! -d "$BASE_PATH" ]; then
  echo "Error: Base path '$BASE_PATH' does not exist or is not a directory."
  exit 1
fi

echo "Base path set to: $BASE_PATH"
echo "Starting permission changes for folders starting with 'jl-v' within this path..."
echo "-------------------------------------"

# Variable to track if any matching directories were found
found_matching_dirs=false

# Loop through all directories in BASE_PATH that start with 'jl-v'
# The trailing slash in "jl-v*/" ensures we only match directories
for dir in "$BASE_PATH"/jl-v*/; do
  # Check if the glob found any matching directories
  # If no matches, 'dir' will literally be the glob pattern itself
  if [ -d "$dir" ]; then
    found_matching_dirs=true
    # Remove trailing slash for cleaner output
    actual_dir_path="${dir%/}"
    echo "Processing directory: $actual_dir_path"

    # Set permissions for sub-directories to 755 (rwxr-xr-x)
    echo "  Setting directory permissions to 755 (rwxr-xr-x)..."
    find "$actual_dir_path" -type d -exec chmod 755 {} \;
    if [ $? -ne 0 ]; then
      echo "  Error setting directory permissions in $actual_dir_path"
    else
      echo "  Directory permissions set."
    fi

    # Set permissions for files to 644 (rw-r--r--)
    echo "  Setting file permissions to 644 (rw-r--r--)..."
    find "$actual_dir_path" -type f -exec chmod 644 {} \;
    if [ $? -ne 0 ]; then
      echo "  Error setting file permissions in $actual_dir_path"
    else
      echo "  File permissions set."
    fi
    echo "-------------------------------------"
  fi # End of if [ -d "$dir" ]
done # End of for loop

# Check if any matching directories were processed
if [ "$found_matching_dirs" = false ]; then
  echo "No directories found matching '$BASE_PATH/jl-v*/'"
fi

echo "Permission changes script finished."
