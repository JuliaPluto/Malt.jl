const BufferedIO = m.BufferedIO
using Serialization
import Random




const test_data1 = (123,sqrt,(a=2,b=[2,sort]), :(1 + 2))

const test_data2 = (123,sqrt,(a=2,b=[2,sort]), :(1 + 2), names(Base))

const test_data3 = fill(test_data1, 20)

const test_data4 = (1,2,rand(UInt8,50_000_000))

const test_data5 = map(N -> rand(UInt8, N), 0:10:400)




function sprintb(f::Function)
	io = IOBuffer()
	f(io)
	take!(io)
end

function sprintbb(f::Function; kwargs...)
	sprintb() do io
		b = BufferedIO(io; kwargs...)
		f(b)
		flush(b)
	end
end

function serialize_this(x)
	function(io)
		serialize(io, x)
	end
end

@testset "BufferedIO" begin
        
    @testset "basics" begin
        for i in 3:7:200
            @test sprintb(serialize_this(test_data1)) == sprintbb(serialize_this(test_data1); buffersize=i); buffersize=i

            @test sprintb(serialize_this(test_data2)) == sprintbb(serialize_this(test_data2); buffersize=i); buffersize=i

            @test sprintb(serialize_this(test_data3)) == sprintbb(serialize_this(test_data3); buffersize=i); buffersize=i

            @test sprintb(serialize_this(test_data4)) == sprintbb(serialize_this(test_data4); buffersize=i); buffersize=i

            @test sprintb(serialize_this(test_data5)) == sprintbb(serialize_this(test_data5); buffersize=i)
        end
    end

    
    @testset "fuzzy" begin
        function fuzzy(rng)
            function(io)
                for _i in 1:2000
                    if rand(rng, Bool)
                        write(io, rand(rng, UInt8))
                    elseif rand(rng, Bool)
                        serialize(io, test_data1)
                    else
                        write(io, rand(rng, UInt8, rand(rng, 1:100)))
    
                    end
                end
            end
        end
        
        for i in 1:7:200
            @test sprintb(fuzzy(Random.MersenneTwister(i))) == 
                sprintbb(fuzzy(Random.MersenneTwister(i)); buffersize=i)
        end
    end
end

