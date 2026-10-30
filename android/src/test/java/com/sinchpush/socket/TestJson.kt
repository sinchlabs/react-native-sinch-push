package com.sinchpush.socket

/**
 * A minimal JSON reader for the golden-vector fixture.
 *
 * Deliberately not a dependency: `org.json` is stubbed in the Android unit-test
 * classpath and a real parser jar would have to win a class-loading race
 * against `android.jar` to be usable here. The fixture is plain data - objects,
 * arrays, strings, integers, booleans - and the parser below is total over that
 * subset, with an explicit failure on anything else so a malformed fixture is a
 * test failure rather than a silently missing field.
 */
internal object TestJson {

    fun parse(text: String): Any? {
        val p = Parser(text)
        val value = p.readValue()
        p.skipWhitespace()
        require(p.atEnd()) { "trailing content at offset ${p.offset}" }
        return value
    }

    private class Parser(private val text: String) {
        var offset = 0
            private set

        fun atEnd(): Boolean = offset >= text.length

        fun skipWhitespace() {
            while (offset < text.length && text[offset].isWhitespace()) offset++
        }

        fun readValue(): Any? {
            skipWhitespace()
            require(!atEnd()) { "unexpected end of JSON input" }
            return when (val c = text[offset]) {
                '{' -> readObject()
                '[' -> readArray()
                '"' -> readString()
                't', 'f' -> readBoolean()
                'n' -> readNull()
                else -> {
                    require(c == '-' || c in '0'..'9') { "unexpected character '$c' at offset $offset" }
                    readNumber()
                }
            }
        }

        private fun readObject(): Map<String, Any?> {
            expect('{')
            val out = linkedMapOf<String, Any?>()
            skipWhitespace()
            if (peek() == '}') { offset++; return out }
            while (true) {
                skipWhitespace()
                val key = readString()
                skipWhitespace()
                expect(':')
                out[key] = readValue()
                skipWhitespace()
                when (val c = next()) {
                    ',' -> continue
                    '}' -> return out
                    else -> error("expected ',' or '}' but found '$c' at offset ${offset - 1}")
                }
            }
        }

        private fun readArray(): List<Any?> {
            expect('[')
            val out = mutableListOf<Any?>()
            skipWhitespace()
            if (peek() == ']') { offset++; return out }
            while (true) {
                out.add(readValue())
                skipWhitespace()
                when (val c = next()) {
                    ',' -> continue
                    ']' -> return out
                    else -> error("expected ',' or ']' but found '$c' at offset ${offset - 1}")
                }
            }
        }

        private fun readString(): String {
            expect('"')
            val sb = StringBuilder()
            while (true) {
                require(!atEnd()) { "unterminated string" }
                when (val c = text[offset++]) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        require(!atEnd()) { "unterminated escape" }
                        when (val e = text[offset++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                require(offset + 4 <= text.length) { "truncated \\u escape" }
                                sb.append(text.substring(offset, offset + 4).toInt(16).toChar())
                                offset += 4
                            }
                            else -> error("unknown escape '\\$e' at offset ${offset - 1}")
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }

        private fun readBoolean(): Boolean {
            val word = text.substring(offset, minOf(offset + 5, text.length))
            if (word.startsWith("true")) { offset += 4; return true }
            if (word.startsWith("false")) { offset += 5; return false }
            error("not a boolean at offset $offset")
        }

        private fun readNull(): Any? {
            require(text.startsWith("null", offset)) { "not null at offset $offset" }
            offset += 4
            return null
        }

        private fun readNumber(): Any {
            val start = offset
            if (peek() == '-') offset++
            while (!atEnd() && text[offset] in "0123456789.eE+-") offset++
            val raw = text.substring(start, offset)
            return if (raw.any { it == '.' || it == 'e' || it == 'E' }) {
                raw.toDouble()
            } else {
                raw.toLong()
            }
        }

        private fun peek(): Char? = if (atEnd()) null else text[offset]

        private fun next(): Char {
            require(!atEnd()) { "unexpected end of JSON input" }
            return text[offset++]
        }

        private fun expect(c: Char) {
            skipWhitespace()
            require(!atEnd() && text[offset] == c) { "expected '$c' at offset $offset" }
            offset++
        }
    }
}

/** This object as a JSON object. */
internal fun Any?.jsonObject(): Map<String, Any?> =
    this as? Map<String, Any?> ?: error("expected a JSON object, got $this")

/** This array as a JSON array. */
internal fun Any?.jsonArray(): List<Any?> =
    this as? List<Any?> ?: error("expected a JSON array, got $this")

/** The named field, required. */
internal fun Map<String, Any?>.field(name: String): Any? =
    this[name] ?: error("missing field '$name'")

/** The named field as a string. */
internal fun Map<String, Any?>.string(name: String): String =
    field(name) as? String ?: error("field '$name' is not a string")

/** The named field as an int, whether the parser read it as a long or a double. */
internal fun Map<String, Any?>.int(name: String): Int = when (val v = field(name)) {
    is Long -> v.toInt()
    is Double -> v.toInt()
    else -> error("field '$name' is not a number")
}

/** The named field as a list of objects. */
internal fun Map<String, Any?>.objects(name: String): List<Map<String, Any?>> =
    field(name).jsonArray().map { it.jsonObject() }