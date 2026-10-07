package id.ac.usu.resqmesh

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Pure binary validation, shared with Dart/C++ RN v1 golden vectors. */
internal data class NeighborEnvelope(
    val status: Boolean, val transmitter: Long, val boot: Long,
    val sequence: Long, val scope: Long, val complete: Boolean,
    val inner: ByteArray?, val inventory: List<ByteArray>
) {
    val burstIdentity: String get() = "$scope:$transmitter:$boot:$sequence"
}

internal object NeighborTransport {
    // Presence of the versioned profile key is enough; malformed config must not fork an owner.
    fun requiresSchedulerOwner(profile: String?): Boolean = !profile.isNullOrBlank()
    const val HEADER = 22
    const val MAX_LENGTH = 86
    fun decode(bytes: ByteArray): NeighborEnvelope? {
        if (bytes.size < HEADER || bytes[0] != 0x52.toByte() || bytes[1] != 0x4e.toByte() ||
            bytes[2] != 1.toByte() || bytes[3].toInt() !in 0..1 ||
            bytes[20].toInt() !in 0..8 || bytes[21].toInt() !in 0..1) return null
        val status = bytes[3] == 1.toByte()
        val count = bytes[20].toInt()
        if (bytes.size != HEADER + if (status) count * 8 else 17) return null
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        val ids = listOf(4,8,12,16).map { b.getInt(it).toLong() and 0xffffffffL }
        if (ids.any { it == 0L }) return null
        val inner = if (status) null else bytes.copyOfRange(HEADER, bytes.size)
        if (inner != null && (count != 0 || bytes[21] != 1.toByte() || !validInner(inner))) return null
        val inventory = (0 until count).map { bytes.copyOfRange(HEADER + it * 8, HEADER + (it+1) * 8) }
        if (inventory.any { !validFlags(it[7].toInt() and 255) }) return null
        return NeighborEnvelope(status,ids[0],ids[1],ids[2],ids[3],bytes[21]==1.toByte(),inner,inventory)
    }
    fun validFlags(flags: Int): Boolean = (flags and 63) <= 2 && !(flags and 128 != 0 && flags and 63 == 1)
    fun validInner(b: ByteArray): Boolean {
        if (b.size != 17 || b[0] != 0x52.toByte() || b[1] != 0x4d.toByte()) return false
        val flags = b[16].toInt() and 255
        val status = b[15].toInt() and 255
        if (status > 2 || (flags and 128 != 0 && status == 1)) return false
        if (flags and 128 == 0) {
            fun coord(o: Int): Int {
                val raw = (b[o].toInt() and 255 shl 16) or (b[o+1].toInt() and 255 shl 8) or (b[o+2].toInt() and 255)
                return if (raw and 0x800000 != 0) raw - 0x1000000 else raw
            }
            if (coord(9) !in -900000..900000 || coord(12) !in -1800000..1800000) return false
        }
        return true
    }
    fun validPayload(b: ByteArray): Boolean = if (b.size==17) validInner(b) else decode(b)!=null
}
