package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The per-install id.
 *
 * The Android Keystore and `SharedPreferences` are both framework, so the store
 * is driven here through its two seams: a [FakeInstallationIdCipher] that
 * round-trips and can be told to fail the way a Keystore fails (lost key,
 * transient failure, cannot encrypt), and an [InMemoryInstallationIdPrefs] that a
 * second store can stand on — which is what a relaunch is. Both live in the test
 * source set; the library ships only the interfaces and the production
 * implementations.
 *
 * The real AndroidKeyStore adapter requires an instrumented test. These tests
 * cover the store's response to KeyMissing and Unavailable.
 *
 * The properties pinned are the ones relay routing depends on: generated once,
 * stable across launches, never rotated — and *not* rotated by anything short of
 * the value being genuinely unreadable.
 */
class InstallationIdRulesTest {

    private val uuidPattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    /** What the fake Keystore does with a read attempt. */
    private enum class ReadOutcome { Ok, Undecryptable, KeyMissing, Unavailable }

    /** Reversible, counts what it was asked to do, and can fail like the real one. */
    private class FakeInstallationIdCipher(
        /** Simulates a lost Keystore key, or a payload that is not ours. */
        var read: ReadOutcome = ReadOutcome.Ok,
        /** Simulates a device that cannot encrypt at all (API < 23, or a broken Keystore). */
        var canEncrypt: Boolean = true,
        /**
         * Simulates a key that exists although decrypt said it was missing (a
         * transient Keystore fault that has since cleared): an `expectNoKey`
         * encrypt finds it and refuses.
         */
        var keyReappears: Boolean = false,
    ) : InstallationIdCipher {
        var encryptCalls = 0
        val expectNoKeyArgs = mutableListOf<Boolean>()
        var decryptCalls = 0
        val decryptPayloads = mutableListOf<String>()
        val written = mutableListOf<String>()

        override fun encrypt(plaintext: String, expectNoKey: Boolean): String? {
            encryptCalls++
            expectNoKeyArgs += expectNoKey
            if (!canEncrypt) return null
            if (expectNoKey && keyReappears) return null
            val payload = "enc($plaintext)"
            written += payload
            return payload
        }

        override fun decrypt(payload: String): DecryptResult {
            decryptCalls++
            decryptPayloads += payload
            return when (read) {
                ReadOutcome.Ok ->
                    DecryptResult.Ok(payload.removePrefix("enc(").removeSuffix(")"))
                ReadOutcome.Undecryptable -> DecryptResult.Undecryptable
                ReadOutcome.KeyMissing -> DecryptResult.KeyMissing
                ReadOutcome.Unavailable -> DecryptResult.Unavailable
            }
        }
    }

    private fun store(
        prefs: InMemoryInstallationIdPrefs,
        cipher: FakeInstallationIdCipher,
        newId: () -> String = { UUID.randomUUID().toString() },
    ) = InstallationIdStore.create(prefs = prefs, cipher = cipher, newId = newId)

    // --------------------------------------------------------------- Format

    @Test
    fun `the generated id is a lowercase canonical UUID`() {
        val store = store(InMemoryInstallationIdPrefs(), FakeInstallationIdCipher())
        val id = store.installationId()
        assertTrue("$id is not a lowercase canonical UUID", uuidPattern.matches(id))
        assertEquals(id, id.lowercase())
    }

    @Test
    fun `the id is generated once and then reused`() {
        var generated = 0
        val prefs = InMemoryInstallationIdPrefs()
        val cipher = FakeInstallationIdCipher()
        val store = store(prefs, cipher) {
            generated++
            UUID.randomUUID().toString()
        }

        val first = store.installationId()
        val second = store.installationId()

        assertEquals(first, second)
        assertEquals(1, generated)
        // Persisted, not just cached in the instance: that is what makes a
        // second store over the same prefs return the same id.
        assertEquals(listOf("enc($first)"), cipher.written)
        assertEquals(1, prefs.writeCount)
    }

    @Test
    fun `the id is persisted as the encrypted payload, never as a bare value`() {
        // The stored form is `base64(iv || ciphertext||tag)` and nothing wrapped
        // around it: a value a backup carries is unreadable without the Keystore
        // key, which is what stops it being an id on two devices.
        val prefs = InMemoryInstallationIdPrefs()
        val id = store(prefs, FakeInstallationIdCipher()).installationId()
        assertEquals("enc($id)", prefs.read())
        assertNotEquals(id, prefs.read())
    }

    // ---------------------------------------------- Stable across instances

    @Test
    fun `the id is stable across store instances over the same preferences`() {
        val prefs = InMemoryInstallationIdPrefs()
        val before = store(prefs, FakeInstallationIdCipher()).installationId()

        // A relaunch: a new store, and a fresh cipher, over storage the previous
        // process left behind.
        val after = store(prefs, FakeInstallationIdCipher()).installationId()

        assertEquals(before, after)
    }

    @Test
    fun `a stored id is never rotated`() {
        val persisted = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        val cipher = FakeInstallationIdCipher()
        val store = store(InMemoryInstallationIdPrefs("enc($persisted)"), cipher)

        assertEquals(persisted, store.installationId())
        assertEquals(0, cipher.encryptCalls)
    }

    @Test
    fun `a stored id in another case is normalised and kept`() {
        // An uppercase UUID is the same id — `UUID.randomUUID().toString()` is
        // lowercase, but nothing stops a host writing the value itself.
        // Regenerating over a formatting difference would rotate an install.
        val persisted = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        val cipher = FakeInstallationIdCipher()
        val store = store(InMemoryInstallationIdPrefs("enc($persisted)"), cipher)

        assertEquals(persisted.lowercase(), store.installationId())
        assertEquals(0, cipher.encryptCalls)
    }

    // --------------------------------------------------- Lost key / garbage

    @Test
    fun `an undecryptable value is replaced by a new id`() {
        // The realistic path: an app backup restored onto a new device. The
        // preferences file came across; the hardware-backed key did not.
        val prefs = InMemoryInstallationIdPrefs("enc(3f2504e0-4f89-41d3-9a0c-0305e82c3301)")
        val lostKey = FakeInstallationIdCipher(read = ReadOutcome.KeyMissing)
        val store = store(prefs, lostKey)

        val id = store.installationId()

        assertTrue(uuidPattern.matches(id))
        assertNotEquals("3f2504e0-4f89-41d3-9a0c-0305e82c3301", id)
        // Overwritten, so the next launch reads the new one rather than
        // regenerating again.
        assertEquals(listOf("enc($id)"), lostKey.written)
        assertEquals(id, store(prefs, FakeInstallationIdCipher()).installationId())
    }

    @Test
    fun `a missing key whose absence is contradicted by encrypt does not overwrite the stored value`() {
        // A transient Keystore fault can read as "no such alias". Once it clears
        // the healthy key is back, and encrypting a new id under it would commit
        // over a readable one — a rotation. The store says it expects no key, the
        // cipher finds one and refuses, and nothing is written.
        val persisted = "enc(3f2504e0-4f89-41d3-9a0c-0305e82c3301)"
        val prefs = InMemoryInstallationIdPrefs(persisted)
        val cipher = FakeInstallationIdCipher(read = ReadOutcome.KeyMissing, keyReappears = true)
        val store = store(prefs, cipher)

        assertThrows(InstallationIdUnavailableException::class.java) { store.installationId() }

        assertEquals(listOf(true), cipher.expectNoKeyArgs)
        assertEquals("the stored value was overwritten", persisted, prefs.read())
        assertEquals(0, prefs.writeCount)
        assertTrue(cipher.written.isEmpty())

        // Nothing cached: once the Keystore reads again, the original id is back.
        cipher.read = ReadOutcome.Ok
        assertEquals("3f2504e0-4f89-41d3-9a0c-0305e82c3301", store.installationId())
    }

    @Test
    fun `a missing key that is truly absent is replaced by a new id`() {
        val prefs = InMemoryInstallationIdPrefs("enc(3f2504e0-4f89-41d3-9a0c-0305e82c3301)")
        val cipher = FakeInstallationIdCipher(read = ReadOutcome.KeyMissing, keyReappears = false)
        val store = store(prefs, cipher)

        val id = store.installationId()

        assertTrue(uuidPattern.matches(id))
        assertNotEquals("3f2504e0-4f89-41d3-9a0c-0305e82c3301", id)
        assertEquals(listOf(true), cipher.expectNoKeyArgs)
        assertEquals("enc($id)", prefs.read())
        assertEquals(1, prefs.writeCount)
    }

    @Test
    fun `other undecryptable causes encrypt without expecting the key to be absent`() {
        // Bad tag / bad base64: the key is fine, the payload is not ours. A
        // present key is exactly what encrypt should use here.
        val prefs = InMemoryInstallationIdPrefs("enc(3f2504e0-4f89-41d3-9a0c-0305e82c3301)")
        val cipher = FakeInstallationIdCipher(read = ReadOutcome.Undecryptable, keyReappears = true)
        val store = store(prefs, cipher)

        val id = store.installationId()

        assertTrue(uuidPattern.matches(id))
        assertEquals(listOf(false), cipher.expectNoKeyArgs)
        assertEquals("enc($id)", prefs.read())
        assertEquals(1, prefs.writeCount)
    }

    @Test
    fun `an unavailable Keystore leaves the stored value untouched`() {
        // A Keystore that fails transiently — locked, throttled, provider error
        // — is not a lost key. The stored id is still good, so it must survive the
        // failure untouched: overwriting it is how an installation id rotates
        // itself on a bad day.
        val persisted = "enc(3f2504e0-4f89-41d3-9a0c-0305e82c3301)"
        val prefs = InMemoryInstallationIdPrefs(persisted)
        val cipher = FakeInstallationIdCipher(read = ReadOutcome.Unavailable)
        val store = store(prefs, cipher)

        assertThrows(InstallationIdUnavailableException::class.java) { store.installationId() }

        assertEquals("the stored value was overwritten", persisted, prefs.read())
        assertEquals(0, prefs.writeCount)
        assertTrue(cipher.written.isEmpty())

        // Nothing was cached, so the first call that can read returns the
        // original id rather than a fresh one.
        cipher.read = ReadOutcome.Ok
        assertEquals("3f2504e0-4f89-41d3-9a0c-0305e82c3301", store.installationId())
        assertEquals(0, cipher.encryptCalls)
    }

    @Test
    fun `a value that is not ours to read is replaced by a new id`() {
        // Something else wrote into the slot: not base64, or too short to be a
        // payload. The cipher reports that as undecryptable, and the store does
        // what it does with any unreadable value.
        val prefs = InMemoryInstallationIdPrefs("{\"installation_id\":\"3f2504e0\"}")
        val cipher = FakeInstallationIdCipher(read = ReadOutcome.Undecryptable)
        val store = store(prefs, cipher)

        assertTrue(uuidPattern.matches(store.installationId()))
    }

    @Test
    fun `a decrypted value that is not a UUID is replaced by a new id`() {
        // Decrypts fine (so it was written by us), but is not the shape the
        // relay expects: treat it as absent rather than send it.
        val prefs = InMemoryInstallationIdPrefs("enc(not-a-uuid)")
        val cipher = FakeInstallationIdCipher()
        val store = store(prefs, cipher)

        val id = store.installationId()

        assertTrue(uuidPattern.matches(id))
        assertEquals(listOf("enc($id)"), cipher.written)
        assertEquals(id, store(prefs, FakeInstallationIdCipher()).installationId())
    }

    @Test
    fun `an empty stored value counts as no value`() {
        var generated = 0
        val store = store(InMemoryInstallationIdPrefs(""), FakeInstallationIdCipher()) {
            generated++
            UUID.randomUUID().toString()
        }
        assertTrue(uuidPattern.matches(store.installationId()))
        assertEquals(1, generated)
    }

    @Test
    fun `an id that could not be persisted is reported rather than cached`() {
        // Same rule as the read side: a value that did not reach storage is not
        // an id, and serving it from the cache would make this launch and the
        // next one disagree.
        var generated = 0
        val prefs = InMemoryInstallationIdPrefs().apply { acceptsWrites = false }
        val store = store(prefs, FakeInstallationIdCipher()) {
            generated++
            UUID.randomUUID().toString()
        }

        assertThrows(InstallationIdUnavailableException::class.java) { store.installationId() }
        assertNull(prefs.read())

        prefs.acceptsWrites = true
        val id = store.installationId()
        assertTrue(uuidPattern.matches(id))
        assertEquals("enc($id)", prefs.read())
        assertEquals("the failed attempt was served from the cache", 2, generated)
    }

    // ----------------------------------------------- No encryption possible

    @Test
    fun `an id that cannot be encrypted is reported and nothing is written`() {
        // Below API 23 the Keystore has no AES key for an app at all, and on 23+
        // a key can keep failing to be created. The store has no second form to
        // fall back on: an id in memory is a different installation on every
        // launch, and an id written unencrypted is readable on whatever device a
        // backup is restored onto. So the id is simply unavailable, and JS sees
        // E_INSTALLATION_ID_UNAVAILABLE.
        val prefs = InMemoryInstallationIdPrefs()
        val cipher = FakeInstallationIdCipher(canEncrypt = false)
        val store = store(prefs, cipher)

        assertThrows(InstallationIdUnavailableException::class.java) { store.installationId() }

        assertNull("an unencrypted id was persisted", prefs.read())
        assertEquals(0, prefs.writeCount)
        assertTrue(cipher.written.isEmpty())

        // Nothing was cached either, so a later call that *can* encrypt still
        // mints and persists rather than serving the id it could not store.
        cipher.canEncrypt = true
        val id = store.installationId()
        assertTrue(uuidPattern.matches(id))
        assertEquals("enc($id)", prefs.read())
    }

    @Test
    fun `an undecryptable value is not replaced when a new id cannot be encrypted`() {
        // The old blob stays put: a failed replacement must not wipe it or hand out an id.
        val prefs = InMemoryInstallationIdPrefs("enc(3f2504e0-4f89-41d3-9a0c-0305e82c3301)")
        val cipher = FakeInstallationIdCipher(read = ReadOutcome.Undecryptable, canEncrypt = false)
        val store = store(prefs, cipher)

        assertThrows(InstallationIdUnavailableException::class.java) { store.installationId() }

        assertEquals("enc(3f2504e0-4f89-41d3-9a0c-0305e82c3301)", prefs.read())
        assertEquals(0, prefs.writeCount)
        assertTrue(cipher.written.isEmpty())
    }

    // ---------------------------------------------------------- Concurrency

    @Test
    fun `concurrent first calls return one id`() {
        val prefs = InMemoryInstallationIdPrefs()
        val cipher = FakeInstallationIdCipher()
        val counter = AtomicInteger()
        val store = store(prefs, cipher) {
            counter.incrementAndGet()
            UUID.randomUUID().toString()
        }

        val threads = 8
        val perThread = 25
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(threads)
        val results = Collections.synchronizedList(mutableListOf<String>())
        try {
            repeat(threads) {
                pool.submit {
                    start.await()
                    repeat(perThread) { results.add(store.installationId()) }
                }
            }
            start.countDown()
            pool.shutdown()
            assertTrue("workers did not finish", pool.awaitTermination(20, TimeUnit.SECONDS))
        } finally {
            pool.shutdownNow()
        }

        assertEquals(threads * perThread, results.size)
        // Without the critical section two threads would mint an id and the
        // loser would overwrite the winner: two installations from one device.
        assertEquals(1, results.distinct().size)
        assertEquals(1, counter.get())
        assertEquals(listOf("enc(${results.first()})"), cipher.written)
    }
}