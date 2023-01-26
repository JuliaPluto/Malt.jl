

"""
Wraps around an IO object, and maintains an internal buffer to collect writes. When the buffer is full, it is flushed to the underlying IO object. 

This is useful for reducing the number of `write` calls, which can be a performance bottleneck when the IO object is a network connection.
	
The advantage of this over `IOBuffer` is that you avoid allocating everything into memory first, before sending it over the original IO.

Implementation inspired by https://github.com/JuliaIO/BufferedStreams.jl and `Base.IOBuffer`.
"""
struct BufferedIO{T<:IO} <: IO
	source::T
	buffer::Vector{UInt8}
	position::Ref{Int}
	buffersize::Int
end
BufferedIO(source::IO; buffersize::Int=128*1024) = BufferedIO(source, zeros(UInt8, buffersize), Ref{Int}(1), buffersize)

@inline function Base.write(io::BufferedIO, x::UInt8)
	L = io.buffersize
	p = io.position[]

	if p <= L
		@inbounds io.buffer[p] = x
		io.position[] = p + 1
		1
	else
		Base.flush(io)
		Base.write(io, x)
	end
end


function Base.write(io::BufferedIO, x::Vector{UInt8})
	L = io.buffersize
	xL = length(x)
	p = io.position[]

	if p + xL <= L + 1 # if the data fits in the remaining buffer
		unsafe_copyto!(io.buffer, p, x, 1, xL)
		io.position[] = p + xL
		xL
	else
		Base.flush(io)
		# Base.unsafe_write(io.source, pointer(x), UInt(xL))
		Base.write(io.source, x)
	end
end

# I don't think unsafe_write is heavily used by Serialization, and I'm not sure how to test it, so let's leave it out for now.

# function Base.unsafe_write(io::BufferedIO, point::Ptr{UInt8}, n::UInt)
# 	L = length(io.buffer)
# 	xL = n
# 	p = io.position[]

# 	if p + xL <= L + 1 # if the data fits in the remaining buffer
# 		unsafe_copyto!(pointer(io.buffer, p), point, xL)
# 		io.position[] = p + xL
# 		xL
# 	else # if the data is smaller than the buffer, but it does not fit right now
# 		Base.flush(io)
# 		Base.unsafe_write(io.source, point, n)
# 	end
# end

Base.isopen(io::BufferedIO) = Base.isopen(io.source)

function Base.flush(io::BufferedIO)
	p = io.position[]
	if p > 1
		write(io.source, view(io.buffer, 1:p-1))
		# unsafe_write(io.source, pointer(io.buffer), UInt(p-1))
		io.position[] = 1
	end
end

function Base.close(io::BufferedIO)
	Base.flush(io)
	Base.close(io.source)
end
