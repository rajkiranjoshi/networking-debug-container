import io
import json
import unittest
from unittest.mock import patch

from rich.console import Console

import pingmesh


class InterfaceDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.console = Console(file=self.output, color_system=None, width=160)
        self.pods = {"pod-a": "pod-a", "pod-b": "pod-b"}

    def test_literal_interface_keeps_existing_lookup(self):
        with patch.object(pingmesh, "run_kubectl_command", return_value=(True, "10.0.0.1\n10.0.0.2")) as run:
            ips = pingmesh.collect_interface_ips(
                "ns", ["pod-a"], ["net1"], self.console, self.pods
            )

        self.assertEqual(ips, {"pod-a": {"net1": "10.0.0.1"}})
        run.assert_called_once_with(
            "ns", "pod-a", "ip -4 addr show net1 2>/dev/null | grep -oP 'inet \\K[0-9.]+'"
        )

    def test_wildcard_resolves_independently_in_each_pod(self):
        names = {"pod-a": "net1vf0", "pod-b": "net1vf1"}
        addresses = {"pod-a": "10.0.0.1", "pod-b": "10.0.0.2"}

        def kubectl(namespace, pod, command):
            self.assertEqual(namespace, "ns")
            if command == "ip -j link show":
                return True, json.dumps([{"ifname": "lo"}, {"ifname": names[pod]}])
            self.assertIn(f"ip -4 addr show {names[pod]} ", command)
            self.assertNotIn("*", command)
            return True, addresses[pod]

        with patch.object(pingmesh, "run_kubectl_command", side_effect=kubectl):
            ips = pingmesh.collect_interface_ips(
                "ns", list(self.pods), ["net1*"], self.console, self.pods
            )

        self.assertEqual(ips, {
            "pod-a": {"net1vf0": "10.0.0.1"},
            "pod-b": {"net1vf1": "10.0.0.2"},
        })

    def test_multiple_matches_fail_before_ip_lookup(self):
        # Link discovery must reject both interfaces even without address data.
        links = json.dumps([{"ifname": "net1vf1"}, {"ifname": "net1vf0"}])
        with patch.object(pingmesh, "run_kubectl_command", return_value=(True, links)) as run:
            with self.assertRaisesRegex(
                pingmesh.InterfaceDiscoveryError,
                r"Pod pod-a: interface pattern 'net1\*' matched 2 interfaces \(net1vf0, net1vf1\)",
            ):
                pingmesh.collect_interface_ips(
                    "ns", ["pod-a"], ["net1*"], self.console, self.pods
                )
        run.assert_called_once_with("ns", "pod-a", "ip -j link show")

    def test_zero_matches_fail_discovery(self):
        with patch.object(pingmesh, "run_kubectl_command", return_value=(True, '[{"ifname": "net2vf0"}]')):
            with self.assertRaisesRegex(pingmesh.InterfaceDiscoveryError, "matched 0 interfaces"):
                pingmesh.collect_interface_ips(
                    "ns", ["pod-a"], ["net1*"], self.console, self.pods
                )

    def test_glob_matching_uses_full_case_sensitive_names(self):
        links = json.dumps([{"ifname": name} for name in ("net1vf0", "Net1vf0", "othernet1vf0")])
        with patch.object(pingmesh, "run_kubectl_command", return_value=(True, links)):
            for pattern in ("net1*", "net?vf0", "net[12]vf0"):
                with self.subTest(pattern=pattern):
                    self.assertEqual(
                        pingmesh.resolve_interface_name("ns", "pod-a", pattern, self.pods),
                        "net1vf0",
                    )

    def test_nodes_mode_resolves_in_derived_pod(self):
        with patch.object(pingmesh, "run_kubectl_command", return_value=(True, '[{"ifname": "net1vf0"}]')) as run:
            self.assertEqual(pingmesh.resolve_interface_name("ns", "node-a", "net1*"), "net1vf0")
        run.assert_called_once_with("ns", "networking-debug-pod-node-a", "ip -j link show")

    def test_unusable_interface_lists_fail_discovery(self):
        for response in ((False, "permission denied"), (True, "not JSON"), (True, '[{}]')):
            with self.subTest(response=response):
                with patch.object(pingmesh, "run_kubectl_command", return_value=response):
                    with self.assertRaises(pingmesh.InterfaceDiscoveryError):
                        pingmesh.collect_interface_ips(
                            "ns", ["pod-a"], ["net1*"], self.console, self.pods
                        )

    def test_ambiguous_pattern_exits_before_any_ping_even_with_valid_ips(self):
        def kubectl(namespace, pod, command):
            if command == "ip -j link show":
                return True, '[{"ifname": "net1vf0"}, {"ifname": "net1vf1"}]'
            return True, "10.0.0.1"

        with patch.object(pingmesh, "run_kubectl_command", side_effect=kubectl), \
             patch.object(pingmesh, "run_pingmesh_tests") as ping:
            with self.assertRaises(SystemExit) as exit_status:
                pingmesh._run_roce_mode(
                    {"interfaces": ["net2", "net1*"]}, "ns", list(self.pods),
                    self.pods, "pods", 2, self.console,
                )

        self.assertEqual(exit_status.exception.code, 1)
        ping.assert_not_called()
        self.assertIn("Interface discovery failed", self.output.getvalue())
        self.assertIn("net1vf0, net1vf1", self.output.getvalue())

    def test_missing_literal_interface_keeps_existing_behavior(self):
        with patch.object(pingmesh, "run_kubectl_command", return_value=(False, "not found")):
            ips = pingmesh.collect_interface_ips(
                "ns", ["pod-a"], ["net1"], self.console, self.pods
            )
        self.assertEqual(ips, {})


if __name__ == "__main__":
    unittest.main()
