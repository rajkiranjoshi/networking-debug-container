#!/bin/bash

# Periodic Multi-NIC IB Write Bandwidth Test
# Runs multi_nic_ib_write_bw.py test multiple times for various message sizes and logs results

set -e

# Default values
template_json=""
num_runs=20
num_iterations=5000
num_qps=4
output_file="multi_nic_bw_periodic.csv"
sleep_interval=1

# Message sizes to test (4 MiB to 64 MiB)
MSG_SIZES=(
    4194304     # 4 MiB
    8388608     # 8 MiB
    16777216    # 16 MiB
    33554432    # 32 MiB
    67108864    # 64 MiB
)

usage() {
    echo "Usage: $0 --template <json-file> [options]"
    echo ""
    echo "Runs multi_nic_ib_write_bw.py tests multiple times for various message sizes"
    echo "(4 MiB - 64 MiB) and logs results to a CSV file."
    echo ""
    echo "Required Arguments:"
    echo "  --template <json-file>       Template NIC pairs JSON file (e.g., 8nic-pairs_4MiB_4qp.json)"
    echo ""
    echo "Optional Arguments:"
    echo "  --num-runs <n>               Number of test runs per message size (default: 20)"
    echo "  --num-iterations <n>         Iterations per ib_write_bw run (default: 5000)"
    echo "  --num-qps <n>                Number of queue pairs (default: 4)"
    echo "  --output <file>              Output CSV file (default: multi_nic_bw_periodic.csv)"
    echo "  --sleep <sec>                Sleep interval between runs in seconds (default: 1)"
    echo ""
    echo "Example:"
    echo "  $0 --template 8nic-pairs_4MiB_4qp.json \\"
    echo "     --num-runs 100 --output results.csv"
    echo ""
    echo "CSV Output Format:"
    echo "  MsgSize,Total_BW_avg,Per_NIC_BW_avg,NIC0_BW_avg,NIC0_BW_peak,NIC1_BW_avg,NIC1_BW_peak,..."
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --template)
            template_json="$2"
            shift 2
            ;;
        --num-runs)
            num_runs="$2"
            shift 2
            ;;
        --num-iterations)
            num_iterations="$2"
            shift 2
            ;;
        --num-qps)
            num_qps="$2"
            shift 2
            ;;
        --output)
            output_file="$2"
            shift 2
            ;;
        --sleep)
            sleep_interval="$2"
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
if [ -z "$template_json" ]; then
    echo "Error: --template is required"
    usage
fi

if [ ! -f "$template_json" ]; then
    echo "Error: Template file not found: $template_json"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if multi_nic_ib_write_bw.py exists
if [ ! -f "$SCRIPT_DIR/multi_nic_ib_write_bw.py" ]; then
    echo "Error: multi_nic_ib_write_bw.py not found in $SCRIPT_DIR"
    exit 1
fi

# Check for required tools
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

# Extract namespace from template for cleanup
namespace=$(jq -r '.namespace' "$template_json")

# Get number of NICs from template
num_nics=$(jq '.test_pairs | length' "$template_json")

# Extract destination pods for cleanup
dst_pods=$(jq -r '[.test_pairs[].dst_pod] | unique | .[]' "$template_json")

# Function to convert bytes to human-readable format
bytes_to_human() {
    local bytes=$1
    if [ $bytes -ge 1073741824 ]; then
        echo "$(echo "scale=0; $bytes / 1073741824" | bc) GiB"
    elif [ $bytes -ge 1048576 ]; then
        echo "$(echo "scale=0; $bytes / 1048576" | bc) MiB"
    elif [ $bytes -ge 1024 ]; then
        echo "$(echo "scale=0; $bytes / 1024" | bc) KiB"
    else
        echo "$bytes B"
    fi
}

# Function to create temporary config JSON with specified msg_size
create_temp_config() {
    local msg_size=$1
    local temp_file=$(mktemp /tmp/multi_nic_config_XXXXXX.json)
    
    # Update msg_size, num_qps, and num_iters in the template
    jq --arg ms "$msg_size" --arg qps "$num_qps" --arg iters "$num_iterations" \
        '.msg_size = ($ms | tonumber) | .num_qps = ($qps | tonumber) | .num_iters = ($iters | tonumber) | del(.duration)' \
        "$template_json" > "$temp_file"
    
    echo "$temp_file"
}

# Function to parse JSON output and create CSV row
parse_json_to_csv() {
    local json_output=$1
    local msg_size=$2
    
    # Extract summary values
    local total_avg=$(echo "$json_output" | jq -r '.summary.total_avg_bw_gbps')
    local per_nic_avg=$(echo "$json_output" | jq -r '.summary.per_nic_avg_bw_gbps')
    
    # Start CSV row with summary values
    local csv_row="$msg_size,$total_avg,$per_nic_avg"
    
    # Extract per-NIC values (sorted by pair_idx)
    local nic_values=$(echo "$json_output" | jq -r '
        .results | sort_by(.pair_idx) | .[] | 
        [.bw_avg_gbps, (.bw_peak_gbps // "null")] | @csv
    ' | tr -d '"')
    
    # Append NIC values to CSV row
    for nic_data in $nic_values; do
        csv_row="$csv_row,$nic_data"
    done
    
    echo "$csv_row"
}

# Generate CSV header dynamically based on number of NICs
generate_csv_header() {
    local header="MsgSize,Total_BW_avg,Per_NIC_BW_avg"
    for ((i=0; i<num_nics; i++)); do
        header="$header,NIC${i}_BW_avg,NIC${i}_BW_peak"
    done
    echo "$header"
}

# Kill any dangling ib_write_bw processes on destination pods
echo "Checking for dangling ib_write_bw processes on destination pods..."
for dst_pod in $dst_pods; do
    dangling_pids=$(kubectl exec -n "$namespace" "$dst_pod" -- pgrep -f ib_write_bw 2>/dev/null || true)
    if [ ! -z "$dangling_pids" ]; then
        echo "  Found dangling processes on $dst_pod: $dangling_pids"
        echo "  Killing dangling processes..."
        kubectl exec -n "$namespace" "$dst_pod" -- pkill -9 -f ib_write_bw 2>/dev/null || true
        sleep 1
    fi
done
echo "Done."
echo ""

# Calculate total tests
total_tests=$((${#MSG_SIZES[@]} * num_runs))

# Print configuration
cat <<EOF
========================================
Periodic Multi-NIC IB Write Bandwidth Test
========================================
Template:        $template_json
Namespace:       $namespace
Number of NICs:  $num_nics
Runs per size:   $num_runs
Iterations:      $num_iterations
Num QPs:         $num_qps
Output file:     $output_file
Sleep interval:  ${sleep_interval}s
Message sizes:   ${#MSG_SIZES[@]} (4 MiB to 64 MiB)

Total tests to run: $total_tests

EOF

# Initialize output file with header if it doesn't exist or is empty
if [ ! -s "$output_file" ]; then
    generate_csv_header > "$output_file"
    echo "Created output file: $output_file"
fi

# Track overall progress
completed=0
start_time=$(date +%s)

# Cleanup function
cleanup() {
    # Remove any temp config files
    rm -f /tmp/multi_nic_config_*.json 2>/dev/null || true
    echo ""
    echo "Cleanup complete."
}

# Set trap for cleanup on exit
trap cleanup EXIT

# Loop through each message size
for msg_size in "${MSG_SIZES[@]}"; do
    human_size=$(bytes_to_human $msg_size)
    echo ""
    echo "========================================"
    echo "Testing message size: $msg_size bytes ($human_size)"
    echo "========================================"
    
    # Create temp config with this message size
    temp_config=$(create_temp_config $msg_size)
    
    # Run tests for this message size
    for run in $(seq 1 $num_runs); do
        # Run the test with --json option
        result=$(cd "$SCRIPT_DIR" && uv run ./multi_nic_ib_write_bw.py --json "$temp_config" 2>/dev/null) || true
        
        if [ ! -z "$result" ]; then
            # Check if test was successful
            successful=$(echo "$result" | jq -r '.summary.successful // 0')
            total_pairs=$(echo "$result" | jq -r '.summary.total_pairs // 0')
            
            if [ "$successful" -eq "$total_pairs" ] && [ "$total_pairs" -gt 0 ]; then
                # Parse JSON and append to CSV
                csv_line=$(parse_json_to_csv "$result" "$msg_size")
                if [ ! -z "$csv_line" ]; then
                    echo "$csv_line" >> "$output_file"
                else
                    echo "Warning: Failed to parse JSON for run $run of $human_size"
                fi
            else
                echo "Warning: Test had failures ($successful/$total_pairs successful) for run $run of $human_size"
            fi
        else
            echo "Warning: Test failed for run $run of $human_size"
        fi
        
        # Update progress
        completed=$((completed + 1))
        
        # Print progress every 10 runs or at the end
        if [ $((run % 10)) -eq 0 ] || [ $run -eq $num_runs ]; then
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))
            if [ $completed -gt 0 ] && [ $elapsed -gt 0 ]; then
                rate=$(echo "scale=2; $completed / $elapsed" | bc)
                remaining=$((total_tests - completed))
                eta=$(echo "scale=0; $remaining / $rate" | bc 2>/dev/null || echo "?")
                # Use stdbuf to force line buffering for printf with \r
                stdbuf -oL printf "\r  Progress: %d/%d for %s | Total: %d/%d (%.2f tests/sec, ETA: %ss)    " \
                    "$run" "$num_runs" "$human_size" "$completed" "$total_tests" "$rate" "$eta"
            fi
        fi
        
        # Sleep between runs
        sleep "$sleep_interval"
    done
    
    # Clean up temp config for this message size
    rm -f "$temp_config"
    
    echo ""
    echo "  Completed $num_runs runs for $human_size"
done

# Final summary
end_time=$(date +%s)
total_elapsed=$((end_time - start_time))

echo ""
echo "========================================"
echo "Test Complete!"
echo "========================================"
echo "Total tests:     $completed"
echo "Total time:      ${total_elapsed}s ($(echo "scale=1; $total_elapsed / 60" | bc) min)"
echo "Results saved:   $output_file"
echo ""
