#!/usr/bin/env python3
"""
Pingmesh Test for RoCE Cluster NIC Connectivity Validation

This script performs comprehensive ping tests between all pairs of NICs
across nodes in a Kubernetes cluster to validate network connectivity.

Usage:
    uv run ./pingmesh.py roce_cluster_info.json
"""

import argparse
import json
import subprocess
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from itertools import combinations
from typing import Optional

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, BarColumn, TextColumn, TaskProgressColumn
from rich.table import Table
from rich.text import Text


@dataclass
class PingResult:
    """Result of a single ping test between two NICs."""
    src_node: str
    src_iface: str
    src_ip: str
    dst_node: str
    dst_iface: str
    dst_ip: str
    success: bool
    error_msg: Optional[str] = None


@dataclass
class NodePairResult:
    """Aggregated results for all NIC pairs between two nodes."""
    src_node: str
    dst_node: str
    total_pairs: int = 0
    successful_pairs: int = 0
    failed_tests: list = field(default_factory=list)


def get_pod_name(node_name: str) -> str:
    """Generate pod name from node name following deploy_pod_to_node.sh convention."""
    return f"networking-debug-pod-{node_name}"


def run_kubectl_command(namespace: str, pod_name: str, command: str, timeout: int = 30) -> tuple[bool, str]:
    """
    Execute a command inside a Kubernetes pod.
    
    Returns:
        Tuple of (success, output/error_message)
    """
    kubectl_cmd = [
        "kubectl", "exec", "-n", namespace, pod_name, "--", 
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


def get_interface_ip(namespace: str, node_name: str, iface_name: str) -> Optional[str]:
    """Get the IPv4 address of a network interface on a node."""
    pod_name = get_pod_name(node_name)
    # Get IPv4 address for the interface
    command = f"ip -4 addr show {iface_name} 2>/dev/null | grep -oP 'inet \\K[0-9.]+'"
    
    success, output = run_kubectl_command(namespace, pod_name, command)
    if success and output:
        # Return first IP if multiple exist
        return output.split('\n')[0].strip()
    return None


def run_ping_test(namespace: str, src_node: str, src_ip: str, dst_ip: str, retries: int = 1, backoff_ms: int = 500) -> tuple[bool, str]:
    """
    Run ping test from source node using source IP to destination IP.
    
    Uses: ping -A -I $srcIP $dstIP -c 3
    -A: Adaptive ping (as fast as possible, one probe in-flight)
    -I: Source interface/IP
    -c 3: Send 3 probes
    
    If the test fails (possibly due to K8s API issues), retries after backoff.
    """
    pod_name = get_pod_name(src_node)
    command = f"ping -A -I {src_ip} {dst_ip} -c 3 -W 2"
    
    last_output = ""
    for attempt in range(retries + 1):
        success, output = run_kubectl_command(namespace, pod_name, command, timeout=15)
        if success:
            return True, output
        last_output = output
        
        # If this wasn't the last attempt, wait before retrying
        if attempt < retries:
            time.sleep(backoff_ms / 1000.0)
    
    return False, last_output


def collect_interface_ips(namespace: str, nodes: list[str], interfaces: list[str], console: Console, max_workers: int = 10) -> dict:
    """
    Collect IP addresses for all interfaces on all nodes.
    
    Returns:
        Dict mapping node -> interface -> IP address
    """
    console.print("\n[bold cyan]📡 Collecting interface IP addresses...[/bold cyan]\n")
    
    node_interface_ips = defaultdict(dict)
    node_status = {node: {"completed": 0, "total": len(interfaces), "errors": 0} for node in nodes}
    
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for node in nodes:
            for iface in interfaces:
                future = executor.submit(get_interface_ip, namespace, node, iface)
                futures[future] = (node, iface)
        
        for future in as_completed(futures):
            node, iface = futures[future]
            try:
                ip = future.result()
                if ip:
                    node_interface_ips[node][iface] = ip
                else:
                    node_status[node]["errors"] += 1
            except Exception:
                node_status[node]["errors"] += 1
            
            node_status[node]["completed"] += 1
    
    # Print summary per node 
    for node in nodes:
        status = node_status[node]
        ips_found = len(node_interface_ips.get(node, {}))
        if status["errors"] == 0:
            console.print(f"  {node} ... [green]✓[/green] [dim]({ips_found}/{status['total']} IPs)[/dim]")
        elif ips_found > 0:
            console.print(f"  {node} ... [yellow]⚠[/yellow] [dim]({ips_found}/{status['total']} IPs)[/dim]")
        else:
            console.print(f"  {node} ... [red]✗[/red] [dim](no IPs found)[/dim]")
    
    return dict(node_interface_ips)


def run_pingmesh_tests(
    namespace: str, 
    nodes: list[str], 
    interfaces: list[str],
    node_interface_ips: dict,
    console: Console,
    max_workers: int = 10
) -> dict[tuple[str, str], NodePairResult]:
    """
    Run ping tests between all pairs of NICs across all node pairs.
    
    Uses N choose 2 for node pairs (unordered) to avoid redundant bidirectional tests,
    since a single ping already validates bidirectional connectivity.
    
    Returns:
        Dict mapping (node_a, node_b) -> NodePairResult (unordered pairs)
    """
    console.print("\n[bold cyan]🔄 Running pingmesh tests...[/bold cyan]\n")
    
    start_time = time.time()
    results = {}
    
    # Generate N choose 2 node pairs (unordered)
    node_pairs = list(combinations(nodes, 2))
    
    # Initialize results for all node pairs
    for node_a, node_b in node_pairs:
        results[(node_a, node_b)] = NodePairResult(
            src_node=node_a,
            dst_node=node_b
        )
    
    # Collect all ping tasks - for each node pair, test all NIC combinations
    ping_tasks = []
    for node_a, node_b in node_pairs:
        ips_a = node_interface_ips.get(node_a, {})
        ips_b = node_interface_ips.get(node_b, {})
        
        # Test all NIC pairs between node_a and node_b (ping from node_a)
        for iface_a, ip_a in ips_a.items():
            for iface_b, ip_b in ips_b.items():
                ping_tasks.append({
                    'node_a': node_a,
                    'node_b': node_b,
                    'src_iface': iface_a,
                    'dst_iface': iface_b,
                    'src_ip': ip_a,
                    'dst_ip': ip_b
                })
    
    total_tests = len(ping_tasks)
    console.print(f"  Total ping tests to run: {total_tests}\n")
    
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
        TextColumn("[cyan]{task.completed}/{task.total}[/cyan]"),
        console=console,
        transient=False
    ) as progress:
        task_id = progress.add_task("  Ping tests", total=total_tests)
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {}
            for task in ping_tasks:
                future = executor.submit(
                    run_ping_test,
                    namespace,
                    task['node_a'],  # Ping from node_a
                    task['src_ip'],
                    task['dst_ip']
                )
                futures[future] = task
            
            for future in as_completed(futures):
                task = futures[future]
                node_a = task['node_a']
                node_b = task['node_b']
                
                pair_key = (node_a, node_b)
                results[pair_key].total_pairs += 1
                
                try:
                    success, output = future.result()
                    if success:
                        results[pair_key].successful_pairs += 1
                    else:
                        results[pair_key].failed_tests.append(PingResult(
                            src_node=node_a,
                            src_iface=task['src_iface'],
                            src_ip=task['src_ip'],
                            dst_node=node_b,
                            dst_iface=task['dst_iface'],
                            dst_ip=task['dst_ip'],
                            success=False,
                            error_msg=output[:200] if output else "Unknown error"
                        ))
                except Exception as e:
                    results[pair_key].failed_tests.append(PingResult(
                        src_node=node_a,
                        src_iface=task['src_iface'],
                        src_ip=task['src_ip'],
                        dst_node=node_b,
                        dst_iface=task['dst_iface'],
                        dst_ip=task['dst_ip'],
                        success=False,
                        error_msg=str(e)
                    ))
                
                progress.update(task_id, advance=1)
    
    elapsed_time = time.time() - start_time
    console.print(f"\n  Completed in {elapsed_time:.3f} seconds")
    
    return results


def get_short_node_name(node_name: str, max_len: int = 12) -> str:
    """Shorten node name for display in table."""
    if len(node_name) <= max_len:
        return node_name
    # For IP addresses, show last octet(s)
    if '.' in node_name:
        parts = node_name.split('.')
        return f"...{parts[-2]}.{parts[-1]}"
    return node_name[:max_len-3] + "..."


def get_pair_result(results: dict[tuple[str, str], NodePairResult], node_a: str, node_b: str) -> Optional[NodePairResult]:
    """Get result for a node pair, checking both orderings since pairs are unordered."""
    return results.get((node_a, node_b)) or results.get((node_b, node_a))


def print_results_matrix(
    nodes: list[str], 
    results: dict[tuple[str, str], NodePairResult],
    console: Console
):
    """Print the connectivity matrix with color-coded results (symmetric)."""
    console.print("\n[bold cyan]📊 Pingmesh Connectivity Matrix[/bold cyan]")
    console.print("[dim](Values show: successful_pairs/total_pairs)[/dim]\n")
    
    # Create the table
    table = Table(show_header=True, header_style="bold", box=None)
    
    # Add the header row (dst nodes)
    table.add_column("Node A \\ B", style="bold", justify="right")
    for node in nodes:
        table.add_column(get_short_node_name(node), justify="center")
    
    # Add data rows - show symmetric matrix (same value in both triangles)
    for i, node_a in enumerate(nodes):
        row = [get_short_node_name(node_a)]
        for j, node_b in enumerate(nodes):
            if i == j:
                # Diagonal
                row.append(Text("-", style="dim"))
            else:
                # Both triangles - show results
                pair_result = get_pair_result(results, node_a, node_b)
                if pair_result:
                    total = pair_result.total_pairs
                    success = pair_result.successful_pairs
                    cell_text = f"{success}/{total}"
                    
                    if total == 0:
                        style = "dim"
                    elif success == total:
                        style = "bold green"
                    elif success > 0:
                        style = "bold yellow"
                    else:
                        style = "bold red"
                    
                    row.append(Text(cell_text, style=style))
                else:
                    row.append(Text("N/A", style="dim"))
        
        table.add_row(*row)
    
    console.print(table)


def print_failure_details(
    results: dict[tuple[str, str], NodePairResult],
    console: Console
):
    """Print detailed information about failed tests."""
    # Collect all node pairs with failures
    failed_pairs = [
        (key, result) for key, result in results.items() 
        if result.failed_tests and result.successful_pairs < result.total_pairs
    ]
    
    if not failed_pairs:
        console.print("\n[bold green]✅ All ping tests passed![/bold green]")
        return
    
    console.print("\n[bold red]❌ Failure Details[/bold red]")
    console.print("[dim]" + "=" * 80 + "[/dim]\n")
    
    for (node_a, node_b), result in sorted(failed_pairs):
        console.print(f"[bold yellow]Node Pair: {node_a} ↔ {node_b}[/bold yellow]")
        console.print(f"  Status: {result.successful_pairs}/{result.total_pairs} pairs succeeded")
        console.print(f"  Failed connections:")
        
        # Group failures by interface pair for cleaner output
        for failed in result.failed_tests[:10]:  # Limit to first 10 failures
            console.print(
                f"    [red]✗[/red] {failed.src_iface}({failed.src_ip}) → "
                f"{failed.dst_iface}({failed.dst_ip})"
            )
            if failed.error_msg:
                # Truncate error message
                error_preview = failed.error_msg.replace('\n', ' ')[:80]
                console.print(f"      [dim]Error: {error_preview}[/dim]")
        
        if len(result.failed_tests) > 10:
            console.print(f"    [dim]... and {len(result.failed_tests) - 10} more failures[/dim]")
        
        console.print()


def print_summary(
    results: dict[tuple[str, str], NodePairResult],
    console: Console
):
    """Print overall test summary."""
    total_pairs = 0
    total_success = 0
    total_node_pairs = len(results)
    fully_connected = 0
    partially_connected = 0
    disconnected = 0
    
    for result in results.values():
        total_pairs += result.total_pairs
        total_success += result.successful_pairs
        
        if result.total_pairs > 0:
            if result.successful_pairs == result.total_pairs:
                fully_connected += 1
            elif result.successful_pairs > 0:
                partially_connected += 1
            else:
                disconnected += 1
    
    console.print("\n[bold cyan]📈 Summary[/bold cyan]")
    console.print("[dim]" + "-" * 40 + "[/dim]")
    console.print(f"  Total node pairs tested: {total_node_pairs}")
    console.print(f"  Total NIC pairs tested: {total_pairs}")
    if total_pairs > 0:
        pct = (total_success / total_pairs) * 100
        # Show more precision for high percentages, truncate don't round
        pct_str = f"{pct:.4f}".rstrip('0').rstrip('.')
        console.print(f"  Successful pings: {total_success}/{total_pairs} ({pct_str}%)")
    else:
        console.print("  No tests run")
    console.print()
    console.print(f"  [green]● Fully connected node pairs: {fully_connected}[/green]")
    console.print(f"  [yellow]● Partially connected node pairs: {partially_connected}[/yellow]")
    console.print(f"  [red]● Disconnected node pairs: {disconnected}[/red]")


def load_config(config_path: str) -> dict:
    """Load and validate the configuration file."""
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    required_fields = ['namespace', 'nodes', 'interfaces']
    for field in required_fields:
        if field not in config:
            raise ValueError(f"Missing required field '{field}' in config file")
    
    if not config['nodes']:
        raise ValueError("'nodes' list cannot be empty")
    
    if not config['interfaces']:
        raise ValueError("'interfaces' list cannot be empty")
    
    return config


def main():
    parser = argparse.ArgumentParser(
        description='Pingmesh test for RoCE cluster NIC connectivity validation',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
    uv run ./pingmesh.py roce_cluster_info.json

Config file format (JSON):
    {
        "namespace": "raj-network-debug",
        "nodes": ["10.0.65.77", "10.0.66.42", ...],
        "interfaces": ["rdma0", "rdma1", ...],
        "max_workers": 10
    }
        """
    )
    parser.add_argument('config', help='Path to JSON configuration file')
    
    args = parser.parse_args()
    
    console = Console()
    
    # Print header
    console.print("\n[bold blue]╔═══════════════════════════════════════════════╗[/bold blue]")
    console.print("[bold blue]║    RoCE Cluster Pingmesh Connectivity Test    ║[/bold blue]")
    console.print("[bold blue]╚═══════════════════════════════════════════════╝[/bold blue]")
    
    # Load configuration
    try:
        config = load_config(args.config)
    except FileNotFoundError:
        console.print(f"[bold red]Error:[/bold red] Config file not found: {args.config}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        console.print(f"[bold red]Error:[/bold red] Invalid JSON in config file: {e}")
        sys.exit(1)
    except ValueError as e:
        console.print(f"[bold red]Error:[/bold red] {e}")
        sys.exit(1)
    
    namespace = config['namespace']
    nodes = config['nodes']
    interfaces = config['interfaces']
    max_workers = config.get('max_workers', 10)
    
    console.print(f"\n[bold]Configuration:[/bold]")
    console.print(f"  Namespace: {namespace}")
    console.print(f"  Nodes: {len(nodes)}")
    console.print(f"  Interfaces per node: {len(interfaces)}")
    console.print(f"  Expected pairs per node-pair: {len(interfaces) * len(interfaces)}")
    console.print(f"  Max workers: {max_workers}")
    
    # Step 1: Collect interface IPs
    node_interface_ips = collect_interface_ips(namespace, nodes, interfaces, console, max_workers=max_workers)
    
    # Validate we have some IPs
    total_ips = sum(len(ips) for ips in node_interface_ips.values())
    if total_ips == 0:
        console.print("\n[bold red]Error:[/bold red] No interface IPs found. Check that:")
        console.print("  - Pods are running in the specified namespace")
        console.print("  - Interface names are correct")
        console.print("  - Pods have network access")
        sys.exit(1)
    
    console.print(f"\n[green]✓[/green] Collected {total_ips} interface IPs across {len(node_interface_ips)} nodes")
    
    # Step 2: Run pingmesh tests
    results = run_pingmesh_tests(
        namespace, 
        nodes, 
        interfaces, 
        node_interface_ips, 
        console,
        max_workers=max_workers
    )
    
    # Step 3: Print results
    print_results_matrix(nodes, results, console)
    print_summary(results, console)
    print_failure_details(results, console)
    
    # Exit with appropriate code
    has_failures = any(
        r.successful_pairs < r.total_pairs 
        for r in results.values() 
        if r.total_pairs > 0
    )
    sys.exit(1 if has_failures else 0)


if __name__ == "__main__":
    main()
