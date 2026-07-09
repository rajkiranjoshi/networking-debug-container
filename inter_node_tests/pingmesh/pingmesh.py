#!/usr/bin/env python3
from __future__ import annotations
"""
Pingmesh Test for Network Connectivity Validation

Supports two network types:
- "roce" (default): ICMP ping between RoCE NIC IPs
- "efa": fi_pingpong over EFA datapath (full NxN cross-device mesh)

And two entity modes:
- "nodes": Provide node names, pods are derived as networking-debug-pod-<node>
- "pods": Provide pod names directly

Usage:
    uv run ./pingmesh.py roce_cluster_info.json
    uv run ./pingmesh.py pingmesh-efa-eks.json
"""

import argparse
import json
import re
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


@dataclass
class EfaTestResult:
    """Result of a single EFA fi_pingpong test between two devices."""
    src_node: str
    src_device: str
    dst_node: str
    dst_device: str
    success: bool
    error_msg: Optional[str] = None


# EFA constants
EFA_RESULT_PATTERN = re.compile(r'^\d+\s+\d+\s+=\d+', re.MULTILINE)
EFA_BASE_PORT = 20000
EFA_CLIENT_TIMEOUT = 15
EFA_SERVER_TIMEOUT = 60
EFA_MAX_WORKERS = 8


def get_pod_name(entity: str, entity_to_pod: dict[str, str] | None = None) -> str:
    """
    Get pod name for an entity.
    
    If entity_to_pod mapping is provided, use it directly.
    Otherwise, generate pod name from node name following deploy_pod_to_node.sh convention.
    """
    if entity_to_pod is not None:
        return entity_to_pod.get(entity, entity)
    return f"networking-debug-pod-{entity}"


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


def get_interface_ip(namespace: str, entity: str, iface_name: str, entity_to_pod: dict[str, str] | None = None) -> Optional[str]:
    """Get the IPv4 address of a network interface on an entity (node or pod)."""
    pod_name = get_pod_name(entity, entity_to_pod)
    # Get IPv4 address for the interface
    command = f"ip -4 addr show {iface_name} 2>/dev/null | grep -oP 'inet \\K[0-9.]+'"
    
    success, output = run_kubectl_command(namespace, pod_name, command)
    if success and output:
        # Return first IP if multiple exist
        return output.split('\n')[0].strip()
    return None


def run_ping_test(namespace: str, src_entity: str, src_ip: str, dst_ip: str, entity_to_pod: dict[str, str] | None = None, retries: int = 1, backoff_ms: int = 500) -> tuple[bool, str]:
    """
    Run ping test from source entity using source IP to destination IP.
    
    Uses: ping -A -I $srcIP $dstIP -c 3
    -A: Adaptive ping (as fast as possible, one probe in-flight)
    -I: Source interface/IP
    -c 3: Send 3 probes
    
    If the test fails (possibly due to K8s API issues), retries after backoff.
    """
    pod_name = get_pod_name(src_entity, entity_to_pod)
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


def collect_interface_ips(namespace: str, entities: list[str], interfaces: list[str], console: Console, entity_to_pod: dict[str, str] | None = None, max_workers: int = 10) -> dict:
    """
    Collect IP addresses for all interfaces on all entities (nodes or pods).
    
    Returns:
        Dict mapping entity -> interface -> IP address
    """
    console.print("\n[bold cyan]📡 Collecting interface IP addresses...[/bold cyan]\n")
    
    entity_interface_ips = defaultdict(dict)
    entity_status = {entity: {"completed": 0, "total": len(interfaces), "errors": 0} for entity in entities}
    
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for entity in entities:
            for iface in interfaces:
                future = executor.submit(get_interface_ip, namespace, entity, iface, entity_to_pod)
                futures[future] = (entity, iface)
        
        for future in as_completed(futures):
            entity, iface = futures[future]
            try:
                ip = future.result()
                if ip:
                    entity_interface_ips[entity][iface] = ip
                else:
                    entity_status[entity]["errors"] += 1
            except Exception:
                entity_status[entity]["errors"] += 1
            
            entity_status[entity]["completed"] += 1
    
    # Print summary per entity 
    for entity in entities:
        status = entity_status[entity]
        ips_found = len(entity_interface_ips.get(entity, {}))
        if status["errors"] == 0:
            console.print(f"  {entity} ... [green]✓[/green] [dim]({ips_found}/{status['total']} IPs)[/dim]")
        elif ips_found > 0:
            console.print(f"  {entity} ... [yellow]⚠[/yellow] [dim]({ips_found}/{status['total']} IPs)[/dim]")
        else:
            console.print(f"  {entity} ... [red]✗[/red] [dim](no IPs found)[/dim]")
    
    return dict(entity_interface_ips)


def run_pingmesh_tests(
    namespace: str, 
    entities: list[str], 
    interfaces: list[str],
    entity_interface_ips: dict,
    console: Console,
    entity_to_pod: dict[str, str] | None = None,
    max_workers: int = 10
) -> dict[tuple[str, str], NodePairResult]:
    """
    Run ping tests between all pairs of NICs across all entity pairs (nodes or pods).
    
    Uses N choose 2 for entity pairs (unordered) to avoid redundant bidirectional tests,
    since a single ping already validates bidirectional connectivity.
    
    Returns:
        Dict mapping (entity_a, entity_b) -> NodePairResult (unordered pairs)
    """
    console.print("\n[bold cyan]🔄 Running pingmesh tests...[/bold cyan]\n")
    
    start_time = time.time()
    results = {}
    
    # Generate N choose 2 entity pairs (unordered)
    entity_pairs = list(combinations(entities, 2))
    
    # Initialize results for all entity pairs
    for entity_a, entity_b in entity_pairs:
        results[(entity_a, entity_b)] = NodePairResult(
            src_node=entity_a,
            dst_node=entity_b
        )
    
    # Collect all ping tasks - for each entity pair, test all NIC combinations
    ping_tasks = []
    for entity_a, entity_b in entity_pairs:
        ips_a = entity_interface_ips.get(entity_a, {})
        ips_b = entity_interface_ips.get(entity_b, {})
        
        # Test all NIC pairs between entity_a and entity_b (ping from entity_a)
        for iface_a, ip_a in ips_a.items():
            for iface_b, ip_b in ips_b.items():
                ping_tasks.append({
                    'entity_a': entity_a,
                    'entity_b': entity_b,
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
                    task['entity_a'],  # Ping from entity_a
                    task['src_ip'],
                    task['dst_ip'],
                    entity_to_pod
                )
                futures[future] = task
            
            for future in as_completed(futures):
                task = futures[future]
                entity_a = task['entity_a']
                entity_b = task['entity_b']
                
                pair_key = (entity_a, entity_b)
                results[pair_key].total_pairs += 1
                
                try:
                    success, output = future.result()
                    if success:
                        results[pair_key].successful_pairs += 1
                    else:
                        results[pair_key].failed_tests.append(PingResult(
                            src_node=entity_a,
                            src_iface=task['src_iface'],
                            src_ip=task['src_ip'],
                            dst_node=entity_b,
                            dst_iface=task['dst_iface'],
                            dst_ip=task['dst_ip'],
                            success=False,
                            error_msg=output[:200] if output else "Unknown error"
                        ))
                except Exception as e:
                    results[pair_key].failed_tests.append(PingResult(
                        src_node=entity_a,
                        src_iface=task['src_iface'],
                        src_ip=task['src_ip'],
                        dst_node=entity_b,
                        dst_iface=task['dst_iface'],
                        dst_ip=task['dst_ip'],
                        success=False,
                        error_msg=str(e)
                    ))
                
                progress.update(task_id, advance=1)
    
    elapsed_time = time.time() - start_time
    console.print(f"\n  Completed in {elapsed_time:.3f} seconds")
    
    return results


def get_pair_result(results: dict[tuple[str, str], NodePairResult], node_a: str, node_b: str) -> Optional[NodePairResult]:
    """Get result for a node pair, checking both orderings since pairs are unordered."""
    return results.get((node_a, node_b)) or results.get((node_b, node_a))


def print_results_matrix(
    entities: list[str], 
    results: dict[tuple[str, str], NodePairResult],
    console: Console,
    mode: str = "nodes"
):
    """Print the connectivity matrix with color-coded results (symmetric)."""
    entity_label = "Pod" if mode == "pods" else "Node"
    
    console.print("\n[bold cyan]📊 Pingmesh Connectivity Matrix[/bold cyan]")
    console.print("[dim](Values show: successful_pairs/total_pairs)[/dim]\n")
    
    # Create the table
    table = Table(show_header=True, header_style="bold", box=None)
    
    # Add the header row (dst entities) - use full names, no truncation
    table.add_column(f"{entity_label} A \\ B", style="bold", justify="right")
    for entity in entities:
        table.add_column(entity, justify="center")
    
    # Add data rows - show symmetric matrix (same value in both triangles)
    for i, entity_a in enumerate(entities):
        row = [entity_a]
        for j, entity_b in enumerate(entities):
            if i == j:
                # Diagonal
                row.append(Text("-", style="dim"))
            else:
                # Both triangles - show results
                pair_result = get_pair_result(results, entity_a, entity_b)
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


## EFA fi_pingpong functions ##


def resolve_pod_ip(namespace: str, pod_name: str) -> Optional[str]:
    """Resolve a pod's primary IP via hostname -I (works with hostNetwork)."""
    success, output = run_kubectl_command(namespace, pod_name, "hostname -I | awk '{print $1}'")
    if success and output:
        return output.strip()
    return None


def start_efa_server_batch(
    namespace: str,
    dst_pod: str,
    device_port_pairs: list[tuple[str, int]],
) -> bool:
    """
    Start a batch of fi_pingpong servers on dst_pod via single kubectl exec.
    Uses nohup so servers persist after kubectl session closes.
    Returns True if the kubectl exec succeeded.
    """
    server_cmds = []
    for device, port in device_port_pairs:
        server_cmds.append(
            f"nohup timeout {EFA_SERVER_TIMEOUT} "
            f"fi_pingpong -e rdm -p efa -d {device}-rdm -S 64 -I 100 -B {port} "
            f"> /dev/null 2>&1 &"
        )
    full_cmd = " ".join(server_cmds) + " sleep 2"
    success, _ = run_kubectl_command(namespace, dst_pod, full_cmd, timeout=15)
    return success


def run_efa_pingpong_client(
    namespace: str,
    src_pod: str,
    src_device: str,
    dst_port: int,
    dst_ip: str,
) -> tuple[bool, str]:
    """
    Run a single fi_pingpong client against an already-running server.
    Returns (success, detail).
    """
    client_cmd = (
        f"timeout {EFA_CLIENT_TIMEOUT} "
        f"fi_pingpong -e rdm -p efa -d {src_device}-rdm -S 64 -I 100 "
        f"-P {dst_port} {dst_ip}"
    )
    success, output = run_kubectl_command(
        namespace, src_pod, client_cmd, timeout=EFA_CLIENT_TIMEOUT + 10
    )
    if success and EFA_RESULT_PATTERN.search(output):
        return True, output
    else:
        return False, output[:200] if output else "No output (possible crash)"


def run_efa_batch(
    namespace: str,
    src_pod: str,
    dst_pod: str,
    dst_ip: str,
    test_pairs: list[tuple[str, str]],
) -> list[tuple[str, str, bool, str]]:
    """
    Execute one batch of up to EFA_MAX_WORKERS fi_pingpong tests.
    1. Start servers on dst_pod (one per test pair's dst_device)
    2. Run clients in parallel on src_pod
    3. Servers auto-exit after serving

    test_pairs: list of (src_device, dst_device)
    Returns: list of (src_device, dst_device, success, detail)
    """
    device_port_pairs = [
        (dst_dev, EFA_BASE_PORT + i)
        for i, (_, dst_dev) in enumerate(test_pairs)
    ]

    start_efa_server_batch(namespace, dst_pod, device_port_pairs)

    results = []
    with ThreadPoolExecutor(max_workers=EFA_MAX_WORKERS) as executor:
        futures = {}
        for i, (src_dev, dst_dev) in enumerate(test_pairs):
            port = EFA_BASE_PORT + i
            f = executor.submit(
                run_efa_pingpong_client, namespace, src_pod, src_dev, port, dst_ip
            )
            futures[f] = (src_dev, dst_dev)

        for f in as_completed(futures):
            src_dev, dst_dev = futures[f]
            try:
                success, detail = f.result()
            except Exception as e:
                success, detail = False, str(e)
            results.append((src_dev, dst_dev, success, detail))

    return results


def generate_efa_batches(devices: list[str], max_workers: int) -> list[list[tuple[str, str]]]:
    """
    Generate batched test pairs for full NxN cross-device mesh.
    Uses diagonal-shifted rotation: each batch has unique src AND dst devices.
    """
    n = len(devices)
    batches = []
    for shift in range(n):
        pairs_for_shift = []
        for i in range(n):
            src_dev = devices[i]
            dst_dev = devices[(i + shift) % n]
            pairs_for_shift.append((src_dev, dst_dev))
        # Split into sub-batches of max_workers
        for start in range(0, n, max_workers):
            batch = pairs_for_shift[start:start + max_workers]
            batches.append(batch)
    return batches


def run_efa_pingmesh_tests(
    namespace: str,
    entities: list[str],
    devices: list[str],
    console: Console,
    entity_to_pod: dict[str, str] | None = None,
    max_workers: int = EFA_MAX_WORKERS,
) -> dict[tuple[str, str], NodePairResult]:
    """
    Run EFA fi_pingpong tests between all NxN device pairs across node pairs.
    Uses N-choose-2 (unidirectional) since fi_pingpong is bidirectional.
    """
    console.print("\n[bold cyan]Running EFA pingmesh tests...[/bold cyan]\n")
    start_time = time.time()

    max_workers = min(max_workers, EFA_MAX_WORKERS)
    entity_pairs = list(combinations(entities, 2))
    results: dict[tuple[str, str], NodePairResult] = {}

    # Resolve pod IPs upfront
    console.print("  Resolving pod IPs...")
    pod_ips: dict[str, str] = {}
    for entity in entities:
        pod_name = get_pod_name(entity, entity_to_pod)
        ip = resolve_pod_ip(namespace, pod_name)
        if ip:
            pod_ips[entity] = ip
            console.print(f"    {entity} -> {ip}")
        else:
            console.print(f"    [red]{entity} -> FAILED to resolve IP[/red]")

    n_devices = len(devices)
    total_tests_per_pair = n_devices * n_devices
    batches = generate_efa_batches(devices, max_workers)
    total_batches = len(batches)

    console.print(f"\n  Devices: {n_devices}")
    console.print(f"  Tests per node pair: {total_tests_per_pair}")
    console.print(f"  Batches per node pair: {total_batches}")
    console.print(f"  Max parallel: {max_workers}")
    console.print(f"  Node pairs: {len(entity_pairs)}\n")

    # Clean up any lingering fi_pingpong processes from prior runs
    console.print("  Cleaning up lingering fi_pingpong processes...")
    for entity in entities:
        pod_name = get_pod_name(entity, entity_to_pod)
        run_kubectl_command(namespace, pod_name, "pkill -f fi_pingpong; true", timeout=10)
    time.sleep(1)

    console.print("\n  Running pingmesh...\n")

    interrupted = False
    active_dst_pod: Optional[str] = None

    try:
        for entity_a, entity_b in entity_pairs:
            results[(entity_a, entity_b)] = NodePairResult(
                src_node=entity_a, dst_node=entity_b
            )

            src_pod = get_pod_name(entity_a, entity_to_pod)
            dst_pod = get_pod_name(entity_b, entity_to_pod)
            dst_ip = pod_ips.get(entity_b)

            if not dst_ip:
                console.print(f"  [red]Skipping {entity_a} -> {entity_b}: no dst IP[/red]")
                continue

            active_dst_pod = dst_pod
            pair_result = results[(entity_a, entity_b)]

            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                BarColumn(),
                TaskProgressColumn(),
                TextColumn("[cyan]{task.completed}/{task.total}[/cyan]"),
                console=console,
                transient=False,
            ) as progress:
                task_id = progress.add_task(
                    f"  {entity_a} -> {entity_b}", total=total_tests_per_pair
                )

                for batch in batches:
                    batch_results = run_efa_batch(
                        namespace, src_pod, dst_pod, dst_ip, batch
                    )
                    for src_dev, dst_dev, success, detail in batch_results:
                        pair_result.total_pairs += 1
                        if success:
                            pair_result.successful_pairs += 1
                        else:
                            pair_result.failed_tests.append(EfaTestResult(
                                src_node=entity_a,
                                src_device=src_dev,
                                dst_node=entity_b,
                                dst_device=dst_dev,
                                success=False,
                                error_msg=detail,
                            ))
                        progress.update(task_id, advance=1)

            active_dst_pod = None

    except KeyboardInterrupt:
        interrupted = True
        console.print("\n\n[bold yellow]Interrupted! Cleaning up...[/bold yellow]")
        if active_dst_pod:
            run_kubectl_command(
                namespace, active_dst_pod,
                "pkill -f fi_pingpong; true", timeout=10
            )
            console.print(f"  Killed fi_pingpong servers on {active_dst_pod}")

    elapsed = time.time() - start_time
    status = "Interrupted" if interrupted else "Completed"
    console.print(f"\n  {status} in {elapsed:.1f} seconds")
    return results


def print_efa_failure_details(
    results: dict[tuple[str, str], NodePairResult],
    console: Console,
):
    """Print detailed EFA test failure information."""
    failed_pairs = [
        (key, result) for key, result in results.items()
        if result.failed_tests and result.successful_pairs < result.total_pairs
    ]

    if not failed_pairs:
        console.print("\n[bold green]All EFA fi_pingpong tests passed![/bold green]")
        return

    console.print("\n[bold red]EFA Failure Details[/bold red]")
    console.print("[dim]" + "=" * 80 + "[/dim]\n")

    for (node_a, node_b), result in sorted(failed_pairs):
        console.print(f"[bold yellow]Node Pair: {node_a} -> {node_b}[/bold yellow]")
        console.print(f"  Status: {result.successful_pairs}/{result.total_pairs} tests passed")
        console.print(f"  Failed device pairs:")

        for failed in result.failed_tests[:20]:
            console.print(
                f"    [red]x[/red] {failed.src_device} -> {failed.dst_device}"
            )
            if failed.error_msg:
                error_preview = failed.error_msg.replace('\n', ' ')[:100]
                console.print(f"      [dim]{error_preview}[/dim]")

        if len(result.failed_tests) > 20:
            console.print(f"    [dim]... and {len(result.failed_tests) - 20} more failures[/dim]")
        console.print()


def load_config(config_path: str) -> dict:
    """Load and validate the configuration file."""
    with open(config_path, 'r') as f:
        config = json.load(f)
    
    if 'namespace' not in config:
        raise ValueError("Missing required field 'namespace' in config file")

    network_type = config.get('network_type', 'roce')
    if network_type not in ('roce', 'efa'):
        raise ValueError(f"Invalid network_type '{network_type}', must be 'roce' or 'efa'")

    has_nodes = 'nodes' in config and config['nodes']
    has_pods = 'pods' in config and config['pods']

    if not has_nodes and not has_pods:
        raise ValueError("Config must have either 'nodes' or 'pods' list (non-empty)")
    if has_nodes and has_pods:
        raise ValueError("Config cannot have both 'nodes' and 'pods' - use one or the other")

    if network_type == 'efa':
        if 'devices' not in config or not config['devices']:
            raise ValueError("EFA config requires non-empty 'devices' list")
        mw = config.get('max_workers', EFA_MAX_WORKERS)
        if mw > EFA_MAX_WORKERS:
            raise ValueError(
                f"max_workers={mw} exceeds EFA safe limit of {EFA_MAX_WORKERS}"
            )
    else:
        if 'interfaces' not in config or not config['interfaces']:
            raise ValueError("RoCE config requires non-empty 'interfaces' list")

    return config


def main():
    parser = argparse.ArgumentParser(
        description='Pingmesh connectivity test (RoCE ping or EFA fi_pingpong)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example:
    uv run ./pingmesh.py roce_cluster_info.json
    uv run ./pingmesh.py pingmesh-efa-eks.json

RoCE config (ICMP ping between NIC IPs):
    {
        "namespace": "default",
        "network_type": "roce",
        "nodes": ["node-1", "node-2"],
        "interfaces": ["rdma0", "rdma1"],
        "max_workers": 10
    }

EFA config (fi_pingpong over EFA datapath, full NxN device mesh):
    {
        "namespace": "default",
        "network_type": "efa",
        "nodes": ["node-1", "node-2"],
        "devices": ["rdmap79s0", "rdmap80s0", ...],
        "max_workers": 8
    }
        """
    )
    parser.add_argument('config', help='Path to JSON configuration file')

    args = parser.parse_args()
    console = Console()

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
    network_type = config.get('network_type', 'roce')
    max_workers = config.get('max_workers', 10 if network_type == 'roce' else EFA_MAX_WORKERS)

    # Determine entity mode
    if 'pods' in config and config['pods']:
        entities = config['pods']
        entity_to_pod = {pod: pod for pod in entities}
        mode = "pods"
    else:
        entities = config['nodes']
        entity_to_pod = None
        mode = "nodes"

    if network_type == 'efa':
        _run_efa_mode(config, namespace, entities, entity_to_pod, mode, max_workers, console)
    else:
        _run_roce_mode(config, namespace, entities, entity_to_pod, mode, max_workers, console)


def _run_efa_mode(config, namespace, entities, entity_to_pod, mode, max_workers, console):
    """EFA fi_pingpong full mesh test."""
    devices = config['devices']

    console.print("\n[bold blue]╔═══════════════════════════════════════════════╗[/bold blue]")
    console.print("[bold blue]║      EFA Pingmesh Connectivity Test           ║[/bold blue]")
    console.print("[bold blue]╚═══════════════════════════════════════════════╝[/bold blue]")

    console.print(f"\n[bold]Configuration:[/bold]")
    console.print(f"  Namespace: {namespace}")
    console.print(f"  Network type: EFA (fi_pingpong)")
    console.print(f"  Mode: {mode}")
    console.print(f"  {'Pods' if mode == 'pods' else 'Nodes'}: {len(entities)}")
    console.print(f"  EFA devices: {len(devices)}")
    console.print(f"  Tests per node pair: {len(devices) * len(devices)}")
    console.print(f"  Max workers: {max_workers}")

    results = run_efa_pingmesh_tests(
        namespace, entities, devices, console,
        entity_to_pod=entity_to_pod, max_workers=max_workers,
    )

    print_results_matrix(entities, results, console, mode=mode)
    print_summary(results, console)
    print_efa_failure_details(results, console)

    has_failures = any(
        r.successful_pairs < r.total_pairs
        for r in results.values()
        if r.total_pairs > 0
    )
    sys.exit(1 if has_failures else 0)


def _run_roce_mode(config, namespace, entities, entity_to_pod, mode, max_workers, console):
    """Original RoCE ICMP ping test."""
    interfaces = config['interfaces']

    console.print("\n[bold blue]╔═══════════════════════════════════════════════╗[/bold blue]")
    console.print("[bold blue]║    RoCE Cluster Pingmesh Connectivity Test    ║[/bold blue]")
    console.print("[bold blue]╚═══════════════════════════════════════════════╝[/bold blue]")

    console.print(f"\n[bold]Configuration:[/bold]")
    console.print(f"  Namespace: {namespace}")
    console.print(f"  Mode: {mode}")
    console.print(f"  {'Pods' if mode == 'pods' else 'Nodes'}: {len(entities)}")
    console.print(f"  Interfaces per {'pod' if mode == 'pods' else 'node'}: {len(interfaces)}")
    console.print(f"  Expected pairs per pair: {len(interfaces) * len(interfaces)}")
    console.print(f"  Max workers: {max_workers}")

    entity_interface_ips = collect_interface_ips(
        namespace, entities, interfaces, console,
        entity_to_pod=entity_to_pod, max_workers=max_workers
    )

    total_ips = sum(len(ips) for ips in entity_interface_ips.values())
    if total_ips == 0:
        console.print("\n[bold red]Error:[/bold red] No interface IPs found. Check that:")
        console.print("  - Pods are running in the specified namespace")
        console.print("  - Interface names are correct")
        console.print("  - Pods have network access")
        sys.exit(1)

    console.print(f"\n[green]✓[/green] Collected {total_ips} interface IPs across {len(entity_interface_ips)} {'pods' if mode == 'pods' else 'nodes'}")

    results = run_pingmesh_tests(
        namespace, entities, interfaces, entity_interface_ips, console,
        entity_to_pod=entity_to_pod, max_workers=max_workers
    )

    print_results_matrix(entities, results, console, mode=mode)
    print_summary(results, console)
    print_failure_details(results, console)

    has_failures = any(
        r.successful_pairs < r.total_pairs
        for r in results.values()
        if r.total_pairs > 0
    )
    sys.exit(1 if has_failures else 0)


if __name__ == "__main__":
    main()
