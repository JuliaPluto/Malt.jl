


Connection:

1. The host starts a Julia process for the worker
2. The worker finds a free port and starts a TCP server
3. The worker writes the chosen port to stdout
4. The host reads the port number from stdout
5. The host connects to the worker's server, we now have an open TCP socket

Communication (either direction):

1. Send a tuple `(msg_type::UInt8, message_id::UInt64)`
2. Send your message data
3. (Not yet implemented) send the message boundary



Message data:

from_host_call_with_response

(f, args, kwargs, respond_with_nothing::Bool)

from_host_call_without_response

(f, args, kwargs, this_value_is_ignored::Bool)


from_host_channel_open

(expr, )

from_host_interrupt

()




from_worker_call_result

(result, )

from_worker_call_failure

(result, )

from_worker_channel_value

(value, )









(expects_response::Bool, response_id::UInt16, )
(expects_response::Bool, response_id::UInt16, )





(channel_id)


