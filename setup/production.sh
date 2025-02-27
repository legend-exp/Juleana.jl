#!/bin/bash
if [ -f /etc/bash_completion ]; then 
    . /etc/bash_completion 
fi

# Juleana production environment creator

echo "#############################################"
echo "Welcome to the Juleana production environment creator"
echo "This script will help you set up a new production environment."
echo "#############################################"
echo -e "\n\n\n"

# Ask for the production name and validate it
while true; do
    echo "#############################################"
    read -p "Please enter the production name (single string, no spaces): " production_name
    if [[ "$production_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        break
    else
        echo "The production name '$production_name' is not valid. Please enter a single string with no spaces."
    fi
    echo "#############################################"
    echo -e "\n\n\n"
done

default_production_path="${LEGEND_DATA_CONFIG:+$(dirname "$(dirname "$LEGEND_DATA_CONFIG")")}"

# Ask for the production path and validate it
while true; do
    echo "#############################################"
    read -e -p "Please enter the production path: " -i "$default_production_path" production_path
    if [[ "$production_path" =~ ^/ ]]; then
        break
    else
        echo "The path '$production_path' is not a valid path string. Please try again."
    fi
    echo "#############################################"
    echo -e "\n\n\n"
done

# Create the full path
full_path="$production_path/$production_name"
echo "#############################################"
echo "The full production path is: $full_path"
echo "#############################################"
echo -e "\n\n\n"

# Check if the directory exists
if [ -d "$full_path" ]; then
    echo "#############################################"
    read -p "Directory $full_path already exists. Do you want to remove it and create a new one? [Y/n] Hit enter: " remove_dir
    remove_dir=${remove_dir:-Y}

    if [[ "$remove_dir" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
        echo ""
        echo ""
        echo "ATTENTION: This will delete all data in $full_path!"
        echo ""
        echo ""
        read -p "Are you sure you want to delete $full_path? [Y/n] Hit enter: " confirm_delete
        confirm_delete=${confirm_delete:-Y}

        if [[ "$confirm_delete" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
            rm -rf "$full_path"
            echo "Directory $full_path deleted."
            mkdir -p "$full_path"
            echo "Directory $full_path created."
        else
            echo "Deletion cancelled. Exiting script."
            exit 1
        fi
    else
        echo "Directory removal cancelled. Exiting script."
        exit 1
    fi
    echo "#############################################"
    echo -e "\n\n\n"
else
    mkdir -p "$full_path"
    echo "#############################################"
    echo "Directory $full_path created."
    echo "#############################################"
    echo -e "\n\n\n"
fi

# Clone the repository into full_path/legend-metadata
echo "#############################################"
echo "Cloning legend-metadata into $full_path/legend-metadata..."
git clone --recursive git@github.com:legend-exp/legend-metadata "$full_path/legend-metadata"
echo "#############################################"
echo -e "\n\n\n"

# Ask if the user wants to check out all main branches of all metadata submodules
echo "#############################################"
read -p "Do you want to check out specific metadata branches? [Y/n] Hit enter: " checkout_submodules
checkout_submodules=${checkout_submodules:-Y}

if [[ "$checkout_submodules" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    default_branch="main"
    read -e -p "Please enter the 'jldataprod' branches to check out (default is 'main'): " -i "$default_branch" branch
    branch=${branch:-main}
    echo "Checking out $branch branches for all 'jldataprod' metadata submodules..."
    cd "$full_path/legend-metadata"
    
    # Checkout branches for submodules under jldataprod/config and jldataprod/overrides
    git submodule foreach --recursive '
        if [[ "$name" == jldataprod/config* || "$name" == jldataprod/overrides* ]]; then
            git checkout '"$branch"' && git pull origin '"$branch"'
        fi
    '
    read -e -p "Please enter the 'dataprod' branches to check out (default is 'main'): " -i "$default_branch" branch
    branch=${branch:-main}
    echo "Checking out $branch branches for all 'dataprod' metadata submodules..."

    # Checkout branches for all other submodules
    git submodule foreach --recursive '
        if [[ "$name" != jldataprod/config* && "$name" != jldataprod/overrides* && "$name" != simprod/config* ]]; then
            git checkout '"$branch"' && git pull origin '"$branch"'
        fi
    '
else
    echo "Skipping checkout of branches for metadata submodules."
fi
echo "#############################################"
echo -e "\n\n\n"

# Create the required directories
mkdir -p "$full_path/generated/tier"
mkdir -p "$full_path/generated/jllog"
mkdir -p "$full_path/generated/jlplt"
mkdir -p "$full_path/generated/jlreport"
mkdir -p "$full_path/generated/jlpar"
mkdir -p "$full_path/generated/jlpar/rpars"
mkdir -p "$full_path/generated/jlpar/ppars"

echo "#############################################"
echo "Required directories created."
echo "#############################################"
echo -e "\n\n\n"

# Create the config.json file with the specified content
config_file="$full_path/config.json"
cat <<EOL > "$config_file"
{
    "setups": {
        "l200": {
            "paths": {
                "metadata": "\$_/legend-metadata/",

                "tier": "\$_/generated/tier/",
                "tier/jllog": "\$_/generated/jllog/",
                "tier/jlreport": "\$_/generated/jlreport/",
                "tier/jlplt": "\$_/generated/jlplt/",

                "par": "\$_/generated/jlpar/"
            }
        }
    }
}
EOL

echo "#############################################"
echo "config.json file created at $config_file"
echo "#############################################"
echo -e "\n\n\n"

# Function to add a path to the config.json file
add_path_to_config() {
    local path_label=$1
    local path_key=$2
    local previous_path=$3

    while true; do
        echo "#############################################"
        read -e -p "Please enter the alternative path for $path_label: " -i "$previous_path" path
        previous_path="$path"
        if [ -d "$path" ]; then
            echo "Alternative path for $path_label exists: $path"
            # Replace the dirname of the config.json path with $_/ if it is contained in the path
            modified_path=$(echo "$path" | sed "s|$(dirname "$(dirname "$config_file")")|\$_/..|")
            # Insert the alternative path into the config.json file
            sed -i "/\"$path_key\": \"\$_\/generated\/$path_key\/\",/a \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \"$path_label\": \"$modified_path\"," "$config_file"
            echo "Alternative path for $path_label added to config.json"
            break
        else
            echo "The path '$path' does not exist. Please enter a valid path or type 'skip' to skip this step."
            read -e -p "Enter a valid alternative path for $path_label or type 'skip': " -i "$previous_path" path
            if [[ "$path" == "skip" ]]; then
                echo "Skipping the addition of an alternative path for $path_label."
                break
            fi
        fi
        echo "#############################################"
        echo -e "\n\n\n"
    done
}

# Ask for alternative tier paths
previous_alternative_path="$default_production_path"
while true; do
    echo "#############################################"
    read -e -p "Please enter the label for the alternative tier path (single string, no spaces) or type 'done' to finish: " label
    if [[ "$label" == "done" ]]; then
        echo "Finished adding alternative tier paths."
        break
    elif [[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        add_path_to_config "tier/$label" "tier" "$previous_alternative_path"
        previous_alternative_path=$(echo "$(grep "\"tier/$label\"" "$config_file" | sed -n 's/.*: "\(.*\)".*/\1/p')" | sed "s|\$_/..|$(dirname "$(dirname "$config_file")")|")
    else
        echo "The label '$label' is not valid. Please enter a single string with no spaces."
    fi
    echo "#############################################"
    echo -e "\n\n\n"
done

# Function to copy additional pars
previous_additional_pars_path="$default_production_path"
copy_additional_pars() {
    while true; do
        echo "#############################################"
        read -e -p "Please enter the path to additional pars or type 'done' to finish: " -i "$previous_additional_pars_path" pars_path
        if [[ "$pars_path" == "done" ]]; then
            echo "Finished adding additional pars."
            break
        elif [ -d "$pars_path" ]; then
            if [[ "$pars_path" == *"/rpars"* || "$pars_path" == *"/ppars"* ]]; then
                pars_subpath=$(echo "$pars_path" | sed -n 's/.*\(\/rpars.*\|\/ppars.*\)/\1/p')
                if [ -n "$pars_subpath" ]; then
                    destination="$full_path/generated/jlpar$pars_subpath"
                    mkdir -p "$destination"
                    cp -r "$pars_path"/* "$destination"
                    echo "Copied $pars_path to $destination"
                    previous_additional_pars_path="$pars_path"
                else
                    echo "Error extracting pars subpath. Please try again."
                fi
            else
                echo "The path does not contain 'rpars' or 'ppars'. Please enter a valid path."
            fi
        else
            echo "The path '$pars_path' does not exist. Please enter a valid path."
        fi
        echo "#############################################"
        echo -e "\n\n\n"
    done
}

# Ask if the user wants to copy additional pars
echo "#############################################"
read -p "Do you want to copy additional pars? [Y/n] Hit enter: " copy_pars
copy_pars=${copy_pars:-Y}

if [[ "$copy_pars" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    copy_additional_pars
else
    echo "No additional pars copied."
fi
echo "#############################################"
echo -e "\n\n\n"

# Ask if the user wants to set the new production as user default
echo "#############################################"
read -p "Do you want to set the new production as user default? [Y/n] Hit enter: " set_default
set_default=${set_default:-Y}

if [[ "$set_default" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    # Determine the default shell
    default_shell=$(basename "$SHELL")
    rc_file=""

    case "$default_shell" in
        bash)
            rc_file="$HOME/.bashrc"
            ;;
        zsh)
            rc_file="$HOME/.zshrc"
            ;;
        *)
            echo "Unsupported shell: $default_shell. Please update your shell configuration file manually."
            exit 1
            ;;
    esac

    # Update the rc file
    if grep -q "export LEGEND_DATA_CONFIG=" "$rc_file"; then
        sed -i "s|export LEGEND_DATA_CONFIG=.*|export LEGEND_DATA_CONFIG=$full_path/config.json|" "$rc_file"
        echo "Updated LEGEND_DATA_CONFIG in $rc_file"
    else
        echo "export LEGEND_DATA_CONFIG=$full_path/config.json" >> "$rc_file"
        echo "Added LEGEND_DATA_CONFIG to $rc_file"
    fi

    # Source the rc file to apply changes
    source "$rc_file"
    echo "Sourced $rc_file to apply changes"
else
    echo "Default production setting skipped."
fi
echo "#############################################"
echo -e "\n\n\n"

# Ask if the dataflow should be cloned
echo "#############################################"
read -p "Do you want to clone the dataflow too? [Y/n] Hit enter: " clone_dataflow
clone_dataflow=${clone_dataflow:-Y}

if [[ "$clone_dataflow" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    echo "Cloning dataflow..."
    # Define the dataflow repository URL
    dataflow_repo_url="git@github.com:legend-exp/legend-julia-dataflow.git"
    
    # Define the destination path for the dataflow repository
    dataflow_dest_path="$full_path/legend-julia-dataflow"
    
    # Clone the dataflow repository
    git clone "$dataflow_repo_url" "$dataflow_dest_path"
    
    echo "Dataflow cloned into $dataflow_dest_path"
    
    # Ask if the user wants to precompile the dataflow production environment
    read -p "Do you want to precompile the dataflow production environment? [Y/n] Hit enter: " precompile_dataflow
    precompile_dataflow=${precompile_dataflow:-Y}
    
    if [[ "$precompile_dataflow" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
        echo "Precompiling dataflow production environment..."
        julia -e "import Pkg; Pkg.activate(\"$dataflow_dest_path\"); Pkg.precompile()"
        echo "Dataflow production environment precompiled."
    else
        echo "Precompilation skipped."
    fi
else
    echo "Dataflow cloning skipped."
fi
echo "#############################################"
echo -e "\n\n\n"