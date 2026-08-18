# Examples

Run examples only after the matching cluster is initialized and healthy. Load the lab credentials from `.env` before running clients that use them:

```bash
set -a
source .env
set +a
```

## Python environment

Use CPython 3.10–3.13. The Ignite 3 DB-API 3.1.0 package tests CPython through 3.13 and contains a native extension; Python 3.14 is not currently a supported example runtime. A source build may additionally require CMake, a C++ compiler, and OpenSSL headers.

Create an isolated environment from the repository root:

```bash
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
```

If `python3.13` is not the executable name on your system, substitute another installed CPython version in the supported range.

### Ignite 2: cache and SQL

A fresh Ignite 2 cluster starts with `ignite` / `ignite`, independently of `IGNITE_LAB_PASSWORD`. The `IGNITE2_PASSWORD` value in `.env` must match the current cluster credential:

```bash
python -m pip install -r examples/ignite2/python/requirements.txt
python examples/ignite2/python/cache_and_sql.py
```

The example verifies both cache and SQL round trips. It generates a unique cache key and SQL row ID, then removes only those two values during cleanup. Set `IGNITE2_HOST` or `IGNITE2_PORT` to override the default endpoint; authentication uses `IGNITE_LAB_USER` and `IGNITE2_PASSWORD` loaded from `.env`.

### Ignite 3: DB-API zone, table, upsert, and select

```bash
python -m pip install -r examples/ignite3/python/requirements.txt
python examples/ignite3/python/tables_sql.py
```

The example connects through the Ignite 3 client port (`127.0.0.1:10810`), creates `LAB_ZONE` and `LAB_KV` when absent, performs a checked upsert and select using a unique row ID, and deletes only its row afterward. The shared zone and table remain available for later practice. Override endpoints with a comma-separated `IGNITE3_ADDRESS` value; authentication uses `IGNITE_LAB_USER` and `IGNITE_LAB_PASSWORD` loaded from `.env`.

### Mocked Python tests

These tests do not contact a live cluster and do not require either client package:

```bash
python -m unittest discover -s examples/tests -v
```

## Java

Requires JDK 17+ and Maven 3.8.6+. Build and run from each module directory so Maven discovers module-local `.mvn` settings:

```bash
(cd examples/ignite2/java && mvn -q verify exec:java)
(cd examples/ignite3/java && mvn -q verify exec:java)
```

The Ignite 2 module's `.mvn/jvm.config` supplies the Java module opens required on modern JDKs. Both programs fail explicitly on a value mismatch and remove only the key written by that run.
