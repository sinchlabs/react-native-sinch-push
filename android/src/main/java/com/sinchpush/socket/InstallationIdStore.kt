package com.sinchpush.socket

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.annotation.RequiresApi
import java.security.Key
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import java.util.UUID
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The per-install id.
 *
 * One lowercase UUID per *install* — not per user, not per session, not per
 * socket connection. The relay's `Hello.installation_id` and the push API's
 * `Subscribe.installation_id` have to be the same string, so nothing that
 * rotates (a token refresh, an identity change, a foreground service restart)
 * is allowed anywhere near it.
 *
 * One cached installation UUID. Only cache IDs confirmed persisted. Preserve
 * storage on transient Keystore failure; replace only absent, invalid, or
 * permanently unreadable values.
 *
 * On Android the value lives in `SharedPreferences` **encrypted with a key that
 * lives in the Android Keystore**: the key is generated on the device, never
 * leaves it, and is not recoverable from a backup. There is no plaintext form
 * of the value on any device: a device whose Keystore cannot encrypt has **no**
 * id, because a readable one — the only thing a backup carries — would come
 * back on a second device and put two installs under one id.
 *
 * Both halves are behind interfaces ([InstallationIdCipher],
 * [InstallationIdPrefs]) because `android.security.keystore` and
 * `SharedPreferences` are Android framework: the rules worth testing here are
 * exactly the ones a JVM test cannot reach through them.
 */
internal class InstallationIdStore private constructor(
    private val prefs: InstallationIdPrefs,
    private val cipher: InstallationIdCipher,
    private val newId: () -> String,
) {

    private val lock = Any()

    /**
     * The resolved id, cached after the first call.
     *
     * It keeps `getInstallationId()` off a disk round trip per call (it is asked
     * for on every `Hello`).
     */
    @Volatile
    private var cached: String? = null

    /**
     * The install's id: a lowercase canonical UUID, generated on first use and
     * never rotated. Concurrent first calls all return the same value.
     *
     * @throws InstallationIdUnavailableException when the value could not be
     *   read because the Keystore misbehaved, when a new id could not be
     *   encrypted, or when it could not be persisted. Nothing is overwritten and
     *   nothing is cached in that case, so a retry sees the real state.
     */
    fun installationId(): String {
        cached?.let { return it }
        return synchronized(lock) {
            cached?.let { return it }
            val resolved = when (val persisted = readPersisted()) {
                is Persisted.Found -> persisted.id
                is Persisted.Absent -> generateAndPersist(expectNoKey = persisted.keyMissing)
            }
            cached = resolved
            resolved
        }
    }

    /**
     * Classify the stored value as Found or Absent; throw when unavailable.
     *
     * [Persisted.Absent] covers the cases that mean the same thing — mint a new
     * id and overwrite:
     *   * nothing stored: first launch;
     *   * [DecryptResult.KeyMissing]: the Keystore key is gone, so the value
     *     cannot be read or proven to be ours. [Persisted.Absent.keyMissing] is
     *     set so the replacement is encrypted with `expectNoKey`;
     *   * [DecryptResult.Undecryptable]: the payload is not ours;
     *   * a plaintext that is not a canonical UUID: a shape this version did
     *     not write, cheaper to treat as absent than to propagate.
     *
     * The stored form is the encrypted blob and nothing else, so every value
     * read here goes to [InstallationIdCipher.decrypt].
     *
     * @throws InstallationIdUnavailableException on
     *   [DecryptResult.Unavailable] — the Keystore failed, so the stored value
     *   may well be perfectly good and is left exactly as it is.
     */
    private fun readPersisted(): Persisted {
        val stored = prefs.read()
        if (stored.isNullOrEmpty()) return Persisted.Absent(keyMissing = false)
        return when (val decrypted = cipher.decrypt(stored)) {
            is DecryptResult.Ok ->
                canonicalIdOrNull(decrypted.plaintext)?.let { Persisted.Found(it) }
                    ?: Persisted.Absent(keyMissing = false)
            DecryptResult.Undecryptable -> Persisted.Absent(keyMissing = false)
            DecryptResult.KeyMissing -> Persisted.Absent(keyMissing = true)
            DecryptResult.Unavailable ->
                throw InstallationIdUnavailableException(
                    "the Android Keystore could not decrypt the installation id; " +
                        "the stored value was left untouched",
                )
        }
    }

    /** Lowercase first, then check: a differently-cased UUID is the same id. */
    private fun canonicalIdOrNull(value: String): String? {
        val normalised = value.lowercase()
        return if (UUID_PATTERN.matches(normalised)) normalised else null
    }

    /** What [readPersisted] found: a usable id, or nothing worth keeping. */
    private sealed interface Persisted {
        data class Found(val id: String) : Persisted

        /** [keyMissing]: decrypt said the Keystore key is gone, rather than the payload being bad. */
        data class Absent(val keyMissing: Boolean) : Persisted
    }

    private fun generateAndPersist(expectNoKey: Boolean): String {
        val id = newId().lowercase()
        // `null` means this device cannot encrypt, so there is nothing safe to
        // write: an unencrypted id in the preferences file would come back
        // through a backup on a second device. The value is not written and not
        // kept; the id is reported as unavailable and a later call re-asks the
        // Keystore. `expectNoKey` is the other way `null` happens; see
        // [InstallationIdCipher.encrypt].
        val encrypted = cipher.encrypt(id, expectNoKey)
            ?: throw InstallationIdUnavailableException(
                "the Android Keystore could not encrypt a new installation id; " +
                    "nothing was stored, and an unencrypted id is never persisted",
            )
        if (!prefs.write(encrypted)) {
            throw InstallationIdUnavailableException("the installation id could not be persisted")
        }
        return id
    }

    companion object {
        private const val TAG = "SinchPushInstallation"

        /** A separate preferences file from the socket state's, and from the config's. */
        const val PREFS = "sinch_push_installation"

        /** The one key inside [PREFS]. */
        const val KEY = "installation_id"

        /** Dedicated alias for the installation-ID key. */
        const val KEYSTORE_ALIAS = "com.sinch.push.installation"

        /**
         * Canonical lowercase UUID. Re-checked on read (after lowercasing) so a
         * value written by something else is treated as absent rather than sent.
         */
        private val UUID_PATTERN =
            Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

        @Volatile
        private var shared: InstallationIdStore? = null

        /**
         * The process-wide store.
         *
         * One instance, built lazily and behind a lock, so the generate-once
         * critical section covers every caller in the process.
         */
        fun get(context: Context): InstallationIdStore {
            shared?.let { return it }
            return synchronized(this) {
                shared ?: create(
                    prefs = SharedPreferencesInstallationIdPrefs(context.applicationContext),
                    cipher = AndroidKeyStoreInstallationIdCipher(),
                    newId = { UUID.randomUUID().toString() },
                ).also { shared = it }
            }
        }

        internal fun create(
            prefs: InstallationIdPrefs,
            cipher: InstallationIdCipher,
            newId: () -> String = { UUID.randomUUID().toString() },
        ): InstallationIdStore = InstallationIdStore(prefs, cipher, newId)

        /** Drops the memoised instance so a test can install its own. */
        internal fun resetForTest() {
            synchronized(this) { shared = null }
        }
    }
}

/**
 * The id exists, but it cannot be produced right now: the Keystore misbehaved,
 * it could not encrypt a new one, or the value could not be written.
 *
 * Distinct from "there is no id", which is repaired by minting one — repairing
 * it here would rotate an installation. The bridge turns this into
 * `E_INSTALLATION_ID_UNAVAILABLE`, so a host retries rather than believing a
 * new install happened.
 */
internal class InstallationIdUnavailableException(message: String) : Exception(message)

/**
 * Encrypts and decrypts the one value [InstallationIdStore] persists.
 *
 * The two halves answer different questions, so they have different failure
 * shapes: [encrypt] either produces a payload or cannot produce one on this
 * device at all, while [decrypt] has to say *why* it failed, because only some
 * of the reasons mean the stored value is gone.
 */
internal interface InstallationIdCipher {
    /**
     * `base64(iv || ciphertext)`, or `null` when this device cannot encrypt.
     *
     * [expectNoKey] is set when the caller replaces a value because
     * [DecryptResult.KeyMissing]: the implementation must then not encrypt under
     * a key that already exists — the earlier "missing" answer was wrong — and
     * returns `null` instead. It still creates a key when there is none.
     */
    fun encrypt(plaintext: String, expectNoKey: Boolean = false): String?

    /** The plaintext, or why there is none. */
    fun decrypt(payload: String): DecryptResult
}

/** What a decrypt attempt produced. */
internal sealed interface DecryptResult {
    /** The value, decrypted. */
    data class Ok(val plaintext: String) : DecryptResult

    /**
     * Not readable now or later: the payload is not base64, it is too short to
     * be one of ours, or it fails authentication. The stored value is
     * worthless, so the caller may replace it.
     */
    data object Undecryptable : DecryptResult

    /**
     * There is no key under the alias. The caller may replace the value, but
     * the "no key" answer can be wrong, so the replacement is encrypted with
     * `expectNoKey = true`.
     */
    data object KeyMissing : DecryptResult

    /**
     * The Keystore itself failed — locked, throttled, provider error. The stored
     * value may still be perfectly good, so the caller must neither overwrite it
     * nor cache anything in its place.
     */
    data object Unavailable : DecryptResult
}

/** Where the stored value sits. One slot in one preferences file. */
internal interface InstallationIdPrefs {
    fun read(): String?

    /**
     * `false` when the value did **not** reach storage.
     *
     * The store has to be able to tell: an id that was generated but not saved
     * is one the next launch will not have.
     */
    fun write(value: String): Boolean
}

/** The production slot. */
internal class SharedPreferencesInstallationIdPrefs(context: Context) : InstallationIdPrefs {

    private val prefs = context.applicationContext
        .getSharedPreferences(InstallationIdStore.PREFS, Context.MODE_PRIVATE)

    override fun read(): String? = prefs.getString(InstallationIdStore.KEY, null)

    /**
     * `commit()` rather than `apply()`: the caller needs to know whether the
     * value landed before it hands the id out, and `apply()` reports success
     * for a write that has not happened yet.
     */
    override fun write(value: String): Boolean =
        prefs.edit().putString(InstallationIdStore.KEY, value).commit()
}

/**
 * AES-GCM under a key held in the Android Keystore.
 *
 * The stored form is `base64(iv || ciphertext||tag)`, so one preferences key
 * holds everything needed to decrypt it. GCM rather than CBC because it
 * authenticates: a value that was truncated or edited fails to decrypt instead
 * of yielding garbage that the store would have to guess about.
 *
 * **When the key may be deleted.** The same rule as the store's, applied to the
 * Keystore: not knowing is not the same as there being nothing. A key entry is
 * deleted and regenerated only when the Keystore *proves* the entry is
 * permanently gone or corrupt — API 33+, an `android.security.KeyStoreException`
 * that is not transient and carries `ERROR_KEY_DOES_NOT_EXIST` or
 * `ERROR_KEY_CORRUPTED` (see [isProvenPermanent]). Everything else is
 * unavailable and the alias is left alone: AOSP wraps *transient* Keystore
 * faults (a busy or locked daemon, `SYSTEM_ERROR`) in `UnrecoverableKeyException`
 * as well, so treating that exception as "corrupt" would delete a working key.
 * Below API 33 there is no way to tell the two apart, so a truly corrupted
 * alias stays unavailable there by design.
 */
internal class AndroidKeyStoreInstallationIdCipher(
    private val alias: String = InstallationIdStore.KEYSTORE_ALIAS,
) : InstallationIdCipher {

    override fun encrypt(plaintext: String, expectNoKey: Boolean): String? {
        // Expected, not an error: no AES Keystore key exists below API 23, so
        // there is nothing to log and nothing to try.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            // No `KeyPermanentlyInvalidatedException` retry: that is raised for
            // keys bound to user authentication or a lock screen, and this one is
            // neither.
            cipher.init(Cipher.ENCRYPT_MODE, key(expectNoKey))
            val ciphertext = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
            Base64.encodeToString(cipher.iv + ciphertext, Base64.NO_WRAP)
        } catch (t: Throwable) {
            Log.w(TAG, "could not encrypt the installation id; it will not be stored", t)
            null
        }
    }

    /**
     * [DecryptResult.Undecryptable] for a payload that is not ours (bad base64,
     * too short, fails authentication); [DecryptResult.KeyMissing] for a missing
     * alias or a proven-permanent key failure from the lookup; any other failure
     * (including from `init` / `doFinal`) is [DecryptResult.Unavailable].
     */
    override fun decrypt(payload: String): DecryptResult {
        val bytes = try {
            Base64.decode(payload, Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            // Not base64, so not something this class wrote.
            return DecryptResult.Undecryptable
        }
        // Too short to hold a GCM IV and a tag, so it was never written by us.
        if (bytes.size <= IV_BYTES + TAG_BITS / 8) return DecryptResult.Undecryptable

        val secretKey = when (val existing = existingKey()) {
            // No alias means no key can ever read this value again.
            is KeyLookup.Missing -> return DecryptResult.KeyMissing
            is KeyLookup.Unavailable -> return DecryptResult.Unavailable
            is KeyLookup.Found -> existing.key
        }
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey,
                GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES),
            )
            DecryptResult.Ok(
                String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES), Charsets.UTF_8),
            )
        } catch (e: AEADBadTagException) {
            // The tag did not verify: the key here is not the key that wrote
            // this value (a backup restored onto another device), or the payload
            // was edited. Either way it is unreadable now and unreadable later,
            // so the caller is free to replace it.
            DecryptResult.Undecryptable
        } catch (t: Throwable) {
            // Anything else — a locked or throttled Keystore, a provider error.
            // The stored value is left exactly as it is; minting a replacement
            // for a transient failure is how an installation id rotates itself.
            Log.w(TAG, "could not decrypt the installation id; leaving the stored value alone", t)
            DecryptResult.Unavailable
        }
    }

    /** What looking up the existing key found — three answers, not two. */
    private sealed interface KeyLookup {
        data class Found(val key: SecretKey) : KeyLookup

        /** No key under this alias. Decrypt can never succeed. */
        data object Missing : KeyLookup

        /** The Keystore could not be read at all. */
        data object Unavailable : KeyLookup
    }

    /**
     * The existing key, and **never a new one**.
     *
     * Decrypting must not create a key: a key minted here is a different key
     * from the one that wrote the stored value, so it cannot read it. Only
     * [encrypt] may create the key, through [key].
     *
     * An `UnrecoverableKeyException` is [KeyLookup.Missing] only when it is
     * [isProvenPermanent]; otherwise it may be a transient Keystore fault with a
     * good key behind it, and the answer is [KeyLookup.Unavailable].
     *
     * `getKey == null` is authoritative only on API 31+ (Keystore2); on API 23-30
     * it can be a binder fault, mitigated by the second lookup under `expectNoKey`.
     */
    private fun existingKey(): KeyLookup = try {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        // No `containsAlias` pre-check: it answers `false` on transient faults
        // too (Keystore2 swallows busy / SYSTEM_ERROR, the legacy provider
        // returns `false` on a RemoteException), which would read as "no key".
        // `getKey` returning `null` is the only "no alias" answer trusted, and
        // `encrypt(expectNoKey = true)` double-checks it.
        when (val entry = keyStore.getKey(alias, null)) {
            null -> KeyLookup.Missing
            is SecretKey -> KeyLookup.Found(entry)
            // Something else under our alias: not proof the real key is
            // gone, so it is not licence to replace anything.
            else -> {
                Log.w(TAG, "the Keystore entry for the installation id is not a secret key")
                KeyLookup.Unavailable
            }
        }
    } catch (e: UnrecoverableKeyException) {
        if (isProvenPermanent(e)) {
            Log.w(TAG, "the Keystore key for the installation id is permanently unrecoverable", e)
            KeyLookup.Missing
        } else {
            Log.w(TAG, "could not recover the Keystore key; leaving the installation id alone", e)
            KeyLookup.Unavailable
        }
    } catch (t: Throwable) {
        Log.w(TAG, "could not read the Keystore; leaving the installation id alone", t)
        KeyLookup.Unavailable
    }

    /**
     * The device key, created on first use — and the only place one is created
     * or replaced.
     *
     * Only [encrypt] may create or replace a key, and only because its caller
     * (`generateAndPersist`) has already established that the stored value is
     * absent, unreadable or not a UUID. [existingKey], the decrypt path, never
     * creates or deletes one.
     *
     * An existing entry is deleted only when `getKey` throws an
     * `UnrecoverableKeyException` that is [isProvenPermanent]. Any other
     * failure — including an unproven `UnrecoverableKeyException` and an entry
     * that is not a [SecretKey] — is rethrown, so [encrypt] returns `null` and
     * the alias is left untouched. A `getKey` that returns `null` (no alias)
     * just generates a key.
     *
     * [expectNoKey]: the caller replaces a value because [decrypt] reported
     * [DecryptResult.KeyMissing]. An existing [SecretKey] then contradicts that
     * report (the platform answers "no such alias" on transient faults too), so
     * it is not used: this throws and [encrypt] returns `null`.
     *
     * Nothing here coordinates across processes, and nothing needs to: the
     * store is only ever touched from the app's own process, and
     * [InstallationIdStore.get] memoises one instance behind one lock.
     */
    @RequiresApi(Build.VERSION_CODES.M)
    private fun key(expectNoKey: Boolean): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing: Key? = try {
            keyStore.getKey(alias, null)
        } catch (e: UnrecoverableKeyException) {
            if (!isProvenPermanent(e)) throw e
            Log.w(TAG, "the Keystore key for the installation id is permanently unrecoverable; replacing it", e)
            keyStore.deleteEntry(alias)
            null
        }
        if (existing is SecretKey) {
            check(!expectNoKey) {
                "the Keystore key for the installation id exists although it was reported missing"
            }
            return existing
        }
        check(existing == null) { "the Keystore entry for the installation id is not a secret key" }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    /**
     * Whether an `UnrecoverableKeyException` is *proven* permanent — the only
     * licence to treat the key as gone. API 33+ only; below that the cause
     * carries no usable classification, so the answer is "no".
     */
    private fun isProvenPermanent(e: UnrecoverableKeyException): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && isPermanentKeystoreFailure(e)

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun isPermanentKeystoreFailure(e: UnrecoverableKeyException): Boolean {
        val ks = e.cause as? android.security.KeyStoreException ?: return false
        return !ks.isTransientFailure && (
            ks.numericErrorCode == android.security.KeyStoreException.ERROR_KEY_DOES_NOT_EXIST ||
                ks.numericErrorCode == android.security.KeyStoreException.ERROR_KEY_CORRUPTED
            )
    }

    private companion object {
        const val TAG = "SinchPushInstallation"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}