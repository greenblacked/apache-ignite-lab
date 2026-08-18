import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch


EXAMPLES = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ignite2_example = load_module(
    "ignite2_cache_and_sql",
    EXAMPLES / "ignite2" / "python" / "cache_and_sql.py",
)
ignite3_example = load_module(
    "ignite3_tables_sql",
    EXAMPLES / "ignite3" / "python" / "tables_sql.py",
)


class FakeCache:
    def __init__(self):
        self.values = {}

    def put(self, key, value):
        self.values[key] = value

    def get(self, key):
        return self.values.get(key)

    def remove_key(self, key):
        self.values.pop(key, None)


class FakeIgnite2Client:
    def __init__(self, username, password, wrong_select=False):
        self.username = username
        self.password = password
        self.wrong_select = wrong_select
        self.cache = FakeCache()
        self.rows = {}
        self.queries = []
        self.connected = None
        self.closed = False

    def connect(self, host, port):
        self.connected = (host, port)

    def get_or_create_cache(self, _name):
        return self.cache

    def sql(self, query, query_args=None):
        args = list(query_args or [])
        normalized = " ".join(query.upper().split())
        self.queries.append((normalized, args))
        if normalized.startswith("CREATE TABLE"):
            return []
        if normalized.startswith("MERGE INTO"):
            self.rows[args[0]] = args[1]
            return [[1]]
        if normalized.startswith("SELECT"):
            if self.wrong_select:
                return [[args[0], "wrong"]]
            value = self.rows.get(args[0])
            return [] if value is None else [[args[0], value]]
        if normalized.startswith("DELETE FROM"):
            self.rows.pop(args[0], None)
            return [[1]]
        raise AssertionError(f"unexpected SQL: {query}")

    def close(self):
        self.closed = True


class FakeIgnite3Cursor:
    def __init__(self, rows):
        self.rows = rows
        self.queries = []
        self.rowcount = -1
        self.results = []

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc, _tb):
        return False

    def execute(self, query, params=None):
        args = list(params or [])
        normalized = " ".join(query.upper().split())
        self.queries.append((normalized, args))
        self.results = []
        if normalized.startswith(("CREATE ZONE", "CREATE TABLE")):
            self.rowcount = -1
        elif normalized.startswith("UPDATE"):
            name, row_id = args
            if row_id in self.rows:
                self.rows[row_id] = name
                self.rowcount = 1
            else:
                self.rowcount = 0
        elif normalized.startswith("INSERT"):
            row_id, name = args
            self.rows[row_id] = name
            self.rowcount = 1
        elif normalized.startswith("SELECT"):
            row_id = args[0]
            self.results = [] if row_id not in self.rows else [(row_id, self.rows[row_id])]
            self.rowcount = -1
        elif normalized.startswith("DELETE"):
            row_id = args[0]
            self.rowcount = 1 if self.rows.pop(row_id, None) is not None else 0
        else:
            raise AssertionError(f"unexpected SQL: {query}")

    def fetchone(self):
        return self.results.pop(0) if self.results else None


class FakeIgnite3Connection:
    def __init__(self, rows=None):
        self.rows = dict(rows or {})
        self.cursor_instance = FakeIgnite3Cursor(self.rows)
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc, _tb):
        self.closed = True
        return False

    def cursor(self):
        return self.cursor_instance


class Ignite2ExampleTests(unittest.TestCase):
    def test_round_trip_checks_and_cleans_only_owned_values(self):
        client = FakeIgnite2Client("ignite", "ignite")
        with patch.dict(os.environ, {"IGNITE2_EXAMPLE_ID": "42"}, clear=False):
            result = ignite2_example.run(
                client_factory=lambda **_kwargs: client,
            )

        self.assertEqual(("ignite2", [42, "Tel Aviv"]), result)
        self.assertEqual({}, client.rows)
        self.assertEqual({}, client.cache.values)
        self.assertTrue(client.closed)
        delete_queries = [
            query for query, _args in client.queries if query.startswith("DELETE FROM")
        ]
        self.assertEqual(["DELETE FROM LAB_CITY WHERE ID = ?"], delete_queries)

    def test_failed_result_check_still_cleans_up(self):
        client = FakeIgnite2Client("ignite", "ignite", wrong_select=True)
        with patch.dict(os.environ, {"IGNITE2_EXAMPLE_ID": "43"}, clear=False):
            with self.assertRaisesRegex(AssertionError, "SQL round-trip mismatch"):
                ignite2_example.run(client_factory=lambda **_kwargs: client)

        self.assertEqual({}, client.rows)
        self.assertEqual({}, client.cache.values)
        self.assertTrue(client.closed)


class Ignite3ExampleTests(unittest.TestCase):
    def test_insert_branch_select_and_scoped_cleanup(self):
        connection = FakeIgnite3Connection()
        captured = {}

        def connect(**kwargs):
            captured.update(kwargs)
            return connection

        env = {
            "IGNITE3_EXAMPLE_ID": "84",
            "IGNITE3_ADDRESS": "node-a:10800,node-b:10800",
            "IGNITE_LAB_USER": "lab-user",
            "IGNITE_LAB_PASSWORD": "lab-pass",
        }
        with patch.dict(os.environ, env, clear=False):
            result = ignite3_example.run(connect=connect)

        self.assertEqual((84, "ignite3-python"), result)
        self.assertEqual(["node-a:10800", "node-b:10800"], captured["address"])
        self.assertEqual("lab-user", captured["identity"])
        self.assertEqual("lab-pass", captured["secret"])
        self.assertEqual({}, connection.rows)
        delete_queries = [
            query
            for query, _args in connection.cursor_instance.queries
            if query.startswith("DELETE FROM")
        ]
        self.assertEqual(["DELETE FROM LAB_KV WHERE ID = ?"], delete_queries)

    def test_update_branch_does_not_insert(self):
        connection = FakeIgnite3Connection({85: "old"})
        with patch.dict(os.environ, {"IGNITE3_EXAMPLE_ID": "85"}, clear=False):
            ignite3_example.run(connect=lambda **_kwargs: connection)

        insert_queries = [
            query
            for query, _args in connection.cursor_instance.queries
            if query.startswith("INSERT")
        ]
        self.assertEqual([], insert_queries)
        self.assertEqual({}, connection.rows)


if __name__ == "__main__":
    unittest.main()
