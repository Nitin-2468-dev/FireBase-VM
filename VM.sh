#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager with Multiple Startup Commands
# =============================

# Function to display header
display_header() {
    clear
    cat << "EOF"
========================================================================
  _    _  ____  _____ _____ _   _  _____ ____   ______     ________
 | |  | |/ __ \|  __ \_   _| \ | |/ ____|  _ \ / __ \ \   / /___  /
 | |__| | |  | | |__) || | |  \| | |  __| |_) | |  | \ \_/ /   / / 
 |  __  | |  | |  ___/ | | |   \ | | |_ |  _ <| |  | |\   /   / /  
 | |  | | |__| | |    _| |_| |\  | |__| | |_) | |__| | | |   / /__ 
 |_|  |_|\____/|_|   |_____|_| \_|\_____|____/ \____/  |_|  /_____|
                                                                  
                    POWERED BY HOPINGBOYZ
========================================================================
EOF
    echo
}

# Function to display colored output
print_status() {
    local type=$1
    local message=$2
    
    case $type in
        "INFO") echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN") echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR") echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT") echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *) echo "[$type] $message" ;;
    esac
}

# Function to check dependencies
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "On Ubuntu/Debian, try: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

# Function to cleanup temporary files
cleanup() {
    if [ -f "user-data" ]; then rm -f "user-data"; fi
    if [ -f "meta-data" ]; then rm -f "meta-data"; fi
}

# Function to get all VM configurations
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# Function to serialize startup commands array for config file
serialize_startup_commands() {
    local -n arr=$1
    local serialized=""
    for key in "${!arr[@]}"; do
        # Escape special characters
        local escaped_key="${key//\\/\\\\}"
        escaped_key="${escaped_key//\"/\\\"}"
        local escaped_value="${arr[$key]//\\/\\\\}"
        escaped_value="${escaped_value//\"/\\\"}"
        if [[ -n "$serialized" ]]; then
            serialized+="|SEPARATOR|"
        fi
        serialized+="${escaped_key}:COMMAND:${escaped_value}"
    done
    echo "$serialized"
}

# Function to deserialize startup commands from config file
deserialize_startup_commands() {
    local serialized="$1"
    declare -gA STARTUP_COMMANDS=()
    
    if [[ -z "$serialized" ]]; then
        return 0
    fi
    
    IFS='|SEPARATOR|' read -ra commands <<< "$serialized"
    for cmd in "${commands[@]}"; do
        if [[ "$cmd" =~ ^(.+):COMMAND:(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            # Unescape special characters
            key="${key//\\\\/\\}"
            key="${key//\\\"/\"}"
            value="${value//\\\\/\\}"
            value="${value//\\\"/\"}"
            STARTUP_COMMANDS["$key"]="$value"
        fi
    done
}

# Function to load VM configuration
load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    
    if [[ -f "$config_file" ]]; then
        # Clear previous variables
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED AUTO_LOGIN AUTO_START STARTUP_COMMAND
        declare -gA STARTUP_COMMANDS=()
        
        source "$config_file"
        
        # Set defaults for new variables if not present in config
        AUTO_LOGIN="${AUTO_LOGIN:-true}"
        AUTO_START="${AUTO_START:-false}"
        
        # Handle legacy STARTUP_COMMAND field
        if [[ -n "${STARTUP_COMMAND:-}" ]] && [[ ${#STARTUP_COMMANDS[@]} -eq 0 ]]; then
            STARTUP_COMMANDS["default"]="$STARTUP_COMMAND"
        fi
        
        # Deserialize startup commands if present
        if [[ -n "${STARTUP_COMMANDS_SERIALIZED:-}" ]]; then
            deserialize_startup_commands "$STARTUP_COMMANDS_SERIALIZED"
        fi
        
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

# Function to save VM configuration
save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    
    # Serialize startup commands
    local serialized_commands=""
    if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
        serialized_commands=$(serialize_startup_commands STARTUP_COMMANDS)
    fi
    
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
AUTO_LOGIN="$AUTO_LOGIN"
AUTO_START="$AUTO_START"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
STARTUP_COMMANDS_SERIALIZED="$serialized_commands"
EOF
    
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# Function to validate input
validate_input() {
    local type=$1
    local value=$2

    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore, and contain only letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "command_name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "Command name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
    esac
    return 0
}

# Function to check if VM is running
is_vm_running() {
    local vm_name=$1
    if pgrep -f "qemu-system-x86_64.*$vm_name" >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to manage startup commands
manage_startup_commands() {
    local vm_name=$1
    
    if ! load_vm_config "$vm_name"; then
        return 1
    fi
    
    while true; do
        echo
        print_status "INFO" "Startup Commands for VM: $vm_name"
        echo "=========================================="
        
        if [[ ${#STARTUP_COMMANDS[@]} -eq 0 ]]; then
            echo "No startup commands configured."
        else
            local i=1
            for cmd_name in "${!STARTUP_COMMANDS[@]}"; do
                echo "  $i) $cmd_name: ${STARTUP_COMMANDS[$cmd_name]}"
                ((i++))
            done
        fi
        
        echo
        echo "Startup Commands Menu:"
        echo "  1) Add new startup command"
        if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
            echo "  2) Edit startup command"
            echo "  3) Delete startup command"
            echo "  4) Test startup command"
        fi
        echo "  0) Back to main menu"
        
        read -p "$(print_status "INPUT" "Enter your choice: ")" choice
        
        case $choice in
            1)
                add_startup_command
                ;;
            2)
                if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
                    edit_startup_command
                else
                    print_status "ERROR" "No startup commands to edit"
                fi
                ;;
            3)
                if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
                    delete_startup_command
                else
                    print_status "ERROR" "No startup commands to delete"
                fi
                ;;
            4)
                if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
                    test_startup_command
                else
                    print_status "ERROR" "No startup commands to test"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                print_status "ERROR" "Invalid selection"
                ;;
        esac
    done
}

# Function to add a new startup command
add_startup_command() {
    local cmd_name=""
    local cmd_value=""
    
    while true; do
        read -p "$(print_status "INPUT" "Enter command name (e.g., webserver, database, backup): ")" cmd_name
        if [[ -z "$cmd_name" ]]; then
            print_status "ERROR" "Command name cannot be empty"
            continue
        fi
        if ! validate_input "command_name" "$cmd_name"; then
            continue
        fi
        if [[ -n "${STARTUP_COMMANDS[$cmd_name]:-}" ]]; then
            print_status "ERROR" "Command name '$cmd_name' already exists"
            continue
        fi
        break
    done
    
    read -p "$(print_status "INPUT" "Enter command to execute: ")" cmd_value
    if [[ -z "$cmd_value" ]]; then
        print_status "ERROR" "Command cannot be empty"
        return 1
    fi
    
    STARTUP_COMMANDS["$cmd_name"]="$cmd_value"
    save_vm_config
    print_status "SUCCESS" "Startup command '$cmd_name' added successfully"
}

# Function to edit an existing startup command
edit_startup_command() {
    local cmd_names=($(printf '%s\n' "${!STARTUP_COMMANDS[@]}" | sort))
    
    echo "Select command to edit:"
    for i in "${!cmd_names[@]}"; do
        echo "  $((i+1))) ${cmd_names[$i]}: ${STARTUP_COMMANDS[${cmd_names[$i]}]}"
    done
    
    read -p "$(print_status "INPUT" "Enter command number: ")" choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#cmd_names[@]} ]; then
        local cmd_name="${cmd_names[$((choice-1))]}"
        local current_cmd="${STARTUP_COMMANDS[$cmd_name]}"
        
        print_status "INFO" "Editing command: $cmd_name"
        print_status "INFO" "Current command: $current_cmd"
        
        read -p "$(print_status "INPUT" "Enter new command (press Enter to keep current): ")" new_cmd
        
        if [[ -n "$new_cmd" ]]; then
            STARTUP_COMMANDS["$cmd_name"]="$new_cmd"
            save_vm_config
            print_status "SUCCESS" "Startup command '$cmd_name' updated successfully"
        else
            print_status "INFO" "Command unchanged"
        fi
    else
        print_status "ERROR" "Invalid selection"
    fi
}

# Function to delete a startup command
delete_startup_command() {
    local cmd_names=($(printf '%s\n' "${!STARTUP_COMMANDS[@]}" | sort))
    
    echo "Select command to delete:"
    for i in "${!cmd_names[@]}"; do
        echo "  $((i+1))) ${cmd_names[$i]}: ${STARTUP_COMMANDS[${cmd_names[$i]}]}"
    done
    
    read -p "$(print_status "INPUT" "Enter command number: ")" choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#cmd_names[@]} ]; then
        local cmd_name="${cmd_names[$((choice-1))]}"
        
        read -p "$(print_status "INPUT" "Are you sure you want to delete '$cmd_name'? (y/N): ")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            unset STARTUP_COMMANDS["$cmd_name"]
            save_vm_config
            print_status "SUCCESS" "Startup command '$cmd_name' deleted successfully"
        else
            print_status "INFO" "Deletion cancelled"
        fi
    else
        print_status "ERROR" "Invalid selection"
    fi
}

# Function to test a startup command
test_startup_command() {
    local cmd_names=($(printf '%s\n' "${!STARTUP_COMMANDS[@]}" | sort))
    
    echo "Select command to test:"
    for i in "${!cmd_names[@]}"; do
        echo "  $((i+1))) ${cmd_names[$i]}: ${STARTUP_COMMANDS[${cmd_names[$i]}]}"
    done
    
    read -p "$(print_status "INPUT" "Enter command number: ")" choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#cmd_names[@]} ]; then
        local cmd_name="${cmd_names[$((choice-1))]}"
        local cmd="${STARTUP_COMMANDS[$cmd_name]}"
        
        print_status "INFO" "Testing command '$cmd_name': $cmd"
        print_status "WARN" "This will execute the command on your host system!"
        
        read -p "$(print_status "INPUT" "Continue with test? (y/N): ")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            print_status "INFO" "Executing: $cmd"
            echo "----------------------------------------"
            if bash -c "$cmd"; then
                print_status "SUCCESS" "Command executed successfully"
            else
                print_status "ERROR" "Command failed with exit code $?"
            fi
            echo "----------------------------------------"
        else
            print_status "INFO" "Test cancelled"
        fi
    else
        print_status "ERROR" "Invalid selection"
    fi
}

# Function to create cloud-init seed ISO with multiple startup commands support
create_cloud_init_seed() {
    local tmpd
    tmpd="$(mktemp -d)" || { print_status "ERROR" "mktemp failed"; return 1; }

    # Generate unique instance-id to force cloud-init to run on each boot
    local iid
    if date +%s%3N >/dev/null 2>&1; then
        iid="$(date +%s%3N)"
    else
        iid="$(date +%s)"
    fi

    # Create user-data with root/root credentials, SSH configuration, and optional auto-login
    cat >"$tmpd/user-data" <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false

# Enable root login with password
users:
  - name: root
    plain_text_passwd: root
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

# Set password for root (multiple methods for reliability)
chpasswd:
  list: |
    root:root
  expire: false

# SSH configuration
ssh_authorized_keys: []

# Configure SSH to allow root login and password authentication
write_files:
  - path: /etc/ssh/sshd_config.d/99-root-login.conf
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
      PubkeyAuthentication yes
    owner: root:root
    permissions: '0644'
EOF

    # Add auto-login configuration if enabled
    if [[ "${AUTO_LOGIN:-true}" == true ]]; then
        cat >>"$tmpd/user-data" <<EOF
  # Auto-login configuration for systemd systems
  - path: /etc/systemd/system/getty@tty1.service.d/autologin.conf
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
    owner: root:root
    permissions: '0644'
  - path: /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I \$TERM
    owner: root:root
    permissions: '0644'
EOF
    fi

    # Add multiple startup commands configuration if specified
    if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
        # Create startup command manager script
        cat >>"$tmpd/user-data" <<EOF
  # Multiple startup commands manager
  - path: /usr/local/bin/vm-startup
    content: |
      #!/bin/bash
      
      # VM Startup Commands Manager
      COMMANDS_DIR="/etc/vm-startup-commands"
      LOG_FILE="/var/log/vm-startup.log"
      
      # Ensure log directory exists
      mkdir -p "\$(dirname "\$LOG_FILE")"
      
      # Function to log messages
      log_message() {
          echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a "\$LOG_FILE"
      }
      
      # Function to show usage
      show_usage() {
          echo "VM Startup Commands Manager"
          echo "Usage: \$0 [COMMAND_NAME]"
          echo ""
          echo "Available commands:"
          if [ -d "\$COMMANDS_DIR" ]; then
              for cmd_file in "\$COMMANDS_DIR"/*; do
                  if [ -f "\$cmd_file" ]; then
                      cmd_name=\$(basename "\$cmd_file")
                      echo "  \$cmd_name"
                  fi
              done
          else
              echo "  No commands configured"
          fi
          echo ""
          echo "Examples:"
          echo "  \$0 webserver    # Execute webserver startup command"
          echo "  \$0              # Show this help"
      }
      
      # Function to execute startup command
      execute_command() {
          local cmd_name="\$1"
          local cmd_file="\$COMMANDS_DIR/\$cmd_name"
          
          if [ ! -f "\$cmd_file" ]; then
              log_message "ERROR: Command '\$cmd_name' not found"
              return 1
          fi
          
          log_message "INFO: Executing startup command '\$cmd_name'"
          
          # Make command executable
          chmod +x "\$cmd_file"
          
          # Execute command and log output
          if "\$cmd_file" 2>&1 | tee -a "\$LOG_FILE"; then
              log_message "SUCCESS: Command '\$cmd_name' completed successfully"
              return 0
          else
              log_message "ERROR: Command '\$cmd_name' failed with exit code \$?"
              return 1
          fi
      }
      
      # Main execution
      case "\${1:-}" in
          "")
              show_usage
              ;;
          *)
              execute_command "\$1"
              ;;
      esac
    owner: root:root
    permissions: '0755'
  # Create commands directory
  - path: /etc/vm-startup-commands/.keep
    content: ""
    owner: root:root
    permissions: '0644'
EOF

        # Add individual startup command files
        for cmd_name in "${!STARTUP_COMMANDS[@]}"; do
            local escaped_cmd="${STARTUP_COMMANDS[$cmd_name]//\\/\\\\}"
            escaped_cmd="${escaped_cmd//\"/\\\"}"
            cat >>"$tmpd/user-data" <<EOF
  - path: /etc/vm-startup-commands/$cmd_name
    content: |
      #!/bin/bash
      # Startup command: $cmd_name
      $escaped_cmd
    owner: root:root
    permissions: '0755'
EOF
        done
    fi

    cat >>"$tmpd/user-data" <<EOF

# System configuration commands
runcmd:
  # Set root password multiple times for reliability
  - echo 'root:root' | chpasswd
  - passwd -u root
  # Configure SSH
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  # Restart SSH service
  - systemctl restart ssh || systemctl restart sshd || service ssh restart || service sshd restart
EOF

    # Add auto-login commands if enabled
    if [[ "${AUTO_LOGIN:-true}" == true ]]; then
        cat >>"$tmpd/user-data" <<EOF
  # Setup auto-login
  - mkdir -p /etc/systemd/system/getty@tty1.service.d
  - mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
  - systemctl daemon-reload
  - systemctl enable getty@tty1.service
  - systemctl enable serial-getty@ttyS0.service
  # Restart getty services
  - systemctl restart getty@tty1.service || true
  - systemctl restart serial-getty@ttyS0.service || true
EOF
    fi

    # Add startup command setup if specified
    if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
        cat >>"$tmpd/user-data" <<EOF
  # Setup startup commands
  - chmod +x /usr/local/bin/vm-startup
  - mkdir -p /etc/vm-startup-commands
  # Create convenience aliases
  - echo 'alias vm-start="/usr/local/bin/vm-startup"' >> /root/.bashrc
  - echo 'alias vmstart="/usr/local/bin/vm-startup"' >> /root/.bashrc
EOF
    fi

    cat >>"$tmpd/user-data" <<EOF
  # Final status message
  - echo "VM setup complete with root/root credentials"
EOF

    if [[ "${AUTO_LOGIN:-true}" == true ]]; then
        cat >>"$tmpd/user-data" <<EOF
  - echo "Auto-login enabled for console access"
EOF
    fi

    if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
        cat >>"$tmpd/user-data" <<EOF
  - echo "Startup commands configured: ${!STARTUP_COMMANDS[*]}"
  - echo "Use 'vm-startup [command-name]' to execute startup commands"
  - echo "Use 'vm-startup' to see available commands"
EOF
    fi

    cat >>"$tmpd/user-data" <<EOF

# Network configuration
preserve_hostname: false
EOF

    # Create meta-data with unique instance-id
    cat >"$tmpd/meta-data" <<EOF
instance-id: ${VM_NAME:-vm}-${iid}
local-hostname: $HOSTNAME
EOF

    # Create seed ISO with cloud-localds or fallback to genisoimage/mkisofs
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$SEED_FILE" "$tmpd/user-data" "$tmpd/meta-data" || {
            print_status "ERROR" "cloud-localds failed"
            rm -rf "$tmpd"
            return 1
        }
    elif command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1; then
        if command -v genisoimage >/dev/null 2>&1; then
            genisoimage -output "$SEED_FILE" -volid cidata -joliet -rock "$tmpd/user-data" "$tmpd/meta-data" >/dev/null 2>&1 || {
                print_status "ERROR" "genisoimage failed"
                rm -rf "$tmpd"
                return 1
            }
        else
            mkisofs -output "$SEED_FILE" -volid cidata -joliet -rock "$tmpd/user-data" "$tmpd/meta-data" >/dev/null 2>&1 || {
                print_status "ERROR" "mkisofs failed"
                rm -rf "$tmpd"
                return 1
            }
        fi
    else
        print_status "ERROR" "No tool to create cloud-init seed (install cloud-localds or genisoimage/mkisofs)."
        rm -rf "$tmpd"
        return 1
    fi

    rm -rf "$tmpd"
    local startup_status=""
    if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
        startup_status=" with ${#STARTUP_COMMANDS[@]} startup command(s)"
    fi
    local autologin_status=""
    if [[ "${AUTO_LOGIN:-true}" == true ]]; then
        autologin_status=" with auto-login"
    fi
    print_status "INFO" "Cloud-init seed created: $SEED_FILE (instance-id ${VM_NAME:-vm}-${iid})$autologin_status$startup_status"
    return 0
}

# Function to create new VM
create_new_vm() {
    print_status "INFO" "Creating a new VM"
    
    # Initialize startup commands array
    declare -gA STARTUP_COMMANDS=()
    
    # OS Selection
    print_status "INFO" "Select an OS to set up:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        ((i++))
    done
    
    while true; do
        read -p "$(print_status "INPUT" "Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    # Custom Inputs with validation
    while true; do
        read -p "$(print_status "INPUT" "Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            # Check if VM name already exists
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM with name '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then
            break
        fi
    done

    # Force root credentials
    USERNAME="root"
    PASSWORD="root"
    print_status "INFO" "Using default credentials: username=root, password=root"

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            # Check if port is already in use
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT is already in use"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, default: n): ")" gui_input
        GUI_MODE=false
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
            GUI_MODE=true
            break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
            break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Auto-login console option
    while true; do
        read -p "$(print_status "INPUT" "Enable auto-login console? (y/n, default: y): ")" autologin_input
        AUTO_LOGIN=true
        autologin_input="${autologin_input:-y}"
        if [[ "$autologin_input" =~ ^[Yy]$ ]]; then 
            AUTO_LOGIN=true
            break
        elif [[ "$autologin_input" =~ ^[Nn]$ ]]; then
            AUTO_LOGIN=false
            break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Auto-start option
    while true; do
        read -p "$(print_status "INPUT" "Set as auto-start VM? (y/n, default: n): ")" autostart_input
        AUTO_START=false
        autostart_input="${autostart_input:-n}"
        if [[ "$autostart_input" =~ ^[Yy]$ ]]; then 
            AUTO_START=true
            break
        elif [[ "$autostart_input" =~ ^[Nn]$ ]]; then
            AUTO_START=false
            break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Startup commands configuration
    while true; do
        read -p "$(print_status "INPUT" "Add startup commands? (y/n, default: n): ")" startup_input
        startup_input="${startup_input:-n}"
        if [[ "$startup_input" =~ ^[Yy]$ ]]; then 
            print_status "INFO" "You can add multiple startup commands that can be executed with arguments"
            manage_startup_commands "$VM_NAME" || true
            break
        elif [[ "$startup_input" =~ ^[Nn]$ ]]; then
            break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Additional network options
    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, press Enter for none): ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"

    # Download and setup VM image
    setup_vm_image
    
    # Save configuration
    save_vm_config
}

# Function to setup VM image
setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    
    # Create VM directory if it doesn't exist
    mkdir -p "$VM_DIR"
    
    # Check if image already exists
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image file already exists. Skipping download."
    else
        print_status "INFO" "Downloading image from $IMG_URL..."
        
        # Determine if the URL points to a tar.xz file
        if [[ "$IMG_URL" == *.tar.xz ]]; then
            local download_file="$IMG_FILE.tar.xz"
            if ! wget --progress=bar:force "$IMG_URL" -O "$download_file"; then
                print_status "ERROR" "Failed to download image from $IMG_URL"
                exit 1
            fi
            
            print_status "INFO" "Extracting tar.xz archive..."
            # Extract the tar.xz file to a temporary directory
            local extract_dir="$VM_DIR/$VM_NAME.extract"
            mkdir -p "$extract_dir"
            
            if ! tar -xJf "$download_file" -C "$extract_dir"; then
                print_status "ERROR" "Failed to extract tar.xz archive"
                rm -rf "$extract_dir" "$download_file"
                exit 1
            fi
            
            # Find the qcow2 file in the extracted contents
            local qcow2_file=$(find "$extract_dir" -name "*.qcow2" -type f | head -n 1)
            
            if [[ -z "$qcow2_file" ]]; then
                print_status "ERROR" "No qcow2 file found in the extracted archive"
                rm -rf "$extract_dir" "$download_file"
                exit 1
            fi
            
            print_status "INFO" "Found qcow2 image: $(basename "$qcow2_file")"
            mv "$qcow2_file" "$IMG_FILE"
            
            # Cleanup
            rm -rf "$extract_dir" "$download_file"
            print_status "SUCCESS" "Image extracted successfully"
        else
            if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
                print_status "ERROR" "Failed to download image from $IMG_URL"
                exit 1
            fi
            mv "$IMG_FILE.tmp" "$IMG_FILE"
        fi
    fi
    
    # Resize the disk image if needed
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "Failed to resize disk image. Creating new image with specified size..."
        # Create a new image with the specified size
        rm -f "$IMG_FILE"
        qemu-img create -f qcow2 -F qcow2 -b "$IMG_FILE" "$IMG_FILE.tmp" "$DISK_SIZE" 2>/dev/null || \
        qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"
        if [ -f "$IMG_FILE.tmp" ]; then
            mv "$IMG_FILE.tmp" "$IMG_FILE"
        fi
    fi

    # Create cloud-init seed with root/root credentials
    create_cloud_init_seed
    
    if [[ "${AUTO_LOGIN:-true}" == true ]]; then
        print_status "SUCCESS" "VM '$VM_NAME' created successfully with root/root credentials and auto-login console."
    else
        print_status "SUCCESS" "VM '$VM_NAME' created successfully with root/root credentials."
    fi
}

# Function to start a VM with optional startup command argument
start_vm() {
    local vm_name=$1
    local startup_cmd_arg="${2:-}"

    if load_vm_config "$vm_name"; then
        # Always use root/root credentials
        USERNAME="root"
        PASSWORD="root"

        print_status "INFO" "Starting VM: $vm_name"
        if [[ "${AUTO_LOGIN:-true}" == true ]]; then
            print_status "INFO" "Auto-login console enabled - no manual login required"
        fi
        if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
            print_status "INFO" "Available startup commands: ${!STARTUP_COMMANDS[*]}"
            if [[ -n "$startup_cmd_arg" ]]; then
                if [[ -n "${STARTUP_COMMANDS[$startup_cmd_arg]:-}" ]]; then
                    print_status "INFO" "Will execute startup command '$startup_cmd_arg' after boot"
                else
                    print_status "WARN" "Startup command '$startup_cmd_arg' not found. Available: ${!STARTUP_COMMANDS[*]}"
                fi
            else
                print_status "INFO" "Use 'vm-startup [command-name]' inside VM to run startup commands"
            fi
        fi
        print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
        print_status "INFO" "Username: $USERNAME"
        print_status "INFO" "Password: $PASSWORD"

        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "VM image file not found: $IMG_FILE"
            return 1
        fi

        # Recreate cloud-init seed for each start to ensure root/root is set
        print_status "INFO" "Creating fresh cloud-init seed for this start..."
        create_cloud_init_seed || { print_status "ERROR" "Failed to create seed"; return 1; }

        # Build qemu command
        local qemu_cmd=(
            qemu-system-x86_64
            -enable-kvm
            -m "$MEMORY"
            -smp "$CPUS"
            -cpu host
            -drive "file=$IMG_FILE,format=qcow2,if=virtio"
            -cdrom "$SEED_FILE"
            -boot order=c
            -device virtio-net-pci,netdev=n0
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
        )

        # Additional port forwards
        if [[ -n "${PORT_FORWARDS:-}" ]]; then
            local net_index=1
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port _ <<< "$forward"
                if [[ -z "$host_port" || -z "$guest_port" ]]; then
                    print_status "WARN" "Invalid port forward entry: $forward (skipping)"
                    continue
                fi
                qemu_cmd+=(-device "virtio-net-pci,netdev=n${net_index}")
                qemu_cmd+=(-netdev "user,id=n${net_index},hostfwd=tcp::${host_port}-${guest_port}")
                ((net_index++))
            done
        fi

        # GUI or console mode
        if [[ "${GUI_MODE:-false}" == true ]]; then
            qemu_cmd+=(-vga virtio -display gtk,gl=on)
            print_status "INFO" "GUI mode enabled"
        else
            qemu_cmd+=(-nographic -serial mon:stdio)
            if [[ "${AUTO_LOGIN:-true}" == true ]]; then
                print_status "INFO" "Console mode with auto-login enabled"
            else
                print_status "INFO" "Console mode (nographic). QEMU output will show guest console."
            fi
        fi

        # Performance enhancements
        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
        )

        # Start the VM
        "${qemu_cmd[@]}" &
        local qemu_pid=$!
        
        # If startup command specified, wait and execute it
        if [[ -n "$startup_cmd_arg" ]] && [[ -n "${STARTUP_COMMANDS[$startup_cmd_arg]:-}" ]]; then
            print_status "INFO" "Waiting for VM to boot before executing startup command..."
            sleep 10  # Give VM time to boot
            
            # Try to execute the startup command via SSH
            local max_attempts=30
            local attempt=1
            while [ $attempt -le $max_attempts ]; do
                if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$SSH_PORT" "$USERNAME@localhost" "vm-startup $startup_cmd_arg" 2>/dev/null; then
                    print_status "SUCCESS" "Startup command '$startup_cmd_arg' executed successfully"
                    break
                else
                    print_status "INFO" "Attempt $attempt/$max_attempts: Waiting for VM to be ready for SSH..."
                    sleep 5
                    ((attempt++))
                fi
            done
            
            if [ $attempt -gt $max_attempts ]; then
                print_status "WARN" "Could not execute startup command via SSH. You can run 'vm-startup $startup_cmd_arg' manually after logging in."
            fi
        fi
        
        # Wait for QEMU process to finish
        wait $qemu_pid
        
        print_status "INFO" "VM $vm_name has been shut down"
    fi
}

# Function to delete a VM
delete_vm() {
    local vm_name=$1
    
    print_status "WARN" "This will permanently delete VM '$vm_name' and all its data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf"
            print_status "SUCCESS" "VM '$vm_name' has been deleted"
        fi
    else
        print_status "INFO" "Deletion cancelled"
    fi
}

# Function to show VM info
show_vm_info() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        echo
        print_status "INFO" "VM Information: $vm_name"
        echo "=========================================="
        echo "OS: $OS_TYPE"
        echo "Hostname: $HOSTNAME"
        echo "Username: root (hardcoded)"
        echo "Password: root (hardcoded)"
        echo "SSH Port: $SSH_PORT"
        echo "Memory: $MEMORY MB"
        echo "CPUs: $CPUS"
        echo "Disk: $DISK_SIZE"
        echo "GUI Mode: $GUI_MODE"
        echo "Auto-Login Console: ${AUTO_LOGIN:-true}"
        echo "Auto-Start: ${AUTO_START:-false}"
        if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
            echo "Startup Commands:"
            for cmd_name in "${!STARTUP_COMMANDS[@]}"; do
                echo "  - $cmd_name: ${STARTUP_COMMANDS[$cmd_name]}"
            done
        else
            echo "Startup Commands: None"
        fi
        echo "Port Forwards: ${PORT_FORWARDS:-None}"
        echo "Created: $CREATED"
        echo "Image File: $IMG_FILE"
        echo "Seed File: $SEED_FILE"
        echo "=========================================="
        echo
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Function to stop a running VM
stop_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Stopping VM: $vm_name"
            pkill -f "qemu-system-x86_64.*$IMG_FILE"
            sleep 2
            if is_vm_running "$vm_name"; then
                print_status "WARN" "VM did not stop gracefully, forcing termination..."
                pkill -9 -f "qemu-system-x86_64.*$IMG_FILE"
            fi
            print_status "SUCCESS" "VM $vm_name stopped"
        else
            print_status "INFO" "VM $vm_name is not running"
        fi
    fi
}

# Function to edit VM configuration
edit_vm_config() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Editing VM: $vm_name"
        
        while true; do
            echo "What would you like to edit?"
            echo "  1) Hostname"
            echo "  2) SSH Port"
            echo "  3) GUI Mode"
            echo "  4) Auto-Login Console"
            echo "  5) Auto-Start Setting"
            echo "  6) Startup Commands"
            echo "  7) Port Forwards"
            echo "  8) Memory (RAM)"
            echo "  9) CPU Count"
            echo " 10) Disk Size"
            echo "  0) Back to main menu"
            echo
            print_status "INFO" "Username and password are hardcoded as root/root"
            
            read -p "$(print_status "INPUT" "Enter your choice: ")" edit_choice
            
            case $edit_choice in
                1)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new hostname (current: $HOSTNAME): ")" new_hostname
                        new_hostname="${new_hostname:-$HOSTNAME}"
                        if validate_input "name" "$new_hostname"; then
                            HOSTNAME="$new_hostname"
                            break
                        fi
                    done
                    ;;
                2)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new SSH port (current: $SSH_PORT): ")" new_ssh_port
                        new_ssh_port="${new_ssh_port:-$SSH_PORT}"
                        if validate_input "port" "$new_ssh_port"; then
                            if [ "$new_ssh_port" != "$SSH_PORT" ] && ss -tln 2>/dev/null | grep -q ":$new_ssh_port "; then
                                print_status "ERROR" "Port $new_ssh_port is already in use"
                            else
                                SSH_PORT="$new_ssh_port"
                                break
                            fi
                        fi
                    done
                    ;;
                3)
                    while true; do
                        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, current: $GUI_MODE): ")" gui_input
                        gui_input="${gui_input:-}"
                        if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
                            GUI_MODE=true
                            break
                        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
                            GUI_MODE=false
                            break
                        elif [ -z "$gui_input" ]; then
                            break
                        else
                            print_status "ERROR" "Please answer y or n"
                        fi
                    done
                    ;;
                4)
                    while true; do
                        read -p "$(print_status "INPUT" "Enable auto-login console? (y/n, current: ${AUTO_LOGIN:-true}): ")" autologin_input
                        autologin_input="${autologin_input:-}"
                        if [[ "$autologin_input" =~ ^[Yy]$ ]]; then 
                            AUTO_LOGIN=true
                            break
                        elif [[ "$autologin_input" =~ ^[Nn]$ ]]; then
                            AUTO_LOGIN=false
                            break
                        elif [ -z "$autologin_input" ]; then
                            break
                        else
                            print_status "ERROR" "Please answer y or n"
                        fi
                    done
                    ;;
                5)
                    while true; do
                        read -p "$(print_status "INPUT" "Set as auto-start VM? (y/n, current: ${AUTO_START:-false}): ")" autostart_input
                        autostart_input="${autostart_input:-}"
                        if [[ "$autostart_input" =~ ^[Yy]$ ]]; then 
                            AUTO_START=true
                            break
                        elif [[ "$autostart_input" =~ ^[Nn]$ ]]; then
                            AUTO_START=false
                            break
                        elif [ -z "$autostart_input" ]; then
                            break
                        else
                            print_status "ERROR" "Please answer y or n"
                        fi
                    done
                    ;;
                6)
                    manage_startup_commands "$vm_name"
                    ;;
                7)
                    read -p "$(print_status "INPUT" "Additional port forwards (current: ${PORT_FORWARDS:-None}): ")" new_port_forwards
                    PORT_FORWARDS="${new_port_forwards:-$PORT_FORWARDS}"
                    ;;
                8)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new memory in MB (current: $MEMORY): ")" new_memory
                        new_memory="${new_memory:-$MEMORY}"
                        if validate_input "number" "$new_memory"; then
                            MEMORY="$new_memory"
                            break
                        fi
                    done
                    ;;
                9)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new CPU count (current: $CPUS): ")" new_cpus
                        new_cpus="${new_cpus:-$CPUS}"
                        if validate_input "number" "$new_cpus"; then
                            CPUS="$new_cpus"
                            break
                        fi
                    done
                    ;;
                10)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new disk size (current: $DISK_SIZE): ")" new_disk_size
                        new_disk_size="${new_disk_size:-$DISK_SIZE}"
                        if validate_input "size" "$new_disk_size"; then
                            DISK_SIZE="$new_disk_size"
                            break
                        fi
                    done
                    ;;
                0)
                    return 0
                    ;;
                *)
                    print_status "ERROR" "Invalid selection"
                    continue
                    ;;
            esac
            
            # Save configuration
            save_vm_config
            
            read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" continue_editing
            if [[ ! "$continue_editing" =~ ^[Yy]$ ]]; then
                break
            fi
        done
    fi
}

# Function to resize VM disk
resize_vm_disk() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Current disk size: $DISK_SIZE"
        
        while true; do
            read -p "$(print_status "INPUT" "Enter new disk size (e.g., 50G): ")" new_disk_size
            if validate_input "size" "$new_disk_size"; then
                if [[ "$new_disk_size" == "$DISK_SIZE" ]]; then
                    print_status "INFO" "New disk size is the same as current size. No changes made."
                    return 0
                fi
                
                print_status "INFO" "Resizing disk to $new_disk_size..."
                if qemu-img resize "$IMG_FILE" "$new_disk_size"; then
                    DISK_SIZE="$new_disk_size"
                    save_vm_config
                    print_status "SUCCESS" "Disk resized successfully to $new_disk_size"
                else
                    print_status "ERROR" "Failed to resize disk"
                    return 1
                fi
                break
            fi
        done
    fi
}

# Function to auto-start designated VM with optional startup command
auto_start_vm() {
    local startup_cmd_arg="${1:-}"
    local vms=($(get_vm_list))
    local autostart_vm=""
    local found_count=0
    
    print_status "INFO" "Scanning for auto-start VMs..."
    
    # Check if we have any VMs at all
    if [ ${#vms[@]} -eq 0 ]; then
        print_status "ERROR" "No VMs found in $VM_DIR"
        print_status "INFO" "Create a VM first, then set it as auto-start"
        read -p "$(print_status "INPUT" "Press Enter to go to main menu...")"
        main_menu
        return
    fi
    
    # Find the auto-start VM(s)
    for vm in "${vms[@]}"; do
        if load_vm_config "$vm"; then
            if [[ "${AUTO_START:-false}" == "true" ]]; then
                found_count=$((found_count + 1))
                if [[ -n "$autostart_vm" ]]; then
                    print_status "WARN" "Multiple VMs set for auto-start found:"
                    print_status "WARN" "  - $autostart_vm (already selected)"
                    print_status "WARN" "  - $vm (skipping)"
                else
                    autostart_vm="$vm"
                    print_status "SUCCESS" "Found auto-start VM: $autostart_vm"
                fi
            fi
        else
            print_status "ERROR" "Failed to load config for VM: $vm"
        fi
    done
    
    print_status "INFO" "Scan complete. Found $found_count auto-start VM(s)"
    
    if [[ -n "$autostart_vm" ]]; then
        print_status "INFO" "Auto-starting VM: $autostart_vm"
        
        # Check if VM is already running
        if is_vm_running "$autostart_vm"; then
            print_status "WARN" "VM $autostart_vm is already running"
            read -p "$(print_status "INPUT" "Press Enter to continue...")"
            main_menu
            return
        fi
        
        # Start the VM with optional startup command
        start_vm "$autostart_vm" "$startup_cmd_arg"
    else
        print_status "INFO" "No VM configured for auto-start"
        print_status "INFO" "To set a VM as auto-start:"
        print_status "INFO" "1. Go to main menu"
        print_status "INFO" "2. Choose 'Edit VM configuration'"
        print_status "INFO" "3. Select 'Auto-Start Setting'"
        print_status "INFO" "4. Set to 'y' (yes)"
        read -p "$(print_status "INPUT" "Press Enter to go to main menu...")"
        main_menu
    fi
}

# Function to show VM performance metrics
show_vm_performance() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Performance metrics for VM: $vm_name"
            echo "=========================================="
            
            local qemu_pid=$(pgrep -f "qemu-system-x86_64.*$IMG_FILE")
            if [[ -n "$qemu_pid" ]]; then
                echo "QEMU Process Stats:"
                ps -p "$qemu_pid" -o pid,%cpu,%mem,sz,rss,vsz,cmd --no-headers
                echo
                
                echo "Memory Usage:"
                free -h
                echo
                
                echo "Disk Usage:"
                df -h "$IMG_FILE" 2>/dev/null || du -h "$IMG_FILE"
            else
                print_status "ERROR" "Could not find QEMU process for VM $vm_name"
            fi
        else
            print_status "INFO" "VM $vm_name is not running"
            echo "Configuration:"
            echo "  Memory: $MEMORY MB"
            echo "  CPUs: $CPUS"
            echo "  Disk: $DISK_SIZE"
            echo "  Auto-Login: ${AUTO_LOGIN:-true}"
            echo "  Auto-Start: ${AUTO_START:-false}"
            if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
                echo "  Startup Commands: ${!STARTUP_COMMANDS[*]}"
            fi
        fi
        echo "=========================================="
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Function to toggle auto-login for existing VM
toggle_autologin() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        local current_status="${AUTO_LOGIN:-true}"
        print_status "INFO" "Current auto-login status for VM '$vm_name': $current_status"
        
        while true; do
            read -p "$(print_status "INPUT" "Enable auto-login console? (y/n): ")" autologin_input
            if [[ "$autologin_input" =~ ^[Yy]$ ]]; then 
                AUTO_LOGIN=true
                break
            elif [[ "$autologin_input" =~ ^[Nn]$ ]]; then
                AUTO_LOGIN=false
                break
            else
                print_status "ERROR" "Please answer y or n"
            fi
        done
        
        save_vm_config
        print_status "SUCCESS" "Auto-login setting updated for VM '$vm_name': $AUTO_LOGIN"
        print_status "INFO" "Changes will take effect on next VM start"
    fi
}

# Function to show usage and examples
show_usage() {
    echo "Enhanced Multi-VM Manager with Multiple Startup Commands"
    echo
    echo "Usage:"
    echo "  $0                                    # Interactive menu"
    echo "  $0 --autostart                       # Auto-start designated VM"
    echo "  $0 --autostart [command-name]        # Auto-start VM with specific startup command"
    echo "  $0 --start [vm-name]                 # Start specific VM"
    echo "  $0 --start [vm-name] [command-name]  # Start VM with startup command"
    echo
    echo "Examples:"
    echo "  $0                           # Start interactive menu"
    echo "  $0 --autostart               # Start the auto-start VM"
    echo "  $0 --autostart webserver     # Start auto-start VM and run 'webserver' command"
    echo "  $0 --start myvm              # Start VM named 'myvm'"
    echo "  $0 --start myvm database     # Start 'myvm' and run 'database' startup command"
    echo
    echo "Inside the VM, use these commands:"
    echo "  vm-startup                   # List available startup commands"
    echo "  vm-startup [command-name]    # Execute specific startup command"
    echo "  vmstart [command-name]       # Alias for vm-startup"
}

# Main menu function
main_menu() {
    while true; do
        display_header
        
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}
        
        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count existing VM(s):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                if is_vm_running "${vms[$i]}"; then
                    status="Running"
                fi
                # Load config to show auto-login, auto-start, and startup commands status
                if load_vm_config "${vms[$i]}"; then
                    local status_tags=""
                    if [[ "${AUTO_LOGIN:-true}" == true ]]; then
                        status_tags="$status_tags[Auto-Login]"
                    fi
                    if [[ "${AUTO_START:-false}" == true ]]; then
                        status_tags="$status_tags[Auto-Start]"
                    fi
                    if [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
                        status_tags="$status_tags[${#STARTUP_COMMANDS[@]} Commands]"
                    fi
                    printf "  %2d) %s (%s)%s\n" $((i+1)) "${vms[$i]}" "$status" "$status_tags"
                fi
            done
            echo
        fi
        
        echo "Main Menu:"
        echo "  1) Create a new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            echo "  9) Toggle auto-login console"
            echo " 10) Manage startup commands"
        fi
        echo " 99) Auto-start VM (if configured)"
        echo "  0) Exit"
        echo
        print_status "INFO" "All VMs use root/root credentials by default"
        print_status "INFO" "Auto-login console eliminates the need for manual login at VM console"
        print_status "INFO" "Multiple startup commands can be configured per VM"
        print_status "INFO" "Use --help for command line usage examples"
        
        read -p "$(print_status "INPUT" "Enter your choice: ")" choice
        
        case $choice in
            1) create_new_vm ;;
            2)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to start: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        local selected_vm="${vms[$((vm_num-1))]}"
                        
                        # Check if VM has startup commands and offer to run one
                        if load_vm_config "$selected_vm" && [[ ${#STARTUP_COMMANDS[@]} -gt 0 ]]; then
                            echo "Available startup commands: ${!STARTUP_COMMANDS[*]}"
                            read -p "$(print_status "INPUT" "Enter startup command name (or press Enter to skip): ")" startup_cmd
                            start_vm "$selected_vm" "$startup_cmd"
                        else
                            start_vm "$selected_vm"
                        fi
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            3)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to stop: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        stop_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            4)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show info: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            5)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to edit: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        edit_vm_config "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to delete: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            7)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to resize disk: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        resize_vm_disk "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            8)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show performance: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_performance "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            9)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to toggle auto-login: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        toggle_autologin "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            10)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to manage startup commands: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        manage_startup_commands "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            99) auto_start_vm ;;
            0)
                print_status "INFO" "Goodbye!"
                exit 0
                ;;
            *) print_status "ERROR" "Invalid option" ;;
        esac
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Check dependencies
check_dependencies

# Initialize paths
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# Install sshpass if not available (for automatic startup command execution)
if ! command -v sshpass &> /dev/null; then
    print_status "WARN" "sshpass not found. Automatic startup command execution via SSH may not work."
    print_status "INFO" "Install sshpass: sudo apt install sshpass (Ubuntu/Debian) or brew install hudochenkov/sshpass/sshpass (macOS)"
fi

# Supported OS list
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
    ["Kali Linux 2025.3"]="kali|2025.3|https://kali.download/cloud-images/kali-2025.3/kali-linux-2025.3-cloud-genericcloud-amd64.tar.xz|kali|kali|kali"
)

# Parse command line arguments
case "${1:-}" in
    "--help"|"-h")
        show_usage
        exit 0
        ;;
    "--autostart")
        auto_start_vm "${2:-}"
        ;;
    "--start")
        if [[ -z "${2:-}" ]]; then
            print_status "ERROR" "VM name required for --start option"
            show_usage
            exit 1
        fi
        start_vm "$2" "${3:-}"
        ;;
    "")
        # Start the main menu
        main_menu
        ;;
    *)
        print_status "ERROR" "Unknown option: $1"
        show_usage
        exit 1
        ;;
esac
