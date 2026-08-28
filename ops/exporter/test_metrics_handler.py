"""Tests for the exporter's HTTP layer.

test_exporter.py covers the scrape and render functions. This file covers
MetricsHandler, which nothing exercised before: routing, status codes, headers,
and the collection-failure fallback.

That fallback matters beyond the handler. When collection raises, /metrics
still answers 200 and the only signal is a single
"ignite_exporter_collection_error 1" sample, which is what the
IgniteExporterCollectionFailing alert rule fires on. If the fallback ever
stopped emitting that line, or started returning a non-200 status, the alert
would silently never fire.

A real ThreadingHTTPServer on an ephemeral port is used rather than a mocked
socket, so the assertions cover what a Prometheus scrape actually receives. No
cluster is contacted: exporter.collect is replaced for the duration of a test.
"""

import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from threading import Thread

import exporter


def settings() -> exporter.Settings:
    return exporter.Settings(
        ignite2_endpoints=("http://ignite2-node1:8080",),
        ignite2_user="test-user",
        ignite2_password="test-password",
        ignite3_endpoints=("http://ignite3-node1:10300",),
        ignite3_user="test-user",
        ignite3_password="test-password",
        timeout_seconds=0.1,
    )


def healthy_results() -> list[exporter.StackResult]:
    return [
        exporter.StackResult(
            stack="ignite2",
            nodes=[
                exporter.NodeResult(
                    name="ignite2-node1",
                    api_up=True,
                    healthy=True,
                    state="ACTIVE",
                    version="2.18.0",
                )
            ],
            expected_nodes=1,
            cluster_nodes=1,
            topology_up=True,
            cluster_ready=True,
            cluster_name="ignite2-lab",
            cluster_version="2.18.0",
            scrape_success=True,
            duration_seconds=0.25,
        )
    ]


class MetricsHandlerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        exporter.MetricsHandler.settings = settings()
        # Port 0 lets the OS pick a free port, so parallel test runs and the
        # exporter's own 8000 never collide.
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), exporter.MetricsHandler)
        cls.server.daemon_threads = True
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def setUp(self) -> None:
        self._original_collect = exporter.collect
        self.addCleanup(setattr, exporter, "collect", self._original_collect)

    def get(self, path: str) -> tuple[int, str, dict[str, str]]:
        try:
            with urllib.request.urlopen(f"{self.base_url}{path}", timeout=5) as response:
                return response.status, response.read().decode(), dict(response.headers)
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode(), dict(error.headers)

    def test_metrics_endpoint_serves_the_prometheus_exposition_format(self) -> None:
        exporter.collect = lambda _settings: healthy_results()

        status, body, headers = self.get("/metrics")

        self.assertEqual(status, 200)
        self.assertEqual(
            headers["Content-Type"], "text/plain; version=0.0.4; charset=utf-8"
        )
        self.assertIn('ignite_node_up{node="ignite2-node1",stack="ignite2"} 1', body)
        self.assertIn('ignite_cluster_ready{stack="ignite2"} 1', body)
        self.assertIn("# TYPE ignite_node_up gauge", body)
        # A truncated body would still parse as text; check the declared length
        # matches what was actually written.
        self.assertEqual(int(headers["Content-Length"]), len(body.encode()))

    def test_collection_failure_still_answers_200_with_the_error_metric(self) -> None:
        # IgniteExporterCollectionFailing alerts on exactly this sample. A
        # non-200 here would make Prometheus record the scrape as failed and
        # the metric would never be stored, so both facts are asserted.
        def explode(_settings: exporter.Settings) -> list[exporter.StackResult]:
            raise RuntimeError("cluster unreachable")

        exporter.collect = explode

        status, body, headers = self.get("/metrics")

        self.assertEqual(status, 200)
        self.assertIn("ignite_exporter_collection_error 1", body)
        self.assertIn("# TYPE ignite_exporter_collection_error gauge", body)
        self.assertEqual(int(headers["Content-Length"]), len(body.encode()))

    def test_healthz_is_independent_of_collection(self) -> None:
        # The Compose healthcheck polls /healthz. It must stay green while the
        # cluster is down, or the container would be restarted for a fault
        # that is not its own.
        def explode(_settings: exporter.Settings) -> list[exporter.StackResult]:
            raise RuntimeError("cluster unreachable")

        exporter.collect = explode

        status, body, headers = self.get("/healthz")

        self.assertEqual(status, 200)
        self.assertEqual(body, "ok\n")
        self.assertEqual(headers["Content-Type"], "text/plain; charset=utf-8")

    def test_unknown_paths_return_404(self) -> None:
        for path in ("/", "/metrics/", "/admin", "/../etc/passwd"):
            with self.subTest(path=path):
                status, body, _ = self.get(path)
                self.assertEqual(status, 404)
                self.assertEqual(body, "not found\n")

    def test_query_strings_are_ignored_on_metrics(self) -> None:
        # Some scrapers append parameters; the path match must not break.
        exporter.collect = lambda _settings: healthy_results()

        status, body, _ = self.get("/metrics?collect[]=nodes")

        self.assertEqual(status, 200)
        self.assertIn("ignite_cluster_ready", body)


if __name__ == "__main__":
    unittest.main()
