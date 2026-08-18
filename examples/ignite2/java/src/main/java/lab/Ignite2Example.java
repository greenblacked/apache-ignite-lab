package lab;

import org.apache.ignite.Ignition;
import org.apache.ignite.client.ClientCache;
import org.apache.ignite.client.IgniteClient;
import org.apache.ignite.configuration.ClientConfiguration;

import java.util.UUID;

public final class Ignite2Example {
    public static void main(String[] args) {
        String host = System.getenv().getOrDefault("IGNITE2_HOST", "127.0.0.1");
        String port = System.getenv().getOrDefault("IGNITE2_PORT", "10800");
        String user = System.getenv().getOrDefault("IGNITE_LAB_USER", "ignite");
        String password = System.getenv().getOrDefault("IGNITE2_PASSWORD", "ignite");

        ClientConfiguration cfg = new ClientConfiguration()
                .setAddresses(host + ":" + port)
                .setUserName(user)
                .setUserPassword(password);

        try (IgniteClient client = Ignition.startClient(cfg)) {
            ClientCache<String, String> cache = client.getOrCreateCache("lab_cache_java");
            String key = "ignite2-java-" + UUID.randomUUID();
            String expected = "ignite2-java";
            try {
                cache.put(key, expected);
                String actual = cache.get(key);
                if (!expected.equals(actual)) {
                    throw new IllegalStateException(
                            "Ignite 2 value mismatch: expected=" + expected + ", actual=" + actual);
                }
                System.out.println("ignite2 java ok: " + actual);
            } finally {
                cache.remove(key);
            }
        }
    }
}
