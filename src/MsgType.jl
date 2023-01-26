
const MsgType = (
    from_host_call_with_response = UInt8(1),
    from_host_call_without_response = UInt8(2),
    from_host_channel_open = UInt8(10),
    from_host_interrupt = UInt8(20),
    ####
    from_worker_call_result = UInt8(80),
    from_worker_call_failure = UInt8(81),
    from_worker_channel_value = UInt8(90),
    ###
    special_serialization_failure = UInt8(100),
)

const MsgID = UInt64
