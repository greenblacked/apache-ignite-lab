#!/usr/bin/env python3
"""Ignite 2 thin-client cache + SQL lab example."""
import os
import sys
import uuid


CACHE_NAME = "lab_cache"
TABLE_NAME = "lab_city"
CITY_NAME = "Tel Aviv"


def _client_factory(**kwargs):
    from pyignite import Client

    return Client(**kwargs)


def _rows(client, query: str, query_args=None) -> list[list[object]]:
    return [list(row) for row in client.sql(query, query_args=query_args)]


def _example_id() -> int:
    configured = os.getenv("IGNITE2_EXAMPLE_ID")
    if configured is not None:
        return int(configured)
    return uuid.uuid4().int & ((1 << 63) - 1)


def run(client_factory=None) -> tuple[str, list[object]]:
    host = os.getenv("IGNITE2_HOST", "127.0.0.1")
    port = int(os.getenv("IGNITE2_PORT", "10800"))
    user = os.getenv("IGNITE_LAB_USER", "ignite")
    password = os.getenv("IGNITE2_PASSWORD", "ignite")
    row_id = _example_id()
    cache_key = f"ignite2-example-{row_id}"
    expected_cache_value = "ignite2"

    factory = client_factory or _client_factory
    client = factory(username=user, password=password)
    cache = None
    table_ready = False
    try:
        client.connect(host, port)

        cache = client.get_or_create_cache(CACHE_NAME)
        cache.put(cache_key, expected_cache_value)
        cache_value = cache.get(cache_key)
        if cache_value != expected_cache_value:
            raise AssertionError(
                f"cache round-trip mismatch: expected {expected_cache_value!r}, got {cache_value!r}"
            )
        print("ignite2 cache ok:", cache_value)

        _rows(
            client,
            f"CREATE TABLE IF NOT EXISTS {TABLE_NAME} (id LONG PRIMARY KEY, name VARCHAR)",
        )
        table_ready = True
        _rows(
            client,
            f"MERGE INTO {TABLE_NAME} (id, name) VALUES (?, ?)",
            query_args=[row_id, CITY_NAME],
        )
        sql_rows = _rows(
            client,
            f"SELECT id, name FROM {TABLE_NAME} WHERE id = ?",
            query_args=[row_id],
        )
        expected_rows = [[row_id, CITY_NAME]]
        if sql_rows != expected_rows:
            raise AssertionError(
                f"SQL round-trip mismatch: expected {expected_rows!r}, got {sql_rows!r}"
            )
        print("ignite2 sql ok:", sql_rows)
        return cache_value, sql_rows[0]
    finally:
        try:
            if table_ready:
                _rows(
                    client,
                    f"DELETE FROM {TABLE_NAME} WHERE id = ?",
                    query_args=[row_id],
                )
        finally:
            try:
                if cache is not None:
                    cache.remove_key(cache_key)
            finally:
                client.close()


def main() -> int:
    run()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print("FAILED:", exc, file=sys.stderr)
        raise
