#!/bin/bash

# ========================================================================
# == Functions
# ========================================================================

compose_with_options() {
    local base_dir="$PWD"
    local compose_files=("compose.yml")  # Always include the base compose file
    local options=("${default_options[@]}")

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir=*)
                base_dir="${1#*=}"
                shift
                ;;
            *)
                options+=("$1")
                shift
                ;;
        esac
    done

    # Check for NVIDIA GPU and drivers
    local has_nvidia=false
    if command -v nvidia-smi &> /dev/null && docker info | grep -q "Runtimes:.*nvidia"; then
        has_nvidia=true
    fi

    # Loop through compose files in the directory
    for file in "$base_dir"/compose.*.yml; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            local match=false
            local is_nvidia_file=false

            # Check if file matches any of the options
            for option in "${options[@]}"; do
                if [[ $option == "*" ]]; then
                    match=true
                    break
                fi

                if [[ $filename == *"$option"* ]]; then
                    match=true
                    break
                fi
            done

            # Check if it's an NVIDIA file
            if [[ $filename == *".nvidia."* ]]; then
                is_nvidia_file=true
            fi

            # Include the file if:
            # 1. It matches an option and is not an NVIDIA file
            # 2. It matches an option, is an NVIDIA file, and NVIDIA is supported
            if $match && (! $is_nvidia_file || ($is_nvidia_file && $has_nvidia)); then
                compose_files+=("$file")
            fi
        fi
    done

    # Prepare docker compose command
    local cmd="docker compose"
    for file in "${compose_files[@]}"; do
        cmd+=" -f $file"
    done

    # Return the command string
    echo "$cmd"
}

show_version() {
    echo "Harbor CLI version: $version"
}

show_help() {
    show_version
    echo "Usage: $0 <command> [options]"
    echo
    echo "Compose Setup Commands:"
    echo "  up            - Start the containers"
    echo "  down          - Stop and remove the containers"
    echo "  ps            - List the running containers"
    echo "  logs          - View the logs of the containers"
    echo "  exec          - Execute a command in a running service"
    echo
    echo "Setup Management Commands:"
    echo "  ollama        - Run the Harbor's Ollama CLI. Ollama service should be running"
    echo "  smi           - Show NVIDIA GPU information"
    echo "  top           - Run nvtop to monitor GPU usage"
    echo "  llamacpp      - Configure llamacpp service"
    echo
    echo "Huggingface CLI:"
    echo "  hf            - Run the Harbor's Huggingface CLI. Expanded with a few additional commands."
    echo "  hf parse-url  - Parse file URL from Hugging Face"
    echo
    echo "Harbor CLI Commands:"
    echo "  open          - Open a service in the default browser"
    echo "  url           - Get the URL for a service"
    echo "  config        - Manage the Harbor environment configuration"
    echo "  ln            - Create a symbolic link to the CLI"
    echo "  eject         - Eject the Compose configuration, accepts same options as 'up'"
    echo "  defaults      - Show the default services"
    echo "  help          - Show this help message"
    echo "  version       - Show the CLI version"
    echo "  gum           - Run the Gum terminal commands"
    echo
    echo "Options:"
    echo "  Additional options to pass to the compose_with_options function"
}

run_hf_cli() {
    case "$1" in
        parse-url)
            shift
            parse_hf_url $@
            return
            ;;
    esac

    local hf_cli_image=shaowenchen/huggingface-cli
    docker run --rm --log-driver none -v ~/.cache/huggingface:/root/.cache/huggingface $hf_cli_image $@
}

run_gum() {
    local gum_image=ghcr.io/charmbracelet/gum
    docker run --rm -it -e "TERM=xterm-256color" $gum_image $@
}

show_default_services() {
    echo "Default services:"
    for service in "${default_options[@]}"; do
        echo "  - $service"
    done
}

link_cli() {
    local target_dir="$HOME/.local/bin"
    local script_path="$harbor_home/harbor.sh"

    # Check if target directory exists in PATH
    if ! echo $PATH | tr ':' '\n' | grep -q "$target_dir"; then
        echo "Creating $target_dir and adding it to PATH..."
        mkdir -p "$target_dir"
        echo -e '\nexport PATH="$PATH:$HOME/.local/bin"\n' >> "$HOME/.bashrc"
        export PATH="$PATH:$HOME/.local/bin"
    fi

    # Create symlink
    if ln -s "$script_path" "$target_dir/$script_name"; then
        echo "Symlink created: $target_dir/$script_name -> $script_path"
        echo "You may need to reload your shell or run 'source ~/.bashrc' for changes to take effect."
    else
        echo "Failed to create symlink. Please check permissions and try again."
        return 1
    fi
}

get_service_url() {
    # Get list of running services
    services=$(docker ps --format "{{.Names}}")

    # Check if any services are running
    if [ -z "$services" ]; then
        echo "No services are currently running."
        return 1
    fi

    # If no service name provided, default to webui
    if [ -z "$1" ]; then
        get_service_url "$default_open"
        return 0
    fi

    # Check if the specified service is running
    if ! echo "$services" | grep -q "^$1$"; then
        echo "Service '$1' is not currently running."
        echo "Available services:"
        echo "$services"
        return 1
    fi

    # Get the port mapping for the service
    port=$(docker port "$1" | grep -oP '0.0.0.0:\K\d+' | head -n 1)

    if [ -z "$port" ]; then
        echo "No port mapping found for service '$1'."
        return 1
    fi

    # Construct the URL
    url="http://localhost:$port"

    echo "$url"
}

open_service() {
    url=$(get_service_url "$1")

    # Open the URL in the default browser
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url"  # Linux
    elif command -v open &> /dev/null; then
        open "$url"  # macOS
    elif command -v start &> /dev/null; then
        start "$url"  # Windows
    else
        echo "Unable to open browser. Please visit $url manually."
        return 1
    fi

    echo "Opened $url in your default browser."
}

smi() {
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi
    else
        echo "nvidia-smi not found."
    fi
}

nvidia_top() {
    if command -v nvtop &> /dev/null; then
        nvtop
    else
        echo "nvtop not found."
    fi
}

eject() {
    $(compose_with_options "$@") config
}

run_in_service() {
    local service_name="$1"
    shift
    local command_to_run="$@"

    if docker compose ps --services --filter "status=running" | grep -q "^${service_name}$"; then
        echo "Service ${service_name} is running. Executing command..."
        docker compose exec ${service_name} ${command_to_run}
    else
        echo "Harbor ${service_name} is not running. Please start it with 'harbor up ${service_name}' first."
    fi
}

exec_ollama() {
    run_in_service ollama ollama "$@"
}

env_manager() {
    local env_file=".env"
    local prefix="HARBOR_"

    transform_llamacpp_model() {
        local url="$1"
        local repo=$(echo "$url" | sed -n 's|https://huggingface.co/\(.*\)/blob/.*|\1|p')
        local file=$(basename "$url")
        echo "--hf-repo $repo --hf-file $file"
    }

    case "$1" in
        get)
            if [[ -z "$2" ]]; then
                echo "Usage: env_manager get <key>"
                return 1
            fi
            local upper_key=$(echo "$2" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
            value=$(grep "^$prefix$upper_key=" "$env_file" | cut -d '=' -f2-)
            value="${value#\"}"  # Remove leading quote if present
            value="${value%\"}"  # Remove trailing quote if present
            echo "$value"
            ;;
        set)
            if [[ -z "$2" ]]; then
                echo "Usage: env_manager set <key> <value>"
                return 1
            fi

            local upper_key=$(echo "$2" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
            shift 2  # Remove 'set' and the key from the arguments
            local value="$*"  # Capture all remaining arguments as the value

            if [[ "$upper_key" == "LLAMACPP_MODEL" ]]; then
                local transformed_value=$(transform_llamacpp_model "$value")
                if grep -q "^${prefix}LLAMACPP_MODEL_SPECIFIER=" "$env_file"; then
                    sed -i "s|^${prefix}LLAMACPP_MODEL_SPECIFIER=.*|${prefix}LLAMACPP_MODEL_SPECIFIER=\"$transformed_value\"|" "$env_file"
                else
                    echo "${prefix}LLAMACPP_MODEL_SPECIFIER=\"$transformed_value\"" >> "$env_file"
                fi
                echo "Set ${prefix}LLAMACPP_MODEL_SPECIFIER to: \"$transformed_value\""
            fi

            if grep -q "^$prefix$upper_key=" "$env_file"; then
                sed -i "s|^$prefix$upper_key=.*|$prefix$upper_key=\"$value\"|" "$env_file"
            else
                echo "$prefix$upper_key=\"$value\"" >> "$env_file"
            fi
            echo "Set $prefix$upper_key to: \"$value\""
            ;;
        list)
            grep "^$prefix" "$env_file" | sed "s/^$prefix//" | while read -r line; do
                key=${line%%=*}
                value=${line#*=}
                value=$(echo "$value" | sed -E 's/^"(.*)"$/\1/')  # Remove surrounding quotes for display
                printf "%-30s %s\n" "$key" "$value"
            done
            ;;
        *)
            echo "Usage: harbor config {get|set|list} [key] [value]"
            return 1
            ;;
    esac
}

parse_hf_url() {
    local url=$1
    local base_url="https://huggingface.co/"
    local ref="/blob/main/"

    # Extract repo name
    repo_name=${url#$base_url}
    repo_name=${repo_name%%$ref*}

    # Extract file specifier
    file_specifier=${url#*$ref}

    # Return values separated by a delimiter (we'll use '|')
    echo "$repo_name$delimiter$file_specifier"
}

hf_url_2_llama_spec() {
    local decomposed=$(parse_hf_url $1)
    local repo_name=$(echo "$decomposed" | cut -d"$delimiter" -f1)
    local file_specifier=$(echo "$decomposed" | cut -d"$delimiter" -f2)

    echo "--hf-repo $repo_name --hf-file $file_specifier"
}

run_llamacpp_command() {
    case "$1" in
        model)
            shift

            # No args - get current model
            if [ $# -eq 0 ]; then
                env_manager get llamacpp.model
            else
                env_manager set llamacpp.model $@
            fi
            ;;
        args)
            shift

            if [ $# -eq 0 ]; then
                env_manager get llamacpp.extra.args
            else
                env_manager set llamacpp.extra.args $@
            fi
            ;;
        *)
            echo "Please note that this is not llama.cpp CLI, but a Harbor CLI to manage llama.cpp service."
            echo "Access llama.cpp own CLI by running 'harbor exec llamacpp' when it's running."
            echo
            echo "Usage: harbor llamacpp <command>"
            echo
            echo "Commands:"
            echo "  harbor llamacpp model [Huggingface URL] - Get or set the llamacpp model to run"
            ;;
    esac
}

# ========================================================================
# == Main script
# ========================================================================

version="0.0.4"
default_options=($(env_manager get services.default))
default_open=$(env_manager get ui.main)
harbor_home=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
delimiter="|"

cd $harbor_home

# Main script logic
case "$1" in
    up)
        shift
        $(compose_with_options "$@") up -d
        ;;
    down)
        shift
        $(compose_with_options "*") down
        ;;
    ps)
        shift
        $(compose_with_options "*") ps
        ;;
    logs)
        shift
        # Only pass "*" to the command if no options are provided
        $(compose_with_options "*") logs "$@" -n 20 -f
        ;;
    help|--help|-h)
        show_help
        ;;
    hf)
        shift
        run_hf_cli $@
        ;;
    defaults)
        shift
        show_default_services
        ;;
    ln)
        shift
        link_cli
        ;;
    open)
        shift
        open_service $@
        ;;
    url)
        shift
        get_service_url $@
        ;;
    version|--version|-v)
        shift
        show_version
        ;;
    smi)
        shift
        smi
        ;;
    top)
        shift
        nvidia_top
        ;;
    eject)
        shift
        eject $@
        ;;
    ollama)
        shift
        exec_ollama $@
        ;;
    llamacpp)
        shift
        run_llamacpp_command $@
        ;;
    exec)
        shift
        run_in_service $@
        ;;
    config)
        shift
        env_manager $@
        ;;
    gum)
        shift
        run_gum $@
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac