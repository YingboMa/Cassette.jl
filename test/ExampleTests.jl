module ExampleTests

using Test, Cassette
using Cassette: @context, @prehook, @posthook, @primitive, @pass, @overdub, box, unbox, hasmeta, meta

############################################################################################

function rosenbrock(x::Vector{Float64})
    a = 1.0
    b = 100.0
    result = 0.0
    for i in 1:length(x)-1
        result += (a - x[i])^2 + b*(x[i+1] - x[i]^2)^2
    end
    return result
end

x = rand(2)

@context RosCtx

messages = String[]
@prehook (f::Any)(args...) where {__CONTEXT__<:RosCtx} = push!(messages, string("calling ", f, args))
@test @overdub(RosCtx(), rosenbrock(x)) == rosenbrock(x)
@test length(messages) > 90

@prehook (f::Any)(args...) where {__CONTEXT__<:RosCtx} = push!(__context__.metadata, string("calling ", f, args))
messages2 = String[]
@test @overdub(RosCtx(metadata=messages2), rosenbrock(x)) == rosenbrock(x)
@test messages == messages2

@prehook (f::Any)(args...) where {__CONTEXT__<:RosCtx} = nothing
@prehook (f::Any)(args::Number...) where {__CONTEXT__<:RosCtx} = push!(__context__.metadata, args)
argslog = Any[]
@test @overdub(RosCtx(metadata=argslog), rosenbrock(x)) == rosenbrock(x)
for args in argslog
    @test all(x -> isa(x, Number), args)
end

############################################################################################

x = rand()
sin_plus_cos(x) = sin(x) + cos(x)
@context SinCtx
@test @overdub(SinCtx(), sin_plus_cos(x)) === sin_plus_cos(x)
@primitive sin(x) where {__CONTEXT__<:SinCtx} = cos(x)
@test @overdub(SinCtx(), sin_plus_cos(x)) === (2 * cos(x))

############################################################################################

x = 2
foldmul(x, args...) = Core._apply(Base.afoldl, (*, x), args...)
@context FoldCtx
@test @overdub(FoldCtx(), foldmul(x)) === foldmul(x)

############################################################################################

@context CountCtx
count1 = Ref(0)
@prehook (f::Any)(args::Number...) where {__CONTEXT__<:CountCtx} = (__context__.metadata[] += 1)
@overdub(CountCtx(metadata=count1), sin(1))
@prehook (f::Any)(args::Number...) where {__CONTEXT__<:CountCtx} = (__context__.metadata[] += 2)
count2 = Ref(0)
@overdub(CountCtx(metadata=count2), sin(1))
@test (2 * count1[]) === count2[]

############################################################################################

square_closure(x) = (y -> y * x)(x)
@context SqrCtx
x = rand()
@test square_closure(x) == @overdub(SqrCtx(), square_closure(x))

############################################################################################

comprehension1(x) = [i for i in x]
comprehension2(f, x, y) = [f(x, i) for i in y]
@context CompCtx
f, x, y = hypot, rand(), rand(2)
@test comprehension1(x) == @overdub(CompCtx(), comprehension1(x))
@test comprehension1(y) == @overdub(CompCtx(), comprehension1(y))
@test comprehension2(f, x, y) == @overdub(CompCtx(), comprehension2(f, x, y))

############################################################################################

struct Baz
    x::Int
    y::Float64
    z::String
end

baz_identity(x::Int) = Baz(x, float(x), "$x").x

@context BazCtx
Cassette.metatype(::Type{<:BazCtx}, ::Type{<:Integer}) = Float64
x, n = rand(Int), rand()
result = @overdub BazCtx(boxes=Val(true)) begin
    ctx = __context__
    b0 = box(ctx, x, n)
    b1 = baz_identity(b0)
    rx = unbox(ctx, b1)
    rn = hasmeta(ctx, b1) ? meta(ctx, b1) : nothing
    return (rx, rn)
end
@test x === result[1]
@test n === result[2]

############################################################################################

struct Bar{X,Y,Z}
    x::X
    y::Y
    z::Z
end

mutable struct Foo
    a::Bar{Int}
    b
end

function foo_bar_identity(x)
    bar = Bar(x, x + 1, x + 2)
    foo = Foo(bar, "ha")
    foo.b = bar
    foo.a = Bar(4,5,6)
    foo2 = Foo(foo.a, foo.b)
    foo2.a = foo2.b
    return foo2.a.x
end

@context FooBarCtx
Cassette.metatype(::Type{<:FooBarCtx}, ::Type{<:Integer}) = Float64
x, n = rand(Int), rand()
result = @overdub FooBarCtx(boxes=Val(true)) begin
    ctx = __context__
    b0 = box(ctx, x, n)
    b1 = foo_bar_identity(b0)
    rx = unbox(ctx, b1)
    rn = hasmeta(ctx, b1) ? meta(ctx, b1) : nothing
    return (rx, rn)
end
@test x === result[1]
@test n === result[2]

############################################################################################

sig_collection = DataType[]
@context PassCtx
mypass = @pass (sig, cinfo) -> (push!(sig_collection, sig); cinfo)
@overdub(PassCtx(pass=mypass), sum(rand(3)))
@test !isempty(sig_collection) && all(T -> T <: Tuple, sig_collection)

############################################################################################

mutable struct Count{T}
    count::Int
end

@context CountCtx2

@prehook function (::Any)(arg::T, args::T...) where {T,__CONTEXT__<:CountCtx2{Count{T}}}
    __context__.metadata.count += 1
end

mapstr(x) = map(string, x)
c = Count{Union{String,Int}}(0)
@test @overdub(CountCtx2(metadata=c), mapstr(1:10)) == mapstr(1:10)
@test c.count > 1000

############################################################################################

@context NestedCtx

function nested_test(n, x)
    if n < 1
        return sin(x)
    else
        return @overdub(NestedCtx(), nested_test(n - 1, x + x))
    end
end

x = rand()
ctxs = Cassette.AbstractTag[]
tag_id = objectid(typeof(nested_test))

@prehook function (::Any)(args...) where {__CONTEXT__<:NestedCtx}
    !(in(__context__.tag, ctxs)) && push!(ctxs, __context__.tag)
end

@test @overdub(NestedCtx(), nested_test(2, x)) === sin(x + x + x + x)

# TODO: restore this test
# tag_type = NestedCtx{Tag{NestedCtx{Tag{NestedCtx{Tag{Nothing,tag_id}},tag_id}},tag_id}}
# @test any(x -> isa(x, nested_ctx_type), ctxs)

end # module
