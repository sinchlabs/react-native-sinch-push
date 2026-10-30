package com.sinchpush.socket

/**
 * The outbox's on-disk form.
 *
 * One record per entry, fields separated by ASCII unit/record separators -
 * characters that cannot appear in a `message_id`, a Sinch id or a decode
 * reason, so nothing has to be escaped and the format cannot be ambiguous.
 *
 * Hand-rolled rather than `org.json` for the same reason the golden-vector
 * suite has its own JSON reader: `org.json` is a stub on the Android unit-test
 * classpath, and a dependency that has to win a class-loading race to be usable
 * is a dependency that silently is not.
 */
internal object OutboxCodec {

    private const val RECORD_SEP = "\u001E"
    private const val FIELD_SEP = "\u001F"
    private const val STATUS_UNSPECIFIED = "0"

    fun encode(entries: List<PendingReport>): String =
        entries.joinToString(RECORD_SEP) { entry ->
            listOf(
                entry.messageId,
                entry.sinchMessageId,
                entry.status.code.toString(),
                entry.reason,
                entry.queuedAtMs.toString(),
                entry.attempts.toString(),
                entry.notBeforeMs.toString(),
                if (entry.deferredByRateLimit) "1" else "0",
            ).joinToString(FIELD_SEP)
        }

    /**
     * Reads back what [encode] wrote.
     *
     * A record that cannot be read is dropped rather than thrown on: a corrupted
     * outbox must not stop the socket from starting, and an unreadable report is
     * no more useful than one that was never queued.
     */
    fun decode(text: String): List<PendingReport> {
        if (text.isEmpty()) return emptyList()
        return text.split(RECORD_SEP).mapNotNull { record ->
            if (record.isEmpty()) return@mapNotNull null
            val fields = record.split(FIELD_SEP)
            if (fields.size < 8) return@mapNotNull null
            val status = ReportStatus.fromCode(fields[2].toIntOrNull() ?: return@mapNotNull null)
                ?: return@mapNotNull null
            val messageId = fields[0]
            if (messageId.isEmpty()) return@mapNotNull null
            PendingReport(
                messageId = messageId,
                sinchMessageId = fields[1],
                status = status,
                reason = fields[3],
                queuedAtMs = fields[4].toLongOrNull() ?: 0L,
                attempts = fields[5].toIntOrNull() ?: 0,
                notBeforeMs = fields[6].toLongOrNull() ?: 0L,
                deferredByRateLimit = fields[7] == "1",
            )
        }
    }
}