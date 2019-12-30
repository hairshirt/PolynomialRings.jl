import DataStructures: enqueue!, dequeue!

import ..Util: BoundedHeap, @assertvalid

"""
    SparsePolynomial{M, C} where M <: AbstractMonomial where C

This type represents a polynomial as a vector of monomials and a vector of
matching non-zero coefficients. All methods guarantee and assume that the vector
is sorted by increasing monomial order (see
`PolynomialRings.MonomialOrderings`).
"""
struct SparsePolynomial{M <: AbstractMonomial, C}
    monomials :: Vector{M}
    coeffs    :: Vector{C}
end

const SparsePolynomialOver{C,Order} = SparsePolynomial{<:AbstractMonomial{Order}, C}
const SparsePolynomialBy{Order,C}   = SparsePolynomialOver{C,Order}

isstrictlysparse(P::Type{<:SparsePolynomial}) = true
issparse(P::Type{<:SparsePolynomial}) = true

monomials(f::SparsePolynomial) = f.monomials
coefficients(f::SparsePolynomial) = f.coeffs

function Base.empty!(p::SparsePolynomial)
    empty!(p.coeffs)
    empty!(p.monomials)
    @assertvalid p
end

function Base.push!(p::SparsePolynomial{M}, t::Term{M}) where M <: AbstractMonomial
    @assert isempty(p.monomials) || isless(last(p.monomials), monomial(t))
    c = convert(basering(p), coefficient(t))
    if !iszero(c)
        push!(p.monomials, monomial(t))
        push!(p.coeffs, c)
    end
    @assertvalid p
end

function Base.sizehint!(p::SparsePolynomial, n)
    sizehint!(p.coeffs, n)
    sizehint!(p.monomials, n)
    p
end

function Base.copy!(dst::SparsePolynomial, src::SparsePolynomial)
    copy!(dst.coeffs, src.coeffs)
    copy!(dst.monomials, src.monomials)
    @assertvalid dst
end

hash(p::SparsePolynomial, h::UInt) = hash(p.monomials, hash(p.coeffs, h))

_leading_term_ix(p::SparsePolynomial, order::MonomialOrder) = argmax(order, p.monomials)
function leading_term(p::SparsePolynomial; order::MonomialOrder=monomialorder(p))
    ix = _leading_term_ix(p, order)
    Term(p.monomials[ix], p.coeffs[ix])
end
leading_monomial(p::SparsePolynomial; order::MonomialOrder=monomialorder(p)) = p.monomials[_leading_term_ix(p, order)]
leading_coefficient(p::SparsePolynomial; order::MonomialOrder=monomialorder(p)) = p.coeffs[_leading_term_ix(p, order)]

tail(p::SparsePolynomial, order::MonomialOrder) = p - leading_term(p; order=order)
tail(p::SparsePolynomial; order::MonomialOrder=monomialorder(p)) = tail(p, order)


_leading_term_ix(p::SparsePolynomialBy{Order}, order::Order) where Order <: MonomialOrder = isstrictlysparse(p) ? length(p.coeffs) : findlast(!iszero, p.coeffs)
function tail(p::SparsePolynomialBy{Order}, order::Order) where Order <: MonomialOrder
    ix = _leading_term_ix(p, order)
    typeof(p)(p.monomials[1:ix-1], p.coeffs[1:ix-1])
end

# -----------------------------------------------------------------------------
#
# zero, one, etc
#
# -----------------------------------------------------------------------------
zero(::Type{P}) where P <: SparsePolynomial = @assertvalid P(monomialtype(P)[], basering(P)[])
one(::Type{P})  where P <: SparsePolynomial = @assertvalid P([one(monomialtype(P))], [one(basering(P))])
iszero(a::P)    where P <: SparsePolynomial = isempty(coefficients(a))

==(a::P, b::P)  where P <: SparsePolynomial = a.monomials == b.monomials && a.coeffs == b.coeffs
+(a::P)         where P <: SparsePolynomial = @assertvalid P(copy(a.monomials), copy(a.coeffs))
-(a::P)         where P <: SparsePolynomial = @assertvalid P(copy(a.monomials), map(-, a.coeffs))

# -----------------------------------------------------------------------------
#
# utility for operators
#
# -----------------------------------------------------------------------------
function _filterzeros!(p::SparsePolynomial)
    !isstrictlysparse(p) && return p
    tgtix = 0
    for srcix in eachindex(p.coeffs)
        if !iszero(p.coeffs[srcix])
            tgtix += 1
            p.monomials[tgtix] = p.monomials[srcix]
            p.coeffs[tgtix] = p.coeffs[srcix]
        end
    end
    resize!(p.monomials, tgtix)
    resize!(p.coeffs, tgtix)
    p
end

function _collectsummands!(p::SparsePolynomial)
    if length(p.coeffs) > 1
        I = sortperm(p.monomials, order=monomialorder(p))
        p.monomials[:] = p.monomials[I]
        p.coeffs[:] = p.coeffs[I]
        tgtix = 1
        for srcix in 2:length(p.coeffs)
            if p.monomials[tgtix] == p.monomials[srcix]
                @inplace p.coeffs[tgtix] += p.coeffs[srcix]
            else
                tgtix += 1
                p.monomials[tgtix] = p.monomials[srcix]
                p.coeffs[tgtix] = p.coeffs[srcix]
            end
        end
        resize!(p.monomials, tgtix)
        resize!(p.coeffs, tgtix)
    end
    _filterzeros!(p)
end

# -----------------------------------------------------------------------------
#
# multiplication
#
# -----------------------------------------------------------------------------

"""
    f = g * h

Return the product of two polynomials.

The implementation is as follows.

A naive implementation would have three steps: first, generate all the summands
as the cartesian product of the terms of `g` and the terms of `h`. Second, sort
the list by monomial order. Third, walk over the sorted list and sum the
coefficients of any terms with equal monomial.

A major improvement can be had if we avoid the sorting, and instead walk
over the cartesian product in the right order.

To understand this, let the following diagram represent the summands
in the cartesian product, with monomial order of the factors increasing
top to bottom and left to right:

    . . . . . . . . . . .
    . . . . . . . . . . .
    . . . . . . . . . . .
    . . . . . . . . . . .

When a certain number of terms have been evaluated and added to the
output (marked by `*` below), the situation may be as follows:

    * * * * * * * ? . . .
    * * * ? . . . . . . .
    ? . . . . . . . . . .
    . . . . . . . . . . .

The key insight is that _the only possibility for the next minimal
terms are the ones marked by `?`_. This is because of the multiplicative
property of monomial orders (``m ≺ n ⇒ km ≺ kn``).

We call these possible minimal terms the 'minimal corners'. In the
implementation below, a `Heap` data structure keeps track of them.

This allows us to avoid separate sorting and summing passes. In turn,
this allows keeping running totals of the coefficients and do all these
operations in-place for mutable types (e.g. BigInt).
"""
function *(a::SparsePolynomialBy{Order}, b::SparsePolynomialBy{Order}) where Order
    ≺(a, b) = Base.Order.lt(Order(), a, b)
    P = promote_type(typeof(a), typeof(b))
    # FIXME(tkluck): promote_type currently only guarantees that
    #     namingscheme(P) == namingscheme(Order)
    # See NamedPolynomials.jl
    @assert monomialorder(P) == Order()
    C = basering(P)
    T = termtype(P)
    M = monomialtype(P)

    if iszero(a) || iszero(b)
        return zero(P)
    end

    l_a = length(a.coeffs)
    l_b = length(b.coeffs)

    monomials = Vector{M}(undef, l_a * l_b)
    coeffs = Vector{C}(undef, l_a * l_b)
    k = 0

    done_until_col_at_row = zeros(Int, l_a)
    done_until_row_at_col = zeros(Int, l_b)

    # We use a *bounded* queue not because we want to drop items when it
    # gets too big, but because we want to allocate it once to its maximal
    # theoretical size, and then never reallocate.
    order = Base.Order.Lt((a, b) -> a[3] ≺ b[3])
    Key = Tuple{Int, Int, M}
    minimal_corners = BoundedHeap(Key, min(l_a, l_b), order)

    # initialize with the minimal term at (row, col) = (1, 1)
    @inbounds m = a.monomials[1] * b.monomials[1]
    enqueue!(minimal_corners, (1, 1, m))

    temp = zero(C)

    @inbounds while !isempty(minimal_corners)
        row, col, m = dequeue!(minimal_corners)

        # compute the product of the terms at (row, col)
        if k > 0 && m == monomials[k]
            @inplace temp = a.coeffs[row] * b.coeffs[col]
            @inplace coeffs[k] += temp
        else
            k += 1
            monomials[k] = m
            coeffs[k] = a.coeffs[row] * b.coeffs[col]
        end

        # mark as done
        done_until_col_at_row[row] = col
        done_until_row_at_col[col] = row

        # decide whether we just added new minimal corners
        if row < l_a && done_until_col_at_row[row+1] == col - 1
            r, c = row + 1, col
            m = a.monomials[r] * b.monomials[c]
            enqueue!(minimal_corners, (r, c, m))
        end
        if col < l_b && done_until_row_at_col[col+1] == row - 1
            r, c = row, col + 1
            m = a.monomials[r] * b.monomials[c]
            enqueue!(minimal_corners, (r, c, m))
        end
    end
    resize!(monomials, k)
    resize!(coeffs, k)
    return @assertvalid _filterzeros!(P(monomials, coeffs))
end

# -----------------------------------------------------------------------------
#
# exponentiation
#
# -----------------------------------------------------------------------------
function multinomial(n,k...)
    @assert sum(k) == n

    i = 1
    for k_i in k
        i *= binomial(n,k_i)
        n -= k_i
    end
    i
end

function ^(f::SparsePolynomial, n::Integer)
    if n == 0
        return one(f)
    end
    if n == 1 || iszero(f)
        return deepcopy(f)
    end

    P = typeof(f)
    M = monomialtype(f)
    C = basering(f)
    E = exptype(f)
    I = typeof(n)

    N = length(f.coeffs)

    # need BigInts to do the multinom computation, but we'll cast
    # back to I = typeof(n) when we use it as an exponent
    bign = BigInt(n)
    i = zeros(BigInt, N)
    i[N] = bign

    nterms = Int(multinomial(bign + N - 1, N - 1, bign))
    monomials = Vector{M}(undef, nterms)
    coeffs = Vector{C}(undef, nterms)
    s = 0

    while true
        c = try
            C(multinomial(bign, i...))
        catch
            # FIXME: what's the Julian way of doing a typeassert e::InexactError
            # and bubble up all other exceptions?
            throw(OverflowError("Coefficient overflow while doing exponentiation; suggested fix is replacing `f^n` by `base_extend(f, BigInt)^n`"))
        end
        s += 1
        monomials[s] =     prod(f.monomials[k] ^ E(i[k]) for k = 1:N)
        coeffs[s]    = c * prod(f.coeffs[k]    ^ I(i[k]) for k = 1:N)

        carry = 1
        for j = N - 1 : -1 : 1
            i[j] += carry
            i[N] -= carry
            if i[N] < 0
                carry = 1
                i[N] += i[j]
                i[j] = 0
            else
                carry = 0
            end
        end
        if carry != 0
            break
        end
    end

    @assertvalid _collectsummands!(P(monomials, coeffs))
end

# -----------------------------------------------------------------------------
#
# differentiation
#
# -----------------------------------------------------------------------------
function diff(f::SparsePolynomial, i::Integer)
    iszero(f) && return zero(f)
    new_terms = filter(!iszero, map(t->diff(t,i), nzterms(f)))
    sort!(new_terms, order=monomialorder(f))
    monomials = [monomial(t) for t in new_terms]
    coeffs = [coefficient(t) for t in new_terms]
    return @assertvalid typeof(f)(monomials, coeffs)
end

"""
    p = map_coefficients(f, q)

Apply a function `f` to all coefficients of `q`, and return the result.
"""
function map_coefficients(f, a::SparsePolynomial)
    @assertvalid _filterzeros!(SparsePolynomial(copy(a.monomials), map(f, a.coeffs)))
end

# -----------------------------------------------------------------------------
#
# Use Term/Monomial/Coefficient as a scalar
#
# -----------------------------------------------------------------------------
function *(a::M, b::P) where P <: SparsePolynomial{M} where M <: AbstractMonomial
    @assertvalid P(a .* b.monomials, deepcopy(b.coeffs))
end
function *(a::P, b::M) where P <: SparsePolynomial{M} where M <: AbstractMonomial
    @assertvalid P(a.monomials .* b, deepcopy(a.coeffs))
end
for Coeff in [Any, Number]
    @eval begin
        function *(a::T, b::P) where P <: SparsePolynomial{M,C} where T <: Term{M,C} where {M <: AbstractMonomial, C <: $Coeff}
            iszero(a) && return zero(P)
            @assertvalid P(monomial(a) .* b.monomials, coefficient(a) .* b.coeffs)
        end
        function *(a::P, b::T) where P <: SparsePolynomial{M,C} where T <: Term{M,C} where {M <: AbstractMonomial, C <: $Coeff}
            iszero(b) && return zero(P)
            @assertvalid P(a.monomials .* monomial(b), a.coeffs .* coefficient(b))
        end
    end
end

# -----------------------------------------------------------------------------
#
# Adding terms/monomials/scalars
#
# -----------------------------------------------------------------------------
function inclusiveinplace!(::typeof(+), a::P, b::T) where
            P <: SparsePolynomial{M, C} where
            T <: Term{M, C} where
            {M <: AbstractMonomial, C}
    ix = searchsorted(a.monomials, monomial(b))
    if length(ix) == 1
        i = first(ix)
        @inplace a.coeffs[i] += coefficient(b)
        if isstrictlysparse(a) && iszero(a.coeffs[i])
            deleteat!(a.monomials, i)
            deleteat!(a.coeffs, i)
        end
    elseif isempty(ix)
        i = first(ix)
        insert!(a.monomials, i, monomial(b))
        insert!(a.coeffs, i, coefficient(b))
    else
        @error "Invalid polynomial" a dump(a)
        error("Invalid polynomial")
    end
    @assertvalid a
end

function inclusiveinplace!(::typeof(+), a::P, b::M) where
            P <: SparsePolynomial{M, C} where
            {M <: AbstractMonomial, C}
    ix = searchsorted(a.monomials, b)
    if length(ix) == 1
        i = first(ix)
        @inplace a.coeffs[i] += one(basering(a))
        if isstrictlysparse(a) && iszero(a.coeffs[i])
            deleteat!(a.monomials, i)
            deleteat!(a.coeffs, i)
        end
    elseif isempty(ix)
        i = first(ix)
        insert!(a.monomials, i, b)
        insert!(a.coeffs, i, one(basering(a)))
    else
        @error "Invalid polynomial" a dump(a)
        error("Invalid polynomial")
    end
    @assertvalid a
end

function inclusiveinplace!(::typeof(+), a::P, b::C) where
            P <: SparsePolynomial{M, C} where
            {M <: AbstractMonomial, C}
    ix = searchsorted(a.monomials, one(monomialtype(a)))
    if length(ix) == 1
        i = first(ix)
        @inplace a.coeffs[i] += b
        if isstrictlysparse(a) && iszero(a.coeffs[i])
            deleteat!(a.monomials, i)
            deleteat!(a.coeffs, i)
        end
    elseif isempty(ix)
        i = first(ix)
        insert!(a.monomials, i, one(monomialtype(a)))
        insert!(a.coeffs, i, b)
    else
        @error "Invalid polynomial" a dump(a)
        error("Invalid polynomial")
    end
    @assertvalid a
end

function inclusiveinplace!(::typeof(*), a::P, b::C) where
            P <: SparsePolynomial{M, C} where
            {M <: AbstractMonomial, C}
    if iszero(b)
        empty!(a)
    else
        a.coeffs .*= b
    end
    @assertvalid a
end

function convert(P::Type{<:SparsePolynomialOver{C,O}}, p::SparsePolynomialOver{D,O}) where {C,D,O <: MonomialOrder}
    return @assertvalid _filterzeros!(P(p.monomials, convert.(C, p.coeffs)))
end

function to_dense_monomials(n, p::SparsePolynomial)
    coeffs = map(deepcopy, coefficients(p))
    monoms = to_dense_monomials.(n, monomials(p))
    return SparsePolynomial(monoms, coeffs)
end

max_variable_index(p::SparsePolynomial) = iszero(p) ? 0 : maximum(max_variable_index(m) for m in monomials(p))
