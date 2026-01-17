#!/bin/bash

set -e  # Exit on error

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
use_iterations=false

# Function to print usage
usage() {
    echo "Usage: $0 --src <pod>:<hca>[:<gpu>] --dst <pod>:<hca>[:<gpu>] --msg-size <size> --num-qps <n> (--duration <sec> | --iterations <n>) [options]"
    echo ""
    echo "Arguments:"
    echo "  --src <pod>:<hca>[:<gpu>]      Source pod name, HCA ID (e.g., mlx5_0), and optional GPU index"
    echo "  --dst <pod>:<hca>[:<gpu>]      Destination pod name, HCA ID, and optional GPU index"
    echo "  --msg-size <size>              Message size in bytes (e.g., 65536, 1048576)"
    echo "  --num-qps <n>                  Number of queue pairs"
    echo "  --duration <sec>               Test duration in seconds (mutually exclusive with --iterations)"
    echo "  --iterations <n>               Number of iterations (mutually exclusive with --duration)"
    echo "                                 Note: iterations mode also measures peak bandwidth"
    echo "  --bi-directional               Enable bi-directional bandwidth test (optional)"
    echo "  --namespace <ns>               Kubernetes namespace (default: default)"
    echo "  --json                         Output results as parsable JSON (suppresses human-readable output)"
    echo ""
    echo "Examples:"
    echo "  # Duration-based test (measures average bandwidth)"
    echo "  $0 --src pod1:mlx5_0 --dst pod2:mlx5_1 --msg-size 65536 --num-qps 1 --duration 10"
    echo ""
    echo "  # Iteration-based test (measures peak and average bandwidth)"
    echo "  $0 --src pod1:mlx5_0 --dst pod2:mlx5_1 --msg-size 1048576 --num-qps 4 --iterations 5000"
    echo ""
    echo "  # JSON output for scripting"
    echo "  $0 --src pod1:mlx5_0 --dst pod2:mlx5_1 --msg-size 1048576 --num-qps 4 --iterations 5000 --json"
    echo ""
    echo "  # Test with GPU and bi-directional"
    echo "  $0 --src pod1:mlx5_0:0 --dst pod2:mlx5_1:1 --msg-size 1048576 --num-qps 4 --duration 30 --bi-directional"
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
            shift 2
            ;;
        --bi-directional)
            bi_directional=true
            shift
            ;;
        --namespace)
            namespace="$2"
            shift 2
            ;;
        --json)
            json_output=true
            shift
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
if [ -z "$src_arg" ] || [ -z "$dst_arg" ] || [ -z "$msg_size" ] || [ -z "$num_qps" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    usage
fi

# Validate that either duration or iterations is specified (but not both)
if [ -z "$duration" ] && [ -z "$iterations" ]; then
    echo -e "${RED}Error: Either --duration or --iterations must be specified${NC}"
    usage
fi

if [ ! -z "$duration" ] && [ ! -z "$iterations" ]; then
    echo -e "${RED}Error: Cannot specify both --duration and --iterations${NC}"
    usage
fi

# Parse source arguments (pod:hca:gpu or pod:hca)
IFS=':' read -r src_pod src_hca src_gpu <<< "$src_arg"
if [ -z "$src_pod" ] || [ -z "$src_hca" ]; then
    echo -e "${RED}Error: Invalid source format. Expected <pod>:<hca>[:<gpu>]${NC}"
    exit 1
fi

# Parse destination arguments (pod:hca:gpu or pod:hca)
IFS=':' read -r dst_pod dst_hca dst_gpu <<< "$dst_arg"
if [ -z "$dst_pod" ] || [ -z "$dst_hca" ]; then
    echo -e "${RED}Error: Invalid destination format. Expected <pod>:<hca>[:<gpu>]${NC}"
    exit 1
fi

# Print configuration (unless JSON output mode)
if [ "$json_output" = false ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}IB Write Bandwidth Test Configuration${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Source:      ${GREEN}$src_pod${NC} (HCA: $src_hca${src_gpu:+, GPU: $src_gpu})"
    echo -e "Destination: ${GREEN}$dst_pod${NC} (HCA: $dst_hca${dst_gpu:+, GPU: $dst_gpu})"
    echo -e "Message Size: ${YELLOW}$msg_size bytes${NC}"
    echo -e "Num QPs:      ${YELLOW}$num_qps${NC}"
    if [ "$use_iterations" = true ]; then
        echo -e "Iterations:   ${YELLOW}$iterations${NC}"
    else
        echo -e "Duration:     ${YELLOW}$duration seconds${NC}"
    fi
    echo -e "Bi-directional: ${YELLOW}$bi_directional${NC}"
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

# Step 1: Find the network interface for the destination HCA
if [ "$json_output" = false ]; then
    echo -e "${BLUE}[1/5]${NC} Finding network interface for destination HCA ${YELLOW}$dst_hca${NC} on pod ${GREEN}$dst_pod${NC}..."
fi
dst_iface=$(find_interface_for_hca "$dst_pod" "$dst_hca" "$namespace")

if [ -z "$dst_iface" ]; then
    echo -e "${RED}Error: Could not find network interface for HCA '$dst_hca' on pod '$dst_pod'${NC}" >&2
    exit 1
fi
if [ "$json_output" = false ]; then
    echo -e "      → Found interface: ${GREEN}$dst_iface${NC}"
fi

# Step 2: Get the IP address of the destination interface
if [ "$json_output" = false ]; then
    echo -e "${BLUE}[2/5]${NC} Getting IP address of interface ${YELLOW}$dst_iface${NC}..."
fi
dst_ip=$(get_interface_ip "$dst_pod" "$dst_iface" "$namespace")

if [ -z "$dst_ip" ]; then
    echo -e "${RED}Error: Could not get IP address for interface '$dst_iface' on pod '$dst_pod'${NC}" >&2
    exit 1
fi
if [ "$json_output" = false ]; then
    echo -e "      → Destination IP: ${GREEN}$dst_ip${NC}"
fi

# Step 3: Start the server on the destination pod
if [ "$json_output" = false ]; then
    echo -e "${BLUE}[3/5]${NC} Starting ib_write_bw server on destination pod ${GREEN}$dst_pod${NC}..."
fi

# Build server command with JSON output
server_json_file="/tmp/ib_server_result_$$.json"
if [ "$use_iterations" = true ]; then
    server_cmd="ib_write_bw -d $dst_hca -s $msg_size -q $num_qps -n $iterations --report_gbits --out_json --out_json_file=$server_json_file"
else
    server_cmd="ib_write_bw -d $dst_hca -s $msg_size -q $num_qps -D $duration --report_gbits --out_json --out_json_file=$server_json_file"
fi
if [ ! -z "$dst_gpu" ]; then
    server_cmd="$server_cmd --use_cuda=$dst_gpu"
fi
if [ "$bi_directional" = true ]; then
    server_cmd="$server_cmd -b --report-both"
fi

# Start server in background and capture output
server_log="/tmp/ib_server_$$.log"
if [ "$json_output" = false ]; then
    echo -e "      → Command: ${YELLOW}$server_cmd${NC}"
fi
kubectl exec -n "$namespace" "$dst_pod" -- bash -c "$server_cmd" > "$server_log" 2>&1 &
server_pid=$!

# Wait a bit for server to start
sleep 2

# Check if server is still running
if ! ps -p $server_pid > /dev/null 2>&1; then
    echo -e "${RED}Error: Server failed to start. Check logs:${NC}" >&2
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

# Build client command with JSON output
client_json_file="/tmp/ib_client_result_$$.json"
if [ "$use_iterations" = true ]; then
    client_cmd="ib_write_bw -d $src_hca -s $msg_size -q $num_qps -n $iterations --report_gbits --out_json --out_json_file=$client_json_file"
else
    client_cmd="ib_write_bw -d $src_hca -s $msg_size -q $num_qps -D $duration --report_gbits --out_json --out_json_file=$client_json_file"
fi
if [ ! -z "$src_gpu" ]; then
    client_cmd="$client_cmd --use_cuda=$src_gpu"
fi
if [ "$bi_directional" = true ]; then
    client_cmd="$client_cmd -b --report-both"
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
client_output=$(kubectl exec -n "$namespace" "$src_pod" -- bash -c "$client_cmd" 2>&1)
client_exit=$?

# Wait for server to finish
wait $server_pid 2>/dev/null || true
rm -f "$server_log"

if [ $client_exit -ne 0 ]; then
    echo -e "${RED}Error: Client test failed${NC}" >&2
    echo "$client_output" >&2
    exit 1
fi

# Retrieve the JSON results from the client pod
client_json=$(kubectl exec -n "$namespace" "$src_pod" -- cat "$client_json_file" 2>/dev/null)
if [ -z "$client_json" ]; then
    echo -e "${RED}Error: Could not retrieve client JSON results${NC}" >&2
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

