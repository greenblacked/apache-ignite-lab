#!/usr/bin/env python3
"""Expose a small, dependency-free Prometheus view of the Ignite lab."""

from __future__ import annotations

import base64
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen

EXPORTER_VERSION = "1.0.0"
MAX_RESPONSE_BYTES = 1_048_576
DEFAULT_IGNITE2_ENDPOINTS = (
    "http://ignite2-node1:8080",
    "http://ignite2-node2:8080",
    "http://ignite2-node3:8080",
)
DEFAULT_IGNITE3_ENDPOINTS = (
    "http://ignite3-node1:10300",
    "http://ignite3-node2:10300",
    "http://ignite3-node3:10300",
)

FetchJson = Callable[[str, float, dict[str, str] | None], Any]


@dataclass(frozen=True)
class Settings:
    ignite2_endpoints: tuple[str, ...]
    ignite2_user: str
    ignite2_password: str
    ignite3_endpoints: tuple[str, ...]
    ignite3_user: str
    ignite3_password: str
    timeout_seconds: float = 2.0
    listen_address: str = "0.0.0.0"
    listen_port: int = 8000

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            ignite2_endpoints=_endpoint_list(
                os.getenv("IGNITE2_ENDPOINTS"), DEFAULT_IGNITE2_ENDPOINTS
            ),
            ignite2_user=os.getenv("IGNITE2_USER", "ignite"),
            ignite2_password=os.getenv("IGNITE2_PASSWORD", "ignite"),
            ignite3_endpoints=_endpoint_list(
                os.getenv("IGNITE3_ENDPOINTS"), DEFAULT_IGNITE3_ENDPOINTS
            ),
            ignite3_user=os.getenv("IGNITE3_USER", "ignite"),
            ignite3_password=os.getenv("IGNITE3_PASSWORD", "ignite-lab-pass"),
            timeout_seconds=_positive_float(
                os.getenv("EXPORTER_TIMEOUT_SECONDS", "2"),
                "EXPORTER_TIMEOUT_SECONDS",
            ),
            listen_address=os.getenv("EXPORTER_LISTEN_ADDRESS", "0.0.0.0"),
            listen_port=_port(os.getenv("EXPORTER_PORT", "8000")),
        )


@dataclass
class NodeResult:
    name: str
    api_up: bool = False
    healthy: bool = False
    state: str = "UNREACHABLE"
    version: str = ""


@dataclass
class StackResult:
    stack: str
    nodes: list[NodeResult]
    expected_nodes: int
    cluster_nodes: int = 0
    topology_up: bool = False
    cluster_ready: bool = False
    cluster_name: str = ""
    cluster_version: str = ""
    scrape_success: bool = False
    errors: int = 0
    duration_seconds: float = 0.0


def _endpoint_list(raw: str | None, defaults: tuple[str, ...]) -> tuple[str, ...]:
    values = defaults if raw is None else tuple(item.strip() for item in raw.split(","))
    endpoints = tuple(item.rstrip("/") for item in values if item)
    if not endpoints:
        raise ValueError("at least one Ignite endpoint must be configured")
    for endpoint in endpoints:
        parsed = urlsplit(endpoint)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError(f"invalid Ignite endpoint: {endpoint!r}")
    if len(set(endpoints)) != len(endpoints):
        raise ValueError("Ignite endpoints must be unique")
    return endpoints


def _positive_float(raw: str, name: str) -> float:
    value = float(raw)
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


def _port(raw: str) -> int:
    value = int(raw)
    if not 1 <= value <= 65535:
        raise ValueError("EXPORTER_PORT must be between 1 and 65535")
    return value


def _node_name(endpoint: str) -> str:
    parsed = urlsplit(endpoint)
    return parsed.hostname or parsed.netloc or endpoint


def _node_names(endpoints: tuple[str, ...]) -> tuple[str, ...]:
    names = tuple(_node_name(endpoint) for endpoint in endpoints)
    return tuple(
        urlsplit(endpoint).netloc if names.count(name) > 1 else name
        for endpoint, name in zip(endpoints, names)
    )


def _with_query(endpoint: str, values: dict[str, str]) -> str:
    parsed = urlsplit(endpoint)
    query = parse_qsl(parsed.query, keep_blank_values=True)
    query.extend(values.items())
    return urlunsplit(parsed._replace(query=urlencode(query)))


def _with_path(endpoint: str, path: str) -> str:
    parsed = urlsplit(endpoint)
    return urlunsplit(parsed._replace(path=path, query="", fragment=""))


def _basic_auth_headers(username: str, password: str) -> dict[str, str]:
    token = base64.b64encode(f"{username}:{password}".encode()).decode("ascii")
    return {"Authorization": f"Basic {token}"}


def fetch_json(
    url: str, timeout_seconds: float, headers: dict[str, str] | None = None
) -> Any:
    request_headers = {"Accept": "application/json"}
    if headers:
        request_headers.update(headers)
    request = Request(url, headers=request_headers)
    with urlopen(request, timeout=timeout_seconds) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            raise ValueError("Ignite API response is too large")
    return json.loads(body)


def _ignite2_url(
    endpoint: str, command: str, username: str, password: str
) -> str:
    values = {"cmd": command}
    if username:
        values["ignite.login"] = username
        values["ignite.password"] = password
    return _with_query(_with_path(endpoint, "/ignite"), values)


def _probe_ignite2_node(
    endpoint: str,
    node_name: str,
    username: str,
    password: str,
    timeout_seconds: float,
    fetch: FetchJson,
) -> NodeResult:
    result = NodeResult(name=node_name)
    try:
        payload = fetch(
            _ignite2_url(endpoint, "version", username, password),
            timeout_seconds,
            None,
        )
        if not isinstance(payload, dict) or payload.get("successStatus") != 0:
            raise ValueError("Ignite 2 version request failed")
        version = payload.get("response")
        if not isinstance(version, str) or not version:
            raise ValueError("Ignite 2 version response is missing")
        result.api_up = True
        result.healthy = True
        result.state = "STARTED"
        result.version = version
    except Exception:
        pass
    return result


def scrape_ignite2(settings: Settings, fetch: FetchJson = fetch_json) -> StackResult:
    started_at = time.monotonic()
    endpoints = settings.ignite2_endpoints
    node_names = _node_names(endpoints)
    with ThreadPoolExecutor(max_workers=len(endpoints)) as executor:
        futures = [
            executor.submit(
                _probe_ignite2_node,
                endpoint,
                node_name,
                settings.ignite2_user,
                settings.ignite2_password,
                settings.timeout_seconds,
                fetch,
            )
            for endpoint, node_name in zip(endpoints, node_names)
        ]
        nodes = [future.result() for future in futures]

    result = StackResult(
        stack="ignite2",
        nodes=nodes,
        expected_nodes=len(endpoints),
        errors=sum(not node.api_up for node in nodes),
    )
    healthy_endpoint = next(
        (endpoint for endpoint, node in zip(endpoints, nodes) if node.healthy), None
    )
    if healthy_endpoint:
        with ThreadPoolExecutor(max_workers=2) as executor:
            topology_future = executor.submit(
                fetch,
                _ignite2_url(
                    healthy_endpoint,
                    "top",
                    settings.ignite2_user,
                    settings.ignite2_password,
                ),
                settings.timeout_seconds,
                None,
            )
            state_future = executor.submit(
                fetch,
                _ignite2_url(
                    healthy_endpoint,
                    "currentstate",
                    settings.ignite2_user,
                    settings.ignite2_password,
                ),
                settings.timeout_seconds,
                None,
            )
        try:
            payload = topology_future.result()
            if not isinstance(payload, dict):
                raise ValueError("Ignite 2 topology response is invalid")
            members = payload.get("response")
            if payload.get("successStatus") != 0 or not isinstance(members, list):
                raise ValueError("Ignite 2 topology request failed")
            result.cluster_nodes = len(members)
            result.topology_up = True
            result.cluster_name = "ignite2-lab"
            result.cluster_version = next(
                (node.version for node in nodes if node.version), ""
            )
        except Exception:
            result.errors += 1
        try:
            state_payload = state_future.result()
            if (
                not isinstance(state_payload, dict)
                or state_payload.get("successStatus") != 0
                or not isinstance(state_payload.get("response"), bool)
            ):
                raise ValueError("Ignite 2 cluster state request failed")
            result.cluster_ready = state_payload["response"] and result.topology_up
        except Exception:
            result.errors += 1
    else:
        result.errors += 2

    result.scrape_success = all(node.healthy for node in nodes) and result.cluster_ready
    result.duration_seconds = time.monotonic() - started_at
    return result


def _probe_ignite3_node(
    endpoint: str,
    node_name: str,
    headers: dict[str, str],
    timeout_seconds: float,
    fetch: FetchJson,
) -> NodeResult:
    result = NodeResult(name=node_name)
    try:
        payload = fetch(
            _with_path(endpoint, "/management/v1/node/state"),
            timeout_seconds,
            headers,
        )
        if not isinstance(payload, dict):
            raise ValueError("Ignite 3 node state response is invalid")
        state = payload.get("state")
        if not isinstance(state, str) or not state:
            raise ValueError("Ignite 3 node state is missing")
        name = payload.get("name")
        if isinstance(name, str) and name:
            result.name = name
        result.api_up = True
        result.healthy = state.upper() == "STARTED"
        result.state = state.upper()
    except Exception:
        pass
    return result


def scrape_ignite3(settings: Settings, fetch: FetchJson = fetch_json) -> StackResult:
    started_at = time.monotonic()
    endpoints = settings.ignite3_endpoints
    node_names = _node_names(endpoints)
    headers = _basic_auth_headers(settings.ignite3_user, settings.ignite3_password)
    with ThreadPoolExecutor(max_workers=len(endpoints)) as executor:
        futures = [
            executor.submit(
                _probe_ignite3_node,
                endpoint,
                node_name,
                headers,
                settings.timeout_seconds,
                fetch,
            )
            for endpoint, node_name in zip(endpoints, node_names)
        ]
        nodes = [future.result() for future in futures]

    result = StackResult(
        stack="ignite3",
        nodes=nodes,
        expected_nodes=len(endpoints),
        errors=sum(not node.api_up for node in nodes),
    )
    healthy_endpoint = next(
        (endpoint for endpoint, node in zip(endpoints, nodes) if node.healthy), None
    )
    if healthy_endpoint:
        state_url = _with_path(healthy_endpoint, "/management/v1/cluster/state")
        topology_url = _with_path(
            healthy_endpoint, "/management/v1/cluster/topology/physical"
        )
        with ThreadPoolExecutor(max_workers=2) as executor:
            state_future = executor.submit(
                fetch, state_url, settings.timeout_seconds, headers
            )
            topology_future = executor.submit(
                fetch, topology_url, settings.timeout_seconds, headers
            )
            try:
                cluster_state = state_future.result()
                if not isinstance(cluster_state, dict):
                    raise ValueError("Ignite 3 cluster state response is invalid")
                version = cluster_state.get("igniteVersion")
                cluster_tag = cluster_state.get("clusterTag")
                if not isinstance(version, str) or not isinstance(cluster_tag, dict):
                    raise ValueError("Ignite 3 cluster metadata is missing")
                cluster_name = cluster_tag.get("clusterName")
                if not isinstance(cluster_name, str):
                    raise ValueError("Ignite 3 cluster name is missing")
                result.cluster_name = cluster_name
                result.cluster_version = version
                for node in nodes:
                    if node.api_up:
                        node.version = version
            except Exception:
                result.errors += 1

            try:
                topology = topology_future.result()
                if not isinstance(topology, list):
                    raise ValueError("Ignite 3 topology response is invalid")
                result.cluster_nodes = len(topology)
                result.topology_up = True
            except Exception:
                result.errors += 1
    else:
        result.errors += 2

    metadata_up = bool(result.cluster_name and result.cluster_version)
    result.cluster_ready = result.topology_up and metadata_up
    result.scrape_success = all(node.healthy for node in nodes) and result.cluster_ready
    result.duration_seconds = time.monotonic() - started_at
    return result


def collect(settings: Settings, fetch: FetchJson = fetch_json) -> list[StackResult]:
    with ThreadPoolExecutor(max_workers=2) as executor:
        ignite2 = executor.submit(scrape_ignite2, settings, fetch)
        ignite3 = executor.submit(scrape_ignite3, settings, fetch)
        return [ignite2.result(), ignite3.result()]


def _label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _sample(metric_name: str, value: float | int, **labels: str) -> str:
    if labels:
        rendered = ",".join(
            f'{key}="{_label_value(label)}"' for key, label in sorted(labels.items())
        )
        return f"{metric_name}{{{rendered}}} {value}"
    return f"{metric_name} {value}"


def render_metrics(results: list[StackResult]) -> str:
    lines = [
        "# HELP ignite_exporter_info Static information about the lab exporter.",
        "# TYPE ignite_exporter_info gauge",
        _sample("ignite_exporter_info", 1, version=EXPORTER_VERSION),
        "# HELP ignite_exporter_scrape_success Whether all configured nodes and "
        "cluster APIs were healthy during the last collection.",
        "# TYPE ignite_exporter_scrape_success gauge",
        "# HELP ignite_exporter_scrape_errors Number of node or cluster API "
        "errors during the last collection.",
        "# TYPE ignite_exporter_scrape_errors gauge",
        "# HELP ignite_exporter_scrape_duration_seconds Time spent collecting one Ignite stack.",
        "# TYPE ignite_exporter_scrape_duration_seconds gauge",
        "# HELP ignite_node_up Whether the node management API responded successfully.",
        "# TYPE ignite_node_up gauge",
        "# HELP ignite_node_healthy Whether the node reports a healthy running state.",
        "# TYPE ignite_node_healthy gauge",
        "# HELP ignite_node_info Ignite node identity, state, and version.",
        "# TYPE ignite_node_info gauge",
        "# HELP ignite_cluster_nodes Number of nodes reported by the cluster topology API.",
        "# TYPE ignite_cluster_nodes gauge",
        "# HELP ignite_cluster_expected_nodes Number of nodes configured for collection.",
        "# TYPE ignite_cluster_expected_nodes gauge",
        "# HELP ignite_cluster_topology_up Whether the cluster topology API "
        "responded successfully.",
        "# TYPE ignite_cluster_topology_up gauge",
        "# HELP ignite_cluster_ready Whether the cluster is initialized, active "
        "where applicable, and its topology API is healthy.",
        "# TYPE ignite_cluster_ready gauge",
        "# HELP ignite_cluster_info Ignite cluster identity and version.",
        "# TYPE ignite_cluster_info gauge",
    ]
    for result in results:
        stack = result.stack
        lines.extend(
            [
                _sample(
                    "ignite_exporter_scrape_success",
                    int(result.scrape_success),
                    stack=stack,
                ),
                _sample(
                    "ignite_exporter_scrape_errors", result.errors, stack=stack
                ),
                _sample(
                    "ignite_exporter_scrape_duration_seconds",
                    round(result.duration_seconds, 6),
                    stack=stack,
                ),
                _sample("ignite_cluster_nodes", result.cluster_nodes, stack=stack),
                _sample(
                    "ignite_cluster_expected_nodes", result.expected_nodes, stack=stack
                ),
                _sample(
                    "ignite_cluster_topology_up", int(result.topology_up), stack=stack
                ),
                _sample(
                    "ignite_cluster_ready", int(result.cluster_ready), stack=stack
                ),
            ]
        )
        if result.cluster_name and result.cluster_version:
            lines.append(
                _sample(
                    "ignite_cluster_info",
                    1,
                    stack=stack,
                    name=result.cluster_name,
                    version=result.cluster_version,
                )
            )
        for node in result.nodes:
            labels = {"node": node.name, "stack": stack}
            lines.extend(
                [
                    _sample("ignite_node_up", int(node.api_up), **labels),
                    _sample("ignite_node_healthy", int(node.healthy), **labels),
                    _sample(
                        "ignite_node_info",
                        1,
                        **labels,
                        state=node.state,
                        version=node.version,
                    ),
                ]
            )
    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    settings: Settings

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = self.path.partition("?")[0]
        if path == "/healthz":
            self._respond(200, b"ok\n", "text/plain; charset=utf-8")
            return
        if path != "/metrics":
            self._respond(404, b"not found\n", "text/plain; charset=utf-8")
            return
        try:
            body = render_metrics(collect(self.settings)).encode()
        except Exception:
            body = (
                "# HELP ignite_exporter_collection_error Whether metric collection "
                "failed unexpectedly.\n"
                "# TYPE ignite_exporter_collection_error gauge\n"
                "ignite_exporter_collection_error 1\n"
            ).encode()
        self._respond(
            200, body, "text/plain; version=0.0.4; charset=utf-8"
        )

    def _respond(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    settings = Settings.from_environment()
    MetricsHandler.settings = settings
    server = ThreadingHTTPServer((settings.listen_address, settings.listen_port), MetricsHandler)
    server.daemon_threads = True
    print(
        f"Ignite lab exporter {EXPORTER_VERSION} listening on "
        f"{settings.listen_address}:{settings.listen_port}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
