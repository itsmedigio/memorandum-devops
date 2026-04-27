import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Production-style demo: reads a secret from a file written by the Vault Agent
 * sidecar.
 *
 * The Vault Agent runs alongside this container, authenticates to Vault
 * via Kubernetes Auth, and writes the rendered secret to a shared volume at:
 * /vault/secrets/db_password
 *
 * This app never talks to Vault directly, never holds a token,
 * and never needs to know the Vault address.
 */
public class VaultDemo {

    private static final Path SECRET_FILE = Paths.get("/vault/secrets/db_password");
    private static final long POLL_INTERVAL_MS = 5_000; // how often to re-read (simulates live refresh)

    public static void main(String[] args) throws IOException, InterruptedException {
        System.out.println("Starting VaultDemo — reading secret from Vault Agent sidecar...");
        System.out.println("Secret file: " + SECRET_FILE);

        waitForSecretFile();

        while (true) {
            String password = readSecret();
            System.out.println("[demo] Secret loaded successfully. Value=" + password);
            Thread.sleep(POLL_INTERVAL_MS);
        }
    }

    /**
     * Blocks until Vault Agent has written the secret file.
     * Vault Agent renders secrets before the main container starts (when using init
     * mode),
     * so in practice this loop rarely iterates more than once.
     */
    private static void waitForSecretFile() throws InterruptedException {
        int attempts = 0;
        while (!Files.exists(SECRET_FILE)) {
            if (attempts++ == 0) {
                System.out.println("Waiting for Vault Agent to render secret...");
            }
            Thread.sleep(1_000);
        }
        System.out.println("Secret file found after " + attempts + " wait(s).");
    }

    private static String readSecret() throws IOException {
        return new String(Files.readAllBytes(SECRET_FILE)).trim();
    }
}