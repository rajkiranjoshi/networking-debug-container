#!/usr/bin/env python3
"""
Multi-NIC IB Write Bandwidth Test

Runs ib_write_bw tests across multiple src-dst pairs simultaneously to measure
aggregate RDMA throughput across multiple NICs.

Usage:
    uv run ./multi_nic_ib_write_bw.py multi_nic_info.json
    uv run ./multi_nic_ib_write_bw.py --json multi_nic_info.json
"""

import argparse
import json
import subprocess
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from typing import Optional

from rich.console import Console
from rich.table import Table
from rich.text import Text


BASE_PORT = 18515  # Default ib_write_bw port


@dataclass
class TestPair:
    """Configuration for a single src-dst test pair."""
    src_pod: str
    src_hca: str
    src_gpu: Optional[str] = None
    src_gpu_type: str = "cuda"  # "cuda" or "rocm"
    dst_pod: str = ""
    dst_hca: str = ""
    dst_gpu: Optional[str] = None
    dst_gpu_type: str = "cuda"  # "cuda" or "rocm"
    # Discovered at runtime
    src_iface: str = ""  # Source interface (needed for RDMA CM / TOS)
    src_ip: str = ""     # Source IP (needed for RDMA CM / TOS to bind correctly)
    dst_iface: str = ""
    dst_ip: str = ""
    port: int = BASE_PORT  # Port for this test (unique per dst_pod)
    # NUMA nodes for CPU/memory binding
    src_numa: int = 0
    dst_numa: int = 0


@dataclass
class TestResult:
    """Result from a single ib_write_bw test."""
    pair_idx: int
    src_pod: str
    src_hca: str
    dst_pod: str
    dst_hca: str
    bw_avg_gbps: float = 0.0
    bw_peak_gbps: Optional[float] = None  # Only populated when using num_iters
    # For bi-directional tests
    reverse_bw_avg_gbps: float = 0.0
    reverse_bw_peak_gbps: Optional[float] = None
    success: bool = False
    error_msg: str = ""


def run_kubectl_command(namespace: str, pod: str, command: str, timeout: int = 60) -> tuple[bool, str]:
    """Execute a command inside a Kubernetes pod."""
    kubectl_cmd = [
        "kubectl", "exec", "-n", namespace, pod, "--",
        "/bin/bash", "-c", command
    ]
    
    try:
        result = subprocess.run(
            kubectl_cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        if result.returncode == 0:
            return True, result.stdout.strip()
        else:
            return False, result.stderr.strip() or result.stdout.strip()
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as e:
        return False, str(e)


def run_kubectl_background(namespace: str, pod: str, command: str) -> subprocess.Popen:
    """Start a command inside a Kubernetes pod in the background."""
    kubectl_cmd = [
        "kubectl", "exec", "-n", namespace, pod, "--",
        "/bin/bash", "-c", command
    ]
    
    return subprocess.Popen(
        kubectl_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )


def find_interface_for_hca(namespace: str, pod: str, hca_id: str) -> Optional[str]:
    """Find the network interface name for a given HCA ID on a pod."""
    command = f"""
    for iface_path in /sys/class/net/*; do
        iface=$(basename "$iface_path")
        if [ ! -L "$iface_path/device" ]; then continue; fi
        ib_path="$iface_path/device/infiniband"
        if [ -d "$ib_path" ]; then
            found_hca=$(ls "$ib_path" 2>/dev/null | head -n 1)
            if [ "$found_hca" == "{hca_id}" ]; then
                echo "$iface"
                exit 0
            fi
        fi
    done
    exit 1
    """
    
    success, output = run_kubectl_command(namespace, pod, command)
    if success and output:
        return output.strip()
    return None


def get_interface_ip(namespace: str, pod: str, iface: str) -> Optional[str]:
    """Get the IPv4 address of a network interface on a pod."""
    command = f"ip -4 addr show dev {iface} | awk '/inet / {{sub(/\\/.*/, \"\", $2); print $2; exit}}'"
    
    success, output = run_kubectl_command(namespace, pod, command)
    if success and output:
        return output.strip()
    return None


def get_numa_node_for_hca(namespace: str, pod: str, hca_id: str) -> int:
    """Get the NUMA node for a given HCA on a pod.
    
    Returns the NUMA node number, defaulting to 0 if not found or -1.
    """
    command = f"cat /sys/class/infiniband/{hca_id}/device/numa_node 2>/dev/null || echo 0"
    
    success, output = run_kubectl_command(namespace, pod, command)
    if success and output:
        try:
            numa_node = int(output.strip())
            # -1 means no NUMA affinity, default to 0
            return 0 if numa_node == -1 else numa_node
        except ValueError:
            return 0
    return 0


def start_ib_server(
    namespace: str,
    pair: TestPair,
    pair_idx: int,
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
    bi_directional: bool,
    use_hugepages: bool = False,
    tos: Optional[int] = None
) -> tuple[subprocess.Popen, str]:
    """Start ib_write_bw server on destination pod. Returns (process, json_file_path)."""
    json_file = f"/tmp/ib_server_{pair_idx}_{uuid.uuid4().hex[:8]}.json"
    
    # Build test mode parameter
    if num_iters is not None:
        test_param = f"-n {num_iters}"
    else:
        test_param = f"-D {duration}"
    
    # Build ib_write_bw command with NUMA binding
    ib_cmd = f"ib_write_bw -d {pair.dst_hca} -p {pair.port} -s {msg_size} -q {num_qps} {test_param} --report_gbits --out_json --out_json_file={json_file}"
    
    if use_hugepages:
        ib_cmd += " --use_hugepages"
    if pair.dst_gpu:
        if pair.dst_gpu_type == "rocm":
            ib_cmd += f" --use_rocm={pair.dst_gpu}"
        else:
            ib_cmd += f" --use_cuda={pair.dst_gpu}"
    if bi_directional:
        ib_cmd += " -b --report-both"
    if tos is not None:
        ib_cmd += f" -R --tos={tos}"
    
    # Wrap with numactl for NUMA-aware execution
    cmd = f"numactl --cpunodebind={pair.dst_numa} --membind={pair.dst_numa} {ib_cmd}"
    
    proc = run_kubectl_background(namespace, pair.dst_pod, cmd)
    return proc, json_file


def run_ib_client(
    namespace: str,
    pair: TestPair,
    pair_idx: int,
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
    bi_directional: bool,
    use_hugepages: bool = False,
    tos: Optional[int] = None
) -> tuple[bool, str, str]:
    """Run ib_write_bw client on source pod. Returns (success, json_output, error_msg)."""
    json_file = f"/tmp/ib_client_{pair_idx}_{uuid.uuid4().hex[:8]}.json"
    
    # Build test mode parameter
    if num_iters is not None:
        test_param = f"-n {num_iters}"
    else:
        test_param = f"-D {duration}"
    
    # Build ib_write_bw command
    ib_cmd = f"ib_write_bw -d {pair.src_hca} -p {pair.port} -s {msg_size} -q {num_qps} {test_param} --report_gbits --out_json --out_json_file={json_file}"
    
    if use_hugepages:
        ib_cmd += " --use_hugepages"
    if pair.src_gpu:
        if pair.src_gpu_type == "rocm":
            ib_cmd += f" --use_rocm={pair.src_gpu}"
        else:
            ib_cmd += f" --use_cuda={pair.src_gpu}"
    if bi_directional:
        ib_cmd += " -b --report-both"
    if tos is not None:
        ib_cmd += f" -R --tos={tos} --bind_source_ip={pair.src_ip}"
    
    ib_cmd += f" {pair.dst_ip}"
    
    # Wrap with numactl for NUMA-aware execution
    cmd = f"numactl --cpunodebind={pair.src_numa} --membind={pair.src_numa} {ib_cmd}"
    
    # Timeout is a safety net for catastrophic failures (pod crash, network partition, etc.)
    # Under normal operation, ib_write_bw clients complete their iterations/duration and exit naturally.
    # Set a generous timeout: 10 minutes for iterations mode, duration + 5 min for duration mode.
    if num_iters is not None:
        timeout = 600  # 10 minutes - should be more than enough for any reasonable iteration count
    else:
        timeout = duration + 300  # duration + 5 minutes buffer
    
    success, output = run_kubectl_command(namespace, pair.src_pod, cmd, timeout=timeout)
    
    if not success:
        return False, "", output
    
    # Retrieve the JSON result file
    success, json_content = run_kubectl_command(namespace, pair.src_pod, f"cat {json_file}")
    
    # Clean up
    run_kubectl_command(namespace, pair.src_pod, f"rm -f {json_file}", timeout=10)
    
    if success:
        return True, json_content, ""
    else:
        return False, "", f"Failed to retrieve JSON results: {json_content}"


def parse_ib_json_result(json_str: str, include_peak: bool = False) -> tuple[float, Optional[float]]:
    """Parse ib_write_bw JSON output. Returns (bw_avg, bw_peak) in Gbps.
    
    bw_peak is only returned when include_peak=True (iterations mode).
    """
    try:
        data = json.loads(json_str)
        results = data.get("results", {})
        bw_avg = float(results.get("BW_average", 0))
        bw_peak = None
        if include_peak:
            bw_peak = float(results.get("BW_peak", 0))
        return bw_avg, bw_peak
    except (json.JSONDecodeError, ValueError, TypeError):
        return 0.0, None


def assign_ports(pairs: list[TestPair]) -> None:
    """Assign unique port numbers to each pair based on destination pod.
    
    When multiple pairs share the same destination pod, each needs a unique port.
    """
    # Track port assignments per destination pod
    dst_pod_port_map: dict[str, int] = {}
    
    for pair in pairs:
        if pair.dst_pod not in dst_pod_port_map:
            # First time seeing this destination pod, use base port
            dst_pod_port_map[pair.dst_pod] = BASE_PORT
        else:
            # Increment port for this destination pod
            dst_pod_port_map[pair.dst_pod] += 1
        
        pair.port = dst_pod_port_map[pair.dst_pod]


def discover_endpoints(namespace: str, pairs: list[TestPair], console: Optional[Console], tos: Optional[int] = None) -> bool:
    """Discover network interfaces, IPs, and NUMA nodes for all test pairs.
    
    When TOS is specified (RDMA CM mode), also discovers source interface and IP
    for proper source binding.
    """
    if console:
        console.print("\n[bold cyan]📡 Discovering network endpoints...[/bold cyan]\n")
    
    all_success = True
    
    # First, assign unique ports to each pair
    assign_ports(pairs)
    
    for i, pair in enumerate(pairs):
        if console:
            # Build source and destination strings with optional GPU info
            src_str = f"{pair.src_pod}:{pair.src_hca}"
            if pair.src_gpu:
                src_str += f":{pair.src_gpu_type}:{pair.src_gpu}"
            dst_str = f"{pair.dst_pod}:{pair.dst_hca}"
            if pair.dst_gpu:
                dst_str += f":{pair.dst_gpu_type}:{pair.dst_gpu}"
            console.print(f"  Pair {i+1}: {src_str} → {dst_str} (port {pair.port})")
        
        # Find source interface and IP (needed for RDMA CM / TOS to bind correctly)
        if tos is not None:
            src_iface = find_interface_for_hca(namespace, pair.src_pod, pair.src_hca)
            if not src_iface:
                if console:
                    console.print(f"    [red]✗[/red] Could not find source interface for HCA {pair.src_hca}")
                all_success = False
                continue
            pair.src_iface = src_iface
            
            src_ip = get_interface_ip(namespace, pair.src_pod, src_iface)
            if not src_ip:
                if console:
                    console.print(f"    [red]✗[/red] Could not get source IP for interface {src_iface}")
                all_success = False
                continue
            pair.src_ip = src_ip
        
        # Find destination interface
        iface = find_interface_for_hca(namespace, pair.dst_pod, pair.dst_hca)
        if not iface:
            if console:
                console.print(f"    [red]✗[/red] Could not find interface for HCA {pair.dst_hca}")
            all_success = False
            continue
        pair.dst_iface = iface
        
        # Get destination IP
        ip = get_interface_ip(namespace, pair.dst_pod, iface)
        if not ip:
            if console:
                console.print(f"    [red]✗[/red] Could not get IP for interface {iface}")
            all_success = False
            continue
        pair.dst_ip = ip
        
        # Get NUMA nodes for source and destination HCAs
        pair.src_numa = get_numa_node_for_hca(namespace, pair.src_pod, pair.src_hca)
        pair.dst_numa = get_numa_node_for_hca(namespace, pair.dst_pod, pair.dst_hca)
        
        if console:
            if tos is not None:
                console.print(f"    [green]✓[/green] src: {pair.src_iface} → {pair.src_ip}, dst: {iface} → {ip} (src NUMA: {pair.src_numa}, dst NUMA: {pair.dst_numa})")
            else:
                console.print(f"    [green]✓[/green] {iface} → {ip} (src NUMA: {pair.src_numa}, dst NUMA: {pair.dst_numa})")
    
    return all_success


def run_multi_nic_test(
    namespace: str,
    pairs: list[TestPair],
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
    bi_directional: bool,
    use_hugepages: bool,
    tos: Optional[int],
    console: Optional[Console]
) -> list[TestResult]:
    """Run ib_write_bw tests across all pairs simultaneously."""
    
    results = []
    server_procs = []
    server_json_files = []
    
    # Determine if we should capture peak bandwidth (only in iterations mode)
    include_peak = num_iters is not None
    
    # Step 1: Start all servers
    if console:
        console.print("\n[bold cyan]🚀 Starting all ib_write_bw servers...[/bold cyan]\n")
    
    for i, pair in enumerate(pairs):
        if not pair.dst_ip:
            if console:
                console.print(f"  Pair {i+1}: [yellow]⚠ Skipping (no endpoint)[/yellow]")
            server_procs.append(None)
            server_json_files.append(None)
            continue
        
        proc, json_file = start_ib_server(
            namespace, pair, i, msg_size, num_qps, duration, num_iters, bi_directional, use_hugepages, tos
        )
        server_procs.append(proc)
        server_json_files.append(json_file)
        if console:
            console.print(f"  Pair {i+1}: [green]✓[/green] Server started on {pair.dst_pod}")
    
    # Wait for servers to be ready
    if console:
        console.print("\n  [dim]Waiting for servers to initialize...[/dim]")
    time.sleep(3)
    
    # Step 2: Start all clients simultaneously
    if console:
        console.print("\n[bold cyan]🔄 Starting all ib_write_bw clients...[/bold cyan]\n")
        if num_iters is not None:
            console.print(f"  Running tests for [yellow]{num_iters}[/yellow] iterations...\n")
        else:
            console.print(f"  Running tests for [yellow]{duration}[/yellow] seconds...\n")
    
    client_futures = {}
    with ThreadPoolExecutor(max_workers=len(pairs)) as executor:
        for i, pair in enumerate(pairs):
            if not pair.dst_ip or server_procs[i] is None:
                continue
            
            future = executor.submit(
                run_ib_client,
                namespace, pair, i, msg_size, num_qps, duration, num_iters, bi_directional, use_hugepages, tos
            )
            client_futures[future] = (i, pair)
        
        # Collect client results
        for future in as_completed(client_futures):
            idx, pair = client_futures[future]
            
            try:
                success, json_output, error_msg = future.result()
                
                result = TestResult(
                    pair_idx=idx,
                    src_pod=pair.src_pod,
                    src_hca=pair.src_hca,
                    dst_pod=pair.dst_pod,
                    dst_hca=pair.dst_hca,
                )
                
                if success and json_output:
                    bw_avg, bw_peak = parse_ib_json_result(json_output, include_peak)
                    result.bw_avg_gbps = bw_avg
                    result.bw_peak_gbps = bw_peak
                    result.success = True
                    if console:
                        if bw_peak is not None:
                            console.print(f"  Pair {idx+1}: [green]✓[/green] {bw_avg:.2f} Gbps avg, {bw_peak:.2f} Gbps peak")
                        else:
                            console.print(f"  Pair {idx+1}: [green]✓[/green] {bw_avg:.2f} Gbps avg")
                else:
                    result.error_msg = error_msg
                    if console:
                        console.print(f"  Pair {idx+1}: [red]✗[/red] Failed - {error_msg[:50]}")
                
                results.append(result)
                
            except Exception as e:
                results.append(TestResult(
                    pair_idx=idx,
                    src_pod=pair.src_pod,
                    src_hca=pair.src_hca,
                    dst_pod=pair.dst_pod,
                    dst_hca=pair.dst_hca,
                    error_msg=str(e)
                ))
                if console:
                    console.print(f"  Pair {idx+1}: [red]✗[/red] Exception - {e}")
    
    # Wait for server processes to finish and clean up
    for i, proc in enumerate(server_procs):
        if proc:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
            
            # Clean up server JSON file
            if server_json_files[i]:
                run_kubectl_command(
                    namespace, pairs[i].dst_pod,
                    f"rm -f {server_json_files[i]}", timeout=10
                )
    
    # Sort results by pair index
    results.sort(key=lambda r: r.pair_idx)
    
    return results


def print_results(results: list[TestResult], bi_directional: bool, include_peak: bool, console: Console):
    """Print test results in a formatted table."""
    console.print("\n[bold cyan]📊 Test Results[/bold cyan]\n")
    
    table = Table(show_header=True, header_style="bold")
    table.add_column("#", justify="right", style="dim")
    table.add_column("Source", justify="left")
    table.add_column("Destination", justify="left")
    table.add_column("Avg BW (Gbps)", justify="right")
    if include_peak:
        table.add_column("Peak BW (Gbps)", justify="right")
    table.add_column("Status", justify="center")
    
    total_avg_bw = 0.0
    total_peak_bw = 0.0
    successful_tests = 0
    
    for r in results:
        if r.success:
            total_avg_bw += r.bw_avg_gbps
            if r.bw_peak_gbps is not None:
                total_peak_bw += r.bw_peak_gbps
            successful_tests += 1
            
            row = [
                str(r.pair_idx + 1),
                f"{r.src_pod}:{r.src_hca}",
                f"{r.dst_pod}:{r.dst_hca}",
                f"{r.bw_avg_gbps:.2f}",
            ]
            if include_peak:
                row.append(f"{r.bw_peak_gbps:.2f}" if r.bw_peak_gbps is not None else "-")
            row.append(Text("✓", style="bold green"))
            table.add_row(*row)
        else:
            row = [
                str(r.pair_idx + 1),
                f"{r.src_pod}:{r.src_hca}",
                f"{r.dst_pod}:{r.dst_hca}",
                "-",
            ]
            if include_peak:
                row.append("-")
            row.append(Text("✗", style="bold red"))
            table.add_row(*row)
    
    console.print(table)
    
    # Print summary
    console.print("\n[bold cyan]📈 Summary[/bold cyan]")
    console.print("[dim]" + "-" * 50 + "[/dim]")
    console.print(f"  Successful tests: {successful_tests}/{len(results)}")
    
    if successful_tests > 0:
        console.print(f"\n  [bold]Aggregate Throughput:[/bold]")
        console.print(f"    Total Avg:  [green]{total_avg_bw:.2f} Gbps[/green]")
        if include_peak:
            console.print(f"    Total Peak: [green]{total_peak_bw:.2f} Gbps[/green]")
        console.print(f"\n  [bold]Per-NIC Average:[/bold]")
        console.print(f"    Average:    [yellow]{total_avg_bw/successful_tests:.2f} Gbps[/yellow]")
        if include_peak:
            console.print(f"    Peak:       [yellow]{total_peak_bw/successful_tests:.2f} Gbps[/yellow]")


def output_json_results(
    results: list[TestResult],
    config: dict,
    elapsed_time: float,
    include_peak: bool
) -> None:
    """Output results as JSON to stdout."""
    successful_tests = [r for r in results if r.success]
    failed_tests = [r for r in results if not r.success]
    
    total_avg_bw = sum(r.bw_avg_gbps for r in successful_tests)
    total_peak_bw = sum(r.bw_peak_gbps or 0 for r in successful_tests) if include_peak else None
    
    # Build result objects
    pair_results = []
    for r in results:
        pr = {
            "pair_idx": r.pair_idx,
            "src_pod": r.src_pod,
            "src_hca": r.src_hca,
            "dst_pod": r.dst_pod,
            "dst_hca": r.dst_hca,
            "success": r.success,
            "bw_avg_gbps": r.bw_avg_gbps if r.success else None,
        }
        if include_peak:
            pr["bw_peak_gbps"] = r.bw_peak_gbps if r.success else None
        if not r.success:
            pr["error"] = r.error_msg
        pair_results.append(pr)
    
    output = {
        "config": {
            "namespace": config["namespace"],
            "tos": config.get("tos"),
            "msg_size": config["msg_size"],
            "num_qps": config["num_qps"],
            "bi_directional": config["bi_directional"],
        },
        "test_mode": "iterations" if config.get("num_iters") else "duration",
        "elapsed_time_seconds": round(elapsed_time, 2),
        "summary": {
            "total_pairs": len(results),
            "successful": len(successful_tests),
            "failed": len(failed_tests),
            "total_avg_bw_gbps": round(total_avg_bw, 2),
            "per_nic_avg_bw_gbps": round(total_avg_bw / len(successful_tests), 2) if successful_tests else 0,
        },
        "results": pair_results,
    }
    
    # Add iterations or duration to config
    if config.get("num_iters"):
        output["config"]["num_iters"] = config["num_iters"]
    else:
        output["config"]["duration"] = config["duration"]
    
    # Add peak bandwidth to summary if in iterations mode
    if include_peak and total_peak_bw is not None:
        output["summary"]["total_peak_bw_gbps"] = round(total_peak_bw, 2)
        output["summary"]["per_nic_peak_bw_gbps"] = round(total_peak_bw / len(successful_tests), 2) if successful_tests else 0
    
    print(json.dumps(output, indent=2))


def load_config(config_path: str) -> dict:
    """Load and validate the configuration file."""
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    required_fields = ['namespace', 'test_pairs']
    for field in required_fields:
        if field not in config:
            raise ValueError(f"Missing required field '{field}' in config file")
    
    if not config['test_pairs']:
        raise ValueError("'test_pairs' list cannot be empty")
    
    # Check for mutually exclusive duration/num_iters
    has_duration = 'duration' in config
    has_iters = 'num_iters' in config
    
    if has_duration and has_iters:
        raise ValueError("'duration' and 'num_iters' are mutually exclusive - specify only one")
    
    if not has_duration and not has_iters:
        # Default to duration mode
        config['duration'] = 10
    
    # Set defaults
    config.setdefault('msg_size', 1048576)  # 1MB default
    config.setdefault('num_qps', 4)
    config.setdefault('bi_directional', False)
    config.setdefault('use_hugepages', False)
    config.setdefault('tos', None)
    
    return config


def main():
    parser = argparse.ArgumentParser(
        description='Multi-NIC IB Write Bandwidth Test',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
    uv run ./multi_nic_ib_write_bw.py multi_nic_info.json
    uv run ./multi_nic_ib_write_bw.py --json multi_nic_info.json

Config file format (JSON):
    {
        "namespace": "raj-network-debug",
        "tos": 41,                // Optional: Type of Service (enables RDMA CM)
        "msg_size": 1048576,
        "num_qps": 4,
        "duration": 10,           // OR "num_iters": 5000 (mutually exclusive)
        "bi_directional": false,
        "test_pairs": [
            {
                "src_pod": "pod1",
                "src_hca": "mlx5_0",
                "src_gpu": "0",              // Optional: GPU index
                "src_gpu_type": "cuda",      // Optional: "cuda" (default) or "rocm"
                "dst_pod": "pod2",
                "dst_hca": "mlx5_0",
                "dst_gpu": "1",
                "dst_gpu_type": "rocm"
            }
        ]
    }

Note: When using "num_iters" (< 20000), peak bandwidth is also measured.
      GPU type defaults to "cuda" (NVIDIA). Use "rocm" for AMD GPUs.
        """
    )
    parser.add_argument('config', help='Path to JSON configuration file')
    parser.add_argument('--json', action='store_true', dest='json_output',
                        help='Output results as JSON (suppresses human-readable output)')
    
    args = parser.parse_args()
    
    # Create console (None if json output mode to suppress all prints)
    console = None if args.json_output else Console()
    
    # Print header
    if console:
        console.print("\n[bold blue]╔════════════════════════════════════════════════════╗[/bold blue]")
        console.print("[bold blue]║    Multi-NIC IB Write Bandwidth Test               ║[/bold blue]")
        console.print("[bold blue]╚════════════════════════════════════════════════════╝[/bold blue]")
    
    # Load configuration
    try:
        config = load_config(args.config)
    except FileNotFoundError:
        if console:
            console.print(f"[bold red]Error:[/bold red] Config file not found: {args.config}")
        else:
            print(json.dumps({"error": f"Config file not found: {args.config}"}), file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        if console:
            console.print(f"[bold red]Error:[/bold red] Invalid JSON in config file: {e}")
        else:
            print(json.dumps({"error": f"Invalid JSON in config file: {str(e)}"}), file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        if console:
            console.print(f"[bold red]Error:[/bold red] {e}")
        else:
            print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)
    
    namespace = config['namespace']
    msg_size = config['msg_size']
    num_qps = config['num_qps']
    duration = config.get('duration')
    num_iters = config.get('num_iters')
    bi_directional = config['bi_directional']
    use_hugepages = config['use_hugepages']
    tos = config.get('tos')
    
    # Parse test pairs
    pairs = []
    for tp in config['test_pairs']:
        pairs.append(TestPair(
            src_pod=tp['src_pod'],
            src_hca=tp['src_hca'],
            src_gpu=tp.get('src_gpu'),
            src_gpu_type=tp.get('src_gpu_type', 'cuda'),
            dst_pod=tp['dst_pod'],
            dst_hca=tp['dst_hca'],
            dst_gpu=tp.get('dst_gpu'),
            dst_gpu_type=tp.get('dst_gpu_type', 'cuda'),
        ))
    
    if console:
        console.print(f"\n[bold]Configuration:[/bold]")
        console.print(f"  Namespace:      {namespace}")
        console.print(f"  Message Size:   {msg_size} bytes ({msg_size/1024/1024:.1f} MB)")
        console.print(f"  Num QPs:        {num_qps}")
        if num_iters is not None:
            console.print(f"  Iterations:     {num_iters}")
        else:
            console.print(f"  Duration:       {duration} seconds")
        console.print(f"  Bi-directional: {bi_directional}")
        if tos is not None:
            console.print(f"  TOS:            {tos} (RDMA CM enabled)")
        console.print(f"  Test Pairs:     {len(pairs)}")
    
    # Step 1: Discover endpoints (pass tos to discover source IPs when needed for RDMA CM)
    if not discover_endpoints(namespace, pairs, console, tos):
        if console:
            console.print("\n[bold red]Error:[/bold red] Failed to discover all endpoints")
        else:
            print(json.dumps({"error": "Failed to discover all endpoints"}), file=sys.stderr)
        sys.exit(1)
    
    # Step 2: Run tests
    start_time = time.time()
    results = run_multi_nic_test(
        namespace, pairs, msg_size, num_qps, duration, num_iters, bi_directional, use_hugepages, tos, console
    )
    elapsed_time = time.time() - start_time
    
    # Determine if we should include peak bandwidth
    include_peak = num_iters is not None
    
    if console:
        console.print(f"\n  [dim]Total test time: {elapsed_time:.1f} seconds[/dim]")
        # Step 3: Print results
        print_results(results, bi_directional, include_peak, console)
    else:
        # JSON output mode
        output_json_results(results, config, elapsed_time, include_peak)
    
    # Exit with appropriate code
    has_failures = any(not r.success for r in results)
    sys.exit(1 if has_failures else 0)


if __name__ == "__main__":
    main()
