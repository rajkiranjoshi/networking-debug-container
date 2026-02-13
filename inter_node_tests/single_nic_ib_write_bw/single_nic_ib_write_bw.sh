#!/bin/bash

# Note: We intentionally don't use 'set -e' because we need explicit error handling
# to provide meaningful error messages when kubectl commands fail.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
bi_directional=false
namespace="default"
json_output=false
use_iterations=true
iterations=5000
iterations_set=false
num_qps=1
tos=""

# Function to print usage
usage() {
    echo "Usage: $0 --src <pod>:<hca>[:<gpu_type>:<gpu>] --dst <pod>:<hca>[:<gpu_type>:<gpu>] --msg-size <size> [options]"
    echo ""
    echo "Arguments:"
    echo "  --src <pod>:<hca>[:[<gpu_type>:]<gpu>]  Source pod, HCA, and optional GPU (type: cuda or rocm)"
    echo "  --dst <pod>:<hca>[:[<gpu_type>:]<gpu>]  Destination pod, HCA, and optional GPU"
    echo "                                          GPU formats: pod:hca:0 (cuda default) or pod:hca:rocm:0"
    echo "  --msg-size <size>              Message size in bytes (e.g., 65536, 1048576)"
    echo "  --duration <sec>               Test duration in seconds (mutually exclusive with --iterations)"
    echo "  --iterations <n>               Number of iterations (default: 5000, mutually exclusive with --duration)"
    echo "                                 Note: iterations mode also measures peak bandwidth"
    echo "  --num-qps <n>                  Number of queue pairs (default: 1)"
    echo "  --bi-directional               Enable bi-directional bandwidth test (optional)"
    echo "  -n, --namespace <ns>           Kubernetes namespace (default: default)"
    echo "  --tos <value>                  Type of Service value (0-255). Enables RDMA CM (-R)"
    echo "  --json                         Output results as parsable JSON (suppresses human-readable output)"
    echo ""
    echo "Examples:"
    echo "  # Simple test (uses defaults: 5000 iterations, 1 QP)"
    echo "  $0 --src pod1:mlx5_0 --dst pod2:mlx5_1 --msg-size 1048576"
    echo ""
    echo "  # Duration-based test (measures average bandwidth only)"
    echo "  $0 --src pod1:mlx5_0 --dst pod2:mlx5_1 --msg-size 65536 --duration 10"
    echo ""
    echo "  # Iteration-based test with 4 QPs (measures peak and average bandwidth)"
    echo "  $0 --src pod1:mlx5_0 --dst pod2:mlx5_1 --msg-size 1048576 --num-qps 4 --iterations 5000"
    echo ""
    echo "  # JSON output for scripting"
    echo "  $0 -n my-namespace --src pod1:mlx5_0 --dst pod2:mlx5_1 --msg-size 1048576 --json"
    echo ""
    echo "  # Test with NVIDIA GPU (cuda is default)"
    echo "  $0 --src pod1:mlx5_0:0 --dst pod2:mlx5_1:1 --msg-size 1048576 --num-qps 4"
    echo ""
    echo "  # Test with AMD GPU (explicit rocm type)"
    echo "  $0 --src pod1:mlx5_0:rocm:0 --dst pod2:mlx5_1:rocm:1 --msg-size 1048576 --num-qps 4"
    echo ""
    echo "  # Test with bi-directional"
    echo "  $0 --src pod1:mlx5_0:cuda:0 --dst pod2:mlx5_1:cuda:1 --msg-size 1048576 --bi-directional"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --src)
            src_arg="$2"
            shift 2
            ;;
        --dst)
            dst_arg="$2"
            shift 2
            ;;
        --msg-size)
            msg_size="$2"
            shift 2
            ;;
        --num-qps)
            num_qps="$2"
            shift 2
            ;;
        --duration)
            duration="$2"
            shift 2
            ;;
        --iterations)
            iterations="$2"
            use_iterations=true
            iterations_set=true
            shift 2
            ;;
        --bi-directional)
            bi_directional=true
            shift
            ;;
        -n|--namespace)
            namespace="$2"
            shift 2
            ;;
        --json)
            json_output=true
            shift
            ;;
        --tos)
            tos="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$src_arg" ] || [ -z "$dst_arg" ] || [ -z "$msg_size" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    usage
fi

# Validate that duration and iterations are not both specified
if [ ! -z "$duration" ] && [ "$iterations_set" = true ]; then
    echo -e "${RED}Error: Cannot specify both --duration and --iterations${NC}"
    usage
fi

# If duration is specified, switch to duration mode
if [ ! -z "$duration" ]; then
    use_iterations=false
fi

# Function to parse endpoint argument (pod:hca or pod:hca:gpu or pod:hca:gpu_type:gpu)
# Sets: _pod, _hca, _gpu_type, _gpu_idx
parse_endpoint() {
    local arg="$1"
    local label="$2"
    
    # Split by colon
    IFS=':' read -ra parts <<< "$arg"
    local num_parts=${#parts[@]}
    
    _pod=""
    _hca=""
    _gpu_type=""
    _gpu_idx=""
    
    if [ $num_parts -lt 2 ]; then
        echo -e "${RED}Error: Invalid $label format. Expected <pod>:<hca>[:[<gpu_type>:]<gpu>]${NC}"
        return 1
    fi
    
    _pod="${parts[0]}"
    _hca="${parts[1]}"
    
    if [ $num_parts -eq 3 ]; then
        # Format: pod:hca:gpu (default to cuda)
        _gpu_type="cuda"
        _gpu_idx="${parts[2]}"
    elif [ $num_parts -eq 4 ]; then
        # Format: pod:hca:gpu_type:gpu
        _gpu_type="${parts[2]}"
        _gpu_idx="${parts[3]}"
        
        # Validate gpu_type
        if [ "$_gpu_type" != "cuda" ] && [ "$_gpu_type" != "rocm" ]; then
            echo -e "${RED}Error: Invalid GPU type '$_gpu_type' in $label. Expected 'cuda' or 'rocm'${NC}"
            return 1
        fi
    elif [ $num_parts -gt 4 ]; then
        echo -e "${RED}Error: Invalid $label format. Too many colons.${NC}"
        return 1
    fi
    
    return 0
}

# Parse source arguments
if ! parse_endpoint "$src_arg" "source"; then
    exit 1
fi
src_pod="$_pod"
src_hca="$_hca"
src_gpu_type="$_gpu_type"
src_gpu="$_gpu_idx"

# Parse destination arguments
if ! parse_endpoint "$dst_arg" "destination"; then
    exit 1
fi
dst_pod="$_pod"
dst_hca="$_hca"
dst_gpu_type="$_gpu_type"
dst_gpu="$_gpu_idx"

# Print configuration (unless JSON output mode)
if [ "$json_output" = false ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}IB Write Bandwidth Test Configuration${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Source:      ${GREEN}$src_pod${NC} (HCA: $src_hca${src_gpu:+, GPU: $src_gpu_type:$src_gpu})"
    echo -e "Destination: ${GREEN}$dst_pod${NC} (HCA: $dst_hca${dst_gpu:+, GPU: $dst_gpu_type:$dst_gpu})"
    echo -e "Message Size: ${YELLOW}$msg_size bytes${NC}"
    echo -e "Num QPs:      ${YELLOW}$num_qps${NC}"
    if [ "$use_iterations" = true ]; then
        echo -e "Iterations:   ${YELLOW}$iterations${NC}"
    else
        echo -e "Duration:     ${YELLOW}$duration seconds${NC}"
    fi
    echo -e "Bi-directional: ${YELLOW}$bi_directional${NC}"
    if [ ! -z "$tos" ]; then
        echo -e "TOS:          ${YELLOW}$tos${NC} (RDMA CM enabled)"
    fi
    echo -e "Namespace:    ${YELLOW}$namespace${NC}"
    echo ""
fi

# Function to find the network interface for a given HCA ID on a pod
find_interface_for_hca() {
    local pod=$1
    local hca_id=$2
    local ns=$3
    
    # Search for the interface that has this HCA device
    local iface=$(kubectl exec -n "$ns" "$pod" -- bash -c "
        for iface_path in /sys/class/net/*; do
            iface=\$(basename \"\$iface_path\")
            # Skip if no device link
            if [ ! -L \"\$iface_path/device\" ]; then continue; fi
            # Check for InfiniBand device
            ib_path=\"\$iface_path/device/infiniband\"
            if [ -d \"\$ib_path\" ]; then
                found_hca=\$(ls \"\$ib_path\" 2>/dev/null | head -n 1)
                if [ \"\$found_hca\" == \"$hca_id\" ]; then
                    echo \"\$iface\"
                    exit 0
                fi
            fi
        done
        exit 1
    " 2>/dev/null)
    
    echo "$iface"
}

# Function to get IP address of an interface on a pod
get_interface_ip() {
    local pod=$1
    local iface=$2
    local ns=$3
    
    # Get the IP address from the interface (using awk for portability)
    local ip=$(kubectl exec -n "$ns" "$pod" -- ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    echo "$ip"
}

# Function to get the NUMA node for a given HCA on a pod
get_numa_node_for_hca() {
    local pod=$1
    local hca_id=$2
    local ns=$3
    
    # Query the NUMA node from sysfs
    local numa_node=$(kubectl exec -n "$ns" "$pod" -- cat /sys/class/infiniband/"$hca_id"/device/numa_node 2>/dev/null)
    
    # If numa_node is -1 or empty, default to 0
    if [ -z "$numa_node" ] || [ "$numa_node" = "-1" ]; then
        numa_node="0"
    fi
    
    echo "$numa_node"
}

# Step 1: Find network interfaces for the HCAs
if [ "$json_output" = false ]; then
    echo -e "${BLUE}[1/5]${NC} Finding network interfaces for HCAs..."
fi

# Find destination interface
if [ "$json_output" = false ]; then
    echo -e "      Destination HCA ${YELLOW}$dst_hca${NC} on pod ${GREEN}$dst_pod${NC}..."
fi
dst_iface=$(find_interface_for_hca "$dst_pod" "$dst_hca" "$namespace")
find_iface_exit=$?

if [ -z "$dst_iface" ] || [ $find_iface_exit -ne 0 ]; then
    echo -e "${RED}Error: Could not find network interface for HCA '$dst_hca' on pod '$dst_pod'${NC}" >&2
    echo -e "${YELLOW}Hint: Verify the pod exists and HCA name is correct:${NC}" >&2
    echo -e "  kubectl get pod -n $namespace $dst_pod" >&2
    echo -e "  kubectl exec -n $namespace $dst_pod -- ibv_devinfo" >&2
    exit 1
fi
if [ "$json_output" = false ]; then
    echo -e "      → Found interface: ${GREEN}$dst_iface${NC}"
fi

# Find source interface (needed for RDMA CM / TOS to bind correctly)
if [ ! -z "$tos" ]; then
    if [ "$json_output" = false ]; then
        echo -e "      Source HCA ${YELLOW}$src_hca${NC} on pod ${GREEN}$src_pod${NC}..."
    fi
    src_iface=$(find_interface_for_hca "$src_pod" "$src_hca" "$namespace")
    find_iface_exit=$?

    if [ -z "$src_iface" ] || [ $find_iface_exit -ne 0 ]; then
        echo -e "${RED}Error: Could not find network interface for HCA '$src_hca' on pod '$src_pod'${NC}" >&2
        echo -e "${YELLOW}Hint: Verify the pod exists and HCA name is correct:${NC}" >&2
        echo -e "  kubectl get pod -n $namespace $src_pod" >&2
        echo -e "  kubectl exec -n $namespace $src_pod -- ibv_devinfo" >&2
        exit 1
    fi
    if [ "$json_output" = false ]; then
        echo -e "      → Found interface: ${GREEN}$src_iface${NC}"
    fi
fi

# Step 2: Get IP addresses
if [ "$json_output" = false ]; then
    echo -e "${BLUE}[2/5]${NC} Getting IP addresses..."
fi

# Get destination IP
dst_ip=$(get_interface_ip "$dst_pod" "$dst_iface" "$namespace")
if [ -z "$dst_ip" ]; then
    echo -e "${RED}Error: Could not get IP address for interface '$dst_iface' on pod '$dst_pod'${NC}" >&2
    exit 1
fi
if [ "$json_output" = false ]; then
    echo -e "      → Destination IP (${dst_iface}): ${GREEN}$dst_ip${NC}"
fi

# Get source IP (needed for RDMA CM / TOS to bind correctly)
if [ ! -z "$tos" ]; then
    src_ip=$(get_interface_ip "$src_pod" "$src_iface" "$namespace")
    if [ -z "$src_ip" ]; then
        echo -e "${RED}Error: Could not get IP address for interface '$src_iface' on pod '$src_pod'${NC}" >&2
        exit 1
    fi
    if [ "$json_output" = false ]; then
        echo -e "      → Source IP (${src_iface}): ${GREEN}$src_ip${NC}"
    fi
fi

# Step 3: Start the server on the destination pod
if [ "$json_output" = false ]; then
    echo -e "${BLUE}[3/5]${NC} Starting ib_write_bw server on destination pod ${GREEN}$dst_pod${NC}..."
fi

# Check for and kill any dangling ib_write_bw processes on the destination pod
dangling_pids=$(kubectl exec -n "$namespace" "$dst_pod" -- pgrep -x ib_write_bw 2>/dev/null || true)
if [ ! -z "$dangling_pids" ]; then
    if [ "$json_output" = false ]; then
        echo -e "      → ${YELLOW}Warning: Found dangling ib_write_bw process(es) on $dst_pod, killing...${NC}"
    fi
    kubectl exec -n "$namespace" "$dst_pod" -- pkill -x ib_write_bw 2>/dev/null || true
    sleep 1  # Give time for the process to terminate
fi

# Get NUMA node for destination HCA
dst_numa=$(get_numa_node_for_hca "$dst_pod" "$dst_hca" "$namespace")
if [ "$json_output" = false ]; then
    echo -e "      → HCA ${YELLOW}$dst_hca${NC} is on NUMA node ${YELLOW}$dst_numa${NC}"
fi

# Build server command with JSON output and NUMA binding
server_json_file="/tmp/ib_server_result_$$.json"
if [ "$use_iterations" = true ]; then
    server_cmd="numactl --cpunodebind=$dst_numa --membind=$dst_numa ib_write_bw -d $dst_hca -s $msg_size -q $num_qps -n $iterations --report_gbits --out_json --out_json_file=$server_json_file"
else
    server_cmd="numactl --cpunodebind=$dst_numa --membind=$dst_numa ib_write_bw -d $dst_hca -s $msg_size -q $num_qps -D $duration --report_gbits --out_json --out_json_file=$server_json_file"
fi
if [ ! -z "$dst_gpu" ]; then
    if [ "$dst_gpu_type" = "rocm" ]; then
        server_cmd="$server_cmd --use_rocm=$dst_gpu"
    else
        server_cmd="$server_cmd --use_cuda=$dst_gpu"
    fi
fi
if [ "$bi_directional" = true ]; then
    server_cmd="$server_cmd -b --report-both"
fi
if [ ! -z "$tos" ]; then
    server_cmd="$server_cmd -R --tos=$tos"
fi

# Start server in background and capture output
server_log="/tmp/ib_server_$$.log"
if [ "$json_output" = false ]; then
    echo -e "      → Command: ${YELLOW}$server_cmd${NC}"
fi
kubectl exec -n "$namespace" "$dst_pod" -- bash -c "$server_cmd" > "$server_log" 2>&1 &
server_pid=$!

# Wait a bit for server to start and listen
sleep 2

# Check if server is still running
if ! ps -p $server_pid > /dev/null 2>&1; then
    echo -e "${RED}Error: Server failed to start or exited immediately${NC}" >&2
    echo -e "${RED}Server log output:${NC}" >&2
    cat "$server_log" >&2
    rm -f "$server_log"
    exit 1
fi
if [ "$json_output" = false ]; then
    echo -e "      → ${GREEN}Server started successfully${NC}"
fi

# Step 4: Start the client on the source pod
if [ "$json_output" = false ]; then
    echo -e "${BLUE}[4/5]${NC} Starting ib_write_bw client on source pod ${GREEN}$src_pod${NC}..."
fi

# Check for and kill any dangling ib_write_bw processes on the source pod
dangling_pids=$(kubectl exec -n "$namespace" "$src_pod" -- pgrep -x ib_write_bw 2>/dev/null || true)
if [ ! -z "$dangling_pids" ]; then
    if [ "$json_output" = false ]; then
        echo -e "      → ${YELLOW}Warning: Found dangling ib_write_bw process(es) on $src_pod, killing...${NC}"
    fi
    kubectl exec -n "$namespace" "$src_pod" -- pkill -x ib_write_bw 2>/dev/null || true
    sleep 1  # Give time for the process to terminate
fi

# Get NUMA node for source HCA
src_numa=$(get_numa_node_for_hca "$src_pod" "$src_hca" "$namespace")
if [ "$json_output" = false ]; then
    echo -e "      → HCA ${YELLOW}$src_hca${NC} is on NUMA node ${YELLOW}$src_numa${NC}"
fi

# Build client command with JSON output and NUMA binding
client_json_file="/tmp/ib_client_result_$$.json"
if [ "$use_iterations" = true ]; then
    client_cmd="numactl --cpunodebind=$src_numa --membind=$src_numa ib_write_bw -d $src_hca -s $msg_size -q $num_qps -n $iterations --report_gbits --out_json --out_json_file=$client_json_file"
else
    client_cmd="numactl --cpunodebind=$src_numa --membind=$src_numa ib_write_bw -d $src_hca -s $msg_size -q $num_qps -D $duration --report_gbits --out_json --out_json_file=$client_json_file"
fi
if [ ! -z "$src_gpu" ]; then
    if [ "$src_gpu_type" = "rocm" ]; then
        client_cmd="$client_cmd --use_rocm=$src_gpu"
    else
        client_cmd="$client_cmd --use_cuda=$src_gpu"
    fi
fi
if [ "$bi_directional" = true ]; then
    client_cmd="$client_cmd -b --report-both"
fi
if [ ! -z "$tos" ]; then
    client_cmd="$client_cmd -R --tos=$tos --bind_source_ip=$src_ip"
fi
client_cmd="$client_cmd $dst_ip"

if [ "$json_output" = false ]; then
    echo -e "      → Command: ${YELLOW}$client_cmd${NC}"
    if [ "$use_iterations" = true ]; then
        echo -e "      → Running test for ${YELLOW}$iterations${NC} iterations..."
    else
        echo -e "      → Running test for ${YELLOW}$duration${NC} seconds..."
    fi
fi

# Run client and capture output
# Use a subshell to ensure we capture the exit code properly
client_output=$(kubectl exec -n "$namespace" "$src_pod" -- bash -c "$client_cmd" 2>&1) || client_exit=$?
client_exit=${client_exit:-0}

# Wait for server to finish
wait $server_pid 2>/dev/null || true
rm -f "$server_log"

if [ $client_exit -ne 0 ]; then
    echo -e "${RED}Error: Client test failed (exit code: $client_exit)${NC}" >&2
    echo -e "${RED}Client output:${NC}" >&2
    echo "$client_output" >&2
    exit 1
fi

# Additional check: if client_output is empty, something may have gone wrong
if [ -z "$client_output" ]; then
    echo -e "${YELLOW}Warning: Client produced no output${NC}" >&2
fi

# Retrieve the JSON results from the client pod
client_json=""
client_json_exit=0
client_json=$(kubectl exec -n "$namespace" "$src_pod" -- cat "$client_json_file" 2>&1) || client_json_exit=$?

if [ $client_json_exit -ne 0 ] || [ -z "$client_json" ]; then
    echo -e "${RED}Error: Could not retrieve client JSON results from $client_json_file${NC}" >&2
    if [ $client_json_exit -ne 0 ]; then
        echo -e "${RED}kubectl exit code: $client_json_exit${NC}" >&2
        echo -e "${RED}kubectl output: $client_json${NC}" >&2
    fi
    echo -e "${YELLOW}Client command output was:${NC}" >&2
    echo "$client_output" >&2
    exit 1
fi

# Clean up JSON file on client pod
kubectl exec -n "$namespace" "$src_pod" -- rm -f "$client_json_file" 2>/dev/null || true

# For bi-directional tests, also retrieve the server JSON
if [ "$bi_directional" = true ]; then
    server_json=$(kubectl exec -n "$namespace" "$dst_pod" -- cat "$server_json_file" 2>/dev/null)
    if [ -z "$server_json" ] && [ "$json_output" = false ]; then
        echo -e "${YELLOW}Warning: Could not retrieve server JSON results${NC}"
    fi
    # Clean up JSON file on server pod
    kubectl exec -n "$namespace" "$dst_pod" -- rm -f "$server_json_file" 2>/dev/null || true
fi

# JSON output mode - just print the raw JSON and exit
if [ "$json_output" = true ]; then
    if [ "$bi_directional" = true ]; then
        # Combine client and server JSON into one object
        if command -v jq &> /dev/null; then
            jq -n \
                --argjson client "$client_json" \
                --argjson server "${server_json:-null}" \
                '{
                    "mode": "bi-directional",
                    "use_iterations": '$use_iterations',
                    "client_to_server": $client,
                    "server_to_client": $server
                }'
        else
            # Fallback without jq
            echo '{"mode":"bi-directional","use_iterations":'$use_iterations',"client_to_server":'$client_json',"server_to_client":'${server_json:-null}'}'
        fi
    else
        # Add metadata to the client JSON
        if command -v jq &> /dev/null; then
            echo "$client_json" | jq --arg mode "uni-directional" --argjson iter "$use_iterations" '. + {mode: $mode, use_iterations: $iter}'
        else
            # Fallback - just output the raw JSON
            echo "$client_json"
        fi
    fi
    exit 0
fi

# Step 5: Parse and display results from JSON
echo -e "${BLUE}[5/5]${NC} Parsing results..."
echo ""

# Check if jq is available for JSON parsing
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: jq not found, using basic parsing${NC}"
    # Fallback to grep/awk parsing
    USE_JQ=false
else
    USE_JQ=true
fi

if [ "$bi_directional" = true ]; then
    # In bi-directional mode:
    # - Client JSON contains client → server bandwidth
    # - Server JSON contains server → client bandwidth
    
    if [ "$USE_JQ" = true ]; then
        # Parse client results (client → server)
        client_bw_peak=$(echo "$client_json" | jq -r '.results.BW_peak' 2>/dev/null)
        client_bw_avg=$(echo "$client_json" | jq -r '.results.BW_average' 2>/dev/null)
        
        # Parse server results (server → client)
        if [ ! -z "$server_json" ]; then
            server_bw_peak=$(echo "$server_json" | jq -r '.results.BW_peak' 2>/dev/null)
            server_bw_avg=$(echo "$server_json" | jq -r '.results.BW_average' 2>/dev/null)
        fi
    else
        # Fallback: extract from JSON manually
        client_bw_peak=$(echo "$client_json" | grep -o '"BW_peak"[^,]*' | grep -o '[0-9.]\+' | head -1)
        client_bw_avg=$(echo "$client_json" | grep -o '"BW_average"[^,]*' | grep -o '[0-9.]\+' | head -1)
        
        if [ ! -z "$server_json" ]; then
            server_bw_peak=$(echo "$server_json" | grep -o '"BW_peak"[^,]*' | grep -o '[0-9.]\+' | head -1)
            server_bw_avg=$(echo "$server_json" | grep -o '"BW_average"[^,]*' | grep -o '[0-9.]\+' | head -1)
        fi
    fi
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Test Results (Bi-directional)${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    if [ ! -z "$client_bw_avg" ] && [ "$client_bw_avg" != "null" ]; then
        echo -e "${BLUE}Client → Server (${src_pod} → ${dst_pod}):${NC}"
        if [ "$use_iterations" = true ]; then
            echo -e "  Peak Bandwidth:    ${YELLOW}$client_bw_peak Gbps${NC}"
        fi
        echo -e "  Average Bandwidth: ${YELLOW}$client_bw_avg Gbps${NC}"
    else
        echo -e "${RED}Warning: Could not parse client → server bandwidth${NC}"
    fi
    
    echo ""
    
    if [ ! -z "$server_bw_avg" ] && [ "$server_bw_avg" != "null" ]; then
        echo -e "${BLUE}Server → Client (${dst_pod} → ${src_pod}):${NC}"
        if [ "$use_iterations" = true ]; then
            echo -e "  Peak Bandwidth:    ${YELLOW}$server_bw_peak Gbps${NC}"
        fi
        echo -e "  Average Bandwidth: ${YELLOW}$server_bw_avg Gbps${NC}"
    else
        echo -e "${RED}Warning: Could not parse server → client bandwidth${NC}"
    fi
    
    if [ "${DEBUG}" = "1" ]; then
        echo ""
        echo -e "${BLUE}Client JSON:${NC}"
        echo "$client_json"
        echo ""
        echo -e "${BLUE}Server JSON:${NC}"
        echo "$server_json"
    fi
else
    # In uni-directional mode, parse results from JSON
    if [ "$USE_JQ" = true ]; then
        # Parse using jq
        bw_peak=$(echo "$client_json" | jq -r '.results.BW_peak' 2>/dev/null)
        bw_avg=$(echo "$client_json" | jq -r '.results.BW_average' 2>/dev/null)
    else
        # Fallback: extract from JSON manually
        bw_peak=$(echo "$client_json" | grep -o '"BW_peak"[^,]*' | grep -o '[0-9.]\+' | head -1)
        bw_avg=$(echo "$client_json" | grep -o '"BW_average"[^,]*' | grep -o '[0-9.]\+' | head -1)
    fi
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Test Results${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    if [ ! -z "$bw_avg" ] && [ "$bw_avg" != "null" ]; then
        if [ "$use_iterations" = true ] && [ ! -z "$bw_peak" ] && [ "$bw_peak" != "null" ]; then
            echo -e "Peak Bandwidth:    ${YELLOW}$bw_peak Gbps${NC}"
        fi
        echo -e "Average Bandwidth: ${YELLOW}$bw_avg Gbps${NC}"
    else
        echo -e "${RED}Warning: Could not parse bandwidth from JSON${NC}"
        if [ "${DEBUG}" = "1" ]; then
            echo ""
            echo "JSON output:"
            echo "$client_json"
        fi
    fi
fi

echo ""
echo -e "${GREEN}✓ Test completed successfully${NC}"
echo ""

# Show full output if needed for debugging
if [ "${DEBUG}" = "1" ]; then
    echo -e "${BLUE}Full client output:${NC}"
    echo "$client_output"
fi

