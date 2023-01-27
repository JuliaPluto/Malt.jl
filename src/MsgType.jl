
const MsgType = (
    from_host_call_with_response = UInt8(1),
    from_host_call_without_response = UInt8(2),
    from_host_channel_open = UInt8(10),
    from_host_interrupt = UInt8(20),
    ####
    from_worker_call_result = UInt8(80),
    from_worker_call_failure = UInt8(81),
    from_worker_channel_value = UInt8(90),
)

const MsgID = UInt64

const BUFFER_SIZE = 4 * Base.SZ_UNBUFFERED_IO

# Boundary inserted between messages on the wire, used for recovering
# from deserialization errors. Picked arbitrarily.
# A size of 10 bytes indicates ~ ~1e24 possible boundaries, so chance of collision
# with message contents is negligible.
const MSG_BOUNDARY = UInt8[0x79, 0x8e, 0x8e, 0xf5, 0x6e, 0x9b, 0x2e, 0x97, 0xd5, 0x7d]
