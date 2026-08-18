#!/usr/bin/env python3
"""Ignite 3 DB-API zone, table, upsert, and select example."""
import os
import sys
import uuid


ZONE_NAME = "LAB_ZONE"
TABLE_NAME = "LAB_KV"
EXPECTED_NAME = "ignite3-python"


def _connect(**kwargs):
    import pyignite_dbapi

    return pyignite_dbapi.connect(**kwargs)


def _example_id() -> int:
    configured = os.getenv("IGNITE3_EXAMPLE_ID")
    if configured is not None:
        return int(configured)
    return uuid.uuid4().int & 0x7FFFFFFF


def _upsert(cursor, row_id: int, name: str) -> None:
    """Update an existing row or insert it when absent."""
    cursor.execute(
        f"UPDATE {TABLE_NAME} SET name = ? WHERE id = ?",
        [name, row_id],
    )
    if cursor.rowcount == 0:
        cursor.execute(
            f"INSERT INTO {TABLE_NAME} (id, name) VALUES (?, ?)",
            [row_id, name],
        )
        if cursor.rowcount != 1:
            raise AssertionError(f"insert affected {cursor.rowcount} rows; expected 1")
    elif cursor.rowcount != 1:
        raise AssertionError(f"update affected {cursor.rowcount} rows; expected 0 or 1")


def run(connect=None) -> tuple[int, str]:
    addresses = [
        address.strip()
        for address in os.getenv("IGNITE3_ADDRESS", "127.0.0.1:10810").split(",")
        if address.strip()
    ]
    user = os.getenv("IGNITE_LAB_USER", "ignite")
    password = os.getenv("IGNITE_LAB_PASSWORD", "ignite-lab-pass")
    row_id = _example_id()
    connector = connect or _connect

    with connector(
        address=addresses,
        identity=user,
        secret=password,
        autocommit=True,
    ) as connection:
        with connection.cursor() as cursor:
            table_ready = False
            try:
                cursor.execute(
                    f"CREATE ZONE IF NOT EXISTS {ZONE_NAME} "
                    "(REPLICAS 2) STORAGE PROFILES['rocksDbProfile']"
                )
                cursor.execute(
                    f"CREATE TABLE IF NOT EXISTS {TABLE_NAME} "
                    f"(id INT PRIMARY KEY, name VARCHAR) ZONE {ZONE_NAME}"
                )
                table_ready = True

                _upsert(cursor, row_id, EXPECTED_NAME)
                cursor.execute(
                    f"SELECT id, name FROM {TABLE_NAME} WHERE id = ?",
                    [row_id],
                )
                row = cursor.fetchone()
                extra_row = cursor.fetchone()
                actual = tuple(row) if row is not None else None
                expected = (row_id, EXPECTED_NAME)
                if actual != expected or extra_row is not None:
                    raise AssertionError(
                        f"SQL round-trip mismatch: expected only {expected!r}, "
                        f"got {actual!r} and extra row {extra_row!r}"
                    )
                print("ignite3 zone/table/upsert/select ok:", actual)
                return expected
            finally:
                if table_ready:
                    cursor.execute(
                        f"DELETE FROM {TABLE_NAME} WHERE id = ?",
                        [row_id],
                    )
                    if cursor.rowcount not in (0, 1):
                        raise AssertionError(
                            f"cleanup affected {cursor.rowcount} rows; expected 0 or 1"
                        )


def main() -> int:
    run()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print("FAILED:", exc, file=sys.stderr)
        raise
