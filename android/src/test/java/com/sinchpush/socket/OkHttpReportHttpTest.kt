package com.sinchpush.socket

import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** SB-67: the real transport against a loopback socket - above all that its timeout is a deadline. */
class OkHttpReportHttpTest {

    private lateinit var server: ServerSocket
    private val release = CountDownLatch(1)

    private val url get() = URL("http://127.0.0.1:${server.localPort}/svc/ReportEvents")
    private val headers = ReportWire.headers("token")
    private val body = ReportWire.requestBody(listOf("m" to "s"))

    /** The request's header lines (lower-cased names) and body, as the server read them. */
    private class Request(val headers: Map<String, String>, val body: ByteArray)

    @Before
    fun start() {
        server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
    }

    @After
    fun stop() {
        release.countDown()
        server.close()
    }

    /** Accepts one connection on a thread, reads the request, then runs [respond]. */
    private fun serve(respond: (Socket, Request) -> Unit) {
        Thread {
            try {
                server.accept().use { socket ->
                    respond(socket, readRequest(socket.getInputStream()))
                }
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true }.start()
    }

    private fun readRequest(input: InputStream): Request {
        val head = StringBuilder()
        while (!head.endsWith("\r\n\r\n")) {
            val b = input.read()
            if (b < 0) break
            head.append(b.toChar())
        }
        val parsed = head.lines().drop(1).mapNotNull { line ->
            line.split(":", limit = 2).takeIf { it.size == 2 }?.let { it[0].trim().lowercase() to it[1].trim() }
        }.toMap()
        val length = parsed["content-length"]?.toInt() ?: 0
        val bytes = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(bytes, read, length - read)
            if (n < 0) break
            read += n
        }
        return Request(parsed, bytes)
    }

    @Test
    fun `SB67_aResponseIsReadWithItsContentTypeAndGrpcStatus`() {
        serve { socket, _ ->
            val out = socket.getOutputStream()
            out.write(
                ("HTTP/1.1 200 OK\r\ncontent-type: application/grpc-web+proto\r\ngrpc-status: 0\r\n" +
                    "content-length: 5\r\nconnection: close\r\n\r\n").toByteArray(),
            )
            out.write(byteArrayOf(0, 0, 0, 0, 0))
            out.flush()
        }

        val response = OkHttpReportHttp.post(url, headers, body, 5_000)

        assertNotNull(response)
        assertEquals(200, response!!.status)
        assertEquals("application/grpc-web+proto", response.contentType)
        assertEquals("0", response.grpcStatusHeader)
        assertEquals(ReportOutcome.SENT, ReportWire.outcome(response.status, response.contentType, response.grpcStatusHeader, response.body))
    }

    /** HTTP/1.1 chunked trailers stand in for HTTP/2 ones: both come after the body, from `response.trailers()`. */
    @Test
    fun `SB67_aGrpcStatusInTheTrailersIsReadAfterTheBody`() {
        serve { socket, _ ->
            val out = socket.getOutputStream()
            out.write(
                ("HTTP/1.1 200 OK\r\ncontent-type: application/grpc+proto\r\ntransfer-encoding: chunked\r\n" +
                    "trailer: grpc-status\r\nconnection: close\r\n\r\n0\r\ngrpc-status: 16\r\n\r\n").toByteArray(),
            )
            out.flush()
        }

        val response = OkHttpReportHttp.post(url, headers, body, 5_000)

        assertEquals("16", response?.grpcStatusHeader)
        assertEquals(ReportOutcome.UNAUTHENTICATED, ReportWire.outcome(response!!.status, response.contentType, response.grpcStatusHeader, response.body))
    }

    @Test
    fun `SB67_theHeaderStatusWinsOverTheTrailers`() {
        serve { socket, _ ->
            socket.getOutputStream().write(
                ("HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\ntransfer-encoding: chunked\r\n" +
                    "connection: close\r\n\r\n0\r\ngrpc-status: 16\r\n\r\n").toByteArray(),
            )
        }

        assertEquals("0", OkHttpReportHttp.post(url, headers, body, 5_000)?.grpcStatusHeader)
    }

    /** The empty plain-gRPC success whose status nobody could read: no status, which the mapping counts as sent. */
    @Test
    fun `SB67_aResponseWithoutTrailersHasNoStatus`() {
        serve { socket, _ ->
            socket.getOutputStream().write(
                "HTTP/1.1 200 OK\r\ncontent-type: application/grpc+proto\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".toByteArray(),
            )
        }

        val response = OkHttpReportHttp.post(url, headers, body, 5_000)

        assertNotNull(response)
        assertNull(response!!.grpcStatusHeader)
        assertEquals(ReportOutcome.SENT, ReportWire.outcome(response.status, response.contentType, response.grpcStatusHeader, response.body))
    }

    /** Over the 64 KiB cap the body is not drained, so the trailers are never read. */
    @Test
    fun `SB67_anOversizedResponseIsNotOursAndIsRetried`() {
        val size = 70 * 1024
        serve { socket, _ ->
            val out = socket.getOutputStream()
            out.write(
                ("HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\ntransfer-encoding: chunked\r\n" +
                    "connection: close\r\n\r\n${size.toString(16)}\r\n").toByteArray(),
            )
            out.write(ByteArray(size))
            out.write("\r\n0\r\ngrpc-status: 16\r\n\r\n".toByteArray())
            out.flush()
        }

        val response = OkHttpReportHttp.post(url, headers, body, 5_000)

        assertNull("over the cap: a transport failure (RETRY), never SENT", response)
    }

    @Test
    fun `SB67_theRequestCarriesTheGrpcWebHeadersAndBody`() {
        var seen: Request? = null
        serve { socket, request ->
            seen = request
            socket.getOutputStream().write("HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n".toByteArray())
        }

        val response = OkHttpReportHttp.post(url, headers, body, 5_000)

        assertEquals(204, response?.status)
        assertEquals("token", seen!!.headers["authorization"])
        assertTrue(seen!!.headers["content-type"]!!.startsWith("application/grpc-web+proto"))
        assertEquals("1", seen!!.headers["x-grpc-web"])
        assertTrue(body.contentEquals(seen!!.body))
    }

    @Test
    fun `SB67_aRedirectIsNotFollowed`() {
        serve { socket, _ ->
            socket.getOutputStream().write(
                "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:1/\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".toByteArray(),
            )
        }

        val response = OkHttpReportHttp.post(url, headers, body, 5_000)

        assertEquals(302, response?.status)
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(302, response?.contentType, null, null))
    }

    @Test
    fun `SB67_aServerThatNeverAnswersIsCutOffAtTheDeadline`() {
        serve { _, _ -> release.await(30, TimeUnit.SECONDS) }

        val started = System.nanoTime()
        val response = OkHttpReportHttp.post(url, headers, body, 600)
        val tookMs = (System.nanoTime() - started) / 1_000_000

        assertNull(response)
        assertTrue("took ${tookMs}ms, the budget was 600ms", tookMs in 500..3_000)
    }

    @Test
    fun `SB67_aBodyThatTricklesInIsCutOffAtTheDeadlineToo`() {
        serve { socket, _ ->
            val out = socket.getOutputStream()
            out.write("HTTP/1.1 200 OK\r\ncontent-type: application/grpc-web+proto\r\ncontent-length: 1000\r\n\r\n".toByteArray())
            out.flush()
            repeat(100) {
                out.write(1)
                out.flush()
                Thread.sleep(100)
            }
        }

        val started = System.nanoTime()
        val response = OkHttpReportHttp.post(url, headers, body, 800)
        val tookMs = (System.nanoTime() - started) / 1_000_000

        assertNull("the half-read response is not an answer", response)
        assertTrue("took ${tookMs}ms, the budget was 800ms", tookMs in 700..3_000)
    }

    @Test
    fun `SB67_anUnreachableHostIsNullNotAnException`() {
        val dead = URL("http://127.0.0.1:1/x")

        assertNull(OkHttpReportHttp.post(dead, headers, ByteArray(0), 1_000))
    }
}
