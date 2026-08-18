import base64
import unittest
from urllib.parse import parse_qs, urlsplit

import exporter


def settings() -> exporter.Settings:
    return exporter.Settings(
        ignite2_endpoints=("http://ignite2-node1:8080", "http://ignite2-node2:8080"),
        ignite2_user="test-user",
        ignite2_password="test-password",
        ignite3_endpoints=("http://ignite3-node1:10300", "http://ignite3-node2:10300"),
        ignite3_user="test-user",
        ignite3_password="test-password",
        timeout_seconds=0.1,
    )


class ExporterTests(unittest.TestCase):
    def test_successful_collection_emits_valid_lab_metrics(self) -> None:
        expected_auth = "Basic " + base64.b64encode(
            b"test-user:test-password"
        ).decode()

        def fake_fetch(url, timeout, headers=None):
            parsed = urlsplit(url)
            if parsed.path == "/ignite":
                query = parse_qs(parsed.query)
                self.assertEqual(query["ignite.login"], ["test-user"])
                self.assertEqual(query["ignite.password"], ["test-password"])
                if query["cmd"] == ["version"]:
                    return {"successStatus": 0, "response": "2.18.0"}
                if query["cmd"] == ["currentstate"]:
                    return {"successStatus": 0, "response": True}
                return {
                    "successStatus": 0,
                    "response": [{"consistentId": "one"}, {"consistentId": "two"}],
                }
            self.assertEqual(headers["Authorization"], expected_auth)
            if parsed.path.endswith("/node/state"):
                return {"name": parsed.hostname, "state": "STARTED"}
            if parsed.path.endswith("/cluster/state"):
                return {
                    "igniteVersion": "3.1.0",
                    "clusterTag": {"clusterName": "ignite3-lab"},
                }
            if parsed.path.endswith("/topology/physical"):
                return [{"name": "one"}, {"name": "two"}]
            raise AssertionError(f"unexpected URL: {url}")

        metrics = exporter.render_metrics(exporter.collect(settings(), fake_fetch))

        self.assertIn('ignite_node_healthy{node="ignite2-node1",stack="ignite2"} 1', metrics)
        self.assertIn('ignite_node_healthy{node="ignite3-node2",stack="ignite3"} 1', metrics)
        self.assertIn('ignite_cluster_nodes{stack="ignite2"} 2', metrics)
        self.assertIn('ignite_cluster_nodes{stack="ignite3"} 2', metrics)
        self.assertIn('ignite_cluster_ready{stack="ignite2"} 1', metrics)
        self.assertIn('ignite_cluster_ready{stack="ignite3"} 1', metrics)
        self.assertIn(
            'ignite_cluster_info{name="ignite3-lab",stack="ignite3",version="3.1.0"} 1',
            metrics,
        )
        self.assertIn('ignite_exporter_scrape_success{stack="ignite2"} 1', metrics)
        self.assertIn('ignite_exporter_scrape_success{stack="ignite3"} 1', metrics)

    def test_failures_still_emit_zero_health_metrics(self) -> None:
        def failing_fetch(url, timeout, headers=None):
            raise OSError("unreachable")

        metrics = exporter.render_metrics(exporter.collect(settings(), failing_fetch))

        self.assertIn('ignite_node_up{node="ignite2-node1",stack="ignite2"} 0', metrics)
        self.assertIn('ignite_node_up{node="ignite3-node1",stack="ignite3"} 0', metrics)
        self.assertIn('ignite_cluster_topology_up{stack="ignite2"} 0', metrics)
        self.assertIn('ignite_cluster_topology_up{stack="ignite3"} 0', metrics)
        self.assertIn('ignite_exporter_scrape_success{stack="ignite2"} 0', metrics)
        self.assertIn('ignite_exporter_scrape_success{stack="ignite3"} 0', metrics)

    def test_label_values_are_escaped_for_prometheus(self) -> None:
        escaped = exporter._sample(
            "example_metric", 1, label='quote" slash\\ line\nnext'
        )
        self.assertEqual(
            escaped,
            'example_metric{label="quote\\" slash\\\\ line\\nnext"} 1',
        )

    def test_settings_reject_an_empty_endpoint_list(self) -> None:
        with self.assertRaisesRegex(ValueError, "at least one"):
            exporter._endpoint_list(" , ", exporter.DEFAULT_IGNITE2_ENDPOINTS)

    def test_duplicate_hostnames_use_ports_in_node_labels(self) -> None:
        self.assertEqual(
            exporter._node_names(
                ("http://127.0.0.1:8080", "http://127.0.0.1:8081")
            ),
            ("127.0.0.1:8080", "127.0.0.1:8081"),
        )


if __name__ == "__main__":
    unittest.main()
