#!/bin/bash

# Periodic IB Write Bandwidth Test
# Runs ib_write_bw test multiple times for various message sizes and logs results

set -e

# Default values
namespace="default"
src_arg=""
dst_arg=""
num_runs=100
num_iterations=5000
num_qps=1
output_file="ib_write_periodic.csv"
sleep_interval=1

# Message sizes to test (8 KiB and above)
MSG_SIZES=(
    8192        # 8 KiB
    16384       # 16 KiB
    32768       # 32 KiB
    65536       # 64 KiB
    131072      # 128 KiB
    262144      # 256 KiB
    524288      # 512 KiB
    1048576     # 1 MiB
    2097152     # 2 MiB
    4194304     # 4 MiB
    8388608     # 8 MiB
    16777216    # 16 MiB
    33554432    # 32 MiB
    67108864    # 64 MiB
)

usage() {
    echo "Usage: $0 --src <pod>:<hca> --dst <pod>:<hca> [options]"
    echo ""
    echo "Runs ib_write_bw tests multiple times for various message sizes (8KiB - 64MiB)"
    echo "and logs MsgSize, BW_average, BW_peak to a CSV file."
    echo ""
    echo "Required Arguments:"
    echo "  --src <pod>:<hca>          Source pod name and HCA ID (e.g., pod1:mlx5_0)"
    echo "  --dst <pod>:<hca>          Destination pod name and HCA ID"
    echo ""
    echo "Optional Arguments:"
    echo "  --namespace <ns>           Kubernetes namespace (default: default)"
    echo "  --num-runs <n>             Number of test runs per message size (default: 100)"
    echo "  --num-iterations <n>       Iterations per ib_write_bw run (default: 5000)"
    echo "  --num-qps <n>              Number of queue pairs (default: 1)"
    echo "  --output <file>            Output CSV file (default: ib_write_periodic.csv)"
    echo "  --sleep <sec>              Sleep interval between runs in seconds (default: 1)"
    echo ""
    echo "Example:"
    echo "  $0 --namespace raj-network-debug \\"
    echo "     --src networking-debug-pod-10.0.65.77:mlx5_0 \\"
    echo "     --dst networking-debug-pod-10.0.66.42:mlx5_0 \\"
    echo "     --num-runs 100 --output results.csv"
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
        --namespace)
            namespace="$2"
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
if [ -z "$src_arg" ] || [ -z "$dst_arg" ]; then
    echo "Error: --src and --dst are required"
    usage
fi

# Parse pod names from arguments (format: pod:hca)
src_pod="${src_arg%%:*}"
dst_pod="${dst_arg%%:*}"

# Kill any dangling ib_write_bw processes on destination pod
echo "Checking for dangling ib_write_bw processes on destination pod..."
dangling_pids=$(kubectl exec -n "$namespace" "$dst_pod" -- pgrep -f ib_write_bw 2>/dev/null || true)
if [ ! -z "$dangling_pids" ]; then
    echo "Found dangling ib_write_bw processes: $dangling_pids"
    echo "Killing dangling processes..."
    kubectl exec -n "$namespace" "$dst_pod" -- pkill -9 -f ib_write_bw 2>/dev/null || true
    sleep 1
    echo "Done."
else
    echo "No dangling processes found."
fi
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if single_nic_ib_write_bw.sh exists
if [ ! -f "$SCRIPT_DIR/single_nic_ib_write_bw.sh" ]; then
    echo "Error: single_nic_ib_write_bw.sh not found in $SCRIPT_DIR"
    exit 1
fi

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

# Calculate total tests
total_tests=$((${#MSG_SIZES[@]} * num_runs))

# Print configuration (piped through cat to force flush)
cat <<EOF
========================================
Periodic IB Write Bandwidth Test
========================================
Source:          $src_arg
Destination:     $dst_arg
Namespace:       $namespace
Runs per size:   $num_runs
Iterations:      $num_iterations
Num QPs:         $num_qps
Output file:     $output_file
Sleep interval:  ${sleep_interval}s
Message sizes:   ${#MSG_SIZES[@]} (8 KiB to 64 MiB)

Total tests to run: $total_tests

EOF

# Initialize output file with header if it doesn't exist or is empty
if [ ! -s "$output_file" ]; then
    echo "MsgSize,BW_average,BW_peak" > "$output_file"
    echo "Created output file: $output_file"
fi

# Track overall progress
completed=0
start_time=$(date +%s)

# Loop through each message size
for msg_size in "${MSG_SIZES[@]}"; do
    human_size=$(bytes_to_human $msg_size)
    echo ""
    echo "========================================"
    echo "Testing message size: $msg_size bytes ($human_size)"
    echo "========================================"
    
    # Run tests for this message size
    for run in $(seq 1 $num_runs); do
        # Run the test and extract results (|| true prevents set -e from exiting on failure)
        result=$("$SCRIPT_DIR/single_nic_ib_write_bw.sh" \
            --namespace "$namespace" \
            --src "$src_arg" \
            --dst "$dst_arg" \
            --msg-size "$msg_size" \
            --num-qps "$num_qps" \
            --iterations "$num_iterations" \
            --json 2>/dev/null) || true
        
        if [ ! -z "$result" ]; then
            # Parse JSON and append to CSV
            csv_line=$(echo "$result" | jq -r '[.results.MsgSize, .results.BW_average, .results.BW_peak] | @csv' 2>/dev/null) || true
            if [ ! -z "$csv_line" ]; then
                echo "$csv_line" >> "$output_file"
            else
                echo "Warning: Failed to parse JSON for run $run of $human_size"
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
                stdbuf -oL printf "\r  Progress: %d/%d for %s | Total: %d/%d (%.1f tests/sec, ETA: %ss)    " \
                    "$run" "$num_runs" "$human_size" "$completed" "$total_tests" "$rate" "$eta"
            fi
        fi
        
        # Sleep between runs
        sleep "$sleep_interval"
    done
    
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
