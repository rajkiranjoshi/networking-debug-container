#!/usr/bin/env python3
"""
Intra-host GPU-to-NIC RDMA bandwidth matrix test.

Runs ib_write_bw or ib_read_bw in localhost loopback mode on a single
networking-debug-pod. For each GPU x NIC pair:

  - Server: host memory on the NIC, bound to NIC NUMA
  - Client: GPU-pinned memory on the same NIC, bound to GPU NUMA

Usage:
    uv run ./gpu_nic_bandwidth.py config.json
    uv run ./gpu_nic_bandwidth.py --json config.json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, asdict
from typing import Optional

from rich.console import Console
from rich.table import Table
from rich.text import Text


BASE_PORT = 18615
DEFAULT_MSG_SIZE = 1048576  # 1 MiB
DEFAULT_NUM_ITERS = 5000


@dataclass
class BandwidthResult:
    gpu: str
    nic: str
    port: int
    gpu_numa: int = 0
    nic_numa: int = 0
    bw_avg_gbps: Optional[float] = None
    bw_peak_gbps: Optional[float] = None
    success: bool = False
    error_msg: str = ""


def get_pod_name(config: dict) -> str:
    if config.get("pod"):
        return config["pod"]
    if config.get("node"):
        return f"networking-debug-pod-{config['node']}"
    raise ValueError("Config must specify either 'pod' or 'node'")


def run_kubectl_command(
    namespace: str, pod: str, command: str, timeout: int = 120
) -> tuple[bool, str]:
    kubectl_cmd = [
        "kubectl", "exec", "-n", namespace, pod, "--",
        "/bin/bash", "-c", command,
    ]
    try:
        result = subprocess.run(
            kubectl_cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        output = (result.stdout or "") + (result.stderr or "")
        if result.returncode == 0:
            return True, result.stdout.strip()
        return False, output.strip()
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as exc:
        return False, str(exc)


def run_kubectl_background(namespace: str, pod: str, command: str) -> subprocess.Popen:
    kubectl_cmd = [
        "kubectl", "exec", "-n", namespace, pod, "--",
        "/bin/bash", "-c", command,
    ]
    return subprocess.Popen(
        kubectl_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def get_numa_node_for_pci(namespace: str, pod: str, pci_addr: str) -> int:
    normalized = pci_addr.strip().lower()
    if re.match(r"^[0-9a-f]{8}:", normalized):
        normalized = f"{int(normalized[:8], 16):04x}:{normalized[9:]}"
    command = f"cat /sys/bus/pci/devices/{normalized}/numa_node 2>/dev/null || echo 0"
    success, output = run_kubectl_command(namespace, pod, command, timeout=30)
    if success and output:
        try:
            numa_node = int(output.strip())
            return 0 if numa_node == -1 else numa_node
        except ValueError:
            pass
    return 0


def get_numa_node_for_hca(namespace: str, pod: str, hca_id: str) -> int:
    command = f"cat /sys/class/infiniband/{hca_id}/device/numa_node 2>/dev/null || echo 0"
    success, output = run_kubectl_command(namespace, pod, command, timeout=30)
    if success and output:
        try:
            numa_node = int(output.strip())
            return 0 if numa_node == -1 else numa_node
        except ValueError:
            pass
    return 0


def get_numa_node_for_gpu(namespace: str, pod: str, gpu: str, gpu_type: str) -> int:
    if gpu_type == "rocm":
        return 0

    command = (
        f"nvidia-smi -i {gpu} --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null"
    )
    success, output = run_kubectl_command(namespace, pod, command, timeout=30)
    if success and output.strip():
        return get_numa_node_for_pci(namespace, pod, output.strip())
    return 0


def verify_pod_running(namespace: str, pod: str) -> tuple[bool, str]:
    cmd = [
        "kubectl", "get", "pod", pod, "-n", namespace,
        "-o", "jsonpath={.status.phase}",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            return False, result.stderr.strip() or f"Pod '{pod}' not found in namespace '{namespace}'"
        phase = result.stdout.strip()
        if phase != "Running":
            return False, f"Pod '{pod}' is not Running (phase={phase})"
        return True, ""
    except Exception as exc:
        return False, str(exc)


def extract_bandwidth_metrics(text: str) -> dict[str, float]:
    """Extract bandwidth fields from perftest JSON or stdout."""
    metrics: dict[str, float] = {}
    for json_key, out_key in (("BW_average", "bw_avg"), ("BW_peak", "bw_peak")):
        match = re.search(rf'"{re.escape(json_key)}"\s*:\s*([0-9.eE+-]+)', text)
        if not match:
            match = re.search(rf'\b{re.escape(json_key)}\s*:\s*([0-9.eE+-]+)', text)
        if match:
            metrics[out_key] = float(match.group(1))

    if metrics:
        return metrics

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        # #bytes #iterations BW peak[Gb/sec] BW average[Gb/sec] ...
        if len(parts) >= 5 and parts[0].isdigit():
            try:
                metrics["bw_peak"] = float(parts[3])
                metrics["bw_avg"] = float(parts[4])
                return metrics
            except ValueError:
                continue
    return metrics


def parse_ib_bw_output(text: str) -> dict[str, float]:
    text = text.strip()
    if not text:
        return {}

    try:
        data = json.loads(text)
        results = data.get("results", data)
        parsed: dict[str, float] = {}
        if "BW_average" in results:
            parsed["bw_avg"] = float(results["BW_average"])
        if "BW_peak" in results:
            parsed["bw_peak"] = float(results["BW_peak"])
        if parsed:
            return parsed
    except (json.JSONDecodeError, TypeError, ValueError):
        pass

    return extract_bandwidth_metrics(text)


def ib_binary_for_op(rdma_op: str) -> str:
    if rdma_op == "read":
        return "ib_read_bw"
    if rdma_op == "write":
        return "ib_write_bw"
    raise ValueError(f"Invalid rdma_op: {rdma_op}. Must be 'read' or 'write'")


def gpu_flag(gpu_type: str, gpu: str) -> str:
    if gpu_type == "rocm":
        return f" --use_rocm={gpu}"
    return f" --use_cuda={gpu}"


@dataclass
class TestPair:
    gpu: str
    nic: str
    port: int
    gpu_numa: int
    nic_numa: int


def discover_numa_topology(
    namespace: str,
    pod: str,
    gpus: list[str],
    nics: list[str],
    gpu_type: str,
) -> tuple[dict[str, int], dict[str, int]]:
    """Discover GPU and NIC NUMA nodes in a single kubectl exec."""
    gpu_numa: dict[str, int] = {g: 0 for g in gpus}
    nic_numa: dict[str, int] = {n: 0 for n in nics}

    nic_loop = " ".join(nics)
    gpu_loop = " ".join(gpus)
    gpu_section = ""
    if gpu_type == "cuda":
        gpu_section = f"""
for g in {gpu_loop}; do
  bus=$(nvidia-smi -i $g --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "$bus" =~ ^[0-9a-f]{{8}}: ]]; then
    d="${{bus:0:8}}"
    rest="${{bus:9}}"
    bus=$(printf "%04x:%s" "$((16#$d))" "$rest")
  fi
  numa=$(cat /sys/bus/pci/devices/$bus/numa_node 2>/dev/null || echo 0)
  [[ "$numa" == "-1" ]] && numa=0
  echo "GPU $g $numa"
done"""

    script = f"""
for nic in {nic_loop}; do
  numa=$(cat /sys/class/infiniband/$nic/device/numa_node 2>/dev/null || echo 0)
  [[ "$numa" == "-1" ]] && numa=0
  echo "NIC $nic $numa"
done{gpu_section}
"""
    success, output = run_kubectl_command(namespace, pod, script.strip(), timeout=60)
    if success:
        for line in output.splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[0] == "GPU":
                gpu_numa[parts[1]] = int(parts[2])
            elif len(parts) == 3 and parts[0] == "NIC":
                nic_numa[parts[1]] = int(parts[2])
        return gpu_numa, nic_numa

    # Fallback: per-device lookups if batched script fails
    for nic in nics:
        nic_numa[nic] = get_numa_node_for_hca(namespace, pod, nic)
    for gpu in gpus:
        gpu_numa[gpu] = get_numa_node_for_gpu(namespace, pod, gpu, gpu_type)
    return gpu_numa, nic_numa


def build_test_pairs(
    gpus: list[str],
    nics: list[str],
    gpu_numa_map: dict[str, int],
    nic_numa_map: dict[str, int],
) -> list[TestPair]:
    pairs: list[TestPair] = []
    for gpu_idx, gpu in enumerate(gpus):
        for nic_idx, nic in enumerate(nics):
            pairs.append(TestPair(
                gpu=gpu,
                nic=nic,
                port=assign_port(gpu_idx, nic_idx, len(nics)),
                gpu_numa=gpu_numa_map[gpu],
                nic_numa=nic_numa_map[nic],
            ))
    return pairs


def common_bw_flags(
    pair: TestPair,
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
) -> str:
    test_param = test_mode_flags(duration, num_iters)
    return f"-d {pair.nic} -p {pair.port} -s {msg_size} -q {num_qps} {test_param} --report_gbits"


def build_server_cmd(
    ib_binary: str,
    pair: TestPair,
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
) -> str:
    flags = common_bw_flags(pair, msg_size, num_qps, duration, num_iters)
    return (
        f"numactl --cpunodebind={pair.nic_numa} --membind={pair.nic_numa} "
        f"{ib_binary} {flags}"
    )


def build_client_cmd(
    ib_binary: str,
    pair: TestPair,
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
    gpu_type: str,
    client_json: str,
    localhost_target: str,
) -> str:
    flags = common_bw_flags(pair, msg_size, num_qps, duration, num_iters)
    return (
        f"numactl --cpunodebind={pair.gpu_numa} --membind={pair.gpu_numa} "
        f"{ib_binary} {flags} "
        f"{gpu_flag(gpu_type, pair.gpu)} "
        f"--out_json --out_json_file={client_json} "
        f"{localhost_target}"
    )


def cleanup_servers(
    namespace: str,
    pod: str,
    ib_binary: str,
    pairs: list[TestPair],
    server_procs: list[subprocess.Popen],
) -> None:
    for proc in server_procs:
        if proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
    port_list = " ".join(str(p.port) for p in pairs)
    run_kubectl_command(
        namespace, pod,
        f"for port in {port_list}; do pkill -f '{ib_binary} -p '\"$port\" || true; done",
        timeout=30,
    )


def run_client(
    namespace: str,
    pod: str,
    pair: TestPair,
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
    gpu_type: str,
    rdma_op: str,
    localhost_target: str,
) -> BandwidthResult:
    result = BandwidthResult(
        gpu=pair.gpu, nic=pair.nic, port=pair.port,
        gpu_numa=pair.gpu_numa, nic_numa=pair.nic_numa,
    )
    ib_binary = ib_binary_for_op(rdma_op)
    client_json = f"/tmp/gpu_nic_bw_client_{pair.gpu}_{pair.nic}_{uuid.uuid4().hex[:8]}.json"
    client_cmd = build_client_cmd(
        ib_binary, pair, msg_size, num_qps, duration, num_iters,
        gpu_type, client_json, localhost_target,
    )

    try:
        success, output = run_kubectl_command(
            namespace, pod, client_cmd, timeout=client_timeout(duration, num_iters),
        )
        if not success:
            result.error_msg = output
            return result

        cat_ok, json_content = run_kubectl_command(namespace, pod, f"cat {client_json}", timeout=30)
        run_kubectl_command(namespace, pod, f"rm -f {client_json}", timeout=10)
        metrics = parse_ib_bw_output(json_content if cat_ok else output)
        if not metrics and cat_ok:
            metrics = parse_ib_bw_output(output)

        if not metrics or "bw_avg" not in metrics:
            result.error_msg = f"Could not parse bandwidth from output: {output[:200]}"
            return result

        result.bw_avg_gbps = metrics["bw_avg"]
        result.bw_peak_gbps = metrics.get("bw_peak")
        result.success = True
        return result
    except subprocess.TimeoutExpired:
        result.error_msg = "Test timed out"
        return result
    except Exception as exc:
        result.error_msg = str(exc)
        return result


def run_matrix_test(
    namespace: str,
    pod: str,
    pairs: list[TestPair],
    msg_size: int,
    num_qps: int,
    duration: Optional[int],
    num_iters: Optional[int],
    gpu_type: str,
    rdma_op: str,
    localhost_target: str,
    server_startup_delay: float,
    console: Optional[Console],
) -> list[BandwidthResult]:
    ib_binary = ib_binary_for_op(rdma_op)
    server_procs: list[subprocess.Popen] = []
    server_errors: dict[tuple[str, str], str] = {}

    if console:
        console.print(f"\n[bold cyan]Starting {len(pairs)} servers in parallel...[/bold cyan]", flush=True)
        console.print("[dim]NUMA binding: server -> NIC NUMA, client -> GPU NUMA[/dim]\n", flush=True)

    try:
        for i, pair in enumerate(pairs):
            server_cmd = build_server_cmd(
                ib_binary, pair, msg_size, num_qps, duration, num_iters,
            )
            server_procs.append(run_kubectl_background(namespace, pod, server_cmd))
            if console and (i + 1) % 16 == 0:
                console.print(
                    f"  [dim]Launched {i + 1}/{len(pairs)} server processes...[/dim]",
                    flush=True,
                )

        time.sleep(server_startup_delay)

        for pair, proc in zip(pairs, server_procs):
            if proc.poll() is not None:
                _, stderr = proc.communicate(timeout=5)
                server_errors[(pair.gpu, pair.nic)] = f"Server exited early: {stderr.strip()}"

        if console:
            started = len(pairs) - len(server_errors)
            console.print(f"  [green]{started}/{len(pairs)}[/green] servers ready\n")
            console.print("[bold cyan]Running clients serially...[/bold cyan]\n")

        results: list[BandwidthResult] = []
        for pair in pairs:
            cross = "cross-NUMA" if pair.gpu_numa != pair.nic_numa else "same-NUMA"
            if console:
                console.print(
                    f"  GPU {pair.gpu} (NUMA {pair.gpu_numa}) / {pair.nic} "
                    f"(NUMA {pair.nic_numa}, {cross}) port {pair.port}...",
                    end=" ",
                )

            key = (pair.gpu, pair.nic)
            if key in server_errors:
                result = BandwidthResult(
                    gpu=pair.gpu, nic=pair.nic, port=pair.port,
                    gpu_numa=pair.gpu_numa, nic_numa=pair.nic_numa,
                    error_msg=server_errors[key],
                )
            else:
                result = run_client(
                    namespace, pod, pair, msg_size, num_qps,
                    duration, num_iters, gpu_type, rdma_op, localhost_target,
                )

            results.append(result)

            if console:
                if result.success and result.bw_avg_gbps is not None:
                    msg = f"avg {result.bw_avg_gbps:.2f} Gbps"
                    if result.bw_peak_gbps is not None:
                        msg += f", peak {result.bw_peak_gbps:.2f} Gbps"
                    console.print(f"[green]✓[/green] {msg}", highlight=False)
                else:
                    console.print(f"[red]✗[/red] {result.error_msg[:80]}", highlight=False)

        return results
    finally:
        cleanup_servers(namespace, pod, ib_binary, pairs, server_procs)


def test_mode_flags(duration: Optional[int], num_iters: Optional[int]) -> str:
    if num_iters is not None:
        return f"-n {num_iters}"
    return f"-D {duration}"


def client_timeout(duration: Optional[int], num_iters: Optional[int]) -> int:
    if num_iters is not None:
        return 600
    return (duration or 10) + 300


def build_bw_matrix(
    results: list[BandwidthResult],
    gpus: list[str],
    nics: list[str],
    field: str,
) -> dict[str, dict[str, Optional[float]]]:
    lookup = {(r.gpu, r.nic): r for r in results}
    matrix: dict[str, dict[str, Optional[float]]] = {}
    for gpu in gpus:
        matrix[gpu] = {}
        for nic in nics:
            entry = lookup.get((gpu, nic))
            if entry and entry.success:
                matrix[gpu][nic] = getattr(entry, field)
            else:
                matrix[gpu][nic] = None
    return matrix


def print_bw_matrix(
    results: list[BandwidthResult],
    gpus: list[str],
    nics: list[str],
    field: str,
    title: str,
    console: Console,
) -> None:
    console.print(f"\n[bold]{title}[/bold] [dim](Gbps)[/dim]\n")

    table = Table(show_header=True, header_style="bold")
    table.add_column("GPU \\ NIC", justify="left")
    for nic in nics:
        table.add_column(nic, justify="right")

    lookup = {(r.gpu, r.nic): r for r in results}
    for gpu in gpus:
        row = [gpu]
        for nic in nics:
            entry = lookup.get((gpu, nic))
            value = getattr(entry, field, None) if entry and entry.success else None
            if value is not None:
                row.append(f"{value:.2f}")
            elif entry and not entry.success:
                row.append(Text("FAIL", style="bold red"))
            else:
                row.append("-")
        table.add_row(*row)

    console.print(table)


def print_result_matrices(
    results: list[BandwidthResult],
    gpus: list[str],
    nics: list[str],
    console: Console,
    *,
    show_peak: bool,
) -> None:
    console.print("\n[bold cyan]Average Bandwidth[/bold cyan]")
    print_bw_matrix(results, gpus, nics, "bw_avg_gbps", "Average (BW_average)", console)

    if show_peak:
        has_peak = any(r.success and r.bw_peak_gbps is not None for r in results)
        if has_peak:
            console.print("\n[bold cyan]Peak Bandwidth[/bold cyan]")
            print_bw_matrix(results, gpus, nics, "bw_peak_gbps", "Peak (BW_peak)", console)

    failed = [r for r in results if not r.success]
    if failed:
        console.print("\n[bold red]Failures[/bold red]")
        for r in failed:
            console.print(f"  GPU {r.gpu} / {r.nic}: {r.error_msg[:120]}")


def output_json_results(
    results: list[BandwidthResult],
    config: dict,
    pod: str,
    elapsed_time: float,
) -> None:
    gpus = [str(g) for g in config["gpus"]]
    nics = config["nics"]
    successful = [r for r in results if r.success]
    avg_matrix = build_bw_matrix(results, gpus, nics, "bw_avg_gbps")
    peak_matrix = build_bw_matrix(results, gpus, nics, "bw_peak_gbps")

    output_config = {
        "namespace": config["namespace"],
        "pod": pod,
        "gpus": gpus,
        "nics": nics,
        "gpu_type": config["gpu_type"],
        "rdma_op": config["rdma_op"],
        "msg_size": config["msg_size"],
        "num_qps": config["num_qps"],
        "localhost_target": config["localhost_target"],
        "test_mode": "iterations" if config.get("num_iters") else "duration",
    }
    if config.get("num_iters"):
        output_config["num_iters"] = config["num_iters"]
    else:
        output_config["duration"] = config["duration"]

    output = {
        "config": output_config,
        "elapsed_time_seconds": round(elapsed_time, 2),
        "summary": {
            "total_pairs": len(results),
            "successful": len(successful),
            "failed": len(results) - len(successful),
        },
        "matrix_avg_gbps": avg_matrix,
        "matrix_peak_gbps": peak_matrix,
        "matrix_gbps": avg_matrix,
        "results": [asdict(r) for r in results],
    }
    print(json.dumps(output, indent=2))


def load_config(config_path: str) -> dict:
    with open(config_path, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    if "namespace" not in config:
        raise ValueError("Missing required field 'namespace' in config file")

    has_pod = bool(config.get("pod"))
    has_node = bool(config.get("node"))
    if has_pod and has_node:
        raise ValueError("Config cannot have both 'pod' and 'node' - use one or the other")
    if not has_pod and not has_node:
        raise ValueError("Config must specify either 'pod' or 'node'")

    if not config.get("gpus"):
        raise ValueError("'gpus' list cannot be empty")
    if not config.get("nics"):
        raise ValueError("'nics' list cannot be empty")

    has_duration = "duration" in config
    has_iters = "num_iters" in config
    if has_duration and has_iters:
        raise ValueError("'duration' and 'num_iters' are mutually exclusive - specify only one")
    if not has_duration and not has_iters:
        config["num_iters"] = DEFAULT_NUM_ITERS

    config["gpus"] = [str(g) for g in config["gpus"]]
    config.setdefault("gpu_type", "cuda")
    config.setdefault("rdma_op", "write")
    config.setdefault("msg_size", DEFAULT_MSG_SIZE)
    config.setdefault("num_qps", 4)
    config.setdefault("localhost_target", "127.0.0.1")
    config.setdefault("server_startup_delay", 2.0)

    if config["gpu_type"] not in ("cuda", "rocm"):
        raise ValueError("gpu_type must be 'cuda' or 'rocm'")
    if config["rdma_op"] not in ("read", "write"):
        raise ValueError("rdma_op must be 'read' or 'write'")

    return config


def assign_port(gpu_idx: int, nic_idx: int, num_nics: int) -> int:
    return BASE_PORT + gpu_idx * num_nics + nic_idx


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Intra-host GPU-to-NIC RDMA bandwidth matrix (localhost loopback)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Example:
    uv run ./gpu_nic_bandwidth.py 8gpu-8nic-aks-h100.json
    uv run ./gpu_nic_bandwidth.py --json 8gpu-8nic-aks-h100.json

Config file format (JSON):
    {{
        "namespace": "default",
        "pod": "networking-debug-pod-aks-gpunp-12730235-vmss000000",
        "gpus": ["0", "1", "2", "3", "4", "5", "6", "7"],
        "nics": ["mlx5_0", "mlx5_1", "mlx5_2", "mlx5_3", "mlx5_4", "mlx5_5", "mlx5_6", "mlx5_7"],
        "msg_size": {DEFAULT_MSG_SIZE},
        "num_qps": 4,
        "num_iters": 5000
    }}

Use "node" instead of "pod" when the pod name follows deploy_pod_to_node.sh convention.
Use "num_iters" instead of "duration" for iteration-based tests (enables peak BW).
        """,
    )
    parser.add_argument("config", help="Path to JSON configuration file")
    parser.add_argument(
        "--json", action="store_true", dest="json_output",
        help="Output results as JSON (suppresses human-readable output)",
    )
    parser.add_argument(
        "--no-peak",
        action="store_true",
        help="Print only the average bandwidth matrix (skip peak matrix)",
    )
    args = parser.parse_args()

    console = None if args.json_output else Console()

    try:
        config = load_config(args.config)
    except FileNotFoundError:
        msg = f"Config file not found: {args.config}"
        if console:
            console.print(f"[bold red]Error:[/bold red] {msg}")
        else:
            print(json.dumps({"error": msg}), file=sys.stderr)
        sys.exit(1)
    except (json.JSONDecodeError, ValueError) as exc:
        if console:
            console.print(f"[bold red]Error:[/bold red] {exc}")
        else:
            print(json.dumps({"error": str(exc)}), file=sys.stderr)
        sys.exit(1)

    namespace = config["namespace"]
    pod = get_pod_name(config)
    gpus = config["gpus"]
    nics = config["nics"]
    duration = config.get("duration")
    num_iters = config.get("num_iters")
    ib_binary = ib_binary_for_op(config["rdma_op"])

    if console:
        console.print("\n[bold blue]╔════════════════════════════════════════════════════╗[/bold blue]")
        console.print("[bold blue]║      Intra-Host GPU–NIC Bandwidth Matrix Test      ║[/bold blue]")
        console.print("[bold blue]╚════════════════════════════════════════════════════╝[/bold blue]")
        console.print("\n[bold]Configuration:[/bold]")
        console.print(f"  Namespace:   {namespace}")
        console.print(f"  Pod:         {pod}")
        console.print(f"  Tool:        {ib_binary} (localhost loopback)")
        console.print(f"  GPUs:        {', '.join(gpus)}")
        console.print(f"  NICs:        {', '.join(nics)}")
        console.print(f"  GPU type:    {config['gpu_type']}")
        console.print(f"  Message size:{config['msg_size']} bytes ({config['msg_size'] / 1024 / 1024:.1f} MiB)")
        console.print(f"  Num QPs:     {config['num_qps']}")
        if num_iters is not None:
            console.print(f"  Iterations:  {num_iters}")
        else:
            console.print(f"  Duration:    {duration} seconds")
        console.print(f"  Matrix size: {len(gpus)} x {len(nics)} = {len(gpus) * len(nics)} pairs")

    ok, err = verify_pod_running(namespace, pod)
    if not ok:
        if console:
            console.print(f"\n[bold red]Error:[/bold red] {err}")
        else:
            print(json.dumps({"error": err}), file=sys.stderr)
        sys.exit(1)

    if console:
        console.print("\n[bold cyan]Discovering NUMA topology...[/bold cyan]", end=" ", flush=True)
    gpu_numa_map, nic_numa_map = discover_numa_topology(
        namespace, pod, gpus, nics, config["gpu_type"],
    )
    if console:
        console.print("[green]done[/green]", flush=True)

    pairs = build_test_pairs(gpus, nics, gpu_numa_map, nic_numa_map)
    start_time = time.time()
    results = run_matrix_test(
        namespace=namespace,
        pod=pod,
        pairs=pairs,
        msg_size=config["msg_size"],
        num_qps=config["num_qps"],
        duration=duration,
        num_iters=num_iters,
        gpu_type=config["gpu_type"],
        rdma_op=config["rdma_op"],
        localhost_target=config["localhost_target"],
        server_startup_delay=config["server_startup_delay"],
        console=console,
    )
    elapsed_time = time.time() - start_time
    show_peak = not args.no_peak and num_iters is not None

    if console:
        console.print(f"\n  [dim]Total test time: {elapsed_time:.1f} seconds[/dim]")
        print_result_matrices(results, gpus, nics, console, show_peak=show_peak)
    else:
        output_json_results(results, config, pod, elapsed_time)

    has_failures = any(not r.success for r in results)
    sys.exit(1 if has_failures else 0)


if __name__ == "__main__":
    main()
