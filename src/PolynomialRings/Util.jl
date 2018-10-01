module Util

import Base: delete!
import Base: iterate
import Base: length, isempty
import Base: length, iterate

import DataStructures: PriorityQueue
import DataStructures: percolate_down!, percolate_up!, enqueue!, dequeue!, peek


# -----------------------------------------------------------------------------
#
# Bounded heap
#
# -----------------------------------------------------------------------------
mutable struct BoundedHeap{T, O<:Base.Order.Ordering}
    values::Vector{T}
    cur_length::Int
    max_length::Int
    order::O
    BoundedHeap{T, O}(max_length::Int, order::O) where {T, O} = new(resize!(T[], max_length+1), 0, max_length, order)
end

BoundedHeap(T::Type, max_length::Int, order::Base.Order.Ordering) = BoundedHeap{T, typeof(order)}(max_length, order)


function enqueue!(x::BoundedHeap{T, O}, v::T) where {T,O}
    x.values[x.cur_length+1] = v
    if(x.cur_length < x.max_length)
        x.cur_length +=1
    end
    percolate_up!(x.values, x.cur_length, x.order)
end

function dequeue!(x::BoundedHeap{T, O})::T where {T,O}
    if x.cur_length < 1
        throw(BoundsError())
    end
    v = x.values[1]
    x.values[1] = x.values[x.cur_length]
    x.cur_length -= 1
    percolate_down!(x.values, 1, x.order, x.cur_length)
    return v
end

function peek(x::BoundedHeap{T,O})::T where {T,O}
    if x.cur_length < 1
        throw(BoundsError())
    end
    return x.values[1]
end

length(x::BoundedHeap) = x.cur_length
isempty(x::BoundedHeap) = iszero(x.cur_length)


lazymap(f::Function, c) = map(f,c)
lazymap(f::Function, c::C) where C<:Channel = Channel() do ch
    for x in c
        push!(ch, f(x))
    end
end

# -----------------------------------------------------------------------------
#
# make filter! work for priority queues
#
# -----------------------------------------------------------------------------
delete!(pq::PriorityQueue{K}, k::K) where K = dequeue!(pq, k)

# -----------------------------------------------------------------------------
#
# One-element iterator
#
# -----------------------------------------------------------------------------
struct SingleItemIter{X}
    item::X
end
length(::SingleItemIter) = 1
iterate(i::SingleItemIter) = (i.item, nothing)
iterate(i::SingleItemIter, ::Nothing) = nothing

include("LinAlgUtil.jl")

# -----------------------------------------------------------------------------
#
# Parallel iteration of two iterators
#
# -----------------------------------------------------------------------------
struct ParallelIter{I,J,key,value,≺,l0,r0}
    left::I
    right::J
end
ParallelIter(key, value, ≺, l0, r0, left, right) = ParallelIter{
        typeof(left), typeof(right),
        key, value, ≺,
        l0, r0,
    }(left, right)

struct Start end
struct LeftReady{T,S}
    liter::T
    rstate::S
end
struct RightReady{T,S}
    riter::T
    lstate::S
end
struct NextTwo{T,S}
    lstate::T
    rstate::S
end
# LeftDone could be represented by LeftReady{Nothing}, but Julia's type
# inference seems happier with a slightly flatter type tree. I checked
# that by adding
#     return it
# to _materialize!, allowing me to obtain the TermsMap from
#     @ring! ℤ[x,y]
#     t = x.terms[1].m
#     it = @. BigInt(1)*x - BigInt(1)*(t*x);
# and then inspecting
#     @code_warntype iterate(it, PolynomialRings.Util.Start())
struct LeftDone{S}
    rstate::S
end
struct RightDone{S}
    lstate::S
end

function iterate2(i::ParallelIter, state::LeftReady)
    riter = iterate(i.right, state.rstate)
    state.liter, riter
end
function iterate2(i::ParallelIter, state::LeftDone)
    riter = iterate(i.right, state.rstate)
    nothing, riter
end
function iterate2(i::ParallelIter, state::RightReady)
    liter = iterate(i.left, state.lstate)
    liter, state.riter
end
function iterate2(i::ParallelIter, state::RightDone)
    liter = iterate(i.left, state.lstate)
    liter, nothing
end
function iterate2(i::ParallelIter, state::NextTwo)
    iterate(i.left, state.lstate), iterate(i.right, state.rstate)
end
function iterate2(i::ParallelIter, ::Start)
    iterate(i.left), iterate(i.right)
end

@inline function iterate(i::ParallelIter{I,J,key,value,≺,l0,r0}, state=Start()) where {I,J,key,value,≺,l0,r0}
    liter, riter = iterate2(i, state)
    if liter === nothing && riter === nothing
        return nothing
    elseif liter === nothing
        return (key(riter[1]), l0, value(riter[1])), LeftDone(riter[2])
    elseif riter === nothing
        return (key(liter[1]), value(liter[1]), r0), RightDone(liter[2])
    elseif key(riter[1]) ≺ key(liter[1])
        return (key(riter[1]), l0, value(riter[1])), LeftReady(liter, riter[2])
    elseif key(liter[1]) ≺ key(riter[1])
        return (key(liter[1]), value(liter[1]), r0), RightReady(riter, liter[2])
    elseif key(liter[1]) == key(riter[1])
        return (key(liter[1]), value(liter[1]), value(riter[1])), NextTwo(liter[2], riter[2])
    else
        @assert(false) # unreachable?
    end
end

# -----------------------------------------------------------------------------
#
# In-place operations that work for BigInt but also for immutable types
#
# -----------------------------------------------------------------------------
inplace!(op, a, b, c) = (a = op(b,c); a)
inplace!(::typeof(+), a::BigInt, b::BigInt, c::BigInt) = (Base.GMP.MPZ.add!(a,b,c); a)
inplace!(::typeof(-), a::BigInt, b::BigInt, c::BigInt) = (Base.GMP.MPZ.sub!(a,b,c); a)
inplace!(::typeof(*), a::BigInt, b::BigInt, c::BigInt) = (Base.GMP.MPZ.mul!(a,b,c); a)

add!(a, b)    = inplace!(+, a, a, b)
add!(a, b, c) = inplace!(+, a, b, c)
mul!(a, b, c) = inplace!(*, a, b, c)

end
