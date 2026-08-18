package lab;

import org.apache.ignite.client.BasicAuthenticator;
import org.apache.ignite.client.IgniteClient;
import org.apache.ignite.table.KeyValueView;
import org.apache.ignite.table.Table;
import org.apache.ignite.table.Tuple;

import java.util.concurrent.ThreadLocalRandom;

public final class Ignite3Example {
    public static void main(String[] args) {
        String address = System.getenv().getOrDefault("IGNITE3_ADDRESS", "127.0.0.1:10810");
        String user = System.getenv().getOrDefault("IGNITE_LAB_USER", "ignite");
        String password = System.getenv().getOrDefault("IGNITE_LAB_PASSWORD", "ignite-lab-pass");

        try (IgniteClient client = IgniteClient.builder()
                .addresses(address)
                .authenticator(BasicAuthenticator.builder()
                        .username(user)
                        .password(password)
                        .build())
                .build()) {
            client.sql().executeScript(
                    "CREATE ZONE IF NOT EXISTS LAB_ZONE (REPLICAS 2) "
                            + "STORAGE PROFILES['rocksDbProfile']; "
                            + "CREATE TABLE IF NOT EXISTS lab_kv (id INT PRIMARY KEY, name VARCHAR) ZONE LAB_ZONE");

            Table table = client.tables().table("lab_kv");
            if (table == null) {
                throw new IllegalStateException("Ignite 3 table LAB_KV was not created");
            }

            KeyValueView<Tuple, Tuple> view = table.keyValueView();
            int id = ThreadLocalRandom.current().nextInt(1, Integer.MAX_VALUE);
            Tuple key = Tuple.create().set("id", id);
            String expected = "ignite3-java";
            Tuple value = Tuple.create().set("name", expected);
            try {
                view.put(null, key, value);
                Tuple actual = view.get(null, key);
                if (actual == null || !expected.equals(actual.stringValue("name"))) {
                    throw new IllegalStateException(
                            "Ignite 3 value mismatch: expected=" + expected + ", actual=" + actual);
                }
                System.out.println("ignite3 java ok: " + actual.stringValue("name"));
            } finally {
                view.remove(null, key);
            }
        }
    }
}
